import CryptoKit
import Foundation
import SwiftData
import UIKit
import os

enum NotesServiceError: LocalizedError {
    case missingNotesKey
    case invalidEncryptedArchive
    case invalidManifest
    case incompleteEncryptedArchive
    case missingSMBConfiguration
    case cannotMoveIntoDescendant
    case noteNotFound
    case invalidLink
    case workspaceUnavailable
    case unsupportedPageType
    case serverRequired

    var errorDescription: String? {
        switch self {
        case .missingNotesKey:
            return "The notes encryption key is unavailable for this profile."
        case .invalidEncryptedArchive:
            return "The encrypted notes archive could not be opened."
        case .invalidManifest:
            return "The notes archive manifest is invalid."
        case .incompleteEncryptedArchive:
            return "The backup is missing note content, so the notes import was stopped."
        case .missingSMBConfiguration:
            return "Configure the SMB share and password before storing notes there."
        case .cannotMoveIntoDescendant:
            return "A note cannot be moved into one of its own subpages."
        case .noteNotFound:
            return "That note could not be found."
        case .invalidLink:
            return "Enter a valid link."
        case .workspaceUnavailable:
            return "Open Notes before importing shared text."
        case .unsupportedPageType:
            return "That action is only available for text notes."
        case .serverRequired:
            return "Connect this profile to Hank Remote before using Notes."
        }
    }
}

struct NoteOutlineItem: Identifiable, Hashable {
    let entry: NoteManifestEntry
    let depth: Int

    var id: UUID { entry.id }
}

struct RawEncryptedNoteArchive: Hashable {
    let manifest: Data
    let notes: [String: Data]
}

enum NoteDropPlacement: Equatable {
    case before
    case inside
    case after
}

enum NoteTreeManager {
    static let rootNoteTitle = "Note"
    static let subnoteTitle = "Subnote"

    static func makeDefaultArchive() -> NotesWorkspaceSnapshot {
        let noteID = UUID()
        let entry = NoteManifestEntry(
            id: noteID,
            title: rootNoteTitle,
            parentID: nil,
            sortOrder: 0,
            createdAt: .now,
            updatedAt: .now
        )
        return NotesWorkspaceSnapshot(
            configuration: NotesConfigSnapshot(
                storageLocation: .device,
                pendingSMBMigration: false,
                resolvedPath: ""
            ),
            entries: [entry],
            bodies: [noteID: Data()],
            boards: [:]
        )
    }

    static func outlineItems(
        entries: [NoteManifestEntry],
        searchText: String = "",
        bodyText: [UUID: String] = [:]
    ) -> [NoteOutlineItem] {
        let normalized = normalizedEntries(entries)
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedSearch.isEmpty else {
            var items: [NoteOutlineItem] = []
            var visited = Set<UUID>()
            appendChildren(parentID: nil, depth: 0, entries: normalized, visited: &visited, items: &items)
            for entry in normalized where !visited.contains(entry.id) {
                visited.insert(entry.id)
                items.append(NoteOutlineItem(entry: entry, depth: 0))
                appendChildren(parentID: entry.id, depth: 1, entries: normalized, visited: &visited, items: &items)
            }
            return items
        }

        let needle = trimmedSearch.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return normalized.compactMap { entry in
            let title = entry.title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            let body = (bodyText[entry.id] ?? "").folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            guard title.contains(needle) || body.contains(needle) else {
                return nil
            }
            return NoteOutlineItem(entry: entry, depth: depth(of: entry.id, in: normalized))
        }
    }

    static func createNote(
        entries: inout [NoteManifestEntry],
        bodies: inout [UUID: Data],
        parentID: UUID?,
        after siblingID: UUID? = nil,
        title: String? = nil,
        body: Data = Data(),
        pageType: NotePageType = .text
    ) -> UUID {
        let now = Date()
        let siblings = orderedChildren(parentID: parentID, in: entries)
        let insertionIndex: Int

        if let siblingID,
           let siblingIndex = siblings.firstIndex(where: { $0.id == siblingID }) {
            insertionIndex = siblingIndex + 1
        } else {
            insertionIndex = siblings.count
        }

        for index in insertionIndex ..< siblings.count {
            if let targetIndex = entries.firstIndex(where: { $0.id == siblings[index].id }) {
                entries[targetIndex].sortOrder += 1
                entries[targetIndex].updatedAt = now
            }
        }

        promoteParentToNotebook(parentID, entries: &entries, updatedAt: now)

        let noteID = UUID()
        entries.append(
            NoteManifestEntry(
                id: noteID,
                title: title ?? defaultTitle(parentID: parentID),
                parentID: parentID,
                sortOrder: insertionIndex,
                createdAt: now,
                updatedAt: now,
                pageType: pageType
            )
        )
        bodies[noteID] = body
        entries = normalizedEntries(entries)
        return noteID
    }

