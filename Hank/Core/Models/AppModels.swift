import Foundation
import SwiftData
import UniformTypeIdentifiers

struct UserSession: Equatable, Sendable {
    let profileID: UUID
    let username: String
    let displayName: String
    let loggedInAt: Date
}

struct HomeAssistantConnectionConfiguration: Equatable, Sendable, Codable {
    var baseURLString: String = ""
    var port: Int = 8123
    var displayName: String = "Home Assistant"
    var allowSelfSignedLocal: Bool = true

    var trimmedBaseURLString: String {
        baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var resolvedBaseURLString: String {
        let trimmed = trimmedBaseURLString
        guard
            !trimmed.isEmpty,
            var components = URLComponents(string: trimmed)
        else {
            return trimmed
        }

        components.port = port
        return components.string ?? trimmed
    }
}

struct SMBConnectionDetails: Equatable, Sendable, Codable {
    var host: String = ""
    var shareName: String = ""
    var username: String = ""
    var domain: String = ""
    var port: Int = 445
    var startPath: String = ""
    var remoteSourceID: String = ""

    enum CodingKeys: String, CodingKey {
        case host
        case shareName
        case username
        case domain
        case port
        case startPath
        case remoteSourceID
    }

    init(
        host: String = "",
        shareName: String = "",
        username: String = "",
        domain: String = "",
        port: Int = 445,
        startPath: String = "",
        remoteSourceID: String = ""
    ) {
        self.host = host
        self.shareName = shareName
        self.username = username
        self.domain = domain
        self.port = port
        self.startPath = startPath
        self.remoteSourceID = remoteSourceID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        shareName = try container.decodeIfPresent(String.self, forKey: .shareName) ?? ""
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        domain = try container.decodeIfPresent(String.self, forKey: .domain) ?? ""
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 445
        startPath = try container.decodeIfPresent(String.self, forKey: .startPath) ?? ""
        remoteSourceID = try container.decodeIfPresent(String.self, forKey: .remoteSourceID) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(host, forKey: .host)
        try container.encode(shareName, forKey: .shareName)
        try container.encode(username, forKey: .username)
        try container.encode(domain, forKey: .domain)
        try container.encode(port, forKey: .port)
        try container.encode(startPath, forKey: .startPath)
        if !normalizedRemoteSourceID.isEmpty {
            try container.encode(normalizedRemoteSourceID, forKey: .remoteSourceID)
        }
    }

    var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedDomain: String {
        domain.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedRemoteSourceID: String {
        remoteSourceID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedStartPath: String {
        let trimmed = startPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "/" else {
            return ""
        }

        let normalizedSeparators = trimmed.replacingOccurrences(of: "\\", with: "/")
        let components = normalizedSeparators
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        return components.joined(separator: "/")
    }
}

enum NotesStorageLocation: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case device
    case smb

    var id: Self { self }

    var title: String {
        switch self {
        case .device:
            "On Device"
        case .smb:
            "SMB Share"
        }
    }
}

enum SavedCalendarSourceKind: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case deviceCalendar
    case webSubscription

    var id: Self { self }

    var title: String {
        switch self {
        case .deviceCalendar:
            "Device Calendar"
        case .webSubscription:
            "Web Calendar"
        }
    }
}

struct ResolvedHomeAssistantEndpoint: Equatable, Sendable {
    let remoteAccess: HankRemoteConnectionContext
}

struct HankRemoteConnectionContext: Equatable, Sendable {
    let cloudURL: String
    let sessionToken: String
}

struct ResolvedSMBConnection: Equatable, Sendable {
    let connectionID: UUID?
    let details: SMBConnectionDetails
    let remoteAccess: HankRemoteConnectionContext
}

struct SavedSMBConnectionSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let displayName: String
    let details: SMBConnectionDetails
    let isDefault: Bool

