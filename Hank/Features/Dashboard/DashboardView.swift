import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UIKit
import OSLog

private struct IncomingImportError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

enum RootTab: String, CaseIterable, Hashable, Identifiable {
    case dashboard
    case calendar
    case notes
    case fileServer
    case chat
    case settings

    static let orderStorageKey = "Hank.RootTabOrder.v1"
    static let defaultOrder: [RootTab] = [.dashboard, .calendar, .notes, .chat, .fileServer, .settings]

    static func resolvedOrder(from rawValue: String) -> [RootTab] {
        let savedTabs = rawValue
            .split(separator: ",")
            .compactMap { RootTab(rawValue: String($0)) }
            .reduce(into: [RootTab]()) { result, tab in
                guard !result.contains(tab) else {
                    return
                }
                result.append(tab)
            }

        guard !savedTabs.isEmpty else {
            return defaultOrder
        }

        return savedTabs + defaultOrder.filter { !savedTabs.contains($0) }
    }

    static func serialize(_ tabs: [RootTab]) -> String {
        tabs.map(\.rawValue).joined(separator: ",")
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard:
            "Dashboard"
        case .calendar:
            "Calendar"
        case .notes:
            "Notes"
        case .fileServer:
            "File Server"
        case .chat:
            "Hank"
        case .settings:
            "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard:
            "rectangle.grid.2x2"
        case .calendar:
            "calendar"
        case .notes:
            "note.text"
        case .fileServer:
            "folder"
        case .chat:
            "message"
        case .settings:
            "gearshape"
        }
    }
}

private enum RootTabItem: Hashable {
    case tab(RootTab)
    case more
}