    static func rename(
        noteID: UUID,
        to title: String,
        entries: inout [NoteManifestEntry]
    ) {
        guard let index = entries.firstIndex(where: { $0.id == noteID }) else {
            return
        }

        entries[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultTitle(parentID: entries[index].parentID) : title.trimmingCharacters(in: .whitespacesAndNewlines)
        entries[index].updatedAt = .now
    }

    @discardableResult
    static func duplicate(
        noteID: UUID,
        entries: inout [NoteManifestEntry],
        bodies: inout [UUID: Data]
    ) throws -> UUID {
        let result = try duplicateWithMapping(noteID: noteID, entries: &entries, bodies: &bodies)
        return result.rootID
    }

    static func duplicateWithMapping(
        noteID: UUID,
        entries: inout [NoteManifestEntry],
        bodies: inout [UUID: Data]
    ) throws -> (rootID: UUID, mapping: [UUID: UUID]) {
        let sourceEntries = normalizedEntries(entries)
        guard let source = sourceEntries.first(where: { $0.id == noteID }) else {
            throw NotesServiceError.noteNotFound
        }

        var clones: [NoteManifestEntry] = []
        var cloneBodies: [UUID: Data] = [:]
        let mapping = duplicateTree(
            noteID: source.id,
            newParentID: source.parentID,
            entries: sourceEntries,
            bodies: bodies,
            clones: &clones,
            cloneBodies: &cloneBodies,
            isRoot: true
        )

        guard let duplicatedRootID = mapping[source.id] else {
            throw NotesServiceError.noteNotFound
        }

        entries.append(contentsOf: clones)
        for (key, value) in cloneBodies {
            bodies[key] = value
        }

        let originalSiblings = orderedChildren(parentID: source.parentID, in: entries)
        guard
            let sourceIndex = originalSiblings.firstIndex(where: { $0.id == source.id }),
            let duplicateIndex = entries.firstIndex(where: { $0.id == duplicatedRootID })
        else {
            entries = normalizedEntries(entries)
            return (duplicatedRootID, mapping)
        }

        entries[duplicateIndex].sortOrder = sourceIndex + 1
        for sibling in originalSiblings[(sourceIndex + 1)...] {
            guard let siblingIndex = entries.firstIndex(where: { $0.id == sibling.id }) else {
                continue
            }
            entries[siblingIndex].sortOrder += 1
        }

        entries = normalizedEntries(entries)
        return (duplicatedRootID, mapping)
    }

    static func delete(
        noteID: UUID,
        entries: inout [NoteManifestEntry],
        bodies: inout [UUID: Data]
    ) {
        let deleteIDs = Set(descendants(of: noteID, in: entries) + [noteID])
        entries.removeAll { deleteIDs.contains($0.id) }
        deleteIDs.forEach { bodies.removeValue(forKey: $0) }
        entries = normalizedEntries(entries)
    }

    static func moveUp(noteID: UUID, entries: inout [NoteManifestEntry]) {
        reorderSibling(noteID: noteID, direction: -1, entries: &entries)
    }

    static func moveDown(noteID: UUID, entries: inout [NoteManifestEntry]) {
        reorderSibling(noteID: noteID, direction: 1, entries: &entries)
    }

    static func moveToRoot(noteID: UUID, entries: inout [NoteManifestEntry]) throws {
        try reparent(noteID: noteID, targetParentID: nil, entries: &entries)
    }

    static func reparent(
        noteID: UUID,
        targetParentID: UUID?,
        entries: inout [NoteManifestEntry]
    ) throws {
        guard let currentIndex = entries.firstIndex(where: { $0.id == noteID }) else {
            throw NotesServiceError.noteNotFound
        }

        if let targetParentID {
            if targetParentID == noteID || isDescendant(targetParentID, of: noteID, in: entries) {
                throw NotesServiceError.cannotMoveIntoDescendant
            }
        }

        let oldParentID = entries[currentIndex].parentID
        entries[currentIndex].parentID = targetParentID
        entries[currentIndex].sortOrder = orderedChildren(parentID: targetParentID, in: entries)
            .filter { $0.id != noteID }
            .count
        entries[currentIndex].updatedAt = .now
        promoteParentToNotebook(targetParentID, entries: &entries, updatedAt: .now)

        entries = normalizedEntries(entries)
        touchAncestorChain(parentID: oldParentID, entries: &entries)
        touchAncestorChain(parentID: targetParentID, entries: &entries)
    }

    static func move(
        noteID: UUID,
        relativeTo targetID: UUID,
        placement: NoteDropPlacement,
        entries: inout [NoteManifestEntry]
    ) throws {
        guard noteID != targetID else {
            return
        }

        switch placement {
        case .inside:
            try reparent(noteID: noteID, targetParentID: targetID, entries: &entries)
        case .before, .after:
            guard
                let currentIndex = entries.firstIndex(where: { $0.id == noteID }),
                let target = entries.first(where: { $0.id == targetID })
            else {
                throw NotesServiceError.noteNotFound
            }

            if isDescendant(targetID, of: noteID, in: entries) {
                throw NotesServiceError.cannotMoveIntoDescendant
            }

            let newParentID = target.parentID
            if let newParentID, isDescendant(newParentID, of: noteID, in: entries) {
                throw NotesServiceError.cannotMoveIntoDescendant
            }

            let oldParentID = entries[currentIndex].parentID
            let siblings = orderedChildren(parentID: newParentID, in: entries)
                .filter { $0.id != noteID }
            let targetSiblingIndex = siblings.firstIndex(where: { $0.id == targetID }) ?? siblings.count
            let insertionIndex = placement == .before ? targetSiblingIndex : targetSiblingIndex + 1

            entries[currentIndex].parentID = newParentID
            entries[currentIndex].sortOrder = insertionIndex
            entries[currentIndex].updatedAt = .now
            promoteParentToNotebook(newParentID, entries: &entries, updatedAt: .now)

            for sibling in siblings {
                guard let siblingIndex = entries.firstIndex(where: { $0.id == sibling.id }) else {
                    continue
                }

                if entries[siblingIndex].sortOrder >= insertionIndex {
                    entries[siblingIndex].sortOrder += 1
                }
            }

            entries = normalizedEntries(entries)
            touchAncestorChain(parentID: oldParentID, entries: &entries)
            touchAncestorChain(parentID: newParentID, entries: &entries)
        }
    }

    static func isDescendant(_ candidateID: UUID, of ancestorID: UUID, in entries: [NoteManifestEntry]) -> Bool {
        var currentID: UUID? = candidateID
        var visited = Set<UUID>()

        while let activeID = currentID {
            guard visited.insert(activeID).inserted else {
                return false
            }
            guard let current = entries.first(where: { $0.id == activeID }) else {
                return false
            }
            if current.parentID == ancestorID {
                return true
            }
            currentID = current.parentID
        }

        return false
    }

    static func normalizedEntries(_ entries: [NoteManifestEntry]) -> [NoteManifestEntry] {
        var normalized = entries
        var grouped = Dictionary(grouping: entries, by: \.parentID)

        for (parentID, siblings) in grouped {
            let ordered = siblings.sorted {
                if $0.sortOrder == $1.sortOrder {
                    return $0.createdAt < $1.createdAt
                }
                return $0.sortOrder < $1.sortOrder
            }

            for (offset, sibling) in ordered.enumerated() {
                guard let index = normalized.firstIndex(where: { $0.id == sibling.id }) else {
                    continue
                }
                normalized[index].parentID = parentID
                normalized[index].sortOrder = offset
            }
        }

        grouped.removeAll()

        let parentIDs = Set(normalized.compactMap(\.parentID))
        for index in normalized.indices where parentIDs.contains(normalized[index].id) {
            normalized[index].pageType = .notebook
        }

        let flattenedOrder = flattenedIDs(from: normalized)
        let orderByID = Dictionary(uniqueKeysWithValues: flattenedOrder.enumerated().map { ($1, $0) })

        return normalized.sorted {
            let leftDepth = depth(of: $0.id, in: normalized)
            let rightDepth = depth(of: $1.id, in: normalized)

            if leftDepth == rightDepth, $0.parentID == $1.parentID {
                if $0.sortOrder == $1.sortOrder {
                    return $0.createdAt < $1.createdAt
                }
                return $0.sortOrder < $1.sortOrder
            }

            if $0.parentID == nil, $1.parentID == nil {
                return $0.sortOrder < $1.sortOrder
            }

            return orderByID[$0.id, default: 0] < orderByID[$1.id, default: 0]
        }
    }

    private static func appendChildren(
        parentID: UUID?,
        depth: Int,
        entries: [NoteManifestEntry],
        visited: inout Set<UUID>,
        items: inout [NoteOutlineItem]
    ) {
        for child in orderedChildren(parentID: parentID, in: entries) {
            guard visited.insert(child.id).inserted else {
                continue
            }
            items.append(NoteOutlineItem(entry: child, depth: depth))
            appendChildren(parentID: child.id, depth: depth + 1, entries: entries, visited: &visited, items: &items)
        }
    }

    private static func orderedChildren(parentID: UUID?, in entries: [NoteManifestEntry]) -> [NoteManifestEntry] {
        entries
            .filter { $0.parentID == parentID }
            .sorted {
                if $0.sortOrder == $1.sortOrder {
                    return $0.createdAt < $1.createdAt
                }
                return $0.sortOrder < $1.sortOrder
            }
    }

    private static func promoteParentToNotebook(_ parentID: UUID?, entries: inout [NoteManifestEntry], updatedAt: Date) {
        guard let parentID, let index = entries.firstIndex(where: { $0.id == parentID }) else {
            return
        }
        entries[index].pageType = .notebook
        entries[index].updatedAt = updatedAt
    }

    private static func depth(of noteID: UUID, in entries: [NoteManifestEntry]) -> Int {
        var depth = 0
        var cursor: UUID? = entries.first(where: { $0.id == noteID })?.parentID
        var visited = Set<UUID>()

        while let activeCursor = cursor {
            guard visited.insert(activeCursor).inserted else {
                break
            }
            depth += 1
            cursor = entries.first(where: { $0.id == activeCursor })?.parentID
        }

        return depth
    }

    private static func flattenedIDs(from entries: [NoteManifestEntry]) -> [UUID] {
        var items: [NoteOutlineItem] = []
        var visited = Set<UUID>()
        appendChildren(parentID: nil, depth: 0, entries: entries, visited: &visited, items: &items)
        if items.count < entries.count {
            for entry in orderedChildren(parentID: nil, in: entries) where !visited.contains(entry.id) {
                visited.insert(entry.id)
                items.append(NoteOutlineItem(entry: entry, depth: 0))
                appendChildren(parentID: entry.id, depth: 1, entries: entries, visited: &visited, items: &items)
            }

            for entry in entries where !visited.contains(entry.id) {
                visited.insert(entry.id)
                items.append(NoteOutlineItem(entry: entry, depth: 0))
                appendChildren(parentID: entry.id, depth: 1, entries: entries, visited: &visited, items: &items)
            }
        }
        return items.map(\.id)
    }

    private static func descendants(of noteID: UUID, in entries: [NoteManifestEntry]) -> [UUID] {
        descendants(of: noteID, in: entries, visited: [])
    }

    private static func descendants(of noteID: UUID, in entries: [NoteManifestEntry], visited: Set<UUID>) -> [UUID] {
        guard !visited.contains(noteID) else {
            return []
        }
        var nextVisited = visited
        nextVisited.insert(noteID)
        var ids: [UUID] = []
        for child in orderedChildren(parentID: noteID, in: entries) {
            ids.append(child.id)
            ids.append(contentsOf: descendants(of: child.id, in: entries, visited: nextVisited))
        }
        return ids
    }

    private static func duplicateTree(
        noteID: UUID,
        newParentID: UUID?,
        entries: [NoteManifestEntry],
        bodies: [UUID: Data],
        clones: inout [NoteManifestEntry],
        cloneBodies: inout [UUID: Data],
        isRoot: Bool,
        visited: Set<UUID> = []
    ) -> [UUID: UUID] {
        guard !visited.contains(noteID) else {
            return [:]
        }
        guard let source = entries.first(where: { $0.id == noteID }) else {
            return [:]
        }
        var nextVisited = visited
        nextVisited.insert(noteID)

        let newID = UUID()
        let duplicatedTitle = isRoot ? "\(source.title) Copy" : source.title
        let clone = NoteManifestEntry(
            id: newID,
            title: duplicatedTitle,
            parentID: newParentID,
            sortOrder: orderedChildren(parentID: newParentID, in: entries + clones).count,
            createdAt: .now,
            updatedAt: .now,
            pageType: source.pageType
        )
        clones.append(clone)
        cloneBodies[newID] = bodies[source.id] ?? Data()

        var mapping: [UUID: UUID] = [source.id: newID]
        for child in orderedChildren(parentID: source.id, in: entries) {
            let childMapping = duplicateTree(
                noteID: child.id,
                newParentID: newID,
                entries: entries,
                bodies: bodies,
                clones: &clones,
                cloneBodies: &cloneBodies,
                isRoot: false,
                visited: nextVisited
            )
            mapping.merge(childMapping) { _, new in new }
        }

        return mapping
    }

    private static func reorderSibling(
        noteID: UUID,
        direction: Int,
        entries: inout [NoteManifestEntry]
    ) {
        guard let note = entries.first(where: { $0.id == noteID }) else {
            return
        }

        var siblings = orderedChildren(parentID: note.parentID, in: entries)
        guard let currentIndex = siblings.firstIndex(where: { $0.id == noteID }) else {
            return
        }

        let nextIndex = currentIndex + direction
        guard siblings.indices.contains(nextIndex) else {
            return
        }

        siblings.swapAt(currentIndex, nextIndex)
        for (offset, sibling) in siblings.enumerated() {
            guard let index = entries.firstIndex(where: { $0.id == sibling.id }) else {
                continue
            }
            entries[index].sortOrder = offset
            entries[index].updatedAt = .now
        }
        entries = normalizedEntries(entries)
    }

    private static func touchAncestorChain(parentID: UUID?, entries: inout [NoteManifestEntry]) {
        var cursor: UUID? = parentID
        while let activeCursor = cursor {
            guard let index = entries.firstIndex(where: { $0.id == activeCursor }) else {
                return
            }
            entries[index].updatedAt = .now
            cursor = entries[index].parentID
        }
    }

    private static func defaultTitle(parentID: UUID?) -> String {
        parentID == nil ? rootNoteTitle : subnoteTitle
    }
}

final class ProfileNotesService: @unchecked Sendable {
    typealias LocalRootProvider = (UUID, FileManager) throws -> URL