    var subtitle: String {
        "\(details.trimmedHost):\(details.port) / \(details.shareName.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

struct HankRemoteSettingsSnapshot: Equatable, Sendable {
    var isEnabled: Bool = false
    var cloudURL: String = ""
    var homeID: String = ""

    var trimmedCloudURL: String {
        cloudURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedHomeID: String {
        homeID.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@Model
final class HankRemoteSettings {
    @Attribute(.unique) var singletonKey: String
    var isEnabled: Bool
    var cloudURL: String
    var homeID: String
    var updatedAt: Date

    init(
        singletonKey: String = "app",
        isEnabled: Bool = false,
        cloudURL: String = "",
        homeID: String = "",
        updatedAt: Date = .now
    ) {
        self.singletonKey = singletonKey
        self.isEnabled = isEnabled
        self.cloudURL = cloudURL
        self.homeID = homeID
        self.updatedAt = updatedAt
    }
}

extension HankRemoteSettings {
    var snapshot: HankRemoteSettingsSnapshot {
        HankRemoteSettingsSnapshot(
            isEnabled: isEnabled,
            cloudURL: cloudURL,
            homeID: homeID
        )
    }

    func apply(_ snapshot: HankRemoteSettingsSnapshot) {
        isEnabled = snapshot.isEnabled
        cloudURL = snapshot.trimmedCloudURL
        homeID = snapshot.trimmedHomeID
        updatedAt = .now
    }

    static func fetch(in context: ModelContext) throws -> HankRemoteSettings? {
        let predicate = #Predicate<HankRemoteSettings> { settings in
            settings.singletonKey == "app"
        }
        var descriptor = FetchDescriptor<HankRemoteSettings>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}

// Retained only so older local stores can still deserialize without forcing a more
// disruptive migration while Hank moves to the Hank Remote architecture.
@Model
final class TailscaleSettings {
    @Attribute(.unique) var singletonKey: String
    var isEnabled: Bool
    var nodeName: String
    var homeAssistantURLOverride: String
    var smbHostOverride: String
    var updatedAt: Date

    init(
        singletonKey: String = "app",
        isEnabled: Bool = false,
        nodeName: String = "Hank",
        homeAssistantURLOverride: String = "",
        smbHostOverride: String = "",
        updatedAt: Date = .now
    ) {
        self.singletonKey = singletonKey
        self.isEnabled = isEnabled
        self.nodeName = nodeName
        self.homeAssistantURLOverride = homeAssistantURLOverride
        self.smbHostOverride = smbHostOverride
        self.updatedAt = updatedAt
    }
}

@Model
final class UserProfile {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var username: String
    var displayName: String
    var passwordHash: String
    var passwordSalt: String
    var authModeRawValue: String = UserProfileAuthMode.local.rawValue
    var remoteUserID: String? = nil
    var remoteEmail: String? = nil
    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?
    var rememberedSession: Bool

    init(
        id: UUID = UUID(),
        username: String,
        displayName: String,
        passwordHash: String,
        passwordSalt: String,
        authModeRawValue: String = UserProfileAuthMode.local.rawValue,
        remoteUserID: String? = nil,
        remoteEmail: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        lastUsedAt: Date? = nil,
        rememberedSession: Bool = false
    ) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.passwordHash = passwordHash
        self.passwordSalt = passwordSalt
        self.authModeRawValue = authModeRawValue
        self.remoteUserID = remoteUserID
        self.remoteEmail = remoteEmail
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
        self.rememberedSession = rememberedSession
    }
}

enum UserProfileAuthMode: String, Codable, Hashable, Sendable {
    case local
    case hankRemote
}

extension UserProfile {
    var authMode: UserProfileAuthMode {
        get { UserProfileAuthMode(rawValue: authModeRawValue) ?? .local }
        set { authModeRawValue = newValue.rawValue }
    }

    var effectiveLoginIdentifier: String {
        switch authMode {
        case .local:
            return username
        case .hankRemote:
            let normalizedRemoteEmail = remoteEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            return normalizedRemoteEmail.isEmpty ? displayName : normalizedRemoteEmail
        }
    }

    static func fetchAll(in context: ModelContext) throws -> [UserProfile] {
        let descriptor = FetchDescriptor<UserProfile>(
            sortBy: [
                SortDescriptor(\.lastUsedAt, order: .reverse),
                SortDescriptor(\.createdAt)
            ]
        )
        return try context.fetch(descriptor)
    }

    static func fetch(id: UUID, in context: ModelContext) throws -> UserProfile? {
        let predicate = #Predicate<UserProfile> { profile in
            profile.id == id
        }
        var descriptor = FetchDescriptor<UserProfile>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    static func fetch(username: String, in context: ModelContext) throws -> UserProfile? {
        let predicate = #Predicate<UserProfile> { profile in
            profile.username == username
        }
        var descriptor = FetchDescriptor<UserProfile>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    static func fetch(remoteUserID: String, in context: ModelContext) throws -> UserProfile? {
        let predicate = #Predicate<UserProfile> { profile in
            profile.remoteUserID == remoteUserID
        }
        var descriptor = FetchDescriptor<UserProfile>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    static func fetch(remoteEmail: String, in context: ModelContext) throws -> UserProfile? {
        let predicate = #Predicate<UserProfile> { profile in
            profile.remoteEmail == remoteEmail
        }
        var descriptor = FetchDescriptor<UserProfile>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    static func fetchRemembered(in context: ModelContext) throws -> [UserProfile] {
        let predicate = #Predicate<UserProfile> { profile in
            profile.rememberedSession == true
        }
        let descriptor = FetchDescriptor<UserProfile>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }
}

@Model
final class HomeAssistantConfig {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var profileID: UUID
    var baseURLString: String
    var port: Int
    var displayName: String
    var allowSelfSignedLocal: Bool
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        profileID: UUID,
        baseURLString: String = "",
        port: Int = 8123,
        displayName: String = "Home Assistant",
        allowSelfSignedLocal: Bool = true,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.profileID = profileID
        self.baseURLString = baseURLString
        self.port = port
        self.displayName = displayName
        self.allowSelfSignedLocal = allowSelfSignedLocal
        self.updatedAt = updatedAt
    }
}

extension HomeAssistantConfig {
    var connectionConfiguration: HomeAssistantConnectionConfiguration {
        HomeAssistantConnectionConfiguration(
            baseURLString: baseURLString,
            port: port,
            displayName: displayName,
            allowSelfSignedLocal: allowSelfSignedLocal
        )
    }

    func apply(_ configuration: HomeAssistantConnectionConfiguration) {
        baseURLString = configuration.trimmedBaseURLString
        port = configuration.port
        displayName = configuration.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        allowSelfSignedLocal = configuration.allowSelfSignedLocal
        updatedAt = .now
    }

    static func fetch(for profileID: UUID, in context: ModelContext) throws -> HomeAssistantConfig? {
        let predicate = #Predicate<HomeAssistantConfig> { config in
            config.profileID == profileID
        }
        var descriptor = FetchDescriptor<HomeAssistantConfig>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}

// Retained for compatibility with older local stores while the app migrates to
// multi-connection SMB support.
@Model
final class SMBConnectionConfig {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var profileID: UUID
    var host: String
    var shareName: String
    var username: String
    var domain: String = ""
    var port: Int
    var startPath: String
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        profileID: UUID,
        host: String = "",
        shareName: String = "",
        username: String = "",
        domain: String = "",
        port: Int = 445,
        startPath: String = "",
        updatedAt: Date = .now
    ) {
        self.id = id
        self.profileID = profileID
        self.host = host
        self.shareName = shareName
        self.username = username
        self.domain = domain
        self.port = port
        self.startPath = startPath
        self.updatedAt = updatedAt
    }
}

extension SMBConnectionConfig {
    var connectionDetails: SMBConnectionDetails {
        SMBConnectionDetails(
            host: host,
            shareName: shareName,
            username: username,
            domain: domain,
            port: port,
            startPath: startPath
        )
    }

