import CryptoKit
import Foundation
import SwiftData
import os
import Security

@MainActor
protocol AuthServicing: AnyObject {
    var isAuthenticated: Bool { get }
    func createProfile(
        username: String,
        password: String,
        rememberSession: Bool,
        in context: ModelContext
    ) throws -> UserSession
    func login(profileID: UUID, password: String, rememberSession: Bool, in context: ModelContext) throws -> UserSession
    func provisionHankRemoteProfile(
        user: HankRemoteUser,
        rememberSession: Bool,
        in context: ModelContext
    ) throws -> UserSession
    func verifyPassword(profileID: UUID, password: String, in context: ModelContext) throws
    func resumeRememberedSession(in context: ModelContext) throws -> UserSession?
    func logout(profileID: UUID?, in context: ModelContext) throws
    func removeProfile(id: UUID, in context: ModelContext) throws
}

protocol HomeAssistantServicing: AnyObject {
    func validateConnection(
        context: HankRemoteConnectionContext
    ) async throws -> String?
    func fetchEntityCatalog(
        context: HankRemoteConnectionContext
    ) async throws -> [HAEntitySummary]
    func fetchStates(
        context: HankRemoteConnectionContext
    ) async throws -> [HAEntityState]
    func subscribeToStateChanges(
        context: HankRemoteConnectionContext
    ) -> AsyncThrowingStream<HAEntityState, Error>
    func performAction(
        for entity: HAEntitySummary,
        state: HAEntityState?,
        context: HankRemoteConnectionContext
    ) async throws
    func setBrightness(
        for entity: HAEntitySummary,
        brightnessPercent: Int,
        context: HankRemoteConnectionContext
    ) async throws
}

protocol SMBServicing: AnyObject, Sendable {
    func connect(
        config: SMBConnectionDetails,
        password: String,
        context: HankRemoteConnectionContext
    ) async throws
    func list(path: String) async throws -> [SMBItem]
    func download(path: String) async throws -> Data
    func download(path: String, to localURL: URL) async throws
    func createDirectory(path: String) async throws
    func upload(data: Data, path: String) async throws
    func upload(fileAt localURL: URL, path: String) async throws
    func move(from: String, to: String, isDirectory: Bool) async throws
    func delete(path: String, isDirectory: Bool) async throws
    func disconnect() async
}

protocol KeychainStoring: AnyObject {
    func set(_ value: String, for key: String) throws
    func string(for key: String) throws -> String?
    func deleteValue(for key: String) throws
    func entries(matchingPrefix prefix: String) throws -> [String: String]
    func deleteValues(matchingPrefix prefix: String) throws
}

extension KeychainStoring {
    func softString(for key: String) throws -> String? {
        do {
            return try string(for: key)
        } catch let error as KeychainError where error.isSoftReadFailure {
            return nil
        }
    }

    func softEntries(matchingPrefix prefix: String) throws -> [String: String] {
        do {
            return try entries(matchingPrefix: prefix)
        } catch let error as KeychainError where error.isSoftReadFailure {
            return [:]
        }
    }
}

enum ProfileRestoreTarget: Equatable {
    case newProfile
    case overwrite(profileID: UUID)
}

enum AuthError: LocalizedError {
    case invalidCredentials
    case duplicateUsername
    case invalidUsername
    case invalidPassword
    case profileNotFound

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Invalid credentials."
        case .duplicateUsername:
            return "That username is already in use."
        case .invalidUsername:
            return "Enter a username."
        case .invalidPassword:
            return "Enter a password with at least 6 characters."
        case .profileNotFound:
            return "That profile could not be found."
        }
    }
}

enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain operation failed with status \(status)."
        case .invalidData:
            return "Stored keychain data could not be decoded."
        }
    }

    var isSoftReadFailure: Bool {
        switch self {
        case .unexpectedStatus(let status):
            return status == errSecMissingEntitlement
                || status == errSecNotAvailable
                || status == errSecInteractionNotAllowed
        case .invalidData:
            return false
        }
    }
}

enum HomeAssistantServiceError: LocalizedError, Equatable {
    case invalidURL
    case invalidResponse
    case invalidToken
    case unreachableHost
    case unsupportedLocalCertificate(host: String)
    case untrustedCertificate(host: String, fingerprint: String)
    case certificateMismatch(host: String, expected: String, received: String)
    case websocketClosed
    case api(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Enter a valid Home Assistant URL."
        case .invalidResponse:
            return "Home Assistant returned an invalid response."
        case .invalidToken:
            return "The Home Assistant token was rejected."
        case .unreachableHost:
            return "Home Assistant could not be reached."
        case .unsupportedLocalCertificate(let host):
            return "The certificate for \(host) is not trusted and self-signed trust is only allowed for local hosts."
        case .untrustedCertificate(let host, _):
            return "The certificate for \(host) is self-signed or untrusted. Review and trust it explicitly to continue."
        case .certificateMismatch(let host, _, _):
            return "The trusted certificate fingerprint for \(host) changed. Refuse the connection until it is trusted again."
        case .websocketClosed:
            return "The Home Assistant WebSocket connection closed unexpectedly."
        case .api(let message):
            return message
        }
    }
}

enum SMBServiceError: LocalizedError {
    case incompleteConfiguration
    case notConnected
    case invalidPort(Int)

    var errorDescription: String? {
        switch self {
        case .incompleteConfiguration:
            return "Complete the SMB connection details before testing or browsing."
        case .notConnected:
            return "The SMB share is not connected."
        case .invalidPort(let port):
            return "SMB port \(port) is invalid. Enter a value between 1 and 65535."
        }
    }
}

private struct SMBConnectionStageError: LocalizedError {
    enum Stage {
        case login
        case shareConnect(String)
    }

    let stage: Stage
    let underlying: Error

    var errorDescription: String? {
        switch stage {
        case .login:
            return "SMB login failed: \(underlying.localizedDescription)."
        case .shareConnect(let shareName):
            return "SMB login succeeded, but Hank could not connect to share \"\(shareName)\": \(underlying.localizedDescription)."
        }
    }
}

enum HankRemoteServiceError: LocalizedError, Equatable {
    case invalidURL
    case invalidHomeID
    case invalidResponse
    case notFound
    case unauthorized
    case unreachableHost
    case notConfigured
    case websocketClosed
    case conflict(HankRemoteNotesFetchResponse?)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Enter a valid Hank Remote cloud URL."
        case .invalidHomeID:
            return "Enter a home ID before enabling Hank Remote."
        case .invalidResponse:
            return "Hank Remote returned an invalid response."
        case .notFound:
            return "That Hank Remote resource could not be found."
        case .unauthorized:
            return "The Hank Remote session token was rejected."
        case .unreachableHost:
            return "The Hank Remote cloud service could not be reached."
        case .notConfigured:
            return "Sign in to Hank Remote before using the relay."
        case .websocketClosed:
            return "The Hank Remote command relay closed unexpectedly."
        case .conflict:
            return "This note was updated elsewhere. Reload it before saving again."
        case .server(let message):
            return message
        }
    }
}

enum ProfileBackupError: LocalizedError {
    case invalidSchemaVersion(Int)
    case invalidPayload
    case smbNotConfigured
    case overwriteAuthorizationRequired

    var errorDescription: String? {
        switch self {
        case .invalidSchemaVersion(let version):
            return "Unsupported backup schema version \(version)."
        case .invalidPayload:
            return "The selected backup file is invalid."
        case .smbNotConfigured:
            return "Configure the profile's SMB share before exporting a backup there."
        case .overwriteAuthorizationRequired:
            return "Enter the current profile password to overwrite this profile."
        }
    }
}

enum AppFileLocations {
    static func applicationSupportDirectory(fileManager: FileManager = .default) throws -> URL {
        let applicationSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        if !fileManager.fileExists(atPath: applicationSupportURL.path) {
            try fileManager.createDirectory(at: applicationSupportURL, withIntermediateDirectories: true)
        }

        return applicationSupportURL
    }

    static func persistentStoreURL(fileManager: FileManager = .default) throws -> URL {
        try applicationSupportDirectory(fileManager: fileManager).appendingPathComponent("default.store")
    }

    static func documentsDirectory(fileManager: FileManager = .default) throws -> URL {
        let documentsURL = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        if !fileManager.fileExists(atPath: documentsURL.path) {
            try fileManager.createDirectory(at: documentsURL, withIntermediateDirectories: true)
        }
        return documentsURL
    }

    static func profileMirrorRootDirectory(fileManager: FileManager = .default) throws -> URL {
        let directory = try documentsDirectory(fileManager: fileManager)
            .appendingPathComponent("Hank Profiles", isDirectory: true)
            .appendingPathComponent("Backup", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func profileMirrorDirectory(profileID: UUID, fileManager: FileManager = .default) throws -> URL {
        let directory = try profileMirrorRootDirectory(fileManager: fileManager)
            .appendingPathComponent(profileID.uuidString.lowercased(), isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

struct PasswordHasher {
    static func makeSalt() -> String {
        Data((0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) }).base64EncodedString()
    }

    static func hash(password: String, salt: String) -> String {
        let digest = SHA256.hash(data: Data((salt + password).utf8))
        return Data(digest).base64EncodedString()
    }
}

final class KeychainService: KeychainStoring {
    private let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? "com.dropfile.Hank") {
        self.service = service
    }

    func set(_ value: String, for key: String) throws {
        let encoded = Data(value.utf8)
        let query = baseQuery(for: key)

        let attributes: [String: Any] = [
            kSecValueData as String: encoded
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(updateStatus)
            }
            return
        }

        if status != errSecItemNotFound {
            throw KeychainError.unexpectedStatus(status)
        }

        var item = query
        item[kSecValueData as String] = encoded

        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    func string(for key: String) throws -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard
                let data = result as? Data,
                let string = String(data: data, encoding: .utf8)
            else {
                throw KeychainError.invalidData
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func deleteValue(for key: String) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func entries(matchingPrefix prefix: String) throws -> [String: String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return [:]
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }

        let items = result as? [[String: Any]] ?? []
        var values: [String: String] = [:]
        for item in items {
            guard
                let account = item[kSecAttrAccount as String] as? String,
                account.hasPrefix(prefix),
                let data = item[kSecValueData as String] as? Data,
                let value = String(data: data, encoding: .utf8)
            else {
                continue
            }

            values[account] = value
        }
        return values
    }

    func deleteValues(matchingPrefix prefix: String) throws {
        let keys = try entries(matchingPrefix: prefix).keys
        for key in keys {
            try deleteValue(for: key)
        }
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }
}

final class InMemoryKeychainStore: KeychainStoring {
    private var values: [String: String] = [:]

    func set(_ value: String, for key: String) throws {
        values[key] = value
    }

    func string(for key: String) throws -> String? {
        values[key]
    }

    func deleteValue(for key: String) throws {
        values.removeValue(forKey: key)
    }

    func entries(matchingPrefix prefix: String) throws -> [String: String] {
        values.filter { $0.key.hasPrefix(prefix) }
    }

    func deleteValues(matchingPrefix prefix: String) throws {
        values.keys.filter { $0.hasPrefix(prefix) }.forEach { values.removeValue(forKey: $0) }
    }
}

private struct CertificateTrustPayload: Codable {
    let fingerprint: String
    let acceptedAt: Date
}

final class CertificateTrustStore: @unchecked Sendable {
    private let keychain: KeychainStoring
    private let prefix = "home-assistant-certificate:"

    init(keychain: KeychainStoring) {
        self.keychain = keychain
    }

    func trust(host: String, fingerprint: String, profileID: UUID) throws {
        let payload = CertificateTrustPayload(fingerprint: fingerprint, acceptedAt: .now)
        let data = try JSONEncoder().encode(payload)
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        try keychain.set(value, for: key(for: host, profileID: profileID))
    }

    func trustedFingerprint(for host: String, profileID: UUID) throws -> String? {
        guard let value = try keychain.softString(for: key(for: host, profileID: profileID)) else {
            return nil
        }
        return try decodeValue(value).fingerprint
    }

    func revoke(host: String, profileID: UUID) throws {
        try keychain.deleteValue(for: key(for: host, profileID: profileID))
    }

    func revokeAll(profileID: UUID) throws {
        try keychain.deleteValues(matchingPrefix: scopedPrefix(for: profileID))
    }

    func records(for profileID: UUID) throws -> [CertificateTrustRecord] {
        try keychain.softEntries(matchingPrefix: scopedPrefix(for: profileID))
            .compactMap { account, value in
                let payload = try decodeValue(value)
                let host = String(account.dropFirst(scopedPrefix(for: profileID).count))
                return CertificateTrustRecord(host: host, fingerprint: payload.fingerprint, acceptedAt: payload.acceptedAt)
            }
            .sorted { $0.host < $1.host }
    }

    func replace(records: [CertificateTrustRecord], profileID: UUID) throws {
        try revokeAll(profileID: profileID)
        for record in records {
            let payload = CertificateTrustPayload(fingerprint: record.fingerprint, acceptedAt: record.acceptedAt)
            let data = try JSONEncoder().encode(payload)
            guard let value = String(data: data, encoding: .utf8) else {
                throw KeychainError.invalidData
            }
            try keychain.set(value, for: key(for: record.host, profileID: profileID))
        }
    }

    func legacyRecords() throws -> [CertificateTrustRecord] {
        let scopedPrefixes = try keychain.softEntries(matchingPrefix: prefix).keys
            .filter { $0.split(separator: ":").count > 2 }
        let entries = try keychain.softEntries(matchingPrefix: prefix)
            .filter { !scopedPrefixes.contains($0.key) }
        return try entries.compactMap { account, value in
            let payload = try decodeValue(value)
            let host = String(account.dropFirst(prefix.count))
            return CertificateTrustRecord(host: host, fingerprint: payload.fingerprint, acceptedAt: payload.acceptedAt)
        }
    }

    private func decodeValue(_ value: String) throws -> CertificateTrustPayload {
        if let data = value.data(using: .utf8),
           let payload = try? JSONDecoder().decode(CertificateTrustPayload.self, from: data) {
            return payload
        }

        return CertificateTrustPayload(fingerprint: value, acceptedAt: .now)
    }

    private func scopedPrefix(for profileID: UUID) -> String {
        "\(prefix)\(profileID.uuidString.lowercased()):"
    }

    private func key(for host: String, profileID: UUID) -> String {
        scopedPrefix(for: profileID) + host.lowercased()
    }
}

@MainActor
final class LocalProfileAuthService: AuthServicing {
    private(set) var currentSession: UserSession?

    var isAuthenticated: Bool {
        currentSession != nil
    }

    func createProfile(
        username: String,
        password: String,
        rememberSession: Bool,
        in context: ModelContext
    ) throws -> UserSession {
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedUsername.isEmpty else {
            throw AuthError.invalidUsername
        }
        guard password.count >= 6 else {
            throw AuthError.invalidPassword
        }
        guard try UserProfile.fetch(username: normalizedUsername, in: context) == nil else {
            throw AuthError.duplicateUsername
        }

        let salt = PasswordHasher.makeSalt()
        let profile = UserProfile(
            username: normalizedUsername,
            displayName: normalizedUsername,
            passwordHash: PasswordHasher.hash(password: password, salt: salt),
            passwordSalt: salt,
            lastUsedAt: .now,
            rememberedSession: rememberSession
        )
        context.insert(profile)
        try context.save()
        return try beginSession(for: profile, rememberSession: rememberSession, in: context)
    }

    func login(profileID: UUID, password: String, rememberSession: Bool, in context: ModelContext) throws -> UserSession {
        guard let profile = try UserProfile.fetch(id: profileID, in: context) else {
            throw AuthError.profileNotFound
        }

        try verifyPassword(profileID: profileID, password: password, in: context)

        return try beginSession(for: profile, rememberSession: rememberSession, in: context)
    }

    func provisionHankRemoteProfile(
        user: HankRemoteUser,
        rememberSession: Bool,
        in context: ModelContext
    ) throws -> UserSession {
        let normalizedEmail = user.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedEmail.isEmpty else {
            throw AuthError.invalidUsername
        }

        let profile = try UserProfile.fetch(remoteUserID: user.id, in: context)
            ?? UserProfile.fetch(remoteEmail: normalizedEmail, in: context)
            ?? {
                let syntheticPassword = UUID().uuidString + UUID().uuidString
                let salt = PasswordHasher.makeSalt()
                let profile = UserProfile(
                    username: try uniqueUsername(startingWith: normalizedEmail, in: context),
                    displayName: normalizedEmail,
                    passwordHash: PasswordHasher.hash(password: syntheticPassword, salt: salt),
                    passwordSalt: salt,
                    authModeRawValue: UserProfileAuthMode.hankRemote.rawValue,
                    remoteUserID: user.id,
                    remoteEmail: normalizedEmail,
                    lastUsedAt: .now,
                    rememberedSession: rememberSession
                )
                context.insert(profile)
                return profile
            }()

        profile.authMode = .hankRemote
        profile.remoteUserID = user.id
        profile.remoteEmail = normalizedEmail
        profile.displayName = normalizedEmail
        profile.updatedAt = .now

        return try beginSession(for: profile, rememberSession: rememberSession, in: context)
    }

    func verifyPassword(profileID: UUID, password: String, in context: ModelContext) throws {
        guard let profile = try UserProfile.fetch(id: profileID, in: context) else {
            throw AuthError.profileNotFound
        }

        let incomingHash = PasswordHasher.hash(password: password, salt: profile.passwordSalt)
        guard incomingHash == profile.passwordHash else {
            throw AuthError.invalidCredentials
        }
    }

    func resumeRememberedSession(in context: ModelContext) throws -> UserSession? {
        let remembered = try UserProfile.fetchRemembered(in: context)
        guard let profile = remembered.first else {
            currentSession = nil
            return nil
        }

        return try beginSession(for: profile, rememberSession: true, in: context)
    }

    func logout(profileID: UUID?, in context: ModelContext) throws {
        if let profileID, let profile = try UserProfile.fetch(id: profileID, in: context) {
            profile.rememberedSession = false
            profile.updatedAt = .now
            try context.save()
        }
        currentSession = nil
    }

    func removeProfile(id: UUID, in context: ModelContext) throws {
        guard let profile = try UserProfile.fetch(id: id, in: context) else {
            return
        }
        context.delete(profile)
        try context.save()
        if currentSession?.profileID == id {
            currentSession = nil
        }
    }

    private func beginSession(for profile: UserProfile, rememberSession: Bool, in context: ModelContext) throws -> UserSession {
        profile.rememberedSession = rememberSession
        profile.lastUsedAt = .now
        profile.updatedAt = .now
        try context.save()

        let session = UserSession(
            profileID: profile.id,
            username: profile.username,
            displayName: profile.displayName,
            loggedInAt: .now
        )
        currentSession = session
        return session
    }

    private func uniqueUsername(startingWith base: String, in context: ModelContext) throws -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let seed = trimmed.isEmpty ? "remote-user" : trimmed
        if try UserProfile.fetch(username: seed, in: context) == nil {
            return seed
        }

        var counter = 2
        while true {
            let candidate = "\(seed)-\(counter)"
            if try UserProfile.fetch(username: candidate, in: context) == nil {
                return candidate
            }
            counter += 1
        }
    }
}

final class ProfileBackupService {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    @MainActor
    func makeSnapshot(profile: UserProfile, modelContext: ModelContext, services: AppServices) throws -> ProfileBackupSnapshot {
        let homeAssistantConfig = try HomeAssistantConfig.fetch(for: profile.id, in: modelContext)?.connectionConfiguration ?? HomeAssistantConnectionConfiguration()
        let savedSMBConnections = try services.savedSMBConnections(for: profile.id, in: modelContext)
        let defaultSMBConnection = savedSMBConnections.first(where: \.isDefault)
        let smbConfig = defaultSMBConnection?.connectionDetails ?? SMBConnectionDetails()
        let homeAssistantToken = try services.homeAssistantToken(for: profile.id) ?? ""
        let smbPassword: String
        if let connection = defaultSMBConnection {
            smbPassword = try services.smbPassword(for: connection.id, profileID: profile.id) ?? ""
        } else {
            smbPassword = ""
        }
        let trustedCertificates = try services.certificateTrustStore.records(for: profile.id)
        let shortcuts = try DashboardShortcut.fetchOrdered(for: profile.id, in: modelContext)
        let calendarSources = try SavedCalendarSource.fetchAll(for: profile.id, in: modelContext)
        let notes = try services.notesService.exportBackupPayload(profileID: profile.id, modelContext: modelContext, services: services)

        return ProfileBackupSnapshot(
            schemaVersion: ProfileBackupSnapshot.currentSchemaVersion,
            exportedAt: .now,
            profile: ProfileBackupProfile(
                username: profile.username,
                displayName: profile.displayName,
                passwordHash: profile.passwordHash,
                passwordSalt: profile.passwordSalt,
                authModeRawValue: profile.authMode.rawValue,
                remoteUserID: profile.remoteUserID,
                remoteEmail: profile.remoteEmail
            ),
            homeAssistant: ProfileBackupHomeAssistant(
                configuration: homeAssistantConfig,
                token: homeAssistantToken,
                trustedCertificates: trustedCertificates
            ),
            smb: ProfileBackupSMB(
                configuration: smbConfig,
                password: smbPassword
            ),
            savedSMBConnections: try savedSMBConnections.map { connection in
                ProfileBackupSavedSMBConnection(
                    id: connection.id,
                    displayName: connection.displayName,
                    configuration: connection.connectionDetails,
                    password: try services.smbPassword(for: connection.id, profileID: profile.id) ?? "",
                    isDefault: connection.isDefault
                )
            },
            savedCalendarSources: calendarSources.map {
                ProfileBackupSavedCalendarSource(
                    id: $0.id,
                    kindRawValue: $0.kindRawValue,
                    displayName: $0.displayName,
                    remoteIdentifier: $0.remoteIdentifier,
                    urlString: $0.urlString,
                    sourceTitle: $0.sourceTitle,
                    detailText: $0.detailText,
                    isEnabled: $0.isEnabled
                )
            },
            dashboardTiles: shortcuts.map {
                ProfileBackupDashboardTile(
                    entityID: $0.entityID,
                    labelOverride: $0.labelOverride,
                    tileSize: $0.tileSize,
                    isEnabled: $0.isEnabled,
                    gridRow: $0.gridRow,
                    gridColumn: $0.gridColumn
                )
            },
            notes: notes
        )
    }

    func loadSnapshot(from url: URL) throws -> ProfileBackupSnapshot {
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let data = try Data(contentsOf: url)
        return try decodeSnapshot(from: data)
    }

    func decodeSnapshot(from data: Data) throws -> ProfileBackupSnapshot {
        let snapshot = try decoder.decode(ProfileBackupSnapshot.self, from: data)
        guard [2, 3, ProfileBackupSnapshot.currentSchemaVersion].contains(snapshot.schemaVersion) else {
            throw ProfileBackupError.invalidSchemaVersion(snapshot.schemaVersion)
        }
        return snapshot
    }

    @MainActor
    func exportSnapshotData(profile: UserProfile, modelContext: ModelContext, services: AppServices) throws -> Data {
        let snapshot = try makeSnapshot(profile: profile, modelContext: modelContext, services: services)
        return try encoder.encode(snapshot)
    }

    @MainActor
    @discardableResult
    func restore(
        snapshot: ProfileBackupSnapshot,
        target: ProfileRestoreTarget,
        modelContext: ModelContext,
        services: AppServices
    ) throws -> UserProfile {
        try restore(
            snapshot: snapshot,
            target: target,
            authorizationPassword: nil,
            modelContext: modelContext,
            services: services
        )
    }

    @MainActor
    @discardableResult
    func restore(
        snapshot: ProfileBackupSnapshot,
        target: ProfileRestoreTarget,
        authorizationPassword: String? = nil,
        modelContext: ModelContext,
        services: AppServices
    ) throws -> UserProfile {
        guard [2, 3, ProfileBackupSnapshot.currentSchemaVersion].contains(snapshot.schemaVersion) else {
            throw ProfileBackupError.invalidSchemaVersion(snapshot.schemaVersion)
        }

        let profile: UserProfile
        switch target {
        case .newProfile:
            let username = try uniqueUsername(startingWith: snapshot.profile.username, in: modelContext)
            profile = UserProfile(
                username: username,
                displayName: snapshot.profile.displayName,
                passwordHash: snapshot.profile.passwordHash,
                passwordSalt: snapshot.profile.passwordSalt,
                authModeRawValue: snapshot.profile.authModeRawValue,
                remoteUserID: snapshot.profile.remoteUserID,
                remoteEmail: snapshot.profile.remoteEmail,
                lastUsedAt: .now
            )
            modelContext.insert(profile)
        case .overwrite(let profileID):
            guard let existing = try UserProfile.fetch(id: profileID, in: modelContext) else {
                throw AuthError.profileNotFound
            }
            let authorizationPassword = authorizationPassword?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !authorizationPassword.isEmpty else {
                throw ProfileBackupError.overwriteAuthorizationRequired
            }
            try services.authService.verifyPassword(
                profileID: profileID,
                password: authorizationPassword,
                in: modelContext
            )
            existing.displayName = snapshot.profile.displayName
            existing.passwordHash = snapshot.profile.passwordHash
            existing.passwordSalt = snapshot.profile.passwordSalt
            existing.authModeRawValue = snapshot.profile.authModeRawValue
            existing.remoteUserID = snapshot.profile.remoteUserID
            existing.remoteEmail = snapshot.profile.remoteEmail
            existing.updatedAt = .now
            profile = existing
        }

        let homeAssistant = try HomeAssistantConfig.fetch(for: profile.id, in: modelContext) ?? {
            let config = HomeAssistantConfig(profileID: profile.id)
            modelContext.insert(config)
            return config
        }()
        homeAssistant.apply(snapshot.homeAssistant.configuration)

        for connection in try SavedSMBConnection.fetchAll(for: profile.id, in: modelContext) {
            try? services.clearSMBPassword(for: connection.id, profileID: profile.id)
            modelContext.delete(connection)
        }
        let restoredConnections = makeRestoredSMBConnections(from: snapshot, profileID: profile.id)
        for connection in restoredConnections {
            modelContext.insert(connection.connection)
        }

        for source in try SavedCalendarSource.fetchAll(for: profile.id, in: modelContext) {
            modelContext.delete(source)
        }
        for source in snapshot.savedCalendarSources {
            let restoredSource = SavedCalendarSource(id: source.id, profileID: profile.id)
            restoredSource.kindRawValue = source.kindRawValue
            restoredSource.displayName = source.displayName
            restoredSource.remoteIdentifier = source.remoteIdentifier
            restoredSource.urlString = source.urlString
            restoredSource.sourceTitle = source.sourceTitle
            restoredSource.detailText = source.detailText
            restoredSource.isEnabled = source.isEnabled
            restoredSource.updatedAt = .now
            modelContext.insert(restoredSource)
        }

        let existingTiles = try DashboardShortcut.fetchOrdered(for: profile.id, in: modelContext)
        existingTiles.forEach(modelContext.delete)
        for (index, tile) in snapshot.dashboardTiles.enumerated() {
            modelContext.insert(
                DashboardShortcut(
                    profileID: profile.id,
                    entityID: tile.entityID,
                    labelOverride: tile.labelOverride,
                    tileSizeRawValue: tile.tileSize.rawValue,
                    sortOrder: index,
                    gridRow: tile.gridRow,
                    gridColumn: tile.gridColumn,
                    isEnabled: tile.isEnabled
                )
            )
        }

        try services.setHomeAssistantToken(snapshot.homeAssistant.token, for: profile.id)
        for restoredConnection in restoredConnections where restoredConnection.backup.hasPassword {
            try services.setSMBPassword(
                restoredConnection.backup.password,
                for: restoredConnection.connection.id,
                profileID: profile.id
            )
        }
        try services.certificateTrustStore.replace(records: snapshot.homeAssistant.trustedCertificates, profileID: profile.id)
        if let notes = snapshot.notes {
            do {
                try services.notesService.restoreBackupPayload(notes, profileID: profile.id, modelContext: modelContext, services: services)
            } catch NotesServiceError.serverRequired {
                // Legacy device-only restores can still recover non-note settings; notes now belong to Hank Remote.
            } catch {
                throw error
            }
        }
        try modelContext.save()
        return profile
    }

    @MainActor
    @discardableResult
    func restore(
        snapshot: ProfileBackupSnapshot,
        mode: ProfileBackupRestoreMode,
        authorizationPassword: String? = nil,
        modelContext: ModelContext,
        services: AppServices
    ) async throws -> UserProfile? {
        switch mode {
        case .full(let target):
            return try restore(
                snapshot: snapshot,
                target: target,
                authorizationPassword: authorizationPassword,
                modelContext: modelContext,
                services: services
            )
        case .importNotes(let profileID):
            try await services.notesService.importBackupPayload(
                snapshot.notes,
                into: profileID,
                modelContext: modelContext,
                services: services
            )
            return try UserProfile.fetch(id: profileID, in: modelContext)
        }
    }

    private func makeRestoredSMBConnections(
        from snapshot: ProfileBackupSnapshot,
        profileID: UUID
    ) -> [(backup: ProfileBackupSavedSMBConnection, connection: SavedSMBConnection)] {
        let backups: [ProfileBackupSavedSMBConnection]
        if snapshot.savedSMBConnections.isEmpty {
            backups = [
                ProfileBackupSavedSMBConnection(
                    id: UUID(),
                    displayName: snapshot.smb.configuration.shareName,
                    configuration: snapshot.smb.configuration,
                    password: snapshot.smb.password,
                    isDefault: true
                )
            ]
        } else {
            backups = snapshot.savedSMBConnections
        }

        let defaultID = backups.first(where: \.isDefault)?.id ?? backups.first?.id
        return backups.enumerated().map { index, backup in
            let connection = SavedSMBConnection(id: backup.id, profileID: profileID, isDefault: backup.id == defaultID)
            connection.apply(
                details: backup.configuration,
                displayName: backup.displayName,
                isDefault: backup.id == defaultID
            )
            connection.updatedAt = Date(timeIntervalSince1970: TimeInterval(index))
            return (backup, connection)
        }
    }

    private func uniqueUsername(startingWith base: String, in context: ModelContext) throws -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let seed = trimmed.isEmpty ? "restored" : trimmed
        if try UserProfile.fetch(username: seed, in: context) == nil {
            return seed
        }

        var counter = 2
        while true {
            let candidate = "\(seed)-\(counter)"
            if try UserProfile.fetch(username: candidate, in: context) == nil {
                return candidate
            }
            counter += 1
        }
    }
}

final class ProfileMirrorService {
    private struct DurableProfileMirrorAccess {
        let containerURL: URL
        let urls: (directory: URL, profile: URL, recovery: URL, metadata: URL)
        let stopAccess: () -> Void
    }