struct RootTabView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var appState: AppState
    @StateObject private var dashboardStore = DashboardStore()
    @StateObject private var calendarStore = CalendarStore()
    @StateObject private var notesStore = NotesStore()
    @StateObject private var fileBrowserStore = FileBrowserStore()
    @StateObject private var hankAssistantStore = HankAssistantStore()
    @StateObject private var settingsStore = SettingsStore()
    @State private var incomingPayloads: [IncomingSharePayload] = []
    @State private var incomingImportError: String?
    @State private var isShowingIncomingImport = false
    @State private var selectedTab = RootTab.dashboard
    @State private var selectedOverflowTab: RootTab?
    @State private var pendingNotesImportPayload: IncomingSharePayload?
    @State private var shouldAutoChooseIncomingNotesDestination = false
    @State private var hasScannedStartupIncomingShares = false
    @State private var launchSessionID = UUID()
    @State private var requestedSettingsSection: SettingsSectionID?
    @State private var hasEnteredBackgroundSinceLaunch = false
    @State private var appLifecycleTask: Task<Void, Never>?
    @State private var dashboardHomeResetID = UUID()
    @State private var calendarHomeResetID = UUID()
    @State private var notesHomeResetID = UUID()
    @State private var fileServerHomeResetID = UUID()
    @State private var chatHomeResetID = UUID()
    @State private var settingsHomeResetID = UUID()
    @State private var isKeyboardVisible = false
    @AppStorage(RootTab.orderStorageKey) private var tabOrderRaw = ""
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.dropfile.Hank", category: "RootTabs")
    private let tabBarContentInset: CGFloat = 82

    var body: some View {
        TabView(selection: tabItemSelectionBinding) {
            ForEach(primaryTabs) { tab in
                tabContentView(for: tab)
                    .tabItem {
                        Label(tab.title, systemImage: tab.systemImage)
                    }
                    .tag(RootTabItem.tab(tab))
            }

            if !overflowTabs.isEmpty {
                moreTabContent
                    .tabItem {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .tag(RootTabItem.more)
            }
        }
        .id(launchSessionID)
        .hankScreenBackground()
        .toolbar(isKeyboardVisible ? .hidden : .visible, for: .tabBar)
        .animation(.easeInOut(duration: 0.22), value: isKeyboardVisible)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
        .task(id: appState.profileLoadKey) {
            guard appState.activeProfileID != nil else {
                cancelLifecycleWork()
                incomingPayloads = []
                isShowingIncomingImport = false
                pendingNotesImportPayload = nil
                shouldAutoChooseIncomingNotesDestination = false
                hasScannedStartupIncomingShares = false
                hankAssistantStore.load(profileID: nil, modelContext: modelContext, services: services)
                return
            }
            guard let profileID = appState.activeProfileID else {
                return
            }
            await preloadTabs(profileID: profileID, force: true)
            await prepareSelectedTab(selectedTab, profileID: profileID)
            guard !hasScannedStartupIncomingShares else {
                return
            }
            hasScannedStartupIncomingShares = true
            autoImportTargetedIncomingPayloadIfNeeded()
        }
        .task(id: selectedTab) {
            guard let profileID = appState.activeProfileID else {
                return
            }
            await prepareSelectedTab(selectedTab, profileID: profileID)
        }
        .onChange(of: hankAssistantStore.pendingNavigationTarget) { _, target in
            guard let target else {
                return
            }
            Task { @MainActor in
                await routeAssistantNavigation(target)
                hankAssistantStore.consumePendingNavigationTarget()
            }
        }
        .onReceive(services.notificationService.$pendingDeepLinkURL.compactMap { $0 }) { url in
            Task { @MainActor in
                await routeNotificationDeepLink(url)
                services.notificationService.consumePendingDeepLinkURL()
            }
        }
        .task(id: appState.pendingIncomingImportURL) {
            guard let url = appState.consumePendingIncomingImportURL() else {
                return
            }
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            shouldAutoChooseIncomingNotesDestination = components?.queryItems?.contains(where: {
                $0.name == "destination" && $0.value == "notes"
            }) == true
            loadIncomingPayloads()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                guard appState.activeProfileID != nil else {
                    return
                }
                hasEnteredBackgroundSinceLaunch = true
                cancelLifecycleWork()
                dashboardStore.stopListening()
                fileBrowserStore.prepareForAppBackground()
                appLifecycleTask = Task { @MainActor in
                    await services.disconnectAllSharedSMBServices()
                }

            case .active:
                guard let profileID = appState.activeProfileID else {
                    return
                }
                autoImportTargetedIncomingPayloadIfNeeded()
                guard hasEnteredBackgroundSinceLaunch else {
                    return
                }

                cancelLifecycleWork()
                appLifecycleTask = Task { @MainActor in
                    await services.profileSyncCoordinator.bootstrap(
                        profileID: profileID,
                        modelContext: modelContext,
                        services: services
                    )
                    await services.disconnectAllSharedSMBServices()
                    await prepareSelectedTab(selectedTab, profileID: profileID)
                }

            case .inactive:
                break

            @unknown default:
                break
            }
        }
        .sheet(isPresented: $isShowingIncomingImport) {
            IncomingShareImportSheet(
                payloads: incomingPayloads,
                errorMessage: incomingImportError,
                currentSMBPath: fileBrowserStore.currentPath,
                notesOutlineItems: notesStore.outlineItems,
                selectedNotesPayload: pendingNotesImportPayload,
                onChooseNotesDestination: choosePayloadNoteDestination,
                onImportToNote: importPayloadToNote,
                onBackFromNoteSelection: {
                    pendingNotesImportPayload = nil
                },
                onImportToSMB: importPayloadToSMB,
                onDismiss: {
                    pendingNotesImportPayload = nil
                    isShowingIncomingImport = false
                }
            )
        }
    }

    private var orderedTabs: [RootTab] {
        RootTab.resolvedOrder(from: tabOrderRaw)
    }

    private var primaryTabs: [RootTab] {
        Array(orderedTabs.prefix(4))
    }

    private var overflowTabs: [RootTab] {
        Array(orderedTabs.dropFirst(4))
    }

    private var tabItemSelectionBinding: Binding<RootTabItem> {
        Binding(
            get: {
                primaryTabs.contains(selectedTab) ? .tab(selectedTab) : .more
            },
            set: { item in
                switch item {
                case .tab(let tab):
                    selectedOverflowTab = nil
                    selectRootTab(tab, source: .nativeTab)
                case .more:
                    selectedOverflowTab = nil
                    selectedTab = overflowTabs.first ?? .settings
                    logger.notice("Root tab selected custom More source=\(RootTabSelectionSource.nativeTab.rawValue, privacy: .public)")
                }
            }
        )
    }

    private var settingsTabContent: some View {
        tabContent(
            SettingsView(
                store: settingsStore,
                calendarStore: calendarStore,
                requestedSection: $requestedSettingsSection,
                orderedTabs: orderedTabs,
                moveRootTab: moveRootTab,
                resetRootTabOrder: resetRootTabOrder,
                bottomContentInset: tabBarContentInset
            ),
            for: .settings
        )
    }

    @ViewBuilder
    private var moreTabContent: some View {
        if let selectedOverflowTab {
            tabContentView(for: selectedOverflowTab)
        } else {
            tabContent(
                MoreTabView(tabs: overflowTabs) { tab in
                    selectRootTab(tab, source: .nativeTab)
                },
                for: .settings
            )
        }
    }

    @ViewBuilder
    private func tabContentView(for tab: RootTab) -> some View {
        switch tab {
        case .dashboard:
            tabContent(DashboardView(store: dashboardStore), for: .dashboard)

        case .calendar:
            tabContent(
                CalendarView(store: calendarStore) {
                    requestedSettingsSection = .calendar
                    selectRootTab(.settings, source: .programmaticSettings)
                },
                for: .calendar
            )

        case .notes:
            tabContent(
                NotesView(
                    store: notesStore,
                    bottomContentInset: 0
                ),
                for: .notes
            )

        case .fileServer:
            tabContent(FileBrowserView(store: fileBrowserStore), for: .fileServer)

        case .chat:
            tabContent(
                HankAssistantView(
                    store: hankAssistantStore,
                    calendarStore: calendarStore,
                    bottomContentInset: 0
                ),
                for: .chat
            )

        case .settings:
            settingsTabContent
        }
    }

    private func preloadTabs(profileID: UUID, force: Bool) async {
        await dashboardStore.loadIfNeeded(profileID: profileID, modelContext: modelContext, services: services, force: force)
        settingsStore.load(profileID: profileID, modelContext: modelContext, services: services, forceReload: force)
        await settingsStore.refreshHankRemoteCloudState(
            modelContext: modelContext,
            services: services,
            reportErrors: false
        )
    }

    private func prepareSelectedTab(_ tab: RootTab, profileID: UUID) async {
        switch tab {
        case .dashboard:
            await dashboardStore.resumeListeningIfNeeded(profileID: profileID, modelContext: modelContext, services: services)

        case .calendar:
            await calendarStore.loadIfNeeded(profileID: profileID, modelContext: modelContext, services: services)

        case .notes:
            await notesStore.loadIfNeeded(profileID: profileID, modelContext: modelContext, services: services)

        case .fileServer:
            await fileBrowserStore.resumeCachedConnectionIfNeeded(profileID: profileID, modelContext: modelContext, services: services)

        case .chat:
            if hankAssistantStore.activeProfileID != profileID {
                hankAssistantStore.load(profileID: profileID, modelContext: modelContext, services: services)
            }

        case .settings:
            settingsStore.load(profileID: profileID, modelContext: modelContext, services: services)
        }
    }

    private func tabContent<Content: View>(_ content: Content, for tab: RootTab) -> some View {
        content
            .id(homeResetID(for: tab))
    }

    private func selectRootTab(_ tab: RootTab, source: RootTabSelectionSource) {
        let previousTab = selectedTab
        let isOverflowTab = overflowTabs.contains(tab)
        guard previousTab != tab || isOverflowTab else {
            logger.notice("Root tab reselected tab=\(tab.rawValue, privacy: .public) source=\(source.rawValue, privacy: .public)")
            resetSelectedTabToHome(tab)
            return
        }

        logger.notice("Root tab selected tab=\(tab.rawValue, privacy: .public) source=\(source.rawValue, privacy: .public) previous=\(previousTab.rawValue, privacy: .public)")
        if isOverflowTab {
            selectedTab = tab
            selectedOverflowTab = tab
        } else {
            selectedTab = tab
            selectedOverflowTab = nil
        }
        guard let profileID = appState.activeProfileID else {
            return
        }
        Task { @MainActor in
            await prepareSelectedTab(tab, profileID: profileID)
        }
    }

    private func moveRootTab(_ tab: RootTab, by offset: Int) {
        var tabs = orderedTabs
        guard
            let currentIndex = tabs.firstIndex(of: tab),
            offset != 0
        else {
            return
        }

        let proposedIndex = currentIndex + offset
        let newIndex = min(max(proposedIndex, tabs.startIndex), tabs.index(before: tabs.endIndex))
        guard newIndex != currentIndex else {
            return
        }

        tabs.remove(at: currentIndex)
        tabs.insert(tab, at: newIndex)
        tabOrderRaw = RootTab.serialize(tabs)
        logger.notice("Root tab order changed order=\(tabOrderRaw, privacy: .public)")
    }

    private func resetRootTabOrder() {
        tabOrderRaw = ""
        logger.notice("Root tab order reset")
    }

    private func homeResetID(for tab: RootTab) -> UUID {
        switch tab {
        case .dashboard:
            dashboardHomeResetID
        case .calendar:
            calendarHomeResetID
        case .notes:
            notesHomeResetID
        case .fileServer:
            fileServerHomeResetID
        case .chat:
            chatHomeResetID
        case .settings:
            settingsHomeResetID
        }
    }

    private func resetSelectedTabToHome(_ tab: RootTab) {
        switch tab {
        case .dashboard:
            dashboardHomeResetID = UUID()

        case .calendar:
            calendarHomeResetID = UUID()
            Task { @MainActor in
                await calendarStore.resetToHome()
            }

        case .notes:
            notesHomeResetID = UUID()
            notesStore.resetToHome()

        case .fileServer:
            fileServerHomeResetID = UUID()
            Task { @MainActor in
                await fileBrowserStore.resetToHome(services: services)
            }

        case .chat:
            chatHomeResetID = UUID()
            hankAssistantStore.resetToHome()

        case .settings:
            settingsHomeResetID = UUID()
            requestedSettingsSection = nil
        }
    }

    private func cancelLifecycleWork() {
        appLifecycleTask?.cancel()
        appLifecycleTask = nil
    }

    private func autoImportTargetedIncomingPayloadIfNeeded() {
        do {
            let payloads = try services.localFileService.incomingPayloads()
            guard let targetedPayload = payloads.first(where: { $0.destinationNoteID != nil && $0.canImportToNotes }),
                  let destinationNoteID = targetedPayload.destinationNoteID else {
                return
            }
            incomingPayloads = payloads
            incomingImportError = nil
            pendingNotesImportPayload = nil
            isShowingIncomingImport = false
            importPayloadToNote(targetedPayload, destinationNoteID)
        } catch {
            incomingImportError = error.localizedDescription
        }
    }

    private func loadIncomingPayloads() {
        do {
            incomingPayloads = try services.localFileService.incomingPayloads()
            incomingImportError = nil
            pendingNotesImportPayload = nil
            isShowingIncomingImport = !incomingPayloads.isEmpty
            if let targetedPayload = incomingPayloads.first(where: { $0.destinationNoteID != nil && $0.canImportToNotes }),
               let destinationNoteID = targetedPayload.destinationNoteID {
                shouldAutoChooseIncomingNotesDestination = false
                importPayloadToNote(targetedPayload, destinationNoteID)
                return
            }
            let autoNotesPayload = shouldAutoChooseIncomingNotesDestination
                ? incomingPayloads.first(where: \.canImportToNotes)
                : (incomingPayloads.count == 1 ? incomingPayloads.first(where: \.canImportToNotes) : nil)
            shouldAutoChooseIncomingNotesDestination = false
            if let payload = autoNotesPayload {
                choosePayloadNoteDestination(payload)
            }
        } catch {
            incomingImportError = error.localizedDescription
            incomingPayloads = []
            pendingNotesImportPayload = nil
            shouldAutoChooseIncomingNotesDestination = false
            isShowingIncomingImport = true
        }
    }

    private func choosePayloadNoteDestination(_ payload: IncomingSharePayload) {
        Task { @MainActor in
            do {
                guard payload.canImportToNotes else {
                    throw IncomingImportError(message: IncomingSharePayloadError.unsupportedNotesImport.localizedDescription)
                }
                try await ensureNotesStoreLoaded()
                selectRootTab(.notes, source: .incomingImport)
                pendingNotesImportPayload = payload
            } catch {
                incomingImportError = error.localizedDescription
            }
        }
    }

    private func importPayloadToNote(_ payload: IncomingSharePayload, _ noteID: UUID) {
        Task { @MainActor in
            do {
                guard payload.canImportToNotes else {
                    throw IncomingImportError(message: IncomingSharePayloadError.unsupportedNotesImport.localizedDescription)
                }
                try await ensureNotesStoreLoaded()
                let url = try services.localFileService.sourceURL(for: payload)
                let text = try payload.decodeNotesText(from: Data(contentsOf: url))
                try notesStore.appendSharedContent(
                    to: noteID,
                    kind: payload.kind,
                    text: text,
                    revealImportedNote: false
                )
                try await notesStore.persistNowOrThrow()
                pendingNotesImportPayload = nil
                try finishIncomingPayload(payload)
            } catch {
                incomingImportError = error.localizedDescription
            }
        }
    }

    private func importPayloadToSMB(_ payload: IncomingSharePayload) {
        Task { @MainActor in
            do {
                try await ensureFileBrowserStoreLoaded()
                let url = try services.localFileService.sourceURL(for: payload)
                await fileBrowserStore.uploadFiles(from: [url], services: services)
                if fileBrowserStore.errorMessage == nil {
                    try finishIncomingPayload(payload)
                } else {
                    incomingImportError = fileBrowserStore.errorMessage
                }
            } catch {
                incomingImportError = error.localizedDescription
            }
        }
    }

    private func ensureNotesStoreLoaded() async throws {
        guard let profileID = appState.activeProfileID else {
            throw NotesServiceError.workspaceUnavailable
        }

        await notesStore.load(profileID: profileID, modelContext: modelContext, services: services)
        if case .unavailable(let message) = notesStore.loadState {
            throw IncomingImportError(message: message)
        }
    }

    private func ensureFileBrowserStoreLoaded() async throws {
        guard let profileID = appState.activeProfileID else {
            throw IncomingImportError(message: "Sign in to a profile before importing shared files.")
        }

        await fileBrowserStore.loadIfNeeded(profileID: profileID, modelContext: modelContext, services: services)
        switch fileBrowserStore.connectionState {
        case .connected:
            return
        case .connections:
            if let selectedConnectionID = fileBrowserStore.selectedConnectionID {
                await fileBrowserStore.selectConnection(
                    selectedConnectionID,
                    profileID: profileID,
                    modelContext: modelContext,
                    services: services
                )
                if fileBrowserStore.connectionState == .connected {
                    return
                }
            }
            throw IncomingImportError(message: "Choose an SMB connection in File Server before importing there.")
        case .failed(let message):
            throw IncomingImportError(message: message)
        case .needsSetup:
            throw IncomingImportError(message: "Configure the profile's SMB share before importing there.")
        case .connecting:
            throw IncomingImportError(message: "Connecting to the SMB share. Try the import again in a moment.")
        }
    }

    private func routeAssistantNavigation(_ target: HankAssistantNavigationTarget) async {
        guard let profileID = appState.activeProfileID else {
            return
        }

        switch target.kind {
        case .note(let noteID, let searchQuery):
            do {
                try await ensureNotesStoreLoaded()
                notesStore.select(noteID, editorSearch: searchQuery)
                selectRootTab(.notes, source: .assistantNavigation)
            } catch {
                notesStore.errorMessage = error.localizedDescription
            }

        case .calendar(let date, let eventID):
            await calendarStore.load(profileID: profileID, modelContext: modelContext, services: services)
            await calendarStore.focus(on: date, highlightedEventID: eventID)
            selectRootTab(.calendar, source: .assistantNavigation)

        case .file(let path):
            selectRootTab(.fileServer, source: .assistantNavigation)
            await fileBrowserStore.assistantOpenPath(
                path,
                profileID: profileID,
                modelContext: modelContext,
                services: services
            )

        case .homeAssistant(let entityID):
            selectRootTab(.dashboard, source: .assistantNavigation)
            await dashboardStore.load(profileID: profileID, modelContext: modelContext, services: services)
            dashboardStore.presentAssistantEntity(entityID: entityID)
        }
    }

    private func routeNotificationDeepLink(_ url: URL) async {
        guard url.scheme == "hank", url.host == "notifications" else {
            return
        }

        let pathComponents = url.pathComponents.filter { $0 != "/" }
        guard let destination = pathComponents.first else {
            return
        }

        switch destination {
        case "storage":
            requestedSettingsSection = .remote
            selectRootTab(.settings, source: .notification)

        case "notes":
            guard pathComponents.count > 1, let noteID = UUID(uuidString: pathComponents[1]) else {
                selectRootTab(.notes, source: .notification)
                return
            }
            do {
                try await ensureNotesStoreLoaded()
                notesStore.select(noteID)
                selectRootTab(.notes, source: .notification)
            } catch {
                notesStore.errorMessage = error.localizedDescription
            }

        case "dashboard":
            guard let profileID = appState.activeProfileID else {
                return
            }
            selectRootTab(.dashboard, source: .notification)
            await dashboardStore.load(profileID: profileID, modelContext: modelContext, services: services)
            if pathComponents.count > 1 {
                dashboardStore.presentAssistantEntity(entityID: pathComponents[1])
            }

        default:
            break
        }
    }

    private func finishIncomingPayload(_ payload: IncomingSharePayload) throws {
        try services.localFileService.clearIncomingPayload(payload)
        incomingPayloads.removeAll { $0.id == payload.id }
        if pendingNotesImportPayload?.id == payload.id {
            pendingNotesImportPayload = nil
        }
        if incomingPayloads.isEmpty {
            isShowingIncomingImport = false
        }
    }
}