    func apply(_ details: SMBConnectionDetails) {
        host = details.trimmedHost
        shareName = details.shareName.trimmingCharacters(in: .whitespacesAndNewlines)
        username = details.trimmedUsername
        domain = details.trimmedDomain
        port = details.port
        startPath = details.normalizedStartPath
        updatedAt = .now
    }

    static func fetch(for profileID: UUID, in context: ModelContext) throws -> SMBConnectionConfig? {
        let predicate = #Predicate<SMBConnectionConfig> { config in
            config.profileID == profileID
        }
        var descriptor = FetchDescriptor<SMBConnectionConfig>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}

@Model
final class SavedSMBConnection {
    @Attribute(.unique) var id: UUID
    var profileID: UUID
    var displayName: String
    var host: String
    var shareName: String
    var username: String
    var domain: String = ""
    var port: Int
    var startPath: String
    var remoteSourceID: String = ""
    var isDefault: Bool
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        profileID: UUID,
        displayName: String = "",
        host: String = "",
        shareName: String = "",
        username: String = "",
        domain: String = "",
        port: Int = 445,
        startPath: String = "",
        remoteSourceID: String = "",
        isDefault: Bool = false,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.profileID = profileID
        self.displayName = displayName
        self.host = host
        self.shareName = shareName
        self.username = username
        self.domain = domain
        self.port = port
        self.startPath = startPath
        self.remoteSourceID = remoteSourceID
        self.isDefault = isDefault
        self.updatedAt = updatedAt
    }
}

extension SavedSMBConnection {
    var connectionDetails: SMBConnectionDetails {
        SMBConnectionDetails(
            host: host,
            shareName: shareName,
            username: username,
            domain: domain,
            port: port,
            startPath: startPath,
            remoteSourceID: remoteSourceID
        )
    }

    var trimmedDisplayName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var effectiveDisplayName: String {
        let trimmed = trimmedDisplayName
        if !trimmed.isEmpty {
            return trimmed
        }

        let trimmedShare = shareName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedShare.isEmpty {
            return trimmedShare
        }

        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHost.isEmpty {
            return trimmedHost
        }

        return "SMB Connection"
    }

    var summary: SavedSMBConnectionSummary {
        SavedSMBConnectionSummary(
            id: id,
            displayName: effectiveDisplayName,
            details: connectionDetails,
            isDefault: isDefault
        )
    }

    func apply(details: SMBConnectionDetails, displayName: String, isDefault: Bool) {
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        host = details.trimmedHost
        shareName = details.shareName.trimmingCharacters(in: .whitespacesAndNewlines)
        username = details.trimmedUsername
        domain = details.trimmedDomain
        port = details.port
        startPath = details.normalizedStartPath
        remoteSourceID = details.normalizedRemoteSourceID
        self.isDefault = isDefault
        updatedAt = .now
    }

