import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct NotesView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var services: AppServices
    @ObservedObject var store: NotesStore
    let bottomContentInset: CGFloat

    @StateObject private var editorController = RichTextEditorController()
    @State private var isShowingLinkPrompt = false
    @State private var linkDraft = ""
    @State private var isShowingTagPrompt = false
    @State private var tagDraft = ""
    @State private var isShowingRenamePrompt = false
    @State private var renameNoteID: UUID?
    @State private var renameDraft = ""
    @State private var browserDestination: HankBrowserDestination?
    @State private var shareItem: NoteShareItem?
    @State private var collapsedNoteIDs: Set<UUID> = []
    @State private var activeDropTargetID: UUID?
    @State private var isNoteSearchVisible = false
    @State private var noteSearchText = ""
    @State private var noteAttachmentPreview: NoteAttachmentPreview?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .hankScreenBackground()
        .task(id: appState.profileLoadKey) {
            guard let profileID = appState.activeProfileID else {
                return
            }
            await store.loadIfNeeded(profileID: profileID, modelContext: modelContext, services: services)
        }
        .onDisappear {
            Task {
                await store.persistNow()
            }
        }
        .quickLookPreview(noteAttachmentPreviewURL)
        .alert("Add Link", isPresented: $isShowingLinkPrompt) {
            TextField("https://example.com", text: $linkDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button("Cancel", role: .cancel) {
                linkDraft = ""
            }

            Button("Apply") {
                do {
                    try editorController.applyLink(linkDraft)
                    linkDraft = ""
                } catch {
                    store.errorMessage = error.localizedDescription
                }
            }
        } message: {
            Text("Apply the link to the current selection, or insert it at the cursor.")
        }
        .alert("Rename Note", isPresented: $isShowingRenamePrompt) {
            TextField("Note title", text: $renameDraft)

            Button("Cancel", role: .cancel) {
                renameNoteID = nil
                renameDraft = ""
            }

            Button("Rename") {
                if let renameNoteID {
                    store.rename(noteID: renameNoteID, to: renameDraft)
                }
                renameNoteID = nil
                renameDraft = ""
            }
        } message: {
            Text("Update the title shown in the notes list and editor header.")
        }
        .alert("Add Tag", isPresented: $isShowingTagPrompt) {
            TextField("tag-name", text: $tagDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button("Cancel", role: .cancel) {
                tagDraft = ""
            }

            Button("Apply") {
                do {
                    try editorController.applyTag(tagDraft)
                    tagDraft = ""
                } catch {
                    store.errorMessage = error.localizedDescription
                }
            }
        } message: {
            Text("Add a single tag prefix to the current line.")
        }
        .sheet(item: $shareItem) { item in
            NoteShareSheet(item: item) {
                shareItem = nil
            }
        }
        .sheet(item: $browserDestination) { destination in
            HankSafariView(url: destination.url)
        }
        .onChange(of: noteSearchText) { _, nextValue in
            editorController.updateSearchQuery(nextValue)
        }
        .task(id: store.selectedNoteID) {
            if let request = store.consumeRequestedEditorSearch(), request.noteID == store.selectedNoteID {
                noteSearchText = request.query
                isNoteSearchVisible = true
                editorController.updateSearchQuery(request.query)
            } else if store.selectedNoteID == nil || store.selectedPageType != .text {
                noteSearchText = ""
                isNoteSearchVisible = false
                editorController.updateSearchQuery("")
            }
        }
    }

    private var noteAttachmentPreviewURL: Binding<URL?> {
        Binding(
            get: { noteAttachmentPreview?.url },
            set: { nextURL in
                if nextURL == nil {
                    noteAttachmentPreview = nil
                }
            }
        )
    }

    private var sidebar: some View {
        Group {
            switch store.loadState {
            case .loading:
                ProgressView("Loading notes…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .hankScreenBackground()
            case .unavailable(let message):
                ContentUnavailableView(
                    "Notes Unavailable",
                    systemImage: "note.text.badge.plus",
                    description: Text(message)
                )
                .hankScreenBackground()
            case .ready:
                List(selection: selectedNoteBinding) {
                    sidebarContent
                }
                .listStyle(.insetGrouped)
                .contentMargins(.top, 10, for: .scrollContent)
                .scrollContentBackground(.hidden)
                .navigationTitle("Notes")
                .navigationBarTitleDisplayMode(.inline)
                .hankNavigationChrome()
                .hankScreenBackground()
                .searchable(
                    text: $store.searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search Notes"
                )
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button("All Tags") {
                                store.selectTag(nil)
                            }

                            ForEach(store.availableTags, id: \.self) { tag in
                                Button {
                                    store.selectTag(tag)
                                } label: {
                                    Label("#\(tag)", systemImage: "tag")
                                }
                            }
                        } label: {
                            Image(systemName: store.selectedTag == nil ? "tag" : "tag.fill")
                        }
                    }

                    ToolbarItem(placement: .principal) {
                        Group {
                            if store.selectedTag != nil {
                                Button {
                                    store.selectTag(nil)
                                } label: {
                                    Text("Notes")
                                        .font(.headline.weight(.semibold))
                                }
                                .buttonStyle(.plain)
                            } else {
                                Text("Notes")
                                    .font(.headline.weight(.semibold))
                            }
                        }
                    }

                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            store.createRootNote()
                        } label: {
                            Label("New Note", systemImage: "plus")
                        }
                    }
                }
            }
        }
    }

    private var visibleOutlineItems: [NoteOutlineItem] {
        let items = store.outlineItems
        guard store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, store.selectedTag == nil else {
            return items
        }

        return items.filter { item in
            var parentID = item.entry.parentID
            var visited = Set<UUID>()
            while let currentParentID = parentID {
                guard visited.insert(currentParentID).inserted else {
                    return true
                }
                if collapsedNoteIDs.contains(currentParentID) {
                    return false
                }
                parentID = items.first(where: { $0.id == currentParentID })?.entry.parentID
            }
            return true
        }
    }

    private var selectedNoteBinding: Binding<UUID?> {
        Binding(
            get: { store.selectedNoteID },
            set: { store.select($0) }
        )
    }

    private func beginRename(_ noteID: UUID) {
        renameNoteID = noteID
        renameDraft = store.title(for: noteID)
        isShowingRenamePrompt = true
    }

    private func share(_ noteID: UUID) {
        do {
            shareItem = try store.makeShareItem(for: noteID)
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    private func toggleCollapse(for noteID: UUID) {
        if collapsedNoteIDs.contains(noteID) {
            collapsedNoteIDs.remove(noteID)
        } else {
            collapsedNoteIDs.insert(noteID)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch store.loadState {
        case .loading:
            ProgressView("Opening note…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .hankScreenBackground()
        case .unavailable(let message):
            ContentUnavailableView(
                "Notes Unavailable",
                systemImage: "externaldrive.badge.xmark",
                description: Text(message)
            )
            .hankScreenBackground()
        case .ready:
            if store.selectedNoteID == nil {
                ContentUnavailableView(
                    store.selectedTag == nil ? "Notes" : "#\(store.selectedTag ?? "")",
                    systemImage: store.selectedTag == nil ? "note.text" : "tag",
                    description: Text(store.selectedTag == nil ? "Create a page or choose one from the tree to start writing." : "Choose a tagged line from the list to open its source note.")
                )
                .hankScreenBackground()
            } else {
                VStack(spacing: 0) {
                    if let errorMessage = store.errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(HankTheme.error)
                            .padding(.horizontal, 16)
                            .padding(.top, 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    VStack(spacing: 0) {
                        switch store.selectedPageType {
                        case .text:
                            RichTextEditor(
                                text: Binding(
                                    get: { store.noteBody },
                                    set: { store.updateBody($0) }
                                ),
                                controller: editorController,
                                searchQuery: noteSearchText,
                                onOpenLink: { url in
                                    if handleNoteAttachmentLink(url) {
                                        return
                                    }
                                    HankLinkRouting.handle(
                                        url,
                                        openInAppBrowser: { browserURL in
                                            browserDestination = HankBrowserDestination(url: browserURL)
                                        },
                                        openExternally: { externalURL in
                                            openURL(externalURL)
                                        }
                                    )
                                },
                                onPullToRevealSearch: {
                                    withAnimation(.easeOut(duration: 0.18)) {
                                        isNoteSearchVisible = true
                                    }
                                }
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 10)
                        case .kanban:
                            KanbanBoardView(store: store)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 12)
                        case .notebook:
                            NotebookContentsView(store: store)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 12)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .hankNavigationChrome()
                .hankScreenBackground()
                .safeAreaInset(edge: .top) {
                    if store.selectedPageType == .text {
                        VStack(spacing: 0) {
                            if isNoteSearchVisible || !noteSearchText.isEmpty {
                                NoteSearchBar(
                                    text: $noteSearchText,
                                    resultCount: editorController.searchResultCount,
                                    currentIndex: editorController.currentSearchResultIndex,
                                    onPrevious: { editorController.focusPreviousSearchResult() },
                                    onNext: { editorController.focusNextSearchResult() },
                                    onClose: {
                                        noteSearchText = ""
                                        isNoteSearchVisible = false
                                        editorController.updateSearchQuery("")
                                    }
                                )
                                .padding(.horizontal, 10)
                                .padding(.top, 8)
                            }

                            formattingBar
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                        }
                        .background(HankTheme.background.opacity(0.96))
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Button {
                            if let selectedNoteID = store.selectedNoteID {
                                beginRename(selectedNoteID)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(store.noteTitle.isEmpty ? "Note" : store.noteTitle)
                                    .font(.headline.weight(.semibold))
                                    .lineLimit(1)

                                if store.collaboratorCount > 0 {
                                    Label("\(store.collaboratorCount)", systemImage: "person.2.fill")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(HankTheme.accent)
                                        .labelStyle(.titleAndIcon)
                                        .accessibilityLabel("\(store.collaboratorCount) collaborators active")
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Rename Note")
                    }

                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Menu {
                            Button("New Note") {
                                store.createSibling()
                            }
                            Button("New Subnote") {
                                store.createSubpage()
                            }
                            Button("Duplicate") {
                                store.duplicateSelected()
                            }
                            if store.selectedPageType == .text {
                                Button("Convert To Kanban") {
                                    store.convertSelectedToKanban()
                                }
                            } else if store.selectedPageType == .kanban {
                                Button("Convert To Note") {
                                    store.convertSelectedToText()
                                }
                            }
                            Button("Move To Root") {
                                store.moveSelectedToRoot()
                            }
                            Button("Delete", role: .destructive) {
                                store.deleteSelected()
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
        }
    }

    private var formattingBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                FormatButton(symbol: "bold", accessibilityLabel: "Bold", isActive: editorController.formatState.isBold) { editorController.toggleBold() }
                FormatButton(symbol: "italic", accessibilityLabel: "Italic", isActive: editorController.formatState.isItalic) { editorController.toggleItalic() }
                FormatButton(symbol: "underline", accessibilityLabel: "Underline", isActive: editorController.formatState.isUnderline) { editorController.toggleUnderline() }
                FormatButton(title: "A-", accessibilityLabel: "Decrease Font Size") { editorController.adjustFontSize(delta: -2) }
                FormatButton(title: "A+", accessibilityLabel: "Increase Font Size") { editorController.adjustFontSize(delta: 2) }
                FormatButton(title: "H", accessibilityLabel: "Heading", isActive: editorController.formatState.isHeader) { editorController.toggleHeader() }
                FormatButton(symbol: "list.bullet", accessibilityLabel: "Bulleted List") { editorController.applyBullets() }
                FormatButton(symbol: "list.number", accessibilityLabel: "Numbered List") { editorController.applyNumbering() }
                FormatButton(symbol: "circle", accessibilityLabel: "Checklist") { editorController.applyChecklist() }
                FormatButton(symbol: "tag", accessibilityLabel: "Add Tag") {
                    tagDraft = ""
                    isShowingTagPrompt = true
                }
                FormatButton(symbol: "link", accessibilityLabel: "Add Link") {
                    do {
                        let didApplySelectionLink = try editorController.applyLinkFromSelectedTextIfPossible()
                        if !didApplySelectionLink {
                            linkDraft = ""
                            isShowingLinkPrompt = true
                        }
                    } catch {
                        store.errorMessage = error.localizedDescription
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(HankTheme.chrome)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(HankTheme.stroke)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var sidebarContent: some View {
        if let selectedTag = store.selectedTag {
            Section {
                ForEach(store.tagRollupItems) { item in
                    NavigationLink(value: item.noteID) {
                        TaggedLineRow(item: item)
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        store.selectTagRollupItem(item)
                    })
                    .tag(item.noteID)
                    .listRowBackground(HankTheme.surface)
                }
            } header: {
                Label("#\(selectedTag)", systemImage: "tag")
            }
        } else if !store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Section {
                ForEach(store.searchResults) { result in
                    NavigationLink(value: result.noteID) {
                        NoteSearchResultRow(result: result)
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        store.selectSearchResult(result)
                    })
                    .tag(result.noteID)
                    .listRowBackground(HankTheme.surface)
                }
            } header: {
                Text("Results")
            }
        } else {
            Section {
                ForEach(visibleOutlineItems) { item in
                    NavigationLink(value: item.id) {
                        NoteOutlineRow(
                            item: item,
                            isSelected: store.selectedNoteID == item.id,
                            hasChildren: store.hasChildren(item.id),
                            isCollapsed: collapsedNoteIDs.contains(item.id),
                            isDropTarget: activeDropTargetID == item.id,
                            onToggle: {
                                toggleCollapse(for: item.id)
                            }
                        )
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        store.select(item.id)
                    })
                    .tag(item.id)
                    .contextMenu {
                        Button("Rename Note") {
                            beginRename(item.id)
                        }
                        Button("Share") {
                            share(item.id)
                        }
                        Button("New Note") {
                            store.select(item.id)
                            store.createSibling()
                        }
                        Button("New Subnote") {
                            store.select(item.id)
                            store.createSubpage()
                        }
                        Button("Duplicate") {
                            store.select(item.id)
                            store.duplicateSelected()
                        }
                        Button("Move To Root") {
                            store.select(item.id)
                            store.moveSelectedToRoot()
                        }
                        Button("Delete", role: .destructive) {
                            store.select(item.id)
                            store.deleteSelected()
                        }
                    }
                    .onDrag {
                        NSItemProvider(object: item.id.uuidString as NSString)
                    }
                    .onDrop(
                        of: [UTType.text.identifier],
                        delegate: NoteRowDropDelegate(
                            targetNoteID: item.id,
                            store: store,
                            activeDropTargetID: $activeDropTargetID
                        )
                    )
                    .listRowBackground(store.selectedNoteID == item.id ? HankTheme.elevatedSurface : HankTheme.surface)
                }
            }
        }
    }

    @discardableResult
    private func handleNoteAttachmentLink(_ url: URL) -> Bool {
        guard url.scheme == "hank-note-attachment" else {
            return false
        }
        let attachmentID = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !attachmentID.isEmpty else {
            return true
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let noteID = components?.queryItems?.first(where: { $0.name == "note_id" })?.value ?? store.selectedNoteID?.uuidString ?? ""
        let scope = components?.queryItems?.first(where: { $0.name == "scope" })?.value ?? "profile"
        let filename = components?.queryItems?.first(where: { $0.name == "filename" })?.value ?? "Attachment"
        guard !noteID.isEmpty else {
            store.errorMessage = "The note attachment link is missing its note reference."
            return true
        }
        Task {
            do {
                guard let context = try services.hankRemoteConnectionContext(in: modelContext) else {
                    store.errorMessage = "Enable Hank Remote to open this note attachment."
                    return
                }
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("HankNoteAttachmentPreviews", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let target = directory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    .appendingPathComponent(filename, isDirectory: false)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await services.hankRemoteService.downloadNoteAttachment(
                    scope: scope,
                    noteID: noteID,
                    attachmentID: attachmentID,
                    to: target,
                    context: context
                )
                noteAttachmentPreview = NoteAttachmentPreview(url: target)
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
        return true
    }
}

private struct NoteOutlineRow: View {
    let item: NoteOutlineItem
    let isSelected: Bool
    let hasChildren: Bool
    let isCollapsed: Bool
    let isDropTarget: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if hasChildren {
                Button(action: onToggle) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Color.clear
                    .frame(width: 18, height: 24)
            }

            Circle()
                .fill(isSelected ? HankTheme.accent : HankTheme.stroke)
                .frame(width: 7, height: 7)

            Text(title)
                .font(.body.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer()
        }
        .padding(.leading, CGFloat(item.depth) * 18)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: HankMetrics.cornerRadius, style: .continuous)
                .fill(isDropTarget ? HankTheme.accent.opacity(0.16) : Color.clear)
        )
    }

    private var title: String {
        let trimmed = item.entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (item.entry.parentID == nil ? NoteTreeManager.rootNoteTitle : NoteTreeManager.subnoteTitle) : trimmed
    }
}

private struct NoteSearchResultRow: View {
    let result: NoteSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(result.title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text(result.preview)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}

private struct TaggedLineRow: View {
    let item: TaggedLineRollupItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.noteTitle)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Label("#\(item.tag)", systemImage: "tag")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(HankTheme.accent)
                .lineLimit(1)

            Text(item.lineText.isEmpty ? "Tagged line" : item.lineText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}

private struct NotebookContentsView: View {
    @ObservedObject var store: NotesStore

    var body: some View {
        if store.selectedNotebookChildItems.isEmpty {
            ContentUnavailableView("Notebook", systemImage: "book.closed")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(store.selectedNotebookChildItems) { item in
                Button {
                    store.select(item.id)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: iconName(for: item.entry.pageType))
                            .foregroundStyle(HankTheme.accent)
                            .frame(width: 22)
                        Text(store.title(for: item.id))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .listRowBackground(HankTheme.surface)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func iconName(for pageType: NotePageType) -> String {
        switch pageType {
        case .text:
            return "note.text"
        case .kanban:
            return "rectangle.3.group"
        case .notebook:
            return "book.closed"
        }
    }
}

private struct NoteSearchBar: View {
    @Binding var text: String
    let resultCount: Int
    let currentIndex: Int?
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search This Note", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if resultCount > 0 {
                Text("\((currentIndex ?? 0) + 1)/\(resultCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Button(action: onPrevious) {
                Image(systemName: "chevron.up")
            }
            .disabled(resultCount == 0)
            .accessibilityLabel("Previous Search Result")

            Button(action: onNext) {
                Image(systemName: "chevron.down")
            }
            .disabled(resultCount == 0)
            .accessibilityLabel("Next Search Result")

            Button("Done", action: onClose)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(HankTheme.chrome)
        .transition(.move(edge: .top).combined(with: .opacity))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(HankTheme.stroke)
                .frame(height: 1)
        }
    }
}

private struct KanbanBoardView: View {
    @ObservedObject var store: NotesStore
    @FocusState private var focusedCardID: UUID?

    var body: some View {
        GeometryReader { proxy in
            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button {
                            store.addKanbanColumn()
                        } label: {
                            Label("Add Column", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)

                        Spacer(minLength: 0)
                    }

                    if let board = store.selectedBoard, !board.columns.isEmpty {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(board.columns.sorted { $0.sortOrder < $1.sortOrder }) { column in
                                KanbanColumnView(
                                    store: store,
                                    column: column,
                                    focusedCardID: $focusedCardID
                                )
                                    .frame(width: 280)
                                    .onDrag {
                                        NSItemProvider(object: "column:\(column.id.uuidString)" as NSString)
                                    }
                                    .onDrop(
                                        of: [UTType.text.identifier],
                                        delegate: KanbanColumnDropDelegate(store: store, targetColumnID: column.id)
                                    )
                            }
                        }
                        .padding(.bottom, 12)
                    } else {
                        ContentUnavailableView(
                            "No Columns Yet",
                            systemImage: "square.grid.3x1.folder.badge.plus",
                            description: Text("Add a column to start organizing this board.")
                        )
                        .frame(maxWidth: .infinity, minHeight: max(240, proxy.size.height - 80), alignment: .topLeading)
                    }
                }
                .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .topLeading)
            }
        }
    }
}

private struct KanbanColumnView: View {
    @ObservedObject var store: NotesStore
    let column: KanbanColumn
    var focusedCardID: FocusState<UUID?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField(
                    "Column",
                    text: Binding(
                        get: { column.title },
                        set: { store.updateKanbanColumnTitle(column.id, title: $0) }
                    )
                )
                .font(.headline.weight(.semibold))

                Button {
                    if let cardID = store.addKanbanCard(to: column.id) {
                        focusedCardID.wrappedValue = cardID
                    }
                } label: {
                    Image(systemName: "plus")
                }

                Menu {
                    Button("Delete Column", role: .destructive) {
                        store.deleteKanbanColumn(column.id)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }

            VStack(spacing: 8) {
                ForEach(column.cards.sorted { $0.sortOrder < $1.sortOrder }) { card in
                    KanbanCardRow(
                        store: store,
                        columnID: column.id,
                        card: card,
                        focusedCardID: focusedCardID
                    )
                        .onDrag {
                            NSItemProvider(object: "card:\(column.id.uuidString):\(card.id.uuidString)" as NSString)
                        }
                        .onDrop(
                            of: [UTType.text.identifier],
                            delegate: KanbanCardDropDelegate(store: store, targetColumnID: column.id, targetCardID: card.id)
                        )
                }

                RoundedRectangle(cornerRadius: HankMetrics.cornerRadius, style: .continuous)
                    .fill(HankTheme.background.opacity(0.4))
                    .frame(height: 26)
                    .overlay(
                        Text("Drop Here")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    )
                    .onDrop(
                        of: [UTType.text.identifier],
                        delegate: KanbanCardDropDelegate(store: store, targetColumnID: column.id, targetCardID: nil)
                    )
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(HankTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(HankTheme.stroke, lineWidth: 1)
        )
    }
}

private struct KanbanCardRow: View {
    @ObservedObject var store: NotesStore
    let columnID: UUID
    let card: KanbanCard
    var focusedCardID: FocusState<UUID?>.Binding

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            TextField(
                "Card",
                text: Binding(
                    get: { card.text },
                    set: { store.updateKanbanCard(card.id, in: columnID, text: $0) }
                )
            )
            .textFieldStyle(.plain)
            .submitLabel(.return)
            .focused(focusedCardID, equals: card.id)
            .onSubmit {
                if let cardID = store.insertKanbanCard(after: card.id, in: columnID) {
                    focusedCardID.wrappedValue = cardID
                }
            }

            Menu {
                Button("Delete Card", role: .destructive) {
                    store.deleteKanbanCard(card.id, from: columnID)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: HankMetrics.cornerRadius, style: .continuous)
                .fill(HankTheme.elevatedSurface)
        )
    }
}

private struct FormatButton: View {
    var title: String?
    var symbol: String?
    var accessibilityLabel: String
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.body.weight(.semibold))
                } else {
                    Text(title ?? "")
                        .font(.caption.weight(.bold))
                }
            }
            .foregroundStyle(isActive ? HankTheme.accent : .primary)
            .frame(minWidth: 36, minHeight: 36)
            .background(
                RoundedRectangle(cornerRadius: HankMetrics.cornerRadius, style: .continuous)
                    .fill(isActive ? HankTheme.accent.opacity(0.18) : HankTheme.surface)
            )
            .overlay {
                RoundedRectangle(cornerRadius: HankMetrics.cornerRadius, style: .continuous)
                    .stroke(isActive ? HankTheme.accent.opacity(0.55) : Color.clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isActive ? "On" : "Off")
    }
}

private struct NoteShareSheet: View {
    @Environment(\.dismiss) private var dismiss

    let item: NoteShareItem
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ShareLink(item: item.markdownURL) {
                        Label("Share Note", systemImage: "square.and.arrow.up")
                    }
                } footer: {
                    Text("Hank exported \(item.title) as a Markdown file for sharing.")
                }
            }
            .navigationTitle("Share Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        onDone()
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct RichTextEditor: UIViewRepresentable {
    @Binding var text: NSAttributedString
    let controller: RichTextEditorController
    let searchQuery: String
    let onOpenLink: (URL) -> Void
    let onPullToRevealSearch: () -> Void

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.textColor = .white
        textView.tintColor = UIColor(HankTheme.accent)
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.isEditable = true
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.delaysContentTouches = false
        textView.canCancelContentTouches = true
        textView.keyboardDismissMode = .interactive
        textView.allowsEditingTextAttributes = true
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 14, left: 10, bottom: 24, right: 10)
        textView.attributedText = editorReadableText(text)
        textView.typingAttributes = bodyTypingAttributes()
        let checklistTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleChecklistTap(_:)))
        checklistTap.cancelsTouchesInView = true
        checklistTap.delegate = context.coordinator
        textView.addGestureRecognizer(checklistTap)
        controller.attach(textView: textView, refreshImmediately: false)
        context.coordinator.refreshFormatStateLater(from: textView)
        controller.updateSearchQuery(searchQuery)
        refreshScrollingLayout(for: textView)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.isApplyingSwiftUIUpdate = true
        defer {
            context.coordinator.isApplyingSwiftUIUpdate = false
            context.coordinator.refreshFormatStateLater(from: uiView)
        }

        controller.attach(textView: uiView, refreshImmediately: false)
        controller.updateSearchQuery(searchQuery)
        let currentText = strippedSearchHighlights(from: uiView.attributedText)
        let readableText = editorReadableText(text)
        if !currentText.isEqual(to: readableText) {
            if uiView.isFirstResponder, currentText.string == readableText.string {
                return
            }
            let selectedRange = uiView.selectedRange
            uiView.attributedText = readableText
            uiView.selectedRange = NSRange(location: min(selectedRange.location, uiView.attributedText.length), length: 0)
            uiView.typingAttributes = bodyTypingAttributes()
            refreshScrollingLayout(for: uiView)
        }
    }

    private func refreshScrollingLayout(for textView: UITextView) {
        Task { @MainActor [weak textView] in
            guard let textView else {
                return
            }

            textView.layoutManager.ensureLayout(for: textView.textContainer)
            textView.invalidateIntrinsicContentSize()
            textView.setNeedsLayout()
            textView.layoutIfNeeded()

            // Toggling scrolling forces UITextView to recalculate its scrollable range
            // before the keyboard appears, which keeps freshly opened notes scrollable.
            textView.isScrollEnabled = false
            textView.isScrollEnabled = true
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            controller: controller,
            onOpenLink: onOpenLink,
            onPullToRevealSearch: onPullToRevealSearch
        )
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        @Binding var text: NSAttributedString
        let controller: RichTextEditorController
        let onOpenLink: (URL) -> Void
        let onPullToRevealSearch: () -> Void
        var isApplyingSwiftUIUpdate = false
        private var crossedSearchRevealThreshold = false
        private var hasTriggeredSearchReveal = false

        init(
            text: Binding<NSAttributedString>,
            controller: RichTextEditorController,
            onOpenLink: @escaping (URL) -> Void,
            onPullToRevealSearch: @escaping () -> Void
        ) {
            _text = text
            self.controller = controller
            self.onOpenLink = onOpenLink
            self.onPullToRevealSearch = onPullToRevealSearch
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingSwiftUIUpdate else {
                return
            }

            text = editorReadableText(strippedSearchHighlights(from: textView.attributedText))
            refreshFormatStateLater(from: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplyingSwiftUIUpdate else {
                return
            }

            refreshFormatStateLater(from: textView)
        }

        func textView(
            _ textView: UITextView,
            primaryActionFor textItem: UITextItem,
            defaultAction: UIAction
        ) -> UIAction? {
            guard case .link(let url) = textItem.content else {
                return defaultAction
            }

            return UIAction { [onOpenLink] _ in
                onOpenLink(url)
            }
        }

        func refreshFormatStateLater(from textView: UITextView) {
            Task { @MainActor [weak textView] in
                guard let textView else {
                    return
                }

                self.controller.refreshFormatState(from: textView)
            }
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            guard text == "\n" else {
                return true
            }
            return !controller.handleReturn(in: range)
        }

        @objc func handleChecklistTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let textView = recognizer.view as? UITextView else {
                return
            }

            if controller.toggleChecklistMarker(at: recognizer.location(in: textView), in: textView) {
                textView.resignFirstResponder()
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            false
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let textView = gestureRecognizer.view as? UITextView else {
                return false
            }

            return controller.isChecklistTapTarget(at: touch.location(in: textView), in: textView)
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            crossedSearchRevealThreshold = false
            hasTriggeredSearchReveal = false
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if scrollView.contentOffset.y > -20 {
                crossedSearchRevealThreshold = false
                hasTriggeredSearchReveal = false
            }

            guard scrollView.isDragging, scrollView.contentOffset.y < -52 else {
                return
            }

            crossedSearchRevealThreshold = true
            revealSearchIfNeeded()
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            guard !decelerate else {
                return
            }

            revealSearchIfNeeded()
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            revealSearchIfNeeded()
        }

        private func revealSearchIfNeeded() {
            guard crossedSearchRevealThreshold, !hasTriggeredSearchReveal else {
                return
            }

            hasTriggeredSearchReveal = true
            onPullToRevealSearch()
        }
    }
}

struct RichTextFormatState: Equatable {
    var isBold = false
    var isItalic = false
    var isUnderline = false
    var isHeader = false
}

@MainActor
final class RichTextEditorController: ObservableObject {
    @Published private(set) var formatState = RichTextFormatState()
    @Published private(set) var searchResultCount = 0
    @Published private(set) var currentSearchResultIndex: Int?
    private weak var textView: UITextView?
    private var searchQuery = ""
    private var searchRanges: [NSRange] = []
    private var activeSearchIndex: Int?
    private var delayedChecklistReorderTask: Task<Void, Never>?

    func attach(textView: UITextView) {
        attach(textView: textView, refreshImmediately: true)
    }

    func attach(textView: UITextView, refreshImmediately: Bool) {
        self.textView = textView
        if refreshImmediately {
            refreshFormatState(from: textView)
        }
        refreshSearchHighlights(in: textView)
    }

    func toggleBold() {
        toggleInlineTrait(.traitBold)
    }

    func toggleItalic() {
        toggleInlineTrait(.traitItalic)
    }

    func toggleUnderline() {
        guard let textView else {
            return
        }

        let range = textView.selectedRange
        guard range.length > 0 else {
            var attributes = currentTypingAttributes(in: textView)
            let current = attributes[.underlineStyle] as? Int ?? 0
            attributes[.underlineStyle] = current == 0 ? NSUnderlineStyle.single.rawValue : 0
            textView.typingAttributes = attributes
            refreshFormatState(from: textView)
            textView.becomeFirstResponder()
            return
        }

        mutate { mutable, range, _ in
            let applyRange = effectiveRange(for: range, in: mutable)
            let current = mutable.attribute(.underlineStyle, at: applyRange.location, effectiveRange: nil) as? Int ?? 0
            let next = current == 0 ? NSUnderlineStyle.single.rawValue : 0
            mutable.addAttribute(.underlineStyle, value: next, range: applyRange)
            return applyRange
        }
    }

    func adjustFontSize(delta: CGFloat) {
        guard let textView else {
            return
        }

        let selection = textView.selectedRange
        guard selection.length > 0 else {
            var attributes = currentTypingAttributes(in: textView)
            let current = attributes[.font] as? UIFont ?? currentFont(in: textView)
            attributes[.font] = resizedFont(current, delta: delta)
            textView.typingAttributes = attributes
            refreshFormatState(from: textView)
            textView.becomeFirstResponder()
            return
        }

        mutate { mutable, range, _ in
            let applyRange = effectiveRange(for: range, in: mutable)
            mutable.enumerateAttribute(.font, in: applyRange) { value, subrange, _ in
                let font = value as? UIFont ?? bodyFont()
                mutable.addAttribute(.font, value: resizedFont(font, delta: delta), range: subrange)
            }
            return applyRange
        }
    }

    func toggleHeader() {
        guard let textView else {
            return
        }

        let shouldApplyHeader = !formatState.isHeader
        let mutable = NSMutableAttributedString(attributedString: textView.attributedText ?? NSAttributedString(string: ""))
        let fullString = mutable.string as NSString
        let selectedRange = textView.selectedRange
        let safeLocation = min(selectedRange.location, fullString.length)
        let paragraphRange = fullString.paragraphRange(for: NSRange(location: safeLocation, length: selectedRange.length))
        let currentFont = currentFont(in: textView)
        let nextFont = shouldApplyHeader ? headerFont(preserving: currentFont) : bodyFont(preserving: currentFont)

        if paragraphRange.length > 0 {
            mutable.addAttribute(.font, value: nextFont, range: paragraphRange)
            update(textView: textView, with: mutable, selectedRange: selectedRange)
        } else {
            var attributes = currentTypingAttributes(in: textView)
            attributes[.font] = nextFont
            textView.typingAttributes = attributes
            refreshFormatState(from: textView)
        }
        textView.becomeFirstResponder()
    }

    func applyBullets() {
        applyLinePrefixes { lines in
            lines.map { line in
                line.hasPrefix("• ") ? line : "• \(line)"
            }
        }
    }

    func applyNumbering() {
        applyLinePrefixes { lines in
            lines.enumerated().map { index, line in
                "\(index + 1). \(line)"
            }
        }
    }

    func applyChecklist() {
        applyLinePrefixes { lines in
            lines.map { self.checklistLine(from: $0) }
        }
    }

    func applyTag(_ rawTag: String) throws {
        let tag = NotesStore.normalizeTag(rawTag)
        guard !tag.isEmpty else {
            throw NotesServiceError.invalidLink
        }

        mutate { mutable, range, _ in
            let fullNSString = mutable.string as NSString
            let targetRange = lineContentRange(containing: range.location, in: fullNSString)
            let selectedText = fullNSString.substring(with: targetRange)
            let lineComponents = taggedLineComponents(for: selectedText)
            let trimmedPrefix = lineComponents.content.replacingOccurrences(
                of: #"^#[A-Za-z0-9\-_]+:\s*"#,
                with: "",
                options: .regularExpression
            )
            let normalizedText = trimmedPrefix.trimmingCharacters(in: .whitespaces)
            let replacementContent = normalizedText.isEmpty ? "#\(tag): " : "#\(tag): \(normalizedText)"
            let replacement = lineComponents.leadingWhitespace + lineComponents.listPrefix + replacementContent
            let replacementAttributes = lineAttributes(forReplacementOf: targetRange, in: mutable)
            mutable.replaceCharacters(
                in: targetRange,
                with: NSAttributedString(string: replacement, attributes: replacementAttributes)
            )
            let updatedRange = NSRange(location: targetRange.location, length: (replacement as NSString).length)
            applyListParagraphStyle(to: mutable, range: updatedRange)
            return updatedRange
        }
    }

    func handleReturn(in range: NSRange) -> Bool {
        guard let textView else {
            return false
        }

        let mutable = NSMutableAttributedString(attributedString: textView.attributedText ?? NSAttributedString(string: ""))
        let fullString = mutable.string as NSString
        let safeLocation = min(range.location, fullString.length)
        let paragraphRange = fullString.paragraphRange(for: NSRange(location: safeLocation, length: 0))
        let paragraphText = fullString.substring(with: paragraphRange).trimmingCharacters(in: .newlines)

        guard let listInfo = listPrefixInfo(for: paragraphText) else {
            mutable.replaceCharacters(in: range, with: NSAttributedString(string: "\n", attributes: bodyTypingAttributes()))
            let insertedLocation = range.location + 1
            update(textView: textView, with: mutable, selectedRange: NSRange(location: insertedLocation, length: 0))
            textView.typingAttributes = bodyTypingAttributes()
            refreshFormatState(from: textView)
            return true
        }

        if listInfo.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            mutable.deleteCharacters(in: NSRange(location: paragraphRange.location, length: min(listInfo.prefixLength, paragraphRange.length)))
            clearParagraphStyle(in: mutable, around: paragraphRange.location)
            update(textView: textView, with: mutable, selectedRange: NSRange(location: paragraphRange.location, length: 0))
            textView.typingAttributes = bodyTypingAttributes()
            refreshFormatState(from: textView)
            return true
        }

        let insertion = "\n\(listInfo.nextPrefix)"
        mutable.replaceCharacters(in: range, with: NSAttributedString(string: insertion, attributes: bodyTypingAttributes()))
        let insertedLocation = range.location + (insertion as NSString).length
        let updatedString = mutable.string as NSString
        let previousParagraph = updatedString.paragraphRange(for: NSRange(location: max(0, range.location), length: 0))
        let nextParagraph = updatedString.paragraphRange(for: NSRange(location: min(insertedLocation, updatedString.length), length: 0))
        applyListParagraphStyle(to: mutable, range: previousParagraph)
        applyListParagraphStyle(to: mutable, range: nextParagraph)
        update(textView: textView, with: mutable, selectedRange: NSRange(location: insertedLocation, length: 0))
        textView.typingAttributes = bodyTypingAttributes()
        refreshFormatState(from: textView)
        return true
    }

    func toggleChecklistMarker(at location: CGPoint, in textView: UITextView) -> Bool {
        guard let hitTarget = checklistHitTarget(at: location, in: textView) else {
            return false
        }

        let mutable = NSMutableAttributedString(attributedString: textView.attributedText ?? NSAttributedString(string: ""))
        let paragraphText = hitTarget.paragraphText
        let marker: String
        let replacement: String
        let isCompletingItem: Bool

        if paragraphText.hasPrefix("○ ") {
            marker = "○ "
            replacement = "● "
            isCompletingItem = true
        } else if paragraphText.hasPrefix("● ") {
            marker = "● "
            replacement = "○ "
            isCompletingItem = false
        } else if paragraphText.hasPrefix("- [ ] ") {
            marker = "- [ ] "
            replacement = "● "
            isCompletingItem = true
        } else if paragraphText.hasPrefix("- [x] ") {
            marker = "- [x] "
            replacement = "○ "
            isCompletingItem = false
        } else {
            return false
        }

        replaceChecklistMarker(in: mutable, paragraphRange: hitTarget.paragraphRange, from: marker, to: replacement)
        if isCompletingItem {
            update(textView: textView, with: mutable, selectedRange: textView.selectedRange)
            scheduleDelayedChecklistReorder(in: textView)
        } else {
            reorderChecklistBlocks(in: mutable)
            update(textView: textView, with: mutable, selectedRange: textView.selectedRange)
        }
        return true
    }

    func isChecklistTapTarget(at location: CGPoint, in textView: UITextView) -> Bool {
        checklistHitTarget(at: location, in: textView) != nil
    }

    func applyLink(_ rawValue: String) throws {
        guard self.textView != nil else {
            return
        }

        var trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NotesServiceError.invalidLink
        }

        if !trimmed.contains("://") {
            trimmed = "https://\(trimmed)"
        }

        guard let url = URL(string: trimmed) else {
            throw NotesServiceError.invalidLink
        }

        mutate { mutable, range, activeTextView in
            if range.length == 0 {
                let baseAttributes = currentTypingAttributes(in: activeTextView)
                let linkText = NSMutableAttributedString(
                    string: trimmed,
                    attributes: baseAttributes.merging([
                        .link: url,
                        .foregroundColor: UIColor(HankTheme.accent)
                    ]) { _, new in new }
                )
                mutable.insert(linkText, at: range.location)
                return NSRange(location: range.location + linkText.length, length: 0)
            }

            mutable.addAttribute(.link, value: url, range: range)
            mutable.addAttribute(.foregroundColor, value: UIColor(HankTheme.accent), range: range)
            return range
        }
    }

    func applyLinkFromSelectedTextIfPossible() throws -> Bool {
        guard let textView else {
            return false
        }

        let selection = textView.selectedRange
        guard selection.length > 0, selection.location != NSNotFound else {
            return false
        }

        let selectedText = (textView.attributedText.string as NSString).substring(with: selection)
        guard normalizedLinkIfWholeString(selectedText) != nil else {
            return false
        }

        try applyLink(selectedText)
        return true
    }

    func updateSearchQuery(_ query: String) {
        searchQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        refreshSearchHighlights()
    }

    func focusNextSearchResult() {
        guard !searchRanges.isEmpty else {
            return
        }
        let nextIndex = ((activeSearchIndex ?? -1) + 1) % searchRanges.count
        focusSearchResult(at: nextIndex)
    }

    func focusPreviousSearchResult() {
        guard !searchRanges.isEmpty else {
            return
        }
        let previousIndex = ((activeSearchIndex ?? 0) - 1 + searchRanges.count) % searchRanges.count
        focusSearchResult(at: previousIndex)
    }

    func refreshFormatState(from suppliedTextView: UITextView? = nil) {
        guard let textView = suppliedTextView ?? textView else {
            setFormatState(RichTextFormatState())
            return
        }

        let attributes = effectiveAttributes(in: textView)
        let font = attributes[.font] as? UIFont ?? bodyFont()
        let underline = attributes[.underlineStyle] as? Int ?? 0
        setFormatState(RichTextFormatState(
            isBold: font.fontDescriptor.symbolicTraits.contains(.traitBold),
            isItalic: font.fontDescriptor.symbolicTraits.contains(.traitItalic),
            isUnderline: underline != 0,
            isHeader: isHeaderFont(font)
        ))
    }

    private func focusSearchResult(at index: Int) {
        guard let textView, searchRanges.indices.contains(index) else {
            return
        }
        activeSearchIndex = index
        updatePublishedSearchState(count: searchRanges.count, index: index)
        refreshSearchHighlights(in: textView)
        textView.scrollRangeToVisible(searchRanges[index])
    }

        private func setFormatState(_ nextState: RichTextFormatState) {
            guard formatState != nextState else {
                return
            }

            formatState = nextState
        }

    private func toggleInlineTrait(_ trait: UIFontDescriptor.SymbolicTraits) {
        guard let textView else {
            return
        }

        let range = textView.selectedRange
        guard range.length > 0 else {
            var attributes = currentTypingAttributes(in: textView)
            let currentFont = attributes[.font] as? UIFont ?? currentFont(in: textView)
            attributes[.font] = toggledFont(from: currentFont, trait: trait)
            textView.typingAttributes = attributes
            refreshFormatState(from: textView)
            textView.becomeFirstResponder()
            return
        }

        mutate { mutable, range, _ in
            let applyRange = effectiveRange(for: range, in: mutable)
            mutable.enumerateAttribute(.font, in: applyRange) { value, subrange, _ in
                let currentFont = value as? UIFont ?? bodyFont()
                mutable.addAttribute(.font, value: toggledFont(from: currentFont, trait: trait), range: subrange)
            }
            return applyRange
        }
    }

    private func applyLinePrefixes(_ transform: ([String]) -> [String]) {
        mutate { mutable, range, _ in
            let fullNSString = mutable.string as NSString
            let targetRange = paragraphRange(for: range, in: fullNSString)
            let selectedText = fullNSString.substring(with: targetRange)
            let lines = selectedText.components(separatedBy: "\n")
            let updatedLines = transform(lines)
            let replacement = updatedLines.joined(separator: "\n")
            mutable.replaceCharacters(in: targetRange, with: NSAttributedString(string: replacement, attributes: bodyTypingAttributes()))
            let updatedRange = NSRange(location: targetRange.location, length: (replacement as NSString).length)
            applyListParagraphStyle(to: mutable, range: updatedRange)
            return collapsedSelectionAfterApplyingLinePrefixes(
                originalSelection: range,
                targetRange: targetRange,
                originalLines: lines,
                updatedLines: updatedLines,
                replacementLength: updatedRange.length
            ) ?? updatedRange
        }
    }

    private func refreshSearchHighlights(in suppliedTextView: UITextView? = nil) {
        guard let textView = suppliedTextView ?? textView else {
            searchRanges = []
            updatePublishedSearchState(count: 0, index: nil)
            return
        }

        let textStorage = textView.textStorage
        textStorage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: textStorage.length))

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, textView.attributedText.length > 0 else {
            searchRanges = []
            activeSearchIndex = nil
            updatePublishedSearchState(count: 0, index: nil)
            return
        }

        let string = textView.attributedText.string as NSString
        var matches: [NSRange] = []
        var searchRange = NSRange(location: 0, length: string.length)
        while searchRange.length > 0 {
            let found = string.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
            guard found.location != NSNotFound else {
                break
            }
            matches.append(found)
            let nextLocation = NSMaxRange(found)
            searchRange = NSRange(location: nextLocation, length: string.length - nextLocation)
        }

        searchRanges = matches
        if matches.isEmpty {
            activeSearchIndex = nil
            updatePublishedSearchState(count: 0, index: nil)
            return
        }

        if activeSearchIndex == nil || !(matches.indices.contains(activeSearchIndex ?? -1)) {
            activeSearchIndex = 0
        }
        updatePublishedSearchState(count: matches.count, index: activeSearchIndex)

        for (index, range) in matches.enumerated() {
            let color = index == activeSearchIndex ? UIColor.systemOrange.withAlphaComponent(0.45) : UIColor.systemYellow.withAlphaComponent(0.28)
            textStorage.addAttribute(.backgroundColor, value: color, range: range)
        }

        if let activeSearchIndex {
            textView.scrollRangeToVisible(matches[activeSearchIndex])
        }
    }

        private func updatePublishedSearchState(count: Int, index: Int?) {
            guard searchResultCount != count || currentSearchResultIndex != index else {
                return
            }

            searchResultCount = count
            currentSearchResultIndex = index
        }

    private func collapsedSelectionAfterApplyingLinePrefixes(
        originalSelection: NSRange,
        targetRange: NSRange,
        originalLines: [String],
        updatedLines: [String],
        replacementLength: Int
    ) -> NSRange? {
        guard originalSelection.length == 0, !updatedLines.isEmpty else {
            return nil
        }

        let localLocation = max(0, originalSelection.location - targetRange.location)
        let linePosition = linePosition(for: localLocation, in: originalLines)
        let originalLine = originalLines[linePosition.index]
        let updatedLine = updatedLines[min(linePosition.index, updatedLines.count - 1)]
        let originalPrefixLength = listPrefixInfo(for: originalLine)?.prefixLength ?? 0
        let updatedPrefixLength = listPrefixInfo(for: updatedLine)?.prefixLength ?? 0

        let adjustedColumn: Int
        if linePosition.column <= originalPrefixLength {
            adjustedColumn = updatedPrefixLength
        } else {
            adjustedColumn = linePosition.column + max(0, updatedPrefixLength - originalPrefixLength)
        }

        let updatedLocalLocation = min(
            replacementLength,
            offsetBeforeLine(at: linePosition.index, in: updatedLines) + adjustedColumn
        )
        return NSRange(location: targetRange.location + updatedLocalLocation, length: 0)
    }

    private func linePosition(for localLocation: Int, in lines: [String]) -> (index: Int, column: Int) {
        guard !lines.isEmpty else {
            return (0, 0)
        }

        var consumed = 0
        for (index, line) in lines.enumerated() {
            let lineLength = (line as NSString).length
            let nextConsumed = consumed + lineLength
            if localLocation <= nextConsumed {
                return (index, localLocation - consumed)
            }

            consumed = nextConsumed + 1
            if localLocation < consumed {
                let nextIndex = min(index + 1, lines.count - 1)
                return (nextIndex, 0)
            }
        }

        let lastIndex = lines.count - 1
        return (lastIndex, (lines[lastIndex] as NSString).length)
    }

    private func offsetBeforeLine(at index: Int, in lines: [String]) -> Int {
        guard index > 0 else {
            return 0
        }

        return lines[..<index].reduce(0) { partialResult, line in
            partialResult + (line as NSString).length + 1
        }
    }

    private func mutate(_ block: (NSMutableAttributedString, NSRange, UITextView) -> NSRange) {
        guard let textView else {
            return
        }

        delayedChecklistReorderTask?.cancel()
        let mutable = NSMutableAttributedString(attributedString: textView.attributedText ?? NSAttributedString(string: ""))
        let currentRange = textView.selectedRange
        let nextRange = block(mutable, currentRange, textView)
        textView.attributedText = mutable
        textView.selectedRange = boundedRange(nextRange, in: mutable)
        setTypingAttributesFromSelection(in: textView)
        textView.delegate?.textViewDidChange?(textView)
        refreshFormatState(from: textView)
        refreshSearchHighlights(in: textView)
        textView.becomeFirstResponder()
    }

    private func update(textView: UITextView, with mutable: NSMutableAttributedString, selectedRange: NSRange) {
        textView.attributedText = mutable
        textView.selectedRange = boundedRange(selectedRange, in: mutable)
        setTypingAttributesFromSelection(in: textView)
        textView.delegate?.textViewDidChange?(textView)
        refreshFormatState(from: textView)
        refreshSearchHighlights(in: textView)
    }

    private func scheduleDelayedChecklistReorder(in textView: UITextView) {
        delayedChecklistReorderTask?.cancel()
        delayedChecklistReorderTask = Task { @MainActor [weak self, weak textView] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, let textView, !Task.isCancelled else {
                return
            }

            let mutable = NSMutableAttributedString(attributedString: textView.attributedText ?? NSAttributedString(string: ""))
            self.reorderChecklistBlocks(in: mutable)
            self.update(textView: textView, with: mutable, selectedRange: textView.selectedRange)
            self.delayedChecklistReorderTask = nil
        }
    }

    private func reorderChecklistBlocks(in mutable: NSMutableAttributedString) {
        let fullString = mutable.string as NSString
        guard fullString.length > 0 else {
            return
        }

        var replacements: [(NSRange, NSAttributedString)] = []
        var location = 0
        while location < fullString.length {
            let paragraphRange = fullString.paragraphRange(for: NSRange(location: location, length: 0))
            let paragraphText = fullString.substring(with: paragraphRange)
            if !isChecklistParagraph(paragraphText) {
                location = NSMaxRange(paragraphRange)
                continue
            }

            let blockRanges = checklistBlockRanges(containing: paragraphRange, in: fullString)
            let blockRange = NSRange(
                location: blockRanges.first?.location ?? paragraphRange.location,
                length: (blockRanges.last.map { NSMaxRange($0) } ?? NSMaxRange(paragraphRange)) - (blockRanges.first?.location ?? paragraphRange.location)
            )
            let items = blockRanges.map { range in
                NSMutableAttributedString(attributedString: mutable.attributedSubstring(from: range))
            }
            let combined = NSMutableAttributedString()
            for paragraph in reorderChecklistParagraphs(items) {
                combined.append(paragraph)
            }
            replacements.append((blockRange, combined))
            location = NSMaxRange(blockRange)
        }

        for (range, replacement) in replacements.reversed() {
            mutable.replaceCharacters(in: range, with: replacement)
        }
    }

    private func listPrefixInfo(for paragraphText: String) -> (prefixLength: Int, nextPrefix: String, content: String)? {
        if paragraphText.hasPrefix("• ") {
            return (2, "• ", String(paragraphText.dropFirst(2)))
        }

        if paragraphText.hasPrefix("○ ") || paragraphText.hasPrefix("● ") {
            return (2, "○ ", String(paragraphText.dropFirst(2)))
        }

        if paragraphText.hasPrefix("- [ ] ") || paragraphText.hasPrefix("- [x] ") {
            return (6, "○ ", String(paragraphText.dropFirst(6)))
        }

        let nsText = paragraphText as NSString
        guard let match = try? NSRegularExpression(pattern: #"^(\d+)\. "#).firstMatch(
            in: paragraphText,
            range: NSRange(location: 0, length: nsText.length)
        ) else {
            return nil
        }

        let numberRange = match.range(at: 1)
        guard numberRange.location != NSNotFound, let currentNumber = Int(nsText.substring(with: numberRange)) else {
            return nil
        }

        let prefixRange = match.range(at: 0)
        let prefixLength = prefixRange.length
        return (prefixLength, "\(currentNumber + 1). ", String(paragraphText.dropFirst(prefixLength)))
    }

    private func checklistLine(from line: String) -> String {
        let components = taggedLineComponents(for: line)
        let content = strippedNestedChecklistMarkers(from: components.content)
            .trimmingCharacters(in: .whitespaces)
        let normalizedPrefix = components.listPrefix.lowercased()

        if normalizedPrefix.hasPrefix("● ") || normalizedPrefix.hasPrefix("- [x] ") {
            return "● \(content)"
        }

        return "○ \(content)"
    }

    private func strippedNestedChecklistMarkers(from rawContent: String) -> String {
        var content = rawContent
        while true {
            let leadingWhitespace = content.prefix { $0 == " " || $0 == "\t" }
            let remainder = String(content.dropFirst(leadingWhitespace.count))
            if remainder.hasPrefix("○ ") || remainder.hasPrefix("● ") {
                content = String(leadingWhitespace) + String(remainder.dropFirst(2))
                continue
            }
            if remainder.hasPrefix("- [ ] ") || remainder.hasPrefix("- [x] ") || remainder.hasPrefix("- [X] ") {
                content = String(leadingWhitespace) + String(remainder.dropFirst(6))
                continue
            }
            return content
        }
    }

    private func hasChecklistContent(_ paragraphText: String) -> Bool {
        guard let listInfo = listPrefixInfo(for: paragraphText) else {
            return false
        }

        return !strippedNestedChecklistMarkers(from: listInfo.content)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    private func applyListParagraphStyle(to mutable: NSMutableAttributedString, range: NSRange) {
        guard range.length > 0 else {
            return
        }

        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 0
        style.headIndent = 28
        style.paragraphSpacing = 4
        mutable.addAttribute(.paragraphStyle, value: style, range: range)
    }

    private func clearParagraphStyle(in mutable: NSMutableAttributedString, around location: Int) {
        guard mutable.length > 0 else {
            return
        }

        let fullString = mutable.string as NSString
        let safeLocation = min(location, max(0, fullString.length - 1))
        let range = fullString.paragraphRange(for: NSRange(location: safeLocation, length: 0))
        mutable.removeAttribute(.paragraphStyle, range: range)
    }

    private func lineContentRange(containing location: Int, in string: NSString) -> NSRange {
        guard string.length > 0 else {
            return NSRange(location: 0, length: 0)
        }

        let boundedLocation = min(max(0, location), string.length)
        let safeLocation = boundedLocation == string.length ? max(0, boundedLocation - 1) : boundedLocation

        var start = safeLocation
        while start > 0, string.character(at: start - 1) != 10 {
            start -= 1
        }

        var end = safeLocation
        while end < string.length, string.character(at: end) != 10 {
            end += 1
        }

        return NSRange(location: start, length: end - start)
    }

    private func lineAttributes(forReplacementOf range: NSRange, in mutable: NSMutableAttributedString) -> [NSAttributedString.Key: Any] {
        guard mutable.length > 0 else {
            return bodyTypingAttributes()
        }

        let safeLocation = min(max(0, range.location), mutable.length - 1)
        return mutable.attributes(at: safeLocation, effectiveRange: nil)
    }

    private func taggedLineComponents(for line: String) -> (leadingWhitespace: String, listPrefix: String, content: String) {
        let leadingWhitespace = String(line.prefix { $0 == " " || $0 == "\t" })
        let remainder = String(line.dropFirst(leadingWhitespace.count))
        let nsRemainder = remainder as NSString

        if let match = try? NSRegularExpression(pattern: #"^(?:[-*•]\s+|\d+\.\s+|[○●]\s+|- \[[ xX]\]\s+)"#)
            .firstMatch(in: remainder, range: NSRange(location: 0, length: nsRemainder.length)),
           match.range.location != NSNotFound {
            let prefix = nsRemainder.substring(with: match.range)
            let content = nsRemainder.substring(from: NSMaxRange(match.range))
            return (leadingWhitespace, prefix, content)
        }

        return (leadingWhitespace, "", remainder)
    }

    private func normalizedLinkIfWholeString(_ rawValue: String) -> URL? {
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
           match.range == range {
            return match.url
        }

        return nil
    }

    private func setTypingAttributesFromSelection(in textView: UITextView) {
        guard textView.attributedText.length > 0 else {
            textView.typingAttributes = bodyTypingAttributes()
            return
        }

        let location = min(textView.selectedRange.location, textView.attributedText.length - 1)
        textView.typingAttributes = textView.attributedText.attributes(at: location, effectiveRange: nil)
    }

    private func resizedFont(_ font: UIFont, delta: CGFloat) -> UIFont {
        UIFont(descriptor: font.fontDescriptor, size: min(42, max(10, font.pointSize + delta)))
    }

    private func checklistBlockRanges(containing paragraphRange: NSRange, in string: NSString) -> [NSRange] {
        var ranges: [NSRange] = [paragraphRange]

        var previousLocation = paragraphRange.location
        while previousLocation > 0 {
            let probeRange = string.paragraphRange(for: NSRange(location: max(0, previousLocation - 1), length: 0))
            if !isChecklistParagraph(string.substring(with: probeRange)) {
                break
            }
            ranges.insert(probeRange, at: 0)
            previousLocation = probeRange.location
        }

        var nextLocation = NSMaxRange(paragraphRange)
        while nextLocation < string.length {
            let probeRange = string.paragraphRange(for: NSRange(location: nextLocation, length: 0))
            if !isChecklistParagraph(string.substring(with: probeRange)) {
                break
            }
            ranges.append(probeRange)
            nextLocation = NSMaxRange(probeRange)
        }

        return ranges
    }

    private func isChecklistParagraph(_ paragraphText: String) -> Bool {
        paragraphText.hasPrefix("○ ") || paragraphText.hasPrefix("● ") || paragraphText.hasPrefix("- [ ] ") || paragraphText.hasPrefix("- [x] ")
    }

    private func checklistHitTarget(at location: CGPoint, in textView: UITextView) -> (paragraphRange: NSRange, paragraphText: String)? {
        let attributedText = textView.attributedText ?? NSAttributedString(string: "")
        let fullString = attributedText.string as NSString
        guard fullString.length > 0 else {
            return nil
        }

        let adjustedLocation = CGPoint(
            x: max(0, location.x - textView.textContainerInset.left),
            y: location.y + textView.contentOffset.y - textView.textContainerInset.top
        )
        let tappedCharacterIndex = textView.layoutManager.characterIndex(
            for: adjustedLocation,
            in: textView.textContainer,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        let safeTappedIndex = min(max(0, tappedCharacterIndex), fullString.length - 1)
        let tappedParagraphRange = fullString.paragraphRange(for: NSRange(location: safeTappedIndex, length: 0))
        let tappedParagraphText = fullString.substring(with: tappedParagraphRange)

        let gutterMaxX = textView.textContainerInset.left + 34
        if location.x >= 0, location.x <= gutterMaxX,
           let gutterPosition = textView.closestPosition(to: CGPoint(x: textView.textContainerInset.left + 8, y: location.y)) {
            let gutterIndex = min(textView.offset(from: textView.beginningOfDocument, to: gutterPosition), fullString.length - 1)
            let gutterParagraphRange = fullString.paragraphRange(for: NSRange(location: gutterIndex, length: 0))
            let gutterParagraphText = fullString.substring(with: gutterParagraphRange)
            if isChecklistParagraph(gutterParagraphText), hasChecklistContent(gutterParagraphText) {
                return (gutterParagraphRange, gutterParagraphText)
            }
        }

        guard isChecklistParagraph(tappedParagraphText), hasChecklistContent(tappedParagraphText) else {
            return nil
        }

        let markerLength = listPrefixInfo(for: tappedParagraphText)?.prefixLength ?? 0
        let markerRange = NSRange(location: tappedParagraphRange.location, length: markerLength)
        guard NSLocationInRange(safeTappedIndex, markerRange) else {
            return nil
        }

        return (tappedParagraphRange, tappedParagraphText)
    }

    private func replaceChecklistMarker(in mutable: NSMutableAttributedString, paragraphRange: NSRange, from marker: String, to replacement: String) {
        let replacementRange = NSRange(location: paragraphRange.location, length: (marker as NSString).length)
        let attributes = lineAttributes(forReplacementOf: paragraphRange, in: mutable)
        mutable.replaceCharacters(
            in: replacementRange,
            with: NSAttributedString(string: replacement, attributes: attributes)
        )
        let refreshedParagraphRange = (mutable.string as NSString).paragraphRange(for: NSRange(location: paragraphRange.location, length: 0))
        applyListParagraphStyle(to: mutable, range: refreshedParagraphRange)
    }

    private func reorderChecklistParagraphs(_ paragraphs: [NSMutableAttributedString]) -> [NSMutableAttributedString] {
        let openParagraphs = paragraphs.filter { !$0.string.hasPrefix("● ") && !$0.string.hasPrefix("- [x] ") }
        let completedParagraphs = paragraphs.filter { $0.string.hasPrefix("● ") || $0.string.hasPrefix("- [x] ") }
        return openParagraphs + completedParagraphs
    }
}

private struct NoteRowDropDelegate: DropDelegate {
    let targetNoteID: UUID
    let store: NotesStore
    @Binding var activeDropTargetID: UUID?

    func dropEntered(info: DropInfo) {
        activeDropTargetID = targetNoteID
    }

    func dropExited(info: DropInfo) {
        if activeDropTargetID == targetNoteID {
            activeDropTargetID = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [UTType.text.identifier]).first else {
            return false
        }
        activeDropTargetID = nil
        let dropPlacement = placement(for: info.location)

        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let identifier = object as? NSString, let noteID = UUID(uuidString: identifier as String) else {
                return
            }
            Task { @MainActor in
                store.moveDraggedNote(
                    noteID,
                    relativeTo: targetNoteID,
                    placement: dropPlacement
                )
            }
        }

        return true
    }

    private func placement(for location: CGPoint) -> NoteDropPlacement {
        if location.y < 14 {
            return .before
        }
        if location.y > 40 {
            return .after
        }
        return .inside
    }
}

private struct KanbanColumnDropDelegate: DropDelegate {
    let store: NotesStore
    let targetColumnID: UUID

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [UTType.text.identifier]).first else {
            return false
        }

        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let payload = object as? NSString else {
                return
            }
            let value = payload as String
            guard value.hasPrefix("column:"),
                  let columnID = UUID(uuidString: String(value.dropFirst("column:".count))) else {
                return
            }
            Task { @MainActor in
                store.moveKanbanColumn(columnID, before: targetColumnID)
            }
        }

        return true
    }
}

