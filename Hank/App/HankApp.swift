import SwiftData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

private struct SMBSharedServiceKey: Hashable {
    let connectionID: UUID?
    let host: String
    let shareName: String
    let username: String
    let domain: String
    let port: Int
    let remoteSourceID: String

    init(connection: ResolvedSMBConnection) {
        connectionID = connection.connectionID
        host = connection.details.trimmedHost
        shareName = connection.details.shareName.trimmingCharacters(in: .whitespacesAndNewlines)
        username = connection.details.trimmedUsername
        domain = connection.details.trimmedDomain
        port = connection.details.port
        remoteSourceID = connection.details.normalizedRemoteSourceID
    }
}

private actor SMBSharedServiceRegistry {
    private var services: [SMBSharedServiceKey: SMBServicing] = [:]

    func service(
        for key: SMBSharedServiceKey,
        override: SMBServicing?,
        factory: @Sendable () -> SMBServicing
    ) -> SMBServicing {
        if let override {
            return override
        }
        if let existing = services[key] {
            return existing
        }

        let service = factory()
        services[key] = service
        return service
    }

    func disconnectAll() async {
        let currentServices = Array(services.values)
        services.removeAll()
        for service in currentServices {
            await service.disconnect()
        }
    }
}

final class AppServices: ObservableObject {
    static let legacyHomeAssistantTokenKey = "home-assistant-token"
    static let legacySMBPasswordKey = "smb-password"
    static let hankRemoteAccessTokenKey = "hank-remote-access-token"

    let authService: LocalProfileAuthService
    let keychain: KeychainStoring
    let certificateTrustStore: CertificateTrustStore
    let hankRemoteService: HankRemoteService
    let homeAssistantService: HomeAssistantService
    let backupService: ProfileBackupService
    let profileMirrorService: ProfileMirrorService
    let migrationService: AppMigrationService
    let notesService: ProfileNotesService
    let localFileService: LocalFileService
    let notificationService: HankNotificationService
    let profileSyncCoordinator: ProfileSyncCoordinator
    private let smbServiceFactory: @Sendable (HankRemoteService) -> SMBServicing
    private let sharedSMBServiceOverride: SMBServicing?
    private let sharedSMBServiceRegistry = SMBSharedServiceRegistry()

    init(
        authService: LocalProfileAuthService = LocalProfileAuthService(),
        keychain: KeychainStoring? = nil,
        smbService: SMBServicing? = nil,
        smbServiceFactory: @escaping @Sendable (HankRemoteService) -> SMBServicing = {
            SMBFileService(hankRemoteService: $0)
        },
        backupService: ProfileBackupService = ProfileBackupService(),
        profileMirrorService: ProfileMirrorService? = nil,
        notesService: ProfileNotesService = ProfileNotesService(),
        localFileService: LocalFileService = LocalFileService(),
        notificationService: HankNotificationService = .shared
    ) {
        let keychain = keychain ?? KeychainService()
        let certificateTrustStore = CertificateTrustStore(keychain: keychain)

        self.authService = authService
        self.keychain = keychain
        self.certificateTrustStore = certificateTrustStore
        self.hankRemoteService = HankRemoteService()
        self.smbServiceFactory = smbServiceFactory
        self.sharedSMBServiceOverride = smbService
        self.homeAssistantService = HomeAssistantService(hankRemoteService: self.hankRemoteService)
        self.backupService = backupService
        self.profileMirrorService = profileMirrorService ?? ProfileMirrorService()
        self.migrationService = AppMigrationService(keychain: keychain, certificateTrustStore: certificateTrustStore)
        self.notesService = notesService
        self.localFileService = localFileService
        self.notificationService = notificationService
        self.profileSyncCoordinator = ProfileSyncCoordinator()
    }

    convenience init() {
        self.init(
            authService: LocalProfileAuthService(),
            keychain: nil,
            smbService: nil,
            smbServiceFactory: {
                SMBFileService(hankRemoteService: $0)
            },
            backupService: ProfileBackupService(),
            profileMirrorService: ProfileMirrorService(),
            notesService: ProfileNotesService(),
            localFileService: LocalFileService(),
            notificationService: .shared
        )
    }

    func homeAssistantTokenKey(for profileID: UUID) -> String {
        "profile:\(profileID.uuidString.lowercased()):home-assistant-token"
    }

    private func legacySMBPasswordKey(for profileID: UUID) -> String {
        "profile:\(profileID.uuidString.lowercased()):smb-password"
    }

    func smbPasswordKey(for connectionID: UUID, profileID: UUID) -> String {
        "profile:\(profileID.uuidString.lowercased()):smb-connection:\(connectionID.uuidString.lowercased()):password"
    }

    func notesMasterKeyKey(for profileID: UUID) -> String {
        "profile:\(profileID.uuidString.lowercased()):notes-master-key"
    }