    static func fetch(id: UUID, in context: ModelContext) throws -> SavedSMBConnection? {
        let predicate = #Predicate<SavedSMBConnection> { connection in
            connection.id == id
        }
        var descriptor = FetchDescriptor<SavedSMBConnection>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    static func fetchAll(for profileID: UUID, in context: ModelContext) throws -> [SavedSMBConnection] {
        let predicate = #Predicate<SavedSMBConnection> { connection in
            connection.profileID == profileID
        }
        let fetched = try context.fetch(
            FetchDescriptor(
                predicate: predicate,
                sortBy: [SortDescriptor(\SavedSMBConnection.updatedAt, order: .reverse)]
            )
        )
        return fetched.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault {
                return lhs.isDefault && !rhs.isDefault
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }
}

@Model
final class NotesConfig {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var profileID: UUID
    var storageLocationRawValue: String
    var pendingSMBMigration: Bool
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        profileID: UUID,
        storageLocationRawValue: String = NotesStorageLocation.device.rawValue,
        pendingSMBMigration: Bool = false,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.profileID = profileID
        self.storageLocationRawValue = storageLocationRawValue
        self.pendingSMBMigration = pendingSMBMigration
        self.updatedAt = updatedAt
    }
}

extension NotesConfig {
    var storageLocation: NotesStorageLocation {
        get { NotesStorageLocation(rawValue: storageLocationRawValue) ?? .device }
        set {
            storageLocationRawValue = newValue.rawValue
            updatedAt = .now
        }
    }

    var effectiveStorageLocation: NotesStorageLocation {
        pendingSMBMigration ? .device : storageLocation
    }

    func apply(storageLocation: NotesStorageLocation, pendingSMBMigration: Bool) {
        self.storageLocationRawValue = storageLocation.rawValue
        self.pendingSMBMigration = pendingSMBMigration
        updatedAt = .now
    }

    static func fetch(for profileID: UUID, in context: ModelContext) throws -> NotesConfig? {
        let predicate = #Predicate<NotesConfig> { config in
            config.profileID == profileID
        }
        var descriptor = FetchDescriptor<NotesConfig>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}

@Model
final class SavedCalendarSource {
    @Attribute(.unique) var id: UUID
    var profileID: UUID
    var kindRawValue: String
    var displayName: String
    var remoteIdentifier: String
    var urlString: String
    var sourceTitle: String
    var detailText: String
    var isEnabled: Bool
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        profileID: UUID,
        kindRawValue: String = SavedCalendarSourceKind.deviceCalendar.rawValue,
        displayName: String = "",
        remoteIdentifier: String = "",
        urlString: String = "",
        sourceTitle: String = "",
        detailText: String = "",
        isEnabled: Bool = true,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.profileID = profileID
        self.kindRawValue = kindRawValue
        self.displayName = displayName
        self.remoteIdentifier = remoteIdentifier
        self.urlString = urlString
        self.sourceTitle = sourceTitle
        self.detailText = detailText
        self.isEnabled = isEnabled
        self.updatedAt = updatedAt
    }
}

extension SavedCalendarSource {
    var kind: SavedCalendarSourceKind {
        get { SavedCalendarSourceKind(rawValue: kindRawValue) ?? .deviceCalendar }
        set {
            kindRawValue = newValue.rawValue
            updatedAt = .now
        }
    }

    var trimmedDisplayName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var effectiveDisplayName: String {
        let trimmed = trimmedDisplayName
        if !trimmed.isEmpty {
            return trimmed
        }

        switch kind {
        case .deviceCalendar:
            return sourceTitle.isEmpty ? "Calendar" : sourceTitle
        case .webSubscription:
            if let host = URL(string: urlString)?.host, !host.isEmpty {
                return host
            }
            return "Web Calendar"
        }
    }

    func applyDeviceCalendar(
        title: String,
        calendarIdentifier: String,
        sourceTitle: String,
        detailText: String,
        isEnabled: Bool
    ) {
        kindRawValue = SavedCalendarSourceKind.deviceCalendar.rawValue
        displayName = title.trimmingCharacters(in: .whitespacesAndNewlines)
        remoteIdentifier = calendarIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        urlString = ""
        self.sourceTitle = sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self.detailText = detailText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isEnabled = isEnabled
        updatedAt = .now
    }

    func applyWebSubscription(
        displayName: String,
        urlString: String,
        detailText: String,
        isEnabled: Bool
    ) {
        kindRawValue = SavedCalendarSourceKind.webSubscription.rawValue
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        remoteIdentifier = ""
        self.urlString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        sourceTitle = "Web Calendar"
        self.detailText = detailText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isEnabled = isEnabled
        updatedAt = .now
    }

