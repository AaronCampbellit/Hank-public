import PDFKit
import QuickLook
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UIKit

private enum FileServerPane: String, CaseIterable, Identifiable {
    case smb
    case iphone

    var id: Self { self }

    var title: String {
        switch self {
        case .smb:
            "SMB"
        case .iphone:
            "iPhone Files"
        }
    }
}

struct FileBrowserView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var services: AppServices
    @ObservedObject var store: FileBrowserStore
    @State private var incomingPaneOffset: CGFloat = 0
    @State private var outgoingPaneOffset: CGFloat = 0
    @State private var outgoingPaneOpacity = 1.0
    @State private var isAnimatingPaneTransition = false
    @State private var paneAnimationTask: Task<Void, Never>?
    @State private var isShowingCreateFolderPrompt = false
    @State private var createFolderDraft = ""
    @State private var renameItem: SMBItem?
    @State private var renameDraft = ""
    @State private var isImportingFiles = false
    @State private var selectedPane: FileServerPane = .smb
    @State private var localFilesByArea: [LocalFileArea: [LocalFileItem]] = [:]
    @State private var iphonePreviewURL: URL?
    @State private var viewportWidth: CGFloat = 0

    var body: some View {
        NavigationStack {
            Group {
                if selectedPane == .iphone {
                    iphoneFilesPane
                } else {
                    switch store.connectionState {
                    case .needsSetup:
                        ContentUnavailableView(
                            "SMB Share Not Configured",
                            systemImage: "externaldrive.badge.plus",
                            description: Text("Set up your SMB host, share, and credentials in Settings.")
                        )
                        .hankScreenBackground()
                        .safeAreaInset(edge: .top) {
                            fileServerModePicker
                        }
                    case .connecting:
                        ProgressView("Connecting to SMB share…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .hankScreenBackground()
                            .safeAreaInset(edge: .top) {
                                fileServerModePicker
                            }
                    case .failed(let message):
                        ContentUnavailableView(
                            "File Server Unavailable",
                            systemImage: "wifi.exclamationmark",
                            description: Text(message)
                        )
                        .hankScreenBackground()
                        .safeAreaInset(edge: .top) {
                            fileServerModePicker
                        }
                    case .connected:
                        browserList
                    case .connections:
                        smbConnectionsPane
                    }
                }
            }
            .navigationTitle("File Server")
            .navigationBarTitleDisplayMode(.inline)
            .hankNavigationChrome()
            .hankScreenBackground()
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            viewportWidth = proxy.size.width
                        }
                        .onChange(of: proxy.size.width) { _, newWidth in
                            viewportWidth = newWidth
                        }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if selectedPane == .smb && !store.isSelectionMode {
                        if store.canNavigateUp {
                            Button {
                                Task {
                                    await store.navigateUp(services: services)
                                }
                            } label: {
                                Image(systemName: "chevron.left")
                                    .font(.headline.weight(.semibold))
                            }
                        } else if store.canReturnToConnectionsPage {
                            Button {
                                store.showConnectionsPage()
                            } label: {
                                Image(systemName: "chevron.left")
                                    .font(.headline.weight(.semibold))
                            }
                        }
                    }
                }

                ToolbarItem(placement: .principal) {
                    Button {
                        if store.isShowingConnectionsPage {
                            return
                        }

                        Task {
                            await store.navigateToRoot(services: services)
                        }
                    } label: {
                        VStack(spacing: 0) {
                            Text(navigationHeaderTitle)
                                .font(.headline)
                            if store.isSelectionMode {
                                Text("\(store.selectedCount) selected")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 4)
                            } else if selectedPane == .iphone {
                                Text("Browse imported iPhone files")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 4)
                            } else if store.isShowingConnectionsPage {
                                Text("Choose a connection")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 4)
                            } else {
                                BreadcrumbLabel(path: store.breadcrumb)
                                    .padding(.top, 6)
                            }
                        }
                        .frame(maxWidth: 240)
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedPane != .smb || store.isSelectionMode || store.currentPath.isEmpty || store.isShowingConnectionsPage)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    if selectedPane == .iphone {
                        Button {
                            isImportingFiles = true
                        } label: {
                            Label("Browse iPhone Files", systemImage: "folder")
                        }
                    } else if !store.isSelectionMode && !store.isShowingConnectionsPage {
                        Menu {
                            Button {
                                store.enterSelectionMode()
                            } label: {
                                Label("Select", systemImage: "checkmark.circle")
                            }

                            Button {
                                store.beginCameraCapture()
                            } label: {
                                Label("Camera", systemImage: "camera")
                            }

                            Button {
                                createFolderDraft = ""
                                isShowingCreateFolderPrompt = true
                            } label: {
                                Label("New Folder", systemImage: "folder.badge.plus")
                            }

                            Button {
                                isImportingFiles = true
                            } label: {
                                Label("Upload From iPhone Files…", systemImage: "doc.badge.plus")
                            }

                            Divider()

                            ForEach(FileBrowserStore.SortOption.allCases) { option in
                                Button {
                                    store.sortOption = option
                                } label: {
                                    Label(option.title, systemImage: store.sortOption == option ? "checkmark" : option.systemImage)
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.title3)
                        }
                        .disabled(store.isBatchOperationInProgress || store.isCameraUploadInProgress)
                    }
                }

            }
            .task(id: appState.profileLoadKey) {
                guard let profileID = appState.activeProfileID else {
                    return
                }
                await store.loadIfNeeded(profileID: profileID, modelContext: modelContext, services: services)
                loadLocalFiles()
            }
            .onAppear {
                guard let profileID = appState.activeProfileID else {
                    return
                }
                guard store.connectionState != .connecting else {
                    return
                }

                Task {
                    await store.loadIfNeeded(profileID: profileID, modelContext: modelContext, services: services)
                }
                loadLocalFiles()
            }
            .searchable(text: $store.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search folders and files")
            .task(id: store.searchText) {
                if selectedPane == .smb && !store.isShowingConnectionsPage {
                    await store.performSearch(services: services)
                }
            }
            .alert("New Folder", isPresented: $isShowingCreateFolderPrompt) {
                TextField("Folder name", text: $createFolderDraft)
                Button("Cancel", role: .cancel) {
                    createFolderDraft = ""
                }
                Button("Create") {
                    Task {
                        await store.createFolder(named: createFolderDraft, services: services)
                        createFolderDraft = ""
                    }
                }
            } message: {
                Text("Create a folder in the current SMB location.")
            }
            .alert("Rename", isPresented: Binding(
                get: { renameItem != nil },
                set: { isPresented in
                    if !isPresented {
                        renameItem = nil
                        renameDraft = ""
                    }
                }
            )) {
                TextField("Name", text: $renameDraft)
                Button("Cancel", role: .cancel) {
                    renameItem = nil
                    renameDraft = ""
                }
                Button("Rename") {
                    if let renameItem {
                        Task {
                            await store.rename(renameItem, to: renameDraft, services: services)
                            self.renameItem = nil
                            renameDraft = ""
                        }
                    }
                }
            } message: {
                Text("Rename this item on the SMB share.")
            }
            .fileImporter(
                isPresented: $isImportingFiles,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true,
                onCompletion: handleImportedFiles
            )
            .quickLookPreview($iphonePreviewURL)
            .sheet(item: $store.preview) { preview in
                FilePreviewScreen(preview: preview)
            }
            .sheet(item: $store.destinationPicker) { picker in
                DestinationPickerSheet(
                    state: picker,
                    startPath: store.currentPath,
                    rootPath: store.browserRootPath,
                    shareTitle: store.shareTitle,
                    store: store,
                    services: services
                ) { destinationPath in
                    Task {
                        switch picker.action {
                        case .copy:
                            await store.copySelected(to: destinationPath, services: services)
                        case .move:
                            await store.moveSelected(to: destinationPath, services: services)
                        }
                    }
                }
            }
            .sheet(item: $store.shareSheet, onDismiss: {
                store.clearShareSheet()
            }) { shareSheet in
                FileBrowserShareSheet(shareSheet: shareSheet) {
                    store.clearShareSheet()
                }
            }
            .fullScreenCover(item: $store.cameraSession) { _ in
                CameraCaptureScreen(
                    onCancel: {
                        store.cancelCameraCapture()
                    },
                    onCapture: { image in
                        Task {
                            await store.handleCapturedPhoto(image, services: services)
                        }
                    }
                )
                .ignoresSafeArea()
            }
            .confirmationDialog(
                "Delete Selected Items?",
                isPresented: $store.isShowingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    Task {
                        await store.deleteSelected(services: services)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Delete \(store.selectedCount) selected item\(store.selectedCount == 1 ? "" : "s") from the share?")
            }
            .confirmationDialog(
                "Photo Uploaded",
                isPresented: $store.isShowingTakeAnotherPhotoPrompt,
                titleVisibility: .visible
            ) {
                Button("Take Another") {
                    store.requestAnotherPhoto()
                }
                Button("Done", role: .cancel) {
                    store.finishCameraPrompt()
                }
            } message: {
                Text("Add another photo to this folder?")
            }
            .onChange(of: store.navigationRevision) { _, _ in
                animateBrowserSlide()
            }
            .onDisappear {
                paneAnimationTask?.cancel()
                paneAnimationTask = nil
            }
        }
    }

    private var navigationHeaderTitle: String {
        if selectedPane == .iphone {
            "iPhone Files"
        } else if store.isShowingConnectionsPage {
            "SMB Connections"
        } else {
            store.shareTitle
        }
    }

    private var fileServerModePicker: some View {
        Picker("File source", selection: fileServerPaneBinding) {
            ForEach(FileServerPane.allCases) { pane in
                Text(pane.title).tag(pane)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Color.clear)
        .padding(.horizontal, 10)
        .hankGlassCapsule(tint: HankTheme.accent.opacity(0.12))
    }

    private var fileServerPaneBinding: Binding<FileServerPane> {
        Binding(
            get: { selectedPane },
            set: { pane in
                selectedPane = pane
                if pane == .smb {
                    store.cancelSelection()
                    store.showConnectionsPage()
                }
            }
        )
    }

    private var browserList: some View {
        ZStack {
            if let snapshot = store.transitionSnapshot {
                paneScrollView(
                    items: snapshot.items,
                    showsErrorMessage: false,
                    isInteractive: false
                )
                .id("snapshot-\(snapshot.id)")
                .offset(x: effectiveOutgoingPaneOffset)
                .opacity(effectiveOutgoingPaneOpacity)
                .allowsHitTesting(false)
            }

            currentPaneScrollView
                .id("current-\(store.currentPath)-\(store.navigationRevision)")
                .offset(x: effectiveIncomingPaneOffset)
                .shadow(
                    color: store.transitionSnapshot == nil ? .clear : Color.black.opacity(0.12),
                    radius: 18,
                    x: 0,
                    y: 0
                )
        }
        .clipped()
        .overlay {
            if let overlayLabel {
                ProgressView(overlayLabel)
                    .controlSize(.large)
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .safeAreaInset(edge: .top) {
            fileServerModePicker
        }
        .safeAreaInset(edge: .bottom, spacing: 10) {
            if store.isSelectionMode {
                fileSelectionActionBar
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
    }

    private var fileSelectionActionBar: some View {
        HStack(spacing: 10) {
            fileSelectionAction("Copy", systemImage: "doc.on.doc") {
                store.beginDestinationAction(.copy)
            }

            fileSelectionAction("Move", systemImage: "folder") {
                store.beginDestinationAction(.move)
            }

            fileSelectionAction("Share", systemImage: "square.and.arrow.up") {
                Task {
                    await store.prepareShare(services: services)
                }
            }

            Button(role: .destructive) {
                store.promptForDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.headline.weight(.semibold))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .disabled(!store.hasSelection || store.isBatchOperationInProgress || store.isCameraUploadInProgress)

            Button("Cancel", role: .cancel) {
                store.cancelSelection()
            }
            .font(.callout.weight(.semibold))
            .buttonStyle(.plain)
            .disabled(store.isBatchOperationInProgress || store.isCameraUploadInProgress)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .hankGlassCapsule(tint: HankTheme.accent.opacity(0.16), interactive: true)
    }

    private func fileSelectionAction(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.headline.weight(.semibold))
                Text(title)
                    .font(.caption2.weight(.semibold))
            }
            .frame(width: 48, height: 42)
        }
        .buttonStyle(.plain)
        .disabled(!store.hasSelection || store.isBatchOperationInProgress || store.isCameraUploadInProgress)
    }

    private var iphoneFilesPane: some View {
        ScrollView {
            LazyVStack(spacing: HankMetrics.rowSpacing) {
                if localFilesByArea.values.flatMap({ $0 }).isEmpty {
                    ContentUnavailableView(
                        "Local Files",
                        systemImage: "folder",
                        description: Text("Import files once, then browse and upload them here without leaving Hank.")
                    )
                    .padding(.top, 24)

                    Button {
                        isImportingFiles = true
                    } label: {
                        Label("Import From Files…", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(HankTheme.accent)
                } else {
                    ForEach(LocalFileArea.allCases) { area in
                        let items = localFilesByArea[area] ?? []
                        if !items.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(area.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)

                                ForEach(items) { item in
                                    Button {
                                        iphonePreviewURL = item.url
                                    } label: {
                                        PhoneFileRow(item: item)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button {
                                            iphonePreviewURL = item.url
                                        } label: {
                                            Label("Open", systemImage: "doc.text.magnifyingglass")
                                        }
                                        Button {
                                            selectedPane = .smb
                                            Task {
                                                await store.uploadFiles(from: [item.url], services: services)
                                            }
                                        } label: {
                                            Label("Upload To SMB", systemImage: "externaldrive.badge.plus")
                                        }
                                        ShareLink(item: item.url) {
                                            Label("Share", systemImage: "square.and.arrow.up")
                                        }
                                        Button(role: .destructive) {
                                            removeLocalFile(item)
                                        } label: {
                                            Label("Remove", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Button {
                        isImportingFiles = true
                    } label: {
                        Label("Import More Files…", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .tint(HankTheme.accent)
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 20)
        }
        .safeAreaInset(edge: .top) {
            fileServerModePicker
        }
    }

    private var currentPaneScrollView: some View {
        paneScrollView(
            items: store.browserItems,
            showsErrorMessage: true,
            isInteractive: true
        )
        .refreshable {
            guard let profileID = appState.activeProfileID else {
                return
            }
            await store.refresh(profileID: profileID, modelContext: modelContext, services: services)
        }
    }

    private var smbConnectionsPane: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if let errorMessage = store.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(HankTheme.error)
                        .hankCard(fill: HankTheme.errorSurface, padding: 14)
                }

                if store.availableConnections.isEmpty {
                    ContentUnavailableView(
                        "No SMB Connections",
                        systemImage: "externaldrive.badge.plus",
                        description: Text("Add one or more SMB connections in Settings to browse them here.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 28)
                } else {
                    ForEach(store.availableConnections) { connection in
                        Button {
                            guard let profileID = appState.activeProfileID else {
                                return
                            }

                            Task {
                                await store.selectConnection(
                                    connection.id,
                                    profileID: profileID,
                                    modelContext: modelContext,
                                    services: services
                                )
                            }
                        } label: {
                            SMBConnectionRow(
                                connection: connection,
                                isActive: store.selectedConnectionID == connection.id && !store.isShowingConnectionsPage,
                                isLive: store.isConnectionLive(connection.id),
                                isLoading: store.isConnectionLoading(connection.id)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 20)
        }
        .safeAreaInset(edge: .top) {
            fileServerModePicker
        }
        .refreshable {
            guard let profileID = appState.activeProfileID else {
                return
            }
            await store.refresh(profileID: profileID, modelContext: modelContext, services: services)
        }
    }

    private func paneScrollView(
        items: [SMBItem],
        showsErrorMessage: Bool,
        isInteractive: Bool
    ) -> some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if showsErrorMessage, let errorMessage = store.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(HankTheme.error)
                        .hankCard(fill: HankTheme.errorSurface, padding: 14)
                }

                if showsErrorMessage, store.isSearching {
                    searchStatus
                }

                if items.isEmpty {
                    ContentUnavailableView(
                        "This Folder Is Empty",
                        systemImage: "folder",
                        description: Text(store.isSelectionMode ? "Choose another action or cancel selection mode." : "Pull to refresh or add files with the camera option.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 28)
                } else {
                    ForEach(items) { item in
                        Button {
                            guard isInteractive else {
                                return
                            }

                            if store.isSelectionMode {
                                store.toggleSelection(for: item)
                            } else {
                                Task {
                                    await store.open(item, services: services)
                                }
                            }
                        } label: {
                            FileBrowserItemRow(
                                item: item,
                                metadata: fileMetadata(for: item),
                                isSelectionMode: store.isSelectionMode && isInteractive,
                                isSelected: isInteractive && store.isSelected(item)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!isInteractive)
                        .onLongPressGesture(minimumDuration: 0.35) {
                            guard isInteractive else {
                                return
                            }
                            store.selectOnly(item)
                        }
                        .contextMenu {
                            Button {
                                store.selectOnly(item)
                            } label: {
                                Label("Select", systemImage: "checkmark.circle")
                            }
                            Button {
                                beginRename(item)
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            Button {
                                store.selectOnly(item)
                                store.beginDestinationAction(.copy)
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                            Button {
                                store.selectOnly(item)
                                store.beginDestinationAction(.move)
                            } label: {
                                Label("Move", systemImage: "folder")
                            }
                            Button {
                                Task {
                                    store.selectOnly(item)
                                    await store.prepareShare(services: services)
                                }
                            } label: {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            Button(role: .destructive) {
                                store.selectOnly(item)
                                store.promptForDelete()
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
        .scrollContentBackground(.hidden)
        .background(HankTheme.background)
    }

    private func animateBrowserSlide() {
        guard let snapshot = store.transitionSnapshot else {
            return
        }

        let width = max(viewportWidth, 1)
        let incomingStart = snapshot.direction == .forward ? width : -width
        let outgoingEnd = snapshot.direction == .forward ? -(width * 0.24) : width * 0.24

        paneAnimationTask?.cancel()
        isAnimatingPaneTransition = true
        incomingPaneOffset = incomingStart
        outgoingPaneOffset = 0
        outgoingPaneOpacity = 1

        paneAnimationTask = Task { @MainActor in
            await Task.yield()
            withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.9, blendDuration: 0.12)) {
                incomingPaneOffset = 0
                outgoingPaneOffset = outgoingEnd
                outgoingPaneOpacity = 0.26
            }

            try? await Task.sleep(for: .milliseconds(340))
            guard !Task.isCancelled else {
                return
            }

            store.completeNavigationTransition()
            isAnimatingPaneTransition = false
            outgoingPaneOffset = 0
            outgoingPaneOpacity = 1
        }
    }

    private var effectiveIncomingPaneOffset: CGFloat {
        guard let snapshot = store.transitionSnapshot else {
            return 0
        }

        if isAnimatingPaneTransition {
            return incomingPaneOffset
        }

        let width = max(viewportWidth, 1)
        return snapshot.direction == .forward ? width : -width
    }

    private var effectiveOutgoingPaneOffset: CGFloat {
        isAnimatingPaneTransition ? outgoingPaneOffset : 0
    }

    private var effectiveOutgoingPaneOpacity: CGFloat {
        isAnimatingPaneTransition ? outgoingPaneOpacity : 1
    }

    private var overlayLabel: String? {
        if store.isPreviewLoading {
            return "Preparing preview…"
        }

        if store.isCameraUploadInProgress {
            return "Uploading photo…"
        }

        if store.isBatchOperationInProgress {
            return "Working…"
        }

        return nil
    }

    @ViewBuilder
    private var searchStatus: some View {
        switch store.searchState {
        case .idle:
            EmptyView()
        case .indexing:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Indexing folders and files…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .hankCard(fill: HankTheme.surface, padding: 12)
        case .ready(let count):
            Text("\(count) result\(count == 1 ? "" : "s")")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .failed(let message):
            Text(message)
                .font(.footnote)
                .foregroundStyle(HankTheme.error)
                .hankCard(fill: HankTheme.errorSurface, padding: 12)
        }
    }

    private func beginRename(_ item: SMBItem) {
        store.selectOnly(item)
        renameItem = item
        renameDraft = item.name
    }

    private func loadLocalFiles() {
        do {
            var nextFilesByArea: [LocalFileArea: [LocalFileItem]] = [:]
            for area in LocalFileArea.allCases {
                nextFilesByArea[area] = try services.localFileService.list(area: area)
            }
            localFilesByArea = nextFilesByArea
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    private func handleImportedFiles(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            if selectedPane == .iphone {
                for url in urls {
                    let didStartAccess = url.startAccessingSecurityScopedResource()
                    defer {
                        if didStartAccess {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                    _ = try services.localFileService.importFile(at: url, to: .imported)
                }
                loadLocalFiles()
            } else {
                Task {
                    await store.uploadFiles(from: urls, services: services)
                }
            }
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    private func removeLocalFile(_ item: LocalFileItem) {
        do {
            try services.localFileService.remove(item)
            loadLocalFiles()
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    private func fileMetadata(for item: SMBItem) -> String? {
        var parts: [String] = []

        if let modifiedAt = item.modifiedAt {
            parts.append(modifiedAt.formatted(date: .abbreviated, time: .shortened))
        }

        if let size = item.size, !item.isDirectory {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }

        guard !parts.isEmpty else {
            return nil
        }

        return parts.joined(separator: " • ")
    }

    private var backSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .global)
            .onEnded { value in
                guard store.canNavigateUp else {
                    return
                }

                let isEdgeSwipe = value.startLocation.x < 32
                let isBackSwipe = value.translation.width > 90
                let isMostlyHorizontal = abs(value.translation.height) < 70

                guard isEdgeSwipe, isBackSwipe, isMostlyHorizontal else {
                    return
                }

                Task {
                    await store.navigateUp(services: services)
                }
            }
    }

    private var forwardSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .global)
            .onEnded { value in
                guard store.canNavigateForward else {
                    return
                }

                let screenWidth = max(viewportWidth, 1)
                let isEdgeSwipe = value.startLocation.x > screenWidth - 32
                let isForwardSwipe = value.translation.width < -90
                let isMostlyHorizontal = abs(value.translation.height) < 70

                guard isEdgeSwipe, isForwardSwipe, isMostlyHorizontal else {
                    return
                }

                Task {
                    await store.navigateForward(services: services)
                }
            }
    }
}

private struct FileBrowserItemRow: View {
    let item: SMBItem
    let metadata: String?
    let isSelectionMode: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 9) {
            if isSelectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? HankTheme.accent : Color.secondary.opacity(0.65))
            }

            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill((item.isDirectory ? HankTheme.folder : HankTheme.file).opacity(0.16))
                Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                    .foregroundStyle(item.isDirectory ? HankTheme.folder : HankTheme.file)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(item.isDirectory ? .body.weight(.semibold) : .body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let metadata {
                    Text(metadata)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if item.isDirectory && !isSelectionMode {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .hankCard(
            fill: isSelected ? HankTheme.accent.opacity(0.2) : HankTheme.surface,
            padding: 8
        )
    }
}

private struct SMBConnectionRow: View {
    let connection: SavedSMBConnectionSummary
    let isActive: Bool
    let isLive: Bool
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(HankTheme.folder.opacity(0.16))
                Image(systemName: "folder.fill")
                    .foregroundStyle(HankTheme.folder)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(connection.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if connection.isDefault {
                        Text("Default")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(HankTheme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(HankTheme.accent.opacity(0.14))
                            )
                    }
                }

                Text(connection.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else if isLive {
                Circle()
                    .fill(HankTheme.success)
                    .frame(width: 8, height: 8)
            }

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .hankCard(
            fill: isActive ? HankTheme.accent.opacity(0.2) : HankTheme.surface,
            padding: 8
        )
    }
}

private struct PhoneFileRow: View {
    let item: LocalFileItem

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: HankMetrics.cornerRadius, style: .continuous)
                    .fill((item.isDirectory ? HankTheme.folder : HankTheme.file).opacity(0.16))
                Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                    .foregroundStyle(item.isDirectory ? HankTheme.folder : HankTheme.file)
            }
            .frame(width: HankMetrics.iconSize, height: HankMetrics.iconSize)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name.isEmpty ? "Local File" : item.name)
                    .font(item.isDirectory ? .body.weight(.semibold) : .body)
                    .lineLimit(1)
                if let metadata = metadataText {
                    Text(metadata)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .hankCard(fill: HankTheme.surface, padding: HankMetrics.rowPadding)
    }

    private var metadataText: String? {
        var parts: [String] = []
        if let modifiedAt = item.modifiedAt {
            parts.append(modifiedAt.formatted(date: .abbreviated, time: .shortened))
        }
        if let size = item.size, !item.isDirectory {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }
}

private struct DestinationPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let state: FileBrowserDestinationPickerState
    let rootPath: String
    let shareTitle: String
    let store: FileBrowserStore
    let services: AppServices
    let onConfirm: (String) -> Void

    @State private var currentPath: String
    @State private var directories: [SMBItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    init(
        state: FileBrowserDestinationPickerState,
        startPath: String,
        rootPath: String,
        shareTitle: String,
        store: FileBrowserStore,
        services: AppServices,
        onConfirm: @escaping (String) -> Void
    ) {
        self.state = state
        self.rootPath = rootPath
        self.shareTitle = shareTitle
        self.store = store
        self.services = services
        self.onConfirm = onConfirm
        _currentPath = State(initialValue: startPath)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(HankTheme.error)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .hankCard(fill: HankTheme.errorSurface, padding: 14)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Destination")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(HankTheme.accent)

                    Text(currentFolderLabel)
                        .font(.callout.monospaced())
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("Choose a folder below or use this destination.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .hankCard(fill: HankTheme.surface)

                if canNavigateUp {
                    Button {
                        currentPath = FileBrowserPathing.parentPath(of: currentPath)
                    } label: {
                        Label("Up One Folder", systemImage: "chevron.left")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .hankCard(fill: HankTheme.surface, padding: 12)
                }

                Text("Folders")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                if isLoading {
                    ProgressView("Loading folders…")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .hankCard(fill: HankTheme.surface, padding: 14)
                } else if directories.isEmpty {
                    ContentUnavailableView(
                        "No Subfolders",
                        systemImage: "folder",
                        description: Text("Use the current destination or move up to another folder.")
                    )
                    .frame(maxWidth: .infinity)
                    .hankCard(fill: HankTheme.surface)
                } else {
                    ForEach(directories) { directory in
                        Button {
                            currentPath = directory.path
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(HankTheme.folder)
                                Text(directory.name)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .hankCard(fill: HankTheme.surface, padding: 12)
                    }
                }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(state.action.title + " To")
            .navigationBarTitleDisplayMode(.inline)
            .hankNavigationChrome()
            .hankScreenBackground()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button {
                    dismiss()
                    onConfirm(currentPath)
                } label: {
                    Text(state.action.title + " Here")
                        .font(.headline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(HankTheme.accent)
                .disabled(isLoading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task(id: currentPath) {
                await loadDirectories()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var currentFolderLabel: String {
        let normalizedPath = FileBrowserPathing.normalized(currentPath)
        return normalizedPath.isEmpty ? shareTitle : normalizedPath
    }

    private var canNavigateUp: Bool {
        FileBrowserPathing.normalized(currentPath) != FileBrowserPathing.normalized(rootPath)
    }

    @MainActor
    private func loadDirectories() async {
        isLoading = true
        defer { isLoading = false }

        do {
            directories = try await store.list(path: currentPath)
                .filter(\.isDirectory)
                .sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            errorMessage = nil
        } catch {
            directories = []
            errorMessage = error.localizedDescription
        }
    }
}

private struct BreadcrumbLabel: View {
    let path: String

    var body: some View {
        Group {
            if path.isEmpty {
                EmptyView()
            } else {
                GeometryReader { geometry in
                    Text(truncatedPath(maxWidth: geometry.size.width))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .frame(height: 16)
            }
        }
    }

    private func truncatedPath(maxWidth: CGFloat) -> String {
        guard !path.isEmpty else {
            return ""
        }

        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty else {
            return ""
        }

        let countsToTry = [3, 2, 1]

        for count in countsToTry {
            let visible = Array(components.suffix(count))
            let prefix = visible.count < components.count ? "…/" : ""
            let candidate = prefix + visible.joined(separator: "/")

            if measuredWidth(for: candidate) <= maxWidth || count == 1 {
                return candidate
            }
        }

        return components.last ?? ""
    }

    private func measuredWidth(for string: String) -> CGFloat {
        let font = UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
        return (string as NSString).size(withAttributes: [.font: font]).width
    }
}

private struct FilePreviewScreen: View {
    let preview: FilePreviewState

    var body: some View {
        NavigationStack {
            Group {
                switch preview.content {
                case .text(let text):
                    ScrollView {
                        Text(text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .font(.body.monospaced())
                            .padding()
                            .hankCard(fill: HankTheme.surface)
                            .padding()
                    }
                    .hankScreenBackground()
                case .image(let url):
                    QuickLookPreviewSurface(url: url)
                case .pdf(let url):
                    PDFKitView(url: url)
                        .hankScreenBackground()
                case .quickLookFile(let url):
                    QuickLookPreviewSurface(url: url)
                case .unsupported:
                    ContentUnavailableView(
                        "Preview Not Supported",
                        systemImage: "doc.questionmark",
                        description: Text("This file type can be listed, but Hank does not have a compatible preview available for it yet.")
                    )
                    .hankScreenBackground()
                }
            }
            .navigationTitle(preview.item.name)
            .navigationBarTitleDisplayMode(.inline)
            .hankNavigationChrome()
            .hankScreenBackground()
        }
    }
}

private struct QuickLookPreviewSurface: View {
    @State private var previewURL: URL?
    let url: URL

    var body: some View {
        Color.clear
            .hankScreenBackground()
            .quickLookPreview($previewURL)
            .onAppear {
                previewURL = url
            }
    }
}

private struct PDFKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = UIColor(HankTheme.background)
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        uiView.backgroundColor = UIColor(HankTheme.background)
        uiView.document = PDFDocument(url: url)
    }
}

private struct FileBrowserShareSheet: View {
    @Environment(\.dismiss) private var dismiss

    let shareSheet: FileBrowserShareSheetState
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ShareLink(items: shareSheet.urls) {
                        Label("Share Exported Files", systemImage: "square.and.arrow.up")
                    }
                } footer: {
                    Text("Hank exported the selected SMB items to a temporary folder for sharing.")
                }
            }
            .navigationTitle("Share")
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

private struct CameraCaptureScreen: View {
    let onCancel: () -> Void
    let onCapture: (UIImage) -> Void

    var body: some View {
        CameraPickerRepresentable(
            onCancel: onCancel,
            onCapture: onCapture
        )
        .ignoresSafeArea()
    }
}

private struct CameraPickerRepresentable: UIViewControllerRepresentable {
    let onCancel: () -> Void
    let onCapture: (UIImage) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCancel: onCancel, onCapture: onCapture)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        picker.modalPresentationStyle = .fullScreen
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onCancel: () -> Void
        let onCapture: (UIImage) -> Void

        init(onCancel: @escaping () -> Void, onCapture: @escaping (UIImage) -> Void) {
            self.onCancel = onCancel
            self.onCapture = onCapture
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = info[.originalImage] as? UIImage else {
                onCancel()
                return
            }

            onCapture(image)
        }
    }
}
