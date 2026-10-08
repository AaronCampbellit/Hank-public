import Foundation
import SwiftData
import SwiftUI
import UIKit
import os

struct NoteSearchResult: Identifiable, Hashable {
    let noteID: UUID
    let title: String
    let preview: String
    let query: String
    let matchLocation: Int

    var id: String {
        "\(noteID.uuidString)-\(matchLocation)-\(query)"
    }
}

struct TaggedLineRollupItem: Identifiable, Hashable {
    let noteID: UUID
    let noteTitle: String
    let tag: String
    let lineText: String
    let lineIndex: Int
    let noteUpdatedAt: Date

    var id: String {
        "\(noteID.uuidString)-\(tag)-\(lineIndex)"
    }
}

struct NotesEditorSearchRequest: Identifiable, Equatable {
    let id = UUID()
    let noteID: UUID
    let query: String
}

enum NotesLandingState: Equatable {
    case root
    case note(UUID)
}

private struct NotesRealtimeNotificationPayload: Decodable {
    let noteID: String?
    let noteInternalID: String?
    let updatedBy: String?

    enum CodingKeys: String, CodingKey {
        case noteID = "note_id"
        case noteInternalID = "note_internal_id"
        case updatedBy = "updated_by"
    }
}

@MainActor
final class NotesStore: ObservableObject {
    enum LoadState: Equatable {
        case loading
        case ready
        case unavailable(String)
    }

    @Published private(set) var loadState: LoadState = .loading
    @Published var searchText = ""
    @Published var selectedTag: String?
    @Published var selectedNoteID: UUID?
    @Published var noteTitle = ""
    @Published var noteBody = NSAttributedString(string: "")
    @Published var errorMessage: String?
    @Published private(set) var isSaving = false
    @Published private(set) var landingState: NotesLandingState = .root
    @Published private(set) var requestedEditorSearch: NotesEditorSearchRequest?
    @Published private(set) var collaboratorCount = 0

    private var workspace: NotesWorkspaceSnapshot?
    private var attributedBodies: [UUID: NSAttributedString] = [:]
    private var currentProfileID: UUID?
    private var modelContext: ModelContext?
    private weak var services: AppServices?
    private var saveTask: Task<Void, Never>?
    private var realtimeTask: Task<Void, Never>?
    private var realtimeReloadTask: Task<Void, Never>?
    private var realtimeContext: HankRemoteConnectionContext?
    private var realtimeSelectedCollabTopic: String?
    private var collaborationSession: HankRemoteNoteCollaborationSession?
    private var collaborationEventsTask: Task<Void, Never>?
    private var collaborationSubmitTask: Task<Void, Never>?
    private var hasPendingLocalSave = false
    private var lastLocalEditAt: Date?
    private var localSaveGeneration = 0
    private let realtimeReloadQuietInterval: TimeInterval = 2.0
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.dropfile.Hank", category: "NotesSync")
    private var isLoadingWorkspace = false

    deinit {
        saveTask?.cancel()
        realtimeTask?.cancel()
        realtimeReloadTask?.cancel()
        collaborationEventsTask?.cancel()
        collaborationSubmitTask?.cancel()
    }

    var outlineItems: [NoteOutlineItem] {
        guard let workspace else {
            return []
        }

        return NoteTreeManager.outlineItems(
            entries: workspace.entries,
            searchText: "",
            bodyText: Dictionary(uniqueKeysWithValues: attributedBodies.map { ($0.key, $0.value.string) })
        )
    }

    var selectedNotebookChildItems: [NoteOutlineItem] {
        guard let selectedNoteID else {
            return []
        }
        return outlineItems.filter { $0.entry.parentID == selectedNoteID }
    }