    static func fetchAll(for profileID: UUID, in context: ModelContext) throws -> [SavedCalendarSource] {
        let predicate = #Predicate<SavedCalendarSource> { source in
            source.profileID == profileID
        }
        let descriptor = FetchDescriptor(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\SavedCalendarSource.updatedAt, order: .reverse),
                SortDescriptor(\SavedCalendarSource.displayName)
            ]
        )
        return try context.fetch(descriptor)
    }
}

@Model
final class DashboardShortcut {
    @Attribute(.unique) var id: UUID
    var profileID: UUID
    var entityID: String
    var labelOverride: String?
    var tileSizeRawValue: String?
    var sortOrder: Int
    var gridRow: Int
    var gridColumn: Int
    var isEnabled: Bool

    init(
        profileID: UUID,
        entityID: String,
        id: UUID = UUID(),
        labelOverride: String? = nil,
        tileSizeRawValue: String? = DashboardTileSize.compact.rawValue,
        sortOrder: Int = 0,
        gridRow: Int = 0,
        gridColumn: Int = 0,
        isEnabled: Bool = true
    ) {
        self.profileID = profileID
        self.entityID = entityID
        self.id = id
        self.labelOverride = labelOverride
        self.tileSizeRawValue = tileSizeRawValue
        self.sortOrder = sortOrder
        self.gridRow = gridRow
        self.gridColumn = gridColumn
        self.isEnabled = isEnabled
    }
}

extension DashboardShortcut {
    var tileSize: DashboardTileSize {
        get { DashboardTileSize(rawValue: tileSizeRawValue ?? "") ?? .compact }
        set { tileSizeRawValue = newValue.rawValue }
    }

    static func fetchOrdered(for profileID: UUID, in context: ModelContext) throws -> [DashboardShortcut] {
        let predicate = #Predicate<DashboardShortcut> { shortcut in
            shortcut.profileID == profileID
        }
        let descriptor = FetchDescriptor<DashboardShortcut>(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\.gridRow),
                SortDescriptor(\.gridColumn),
                SortDescriptor(\.sortOrder),
                SortDescriptor(\.entityID)
            ]
        )
        return try context.fetch(descriptor)
    }
}

enum DashboardTileSize: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case compact
    case expanded

    var id: Self { self }

    var title: String {
        switch self {
        case .compact:
            "Half Width"
        case .expanded:
            "Full Width"
        }
    }

    var columnSpan: Int {
        switch self {
        case .compact:
            1
        case .expanded:
            2
        }
    }
}

enum HomeAssistantControlStyle: String, Codable, Hashable, Sendable {
    case toggle
    case activate
    case press
    case readOnly
}

struct HAEntitySummary: Identifiable, Hashable, Sendable {
    let entityID: String
    let friendlyName: String
    let domain: String
    let icon: String?
    let controlStyle: HomeAssistantControlStyle
    let unitOfMeasurement: String?
    let deviceClass: String?
    let supportsBrightness: Bool

    var id: String { entityID }

    var suggestedLabel: String {
        friendlyName.isEmpty ? entityID : friendlyName
    }

    var isReadOnly: Bool {
        controlStyle == .readOnly
    }

    func merged(with state: HAEntityState?) -> HAEntitySummary {
        HAEntitySummary(
            entityID: entityID,
            friendlyName: friendlyName,
            domain: domain,
            icon: state?.icon ?? icon,
            controlStyle: controlStyle,
            unitOfMeasurement: state?.unitOfMeasurement ?? unitOfMeasurement,
            deviceClass: state?.deviceClass ?? deviceClass,
            supportsBrightness: state?.supportsBrightness ?? supportsBrightness
        )
    }
}

struct HAEntityState: Identifiable, Hashable, Sendable {
    let entityID: String
    let state: String
    let friendlyName: String?
    let icon: String?
    let unitOfMeasurement: String?
    let deviceClass: String?
    let supportedColorModes: [String]
    let brightness: Int?

    var id: String { entityID }

    var supportsBrightness: Bool {
        if let brightness {
            return brightness > 0 || !supportedColorModes.isEmpty
        }

        return supportedColorModes.contains { mode in
            switch mode.lowercased() {
            case "brightness", "color_temp", "hs", "xy", "rgb", "rgbw", "rgbww", "white":
                return true
            default:
                return false
            }
        }
    }

    var brightnessPercent: Int? {
        guard let brightness else {
            return nil
        }

        return Int((Double(brightness) / 255.0 * 100.0).rounded())
    }
}

struct CertificateTrustRecord: Hashable, Sendable, Codable {
    let host: String
    let fingerprint: String
    let acceptedAt: Date
}

struct SMBItem: Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    let isDirectory: Bool
    let size: Int64?
    let modifiedAt: Date?

    var id: String { path }
}

struct ProfileBackupSnapshot: Codable, Sendable {
    static let currentSchemaVersion = 4