    private struct DurableProfileMirrorError: LocalizedError {
        let description: String

        var errorDescription: String? { description }
    }

    private struct LiveProfileSettingsPayload: Codable, Sendable {
        let schemaVersion: Int
        let exportedAt: Date
        let profile: LiveProfileSettingsProfile
        let homeAssistant: LiveProfileSettingsHomeAssistant
        let smb: LiveProfileSettingsSMB
        let savedCalendarSources: [ProfileBackupSavedCalendarSource]
        let dashboardTiles: [ProfileBackupDashboardTile]
        let notes: LiveProfileSettingsNotes?

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case exportedAt = "exported_at"
            case profile
            case homeAssistant = "home_assistant"
            case smb
            case savedCalendarSources = "calendar_sources"
            case dashboardTiles = "dashboard_tiles"
            case notes
        }

        init(
            schemaVersion: Int,
            exportedAt: Date,
            profile: LiveProfileSettingsProfile,
            homeAssistant: LiveProfileSettingsHomeAssistant,
            smb: LiveProfileSettingsSMB,
            savedCalendarSources: [ProfileBackupSavedCalendarSource],
            dashboardTiles: [ProfileBackupDashboardTile],
            notes: LiveProfileSettingsNotes?
        ) {
            self.schemaVersion = schemaVersion
            self.exportedAt = exportedAt
            self.profile = profile
            self.homeAssistant = homeAssistant
            self.smb = smb
            self.savedCalendarSources = savedCalendarSources
            self.dashboardTiles = dashboardTiles
            self.notes = notes
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            exportedAt = try container.decodeIfPresent(Date.self, forKey: .exportedAt) ?? .distantPast
            profile = try container.decodeIfPresent(LiveProfileSettingsProfile.self, forKey: .profile)
                ?? LiveProfileSettingsProfile(
                    username: "",
                    displayName: "",
                    authModeRawValue: UserProfileAuthMode.hankRemote.rawValue,
                    remoteUserID: nil,
                    remoteEmail: nil
                )
            homeAssistant = try container.decodeIfPresent(LiveProfileSettingsHomeAssistant.self, forKey: .homeAssistant)
                ?? LiveProfileSettingsHomeAssistant(
                    configuration: HomeAssistantConnectionConfiguration(),
                    trustedCertificates: []
                )
            smb = try container.decodeIfPresent(LiveProfileSettingsSMB.self, forKey: .smb)
                ?? LiveProfileSettingsSMB(configuration: SMBConnectionDetails(), savedConnections: [])
            savedCalendarSources = try container.decodeIfPresent([ProfileBackupSavedCalendarSource].self, forKey: .savedCalendarSources) ?? []
            dashboardTiles = try container.decodeIfPresent([ProfileBackupDashboardTile].self, forKey: .dashboardTiles) ?? []
            notes = try container.decodeIfPresent(LiveProfileSettingsNotes.self, forKey: .notes)
        }
    }

    private struct LiveProfileSettingsProfile: Codable, Sendable {
        let username: String
        let displayName: String
        let authModeRawValue: String
        let remoteUserID: String?
        let remoteEmail: String?

        enum CodingKeys: String, CodingKey {
            case username
            case displayName = "display_name"
            case authModeRawValue = "auth_mode"
            case remoteUserID = "remote_user_id"
            case remoteEmail = "remote_email"
        }
    }

    private struct LiveProfileSettingsHomeAssistant: Codable, Sendable {
        let configuration: HomeAssistantConnectionConfiguration
        let trustedCertificates: [CertificateTrustRecord]

        enum CodingKeys: String, CodingKey {
            case configuration
            case trustedCertificates = "trusted_certificates"
        }
    }

    private struct LiveProfileSettingsSMB: Codable, Sendable {
        let configuration: SMBConnectionDetails
        let savedConnections: [LiveProfileSettingsSavedSMBConnection]

        enum CodingKeys: String, CodingKey {
            case configuration
            case savedConnections = "saved_connections"
        }

        init(configuration: SMBConnectionDetails, savedConnections: [LiveProfileSettingsSavedSMBConnection]) {
            self.configuration = configuration
            self.savedConnections = savedConnections
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            configuration = try container.decodeIfPresent(SMBConnectionDetails.self, forKey: .configuration) ?? SMBConnectionDetails()
            savedConnections = try container.decodeIfPresent([LiveProfileSettingsSavedSMBConnection].self, forKey: .savedConnections) ?? []
        }
    }