private struct KanbanCardDropDelegate: DropDelegate {
    let store: NotesStore
    let targetColumnID: UUID
    let targetCardID: UUID?

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [UTType.text.identifier]).first else {
            return false
        }

        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let payload = object as? NSString else {
                return
            }
            let value = payload as String
            guard value.hasPrefix("card:") else {
                return
            }
            let components = value.components(separatedBy: ":")
            guard components.count == 3, let cardID = UUID(uuidString: components[2]) else {
                return
            }
            Task { @MainActor in
                store.moveKanbanCard(cardID, to: targetColumnID, before: targetCardID)
            }
        }

        return true
    }
}


private func effectiveRange(for selectedRange: NSRange, in attributedText: NSAttributedString) -> NSRange {
    selectedRange.length > 0 ? selectedRange : NSRange(location: selectedRange.location, length: 0)
}

private func paragraphRange(for selectedRange: NSRange, in string: NSString) -> NSRange {
    string.paragraphRange(for: selectedRange)
}

private func boundedRange(_ range: NSRange, in attributedText: NSAttributedString) -> NSRange {
    let location = min(max(0, range.location), attributedText.length)
    let length = min(max(0, range.length), max(0, attributedText.length - location))
    return NSRange(location: location, length: length)
}

@MainActor
private func effectiveAttributes(in textView: UITextView) -> [NSAttributedString.Key: Any] {
    let selectedRange = textView.selectedRange
    if selectedRange.length == 0, !textView.typingAttributes.isEmpty {
        return normalizedAttributes(textView.typingAttributes)
    }

    guard textView.attributedText.length > 0 else {
        return bodyTypingAttributes()
    }

    let location = min(selectedRange.location, textView.attributedText.length - 1)
    return normalizedAttributes(textView.attributedText.attributes(at: location, effectiveRange: nil))
}