    func profileSecretVaultKeyKey(for profileID: UUID) -> String {
        "profile:\(profileID.uuidString.lowercased()):profile-secret-vault-key"
    }

    func durableBackupBookmarkKey(for profileID: UUID) -> String {
        "profile:\(profileID.uuidString.lowercased()):durable-backup-bookmark"
    }

    func hankRemoteAccessToken() throws -> String? {
        try readKeychainString(for: Self.hankRemoteAccessTokenKey)
    }

    func setHankRemoteAccessToken(_ value: String) throws {
        try keychain.set(value.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.hankRemoteAccessTokenKey)
    }

    func clearHankRemoteAccessToken() throws {
        try keychain.deleteValue(for: Self.hankRemoteAccessTokenKey)
    }

    func homeAssistantToken(for profileID: UUID) throws -> String? {
        try readKeychainString(for: homeAssistantTokenKey(for: profileID))
    }

    func setHomeAssistantToken(_ value: String, for profileID: UUID) throws {
        try keychain.set(value.trimmingCharacters(in: .whitespacesAndNewlines), for: homeAssistantTokenKey(for: profileID))
    }

    func clearHomeAssistantToken(for profileID: UUID) throws {
        try keychain.deleteValue(for: homeAssistantTokenKey(for: profileID))
    }

    private func legacySMBPassword(for profileID: UUID) throws -> String? {
        try readKeychainString(for: legacySMBPasswordKey(for: profileID))
    }

    private func setLegacySMBPassword(_ value: String, for profileID: UUID) throws {
        try keychain.set(value, for: legacySMBPasswordKey(for: profileID))
    }

    private func clearLegacySMBPassword(for profileID: UUID) throws {
        try keychain.deleteValue(for: legacySMBPasswordKey(for: profileID))
    }

    func smbPassword(for connectionID: UUID, profileID: UUID) throws -> String? {
        let key = smbPasswordKey(for: connectionID, profileID: profileID)
        if let password = try readKeychainString(for: key) {
            return password
        }

        if let legacyPassword = try legacySMBPassword(for: profileID), !legacyPassword.isEmpty {
            try keychain.set(legacyPassword, for: key)
            try clearLegacySMBPassword(for: profileID)
            return legacyPassword
        }

        return nil
    }

    func smbPassword(for resolvedConnection: ResolvedSMBConnection, profileID: UUID) throws -> String? {
        guard let connectionID = resolvedConnection.connectionID else {
            return try legacySMBPassword(for: profileID)
        }
        return try smbPassword(for: connectionID, profileID: profileID)
    }

    func setSMBPassword(_ value: String, for connectionID: UUID, profileID: UUID) throws {
        try keychain.set(value, for: smbPasswordKey(for: connectionID, profileID: profileID))
    }

    func clearSMBPassword(for connectionID: UUID, profileID: UUID) throws {
        try keychain.deleteValue(for: smbPasswordKey(for: connectionID, profileID: profileID))
    }

    func clearAllSMBPasswords(for profileID: UUID) throws {
        try keychain.deleteValues(
            matchingPrefix: "profile:\(profileID.uuidString.lowercased()):smb-connection:"
        )
        try clearLegacySMBPassword(for: profileID)
    }

    func notesMasterKey(for profileID: UUID) throws -> String? {
        try readKeychainString(for: notesMasterKeyKey(for: profileID))
    }

    func setNotesMasterKey(_ value: String, for profileID: UUID) throws {
        try keychain.set(value, for: notesMasterKeyKey(for: profileID))
    }

    func clearNotesMasterKey(for profileID: UUID) throws {
        try keychain.deleteValue(for: notesMasterKeyKey(for: profileID))
    }

    func profileSecretVaultKey(for profileID: UUID) throws -> String? {
        try readKeychainString(for: profileSecretVaultKeyKey(for: profileID))
    }

    func setProfileSecretVaultKey(_ value: String, for profileID: UUID) throws {
        try keychain.set(value, for: profileSecretVaultKeyKey(for: profileID))
    }

    func clearProfileSecretVaultKey(for profileID: UUID) throws {
        try keychain.deleteValue(for: profileSecretVaultKeyKey(for: profileID))
    }

    func durableBackupBookmarkData(for profileID: UUID) throws -> Data? {
        guard let encoded = try readKeychainString(for: durableBackupBookmarkKey(for: profileID)),
              let data = Data(base64Encoded: encoded) else {
            return nil
        }
        return data
    }

    func setDurableBackupBookmarkData(_ data: Data, for profileID: UUID) throws {
        try keychain.set(data.base64EncodedString(), for: durableBackupBookmarkKey(for: profileID))
    }

    func clearDurableBackupBookmarkData(for profileID: UUID) throws {
        try keychain.deleteValue(for: durableBackupBookmarkKey(for: profileID))
    }