private enum RootTabSelectionSource: String {
    case nativeTab
    case programmaticSettings
    case assistantNavigation
    case incomingImport
    case notification
}

private struct MoreTabView: View {
    let tabs: [RootTab]
    let onSelect: (RootTab) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("More")
                            .font(.largeTitle.bold())
                            .foregroundStyle(.white)

                        Text("Open the rest of your Hank workspace.")
                            .font(.subheadline)
                            .foregroundStyle(Color.white.opacity(0.68))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 12)

                    VStack(spacing: 10) {
                        ForEach(tabs) { tab in
                            Button {
                                onSelect(tab)
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: tab.systemImage)
                                        .font(.title3.weight(.semibold))
                                        .foregroundStyle(HankTheme.accent)
                                        .frame(width: 34, height: 34)
                                        .background(HankTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                                    Text(tab.title)
                                        .font(.headline)
                                        .foregroundStyle(.white)

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(Color.white.opacity(0.46))
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .hankCard(fill: HankTheme.surface, padding: 14)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .scrollContentBackground(.hidden)
            .hankScreenBackground()
            .navigationBarTitleDisplayMode(.inline)
            .hankNavigationChrome()
        }
        .hankScreenBackground()
    }
}

private struct IncomingShareImportSheet: View {
    let payloads: [IncomingSharePayload]
    let errorMessage: String?
    let currentSMBPath: String
    let notesOutlineItems: [NoteOutlineItem]
    let selectedNotesPayload: IncomingSharePayload?
    let onChooseNotesDestination: (IncomingSharePayload) -> Void
    let onImportToNote: (IncomingSharePayload, UUID) -> Void
    let onBackFromNoteSelection: () -> Void
    let onImportToSMB: (IncomingSharePayload) -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(HankTheme.error)
                        .listRowBackground(HankTheme.errorSurface)
                }

                if let selectedNotesPayload {
                    Section {
                        ForEach(Array(notesOutlineItems.filter { $0.entry.pageType == .text }.enumerated()), id: \.element.id) { _, item in
                            Button {
                                onImportToNote(selectedNotesPayload, item.id)
                            } label: {
                                IncomingShareNoteDestinationRow(item: item)
                            }
                        }
                    } footer: {
                        Text(notePickerFooterText(for: selectedNotesPayload))
                    }
                    .listRowBackground(HankTheme.surface)
                } else {
                    ForEach(payloads) { payload in
                        Section {
                            if payload.canImportToNotes {
                                Button(payload.notesActionTitle) {
                                    onChooseNotesDestination(payload)
                                }
                            }
                            Button("Upload To Current SMB Folder") {
                                onImportToSMB(payload)
                            }
                        } header: {
                            Text(payload.suggestedName)
                        } footer: {
                            Text(footerText(for: payload))
                        }
                        .listRowBackground(HankTheme.surface)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(HankTheme.background)
            .navigationTitle(selectedNotesPayload == nil ? "Import To Hank" : "Choose Note")
            .navigationBarTitleDisplayMode(.inline)
            .hankNavigationChrome()
            .hankScreenBackground()
            .toolbar {
                if selectedNotesPayload != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back", action: onBackFromNoteSelection)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDismiss)
                }
            }
        }
    }

    private func footerText(for payload: IncomingSharePayload) -> String {
        let destination = currentSMBPath.isEmpty ? "SMB destination: share root" : "SMB destination: \(currentSMBPath)"
        guard !payload.canImportToNotes else {
            return destination
        }

        return destination + "\nFiles can be uploaded to SMB but not imported into Notes."
    }

    private func notePickerFooterText(for payload: IncomingSharePayload) -> String {
        switch payload.kind {
        case .text:
            return "Tap a note to append the shared text."
        case .url:
            return "Tap a note to append the shared link as a hyperlink."
        case .file:
            return "Files can be uploaded to SMB but not imported into Notes."
        }
    }
}