    let schemaVersion: Int
    let exportedAt: Date
    let profile: ProfileBackupProfile
    let homeAssistant: ProfileBackupHomeAssistant
    let smb: ProfileBackupSMB
    let savedSMBConnections: [ProfileBackupSavedSMBConnection]
    let savedCalendarSources: [ProfileBackupSavedCalendarSource]
    let dashboardTiles: [ProfileBackupDashboardTile]
    let notes: ProfileBackupNotes?
}

struct ProfileBackupProfile: Codable, Sendable {
    let username: String
    let displayName: String
    let passwordHash: String
    let passwordSalt: String
    let authModeRawValue: String
    let remoteUserID: String?
    let remoteEmail: String?
}

struct ProfileBackupHomeAssistant: Codable, Sendable {
    let configuration: HomeAssistantConnectionConfiguration
    let token: String
    let trustedCertificates: [CertificateTrustRecord]
}

struct ProfileBackupSMB: Codable, Sendable {
    let configuration: SMBConnectionDetails
    let password: String
}

struct ProfileBackupSavedSMBConnection: Codable, Sendable, Identifiable {
    let id: UUID
    let displayName: String
    let configuration: SMBConnectionDetails
    let password: String
    let isDefault: Bool

    var hasPassword: Bool {
        !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct ProfileBackupSavedCalendarSource: Codable, Sendable, Hashable, Identifiable {
    let id: UUID
    let kindRawValue: String
    let displayName: String
    let remoteIdentifier: String
    let urlString: String
    let sourceTitle: String
    let detailText: String
    let isEnabled: Bool
}

struct ProfileBackupDashboardTile: Codable, Sendable, Hashable {
    let entityID: String
    let labelOverride: String?
    let tileSize: DashboardTileSize
    let isEnabled: Bool
    let gridRow: Int
    let gridColumn: Int
}

struct ProfileBackupNotes: Codable, Sendable, Hashable {
    let configuration: ProfileBackupNotesConfiguration
    let masterKey: String
    let archive: EncryptedNoteArchiveSnapshot
}

struct ProfileBackupNotesConfiguration: Codable, Sendable, Hashable {
    let storageLocation: NotesStorageLocation
    let pendingSMBMigration: Bool
}

struct EncryptedNoteArchiveSnapshot: Codable, Sendable, Hashable {
    let manifest: Data
    let notes: [String: Data]
}

enum ProfileBackupRestoreMode: Equatable, Sendable {
    case full(ProfileRestoreTarget)
    case importNotes(profileID: UUID)
}

enum ProfileMirrorSyncState: String, Codable, Sendable, Hashable {
    case idle
    case synced
    case pending
    case failed
    case repairNeeded
}

enum ProfileMirrorRecoverySource: String, Codable, Sendable, Hashable {
    case none
    case canonical
    case lastKnownGood
    case durable
    case remote
}

struct ProfileMirrorMetadata: Codable, Sendable, Hashable {
    private enum CodingKeys: String, CodingKey {
        case profileID
        case checksum
        case lastValidatedAt
        case lastLocalWriteAt
        case lastDurableWriteAt
        case lastRemotePushAt
        case lastRemotePullAt
        case remoteRevision
        case durableLocationPath
        case durableLastError
        case lastError
        case syncState
        case lastRecoverySource
    }

    let profileID: UUID
    var checksum: String
    var lastValidatedAt: Date?
    var lastLocalWriteAt: Date?
    var lastDurableWriteAt: Date?
    var lastRemotePushAt: Date?
    var lastRemotePullAt: Date?
    var remoteRevision: Int?
    var durableLocationPath: String
    var durableLastError: String
    var lastError: String
    var syncState: ProfileMirrorSyncState
    var lastRecoverySource: ProfileMirrorRecoverySource

    init(
        profileID: UUID,
        checksum: String = "",
        lastValidatedAt: Date? = nil,
        lastLocalWriteAt: Date? = nil,
        lastDurableWriteAt: Date? = nil,
        lastRemotePushAt: Date? = nil,
        lastRemotePullAt: Date? = nil,
        remoteRevision: Int? = nil,
        durableLocationPath: String = "",
        durableLastError: String = "",
        lastError: String = "",
        syncState: ProfileMirrorSyncState = .idle,
        lastRecoverySource: ProfileMirrorRecoverySource = .none
    ) {
        self.profileID = profileID
        self.checksum = checksum
        self.lastValidatedAt = lastValidatedAt
        self.lastLocalWriteAt = lastLocalWriteAt
        self.lastDurableWriteAt = lastDurableWriteAt
        self.lastRemotePushAt = lastRemotePushAt
        self.lastRemotePullAt = lastRemotePullAt
        self.remoteRevision = remoteRevision
        self.durableLocationPath = durableLocationPath
        self.durableLastError = durableLastError
        self.lastError = lastError
        self.syncState = syncState
        self.lastRecoverySource = lastRecoverySource
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try container.decode(UUID.self, forKey: .profileID)
        checksum = try container.decodeIfPresent(String.self, forKey: .checksum) ?? ""
        lastValidatedAt = try container.decodeIfPresent(Date.self, forKey: .lastValidatedAt)
        lastLocalWriteAt = try container.decodeIfPresent(Date.self, forKey: .lastLocalWriteAt)
        lastDurableWriteAt = try container.decodeIfPresent(Date.self, forKey: .lastDurableWriteAt)
        lastRemotePushAt = try container.decodeIfPresent(Date.self, forKey: .lastRemotePushAt)
        lastRemotePullAt = try container.decodeIfPresent(Date.self, forKey: .lastRemotePullAt)
        remoteRevision = try container.decodeIfPresent(Int.self, forKey: .remoteRevision)
        durableLocationPath = try container.decodeIfPresent(String.self, forKey: .durableLocationPath) ?? ""
        durableLastError = try container.decodeIfPresent(String.self, forKey: .durableLastError) ?? ""
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError) ?? ""
        syncState = try container.decodeIfPresent(ProfileMirrorSyncState.self, forKey: .syncState) ?? .idle
        lastRecoverySource = try container.decodeIfPresent(ProfileMirrorRecoverySource.self, forKey: .lastRecoverySource) ?? .none
    }
}

struct ProfileMirrorHealth: Sendable, Hashable {
    let profileID: UUID
    let directoryURL: URL
    let profileURL: URL
    let durableDirectoryURL: URL?
    let durableProfileURL: URL?
    let metadata: ProfileMirrorMetadata
}

enum NotePageType: String, Codable, CaseIterable, Sendable, Hashable {
    case text
    case kanban
    case notebook
}

struct KanbanCard: Codable, Sendable, Hashable, Identifiable {
    let id: UUID
    var text: String
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        text: String,
        sortOrder: Int,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.text = text
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct KanbanColumn: Codable, Sendable, Hashable, Identifiable {
    let id: UUID
    var title: String
    var sortOrder: Int
    var cards: [KanbanCard]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        sortOrder: Int,
        cards: [KanbanCard] = [],
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.sortOrder = sortOrder
        self.cards = cards
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct KanbanBoard: Codable, Sendable, Hashable {
    var columns: [KanbanColumn]
    var createdAt: Date
    var updatedAt: Date

    init(columns: [KanbanColumn] = [], createdAt: Date = .now, updatedAt: Date = .now) {
        self.columns = columns
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct NoteManifestEntry: Codable, Sendable, Hashable, Identifiable {
    let id: UUID
    var title: String
    var parentID: UUID?
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date
    var pageType: NotePageType

    init(
        id: UUID,
        title: String,
        parentID: UUID?,
        sortOrder: Int,
        createdAt: Date,
        updatedAt: Date,
        pageType: NotePageType = .text
    ) {
        self.id = id
        self.title = title
        self.parentID = parentID
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.pageType = pageType
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case parentID
        case sortOrder
        case createdAt
        case updatedAt
        case pageType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        parentID = try container.decodeIfPresent(UUID.self, forKey: .parentID)
        sortOrder = try container.decode(Int.self, forKey: .sortOrder)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        pageType = try container.decodeIfPresent(NotePageType.self, forKey: .pageType) ?? .text
    }
}

struct NotesConfigSnapshot: Sendable, Hashable {
    let storageLocation: NotesStorageLocation
    let pendingSMBMigration: Bool
    let resolvedPath: String

    var effectiveStorageLocation: NotesStorageLocation {
        pendingSMBMigration ? .device : storageLocation
    }
}

struct NotesWorkspaceSnapshot: Sendable, Hashable {
    let configuration: NotesConfigSnapshot
    var entries: [NoteManifestEntry]
    var bodies: [UUID: Data]
    var boards: [UUID: KanbanBoard]
}

enum FilePreviewKind: Equatable, Sendable {
    case text
    case image
    case pdf
    case quickLookFile
    case unsupported
}

struct FilePreviewClassifier {
    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "yaml", "yml", "log", "csv",
        "swift", "js", "ts", "tsx", "jsx", "html", "css", "xml", "sh", "conf"
    ]

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff"
    ]

    private static let quickLookExtensions: Set<String> = [
        "aac", "aif", "aiff", "avi", "bmp", "caf", "doc", "docm", "docx",
        "epub", "flac", "gz", "ics", "key", "m4a", "m4v", "mid", "midi", "mov",
        "mp3", "mp4", "mpeg", "mpg", "numbers", "ods", "odt", "oga", "ogg", "ogv",
        "pages", "pps", "ppsx", "ppt", "pptm", "pptx", "rar", "rtf", "rtfd", "tar",
        "tgz", "wav", "webm", "xls", "xlsb", "xlsm", "xlsx", "zip"
    ]

    static func classify(fileName: String) -> FilePreviewKind {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()

        if ext.isEmpty || textExtensions.contains(ext) {
            return .text
        }

        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .pdf) {
                return .pdf
            }
            if type.conforms(to: .image) {
                return .image
            }
            if type.conforms(to: .plainText)
                || type.conforms(to: .text)
                || type.conforms(to: .sourceCode) {
                return .text
            }
            if type.conforms(to: .movie)
                || type.conforms(to: .video)
                || type.conforms(to: .audio)
                || type.conforms(to: .audiovisualContent)
                || type.conforms(to: .archive)
                || type.conforms(to: .rtf) {
                return .quickLookFile
            }
        }

        if imageExtensions.contains(ext) {
            return .image
        }

        if quickLookExtensions.contains(ext) {
            return .quickLookFile
        }

        return .unsupported
    }
}

struct HomeAssistantServiceCall: Equatable, Sendable {
    let domain: String
    let service: String
    let payload: HomeAssistantServicePayload
}

enum HomeAssistantServicePayload: Equatable, Sendable {
    case entity(entityID: String)
    case lightBrightness(entityID: String, brightnessPercent: Int)

