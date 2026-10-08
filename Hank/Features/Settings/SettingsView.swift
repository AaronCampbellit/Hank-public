import SwiftData
import SwiftUI
import OSLog
#if canImport(UIKit)
import UIKit
#endif

enum SettingsSectionID: String, CaseIterable, Hashable {
    case remote
    case assistant
    case tabs
    case calendar
    case homeAssistant
    case smb
    case notes
    case advanced

    var title: String {
        switch self {
        case .remote:
            "Hank Remote"
        case .assistant:
            "Assistant"
        case .tabs:
            "Tabs"
        case .calendar:
            "Calendars"
        case .homeAssistant:
            "Home Assistant"
        case .smb:
            "SMB Share"
        case .notes:
            "Notes"
        case .advanced:
            "Advanced"
        }
    }
}

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var services: AppServices
    @ObservedObject var store: SettingsStore
    @ObservedObject var calendarStore: CalendarStore
    @Binding var requestedSection: SettingsSectionID?
    let orderedTabs: [RootTab]
    let moveRootTab: (RootTab, Int) -> Void
    let resetRootTabOrder: () -> Void
    let bottomContentInset: CGFloat

    @State private var isShowingDeleteProfileConfirmation = false
    @State private var browserDestination: HankBrowserDestination?
    @State private var deleteProfileAuthorizationRequest: DeleteProfileAuthorizationRequest?
    @AppStorage("Hank.CollapsedSettingsSections") private var collapsedSettingsSectionsRaw = ""
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.dropfile.Hank", category: "SettingsView")

    var body: some View {
        let resolvedActiveProfile = appState.activeProfile
        NavigationStack {
            VStack(spacing: 0) {
                SettingsBannerStack(
                    infoMessage: store.infoMessage,
                    errorMessage: store.errorMessage
                )

                Form {
                    if let profile = resolvedActiveProfile {
                        Section("Profile") {
                            profileSectionContent(profile)
                        }
                        .listRowBackground(settingsSectionFill)

                        settingsDisclosureSection(.tabs) {
                            tabsSectionContent()
                        }

                        settingsDisclosureSection(.calendar) {
                            calendarSectionContent()
                        }

                        settingsDisclosureSection(.remote) {
                            remoteSectionContent(profile)
                        }

                        settingsDisclosureSection(.smb) {
                            smbSectionContent(profile)
                        }

                        settingsDisclosureSection(.advanced) {
                            advancedSectionContent()
                        }
                    } else {
                        Section {
                            ContentUnavailableView(
                                "No Active Profile",
                                systemImage: "person.crop.circle.badge.exclamationmark",
                                description: Text("Sign in to a profile to manage settings.")
                            )
                        }
                        .listRowBackground(settingsSectionFill)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .contentMargins(.bottom, bottomContentInset + 12, for: .scrollContent)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .hankScreenBackground()
        }
        .hankScreenBackground()
        .onAppear {
            let activeProfileID = appState.activeProfileID?.uuidString ?? "none"
            logger.notice("SettingsView appeared activeProfileID=\(activeProfileID, privacy: .public) collapsedSections=\(collapsedSettingsSectionsRaw, privacy: .public)")
        }
        .task(id: appState.profileLoadKey) {
            guard let profileID = appState.activeProfileID else {
                logger.notice("SettingsView load skipped because no active profile is available")
                return
            }
            let requestedSectionID = requestedSection?.rawValue ?? "none"
            logger.notice("SettingsView load task started profileID=\(profileID.uuidString, privacy: .public) requestedSection=\(requestedSectionID, privacy: .public)")
            store.load(profileID: profileID, modelContext: modelContext, services: services)
            await store.refreshHankRemoteCloudState(modelContext: modelContext, services: services, reportErrors: false)
            await loadCalendarSectionIfNeeded(profileID: profileID, forceReload: false)
            handleRequestedSection(requestedSection)
            logger.notice("SettingsView load task finished")
        }
        .onChange(of: requestedSection) { _, section in
            let requestedSectionID = section?.rawValue ?? "none"
            logger.notice("SettingsView requested section changed to \(requestedSectionID, privacy: .public)")
            handleRequestedSection(section)
            guard section == .calendar, let profileID = appState.activeProfileID else {
                return
            }
            Task {
                await loadCalendarSectionIfNeeded(profileID: profileID, forceReload: true)
            }
        }
        .sheet(item: $browserDestination) { destination in
            HankSafariView(url: destination.url)
        }
        .confirmationDialog(
            "Delete This Profile?",
            isPresented: $isShowingDeleteProfileConfirmation,
            titleVisibility: .visible
        ) {
            if let activeProfileID = appState.activeProfileID {
                Button("Delete Profile", role: .destructive) {
                    deleteProfileAuthorizationRequest = DeleteProfileAuthorizationRequest(
                        profileID: activeProfileID,
                        profileName: appState.activeProfile?.username ?? "Current Profile"
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteProfileMessage)
        }
        .sheet(item: $deleteProfileAuthorizationRequest) { request in
            DeleteProfileAuthorizationSheet(profileName: request.profileName) { password in
                guard store.authorizeProfileDeletion(
                    profileID: request.profileID,
                    password: password,
                    modelContext: modelContext,
                    services: services
                ) else {
                    return
                }

                appState.removeProfile(request.profileID)
            }
        }
    }

    private func settingsDisclosureSection<Content: View>(
        _ section: SettingsSectionID,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        Section {
            DisclosureGroup(isExpanded: sectionExpandedBinding(section)) {
                content()
                    .padding(.top, 6)
            } label: {
                Text(section.title)
            }
            .id(section)
        }
        .listRowBackground(settingsSectionFill)
    }

    private var settingsSectionFill: Color {
        HankTheme.elevatedSurface.opacity(0.82)
    }

    private func profileSectionContent(_ profile: UserProfile) -> some View {
        return Group {
            Text(profile.username)

            Button("Switch Profile") {
                appState.switchProfile()
            }

            Button("Log Out", role: .destructive) {
                appState.logout()
            }

            Button("Delete Profile", role: .destructive) {
                isShowingDeleteProfileConfirmation = true
            }
        }
    }

    private func tabsSectionContent() -> some View {
        return Group {
            ForEach(Array(orderedTabs.enumerated()), id: \.element.id) { index, tab in
                HStack(spacing: 12) {
                    Label(tab.title, systemImage: tab.systemImage)

                    Spacer()

                    Button {
                        moveRootTab(tab, -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(index == orderedTabs.startIndex)
                    .buttonStyle(.borderless)

                    Button {
                        moveRootTab(tab, 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(index == orderedTabs.index(before: orderedTabs.endIndex))
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private func calendarSectionContent() -> some View {
        return Group {
            if calendarStore.savedSources.isEmpty {
                Text("Add iCloud, CalDAV, or web calendar feeds below.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(calendarStore.savedSources.enumerated()), id: \.element.id) { index, source in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(source.title)
                                .foregroundStyle(.primary)

                            Text(source.subtitle)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Toggle(
                            "",
                            isOn: Binding(
                                get: { source.isEnabled },
                                set: { newValue in
                                    Task {
                                        await calendarStore.setSourceEnabled(source.id, isEnabled: newValue)
                                    }
                                }
                            )
                        )
                        .labelsHidden()

                        Button(role: .destructive) {
                            Task {
                                await calendarStore.removeSources(at: IndexSet(integer: index))
                            }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            switch calendarStore.accessState {
            case .fullAccess:
                if calendarStore.availableDeviceCalendars.isEmpty {
                    Text("No device calendars are currently available.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(calendarStore.availableDeviceCalendars) { calendar in
                        HStack(alignment: .top, spacing: 12) {
                            Circle()
                                .fill(color(from: calendar.colorHex))
                                .frame(width: 10, height: 10)
                                .padding(.top, 6)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(calendar.title)
                                    .foregroundStyle(.primary)

                                Text(calendar.detailText)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if calendar.isAlreadyAdded {
                                Text("Added")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(HankTheme.success)
                            } else {
                                Button("Add") {
                                    Task {
                                        await calendarStore.addDeviceCalendar(identifier: calendar.calendarIdentifier)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .tint(HankTheme.accent)
                            }
                        }
                    }
                }

                Text("iCloud and CalDAV calendars come from Calendar accounts already configured on this iPhone or iPad.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

            case .notDetermined, .denied, .restricted, .writeOnly:
                Text(calendarDeviceAccessDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("Allow Calendar Access") {
                    Task {
                        await calendarStore.requestDeviceCalendarAccess()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(HankTheme.accent)
            }

            TextField("Calendar Name", text: $calendarStore.webCalendarName)
                .textInputAutocapitalization(.words)

            TextField("webcal:// or https:// URL", text: $calendarStore.webCalendarURL)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()

            Button("Add Web Calendar") {
                Task {
                    await calendarStore.addWebCalendar()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(HankTheme.accent)
        }
    }

    private func remoteSectionContent(_ profile: UserProfile) -> some View {
        return VStack(alignment: .leading, spacing: 14) {
            LabeledContent("Connection", value: remoteConnectionState)
            LabeledContent("Serverside", value: serverHealthState)
            LabeledContent("Home", value: statusValue(store.hankRemoteHome?.name ?? ""))
            LabeledContent("Agent", value: statusValue(store.hankRemoteAgent?.status.replacingOccurrences(of: "_", with: " ").capitalized ?? ""))
            LabeledContent("Profile Sync", value: profileSyncState)

            Button {
                Task {
                    await store.testHankRemote(modelContext: modelContext, services: services)
                }
            } label: {
                HStack {
                    if store.isTestingHankRemote {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Test Connection")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(HankTheme.accent)
            .controlSize(.regular)
            .frame(maxWidth: .infinity)

            Button {
                Task {
                    await store.syncProfile(profileID: profile.id, modelContext: modelContext, services: services)
                    if store.errorMessage == nil {
                        appState.markProfileDataChanged()
                    }
                }
            } label: {
                HStack {
                    if store.isSyncingProfile {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Profile Sync")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(HankTheme.accent)
            .controlSize(.regular)
            .frame(maxWidth: .infinity)

            Button {
                Task {
                    await store.refreshHankRemoteCloudState(modelContext: modelContext, services: services)
                }
            } label: {
                HStack {
                    if store.isRefreshingHankRemote {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Refresh State")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(HankTheme.accent)
            .controlSize(.regular)
            .frame(maxWidth: .infinity)

            if let ping = store.hankRemotePingResult, !ping.isEmpty {
                Text(ping)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func advancedSectionContent() -> some View {
        return Group {
            Text("Advanced server settings live on the Hank Serverside dashboard.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            LabeledContent("Dashboard", value: statusValue(advancedSettingsURL?.absoluteString ?? ""))

            Button {
                if let url = advancedSettingsURL {
                    browserDestination = HankBrowserDestination(url: url)
                }
            } label: {
                Label("Open Web Settings", systemImage: "safari")
            }
            .buttonStyle(.borderedProminent)
            .tint(HankTheme.accent)
            .disabled(advancedSettingsURL == nil)
        }
    }

    private var remoteConnectionState: String {
        if store.hankRemoteSession != nil {
            return "Up"
        }
        if store.hankRemote.trimmedCloudURL.isEmpty {
            return "Needs attention"
        }
        return "Needs attention"
    }

    private var serverHealthState: String {
        if store.hankRemoteAgent?.status.lowercased() == "online" || store.hankRemotePingResult != nil {
            return "Up"
        }
        if store.hankRemoteSession != nil {
            return "Needs attention"
        }
        return "Down"
    }

    private var profileSyncState: String {
        guard let sync = store.hankRemoteSyncStatus, store.hankRemoteSyncFeatureAvailable else {
            return store.hankRemoteSession == nil ? "Needs attention" : "Up"
        }
        if sync.notes.status == .healthy {
            return "Up"
        }
        return "Needs attention"
    }

    private var advancedSettingsURL: URL? {
        guard var components = URLComponents(string: normalizedHankRemoteCloudURL), components.scheme != nil else {
            return nil
        }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + ([path, "dashboard", "settings"].filter { !$0.isEmpty }.joined(separator: "/"))
        components.query = nil
        components.fragment = nil
        return components.url
    }

    @ViewBuilder
    private func remoteAccountContent() -> some View {
        Toggle("Enable Hank Remote", isOn: $store.hankRemote.isEnabled)
        TextField("Cloud URL", text: $store.hankRemote.cloudURL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
        TextField("Email", text: $store.hankRemoteEmail)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.emailAddress)
        SecureField("Password", text: $store.hankRemotePassword)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        SecureField("Session Token", text: $store.hankRemoteAccessToken)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

        if let session = store.hankRemoteSession {
            LabeledContent("Signed In", value: session.user.email)
            LabeledContent("User ID", value: statusValue(session.user.id))
            LabeledContent("Session Expires", value: statusValue(Self.remoteDateFormatter.string(from: session.expiresAt)))
        } else {
            Text("Sign in with your Hank Remote account to load your Home, members, shared notes, sync status, and integration state.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Button {
            Task {
                await store.registerHankRemote(modelContext: modelContext, services: services)
            }
        } label: {
            HStack {
                if store.isSigningIntoHankRemote {
                    ProgressView()
                        .controlSize(.small)
                }
                Text("Register Account")
            }
        }

        Button {
            Task {
                await store.signInToHankRemote(modelContext: modelContext, services: services)
            }
        } label: {
            HStack {
                if store.isSigningIntoHankRemote {
                    ProgressView()
                        .controlSize(.small)
                }
                Text("Sign In")
            }
        }
    }

    @ViewBuilder
    private func remoteHomeContent() -> some View {
        if let selectedHome = store.hankRemoteHome {
            Text("Home")
                .font(.subheadline.weight(.semibold))
            LabeledContent("Name", value: selectedHome.name)
            LabeledContent("Role", value: statusValue(store.hankRemoteHomeRole?.rawValue.capitalized ?? ""))
            if let agent = store.hankRemoteAgent {
                LabeledContent("Agent Status", value: statusValue(agent.status.replacingOccurrences(of: "_", with: " ").capitalized))
                if let lastSeenAt = agent.lastSeenAt {
                    LabeledContent("Agent Last Seen", value: statusValue(Self.remoteDateFormatter.string(from: lastSeenAt)))
                }
            } else if store.hankRemoteAgentFeatureAvailable {
                LabeledContent("Agent Status", value: "Not registered")
            }

            if store.canManageHankRemotePermissions {
                TextField("Home Name", text: $store.hankRemoteNewHomeName)
                Button {
                    Task {
                        await store.renameHankRemoteHome(modelContext: modelContext, services: services)
                    }
                } label: {
                    HStack {
                        if store.isRenamingHankRemoteHome {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Save Home Name")
                    }
                }
            }

            remoteHomePermissionsContent()
        }
    }

    @ViewBuilder
    private func remoteHomePermissionsContent() -> some View {
        if store.hankRemotePermissionsFeatureAvailable {
            Text("Home Permissions")
                .font(.subheadline.weight(.semibold))
            Toggle("Home Assistant", isOn: $store.hankRemoteHomeAssistantEnabled)
                .disabled(!store.canManageHankRemotePermissions)
            Toggle("Files", isOn: $store.hankRemoteFilesEnabled)
                .disabled(!store.canManageHankRemotePermissions)
            Toggle("Shared Notes", isOn: $store.hankRemoteNotesEnabled)
                .disabled(!store.canManageHankRemotePermissions)
            if store.canManageHankRemotePermissions {
                Button {
                    Task {
                        await store.saveHankRemotePermissions(services: services)
                    }
                } label: {
                    HStack {
                        if store.isSavingHankRemotePermissions {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Save Home Permissions")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func remoteNotificationsContent() -> some View {
        if store.hankRemoteSession != nil {
            Text("Notifications")
                .font(.subheadline.weight(.semibold))

            Button {
                Task {
                    await store.requestHankRemoteNotifications(modelContext: modelContext, services: services)
                }
            } label: {
                HStack {
                    if store.isRequestingHankRemoteNotificationAccess {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Allow Notifications")
                }
            }

            if store.hankRemoteNotificationsFeatureAvailable {
                Toggle("Backups and Storage", isOn: $store.hankRemoteStorageNotificationsEnabled)
                Toggle("Shared Notes", isOn: $store.hankRemoteNotesNotificationsEnabled)
                Toggle("Dashboard Entities", isOn: $store.hankRemoteDashboardEntityNotificationsEnabled)
                Button {
                    Task {
                        await store.saveHankRemoteNotificationSettings(services: services)
                    }
                } label: {
                    HStack {
                        if store.isSavingHankRemoteNotificationSettings {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Save Notifications")
                    }
                }
            } else {
                Text("Notification settings are not available on this server yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let registrationError = services.notificationService.lastRegistrationError {
                Text(registrationError)
                    .font(.caption)
                    .foregroundStyle(HankTheme.error)
            }
        }
    }

    @ViewBuilder
    private func remoteInvitationContent() -> some View {
        if store.hankRemoteSession != nil {
            Text("Accept Invitation")
                .font(.subheadline.weight(.semibold))
            TextField("Invitation Token", text: $store.hankRemoteJoinToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button {
                Task {
                    await store.acceptHankRemoteInvitation(modelContext: modelContext, services: services)
                }
            } label: {
                HStack {
                    if store.isAcceptingHankRemoteInvitation {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Accept Invitation")
                }
            }
        }
    }

    @ViewBuilder
    private func remoteAgentTokenContent() -> some View {
        if store.hankRemoteHome != nil && store.canManageHankRemoteHomeAgent {
            Text("Agent Tokens")
                .font(.subheadline.weight(.semibold))
            TextField("Agent ID", text: $store.hankRemoteAgentID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Agent Name", text: $store.hankRemoteAgentName)

            Button {
                Task {
                    await store.createHankRemoteAgentToken(services: services)
                }
            } label: {
                HStack {
                    if store.isCreatingHankRemoteAgentToken {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Issue Agent Token")
                }
            }
        }

        if let issuedToken = store.hankRemoteLastIssuedToken {
            LabeledContent("Last Token ID", value: statusValue(issuedToken.tokenID))
            Text(issuedToken.token)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }

        if !store.hankRemoteAgentTokens.isEmpty {
            ForEach(store.hankRemoteAgentTokens) { token in
                VStack(alignment: .leading, spacing: 6) {
                    Text(token.agentID)
                        .font(.subheadline.weight(.semibold))
                    Text(token.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text("Created \(Self.remoteDateFormatter.string(from: token.createdAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let expiresAt = token.expiresAt {
                        Text("Expires \(Self.remoteDateFormatter.string(from: expiresAt))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if token.revokedAt == nil {
                        Button("Revoke Token", role: .destructive) {
                            Task {
                                await store.revokeHankRemoteAgentToken(token.id, services: services)
                            }
                        }
                        .disabled(store.revokingHankRemoteTokenID == token.id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func remoteMembersContent() -> some View {
        if store.hankRemoteHome != nil {
            Text("Home Members")
                .font(.subheadline.weight(.semibold))

            if store.hankRemoteMembersFeatureAvailable {
                if store.hankRemoteMembers.isEmpty {
                    Text("No members returned for this home yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.hankRemoteMembers) { member in
                        remoteMemberRow(member)
                    }
                }

                remoteMemberInvitationContent()
            } else {
                Text("Home membership controls are not available on this server yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func remoteMemberRow(_ member: HankRemoteHomeMember) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(member.email)
                    .font(.subheadline.weight(.semibold))
                if member.userID == store.hankRemoteSession?.user.id {
                    Text("You")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(HankTheme.accent)
                }
                Spacer()
                Text(member.role.rawValue.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if store.canManageHankRemoteHomeMembers && member.userID != store.hankRemoteSession?.user.id {
                Picker("Role", selection: memberRoleBinding(for: member)) {
                    Text("Member").tag(HankRemoteHomeRole.member)
                    Text("Admin").tag(HankRemoteHomeRole.admin)
                }
                Button {
                    Task {
                        await store.updateHankRemoteMemberRole(member.userID, services: services)
                    }
                } label: {
                    HStack {
                        if store.updatingHankRemoteMemberRoleUserID == member.userID {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Save Role")
                    }
                }
                .disabled(store.updatingHankRemoteMemberRoleUserID == member.userID)

                remoteMemberPermissionsContent(member)

                Button("Remove Member", role: .destructive) {
                    Task {
                        await store.removeHankRemoteMember(member.userID, services: services)
                    }
                }
                .disabled(store.removingHankRemoteMemberID == member.userID)
            }
        }
    }

    @ViewBuilder
    private func remoteMemberPermissionsContent(_ member: HankRemoteHomeMember) -> some View {
        if store.hankRemotePermissionsFeatureAvailable {
            Picker("Home Assistant Access", selection: memberHomeAssistantBinding(for: member.userID)) {
                ForEach(HankRemotePermissionOverride.allCases) { value in
                    Text(value.title).tag(value)
                }
            }
            Picker("Files Access", selection: memberFilesBinding(for: member.userID)) {
                ForEach(HankRemotePermissionOverride.allCases) { value in
                    Text(value.title).tag(value)
                }
            }
            Picker("Shared Notes Access", selection: memberNotesBinding(for: member.userID)) {
                ForEach(HankRemotePermissionOverride.allCases) { value in
                    Text(value.title).tag(value)
                }
            }
            Button {
                Task {
                    await store.saveHankRemoteMemberPermissions(member.userID, services: services)
                }
            } label: {
                HStack {
                    if store.savingHankRemoteMemberPermissionsUserID == member.userID {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Save Permissions")
                }
            }
            .disabled(store.savingHankRemoteMemberPermissionsUserID == member.userID)
        }
    }

    @ViewBuilder
    private func remoteMemberInvitationContent() -> some View {
        if store.canManageHankRemoteHomeMembers {
            TextField("Invitee Email", text: $store.hankRemoteInvitationEmail)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.emailAddress)
            Button {
                Task {
                    await store.createHankRemoteInvitation(services: services)
                }
            } label: {
                HStack {
                    if store.isCreatingHankRemoteInvitation {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Create Invitation")
                }
            }
            if !store.hankRemoteInvitationToken.isEmpty {
                Text(store.hankRemoteInvitationToken)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                if let expiresAt = store.hankRemoteInvitationExpiresAt {
                    Text("Expires \(Self.remoteDateFormatter.string(from: expiresAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ShareLink(item: store.hankRemoteInvitationToken) {
                    Label("Share Invitation", systemImage: "square.and.arrow.up")
                }
                Button("Copy Invitation Token") {
                    copyToPasteboard(store.hankRemoteInvitationToken)
                }
                Button("Revoke Invitation", role: .destructive) {
                    Task {
                        await store.revokeLastHankRemoteInvitation(services: services)
                    }
                }
                .disabled(store.isRevokingHankRemoteInvitation)
            }
        } else {
            Text("Only admins can invite, remove, or manage members.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func remoteSyncContent() -> some View {
        if let sync = store.hankRemoteSyncStatus, store.hankRemoteSyncFeatureAvailable {
            Text("Home Sync")
                .font(.subheadline.weight(.semibold))
            LabeledContent("Notes", value: sync.notes.status.displayTitle)
            if let backupAt = sync.notes.lastSuccessfulBackupAt {
                LabeledContent("Latest Backup", value: Self.remoteDateFormatter.string(from: backupAt))
            }
            if sync.notes.pendingPullCount > 0 {
                LabeledContent("Pending Pull", value: "\(sync.notes.pendingPullCount)")
            }
            if sync.notes.pendingPushCount > 0 {
                LabeledContent("Pending Push", value: "\(sync.notes.pendingPushCount)")
            }
            if !sync.notes.lastError.isEmpty {
                Text(sync.notes.lastError)
                    .font(.caption)
                    .foregroundStyle(HankTheme.error)
            }
            ForEach(HankRemoteServiceType.allCases) { serviceType in
                if let status = sync.profiles[serviceType.rawValue] {
                    LabeledContent(serviceType.title, value: status.status.displayTitle)
                }
            }
        }
    }

    @ViewBuilder
    private func remoteIntegrationsContent() -> some View {
        if store.hankRemoteServiceProfilesFeatureAvailable {
            Text("Shared Integrations")
                .font(.subheadline.weight(.semibold))

            remoteHomeAssistantIntegrationContent()
            remoteSMBIntegrationContent()
        }
    }

    @ViewBuilder
    private func remoteHomeAssistantIntegrationContent() -> some View {
        if let profile = store.homeAssistantServiceProfile {
            LabeledContent("Home Assistant", value: profile.status.displayTitle)
            if let backupAt = profile.lastBackupAt {
                LabeledContent("HA Last Backup", value: Self.remoteDateFormatter.string(from: backupAt))
            }
            if !profile.lastError.isEmpty {
                Text(profile.lastError)
                    .font(.caption)
                    .foregroundStyle(HankTheme.error)
            }
        } else {
            LabeledContent("Home Assistant", value: "Not configured")
        }

        if store.canManageHankRemoteIntegrations {
            TextField("Shared HA Base URL", text: $store.hankRemoteSharedHomeAssistantBaseURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            TextField("Shared HA Timeout", value: $store.hankRemoteSharedHomeAssistantTimeoutSeconds, formatter: Self.portFormatter)
                .keyboardType(.numberPad)
            SecureField("Shared HA Token", text: $store.hankRemoteSharedHomeAssistantToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Toggle("Persist Shared Integrations", isOn: $store.hankRemotePersistSharedIntegrations)
            Button {
                Task {
                    await store.saveHankRemoteHomeAssistantProfile(services: services)
                }
            } label: {
                HStack {
                    if store.isSavingHankRemoteHomeAssistantProfile {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Save Shared Home Assistant")
                }
            }
        }
    }

    @ViewBuilder
    private func remoteSMBIntegrationContent() -> some View {
        if let profile = store.smbServiceProfile {
            LabeledContent("SMB", value: profile.status.displayTitle)
            if let backupAt = profile.lastBackupAt {
                LabeledContent("SMB Last Backup", value: Self.remoteDateFormatter.string(from: backupAt))
            }
            if !profile.lastError.isEmpty {
                Text(profile.lastError)
                    .font(.caption)
                    .foregroundStyle(HankTheme.error)
            }
        } else {
            LabeledContent("SMB", value: "Not configured")
        }

        if store.canManageHankRemoteIntegrations {
            TextField("Shared SMB Host", text: $store.hankRemoteSharedSMBHost)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Shared SMB Share", text: $store.hankRemoteSharedSMBShare)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Shared SMB Domain", text: $store.hankRemoteSharedSMBDomain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Shared SMB Username", text: $store.hankRemoteSharedSMBUsername)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Shared SMB Password", text: $store.hankRemoteSharedSMBPassword)
            Button {
                Task {
                    await store.saveHankRemoteSMBProfile(services: services)
                }
            } label: {
                HStack {
                    if store.isSavingHankRemoteSMBProfile {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Save Shared SMB")
                }
            }
        } else if store.hankRemoteHome != nil {
            Text("Only admins can update shared Home Assistant and SMB settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func remoteStatusActionsContent() -> some View {
        Text("Hank Remote now treats this deployment as one shared Home. It drives shared notes, sync health, members, and shared integrations whenever remote access is enabled.")
            .font(.caption)
            .foregroundStyle(.secondary)

        LabeledContent("Normalized URL", value: statusValue(normalizedHankRemoteCloudURL))
        LabeledContent("Relay Ping", value: statusValue(store.hankRemotePingResult ?? ""))

        Button {
            Task {
                await store.saveHankRemote(modelContext: modelContext, services: services)
            }
        } label: {
            HStack {
                if store.isSavingHankRemote {
                    ProgressView()
                        .controlSize(.small)
                }
                Text("Save")
            }
        }

        Button {
            Task {
                await store.testHankRemote(modelContext: modelContext, services: services)
            }
        } label: {
            HStack {
                if store.isTestingHankRemote {
                    ProgressView()
                        .controlSize(.small)
                }
                Text("Test Connection")
            }
        }

        Button {
            Task {
                await store.refreshHankRemoteCloudState(modelContext: modelContext, services: services)
            }
        } label: {
            HStack {
                if store.isRefreshingHankRemote {
                    ProgressView()
                        .controlSize(.small)
                }
                Text("Refresh Cloud State")
            }
        }

        Button {
            Task {
                await store.pingHankRemote(services: services)
            }
        } label: {
            HStack {
                if store.isPingingHankRemote {
                    ProgressView()
                        .controlSize(.small)
                }
                Text("Ping Home Agent")
            }
        }

        if store.hankRemoteSession != nil {
            Button("Sign Out", role: .destructive) {
                Task {
                    await store.signOutOfHankRemote(modelContext: modelContext, services: services)
                }
            }
        }

        Button("Clear", role: .destructive) {
            store.clearHankRemote(modelContext: modelContext, services: services)
        }
    }

    private func storageSectionContent() -> some View {
        return Group {
            if store.canManageHankRemotePermissions, store.hankRemoteStorageFeatureAvailable || store.hankRemoteStorageStatus != nil {
                Text("Storage Health")
                    .font(.subheadline.weight(.semibold))

                if let status = store.hankRemoteStorageStatus {
                    LabeledContent("Checksum", value: status.checksum.enabled ? "Enabled" : "Off")
                    if let lastCheckAt = status.checksum.lastCheckAt {
                        LabeledContent("Last Check", value: Self.remoteDateFormatter.string(from: lastCheckAt))
                    }
                    if let lastAmcheckAt = status.checksum.lastAmcheckAt {
                        LabeledContent("Last pg_amcheck", value: Self.remoteDateFormatter.string(from: lastAmcheckAt))
                    }
                    if status.checksum.corruptionDetected {
                        Text("Database corruption detected.")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(HankTheme.error)
                    }
                    if !status.checksum.lastError.isEmpty {
                        Text(status.checksum.lastError)
                            .font(.caption)
                            .foregroundStyle(HankTheme.error)
                    }

                    LabeledContent("Backup Target", value: status.backup.targetPath.isEmpty ? status.backup.targetType : status.backup.targetPath)
                    if let lastBackup = status.backup.lastSuccessfulBackupAt {
                        LabeledContent("Latest Backup", value: Self.remoteDateFormatter.string(from: lastBackup))
                    }
                    LabeledContent("Backup Failures", value: "\(status.backup.failureCount)")

                    if !status.tasks.isEmpty {
                        Text("Current Work")
                            .font(.caption.weight(.semibold))
                        ForEach(status.tasks.prefix(6)) { task in
                            storageTaskRow(task)
                        }
                    }

                    if !status.failures.isEmpty {
                        Text("Recent Failures")
                            .font(.caption.weight(.semibold))
                        ForEach(status.failures.prefix(4)) { event in
                            storageEventRow(event)
                        }
                    }
                }

                TextField("Backup Target Type", text: $store.hankRemoteStorageBackupTargetType)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Backup Target Path", text: $store.hankRemoteStorageBackupTargetPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Full Backup Schedule", text: $store.hankRemoteStorageFullSchedule)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Differential Backup Schedule", text: $store.hankRemoteStorageDifferentialSchedule)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Checksum Interval Seconds", value: $store.hankRemoteStorageChecksumIntervalSeconds, formatter: Self.portFormatter)
                    .keyboardType(.numberPad)
                TextField("Restore Test Schedule", text: $store.hankRemoteStorageRestoreVerificationSchedule)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Retained Full Backups", value: $store.hankRemoteStorageRetainedFullBackupCount, formatter: Self.portFormatter)
                    .keyboardType(.numberPad)

                Button {
                    Task {
                        await store.saveHankRemoteStorageConfig(services: services)
                    }
                } label: {
                    HStack {
                        if store.isSavingHankRemoteStorageConfig {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Save Storage Settings")
                    }
                }

                HStack {
                    Button("Run Full Backup") {
                        Task {
                            await store.requestHankRemoteStorageBackup(type: "full", services: services)
                        }
                    }
                    Button("Run Differential Backup") {
                        Task {
                            await store.requestHankRemoteStorageBackup(type: "differential", services: services)
                        }
                    }
                }
                .disabled(store.isRequestingHankRemoteStorageBackup)

                Button {
                    Task {
                        await store.requestHankRemoteStorageRestoreTest(services: services)
                    }
                } label: {
                    HStack {
                        if store.isRequestingHankRemoteStorageRestoreTest {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Run Restore Test")
                    }
                }

                if let phrase = store.hankRemoteStorageStatus?.restore.confirmationPhrase, !phrase.isEmpty {
                    Text("Primary restore confirmation: \(phrase)")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    TextField("Confirmation Phrase", text: $store.hankRemoteStoragePrimaryRestoreConfirmation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Restore Primary Database", role: .destructive) {
                        Task {
                            await store.requestHankRemoteStoragePrimaryRestore(services: services)
                        }
                    }
                    .disabled(store.isRequestingHankRemoteStoragePrimaryRestore)
                }

                if !store.hankRemoteStorageEvents.isEmpty {
                    Text("Storage Events")
                        .font(.caption.weight(.semibold))
                    ForEach(store.hankRemoteStorageEvents.prefix(5)) { event in
                        storageEventRow(event)
                    }
                }

                Button {
                    Task {
                        await store.refreshHankRemoteStorage(services: services)
                    }
                } label: {
                    HStack {
                        if store.isRefreshingHankRemoteStorage {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Refresh Storage")
                    }
                }
            } else if store.hankRemoteHome != nil && store.hankRemoteHomeRole == .member {
                Text("Only admins can view server storage health and restore controls.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func storageTaskRow(_ task: HankRemoteStorageTask) -> some View {
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(task.operation.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(task.status.rawValue.capitalized)
                    .font(.caption)
                    .foregroundStyle(task.status == .failed ? HankTheme.error : .secondary)
            }
            if !task.message.isEmpty {
                Text(task.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if let step = task.step, !step.isEmpty {
                    Text(step)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                if let backupType = task.backupType, !backupType.isEmpty {
                    Text(backupType)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                if let backupLabel = task.backupLabel, !backupLabel.isEmpty {
                    Text(backupLabel)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            if let updatedAt = task.updatedAt ?? task.startedAt ?? task.queuedAt {
                Text(Self.remoteDateFormatter.string(from: updatedAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func storageEventRow(_ event: HankRemoteStorageEvent) -> some View {
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(event.operation.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(event.severity.rawValue.capitalized)
                    .font(.caption)
                    .foregroundStyle(event.severity == .critical || event.severity == .error ? HankTheme.error : .secondary)
            }
            Text(event.message)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let backupLabel = event.backupLabel, !backupLabel.isEmpty {
                Text(backupLabel)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func assistantSectionContent() -> some View {
        return Group {
            if let status = store.hankRemoteAssistantStatus {
                Text("Assistant")
                    .font(.subheadline.weight(.semibold))
                LabeledContent("Provider", value: status.providerDisplayTitle)
                LabeledContent("Chat", value: status.chatConfigured ? "Ready" : "Not configured")
                LabeledContent("Chat Model", value: status.chatModel)
                LabeledContent("Embeddings", value: status.embeddingConfigured ? status.embeddingModel : "Not configured")
                LabeledContent("Vector Store", value: status.vectorStore.replacingOccurrences(of: "_", with: " "))
                if let index = status.index {
                    LabeledContent("Indexed Context", value: "\(index.embeddedChunkCount)/\(index.chunkCount) chunks")
                }
            } else if store.hankRemoteSession != nil {
                Text("Assistant status is not loaded yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let openAIStatus = store.hankRemoteOpenAIStatus {
                Text("ChatGPT / OpenAI")
                    .font(.subheadline.weight(.semibold))
                LabeledContent("Status", value: openAIStatus.displayTitle)
                if !openAIStatus.authProvider.isEmpty {
                    LabeledContent("Provider", value: openAIStatus.authProviderDisplayTitle)
                }
                if !openAIStatus.authMode.isEmpty {
                    LabeledContent("Link Type", value: openAIStatus.authModeDisplayTitle)
                }
                if !openAIStatus.chatGPTPlanType.isEmpty {
                    LabeledContent("Plan", value: openAIStatus.chatGPTPlanType)
                }
                if let expiresAt = openAIStatus.expiresAt {
                    LabeledContent("Expires", value: Self.remoteDateFormatter.string(from: expiresAt))
                }
                if !openAIStatus.missing.isEmpty {
                    Text("Server setup missing: \(openAIStatus.missing.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(HankTheme.error)
                        .textSelection(.enabled)
                }
                if let pending = openAIStatus.pending, !pending.state.isEmpty {
                    LabeledContent("Device Code State", value: pending.state.capitalized)
                    if !pending.error.isEmpty {
                        Text(pending.error)
                            .font(.caption)
                            .foregroundStyle(HankTheme.error)
                    }
                }
            } else {
                LabeledContent("ChatGPT", value: store.hankRemoteSession == nil ? "Sign in first" : "Not linked")
            }

            if let start = store.hankRemoteOpenAIStart, start.authMode == "device_code", !start.userCode.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Device Code")
                        .font(.caption.weight(.semibold))
                    Text(start.userCode)
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .textSelection(.enabled)
                    if let expiresAt = start.expiresAt {
                        Text("Expires \(Self.remoteDateFormatter.string(from: expiresAt))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Copy Code") {
                        UIPasteboard.general.string = start.userCode
                    }
                    .buttonStyle(.bordered)
                    .tint(HankTheme.accent)
                }
            }

            Button {
                Task {
                    guard let url = await store.startOpenAIAccountLink(services: services) else {
                        return
                    }
                    browserDestination = HankBrowserDestination(url: url)
                }
            } label: {
                HStack {
                    if store.isStartingOpenAIAccountLink {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Link OpenAI")
                }
            }
            .disabled(store.hankRemoteSession == nil || store.isStartingOpenAIAccountLink || store.hankRemoteOpenAIStatus?.configured == false)

            if let settings = store.hankRemoteAssistantSettings {
                Text("Context Sources")
                    .font(.subheadline.weight(.semibold))

                ForEach(settings.sources) { source in
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(source.label, isOn: assistantSourceBinding(for: source))
                            .disabled(!store.isHankRemoteAssistantSourceAvailable(source.key))
                        Text(source.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !store.isHankRemoteAssistantSourceAvailable(source.key) {
                            Text("Disabled by Home permissions for this member.")
                                .font(.caption)
                                .foregroundStyle(HankTheme.error)
                        }
                    }
                }

                Text("System Prompt")
                    .font(.caption.weight(.semibold))
                TextEditor(text: $store.hankRemoteAssistantSystemPrompt)
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(HankTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                Button {
                    Task {
                        await store.saveHankRemoteAssistantSettings(services: services)
                    }
                } label: {
                    HStack {
                        if store.isSavingHankRemoteAssistantSettings {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Save Assistant Settings")
                    }
                }
            }

            Button {
                Task {
                    await store.refreshHankRemoteAssistant(services: services)
                }
            } label: {
                HStack {
                    if store.isRefreshingHankRemoteAssistant {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Refresh Assistant")
                }
            }
            .disabled(store.hankRemoteSession == nil || store.isRefreshingHankRemoteAssistant)

            if store.hankRemoteSession == nil {
                Text("Sign in to Hank Remote before linking OpenAI.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func assistantSourceBinding(for source: HankRemoteAssistantSettingsSource) -> Binding<Bool> {
        Binding(
            get: { store.hankRemoteAssistantSourceSelections[source.key] ?? source.enabled },
            set: { store.hankRemoteAssistantSourceSelections[source.key] = $0 }
        )
    }

    private func memberRoleBinding(for member: HankRemoteHomeMember) -> Binding<HankRemoteHomeRole> {
        Binding(
            get: { store.hankRemoteMemberRoleSelections[member.userID] ?? member.role },
            set: { store.hankRemoteMemberRoleSelections[member.userID] = $0 }
        )
    }

    private func memberHomeAssistantBinding(for userID: String) -> Binding<HankRemotePermissionOverride> {
        Binding(
            get: { store.hankRemoteMemberHomeAssistantOverrides[userID] ?? .inherit },
            set: { store.hankRemoteMemberHomeAssistantOverrides[userID] = $0 }
        )
    }

    private func memberFilesBinding(for userID: String) -> Binding<HankRemotePermissionOverride> {
        Binding(
            get: { store.hankRemoteMemberFilesOverrides[userID] ?? .inherit },
            set: { store.hankRemoteMemberFilesOverrides[userID] = $0 }
        )
    }

    private func memberNotesBinding(for userID: String) -> Binding<HankRemotePermissionOverride> {
        Binding(
            get: { store.hankRemoteMemberNotesOverrides[userID] ?? .inherit },
            set: { store.hankRemoteMemberNotesOverrides[userID] = $0 }
        )
    }

    private func homeAssistantSectionContent(_ profile: UserProfile) -> some View {
        return Group {
            if store.hankRemoteHome != nil {
                Text("Home Assistant requests run through Hank Remote. These cached fields are refreshed from server profile data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField("Display Name", text: $store.homeAssistant.displayName)
            TextField("Base URL", text: $store.homeAssistant.baseURLString)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            TextField("Port", value: $store.homeAssistant.port, formatter: Self.portFormatter)
                .keyboardType(.numberPad)
            SecureField("Long-Lived Access Token", text: $store.homeAssistantToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button("Save") {
                store.saveHomeAssistant(profileID: profile.id, modelContext: modelContext, services: services)
            }

            Button {
                Task {
                    await store.testHomeAssistant(profileID: profile.id, modelContext: modelContext, services: services)
                }
            } label: {
                HStack {
                    if store.isTestingHomeAssistant {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Test Connection")
                }
            }

            Button("Clear", role: .destructive) {
                store.clearHomeAssistant(profileID: profile.id, modelContext: modelContext, services: services)
            }
        }
    }

    private func smbSectionContent(_ profile: UserProfile) -> some View {
        return Group {
            if store.hankRemoteHome != nil {
                Text("File requests run through Hank Remote. These cached fields identify the server-managed source.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !store.smbConnections.isEmpty {
                Picker("Saved Connection", selection: $store.selectedSMBConnectionID) {
                    ForEach(store.smbConnections) { connection in
                        Text(connection.isDefault ? "\(connection.displayName) (Default)" : connection.displayName)
                            .tag(Optional(connection.id))
                    }
                }
                .onChange(of: store.selectedSMBConnectionID) { _, newValue in
                    guard let newValue else {
                        return
                    }
                    store.selectSMBConnection(
                        newValue,
                        profileID: profile.id,
                        modelContext: modelContext,
                        services: services
                    )
                }
            }
            Button("New Connection") {
                store.beginNewSMBConnection()
            }
            TextField("Connection Name", text: $store.smbDisplayName)
            TextField("Host", text: $store.smb.host)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Share Name", text: $store.smb.shareName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Username", text: $store.smb.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Password", text: $store.smbPassword)
            TextField("Port", value: $store.smb.port, formatter: Self.portFormatter)
                .keyboardType(.numberPad)
            TextField("Optional Start Path", text: $store.smb.startPath)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Toggle("Use as default file source", isOn: $store.smbIsDefault)

            Button("Save") {
                store.saveSMB(profileID: profile.id, modelContext: modelContext, services: services)
                if store.errorMessage == nil {
                    appState.markProfileDataChanged()
                }
            }

            Button {
                Task {
                    await store.testSMB(profileID: profile.id, modelContext: modelContext, services: services)
                    if store.errorMessage == nil {
                        appState.markProfileDataChanged()
                    }
                }
            } label: {
                HStack {
                    if store.isTestingSMB {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Test Connection")
                }
            }

            Button(store.selectedSMBConnectionID == nil ? "Clear Draft" : "Delete Connection", role: .destructive) {
                store.clearSMB(profileID: profile.id, modelContext: modelContext, services: services)
                if store.errorMessage == nil {
                    appState.markProfileDataChanged()
                }
            }
        }
    }

    private func notesSectionContent(_ profile: UserProfile) -> some View {
        return Group {
            if let sync = store.hankRemoteSyncStatus, store.hankRemoteSyncFeatureAvailable {
                Text("Shared Home Notes: \(sync.notes.status.displayTitle)")
                    .font(.caption)
                    .foregroundStyle(sync.notes.status == .healthy ? .secondary : HankTheme.folder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Notes Storage")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HankTheme.accent)
                Text("Hank Remote with offline cache")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(store.notesResolvedPath.isEmpty ? "Notes are synced by the server and cached on this iPhone for offline edits." : store.notesResolvedPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task {
                    await store.validateNotesStorage(profileID: profile.id, modelContext: modelContext, services: services)
                }
            } label: {
                HStack {
                    if store.isTestingNotesStorage {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Check Notes Sync")
                }
            }
        }
    }

    private var calendarDeviceAccessDescription: String {
        switch calendarStore.accessState {
        case .notDetermined:
            "Allow full calendar access so Hank can see your device calendars, including iCloud and device-backed CalDAV accounts."
        case .denied:
            "Calendar access is currently denied. Re-enable it to browse and add your iCloud or CalDAV calendars."
        case .restricted:
            "Calendar access is restricted on this device."
        case .writeOnly:
            "Hank needs full calendar access to read calendars and events."
        case .fullAccess:
            ""
        }
    }

    private func isSectionCollapsed(_ section: SettingsSectionID) -> Bool {
        collapsedSectionIDs.contains(section.rawValue)
    }

    private func expandSection(_ section: SettingsSectionID) {
        var ids = collapsedSectionIDs
        ids.remove(section.rawValue)
        collapsedSettingsSectionsRaw = ids.sorted().joined(separator: ",")
    }

    private func collapseSection(_ section: SettingsSectionID) {
        var ids = collapsedSectionIDs
        ids.insert(section.rawValue)
        collapsedSettingsSectionsRaw = ids.sorted().joined(separator: ",")
    }

    private func sectionExpandedBinding(_ section: SettingsSectionID) -> Binding<Bool> {
        Binding(
            get: { !isSectionCollapsed(section) },
            set: { isExpanded in
                let previousValue = isSectionCollapsed(section) ? "false" : "true"
                let nextValue = isExpanded ? "true" : "false"
                logger.notice("Settings section expanded changed section=\(section.rawValue, privacy: .public) previous=\(previousValue, privacy: .public) next=\(nextValue, privacy: .public)")

                if isExpanded {
                    expandSection(section)
                    guard section == .calendar, let profileID = appState.activeProfileID else {
                        return
                    }
                    Task {
                        await loadCalendarSectionIfNeeded(profileID: profileID, forceReload: false)
                    }
                } else {
                    collapseSection(section)
                }
            }
        )
    }

    private var collapsedSectionIDs: Set<String> {
        let saved = Set(collapsedSettingsSectionsRaw.split(separator: ",").map(String.init))
        if saved.isEmpty && collapsedSettingsSectionsRaw.isEmpty {
            return [
                SettingsSectionID.calendar.rawValue,
                SettingsSectionID.remote.rawValue
            ]
        }
        return saved
    }

    private func loadCalendarSectionIfNeeded(profileID: UUID, forceReload: Bool) async {
        guard forceReload || requestedSection == .calendar || !isSectionCollapsed(.calendar) else {
            let forceReloadText = forceReload ? "true" : "false"
            let calendarCollapsed = isSectionCollapsed(.calendar) ? "true" : "false"
            logger.notice("Calendar section load skipped forceReload=\(forceReloadText, privacy: .public) calendarCollapsed=\(calendarCollapsed, privacy: .public)")
            return
        }

        let forceReloadText = forceReload ? "true" : "false"
        logger.notice("Calendar section load started forceReload=\(forceReloadText, privacy: .public)")
        await calendarStore.load(profileID: profileID, modelContext: modelContext, services: services)
        logger.notice("Calendar section load finished")
    }

    private var deleteProfileMessage: String {
        "This removes the local profile, its dashboard configuration, and saved secrets from this iPhone. Server-side notes and storage backups are not deleted."
    }

    private static let portFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.usesGroupingSeparator = false
        formatter.minimum = 0
        formatter.maximum = 65_535
        return formatter
    }()

    private static let remoteDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private var normalizedHankRemoteCloudURL: String {
        let trimmed = store.hankRemote.cloudURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }
        return trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    }

    private func handleRequestedSection(_ section: SettingsSectionID?) {
        guard let section else {
            return
        }

        logger.notice("Expanding requested settings section=\(section.rawValue, privacy: .public)")
        expandSection(section)
        requestedSection = nil
    }

    private func statusValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "—" : trimmed
    }

    private func copyToPasteboard(_ value: String) {
#if canImport(UIKit)
        UIPasteboard.general.string = value
#endif
    }

    private func color(from hex: String) -> Color {
        var value = hex
        if value.hasPrefix("#") {
            value.removeFirst()
        }

        guard let intValue = Int(value, radix: 16) else {
            return HankTheme.accent
        }

        let red = Double((intValue >> 16) & 0xFF) / 255
        let green = Double((intValue >> 8) & 0xFF) / 255
        let blue = Double(intValue & 0xFF) / 255
        return Color(red: red, green: green, blue: blue)
    }
}

private struct DeleteProfileAuthorizationRequest: Identifiable {
    let profileID: UUID
    let profileName: String

    var id: UUID { profileID }
}

private struct DeleteProfileAuthorizationSheet: View {
    @Environment(\.dismiss) private var dismiss

    let profileName: String
    let onAuthorize: (String) -> Void

    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Confirm Profile Password") {
                    Text("Enter the current password for \(profileName) to permanently delete this profile.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    SecureField("Current Password", text: $password)
                }
            }
            .navigationTitle("Delete Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Delete", role: .destructive) {
                        onAuthorize(password)
                        dismiss()
                    }
                    .disabled(password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct SettingsBannerStack: View {
    let infoMessage: String?
    let errorMessage: String?

    var body: some View {
        VStack(spacing: 8) {
            if let infoMessage, !infoMessage.isEmpty {
                SettingsBanner(message: infoMessage, tint: HankTheme.success, background: HankTheme.successSurface)
                    .transition(.opacity)
            }

            if let errorMessage, !errorMessage.isEmpty {
                SettingsBanner(message: errorMessage, tint: HankTheme.error, background: HankTheme.errorSurface)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .animation(.easeOut(duration: 0.35), value: infoMessage)
        .animation(.easeOut(duration: 0.35), value: errorMessage)
    }
}

private struct SettingsBanner: View {
    let message: String
    let tint: Color
    let background: Color

    var body: some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hankCard(fill: background, padding: 14)
    }
}

private extension HankRemoteAssistantStatus {
    var providerDisplayTitle: String {
        provider
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}

private extension HankRemoteOpenAIAccountStatus {
    var displayTitle: String {
        if !configured {
            return "Server setup needed"
        }
        if linked {
            return "Linked"
        }
        if let pending, !pending.state.isEmpty {
            return pending.state.capitalized
        }
        return "Not linked"
    }

    var authProviderDisplayTitle: String {
        switch authProvider {
        case "chatgpt_codex":
            return "ChatGPT / Codex"
        case "openai_oauth":
            return "OpenAI OAuth"
        default:
            return authProvider.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var authModeDisplayTitle: String {
        switch authMode {
        case "device_code":
            return "Device Code"
        case "authorization_url":
            return "Browser Sign In"
        default:
            return authMode.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