    private struct PendingRemoteProfileWorkspace: Codable {
        var entries: [NoteManifestEntry]
        var bodies: [PendingRemoteNoteBody]
        var boards: [PendingRemoteKanbanBoard]
        var updatedAt: Date
        var needsUpload: Bool

        init(workspace: NotesWorkspaceSnapshot, updatedAt: Date = .now, needsUpload: Bool) {
            entries = workspace.entries
            bodies = workspace.bodies.map { PendingRemoteNoteBody(noteID: $0.key, data: $0.value) }
            boards = workspace.boards.map { PendingRemoteKanbanBoard(noteID: $0.key, board: $0.value) }
            self.updatedAt = updatedAt
            self.needsUpload = needsUpload
        }

        enum CodingKeys: String, CodingKey {
            case entries
            case bodies
            case boards
            case updatedAt
            case needsUpload
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            entries = try container.decode([NoteManifestEntry].self, forKey: .entries)
            bodies = try container.decode([PendingRemoteNoteBody].self, forKey: .bodies)
            boards = try container.decode([PendingRemoteKanbanBoard].self, forKey: .boards)
            updatedAt = try container.decode(Date.self, forKey: .updatedAt)
            needsUpload = try container.decodeIfPresent(Bool.self, forKey: .needsUpload) ?? true
        }

        func workspace(configuration: NotesConfigSnapshot) -> NotesWorkspaceSnapshot {
            NotesWorkspaceSnapshot(
                configuration: configuration,
                entries: entries,
                bodies: Dictionary(uniqueKeysWithValues: bodies.map { ($0.noteID, $0.data) }),
                boards: Dictionary(uniqueKeysWithValues: boards.map { ($0.noteID, $0.board) })
            )
        }
    }

    private struct PendingRemoteNoteBody: Codable {
        let noteID: UUID
        let data: Data
    }

    private struct PendingRemoteKanbanBoard: Codable {
        let noteID: UUID
        let board: KanbanBoard
    }

    private let fileManager: FileManager
    private let localRootProvider: LocalRootProvider
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.dropfile.Hank", category: "NotesSync")