    func deleteSecrets(for profileID: UUID) throws {
        try clearHomeAssistantToken(for: profileID)
        try clearAllSMBPasswords(for: profileID)
        try clearNotesMasterKey(for: profileID)
        try clearProfileSecretVaultKey(for: profileID)
        try clearDurableBackupBookmarkData(for: profileID)
        try certificateTrustStore.revokeAll(profileID: profileID)
    }

    @MainActor
    func savedSMBConnections(
        for profileID: UUID,
        in modelContext: ModelContext
    ) throws -> [SavedSMBConnection] {
        try migrateLegacySMBConfigurationIfNeeded(for: profileID, in: modelContext)
        return try normalizeDefaultSMBConnections(for: profileID, in: modelContext)
    }

    @MainActor
    func savedSMBConnection(
        id: UUID,
        for profileID: UUID,
        in modelContext: ModelContext
    ) throws -> SavedSMBConnection? {
        try savedSMBConnections(for: profileID, in: modelContext).first { $0.id == id }
    }

    @MainActor
    func defaultSMBConnection(
        for profileID: UUID,
        in modelContext: ModelContext
    ) throws -> SavedSMBConnection? {
        try savedSMBConnections(for: profileID, in: modelContext).first { $0.isDefault }
    }

    @MainActor
    func setDefaultSMBConnection(
        _ connectionID: UUID,
        for profileID: UUID,
        in modelContext: ModelContext
    ) throws {
        let connections = try savedSMBConnections(for: profileID, in: modelContext)
        guard connections.contains(where: { $0.id == connectionID }) else {
            return
        }

        for connection in connections {
            connection.isDefault = connection.id == connectionID
            connection.updatedAt = .now
        }
        try modelContext.save()
    }

    @MainActor
    func sharedSMBService(for connection: ResolvedSMBConnection) async -> SMBServicing {
        await sharedSMBServiceRegistry.service(
            for: SMBSharedServiceKey(connection: connection),
            override: sharedSMBServiceOverride
        ) { [hankRemoteService, smbServiceFactory] in
            smbServiceFactory(hankRemoteService)
        }
    }

    @MainActor
    func disconnectAllSharedSMBServices() async {
        await sharedSMBServiceRegistry.disconnectAll()
    }

    func hankRemoteSettingsSnapshot(in modelContext: ModelContext) throws -> HankRemoteSettingsSnapshot {
        try HankRemoteSettings.fetch(in: modelContext)?.snapshot ?? HankRemoteSettingsSnapshot()
    }

    func saveHankRemoteSettings(_ snapshot: HankRemoteSettingsSnapshot, in modelContext: ModelContext) throws {
        let settings = try HankRemoteSettings.fetch(in: modelContext) ?? {
            let settings = HankRemoteSettings()
            modelContext.insert(settings)
            return settings
        }()
        settings.apply(snapshot)
        try modelContext.save()
    }

    func resolvedHomeAssistantEndpoint(
        for profileID: UUID,
        in modelContext: ModelContext
    ) throws -> ResolvedHomeAssistantEndpoint? {
        guard let remoteAccess = try hankRemoteConnectionContext(in: modelContext) else {
            return nil
        }

        return ResolvedHomeAssistantEndpoint(remoteAccess: remoteAccess)
    }

    @MainActor
    func resolvedSMBConnection(
        for profileID: UUID,
        preferredConnectionID: UUID? = nil,
        in modelContext: ModelContext
    ) throws -> ResolvedSMBConnection? {
        guard let remoteAccess = try hankRemoteConnectionContext(in: modelContext) else {
            return nil
        }

        let cachedConnection = try cachedSMBConnection(
            for: profileID,
            preferredConnectionID: preferredConnectionID,
            in: modelContext
        )

        let details = cachedConnection?.connectionDetails ??
            SMBConnectionDetails(
                host: "hank-remote",
                shareName: "Hank Remote",
                username: "",
                port: 445,
                startPath: ""
            )
        return ResolvedSMBConnection(
            connectionID: cachedConnection?.id,
            details: details,
            remoteAccess: remoteAccess
        )
    }

    @MainActor
    func preferredHomeAssistantEndpoint(
        for profileID: UUID,
        in modelContext: ModelContext
    ) async throws -> ResolvedHomeAssistantEndpoint? {
        try resolvedHomeAssistantEndpoint(for: profileID, in: modelContext)
    }

    @MainActor
    func preferredSMBConnection(
        for profileID: UUID,
        preferredConnectionID: UUID? = nil,
        in modelContext: ModelContext
    ) async throws -> ResolvedSMBConnection? {
        try resolvedSMBConnection(
            for: profileID,
            preferredConnectionID: preferredConnectionID,
            in: modelContext
        )
    }