    private struct LiveProfileSettingsSavedSMBConnection: Codable, Sendable {
        let id: UUID
        let displayName: String
        let configuration: SMBConnectionDetails
        let isDefault: Bool

        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
            case configuration
            case isDefault = "is_default"
        }
    }

    private struct ServiceProfileSMBPublicConfig: Decodable, Sendable {
        let activeSourceID: String
        let shares: [ServiceProfileSMBShare]
        let fileSources: [ServiceProfileSMBShare]
        let sources: [ServiceProfileSMBShare]
        let fallbackShare: ServiceProfileSMBShare?

        enum CodingKeys: String, CodingKey {
            case activeSourceID = "active_source_id"
            case shares
            case fileSources = "file_sources"
            case sources
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            activeSourceID = try container.decodeIfPresent(String.self, forKey: .activeSourceID) ?? ""
            shares = try container.decodeIfPresent([ServiceProfileSMBShare].self, forKey: .shares) ?? []
            fileSources = try container.decodeIfPresent([ServiceProfileSMBShare].self, forKey: .fileSources) ?? []
            sources = try container.decodeIfPresent([ServiceProfileSMBShare].self, forKey: .sources) ?? []
            fallbackShare = try? ServiceProfileSMBShare(from: decoder)
        }
    }

    private struct ServiceProfileSMBShare: Decodable, Sendable {
        let id: String
        let sourceID: String
        let name: String
        let type: String
        let host: String
        let share: String
        let domain: String
        let username: String

        enum CodingKeys: String, CodingKey {
            case id
            case sourceID = "source_id"
            case name
            case type
            case host
            case share
            case domain
            case username
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
            sourceID = try container.decodeIfPresent(String.self, forKey: .sourceID) ?? ""
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
            type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
            host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
            share = try container.decodeIfPresent(String.self, forKey: .share) ?? ""
            domain = try container.decodeIfPresent(String.self, forKey: .domain) ?? ""
            username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        }
    }

    private struct LiveProfileSettingsNotes: Codable, Sendable {
        let configuration: ProfileBackupNotesConfiguration
        let hasMasterKey: Bool

        enum CodingKeys: String, CodingKey {
            case configuration
            case hasMasterKey = "has_master_key"
        }
    }

    private struct ProfileSecretVaultPayload: Codable, Sendable {
        let schemaVersion: Int
        let exportedAt: Date
        let homeAssistantToken: String
        let smbPassword: String
        let savedSMBConnectionPasswords: [ProfileSecretVaultSMBPassword]
        let notesMasterKey: String
    }

    private struct ProfileSecretVaultSMBPassword: Codable, Sendable {
        let id: UUID
        let password: String
    }

    private struct EncryptedProfileSecretVault: Codable, Sendable {
        let schemaVersion: Int
        let algorithm: String
        let exportedAt: Date
        let ciphertext: String

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case algorithm
            case exportedAt = "exported_at"
            case ciphertext
        }
    }

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.dropfile.Hank", category: "ProfileMirror")

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func rootDirectory() throws -> URL {
        try AppFileLocations.profileMirrorRootDirectory(fileManager: fileManager)
    }

    func health(
        profileID: UUID,
        services: AppServices? = nil,
        resolveDurableAccess: Bool = false
    ) throws -> ProfileMirrorHealth {
        do {
            let urls = try mirrorURLs(profileID: profileID)
            let durableURLs = resolveDurableAccess
                ? (try? resolveDurableMirrorURLs(profileID: profileID, services: services))
                : nil
            durableURLs?.stopAccess()
            let metadata = try loadMetadata(profileID: profileID)
            return ProfileMirrorHealth(
                profileID: profileID,
                directoryURL: urls.directory,
                profileURL: urls.profile,
                durableDirectoryURL: durableURLs?.urls.directory,
                durableProfileURL: durableURLs?.urls.profile,
                metadata: metadata
            )
        } catch {
            let message = error.localizedDescription
            logger.error("ProfileMirror.health failed profileID=\(profileID.uuidString, privacy: .public) error=\(message, privacy: .public)")
            throw error
        }
    }

    @MainActor
    @discardableResult
    func configureDurableLocation(
        profileID: UUID,
        directoryURL: URL,
        modelContext: ModelContext,
        services: AppServices
    ) async throws -> ProfileMirrorHealth {
        guard !isInsideAppContainer(directoryURL) else {
            throw DurableProfileMirrorError(
                description: "Choose a folder outside Hank's local iPhone files so the backup can survive app removal."
            )
        }

        let bookmark = try directoryURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        try services.setDurableBackupBookmarkData(bookmark, for: profileID)
        let access = try resolveDurableAccess(profileID: profileID, services: services)
        access?.stopAccess()

        var metadata = try loadMetadata(profileID: profileID)
        metadata.durableLocationPath = directoryURL.path
        metadata.durableLastError = ""
        try storeMetadata(metadata, profileID: profileID)

        return try await writeMirror(
            profileID: profileID,
            modelContext: modelContext,
            services: services,
            pushRemote: true
        )
    }

    func clearDurableLocation(profileID: UUID, services: AppServices) throws {
        try services.clearDurableBackupBookmarkData(for: profileID)
        var metadata = try loadMetadata(profileID: profileID)
        metadata.durableLocationPath = ""
        metadata.durableLastError = ""
        metadata.lastDurableWriteAt = nil
        try storeMetadata(metadata, profileID: profileID)
    }

    @MainActor
    func pullRemoteSourceTruth(
        profileID: UUID,
        modelContext: ModelContext,
        services: AppServices,
        context: HankRemoteConnectionContext
    ) async throws {
        try await pullLiveProfileSettings(
            profileID: profileID,
            modelContext: modelContext,
            services: services,
            context: context
        )
    }

    @MainActor
    @discardableResult
    func writeMirror(
        profileID: UUID,
        modelContext: ModelContext,
        services: AppServices,
        pushRemote: Bool
    ) async throws -> ProfileMirrorHealth {
        guard let profile = try UserProfile.fetch(id: profileID, in: modelContext) else {
            throw AuthError.profileNotFound
        }

        let snapshot = try services.backupService.makeSnapshot(
            profile: profile,
            modelContext: modelContext,
            services: services
        )
        let data = try encoder.encode(snapshot)
        _ = try services.backupService.decodeSnapshot(from: data)

        let checksum = Self.checksum(for: data)
        let urls = try mirrorURLs(profileID: profileID)
        try rotateLastKnownGood(profileURL: urls.profile, recoveryURL: urls.recovery)
        try replaceFile(contents: data, at: urls.profile)

        var metadata = try loadMetadata(profileID: profileID)
        metadata.checksum = checksum
        metadata.lastLocalWriteAt = .now
        metadata.lastValidatedAt = .now
        metadata.lastError = ""
        metadata.syncState = .synced
        metadata.lastRecoverySource = .canonical

        if pushRemote, let context = try services.hankRemoteConnectionContext(in: modelContext) {
            metadata = try await pushRemoteSnapshot(
                snapshot,
                metadata: metadata,
                profileID: profileID,
                context: context,
                services: services,
                hankRemoteService: services.hankRemoteService
            )
        }

        metadata = try syncDurableMirror(
            profileID: profileID,
            data: data,
            metadata: metadata,
            services: services
        )

        try storeMetadata(metadata, profileID: profileID)
        let durableAccess = try resolveDurableMirrorURLs(profileID: profileID, services: services)
        defer { durableAccess?.stopAccess() }

        return ProfileMirrorHealth(
            profileID: profileID,
            directoryURL: urls.directory,
            profileURL: urls.profile,
            durableDirectoryURL: durableAccess?.urls.directory,
            durableProfileURL: durableAccess?.urls.profile,
            metadata: metadata
        )
    }

    @MainActor
    private func pullLiveProfileSettings(
        profileID: UUID,
        modelContext: ModelContext,
        services: AppServices,
        context: HankRemoteConnectionContext
    ) async throws {
        let record: HankRemoteProfileSettingsRecord
        do {
            record = try await services.hankRemoteService.profileSettings(context)
        } catch HankRemoteServiceError.notFound {
            try await pullSMBServiceProfileSettings(profileID: profileID, modelContext: modelContext, services: services, context: context)
            return
        }

        let payload = try decodeLiveProfileSettings(record.settings)
        let appliedSMB = try applyLiveProfileSettings(payload, profileID: profileID, modelContext: modelContext, services: services)
        if !appliedSMB {
            try await pullSMBServiceProfileSettings(profileID: profileID, modelContext: modelContext, services: services, context: context)
        }
    }

    private func decodeLiveProfileSettings(_ settings: [String: AnyDecodable]) throws -> LiveProfileSettingsPayload {
        let object = settings.mapValues(\.value)
        guard JSONSerialization.isValidJSONObject(object) else {
            throw HankRemoteServiceError.invalidResponse
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try decoder.decode(LiveProfileSettingsPayload.self, from: data)
    }

    @MainActor
    @discardableResult
    private func applyLiveProfileSettings(
        _ payload: LiveProfileSettingsPayload,
        profileID: UUID,
        modelContext: ModelContext,
        services: AppServices
    ) throws -> Bool {
        try applyLiveProfileSMBSettings(payload.smb, profileID: profileID, modelContext: modelContext, services: services)
    }

    @MainActor
    @discardableResult
    private func applyLiveProfileSMBSettings(
        _ smb: LiveProfileSettingsSMB,
        profileID: UUID,
        modelContext: ModelContext,
        services: AppServices
    ) throws -> Bool {
        let incoming = liveSMBConnections(from: smb, profileID: profileID)
        guard !incoming.isEmpty else {
            return false
        }

        let incomingIDs = Set(incoming.map(\.id))
        let existingConnections = try SavedSMBConnection.fetchAll(for: profileID, in: modelContext)
        for connection in existingConnections where !incomingIDs.contains(connection.id) {
            modelContext.delete(connection)
        }

        let existingByID = Dictionary(uniqueKeysWithValues: existingConnections.map { ($0.id, $0) })
        for incomingConnection in incoming {
            let connection = existingByID[incomingConnection.id] ?? incomingConnection
            if existingByID[incomingConnection.id] == nil {
                modelContext.insert(connection)
            }
            connection.apply(
                details: incomingConnection.connectionDetails,
                displayName: incomingConnection.displayName,
                isDefault: incomingConnection.isDefault
            )
        }
        try modelContext.save()
        if let defaultConnection = incoming.first(where: \.isDefault) ?? incoming.first {
            try services.setDefaultSMBConnection(defaultConnection.id, for: profileID, in: modelContext)
        }
        return true
    }

    @MainActor
    private func pullSMBServiceProfileSettings(
        profileID: UUID,
        modelContext: ModelContext,
        services: AppServices,
        context: HankRemoteConnectionContext
    ) async throws {
        let profiles: [HankRemoteServiceProfile]
        do {
            profiles = try await services.hankRemoteService.listServiceProfiles(context: context)
        } catch HankRemoteServiceError.notFound {
            return
        }

        guard let profile = profiles.first(where: { $0.serviceType == .smb }) else {
            return
        }

        let incoming = try serviceProfileSMBConnections(from: profile, profileID: profileID)
        guard !incoming.isEmpty else {
            return
        }

        try applyServiceProfileSMBConnections(incoming, profileID: profileID, modelContext: modelContext, services: services)
    }

    private func serviceProfileSMBConnections(
        from profile: HankRemoteServiceProfile,
        profileID: UUID
    ) throws -> [SavedSMBConnection] {
        guard let data = profile.publicConfigJSON.data(using: .utf8), !data.isEmpty else {
            return []
        }

        let config = try decoder.decode(ServiceProfileSMBPublicConfig.self, from: data)
        var shares: [ServiceProfileSMBShare] = []
        shares.append(contentsOf: config.shares)
        shares.append(contentsOf: config.fileSources.filter { source in
            let type = source.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return type.isEmpty || type == "smb"
        })
        shares.append(contentsOf: config.sources.filter { source in
            let type = source.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return type.isEmpty || type == "smb"
        })
        if let fallbackShare = config.fallbackShare,
           isUsableServiceProfileShare(fallbackShare),
           shares.isEmpty {
            shares.append(fallbackShare)
        }

        var seenSourceIDs: Set<String> = []
        let activeSourceID = config.activeSourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let models = shares.compactMap { share -> SavedSMBConnection? in
            guard isUsableServiceProfileShare(share) else {
                return nil
            }
            let sourceID = normalizedServiceProfileSourceID(for: share)
            guard !sourceID.isEmpty, !seenSourceIDs.contains(sourceID) else {
                return nil
            }
            seenSourceIDs.insert(sourceID)

            let details = SMBConnectionDetails(
                host: share.host,
                shareName: share.share,
                username: share.username,
                domain: share.domain,
                port: 445,
                startPath: "",
                remoteSourceID: sourceID
            )
            let connection = SavedSMBConnection(
                id: deterministicSMBConnectionID(profileID: profileID, sourceID: sourceID),
                profileID: profileID
            )
            connection.apply(
                details: details,
                displayName: share.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? share.share : share.name,
                isDefault: sourceID == activeSourceID
            )
            return connection
        }

        return normalizeDefaultLiveSMBConnections(models)
    }

    @MainActor
    private func applyServiceProfileSMBConnections(
        _ incoming: [SavedSMBConnection],
        profileID: UUID,
        modelContext: ModelContext,
        services: AppServices
    ) throws {
        let incomingRemoteSourceIDs = Set(incoming.map(\.remoteSourceID).filter { !$0.isEmpty })
        let existingConnections = try SavedSMBConnection.fetchAll(for: profileID, in: modelContext)
        var existingByRemoteSourceID: [String: SavedSMBConnection] = [:]
        for connection in existingConnections {
            let sourceID = connection.remoteSourceID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sourceID.isEmpty, existingByRemoteSourceID[sourceID] == nil else {
                continue
            }
            existingByRemoteSourceID[sourceID] = connection
        }

        for connection in existingConnections {
            let sourceID = connection.remoteSourceID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sourceID.isEmpty, !incomingRemoteSourceIDs.contains(sourceID) {
                modelContext.delete(connection)
            }
        }

        for incomingConnection in incoming {
            let connection = existingByRemoteSourceID[incomingConnection.remoteSourceID] ?? incomingConnection
            if existingByRemoteSourceID[incomingConnection.remoteSourceID] == nil {
                modelContext.insert(connection)
            }
            connection.apply(
                details: incomingConnection.connectionDetails,
                displayName: incomingConnection.displayName,
                isDefault: incomingConnection.isDefault
            )
        }

        try modelContext.save()
        if let defaultConnection = incoming.first(where: \.isDefault) ?? incoming.first {
            let defaultID = existingByRemoteSourceID[defaultConnection.remoteSourceID]?.id ?? defaultConnection.id
            try services.setDefaultSMBConnection(defaultID, for: profileID, in: modelContext)
        }
    }

    private func liveSMBConnections(from smb: LiveProfileSettingsSMB, profileID: UUID) -> [SavedSMBConnection] {
        let saved = smb.savedConnections.map { connection in
            let model = SavedSMBConnection(id: connection.id, profileID: profileID)
            model.apply(
                details: connection.configuration,
                displayName: connection.displayName,
                isDefault: connection.isDefault
            )
            return model
        }

        if !saved.isEmpty {
            return normalizeDefaultLiveSMBConnections(saved)
        }

        guard isUsableSMBConfiguration(smb.configuration) else {
            return []
        }

        let connection = SavedSMBConnection(profileID: profileID, isDefault: true)
        connection.apply(
            details: smb.configuration,
            displayName: smb.configuration.shareName,
            isDefault: true
        )
        return [connection]
    }

    private func normalizeDefaultLiveSMBConnections(_ connections: [SavedSMBConnection]) -> [SavedSMBConnection] {
        guard !connections.isEmpty else {
            return []
        }
        if connections.contains(where: \.isDefault) {
            return connections
        }
        connections[0].isDefault = true
        return connections
    }

    private func isUsableSMBConfiguration(_ details: SMBConnectionDetails) -> Bool {
        !details.trimmedHost.isEmpty
            && !details.shareName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !details.trimmedUsername.isEmpty
    }

    private func isUsableServiceProfileShare(_ share: ServiceProfileSMBShare) -> Bool {
        !share.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !share.share.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !share.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func normalizedServiceProfileSourceID(for share: ServiceProfileSMBShare) -> String {
        let candidates = [
            share.sourceID,
            share.id,
            share.name,
            share.share
        ]

        return candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    private func deterministicSMBConnectionID(profileID: UUID, sourceID: String) -> UUID {
        let seed = "\(profileID.uuidString.lowercased()):\(sourceID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
        let digest = SHA256.hash(data: Data(seed.utf8))
        let bytes = Array(digest.prefix(16))
        let uuid = uuid_t(
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: uuid)
    }

    @MainActor
    private func pushRemoteSnapshot(
        _ snapshot: ProfileBackupSnapshot,
        metadata: ProfileMirrorMetadata,
        profileID: UUID,
        context: HankRemoteConnectionContext,
        services: AppServices,
        hankRemoteService: HankRemoteService
    ) async throws -> ProfileMirrorMetadata {
        var workingMetadata = metadata
        do {
            let response = try await hankRemoteService.saveProfileBackup(
                snapshot,
                expectedRevision: workingMetadata.remoteRevision,
                context: context
            )
            try await pushLiveProfileRecords(
                snapshot,
                profileID: profileID,
                context: context,
                services: services,
                hankRemoteService: hankRemoteService
            )
            workingMetadata.remoteRevision = response.revision
            workingMetadata.lastRemotePushAt = .now
            workingMetadata.lastError = ""
            workingMetadata.syncState = .synced
            return workingMetadata
        } catch HankRemoteServiceError.conflict {
            let latest = try await hankRemoteService.profileBackup(context)
            let response = try await hankRemoteService.saveProfileBackup(
                snapshot,
                expectedRevision: latest?.revision,
                context: context
            )
            try await pushLiveProfileRecords(
                snapshot,
                profileID: profileID,
                context: context,
                services: services,
                hankRemoteService: hankRemoteService
            )
            workingMetadata.remoteRevision = response.revision
            workingMetadata.lastRemotePullAt = .now
            workingMetadata.lastRemotePushAt = .now
            workingMetadata.lastError = ""
            workingMetadata.syncState = .synced
            return workingMetadata
        }
    }

    @MainActor
    private func pushLiveProfileRecords(
        _ snapshot: ProfileBackupSnapshot,
        profileID: UUID,
        context: HankRemoteConnectionContext,
        services: AppServices,
        hankRemoteService: HankRemoteService
    ) async throws {
        let settings = makeLiveProfileSettings(from: snapshot)
        do {
            _ = try await hankRemoteService.saveProfileSettings(
                settings: settings,
                expectedRevision: nil,
                context: context
            )
        } catch HankRemoteServiceError.conflict {
            let latest = try await hankRemoteService.profileSettings(context)
            _ = try await hankRemoteService.saveProfileSettings(
                settings: settings,
                expectedRevision: latest.revision,
                context: context
            )
        }

        let encryptedVault = try makeEncryptedSecretVault(from: snapshot, profileID: profileID, services: services)
        do {
            _ = try await hankRemoteService.saveProfileSecretVault(
                keyID: encryptedVault.keyID,
                vault: encryptedVault.vault,
                expectedRevision: nil,
                context: context
            )
        } catch HankRemoteServiceError.conflict {
            let latest = try await hankRemoteService.profileSecretVault(context)
            _ = try await hankRemoteService.saveProfileSecretVault(
                keyID: encryptedVault.keyID,
                vault: encryptedVault.vault,
                expectedRevision: latest.revision,
                context: context
            )
        }
    }

    private func makeLiveProfileSettings(from snapshot: ProfileBackupSnapshot) -> LiveProfileSettingsPayload {
        LiveProfileSettingsPayload(
            schemaVersion: 1,
            exportedAt: snapshot.exportedAt,
            profile: LiveProfileSettingsProfile(
                username: snapshot.profile.username,
                displayName: snapshot.profile.displayName,
                authModeRawValue: snapshot.profile.authModeRawValue,
                remoteUserID: snapshot.profile.remoteUserID,
                remoteEmail: snapshot.profile.remoteEmail
            ),
            homeAssistant: LiveProfileSettingsHomeAssistant(
                configuration: snapshot.homeAssistant.configuration,
                trustedCertificates: snapshot.homeAssistant.trustedCertificates
            ),
            smb: LiveProfileSettingsSMB(
                configuration: snapshot.smb.configuration,
                savedConnections: snapshot.savedSMBConnections.map { connection in
                    LiveProfileSettingsSavedSMBConnection(
                        id: connection.id,
                        displayName: connection.displayName,
                        configuration: connection.configuration,
                        isDefault: connection.isDefault
                    )
                }
            ),
            savedCalendarSources: snapshot.savedCalendarSources,
            dashboardTiles: snapshot.dashboardTiles,
            notes: snapshot.notes.map { notesSnapshot in
                LiveProfileSettingsNotes(
                    configuration: notesSnapshot.configuration,
                    hasMasterKey: !notesSnapshot.masterKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        )
    }

    @MainActor
    private func makeEncryptedSecretVault(
        from snapshot: ProfileBackupSnapshot,
        profileID: UUID,
        services: AppServices
    ) throws -> (keyID: String, vault: EncryptedProfileSecretVault) {
        let key = try ensureProfileSecretVaultKey(profileID: profileID, services: services)
        let payload = ProfileSecretVaultPayload(
            schemaVersion: 1,
            exportedAt: snapshot.exportedAt,
            homeAssistantToken: snapshot.homeAssistant.token,
            smbPassword: snapshot.smb.password,
            savedSMBConnectionPasswords: snapshot.savedSMBConnections.map {
                ProfileSecretVaultSMBPassword(id: $0.id, password: $0.password)
            },
            notesMasterKey: snapshot.notes?.masterKey ?? ""
        )
        let payloadData = try encoder.encode(payload)
        let sealedBox = try AES.GCM.seal(payloadData, using: key)
        guard let combined = sealedBox.combined else {
            throw DurableProfileMirrorError(description: "The profile secret vault could not be encrypted.")
        }

        let vault = EncryptedProfileSecretVault(
            schemaVersion: 1,
            algorithm: "AES.GCM",
            exportedAt: .now,
            ciphertext: combined.base64EncodedString()
        )
        return (
            keyID: "profile-secret-vault:aes-gcm:v1",
            vault: vault
        )
    }

    @MainActor
    private func ensureProfileSecretVaultKey(profileID: UUID, services: AppServices) throws -> SymmetricKey {
        if let existing = try services.profileSecretVaultKey(for: profileID),
           let data = Data(base64Encoded: existing),
           !data.isEmpty {
            return SymmetricKey(data: data)
        }

        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try services.setProfileSecretVaultKey(data.base64EncodedString(), for: profileID)
        return key
    }

    private func mirrorURLs(profileID: UUID) throws -> (directory: URL, profile: URL, recovery: URL, metadata: URL) {
        let directory = try AppFileLocations.profileMirrorDirectory(profileID: profileID, fileManager: fileManager)
        return mirrorURLs(in: directory)
    }

    private func mirrorURLs(in directory: URL) -> (directory: URL, profile: URL, recovery: URL, metadata: URL) {
        (
            directory,
            directory.appendingPathComponent("profile.json"),
            directory.appendingPathComponent("last-known-good.json"),
            directory.appendingPathComponent("mirror-metadata.json")
        )
    }

    private func loadMetadata(profileID: UUID) throws -> ProfileMirrorMetadata {
        let urls = try mirrorURLs(profileID: profileID)
        guard fileManager.fileExists(atPath: urls.metadata.path) else {
            return ProfileMirrorMetadata(profileID: profileID)
        }
        let data = try Data(contentsOf: urls.metadata)
        return try decoder.decode(ProfileMirrorMetadata.self, from: data)
    }

    private func storeMetadata(_ metadata: ProfileMirrorMetadata, profileID: UUID) throws {
        let urls = try mirrorURLs(profileID: profileID)
        let data = try encoder.encode(metadata)
        try replaceFile(contents: data, at: urls.metadata)
    }

    private func rotateLastKnownGood(profileURL: URL, recoveryURL: URL) throws {
        guard fileManager.fileExists(atPath: profileURL.path) else {
            return
        }
        if fileManager.fileExists(atPath: recoveryURL.path) {
            try fileManager.removeItem(at: recoveryURL)
        }
        try fileManager.copyItem(at: profileURL, to: recoveryURL)
    }

    private func replaceFile(contents data: Data, at url: URL) throws {
        let tempURL = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".tmp")
        try data.write(to: tempURL, options: [.atomic])
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try fileManager.moveItem(at: tempURL, to: url)
    }

    private static func checksum(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func syncDurableMirror(
        profileID: UUID,
        data: Data,
        metadata: ProfileMirrorMetadata,
        services: AppServices
    ) throws -> ProfileMirrorMetadata {
        var updated = metadata
        guard let access = try? resolveDurableAccess(profileID: profileID, services: services) else {
            if !updated.durableLocationPath.isEmpty {
                updated.durableLastError = "Hank could not access the selected durable backup folder. Re-select the folder to continue syncing."
            } else {
                updated.durableLastError = ""
            }
            return updated
        }

        defer { access.stopAccess() }

        do {
            try fileManager.createDirectory(at: access.urls.directory, withIntermediateDirectories: true)
            try rotateLastKnownGood(profileURL: access.urls.profile, recoveryURL: access.urls.recovery)
            try replaceFile(contents: data, at: access.urls.profile)
            let metadataData = try encoder.encode(updated)
            try replaceFile(contents: metadataData, at: access.urls.metadata)
            updated.lastDurableWriteAt = .now
            updated.durableLocationPath = access.containerURL.path
            updated.durableLastError = ""
            return updated
        } catch {
            updated.durableLocationPath = access.containerURL.path
            updated.durableLastError = error.localizedDescription
            return updated
        }
    }

    private func resolveDurableMirrorURLs(
        profileID: UUID,
        services: AppServices?
    ) throws -> DurableProfileMirrorAccess? {
        guard let services else {
            return nil
        }
        return try resolveDurableAccess(profileID: profileID, services: services)
    }

    private func resolveDurableAccess(
        profileID: UUID,
        services: AppServices
    ) throws -> DurableProfileMirrorAccess? {
        guard let bookmark = try services.durableBackupBookmarkData(for: profileID) else {
            return nil
        }

        var isStale = false
        let containerURL = try URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        guard !isInsideAppContainer(containerURL) else {
            throw DurableProfileMirrorError(
                description: "Durable backup location points into Hank's app storage. Choose a folder outside the app."
            )
        }

        let didAccess = containerURL.startAccessingSecurityScopedResource()
        if !didAccess {
            throw DurableProfileMirrorError(
                description: "Hank could not access the selected durable backup folder. Re-select the folder to continue syncing."
            )
        }

        if isStale {
            let refreshed = try containerURL.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            try services.setDurableBackupBookmarkData(refreshed, for: profileID)
        }

        let directory = containerURL
            .appendingPathComponent("Hank Profiles", isDirectory: true)
            .appendingPathComponent("Backup", isDirectory: true)
            .appendingPathComponent(profileID.uuidString.lowercased(), isDirectory: true)
        return DurableProfileMirrorAccess(
            containerURL: containerURL,
            urls: mirrorURLs(in: directory),
            stopAccess: { containerURL.stopAccessingSecurityScopedResource() }
        )
    }

    private func isInsideAppContainer(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL.path
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL.path
        return standardized == home || standardized.hasPrefix(home + "/")
    }
}

final class AppMigrationService {
    private let keychain: KeychainStoring
    private let certificateTrustStore: CertificateTrustStore

    init(keychain: KeychainStoring, certificateTrustStore: CertificateTrustStore) {
        self.keychain = keychain
        self.certificateTrustStore = certificateTrustStore
    }

    @MainActor
    func migrateIfNeeded(context: ModelContext, services: AppServices) throws {
        let existingProfiles = try UserProfile.fetchAll(in: context)
        guard existingProfiles.isEmpty else {
            return
        }

        let existingHomeAssistantConfigs = try context.fetch(FetchDescriptor<HomeAssistantConfig>())
        let existingSMBConfigs = try context.fetch(FetchDescriptor<SMBConnectionConfig>())
        let existingShortcuts = try context.fetch(FetchDescriptor<DashboardShortcut>(sortBy: [SortDescriptor(\.sortOrder)]))
        let legacyToken = try keychain.softString(for: AppServices.legacyHomeAssistantTokenKey)
        let legacySMBPassword = try keychain.softString(for: AppServices.legacySMBPasswordKey)
        let legacyTrustRecords = try certificateTrustStore.legacyRecords()

        let hasLegacyState = !existingHomeAssistantConfigs.isEmpty ||
            !existingSMBConfigs.isEmpty ||
            !existingShortcuts.isEmpty ||
            !(legacyToken?.isEmpty ?? true) ||
            !(legacySMBPassword?.isEmpty ?? true) ||
            !legacyTrustRecords.isEmpty

        guard hasLegacyState else {
            return
        }

        let salt = PasswordHasher.makeSalt()
        let profile = UserProfile(
            username: "admin",
            displayName: "admin",
            passwordHash: PasswordHasher.hash(password: "admin123!", salt: salt),
            passwordSalt: salt,
            lastUsedAt: .now
        )
        context.insert(profile)

        if let homeAssistant = existingHomeAssistantConfigs.first {
            homeAssistant.profileID = profile.id
            homeAssistant.updatedAt = .now
        }

        var migratedSMBConnectionID: UUID?
        if let smb = existingSMBConfigs.first {
            let connection = SavedSMBConnection(profileID: profile.id, isDefault: true)
            connection.apply(details: smb.connectionDetails, displayName: smb.shareName, isDefault: true)
            context.insert(connection)
            migratedSMBConnectionID = connection.id
            context.delete(smb)
        }

        for (index, shortcut) in existingShortcuts.enumerated() {
            shortcut.profileID = profile.id
            shortcut.gridRow = index / 2
            shortcut.gridColumn = index % 2
            shortcut.sortOrder = index
        }

        if let legacyToken, !legacyToken.isEmpty {
            try services.setHomeAssistantToken(legacyToken, for: profile.id)
            try keychain.deleteValue(for: AppServices.legacyHomeAssistantTokenKey)
        }

        if let legacySMBPassword, !legacySMBPassword.isEmpty, let migratedSMBConnectionID {
            try services.setSMBPassword(legacySMBPassword, for: migratedSMBConnectionID, profileID: profile.id)
            try keychain.deleteValue(for: AppServices.legacySMBPasswordKey)
        }

        if !legacyTrustRecords.isEmpty {
            try services.certificateTrustStore.replace(records: legacyTrustRecords, profileID: profile.id)
            try keychain.deleteValues(matchingPrefix: "home-assistant-certificate:")
        }

        try context.save()
    }
}

@MainActor
final class ProfileSyncCoordinator {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.dropfile.Hank", category: "ProfileSync")

    func bootstrap(
        profileID: UUID,
        modelContext: ModelContext,
        services: AppServices
    ) async {
        do {
            try await pullRemoteSourceTruth(
                profileID: profileID,
                modelContext: modelContext,
                services: services
            )
        } catch {
            logger.error("Remote source truth bootstrap failed profileID=\(profileID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    func pullRemoteSourceTruth(
        profileID: UUID,
        modelContext: ModelContext,
        services: AppServices
    ) async throws {
        guard let context = try services.hankRemoteConnectionContext(in: modelContext) else {
            throw HankRemoteServiceError.notConfigured
        }

        _ = try await services.hankRemoteService.currentSession(context)
        try await services.profileMirrorService.pullRemoteSourceTruth(
            profileID: profileID,
            modelContext: modelContext,
            services: services,
            context: context
        )
    }

    func pushExplicitProfileSnapshot(
        profileID: UUID,
        modelContext: ModelContext,
        services: AppServices
    ) async throws {
        guard try services.hankRemoteConnectionContext(in: modelContext) != nil else {
            throw HankRemoteServiceError.notConfigured
        }
        _ = try await services.profileMirrorService.writeMirror(
            profileID: profileID,
            modelContext: modelContext,
            services: services,
            pushRemote: true
        )
    }
}

struct HankRemoteUser: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let email: String
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct HankRemoteSessionSummary: Equatable, Sendable {
    let user: HankRemoteUser
    let sessionID: String
    let sessionToken: String
    let expiresAt: Date
}

enum HankRemoteHomeRole: String, Codable, CaseIterable, Sendable, Hashable {
    case admin
    case member

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch rawValue {
        case "admin", "owner":
            self = .admin
        case "member":
            self = .member
        default:
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown Hank Remote home role: \(rawValue)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum HankRemoteServiceType: String, Codable, CaseIterable, Sendable, Hashable, Identifiable {
    case homeAssistant = "homeassistant"
    case smb

    var id: String { rawValue }

    var title: String {
        switch self {
        case .homeAssistant:
            "Home Assistant"
        case .smb:
            "SMB"
        }
    }
}

enum HankRemoteStatusValue: String, Codable, CaseIterable, Sendable, Hashable {
    case healthy
    case degraded
    case outOfSync = "out_of_sync"
    case offline
    case pending

    var displayTitle: String {
        switch self {
        case .healthy:
            "Backed up"
        case .offline:
            "Home agent offline"
        case .outOfSync:
            "Sync pending"
        case .degraded:
            "Needs attention"
        case .pending:
            "Not yet applied"
        }
    }
}

struct HankRemoteHome: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let userID: String
    let name: String
    let createdAt: Date
    let updatedAt: Date
    var role: HankRemoteHomeRole?

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case name
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case role
    }

    init(
        id: String,
        userID: String,
        name: String,
        createdAt: Date,
        updatedAt: Date,
        role: HankRemoteHomeRole? = nil
    ) {
        self.id = id
        self.userID = userID
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.role = role
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        userID = try container.decodeIfPresent(String.self, forKey: .userID) ?? ""
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        role = try container.decodeIfPresent(HankRemoteHomeRole.self, forKey: .role)
    }

    var canManageMembers: Bool {
        role == .admin
    }

    var canManageAgent: Bool {
        role == .admin
    }

    var canManageIntegrations: Bool {
        role == .admin
    }

    var canManagePermissions: Bool {
        role == .admin
    }

    var canEditSharedNotes: Bool {
        role == .admin || role == .member
    }
}

struct HankRemoteHomeMember: Codable, Equatable, Identifiable, Sendable {
    let userID: String
    let email: String
    let role: HankRemoteHomeRole
    let createdAt: Date
    let updatedAt: Date

    var id: String { userID }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case email
        case role
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct HankRemoteHomeInvitationCreateResponse: Decodable, Equatable, Sendable {
    let invitationID: String
    let homeID: String
    let email: String
    let role: HankRemoteHomeRole
    let token: String
    let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case invitationID = "invitation_id"
        case homeID = "home_id"
        case email
        case role
        case token
        case expiresAt = "expires_at"
    }
}

struct HankRemoteHomeNotesSyncStatus: Decodable, Equatable, Sendable {
    let status: HankRemoteStatusValue
    let lastManifestAt: Date?
    let lastPullAt: Date?
    let lastPushAt: Date?
    let lastSuccessfulSyncAt: Date?
    let lastSuccessfulBackupAt: Date?
    let pendingPullCount: Int
    let pendingPushCount: Int
    let lastError: String

    enum CodingKeys: String, CodingKey {
        case status
        case lastManifestAt = "last_manifest_at"
        case lastPullAt = "last_pull_at"
        case lastPushAt = "last_push_at"
        case lastSuccessfulSyncAt = "last_successful_sync_at"
        case lastSuccessfulBackupAt = "last_successful_backup_at"
        case pendingPullCount = "pending_pull_count"
        case pendingPushCount = "pending_push_count"
        case lastError = "last_error"
    }
}

struct HankRemoteHomeSyncProfileStatus: Decodable, Equatable, Sendable {
    let status: HankRemoteStatusValue
    let updatedAt: Date?
    let lastBackupAt: Date?
    let lastError: String
    let secretVersion: Int
    let appliedVersion: Int

    enum CodingKeys: String, CodingKey {
        case status
        case updatedAt = "updated_at"
        case lastBackupAt = "last_backup_at"
        case lastError = "last_error"
        case secretVersion = "secret_version"
        case appliedVersion = "applied_version"
    }
}

struct HankRemoteHomeSyncStatus: Decodable, Equatable, Sendable {
    let homeID: String
    let notes: HankRemoteHomeNotesSyncStatus
    let profiles: [String: HankRemoteHomeSyncProfileStatus]

    enum CodingKeys: String, CodingKey {
        case homeID = "home_id"
        case notes
        case profiles
    }
}

struct HankRemoteHomePermissions: Codable, Equatable, Sendable {
    let homeID: String
    let homeAssistant: Bool
    let files: Bool
    let notes: Bool
    let updatedAt: Date
    let updatedBy: String

    enum CodingKeys: String, CodingKey {
        case homeID = "home_id"
        case homeAssistant = "homeassistant"
        case files
        case notes
        case updatedAt = "updated_at"
        case updatedBy = "updated_by"
    }
}

struct HankRemoteHomeMemberPermissions: Codable, Equatable, Sendable {
    let homeID: String
    let userID: String
    let homeAssistant: Bool?
    let files: Bool?
    let notes: Bool?
    let updatedAt: Date?
    let updatedBy: String

    enum CodingKeys: String, CodingKey {
        case homeID = "home_id"
        case userID = "user_id"
        case homeAssistant = "homeassistant"
        case files
        case notes
        case updatedAt = "updated_at"
        case updatedBy = "updated_by"
    }
}

struct HankRemoteHomeAgent: Decodable, Equatable, Sendable {
    let agentID: String
    let name: String
    let status: String
    let lastSeenAt: Date?
    let homeID: String
    let homeName: String
    let capabilities: [String]

    enum CodingKeys: String, CodingKey {
        case agentID = "agent_id"
        case name
        case status
        case lastSeenAt = "last_seen_at"
        case homeID = "home_id"
        case homeName = "home_name"
        case capabilities
    }
}

struct HankRemoteAgentToken: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let homeID: String
    let agentID: String
    let revokedAt: Date?
    let expiresAt: Date?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case homeID = "home_id"
        case agentID = "agent_id"
        case revokedAt = "revoked_at"
        case expiresAt = "expires_at"
        case createdAt = "created_at"
    }
}

struct HankRemoteIssuedAgentToken: Equatable, Sendable {
    let tokenID: String
    let homeID: String
    let agentID: String
    let agentName: String
    let token: String
    let expiresAt: Date?
    let createdAt: Date
    let agentStatus: String
}

enum HankRemoteStorageSeverity: String, Codable, CaseIterable, Sendable {
    case info
    case warning
    case error
    case critical
}

enum HankRemoteStorageOperation: String, Codable, CaseIterable, Sendable {
    case checksum
    case amcheck
    case backup
    case restoreTest = "restore_test"
    case primaryRestore = "primary_restore"
    case config
}

enum HankRemoteStorageEventStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case started
    case success
    case failed
}

struct HankRemoteStorageEvent: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let time: Date
    let severity: HankRemoteStorageSeverity
    let operation: HankRemoteStorageOperation
    let status: HankRemoteStorageEventStatus
    let message: String
    let backupLabel: String?
    let details: [String: AnyDecodable]

    enum CodingKeys: String, CodingKey {
        case id
        case time
        case severity
        case operation
        case status
        case message
        case backupLabel = "backup_label"
        case details
    }

    static func == (lhs: HankRemoteStorageEvent, rhs: HankRemoteStorageEvent) -> Bool {
        lhs.id == rhs.id
            && lhs.time == rhs.time
            && lhs.severity == rhs.severity
            && lhs.operation == rhs.operation
            && lhs.status == rhs.status
            && lhs.message == rhs.message
            && lhs.backupLabel == rhs.backupLabel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        time = try container.decode(Date.self, forKey: .time)
        severity = try container.decodeIfPresent(HankRemoteStorageSeverity.self, forKey: .severity) ?? .info
        operation = try container.decodeIfPresent(HankRemoteStorageOperation.self, forKey: .operation) ?? .config
        status = try container.decodeIfPresent(HankRemoteStorageEventStatus.self, forKey: .status) ?? .pending
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        backupLabel = try container.decodeIfPresent(String.self, forKey: .backupLabel)
        details = try container.decodeIfPresent([String: AnyDecodable].self, forKey: .details) ?? [:]
    }
}

struct HankRemoteNotificationSettings: Codable, Equatable, Sendable {
    var userID: String?
    var storage: Bool
    var notes: Bool
    var dashboardEntities: Bool
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case storage
        case notes
        case dashboardEntities = "dashboard_entities"
        case updatedAt = "updated_at"
    }

    init(
        userID: String? = nil,
        storage: Bool = true,
        notes: Bool = true,
        dashboardEntities: Bool = true,
        updatedAt: Date? = nil
    ) {
        self.userID = userID
        self.storage = storage
        self.notes = notes
        self.dashboardEntities = dashboardEntities
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userID = try container.decodeIfPresent(String.self, forKey: .userID)
        storage = try container.decodeIfPresent(Bool.self, forKey: .storage) ?? true
        notes = try container.decodeIfPresent(Bool.self, forKey: .notes) ?? true
        dashboardEntities = try container.decodeIfPresent(Bool.self, forKey: .dashboardEntities) ?? true
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

struct HankRemoteStorageConfig: Codable, Equatable, Sendable {
    var targetType: String
    var targetPath: String
    var fullSchedule: String
    var differentialSchedule: String
    var checksumIntervalSeconds: Int
    var restoreVerificationSchedule: String
    var retainedFullBackupCount: Int
    var restoreConfirmationPhrase: String

    enum CodingKeys: String, CodingKey {
        case targetType = "target_type"
        case targetPath = "target_path"
        case fullSchedule = "full_schedule"
        case differentialSchedule = "differential_schedule"
        case checksumIntervalSeconds = "checksum_interval_seconds"
        case restoreVerificationSchedule = "restore_verification_schedule"
        case retainedFullBackupCount = "retained_full_backup_count"
        case restoreConfirmationPhrase = "restore_confirmation_phrase"
    }

    init(
        targetType: String = "local",
        targetPath: String = "",
        fullSchedule: String = "",
        differentialSchedule: String = "",
        checksumIntervalSeconds: Int = 86_400,
        restoreVerificationSchedule: String = "",
        retainedFullBackupCount: Int = 7,
        restoreConfirmationPhrase: String = ""
    ) {
        self.targetType = targetType
        self.targetPath = targetPath
        self.fullSchedule = fullSchedule
        self.differentialSchedule = differentialSchedule
        self.checksumIntervalSeconds = checksumIntervalSeconds
        self.restoreVerificationSchedule = restoreVerificationSchedule
        self.retainedFullBackupCount = retainedFullBackupCount
        self.restoreConfirmationPhrase = restoreConfirmationPhrase
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        targetType = try container.decodeIfPresent(String.self, forKey: .targetType) ?? "local"
        targetPath = try container.decodeIfPresent(String.self, forKey: .targetPath) ?? ""
        fullSchedule = try container.decodeIfPresent(String.self, forKey: .fullSchedule) ?? ""
        differentialSchedule = try container.decodeIfPresent(String.self, forKey: .differentialSchedule) ?? ""
        checksumIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .checksumIntervalSeconds) ?? 86_400
        restoreVerificationSchedule = try container.decodeIfPresent(String.self, forKey: .restoreVerificationSchedule) ?? ""
        retainedFullBackupCount = try container.decodeIfPresent(Int.self, forKey: .retainedFullBackupCount) ?? 7
        restoreConfirmationPhrase = try container.decodeIfPresent(String.self, forKey: .restoreConfirmationPhrase) ?? ""
    }
}

struct HankRemoteStorageChecksumStatus: Decodable, Equatable, Sendable {
    let enabled: Bool
    let lastCheckAt: Date?
    let lastAmcheckAt: Date?
    let failureCount: Int
    let corruptionDetected: Bool
    let lastError: String

    enum CodingKeys: String, CodingKey {
        case enabled
        case lastCheckAt = "last_check_at"
        case lastAmcheckAt = "last_amcheck_at"
        case failureCount = "failure_count"
        case corruptionDetected = "corruption_detected"
        case lastError = "last_error"
    }
}

struct HankRemoteStorageBackupStatus: Decodable, Equatable, Sendable {
    struct Backup: Decodable, Equatable, Identifiable, Sendable {
        let label: String
        let type: String
        let createdAt: Date?
        let sizeBytes: Int64?

        var id: String { label }

        enum CodingKeys: String, CodingKey {
            case label
            case type
            case createdAt = "created_at"
            case sizeBytes = "size_bytes"
        }
    }

    let targetType: String
    let targetPath: String
    let backups: [Backup]
    let lastSuccessfulBackupAt: Date?
    let failureCount: Int

    enum CodingKeys: String, CodingKey {
        case targetType = "target_type"
        case targetPath = "target_path"
        case backups
        case lastSuccessfulBackupAt = "last_successful_backup_at"
        case failureCount = "failure_count"
    }
}

struct HankRemoteStorageRestoreStatus: Decodable, Equatable, Sendable {
    let lastRestoreTestAt: Date?
    let lastPrimaryRestoreAt: Date?
    let pendingIntentCount: Int
    let confirmationPhrase: String

    enum CodingKeys: String, CodingKey {
        case lastRestoreTestAt = "last_restore_test_at"
        case lastPrimaryRestoreAt = "last_primary_restore_at"
        case pendingIntentCount = "pending_intent_count"
        case confirmationPhrase = "confirmation_phrase"
    }
}

enum HankRemoteStorageTaskStatus: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case success
    case failed
}

struct HankRemoteStorageTask: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let operation: HankRemoteStorageOperation
    let status: HankRemoteStorageTaskStatus
    let message: String
    let step: String?
    let backupType: String?
    let backupLabel: String?
    let queuedAt: Date?
    let startedAt: Date?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case operation
        case status
        case message
        case step
        case backupType = "backup_type"
        case backupLabel = "backup_label"
        case queuedAt = "queued_at"
        case startedAt = "started_at"
        case updatedAt = "updated_at"
    }
}

struct HankRemoteStorageStatus: Decodable, Equatable, Sendable {
    let config: HankRemoteStorageConfig
    let checksum: HankRemoteStorageChecksumStatus
    let backup: HankRemoteStorageBackupStatus
    let restore: HankRemoteStorageRestoreStatus
    let tasks: [HankRemoteStorageTask]
    let events: [HankRemoteStorageEvent]
    let failures: [HankRemoteStorageEvent]

    enum CodingKeys: String, CodingKey {
        case config
        case checksum
        case backup
        case restore
        case tasks
        case events
        case failures
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        config = try container.decode(HankRemoteStorageConfig.self, forKey: .config)
        checksum = try container.decode(HankRemoteStorageChecksumStatus.self, forKey: .checksum)
        backup = try container.decode(HankRemoteStorageBackupStatus.self, forKey: .backup)
        restore = try container.decode(HankRemoteStorageRestoreStatus.self, forKey: .restore)
        tasks = try container.decodeIfPresent([HankRemoteStorageTask].self, forKey: .tasks) ?? []
        events = try container.decodeIfPresent([HankRemoteStorageEvent].self, forKey: .events) ?? []
        failures = try container.decodeIfPresent([HankRemoteStorageEvent].self, forKey: .failures) ?? []
    }
}

struct HankRemoteAssistantResultCard: Decodable, Sendable {
    let kind: String
    let title: String
    let summary: String
    let actionTitle: String
    let noteID: String?
    let eventID: String?
    let targetDate: Date?
    let path: String?
    let searchText: String?
    let imageURL: URL?
    let mediaOptionID: String?
    let mediaType: String?
    let year: Int?
    let jobID: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case title
        case summary
        case actionTitle = "action_title"
        case noteID = "note_id"
        case eventID = "event_id"
        case targetDate = "target_date"
        case date
        case path
        case searchText = "search_text"
        case imageURL = "image_url"
        case posterURL = "poster_url"
        case mediaOptionID = "media_option_id"
        case mediaType = "media_type"
        case year
        case jobID = "job_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decode(String.self, forKey: .summary)
        actionTitle = try container.decodeIfPresent(String.self, forKey: .actionTitle) ?? "Open"
        noteID = try container.decodeIfPresent(String.self, forKey: .noteID)
        eventID = try container.decodeIfPresent(String.self, forKey: .eventID)
        targetDate = try container.decodeIfPresent(Date.self, forKey: .targetDate)
            ?? container.decodeIfPresent(Date.self, forKey: .date)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        searchText = try container.decodeIfPresent(String.self, forKey: .searchText)
        if let rawImageURL = try (container.decodeIfPresent(String.self, forKey: .imageURL)
            ?? container.decodeIfPresent(String.self, forKey: .posterURL))?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !rawImageURL.isEmpty {
            imageURL = URL(string: rawImageURL)
        } else {
            imageURL = nil
        }
        mediaOptionID = try container.decodeIfPresent(String.self, forKey: .mediaOptionID)
        mediaType = try container.decodeIfPresent(String.self, forKey: .mediaType)
        year = try container.decodeIfPresent(Int.self, forKey: .year)
        jobID = try container.decodeIfPresent(String.self, forKey: .jobID)
    }
}