    init(
        fileManager: FileManager = .default,
        localRootProvider: @escaping LocalRootProvider = ProfileNotesService.defaultLocalRoot
    ) {
        self.fileManager = fileManager
        self.localRootProvider = localRootProvider

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    @MainActor
    func notesConfig(for profileID: UUID, in context: ModelContext) throws -> NotesConfig {
        if let existing = try NotesConfig.fetch(for: profileID, in: context) {
            return existing
        }

        let config = NotesConfig(profileID: profileID)
        context.insert(config)
        try context.save()
        return config
    }

    @MainActor
    func configurationSnapshot(profileID: UUID, modelContext: ModelContext, services: AppServices) throws -> NotesConfigSnapshot {
        let config = try notesConfig(for: profileID, in: modelContext)
        guard try isHankRemoteProfile(profileID: profileID, modelContext: modelContext) else {
            return NotesConfigSnapshot(
                storageLocation: config.storageLocation,
                pendingSMBMigration: config.pendingSMBMigration,
                resolvedPath: "Hank Remote profile notes (not connected)"
            )
        }
        if try remoteProfileNotesContext(profileID: profileID, modelContext: modelContext, services: services) != nil {
            return NotesConfigSnapshot(
                storageLocation: config.storageLocation,
                pendingSMBMigration: config.pendingSMBMigration,
                resolvedPath: "Hank Remote profile notes"
            )
        }
        if let cachedWorkspace = try pendingRemoteProfileWorkspace(profileID: profileID) {
            return NotesConfigSnapshot(
                storageLocation: config.storageLocation,
                pendingSMBMigration: config.pendingSMBMigration,
                resolvedPath: cachedWorkspace.needsUpload
                    ? "Hank Remote profile notes (pending sync)"
                    : "Hank Remote profile notes (offline cache)"
            )
        }
        return NotesConfigSnapshot(
            storageLocation: config.storageLocation,
            pendingSMBMigration: config.pendingSMBMigration,
            resolvedPath: "Hank Remote profile notes (not connected)"
        )
    }

    @MainActor
    func loadWorkspace(
        profileID: UUID,
        modelContext: ModelContext,
        services: AppServices
    ) async throws -> NotesWorkspaceSnapshot {
        let config = try notesConfig(for: profileID, in: modelContext)
        let configuration = NotesConfigSnapshot(
            storageLocation: config.storageLocation,
            pendingSMBMigration: config.pendingSMBMigration,
            resolvedPath: "Hank Remote profile notes"
        )
        guard try isHankRemoteProfile(profileID: profileID, modelContext: modelContext) else {
            throw NotesServiceError.serverRequired
        }

        guard let remoteAccess = try remoteProfileNotesContext(profileID: profileID, modelContext: modelContext, services: services) else {
            if let cachedWorkspace = try pendingRemoteProfileWorkspace(profileID: profileID) {
                return cachedWorkspace.workspace(configuration: NotesConfigSnapshot(
                    storageLocation: config.storageLocation,
                    pendingSMBMigration: config.pendingSMBMigration,
                    resolvedPath: cachedWorkspace.needsUpload
                        ? "Hank Remote profile notes (pending sync)"
                        : "Hank Remote profile notes (offline cache)"
                ))
            }
            throw NotesServiceError.serverRequired
        }

        let key = try ensureNotesKey(profileID: profileID, services: services)
        if let workspace = try await readRemoteProfileWorkspace(
            profileID: profileID,
            credentials: nil,
            context: remoteAccess,
            hankRemoteService: services.hankRemoteService,
            key: key,
            configuration: configuration
        ) {
            logger.info("Loaded notes from Hank Remote profile notes profile_id=\(profileID.uuidString, privacy: .public) note_count=\(workspace.entries.count, privacy: .public)")
            return workspace
        }

        let defaultWorkspace = NoteTreeManager.makeDefaultArchive()
        let workspace = NotesWorkspaceSnapshot(
            configuration: configuration,
            entries: defaultWorkspace.entries,
            bodies: defaultWorkspace.bodies,
            boards: defaultWorkspace.boards
        )
        logger.info("Created default Hank Remote profile notes workspace profile_id=\(profileID.uuidString, privacy: .public) note_count=\(workspace.entries.count, privacy: .public)")
        do {
            try await writeRemoteProfileWorkspace(
                workspace,
                profileID: profileID,
                context: remoteAccess,
                hankRemoteService: services.hankRemoteService
            )
            try cacheRemoteProfileWorkspace(workspace, profileID: profileID)
        } catch {
            if Self.shouldUsePendingRemoteWorkspace(for: error) {
                try queuePendingRemoteProfileWorkspace(workspace, profileID: profileID)
            } else {
                throw error
            }
        }
        return workspace
    }

    @MainActor
    func saveWorkspace(
        _ workspace: NotesWorkspaceSnapshot,
        profileID: UUID,
        modelContext: ModelContext,
        services: AppServices
    ) async throws {
        guard try isHankRemoteProfile(profileID: profileID, modelContext: modelContext) else {
            throw NotesServiceError.serverRequired
        }

        if let remoteAccess = try remoteProfileNotesContext(profileID: profileID, modelContext: modelContext, services: services) {
            logger.info("Saving notes to Hank Remote profile notes profile_id=\(profileID.uuidString, privacy: .public) note_count=\(workspace.entries.count, privacy: .public)")
            do {
                try await writeRemoteProfileWorkspace(
                    workspace,
                    profileID: profileID,
                    context: remoteAccess,
                    hankRemoteService: services.hankRemoteService
                )
                try cacheRemoteProfileWorkspace(workspace, profileID: profileID)
            } catch {
                if Self.shouldUsePendingRemoteWorkspace(for: error) {
                    try queuePendingRemoteProfileWorkspace(workspace, profileID: profileID)
                    return
                }
                throw error
            }
            return
        }

        try queuePendingRemoteProfileWorkspace(workspace, profileID: profileID)
    }

    @MainActor
    func migrateStorage(
        profileID: UUID,
        to newLocation: NotesStorageLocation,
        modelContext: ModelContext,
        services: AppServices
    ) async throws -> NotesConfigSnapshot {
        _ = profileID
        _ = newLocation
        _ = modelContext
        _ = services
        throw NotesServiceError.serverRequired
    }

    @MainActor
    func validateStorage(
        profileID: UUID,
        modelContext: ModelContext,
        services: AppServices
    ) async throws -> String {
        let config = try notesConfig(for: profileID, in: modelContext)
        guard try isHankRemoteProfile(profileID: profileID, modelContext: modelContext) else {
            throw NotesServiceError.serverRequired
        }

        guard let remoteAccess = try remoteProfileNotesContext(profileID: profileID, modelContext: modelContext, services: services) else {
            if let cachedWorkspace = try pendingRemoteProfileWorkspace(profileID: profileID) {
                return cachedWorkspace.needsUpload
                    ? "Hank Remote profile notes (pending sync)"
                    : "Hank Remote profile notes (offline cache)"
            }
            throw NotesServiceError.serverRequired
        }
        do {
            _ = try await services.hankRemoteService.profileNotesSync(remoteAccess)
        } catch {
            if
                Self.shouldUsePendingRemoteWorkspace(for: error),
                let cachedWorkspace = try pendingRemoteProfileWorkspace(profileID: profileID)
            {
                return cachedWorkspace.needsUpload
                    ? "Hank Remote profile notes (pending sync)"
                    : "Hank Remote profile notes (offline cache)"
            }
            throw error
        }
        return NotesConfigSnapshot(
            storageLocation: config.storageLocation,
            pendingSMBMigration: config.pendingSMBMigration,
            resolvedPath: "Hank Remote profile notes"
        ).resolvedPath
    }

    @MainActor
    func exportBackupPayload(
        profileID: UUID,
        modelContext: ModelContext,
        services: AppServices
    ) throws -> ProfileBackupNotes? {
        _ = profileID
        _ = modelContext
        _ = services
        return nil
    }

    @MainActor
    func restoreBackupPayload(
        _ payload: ProfileBackupNotes,
        profileID: UUID,
        modelContext: ModelContext,
        services: AppServices
    ) throws {
        guard try isHankRemoteProfile(profileID: profileID, modelContext: modelContext) else {
            throw NotesServiceError.serverRequired
        }

        let importedWorkspace = try decryptWorkspace(
            RawEncryptedNoteArchive(
                manifest: payload.archive.manifest,
                notes: payload.archive.notes
            ),
            key: payload.masterKey,
            configuration: NotesConfigSnapshot(
                storageLocation: payload.configuration.storageLocation,
                pendingSMBMigration: payload.configuration.pendingSMBMigration,
                resolvedPath: ""
            ),
            requireCompleteArchive: true
        )

        _ = try notesConfig(for: profileID, in: modelContext)
        try services.setNotesMasterKey(payload.masterKey, for: profileID)
        try queuePendingRemoteProfileWorkspace(importedWorkspace, profileID: profileID)
        try modelContext.save()
    }

    @MainActor
    func importBackupPayload(
        _ payload: ProfileBackupNotes?,
        into profileID: UUID,
        modelContext: ModelContext,
        services: AppServices
    ) async throws {
        guard let payload else {
            return
        }

        let importedWorkspace = try decryptWorkspace(
            RawEncryptedNoteArchive(
                manifest: payload.archive.manifest,
                notes: payload.archive.notes
            ),
            key: payload.masterKey,
            configuration: NotesConfigSnapshot(
                storageLocation: payload.configuration.storageLocation,
                pendingSMBMigration: payload.configuration.pendingSMBMigration,
                resolvedPath: ""
            ),
            requireCompleteArchive: true
        )

        let currentWorkspace = try await loadWorkspace(
            profileID: profileID,
            modelContext: modelContext,
            services: services
        )

        var mergedWorkspace = currentWorkspace
        let importRootID = NoteTreeManager.createNote(
            entries: &mergedWorkspace.entries,
            bodies: &mergedWorkspace.bodies,
            parentID: nil,
            after: nil,
            title: importedFolderTitle(),
            body: Data()
        )

        var idMapping: [UUID: UUID] = [:]
        cloneImportedEntries(
            parentID: nil,
            importedWorkspace: importedWorkspace,
            destinationWorkspace: &mergedWorkspace,
            destinationParentID: importRootID,
            idMapping: &idMapping
        )

        try await saveWorkspace(
            mergedWorkspace,
            profileID: profileID,
            modelContext: modelContext,
            services: services
        )
    }

    func deleteLocalNotes(profileID: UUID) throws {
        let url = try localRootProvider(profileID, fileManager)
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        try fileManager.removeItem(at: url)
    }

    @MainActor
    func resolvedStoragePath(
        profileID: UUID,
        storageLocation: NotesStorageLocation,
        modelContext: ModelContext,
        services: AppServices
    ) throws -> String {
        if try remoteProfileNotesContext(profileID: profileID, modelContext: modelContext, services: services) != nil {
            return "Hank Remote profile notes"
        }
        _ = storageLocation
        return "Hank Remote profile notes (not connected)"
    }

    private func ensureNotesKey(profileID: UUID, services: AppServices) throws -> String {
        if let existing = try services.notesMasterKey(for: profileID), !existing.isEmpty {
            return existing
        }

        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        let encoded = data.base64EncodedString()
        try services.setNotesMasterKey(encoded, for: profileID)
        return encoded
    }

    @MainActor
    private func loadOrInitializeArchive(
        profileID: UUID,
        config: NotesConfig,
        key: String,
        modelContext: ModelContext,
        services: AppServices
    ) async throws -> RawEncryptedNoteArchive {
        if let archive = try await readArchive(
            profileID: profileID,
            storageLocation: config.effectiveStorageLocation,
            modelContext: modelContext,
            services: services
        ) {
            return archive
        }

        let defaultWorkspace = NoteTreeManager.makeDefaultArchive()
        let rawArchive = try encryptWorkspace(defaultWorkspace, key: key)
        try await writeArchive(
            rawArchive,
            profileID: profileID,
            storageLocation: config.effectiveStorageLocation,
            modelContext: modelContext,
            services: services
        )
        return rawArchive
    }

    private func encryptWorkspace(
        _ workspace: NotesWorkspaceSnapshot,
        key: String
    ) throws -> RawEncryptedNoteArchive {
        let symmetricKey = try symmetricKey(from: key)
        let manifestData = try encoder.encode(NoteTreeManager.normalizedEntries(workspace.entries))
        let encryptedManifest = try encrypt(manifestData, using: symmetricKey)

        var noteFiles: [String: Data] = [:]
        for entry in workspace.entries {
            let bodyData = workspace.bodies[entry.id] ?? Data()
            let fileName = noteFileName(for: entry.id)
            noteFiles[fileName] = try encrypt(bodyData, using: symmetricKey)
            if let board = workspace.boards[entry.id] {
                noteFiles[boardFileName(for: entry.id)] = try encrypt(encoder.encode(board), using: symmetricKey)
            }
        }

        return RawEncryptedNoteArchive(manifest: encryptedManifest, notes: noteFiles)
    }

    private func decryptWorkspace(
        _ rawArchive: RawEncryptedNoteArchive,
        key: String,
        configuration: NotesConfigSnapshot,
        requireCompleteArchive: Bool = false
    ) throws -> NotesWorkspaceSnapshot {
        let symmetricKey = try symmetricKey(from: key)
        let manifestData = try decrypt(rawArchive.manifest, using: symmetricKey)
        let manifest = try decoder.decode([NoteManifestEntry].self, from: manifestData)

        var bodies: [UUID: Data] = [:]
        var boards: [UUID: KanbanBoard] = [:]
        for entry in manifest {
            let fileName = noteFileName(for: entry.id)
            if let encryptedBody = rawArchive.notes[fileName] {
                bodies[entry.id] = try decrypt(encryptedBody, using: symmetricKey)
            } else {
                guard !requireCompleteArchive else {
                    throw NotesServiceError.incompleteEncryptedArchive
                }
                bodies[entry.id] = Data()
            }

            let boardFile = boardFileName(for: entry.id)
            if let encryptedBoard = rawArchive.notes[boardFile] {
                let boardData = try decrypt(encryptedBoard, using: symmetricKey)
                boards[entry.id] = try decoder.decode(KanbanBoard.self, from: boardData)
            } else if requireCompleteArchive, entry.pageType == .kanban {
                throw NotesServiceError.incompleteEncryptedArchive
            }
        }

        return NotesWorkspaceSnapshot(
            configuration: configuration,
            entries: NoteTreeManager.normalizedEntries(manifest),
            bodies: bodies,
            boards: boards
        )
    }

    private func encrypt(_ data: Data, using key: SymmetricKey) throws -> Data {
        let sealedBox = try AES.GCM.seal(data, using: key)
        guard let combined = sealedBox.combined else {
            throw NotesServiceError.invalidEncryptedArchive
        }
        return combined
    }

    private func decrypt(_ data: Data, using key: SymmetricKey) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(sealedBox, using: key)
    }