    func hankRemoteConnectionContext(in modelContext: ModelContext) throws -> HankRemoteConnectionContext? {
        let settings = try hankRemoteSettingsSnapshot(in: modelContext)
        guard settings.isEnabled else {
            return nil
        }

        let trimmedCloudURL = settings.trimmedCloudURL
        guard
            !trimmedCloudURL.isEmpty,
            let normalizedCloudURL = HankRemoteService.normalizedCloudURL(from: trimmedCloudURL)
        else {
            return nil
        }

        guard
            let token = try hankRemoteAccessToken()?.trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty
        else {
            return nil
        }

        return HankRemoteConnectionContext(
            cloudURL: normalizedCloudURL,
            sessionToken: token
        )
    }

    @MainActor
    private func cachedSMBConnection(
        for profileID: UUID,
        preferredConnectionID: UUID?,
        in modelContext: ModelContext
    ) throws -> SavedSMBConnection? {
        let connections = try savedSMBConnections(for: profileID, in: modelContext)
        if let preferredConnectionID {
            return connections.first { $0.id == preferredConnectionID } ?? connections.first { $0.isDefault } ?? connections.first
        }
        return connections.first { $0.isDefault } ?? connections.first
    }

    @MainActor
    private func migrateLegacySMBConfigurationIfNeeded(
        for profileID: UUID,
        in modelContext: ModelContext
    ) throws {
        let existingConnections = try SavedSMBConnection.fetchAll(for: profileID, in: modelContext)
        guard existingConnections.isEmpty else {
            return
        }

        guard let legacyConfig = try SMBConnectionConfig.fetch(for: profileID, in: modelContext) else {
            return
        }

        let connection = SavedSMBConnection(profileID: profileID, isDefault: true)
        connection.apply(
            details: legacyConfig.connectionDetails,
            displayName: legacyConfig.shareName,
            isDefault: true
        )
        modelContext.insert(connection)
        if let legacyPassword = try legacySMBPassword(for: profileID), !legacyPassword.isEmpty {
            try setSMBPassword(legacyPassword, for: connection.id, profileID: profileID)
            try clearLegacySMBPassword(for: profileID)
        }
        modelContext.delete(legacyConfig)
        try modelContext.save()
    }

    @MainActor
    private func normalizeDefaultSMBConnections(
        for profileID: UUID,
        in modelContext: ModelContext
    ) throws -> [SavedSMBConnection] {
        let connections = try SavedSMBConnection.fetchAll(for: profileID, in: modelContext)
        guard !connections.isEmpty else {
            return []
        }

        let defaultConnections = connections.filter(\.isDefault)
        guard defaultConnections.count != 1 else {
            return connections
        }

        let selectedDefaultID = defaultConnections.first?.id ?? connections.first?.id
        for connection in connections {
            connection.isDefault = connection.id == selectedDefaultID
        }
        try modelContext.save()
        return try SavedSMBConnection.fetchAll(for: profileID, in: modelContext)
    }

    private func readKeychainString(for key: String) throws -> String? {
        try keychain.softString(for: key)
    }
}

@MainActor
struct ProfileLoadKey: Hashable {
    let profileID: UUID?
    let revision: Int
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var session: UserSession?
    @Published private(set) var profiles: [UserProfile] = []
    @Published var selectedProfileID: UUID?
    @Published var errorMessage: String?
    @Published private(set) var isBootstrapped = false
    @Published private(set) var profileDataRevision = 0
    @Published private(set) var pendingIncomingImportURL: URL?

    private let authService: AuthServicing
    private let services: AppServices
    private let modelContext: ModelContext

    var isAuthenticated: Bool {
        session != nil
    }

    var activeProfileID: UUID? {
        session?.profileID
    }

    var profileLoadKey: ProfileLoadKey {
        ProfileLoadKey(profileID: activeProfileID, revision: profileDataRevision)
    }

    var activeProfile: UserProfile? {
        guard let activeProfileID else {
            return nil
        }
        return profiles.first(where: { $0.id == activeProfileID })
    }

    init(authService: AuthServicing, services: AppServices, modelContainer: ModelContainer) {
        self.authService = authService
        self.services = services
        self.modelContext = ModelContext(modelContainer)
    }