private struct IncomingShareNoteDestinationRow: View {
    let item: NoteOutlineItem

    var body: some View {
        HStack(spacing: 12) {
            Color.clear
                .frame(width: indentationWidth, height: 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .foregroundStyle(Color.white)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.68))
            }
        }
        .contentShape(Rectangle())
    }

    private var title: String {
        let trimmedTitle = item.entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? NoteTreeManager.rootNoteTitle : trimmedTitle
    }

    private var subtitle: String {
        item.entry.parentID == nil ? "Top level note" : "Subnote"
    }

    private var indentationWidth: CGFloat {
        CGFloat(item.depth) * 18
    }
}

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var appState: AppState
    @ObservedObject var store: DashboardStore
    @State private var draggedTileID: String?
    @State private var titleEditor: DashboardTileTitleEditor?
    @State private var deleteConfirmation: DashboardTileDeleteConfirmation?

    var body: some View {
        NavigationStack {
            Group {
                switch store.connectionState {
                case .needsSetup:
                    ContentUnavailableView(
                        "Home Assistant Not Configured",
                        systemImage: "bolt.horizontal.circle",
                        description: Text("Configure Home Assistant from the Hank Serverside dashboard, then come back here to build the dashboard.")
                    )
                    .hankScreenBackground()
                case .loading:
                    ProgressView("Loading dashboard…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .hankScreenBackground()
                case .failed(let message):
                    ContentUnavailableView(
                        "Dashboard Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                    .hankScreenBackground()
                case .connected:
                    dashboardContent
                }
            }
            .navigationTitle("Hank Dashboard")
            .navigationBarTitleDisplayMode(.inline)
            .hankNavigationChrome()
            .hankScreenBackground()
            .overlay(alignment: .topTrailing) {
                dashboardAddButton
                    .padding(.top, 24)
                    .padding(.trailing, 16)
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Hank Dashboard")
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                }
            }
            .task(id: appState.profileLoadKey) {
                guard let profileID = appState.activeProfileID else {
                    return
                }
                await store.loadIfNeeded(profileID: profileID, modelContext: modelContext, services: services)
            }
            .onDisappear {
                store.stopListening()
            }
            .sheet(isPresented: $store.isShowingEntityPicker) {
                entityPicker
            }
            .alert("Rename Tile", isPresented: renameAlertBinding) {
                TextField(titleEditor?.placeholder ?? "Tile title", text: titleDraftBinding)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) {
                    titleEditor = nil
                }
                Button("Save") {
                    guard let titleEditor else {
                        return
                    }
                    store.saveTileEdits(
                        shortcutID: titleEditor.shortcutID,
                        label: titleEditor.draft,
                        modelContext: modelContext
                    )
                    self.titleEditor = nil
                }
            } message: {
                Text("Update the title shown on this dashboard tile.")
            }
            .alert(item: $deleteConfirmation) { confirmation in
                Alert(
                    title: Text("Delete Tile?"),
                    message: Text("Remove \(confirmation.title) from the dashboard?"),
                    primaryButton: .destructive(Text("Delete")) {
                        store.removeShortcut(shortcutID: confirmation.shortcutID, modelContext: modelContext)
                    },
                    secondaryButton: .cancel()
                )
            }
            .onChange(of: store.isEditing) { _, isEditing in
                if !isEditing {
                    draggedTileID = nil
                    titleEditor = nil
                    deleteConfirmation = nil
                }
            }
        }
    }

    private var dashboardAddButton: some View {
        Button {
            store.setEditing(true)
            store.isShowingEntityPicker = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(HankTheme.accent)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add Dashboard Entity")
        .disabled(!store.canEditDashboard || store.connectionState != .connected)
        .opacity(store.canEditDashboard && store.connectionState == .connected ? 1 : 0.82)
    }

    private var dashboardContent: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let errorMessage = store.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(HankTheme.error)
                        .hankCard(fill: HankTheme.errorSurface, padding: 14)
                }

                if store.tiles.isEmpty {
                    ContentUnavailableView(
                        "No Dashboard Buttons",
                        systemImage: "plus.circle",
                        description: Text("Tap the plus button to add entities from Home Assistant.")
                    )
                    .frame(maxWidth: .infinity)
                    .hankCard(fill: HankTheme.surface)
                } else {
                    Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 12) {
                        ForEach(store.gridRows) { row in
                            GridRow {
                                if let tile = row.fullWidthTile {
                                    tileCell(tile)
                                        .gridCellColumns(2)
                                } else {
                                    if let leading = row.leading {
                                        gridSlotView(leading)
                                    }
                                    if let trailing = row.trailing {
                                        gridSlotView(trailing)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
        .refreshable {
            guard let profileID = appState.activeProfileID else {
                return
            }
            await store.refresh(profileID: profileID, modelContext: modelContext, services: services)
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func gridSlotView(_ slot: DashboardGridSlot) -> some View {
        switch slot {
        case .tile(let tile):
            tileCell(tile)
        case .empty(let row, let column):
            DashboardEmptyGridCell(isEditing: store.isEditing)
                .onDrop(
                    of: [UTType.text.identifier],
                    delegate: DashboardGridCellDropDelegate(
                        destinationRow: row,
                        destinationColumn: column,
                        store: store,
                        draggedTileID: $draggedTileID,
                        modelContext: modelContext
                    )
                )
        }
    }

    private func tileCell(_ tile: DashboardTileModel) -> some View {
        DashboardTileCard(
            tile: tile,
            isEditing: store.isEditing,
            isPerformingAction: store.isPerformingAction,
            fullWidth: tile.tileSize == .expanded,
            onSelect: {
                guard let profileID = appState.activeProfileID else {
                    return
                }
                if store.isEditing {
                    return
                } else {
                    Task {
                        await store.performPrimaryAction(
                            tile,
                            profileID: profileID,
                            modelContext: modelContext,
                            services: services
                        )
                    }
                }
            },
            onEditModeRequested: {
                store.setEditing(true)
            },
            onTitleEdit: {
                titleEditor = DashboardTileTitleEditor(tile: tile)
            },
            onDelete: {
                deleteConfirmation = DashboardTileDeleteConfirmation(tile: tile)
            },
            onBrightnessChange: { brightnessPercent in
                guard let profileID = appState.activeProfileID else {
                    return
                }

                Task {
                    await store.setBrightness(
                        brightnessPercent,
                        for: tile,
                        profileID: profileID,
                        modelContext: modelContext,
                        services: services
                    )
                }
            },
            onResize: { tileSize in
                withAnimation(.snappy(duration: 0.28, extraBounce: 0.08)) {
                    store.setTileSize(
                        shortcutID: tile.shortcut.id,
                        to: tileSize,
                        modelContext: modelContext
                    )
                }
            }
        )
        .opacity(draggedTileID == tile.id ? 0.78 : 1)
        .scaleEffect(draggedTileID == tile.id ? 0.985 : 1)
        .animation(.easeInOut(duration: 0.18), value: draggedTileID)
        .onDrag {
            guard store.isEditing else {
                return NSItemProvider()
            }

            draggedTileID = tile.id
            return NSItemProvider(object: tile.id as NSString)
        }
        .onDrop(
            of: [UTType.text.identifier],
            delegate: DashboardGridCellDropDelegate(
                destinationRow: tile.gridRow,
                destinationColumn: tile.gridColumn,
                store: store,
                draggedTileID: $draggedTileID,
                modelContext: modelContext
            )
        )
    }

    private var entityPicker: some View {
        NavigationStack {
            List(store.filteredEntities) { entity in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entity.suggestedLabel)
                            .font(.headline)
                        Text(entity.entityID)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        guard let profileID = appState.activeProfileID else {
                            return
                        }
                        store.toggleEntitySelection(entity, profileID: profileID, modelContext: modelContext)
                    } label: {
                        Image(systemName: store.isSelected(entityID: entity.entityID) ? "checkmark.circle.fill" : "plus.circle")
                            .font(.title3)
                            .foregroundStyle(store.isSelected(entityID: entity.entityID) ? HankTheme.success : HankTheme.accent)
                    }
                    .buttonStyle(.plain)
                }
                .hankCard(fill: HankTheme.surface)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .searchable(text: $store.pickerSearchText)
            .navigationTitle("Add Entities")
            .scrollContentBackground(.hidden)
            .background(HankTheme.background)
            .hankNavigationChrome()
            .hankScreenBackground()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        store.isShowingEntityPicker = false
                    }
                }
            }
        }
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { titleEditor != nil },
            set: { isPresented in
                if !isPresented {
                    titleEditor = nil
                }
            }
        )
    }

    private var titleDraftBinding: Binding<String> {
        Binding(
            get: { titleEditor?.draft ?? "" },
            set: { value in
                titleEditor?.draft = value
            }
        )
    }
}