    private func symmetricKey(from encoded: String) throws -> SymmetricKey {
        guard let data = Data(base64Encoded: encoded) else {
            throw NotesServiceError.missingNotesKey
        }
        return SymmetricKey(data: data)
    }

    @MainActor
    private func readArchive(
        profileID: UUID,
        storageLocation: NotesStorageLocation,
        modelContext: ModelContext,
        services: AppServices
    ) async throws -> RawEncryptedNoteArchive? {
        let credentials = try await smbCredentialsIfNeeded(
            profileID: profileID,
            storageLocation: storageLocation,
            modelContext: modelContext,
            services: services
        )
        return try await readArchive(
            profileID: profileID,
            storageLocation: storageLocation,
            credentials: credentials,
            hankRemoteService: services.hankRemoteService
        )
    }

    private func readArchive(
        profileID: UUID,
        storageLocation: NotesStorageLocation,
        credentials: SMBNotesCredentials?,
        hankRemoteService: HankRemoteService? = nil
    ) async throws -> RawEncryptedNoteArchive? {
        switch storageLocation {
        case .device:
            return try readLocalArchive(profileID: profileID)
        case .smb:
            guard let credentials else {
                throw NotesServiceError.missingSMBConfiguration
            }
            return try await readRemoteArchive(
                profileID: profileID,
                credentials: credentials,
                context: credentials.remoteAccess,
                hankRemoteService: hankRemoteService
            )
        }
    }

    @MainActor
    private func writeArchive(
        _ archive: RawEncryptedNoteArchive,
        profileID: UUID,
        storageLocation: NotesStorageLocation,
        modelContext: ModelContext,
        services: AppServices
    ) async throws {
        let credentials = try await smbCredentialsIfNeeded(
            profileID: profileID,
            storageLocation: storageLocation,
            modelContext: modelContext,
            services: services
        )
        try await writeArchive(
            archive,
            profileID: profileID,
            storageLocation: storageLocation,
            credentials: credentials,
            hankRemoteService: services.hankRemoteService
        )
    }