@MainActor
private func currentTypingAttributes(in textView: UITextView) -> [NSAttributedString.Key: Any] {
    if !textView.typingAttributes.isEmpty {
        return normalizedAttributes(textView.typingAttributes)
    }
    return effectiveAttributes(in: textView)
}

@MainActor
private func currentFont(in textView: UITextView) -> UIFont {
    (effectiveAttributes(in: textView)[.font] as? UIFont) ?? bodyFont()
}

private func normalizedAttributes(_ attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
    var normalized = attributes
    if normalized[.font] == nil {
        normalized[.font] = bodyFont()
    }
    normalized[.foregroundColor] = UIColor.white
    return normalized
}

private func strippedSearchHighlights(from attributedText: NSAttributedString) -> NSAttributedString {
    let mutable = NSMutableAttributedString(attributedString: attributedText)
    mutable.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: mutable.length))
    return mutable
}

private func editorReadableText(_ attributedText: NSAttributedString) -> NSAttributedString {
    guard attributedText.length > 0 else {
        return attributedText
    }

    let mutable = NSMutableAttributedString(attributedString: attributedText)
    let fullRange = NSRange(location: 0, length: mutable.length)
    mutable.enumerateAttributes(in: fullRange) { attributes, range, _ in
        if attributes[.font] == nil {
            mutable.addAttribute(.font, value: bodyFont(), range: range)
        }
        mutable.addAttribute(.foregroundColor, value: UIColor.white, range: range)
    }
    return mutable
}