private struct DashboardTileTitleEditor: Identifiable {
    let shortcutID: UUID
    let placeholder: String
    var draft: String

    var id: UUID { shortcutID }

    init(tile: DashboardTileModel) {
        shortcutID = tile.shortcut.id
        placeholder = tile.state?.friendlyName ?? tile.entity.friendlyName
        draft = tile.shortcut.labelOverride ?? ""
    }
}

private struct DashboardTileDeleteConfirmation: Identifiable {
    let shortcutID: UUID
    let title: String

    var id: UUID { shortcutID }

    init(tile: DashboardTileModel) {
        shortcutID = tile.shortcut.id
        title = tile.title
    }
}

private struct DashboardTileCard: View {
    let tile: DashboardTileModel
    let isEditing: Bool
    let isPerformingAction: Bool
    let fullWidth: Bool
    let onSelect: () -> Void
    let onEditModeRequested: () -> Void
    let onTitleEdit: () -> Void
    let onDelete: () -> Void
    let onBrightnessChange: (Int) -> Void
    let onResize: (DashboardTileSize) -> Void

    @State private var sliderValue: Double = 100
    @State private var isAdjustingBrightness = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: showsBrightnessSlider ? 14 : 0) {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: tile.isReadOnly ? 10 : 6) {
                        if isEditing {
                            Button(action: onTitleEdit) {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(tile.title)
                                        .font(fullWidth ? .title3.weight(.semibold) : .headline)
                                        .multilineTextAlignment(.leading)
                                        .lineLimit(2)
                                    Image(systemName: "pencil")
                                        .font(.caption.weight(.semibold))
                                }
                                .foregroundStyle(.primary)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(tile.title)
                                .font(fullWidth ? .title3.weight(.semibold) : .headline)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .lineLimit(2)
                        }

                        if tile.isReadOnly, let readoutValue = tile.readoutValue {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(readoutValue)
                                    .font(fullWidth ? .system(size: 28, weight: .semibold, design: .rounded) : .title3.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)

                                if let readoutUnit = tile.readoutUnit {
                                    Text(readoutUnit)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }

                            Text(tile.subtitle)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            Text(tile.subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 12)

                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(HankTheme.accent.opacity(isEditing ? 0.2 : 0.16))

                        Image(systemName: isEditing ? "slider.horizontal.3" : actionSymbol)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(HankTheme.accent)
                    }
                    .frame(width: fullWidth ? 52 : 46, height: fullWidth ? 52 : 46)
                }

                if showsBrightnessSlider {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Brightness")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)

                            Spacer()

                            Text("\(Int(sliderValue.rounded()))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        Slider(
                            value: $sliderValue,
                            in: 1 ... 100,
                            step: 1,
                            onEditingChanged: handleBrightnessEditingChanged
                        )
                        .tint(HankTheme.accent)
                        .disabled(isEditing || isPerformingAction)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: tileMinHeight, alignment: .leading)
            .padding(16)
            .hankCard(fill: HankTheme.surface, padding: 0)

            if isEditing {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3.weight(.semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, HankTheme.error)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete \(tile.title)")
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

                DashboardTileResizeHandle(tileSize: tile.tileSize)
                    .padding(12)
                    .gesture(
                        DragGesture(minimumDistance: 10)
                            .onChanged { value in
                                guard abs(value.translation.width) >= 40 else {
                                    return
                                }

                                let nextSize: DashboardTileSize = value.translation.width > 0 ? .expanded : .compact
                                guard nextSize != tile.tileSize else {
                                    return
                                }

                                withAnimation(.snappy(duration: 0.28, extraBounce: 0.08)) {
                                    onResize(nextSize)
                                }
                            }
                            .onEnded { value in
                                guard abs(value.translation.width) >= 16 else {
                                    return
                                }

                                let nextSize: DashboardTileSize = value.translation.width > 0 ? .expanded : .compact
                                withAnimation(.snappy(duration: 0.28, extraBounce: 0.08)) {
                                    onResize(nextSize)
                                }
                            }
                    )
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onAppear(perform: syncSliderValue)
        .onChange(of: tile.brightnessPercent) { _, _ in
            guard !isAdjustingBrightness else {
                return
            }
            syncSliderValue()
        }
        .onTapGesture {
            guard isEditing || tile.canPerformPrimaryAction else {
                return
            }

            guard !isPerformingAction, !isAdjustingBrightness else {
                return
            }

            onSelect()
        }
        .contextMenu {
            Button {
                onEditModeRequested()
            } label: {
                Label("Edit Dashboard", systemImage: "square.grid.2x2")
            }

            Button {
                onTitleEdit()
            } label: {
                Label("Rename Tile", systemImage: "pencil")
            }

            Button {
                onResize(tile.tileSize == .expanded ? .compact : .expanded)
            } label: {
                Label(tile.tileSize == .expanded ? "Make Compact" : "Make Expanded", systemImage: "arrow.left.and.right")
            }

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete Tile", systemImage: "trash")
            }
        }
    }

    private var actionSymbol: String {
        if tile.isReadOnly {
            switch (tile.entity.deviceClass ?? tile.state?.deviceClass ?? "").lowercased() {
            case "temperature":
                return "thermometer.medium"
            case "humidity":
                return "humidity.fill"
            case "power":
                return "bolt.fill"
            case "battery":
                return "battery.50"
            default:
                return "waveform.path.ecg"
            }
        }

        return tile.entity.controlStyle == .press ? "play.circle.fill" : "power"
    }

    private var showsBrightnessSlider: Bool {
        tile.supportsBrightness && !isEditing
    }

    private var tileMinHeight: CGFloat {
        if showsBrightnessSlider {
            return fullWidth ? 132 : 124
        }

        if tile.isReadOnly {
            return fullWidth ? 118 : 104
        }

        return fullWidth ? 108 : 96
    }

    private func syncSliderValue() {
        sliderValue = Double(max(tile.brightnessPercent ?? 100, 1))
    }

    private func handleBrightnessEditingChanged(_ isEditingBrightness: Bool) {
        isAdjustingBrightness = isEditingBrightness
        guard !isEditingBrightness else {
            return
        }

        onBrightnessChange(Int(sliderValue.rounded()))
    }
}