    var searchResults: [NoteSearchResult] {
        guard let workspace else {
            return []
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return []
        }

        return workspace.entries.compactMap { entry in
            let title = displayTitle(for: entry)
            let body = attributedBodies[entry.id]?.string ?? ""
            let titleRange = (title as NSString).range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
            let bodyRange = (body as NSString).range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
            guard titleRange.location != NSNotFound || bodyRange.location != NSNotFound else {
                return nil
            }

            let preview: String
            let matchLocation: Int
            if bodyRange.location != NSNotFound {
                let bodyNSString = body as NSString
                let start = max(0, bodyRange.location - 38)
                let length = min(bodyNSString.length - start, max((query as NSString).length + 24, 88))
                let snippet = bodyNSString.substring(with: NSRange(location: start, length: length))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                preview = snippet.isEmpty ? title : snippet
                matchLocation = bodyRange.location
            } else {
                preview = title
                matchLocation = 0
            }

            return NoteSearchResult(
                noteID: entry.id,
                title: title,
                preview: preview,
                query: query,
                matchLocation: matchLocation
            )
        }
        .sorted { lhs, rhs in
            if lhs.title == rhs.title {
                return lhs.preview.localizedCaseInsensitiveCompare(rhs.preview) == .orderedAscending
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    var availableTags: [String] {
        guard let workspace else {
            return []
        }

        var tags = Set<String>()
        for entry in workspace.entries where entry.pageType == .text {
            for parsed in Self.extractTaggedLines(from: attributedBodies[entry.id]?.string ?? "") {
                tags.insert(parsed.tag)
            }
        }
        return tags.sorted()
    }

    var tagRollupItems: [TaggedLineRollupItem] {
        guard let workspace, let selectedTag else {
            return []
        }

        return workspace.entries.flatMap { entry -> [TaggedLineRollupItem] in
            guard entry.pageType == .text else {
                return []
            }

            let title = displayTitle(for: entry)
            return Self.extractTaggedLines(from: attributedBodies[entry.id]?.string ?? "")
                .enumerated()
                .compactMap { index, line in
                    guard line.tag.caseInsensitiveCompare(selectedTag) == .orderedSame else {
                        return nil
                    }
                    return TaggedLineRollupItem(
                        noteID: entry.id,
                        noteTitle: title,
                        tag: line.tag,
                        lineText: line.text,
                        lineIndex: index,
                        noteUpdatedAt: entry.updatedAt
                    )
                }
        }
        .sorted { lhs, rhs in
            if lhs.noteUpdatedAt != rhs.noteUpdatedAt {
                return lhs.noteUpdatedAt > rhs.noteUpdatedAt
            }
            if lhs.noteTitle == rhs.noteTitle {
                return lhs.lineIndex < rhs.lineIndex
            }
            return lhs.noteTitle.localizedCaseInsensitiveCompare(rhs.noteTitle) == .orderedAscending
        }
    }

    var currentConfiguration: NotesConfigSnapshot? {
        workspace?.configuration
    }

    var selectedEntry: NoteManifestEntry? {
        guard let selectedNoteID else {
            return nil
        }
        return workspace?.entries.first(where: { $0.id == selectedNoteID })
    }

    var selectedPageType: NotePageType {
        selectedEntry?.pageType ?? .text
    }

    var selectedBoard: KanbanBoard? {
        guard let selectedNoteID else {
            return nil
        }
        return workspace?.boards[selectedNoteID]
    }

    func hasChildren(_ noteID: UUID) -> Bool {
        workspace?.entries.contains(where: { $0.parentID == noteID }) ?? false
    }

    func loadIfNeeded(profileID: UUID, modelContext: ModelContext, services: AppServices, force: Bool = false) async {
        if !force, currentProfileID == profileID, workspace != nil {
            return
        }
        guard !isLoadingWorkspace else {
            return
        }
        isLoadingWorkspace = true
        defer { isLoadingWorkspace = false }
        await load(profileID: profileID, modelContext: modelContext, services: services)
    }

    func load(profileID: UUID, modelContext: ModelContext, services: AppServices) async {
        let shouldPreserveSelection = currentProfileID == profileID
        let previousLandingState = shouldPreserveSelection ? landingState : .root
        let previousSelection = shouldPreserveSelection ? selectedNoteID : nil
        currentProfileID = profileID
        self.modelContext = modelContext
        self.services = services
        loadState = .loading
        errorMessage = nil
        saveTask?.cancel()
        hasPendingLocalSave = false
        lastLocalEditAt = nil
        localSaveGeneration = 0

        do {
            logger.info("Loading Notes workspace profile_id=\(profileID.uuidString, privacy: .public)")
            let workspace = try await services.notesService.loadWorkspace(
                profileID: profileID,
                modelContext: modelContext,
                services: services
            )
            self.workspace = workspace
            attributedBodies = workspace.bodies.mapValues(Self.decodeBody)

            let resolvedSelection = previousSelection.flatMap { id in
                workspace.entries.contains(where: { $0.id == id }) ? id : nil
            }

            switch previousLandingState {
            case .root:
                selectedNoteID = nil
                landingState = .root
            case .note(let noteID):
                let noteSelection = shouldPreserveSelection
                    ? (workspace.entries.contains(where: { $0.id == noteID }) ? noteID : resolvedSelection)
                    : resolvedSelection
                selectedNoteID = noteSelection
                landingState = noteSelection.map(NotesLandingState.note) ?? .root
            }

            syncEditorState()
            refreshSharedDestinationCache()
            loadState = .ready
            logger.info("Loaded Notes workspace profile_id=\(profileID.uuidString, privacy: .public) note_count=\(workspace.entries.count, privacy: .public)")
            startNotesRealtimeIfAvailable()
        } catch {
            workspace = nil
            attributedBodies = [:]
            selectedNoteID = nil
            noteTitle = ""
            noteBody = NSAttributedString(string: "")
            landingState = .root
            loadState = .unavailable(error.localizedDescription)
            errorMessage = error.localizedDescription
            logger.error("Failed to load Notes workspace profile_id=\(profileID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            stopNotesRealtime()
        }
    }

    func select(_ noteID: UUID?, revealDetail: Bool = true, editorSearch: String? = nil) {
        if let noteID {
            selectedNoteID = noteID
            landingState = revealDetail ? .note(noteID) : .root
            if let editorSearch, !editorSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                requestedEditorSearch = NotesEditorSearchRequest(noteID: noteID, query: editorSearch)
            }
        } else {
            selectedNoteID = nil
            landingState = .root
        }
        syncEditorState()
        updateSelectedCollaborationSubscription()
    }

    func showRoot() {
        selectedNoteID = nil
        landingState = .root
        syncEditorState()
        updateSelectedCollaborationSubscription()
    }

    func resetToHome() {
        searchText = ""
        selectedTag = nil
        errorMessage = nil
        showRoot()
    }

    func consumeRequestedEditorSearch() -> NotesEditorSearchRequest? {
        defer { requestedEditorSearch = nil }
        return requestedEditorSearch
    }

    func title(for noteID: UUID) -> String {
        guard let entry = workspace?.entries.first(where: { $0.id == noteID }) else {
            return NoteTreeManager.rootNoteTitle
        }
        return displayTitle(for: entry)
    }

    func rename(noteID: UUID, to title: String) {
        guard var workspace else {
            return
        }

        NoteTreeManager.rename(noteID: noteID, to: title, entries: &workspace.entries)
        self.workspace = workspace
        if selectedNoteID == noteID {
            syncEditorState()
        }
        refreshSharedDestinationCache()
        scheduleSelectedCollaborationSubmit(noteID: noteID)
        scheduleSave()
    }

    func makeShareItem(for noteID: UUID) throws -> NoteShareItem {
        guard let workspace, let entry = workspace.entries.first(where: { $0.id == noteID }) else {
            throw NotesServiceError.noteNotFound
        }

        let title = displayTitle(for: entry)
        let body: NSAttributedString
        let markdown: String

        switch entry.pageType {
        case .text:
            body = attributedBodies[noteID] ?? NSAttributedString(string: "")
            markdown = NoteMarkdownExporter.markdown(title: title, attributedText: body)
        case .kanban:
            let boardText = Self.kanbanMarkdown(title: title, board: workspace.boards[noteID] ?? KanbanBoard())
            body = NSAttributedString(string: boardText)
            markdown = boardText
        case .notebook:
            let notebookText = Self.notebookMarkdown(title: title, noteID: noteID, entries: workspace.entries)
            body = NSAttributedString(string: notebookText)
            markdown = notebookText
        }

        let export = NSMutableAttributedString()
        export.append(NSAttributedString(
            string: title,
            attributes: [
                .font: UIFont.preferredFont(forTextStyle: .title1),
                .foregroundColor: UIColor.label
            ]
        ))
        export.append(NSAttributedString(string: "\n\n"))
        export.append(body)

        let data = Data(markdown.utf8)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HankSharedNotes", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory
            .appendingPathComponent(Self.safeFileName(for: title))
            .appendingPathExtension("md")
        try data.write(to: fileURL, options: .atomic)
        return NoteShareItem(
            title: title,
            attributedText: export,
            plainText: export.string,
            markdownText: markdown,
            markdownURL: fileURL
        )
    }

    func updateTitle(_ title: String) {
        guard var workspace, let selectedNoteID else {
            return
        }

        noteTitle = title
        clearTransientRemoteErrorIfNeeded()
        NoteTreeManager.rename(noteID: selectedNoteID, to: title, entries: &workspace.entries)
        self.workspace = workspace
        refreshSharedDestinationCache()
        scheduleSelectedCollaborationSubmit(noteID: selectedNoteID)
        scheduleSave()
    }

    func updateBody(_ attributedText: NSAttributedString) {
        guard var workspace, let selectedNoteID else {
            return
        }
        guard workspace.entries.first(where: { $0.id == selectedNoteID })?.pageType == .text else {
            return
        }

        applyBody(attributedText, to: selectedNoteID, workspace: &workspace)
        clearTransientRemoteErrorIfNeeded()
        scheduleSelectedCollaborationSubmit(noteID: selectedNoteID)
        scheduleSave()
    }

    func appendSharedContent(
        to noteID: UUID,
        kind: IncomingSharePayload.Kind,
        text rawText: String,
        revealImportedNote: Bool = true
    ) throws {
        guard var workspace else {
            throw NotesServiceError.workspaceUnavailable
        }
        guard let entry = workspace.entries.first(where: { $0.id == noteID }) else {
            throw NotesServiceError.noteNotFound
        }
        guard entry.pageType == .text else {
            throw NotesServiceError.unsupportedPageType
        }

        let currentBody = attributedBodies[noteID] ?? NSAttributedString(string: "")
        let appendedBody = NSMutableAttributedString(attributedString: currentBody)
        let incomingBody = try Self.makeSharedContent(kind: kind, text: rawText)

        if appendedBody.length > 0, incomingBody.length > 0 {
            appendedBody.append(NSAttributedString(string: "\n\n"))
        }
        appendedBody.append(incomingBody)

        applyBody(appendedBody, to: noteID, workspace: &workspace)
        if revealImportedNote {
            select(noteID)
        } else if selectedNoteID == noteID {
            syncEditorState()
        }
        scheduleSave()
    }

    func createRootNote() {
        createNote(parentID: nil, after: selectedEntry?.parentID == nil ? selectedNoteID : nil)
    }

    func importPlainTextNote(title rawTitle: String, text: String) throws {
        guard var workspace else {
            throw NotesServiceError.workspaceUnavailable
        }

        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Shared Note" : rawTitle
        let noteID = NoteTreeManager.createNote(
            entries: &workspace.entries,
            bodies: &workspace.bodies,
            parentID: nil,
            after: nil,
            title: title
        )
        let body = Self.readableBody(NSAttributedString(string: text))
        workspace.bodies[noteID] = Self.encodeBody(body)
        attributedBodies[noteID] = body
        self.workspace = workspace
        select(noteID)
        refreshSharedDestinationCache()
        scheduleSave()
    }

    func createSubpage() {
        createNote(parentID: selectedNoteID, after: nil)
    }

    func createSibling() {
        createNote(parentID: selectedEntry?.parentID, after: selectedNoteID)
    }

    func duplicateSelected() {
        guard var workspace, let selectedNoteID else {
            return
        }

        do {
            let duplicated = try NoteTreeManager.duplicateWithMapping(
                noteID: selectedNoteID,
                entries: &workspace.entries,
                bodies: &workspace.bodies
            )
            for (sourceID, clonedID) in duplicated.mapping {
                if let board = workspace.boards[sourceID] {
                    workspace.boards[clonedID] = board
                }
            }
            attributedBodies = workspace.bodies.mapValues(Self.decodeBody)
            self.workspace = workspace
            select(duplicated.rootID)
            refreshSharedDestinationCache()
            scheduleSave()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSelected() {
        guard var workspace, let selectedNoteID else {
            return
        }

        let orderedItems = NoteTreeManager.outlineItems(entries: workspace.entries)
        let deletedIndex = orderedItems.firstIndex(where: { $0.id == selectedNoteID })
        let deletedIDs = Set(Self.descendantIDs(of: selectedNoteID, in: workspace.entries) + [selectedNoteID])

        NoteTreeManager.delete(noteID: selectedNoteID, entries: &workspace.entries, bodies: &workspace.bodies)
        for deletedID in deletedIDs {
            workspace.boards.removeValue(forKey: deletedID)
        }
        attributedBodies = workspace.bodies.mapValues(Self.decodeBody)
        self.workspace = workspace

        let nextSelection = NoteTreeManager.outlineItems(entries: workspace.entries)
        if let deletedIndex, nextSelection.indices.contains(deletedIndex) {
            select(nextSelection[deletedIndex].id)
        } else if let next = nextSelection.last?.id {
            select(next)
        } else {
            showRoot()
        }

        refreshSharedDestinationCache()
        scheduleSave()
    }

    func moveSelectedUp() {
        guard var workspace, let selectedNoteID else {
            return
        }
        NoteTreeManager.moveUp(noteID: selectedNoteID, entries: &workspace.entries)
        self.workspace = workspace
        refreshSharedDestinationCache()
        scheduleSave()
    }

    func moveSelectedDown() {
        guard var workspace, let selectedNoteID else {
            return
        }
        NoteTreeManager.moveDown(noteID: selectedNoteID, entries: &workspace.entries)
        self.workspace = workspace
        refreshSharedDestinationCache()
        scheduleSave()
    }

    func moveDraggedNote(_ draggedNoteID: UUID, relativeTo targetNoteID: UUID, placement: NoteDropPlacement) {
        guard var workspace else {
            return
        }

        do {
            try NoteTreeManager.move(
                noteID: draggedNoteID,
                relativeTo: targetNoteID,
                placement: placement,
                entries: &workspace.entries
            )
            self.workspace = workspace
            select(draggedNoteID)
            refreshSharedDestinationCache()
            scheduleSave()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveSelectedToRoot() {
        guard var workspace, let selectedNoteID else {
            return
        }
        do {
            try NoteTreeManager.moveToRoot(noteID: selectedNoteID, entries: &workspace.entries)
            self.workspace = workspace
            refreshSharedDestinationCache()
            scheduleSave()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reparentDraggedNote(_ draggedNoteID: UUID, under targetParentID: UUID?) {
        guard var workspace else {
            return
        }

        do {
            try NoteTreeManager.reparent(noteID: draggedNoteID, targetParentID: targetParentID, entries: &workspace.entries)
            self.workspace = workspace
            refreshSharedDestinationCache()
            scheduleSave()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectSearchResult(_ result: NoteSearchResult) {
        selectedTag = nil
        select(result.noteID, editorSearch: result.query)
    }

    func selectTag(_ tag: String?) {
        selectedTag = tag
    }

    func selectTagRollupItem(_ item: TaggedLineRollupItem) {
        select(item.noteID, editorSearch: item.tag)
    }

    func convertSelectedToKanban() {
        guard var workspace, let selectedNoteID, let index = workspace.entries.firstIndex(where: { $0.id == selectedNoteID }) else {
            return
        }
        guard !hasChildren(selectedNoteID) else {
            errorMessage = "Move or delete subnotes before converting this notebook."
            return
        }

        workspace.entries[index].pageType = .kanban
        workspace.entries[index].updatedAt = .now
        if workspace.boards[selectedNoteID] == nil {
            workspace.boards[selectedNoteID] = Self.boardFromTextBody(attributedBodies[selectedNoteID]?.string ?? "")
        }
        errorMessage = nil
        self.workspace = workspace
        syncEditorState()
        refreshSharedDestinationCache()
        scheduleSave()
    }

    func convertSelectedToText() {
        guard var workspace, let selectedNoteID, let index = workspace.entries.firstIndex(where: { $0.id == selectedNoteID }) else {
            return
        }
        guard !hasChildren(selectedNoteID) else {
            errorMessage = "Move or delete subnotes before converting this notebook."
            return
        }

        workspace.entries[index].pageType = .text
        workspace.entries[index].updatedAt = .now
        errorMessage = nil
        self.workspace = workspace
        syncEditorState()
        refreshSharedDestinationCache()
        scheduleSave()
    }

    func addKanbanColumn() {
        guard var workspace, let selectedNoteID else {
            return
        }
        var board = workspace.boards[selectedNoteID] ?? KanbanBoard()
        board.columns.append(KanbanColumn(title: "New Column", sortOrder: board.columns.count))
        board.updatedAt = .now
        workspace.boards[selectedNoteID] = Self.normalizedBoard(board)
        touchEntry(selectedNoteID, workspace: &workspace)
        self.workspace = workspace
        scheduleSave()
    }

    func updateKanbanColumnTitle(_ columnID: UUID, title: String) {
        guard var workspace, let selectedNoteID, var board = workspace.boards[selectedNoteID] else {
            return
        }
        guard let index = board.columns.firstIndex(where: { $0.id == columnID }) else {
            return
        }

        board.columns[index].title = title
        board.columns[index].updatedAt = .now
        board.updatedAt = .now
        workspace.boards[selectedNoteID] = Self.normalizedBoard(board)
        touchEntry(selectedNoteID, workspace: &workspace)
        self.workspace = workspace
        scheduleSave()
    }

    func deleteKanbanColumn(_ columnID: UUID) {
        guard var workspace, let selectedNoteID, var board = workspace.boards[selectedNoteID] else {
            return
        }
        board.columns.removeAll { $0.id == columnID }
        board.updatedAt = .now
        workspace.boards[selectedNoteID] = Self.normalizedBoard(board)
        touchEntry(selectedNoteID, workspace: &workspace)
        self.workspace = workspace
        scheduleSave()
    }

    func moveKanbanColumn(_ columnID: UUID, before targetColumnID: UUID?) {
        guard var workspace, let selectedNoteID, var board = workspace.boards[selectedNoteID] else {
            return
        }
        guard let fromIndex = board.columns.firstIndex(where: { $0.id == columnID }) else {
            return
        }

        let moved = board.columns.remove(at: fromIndex)
        let destinationIndex = targetColumnID.flatMap { targetID in
            board.columns.firstIndex(where: { $0.id == targetID })
        } ?? board.columns.count
        board.columns.insert(moved, at: min(destinationIndex, board.columns.count))
        board.updatedAt = .now
        workspace.boards[selectedNoteID] = Self.normalizedBoard(board)
        touchEntry(selectedNoteID, workspace: &workspace)
        self.workspace = workspace
        scheduleSave()
    }

    @discardableResult
    func addKanbanCard(to columnID: UUID) -> UUID? {
        insertKanbanCard(after: nil, in: columnID)
    }

    @discardableResult
    func insertKanbanCard(after cardID: UUID?, in columnID: UUID) -> UUID? {
        guard var workspace, let selectedNoteID, var board = workspace.boards[selectedNoteID] else {
            return nil
        }
        guard let index = board.columns.firstIndex(where: { $0.id == columnID }) else {
            return nil
        }

        let insertIndex = cardID.flatMap { currentCardID in
            board.columns[index].cards.firstIndex(where: { $0.id == currentCardID }).map { $0 + 1 }
        } ?? board.columns[index].cards.count
        let card = KanbanCard(text: "", sortOrder: insertIndex)
        board.columns[index].cards.insert(card, at: min(insertIndex, board.columns[index].cards.count))
        board.columns[index].updatedAt = .now
        board.updatedAt = .now
        workspace.boards[selectedNoteID] = Self.normalizedBoard(board)
        touchEntry(selectedNoteID, workspace: &workspace)
        self.workspace = workspace
        scheduleSave()
        return card.id
    }

    func updateKanbanCard(_ cardID: UUID, in columnID: UUID, text: String) {
        guard var workspace, let selectedNoteID, var board = workspace.boards[selectedNoteID] else {
            return
        }
        guard let columnIndex = board.columns.firstIndex(where: { $0.id == columnID }),
              let cardIndex = board.columns[columnIndex].cards.firstIndex(where: { $0.id == cardID }) else {
            return
        }

        board.columns[columnIndex].cards[cardIndex].text = text
        board.columns[columnIndex].cards[cardIndex].updatedAt = .now
        board.columns[columnIndex].updatedAt = .now
        board.updatedAt = .now
        workspace.boards[selectedNoteID] = Self.normalizedBoard(board)
        touchEntry(selectedNoteID, workspace: &workspace)
        self.workspace = workspace
        scheduleSave()
    }

    func deleteKanbanCard(_ cardID: UUID, from columnID: UUID) {
        guard var workspace, let selectedNoteID, var board = workspace.boards[selectedNoteID] else {
            return
        }
        guard let columnIndex = board.columns.firstIndex(where: { $0.id == columnID }) else {
            return
        }

        board.columns[columnIndex].cards.removeAll { $0.id == cardID }
        board.columns[columnIndex].updatedAt = .now
        board.updatedAt = .now
        workspace.boards[selectedNoteID] = Self.normalizedBoard(board)
        touchEntry(selectedNoteID, workspace: &workspace)
        self.workspace = workspace
        scheduleSave()
    }

    func moveKanbanCard(_ cardID: UUID, to columnID: UUID, before targetCardID: UUID?) {
        guard var workspace, let selectedNoteID, var board = workspace.boards[selectedNoteID] else {
            return
        }

        var movedCard: KanbanCard?
        for columnIndex in board.columns.indices {
            if let cardIndex = board.columns[columnIndex].cards.firstIndex(where: { $0.id == cardID }) {
                movedCard = board.columns[columnIndex].cards.remove(at: cardIndex)
                board.columns[columnIndex].updatedAt = .now
                break
            }
        }
        guard let movedCard, let destinationColumnIndex = board.columns.firstIndex(where: { $0.id == columnID }) else {
            return
        }

        let insertIndex = targetCardID.flatMap { targetID in
            board.columns[destinationColumnIndex].cards.firstIndex(where: { $0.id == targetID })
        } ?? board.columns[destinationColumnIndex].cards.count
        board.columns[destinationColumnIndex].cards.insert(movedCard, at: min(insertIndex, board.columns[destinationColumnIndex].cards.count))
        board.columns[destinationColumnIndex].updatedAt = .now
        board.updatedAt = .now
        workspace.boards[selectedNoteID] = Self.normalizedBoard(board)
        touchEntry(selectedNoteID, workspace: &workspace)
        self.workspace = workspace
        scheduleSave()
    }

    func persistNow() async {
        do {
            try await persistNowOrThrow()
        } catch {
            errorMessage = notesErrorMessage(for: error)
        }
    }

    func persistNowOrThrow() async throws {
        saveTask?.cancel()
        try await persistWorkspaceOrThrow(savingGeneration: localSaveGeneration)
    }

    private func createNote(parentID: UUID?, after siblingID: UUID?) {
        guard var workspace else {
            return
        }

        let newID = NoteTreeManager.createNote(
            entries: &workspace.entries,
            bodies: &workspace.bodies,
            parentID: parentID,
            after: siblingID
        )
        attributedBodies[newID] = Self.readableBody(NSAttributedString(string: ""))
        self.workspace = workspace
        select(newID)
        refreshSharedDestinationCache()
        scheduleSave()
    }

    private func syncEditorState() {
        guard let workspace, let selectedNoteID, let entry = workspace.entries.first(where: { $0.id == selectedNoteID }) else {
            noteTitle = ""
            noteBody = NSAttributedString(string: "")
            return
        }

        noteTitle = displayTitle(for: entry)
        noteBody = attributedBodies[selectedNoteID] ?? Self.readableBody(NSAttributedString(string: ""))
    }

    private func scheduleSave() {
        hasPendingLocalSave = true
        lastLocalEditAt = .now
        localSaveGeneration += 1
        scheduleAutosave(for: localSaveGeneration)
    }

    private func scheduleAutosave(for generation: Int) {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let self, !Task.isCancelled else {
                return
            }
            await self.runScheduledAutosave(savingGeneration: generation)
        }
    }

    private func runScheduledAutosave(savingGeneration: Int) async {
        saveTask = nil
        await persistWorkspace(savingGeneration: savingGeneration)
    }

    private func scheduleSelectedCollaborationSubmit(noteID: UUID) {
        guard
            selectedNoteID == noteID,
            selectedPageType == .text,
            collaborationSession != nil
        else {
            return
        }

        let title = noteTitle
        let body = noteBody.string
        collaborationSubmitTask?.cancel()
        collaborationSubmitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard
                !Task.isCancelled,
                let self,
                self.selectedNoteID == noteID,
                let session = self.collaborationSession
            else {
                return
            }

            do {
                _ = try await session.submit([
                    HankRemoteNoteCollaborationOperation(type: "set_field", field: "title", value: title),
                    HankRemoteNoteCollaborationOperation(type: "text_replace", text: body)
                ])
            } catch {
                await MainActor.run { [weak self] in
                    self?.logger.warning("Queued note save will cover collaboration submit failure error=\(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func persistWorkspace(savingGeneration: Int) async {
        do {
            try await persistWorkspaceOrThrow(savingGeneration: savingGeneration)
        } catch {
            hasPendingLocalSave = true
            errorMessage = notesErrorMessage(for: error)
        }
    }

    private func persistWorkspaceOrThrow(savingGeneration: Int) async throws {
        guard !isSaving else {
            scheduleAutosave(for: localSaveGeneration)
            return
        }
        guard
            let workspace,
            let currentProfileID,
            let modelContext,
            let services
        else {
            return
        }

        isSaving = true
        defer { isSaving = false }

        logger.info("Persisting Notes workspace profile_id=\(currentProfileID.uuidString, privacy: .public) note_count=\(workspace.entries.count, privacy: .public)")
        try await services.notesService.saveWorkspace(
            workspace,
            profileID: currentProfileID,
            modelContext: modelContext,
            services: services
        )
        logger.info("Persisted Notes workspace profile_id=\(currentProfileID.uuidString, privacy: .public)")
        Task { @MainActor in
            try? await services.profileSyncCoordinator.pushExplicitProfileSnapshot(
                profileID: currentProfileID,
                modelContext: modelContext,
                services: services
            )
        }

        if localSaveGeneration <= savingGeneration {
            hasPendingLocalSave = false
            errorMessage = nil
            refreshSharedDestinationCache()
        } else {
            hasPendingLocalSave = true
            scheduleAutosave(for: localSaveGeneration)
        }
    }

    private func startNotesRealtimeIfAvailable() {
        stopNotesRealtime()
        guard
            let modelContext,
            let services,
            let context = try? services.hankRemoteConnectionContext(in: modelContext)
        else {
            logger.info("Notes realtime not started because Hank Remote connection is unavailable")
            return
        }

        realtimeContext = context
        logger.info("Starting Notes realtime subscriptions")
        realtimeTask = Task { [weak self, weak services] in
            guard let services else {
                return
            }
            do {
                try await services.hankRemoteService.startRealtime(context: context)
                try await services.hankRemoteService.subscribeRealtime(
                    topics: ["notes.home", "notes.profile"],
                    context: context
                )
                await MainActor.run { [weak self] in
                    self?.logger.info("Subscribed Notes realtime base topics")
                }
                await MainActor.run { [weak self] in
                    self?.updateSelectedCollaborationSubscription()
                }

                for await event in await services.hankRemoteService.realtimeEvents() {
                    guard !Task.isCancelled else {
                        return
                    }
                    await MainActor.run { [weak self] in
                        self?.handleNotesRealtimeEvent(event)
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.realtimeContext = nil
                    self?.logger.warning("Notes realtime stopped after error=\(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func stopNotesRealtime() {
        realtimeTask?.cancel()
        realtimeReloadTask?.cancel()
        collaborationEventsTask?.cancel()
        collaborationSubmitTask?.cancel()
        if let collaborationSession {
            Task {
                await collaborationSession.leave()
            }
        }
        realtimeTask = nil
        realtimeReloadTask = nil
        realtimeContext = nil
        realtimeSelectedCollabTopic = nil
        collaborationSession = nil
        collaborationEventsTask = nil
        collaborationSubmitTask = nil
        collaboratorCount = 0
    }

    private func updateSelectedCollaborationSubscription() {
        guard let context = realtimeContext, let services else {
            return
        }

        let nextTopic = selectedNoteID.map { "notes.collab:profile:\($0.uuidString.lowercased())" }
        guard nextTopic != realtimeSelectedCollabTopic else {
            return
        }

        let previousTopic = realtimeSelectedCollabTopic
        realtimeSelectedCollabTopic = nextTopic
        collaborationEventsTask?.cancel()
        collaborationSubmitTask?.cancel()
        if let collaborationSession {
            Task {
                await collaborationSession.leave()
            }
        }
        collaborationSession = nil
        collaborationEventsTask = nil
        collaborationSubmitTask = nil
        collaboratorCount = 0
        logger.info("Updating selected Notes collaboration topic previous=\((previousTopic ?? ""), privacy: .public) next=\((nextTopic ?? ""), privacy: .public)")
        Task { [weak services] in
            if let previousTopic {
                try? await services?.hankRemoteService.unsubscribeRealtime(topics: [previousTopic], context: context)
            }
            if let nextTopic {
                try? await services?.hankRemoteService.subscribeRealtime(topics: [nextTopic], context: context)
            }
        }
        guard let selectedNoteID else {
            return
        }
        startSelectedCollaborationSession(noteID: selectedNoteID, context: context, services: services)
    }

    private func startSelectedCollaborationSession(noteID: UUID, context: HankRemoteConnectionContext, services: AppServices) {
        let remoteNoteID = noteID.uuidString.lowercased()
        let session = HankRemoteNoteCollaborationSession(
            noteID: remoteNoteID,
            scope: "profile",
            context: context,
            service: services.hankRemoteService
        )
        collaborationSession = session
        collaborationEventsTask = Task { [weak self] in
            do {
                let stream = await session.events()
                let snapshot = try await session.join()
                await MainActor.run { [weak self] in
                    self?.collaboratorCount = max(0, snapshot.presence.count - 1)
                }
                for await event in stream {
                    guard !Task.isCancelled else {
                        return
                    }
                    await MainActor.run { [weak self] in
                        self?.handleCollaborationSessionEvent(event)
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.collaboratorCount = 0
                    self?.logger.warning("Selected note collaboration stopped error=\(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func handleCollaborationSessionEvent(_ event: HankRemoteNoteCollaborationSessionEvent) {
        switch event {
        case .presence(let presence):
            collaboratorCount = max(0, presence.presence.count - 1)
        case .ops:
            scheduleRealtimeReload()
        case .revoked:
            collaboratorCount = 0
            scheduleRealtimeReload()
        }
    }

    private func handleNotesRealtimeEvent(_ event: HankRemoteRealtimeEvent) {
        logger.info("Notes realtime event handled event=\(event.event, privacy: .public) topic=\((event.topic ?? ""), privacy: .public)")
        guard Self.isNotesRealtimeTopic(event.topic) else {
            return
        }

        switch event.event {
        case "notes.changed",
             "notes.collab.ops":
            presentLocalNoteNotificationIfNeeded(event)
            scheduleRealtimeReload()
        case "notes.deleted",
             "notes.share_changed",
             "notes.collab.revoked":
            scheduleRealtimeReload()
        default:
            break
        }
    }

    private func presentLocalNoteNotificationIfNeeded(_ event: HankRemoteRealtimeEvent) {
        guard
            let payloadData = event.payload,
            let payload = try? JSONDecoder().decode(NotesRealtimeNotificationPayload.self, from: payloadData),
            let updatedBy = payload.updatedBy?.trimmingCharacters(in: .whitespacesAndNewlines),
            !updatedBy.isEmpty,
            let currentProfileID,
            let modelContext,
            let services
        else {
            return
        }

        let currentUserID = (try? UserProfile.fetch(id: currentProfileID, in: modelContext))?
            .remoteUserID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let currentUserID, !currentUserID.isEmpty, updatedBy != currentUserID else {
            return
        }

        let rawNoteID = payload.noteInternalID ?? payload.noteID
        guard
            let rawNoteID,
            let noteID = UUID(uuidString: rawNoteID),
            let url = URL(string: "hank://notifications/notes/\(noteID.uuidString.lowercased())")
        else {
            return
        }

        let title = workspace?.entries.first(where: { $0.id == noteID }).map(displayTitle(for:)) ?? "Shared Note"
        Task {
            await services.notificationService.presentLocalNotification(
                HankLocalNotification(
                    category: .notes,
                    title: "Note Edited",
                    body: "\(title) was updated.",
                    url: url,
                    threadID: "notes:\(noteID.uuidString.lowercased())"
                )
            )
        }
    }

    private func scheduleRealtimeReload() {
        realtimeReloadTask?.cancel()
        realtimeReloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            await self?.reloadWorkspaceFromRealtime()
        }
    }

    private func reloadWorkspaceFromRealtime() async {
        let recentLocalEdit = hasRecentLocalEdit()
        guard !hasPendingLocalSave, !isSaving, !recentLocalEdit else {
            logger.info("Deferring Notes realtime reload pending_local_save=\(self.hasPendingLocalSave, privacy: .public) is_saving=\(self.isSaving, privacy: .public) recent_local_edit=\(recentLocalEdit, privacy: .public)")
            scheduleRealtimeReload()
            return
        }
        guard
            let currentProfileID,
            let modelContext,
            let services
        else {
            return
        }

        do {
            logger.info("Reloading Notes workspace from realtime event profile_id=\(currentProfileID.uuidString, privacy: .public)")
            let refreshedWorkspace = try await services.notesService.loadWorkspace(
                profileID: currentProfileID,
                modelContext: modelContext,
                services: services
            )
            let mergedWorkspace = Self.mergeRemoteWorkspace(
                refreshedWorkspace,
                preservingBodiesFrom: attributedBodies
            )
            workspace = mergedWorkspace.workspace
            attributedBodies = mergedWorkspace.attributedBodies
            if let selectedNoteID, !refreshedWorkspace.entries.contains(where: { $0.id == selectedNoteID }) {
                self.selectedNoteID = nil
                landingState = .root
            }
            syncEditorState()
            refreshSharedDestinationCache()
            errorMessage = nil
            logger.info("Reloaded Notes workspace from realtime event profile_id=\(currentProfileID.uuidString, privacy: .public) note_count=\(refreshedWorkspace.entries.count, privacy: .public)")
        } catch {
            if isTransientRemoteNotesError(error) {
                clearTransientRemoteErrorIfNeeded()
                logger.warning("Ignored transient Notes realtime reload error after local edits remain available error=\(error.localizedDescription, privacy: .public)")
            } else {
                errorMessage = notesErrorMessage(for: error)
                logger.error("Failed to reload Notes workspace from realtime event error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func notesErrorMessage(for error: Error) -> String {
        if case HankRemoteServiceError.conflict = error {
            return "This note was updated elsewhere. Reload it before saving again."
        }
        return error.localizedDescription
    }

    private func isTransientRemoteNotesError(_ error: Error) -> Bool {
        guard let remoteError = error as? HankRemoteServiceError else {
            return false
        }

        switch remoteError {
        case .unreachableHost,
             .websocketClosed:
            return true
        case .server(let message):
            return message.localizedCaseInsensitiveContains("offline")
        default:
            return false
        }
    }

    private func clearTransientRemoteErrorIfNeeded() {
        guard let errorMessage else {
            return
        }

        let transientMessages = [
            HankRemoteServiceError.unreachableHost.localizedDescription,
            HankRemoteServiceError.websocketClosed.localizedDescription
        ]
        if transientMessages.contains(errorMessage) || errorMessage.localizedCaseInsensitiveContains("offline") {
            self.errorMessage = nil
        }
    }

    private func hasRecentLocalEdit() -> Bool {
        guard let lastLocalEditAt else {
            return false
        }

        return Date().timeIntervalSince(lastLocalEditAt) < realtimeReloadQuietInterval
    }

    private func touchEntry(_ noteID: UUID, workspace: inout NotesWorkspaceSnapshot) {
        if let index = workspace.entries.firstIndex(where: { $0.id == noteID }) {
            workspace.entries[index].updatedAt = .now
        }
    }

    private static func decodeBody(_ data: Data) -> NSAttributedString {
        guard !data.isEmpty else {
            return Self.readableBody(NSAttributedString(string: ""))
        }

        if let attributed = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ) {
            return readableBody(attachmentLinkedBody(attributed))
        }

        return readableBody(attachmentLinkedBody(NSAttributedString(string: String(decoding: data, as: UTF8.self))))
    }

    static func attributedText(
        replacingStringWith remoteString: String,
        preservingFormattingFrom existingText: NSAttributedString
    ) -> NSAttributedString {
        let existingString = existingText.string
        guard existingString != remoteString else {
            return readableBody(existingText)
        }
        guard !existingString.isEmpty else {
            return readableBody(NSAttributedString(string: remoteString))
        }

        var oldPrefix = existingString.startIndex
        var newPrefix = remoteString.startIndex
        while oldPrefix < existingString.endIndex,
              newPrefix < remoteString.endIndex,
              existingString[oldPrefix] == remoteString[newPrefix] {
            existingString.formIndex(after: &oldPrefix)
            remoteString.formIndex(after: &newPrefix)
        }

        var oldSuffix = existingString.endIndex
        var newSuffix = remoteString.endIndex
        while oldSuffix > oldPrefix,
              newSuffix > newPrefix {
            let previousOld = existingString.index(before: oldSuffix)
            let previousNew = remoteString.index(before: newSuffix)
            guard existingString[previousOld] == remoteString[previousNew] else {
                break
            }
            oldSuffix = previousOld
            newSuffix = previousNew
        }

        let replacementRange = oldPrefix..<oldSuffix
        let replacementText = String(remoteString[newPrefix..<newSuffix])
        let nsRange = NSRange(replacementRange, in: existingString)
        let replacementAttributes = attributesForReplacementText(
            in: existingText,
            range: nsRange
        )
        let mergedText = NSMutableAttributedString(attributedString: existingText)
        mergedText.replaceCharacters(
            in: nsRange,
            with: NSAttributedString(string: replacementText, attributes: replacementAttributes)
        )
        return readableBody(mergedText)
    }

    private static func isNotesRealtimeTopic(_ topic: String?) -> Bool {
        guard let topic, !topic.isEmpty else {
            return true
        }
        return topic == "notes.profile"
            || topic == "notes.home"
            || topic.hasPrefix("notes.collab:")
    }

    private static func mergeRemoteWorkspace(
        _ remoteWorkspace: NotesWorkspaceSnapshot,
        preservingBodiesFrom existingBodies: [UUID: NSAttributedString]
    ) -> (workspace: NotesWorkspaceSnapshot, attributedBodies: [UUID: NSAttributedString]) {
        var mergedWorkspace = remoteWorkspace
        var mergedBodies: [UUID: NSAttributedString] = [:]

        for entry in remoteWorkspace.entries {
            switch entry.pageType {
            case .text:
                let remoteBody = decodeBody(remoteWorkspace.bodies[entry.id] ?? Data())
                let mergedBody: NSAttributedString
                if let existingBody = existingBodies[entry.id] {
                    mergedBody = attributedText(
                        replacingStringWith: remoteBody.string,
                        preservingFormattingFrom: existingBody
                    )
                } else {
                    mergedBody = remoteBody
                }
                let readableMergedBody = readableBody(mergedBody)
                mergedBodies[entry.id] = readableMergedBody
                mergedWorkspace.bodies[entry.id] = encodeBody(readableMergedBody)
            case .kanban:
                if let remoteData = remoteWorkspace.bodies[entry.id] {
                    mergedWorkspace.bodies[entry.id] = remoteData
                }
            case .notebook:
                mergedWorkspace.bodies[entry.id] = Data()
            }
        }

        return (mergedWorkspace, mergedBodies)
    }

    private static func attributesForReplacementText(
        in attributedText: NSAttributedString,
        range: NSRange
    ) -> [NSAttributedString.Key: Any] {
        guard attributedText.length > 0 else {
            return [:]
        }
        let preferredLocation = range.length > 0 ? range.location : range.location - 1
        let attributeLocation = min(max(preferredLocation, 0), attributedText.length - 1)
        return attributedText.attributes(at: attributeLocation, effectiveRange: nil)
    }

    private static func readableBody(_ attributedText: NSAttributedString) -> NSAttributedString {
        guard attributedText.length > 0 else {
            return attributedText
        }

        let mutable = NSMutableAttributedString(attributedString: attributedText)
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.enumerateAttributes(in: fullRange) { attributes, range, _ in
            if attributes[.font] == nil {
                mutable.addAttribute(.font, value: UIFont.preferredFont(forTextStyle: .body), range: range)
            }
            mutable.addAttribute(.foregroundColor, value: UIColor.white, range: range)
        }
        return mutable
    }

    private static func attachmentLinkedBody(_ attributedText: NSAttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attributedText)
        let text = mutable.string as NSString
        guard text.length > 0,
              let regex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\((hank-note-attachment://[^)]+)\)"#) else {
            return mutable
        }
        let matches = regex.matches(in: mutable.string, range: NSRange(location: 0, length: text.length))
        for match in matches {
	            guard match.numberOfRanges >= 3,
	                  let urlRange = Range(match.range(at: 2), in: mutable.string),
	                  let url = URL(string: String(mutable.string[urlRange])) else {
	                continue
	            }
	            mutable.addAttribute(.link, value: url, range: match.range(at: 0))
	            mutable.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: match.range(at: 1))
	            mutable.addAttribute(.backgroundColor, value: UIColor.white.withAlphaComponent(0.08), range: match.range(at: 0))
	            mutable.addAttribute(.foregroundColor, value: UIColor.white, range: match.range(at: 0))
	        }
	        return mutable
	    }

    private static func encodeBody(_ attributedText: NSAttributedString) -> Data {
        let fullRange = NSRange(location: 0, length: attributedText.length)
        if let data = try? attributedText.data(
            from: fullRange,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) {
            return data
        }

        return Data(attributedText.string.utf8)
    }

    private func applyBody(_ attributedText: NSAttributedString, to noteID: UUID, workspace: inout NotesWorkspaceSnapshot) {
        let readableText = Self.readableBody(attributedText)
        attributedBodies[noteID] = readableText
        workspace.bodies[noteID] = Self.encodeBody(readableText)
        touchEntry(noteID, workspace: &workspace)
        self.workspace = workspace
        if selectedNoteID == noteID {
            noteBody = readableText
        }
    }

    private func refreshSharedDestinationCache() {
        guard let workspace, let services else {
            return
        }

        let destinations = NoteTreeManager.outlineItems(entries: workspace.entries)
            .filter { $0.entry.pageType == .text }
            .map { item in
                let breadcrumb = Self.breadcrumb(for: item.id, in: workspace.entries)
                return SharedNoteDestination(
                    noteID: item.id,
                    title: displayTitle(for: item.entry),
                    breadcrumb: breadcrumb,
                    updatedAt: item.entry.updatedAt
                )
            }

        try? services.localFileService.writeCachedNoteDestinations(destinations)
    }

    private func displayTitle(for entry: NoteManifestEntry) -> String {
        let trimmed = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return entry.parentID == nil ? NoteTreeManager.rootNoteTitle : NoteTreeManager.subnoteTitle
        }
        return trimmed
    }

    private static func breadcrumb(for noteID: UUID, in entries: [NoteManifestEntry]) -> String {
        var components: [String] = []
        var cursor = entries.first(where: { $0.id == noteID })?.parentID
        var visited = Set<UUID>()

        while let activeID = cursor, let entry = entries.first(where: { $0.id == activeID }) {
            guard visited.insert(activeID).inserted else {
                break
            }
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            components.append(title.isEmpty ? (entry.parentID == nil ? NoteTreeManager.rootNoteTitle : NoteTreeManager.subnoteTitle) : title)
            cursor = entry.parentID
        }

        return components.reversed().joined(separator: " / ")
    }

    private static func makeSharedContent(kind: IncomingSharePayload.Kind, text rawText: String) throws -> NSAttributedString {
        switch kind {
        case .text:
            if let url = normalizedLinkIfWholeString(rawText) {
                return linkedText(for: url)
            }
            return NSAttributedString(string: rawText)
        case .url:
            let url = try normalizedLink(from: rawText)
            return linkedText(for: url)
        case .file:
            throw IncomingSharePayloadError.unsupportedNotesImport
        }
    }

    private static func normalizedLink(from rawValue: String) throws -> URL {
        guard let url = normalizedLinkIfWholeString(rawValue) else {
            throw NotesServiceError.invalidLink
        }

        return url
    }

    private static func normalizedLinkIfWholeString(_ rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if !trimmed.contains("://") {
            guard !trimmed.contains(" "), !trimmed.contains("\n"), trimmed.contains(".") else {
                return nil
            }
            return URL(string: "https://\(trimmed)")
        }

        let range = NSRange(location: 0, length: trimmed.utf16.count)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
           let match = detector.firstMatch(in: trimmed, options: [], range: range),
           match.range == range,
           let url = match.url {
            return url
        }
        return URL(string: trimmed)
    }

    private static func linkedText(for url: URL) -> NSAttributedString {
        let linkText = NSMutableAttributedString(string: url.absoluteString)
        let range = NSRange(location: 0, length: linkText.length)
        linkText.addAttribute(.link, value: url, range: range)
        linkText.addAttribute(.foregroundColor, value: UIColor(HankTheme.accent), range: range)
        linkText.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        return linkText
    }

    private static func safeFileName(for title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let characters = title.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let fileName = String(characters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
        return fileName.isEmpty ? "Untitled-Note" : fileName
    }

    private static func normalizedBoard(_ board: KanbanBoard) -> KanbanBoard {
        var normalized = board
        normalized.columns = normalized.columns.enumerated().map { columnOffset, column in
            var updatedColumn = column
            updatedColumn.sortOrder = columnOffset
            updatedColumn.cards = updatedColumn.cards.enumerated().map { cardOffset, card in
                var updatedCard = card
                updatedCard.sortOrder = cardOffset
                return updatedCard
            }
            return updatedColumn
        }
        return normalized
    }

    private static func boardFromTextBody(_ body: String) -> KanbanBoard {
        let cards = body
            .components(separatedBy: .newlines)
            .map { line in
                line.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: #"^[-*]\s+"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"^\d+[.)]\s+"#, with: "", options: .regularExpression)
            }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { index, text in
                KanbanCard(text: text, sortOrder: index)
            }

        return KanbanBoard(columns: [
            KanbanColumn(title: "Inbox", sortOrder: 0, cards: cards)
        ])
    }

    private static func kanbanMarkdown(title: String, board: KanbanBoard) -> String {
        let body = board.columns
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { column in
                let columnTitle = column.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Column" : column.title
                let cards = column.cards
                    .sorted { $0.sortOrder < $1.sortOrder }
                    .map { "- \($0.text)" }
                    .joined(separator: "\n")
                return cards.isEmpty ? "## \(columnTitle)" : "## \(columnTitle)\n\(cards)"
            }
            .joined(separator: "\n\n")

        return body.isEmpty ? "# \(title)\n" : "# \(title)\n\n\(body)\n"
    }

    private static func notebookMarkdown(title: String, noteID: UUID, entries: [NoteManifestEntry]) -> String {
        let outline = NoteTreeManager.outlineItems(entries: entries)
        let rootDepth = outline.first(where: { $0.id == noteID })?.depth ?? 0
        let descendantIDs = Set(descendantIDs(of: noteID, in: entries))
        guard !descendantIDs.isEmpty else {
            return "# \(title)\n"
        }

        let lines = outline.filter { descendantIDs.contains($0.id) }.map { item in
            let indent = String(repeating: "  ", count: max(0, item.depth - rootDepth - 1))
            let childTitle = item.entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? NoteTreeManager.subnoteTitle : item.entry.title
            return "\(indent)- \(childTitle)"
        }
        .joined(separator: "\n")

        return "# \(title)\n\n\(lines)\n"
    }

    private static func descendantIDs(of noteID: UUID, in entries: [NoteManifestEntry]) -> [UUID] {
        let children = entries.filter { $0.parentID == noteID }
        return children.flatMap { [ $0.id ] + descendantIDs(of: $0.id, in: entries) }
    }

    private struct TaggedLine {
        let tag: String
        let text: String
    }

    private static func extractTaggedLines(from text: String) -> [TaggedLine] {
        text
            .components(separatedBy: .newlines)
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                let content = trimmed.replacingOccurrences(
                    of: #"^(?:[-*•]\s+|\d+\.\s+|[○●]\s+|- \[[ xX]\]\s+)"#,
                    with: "",
                    options: .regularExpression
                )
                guard content.hasPrefix("#"), let colonIndex = content.firstIndex(of: ":") else {
                    return nil
                }

                let rawTag = String(content[content.index(after: content.startIndex)..<colonIndex])
                let normalizedTag = normalizeTag(rawTag)
                guard !normalizedTag.isEmpty else {
                    return nil
                }

                let textStart = content.index(after: colonIndex)
                let lineText = String(content[textStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return TaggedLine(tag: normalizedTag, text: lineText)
            }
    }

    static func normalizeTag(_ rawTag: String) -> String {
        let trimmed = rawTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            return ""
        }

        let replacedSpaces = trimmed.replacingOccurrences(of: " ", with: "-")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(replacedSpaces.unicodeScalars.filter { allowed.contains($0) })
    }
}

enum NoteMarkdownExporter {
    static func markdown(title: String, attributedText: NSAttributedString) -> String {
        let body = attributedText.string
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let rawLine = String(line)
                if rawLine.hasPrefix("• ") {
                    return "- " + String(rawLine.dropFirst(2))
                }
                if rawLine.hasPrefix("○ ") {
                    return "- [ ] " + String(rawLine.dropFirst(2))
                }
                if rawLine.hasPrefix("● ") {
                    return "- [x] " + String(rawLine.dropFirst(2))
                }
                return rawLine
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !body.isEmpty else {
            return "# \(title)\n"
        }

        return "# \(title)\n\n\(body)\n"
    }
}

struct NoteShareItem: Identifiable {
    let id = UUID()
    let title: String
    let attributedText: NSAttributedString
    let plainText: String
    let markdownText: String
    let markdownURL: URL
}