    var body: [String: Any] {
        switch self {
        case .entity(let entityID):
            return ["entity_id": entityID]
        case .lightBrightness(let entityID, let brightnessPercent):
            return [
                "entity_id": entityID,
                "brightness_pct": brightnessPercent
            ]
        }
    }
}

struct HomeAssistantActionResolver {
    private static let turnOnOffDomains: Set<String> = [
        "light",
        "switch",
        "input_boolean",
        "fan",
        "automation",
        "humidifier",
        "media_player",
        "remote",
        "siren"
    ]

    private static let toggleServiceDomains: Set<String> = [
        "cover",
        "valve"
    ]

    private static let activateDomains: Set<String> = [
        "script",
        "scene"
    ]

    private static let pressDomains: Set<String> = [
        "button",
        "input_button"
    ]

    private static let readOnlyDomains: Set<String> = [
        "sensor",
        "binary_sensor"
    ]

    static let supportedDomains: Set<String> = turnOnOffDomains
        .union(toggleServiceDomains)
        .union(activateDomains)
        .union(pressDomains)
        .union(readOnlyDomains)
        .union([
        "lock"
        ])

    static func supports(entityID: String) -> Bool {
        let domain = entityID.split(separator: ".").first.map(String.init) ?? ""
        return supportedDomains.contains(domain)
    }