struct HankRemoteAssistantIndexSourceCount: Decodable, Equatable, Sendable {
    let sourceType: String
    let documentCount: Int
    let chunkCount: Int
    let embeddedChunkCount: Int

    enum CodingKeys: String, CodingKey {
        case sourceType = "source_type"
        case documentCount = "document_count"
        case chunkCount = "chunk_count"
        case embeddedChunkCount = "embedded_chunk_count"
    }
}

struct HankRemoteAssistantIndexStatus: Decodable, Equatable, Sendable {
    let vectorAvailable: Bool
    let vectorMode: String
    let documentsBySource: [HankRemoteAssistantIndexSourceCount]
    let chunkCount: Int
    let embeddedChunkCount: Int
    let fileCount: Int
    let embeddedFileCount: Int
    let conversationCount: Int

    enum CodingKeys: String, CodingKey {
        case vectorAvailable = "vector_available"
        case vectorMode = "vector_mode"
        case documentsBySource = "documents_by_source"
        case chunkCount = "chunk_count"
        case embeddedChunkCount = "embedded_chunk_count"
        case fileCount = "file_count"
        case embeddedFileCount = "embedded_file_count"
        case conversationCount = "conversation_count"
    }
}

struct HankRemoteAssistantStatus: Decodable, Equatable, Sendable {
    let homeID: String
    let provider: String
    let chatConfigured: Bool
    let embeddingConfigured: Bool
    let chatModel: String
    let embeddingModel: String
    let vectorStore: String
    let index: HankRemoteAssistantIndexStatus?

    enum CodingKeys: String, CodingKey {
        case homeID = "home_id"
        case provider
        case chatConfigured = "chat_configured"
        case embeddingConfigured = "embedding_configured"
        case chatModel = "chat_model"
        case embeddingModel = "embedding_model"
        case vectorStore = "vector_store"
        case index
    }
}

struct HankRemoteAssistantSettings: Codable, Equatable, Sendable {
    var homeID: String
    var userID: String
    var profileNotesEnabled: Bool
    var homeNotesEnabled: Bool
    var filesEnabled: Bool
    var calendarEnabled: Bool
    var homeAssistantEnabled: Bool
    var projectDocsEnabled: Bool
    var conversationsEnabled: Bool
    var systemPrompt: String
    var maxContextItems: Int
    var createdAt: Date?
    var updatedAt: Date?
    var updatedBy: String

    enum CodingKeys: String, CodingKey {
        case homeID = "home_id"
        case userID = "user_id"
        case profileNotesEnabled = "profile_notes_enabled"
        case homeNotesEnabled = "home_notes_enabled"
        case filesEnabled = "files_enabled"
        case calendarEnabled = "calendar_enabled"
        case homeAssistantEnabled = "homeassistant_enabled"
        case projectDocsEnabled = "project_docs_enabled"
        case conversationsEnabled = "conversations_enabled"
        case systemPrompt = "system_prompt"
        case maxContextItems = "max_context_items"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case updatedBy = "updated_by"
    }
}

struct HankRemoteAssistantSettingsSource: Decodable, Equatable, Identifiable, Sendable {
    let key: String
    let label: String
    let enabled: Bool
    let description: String

    var id: String { key }
}

struct HankRemoteAssistantSettingsResponse: Decodable, Equatable, Sendable {
    let settings: HankRemoteAssistantSettings
    let sources: [HankRemoteAssistantSettingsSource]
    let defaults: [String: AnyDecodable]

    enum CodingKeys: String, CodingKey {
        case settings
        case sources
        case defaults
    }

    static func == (lhs: HankRemoteAssistantSettingsResponse, rhs: HankRemoteAssistantSettingsResponse) -> Bool {
        lhs.settings == rhs.settings && lhs.sources == rhs.sources
    }
}

struct HankRemoteInstalledAppsResponse: Decodable, Equatable, Sendable {
    let apps: [HankRemoteInstalledApp]
}

struct HankRemoteInstalledApp: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let version: String
    let description: String
    let enabled: Bool
    let status: String
    let userAccess: String
    let slashCommands: [HankRemoteInstalledAppSlashCommand]
    let commands: [HankRemoteInstalledAppCommand]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case version
        case description
        case enabled
        case status
        case userAccess = "user_access"
        case slashCommands = "slash_commands"
        case commands
    }

    init(
        id: String,
        name: String,
        version: String,
        description: String,
        enabled: Bool,
        status: String,
        userAccess: String = "",
        slashCommands: [HankRemoteInstalledAppSlashCommand],
        commands: [HankRemoteInstalledAppCommand]
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.enabled = enabled
        self.status = status
        self.userAccess = userAccess
        self.slashCommands = slashCommands
        self.commands = commands
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? ""
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        userAccess = try container.decodeIfPresent(String.self, forKey: .userAccess) ?? ""
        slashCommands = try container.decodeIfPresent([HankRemoteInstalledAppSlashCommand].self, forKey: .slashCommands) ?? []
        commands = try container.decodeIfPresent([HankRemoteInstalledAppCommand].self, forKey: .commands) ?? []
    }
}

struct HankRemoteInstalledAppSlashCommand: Decodable, Equatable, Sendable {
    let command: String
    let commandID: String
    let description: String

    enum CodingKeys: String, CodingKey {
        case command
        case commandID = "command_id"
        case description
    }

    init(command: String, commandID: String, description: String) {
        self.command = command
        self.commandID = commandID
        self.description = description
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
        commandID = try container.decodeIfPresent(String.self, forKey: .commandID) ?? ""
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
    }
}

struct HankRemoteInstalledAppCommand: Decodable, Equatable, Sendable {
    let id: String
    let mode: String
    let timeoutSeconds: Int
    let adminOnly: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case mode
        case timeoutSeconds = "timeout_seconds"
        case adminOnly = "admin_only"
    }
}

struct HankRemoteOpenAIDeviceAuthStatus: Decodable, Equatable, Sendable {
    let state: String
    let verificationURL: URL?
    let userCode: String
    let expiresAt: Date?
    let pollAfterSeconds: Int
    let error: String
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case state
        case verificationURL = "verification_url"
        case userCode = "user_code"
        case expiresAt = "expires_at"
        case pollAfterSeconds = "poll_after_seconds"
        case error
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? ""
        verificationURL = try container.decodeIfPresent(URL.self, forKey: .verificationURL)
        userCode = try container.decodeIfPresent(String.self, forKey: .userCode) ?? ""
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        pollAfterSeconds = try container.decodeIfPresent(Int.self, forKey: .pollAfterSeconds) ?? 5
        error = try container.decodeIfPresent(String.self, forKey: .error) ?? ""
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

struct HankRemoteOpenAIAccountStatus: Decodable, Equatable, Sendable {
    let configured: Bool
    let linked: Bool
    let missing: [String]
    let authMode: String
    let authProvider: String
    let chatGPTPlanType: String
    let pending: HankRemoteOpenAIDeviceAuthStatus?
    let scopes: String
    let redirectURI: String
    let tokenType: String
    let scope: String
    let expiresAt: Date?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case configured
        case linked
        case missing
        case authMode = "auth_mode"
        case authProvider = "auth_provider"
        case chatGPTPlanType = "chatgpt_plan_type"
        case pending
        case scopes
        case redirectURI = "redirect_uri"
        case tokenType = "token_type"
        case scope
        case expiresAt = "expires_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        configured = try container.decodeIfPresent(Bool.self, forKey: .configured) ?? false
        linked = try container.decodeIfPresent(Bool.self, forKey: .linked) ?? false
        missing = try container.decodeIfPresent([String].self, forKey: .missing) ?? []
        authMode = try container.decodeIfPresent(String.self, forKey: .authMode) ?? "authorization_url"
        authProvider = try container.decodeIfPresent(String.self, forKey: .authProvider) ?? ""
        chatGPTPlanType = try container.decodeIfPresent(String.self, forKey: .chatGPTPlanType) ?? ""
        pending = try container.decodeIfPresent(HankRemoteOpenAIDeviceAuthStatus.self, forKey: .pending)
        scopes = try container.decodeIfPresent(String.self, forKey: .scopes) ?? ""
        redirectURI = try container.decodeIfPresent(String.self, forKey: .redirectURI) ?? ""
        tokenType = try container.decodeIfPresent(String.self, forKey: .tokenType) ?? ""
        scope = try container.decodeIfPresent(String.self, forKey: .scope) ?? ""
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

struct HankRemoteOpenAIAccountLinkStart: Decodable, Equatable, Sendable {
    let authMode: String
    let authorizationURL: URL?
    let verificationURL: URL?
    let userCode: String
    let expiresAt: Date?
    let pollAfterSeconds: Int

    enum CodingKeys: String, CodingKey {
        case authMode = "auth_mode"
        case authorizationURL = "authorization_url"
        case verificationURL = "verification_url"
        case userCode = "user_code"
        case expiresAt = "expires_at"
        case pollAfterSeconds = "poll_after_seconds"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        authorizationURL = try container.decodeIfPresent(URL.self, forKey: .authorizationURL)
        verificationURL = try container.decodeIfPresent(URL.self, forKey: .verificationURL)
        userCode = try container.decodeIfPresent(String.self, forKey: .userCode) ?? ""
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        pollAfterSeconds = try container.decodeIfPresent(Int.self, forKey: .pollAfterSeconds) ?? 5
        authMode = try container.decodeIfPresent(String.self, forKey: .authMode)
            ?? (authorizationURL == nil ? "device_code" : "authorization_url")
    }
}

struct HankRemoteAssistantMessage: Decodable, Sendable, Identifiable {
    let id: String
    let role: String
    let text: String
    let createdAt: Date
    let cards: [HankRemoteAssistantResultCard]
    let diagnostics: HankRemoteAssistantDiagnostics?

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case text
        case createdAt = "created_at"
        case cards
        case diagnostics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? "assistant"
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        cards = try container.decodeIfPresent([HankRemoteAssistantResultCard].self, forKey: .cards) ?? []
        diagnostics = try container.decodeIfPresent(HankRemoteAssistantDiagnostics.self, forKey: .diagnostics)
    }
}

struct HankRemoteAssistantDiagnostics: Decodable, Equatable, Sendable {
    let toolKind: String
    let intentKind: String
    let query: String
    let mediaSelectionTitle: String
    let mediaSelectionPath: String

    enum CodingKeys: String, CodingKey {
        case toolKind = "tool_kind"
        case intentKind = "intent_kind"
        case query
        case mediaSelectionTitle = "media_selection_title"
        case mediaSelectionPath = "media_selection_path"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        toolKind = try container.decodeIfPresent(String.self, forKey: .toolKind) ?? ""
        intentKind = try container.decodeIfPresent(String.self, forKey: .intentKind) ?? ""
        query = try container.decodeIfPresent(String.self, forKey: .query) ?? ""
        mediaSelectionTitle = try container.decodeIfPresent(String.self, forKey: .mediaSelectionTitle) ?? ""
        mediaSelectionPath = try container.decodeIfPresent(String.self, forKey: .mediaSelectionPath) ?? ""
    }
}

struct HankRemoteAssistantSession: Decodable, Sendable, Identifiable {
    let id: String
    let title: String
    let lastMessageAt: Date
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case lastMessageAt = "last_message_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

private struct HankRemoteAssistantSessionsResponse: Decodable {
    let sessions: [HankRemoteAssistantSession]
}

private struct HankRemoteAssistantMessagesResponse: Decodable {
    let messages: [HankRemoteAssistantMessage]
}

private struct HankRemoteAssistantMessageCreateRequest: Encodable {
    let content: String
    let attachments: [HankRemoteAssistantAttachmentUpload]
    let deviceContext: HankRemoteAssistantDeviceContext

    enum CodingKeys: String, CodingKey {
        case content
        case attachments
        case deviceContext = "device_context"
    }
}

struct HankRemoteAssistantAttachmentUpload: Encodable {
    let clientAttachmentID: String
    let filename: String
    let contentType: String
    let sizeBytes: Int64
    let checksumSHA256: String
    let kind: String

    enum CodingKeys: String, CodingKey {
        case clientAttachmentID = "client_attachment_id"
        case filename
        case contentType = "content_type"
        case sizeBytes = "size_bytes"
        case checksumSHA256 = "checksum_sha256"
        case kind
    }
}

extension HankRemoteAssistantAttachmentUpload {
    init(stagedAttachment: HankAssistantStagedAttachment) {
        self.init(
            clientAttachmentID: stagedAttachment.clientAttachmentID,
            filename: stagedAttachment.filename,
            contentType: stagedAttachment.contentType,
            sizeBytes: stagedAttachment.sizeBytes,
            checksumSHA256: stagedAttachment.checksumSHA256,
            kind: stagedAttachment.kind
        )
    }
}

private struct HankRemoteAssistantDeviceContext: Encodable {
    let deviceID: String
    let timezone: String

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case timezone
    }
}

private struct HankRemoteAssistantClientToolResultPayload: Encodable {
    let toolName: String
    let result: [String: AnyEncodable]
    let error: String?

    enum CodingKeys: String, CodingKey {
        case toolName = "tool_name"
        case result
        case error
    }
}

private struct HankRemoteAssistantClientToolResultsPayload: Encodable {
    let results: [HankRemoteAssistantClientToolResultPayload]
}

struct HankRemoteAssistantSettingsUpdate: Encodable, Equatable, Sendable {
    let profileNotesEnabled: Bool
    let homeNotesEnabled: Bool
    let filesEnabled: Bool
    let calendarEnabled: Bool
    let homeAssistantEnabled: Bool
    let projectDocsEnabled: Bool
    let conversationsEnabled: Bool
    let systemPrompt: String

    enum CodingKeys: String, CodingKey {
        case profileNotesEnabled = "profile_notes_enabled"
        case homeNotesEnabled = "home_notes_enabled"
        case filesEnabled = "files_enabled"
        case calendarEnabled = "calendar_enabled"
        case homeAssistantEnabled = "homeassistant_enabled"
        case projectDocsEnabled = "project_docs_enabled"
        case conversationsEnabled = "conversations_enabled"
        case systemPrompt = "system_prompt"
    }
}

private struct HankRemoteAssistantCalendarIndexRequest: Encodable {
    let deviceID: String
    let entries: [[String: AnyEncodable]]

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case entries
    }
}

struct HankRemotePingResponse: Codable, Equatable, Sendable {
    let message: String
    let time: Date
}

struct HankRemoteAssistantClientToolRequest: Decodable {
    let toolName: String
    let arguments: [String: AnyDecodable]

    enum CodingKeys: String, CodingKey {
        case toolName = "tool_name"
        case arguments
    }
}

struct HankRemoteAssistantPendingActionDetail: Decodable, Equatable {
    let label: String
    let value: String
}

struct HankRemoteAssistantPendingActionSummary: Decodable, Equatable {
    let kind: String
    let title: String
    let summary: String
    let confirmationMessage: String
    let details: [HankRemoteAssistantPendingActionDetail]
    let isDestructive: Bool

    enum CodingKeys: String, CodingKey {
        case kind
        case title
        case summary
        case confirmationMessage = "confirmation_message"
        case details
        case isDestructive = "is_destructive"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        confirmationMessage = try container.decodeIfPresent(String.self, forKey: .confirmationMessage) ?? ""
        details = try container.decodeIfPresent([HankRemoteAssistantPendingActionDetail].self, forKey: .details) ?? []
        isDestructive = try container.decodeIfPresent(Bool.self, forKey: .isDestructive) ?? false
    }
}

struct HankRemoteAssistantRun: Decodable {
    let id: String
    let state: String
    let requiresClientTools: Bool
    let requiresConfirmation: Bool
    let assistantMessage: HankRemoteAssistantMessage?
    let clientToolRequest: HankRemoteAssistantClientToolRequest?
    let pendingActionSummary: HankRemoteAssistantPendingActionSummary?
    let diagnostics: HankRemoteAssistantDiagnostics?

    enum CodingKeys: String, CodingKey {
        case id
        case state
        case requiresClientTools = "requires_client_tools"
        case requiresConfirmation = "requires_confirmation"
        case assistantMessage = "assistant_message"
        case clientToolRequest = "client_tool_request"
        case pendingActionSummary = "pending_action_summary"
        case diagnostics
    }
}

struct HankRemoteAssistantCalendarIndexEntry: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let externalEventID: String
    let calendarID: String
    let calendarTitle: String
    let title: String
    let location: String
    let notes: String
    let startsAt: Date
    let endsAt: Date
    let isAllDay: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case externalEventID = "external_event_id"
        case calendarID = "calendar_id"
        case calendarTitle = "calendar_title"
        case title
        case location
        case notes
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case isAllDay = "is_all_day"
    }
}

private struct HankRemoteAssistantRunResponse: Decodable {
    let run: HankRemoteAssistantRun
}

private struct HankRemoteAssistantRunConfirmRequest: Encodable {
    let approved: Bool
}

private struct HankRemoteAssistantCalendarIndexUploadRequest: Encodable {
    let deviceID: String
    let timezone: String
    let entries: [HankRemoteAssistantCalendarIndexEntry]

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case timezone
        case entries
    }
}

private struct HankRemoteAuthResponse: Decodable {
    let user: HankRemoteUser
    let sessionID: String
    let sessionToken: String
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case user
        case sessionID = "session_id"
        case sessionToken = "session_token"
        case expiresAt = "expires_at"
    }
}

private struct HankRemoteMeResponse: Decodable {
    let user: HankRemoteUser
    let sessionID: String
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case user
        case sessionID = "session_id"
        case expiresAt = "expires_at"
    }
}

private struct HankRemoteHomeAcceptResponse: Decodable {
    let ok: Bool
    let home: HankRemoteHome
}

private struct HankRemoteHomeMembersResponse: Decodable {
    let members: [HankRemoteHomeMember]
}

private struct HankRemoteAgentTokensResponse: Decodable {
    let tokens: [HankRemoteAgentToken]
}

private struct HankRemoteStorageEventsResponse: Decodable {
    let events: [HankRemoteStorageEvent]
}

private struct HankRemoteStorageBackupRequest: Encodable {
    let type: String
}

private struct HankRemoteAPNSDeviceRegistrationRequest: Encodable {
    let deviceID: String
    let token: String
    let environment: String
    let bundleID: String
    let enabledCategories: [String]

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case token
        case environment
        case bundleID = "bundle_id"
        case enabledCategories = "enabled_categories"
    }
}

private struct HankRemoteAPNSDeviceRegistrationResponse: Decodable {
    let ok: Bool
}

private struct HankRemoteStorageRestorePrimaryRequest: Encodable {
    let confirmationPhrase: String

    enum CodingKeys: String, CodingKey {
        case confirmationPhrase = "confirmation_phrase"
    }
}

private struct HankRemoteHomeAgentResponse: Decodable {
    let agent: HankRemoteHomeAgent?
}

private struct HankRemoteIssuedAgentTokenResponse: Decodable {
    let tokenID: String
    let homeID: String
    let agentID: String
    let agentName: String
    let token: String
    let expiresAt: Date?
    let createdAt: Date
    let agentStatus: String

    enum CodingKeys: String, CodingKey {
        case tokenID = "token_id"
        case homeID = "home_id"
        case agentID = "agent_id"
        case agentName = "agent_name"
        case token
        case expiresAt = "expires_at"
        case createdAt = "created_at"
        case agentStatus = "agent_status"
    }
}

private struct HankRemoteHealthResponse: Decodable {
    let ok: Bool?
    let service: String?
}

private struct HankRemoteAppWebSocketTicketResponse: Decodable {
    let ticket: String
    let expiresAt: Date
    let websocketPath: String

    enum CodingKeys: String, CodingKey {
        case ticket
        case expiresAt = "expires_at"
        case websocketPath = "websocket_path"
    }
}

private struct HankRemoteEmptyResponse: Decodable {
    let ok: Bool
}

struct HankRemoteProfileBackupRecord: Codable, Sendable {
    let revision: Int
    let updatedAt: Date
    let snapshot: ProfileBackupSnapshot

    enum CodingKeys: String, CodingKey {
        case revision
        case updatedAt = "updated_at"
        case snapshot
    }
}

struct HankRemoteProfileSettingsRecord: Decodable, Sendable {
    let revision: Int
    let updatedAt: Date?
    let settings: [String: AnyDecodable]

    enum CodingKeys: String, CodingKey {
        case revision
        case updatedAt = "updated_at"
        case settings
    }
}

struct HankRemoteProfileSecretVaultRecord: Decodable, Sendable {
    let revision: Int
    let keyID: String
    let updatedAt: Date?
    let vault: [String: AnyDecodable]

    enum CodingKeys: String, CodingKey {
        case revision
        case keyID = "key_id"
        case updatedAt = "updated_at"
        case vault
    }
}

private struct HankRemoteProfileBackupSaveRequest: Encodable {
    let expectedRevision: Int?
    let snapshot: ProfileBackupSnapshot

    enum CodingKeys: String, CodingKey {
        case expectedRevision = "expected_revision"
        case snapshot
    }
}

private struct HankRemoteProfileSettingsSaveRequest<Settings: Encodable>: Encodable {
    let expectedRevision: Int?
    let settings: Settings

    enum CodingKeys: String, CodingKey {
        case expectedRevision = "expected_revision"
        case settings
    }
}

private struct HankRemoteProfileSecretVaultSaveRequest<Vault: Encodable>: Encodable {
    let expectedRevision: Int?
    let keyID: String
    let vault: Vault

    enum CodingKeys: String, CodingKey {
        case expectedRevision = "expected_revision"
        case keyID = "key_id"
        case vault
    }
}

private struct HankRemoteFileListResponse: Decodable {
    let items: [HankRemoteFileItem]
}

private struct HankRemoteFileItem: Decodable {
    let path: String
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modifiedAt: Date?

    enum CodingKeys: String, CodingKey {
        case path
        case name
        case isDirectory = "is_directory"
        case size
        case modifiedAt = "modified_at"
    }

    var smbItem: SMBItem {
        SMBItem(
            path: path,
            name: name,
            isDirectory: isDirectory,
            size: isDirectory ? nil : size,
            modifiedAt: modifiedAt
        )
    }
}

private struct HankRemoteTransferSetup: Decodable {
    let transferID: String?
    let jobID: String?
    let sourceID: String?
    let transferToken: String
    let url: String
    let method: String?

    enum CodingKeys: String, CodingKey {
        case transferID = "transfer_id"
        case jobID = "job_id"
        case sourceID = "source_id"
        case transferToken = "transfer_token"
        case url
        case method
    }
}

private struct HankRemoteTransferUploadResponse: Decodable {
    let ok: Bool
    let path: String
    let size: Int64
    let nextOffset: Int64
    let resumable: Bool

    enum CodingKeys: String, CodingKey {
        case ok
        case path
        case size
        case nextOffset = "next_offset"
        case resumable
    }
}

private struct HankRemoteSocketEnvelope {
    let type: String
    let requestID: String?
    let payload: Data?
    let error: HankRemoteSocketErrorPayload?
}

private struct HankRemoteSocketErrorPayload {
    let code: String
    let message: String
}

private enum HankRemoteSocketLifecycleError: Error {
    case openFailed
}

protocol RemoteTransporting: Sendable {}

final class RemoteTransport: RemoteTransporting, @unchecked Sendable {
    let service: HankRemoteService

    init(service: HankRemoteService) {
        self.service = service
    }
}

final class AuthClient: @unchecked Sendable {
    private let transport: RemoteTransport

    init(transport: RemoteTransport) {
        self.transport = transport
    }

    func register(cloudURL: String, email: String, password: String) async throws -> HankRemoteSessionSummary {
        try await transport.service.register(cloudURL: cloudURL, email: email, password: password)
    }

    func login(cloudURL: String, email: String, password: String) async throws -> HankRemoteSessionSummary {
        try await transport.service.login(cloudURL: cloudURL, email: email, password: password)
    }

    func logout(_ context: HankRemoteConnectionContext) async throws {
        try await transport.service.logout(context)
    }

    func currentSession(_ context: HankRemoteConnectionContext) async throws -> HankRemoteSessionSummary {
        try await transport.service.currentSession(context)
    }
}

final class ProfileClient: @unchecked Sendable {
    private let transport: RemoteTransport

    init(transport: RemoteTransport) {
        self.transport = transport
    }

    func profileSettings(_ context: HankRemoteConnectionContext) async throws -> HankRemoteProfileSettingsRecord {
        try await transport.service.profileSettings(context)
    }

    func profileBackup(_ context: HankRemoteConnectionContext) async throws -> HankRemoteProfileBackupRecord? {
        try await transport.service.profileBackup(context)
    }
}

final class HomeClient: @unchecked Sendable {
    private let transport: RemoteTransport

    init(transport: RemoteTransport) {
        self.transport = transport
    }

    func serviceProfiles(context: HankRemoteConnectionContext) async throws -> [HankRemoteServiceProfile] {
        try await transport.service.listServiceProfiles(context: context)
    }
}

final class AssistantClient: @unchecked Sendable {
    private let transport: RemoteTransport

    init(transport: RemoteTransport) {
        self.transport = transport
    }
}

final class FilesClient: @unchecked Sendable {
    private let transport: RemoteTransport

    init(transport: RemoteTransport) {
        self.transport = transport
    }
}

final class StorageClient: @unchecked Sendable {
    private let transport: RemoteTransport

    init(transport: RemoteTransport) {
        self.transport = transport
    }
}

final class RealtimeClient: @unchecked Sendable {
    private let transport: RemoteTransport

    init(transport: RemoteTransport) {
        self.transport = transport
    }
}

struct HankRemoteRealtimeEvent: Sendable {
    let event: String
    let topic: String?
    let payload: Data?
}

private struct HankRemoteSystemPingRequest: Encodable {
    let message: String?
}

private struct HankRemoteFilesListRequest: Encodable {
    let sourceID: String?
    let path: String

    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case path
    }
}

private struct HankRemoteRealtimeSubscribeRequest: Encodable {
    let topics: [String]
}

private struct HankRemoteRealtimeSubscribeResponse: Decodable {
    let topics: [String]
}

private struct HankRemoteFilesCreateDirectoryRequest: Encodable {
    let sourceID: String?
    let path: String

    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case path
    }
}

private struct HankRemoteFilesRenameRequest: Encodable {
    let sourceID: String?
    let from: String
    let to: String

    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case from
        case to
    }
}

private struct HankRemoteFilesMoveRequest: Encodable {
    let sourceID: String?
    let destinationSourceID: String?
    let from: String
    let to: String
    let isDirectory: Bool

    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case destinationSourceID = "destination_source_id"
        case from
        case to
        case isDirectory = "is_directory"
    }
}

private struct HankRemoteFileOperationJobResponse: Decodable {
    let ok: Bool
    let jobID: String?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case jobID = "job_id"
        case status
    }
}