    private func writeArchive(
        _ archive: RawEncryptedNoteArchive,
        profileID: UUID,
        storageLocation: NotesStorageLocation,
        credentials: SMBNotesCredentials?,
        hankRemoteService: HankRemoteService? = nil
    ) async throws {
        switch storageLocation {
        case .device:
            try writeLocalArchive(archive, profileID: profileID)
        case .smb:
            guard let credentials else {
                throw NotesServiceError.missingSMBConfiguration
            }
            try await writeRemoteArchive(
                archive,
                profileID: profileID,
                credentials: credentials,
                context: credentials.remoteAccess,
                hankRemoteService: hankRemoteService
            )
        }
    }

    private func readLocalArchive(profileID: UUID) throws -> RawEncryptedNoteArchive? {
        let rootURL = try localRootProvider(profileID, fileManager)
        let manifestURL = rootURL.appendingPathComponent("manifest.enc")
        let notesURL = rootURL.appendingPathComponent("notes", isDirectory: true)

        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return nil
        }

        let manifest = try Data(contentsOf: manifestURL)
        var noteFiles: [String: Data] = [:]
        if fileManager.fileExists(atPath: notesURL.path) {
            for url in try fileManager.contentsOfDirectory(at: notesURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) where url.pathExtension == "enc" {
                noteFiles[url.lastPathComponent] = try Data(contentsOf: url)
            }
        }

        return RawEncryptedNoteArchive(manifest: manifest, notes: noteFiles)
    }