    static func controlStyle(for domain: String) -> HomeAssistantControlStyle {
        if readOnlyDomains.contains(domain) {
            return .readOnly
        }
        if activateDomains.contains(domain) {
            return .activate
        }
        if pressDomains.contains(domain) {
            return .press
        }

        return .toggle
    }

    static func serviceCall(for entity: HAEntitySummary, state: HAEntityState?) -> HomeAssistantServiceCall? {
        switch entity.controlStyle {
        case .toggle:
            if entity.domain == "lock" {
                let isLocked = state?.state.lowercased() == "locked"
                return HomeAssistantServiceCall(
                    domain: entity.domain,
                    service: isLocked ? "unlock" : "lock",
                    payload: .entity(entityID: entity.entityID)
                )
            }

            if toggleServiceDomains.contains(entity.domain) {
                return HomeAssistantServiceCall(
                    domain: entity.domain,
                    service: "toggle",
                    payload: .entity(entityID: entity.entityID)
                )
            }

            let isOn = isActive(state)
            return HomeAssistantServiceCall(
                domain: entity.domain,
                service: isOn ? "turn_off" : "turn_on",
                payload: .entity(entityID: entity.entityID)
            )
        case .activate:
            return HomeAssistantServiceCall(
                domain: entity.domain,
                service: "turn_on",
                payload: .entity(entityID: entity.entityID)
            )
        case .press:
            return HomeAssistantServiceCall(
                domain: entity.domain,
                service: "press",
                payload: .entity(entityID: entity.entityID)
            )
        case .readOnly:
            return nil
        }
    }

    static func brightnessServiceCall(for entity: HAEntitySummary, brightnessPercent: Int) -> HomeAssistantServiceCall? {
        guard entity.domain == "light", entity.supportsBrightness else {
            return nil
        }

        let clampedBrightness = max(1, min(100, brightnessPercent))
        return HomeAssistantServiceCall(
            domain: entity.domain,
            service: "turn_on",
            payload: .lightBrightness(entityID: entity.entityID, brightnessPercent: clampedBrightness)
        )
    }

    private static func isActive(_ state: HAEntityState?) -> Bool {
        guard let stateValue = state?.state.lowercased() else {
            return false
        }

        return !["off", "unavailable", "unknown"].contains(stateValue)
    }
}
