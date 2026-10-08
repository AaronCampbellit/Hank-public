import CryptoKit
import Foundation
import SwiftData
import SwiftUI
import UIKit

extension Notification.Name {
    static let hankAssistantSMBUploadDidCommit = Notification.Name("HankAssistantSMBUploadDidCommit")
}

struct FilePreviewState: Identifiable {
    enum Content {
        case text(String)
        case image(URL)
        case pdf(URL)
        case quickLookFile(URL)
        case unsupported
    }

    let item: SMBItem
    let content: Content

    var id: String { item.id }
}

enum FileBrowserSelectionAction: Identifiable {
    case copy
    case move

    var id: Self { self }

    var title: String {
        switch self {
        case .copy:
            "Copy"
        case .move:
            "Move"
        }
    }
}

extension FileBrowserSelectionAction: Equatable {}

struct FileBrowserDestinationPickerState: Identifiable {
    let action: FileBrowserSelectionAction

    var id: FileBrowserSelectionAction { action }
}

struct FileBrowserShareSheetState: Identifiable {
    let id = UUID()
    let urls: [URL]
    let cleanupDirectory: URL
}

struct FileBrowserCameraSession: Identifiable {
    let id = UUID()
}

enum FileBrowserNavigationDirection {
    case none
    case forward
    case backward
}

struct FileBrowserTransitionSnapshot: Identifiable {
    let id = UUID()
    let path: String
    let items: [SMBItem]
    let direction: FileBrowserNavigationDirection
}

struct SMBSearchIndexEntry: Identifiable, Hashable, Sendable, Codable {
    let path: String
    let name: String
    let isDirectory: Bool
    let size: Int64?
    let modifiedAt: Date?

    var id: String { path }

    var item: SMBItem {
        SMBItem(
            path: path,
            name: name,
            isDirectory: isDirectory,
            size: size,
            modifiedAt: modifiedAt
        )
    }

    var searchableText: String {
        "\(name) \(path)"
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

private struct SMBSearchIndexSnapshot: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let entries: [SMBSearchIndexEntry]
}

protocol SMBSearchIndexPersisting {
    func loadEntries(for scopeKey: String) throws -> [SMBSearchIndexEntry]?
    func saveEntries(_ entries: [SMBSearchIndexEntry], for scopeKey: String) throws
    func deleteEntries(for scopeKey: String) throws
}

struct DiskSMBSearchIndexPersistence: SMBSearchIndexPersisting {
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func loadEntries(for scopeKey: String) throws -> [SMBSearchIndexEntry]? {
        let fileURL = try snapshotURL(for: scopeKey)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: fileURL)
        let snapshot = try decoder.decode(SMBSearchIndexSnapshot.self, from: data)
        guard snapshot.schemaVersion == SMBSearchIndexSnapshot.currentSchemaVersion else {
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
        return snapshot.entries
    }

    func saveEntries(_ entries: [SMBSearchIndexEntry], for scopeKey: String) throws {
        let snapshot = SMBSearchIndexSnapshot(
            schemaVersion: SMBSearchIndexSnapshot.currentSchemaVersion,
            entries: entries
        )
        let data = try encoder.encode(snapshot)
        let fileURL = try snapshotURL(for: scopeKey)
        try data.write(to: fileURL, options: [.atomic])
    }

    func deleteEntries(for scopeKey: String) throws {
        let fileURL = try snapshotURL(for: scopeKey)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }
        try fileManager.removeItem(at: fileURL)
    }

    private func snapshotURL(for scopeKey: String) throws -> URL {
        let directory = try AppFileLocations.applicationSupportDirectory(fileManager: fileManager)
            .appendingPathComponent("SMBSearchIndex", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(scopeKey.sha256FileComponent).appendingPathExtension("json")
    }
}

private extension String {
    var sha256FileComponent: String {
        SHA256.hash(data: Data(utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum SMBSearchState: Equatable {
    case idle
    case indexing
    case ready(Int)
    case failed(String)
}

enum FileBrowserOperationError: LocalizedError {
    case emptySelection
    case noOpDestination(itemName: String)
    case invalidNestedDestination(itemName: String)
    case destinationAlreadyContains(itemName: String)
    case cameraUnavailable
    case imageEncodingFailed
    case invalidName
    case nameAlreadyExists(String)
    case uploadUnavailable(URL)

    var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "Select one or more items to use this action."
        case .noOpDestination(let itemName):
            return "\"\(itemName)\" is already in that folder."
        case .invalidNestedDestination(let itemName):
            return "\"\(itemName)\" cannot be moved or copied into itself."
        case .destinationAlreadyContains(let itemName):
            return "The destination already contains \"\(itemName)\"."
        case .cameraUnavailable:
            return "Camera is unavailable on this device."
        case .imageEncodingFailed:
            return "The captured image could not be prepared for upload."
        case .invalidName:
            return "Enter a valid name."
        case .nameAlreadyExists(let name):
            return "The folder already contains \"\(name)\"."
        case .uploadUnavailable(let url):
            return "\"\(url.lastPathComponent)\" could not be read for upload."
        }
    }
}

enum FileBrowserPathing {
    static func normalized(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }

        let normalizedSeparators = trimmed.replacingOccurrences(of: "\\", with: "/")
        let components = normalizedSeparators
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        return components.joined(separator: "/")
    }

    static func parentPath(of path: String) -> String {
        let components = normalized(path).split(separator: "/").map(String.init)
        guard !components.isEmpty else {
            return ""
        }

        return components.dropLast().joined(separator: "/")
    }

    static func childPath(named name: String, in directory: String) -> String {
        let normalizedDirectory = normalized(directory)
        guard !normalizedDirectory.isEmpty else {
            return name
        }

        return "\(normalizedDirectory)/\(name)"
    }

    static func isSameOrDescendant(_ path: String, ancestor: String) -> Bool {
        let normalizedPath = normalized(path)
        let normalizedAncestor = normalized(ancestor)

        guard !normalizedAncestor.isEmpty else {
            return false
        }

        return normalizedPath == normalizedAncestor || normalizedPath.hasPrefix(normalizedAncestor + "/")
    }

    static func uniqueCopyName(for originalName: String, existingNames: Set<String>, isDirectory: Bool) -> String {
        guard existingNames.contains(originalName) else {
            return originalName
        }

        let (baseName, ext) = splitName(originalName, isDirectory: isDirectory)
        var counter = 1

        while true {
            let candidateBase = counter == 1 ? "\(baseName) copy" : "\(baseName) copy \(counter)"
            let candidate = ext.isEmpty ? candidateBase : "\(candidateBase).\(ext)"
            if !existingNames.contains(candidate) {
                return candidate
            }
            counter += 1
        }
    }

    static func uniqueCameraFileName(for date: Date, existingNames: Set<String>) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"

        let baseName = "Photo \(formatter.string(from: date))"
        var counter = 1

        while true {
            let candidate = counter == 1 ? "\(baseName).jpg" : "\(baseName) \(counter).jpg"
            if !existingNames.contains(candidate) {
                return candidate
            }
            counter += 1
        }
    }

    private static func splitName(_ name: String, isDirectory: Bool) -> (base: String, ext: String) {
        guard !isDirectory else {
            return (name, "")
        }

        let url = URL(fileURLWithPath: name)
        let ext = url.pathExtension
        guard !ext.isEmpty else {
            return (name, "")
        }

        let base = url.deletingPathExtension().lastPathComponent
        return (base, ext)
    }
}

@MainActor
final class FileBrowserStore: ObservableObject {
    private struct CachedConnectionState {
        let currentPath: String
        let rootPath: String
        let shareTitle: String
        let allItems: [SMBItem]
        let forwardHistory: [String]
        let directoryCache: [String: [SMBItem]]
    }

    enum SortOption: String, CaseIterable, Identifiable {
        case alphabeticalAscending
        case alphabeticalDescending
        case foldersFirst
        case filesFirst
        case lastModified

        var id: Self { self }