private struct DashboardTileResizeHandle: View {
    let tileSize: DashboardTileSize

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tileSize == .expanded ? "arrow.left.to.line.compact" : "arrow.right.to.line.compact")
                .font(.caption.weight(.bold))

            Image(systemName: "arrow.left.and.right")
                .font(.caption.weight(.bold))
        }
        .foregroundStyle(HankTheme.accent)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

private struct DashboardEmptyGridCell: View {
    let isEditing: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(isEditing ? HankTheme.surface.opacity(0.48) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: isEditing ? 1.5 : 0, dash: [6, 6])
                    )
                    .foregroundStyle(HankTheme.accent.opacity(isEditing ? 0.45 : 0))
            )
            .frame(maxWidth: .infinity, minHeight: 96)
    }
}

private struct DashboardGridCellDropDelegate: DropDelegate {
    let destinationRow: Int
    let destinationColumn: Int
    let store: DashboardStore
    @Binding var draggedTileID: String?
    let modelContext: ModelContext

    func dropEntered(info: DropInfo) {
        guard store.isEditing, let draggedTileID else {
            return
        }

        store.moveTile(
            entityID: draggedTileID,
            toRow: destinationRow,
            column: destinationColumn,
            modelContext: modelContext
        )
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedTileID = nil
        return true
    }
}