    func bootstrap() {
        guard !isBootstrapped else {
            return
        }

        do {
            try services.migrationService.migrateIfNeeded(context: modelContext, services: services)
            try reloadProfiles()
            session = try authService.resumeRememberedSession(in: modelContext)
            if session == nil {
                selectedProfileID = profiles.first?.id
            } else if let activeProfileID {
                Task { @MainActor in
                    await services.profileSyncCoordinator.bootstrap(
                        profileID: activeProfileID,
                        modelContext: modelContext,
                        services: services
                    )
                    await registerRemoteNotificationsIfPossible()
                }
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }

        isBootstrapped = true
    }

    func reloadProfiles() throws {
        profiles = try UserProfile.fetchAll(in: modelContext)
        var didNormalizeProfileNames = false
        for profile in profiles {
            let normalizedRemoteEmail = profile.remoteEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if profile.remoteEmail != normalizedRemoteEmail {
                profile.remoteEmail = normalizedRemoteEmail
                profile.updatedAt = .now
                didNormalizeProfileNames = true
            }

            let desiredDisplayName: String
            switch profile.authMode {
            case .local:
                desiredDisplayName = profile.username
            case .hankRemote:
                desiredDisplayName = normalizedRemoteEmail?.isEmpty == false ? normalizedRemoteEmail! : profile.username
            }

            if profile.displayName != desiredDisplayName {
                profile.displayName = desiredDisplayName
                profile.updatedAt = .now
                didNormalizeProfileNames = true
            }
        }
        if didNormalizeProfileNames {
            try modelContext.save()
            profiles = try UserProfile.fetchAll(in: modelContext)
        }
        if let selectedProfileID, profiles.contains(where: { $0.id == selectedProfileID }) {
            return
        }
        selectedProfileID = profiles.first?.id
    }

    func selectProfile(_ profileID: UUID) {
        selectedProfileID = profileID
        errorMessage = nil
    }

    func createProfile(username: String, password: String, rememberSession: Bool) {
        do {
            session = try authService.createProfile(
                username: username,
                password: password,
                rememberSession: rememberSession,
                in: modelContext
            )
            try reloadProfiles()
            selectedProfileID = session?.profileID
            errorMessage = nil
            profileDataRevision += 1
            scheduleActiveProfileMirrorWrite()
            Task { @MainActor in
                await registerRemoteNotificationsIfPossible()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func login(profileID: UUID, password: String, rememberSession: Bool) {
        do {
            session = try authService.login(
                profileID: profileID,
                password: password,
                rememberSession: rememberSession,
                in: modelContext
            )
            try reloadProfiles()
            selectedProfileID = session?.profileID
            errorMessage = nil
            profileDataRevision += 1
            scheduleActiveProfileMirrorWrite()
            Task { @MainActor in
                await registerRemoteNotificationsIfPossible()
            }
        } catch {
            errorMessage = error.localizedDescription
            session = nil
        }
    }

    @MainActor
    func signInToHankRemote(
        cloudURL: String,
        email: String,
        password: String,
        rememberSession: Bool,
        createAccount: Bool = false
    ) async {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let normalizedCloudURL = HankRemoteService.normalizedCloudURL(from: cloudURL) else {
            errorMessage = HankRemoteServiceError.invalidURL.localizedDescription
            return
        }
        guard !normalizedEmail.isEmpty else {
            errorMessage = "Enter your Hank Remote email address."
            return
        }
        guard !trimmedPassword.isEmpty else {
            errorMessage = "Enter your Hank Remote password."
            return
        }

        do {
            let remoteSession: HankRemoteSessionSummary
            if createAccount {
                remoteSession = try await services.hankRemoteService.register(
                    cloudURL: normalizedCloudURL,
                    email: normalizedEmail,
                    password: trimmedPassword
                )
            } else {
                remoteSession = try await services.hankRemoteService.login(
                    cloudURL: normalizedCloudURL,
                    email: normalizedEmail,
                    password: trimmedPassword
                )
            }

            let remoteContext = HankRemoteConnectionContext(
                cloudURL: normalizedCloudURL,
                sessionToken: remoteSession.sessionToken
            )
            _ = try await services.hankRemoteService.currentSession(remoteContext)
            do {
                _ = try await services.hankRemoteService.currentHome(remoteContext)
            } catch HankRemoteServiceError.notFound {
                throw HankRemoteServiceError.server("This Hank Remote account is not linked to a Home yet.")
            }

            try services.saveHankRemoteSettings(
                HankRemoteSettingsSnapshot(
                    isEnabled: true,
                    cloudURL: normalizedCloudURL,
                    homeID: ""
                ),
                in: modelContext
            )
            try services.setHankRemoteAccessToken(remoteSession.sessionToken)

            session = try authService.provisionHankRemoteProfile(
                user: remoteSession.user,
                rememberSession: rememberSession,
                in: modelContext
            )
            try reloadProfiles()
            selectedProfileID = session?.profileID
            errorMessage = nil
            profileDataRevision += 1
            scheduleActiveProfileMirrorWrite()
            await services.notificationService.requestAuthorizationAndRegister(
                context: remoteContext,
                services: services
            )
        } catch {
            errorMessage = error.localizedDescription
            session = nil
        }
    }

    func logout() {
        do {
            let remoteContext = try services.hankRemoteConnectionContext(in: modelContext)
            try authService.logout(profileID: session?.profileID, in: modelContext)
            session = nil
            try reloadProfiles()
            errorMessage = nil
            if let remoteContext {
                Task { @MainActor in
                    await services.notificationService.unregisterAPNSDevice(
                        context: remoteContext,
                        services: services
                    )
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func switchProfile() {
        session = nil
        errorMessage = nil
        do {
            try authService.logout(profileID: nil, in: modelContext)
            try reloadProfiles()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeProfile(_ profileID: UUID) {
        do {
            if let homeAssistant = try HomeAssistantConfig.fetch(for: profileID, in: modelContext) {
                modelContext.delete(homeAssistant)
            }
            if let smb = try SMBConnectionConfig.fetch(for: profileID, in: modelContext) {
                modelContext.delete(smb)
            }
            if let notesConfig = try NotesConfig.fetch(for: profileID, in: modelContext) {
                modelContext.delete(notesConfig)
            }
            for calendarSource in try SavedCalendarSource.fetchAll(for: profileID, in: modelContext) {
                modelContext.delete(calendarSource)
            }
            for shortcut in try DashboardShortcut.fetchOrdered(for: profileID, in: modelContext) {
                modelContext.delete(shortcut)
            }
            try services.deleteSecrets(for: profileID)
            try services.notesService.deleteLocalNotes(profileID: profileID)
            try authService.removeProfile(id: profileID, in: modelContext)
            if session?.profileID == profileID {
                session = nil
            }
            try reloadProfiles()
            profileDataRevision += 1
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func didRestoreProfile(_ profileID: UUID?) {
        do {
            try reloadProfiles()
            if let profileID {
                selectedProfileID = profileID
                Task { @MainActor in
                    try? await services.profileSyncCoordinator.pushExplicitProfileSnapshot(
                        profileID: profileID,
                        modelContext: modelContext,
                        services: services
                    )
                }
            }
            profileDataRevision += 1
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func markProfileDataChanged() {
        profileDataRevision += 1
        scheduleActiveProfileMirrorWrite()
    }

    func queueIncomingImportURL(_ url: URL) {
        pendingIncomingImportURL = url
    }

    func consumePendingIncomingImportURL() -> URL? {
        defer { pendingIncomingImportURL = nil }
        return pendingIncomingImportURL
    }

    private func scheduleActiveProfileMirrorWrite() {
        guard let activeProfileID else {
            return
        }
        Task { @MainActor in
            try? await services.profileSyncCoordinator.pushExplicitProfileSnapshot(
                profileID: activeProfileID,
                modelContext: modelContext,
                services: services
            )
        }
    }

    private func registerRemoteNotificationsIfPossible() async {
        guard HankNotificationService.isEnabled else {
            return
        }
        guard let remoteContext = try? services.hankRemoteConnectionContext(in: modelContext) else {
            return
        }
        await services.notificationService.requestAuthorizationAndRegister(
            context: remoteContext,
            services: services
        )
    }
}

enum HankTheme {
    static let background = Color(red: 0.03, green: 0.05, blue: 0.09)
    static let backgroundTop = Color(red: 0.12, green: 0.20, blue: 0.32)
    static let backgroundBottom = Color(red: 0.04, green: 0.09, blue: 0.18)
    static let chrome = Color.white.opacity(0.08)
    static let surface = Color.white.opacity(0.09)
    static let elevatedSurface = Color.white.opacity(0.15)
    static let stroke = Color.white.opacity(0.14)
    static let accent = Color(red: 0.42, green: 0.74, blue: 1.0)
    static let accentGlow = Color(red: 0.52, green: 0.80, blue: 1.0)
    static let success = Color(red: 0.39, green: 0.86, blue: 0.61)
    static let successSurface = success.opacity(0.16)
    static let error = Color(red: 1.0, green: 0.46, blue: 0.46)
    static let errorSurface = error.opacity(0.16)
    static let folder = Color(red: 1.0, green: 0.78, blue: 0.29)
    static let file = Color(red: 0.47, green: 0.67, blue: 1.0)
    static let shadow = Color.black.opacity(0.28)
}

enum HankMetrics {
    static let rowSpacing: CGFloat = 8
    static let rowPadding: CGFloat = 10
    static let sectionSpacing: CGFloat = 12
    static let iconSize: CGFloat = 32
    static let cornerRadius: CGFloat = 12
}

extension View {
    func hankScreenBackground() -> some View {
        background {
            ZStack {
                LinearGradient(
                    colors: [
                        HankTheme.backgroundTop.opacity(0.72),
                        HankTheme.background,
                        HankTheme.backgroundBottom.opacity(0.86)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                RadialGradient(
                    colors: [
                        HankTheme.accentGlow.opacity(0.32),
                        HankTheme.accentGlow.opacity(0.06),
                        .clear
                    ],
                    center: .topTrailing,
                    startRadius: 24,
                    endRadius: 340
                )
                .blendMode(.screen)

                RadialGradient(
                    colors: [
                        Color.white.opacity(0.12),
                        Color.white.opacity(0.03),
                        .clear
                    ],
                    center: .top,
                    startRadius: 12,
                    endRadius: 260
                )
                .blendMode(.screen)
            }
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    func hankCard(fill: Color = HankTheme.surface, padding: CGFloat = 16) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

        if #available(iOS 26, *) {
            self
                .padding(padding)
                .background(fill.opacity(0.34), in: shape)
                .overlay(
                    shape.stroke(HankTheme.stroke, lineWidth: 1)
                )
                .glassEffect(.regular.tint(fill.opacity(0.18)), in: shape)
                .shadow(color: HankTheme.shadow, radius: 18, y: 10)
        } else {
            self
                .padding(padding)
                .background(
                    shape.fill(fill)
                )
                .overlay(
                    shape.stroke(HankTheme.stroke, lineWidth: 1)
                )
        }
    }

    @ViewBuilder
    func hankGlassCapsule(tint: Color = HankTheme.accent.opacity(0.18), interactive: Bool = false) -> some View {
        if #available(iOS 26, *) {
            self
                .background(tint.opacity(0.16), in: Capsule())
                .glassEffect(
                    interactive ? .regular.tint(tint).interactive() : .regular.tint(tint),
                    in: Capsule()
                )
                .overlay(
                    Capsule()
                        .stroke(HankTheme.stroke, lineWidth: 1)
                )
                .shadow(color: HankTheme.shadow, radius: 12, y: 6)
        } else {
            self
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(HankTheme.stroke, lineWidth: 1)
                )
        }
    }

    @ViewBuilder
    func hankSwipeBackEnabled() -> some View {
#if canImport(UIKit)
        background(HankInteractivePopGestureEnabler())
#else
        self
#endif
    }

    @ViewBuilder
    func hankNavigationChrome() -> some View {
        if #available(iOS 26, *) {
            self
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .hankSwipeBackEnabled()
        } else {
            self
                .toolbarBackground(HankTheme.chrome, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .hankSwipeBackEnabled()
        }
    }

    @ViewBuilder
    func hankTabChrome() -> some View {
        if #available(iOS 26, *) {
            self
                .toolbarBackground(.hidden, for: .tabBar)
                .toolbarColorScheme(.dark, for: .tabBar)
        } else {
            self
                .toolbarBackground(HankTheme.chrome, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
                .toolbarColorScheme(.dark, for: .tabBar)
        }
    }
}

#if canImport(UIKit)
private struct HankInteractivePopGestureEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> HankInteractivePopGestureController {
        HankInteractivePopGestureController()
    }

    func updateUIViewController(_ uiViewController: HankInteractivePopGestureController, context: Context) {
        uiViewController.enableInteractivePopGestureIfPossible()
    }
}

private final class HankInteractivePopGestureController: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        enableInteractivePopGestureIfPossible()
    }

    func enableInteractivePopGestureIfPossible() {
        DispatchQueue.main.async { [weak self] in
            guard let navigationController = self?.nearestNavigationController() else {
                return
            }

            navigationController.interactivePopGestureRecognizer?.delegate = nil
            navigationController.interactivePopGestureRecognizer?.isEnabled = navigationController.viewControllers.count > 1
        }
    }

    private func nearestNavigationController() -> UINavigationController? {
        if let navigationController {
            return navigationController
        }

        var ancestor = parent
        while let current = ancestor {
            if let navigationController = current.navigationController {
                return navigationController
            }
            ancestor = current.parent
        }

        return nil
    }
}
#endif

struct ModelContainerBootstrapResult {
    let container: ModelContainer
    let startupErrorMessage: String?
}

@main
struct HankApp: App {
    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(HankAppDelegate.self) private var appDelegate
    #endif
    @StateObject private var services: AppServices
    @StateObject private var appState: AppState
    @State private var isShowingLaunchOverlay = true
    #if DEBUG
    @State private var hasRunDemoAutoconnect = false
    #endif
    private let sharedModelContainer: ModelContainer
    private let startupErrorMessage: String?

    init() {
        let services = AppServices()
        let bootstrapResult = Self.makeModelContainer()
        _services = StateObject(wrappedValue: services)
        _appState = StateObject(wrappedValue: AppState(authService: services.authService, services: services, modelContainer: bootstrapResult.container))
        services.notificationService.configure(services: services)
        sharedModelContainer = bootstrapResult.container
        startupErrorMessage = bootstrapResult.startupErrorMessage
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if appState.isBootstrapped {
                    if let startupErrorMessage {
                        ContentUnavailableView(
                            "Hank Couldn’t Open Its Data Store",
                            systemImage: "externaldrive.badge.exclamationmark",
                            description: Text(startupErrorMessage)
                        )
                    } else if appState.isAuthenticated {
                        RootTabView()
                    } else {
                        LoginView()
                    }
                } else {
                    ProgressView("Starting Hank…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .environmentObject(services)
            .environmentObject(appState)
            .tint(HankTheme.accent)
            .preferredColorScheme(.dark)
            .hankScreenBackground()
            .task {
                appState.bootstrap()
            }
            #if DEBUG
            .task {
                await runDemoAutoconnectIfRequested()
            }
            #endif
            .onOpenURL { url in
                guard url.scheme == "hank" else {
                    return
                }
                if url.host == "notifications" {
                    services.notificationService.queueDeepLink(url)
                } else if url.host == "import" {
                    appState.queueIncomingImportURL(url)
                }
            }
            .overlay {
                if isShowingLaunchOverlay {
                    AnimatedLaunchOverlay {
                        withAnimation(.easeOut(duration: 0.2)) {
                            isShowingLaunchOverlay = false
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
        .modelContainer(sharedModelContainer)
    }

    #if DEBUG
    @MainActor
    private func runDemoAutoconnectIfRequested() async {
        guard !hasRunDemoAutoconnect else {
            return
        }
        let environment = ProcessInfo.processInfo.environment
        guard environment["HANK_DEMO_AUTOCONNECT"] == "1" else {
            return
        }
        guard
            let cloudURL = environment["HANK_DEMO_CLOUD_URL"],
            let email = environment["HANK_DEMO_EMAIL"],
            let password = environment["HANK_DEMO_PASSWORD"]
        else {
            return
        }

        hasRunDemoAutoconnect = true
        while !appState.isBootstrapped {
            try? await Task.sleep(for: .milliseconds(100))
        }

        await appState.signInToHankRemote(
            cloudURL: cloudURL,
            email: email,
            password: password,
            rememberSession: true
        )
    }
    #endif

    static func makeModelContainer() -> ModelContainerBootstrapResult {
        makeModelContainer(
            schema: applicationSchema(),
            storeURLProvider: {
                try AppFileLocations.persistentStoreURL()
            },
            recoverStore: recoverPersistentStore
        )
    }

    static func makeModelContainer(
        schema: Schema,
        storeURLProvider: () throws -> URL,
        recoverStore: (URL) throws -> Void
    ) -> ModelContainerBootstrapResult {
        do {
            let storeURL = try storeURLProvider()

            do {
                let configuration = ModelConfiguration(
                    url: storeURL,
                    cloudKitDatabase: .none
                )
                return ModelContainerBootstrapResult(
                    container: try ModelContainer(for: schema, configurations: [configuration]),
                    startupErrorMessage: nil
                )
            } catch {
                print("SwiftData persistent container failed to load. Attempting store recovery: \(error.localizedDescription)")
                try recoverStore(storeURL)

                let recoveredConfiguration = ModelConfiguration(
                    url: storeURL,
                    cloudKitDatabase: .none
                )
                return ModelContainerBootstrapResult(
                    container: try ModelContainer(for: schema, configurations: [recoveredConfiguration]),
                    startupErrorMessage: nil
                )
            }
        } catch {
            print("SwiftData persistent recovery failed. Starting in blocked recovery mode: \(error.localizedDescription)")
            do {
                let fallbackContainer = try ModelContainer(
                    for: schema,
                    configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
                )
                return ModelContainerBootstrapResult(
                    container: fallbackContainer,
                    startupErrorMessage: error.localizedDescription
                )
            } catch {
                fatalError("Failed to initialize any SwiftData container: \(error.localizedDescription)")
            }
        }
    }

    private static func applicationSchema() -> Schema {
        Schema([
            UserProfile.self,
            HomeAssistantConfig.self,
            SMBConnectionConfig.self,
            SavedSMBConnection.self,
            HankRemoteSettings.self,
            TailscaleSettings.self,
            NotesConfig.self,
            SavedCalendarSource.self,
            DashboardShortcut.self
        ])
    }

    private static func recoverPersistentStore(at storeURL: URL) throws {
        let fileManager = FileManager.default
        let backupsDirectory = storeURL.deletingLastPathComponent()
            .appendingPathComponent("RecoveredStores", isDirectory: true)
        try fileManager.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let recoveryDirectory = backupsDirectory.appendingPathComponent(
            "recovery-\(formatter.string(from: .now))",
            isDirectory: true
        )
        try fileManager.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)

        for candidateURL in persistentStoreSidecars(for: storeURL) where fileManager.fileExists(atPath: candidateURL.path) {
            try fileManager.moveItem(
                at: candidateURL,
                to: recoveryDirectory.appendingPathComponent(candidateURL.lastPathComponent)
            )
        }
    }

    private static func persistentStoreSidecars(for storeURL: URL) -> [URL] {
        [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-shm"),
            URL(fileURLWithPath: storeURL.path + "-wal")
        ]
    }
}

private struct AnimatedLaunchOverlay: View {
    let onFinish: () -> Void

    @State private var progress: CGFloat = 0
    @State private var hasStarted = false

    private let duration: Double = 0.95

    var body: some View {
        ZStack {
            HankTheme.background
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Text("Hank")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)

                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(HankTheme.elevatedSurface)
                        .frame(width: 226, height: 9)

                    Rectangle()
                        .fill(HankTheme.accent)
                        .frame(width: 226 * progress, height: 9)
                }
            }
        }
        .task {
            guard !hasStarted else {
                return
            }

            hasStarted = true

            withAnimation(.easeInOut(duration: duration)) {
                progress = 1
            }

            try? await Task.sleep(for: .seconds(duration))
            onFinish()
        }
    }
}