struct HankRemoteFileOperationJobSnapshot: Decodable, Equatable, Sendable {
    let id: String
    let operation: String
    let sourceID: String
    let destinationSourceID: String
    let fromPath: String
    let toPath: String
    let isDirectory: Bool
    let status: String
    let bytesTotal: Int64
    let bytesDone: Int64
    let filesTotal: Int64
    let filesDone: Int64
    let errorMessage: String
    let createdAt: Date?
    let updatedAt: Date?
    let completedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case operation
        case sourceID = "source_id"
        case destinationSourceID = "destination_source_id"
        case fromPath = "from_path"
        case toPath = "to_path"
        case isDirectory = "is_directory"
        case status
        case bytesTotal = "bytes_total"
        case bytesDone = "bytes_done"
        case filesTotal = "files_total"
        case filesDone = "files_done"
        case errorMessage = "error_message"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case completedAt = "completed_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        operation = try container.decodeIfPresent(String.self, forKey: .operation) ?? ""
        sourceID = try container.decodeIfPresent(String.self, forKey: .sourceID) ?? ""
        destinationSourceID = try container.decodeIfPresent(String.self, forKey: .destinationSourceID) ?? ""
        fromPath = try container.decodeIfPresent(String.self, forKey: .fromPath) ?? ""
        toPath = try container.decodeIfPresent(String.self, forKey: .toPath) ?? ""
        isDirectory = try container.decodeIfPresent(Bool.self, forKey: .isDirectory) ?? false
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        bytesTotal = try container.decodeIfPresent(Int64.self, forKey: .bytesTotal) ?? 0
        bytesDone = try container.decodeIfPresent(Int64.self, forKey: .bytesDone) ?? 0
        filesTotal = try container.decodeIfPresent(Int64.self, forKey: .filesTotal) ?? 0
        filesDone = try container.decodeIfPresent(Int64.self, forKey: .filesDone) ?? 0
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
    }
}

private struct HankRemoteFilesDeleteRequest: Encodable {
    let sourceID: String?
    let path: String
    let isDirectory: Bool

    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case path
        case isDirectory = "is_directory"
    }
}

private struct HankRemoteHomeAssistantHealthResponse: Decodable {
    let ok: Bool
}

private struct HankRemoteHomeAssistantCallServiceRequest: Encodable {
    let domain: String
    let service: String
    let body: [String: AnyEncodable]
}

struct HankRemoteNoteSummary: Decodable, Equatable, Sendable {
    let id: String
    let title: String
    let updatedAt: Date
    let revision: String
    let size: Int64
    let storageKey: String?
    let pageType: String
    let parentID: String?
    let sortOrder: Int
    let bodyFormat: String
    let ownerUserID: String?
    let shared: Bool
    let preview: String
    let tags: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case noteID = "note_id"
        case title
        case updatedAt = "updated_at"
        case revision
        case size
        case storageKey = "storage_key"
        case pageType = "page_type"
        case parentID = "parent_id"
        case sortOrder = "sort_order"
        case bodyFormat = "body_format"
        case ownerUserID = "owner_user_id"
        case shared
        case preview
        case tags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? container.decode(String.self, forKey: .noteID)
        title = try container.decode(String.self, forKey: .title)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        revision = try container.decode(String.self, forKey: .revision)
        size = try container.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        storageKey = try container.decodeIfPresent(String.self, forKey: .storageKey)
        pageType = try container.decodeIfPresent(String.self, forKey: .pageType) ?? "text"
        parentID = try container.decodeIfPresent(String.self, forKey: .parentID)
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        bodyFormat = try container.decodeIfPresent(String.self, forKey: .bodyFormat) ?? "markdown"
        ownerUserID = try container.decodeIfPresent(String.self, forKey: .ownerUserID)
        shared = try container.decodeIfPresent(Bool.self, forKey: .shared) ?? false
        preview = try container.decodeIfPresent(String.self, forKey: .preview) ?? ""
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
    }
}

private struct HankRemoteNotesSyncResponse: Decodable {
    let notes: [HankRemoteNoteSummary]
}

private struct HankRemoteNotesFetchRequest: Encodable {
    let noteID: String

    enum CodingKeys: String, CodingKey {
        case noteID = "note_id"
    }
}

struct HankRemoteNotesFetchResponse: Decodable, Equatable, Sendable {
    let noteID: String
    let title: String
    let content: String
    let bodyMarkdown: String
    let bodyFormat: String
    let revision: String
    let updatedAt: Date
    let pageType: String
    let parentID: String?
    let sortOrder: Int
    let ownerUserID: String?
    let shared: Bool
    let preview: String
    let tags: [String]
    let board: HankRemoteKanbanBoard?

    enum CodingKeys: String, CodingKey {
        case noteID = "note_id"
        case title
        case content
        case bodyMarkdown = "body_markdown"
        case bodyFormat = "body_format"
        case revision
        case updatedAt = "updated_at"
        case pageType = "page_type"
        case parentID = "parent_id"
        case sortOrder = "sort_order"
        case ownerUserID = "owner_user_id"
        case shared
        case preview
        case tags
        case board
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        noteID = try container.decode(String.self, forKey: .noteID)
        title = try container.decode(String.self, forKey: .title)
        let decodedContent = try container.decodeIfPresent(String.self, forKey: .content)
            ?? container.decodeIfPresent(String.self, forKey: .bodyMarkdown)
            ?? ""
        content = decodedContent
        bodyMarkdown = try container.decodeIfPresent(String.self, forKey: .bodyMarkdown) ?? decodedContent
        bodyFormat = try container.decodeIfPresent(String.self, forKey: .bodyFormat) ?? "markdown"
        revision = try container.decode(String.self, forKey: .revision)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        pageType = try container.decodeIfPresent(String.self, forKey: .pageType) ?? "text"
        parentID = try container.decodeIfPresent(String.self, forKey: .parentID)
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        ownerUserID = try container.decodeIfPresent(String.self, forKey: .ownerUserID)
        shared = try container.decodeIfPresent(Bool.self, forKey: .shared) ?? false
        preview = try container.decodeIfPresent(String.self, forKey: .preview) ?? ""
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        board = try container.decodeIfPresent(HankRemoteKanbanBoard.self, forKey: .board)
    }
}

struct HankRemoteNoteAttachment: Decodable, Equatable, Sendable {
    let id: String
    let noteID: String
    let filename: String
    let contentType: String
    let sizeBytes: Int64
    let checksumSHA256: String
    let downloadURL: String?
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case noteID = "note_id"
        case filename
        case contentType = "content_type"
        case sizeBytes = "size_bytes"
        case checksumSHA256 = "checksum_sha256"
        case downloadURL = "download_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct HankRemoteKanbanCard: Codable, Equatable, Sendable {
    let id: String
    let text: String
    let sortOrder: Int
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case text
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct HankRemoteKanbanColumn: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let sortOrder: Int
    let cards: [HankRemoteKanbanCard]
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case sortOrder = "sort_order"
        case cards
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct HankRemoteKanbanBoard: Codable, Equatable, Sendable {
    let columns: [HankRemoteKanbanColumn]
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case columns
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

private struct HankRemoteNotesSaveRequest: Encodable {
    let noteID: String
    let title: String
    let content: String
    let bodyMarkdown: String?
    let bodyFormat: String?
    let expectedRevision: String?
    let pageType: String?
    let parentID: String?
    let sortOrder: Int?
    let board: HankRemoteKanbanBoard?

    enum CodingKeys: String, CodingKey {
        case noteID = "note_id"
        case title
        case content
        case bodyMarkdown = "body_markdown"
        case bodyFormat = "body_format"
        case expectedRevision = "expected_revision"
        case pageType = "page_type"
        case parentID = "parent_id"
        case sortOrder = "sort_order"
        case board
    }
}

struct HankRemoteNotesSaveResponse: Decodable, Equatable, Sendable {
    let noteID: String
    let revision: String
    let updatedAt: Date
    let pageType: String

    enum CodingKeys: String, CodingKey {
        case noteID = "note_id"
        case revision
        case updatedAt = "updated_at"
        case pageType = "page_type"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        noteID = try container.decode(String.self, forKey: .noteID)
        revision = try container.decode(String.self, forKey: .revision)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        pageType = try container.decodeIfPresent(String.self, forKey: .pageType) ?? "text"
    }
}

private struct HankRemoteNotesDeleteRequest: Encodable {
    let noteID: String

    enum CodingKeys: String, CodingKey {
        case noteID = "note_id"
    }
}

private struct HankRemoteNoteCollaborationJoinRequest: Encodable {
    let noteID: String
    let sessionID: String
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case noteID = "note_id"
        case sessionID = "session_id"
        case scope
    }
}

private struct HankRemoteNoteCollaborationLeaveRequest: Encodable {
    let noteID: String
    let sessionID: String
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case noteID = "note_id"
        case sessionID = "session_id"
        case scope
    }
}

private struct HankRemoteNoteCollaborationSyncRequest: Encodable {
    let noteID: String
    let sessionID: String
    let scope: String?
    let afterVersion: Int64
    let maxOperations: Int?

    enum CodingKeys: String, CodingKey {
        case noteID = "note_id"
        case sessionID = "session_id"
        case scope
        case afterVersion = "after_version"
        case maxOperations = "max_operations"
    }
}

struct HankRemoteNoteCollaborationOperation: Codable, Sendable {
    let opID: String
    let type: String
    let field: String?
    let value: AnyDecodable?
    let index: Int?
    let deleteCount: Int?
    let text: String?
    let id: String?
    let parentID: String?
    let toIndex: Int?

    enum CodingKeys: String, CodingKey {
        case opID = "op_id"
        case type
        case field
        case value
        case index
        case deleteCount = "delete_count"
        case text
        case id
        case parentID = "parent_id"
        case toIndex = "to_index"
    }

    init(
        opID: String = UUID().uuidString,
        type: String,
        field: String? = nil,
        value: Any? = nil,
        index: Int? = nil,
        deleteCount: Int? = nil,
        text: String? = nil,
        id: String? = nil,
        parentID: String? = nil,
        toIndex: Int? = nil
    ) {
        self.opID = opID
        self.type = type
        self.field = field
        self.value = value.map { AnyDecodable(value: $0) }
        self.index = index
        self.deleteCount = deleteCount
        self.text = text
        self.id = id
        self.parentID = parentID
        self.toIndex = toIndex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        opID = try container.decode(String.self, forKey: .opID)
        type = try container.decode(String.self, forKey: .type)
        field = try container.decodeIfPresent(String.self, forKey: .field)
        value = try container.decodeIfPresent(AnyDecodable.self, forKey: .value)
        index = try container.decodeIfPresent(Int.self, forKey: .index)
        deleteCount = try container.decodeIfPresent(Int.self, forKey: .deleteCount)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        parentID = try container.decodeIfPresent(String.self, forKey: .parentID)
        toIndex = try container.decodeIfPresent(Int.self, forKey: .toIndex)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(opID, forKey: .opID)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(field, forKey: .field)
        if let value {
            try container.encode(AnyEncodable(jsonValue: value.value), forKey: .value)
        }
        try container.encodeIfPresent(index, forKey: .index)
        try container.encodeIfPresent(deleteCount, forKey: .deleteCount)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(parentID, forKey: .parentID)
        try container.encodeIfPresent(toIndex, forKey: .toIndex)
    }
}

private struct HankRemoteNoteCollaborationSubmitOpsRequest: Encodable {
    let noteID: String
    let sessionID: String
    let scope: String?
    let baseVersion: Int64
    let ops: [HankRemoteNoteCollaborationOperation]

    enum CodingKeys: String, CodingKey {
        case noteID = "note_id"
        case sessionID = "session_id"
        case scope
        case baseVersion = "base_version"
        case ops
    }
}

struct HankRemoteNoteCollaborationAck: Decodable, Equatable, Sendable {
    let noteID: String
    let sessionID: String
    let appliedVersion: Int64
    let acceptedOps: Int
    let revision: String

    enum CodingKeys: String, CodingKey {
        case noteID = "note_id"
        case sessionID = "session_id"
        case appliedVersion = "applied_version"
        case acceptedOps = "accepted_ops"
        case revision
    }
}

struct HankRemoteNoteCollaborationPresenceUser: Decodable, Equatable, Sendable {
    let userID: String
    let sessionID: String
    let joinedAt: Date

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case sessionID = "session_id"
        case joinedAt = "joined_at"
    }
}

struct HankRemoteNoteCollaborationSnapshot: Decodable, Equatable, Sendable {
    let noteID: String
    let appliedVersion: Int64
    let revision: String
    let note: HankRemoteNotesFetchResponse
    let presence: [HankRemoteNoteCollaborationPresenceUser]

    enum CodingKeys: String, CodingKey {
        case noteID = "note_id"
        case appliedVersion = "applied_version"
        case revision
        case note
        case presence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        noteID = try container.decode(String.self, forKey: .noteID)
        appliedVersion = try container.decode(Int64.self, forKey: .appliedVersion)
        revision = try container.decode(String.self, forKey: .revision)
        note = try container.decode(HankRemoteNotesFetchResponse.self, forKey: .note)
        presence = try container.decodeIfPresent([HankRemoteNoteCollaborationPresenceUser].self, forKey: .presence) ?? []
    }
}

struct HankRemoteNoteCollaborationAppliedOperation: Decodable, Sendable {
    let operation: HankRemoteNoteCollaborationOperation
    let actorUserID: String
    let sessionID: String
    let baseVersion: Int64
    let appliedVersion: Int64
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case actorUserID = "actor_user_id"
        case sessionID = "session_id"
        case baseVersion = "base_version"
        case appliedVersion = "applied_version"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        operation = try HankRemoteNoteCollaborationOperation(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        actorUserID = try container.decode(String.self, forKey: .actorUserID)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        baseVersion = try container.decode(Int64.self, forKey: .baseVersion)
        appliedVersion = try container.decode(Int64.self, forKey: .appliedVersion)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}

struct HankRemoteNoteCollaborationOpsEvent: Decodable, Sendable {
    let noteID: String
    let appliedVersion: Int64
    let revision: String
    let ops: [HankRemoteNoteCollaborationAppliedOperation]

    enum CodingKeys: String, CodingKey {
        case noteID = "note_id"
        case appliedVersion = "applied_version"
        case revision
        case ops
    }
}

struct HankRemoteNoteCollaborationPresenceEvent: Decodable, Equatable, Sendable {
    let noteID: String
    let presence: [HankRemoteNoteCollaborationPresenceUser]

    enum CodingKeys: String, CodingKey {
        case noteID = "note_id"
        case presence
    }
}

struct HankRemoteNoteCollaborationRevokedEvent: Decodable, Equatable, Sendable {
    let noteID: String
    let reason: String

    enum CodingKeys: String, CodingKey {
        case noteID = "note_id"
        case reason
    }
}

enum HankRemoteNoteCollaborationSyncResult: Sendable {
    case snapshot(HankRemoteNoteCollaborationSnapshot)
    case ops(HankRemoteNoteCollaborationOpsEvent)
}

enum HankRemoteNoteCollaborationSessionEvent: Sendable {
    case presence(HankRemoteNoteCollaborationPresenceEvent)
    case ops(HankRemoteNoteCollaborationOpsEvent)
    case revoked(HankRemoteNoteCollaborationRevokedEvent)
}

actor HankRemoteNoteCollaborationSession {
    let noteID: String
    let sessionID: String
    let scope: String

    private let context: HankRemoteConnectionContext
    private let service: HankRemoteService
    private let topic: String
    private var appliedVersion: Int64 = 0
    private var eventTask: Task<Void, Never>?
    private var continuation: AsyncStream<HankRemoteNoteCollaborationSessionEvent>.Continuation?

    init(
        noteID: String,
        scope: String = "home",
        context: HankRemoteConnectionContext,
        service: HankRemoteService,
        sessionID: String = UUID().uuidString
    ) {
        self.noteID = noteID
        self.scope = Self.normalizedScope(scope)
        self.context = context
        self.service = service
        self.sessionID = sessionID
        self.topic = Self.topic(noteID: noteID, scope: self.scope)
    }

    func events() -> AsyncStream<HankRemoteNoteCollaborationSessionEvent> {
        AsyncStream { continuation in
            Task {
                self.setContinuation(continuation)
            }
        }
    }

    @discardableResult
    func join() async throws -> HankRemoteNoteCollaborationSnapshot {
        try await service.startRealtime(context: context)
        try await service.subscribeRealtime(topics: [topic], context: context)
        startEventPump()
        let snapshot = try await service.notesCollaborationJoin(
            noteID: noteID,
            sessionID: sessionID,
            scope: scope,
            context: context
        )
        appliedVersion = snapshot.appliedVersion
        return snapshot
    }

    func sync(maxOperations: Int? = nil) async throws -> HankRemoteNoteCollaborationSyncResult {
        let result = try await service.notesCollaborationSync(
            noteID: noteID,
            sessionID: sessionID,
            scope: scope,
            afterVersion: appliedVersion,
            maxOperations: maxOperations,
            context: context
        )
        switch result {
        case .snapshot(let snapshot):
            appliedVersion = snapshot.appliedVersion
        case .ops(let event):
            appliedVersion = max(appliedVersion, event.appliedVersion)
        }
        return result
    }

    func submitTextReplace(_ text: String) async throws -> HankRemoteNoteCollaborationAck {
        try await submit([
            HankRemoteNoteCollaborationOperation(type: "text_replace", text: text)
        ])
    }

    func submitTitle(_ title: String) async throws -> HankRemoteNoteCollaborationAck {
        try await submit([
            HankRemoteNoteCollaborationOperation(type: "set_field", field: "title", value: title)
        ])
    }

    func submit(_ ops: [HankRemoteNoteCollaborationOperation]) async throws -> HankRemoteNoteCollaborationAck {
        let ack = try await service.notesCollaborationSubmitOps(
            noteID: noteID,
            sessionID: sessionID,
            scope: scope,
            baseVersion: appliedVersion,
            ops: ops,
            context: context
        )
        appliedVersion = ack.appliedVersion
        return ack
    }

    func leave() async {
        eventTask?.cancel()
        eventTask = nil
        continuation?.finish()
        continuation = nil
        try? await service.notesCollaborationLeave(noteID: noteID, sessionID: sessionID, scope: scope, context: context)
        try? await service.unsubscribeRealtime(topics: [topic], context: context)
    }

    private func startEventPump() {
        guard eventTask == nil else {
            return
        }

        eventTask = Task { [service, topic] in
            for await event in await service.realtimeEvents() {
                guard !Task.isCancelled else {
                    return
                }
                guard event.topic == topic, let payload = event.payload else {
                    continue
                }
                handleRealtimeEvent(name: event.event, payload: payload)
            }
        }
    }

    private func setContinuation(_ continuation: AsyncStream<HankRemoteNoteCollaborationSessionEvent>.Continuation) {
        self.continuation = continuation
    }

    private func handleRealtimeEvent(name: String, payload: Data) {
        let decoder = JSONDecoder()
        HankRemoteDateCoding.configure(decoder)
        switch name {
        case "notes.collab.presence":
            if let event = try? decoder.decode(HankRemoteNoteCollaborationPresenceEvent.self, from: payload) {
                continuation?.yield(.presence(event))
            }
        case "notes.collab.ops":
            if let event = try? decoder.decode(HankRemoteNoteCollaborationOpsEvent.self, from: payload) {
                appliedVersion = max(appliedVersion, event.appliedVersion)
                continuation?.yield(.ops(event))
            }
        case "notes.collab.revoked":
            if let event = try? decoder.decode(HankRemoteNoteCollaborationRevokedEvent.self, from: payload) {
                continuation?.yield(.revoked(event))
            }
        default:
            break
        }
    }

    private static func normalizedScope(_ scope: String) -> String {
        scope.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "profile" ? "profile" : "home"
    }

    private static func topic(noteID: String, scope: String) -> String {
        if normalizedScope(scope) == "profile" {
            return "notes.collab:profile:\(noteID)"
        }
        return "notes.collab:\(noteID)"
    }
}

struct HankRemoteServiceProfile: Decodable, Equatable, Sendable, Identifiable {
    let homeID: String
    let serviceType: HankRemoteServiceType
    let publicConfigJSON: String
    let secretVersion: Int
    let appliedVersion: Int
    let status: HankRemoteStatusValue
    let updatedAt: Date
    let updatedBy: String
    let lastBackupAt: Date?
    let lastError: String

    var id: HankRemoteServiceType { serviceType }

    enum CodingKeys: String, CodingKey {
        case homeID = "home_id"
        case serviceType = "service_type"
        case publicConfigJSON = "public_config_json"
        case publicConfig = "public_config"
        case secretVersion = "secret_version"
        case appliedVersion = "applied_version"
        case status
        case updatedAt = "updated_at"
        case updatedBy = "updated_by"
        case lastBackupAt = "last_backup_at"
        case lastError = "last_error"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        homeID = try container.decodeIfPresent(String.self, forKey: .homeID) ?? ""
        serviceType = try container.decode(HankRemoteServiceType.self, forKey: .serviceType)
        if let raw = try container.decodeIfPresent(String.self, forKey: .publicConfigJSON) {
            publicConfigJSON = raw
        } else if let object = try container.decodeIfPresent([String: AnyDecodable].self, forKey: .publicConfig) {
            let encoded = try JSONSerialization.data(withJSONObject: object.mapValues(\.value))
            publicConfigJSON = String(decoding: encoded, as: UTF8.self)
        } else {
            publicConfigJSON = ""
        }
        secretVersion = try container.decodeIfPresent(Int.self, forKey: .secretVersion) ?? 0
        appliedVersion = try container.decodeIfPresent(Int.self, forKey: .appliedVersion) ?? 0
        status = try container.decodeIfPresent(HankRemoteStatusValue.self, forKey: .status) ?? .pending
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        updatedBy = try container.decodeIfPresent(String.self, forKey: .updatedBy) ?? ""
        lastBackupAt = try container.decodeIfPresent(Date.self, forKey: .lastBackupAt)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError) ?? ""
    }
}

private struct HankRemoteServiceProfilesResponse: Decodable {
    let profiles: [HankRemoteServiceProfile]
}

private struct HankRemoteNotesConflictEnvelope: Decodable {
    let error: String?
    let current: HankRemoteNotesFetchResponse?
}

private struct HankRemoteTransferRecord: Codable, Sendable {
    let key: String
    let operation: String
    let cloudURL: String
    let sourceID: String
    let path: String
    let url: String
    let transferToken: String
    var nextOffset: Int64
    var updatedAt: Date
}