    private func writeLocalArchive(_ archive: RawEncryptedNoteArchive, profileID: UUID) throws {
        let rootURL = try localRootProvider(profileID, fileManager)
        let notesURL = rootURL.appendingPathComponent("notes", isDirectory: true)
        try fileManager.createDirectory(at: notesURL, withIntermediateDirectories: true)

        try archive.manifest.write(to: rootURL.appendingPathComponent("manifest.enc"), options: [.atomic])

        let existingURLs = (try? fileManager.contentsOfDirectory(at: notesURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let keep = Set(archive.notes.keys)
        for url in existingURLs where !keep.contains(url.lastPathComponent) {
            try? fileManager.removeItem(at: url)
        }

        for (fileName, data) in archive.notes {
            try data.write(to: notesURL.appendingPathComponent(fileName), options: [.atomic])
        }
    }

    private func readRemoteProfileWorkspace(
        profileID: UUID,
        credentials: SMBNotesCredentials?,
        context: HankRemoteConnectionContext,
        hankRemoteService: HankRemoteService?,
        key: String,
        configuration: NotesConfigSnapshot
    ) async throws -> NotesWorkspaceSnapshot? {
        guard let hankRemoteService else {
            throw HankRemoteServiceError.notConfigured
        }

        if let pending = try pendingRemoteProfileWorkspace(profileID: profileID), pending.needsUpload {
            let pendingWorkspace = pending.workspace(configuration: NotesConfigSnapshot(
                storageLocation: configuration.storageLocation,
                pendingSMBMigration: configuration.pendingSMBMigration,
                resolvedPath: "Hank Remote profile notes (pending sync)"
            ))
            do {
                try await writeRemoteProfileWorkspace(
                    pendingWorkspace,
                    profileID: profileID,
                    context: context,
                    hankRemoteService: hankRemoteService
                )
                try cacheRemoteProfileWorkspace(pendingWorkspace, profileID: profileID)
            } catch {
                if Self.shouldUsePendingRemoteWorkspace(for: error) {
                    logger.info("Using pending Hank Remote profile notes workspace profile_id=\(profileID.uuidString, privacy: .public)")
                    return pendingWorkspace
                }
                throw error
            }
        }

        let summaries: [HankRemoteNoteSummary]
        do {
            summaries = try await hankRemoteService.profileNotesSync(context)
        } catch {
            if
                Self.shouldUsePendingRemoteWorkspace(for: error),
                let pending = try pendingRemoteProfileWorkspace(profileID: profileID)
            {
                return pending.workspace(configuration: NotesConfigSnapshot(
                    storageLocation: configuration.storageLocation,
                    pendingSMBMigration: configuration.pendingSMBMigration,
                    resolvedPath: pending.needsUpload
                        ? "Hank Remote profile notes (pending sync)"
                        : "Hank Remote profile notes (offline cache)"
                ))
            }
            throw error
        }
        let profileSummaries = summaries.filter { !Self.isLegacyRemoteArchiveNote($0) }
        guard !profileSummaries.isEmpty else {
            if let credentials, let legacyArchive = try await readRemoteArchive(
                profileID: profileID,
                credentials: credentials,
                context: context,
                hankRemoteService: hankRemoteService
            ) {
                let workspace = try decryptWorkspace(legacyArchive, key: key, configuration: configuration)
                try cacheRemoteProfileWorkspace(workspace, profileID: profileID)
                return workspace
            }
            return nil
        }

        var entries: [NoteManifestEntry] = []
        var bodies: [UUID: Data] = [:]
        var boards: [UUID: KanbanBoard] = [:]

        for (index, summary) in profileSummaries.enumerated() {
            let note = try await hankRemoteService.profileNotesFetch(noteID: summary.id, context: context)
            let noteID = Self.localNoteUUID(forRemoteNoteID: note.noteID)
            let pageType = NotePageType(rawValue: note.pageType) ?? .text
            let parentID = note.parentID.flatMap { UUID(uuidString: $0) }
            let sortOrder = note.sortOrder != 0 ? note.sortOrder : (summary.sortOrder != 0 ? summary.sortOrder : index)
            entries.append(NoteManifestEntry(
                id: noteID,
                title: note.title.isEmpty ? NoteTreeManager.rootNoteTitle : note.title,
                parentID: parentID,
                sortOrder: sortOrder,
                createdAt: note.updatedAt,
                updatedAt: note.updatedAt,
                pageType: pageType
            ))
            switch pageType {
            case .text:
                let bodyMarkdown = note.bodyMarkdown.isEmpty ? note.content : note.bodyMarkdown
                bodies[noteID] = Data(bodyMarkdown.utf8)
            case .kanban:
                bodies[noteID] = Data()
                boards[noteID] = note.board.map(Self.kanbanBoard(from:)) ?? KanbanBoard()
            case .notebook:
                bodies[noteID] = Data()
            }
        }

        let workspace = NotesWorkspaceSnapshot(
            configuration: configuration,
            entries: NoteTreeManager.normalizedEntries(entries),
            bodies: bodies,
            boards: boards
        )
        try cacheRemoteProfileWorkspace(workspace, profileID: profileID)
        return workspace
    }

    private func writeRemoteProfileWorkspace(
        _ workspace: NotesWorkspaceSnapshot,
        profileID: UUID,
        context: HankRemoteConnectionContext,
        hankRemoteService: HankRemoteService?
    ) async throws {
        guard let hankRemoteService else {
            throw HankRemoteServiceError.notConfigured
        }

        let summaries = try await hankRemoteService.profileNotesSync(context)
        let profileSummaries = summaries.filter { !Self.isLegacyRemoteArchiveNote($0) }
        let summaryByID = Dictionary(uniqueKeysWithValues: profileSummaries.map { ($0.id, $0) })
        let remoteIDByLocalID = Dictionary(uniqueKeysWithValues: profileSummaries.map {
            (Self.localNoteUUID(forRemoteNoteID: $0.id), $0.id)
        })

        let keepRemoteIDs = Set(workspace.entries.map { entry in
            remoteIDByLocalID[entry.id] ?? entry.id.uuidString.lowercased()
        })

        for summary in profileSummaries where !keepRemoteIDs.contains(summary.id) {
            logger.info("Deleting remote profile note removed in app profile_id=\(profileID.uuidString, privacy: .public) note_id=\(summary.id, privacy: .public)")
            try await hankRemoteService.profileNotesDelete(noteID: summary.id, context: context)
        }

        for entry in NoteTreeManager.normalizedEntries(workspace.entries) {
            let remoteNoteID = remoteIDByLocalID[entry.id] ?? entry.id.uuidString.lowercased()
            let pageType = entry.pageType.rawValue
            let board = entry.pageType == .kanban ? workspace.boards[entry.id].map(Self.remoteKanbanBoard(from:)) : nil
            let content: String
            switch entry.pageType {
            case .text:
                content = Self.plainText(fromBodyData: workspace.bodies[entry.id] ?? Data())
            case .kanban:
                content = ""
            case .notebook:
                content = ""
            }
            let parentID = entry.parentID?.uuidString.lowercased() ?? ""
            let expectedRevision = summaryByID[remoteNoteID]?.revision
            do {
                _ = try await hankRemoteService.profileNotesSave(
                    noteID: remoteNoteID,
                    title: entry.title,
                    content: content,
                    expectedRevision: expectedRevision,
                    bodyMarkdown: content,
                    bodyFormat: "markdown",
                    pageType: pageType,
                    parentID: parentID,
                    sortOrder: entry.sortOrder,
                    board: board,
                    context: context
                )
            } catch HankRemoteServiceError.conflict(let currentNote) {
                logger.info("Retrying remote profile note save after stale revision profile_id=\(profileID.uuidString, privacy: .public) note_id=\(remoteNoteID, privacy: .public)")
                _ = try await hankRemoteService.profileNotesSave(
                    noteID: remoteNoteID,
                    title: entry.title,
                    content: content,
                    expectedRevision: currentNote?.revision,
                    bodyMarkdown: content,
                    bodyFormat: "markdown",
                    pageType: pageType,
                    parentID: parentID,
                    sortOrder: entry.sortOrder,
                    board: board,
                    context: context
                )
            }
            logger.info("Saved remote profile note profile_id=\(profileID.uuidString, privacy: .public) note_id=\(remoteNoteID, privacy: .public) page_type=\(pageType, privacy: .public)")
        }
    }

    private func queuePendingRemoteProfileWorkspace(_ workspace: NotesWorkspaceSnapshot, profileID: UUID) throws {
        let url = try pendingRemoteProfileWorkspaceURL(profileID: profileID)
        let pending = PendingRemoteProfileWorkspace(workspace: workspace, needsUpload: true)
        let data = try encoder.encode(pending)
        try data.write(to: url, options: [.atomic])
        logger.info("Queued pending Hank Remote profile notes workspace profile_id=\(profileID.uuidString, privacy: .public) note_count=\(workspace.entries.count, privacy: .public)")
    }

    private func cacheRemoteProfileWorkspace(_ workspace: NotesWorkspaceSnapshot, profileID: UUID) throws {
        let url = try pendingRemoteProfileWorkspaceURL(profileID: profileID)
        let cached = PendingRemoteProfileWorkspace(workspace: workspace, needsUpload: false)
        let data = try encoder.encode(cached)
        try data.write(to: url, options: [.atomic])
        logger.info("Cached Hank Remote profile notes workspace profile_id=\(profileID.uuidString, privacy: .public) note_count=\(workspace.entries.count, privacy: .public)")
    }

    private func pendingRemoteProfileWorkspace(profileID: UUID) throws -> PendingRemoteProfileWorkspace? {
        let url = try pendingRemoteProfileWorkspaceURL(profileID: profileID)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode(PendingRemoteProfileWorkspace.self, from: data)
    }

    private func pendingRemoteProfileWorkspaceURL(profileID: UUID) throws -> URL {
        let directory = try AppFileLocations.applicationSupportDirectory(fileManager: fileManager)
            .appendingPathComponent("RemotePendingNotes", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
            .appendingPathComponent(profileID.uuidString.lowercased())
            .appendingPathExtension("json")
    }

    private static func shouldUsePendingRemoteWorkspace(for error: Error) -> Bool {
        switch error {
        case HankRemoteServiceError.unreachableHost,
             HankRemoteServiceError.websocketClosed:
            return true
        case HankRemoteServiceError.server(let message):
            return message.localizedCaseInsensitiveContains("offline")
        default:
            return false
        }
    }

    @MainActor
    private func isHankRemoteProfile(profileID: UUID, modelContext: ModelContext) throws -> Bool {
        try UserProfile.fetch(id: profileID, in: modelContext)?.authMode == .hankRemote
    }

    @MainActor
    private func remoteProfileNotesContext(
        profileID: UUID,
        modelContext: ModelContext,
        services: AppServices
    ) throws -> HankRemoteConnectionContext? {
        guard
            let profile = try UserProfile.fetch(id: profileID, in: modelContext),
            profile.authMode == .hankRemote
        else {
            return nil
        }
        guard let context = try services.hankRemoteConnectionContext(in: modelContext) else {
            logger.warning("Hank Remote profile notes requested without a usable remote connection profile_id=\(profileID.uuidString, privacy: .public)")
            return nil
        }
        return context
    }

    private static func isLegacyRemoteArchiveNote(_ summary: HankRemoteNoteSummary) -> Bool {
        summary.id.contains("/")
            || summary.title == "manifest.enc"
            || summary.title.hasSuffix(".enc")
            || summary.id.hasSuffix(".enc")
    }

    private static func localNoteUUID(forRemoteNoteID remoteNoteID: String) -> UUID {
        if let uuid = UUID(uuidString: remoteNoteID) {
            return uuid
        }
        let hash = SHA256.hash(data: Data(remoteNoteID.utf8))
        var bytes = Array(hash.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5],
            bytes[6], bytes[7],
            bytes[8], bytes[9],
            bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func plainText(fromBodyData data: Data) -> String {
        guard !data.isEmpty else {
            return ""
        }
        if let attributed = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ) {
            return attributed.string
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func kanbanBoard(from remote: HankRemoteKanbanBoard) -> KanbanBoard {
        KanbanBoard(
            columns: remote.columns.map { column in
                KanbanColumn(
                    id: UUID(uuidString: column.id) ?? localNoteUUID(forRemoteNoteID: column.id),
                    title: column.title,
                    sortOrder: column.sortOrder,
                    cards: column.cards.map { card in
                        KanbanCard(
                            id: UUID(uuidString: card.id) ?? localNoteUUID(forRemoteNoteID: card.id),
                            text: card.text,
                            sortOrder: card.sortOrder,
                            createdAt: card.createdAt,
                            updatedAt: card.updatedAt
                        )
                    },
                    createdAt: column.createdAt,
                    updatedAt: column.updatedAt
                )
            },
            createdAt: remote.createdAt,
            updatedAt: remote.updatedAt
        )
    }

    private static func remoteKanbanBoard(from board: KanbanBoard) -> HankRemoteKanbanBoard {
        HankRemoteKanbanBoard(
            columns: board.columns.map { column in
                HankRemoteKanbanColumn(
                    id: column.id.uuidString.lowercased(),
                    title: column.title,
                    sortOrder: column.sortOrder,
                    cards: column.cards.map { card in
                        HankRemoteKanbanCard(
                            id: card.id.uuidString.lowercased(),
                            text: card.text,
                            sortOrder: card.sortOrder,
                            createdAt: card.createdAt,
                            updatedAt: card.updatedAt
                        )
                    },
                    createdAt: column.createdAt,
                    updatedAt: column.updatedAt
                )
            },
            createdAt: board.createdAt,
            updatedAt: board.updatedAt
        )
    }

    private func readRemoteArchive(
        profileID: UUID,
        credentials: SMBNotesCredentials,
        context: HankRemoteConnectionContext,
        hankRemoteService: HankRemoteService?
    ) async throws -> RawEncryptedNoteArchive? {
        guard let hankRemoteService else {
            throw HankRemoteServiceError.notConfigured
        }
        let rootPath = smbRootPath(profileID: profileID, connection: credentials.details)
        let manifestID = remoteNoteID(for: "manifest.enc", in: rootPath)
        let notesRoot = FileBrowserPathing.childPath(named: "notes", in: rootPath)
        let summaries = try await hankRemoteService.notesSync(context)
        let summaryByID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })
        guard summaryByID[manifestID] != nil else {
            return nil
        }

        let manifestResponse = try await hankRemoteService.notesFetch(noteID: manifestID, context: context)
        guard let manifest = Data(base64Encoded: manifestResponse.content) else {
            throw NotesServiceError.invalidEncryptedArchive
        }

        var noteFiles: [String: Data] = [:]
        for summary in summaries where summary.id.hasPrefix(notesRoot + "/") {
            let response = try await hankRemoteService.notesFetch(noteID: summary.id, context: context)
            guard let data = Data(base64Encoded: response.content) else {
                throw NotesServiceError.invalidEncryptedArchive
            }
            noteFiles[(summary.id as NSString).lastPathComponent] = data
        }

        return RawEncryptedNoteArchive(manifest: manifest, notes: noteFiles)
    }

    private func writeRemoteArchive(
        _ archive: RawEncryptedNoteArchive,
        profileID: UUID,
        credentials: SMBNotesCredentials,
        context: HankRemoteConnectionContext,
        hankRemoteService: HankRemoteService?
    ) async throws {
        guard let hankRemoteService else {
            throw HankRemoteServiceError.notConfigured
        }
        let rootPath = smbRootPath(profileID: profileID, connection: credentials.details)
        let manifestID = remoteNoteID(for: "manifest.enc", in: rootPath)
        let notesRoot = FileBrowserPathing.childPath(named: "notes", in: rootPath)
        let summaries = try await hankRemoteService.notesSync(context)
        let summaryByID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })

        _ = try await hankRemoteService.notesSave(
            noteID: manifestID,
            title: "manifest.enc",
            content: archive.manifest.base64EncodedString(),
            expectedRevision: summaryByID[manifestID]?.revision,
            context: context
        )

        let keep = Set(archive.notes.keys.map { remoteNoteID(for: $0, in: notesRoot) })
        for summary in summaries where summary.id.hasPrefix(notesRoot + "/") && !keep.contains(summary.id) {
            try await hankRemoteService.notesDelete(noteID: summary.id, context: context)
        }

        for (fileName, data) in archive.notes {
            let noteID = remoteNoteID(for: fileName, in: notesRoot)
            _ = try await hankRemoteService.notesSave(
                noteID: noteID,
                title: fileName,
                content: data.base64EncodedString(),
                expectedRevision: summaryByID[noteID]?.revision,
                context: context
            )
        }
    }

    @MainActor
    private func smbCredentials(
        profileID: UUID,
        modelContext: ModelContext,
        services: AppServices
    ) async throws -> SMBNotesCredentials {
        guard
            let resolvedConnection = try await services.preferredSMBConnection(for: profileID, in: modelContext)
        else {
            throw NotesServiceError.missingSMBConfiguration
        }

        return SMBNotesCredentials(
            details: resolvedConnection.details,
            password: try services.smbPassword(for: resolvedConnection, profileID: profileID) ?? "",
            remoteAccess: resolvedConnection.remoteAccess
        )
    }

    @MainActor
    private func smbCredentialsIfNeeded(
        profileID: UUID,
        storageLocation: NotesStorageLocation,
        modelContext: ModelContext,
        services: AppServices
    ) async throws -> SMBNotesCredentials? {
        guard storageLocation == .smb else {
            return nil
        }
        return try await smbCredentials(profileID: profileID, modelContext: modelContext, services: services)
    }

    @MainActor
    private func fallbackSMBCredentials(
        profileID: UUID,
        modelContext: ModelContext,
        services: AppServices
    ) throws -> SMBNotesCredentials {
        guard
            let resolvedConnection = try services.resolvedSMBConnection(for: profileID, in: modelContext)
        else {
            throw NotesServiceError.missingSMBConfiguration
        }

        return SMBNotesCredentials(
            details: resolvedConnection.details,
            password: try services.smbPassword(for: resolvedConnection, profileID: profileID) ?? "",
            remoteAccess: resolvedConnection.remoteAccess
        )
    }

    @MainActor
    private func fallbackSMBCredentialsIfNeeded(
        profileID: UUID,
        storageLocation: NotesStorageLocation,
        modelContext: ModelContext,
        services: AppServices
    ) throws -> SMBNotesCredentials? {
        guard storageLocation == .smb else {
            return nil
        }
        return try fallbackSMBCredentials(profileID: profileID, modelContext: modelContext, services: services)
    }

    private func smbRootPath(profileID: UUID, connection: SMBConnectionDetails) -> String {
        let notesRoot = FileBrowserPathing.childPath(named: "Hank Notes", in: connection.normalizedStartPath)
        return FileBrowserPathing.childPath(named: profileID.uuidString.lowercased(), in: notesRoot)
    }

    private func remoteNoteID(for fileName: String, in parentPath: String) -> String {
        FileBrowserPathing.childPath(named: fileName, in: parentPath)
    }

    private func noteFileName(for noteID: UUID) -> String {
        "\(noteID.uuidString.lowercased()).rtf.enc"
    }

    private func boardFileName(for noteID: UUID) -> String {
        "\(noteID.uuidString.lowercased()).kanban.enc"
    }

    private func importedFolderTitle() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        return "Imported from Backup \(formatter.string(from: .now))"
    }