private func bodyTypingAttributes() -> [NSAttributedString.Key: Any] {
    [
        .font: bodyFont(),
        .foregroundColor: UIColor.white
    ]
}

private struct NoteAttachmentPreview: Identifiable {
    let id = UUID()
    let url: URL
}

private func bodyFont(preserving font: UIFont? = nil) -> UIFont {
    fontWithBase(.preferredFont(forTextStyle: .body), preserving: font, forceBold: false)
}

private func headerFont(preserving font: UIFont? = nil) -> UIFont {
    fontWithBase(.systemFont(ofSize: 28, weight: .bold), preserving: font, forceBold: true)
}

private func fontWithBase(_ baseFont: UIFont, preserving font: UIFont?, forceBold: Bool) -> UIFont {
    var traits = font?.fontDescriptor.symbolicTraits.intersection([.traitBold, .traitItalic]) ?? []
    if forceBold {
        traits.insert(.traitBold)
    }
    let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits) ?? baseFont.fontDescriptor
    return UIFont(descriptor: descriptor, size: baseFont.pointSize)
}

private func isHeaderFont(_ font: UIFont) -> Bool {
    font.pointSize >= 24
}

private func toggledFont(from font: UIFont, trait: UIFontDescriptor.SymbolicTraits) -> UIFont {
    var traits = font.fontDescriptor.symbolicTraits
    if traits.contains(trait) {
        traits.remove(trait)
    } else {
        traits.insert(trait)
    }

    let descriptor = font.fontDescriptor.withSymbolicTraits(traits) ?? font.fontDescriptor
    return UIFont(descriptor: descriptor, size: font.pointSize)
}