        var title: String {
            switch self {
            case .alphabeticalAscending:
                "Alphabetical (A-Z)"
            case .alphabeticalDescending:
                "Alphabetical (Z-A)"
            case .foldersFirst:
                "Folders First"
            case .filesFirst:
                "Files First"
            case .lastModified:
                "Last Modified"
            }
        }

        var systemImage: String {
            switch self {
            case .alphabeticalAscending:
                "textformat"
            case .alphabeticalDescending:
                "textformat.alt"
            case .foldersFirst:
                "folder.badge.plus"
            case .filesFirst:
                "doc.badge.plus"
            case .lastModified:
                "calendar"
            }
        }
    }

    enum ConnectionState: Equatable {
        case needsSetup
        case connections
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var connectionState: ConnectionState = .connecting
    @Published private(set) var availableConnections: [SavedSMBConnectionSummary] = []
    @Published private(set) var selectedConnectionID: UUID?
    @Published private(set) var liveConnectionIDs: Set<UUID> = []
    @Published private(set) var loadingConnectionIDs: Set<UUID> = []
    @Published private(set) var items: [SMBItem] = []
    @Published private(set) var searchResults: [SMBItem] = []
    @Published var searchText = ""
    @Published private(set) var currentPath = ""
    @Published var preview: FilePreviewState?
    @Published var isPreviewLoading = false
    @Published var errorMessage: String?
    @Published private(set) var shareTitle = "File Server"
    @Published var sortOption: SortOption = .foldersFirst {
        didSet {
            applySort()
        }
    }
    @Published var isSelectionMode = false
    @Published private(set) var selectedItemIDs: Set<String> = []
    @Published var isShowingDeleteConfirmation = false
    @Published var destinationPicker: FileBrowserDestinationPickerState?
    @Published var shareSheet: FileBrowserShareSheetState?
    @Published var cameraSession: FileBrowserCameraSession?
    @Published var isShowingTakeAnotherPhotoPrompt = false
    @Published private(set) var isBatchOperationInProgress = false
    @Published private(set) var isCameraUploadInProgress = false
    @Published private(set) var navigationDirection: FileBrowserNavigationDirection = .none
    @Published private(set) var navigationRevision = 0
    @Published private(set) var transitionSnapshot: FileBrowserTransitionSnapshot?
    @Published private(set) var searchState: SMBSearchState = .idle
    @Published private(set) var isSearchIndexWarming = false

    private let searchIndexPersistence: SMBSearchIndexPersisting
    private var rootPath = ""
    private var allItems: [SMBItem] = []
    private var forwardHistory: [String] = []
    private var currentProfileID: UUID?
    private var directoryCache: [String: [SMBItem]] = [:]
    private var searchIndex: [SMBSearchIndexEntry] = []
    private var isSearchIndexValid = false
    private var searchIndexTask: Task<[SMBSearchIndexEntry], Error>?
    private var searchIndexGeneration = 0
    private var searchIndexScopeKey: String?
    private var previewCache: [String: FilePreviewState] = [:]
    private var isLoadingConnection = false
    private var activeSMBService: SMBServicing?
    private var preferredConnectionID: UUID?
    private var cachedConnectionStates: [UUID: CachedConnectionState] = [:]
    private var knownConnectionSummaries: [UUID: SavedSMBConnectionSummary] = [:]
    private var prewarmTasks: [UUID: Task<Void, Never>] = [:]
    private var activeConnectionLoadTask: Task<Void, Never>?
    private var realtimeTask: Task<Void, Never>?
    private var realtimeContext: HankRemoteConnectionContext?

    init(searchIndexPersistence: SMBSearchIndexPersisting = DiskSMBSearchIndexPersistence()) {
        self.searchIndexPersistence = searchIndexPersistence
        NotificationCenter.default.addObserver(
            forName: .hankAssistantSMBUploadDidCommit,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let scopeKey = notification.userInfo?["scope_key"] as? String
            let entries = notification.userInfo?["files"] as? [SMBSearchIndexEntry]
            Task { @MainActor in
                self?.handleAssistantSMBUploadNotification(scopeKey: scopeKey, entries: entries)
            }
        }
    }

    var browserItems: [SMBItem] {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? items : searchResults
    }

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canSwitchConnections: Bool {
        availableConnections.count > 1
    }

    var isShowingConnectionsPage: Bool {
        connectionState == .connections
    }

    var canReturnToConnectionsPage: Bool {
        selectedConnectionID != nil && !isShowingConnectionsPage
    }

    func isConnectionLive(_ connectionID: UUID) -> Bool {
        liveConnectionIDs.contains(connectionID)
    }

    func isConnectionLoading(_ connectionID: UUID) -> Bool {
        loadingConnectionIDs.contains(connectionID)
    }

    func loadIfNeeded(profileID: UUID, modelContext: ModelContext, services: AppServices, force: Bool = false) async {
        if force {
            await refresh(profileID: profileID, modelContext: modelContext, services: services)
            return
        }

        guard currentProfileID != profileID || connectionState == .connecting else {
            return
        }

        await load(profileID: profileID, modelContext: modelContext, services: services)
    }