    private func cloneImportedEntries(
        parentID: UUID?,
        importedWorkspace: NotesWorkspaceSnapshot,
        destinationWorkspace: inout NotesWorkspaceSnapshot,
        destinationParentID: UUID,
        idMapping: inout [UUID: UUID]
    ) {
        let children = importedWorkspace.entries
            .filter { $0.parentID == parentID }
            .sorted {
                if $0.sortOrder != $1.sortOrder {
                    return $0.sortOrder < $1.sortOrder
                }
                return $0.createdAt < $1.createdAt
            }

        for child in children {
            let newID = UUID()
            idMapping[child.id] = newID

            destinationWorkspace.entries.append(
                NoteManifestEntry(
                    id: newID,
                    title: child.title,
                    parentID: destinationParentID,
                    sortOrder: destinationWorkspace.entries.filter { $0.parentID == destinationParentID }.count,
                    createdAt: child.createdAt,
                    updatedAt: child.updatedAt,
                    pageType: child.pageType
                )
            )
            destinationWorkspace.bodies[newID] = importedWorkspace.bodies[child.id] ?? Data()
            if let board = importedWorkspace.boards[child.id] {
                destinationWorkspace.boards[newID] = board
            }

            cloneImportedEntries(
                parentID: child.id,
                importedWorkspace: importedWorkspace,
                destinationWorkspace: &destinationWorkspace,
                destinationParentID: newID,
                idMapping: &idMapping
            )
        }

        destinationWorkspace.entries = NoteTreeManager.normalizedEntries(destinationWorkspace.entries)
    }

    private static func defaultLocalRoot(profileID: UUID, fileManager: FileManager) throws -> URL {
        let root = try AppFileLocations.applicationSupportDirectory(fileManager: fileManager)
            .appendingPathComponent("Notes", isDirectory: true)
            .appendingPathComponent(profileID.uuidString.lowercased(), isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func blockingWait<T>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = BlockingResultBox<T>()

        Task.detached {
            defer { semaphore.signal() }
            do {
                let value = try await operation()
                box.result = .success(value)
            } catch {
                box.result = .failure(error)
            }
        }

        semaphore.wait()
        switch box.result {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        case .none:
            throw NotesServiceError.invalidEncryptedArchive
        }
    }
}

private struct SMBNotesCredentials {
    let details: SMBConnectionDetails
    let password: String
    let remoteAccess: HankRemoteConnectionContext
}

private final class BlockingResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}
