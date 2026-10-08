import Foundation
import OSLog
import SwiftData

private struct SMBStartPathAccessError: LocalizedError {
    let path: String

    var errorDescription: String? {
        "SMB login succeeded, but the configured start path \"\(path)\" is inaccessible for this account."
    }
}

private struct StorageRealtimeNotificationPayload: Decodable {
    let eventID: String?
    let operation: String?
    let status: String?
    let severity: String?

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case operation
        case status
        case severity
    }
}

struct HankRemoteSMBServiceProfileForm: Equatable {
    let host: String
    let share: String
    let domain: String
    let username: String

    init(publicConfigJSON: String) {
        let config = Self.decodedPublicConfig(from: publicConfigJSON)
        host = Self.stringValue(for: "host", in: config)
        share = Self.stringValue(for: "share", in: config)
        domain = Self.stringValue(for: "domain", in: config)
        username = Self.stringValue(for: "username", in: config)
    }

    private static func decodedPublicConfig(from rawJSON: String) -> [String: Any] {
        guard
            let data = rawJSON.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return object
    }

    private static func stringValue(for key: String, in object: [String: Any]) -> String {
        if let value = object[key] as? String {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }
}

enum HankRemotePermissionOverride: String, CaseIterable, Identifiable {
    case inherit
    case allow
    case deny

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inherit:
            "Inherit"
        case .allow:
            "Allow"
        case .deny:
            "Deny"
        }
    }

    init(_ value: Bool?) {
        switch value {
        case .some(true):
            self = .allow
        case .some(false):
            self = .deny
        case .none:
            self = .inherit
        }
    }

    var boolValue: Bool? {
        switch self {
        case .inherit:
            nil
        case .allow:
            true
        case .deny:
            false
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published private(set) var smbConnections: [SavedSMBConnectionSummary] = []
    @Published var selectedSMBConnectionID: UUID?
    @Published var smbDisplayName = ""
    @Published var hankRemote = HankRemoteSettingsSnapshot()
    @Published var hankRemoteAccessToken = ""
    @Published var hankRemoteEmail = ""
    @Published var hankRemotePassword = ""
    @Published var hankRemoteNewHomeName = ""
    @Published var hankRemoteInvitationEmail = ""
    @Published var hankRemoteInvitationToken = ""
    @Published var hankRemoteInvitationID = ""
    @Published var hankRemoteInvitationExpiresAt: Date?
    @Published var hankRemoteJoinToken = ""
    @Published var hankRemoteAgentID = ""
    @Published var hankRemoteAgentName = ""
    @Published var hankRemoteSharedHomeAssistantBaseURL = ""
    @Published var hankRemoteSharedHomeAssistantTimeoutSeconds = 10
    @Published var hankRemoteSharedHomeAssistantToken = ""
    @Published var hankRemoteSharedSMBHost = ""
    @Published var hankRemoteSharedSMBShare = ""
    @Published var hankRemoteSharedSMBDomain = ""
    @Published var hankRemoteSharedSMBUsername = ""
    @Published var hankRemoteSharedSMBPassword = ""
    @Published var hankRemotePersistSharedIntegrations = true
    @Published private(set) var hankRemoteSession: HankRemoteSessionSummary?
    @Published private(set) var hankRemoteHome: HankRemoteHome?
    @Published private(set) var hankRemoteAgent: HankRemoteHomeAgent?
    @Published private(set) var hankRemoteMembers: [HankRemoteHomeMember] = []
    @Published private(set) var hankRemoteAgentTokens: [HankRemoteAgentToken] = []
    @Published private(set) var hankRemoteLastIssuedToken: HankRemoteIssuedAgentToken?
    @Published private(set) var hankRemotePingResult: String?
    @Published private(set) var hankRemoteSyncStatus: HankRemoteHomeSyncStatus?
    @Published private(set) var hankRemoteServiceProfiles: [HankRemoteServiceProfile] = []
    @Published private(set) var hankRemoteHomePermissions: HankRemoteHomePermissions?
    @Published private(set) var hankRemoteMemberPermissions: [String: HankRemoteHomeMemberPermissions] = [:]
    @Published private(set) var hankRemoteStorageStatus: HankRemoteStorageStatus?
    @Published private(set) var hankRemoteStorageConfig: HankRemoteStorageConfig?
    @Published private(set) var hankRemoteStorageEvents: [HankRemoteStorageEvent] = []
    @Published private(set) var hankRemoteAssistantStatus: HankRemoteAssistantStatus?
    @Published private(set) var hankRemoteAssistantSettings: HankRemoteAssistantSettingsResponse?
    @Published private(set) var hankRemoteOpenAIStatus: HankRemoteOpenAIAccountStatus?
    @Published private(set) var hankRemoteOpenAIStart: HankRemoteOpenAIAccountLinkStart?
    @Published private(set) var hankRemoteNotificationSettings: HankRemoteNotificationSettings?
    @Published private(set) var hankRemoteMembersFeatureAvailable = false
    @Published private(set) var hankRemoteAgentFeatureAvailable = false
    @Published private(set) var hankRemoteSyncFeatureAvailable = false
    @Published private(set) var hankRemoteServiceProfilesFeatureAvailable = false
    @Published private(set) var hankRemotePermissionsFeatureAvailable = false
    @Published private(set) var hankRemoteStorageFeatureAvailable = false
    @Published private(set) var hankRemoteAssistantFeatureAvailable = false
    @Published private(set) var hankRemoteOpenAIFeatureAvailable = false
    @Published private(set) var hankRemoteNotificationsFeatureAvailable = false
    @Published var hankRemoteHomeAssistantEnabled = true
    @Published var hankRemoteFilesEnabled = true
    @Published var hankRemoteNotesEnabled = true
    @Published var hankRemoteStorageNotificationsEnabled = true
    @Published var hankRemoteNotesNotificationsEnabled = true
    @Published var hankRemoteDashboardEntityNotificationsEnabled = true
    @Published var hankRemoteMemberRoleSelections: [String: HankRemoteHomeRole] = [:]
    @Published var hankRemoteMemberHomeAssistantOverrides: [String: HankRemotePermissionOverride] = [:]
    @Published var hankRemoteMemberFilesOverrides: [String: HankRemotePermissionOverride] = [:]
    @Published var hankRemoteMemberNotesOverrides: [String: HankRemotePermissionOverride] = [:]
    @Published var hankRemoteAssistantSourceSelections: [String: Bool] = [:]
    @Published var hankRemoteAssistantSystemPrompt = ""
    @Published var hankRemoteStorageBackupTargetType = "local"
    @Published var hankRemoteStorageBackupTargetPath = ""
    @Published var hankRemoteStorageFullSchedule = ""
    @Published var hankRemoteStorageDifferentialSchedule = ""
    @Published var hankRemoteStorageChecksumIntervalSeconds = 86_400
    @Published var hankRemoteStorageRestoreVerificationSchedule = ""
    @Published var hankRemoteStorageRetainedFullBackupCount = 7
    @Published var hankRemoteStoragePrimaryRestoreConfirmation = ""
    @Published var homeAssistant = HomeAssistantConnectionConfiguration()
    @Published var homeAssistantToken = ""
    @Published var smb = SMBConnectionDetails()
    @Published var smbPassword = ""
    @Published var smbIsDefault = false
    @Published var notesResolvedPath = ""
    @Published var infoMessage: String? {
        didSet {
            scheduleBannerDismiss(for: .info, message: infoMessage)
        }
    }
    @Published var errorMessage: String? {
        didSet {
            scheduleBannerDismiss(for: .error, message: errorMessage)
        }
    }
    @Published var isTestingHomeAssistant = false
    @Published var isTestingSMB = false
    @Published var isTestingNotesStorage = false
    @Published var isSavingHankRemote = false
    @Published var isTestingHankRemote = false
    @Published var isSyncingProfile = false
    @Published var isSigningIntoHankRemote = false
    @Published var isRefreshingHankRemote = false
    @Published var isRenamingHankRemoteHome = false
    @Published var isCreatingHankRemoteInvitation = false
    @Published var isRevokingHankRemoteInvitation = false
    @Published var isAcceptingHankRemoteInvitation = false
    @Published var isCreatingHankRemoteAgentToken = false
    @Published var isPingingHankRemote = false
    @Published var isStartingOpenAIAccountLink = false
    @Published var isRefreshingHankRemoteAssistant = false
    @Published var isSavingHankRemoteAssistantSettings = false
    @Published var isSavingHankRemoteNotificationSettings = false
    @Published var isRequestingHankRemoteNotificationAccess = false
    @Published var isSavingHankRemotePermissions = false
    @Published var isSavingHankRemoteHomeAssistantProfile = false
    @Published var isSavingHankRemoteSMBProfile = false
    @Published var isSavingHankRemoteStorageConfig = false
    @Published var isRefreshingHankRemoteStorage = false
    @Published var isRequestingHankRemoteStorageBackup = false
    @Published var isRequestingHankRemoteStorageRestoreTest = false
    @Published var isRequestingHankRemoteStoragePrimaryRestore = false
    @Published var updatingHankRemoteMemberRoleUserID: String?
    @Published var savingHankRemoteMemberPermissionsUserID: String?
    @Published var revokingHankRemoteTokenID: String?
    @Published var removingHankRemoteMemberID: String?

    private var loadedProfileID: UUID?
    private var infoDismissTask: Task<Void, Never>?
    private var errorDismissTask: Task<Void, Never>?
    private let smbValidationServiceFactory: @Sendable (HankRemoteService) -> SMBServicing
    private var hankRemoteRealtimeTask: Task<Void, Never>?
    private var openAIAccountStatusPollTask: Task<Void, Never>?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.dropfile.Hank", category: "SettingsStore")

    init(
        smbValidationServiceFactory: @escaping @Sendable (HankRemoteService) -> SMBServicing = {
            SMBFileService(hankRemoteService: $0)
        }
    ) {
        self.smbValidationServiceFactory = smbValidationServiceFactory
    }

    func load(profileID: UUID, modelContext: ModelContext, services: AppServices, forceReload: Bool = false) {
        let forceReloadText = forceReload ? "true" : "false"
        logger.notice("SettingsStore.load begin profileID=\(profileID.uuidString, privacy: .public) forceReload=\(forceReloadText, privacy: .public)")
        guard forceReload || loadedProfileID != profileID else {
            logger.notice("SettingsStore.load skipped profileID=\(profileID.uuidString, privacy: .public) reason=alreadyLoaded")
            return
        }

        do {
            if let config = try HomeAssistantConfig.fetch(for: profileID, in: modelContext) {
                homeAssistant = config.connectionConfiguration
            } else {
                homeAssistant = HomeAssistantConnectionConfiguration()
            }

            homeAssistantToken = try services.homeAssistantToken(for: profileID) ?? ""

            try loadSMBConnections(profileID: profileID, modelContext: modelContext, services: services)

            hankRemote = try services.hankRemoteSettingsSnapshot(in: modelContext)
            hankRemote.isEnabled = true
            hankRemoteAccessToken = try services.hankRemoteAccessToken() ?? ""
            hankRemotePingResult = nil
            resetHankRemoteCloudState(keepCredentials: !hankRemoteEmail.isEmpty || !hankRemotePassword.isEmpty)
            let notesConfig = try services.notesService.configurationSnapshot(
                profileID: profileID,
                modelContext: modelContext,
                services: services
            )
            notesResolvedPath = notesConfig.resolvedPath
            loadedProfileID = profileID
            logger.notice("SettingsStore.load success profileID=\(profileID.uuidString, privacy: .public) smbConnections=\(self.smbConnections.count)")
        } catch {
            let message = error.localizedDescription
            logger.error("SettingsStore.load failed profileID=\(profileID.uuidString, privacy: .public) error=\(message, privacy: .public)")
            showError(error.localizedDescription)
        }
    }

    func saveHomeAssistant(profileID: UUID, modelContext: ModelContext, services: AppServices) {
        do {
            let config = try HomeAssistantConfig.fetch(for: profileID, in: modelContext) ?? {
                let config = HomeAssistantConfig(profileID: profileID)
                modelContext.insert(config)
                return config
            }()

            config.apply(homeAssistant)
            try modelContext.save()
            try services.setHomeAssistantToken(homeAssistantToken, for: profileID)
            pushProfileSnapshot(profileID: profileID, modelContext: modelContext, services: services)
            showInfo("Home Assistant settings saved.")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func clearHomeAssistant(profileID: UUID, modelContext: ModelContext, services: AppServices) {
        do {
            if let config = try HomeAssistantConfig.fetch(for: profileID, in: modelContext) {
                modelContext.delete(config)
            }
            try modelContext.save()
            try services.clearHomeAssistantToken(for: profileID)
            homeAssistant = HomeAssistantConnectionConfiguration()
            homeAssistantToken = ""
            pushProfileSnapshot(profileID: profileID, modelContext: modelContext, services: services)
            showInfo("Home Assistant settings cleared.")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func testHomeAssistant(profileID: UUID, modelContext: ModelContext, services: AppServices) async {
        isTestingHomeAssistant = true
        defer { isTestingHomeAssistant = false }

        do {
            guard let endpoint = try await services.preferredHomeAssistantEndpoint(for: profileID, in: modelContext) else {
                throw HankRemoteServiceError.notConfigured
            }
            let remoteContext = endpoint.remoteAccess
            let message = try await services.homeAssistantService.validateConnection(
                context: remoteContext
            )
            saveHomeAssistant(profileID: profileID, modelContext: modelContext, services: services)
            showInfo(message ?? "Home Assistant connection succeeded.")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func saveSMB(profileID: UUID, modelContext: ModelContext, services: AppServices) {
        do {
            try persistSMBConfiguration(profileID: profileID, modelContext: modelContext, services: services)
            showInfo("SMB settings saved.")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func clearSMB(profileID: UUID, modelContext: ModelContext, services: AppServices) {
        do {
            if let selectedSMBConnectionID,
               let connection = try services.savedSMBConnection(id: selectedSMBConnectionID, for: profileID, in: modelContext)
            {
                let wasDefault = connection.isDefault
                modelContext.delete(connection)
                try modelContext.save()
                try services.clearSMBPassword(for: connection.id, profileID: profileID)
                let remainingConnections = try services.savedSMBConnections(for: profileID, in: modelContext)
                if wasDefault, let replacement = remainingConnections.first {
                    try services.setDefaultSMBConnection(replacement.id, for: profileID, in: modelContext)
                }
            }
            try loadSMBConnections(profileID: profileID, modelContext: modelContext, services: services)
            pushProfileSnapshot(profileID: profileID, modelContext: modelContext, services: services)
            showInfo("SMB connection cleared.")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func testSMB(profileID: UUID, modelContext: ModelContext, services: AppServices) async {
        isTestingSMB = true
        defer { isTestingSMB = false }

        do {
            let validationService = smbValidationServiceFactory(services.hankRemoteService)
            guard let remoteAccess = try services.hankRemoteConnectionContext(in: modelContext) else {
                throw HankRemoteServiceError.notConfigured
            }
            try await validationService.connect(
                config: smb,
                password: smbPassword,
                context: remoteAccess
            )
            _ = try await validationService.list(path: "")
            let startPath = smb.normalizedStartPath
            if !startPath.isEmpty {
                do {
                    _ = try await validationService.list(path: startPath)
                } catch {
                    throw SMBStartPathAccessError(path: startPath)
                }
            }
            await validationService.disconnect()
            try persistSMBConfiguration(profileID: profileID, modelContext: modelContext, services: services)
            showInfo("SMB connection succeeded.")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func beginNewSMBConnection() {
        selectedSMBConnectionID = nil
        smbDisplayName = ""
        smb = SMBConnectionDetails()
        smbPassword = ""
        smbIsDefault = smbConnections.isEmpty
    }

    func selectSMBConnection(
        _ connectionID: UUID,
        profileID: UUID,
        modelContext: ModelContext,
        services: AppServices
    ) {
        do {
            guard let connection = try services.savedSMBConnection(id: connectionID, for: profileID, in: modelContext) else {
                beginNewSMBConnection()
                return
            }
            selectedSMBConnectionID = connection.id
            smbDisplayName = connection.effectiveDisplayName
            smb = connection.connectionDetails
            smbPassword = try services.smbPassword(for: connection.id, profileID: profileID) ?? ""
            smbIsDefault = connection.isDefault
        } catch {
            showError(error.localizedDescription)
        }
    }

    func validateNotesStorage(profileID: UUID, modelContext: ModelContext, services: AppServices) async {
        isTestingNotesStorage = true
        defer { isTestingNotesStorage = false }

        do {
            let path = try await services.notesService.validateStorage(
                profileID: profileID,
                modelContext: modelContext,
                services: services
            )
            notesResolvedPath = path
            showInfo("Notes sync is available.")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func saveHankRemote(modelContext: ModelContext, services: AppServices) async {
        isSavingHankRemote = true
        defer { isSavingHankRemote = false }

        do {
            try persistHankRemote(modelContext: modelContext, services: services)
            await refreshHankRemoteCloudState(modelContext: modelContext, services: services)
            showInfo("Hank Remote settings saved.")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func testHankRemote(modelContext: ModelContext, services: AppServices) async {
        isTestingHankRemote = true
        defer { isTestingHankRemote = false }

        do {
            hankRemote.cloudURL = try normalizeHankRemoteCloudURL(hankRemote.cloudURL)
            if let context = try makeHankRemoteContext() {
                let response = try await services.hankRemoteService.ping(context, message: "settings smoke test")
                hankRemotePingResult = response.message
                try persistHankRemote(modelContext: modelContext, services: services)
                showInfo("Hank Remote relay responded with \(response.message).")
            } else {
                let message = try await services.hankRemoteService.validateConnection(
                    settings: hankRemote,
                    accessToken: hankRemoteAccessToken
                )
                showInfo(message ?? "Hank Remote connection succeeded.")
            }
        } catch {
            showError(error.localizedDescription)
        }
    }

    func syncProfile(profileID: UUID, modelContext: ModelContext, services: AppServices) async {
        isSyncingProfile = true
        defer { isSyncingProfile = false }

        do {
            try await services.profileSyncCoordinator.pushExplicitProfileSnapshot(
                profileID: profileID,
                modelContext: modelContext,
                services: services
            )
            await refreshHankRemoteCloudState(modelContext: modelContext, services: services, reportErrors: false)
            showInfo("Profile synced with Hank Serverside.")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func clearHankRemote(modelContext: ModelContext, services: AppServices) {
        do {
            let remoteContext = try makeHankRemoteContext() ?? services.hankRemoteConnectionContext(in: modelContext)
            if let remoteContext {
                Task { @MainActor in
                    await services.notificationService.unregisterAPNSDevice(
                        context: remoteContext,
                        services: services
                    )
                }
            }
            try services.saveHankRemoteSettings(HankRemoteSettingsSnapshot(), in: modelContext)
            try services.clearHankRemoteAccessToken()
            hankRemote = HankRemoteSettingsSnapshot()
            hankRemoteAccessToken = ""
            resetHankRemoteCloudState(keepCredentials: false)
            showInfo("Hank Remote settings cleared.")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func refreshHankRemoteCloudState(modelContext: ModelContext? = nil, services: AppServices, reportErrors: Bool = true) async {
        isRefreshingHankRemote = true
        defer { isRefreshingHankRemote = false }

        do {
            guard hankRemote.isEnabled else {
                resetHankRemoteCloudState(keepCredentials: true)
                return
            }

            hankRemote.cloudURL = try normalizeHankRemoteCloudURL(hankRemote.cloudURL)
            guard let context = try makeHankRemoteContext() else {
                resetHankRemoteCloudState(keepCredentials: true)
                return
            }

            let session = try await services.hankRemoteService.currentSession(context)
            hankRemoteSession = session
            hankRemoteEmail = session.user.email

            var home = try await services.hankRemoteService.currentHome(context)
            let selectedRole = await refreshHankRemoteHomeFeatures(context: context, services: services)
            home.role = selectedRole ?? inferredRole(for: home, userID: session.user.id)
            hankRemoteHome = home
            hankRemote.homeID = ""
            hankRemoteNewHomeName = home.name

            if let modelContext {
                try persistHankRemote(modelContext: modelContext, services: services)
            }
            refreshHankRemoteAgentDefaults()
        } catch {
            resetHankRemoteCloudState(keepCredentials: true)
            if reportErrors {
                showError(error.localizedDescription)
            }
        }
    }

    func authorizeProfileDeletion(
        profileID: UUID,
        password: String,
        modelContext: ModelContext,
        services: AppServices
    ) -> Bool {
        do {
            try services.authService.verifyPassword(
                profileID: profileID,
                password: password,
                in: modelContext
            )
            return true
        } catch {
            showError(error.localizedDescription)
            return false
        }
    }

    func registerHankRemote(modelContext: ModelContext, services: AppServices) async {
        isSigningIntoHankRemote = true
        defer { isSigningIntoHankRemote = false }

        do {
            let session = try await services.hankRemoteService.register(
                cloudURL: try normalizeHankRemoteCloudURL(hankRemote.cloudURL),
                email: trimmedHankRemoteEmail,
                password: trimmedHankRemotePassword
            )
            try applyHankRemoteSession(session, modelContext: modelContext, services: services)
            await refreshHankRemoteCloudState(modelContext: modelContext, services: services)
            showInfo("Signed in to Hank Remote.")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func signInToHankRemote(modelContext: ModelContext, services: AppServices) async {
        isSigningIntoHankRemote = true
        defer { isSigningIntoHankRemote = false }

        do {
            let session = try await services.hankRemoteService.login(
                cloudURL: try normalizeHankRemoteCloudURL(hankRemote.cloudURL),
                email: trimmedHankRemoteEmail,
                password: trimmedHankRemotePassword
            )
            try applyHankRemoteSession(session, modelContext: modelContext, services: services)
            await refreshHankRemoteCloudState(modelContext: modelContext, services: services)
            showInfo("Signed in to Hank Remote.")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func signOutOfHankRemote(modelContext: ModelContext, services: AppServices) async {
        isSigningIntoHankRemote = true
        defer { isSigningIntoHankRemote = false }

        let remoteContext: HankRemoteConnectionContext?
        do {
            remoteContext = try makeHankRemoteContext() ?? services.hankRemoteConnectionContext(in: modelContext)
        } catch {
            remoteContext = nil
        }
        do {
            if let context = remoteContext {
                await services.notificationService.unregisterAPNSDevice(context: context, services: services)
                try await services.hankRemoteService.logout(context)
            }
        } catch {
            // The local session should still be cleared even if the server call fails.
        }

        do {
            hankRemote.isEnabled = false
            hankRemote.homeID = ""
            hankRemoteAccessToken = ""
            try services.clearHankRemoteAccessToken()
            try services.saveHankRemoteSettings(hankRemote, in: modelContext)
            resetHankRemoteCloudState(keepCredentials: true)
            showInfo("Signed out of Hank Remote.")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func renameHankRemoteHome(modelContext: ModelContext, services: AppServices) async {
        isRenamingHankRemoteHome = true
        defer { isRenamingHankRemoteHome = false }

        do {
            guard let context = try makeHankRemoteContext() else {
                throw HankRemoteServiceError.notConfigured
            }
            let name = hankRemoteNewHomeName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw HankRemoteServiceError.server("Home name is required.")
            }
            let home = try await services.hankRemoteService.renameHome(name: name, context: context)
            hankRemoteNewHomeName = home.name
            hankRemote.homeID = ""
            try persistHankRemote(modelContext: modelContext, services: services)
            await refreshHankRemoteCloudState(modelContext: modelContext, services: services)
            showInfo("Updated Home name to \"\(home.name)\".")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func createHankRemoteInvitation(services: AppServices) async {
        isCreatingHankRemoteInvitation = true
        defer { isCreatingHankRemoteInvitation = false }

        do {
            guard let context = try makeHankRemoteContext() else {
                throw HankRemoteServiceError.notConfigured
            }
            guard canManageHankRemoteHomeMembers else {
                throw HankRemoteServiceError.server("Only admins can invite members.")
            }
            let response = try await services.hankRemoteService.createHomeInvitation(
                email: hankRemoteInvitationEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                context: context
            )
            hankRemoteInvitationID = response.invitationID
            hankRemoteInvitationToken = response.token
            hankRemoteInvitationExpiresAt = response.expiresAt
            hankRemoteInvitationEmail = ""
            showInfo("Invitation created for \(response.email).")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func revokeLastHankRemoteInvitation(services: AppServices) async {
        isRevokingHankRemoteInvitation = true
        defer { isRevokingHankRemoteInvitation = false }

        do {
            guard let context = try makeHankRemoteContext() else {
                throw HankRemoteServiceError.notConfigured
            }
            guard canManageHankRemoteHomeMembers else {
                throw HankRemoteServiceError.server("Only admins can revoke invitations.")
            }
            let invitationID = hankRemoteInvitationID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !invitationID.isEmpty else {
                throw HankRemoteServiceError.server("There is no invitation to revoke.")
            }
            try await services.hankRemoteService.revokeHomeInvitation(invitationID: invitationID, context: context)
            hankRemoteInvitationID = ""
            hankRemoteInvitationToken = ""
            hankRemoteInvitationExpiresAt = nil
            showInfo("Invitation revoked.")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func acceptHankRemoteInvitation(modelContext: ModelContext, services: AppServices) async {
        isAcceptingHankRemoteInvitation = true
        defer { isAcceptingHankRemoteInvitation = false }

        do {
            guard let context = try makeHankRemoteContext() else {
                throw HankRemoteServiceError.notConfigured
            }
            let token = hankRemoteJoinToken.trimmingCharacters(in: .whitespacesAndNewlines)
            let home = try await services.hankRemoteService.acceptHomeInvitation(token: token, context: context)
            hankRemoteJoinToken = ""
            hankRemote.homeID = ""
            try persistHankRemote(modelContext: modelContext, services: services)
            await refreshHankRemoteCloudState(modelContext: modelContext, services: services)
            showInfo("Joined \(home.name).")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func removeHankRemoteMember(_ userID: String, services: AppServices) async {
        removingHankRemoteMemberID = userID
        defer { removingHankRemoteMemberID = nil }

        do {
            guard let context = try makeHankRemoteContext() else {
                throw HankRemoteServiceError.notConfigured
            }
            guard canManageHankRemoteHomeMembers else {
                throw HankRemoteServiceError.server("Only admins can remove members.")
            }
            try await services.hankRemoteService.removeHomeMember(
                userID: userID,
                context: context
            )
            _ = await refreshHankRemoteHomeFeatures(context: context, services: services)
            showInfo("Home member removed.")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func saveHankRemoteHomeAssistantProfile(services: AppServices) async {
        isSavingHankRemoteHomeAssistantProfile = true
        defer { isSavingHankRemoteHomeAssistantProfile = false }

        do {
            guard let context = try makeHankRemoteContext() else {
                throw HankRemoteServiceError.notConfigured
            }
            guard canManageHankRemoteIntegrations else {
                throw HankRemoteServiceError.server("Only admins can update shared integrations.")
            }
            let secrets = makeNonEmptySecrets(["token": hankRemoteSharedHomeAssistantToken])
            let profile = try await services.hankRemoteService.updateServiceProfile(
                serviceType: .homeAssistant,
                publicConfig: [
                    "base_url": hankRemoteSharedHomeAssistantBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                    "timeout_seconds": hankRemoteSharedHomeAssistantTimeoutSeconds
                ],
                secrets: secrets,
                persist: hankRemotePersistSharedIntegrations,
                context: context
            )
            updateServiceProfile(profile)
            hankRemoteSharedHomeAssistantToken = ""
            showInfo("Shared Home Assistant settings saved.")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func saveHankRemoteSMBProfile(services: AppServices) async {
        isSavingHankRemoteSMBProfile = true
        defer { isSavingHankRemoteSMBProfile = false }

        do {
            guard let context = try makeHankRemoteContext() else {
                throw HankRemoteServiceError.notConfigured
            }
            guard canManageHankRemoteIntegrations else {
                throw HankRemoteServiceError.server("Only admins can update shared integrations.")
            }
            let secrets = makeNonEmptySecrets(["password": hankRemoteSharedSMBPassword])
            let profile = try await services.hankRemoteService.updateServiceProfile(
                serviceType: .smb,
                publicConfig: [
                    "host": hankRemoteSharedSMBHost.trimmingCharacters(in: .whitespacesAndNewlines),
                    "share": hankRemoteSharedSMBShare.trimmingCharacters(in: .whitespacesAndNewlines),
                    "domain": hankRemoteSharedSMBDomain.trimmingCharacters(in: .whitespacesAndNewlines),
                    "username": hankRemoteSharedSMBUsername.trimmingCharacters(in: .whitespacesAndNewlines)
                ],
                secrets: secrets,
                persist: hankRemotePersistSharedIntegrations,
                context: context
            )
            updateServiceProfile(profile)
            hankRemoteSharedSMBPassword = ""
            showInfo("Shared SMB settings saved.")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func createHankRemoteAgentToken(services: AppServices) async {
        isCreatingHankRemoteAgentToken = true
        defer { isCreatingHankRemoteAgentToken = false }

        do {
            guard let context = try makeHankRemoteContext() else {
                throw HankRemoteServiceError.notConfigured
            }
            guard canManageHankRemoteHomeAgent else {
                throw HankRemoteServiceError.server("Only admins can manage agent tokens.")
            }
            let homeName = hankRemoteHome?.name ?? ""
            let agentID = hankRemoteAgentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? Self.defaultAgentID(for: homeName)
                : hankRemoteAgentID.trimmingCharacters(in: .whitespacesAndNewlines)
            let agentName = hankRemoteAgentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? Self.defaultAgentName(for: homeName)
                : hankRemoteAgentName.trimmingCharacters(in: .whitespacesAndNewlines)
            let token = try await services.hankRemoteService.createAgentToken(
                agentID: agentID,
                agentName: agentName,
                expiresInSeconds: nil,
                context: context
            )
            hankRemoteLastIssuedToken = token
            hankRemoteAgentID = agentID
            hankRemoteAgentName = agentName
            hankRemoteAgentTokens = Self.uniquedFirst(
                try await services.hankRemoteService.listAgentTokens(context: context)
            ) { $0.id }
            showInfo("Issued a new agent token for \(agentID).")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func revokeHankRemoteAgentToken(_ tokenID: String, services: AppServices) async {
        revokingHankRemoteTokenID = tokenID
        defer { revokingHankRemoteTokenID = nil }

        do {
            guard let context = try makeHankRemoteContext() else {
                throw HankRemoteServiceError.notConfigured
            }
            guard canManageHankRemoteHomeAgent else {
                throw HankRemoteServiceError.server("Only admins can revoke agent tokens.")
            }
            try await services.hankRemoteService.revokeAgentToken(tokenID: tokenID, context: context)
            hankRemoteAgentTokens = Self.uniquedFirst(
                try await services.hankRemoteService.listAgentTokens(context: context)
            ) { $0.id }
            showInfo("Agent token revoked.")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func pingHankRemote(services: AppServices) async {
        isPingingHankRemote = true
        defer { isPingingHankRemote = false }

        do {
            guard let context = try makeHankRemoteContext() else {
                throw HankRemoteServiceError.notConfigured
            }
            let response = try await services.hankRemoteService.ping(context, message: "hank app")
            hankRemotePingResult = "\(response.message) at \(Self.remoteDateFormatter.string(from: response.time))"
            showInfo("Hank Remote agent replied.")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func startOpenAIAccountLink(services: AppServices) async -> URL? {
        isStartingOpenAIAccountLink = true
        defer { isStartingOpenAIAccountLink = false }

        do {
            guard let context = try makeHankRemoteContext() else {
                throw HankRemoteServiceError.notConfigured
            }
            let start = try await services.hankRemoteService.startOpenAIAccountLink(context: context)
            hankRemoteOpenAIStart = start

            switch start.authMode {
            case "device_code":
                showInfo(start.userCode.isEmpty ? "Complete ChatGPT/Codex device authorization." : "Enter \(start.userCode) to link ChatGPT/Codex.")
                startOpenAIAccountStatusPolling(context: context, services: services, pollAfterSeconds: start.pollAfterSeconds)
                return start.verificationURL
            default:
                showInfo("Complete OpenAI sign in to link ChatGPT features.")
                return start.authorizationURL
            }
        } catch {
            showError(error.localizedDescription)
            return nil
        }
    }

    func refreshHankRemoteAssistant(services: AppServices) async {
        isRefreshingHankRemoteAssistant = true
        defer { isRefreshingHankRemoteAssistant = false }

        do {
            guard let context = try makeHankRemoteContext() else {
                throw HankRemoteServiceError.notConfigured
            }
            await refreshHankRemoteAssistant(context: context, services: services, reportErrors: true)
        } catch {
            showError(error.localizedDescription)
        }
    }

    func saveHankRemoteAssistantSettings(services: AppServices) async {
        isSavingHankRemoteAssistantSettings = true
        defer { isSavingHankRemoteAssistantSettings = false }

        do {
            guard let context = try makeHankRemoteContext() else {
                throw HankRemoteServiceError.notConfigured
            }
            guard let current = hankRemoteAssistantSettings?.settings else {
                throw HankRemoteServiceError.server("Assistant settings are not loaded yet.")
            }
            let update = HankRemoteAssistantSettingsUpdate(
                profileNotesEnabled: hankRemoteAssistantSourceSelections["profile_notes"] ?? current.profileNotesEnabled,
                homeNotesEnabled: hankRemoteAssistantSourceSelections["home_notes"] ?? current.homeNotesEnabled,
                filesEnabled: hankRemoteAssistantSourceSelections["files"] ?? current.filesEnabled,
                calendarEnabled: hankRemoteAssistantSourceSelections["calendar"] ?? current.calendarEnabled,
                homeAssistantEnabled: hankRemoteAssistantSourceSelections["homeassistant"] ?? current.homeAssistantEnabled,
                projectDocsEnabled: hankRemoteAssistantSourceSelections["project_docs"] ?? current.projectDocsEnabled,
                conversationsEnabled: hankRemoteAssistantSourceSelections["assistant_conversation"] ?? current.conversationsEnabled,
                systemPrompt: hankRemoteAssistantSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let saved = try await services.hankRemoteService.updateAssistantSettings(update, context: context)
            applyAssistantSettings(saved)
            showInfo("Assistant settings saved.")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func updateHankRemoteMemberRole(_ userID: String, services: AppServices) async {
        updatingHankRemoteMemberRoleUserID = userID
        defer { updatingHankRemoteMemberRoleUserID = nil }

        do {
            guard let context = try makeHankRemoteContext() else {
                throw HankRemoteServiceError.notConfigured
            }
            guard canManageHankRemoteHomeMembers else {
                throw HankRemoteServiceError.server("Only admins can update member roles.")
            }
            let role = hankRemoteMemberRoleSelections[userID] ?? .member
            _ = try await services.hankRemoteService.updateHomeMemberRole(userID: userID, role: role, context: context)
            _ = await refreshHankRemoteHomeFeatures(context: context, services: services)
            showInfo("Member role updated.")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func saveHankRemotePermissions(services: AppServices) async {
        isSavingHankRemotePermissions = true
        defer { isSavingHankRemotePermissions = false }

        do {
            guard let context = try makeHankRemoteContext() else {
                throw HankRemoteServiceError.notConfigured
            }
            guard canManageHankRemotePermissions else {
                throw HankRemoteServiceError.server("Only admins can update Home permissions.")
            }
            let permissions = try await services.hankRemoteService.updateHomePermissions(
                homeAssistant: hankRemoteHomeAssistantEnabled,
                files: hankRemoteFilesEnabled,
                notes: hankRemoteNotesEnabled,
                context: context
            )
            applyHomePermissions(permissions)
            showInfo("Home permissions saved.")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func saveHankRemoteMemberPermissions(_ userID: String, services: AppServices) async {
        savingHankRemoteMemberPermissionsUserID = userID
        defer { savingHankRemoteMemberPermissionsUserID = nil }

        do {
            guard let context = try makeHankRemoteContext() else {
                throw HankRemoteServiceError.notConfigured
            }
            guard canManageHankRemotePermissions else {
                throw HankRemoteServiceError.server("Only admins can update member permissions.")
            }
            let permissions = try await services.hankRemoteService.updateMemberPermissions(
                userID: userID,
                homeAssistant: hankRemoteMemberHomeAssistantOverrides[userID]?.boolValue,
                files: hankRemoteMemberFilesOverrides[userID]?.boolValue,
                notes: hankRemoteMemberNotesOverrides[userID]?.boolValue,
                context: context
            )
            applyMemberPermissions(permissions)
            showInfo("Member permissions saved.")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func refreshHankRemoteStorage(services: AppServices) async {
        do {
            guard let context = try makeHankRemoteContext() else {
                throw HankRemoteServiceError.notConfigured
            }
            await refreshHankRemoteStorage(context: context, services: services, reportErrors: true)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func refreshHankRemoteStorage(
        context: HankRemoteConnectionContext,
        services: AppServices,
        reportErrors: Bool
    ) async {
        isRefreshingHankRemoteStorage = true
        defer { isRefreshingHankRemoteStorage = false }

        do {
            let status = try await services.hankRemoteService.storageStatus(context: context)
            hankRemoteStorageStatus = status
            hankRemoteStorageConfig = status.config
            hankRemoteStorageEvents = status.events
            hankRemoteStorageFeatureAvailable = true
            applyStorageConfigForm(status.config)
        } catch HankRemoteServiceError.notFound {
            hankRemoteStorageFeatureAvailable = false
        } catch {
            hankRemoteStorageFeatureAvailable = false
            if reportErrors {
                showError(error.localizedDescription)
            }
        }
    }

    func refreshHankRemoteNotificationSettings(services: AppServices) async {
        do {
            guard let context = try makeHankRemoteContext() else {
                throw HankRemoteServiceError.notConfigured
            }
            await refreshHankRemoteNotificationSettings(context: context, services: services, reportErrors: true)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func refreshHankRemoteNotificationSettings(
        context: HankRemoteConnectionContext,
        services: AppServices,
        reportErrors: Bool
    ) async {
        guard HankNotificationService.isEnabled else {
            hankRemoteNotificationsFeatureAvailable = false
            return
        }
        do {
            let settings = try await services.hankRemoteService.notificationSettings(context: context)
            applyNotificationSettings(settings)
            hankRemoteNotificationsFeatureAvailable = true
        } catch HankRemoteServiceError.notFound {
            hankRemoteNotificationsFeatureAvailable = false
        } catch {
            hankRemoteNotificationsFeatureAvailable = false
            if reportErrors {
                showError(error.localizedDescription)
            }
        }
    }

    func saveHankRemoteNotificationSettings(services: AppServices) async {
        guard HankNotificationService.isEnabled else {
            hankRemoteNotificationsFeatureAvailable = false
            return
        }
        isSavingHankRemoteNotificationSettings = true
        defer { isSavingHankRemoteNotificationSettings = false }

        do {
            guard let context = try makeHankRemoteContext() else {
                throw HankRemoteServiceError.notConfigured
            }
            let saved = try await services.hankRemoteService.updateNotificationSettings(
                HankRemoteNotificationSettings(
                    userID: hankRemoteNotificationSettings?.userID,
                    storage: hankRemoteStorageNotificationsEnabled,
                    notes: hankRemoteNotesNotificationsEnabled,
                    dashboardEntities: hankRemoteDashboardEntityNotificationsEnabled,
                    updatedAt: hankRemoteNotificationSettings?.updatedAt
                ),
                context: context
            )
            applyNotificationSettings(saved)
            hankRemoteNotificationsFeatureAvailable = true
            await services.notificationService.registerAPNSDeviceIfPossible(context: context, services: services)
            showInfo("Notification settings saved.")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func requestHankRemoteNotifications(modelContext: ModelContext, services: AppServices) async {
        guard HankNotificationService.isEnabled else {
            hankRemoteNotificationsFeatureAvailable = false
            return
        }
        isRequestingHankRemoteNotificationAccess = true
        defer { isRequestingHankRemoteNotificationAccess = false }

        do {
            let context = try makeHankRemoteContext() ?? services.hankRemoteConnectionContext(in: modelContext)
            guard let context else {
                throw HankRemoteServiceError.notConfigured
            }
            await services.notificationService.requestAuthorizationAndRegister(
                context: context,
                services: services
            )
            if services.notificationService.lastRegistrationError == nil {
                showInfo("Notifications are ready.")
            }
        } catch {
            showError(error.localizedDescription)
        }
    }

    func saveHankRemoteStorageConfig(services: AppServices) async {
        isSavingHankRemoteStorageConfig = true
        defer { isSavingHankRemoteStorageConfig = false }

        do {
            guard let context = try makeHankRemoteContext() else {
                throw HankRemoteServiceError.notConfigured
            }
            guard canManageHankRemotePermissions else {
                throw HankRemoteServiceError.server("Only admins can update storage settings.")
            }
            let config = HankRemoteStorageConfig(
                targetType: hankRemoteStorageBackupTargetType.trimmingCharacters(in: .whitespacesAndNewlines),
                targetPath: hankRemoteStorageBackupTargetPath.trimmingCharacters(in: .whitespacesAndNewlines),
                fullSchedule: hankRemoteStorageFullSchedule.trimmingCharacters(in: .whitespacesAndNewlines),
                differentialSchedule: hankRemoteStorageDifferentialSchedule.trimmingCharacters(in: .whitespacesAndNewlines),
                checksumIntervalSeconds: hankRemoteStorageChecksumIntervalSeconds,
                restoreVerificationSchedule: hankRemoteStorageRestoreVerificationSchedule.trimmingCharacters(in: .whitespacesAndNewlines),
                retainedFullBackupCount: hankRemoteStorageRetainedFullBackupCount,
                restoreConfirmationPhrase: hankRemoteStorageConfig?.restoreConfirmationPhrase ?? ""
            )
            let saved = try await services.hankRemoteService.updateStorageConfig(config, context: context)
            hankRemoteStorageConfig = saved
            applyStorageConfigForm(saved)
            showInfo("Storage settings saved.")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func requestHankRemoteStorageBackup(type: String, services: AppServices) async {
        isRequestingHankRemoteStorageBackup = true
        defer { isRequestingHankRemoteStorageBackup = false }

        do {
            guard let context = try makeHankRemoteContext() else {
                throw HankRemoteServiceError.notConfigured
            }
            guard canManageHankRemotePermissions else {
                throw HankRemoteServiceError.server("Only admins can request backups.")
            }
            try await services.hankRemoteService.requestStorageBackup(type: type, context: context)
            await refreshHankRemoteStorage(context: context, services: services, reportErrors: false)
            showInfo("Backup requested.")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func requestHankRemoteStorageRestoreTest(services: AppServices) async {
        isRequestingHankRemoteStorageRestoreTest = true
        defer { isRequestingHankRemoteStorageRestoreTest = false }

        do {
            guard let context = try makeHankRemoteContext() else {
                throw HankRemoteServiceError.notConfigured
            }
            guard canManageHankRemotePermissions else {
                throw HankRemoteServiceError.server("Only admins can test restores.")
            }
            try await services.hankRemoteService.requestStorageRestoreTest(context: context)
            await refreshHankRemoteStorage(context: context, services: services, reportErrors: false)
            showInfo("Restore test requested.")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func requestHankRemoteStoragePrimaryRestore(services: AppServices) async {
        isRequestingHankRemoteStoragePrimaryRestore = true
        defer { isRequestingHankRemoteStoragePrimaryRestore = false }

        do {
            guard let context = try makeHankRemoteContext() else {
                throw HankRemoteServiceError.notConfigured
            }
            guard canManageHankRemotePermissions else {
                throw HankRemoteServiceError.server("Only admins can restore the primary database.")
            }
            let phrase = hankRemoteStorageStatus?.restore.confirmationPhrase
                ?? hankRemoteStorageConfig?.restoreConfirmationPhrase
                ?? ""
            guard !phrase.isEmpty, hankRemoteStoragePrimaryRestoreConfirmation == phrase else {
                throw HankRemoteServiceError.server("Enter the confirmation phrase before restoring the primary database.")
            }
            try await services.hankRemoteService.requestStoragePrimaryRestore(
                confirmationPhrase: hankRemoteStoragePrimaryRestoreConfirmation,
                context: context
            )
            hankRemoteStoragePrimaryRestoreConfirmation = ""
            await refreshHankRemoteStorage(context: context, services: services, reportErrors: false)
            showInfo("Primary restore requested.")
        } catch {
            showError(error.localizedDescription)
        }
    }

    private enum BannerKind {
        case info
        case error
    }

    private var trimmedHankRemoteEmail: String {
        hankRemoteEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var trimmedHankRemotePassword: String {
        hankRemotePassword.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hankRemoteHomeRole: HankRemoteHomeRole? {
        hankRemoteHome?.role
    }

    var canManageHankRemoteHomeMembers: Bool {
        hankRemoteHome?.canManageMembers == true
    }

    var canManageHankRemoteHomeAgent: Bool {
        hankRemoteHome?.canManageAgent == true
    }

    var canManageHankRemoteIntegrations: Bool {
        hankRemoteHome?.canManageIntegrations == true
    }

    var canManageHankRemotePermissions: Bool {
        hankRemoteHome?.canManagePermissions == true
    }

    var homeAssistantServiceProfile: HankRemoteServiceProfile? {
        hankRemoteServiceProfiles.first(where: { $0.serviceType == .homeAssistant })
    }

    var smbServiceProfile: HankRemoteServiceProfile? {
        hankRemoteServiceProfiles.first(where: { $0.serviceType == .smb })
    }

    private func showInfo(_ message: String) {
        infoMessage = message
        errorMessage = nil
    }

    private func showError(_ message: String) {
        infoMessage = nil
        errorMessage = message
    }

    private func scheduleBannerDismiss(for kind: BannerKind, message: String?) {
        let task: Task<Void, Never>?

        switch kind {
        case .info:
            infoDismissTask?.cancel()
            task = message.map { message in
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    guard !Task.isCancelled else {
                        return
                    }

                    await MainActor.run {
                        if self?.infoMessage == message {
                            self?.infoMessage = nil
                        }
                    }
                }
            }
            infoDismissTask = task
        case .error:
            errorDismissTask?.cancel()
            task = message.map { message in
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    guard !Task.isCancelled else {
                        return
                    }

                    await MainActor.run {
                        if self?.errorMessage == message {
                            self?.errorMessage = nil
                        }
                    }
                }
            }
            errorDismissTask = task
        }
    }

    private func inferredRole(for home: HankRemoteHome, userID: String) -> HankRemoteHomeRole? {
        if home.userID == userID {
            return .admin
        }
        return hankRemoteMembers.first(where: { $0.userID == userID })?.role
    }

    private func clearHankRemoteHomeFeatures() {
        hankRemoteAgent = nil
        hankRemoteMembers = []
        hankRemoteAgentTokens = []
        hankRemoteSyncStatus = nil
        hankRemoteServiceProfiles = []
        hankRemoteHomePermissions = nil
        hankRemoteMemberPermissions = [:]
        hankRemoteMemberRoleSelections = [:]
        hankRemoteMemberHomeAssistantOverrides = [:]
        hankRemoteMemberFilesOverrides = [:]
        hankRemoteMemberNotesOverrides = [:]
        hankRemoteMembersFeatureAvailable = false
        hankRemoteAgentFeatureAvailable = false
        hankRemoteSyncFeatureAvailable = false
        hankRemoteServiceProfilesFeatureAvailable = false
        hankRemotePermissionsFeatureAvailable = false
        hankRemoteStorageFeatureAvailable = false
        hankRemoteInvitationToken = ""
        hankRemoteInvitationID = ""
        hankRemoteInvitationExpiresAt = nil
        hankRemoteSharedHomeAssistantToken = ""
        hankRemoteSharedSMBPassword = ""
        hankRemoteStorageStatus = nil
        hankRemoteStorageConfig = nil
        hankRemoteStorageEvents = []
        hankRemoteStoragePrimaryRestoreConfirmation = ""
        hankRemoteAssistantStatus = nil
        hankRemoteAssistantSettings = nil
        hankRemoteOpenAIStatus = nil
        hankRemoteOpenAIStart = nil
        hankRemoteNotificationSettings = nil
        hankRemoteAssistantSourceSelections = [:]
        hankRemoteAssistantSystemPrompt = ""
        hankRemoteAssistantFeatureAvailable = false
        hankRemoteOpenAIFeatureAvailable = false
        hankRemoteNotificationsFeatureAvailable = false
        openAIAccountStatusPollTask?.cancel()
        openAIAccountStatusPollTask = nil
    }

    private func refreshHankRemoteHomeFeatures(
        context: HankRemoteConnectionContext,
        services: AppServices
    ) async -> HankRemoteHomeRole? {
        clearHankRemoteHomeFeatures()
        let currentUserID = hankRemoteSession?.user.id

        do {
            let members = try await services.hankRemoteService.listHomeMembers(context: context)
            let uniquedMembers = Self.uniquedFirst(members) { $0.userID }
            hankRemoteMembers = uniquedMembers
            hankRemoteMemberRoleSelections = Dictionary(uniqueKeysWithValues: uniquedMembers.map { ($0.userID, $0.role) })
            hankRemoteMembersFeatureAvailable = true
        } catch HankRemoteServiceError.notFound {
            hankRemoteMembersFeatureAvailable = false
        } catch {
            hankRemoteMembersFeatureAvailable = false
        }

        let currentRole = currentUserID.flatMap { userID in
            hankRemoteMembers.first(where: { $0.userID == userID })?.role
        }

        do {
            hankRemoteAgent = try await services.hankRemoteService.homeAgent(context)
            hankRemoteAgentFeatureAvailable = true
        } catch HankRemoteServiceError.notFound {
            hankRemoteAgentFeatureAvailable = false
        } catch {
            hankRemoteAgentFeatureAvailable = false
        }

        if currentRole == .admin {
            do {
                hankRemoteAgentTokens = Self.uniquedFirst(
                    try await services.hankRemoteService.listAgentTokens(context: context)
                ) { $0.id }
            } catch HankRemoteServiceError.notFound {
                hankRemoteAgentTokens = []
            } catch {
                hankRemoteAgentTokens = []
            }
        }

        do {
            let sync = try await services.hankRemoteService.homeSyncStatus(context: context)
            hankRemoteSyncStatus = sync
            hankRemoteSyncFeatureAvailable = true
        } catch HankRemoteServiceError.notFound {
            hankRemoteSyncFeatureAvailable = false
        } catch {
            hankRemoteSyncFeatureAvailable = false
        }

        do {
            let profiles = try await services.hankRemoteService.listServiceProfiles(context: context)
            hankRemoteServiceProfiles = Self.uniquedFirst(profiles) { $0.id }
            hankRemoteServiceProfilesFeatureAvailable = true
            applyServiceProfileForms()
        } catch HankRemoteServiceError.notFound {
            hankRemoteServiceProfilesFeatureAvailable = false
        } catch {
            hankRemoteServiceProfilesFeatureAvailable = false
        }

        do {
            let permissions = try await services.hankRemoteService.homePermissions(context)
            applyHomePermissions(permissions)
            hankRemotePermissionsFeatureAvailable = true
        } catch HankRemoteServiceError.notFound {
            hankRemotePermissionsFeatureAvailable = false
        } catch {
            hankRemotePermissionsFeatureAvailable = false
        }

        if currentRole == .admin {
            for member in hankRemoteMembers {
                do {
                    let permissions = try await services.hankRemoteService.memberPermissions(userID: member.userID, context: context)
                    applyMemberPermissions(permissions)
                } catch HankRemoteServiceError.notFound {
                    applyMemberPermissions(
                        HankRemoteHomeMemberPermissions(
                            homeID: "",
                            userID: member.userID,
                            homeAssistant: nil,
                            files: nil,
                            notes: nil,
                            updatedAt: nil,
                            updatedBy: ""
                        )
                    )
                } catch {
                    continue
                }
            }

            await refreshHankRemoteStorage(context: context, services: services, reportErrors: false)
        }

        await refreshHankRemoteNotificationSettings(context: context, services: services, reportErrors: false)
        await refreshHankRemoteAssistant(context: context, services: services, reportErrors: false)
        startHankRemoteRealtimeRefresh(context: context, services: services)
        return currentRole
    }

    private func refreshHankRemoteAssistant(
        context: HankRemoteConnectionContext,
        services: AppServices,
        reportErrors: Bool
    ) async {
        var lastError: Error?

        do {
            hankRemoteAssistantStatus = try await services.hankRemoteService.assistantStatus(context: context)
            hankRemoteAssistantFeatureAvailable = true
        } catch HankRemoteServiceError.notFound {
            hankRemoteAssistantFeatureAvailable = false
        } catch {
            hankRemoteAssistantFeatureAvailable = false
            lastError = error
        }

        do {
            let settings = try await services.hankRemoteService.assistantSettings(context: context)
            applyAssistantSettings(settings)
            hankRemoteAssistantFeatureAvailable = true
        } catch HankRemoteServiceError.notFound {
            hankRemoteAssistantSettings = nil
        } catch {
            lastError = error
        }

        do {
            hankRemoteOpenAIStatus = try await services.hankRemoteService.openAIAccountStatus(context: context)
            hankRemoteOpenAIFeatureAvailable = true
        } catch HankRemoteServiceError.notFound {
            hankRemoteOpenAIFeatureAvailable = false
        } catch {
            hankRemoteOpenAIFeatureAvailable = false
            lastError = error
        }

        if reportErrors, let lastError {
            showError(lastError.localizedDescription)
        }
    }

    private func applyAssistantSettings(_ response: HankRemoteAssistantSettingsResponse) {
        hankRemoteAssistantSettings = response
        hankRemoteAssistantSystemPrompt = response.settings.systemPrompt
        hankRemoteAssistantSourceSelections = Dictionary(
            uniqueKeysWithValues: response.sources.map { ($0.key, $0.enabled) }
        )
    }

    func isHankRemoteAssistantSourceAvailable(_ key: String) -> Bool {
        guard hankRemoteHomeRole != .admin else {
            return true
        }
        switch key {
        case "home_notes":
            return effectiveMemberPermission(homeDefault: hankRemoteHomePermissions?.notes, memberOverride: currentMemberPermissions?.notes)
        case "files":
            return effectiveMemberPermission(homeDefault: hankRemoteHomePermissions?.files, memberOverride: currentMemberPermissions?.files)
        case "homeassistant":
            return effectiveMemberPermission(homeDefault: hankRemoteHomePermissions?.homeAssistant, memberOverride: currentMemberPermissions?.homeAssistant)
        default:
            return true
        }
    }

    private var currentMemberPermissions: HankRemoteHomeMemberPermissions? {
        guard let userID = hankRemoteSession?.user.id else {
            return nil
        }
        return hankRemoteMemberPermissions[userID]
    }

    private func effectiveMemberPermission(homeDefault: Bool?, memberOverride: Bool?) -> Bool {
        memberOverride ?? homeDefault ?? true
    }

    private func startOpenAIAccountStatusPolling(
        context: HankRemoteConnectionContext,
        services: AppServices,
        pollAfterSeconds: Int
    ) {
        openAIAccountStatusPollTask?.cancel()
        openAIAccountStatusPollTask = Task { [weak self] in
            let delay = UInt64(max(2, pollAfterSeconds)) * 1_000_000_000
            for _ in 0 ..< 60 {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else {
                    return
                }

                do {
                    let status = try await services.hankRemoteService.openAIAccountStatus(context: context)
                    await MainActor.run {
                        self?.hankRemoteOpenAIStatus = status
                        self?.hankRemoteOpenAIFeatureAvailable = true
                    }
                    if status.linked || ["expired", "failed", "error", "cancelled", "canceled"].contains(status.pending?.state.lowercased() ?? "") {
                        return
                    }
                } catch {
                    return
                }
            }
        }
    }

    private func startHankRemoteRealtimeRefresh(
        context: HankRemoteConnectionContext,
        services: AppServices
    ) {
        hankRemoteRealtimeTask?.cancel()
        hankRemoteRealtimeTask = Task { [weak self] in
            do {
                try await services.hankRemoteService.subscribeRealtime(
                    topics: ["home.status", "home.settings", "home.members", "home.permissions", "storage.health"],
                    context: context
                )
                for await event in await services.hankRemoteService.realtimeEvents() {
                    guard [
                        "home.status_changed",
                        "sync.status_changed",
                        "agent.status_changed",
                        "service_profiles.changed",
                        "members.changed",
                        "permissions.changed",
                        "invitations.changed",
                        "storage.health.changed",
                        "storage.backup.failed",
                        "storage.checksum.corruption",
                        "storage.restore.started",
                        "storage.restore.completed",
                        "storage.restore.failed"
                    ].contains(event.event) else {
                        continue
                    }
                    if let notification = Self.localStorageNotification(for: event) {
                        await services.notificationService.presentLocalNotification(notification)
                    }
                    _ = await self?.refreshHankRemoteHomeFeatures(context: context, services: services)
                }
            } catch {
                return
            }
        }
    }

    private static func localStorageNotification(for event: HankRemoteRealtimeEvent) -> HankLocalNotification? {
        guard
            event.event.hasPrefix("storage."),
            let payloadData = event.payload,
            let payload = try? JSONDecoder().decode(StorageRealtimeNotificationPayload.self, from: payloadData),
            let url = URL(string: "hank://notifications/storage")
        else {
            return nil
        }

        let operation = payload.operation?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let status = payload.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let severity = payload.severity?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let title: String
        let body: String

        switch (operation, status) {
        case ("backup", "started"), ("backup", "pending"):
            title = "Backup Started"
            body = "Hank Remote started a PostgreSQL backup."
        case ("backup", "success"):
            title = "Backup Completed"
            body = "Hank Remote completed a PostgreSQL backup."
        case ("backup", "failed"):
            title = "Backup Failed"
            body = "A PostgreSQL backup needs attention."
        case ("restore_test", "started"), ("restore_test", "pending"),
             ("primary_restore", "started"), ("primary_restore", "pending"):
            title = "Restore Started"
            body = "Hank Remote started a restore operation."
        case ("restore_test", "success"), ("primary_restore", "success"):
            title = "Restore Completed"
            body = "Hank Remote completed a restore operation."
        case ("restore_test", "failed"), ("primary_restore", "failed"):
            title = "Restore Failed"
            body = "A restore operation needs attention."
        case ("checksum", _), ("amcheck", _):
            guard severity == "critical" else {
                return nil
            }
            title = "Storage Check Failed"
            body = "A storage integrity check needs attention."
        default:
            return nil
        }

        return HankLocalNotification(
            category: .storage,
            title: title,
            body: body,
            url: url,
            threadID: "storage:\(payload.eventID ?? event.event)"
        )
    }

    private func applyHomePermissions(_ permissions: HankRemoteHomePermissions) {
        hankRemoteHomePermissions = permissions
        hankRemoteHomeAssistantEnabled = permissions.homeAssistant
        hankRemoteFilesEnabled = permissions.files
        hankRemoteNotesEnabled = permissions.notes
        hankRemotePermissionsFeatureAvailable = true
    }

    private func applyMemberPermissions(_ permissions: HankRemoteHomeMemberPermissions) {
        hankRemoteMemberPermissions[permissions.userID] = permissions
        hankRemoteMemberHomeAssistantOverrides[permissions.userID] = HankRemotePermissionOverride(permissions.homeAssistant)
        hankRemoteMemberFilesOverrides[permissions.userID] = HankRemotePermissionOverride(permissions.files)
        hankRemoteMemberNotesOverrides[permissions.userID] = HankRemotePermissionOverride(permissions.notes)
    }

    private func applyServiceProfileForms() {
        if let profile = homeAssistantServiceProfile {
            let config = decodedPublicConfig(from: profile.publicConfigJSON)
            hankRemoteSharedHomeAssistantBaseURL = stringValue(for: "base_url", in: config)
            hankRemoteSharedHomeAssistantTimeoutSeconds = intValue(for: "timeout_seconds", in: config) ?? 10
        } else {
            hankRemoteSharedHomeAssistantBaseURL = ""
            hankRemoteSharedHomeAssistantTimeoutSeconds = 10
        }

        if let profile = smbServiceProfile {
            let form = HankRemoteSMBServiceProfileForm(publicConfigJSON: profile.publicConfigJSON)
            hankRemoteSharedSMBHost = form.host
            hankRemoteSharedSMBShare = form.share
            hankRemoteSharedSMBDomain = form.domain
            hankRemoteSharedSMBUsername = form.username
        } else {
            hankRemoteSharedSMBHost = ""
            hankRemoteSharedSMBShare = ""
            hankRemoteSharedSMBDomain = ""
            hankRemoteSharedSMBUsername = ""
        }
    }

    private func applyStorageConfigForm(_ config: HankRemoteStorageConfig) {
        hankRemoteStorageBackupTargetType = config.targetType
        hankRemoteStorageBackupTargetPath = config.targetPath
        hankRemoteStorageFullSchedule = config.fullSchedule
        hankRemoteStorageDifferentialSchedule = config.differentialSchedule
        hankRemoteStorageChecksumIntervalSeconds = config.checksumIntervalSeconds
        hankRemoteStorageRestoreVerificationSchedule = config.restoreVerificationSchedule
        hankRemoteStorageRetainedFullBackupCount = config.retainedFullBackupCount
    }

    private func applyNotificationSettings(_ settings: HankRemoteNotificationSettings) {
        hankRemoteNotificationSettings = settings
        hankRemoteStorageNotificationsEnabled = settings.storage
        hankRemoteNotesNotificationsEnabled = settings.notes
        hankRemoteDashboardEntityNotificationsEnabled = settings.dashboardEntities
    }

    private func decodedPublicConfig(from rawJSON: String) -> [String: Any] {
        guard
            let data = rawJSON.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return object
    }

    private func stringValue(for key: String, in object: [String: Any]) -> String {
        (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func intValue(for key: String, in object: [String: Any]) -> Int? {
        if let value = object[key] as? Int {
            return value
        }
        if let value = object[key] as? NSNumber {
            return value.intValue
        }
        return nil
    }

    private func makeNonEmptySecrets(_ values: [String: String]) -> [String: Any] {
        values.reduce(into: [String: Any]()) { partialResult, entry in
            let trimmed = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                partialResult[entry.key] = trimmed
            }
        }
    }

    private func updateServiceProfile(_ profile: HankRemoteServiceProfile) {
        if let index = hankRemoteServiceProfiles.firstIndex(where: { $0.serviceType == profile.serviceType }) {
            hankRemoteServiceProfiles[index] = profile
        } else {
            hankRemoteServiceProfiles.append(profile)
            hankRemoteServiceProfiles.sort { $0.serviceType.rawValue < $1.serviceType.rawValue }
        }
        hankRemoteServiceProfilesFeatureAvailable = true
        applyServiceProfileForms()
    }

    private func persistSMBConfiguration(profileID: UUID, modelContext: ModelContext, services: AppServices) throws {
        let existingConnections = try services.savedSMBConnections(for: profileID, in: modelContext)
        let existingConnection = selectedSMBConnectionID.flatMap { connectionID in
            existingConnections.first { $0.id == connectionID }
        }

        let connection = existingConnection ?? {
            let newConnection = SavedSMBConnection(profileID: profileID)
            modelContext.insert(newConnection)
            return newConnection
        }()

        let shouldBeDefault: Bool
        if smbIsDefault || existingConnections.isEmpty {
            shouldBeDefault = true
        } else if let existingConnection {
            shouldBeDefault = existingConnection.isDefault
        } else {
            shouldBeDefault = false
        }

        connection.apply(details: smb, displayName: smbDisplayName, isDefault: shouldBeDefault)
        try modelContext.save()

        if shouldBeDefault {
            try services.setDefaultSMBConnection(connection.id, for: profileID, in: modelContext)
        } else if existingConnection?.isDefault == true,
                  let replacement = existingConnections.first(where: { $0.id != connection.id })
        {
            try services.setDefaultSMBConnection(replacement.id, for: profileID, in: modelContext)
        }

        try services.setSMBPassword(smbPassword, for: connection.id, profileID: profileID)
        try loadSMBConnections(
            profileID: profileID,
            modelContext: modelContext,
            services: services,
            preferredConnectionID: connection.id
        )
        notesResolvedPath = try services.notesService.configurationSnapshot(
            profileID: profileID,
            modelContext: modelContext,
            services: services
        ).resolvedPath
        pushProfileSnapshot(profileID: profileID, modelContext: modelContext, services: services)
    }

    private func pushProfileSnapshot(profileID: UUID, modelContext: ModelContext, services: AppServices) {
        Task { @MainActor in
            try? await services.profileSyncCoordinator.pushExplicitProfileSnapshot(
                profileID: profileID,
                modelContext: modelContext,
                services: services
            )
        }
    }

    private func loadSMBConnections(
        profileID: UUID,
        modelContext: ModelContext,
        services: AppServices,
        preferredConnectionID: UUID? = nil
    ) throws {
        let connections = try services.savedSMBConnections(for: profileID, in: modelContext)
        smbConnections = connections.map(\.summary)

        guard !connections.isEmpty else {
            selectedSMBConnectionID = nil
            smbDisplayName = ""
            smb = SMBConnectionDetails()
            smbPassword = ""
            smbIsDefault = false
            return
        }

        let selectedConnection = connections.first { $0.id == preferredConnectionID }
            ?? connections.first { $0.id == selectedSMBConnectionID }
            ?? connections.first { $0.isDefault }
            ?? connections.first

        guard let selectedConnection else {
            return
        }

        selectedSMBConnectionID = selectedConnection.id
        smbDisplayName = selectedConnection.effectiveDisplayName
        smb = selectedConnection.connectionDetails
        smbPassword = try services.smbPassword(for: selectedConnection.id, profileID: profileID) ?? ""
        smbIsDefault = selectedConnection.isDefault
    }

    private func normalizeHankRemoteCloudURL(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard
            let components = URLComponents(string: candidate),
            let scheme = components.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            components.host?.isEmpty == false
        else {
            throw HankRemoteServiceError.invalidURL
        }

        return components.string ?? candidate
    }

    private func persistHankRemote(modelContext: ModelContext, services: AppServices) throws {
        hankRemote.cloudURL = try normalizeHankRemoteCloudURL(hankRemote.cloudURL)
        hankRemote.homeID = ""
        try services.saveHankRemoteSettings(hankRemote, in: modelContext)

        let trimmedToken = hankRemoteAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedToken.isEmpty {
            try services.clearHankRemoteAccessToken()
        } else {
            try services.setHankRemoteAccessToken(trimmedToken)
        }
    }

    private func applyHankRemoteSession(
        _ session: HankRemoteSessionSummary,
        modelContext: ModelContext,
        services: AppServices
    ) throws {
        hankRemote.cloudURL = try normalizeHankRemoteCloudURL(hankRemote.cloudURL)
        hankRemoteAccessToken = session.sessionToken
        hankRemoteSession = session
        hankRemoteEmail = session.user.email
        hankRemotePassword = ""
        try persistHankRemote(modelContext: modelContext, services: services)
    }

    private func makeHankRemoteContext() throws -> HankRemoteConnectionContext? {
        hankRemote.cloudURL = try normalizeHankRemoteCloudURL(hankRemote.cloudURL)
        let token = hankRemoteAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hankRemote.trimmedCloudURL.isEmpty, !token.isEmpty else {
            return nil
        }

        return HankRemoteConnectionContext(
            cloudURL: hankRemote.trimmedCloudURL,
            sessionToken: token
        )
    }

    private func resetHankRemoteCloudState(keepCredentials: Bool) {
        hankRemoteSession = nil
        hankRemoteHome = nil
        hankRemotePingResult = nil
        clearHankRemoteHomeFeatures()
        hankRemoteLastIssuedToken = nil

        if !keepCredentials {
            hankRemoteEmail = ""
            hankRemotePassword = ""
            hankRemoteInvitationEmail = ""
            hankRemoteJoinToken = ""
            hankRemoteAgentID = ""
            hankRemoteAgentName = ""
        }
    }

    private func refreshHankRemoteAgentDefaults() {
        guard let home = hankRemoteHome else {
            return
        }

        let defaultID = Self.defaultAgentID(for: home.name)
        let defaultName = Self.defaultAgentName(for: home.name)

        if hankRemoteAgentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            hankRemoteAgentID = defaultID
        }
        if hankRemoteAgentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            hankRemoteAgentName = defaultName
        }
    }

    private static func defaultAgentID(for homeName: String) -> String {
        let slug = homeName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "home-agent" : slug
    }

    private static func defaultAgentName(for homeName: String) -> String {
        let trimmed = homeName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Home Agent" : "\(trimmed) Agent"
    }

    private static func uniquedFirst<Value, Key: Hashable>(
        _ values: [Value],
        key: (Value) -> Key
    ) -> [Value] {
        var seenKeys: Set<Key> = []
        var uniqued: [Value] = []
        uniqued.reserveCapacity(values.count)

        for value in values {
            let valueKey = key(value)
            if seenKeys.insert(valueKey).inserted {
                uniqued.append(value)
            }
        }

        return uniqued
    }

    private static let remoteDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}