    func load(profileID: UUID, modelContext: ModelContext, services: AppServices) async {
        guard !isLoadingConnection else {
            return
        }

        isLoadingConnection = true
        defer { isLoadingConnection = false }

        do {
            let wasBrowsingConnection: Bool
            switch connectionState {
            case .connected, .failed:
                wasBrowsingConnection = selectedConnectionID != nil
            case .needsSetup, .connections, .connecting:
                wasBrowsingConnection = false
            }

            currentProfileID = profileID
            let connections = try services.savedSMBConnections(for: profileID, in: modelContext).map(\.summary)
            syncAvailableConnections(connections)

            guard !connections.isEmpty else {
                resetBrowserState()
                connectionState = .needsSetup
                return
            }

            if selectedConnectionID == nil || !connections.contains(where: { $0.id == selectedConnectionID }) {
                selectedConnectionID = preferredConnectionID
                    .flatMap { preferredID in connections.first(where: { $0.id == preferredID })?.id }
                    ?? connections.first(where: \.isDefault)?.id
                    ?? connections.first?.id
            }

            startPrewarmingConnections(profileID: profileID, modelContext: modelContext, services: services)

            guard
                let selectedConnectionID,
                wasBrowsingConnection
            else {
                connectionState = .connections
                shareTitle = "SMB Connections"
                return
            }

            await loadConnection(
                selectedConnectionID,
                profileID: profileID,
                modelContext: modelContext,
                services: services,
                allowCachedState: true,
                updateUI: true
            )
        } catch {
            connectionState = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    func refresh(profileID: UUID, modelContext: ModelContext, services: AppServices) async {
        if let currentProfileID, currentProfileID != profileID {
            await services.disconnectAllSharedSMBServices()
            activeSMBService = nil
            connectionState = .connecting
            resetTransientState()
            invalidateSearchIndex(keepingCurrentDirectory: false)
            cancelConnectionTasks()
            cachedConnectionStates = [:]
            knownConnectionSummaries = [:]
            liveConnectionIDs = []
            loadingConnectionIDs = []
        }
        await load(profileID: profileID, modelContext: modelContext, services: services)
    }

    func prepareForAppBackground() {
        cacheCurrentConnectionStateIfNeeded()
        activeSMBService = nil
        cancelConnectionTasks()
        liveConnectionIDs = []
        loadingConnectionIDs = []
        realtimeTask?.cancel()
        realtimeTask = nil
    }

    func resumeCachedConnectionIfNeeded(
        profileID: UUID,
        modelContext: ModelContext,
        services: AppServices
    ) async {
        guard currentProfileID == profileID else {
            await loadIfNeeded(profileID: profileID, modelContext: modelContext, services: services)
            return
        }

        guard let selectedConnectionID else {
            await loadIfNeeded(profileID: profileID, modelContext: modelContext, services: services)
            return
        }

        guard connectionState == .connected else {
            await loadIfNeeded(profileID: profileID, modelContext: modelContext, services: services)
            return
        }

        guard activeSMBService == nil else {
            return
        }

        activeConnectionLoadTask?.cancel()
        activeConnectionLoadTask = Task { [weak self] in
            guard let self else {
                return
            }
            await self.loadConnection(
                selectedConnectionID,
                profileID: profileID,
                modelContext: modelContext,
                services: services,
                allowCachedState: true,
                updateUI: true
            )
        }
    }

    func selectConnection(
        _ connectionID: UUID,
        profileID: UUID,
        modelContext: ModelContext,
        services: AppServices
    ) async {
        preferredConnectionID = connectionID
        resetTransientState()
        invalidateSearchIndex(keepingCurrentDirectory: false)
        selectedConnectionID = connectionID
        connectionState = .connecting
        if let cachedState = cachedConnectionStates[connectionID] {
            restoreConnectionState(cachedState, for: connectionID)
        } else if let summary = availableConnections.first(where: { $0.id == connectionID }) {
            shareTitle = summary.displayName
            items = []
            allItems = []
            currentPath = ""
            rootPath = ""
            forwardHistory = []
        }

        activeConnectionLoadTask?.cancel()
        activeConnectionLoadTask = Task { [weak self] in
            guard let self else {
                return
            }
            await self.loadConnection(
                connectionID,
                profileID: profileID,
                modelContext: modelContext,
                services: services,
                allowCachedState: true,
                updateUI: true
            )
        }
    }

    func showConnectionsPage() {
        cacheCurrentConnectionStateIfNeeded()
        resetTransientState()
        searchText = ""
        searchResults = []
        searchState = .idle
        currentPath = ""
        rootPath = ""
        items = []
        allItems = []
        forwardHistory = []
        transitionSnapshot = nil
        navigationDirection = .none
        shareTitle = "SMB Connections"
        activeSMBService = nil
        errorMessage = nil
        connectionState = availableConnections.isEmpty ? .needsSetup : .connections
    }

    func assistantOpenPath(
        _ requestedPath: String,
        profileID: UUID,
        modelContext: ModelContext,
        services: AppServices
    ) async {
        let normalizedPath = FileBrowserPathing.normalized(requestedPath)
        do {
            if currentProfileID != profileID || availableConnections.isEmpty {
                await load(profileID: profileID, modelContext: modelContext, services: services)
            }

            guard let connectionID = selectedConnectionID ?? availableConnections.first?.id else {
                errorMessage = "Add an SMB connection before opening assistant file results."
                showConnectionsPage()
                return
            }

            if selectedConnectionID != connectionID || activeSMBService == nil || connectionState != .connected {
                selectedConnectionID = connectionID
                connectionState = .connecting
                await loadConnection(
                    connectionID,
                    profileID: profileID,
                    modelContext: modelContext,
                    services: services,
                    allowCachedState: true,
                    updateUI: true
                )
            }

            guard let smbService = activeSMBService else {
                errorMessage = SMBServiceError.notConnected.localizedDescription
                return
            }

            guard !normalizedPath.isEmpty else {
                await navigateToRoot(services: services)
                return
            }

            if let directoryItems = try? await smbService.list(path: normalizedPath) {
                applyNavigation(to: normalizedPath, items: directoryItems, direction: .forward)
                errorMessage = nil
                return
            }

            let parentPath = String(normalizedPath.split(separator: "/").dropLast().joined(separator: "/"))
            let parentItems = try await smbService.list(path: parentPath)
            applyNavigation(to: parentPath, items: parentItems, direction: .forward)
            if let fileItem = parentItems.first(where: {
                FileBrowserPathing.normalized($0.path) == normalizedPath && $0.isDirectory == false
            }) {
                await open(fileItem, services: services)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func open(_ item: SMBItem, services: AppServices) async {
        guard connectionState == .connected, !isSelectionMode else {
            return
        }
        guard let smbService = activeSMBService else {
            errorMessage = SMBServiceError.notConnected.localizedDescription
            return
        }

        do {
            if item.isDirectory {
                forwardHistory.removeAll()
                let nextItems = try await smbService.list(path: item.path)
                applyNavigation(to: item.path, items: nextItems, direction: .forward)
                errorMessage = nil
                return
            }

            let cacheKey = previewCacheKey(for: item)
            if let cachedPreview = cachedPreview(for: cacheKey) {
                preview = cachedPreview
                errorMessage = nil
                return
            }

            isPreviewLoading = true
            defer { isPreviewLoading = false }
            let nextPreview = try await buildPreview(for: item, using: smbService)
            previewCache[cacheKey] = nextPreview
            preview = nextPreview
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func navigateUp(services: AppServices) async {
        guard connectionState == .connected, !isSelectionMode else {
            return
        }

        let components = currentPath.split(separator: "/").map(String.init)
        let nextPath: String

        if components.isEmpty {
            nextPath = rootPath
        } else {
            nextPath = components.dropLast().joined(separator: "/")
        }

        forwardHistory.append(currentPath)
        await navigate(to: nextPath, direction: .backward, services: services)
    }

    func navigateForward(services: AppServices) async {
        guard connectionState == .connected, !isSelectionMode, let nextPath = forwardHistory.popLast() else {
            return
        }

        await navigate(to: nextPath, direction: .forward, services: services)
    }

    func navigateToRoot(services: AppServices) async {
        guard connectionState == .connected, !isSelectionMode else {
            return
        }

        let normalizedRoot = FileBrowserPathing.normalized(rootPath)
        guard FileBrowserPathing.normalized(currentPath) != normalizedRoot else {
            return
        }

        forwardHistory.append(currentPath)
        await navigate(to: rootPath, direction: .backward, services: services)
    }

    func resetToHome(services: AppServices) async {
        searchText = ""
        searchResults = []
        searchState = .idle

        if connectionState == .connected {
            if isSelectionMode {
                cancelSelection()
            }
            await navigateToRoot(services: services)
        } else if connectionState == .connections || selectedConnectionID != nil {
            showConnectionsPage()
        }
    }

    func enterSelectionMode() {
        guard connectionState == .connected else {
            return
        }

        preview = nil
        isSelectionMode = true
        selectedItemIDs.removeAll()
        errorMessage = nil
    }

    func enterSelectionMode(selecting item: SMBItem) {
        guard connectionState == .connected else {
            return
        }

        preview = nil
        isSelectionMode = true
        selectedItemIDs = [item.id]
        errorMessage = nil
    }

    func cancelSelection() {
        isSelectionMode = false
        selectedItemIDs.removeAll()
        isShowingDeleteConfirmation = false
        destinationPicker = nil
    }

    func toggleSelection(for item: SMBItem) {
        guard isSelectionMode else {
            return
        }

        if selectedItemIDs.contains(item.id) {
            selectedItemIDs.remove(item.id)
        } else {
            selectedItemIDs.insert(item.id)
        }
    }

    func selectOnly(_ item: SMBItem) {
        enterSelectionMode(selecting: item)
    }

    func isSelected(_ item: SMBItem) -> Bool {
        selectedItemIDs.contains(item.id)
    }

    func beginDestinationAction(_ action: FileBrowserSelectionAction) {
        guard hasSelection else {
            errorMessage = FileBrowserOperationError.emptySelection.localizedDescription
            return
        }

        destinationPicker = FileBrowserDestinationPickerState(action: action)
        errorMessage = nil
    }

    func promptForDelete() {
        guard hasSelection else {
            errorMessage = FileBrowserOperationError.emptySelection.localizedDescription
            return
        }

        isShowingDeleteConfirmation = true
        errorMessage = nil
    }

    func deleteSelected(services: AppServices) async {
        guard let activeSMBService else { return }
        await deleteSelectedItems(using: activeSMBService)
    }

    func copySelected(to destinationPath: String, services: AppServices) async {
        guard let activeSMBService else { return }
        await copySelectedItems(to: destinationPath, using: activeSMBService)
    }

    func moveSelected(to destinationPath: String, services: AppServices) async {
        guard let activeSMBService else { return }
        await moveSelectedItems(to: destinationPath, using: activeSMBService)
    }

    func prepareShare(services: AppServices) async {
        guard let activeSMBService else { return }
        await prepareShareSheet(using: activeSMBService)
    }

    func createFolder(named rawName: String, services: AppServices) async {
        guard let activeSMBService else { return }
        await createFolder(named: rawName, using: activeSMBService)
    }

    func rename(_ item: SMBItem, to rawName: String, services: AppServices) async {
        guard let activeSMBService else { return }
        await rename(item, to: rawName, using: activeSMBService)
    }

    func uploadFiles(from urls: [URL], services: AppServices) async {
        guard let activeSMBService else { return }
        await uploadFiles(from: urls, using: activeSMBService)
    }

    func performSearch(services: AppServices) async {
        guard let activeSMBService else { return }
        await performSearch(using: activeSMBService)
    }

    func warmSearchIndex(services: AppServices) {
        guard let activeSMBService else { return }
        warmSearchIndex(using: activeSMBService)
    }

    func clearShareSheet() {
        guard let shareSheet else {
            return
        }

        try? FileManager.default.removeItem(at: shareSheet.cleanupDirectory)
        self.shareSheet = nil
    }

    func beginCameraCapture() {
        guard connectionState == .connected else {
            return
        }

        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            errorMessage = FileBrowserOperationError.cameraUnavailable.localizedDescription
            return
        }

        isShowingTakeAnotherPhotoPrompt = false
        errorMessage = nil
        cameraSession = FileBrowserCameraSession()
    }

    func cancelCameraCapture() {
        cameraSession = nil
        isShowingTakeAnotherPhotoPrompt = false
    }

    func requestAnotherPhoto() {
        isShowingTakeAnotherPhotoPrompt = false
        beginCameraCapture()
    }

    func finishCameraPrompt() {
        isShowingTakeAnotherPhotoPrompt = false
    }

    func handleCapturedPhoto(_ image: UIImage, services: AppServices) async {
        cameraSession = nil

        guard let data = image.jpegData(compressionQuality: 0.9) else {
            errorMessage = FileBrowserOperationError.imageEncodingFailed.localizedDescription
            isShowingTakeAnotherPhotoPrompt = false
            return
        }

        guard let activeSMBService else { return }
        await uploadCapturedPhoto(data: data, using: activeSMBService)
    }

    var canNavigateUp: Bool {
        !currentPath.isEmpty
    }

    var canNavigateForward: Bool {
        !forwardHistory.isEmpty
    }

    var breadcrumb: String {
        currentPath.isEmpty ? "" : currentPath
    }

    var browserRootPath: String {
        rootPath
    }

    var selectedCount: Int {
        selectedItemIDs.count
    }

    var hasSelection: Bool {
        !selectedItemIDs.isEmpty
    }

    func list(path: String) async throws -> [SMBItem] {
        guard let activeSMBService else {
            throw SMBServiceError.notConnected
        }
        return try await activeSMBService.list(path: path)
    }

    func primeForTesting(
        items: [SMBItem],
        currentPath: String = "",
        rootPath: String = "",
        searchScopeKey: String? = nil,
        activeService: SMBServicing? = nil
    ) {
        connectionState = .connected
        activeSMBService = activeService
        shareTitle = "Test Share"
        self.currentPath = currentPath
        self.rootPath = rootPath
        transitionSnapshot = nil
        activateSearchScope(searchScopeKey)
        updateItems(items)
    }

    func completeNavigationTransition() {
        transitionSnapshot = nil
        navigationDirection = .none
    }

    func deleteSelectedItems(using smbService: SMBServicing) async {
        let selection = selectedItemsSnapshot()
        guard !selection.isEmpty else {
            errorMessage = FileBrowserOperationError.emptySelection.localizedDescription
            return
        }

        isShowingDeleteConfirmation = false
        isBatchOperationInProgress = true
        defer { isBatchOperationInProgress = false }

        do {
            for item in selection {
                try await smbService.delete(path: item.path, isDirectory: item.isDirectory)
            }

            removeSearchEntries(for: selection)
            discardDirectoryCache(prefixedBy: selection.map(\.path))
            try await reloadCurrentFolder(using: smbService)
            persistSearchIndexIfNeeded()
            errorMessage = nil
            cancelSelection()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func copySelectedItems(to destinationPath: String, using smbService: SMBServicing) async {
        let selection = selectedItemsSnapshot()
        guard !selection.isEmpty else {
            errorMessage = FileBrowserOperationError.emptySelection.localizedDescription
            return
        }

        isBatchOperationInProgress = true
        defer { isBatchOperationInProgress = false }

        do {
            let destinationChildren = try await validateDestination(destinationPath, for: selection, action: .copy, using: smbService)
            var existingNames = Set(destinationChildren.map(\.name))
            var copiedEntries: [SMBSearchIndexEntry] = []

            for item in selection {
                let targetName = FileBrowserPathing.uniqueCopyName(
                    for: item.name,
                    existingNames: existingNames,
                    isDirectory: item.isDirectory
                )
                existingNames.insert(targetName)
                let targetPath = FileBrowserPathing.childPath(named: targetName, in: destinationPath)
                copiedEntries += try await copy(item: item, to: targetPath, using: smbService)
            }

            upsertSearchEntries(copiedEntries)
            discardDirectoryCache(at: destinationPath)
            try await reloadCurrentFolder(using: smbService)
            persistSearchIndexIfNeeded()
            errorMessage = nil
            destinationPicker = nil
            cancelSelection()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveSelectedItems(to destinationPath: String, using smbService: SMBServicing) async {
        let selection = selectedItemsSnapshot()
        guard !selection.isEmpty else {
            errorMessage = FileBrowserOperationError.emptySelection.localizedDescription
            return
        }

        isBatchOperationInProgress = true
        defer { isBatchOperationInProgress = false }

        do {
            _ = try await validateDestination(destinationPath, for: selection, action: .move, using: smbService)

            for item in selection {
                let targetPath = FileBrowserPathing.childPath(named: item.name, in: destinationPath)
                try await smbService.move(from: item.path, to: targetPath, isDirectory: item.isDirectory)
                rebaseSearchEntries(from: item.path, to: targetPath, fallback: item)
            }

            discardDirectoryCache(at: destinationPath)
            try await reloadCurrentFolder(using: smbService)
            persistSearchIndexIfNeeded()
            errorMessage = nil
            destinationPicker = nil
            cancelSelection()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func prepareShareSheet(using smbService: SMBServicing, fileManager: FileManager = .default) async {
        let selection = selectedItemsSnapshot()
        guard !selection.isEmpty else {
            errorMessage = FileBrowserOperationError.emptySelection.localizedDescription
            return
        }

        isBatchOperationInProgress = true
        defer { isBatchOperationInProgress = false }

        do {
            let exportRoot = fileManager.temporaryDirectory
                .appendingPathComponent("HankShare", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fileManager.createDirectory(at: exportRoot, withIntermediateDirectories: true)

            var urls: [URL] = []
            for item in selection {
                let destinationURL = exportRoot.appendingPathComponent(item.name, isDirectory: item.isDirectory)
                try await export(item: item, to: destinationURL, using: smbService, fileManager: fileManager)
                urls.append(destinationURL)
            }

            shareSheet = FileBrowserShareSheetState(urls: urls, cleanupDirectory: exportRoot)
            errorMessage = nil
            cancelSelection()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func uploadCapturedPhoto(data: Data, using smbService: SMBServicing, capturedAt: Date = .now) async {
        isCameraUploadInProgress = true
        defer { isCameraUploadInProgress = false }

        do {
            let existingNames = Set(try await smbService.list(path: currentPath).map(\.name))
            let fileName = FileBrowserPathing.uniqueCameraFileName(for: capturedAt, existingNames: existingNames)
            let destinationPath = FileBrowserPathing.childPath(named: fileName, in: currentPath)

            try await smbService.upload(data: data, path: destinationPath)
            try await reloadCurrentFolder(using: smbService)
            persistSearchIndexIfNeeded()
            cameraSession = nil
            isShowingTakeAnotherPhotoPrompt = true
            errorMessage = nil
        } catch {
            cameraSession = nil
            isShowingTakeAnotherPhotoPrompt = false
            errorMessage = error.localizedDescription
        }
    }

    func createFolder(named rawName: String, using smbService: SMBServicing) async {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else {
            errorMessage = FileBrowserOperationError.invalidName.localizedDescription
            return
        }

        isBatchOperationInProgress = true
        defer { isBatchOperationInProgress = false }

        do {
            let existingNames = Set(try await smbService.list(path: currentPath).map(\.name))
            guard !existingNames.contains(name) else {
                throw FileBrowserOperationError.nameAlreadyExists(name)
            }

            let folderPath = FileBrowserPathing.childPath(named: name, in: currentPath)
            try await smbService.createDirectory(path: folderPath)
            try await reloadCurrentFolder(using: smbService)
            persistSearchIndexIfNeeded()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rename(_ item: SMBItem, to rawName: String, using smbService: SMBServicing) async {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else {
            errorMessage = FileBrowserOperationError.invalidName.localizedDescription
            return
        }
        guard name != item.name else {
            return
        }

        isBatchOperationInProgress = true
        defer { isBatchOperationInProgress = false }

        do {
            let parentPath = FileBrowserPathing.parentPath(of: item.path)
            let siblings = try await smbService.list(path: parentPath)
            guard !siblings.contains(where: { $0.name == name }) else {
                throw FileBrowserOperationError.nameAlreadyExists(name)
            }

            let targetPath = FileBrowserPathing.childPath(named: name, in: parentPath)
            try await smbService.move(from: item.path, to: targetPath, isDirectory: item.isDirectory)
            rebaseSearchEntries(from: item.path, to: targetPath, fallback: item)
            try await reloadCurrentFolder(using: smbService)
            persistSearchIndexIfNeeded()
            errorMessage = nil
            if isSelectionMode {
                selectedItemIDs.remove(item.id)
                selectedItemIDs.insert(targetPath)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func uploadFiles(from urls: [URL], using smbService: SMBServicing) async {
        guard !urls.isEmpty else {
            errorMessage = LocalFileServiceError.emptyImport.localizedDescription
            return
        }

        isBatchOperationInProgress = true
        defer { isBatchOperationInProgress = false }

        do {
            var existingNames = Set(try await smbService.list(path: currentPath).map(\.name))
            for url in urls {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                let targetName = FileBrowserPathing.uniqueCopyName(
                    for: url.lastPathComponent.isEmpty ? "Uploaded File" : url.lastPathComponent,
                    existingNames: existingNames,
                    isDirectory: false
                )
                existingNames.insert(targetName)
                try await smbService.upload(fileAt: url, path: FileBrowserPathing.childPath(named: targetName, in: currentPath))
            }

            try await reloadCurrentFolder(using: smbService)
            persistSearchIndexIfNeeded()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func performSearch(using smbService: SMBServicing) async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            searchState = .idle
            return
        }

        do {
            if !isSearchIndexValid {
                searchState = .indexing
                searchIndex = try await currentOrNewSearchIndex(using: smbService)
            }

            persistSearchIndexIfNeeded()
            applySearch(query: query)
            searchState = .ready(searchResults.count)
            errorMessage = nil
        } catch {
            searchResults = []
            searchState = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    private func syncAvailableConnections(_ connections: [SavedSMBConnectionSummary]) {
        availableConnections = connections

        let nextSummaries = Dictionary(uniqueKeysWithValues: connections.map { ($0.id, $0) })
        let currentIDs = Set(nextSummaries.keys)

        cachedConnectionStates = cachedConnectionStates.filter { currentIDs.contains($0.key) }
        liveConnectionIDs = Set(liveConnectionIDs.filter { currentIDs.contains($0) })
        loadingConnectionIDs = Set(loadingConnectionIDs.filter { currentIDs.contains($0) })
        prewarmTasks = Dictionary(uniqueKeysWithValues: prewarmTasks.filter { currentIDs.contains($0.key) })

        for (connectionID, summary) in nextSummaries {
            if let previousSummary = knownConnectionSummaries[connectionID], previousSummary != summary {
                cachedConnectionStates.removeValue(forKey: connectionID)
                liveConnectionIDs.remove(connectionID)
            }
        }

        knownConnectionSummaries = nextSummaries

        if let selectedConnectionID, !currentIDs.contains(selectedConnectionID) {
            self.selectedConnectionID = connections.first(where: \.isDefault)?.id ?? connections.first?.id
            showConnectionsPage()
        }
    }

    private func cancelConnectionTasks() {
        activeConnectionLoadTask?.cancel()
        activeConnectionLoadTask = nil
        for task in prewarmTasks.values {
            task.cancel()
        }
        prewarmTasks.removeAll()
    }

    private func startPrewarmingConnections(
        profileID: UUID,
        modelContext: ModelContext,
        services: AppServices
    ) {
        let currentIDs = Set(availableConnections.map(\.id))
        for (connectionID, task) in prewarmTasks where !currentIDs.contains(connectionID) {
            task.cancel()
            prewarmTasks.removeValue(forKey: connectionID)
        }

        for connection in availableConnections {
            guard cachedConnectionStates[connection.id] == nil, prewarmTasks[connection.id] == nil else {
                continue
            }

            loadingConnectionIDs.insert(connection.id)
            prewarmTasks[connection.id] = Task { [weak self] in
                guard let self else {
                    return
                }

                defer {
                    Task { @MainActor [weak self] in
                        guard let self else {
                            return
                        }
                        self.loadingConnectionIDs.remove(connection.id)
                        self.prewarmTasks.removeValue(forKey: connection.id)
                    }
                }

                await self.prewarmConnection(
                    connection.id,
                    profileID: profileID,
                    modelContext: modelContext,
                    services: services
                )
            }
        }
    }

    private func prewarmConnection(
        _ connectionID: UUID,
        profileID: UUID,
        modelContext: ModelContext,
        services: AppServices
    ) async {
        do {
            let resolvedConnection = try await services.preferredSMBConnection(
                for: profileID,
                preferredConnectionID: connectionID,
                in: modelContext
            )
            guard
                let resolvedConnection
            else {
                liveConnectionIDs.remove(connectionID)
                return
            }
            let password = try passwordForConnection(resolvedConnection, profileID: profileID, services: services)

            let snapshot = try await connectAndLoadSnapshot(
                resolvedConnection: resolvedConnection,
                password: password,
                preferredPath: nil,
                services: services
            )
            cachedConnectionStates[connectionID] = snapshot.state
            liveConnectionIDs.insert(connectionID)
        } catch {
            liveConnectionIDs.remove(connectionID)
        }
    }

    private func passwordForConnection(
        _ resolvedConnection: ResolvedSMBConnection,
        profileID: UUID,
        services: AppServices
    ) throws -> String {
        try services.smbPassword(for: resolvedConnection, profileID: profileID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func loadConnection(
        _ connectionID: UUID,
        profileID: UUID,
        modelContext: ModelContext,
        services: AppServices,
        allowCachedState: Bool,
        updateUI: Bool
    ) async {
        loadingConnectionIDs.insert(connectionID)
        defer {
            loadingConnectionIDs.remove(connectionID)
        }

        do {
            let resolvedConnection = try await services.preferredSMBConnection(
                for: profileID,
                preferredConnectionID: connectionID,
                in: modelContext
            )
            guard let resolvedConnection else {
                if updateUI {
                    showConnectionsPage()
                }
                return
            }

            let password = try passwordForConnection(resolvedConnection, profileID: profileID, services: services)

            let preferredPath = allowCachedState ? cachedConnectionStates[connectionID]?.currentPath : nil
            let snapshot = try await connectAndLoadSnapshot(
                resolvedConnection: resolvedConnection,
                password: password,
                preferredPath: preferredPath,
                services: services
            )

            cachedConnectionStates[connectionID] = snapshot.state
            liveConnectionIDs.insert(connectionID)

            if updateUI, selectedConnectionID == connectionID {
                activeSMBService = snapshot.service
                restoreConnectionState(snapshot.state, for: connectionID)
                connectionState = .connected
                errorMessage = snapshot.message
                warmSearchIndex(using: snapshot.service)
            }
        } catch {
            liveConnectionIDs.remove(connectionID)
            if updateUI, selectedConnectionID == connectionID {
                if allowCachedState, let cachedState = cachedConnectionStates[connectionID] {
                    restoreConnectionState(cachedState, for: connectionID)
                    connectionState = .connected
                    errorMessage = error.localizedDescription
                } else {
                    connectionState = .failed(error.localizedDescription)
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func connectAndLoadSnapshot(
        resolvedConnection: ResolvedSMBConnection,
        password: String,
        preferredPath: String?,
        services: AppServices
    ) async throws -> (state: CachedConnectionState, service: SMBServicing, message: String?) {
        let smbService = await services.sharedSMBService(for: resolvedConnection)
        realtimeContext = resolvedConnection.remoteAccess
        let nextSearchScopeKey = Self.searchIndexScopeKey(
            for: resolvedConnection.details
        )

        activateSearchScope(nextSearchScopeKey)
        try await smbService.connect(
            config: resolvedConnection.details,
            password: password,
            context: resolvedConnection.remoteAccess
        )

        let nextRootPath = resolvedConnection.details.normalizedStartPath
        let normalizedPreferredPath = FileBrowserPathing.normalized(preferredPath ?? "")
        let targetPath: String
        if !normalizedPreferredPath.isEmpty, normalizedPreferredPath.hasPrefix(FileBrowserPathing.normalized(nextRootPath)) {
            targetPath = normalizedPreferredPath
        } else {
            targetPath = nextRootPath
        }

        let resolvedStartPath: String
        let message: String?
        if targetPath.isEmpty {
            resolvedStartPath = ""
            message = nil
        } else {
            do {
                _ = try await smbService.list(path: targetPath)
                resolvedStartPath = targetPath
                message = nil
            } catch {
                resolvedStartPath = ""
                message = "Connected to SMB, but the configured start path \"\(targetPath)\" is inaccessible for this account. Opened the share root instead."
            }
        }

        let loadedItems = try await smbService.list(path: resolvedStartPath)
        startRealtimeDirectorySubscription(path: resolvedStartPath, services: services)
        let normalizedDirectoryPath = FileBrowserPathing.normalized(resolvedStartPath)
        let shareTitle = resolvedConnection.details.shareName.isEmpty ? "File Server" : resolvedConnection.details.shareName
        return (
            state: CachedConnectionState(
                currentPath: resolvedStartPath,
                rootPath: resolvedStartPath,
                shareTitle: shareTitle,
                allItems: loadedItems,
                forwardHistory: [],
                directoryCache: [normalizedDirectoryPath: loadedItems]
            ),
            service: smbService,
            message: message
        )
    }

    private func restoreConnectionState(_ cachedState: CachedConnectionState, for connectionID: UUID) {
        selectedConnectionID = connectionID
        currentPath = cachedState.currentPath
        rootPath = cachedState.rootPath
        shareTitle = cachedState.shareTitle
        allItems = cachedState.allItems
        directoryCache = cachedState.directoryCache
        forwardHistory = cachedState.forwardHistory
        transitionSnapshot = nil
        navigationDirection = .none
        items = cachedState.allItems.sorted(by: compareItems)
        if isSearching {
            applySearch(query: searchText)
        }
        connectionState = .connected
    }

    private func cacheCurrentConnectionStateIfNeeded() {
        guard
            connectionState == .connected,
            let selectedConnectionID
        else {
            return
        }

        cachedConnectionStates[selectedConnectionID] = CachedConnectionState(
            currentPath: currentPath,
            rootPath: rootPath,
            shareTitle: shareTitle,
            allItems: allItems,
            forwardHistory: forwardHistory,
            directoryCache: directoryCache
        )
    }

    private func navigate(to path: String, direction: FileBrowserNavigationDirection, services: AppServices) async {
        guard let activeSMBService else {
            errorMessage = SMBServiceError.notConnected.localizedDescription
            return
        }
        do {
            let nextItems = try await activeSMBService.list(path: path)
            applyNavigation(to: path, items: nextItems, direction: direction)
            startRealtimeDirectorySubscription(path: path, services: services)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resetBrowserState() {
        items = []
        allItems = []
        currentPath = ""
        currentProfileID = nil
        selectedConnectionID = nil
        rootPath = ""
        searchIndexScopeKey = nil
        shareTitle = "SMB Connections"
        forwardHistory = []
        transitionSnapshot = nil
        activeSMBService = nil
        availableConnections = []
        liveConnectionIDs = []
        loadingConnectionIDs = []
        cachedConnectionStates = [:]
        knownConnectionSummaries = [:]
        cancelConnectionTasks()
        realtimeTask?.cancel()
        realtimeTask = nil
        realtimeContext = nil
        resetTransientState()
        invalidateSearchIndex(keepingCurrentDirectory: false)
    }

    private func resetTransientState() {
        cancelSelection()
        preview = nil
        previewCache = [:]
        clearShareSheet()
        cameraSession = nil
        isShowingTakeAnotherPhotoPrompt = false
        isShowingDeleteConfirmation = false
    }

    private func updateItems(_ nextItems: [SMBItem]) {
        let normalizedCurrentPath = FileBrowserPathing.normalized(currentPath)
        allItems = nextItems
        directoryCache[normalizedCurrentPath] = nextItems
        if isSearchIndexValid {
            replaceSearchEntries(in: normalizedCurrentPath, with: nextItems)
        }
        applySort()
        cacheCurrentConnectionStateIfNeeded()
    }

    private func handleAssistantSMBUploadNotification(scopeKey: String?, entries: [SMBSearchIndexEntry]?) {
        guard let scopeKey,
              scopeKey == searchIndexScopeKey,
              let entries else {
            return
        }
        upsertSearchEntries(entries)
        persistSearchIndexIfNeeded()

        let normalizedCurrentPath = FileBrowserPathing.normalized(currentPath)
        let currentEntries = entries.filter { FileBrowserPathing.parentPath(of: $0.path) == normalizedCurrentPath }
        guard !currentEntries.isEmpty else {
            return
        }
        var nextItems = allItems
        let byPath = Dictionary(uniqueKeysWithValues: currentEntries.map { ($0.path, $0.item) })
        nextItems.removeAll { byPath[$0.path] != nil }
        nextItems.append(contentsOf: byPath.values)
        updateItems(nextItems)
    }

    private func applyNavigation(to path: String, items: [SMBItem], direction: FileBrowserNavigationDirection) {
        let normalizedCurrentPath = FileBrowserPathing.normalized(currentPath)
        let normalizedNextPath = FileBrowserPathing.normalized(path)
        let shouldCaptureTransition = direction != .none && normalizedCurrentPath != normalizedNextPath

        if shouldCaptureTransition {
            transitionSnapshot = FileBrowserTransitionSnapshot(
                path: currentPath,
                items: self.items,
                direction: direction
            )
        } else {
            transitionSnapshot = nil
        }

        navigationDirection = direction
        currentPath = path
        updateItems(items)
        navigationRevision += 1
        cacheCurrentConnectionStateIfNeeded()
    }

    private func startRealtimeDirectorySubscription(path: String, services: AppServices) {
        guard let realtimeContext else {
            return
        }
        let normalizedPath = FileBrowserPathing.normalized(path)
        realtimeTask?.cancel()
        realtimeTask = Task { [weak self] in
            do {
                try await services.hankRemoteService.subscribeRealtime(
                    topics: ["files.directory:\(normalizedPath.isEmpty ? "/" : normalizedPath)"],
                    context: realtimeContext
                )
                for await event in await services.hankRemoteService.realtimeEvents() {
                    guard
                        event.event == "files.directory_changed",
                        let payload = event.payload,
                        let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                        let eventPath = object["path"] as? String,
                        FileBrowserPathing.normalized(eventPath) == normalizedPath
                    else {
                        continue
                    }
                    let items = try await self?.activeSMBService?.list(path: path) ?? []
                    await MainActor.run {
                        self?.updateItems(items)
                    }
                }
            } catch {
                await MainActor.run {
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func applySort() {
        items = allItems.sorted(by: compareItems)
        if isSearching {
            applySearch(query: searchText)
        }
    }

    private func compareItems(_ lhs: SMBItem, _ rhs: SMBItem) -> Bool {
        switch sortOption {
        case .alphabeticalAscending:
            return localizedName(lhs) < localizedName(rhs)
        case .alphabeticalDescending:
            return localizedName(lhs) > localizedName(rhs)
        case .foldersFirst:
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return localizedName(lhs) < localizedName(rhs)
        case .filesFirst:
            if lhs.isDirectory != rhs.isDirectory {
                return !lhs.isDirectory && rhs.isDirectory
            }
            return localizedName(lhs) < localizedName(rhs)
        case .lastModified:
            switch (lhs.modifiedAt, rhs.modifiedAt) {
            case let (left?, right?) where left != right:
                return left > right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory && !rhs.isDirectory
                }
                return localizedName(lhs) < localizedName(rhs)
            }
        }
    }

    private func localizedName(_ item: SMBItem) -> String {
        item.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func activateSearchScope(_ scopeKey: String?) {
        guard searchIndexScopeKey != scopeKey else {
            return
        }

        searchIndexGeneration += 1
        searchIndexTask?.cancel()
        searchIndexTask = nil
        searchIndexScopeKey = scopeKey
        searchIndex = []
        searchResults = []
        searchState = .idle
        isSearchIndexValid = false
        isSearchIndexWarming = false

        guard let scopeKey, let entries = try? searchIndexPersistence.loadEntries(for: scopeKey) else {
            return
        }

        searchIndex = sortedSearchEntries(entries)
        isSearchIndexValid = true
    }

    private func buildPreview(for item: SMBItem, using smbService: SMBServicing) async throws -> FilePreviewState {
        let kind = FilePreviewClassifier.classify(fileName: item.name)

        switch kind {
        case .text:
            let data = try await smbService.download(path: item.path)
            let text = String(data: data, encoding: .utf8) ??
                String(data: data, encoding: .ascii) ??
                "Unable to decode the text content."
            return FilePreviewState(item: item, content: .text(text))
        case .image, .pdf, .quickLookFile:
            let destination = try previewFileURL(for: item)
            try await smbService.download(path: item.path, to: destination)
            let content: FilePreviewState.Content
            switch kind {
            case .image:
                content = .image(destination)
            case .pdf:
                content = .pdf(destination)
            case .quickLookFile:
                content = .quickLookFile(destination)
            case .text, .unsupported:
                throw CocoaError(.fileReadUnknown)
            }
            return FilePreviewState(item: item, content: content)
        case .unsupported:
            return FilePreviewState(item: item, content: .unsupported)
        }
    }

    private func previewFileURL(for item: SMBItem) throws -> URL {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("HankPreview", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let destination = tempDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(item.name)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        return destination
    }

    private func previewCacheKey(for item: SMBItem) -> String {
        let modified = item.modifiedAt?.timeIntervalSince1970 ?? 0
        let size = item.size ?? -1
        return "\(item.path)|\(size)|\(modified)"
    }

    private func cachedPreview(for key: String) -> FilePreviewState? {
        guard let cached = previewCache[key] else {
            return nil
        }

        switch cached.content {
        case .image(let url), .pdf(let url), .quickLookFile(let url):
            guard FileManager.default.fileExists(atPath: url.path) else {
                previewCache.removeValue(forKey: key)
                return nil
            }
        case .text, .unsupported:
            break
        }

        return cached
    }

    private func selectedItemsSnapshot() -> [SMBItem] {
        allItems
            .filter { selectedItemIDs.contains($0.id) }
            .sorted { localizedName($0) < localizedName($1) }
    }

    private func validateDestination(
        _ destinationPath: String,
        for items: [SMBItem],
        action: FileBrowserSelectionAction,
        using smbService: SMBServicing
    ) async throws -> [SMBItem] {
        let normalizedDestination = FileBrowserPathing.normalized(destinationPath)

        for item in items {
            let parentPath = FileBrowserPathing.parentPath(of: item.path)
            if parentPath == normalizedDestination {
                throw FileBrowserOperationError.noOpDestination(itemName: item.name)
            }

            if item.isDirectory, FileBrowserPathing.isSameOrDescendant(normalizedDestination, ancestor: item.path) {
                throw FileBrowserOperationError.invalidNestedDestination(itemName: item.name)
            }
        }

        let destinationChildren = try await smbService.list(path: normalizedDestination)

        if action == .move {
            let existingNames = Set(destinationChildren.map(\.name))
            if let conflict = items.map(\.name).first(where: existingNames.contains) {
                throw FileBrowserOperationError.destinationAlreadyContains(itemName: conflict)
            }
        }

        return destinationChildren
    }

    private func copy(item: SMBItem, to destinationPath: String, using smbService: SMBServicing) async throws -> [SMBSearchIndexEntry] {
        let targetName = destinationPath.split(separator: "/").last.map(String.init) ?? item.name
        var copiedEntries = [searchEntry(for: item, path: destinationPath, name: targetName)]

        if item.isDirectory {
            try await smbService.createDirectory(path: destinationPath)
            let children = try await smbService.list(path: item.path)
            for child in children {
                let childDestination = FileBrowserPathing.childPath(named: child.name, in: destinationPath)
                copiedEntries += try await copy(item: child, to: childDestination, using: smbService)
            }
        } else {
            let temporaryURL = try temporaryTransferURL(named: item.name)
            defer { try? FileManager.default.removeItem(at: temporaryURL.deletingLastPathComponent()) }
            try await smbService.download(path: item.path, to: temporaryURL)
            try await smbService.upload(fileAt: temporaryURL, path: destinationPath)
        }

        return copiedEntries
    }

    private func export(item: SMBItem, to destinationURL: URL, using smbService: SMBServicing, fileManager: FileManager) async throws {
        if item.isDirectory {
            try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            let children = try await smbService.list(path: item.path)
            for child in children {
                let childURL = destinationURL.appendingPathComponent(child.name, isDirectory: child.isDirectory)
                try await export(item: child, to: childURL, using: smbService, fileManager: fileManager)
            }
        } else {
            try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await smbService.download(path: item.path, to: destinationURL)
        }
    }

    private func temporaryTransferURL(named fileName: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HankTransfer", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(fileName)
    }

    private func reloadCurrentFolder(using smbService: SMBServicing) async throws {
        updateItems(try await smbService.list(path: currentPath))
    }

    private func invalidateSearchIndex() {
        invalidateSearchIndex(keepingCurrentDirectory: true)
    }

    private func invalidateSearchIndex(keepingCurrentDirectory: Bool) {
        searchIndexGeneration += 1
        searchIndexTask?.cancel()
        searchIndexTask = nil
        isSearchIndexWarming = false
        isSearchIndexValid = false
        searchIndex = []
        searchResults = []
        searchState = .idle
        if keepingCurrentDirectory {
            directoryCache = directoryCache.filter { $0.key == FileBrowserPathing.normalized(currentPath) }
        } else {
            directoryCache = [:]
        }
        previewCache = [:]
    }

    private func warmSearchIndex(using smbService: SMBServicing) {
        guard connectionState == .connected, !isSearchIndexValid, searchIndexTask == nil else {
            return
        }

        isSearchIndexWarming = true
        let generation = searchIndexGeneration
        let task = Task<[SMBSearchIndexEntry], Error> { @MainActor [weak self] in
            guard let self else {
                return []
            }
            return try await self.buildSearchIndex(rootPath: self.rootPath, using: smbService)
        }
        searchIndexTask = task

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                let entries = try await task.value
                guard generation == self.searchIndexGeneration else {
                    return
                }
                self.searchIndex = entries
                self.isSearchIndexValid = true
                self.isSearchIndexWarming = false
                self.searchIndexTask = nil
                self.persistSearchIndexIfNeeded()

                let query = self.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                if query.isEmpty {
                    self.searchState = .idle
                } else {
                    self.applySearch(query: query)
                    self.searchState = .ready(self.searchResults.count)
                }
            } catch is CancellationError {
                guard generation == self.searchIndexGeneration else {
                    return
                }
                self.isSearchIndexWarming = false
                self.searchIndexTask = nil
            } catch {
                guard generation == self.searchIndexGeneration else {
                    return
                }
                self.searchIndex = []
                self.isSearchIndexValid = false
                self.isSearchIndexWarming = false
                self.searchIndexTask = nil

                if self.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.searchState = .idle
                } else {
                    self.searchState = .failed(error.localizedDescription)
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func currentOrNewSearchIndex(using smbService: SMBServicing) async throws -> [SMBSearchIndexEntry] {
        if let searchIndexTask {
            let entries = try await searchIndexTask.value
            searchIndex = entries
            isSearchIndexValid = true
            isSearchIndexWarming = false
            self.searchIndexTask = nil
            persistSearchIndexIfNeeded()
            return entries
        }

        let entries = try await buildSearchIndex(rootPath: rootPath, using: smbService)
        searchIndex = entries
        isSearchIndexValid = true
        persistSearchIndexIfNeeded()
        return entries
    }

    private func buildSearchIndex(rootPath: String, using smbService: SMBServicing) async throws -> [SMBSearchIndexEntry] {
        var visitedDirectories: Set<String> = []
        var entries: [SMBSearchIndexEntry] = []
        try await crawl(path: FileBrowserPathing.normalized(rootPath), using: smbService, visitedDirectories: &visitedDirectories, entries: &entries)
        return entries.sorted { localizedName($0.item) < localizedName($1.item) }
    }

    private func crawl(
        path: String,
        using smbService: SMBServicing,
        visitedDirectories: inout Set<String>,
        entries: inout [SMBSearchIndexEntry]
    ) async throws {
        let normalizedPath = FileBrowserPathing.normalized(path)
        guard visitedDirectories.insert(normalizedPath).inserted else {
            return
        }

        let children: [SMBItem]
        if let cached = directoryCache[normalizedPath] {
            children = cached
        } else {
            children = try await smbService.list(path: normalizedPath)
        }

        for child in children {
            entries.append(searchEntry(for: child))
            if child.isDirectory {
                try await crawl(path: child.path, using: smbService, visitedDirectories: &visitedDirectories, entries: &entries)
            }
        }
    }

    private func applySearch(query rawQuery: String) {
        let tokens = rawQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(separator: " ")
            .map(String.init)

        guard !tokens.isEmpty else {
            searchResults = []
            return
        }

        searchResults = searchIndex
            .filter { entry in
                tokens.allSatisfy { entry.searchableText.contains($0) }
            }
            .map(\.item)
            .sorted(by: compareItems)
    }

    private func searchEntry(for item: SMBItem, path: String? = nil, name: String? = nil) -> SMBSearchIndexEntry {
        SMBSearchIndexEntry(
            path: FileBrowserPathing.normalized(path ?? item.path),
            name: name ?? item.name,
            isDirectory: item.isDirectory,
            size: item.size,
            modifiedAt: item.modifiedAt
        )
    }

    private func replaceSearchEntries(in directoryPath: String, with children: [SMBItem]) {
        guard isSearchIndexValid else {
            return
        }

        let normalizedDirectoryPath = FileBrowserPathing.normalized(directoryPath)
        searchIndex.removeAll { FileBrowserPathing.parentPath(of: $0.path) == normalizedDirectoryPath }
        searchIndex += children.map { searchEntry(for: $0) }
        searchIndex = sortedSearchEntries(searchIndex)
    }

    private func upsertSearchEntries(_ entries: [SMBSearchIndexEntry]) {
        guard isSearchIndexValid, !entries.isEmpty else {
            return
        }

        let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        searchIndex.removeAll { byPath[$0.path] != nil }
        searchIndex += entries
        searchIndex = sortedSearchEntries(searchIndex)
    }

    private func removeSearchEntries(for items: [SMBItem]) {
        guard isSearchIndexValid, !items.isEmpty else {
            return
        }

        let removedPrefixes = items.map { FileBrowserPathing.normalized($0.path) }
        searchIndex.removeAll { entry in
            removedPrefixes.contains { prefix in
                entry.path == prefix || entry.path.hasPrefix(prefix + "/")
            }
        }
        discardDirectoryCache(prefixedBy: removedPrefixes)
    }

    private func rebaseSearchEntries(from oldPath: String, to newPath: String, fallback item: SMBItem) {
        guard isSearchIndexValid else {
            return
        }

        let normalizedOldPath = FileBrowserPathing.normalized(oldPath)
        let normalizedNewPath = FileBrowserPathing.normalized(newPath)
        let renamedItemName = normalizedNewPath.split(separator: "/").last.map(String.init) ?? item.name
        var didUpdate = false

        searchIndex = searchIndex.map { entry in
            guard entry.path == normalizedOldPath || entry.path.hasPrefix(normalizedOldPath + "/") else {
                return entry
            }

            didUpdate = true
            let suffix = String(entry.path.dropFirst(normalizedOldPath.count))
            let rebasedPath = normalizedNewPath + suffix
            return SMBSearchIndexEntry(
                path: rebasedPath,
                name: entry.path == normalizedOldPath ? renamedItemName : entry.name,
                isDirectory: entry.isDirectory,
                size: entry.size,
                modifiedAt: entry.modifiedAt
            )
        }

        if !didUpdate {
            searchIndex.append(searchEntry(for: item, path: normalizedNewPath, name: renamedItemName))
        }

        discardDirectoryCache(prefixedBy: [normalizedOldPath])
        discardDirectoryCache(at: FileBrowserPathing.parentPath(of: normalizedNewPath))
        searchIndex = sortedSearchEntries(searchIndex)
    }

    private func discardDirectoryCache(at path: String) {
        directoryCache.removeValue(forKey: FileBrowserPathing.normalized(path))
    }

    private func discardDirectoryCache(prefixedBy prefixes: [String]) {
        guard !prefixes.isEmpty else {
            return
        }

        directoryCache = directoryCache.filter { cachedPath, _ in
            !prefixes.contains { prefix in
                let normalizedPrefix = FileBrowserPathing.normalized(prefix)
                return cachedPath == normalizedPrefix || cachedPath.hasPrefix(normalizedPrefix + "/")
            }
        }
    }

    private func persistSearchIndexIfNeeded() {
        guard isSearchIndexValid, let searchIndexScopeKey else {
            return
        }

        do {
            try searchIndexPersistence.saveEntries(searchIndex, for: searchIndexScopeKey)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func sortedSearchEntries(_ entries: [SMBSearchIndexEntry]) -> [SMBSearchIndexEntry] {
        entries.sorted { lhs, rhs in
            let left = lhs.item
            let right = rhs.item

            if localizedName(left) != localizedName(right) {
                return localizedName(left) < localizedName(right)
            }

            return left.path < right.path
        }
    }

    static func searchIndexScopeKey(for details: SMBConnectionDetails) -> String {
        [
            details.trimmedHost,
            String(details.port),
            details.shareName.trimmingCharacters(in: .whitespacesAndNewlines),
            details.username.trimmingCharacters(in: .whitespacesAndNewlines),
            details.normalizedStartPath
        ].joined(separator: "|")
    }

}