private actor HankRemoteTransferStateStore {
    private let fileManager = FileManager.default

    func record(for key: String) throws -> HankRemoteTransferRecord? {
        let url = try recordURL(for: key)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(HankRemoteTransferRecord.self, from: Data(contentsOf: url))
        } catch {
            try? fileManager.removeItem(at: url)
            try? removePartialData(for: key)
            return nil
        }
    }

    func save(_ record: HankRemoteTransferRecord) throws {
        let data = try JSONEncoder().encode(record)
        try data.write(to: try recordURL(for: record.key), options: [.atomic])
    }

    func removeRecord(for key: String) throws {
        let url = try recordURL(for: key)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    func resetPartialData(for key: String) throws {
        let url = try partialURL(for: key)
        try Data().write(to: url, options: [.atomic])
    }

    func appendPartialData(_ data: Data, for key: String) throws {
        let url = try partialURL(for: key)
        if !fileManager.fileExists(atPath: url.path) {
            try Data().write(to: url, options: [.atomic])
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    func readPartialData(for key: String) throws -> Data {
        let url = try partialURL(for: key)
        guard fileManager.fileExists(atPath: url.path) else {
            return Data()
        }
        return try Data(contentsOf: url)
    }

    func copyPartialData(for key: String, to destinationURL: URL) throws {
        let sourceURL = try partialURL(for: key)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            try Data().write(to: destinationURL, options: [.atomic])
            return
        }

        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    func removePartialData(for key: String) throws {
        let url = try partialURL(for: key)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func baseDirectory() throws -> URL {
        let directory = try AppFileLocations.applicationSupportDirectory(fileManager: fileManager)
            .appendingPathComponent("HankRemoteTransfers", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func recordURL(for key: String) throws -> URL {
        try baseDirectory().appendingPathComponent(fileComponent(for: key)).appendingPathExtension("json")
    }

    private func partialURL(for key: String) throws -> URL {
        try baseDirectory().appendingPathComponent(fileComponent(for: key)).appendingPathExtension("part")
    }

    private func fileComponent(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void

    init(erasing value: any Encodable) {
        self.encodeValue = { encoder in
            try value.encode(to: encoder)
        }
    }

    init(jsonValue value: Any) {
        switch value {
        case let value as String:
            self.init(erasing: value)
        case let value as Int:
            self.init(erasing: value)
        case let value as Int64:
            self.init(erasing: value)
        case let value as Double:
            self.init(erasing: value)
        case let value as Bool:
            self.init(erasing: value)
        case let value as Date:
            self.init(erasing: value)
        case is NSNull:
            self.init(erasing: Optional<String>.none as String?)
        case let value as [Any]:
            self.init(erasing: value.map { AnyEncodable(jsonValue: $0) })
        case let value as [String: Any]:
            self.init(erasing: value.mapValues { AnyEncodable(jsonValue: $0) })
        case let value as any Encodable:
            self.init(erasing: value)
        default:
            self.init(erasing: String(describing: value))
        }
    }

    func encode(to encoder: Encoder) throws {
        try encodeValue(encoder)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct AnyDecodable: Decodable, @unchecked Sendable {
    let value: Any

    init(value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let array = try? container.decode([AnyDecodable].self) {
            value = array.map(\.value)
        } else if let dictionary = try? container.decode([String: AnyDecodable].self) {
            value = dictionary.mapValues(\.value)
        } else if container.decodeNil() {
            value = NSNull()
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }
}

enum HankRemoteDateCoding {
    private static func standardFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    private static func fractionalFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    static func decode(_ decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if let date = fractionalFormatter().date(from: value) ?? standardFormatter().date(from: value) {
            return date
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Invalid ISO-8601 date: \(value)"
        )
    }

    static func configure(_ decoder: JSONDecoder) {
        decoder.dateDecodingStrategy = .custom(decode)
    }
}

final class HankRemoteService: @unchecked Sendable {
    lazy var transport = RemoteTransport(service: self)
    lazy var authClient = AuthClient(transport: transport)
    lazy var homeClient = HomeClient(transport: transport)
    lazy var profileClient = ProfileClient(transport: transport)
    lazy var assistantClient = AssistantClient(transport: transport)
    lazy var filesClient = FilesClient(transport: transport)
    lazy var storageClient = StorageClient(transport: transport)
    lazy var realtimeClient = RealtimeClient(transport: transport)

    private let transferStateStore = HankRemoteTransferStateStore()
    private let realtimeSocket = HankRemoteRealtimeSocket()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.dropfile.Hank", category: "HankRemote")

    func realtimeEvents() async -> AsyncStream<HankRemoteRealtimeEvent> {
        await realtimeSocket.events()
    }

    func startRealtime(context: HankRemoteConnectionContext) async throws {
        if await realtimeSocket.isConnected(to: context) {
            logger.info("Hank Remote realtime already connected cloud_url=\(context.cloudURL, privacy: .public)")
            return
        }
        let ticket = try await issueAppWebSocketTicket(context: context)
        let websocketPath = ticket.websocketPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "/ws/app?app_ticket=\(ticket.ticket)"
            : ticket.websocketPath
        guard let url = Self.appWebSocketURL(from: context.cloudURL, websocketPath: websocketPath) else {
            throw HankRemoteServiceError.invalidURL
        }
        logger.info("Opening Hank Remote realtime socket cloud_url=\(context.cloudURL, privacy: .public) websocket_path=\(websocketPath, privacy: .public)")
        await realtimeSocket.connect(context: context, url: url)
    }

    func stopRealtime() async {
        logger.info("Stopping Hank Remote realtime socket")
        await realtimeSocket.disconnect()
    }

    func subscribeRealtime(topics: [String], context: HankRemoteConnectionContext) async throws {
        try await startRealtime(context: context)
        logger.info("Subscribing Hank Remote realtime topics=\(topics.joined(separator: ","), privacy: .public)")
        let request = HankRemoteRealtimeSubscribeRequest(topics: topics)
        let _: HankRemoteRealtimeSubscribeResponse = try await sendAppCommand(
            context: context,
            command: "app.subscribe",
            body: request,
            responseType: HankRemoteRealtimeSubscribeResponse.self
        )
    }

    func unsubscribeRealtime(topics: [String], context: HankRemoteConnectionContext) async throws {
        try await startRealtime(context: context)
        logger.info("Unsubscribing Hank Remote realtime topics=\(topics.joined(separator: ","), privacy: .public)")
        let request = HankRemoteRealtimeSubscribeRequest(topics: topics)
        let _: HankRemoteRealtimeSubscribeResponse = try await sendAppCommand(
            context: context,
            command: "app.unsubscribe",
            body: request,
            responseType: HankRemoteRealtimeSubscribeResponse.self
        )
    }

    func validateConnection(
        settings: HankRemoteSettingsSnapshot,
        accessToken: String
    ) async throws -> String? {
        guard let url = healthURL(from: settings.trimmedCloudURL) else {
            throw HankRemoteServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        let trimmedToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedToken.isEmpty {
            request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")
        }

        let payload: HankRemoteHealthResponse = try await send(request, expecting: HankRemoteHealthResponse.self)
        if payload.ok == true {
            if let service = payload.service?.trimmingCharacters(in: .whitespacesAndNewlines), !service.isEmpty {
                return "Connected to \(service)."
            }
            return "Connected to Hank Remote."
        }
        return "Connected to Hank Remote."
    }

    func register(cloudURL: String, email: String, password: String) async throws -> HankRemoteSessionSummary {
        let request = try makeJSONRequest(
            cloudURL: cloudURL,
            path: "/v1/auth/register",
            method: "POST",
            body: ["email": email, "password": password]
        )
        let response: HankRemoteAuthResponse = try await send(request, expecting: HankRemoteAuthResponse.self)
        return HankRemoteSessionSummary(
            user: response.user,
            sessionID: response.sessionID,
            sessionToken: response.sessionToken,
            expiresAt: response.expiresAt
        )
    }

    func login(cloudURL: String, email: String, password: String) async throws -> HankRemoteSessionSummary {
        let request = try makeJSONRequest(
            cloudURL: cloudURL,
            path: "/v1/auth/login",
            method: "POST",
            body: ["email": email, "password": password]
        )
        let response: HankRemoteAuthResponse = try await send(request, expecting: HankRemoteAuthResponse.self)
        return HankRemoteSessionSummary(
            user: response.user,
            sessionID: response.sessionID,
            sessionToken: response.sessionToken,
            expiresAt: response.expiresAt
        )
    }

    func logout(_ context: HankRemoteConnectionContext) async throws {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/auth/logout",
            method: "POST"
        )
        let _: HankRemoteEmptyResponse = try await send(request, expecting: HankRemoteEmptyResponse.self)
    }

    func currentSession(_ context: HankRemoteConnectionContext) async throws -> HankRemoteSessionSummary {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/me",
            method: "GET"
        )
        let response: HankRemoteMeResponse = try await send(request, expecting: HankRemoteMeResponse.self)
        return HankRemoteSessionSummary(
            user: response.user,
            sessionID: response.sessionID,
            sessionToken: context.sessionToken,
            expiresAt: response.expiresAt
        )
    }

    func registerAPNSDevice(
        deviceID: String,
        token: String,
        environment: String,
        bundleID: String,
        enabledCategories: [String],
        context: HankRemoteConnectionContext
    ) async throws {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/me/devices/apns",
            method: "POST",
            body: HankRemoteAPNSDeviceRegistrationRequest(
                deviceID: deviceID,
                token: token,
                environment: environment,
                bundleID: bundleID,
                enabledCategories: enabledCategories
            )
        )
        let _: HankRemoteAPNSDeviceRegistrationResponse = try await send(request, expecting: HankRemoteAPNSDeviceRegistrationResponse.self)
    }

    func unregisterAPNSDevice(
        deviceID: String,
        context: HankRemoteConnectionContext
    ) async throws {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/me/devices/\(Self.pathComponent(deviceID))/apns",
            method: "DELETE"
        )
        let _: HankRemoteEmptyResponse = try await send(request, expecting: HankRemoteEmptyResponse.self)
    }

    func notificationSettings(context: HankRemoteConnectionContext) async throws -> HankRemoteNotificationSettings {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/me/notification-settings",
            method: "GET"
        )
        return try await send(request, expecting: HankRemoteNotificationSettings.self)
    }

    func updateNotificationSettings(
        _ settings: HankRemoteNotificationSettings,
        context: HankRemoteConnectionContext
    ) async throws -> HankRemoteNotificationSettings {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/me/notification-settings",
            method: "PUT",
            body: settings
        )
        return try await send(request, expecting: HankRemoteNotificationSettings.self)
    }

    func profileBackup(_ context: HankRemoteConnectionContext) async throws -> HankRemoteProfileBackupRecord? {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/me/profile-backup",
            method: "GET"
        )
        do {
            return try await send(request, expecting: HankRemoteProfileBackupRecord.self)
        } catch HankRemoteServiceError.notFound {
            return nil
        }
    }

    func saveProfileBackup(
        _ snapshot: ProfileBackupSnapshot,
        expectedRevision: Int?,
        context: HankRemoteConnectionContext
    ) async throws -> HankRemoteProfileBackupRecord {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/me/profile-backup",
            method: "PUT",
            body: HankRemoteProfileBackupSaveRequest(
                expectedRevision: expectedRevision,
                snapshot: snapshot
            )
        )
        return try await send(request, expecting: HankRemoteProfileBackupRecord.self)
    }

    func profileSettings(_ context: HankRemoteConnectionContext) async throws -> HankRemoteProfileSettingsRecord {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/me/profile",
            method: "GET"
        )
        return try await send(request, expecting: HankRemoteProfileSettingsRecord.self)
    }

    func saveProfileSettings<Settings: Encodable & Sendable>(
        settings: Settings,
        expectedRevision: Int?,
        context: HankRemoteConnectionContext
    ) async throws -> HankRemoteProfileSettingsRecord {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/me/profile",
            method: "PUT",
            body: HankRemoteProfileSettingsSaveRequest(
                expectedRevision: expectedRevision,
                settings: settings
            )
        )
        return try await send(request, expecting: HankRemoteProfileSettingsRecord.self)
    }

    func profileSecretVault(_ context: HankRemoteConnectionContext) async throws -> HankRemoteProfileSecretVaultRecord {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/me/profile-secret-vault",
            method: "GET"
        )
        return try await send(request, expecting: HankRemoteProfileSecretVaultRecord.self)
    }

    func saveProfileSecretVault<Vault: Encodable & Sendable>(
        keyID: String,
        vault: Vault,
        expectedRevision: Int?,
        context: HankRemoteConnectionContext
    ) async throws -> HankRemoteProfileSecretVaultRecord {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/me/profile-secret-vault",
            method: "PUT",
            body: HankRemoteProfileSecretVaultSaveRequest(
                expectedRevision: expectedRevision,
                keyID: keyID,
                vault: vault
            )
        )
        return try await send(request, expecting: HankRemoteProfileSecretVaultRecord.self)
    }

    func currentHome(_ context: HankRemoteConnectionContext) async throws -> HankRemoteHome {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home",
            method: "GET"
        )
        return try await send(request, expecting: HankRemoteHome.self)
    }

    func renameHome(name: String, context: HankRemoteConnectionContext) async throws -> HankRemoteHome {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home",
            method: "PUT",
            body: ["name": name]
        )
        return try await send(request, expecting: HankRemoteHome.self)
    }

    func listHomeMembers(context: HankRemoteConnectionContext) async throws -> [HankRemoteHomeMember] {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/members",
            method: "GET"
        )
        let response: HankRemoteHomeMembersResponse = try await send(request, expecting: HankRemoteHomeMembersResponse.self)
        return response.members
    }

    func createHomeInvitation(
        email: String,
        context: HankRemoteConnectionContext
    ) async throws -> HankRemoteHomeInvitationCreateResponse {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/members/invitations",
            method: "POST",
            body: ["email": email]
        )
        return try await send(request, expecting: HankRemoteHomeInvitationCreateResponse.self)
    }

    func revokeHomeInvitation(
        invitationID: String,
        context: HankRemoteConnectionContext
    ) async throws {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/members/invitations/\(Self.pathComponent(invitationID))",
            method: "DELETE"
        )
        let _: HankRemoteEmptyResponse = try await send(request, expecting: HankRemoteEmptyResponse.self)
    }

    func acceptHomeInvitation(
        token: String,
        context: HankRemoteConnectionContext
    ) async throws -> HankRemoteHome {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/invitations/accept",
            method: "POST",
            body: ["token": token]
        )
        let response: HankRemoteHomeAcceptResponse = try await send(request, expecting: HankRemoteHomeAcceptResponse.self)
        return response.home
    }

    func removeHomeMember(
        userID: String,
        context: HankRemoteConnectionContext
    ) async throws {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/members/\(userID)",
            method: "DELETE"
        )
        let _: HankRemoteEmptyResponse = try await send(request, expecting: HankRemoteEmptyResponse.self)
    }

    func updateHomeMemberRole(
        userID: String,
        role: HankRemoteHomeRole,
        context: HankRemoteConnectionContext
    ) async throws -> HankRemoteHomeMember {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/members/\(userID)/role",
            method: "PUT",
            body: ["role": role.rawValue]
        )
        return try await send(request, expecting: HankRemoteHomeMember.self)
    }

    func homePermissions(_ context: HankRemoteConnectionContext) async throws -> HankRemoteHomePermissions {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/permissions",
            method: "GET"
        )
        return try await send(request, expecting: HankRemoteHomePermissions.self)
    }

    func updateHomePermissions(
        homeAssistant: Bool,
        files: Bool,
        notes: Bool,
        context: HankRemoteConnectionContext
    ) async throws -> HankRemoteHomePermissions {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/permissions",
            method: "PUT",
            body: [
                "homeassistant": homeAssistant,
                "files": files,
                "notes": notes
            ]
        )
        return try await send(request, expecting: HankRemoteHomePermissions.self)
    }

    func memberPermissions(
        userID: String,
        context: HankRemoteConnectionContext
    ) async throws -> HankRemoteHomeMemberPermissions {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/members/\(userID)/permissions",
            method: "GET"
        )
        return try await send(request, expecting: HankRemoteHomeMemberPermissions.self)
    }

    func updateMemberPermissions(
        userID: String,
        homeAssistant: Bool?,
        files: Bool?,
        notes: Bool?,
        context: HankRemoteConnectionContext
    ) async throws -> HankRemoteHomeMemberPermissions {
        let body: [String: Any] = [
            "homeassistant": homeAssistant ?? NSNull(),
            "files": files ?? NSNull(),
            "notes": notes ?? NSNull()
        ]
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/members/\(userID)/permissions",
            method: "PUT",
            body: body
        )
        return try await send(request, expecting: HankRemoteHomeMemberPermissions.self)
    }

    func homeSyncStatus(context: HankRemoteConnectionContext) async throws -> HankRemoteHomeSyncStatus {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/sync",
            method: "GET"
        )
        return try await send(request, expecting: HankRemoteHomeSyncStatus.self)
    }

    func homeAgent(_ context: HankRemoteConnectionContext) async throws -> HankRemoteHomeAgent? {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/agent",
            method: "GET"
        )
        let response: HankRemoteHomeAgentResponse = try await send(request, expecting: HankRemoteHomeAgentResponse.self)
        return response.agent
    }

    func listServiceProfiles(context: HankRemoteConnectionContext) async throws -> [HankRemoteServiceProfile] {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/service-profiles",
            method: "GET"
        )
        let response: HankRemoteServiceProfilesResponse = try await send(request, expecting: HankRemoteServiceProfilesResponse.self)
        return response.profiles
    }

    @MainActor
    func updateServiceProfile(
        serviceType: HankRemoteServiceType,
        publicConfig: [String: Any],
        secrets: [String: Any],
        persist: Bool,
        context: HankRemoteConnectionContext
    ) async throws -> HankRemoteServiceProfile {
        var body: [String: Any] = [
            "persist": persist
        ]
        if !publicConfig.isEmpty {
            body["public_config"] = publicConfig
        }
        if !secrets.isEmpty {
            body["secrets"] = secrets
        }
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/service-profiles/\(serviceType.rawValue)",
            method: "PUT",
            body: body
        )
        return try await send(request, expecting: HankRemoteServiceProfile.self)
    }

    func listAgentTokens(context: HankRemoteConnectionContext) async throws -> [HankRemoteAgentToken] {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/agent/tokens",
            method: "GET"
        )
        let response: HankRemoteAgentTokensResponse = try await send(request, expecting: HankRemoteAgentTokensResponse.self)
        return response.tokens
    }

    func createAgentToken(
        agentID: String,
        agentName: String,
        expiresInSeconds: Int?,
        context: HankRemoteConnectionContext
    ) async throws -> HankRemoteIssuedAgentToken {
        var body: [String: Any] = [
            "agent_id": agentID,
            "name": agentName
        ]
        if let expiresInSeconds, expiresInSeconds > 0 {
            body["expires_in_seconds"] = expiresInSeconds
        }
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/agent/tokens",
            method: "POST",
            body: body
        )
        let response: HankRemoteIssuedAgentTokenResponse = try await send(request, expecting: HankRemoteIssuedAgentTokenResponse.self)
        return HankRemoteIssuedAgentToken(
            tokenID: response.tokenID,
            homeID: response.homeID,
            agentID: response.agentID,
            agentName: response.agentName,
            token: response.token,
            expiresAt: response.expiresAt,
            createdAt: response.createdAt,
            agentStatus: response.agentStatus
        )
    }

    func revokeAgentToken(tokenID: String, context: HankRemoteConnectionContext) async throws {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/agent/tokens/\(tokenID)",
            method: "DELETE"
        )
        let _: HankRemoteEmptyResponse = try await send(request, expecting: HankRemoteEmptyResponse.self)
    }

    func storageStatus(context: HankRemoteConnectionContext) async throws -> HankRemoteStorageStatus {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/storage/status",
            method: "GET"
        )
        return try await send(request, expecting: HankRemoteStorageStatus.self)
    }

    func storageConfig(context: HankRemoteConnectionContext) async throws -> HankRemoteStorageConfig {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/storage/config",
            method: "GET"
        )
        return try await send(request, expecting: HankRemoteStorageConfig.self)
    }

    func updateStorageConfig(
        _ config: HankRemoteStorageConfig,
        context: HankRemoteConnectionContext
    ) async throws -> HankRemoteStorageConfig {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/storage/config",
            method: "PUT",
            body: config
        )
        return try await send(request, expecting: HankRemoteStorageConfig.self)
    }

    func storageEvents(context: HankRemoteConnectionContext) async throws -> [HankRemoteStorageEvent] {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/storage/events",
            method: "GET"
        )
        let response = try await send(request, expecting: HankRemoteStorageEventsResponse.self)
        return response.events
    }

    func requestStorageBackup(type: String, context: HankRemoteConnectionContext) async throws {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/storage/backup",
            method: "POST",
            body: HankRemoteStorageBackupRequest(type: type)
        )
        let _: HankRemoteEmptyResponse = try await send(request, expecting: HankRemoteEmptyResponse.self)
    }

    func requestStorageRestoreTest(context: HankRemoteConnectionContext) async throws {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/storage/restore-test",
            method: "POST"
        )
        let _: HankRemoteEmptyResponse = try await send(request, expecting: HankRemoteEmptyResponse.self)
    }

    func requestStoragePrimaryRestore(
        confirmationPhrase: String,
        context: HankRemoteConnectionContext
    ) async throws {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/storage/restore-primary",
            method: "POST",
            body: HankRemoteStorageRestorePrimaryRequest(confirmationPhrase: confirmationPhrase)
        )
        let _: HankRemoteEmptyResponse = try await send(request, expecting: HankRemoteEmptyResponse.self)
    }

    func assistantSessions(context: HankRemoteConnectionContext) async throws -> [HankRemoteAssistantSession] {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/assistant/sessions",
            method: "GET"
        )
        let response: HankRemoteAssistantSessionsResponse = try await send(request, expecting: HankRemoteAssistantSessionsResponse.self)
        return response.sessions
    }

    func createAssistantSession(context: HankRemoteConnectionContext) async throws -> HankRemoteAssistantSession {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/assistant/sessions",
            method: "POST"
        )
        return try await send(request, expecting: HankRemoteAssistantSession.self)
    }

    func assistantSession(
        sessionID: String,
        context: HankRemoteConnectionContext
    ) async throws -> HankRemoteAssistantSession {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/assistant/sessions/\(Self.pathComponent(sessionID))",
            method: "GET"
        )
        return try await send(request, expecting: HankRemoteAssistantSession.self)
    }

    func deleteAssistantSession(
        sessionID: String,
        context: HankRemoteConnectionContext
    ) async throws {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/assistant/sessions/\(Self.pathComponent(sessionID))",
            method: "DELETE"
        )
        let _: HankRemoteEmptyResponse = try await send(request, expecting: HankRemoteEmptyResponse.self)
    }

    func discardAssistantAttachment(
        sessionID: String,
        clientAttachmentID: String,
        context: HankRemoteConnectionContext
    ) async throws {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/assistant/sessions/\(Self.pathComponent(sessionID))/attachments/\(Self.pathComponent(clientAttachmentID))/discard",
            method: "POST"
        )
        let _: HankRemoteEmptyResponse = try await send(request, expecting: HankRemoteEmptyResponse.self)
    }

    func assistantStatus(context: HankRemoteConnectionContext) async throws -> HankRemoteAssistantStatus {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/assistant/status",
            method: "GET"
        )
        return try await send(request, expecting: HankRemoteAssistantStatus.self)
    }

    func assistantSettings(context: HankRemoteConnectionContext) async throws -> HankRemoteAssistantSettingsResponse {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/assistant/settings",
            method: "GET"
        )
        return try await send(request, expecting: HankRemoteAssistantSettingsResponse.self)
    }

    func installedApps(context: HankRemoteConnectionContext) async throws -> [HankRemoteInstalledApp] {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/apps",
            method: "GET"
        )
        let response = try await send(request, expecting: HankRemoteInstalledAppsResponse.self)
        return response.apps
    }

    func updateAssistantSettings(
        _ settings: HankRemoteAssistantSettingsUpdate,
        context: HankRemoteConnectionContext
    ) async throws -> HankRemoteAssistantSettingsResponse {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/assistant/settings",
            method: "PUT",
            body: settings
        )
        return try await send(request, expecting: HankRemoteAssistantSettingsResponse.self)
    }

    func openAIAccountStatus(context: HankRemoteConnectionContext) async throws -> HankRemoteOpenAIAccountStatus {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/oauth/openai/status",
            method: "GET"
        )
        return try await send(request, expecting: HankRemoteOpenAIAccountStatus.self)
    }

    func startOpenAIAccountLink(context: HankRemoteConnectionContext) async throws -> HankRemoteOpenAIAccountLinkStart {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/oauth/openai/start",
            method: "GET"
        )
        return try await send(request, expecting: HankRemoteOpenAIAccountLinkStart.self)
    }

    func assistantMessages(
        sessionID: String,
        context: HankRemoteConnectionContext
    ) async throws -> [HankRemoteAssistantMessage] {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/assistant/sessions/\(sessionID)/messages",
            method: "GET"
        )
        let response: HankRemoteAssistantMessagesResponse = try await send(request, expecting: HankRemoteAssistantMessagesResponse.self)
        return response.messages
    }

    func sendAssistantMessage(
        sessionID: String,
        content: String,
        attachments: [HankRemoteAssistantAttachmentUpload] = [],
        deviceID: String,
        timezone: String,
        context: HankRemoteConnectionContext
    ) async throws -> HankRemoteAssistantRun {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/assistant/sessions/\(sessionID)/messages",
            method: "POST",
            body: HankRemoteAssistantMessageCreateRequest(
                content: content,
                attachments: attachments,
                deviceContext: HankRemoteAssistantDeviceContext(
                    deviceID: deviceID,
                    timezone: timezone
                )
            )
        )
        if let response = try? await send(request, expecting: HankRemoteAssistantRunResponse.self) {
            return response.run
        }
        return try await send(request, expecting: HankRemoteAssistantRun.self)
    }

    func assistantRun(
        runID: String,
        context: HankRemoteConnectionContext
    ) async throws -> HankRemoteAssistantRun {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/assistant/runs/\(runID)",
            method: "GET"
        )
        if let response = try? await send(request, expecting: HankRemoteAssistantRunResponse.self) {
            return response.run
        }
        return try await send(request, expecting: HankRemoteAssistantRun.self)
    }

    @MainActor
    func submitAssistantClientToolResult(
        runID: String,
        toolName: String,
        result: [String: Any],
        context: HankRemoteConnectionContext
    ) async throws -> HankRemoteAssistantRun {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/assistant/runs/\(runID)/client-tool-results",
            method: "POST",
            body: HankRemoteAssistantClientToolResultsPayload(
                results: [
                    HankRemoteAssistantClientToolResultPayload(
                        toolName: toolName,
                        result: result.mapValues { AnyEncodable(jsonValue: $0) },
                        error: nil
                    )
                ]
            )
        )
        if let response = try? await send(request, expecting: HankRemoteAssistantRunResponse.self) {
            return response.run
        }
        return try await send(request, expecting: HankRemoteAssistantRun.self)
    }

    @MainActor
    func uploadAssistantCalendarIndex(
        deviceID: String,
        entries: [[String: Any]],
        context: HankRemoteConnectionContext
    ) async throws {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/assistant/calendar-index",
            method: "PUT",
            body: HankRemoteAssistantCalendarIndexRequest(
                deviceID: deviceID,
                entries: entries.map { $0.mapValues { AnyEncodable(jsonValue: $0) } }
            )
        )
        let _: HankRemoteEmptyResponse = try await send(request, expecting: HankRemoteEmptyResponse.self)
    }

    func confirmAssistantRun(
        runID: String,
        approved: Bool,
        context: HankRemoteConnectionContext
    ) async throws -> HankRemoteAssistantRun {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/assistant/runs/\(runID)/confirm",
            method: "POST",
            body: HankRemoteAssistantRunConfirmRequest(approved: approved)
        )
        if let response = try? await send(request, expecting: HankRemoteAssistantRunResponse.self) {
            return response.run
        }
        return try await send(request, expecting: HankRemoteAssistantRun.self)
    }

    func submitAssistantClientToolResults(
        runID: String,
        results: [(toolName: String, result: [String: Any], error: String?)],
        context: HankRemoteConnectionContext
    ) async throws -> HankRemoteAssistantRun {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/assistant/runs/\(runID)/client-tool-results",
            method: "POST",
            body: HankRemoteAssistantClientToolResultsPayload(
                results: results.map {
                    HankRemoteAssistantClientToolResultPayload(
                        toolName: $0.toolName,
                        result: $0.result.mapValues { AnyEncodable(jsonValue: $0) },
                        error: $0.error
                    )
                }
            )
        )
        if let response = try? await send(request, expecting: HankRemoteAssistantRunResponse.self) {
            return response.run
        }
        return try await send(request, expecting: HankRemoteAssistantRun.self)
    }

    func uploadAssistantCalendarIndex(
        entries: [HankRemoteAssistantCalendarIndexEntry],
        deviceID: String,
        timezone: String,
        context: HankRemoteConnectionContext
    ) async throws {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/assistant/calendar-index",
            method: "PUT",
            body: HankRemoteAssistantCalendarIndexUploadRequest(
                deviceID: deviceID,
                timezone: timezone,
                entries: entries
            )
        )
        let _: HankRemoteEmptyResponse = try await send(request, expecting: HankRemoteEmptyResponse.self)
    }

    func ping(_ context: HankRemoteConnectionContext, message: String? = nil) async throws -> HankRemotePingResponse {
        try await sendAppCommand(
            context: context,
            command: "system.ping",
            body: HankRemoteSystemPingRequest(message: message),
            responseType: HankRemotePingResponse.self
        )
    }

    func homeAssistantHealth(_ context: HankRemoteConnectionContext) async throws -> Bool {
        do {
            let response = try await sendAppCommand(
                context: context,
                command: "homeassistant.health",
                responseType: HankRemoteHomeAssistantHealthResponse.self
            )
            return response.ok
        } catch {
            throw mappedPermissionError(error, feature: .homeAssistant)
        }
    }

    func homeAssistantFetchStates(_ context: HankRemoteConnectionContext) async throws -> [[String: Any]] {
        let object: [String: Any]
        do {
            object = try await sendAppJSONObject(
                context: context,
                command: "homeassistant.fetch_states"
            )
        } catch {
            throw mappedPermissionError(error, feature: .homeAssistant)
        }
        guard let states = object["states"] as? [[String: Any]] else {
            throw HankRemoteServiceError.invalidResponse
        }
        return states
    }

    func homeAssistantCallService(
        domain: String,
        service: String,
        body: [String: Any],
        context: HankRemoteConnectionContext
    ) async throws {
        do {
            let _: [String: Any] = try await sendAppJSONObject(
                context: context,
                command: "homeassistant.call_service",
                body: HankRemoteHomeAssistantCallServiceRequest(
                    domain: domain,
                    service: service,
                    body: body.mapValues { AnyEncodable(jsonValue: $0) }
                )
            )
        } catch {
            throw mappedPermissionError(error, feature: .homeAssistant)
        }
    }

    func notesSync(_ context: HankRemoteConnectionContext) async throws -> [HankRemoteNoteSummary] {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/notes",
            method: "GET"
        )
        let response: HankRemoteNotesSyncResponse
        do {
            response = try await send(request, expecting: HankRemoteNotesSyncResponse.self)
        } catch {
            throw mappedPermissionError(error, feature: .sharedNotes)
        }
        return response.notes
    }

    func notesFetch(noteID: String, context: HankRemoteConnectionContext) async throws -> HankRemoteNotesFetchResponse {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/notes/\(Self.pathComponent(noteID))",
            method: "GET"
        )
        do {
            return try await send(request, expecting: HankRemoteNotesFetchResponse.self)
        } catch {
            throw mappedPermissionError(error, feature: .sharedNotes)
        }
    }

    func notesSave(
        noteID: String,
        title: String,
        content: String,
        expectedRevision: String?,
        bodyMarkdown: String? = nil,
        bodyFormat: String? = nil,
        pageType: String? = nil,
        parentID: String? = nil,
        sortOrder: Int? = nil,
        board: HankRemoteKanbanBoard? = nil,
        context: HankRemoteConnectionContext
    ) async throws -> HankRemoteNotesSaveResponse {
        var body: [String: Any] = [
            "title": title,
            "content": content
        ]
        if let expectedRevision, !expectedRevision.isEmpty {
            body["expected_revision"] = expectedRevision
        }
        if let bodyMarkdown {
            body["body_markdown"] = bodyMarkdown
        }
        if let bodyFormat, !bodyFormat.isEmpty {
            body["body_format"] = bodyFormat
        }
        if let pageType, !pageType.isEmpty {
            body["page_type"] = pageType
        }
        if let parentID {
            body["parent_id"] = parentID
        }
        if let sortOrder {
            body["sort_order"] = sortOrder
        }
        if let board {
            body["board"] = try jsonObject(from: board)
        }
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/notes/\(Self.pathComponent(noteID))",
            method: "PUT",
            body: body
        )
        do {
            return try await send(request, expecting: HankRemoteNotesSaveResponse.self)
        } catch {
            throw mappedPermissionError(error, feature: .sharedNotes)
        }
    }

    func notesDelete(noteID: String, context: HankRemoteConnectionContext) async throws {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/notes/\(Self.pathComponent(noteID))",
            method: "DELETE"
        )
        do {
            let _: HankRemoteEmptyResponse = try await send(request, expecting: HankRemoteEmptyResponse.self)
        } catch {
            throw mappedPermissionError(error, feature: .sharedNotes)
        }
    }

    func profileNotesSync(_ context: HankRemoteConnectionContext) async throws -> [HankRemoteNoteSummary] {
        logger.info("Fetching Hank Remote profile notes list")
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/me/notes",
            method: "GET"
        )
        let response: HankRemoteNotesSyncResponse = try await send(request, expecting: HankRemoteNotesSyncResponse.self)
        logger.info("Fetched Hank Remote profile notes list note_count=\(response.notes.count, privacy: .public)")
        return response.notes
    }

    func profileNotesFetch(noteID: String, context: HankRemoteConnectionContext) async throws -> HankRemoteNotesFetchResponse {
        logger.info("Fetching Hank Remote profile note note_id=\(noteID, privacy: .public)")
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/me/notes/\(Self.pathComponent(noteID))",
            method: "GET"
        )
        return try await send(request, expecting: HankRemoteNotesFetchResponse.self)
    }

    func uploadNoteAttachment(
        scope: String,
        noteID: String,
        fileAt localURL: URL,
        filename: String,
        contentType: String,
        context: HankRemoteConnectionContext
    ) async throws -> HankRemoteNoteAttachment {
        let basePath: String
        if scope == "home" {
            basePath = "/v1/home/notes/\(Self.pathComponent(noteID))/attachments"
        } else {
            basePath = "/v1/me/notes/\(Self.pathComponent(noteID))/attachments"
        }
        var request = try makeAuthenticatedRequest(
            context: context,
            path: basePath,
            method: "POST"
        )
        request.setValue(filename, forHTTPHeaderField: "X-Hank-Filename")
        request.setValue(contentType.isEmpty ? "application/octet-stream" : contentType, forHTTPHeaderField: "Content-Type")
        return try await upload(localURL, with: request, expecting: HankRemoteNoteAttachment.self)
    }

    func downloadNoteAttachment(
        scope: String,
        noteID: String,
        attachmentID: String,
        to localURL: URL,
        context: HankRemoteConnectionContext
    ) async throws {
        let basePath: String
        if scope == "home" {
            basePath = "/v1/home/notes/\(Self.pathComponent(noteID))/attachments/\(Self.pathComponent(attachmentID))"
        } else {
            basePath = "/v1/me/notes/\(Self.pathComponent(noteID))/attachments/\(Self.pathComponent(attachmentID))"
        }
        let request = try makeAuthenticatedRequest(context: context, path: basePath, method: "GET")
        let (data, response) = try await sendRaw(request)
        guard let http = response as? HTTPURLResponse else {
            throw HankRemoteServiceError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw decodedError(from: data, statusCode: http.statusCode)
        }
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: localURL, options: .atomic)
    }

    func deleteNoteAttachment(
        scope: String,
        noteID: String,
        attachmentID: String,
        context: HankRemoteConnectionContext
    ) async throws {
        let basePath: String
        if scope == "home" {
            basePath = "/v1/home/notes/\(Self.pathComponent(noteID))/attachments/\(Self.pathComponent(attachmentID))"
        } else {
            basePath = "/v1/me/notes/\(Self.pathComponent(noteID))/attachments/\(Self.pathComponent(attachmentID))"
        }
        let request = try makeAuthenticatedRequest(context: context, path: basePath, method: "DELETE")
        let _: HankRemoteEmptyResponse = try await send(request, expecting: HankRemoteEmptyResponse.self)
    }

    func profileNotesSave(
        noteID: String,
        title: String,
        content: String,
        expectedRevision: String?,
        bodyMarkdown: String? = nil,
        bodyFormat: String? = nil,
        pageType: String? = nil,
        parentID: String? = nil,
        sortOrder: Int? = nil,
        board: HankRemoteKanbanBoard? = nil,
        context: HankRemoteConnectionContext
    ) async throws -> HankRemoteNotesSaveResponse {
        logger.info("Saving Hank Remote profile note note_id=\(noteID, privacy: .public) expected_revision=\((expectedRevision ?? ""), privacy: .public)")
        var body: [String: Any] = [
            "title": title,
            "content": content
        ]
        if let expectedRevision, !expectedRevision.isEmpty {
            body["expected_revision"] = expectedRevision
        }
        if let bodyMarkdown {
            body["body_markdown"] = bodyMarkdown
        }
        if let bodyFormat, !bodyFormat.isEmpty {
            body["body_format"] = bodyFormat
        }
        if let pageType, !pageType.isEmpty {
            body["page_type"] = pageType
        }
        if let parentID {
            body["parent_id"] = parentID
        }
        if let sortOrder {
            body["sort_order"] = sortOrder
        }
        if let board {
            body["board"] = try jsonObject(from: board)
        }
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/me/notes/\(Self.pathComponent(noteID))",
            method: "PUT",
            body: body
        )
        let response = try await send(request, expecting: HankRemoteNotesSaveResponse.self)
        logger.info("Saved Hank Remote profile note note_id=\(response.noteID, privacy: .public) revision=\(response.revision, privacy: .public)")
        return response
    }

    func profileNotesDelete(noteID: String, context: HankRemoteConnectionContext) async throws {
        logger.info("Deleting Hank Remote profile note note_id=\(noteID, privacy: .public)")
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/me/notes/\(Self.pathComponent(noteID))",
            method: "DELETE"
        )
        let _: HankRemoteEmptyResponse = try await send(request, expecting: HankRemoteEmptyResponse.self)
    }

    func notesCollaborationJoin(
        noteID: String,
        sessionID: String,
        scope: String = "home",
        context: HankRemoteConnectionContext
    ) async throws -> HankRemoteNoteCollaborationSnapshot {
        try await sendAppCommand(
            context: context,
            command: "notes.collab.join",
            body: HankRemoteNoteCollaborationJoinRequest(noteID: noteID, sessionID: sessionID, scope: scope),
            responseType: HankRemoteNoteCollaborationSnapshot.self
        )
    }

    func notesCollaborationLeave(
        noteID: String,
        sessionID: String,
        scope: String = "home",
        context: HankRemoteConnectionContext
    ) async throws {
        let _: HankRemoteEmptyResponse = try await sendAppCommand(
            context: context,
            command: "notes.collab.leave",
            body: HankRemoteNoteCollaborationLeaveRequest(noteID: noteID, sessionID: sessionID, scope: scope),
            responseType: HankRemoteEmptyResponse.self
        )
    }

    func notesCollaborationSync(
        noteID: String,
        sessionID: String,
        scope: String = "home",
        afterVersion: Int64,
        maxOperations: Int? = nil,
        context: HankRemoteConnectionContext
    ) async throws -> HankRemoteNoteCollaborationSyncResult {
        let request = HankRemoteNoteCollaborationSyncRequest(
            noteID: noteID,
            sessionID: sessionID,
            scope: scope,
            afterVersion: afterVersion,
            maxOperations: maxOperations
        )
        let object = try await sendAppJSONObject(
            context: context,
            command: "notes.collab.sync",
            body: request
        )
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        HankRemoteDateCoding.configure(decoder)
        if let snapshot = try? decoder.decode(HankRemoteNoteCollaborationSnapshot.self, from: data) {
            return .snapshot(snapshot)
        }
        return .ops(try decoder.decode(HankRemoteNoteCollaborationOpsEvent.self, from: data))
    }

    func notesCollaborationSubmitOps(
        noteID: String,
        sessionID: String,
        scope: String = "home",
        baseVersion: Int64,
        ops: [HankRemoteNoteCollaborationOperation],
        context: HankRemoteConnectionContext
    ) async throws -> HankRemoteNoteCollaborationAck {
        try await sendAppCommand(
            context: context,
            command: "notes.collab.submit_ops",
            body: HankRemoteNoteCollaborationSubmitOpsRequest(
                noteID: noteID,
                sessionID: sessionID,
                scope: scope,
                baseVersion: baseVersion,
                ops: ops
            ),
            responseType: HankRemoteNoteCollaborationAck.self
        )
    }

    func listFiles(
        path: String,
        sourceID: String? = nil,
        context: HankRemoteConnectionContext
    ) async throws -> [SMBItem] {
        let response: HankRemoteFileListResponse
        do {
            response = try await sendAppCommand(
                context: context,
                command: "files.list",
                body: HankRemoteFilesListRequest(sourceID: Self.normalizedSourceID(sourceID), path: path),
                responseType: HankRemoteFileListResponse.self
            )
        } catch {
            throw mappedPermissionError(error, feature: .files)
        }
        return response.items
            .map(\.smbItem)
            .sorted {
                if $0.isDirectory != $1.isDirectory {
                    return $0.isDirectory && !$1.isDirectory
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    func createDirectory(
        path: String,
        sourceID: String? = nil,
        context: HankRemoteConnectionContext
    ) async throws {
        do {
            let _: HankRemoteEmptyResponse = try await sendAppCommand(
                context: context,
                command: "files.create_directory",
                body: HankRemoteFilesCreateDirectoryRequest(sourceID: Self.normalizedSourceID(sourceID), path: path),
                responseType: HankRemoteEmptyResponse.self
            )
        } catch {
            throw mappedPermissionError(error, feature: .files)
        }
    }

    func renameFile(
        from: String,
        to: String,
        sourceID: String? = nil,
        context: HankRemoteConnectionContext
    ) async throws {
        do {
            let _: HankRemoteEmptyResponse = try await sendAppCommand(
                context: context,
                command: "files.rename",
                body: HankRemoteFilesRenameRequest(sourceID: Self.normalizedSourceID(sourceID), from: from, to: to),
                responseType: HankRemoteEmptyResponse.self
            )
        } catch {
            throw mappedPermissionError(error, feature: .files)
        }
    }

    func moveFile(
        from: String,
        to: String,
        isDirectory: Bool,
        sourceID: String? = nil,
        destinationSourceID: String? = nil,
        context: HankRemoteConnectionContext
    ) async throws {
        let normalizedSourceID = Self.normalizedSourceID(sourceID)
        do {
            let response: HankRemoteFileOperationJobResponse = try await sendAppCommand(
                context: context,
                command: "files.move",
                body: HankRemoteFilesMoveRequest(
                    sourceID: normalizedSourceID,
                    destinationSourceID: Self.normalizedSourceID(destinationSourceID) ?? normalizedSourceID,
                    from: from,
                    to: to,
                    isDirectory: isDirectory
                ),
                responseType: HankRemoteFileOperationJobResponse.self
            )
            guard response.ok else {
                throw HankRemoteServiceError.invalidResponse
            }
            if
                (response.status?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
                response.jobID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
            {
                return
            }
            try Self.validateSuccessfulFileOperationStatus(response.status, errorMessage: nil)
            if !Self.isTerminalFileOperationJobStatus(response.status) {
                guard let jobID = response.jobID?.trimmingCharacters(in: .whitespacesAndNewlines), !jobID.isEmpty else {
                    throw HankRemoteServiceError.invalidResponse
                }
                let job = try await waitForFileOperationJob(jobID: jobID, context: context)
                try Self.validateSuccessfulFileOperationStatus(job.status, errorMessage: job.errorMessage)
            }
        } catch {
            throw mappedPermissionError(error, feature: .files)
        }
    }

    static func isTerminalFileOperationJobStatus(_ status: String?) -> Bool {
        switch normalizedFileOperationStatus(status) {
        case "completed", "failed", "cancelled", "canceled", "rollback_required", "rolled_back":
            return true
        default:
            return false
        }
    }

    static func fileOperationFailureMessage(status: String?, errorMessage: String?) -> String? {
        let message = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch normalizedFileOperationStatus(status) {
        case "failed":
            return message.isEmpty ? "File operation failed." : message
        case "cancelled", "canceled":
            return message.isEmpty ? "File operation was cancelled." : message
        case "rollback_required":
            return message.isEmpty ? "File operation needs rollback before trying again." : message
        case "rolled_back":
            return message.isEmpty ? "File operation was rolled back." : message
        default:
            return nil
        }
    }

    private static func normalizedFileOperationStatus(_ status: String?) -> String {
        status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    private static func validateSuccessfulFileOperationStatus(_ status: String?, errorMessage: String?) throws {
        if let message = fileOperationFailureMessage(status: status, errorMessage: errorMessage) {
            throw HankRemoteServiceError.server(message)
        }
    }

    private func fileOperationJob(jobID: String, context: HankRemoteConnectionContext) async throws -> HankRemoteFileOperationJobSnapshot {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/home/file-jobs/\(Self.pathComponent(jobID))",
            method: "GET"
        )
        return try await send(request, expecting: HankRemoteFileOperationJobSnapshot.self)
    }

    private func waitForFileOperationJob(
        jobID: String,
        context: HankRemoteConnectionContext,
        timeout: TimeInterval = 600
    ) async throws -> HankRemoteFileOperationJobSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        var pollDelay: UInt64 = 250_000_000
        while true {
            try Task.checkCancellation()
            let job = try await fileOperationJob(jobID: jobID, context: context)
            if Self.isTerminalFileOperationJobStatus(job.status) {
                return job
            }
            if Date() >= deadline {
                throw HankRemoteServiceError.server("The file operation is still running. Check File Server again in a moment.")
            }
            try await Task.sleep(nanoseconds: pollDelay)
            pollDelay = min(pollDelay * 2, 2_000_000_000)
        }
    }

    func deleteFile(
        path: String,
        isDirectory: Bool,
        sourceID: String? = nil,
        context: HankRemoteConnectionContext
    ) async throws {
        do {
            let _: HankRemoteEmptyResponse = try await sendAppCommand(
                context: context,
                command: "files.delete",
                body: HankRemoteFilesDeleteRequest(
                    sourceID: Self.normalizedSourceID(sourceID),
                    path: path,
                    isDirectory: isDirectory
                ),
                responseType: HankRemoteEmptyResponse.self
            )
        } catch {
            throw mappedPermissionError(error, feature: .files)
        }
    }

    func downloadFile(
        path: String,
        sourceID: String? = nil,
        context: HankRemoteConnectionContext
    ) async throws -> Data {
        let temporaryURL = try makeTransferTemporaryFileURL(prefix: "download")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try await downloadFile(path: path, sourceID: sourceID, to: temporaryURL, context: context)
        return try Data(contentsOf: temporaryURL)
    }

    func downloadFile(
        path: String,
        sourceID: String? = nil,
        to localURL: URL,
        context: HankRemoteConnectionContext
    ) async throws {
        let normalizedSourceID = Self.normalizedSourceID(sourceID)
        let key = transferKey(operation: "download", sourceID: normalizedSourceID, path: path, context: context)
        var record = try await existingOrNewTransferRecord(
            key: key,
            operation: "download",
            sourceID: normalizedSourceID,
            path: path,
            operationPath: "/v1/home/files/downloads",
            requestedSize: nil,
            context: context
        )
        if record.nextOffset == 0 {
            try await transferStateStore.resetPartialData(for: key)
        }

        var lastError: Error?
        for _ in 0 ..< 4 {
            do {
                let request = try makeTransferRequest(
                    urlValue: record.url,
                    cloudURL: context.cloudURL,
                    transferToken: record.transferToken,
                    method: "GET",
                    offset: record.nextOffset
                )
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw HankRemoteServiceError.invalidResponse
                }

                if http.statusCode == 404 {
                    try await clearTransferState(for: key)
                    record = try await createTransferRecord(
                        key: key,
                        operation: "download",
                        sourceID: normalizedSourceID,
                        path: path,
                        operationPath: "/v1/home/files/downloads",
                        requestedSize: nil,
                        context: context,
                        nextOffset: 0
                    )
                    try await transferStateStore.resetPartialData(for: key)
                    continue
                }

                if http.statusCode == 409 {
                    let body = try await collect(bytes)
                    if let nextOffset = nextTransferOffset(from: body) {
                        record.nextOffset = nextOffset
                        record.updatedAt = .now
                        try await transferStateStore.save(record)
                        continue
                    }
                    throw decodedError(from: body, statusCode: http.statusCode)
                }

                guard (200 ..< 300).contains(http.statusCode) else {
                    let body = try await collect(bytes)
                    throw decodedError(from: body, statusCode: http.statusCode)
                }

                var chunk = Data()
                for try await byte in bytes {
                    chunk.append(byte)
                    if chunk.count >= 256 * 1024 {
                        try await transferStateStore.appendPartialData(chunk, for: key)
                        record.nextOffset += Int64(chunk.count)
                        record.updatedAt = .now
                        try await transferStateStore.save(record)
                        chunk.removeAll(keepingCapacity: true)
                    }
                }
                if !chunk.isEmpty {
                    try await transferStateStore.appendPartialData(chunk, for: key)
                    record.nextOffset += Int64(chunk.count)
                    record.updatedAt = .now
                    try await transferStateStore.save(record)
                }

                try await transferStateStore.copyPartialData(for: key, to: localURL)
                try await clearTransferState(for: key)
                return
            } catch {
                lastError = error
            }
        }

        throw lastError ?? HankRemoteServiceError.unreachableHost
    }

    func uploadFile(
        data: Data,
        path: String,
        sourceID: String? = nil,
        context: HankRemoteConnectionContext
    ) async throws {
        let temporaryURL = try makeTransferTemporaryFileURL(prefix: "upload")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try data.write(to: temporaryURL, options: [.atomic])
        try await uploadFile(fileAt: temporaryURL, path: path, sourceID: sourceID, context: context)
    }

    func uploadFile(
        fileAt localURL: URL,
        path: String,
        sourceID: String? = nil,
        context: HankRemoteConnectionContext
    ) async throws {
        let normalizedSourceID = Self.normalizedSourceID(sourceID)
        let fileSize = try localFileSize(at: localURL)
        let key = transferKey(operation: "upload", sourceID: normalizedSourceID, path: path, context: context)
        var record = try await existingOrNewTransferRecord(
            key: key,
            operation: "upload",
            sourceID: normalizedSourceID,
            path: path,
            operationPath: "/v1/home/files/uploads",
            requestedSize: fileSize,
            context: context
        )
        let chunkSize = 256 * 1024

        var lastError: Error?
        for _ in 0 ..< 5 {
            do {
                let offset = max(0, min(record.nextOffset, fileSize))
                let payload = try readUploadChunk(from: localURL, offset: offset, maximumLength: chunkSize)
                var request = try makeTransferRequest(
                    urlValue: record.url,
                    cloudURL: context.cloudURL,
                    transferToken: record.transferToken,
                    method: "PUT",
                    offset: offset
                )
                request.httpBody = payload

                let (responseData, response) = try await sendRaw(request)
                guard let http = response as? HTTPURLResponse else {
                    throw HankRemoteServiceError.invalidResponse
                }

                if http.statusCode == 404 {
                    try await clearTransferState(for: key)
                    record = try await createTransferRecord(
                        key: key,
                        operation: "upload",
                        sourceID: normalizedSourceID,
                        path: path,
                        operationPath: "/v1/home/files/uploads",
                        requestedSize: fileSize,
                        context: context,
                        nextOffset: 0
                    )
                    continue
                }

                if http.statusCode == 409, let nextOffset = nextTransferOffset(from: responseData) {
                    record.nextOffset = nextOffset
                    record.updatedAt = .now
                    try await transferStateStore.save(record)
                    continue
                }

                guard (200 ..< 300).contains(http.statusCode) else {
                    throw decodedError(from: responseData, statusCode: http.statusCode)
                }

                if offset + Int64(payload.count) < fileSize {
                    record.nextOffset = offset + Int64(payload.count)
                    record.updatedAt = .now
                    try await transferStateStore.save(record)
                    continue
                }

                let responsePayload = try decoder.decode(HankRemoteTransferUploadResponse.self, from: responseData)
                guard responsePayload.ok else {
                    throw HankRemoteServiceError.invalidResponse
                }
                try await clearTransferState(for: key)
                return
            } catch {
                lastError = error
            }
        }

        throw lastError ?? HankRemoteServiceError.unreachableHost
    }

    static func normalizedCloudURL(from value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard
            let components = URLComponents(string: candidate),
            let scheme = components.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            components.host?.isEmpty == false
        else {
            return nil
        }

        return components.string ?? candidate
    }

    static func normalizedSourceID(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static func inferredRemoteSourceID(from details: SMBConnectionDetails) -> String? {
        if let explicit = normalizedSourceID(details.remoteSourceID) {
            return explicit
        }

        let seed = details.shareName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !seed.isEmpty, details.trimmedHost.lowercased() != "hank-remote" else {
            return nil
        }

        var output = ""
        var previousWasSeparator = false
        for scalar in seed.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "." {
                output.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                output.append("-")
                previousWasSeparator = true
            }
        }

        let trimmed = output.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? nil : trimmed
    }

    static func appCommandEnvelope(
        command: String,
        bodyData: Data?,
        requestID: String,
        timestamp: String
    ) throws -> [String: Any] {
        var payload: [String: Any] = ["command": command]
        if let bodyData {
            payload["body"] = try JSONSerialization.jsonObject(with: bodyData)
        }
        return [
            "version": "v1",
            "type": "app.command",
            "request_id": requestID,
            "timestamp": timestamp,
            "payload": payload
        ]
    }

    static func transferCacheKey(operation: String, cloudURL: String, sourceID: String? = nil, path: String) -> String {
        "singleton|\(operation)|\(cloudURL)|\(normalizedSourceID(sourceID) ?? "")|\(path)"
    }

    private func startTransfer(
        context: HankRemoteConnectionContext,
        sourceID: String?,
        path: String,
        operationPath: String,
        requestedSize: Int64?
    ) async throws -> HankRemoteTransferSetup {
        var body: [String: Any] = ["path": path]
        if let sourceID = Self.normalizedSourceID(sourceID) {
            body["source_id"] = sourceID
        }
        if let requestedSize, requestedSize > 0 {
            body["size"] = requestedSize
        }
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: operationPath,
            method: "POST",
            body: body
        )
        do {
            return try await send(request, expecting: HankRemoteTransferSetup.self)
        } catch {
            throw mappedPermissionError(error, feature: .files)
        }
    }

    private func createTransferRecord(
        key: String,
        operation: String,
        sourceID: String?,
        path: String,
        operationPath: String,
        requestedSize: Int64?,
        context: HankRemoteConnectionContext,
        nextOffset: Int64
    ) async throws -> HankRemoteTransferRecord {
        let normalizedSourceID = Self.normalizedSourceID(sourceID) ?? ""
        let setup = try await startTransfer(
            context: context,
            sourceID: normalizedSourceID,
            path: path,
            operationPath: operationPath,
            requestedSize: requestedSize
        )
        let record = HankRemoteTransferRecord(
            key: key,
            operation: operation,
            cloudURL: context.cloudURL,
            sourceID: setup.sourceID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? normalizedSourceID,
            path: path,
            url: setup.url,
            transferToken: setup.transferToken,
            nextOffset: nextOffset,
            updatedAt: .now
        )
        try await transferStateStore.save(record)
        return record
    }

    private func existingOrNewTransferRecord(
        key: String,
        operation: String,
        sourceID: String?,
        path: String,
        operationPath: String,
        requestedSize: Int64?,
        context: HankRemoteConnectionContext
    ) async throws -> HankRemoteTransferRecord {
        let normalizedSourceID = Self.normalizedSourceID(sourceID) ?? ""
        if
            let record = try await transferStateStore.record(for: key),
            record.operation == operation,
            record.path == path,
            record.cloudURL == context.cloudURL,
            record.sourceID == normalizedSourceID,
            !record.transferToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return record
        }

        return try await createTransferRecord(
            key: key,
            operation: operation,
            sourceID: normalizedSourceID,
            path: path,
            operationPath: operationPath,
            requestedSize: requestedSize,
            context: context,
            nextOffset: 0
        )
    }

    private func clearTransferState(for key: String) async throws {
        try await transferStateStore.removeRecord(for: key)
        try await transferStateStore.removePartialData(for: key)
    }

    private enum RemoteFeature {
        case homeAssistant
        case files
        case sharedNotes

        var permissionDeniedMessage: String {
            switch self {
            case .homeAssistant:
                "Home Assistant access is disabled for this member."
            case .files:
                "File access is disabled for this member."
            case .sharedNotes:
                "Shared-note access is disabled for this member."
            }
        }
    }

    private func mappedPermissionError(_ error: Error, feature: RemoteFeature) -> Error {
        guard case HankRemoteServiceError.unauthorized = error else {
            return error
        }
        return HankRemoteServiceError.server(feature.permissionDeniedMessage)
    }

    private func makeTransferTemporaryFileURL(prefix: String) throws -> URL {
        let directory = try AppFileLocations.applicationSupportDirectory()
            .appendingPathComponent("TransferTemps", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: false)
    }

    private func localFileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize else {
            throw HankRemoteServiceError.invalidResponse
        }
        return Int64(fileSize)
    }

    private func readUploadChunk(from url: URL, offset: Int64, maximumLength: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: maximumLength) ?? Data()
    }

    private func transferKey(
        operation: String,
        sourceID: String?,
        path: String,
        context: HankRemoteConnectionContext
    ) -> String {
        Self.transferCacheKey(operation: operation, cloudURL: context.cloudURL, sourceID: sourceID, path: path)
    }

    private func makeTransferRequest(
        urlValue: String,
        cloudURL: String,
        transferToken: String,
        method: String,
        offset: Int64
    ) throws -> URLRequest {
        let token = transferToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw HankRemoteServiceError.invalidResponse
        }
        guard let baseURL = absoluteURL(from: urlValue, cloudURL: cloudURL) else {
            throw HankRemoteServiceError.invalidResponse
        }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw HankRemoteServiceError.invalidResponse
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll(where: { $0.name == "offset" })
        queryItems.append(URLQueryItem(name: "offset", value: String(offset)))
        components.queryItems = queryItems
        guard let resolvedURL = components.url else {
            throw HankRemoteServiceError.invalidResponse
        }

        var request = URLRequest(url: resolvedURL)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func nextTransferOffset(from data: Data) -> Int64? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let nextOffset = object["next_offset"] as? NSNumber
        else {
            return nil
        }
        return nextOffset.int64Value
    }

    private func collect(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        return data
    }

    private func sendAppCommand<Response: Decodable>(
        context: HankRemoteConnectionContext,
        command: String,
        body: (any Encodable)? = nil,
        responseType: Response.Type
    ) async throws -> Response {
        if await realtimeSocket.isConnected(to: context) {
            do {
                let payload = try await realtimeSocket.sendPayload(command: command, bodyData: encodedBodyData(body))
                let decoder = JSONDecoder()
                HankRemoteDateCoding.configure(decoder)
                return try decoder.decode(Response.self, from: payload)
            } catch {
                await realtimeSocket.disconnect()
            }
        }
        return try await withOneShotAppSocket(context: context) { socket in
            try await socket.send(command: command, body: body, responseType: responseType)
        }
    }

    private func sendAppJSONObject(
        context: HankRemoteConnectionContext,
        command: String,
        body: (any Encodable)? = nil
    ) async throws -> [String: Any] {
        if await realtimeSocket.isConnected(to: context) {
            do {
                let payload = try await realtimeSocket.sendPayload(command: command, bodyData: encodedBodyData(body))
                guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                    throw HankRemoteServiceError.invalidResponse
                }
                return object
            } catch {
                await realtimeSocket.disconnect()
            }
        }
        let payload = try await withOneShotAppSocket(context: context) { socket in
            try await socket.sendPayload(command: command, body: body)
        }
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw HankRemoteServiceError.invalidResponse
        }
        return object
    }

    private func encodedBodyData(_ body: (any Encodable)?) throws -> Data? {
        guard let body else {
            return nil
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(AnyEncodable(erasing: body))
    }

    private func withOneShotAppSocket<T>(
        context: HankRemoteConnectionContext,
        operation: (OneShotHankRemoteSocket) async throws -> T
    ) async throws -> T {
        var shouldRetryOpen = true

        while true {
            let socket = try await makeOneShotAppSocket(context: context)
            do {
                let result = try await operation(socket)
                socket.close()
                return result
            } catch HankRemoteSocketLifecycleError.openFailed where shouldRetryOpen {
                shouldRetryOpen = false
                socket.close()
                continue
            } catch {
                socket.close()
                throw error
            }
        }
    }

    private func makeOneShotAppSocket(context: HankRemoteConnectionContext) async throws -> OneShotHankRemoteSocket {
        let ticket = try await issueAppWebSocketTicket(context: context)
        let websocketPath = ticket.websocketPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "/ws/app?app_ticket=\(ticket.ticket)"
            : ticket.websocketPath
        guard let url = Self.appWebSocketURL(from: context.cloudURL, websocketPath: websocketPath) else {
            throw HankRemoteServiceError.invalidURL
        }
        return OneShotHankRemoteSocket(context: context, url: url)
    }

    private func makeJSONRequest(
        cloudURL: String,
        path: String,
        method: String,
        body: [String: Any]? = nil
    ) throws -> URLRequest {
        guard let url = apiURL(from: cloudURL, path: path) else {
            throw HankRemoteServiceError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func makeJSONRequest<Body: Encodable>(
        cloudURL: String,
        path: String,
        method: String,
        body: Body
    ) throws -> URLRequest {
        guard let url = apiURL(from: cloudURL, path: path) else {
            throw HankRemoteServiceError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func makeAuthenticatedJSONRequest(
        context: HankRemoteConnectionContext,
        path: String,
        method: String,
        body: [String: Any]? = nil
    ) throws -> URLRequest {
        var request = try makeJSONRequest(cloudURL: context.cloudURL, path: path, method: method, body: body)
        request.setValue("Bearer \(context.sessionToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func makeAuthenticatedRequest(
        context: HankRemoteConnectionContext,
        path: String,
        method: String
    ) throws -> URLRequest {
        guard let url = apiURL(from: context.cloudURL, path: path) else {
            throw HankRemoteServiceError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("Bearer \(context.sessionToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func makeAuthenticatedJSONRequest<Body: Encodable>(
        context: HankRemoteConnectionContext,
        path: String,
        method: String,
        body: Body
    ) throws -> URLRequest {
        var request = try makeJSONRequest(cloudURL: context.cloudURL, path: path, method: method, body: body)
        request.setValue("Bearer \(context.sessionToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func upload<Response: Decodable>(
        _ fileURL: URL,
        with request: URLRequest,
        expecting type: Response.Type
    ) async throws -> Response {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
        } catch let error as URLError {
            switch error.code {
            case .badURL:
                throw HankRemoteServiceError.invalidURL
            default:
                throw HankRemoteServiceError.unreachableHost
            }
        } catch {
            throw HankRemoteServiceError.unreachableHost
        }
        guard let http = response as? HTTPURLResponse else {
            throw HankRemoteServiceError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw decodedError(from: data, statusCode: http.statusCode)
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw HankRemoteServiceError.invalidResponse
        }
    }

    private func send<Response: Decodable>(_ request: URLRequest, expecting type: Response.Type) async throws -> Response {
        let (data, response) = try await sendRaw(request)
        guard let http = response as? HTTPURLResponse else {
            throw HankRemoteServiceError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw decodedError(from: data, statusCode: http.statusCode)
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw HankRemoteServiceError.invalidResponse
        }
    }

    private func sendRaw(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch let error as HankRemoteServiceError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .badURL:
                throw HankRemoteServiceError.invalidURL
            default:
                throw HankRemoteServiceError.unreachableHost
            }
        } catch {
            throw HankRemoteServiceError.unreachableHost
        }
    }

    private func decodedError(from data: Data, statusCode: Int) -> HankRemoteServiceError {
        if statusCode == 401 || statusCode == 403 {
            return .unauthorized
        }

        if statusCode == 404 {
            return .notFound
        }

        if statusCode == 409 {
            if let envelope = try? decoder.decode(HankRemoteNotesConflictEnvelope.self, from: data) {
                return .conflict(envelope.current)
            }
            if
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let error = object["error"] as? String,
                error == "agent_offline"
            {
                return .server("The home agent is offline, so this change cannot be applied yet.")
            }
        }

        if
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = (object["message"] as? String) ?? (object["error"] as? String),
            !message.isEmpty
        {
            return .server(message)
        }

        if let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            return .server(message)
        }

        return .invalidResponse
    }

    private func issueAppWebSocketTicket(
        context: HankRemoteConnectionContext
    ) async throws -> HankRemoteAppWebSocketTicketResponse {
        let request = try makeAuthenticatedJSONRequest(
            context: context,
            path: "/v1/ws/app-ticket",
            method: "POST"
        )
        return try await send(request, expecting: HankRemoteAppWebSocketTicketResponse.self)
    }

    private func apiURL(from cloudURL: String, path: String) -> URL? {
        guard let normalized = Self.normalizedCloudURL(from: cloudURL), var components = URLComponents(string: normalized) else {
            return nil
        }

        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let extraPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = basePath.isEmpty ? "/\(extraPath)" : "/\(basePath)/\(extraPath)"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func pathComponent(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func healthURL(from cloudURL: String) -> URL? {
        apiURL(from: cloudURL, path: "/healthz")
    }

    static func appWebSocketURL(from cloudURL: String, websocketPath: String) -> URL? {
        let trimmedPath = websocketPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return nil
        }

        let absoluteURL: URL?
        if let directURL = URL(string: trimmedPath), directURL.scheme != nil {
            absoluteURL = directURL
        } else if let normalized = normalizedCloudURL(from: cloudURL), let baseURL = URL(string: normalized) {
            absoluteURL = URL(string: trimmedPath, relativeTo: baseURL)?.absoluteURL
        } else {
            absoluteURL = nil
        }

        guard var components = absoluteURL.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else {
            return nil
        }

        switch components.scheme?.lowercased() {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        case "ws", "wss":
            break
        default:
            return nil
        }

        components.fragment = nil
        return components.url
    }

    private func absoluteURL(from value: String, cloudURL: String) -> URL? {
        if let absolute = URL(string: value), absolute.scheme != nil {
            return absolute
        }
        guard let base = Self.normalizedCloudURL(from: cloudURL) else {
            return nil
        }
        return URL(string: value, relativeTo: URL(string: base))?.absoluteURL
    }

    private func jsonObject(from value: some Encodable) throws -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        HankRemoteDateCoding.configure(decoder)
        return decoder
    }
}

private actor HankRemoteRealtimeSocket {
    private var context: HankRemoteConnectionContext?
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var eventContinuations: [UUID: AsyncStream<HankRemoteRealtimeEvent>.Continuation] = [:]
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.dropfile.Hank", category: "HankRemoteRealtime")

    func isConnected(to context: HankRemoteConnectionContext) -> Bool {
        self.context == context && task != nil
    }

    func connect(context: HankRemoteConnectionContext, url: URL) {
        disconnect()
        self.context = context
        logger.info("Realtime socket connecting url=\(url.absoluteString, privacy: .public)")
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        self.session = session
        self.task = task
        task.resume()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    func disconnect() {
        if task != nil {
            logger.info("Realtime socket disconnecting")
        }
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        context = nil
        for continuation in pending.values {
            continuation.resume(throwing: HankRemoteServiceError.websocketClosed)
        }
        pending.removeAll()
    }

    func events() -> AsyncStream<HankRemoteRealtimeEvent> {
        AsyncStream { continuation in
            let id = UUID()
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventContinuation(id) }
            }
        }
    }

    func sendPayload(command: String, bodyData: Data?) async throws -> Data {
        guard let task else {
            throw HankRemoteServiceError.websocketClosed
        }
        let requestID = UUID().uuidString.lowercased()
        let message = try HankRemoteService.appCommandEnvelope(
            command: command,
            bodyData: bodyData,
            requestID: requestID,
            timestamp: ISO8601DateFormatter().string(from: .now)
        )
        let data = try JSONSerialization.data(withJSONObject: message)
        guard let text = String(data: data, encoding: .utf8) else {
            throw HankRemoteServiceError.invalidResponse
        }

        return try await withCheckedThrowingContinuation { continuation in
            pending[requestID] = continuation
            Task {
                do {
                    try await task.send(.string(text))
                } catch {
                    self.resolve(requestID: requestID, result: .failure(HankRemoteSocketLifecycleError.openFailed))
                }
            }
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            guard let task else {
                return
            }
            do {
                let message = try await task.receive()
                let envelope = try decodeEnvelope(message)
                switch envelope.type {
                case "app.response":
                    if let requestID = envelope.requestID, let payload = envelope.payload {
                        resolve(requestID: requestID, result: .success(payload))
                    }
                case "app.error":
                    if let requestID = envelope.requestID {
                        resolve(requestID: requestID, result: .failure(HankRemoteServiceError.server(envelope.error?.message ?? "Hank Remote command failed.")))
                    }
                case "app.event":
                    if let event = decodeRealtimeEvent(from: envelope.payload) {
                        logger.info("Realtime event received event=\(event.event, privacy: .public) topic=\((event.topic ?? ""), privacy: .public)")
                        for continuation in eventContinuations.values {
                            continuation.yield(event)
                        }
                    }
                default:
                    break
                }
            } catch {
                logger.warning("Realtime socket receive loop ended error=\(error.localizedDescription, privacy: .public)")
                disconnect()
                return
            }
        }
    }

    private func resolve(requestID: String, result: Result<Data, Error>) {
        guard let continuation = pending.removeValue(forKey: requestID) else {
            return
        }
        switch result {
        case .success(let data):
            continuation.resume(returning: data)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    private func decodeEnvelope(_ message: URLSessionWebSocketTask.Message) throws -> HankRemoteSocketEnvelope {
        let payloadData: Data
        switch message {
        case .data(let data):
            payloadData = data
        case .string(let string):
            guard let payload = string.data(using: .utf8) else {
                throw HankRemoteServiceError.invalidResponse
            }
            payloadData = payload
        @unknown default:
            throw HankRemoteServiceError.invalidResponse
        }
        guard let object = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            throw HankRemoteServiceError.invalidResponse
        }
        return Self.socketEnvelope(from: object)
    }

    private func decodeRealtimeEvent(from data: Data?) -> HankRemoteRealtimeEvent? {
        guard
            let data,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let event = object["event"] as? String
        else {
            return nil
        }
        let body: Data?
        if let rawBody = object["body"] {
            body = try? JSONSerialization.data(withJSONObject: rawBody)
        } else {
            body = nil
        }
        return HankRemoteRealtimeEvent(event: event, topic: object["topic"] as? String, payload: body)
    }

    static func socketEnvelope(from object: [String: Any]) -> HankRemoteSocketEnvelope {
        let payload: Data?
        if let rawPayload = object["payload"] {
            payload = try? JSONSerialization.data(withJSONObject: rawPayload)
        } else {
            payload = nil
        }
        let errorPayload: HankRemoteSocketErrorPayload?
        if let rawError = object["error"] as? [String: Any] {
            errorPayload = HankRemoteSocketErrorPayload(
                code: rawError["code"] as? String ?? "unknown_error",
                message: rawError["message"] as? String ?? "Hank Remote command failed."
            )
        } else {
            errorPayload = nil
        }
        return HankRemoteSocketEnvelope(
            type: object["type"] as? String ?? "",
            requestID: object["request_id"] as? String,
            payload: payload,
            error: errorPayload
        )
    }
}

private final class OneShotHankRemoteSocket {
    private let context: HankRemoteConnectionContext
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(context: HankRemoteConnectionContext, url: URL) {
        self.context = context
        self.session = URLSession(configuration: .ephemeral)
        self.task = session.webSocketTask(with: url)
        task.resume()
    }

    func send<Response: Decodable>(
        command: String,
        body: (any Encodable)?,
        responseType: Response.Type
    ) async throws -> Response {
        let payload = try await sendPayload(command: command, body: body)
        do {
            let decoder = JSONDecoder()
            HankRemoteDateCoding.configure(decoder)
            return try decoder.decode(Response.self, from: payload)
        } catch {
            throw HankRemoteServiceError.invalidResponse
        }
    }

    func sendPayload(
        command: String,
        body: (any Encodable)?
    ) async throws -> Data {
        let requestID = UUID().uuidString.lowercased()
        let bodyData: Data?
        if let body {
            bodyData = try JSONSerialization.data(withJSONObject: jsonObject(from: AnyEncodable(erasing: body)))
        } else {
            bodyData = nil
        }
        let message = try HankRemoteService.appCommandEnvelope(
            command: command,
            bodyData: bodyData,
            requestID: requestID,
            timestamp: ISO8601DateFormatter().string(from: .now)
        )

        let data = try JSONSerialization.data(withJSONObject: message)
        guard let text = String(data: data, encoding: .utf8) else {
            throw HankRemoteServiceError.invalidResponse
        }
        do {
            try await task.send(.string(text))
        } catch {
            throw HankRemoteSocketLifecycleError.openFailed
        }

        while true {
            let envelope = try await receiveEnvelope()
            guard envelope.requestID == requestID else {
                continue
            }

            switch envelope.type {
            case "app.response":
                guard let payload = envelope.payload else {
                    throw HankRemoteServiceError.invalidResponse
                }
                return payload
            case "app.error":
                throw HankRemoteServiceError.server(envelope.error?.message ?? "Hank Remote command failed.")
            default:
                continue
            }
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    private func receiveEnvelope() async throws -> HankRemoteSocketEnvelope {
        do {
            let message = try await task.receive()
            let payloadData: Data
            switch message {
            case .data(let data):
                payloadData = data
            case .string(let string):
                guard let payload = string.data(using: .utf8) else {
                    throw HankRemoteServiceError.invalidResponse
                }
                payloadData = payload
            @unknown default:
                throw HankRemoteServiceError.invalidResponse
            }
            guard let object = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
                throw HankRemoteServiceError.invalidResponse
            }
            let payload: Data?
            if let rawPayload = object["payload"] {
                payload = try JSONSerialization.data(withJSONObject: rawPayload)
            } else {
                payload = nil
            }
            let errorPayload: HankRemoteSocketErrorPayload?
            if let rawError = object["error"] as? [String: Any] {
                errorPayload = HankRemoteSocketErrorPayload(
                    code: rawError["code"] as? String ?? "unknown_error",
                    message: rawError["message"] as? String ?? "Hank Remote command failed."
                )
            } else {
                errorPayload = nil
            }
            return HankRemoteSocketEnvelope(
                type: object["type"] as? String ?? "",
                requestID: object["request_id"] as? String,
                payload: payload,
                error: errorPayload
            )
        } catch let error as HankRemoteServiceError {
            throw error
        } catch {
            throw HankRemoteServiceError.websocketClosed
        }
    }

    private func jsonObject(from value: some Encodable) throws -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }
}

final class HomeAssistantService: HomeAssistantServicing, @unchecked Sendable {
    private let hankRemoteService: HankRemoteService
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.dropfile.Hank", category: "HomeAssistant")

    init(hankRemoteService: HankRemoteService) {
        self.hankRemoteService = hankRemoteService
    }

    func validateConnection(context: HankRemoteConnectionContext) async throws -> String? {
        _ = try await hankRemoteService.homeAssistantHealth(context)
        return "Connected to Home Assistant via Hank Remote."
    }

    func fetchEntityCatalog(context: HankRemoteConnectionContext) async throws -> [HAEntitySummary] {
        let states = try await fetchStates(context: context)
        return Self.makeEntityCatalog(from: states)
    }

    func fetchStates(context: HankRemoteConnectionContext) async throws -> [HAEntityState] {
        let rawStates = try await hankRemoteService.homeAssistantFetchStates(context)
        return rawStates.compactMap(Self.parseState(from:))
    }

    func subscribeToStateChanges(context: HankRemoteConnectionContext) -> AsyncThrowingStream<HAEntityState, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.hankRemoteService.subscribeRealtime(
                        topics: ["homeassistant.states"],
                        context: context
                    )
                    for await event in await self.hankRemoteService.realtimeEvents() where event.event == "homeassistant.state_changed" {
                        guard
                            let payload = event.payload,
                            let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                            let rawState = object["state"] as? [String: Any],
                            let state = Self.parseState(from: rawState)
                        else {
                            continue
                        }
                        continuation.yield(state)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    self.logger.error("Home Assistant remote polling failed: \(String(describing: error), privacy: .public)")
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func performAction(
        for entity: HAEntitySummary,
        state: HAEntityState?,
        context: HankRemoteConnectionContext
    ) async throws {
        guard let serviceCall = HomeAssistantActionResolver.serviceCall(for: entity, state: state) else {
            return
        }
        try await hankRemoteService.homeAssistantCallService(
            domain: serviceCall.domain,
            service: serviceCall.service,
            body: serviceCall.payload.body,
            context: context
        )
    }

    func setBrightness(
        for entity: HAEntitySummary,
        brightnessPercent: Int,
        context: HankRemoteConnectionContext
    ) async throws {
        guard let serviceCall = HomeAssistantActionResolver.brightnessServiceCall(
            for: entity,
            brightnessPercent: brightnessPercent
        ) else {
            return
        }

        try await hankRemoteService.homeAssistantCallService(
            domain: serviceCall.domain,
            service: serviceCall.service,
            body: serviceCall.payload.body,
            context: context
        )
    }

    private static func parseState(from rawState: [String: Any]) -> HAEntityState? {
        guard
            let entityID = rawState["entity_id"] as? String,
            let state = rawState["state"] as? String
        else {
            return nil
        }

        let attributes = rawState["attributes"] as? [String: Any]
        let friendlyName = attributes?["friendly_name"] as? String
        let icon = attributes?["icon"] as? String
        let unitOfMeasurement = attributes?["unit_of_measurement"] as? String
        let deviceClass = attributes?["device_class"] as? String
        let supportedColorModes = (attributes?["supported_color_modes"] as? [Any])?.compactMap { value in
            value as? String
        } ?? []
        let brightness = intValue(attributes?["brightness"])

        return HAEntityState(
            entityID: entityID,
            state: state,
            friendlyName: friendlyName,
            icon: icon,
            unitOfMeasurement: unitOfMeasurement,
            deviceClass: deviceClass,
            supportedColorModes: supportedColorModes,
            brightness: brightness
        )
    }

    private static func makeEntityCatalog(from states: [HAEntityState]) -> [HAEntitySummary] {
        states.compactMap { state in
            guard HomeAssistantActionResolver.supports(entityID: state.entityID) else {
                return nil
            }
            let domain = state.entityID.split(separator: ".").first.map(String.init) ?? ""
            let friendlyName = state.friendlyName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? state.entityID
            return HAEntitySummary(
                entityID: state.entityID,
                friendlyName: friendlyName.isEmpty ? state.entityID : friendlyName,
                domain: domain,
                icon: state.icon,
                controlStyle: HomeAssistantActionResolver.controlStyle(for: domain),
                unitOfMeasurement: state.unitOfMeasurement,
                deviceClass: state.deviceClass,
                supportsBrightness: state.supportsBrightness
            )
        }
        .sorted { $0.suggestedLabel.localizedCaseInsensitiveCompare($1.suggestedLabel) == .orderedAscending }
    }

    private static func intValue(_ raw: Any?) -> Int? {
        switch raw {
        case let value as Int:
            return value
        case let value as Double:
            return Int(value.rounded())
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }
}

protocol SMBRemoteSession: AnyObject, Sendable {
    func login(username: String, password: String, domain: String?) async throws
    func listShares() async throws -> [String]
    func connectShare(_ shareName: String) async throws
    func list(path: String) async throws -> [SMBItem]
    func download(path: String) async throws -> Data
    func download(path: String, to localURL: URL) async throws
    func createDirectory(path: String) async throws
    func upload(data: Data, path: String) async throws
    func upload(fileAt localURL: URL, path: String) async throws
    func move(from: String, to: String, isDirectory: Bool) async throws
    func delete(path: String, isDirectory: Bool) async throws
    func disconnect() async
}

final class SMBClientRemoteSession: SMBRemoteSession, @unchecked Sendable {
    private let remoteAccess: HankRemoteConnectionContext
    private let sourceID: String?
    private let hankRemoteService: HankRemoteService

    init(
        config: SMBConnectionDetails,
        remoteAccess: HankRemoteConnectionContext,
        hankRemoteService: HankRemoteService
    ) async throws {
        self.remoteAccess = remoteAccess
        self.sourceID = HankRemoteService.inferredRemoteSourceID(from: config)
        self.hankRemoteService = hankRemoteService
    }

    func login(username: String, password: String, domain: String?) async throws {
        return
    }

    func listShares() async throws -> [String] {
        []
    }

    func connectShare(_ shareName: String) async throws {
        return
    }

    func list(path: String) async throws -> [SMBItem] {
        try await hankRemoteService.listFiles(path: path, sourceID: sourceID, context: remoteAccess)
    }

    func download(path: String) async throws -> Data {
        try await hankRemoteService.downloadFile(path: path, sourceID: sourceID, context: remoteAccess)
    }

    func download(path: String, to localURL: URL) async throws {
        try await hankRemoteService.downloadFile(path: path, sourceID: sourceID, to: localURL, context: remoteAccess)
    }

    func createDirectory(path: String) async throws {
        try await hankRemoteService.createDirectory(path: path, sourceID: sourceID, context: remoteAccess)
    }

    func upload(data: Data, path: String) async throws {
        try await hankRemoteService.uploadFile(data: data, path: path, sourceID: sourceID, context: remoteAccess)
    }

    func upload(fileAt localURL: URL, path: String) async throws {
        try await hankRemoteService.uploadFile(fileAt: localURL, path: path, sourceID: sourceID, context: remoteAccess)
    }

    func move(from: String, to: String, isDirectory: Bool) async throws {
        try await hankRemoteService.moveFile(
            from: from,
            to: to,
            isDirectory: isDirectory,
            sourceID: sourceID,
            context: remoteAccess
        )
    }

    func delete(path: String, isDirectory: Bool) async throws {
        try await hankRemoteService.deleteFile(path: path, isDirectory: isDirectory, sourceID: sourceID, context: remoteAccess)
    }

    func disconnect() async {
        return
    }
}

final class SMBFileService: SMBServicing, @unchecked Sendable {
    private let clientFactory: @Sendable (SMBConnectionDetails, HankRemoteConnectionContext) async throws -> SMBRemoteSession
    private var client: SMBRemoteSession?
    private var connectedConfig: SMBConnectionDetails?
    private var connectedPassword: String?
    private var connectedRemoteAccess: HankRemoteConnectionContext?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.dropfile.Hank", category: "SMB")

    private func diagnosticSummary(for error: Error) -> String {
        let nsError = error as NSError
        return "\(error.localizedDescription) [\(nsError.domain):\(nsError.code)]"
    }

    private func previewNames(for items: [SMBItem], limit: Int = 5) -> String {
        let names = items.prefix(limit).map(\.name)
        guard !names.isEmpty else {
            return "-"
        }
        return names.joined(separator: ", ")
    }

    init(hankRemoteService: HankRemoteService) {
        self.clientFactory = { config, remoteAccess in
            try await SMBClientRemoteSession(
                config: config,
                remoteAccess: remoteAccess,
                hankRemoteService: hankRemoteService
            )
        }
    }

    init(clientFactory: @escaping @Sendable (SMBConnectionDetails, HankRemoteConnectionContext) async throws -> SMBRemoteSession) {
        self.clientFactory = clientFactory
    }

    init(clientFactory: @escaping @Sendable (SMBConnectionDetails) -> SMBRemoteSession) {
        self.clientFactory = { config, _ in
            clientFactory(config)
        }
    }

    func connect(
        config: SMBConnectionDetails,
        password: String,
        context: HankRemoteConnectionContext
    ) async throws {
        if
            connectedConfig == config,
            connectedPassword == password,
            connectedRemoteAccess == context,
            client != nil
        {
            return
        }

        await disconnect()

        logger.info("Starting SMB session to \(config.trimmedHost, privacy: .public):\(config.port) via Hank Remote")
        let client = try await clientFactory(config, context)
        logger.info("SMB transport created for \(config.trimmedHost, privacy: .public)")
        do {
            try await client.login(username: config.trimmedUsername, password: password, domain: config.trimmedDomain.nilIfEmpty)
            logger.info("SMB login succeeded for \(config.trimmedHost, privacy: .public)")
        } catch {
            await client.disconnect()
            throw SMBConnectionStageError(stage: .login, underlying: error)
        }

        do {
            let shares = try await client.listShares().sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
            let shareList = shares.isEmpty ? "-" : shares.joined(separator: ", ")
            let requestedSharePresent = shares.contains {
                $0.compare(config.shareName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }
            logger.info(
                """
                SMB share enumeration for \(config.trimmedHost, privacy: .public) user \(config.trimmedUsername, privacy: .public) returned \(shares.count) shares. requestedSharePresent=\(requestedSharePresent, privacy: .public) shares=\(shareList, privacy: .public)
                """
            )
        } catch {
            logger.error(
                """
                SMB share enumeration failed for \(config.trimmedHost, privacy: .public) user \(config.trimmedUsername, privacy: .public): \(self.diagnosticSummary(for: error), privacy: .public)
                """
            )
        }

        do {
            try await client.connectShare(config.shareName)
            logger.info("SMB tree connect succeeded for share \(config.shareName, privacy: .public)")
        } catch {
            await client.disconnect()
            throw SMBConnectionStageError(stage: .shareConnect(config.shareName), underlying: error)
        }
        self.client = client
        self.connectedConfig = config
        self.connectedPassword = password
        connectedRemoteAccess = context
    }

    func list(path: String) async throws -> [SMBItem] {
        guard let client else {
            throw SMBServiceError.notConnected
        }

        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        logger.info("Listing SMB path \(normalizedPath, privacy: .public)")
        do {
            let items = try await client.list(path: normalizedPath)
            logger.info(
                "SMB list succeeded for path \(normalizedPath, privacy: .public) with \(items.count) items. preview=\(self.previewNames(for: items), privacy: .public)"
            )
            return items
        } catch {
            logger.error(
                "SMB list failed for path \(normalizedPath, privacy: .public): \(self.diagnosticSummary(for: error), privacy: .public)"
            )
            throw error
        }
    }

    func download(path: String) async throws -> Data {
        guard let client else {
            throw SMBServiceError.notConnected
        }

        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return try await client.download(path: normalizedPath)
    }

    func download(path: String, to localURL: URL) async throws {
        guard let client else {
            throw SMBServiceError.notConnected
        }

        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        try await client.download(path: normalizedPath, to: localURL)
    }

    func createDirectory(path: String) async throws {
        guard let client else {
            throw SMBServiceError.notConnected
        }

        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        try await client.createDirectory(path: normalizedPath)
    }

    func upload(data: Data, path: String) async throws {
        guard let client else {
            throw SMBServiceError.notConnected
        }

        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        try await client.upload(data: data, path: normalizedPath)
    }

    func upload(fileAt localURL: URL, path: String) async throws {
        guard let client else {
            throw SMBServiceError.notConnected
        }

        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        try await client.upload(fileAt: localURL, path: normalizedPath)
    }

    func move(from: String, to: String, isDirectory: Bool) async throws {
        guard let client else {
            throw SMBServiceError.notConnected
        }

        let normalizedFrom = from.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedTo = to.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        try await client.move(from: normalizedFrom, to: normalizedTo, isDirectory: isDirectory)
    }

    func delete(path: String, isDirectory: Bool) async throws {
        guard let client else {
            throw SMBServiceError.notConnected
        }

        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        try await client.delete(path: normalizedPath, isDirectory: isDirectory)
    }

    func disconnect() async {
        if let client {
            await client.disconnect()
        }
        self.client = nil
        connectedConfig = nil
        connectedPassword = nil
        connectedRemoteAccess = nil
    }
}
