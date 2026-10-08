import SwiftData
import Security
import XCTest
@testable import Hank

final class AuthAndKeychainTests: XCTestCase {
    @MainActor
    func testLocalProfileAuthCreatesAndResumesRememberedProfile() throws {
        let schema = Schema([UserProfile.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let service = LocalProfileAuthService()

        let session = try service.createProfile(
            username: "admin",
            password: "admin123!",
            rememberSession: true,
            in: context
        )

        XCTAssertEqual(session.username, "admin")
        XCTAssertEqual(session.displayName, "admin")
        XCTAssertTrue(service.isAuthenticated)
        XCTAssertEqual(try UserProfile.fetchRemembered(in: context).count, 1)

        let resumed = try service.resumeRememberedSession(in: context)

        XCTAssertEqual(resumed?.profileID, session.profileID)
    }

    @MainActor
    func testLocalProfileAuthRejectsUnexpectedCredentials() throws {
        let schema = Schema([UserProfile.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let service = LocalProfileAuthService()

        let session = try service.createProfile(
            username: "operator",
            password: "secret12",
            rememberSession: false,
            in: context
        )

        XCTAssertThrowsError(
            try service.login(profileID: session.profileID, password: "wrong", rememberSession: false, in: context)
        ) { error in
            XCTAssertEqual(error.localizedDescription, AuthError.invalidCredentials.localizedDescription)
        }
    }

    @MainActor
    func testLocalProfileAuthVerifiesPasswordWithoutStartingSession() throws {
        let schema = Schema([UserProfile.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let service = LocalProfileAuthService()

        let session = try service.createProfile(
            username: "restore-user",
            password: "restore123!",
            rememberSession: false,
            in: context
        )
        try service.logout(profileID: nil, in: context)

        try service.verifyPassword(profileID: session.profileID, password: "restore123!", in: context)
        XCTAssertNil(service.currentSession)

        XCTAssertThrowsError(
            try service.verifyPassword(profileID: session.profileID, password: "wrong", in: context)
        ) { error in
            XCTAssertEqual(error.localizedDescription, AuthError.invalidCredentials.localizedDescription)
        }
    }

    @MainActor
    func testLocalProfileAuthResumesMostRecentRememberedProfile() throws {
        let schema = Schema([UserProfile.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let service = LocalProfileAuthService()

        let firstSession = try service.createProfile(
            username: "admin",
            password: "admin123!",
            rememberSession: true,
            in: context
        )
        let secondSession = try service.createProfile(
            username: "operator",
            password: "operator123!",
            rememberSession: true,
            in: context
        )

        XCTAssertEqual(try UserProfile.fetchRemembered(in: context).map(\.username).sorted(), ["admin", "operator"])

        try service.logout(profileID: nil, in: context)
        let resumed = try service.resumeRememberedSession(in: context)

        XCTAssertEqual(resumed?.profileID, secondSession.profileID)
        XCTAssertNotEqual(resumed?.profileID, firstSession.profileID)
        XCTAssertEqual(service.currentSession?.profileID, secondSession.profileID)
    }

    @MainActor
    func testProvisionHankRemoteProfileCreatesAndReusesRemoteBackedProfile() throws {
        let schema = Schema([UserProfile.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let service = LocalProfileAuthService()

        let remoteUser = HankRemoteUser(
            id: "usr_remote_1",
            email: "person@example.com",
            createdAt: .now,
            updatedAt: .now
        )

        let firstSession = try service.provisionHankRemoteProfile(
            user: remoteUser,
            rememberSession: true,
            in: context
        )

        let profile = try XCTUnwrap(UserProfile.fetch(id: firstSession.profileID, in: context))
        XCTAssertEqual(profile.authMode, .hankRemote)
        XCTAssertEqual(profile.remoteUserID, remoteUser.id)
        XCTAssertEqual(profile.remoteEmail, remoteUser.email)
        XCTAssertEqual(profile.effectiveLoginIdentifier, remoteUser.email)
        XCTAssertTrue(profile.rememberedSession)

        let secondSession = try service.provisionHankRemoteProfile(
            user: remoteUser,
            rememberSession: false,
            in: context
        )

        XCTAssertEqual(secondSession.profileID, firstSession.profileID)
        XCTAssertEqual(try UserProfile.fetchAll(in: context).count, 1)
    }

    func testKeychainSaveLoadDeleteAndPrefixEnumeration() throws {
        let service = InMemoryKeychainStore()

        try service.set("secret-token", for: "profile:a:token")
        try service.set("secret-password", for: "profile:a:password")
        try service.set("other", for: "profile:b:token")

        XCTAssertEqual(try service.string(for: "profile:a:token"), "secret-token")
        XCTAssertEqual(try service.entries(matchingPrefix: "profile:a").count, 2)

        try service.deleteValues(matchingPrefix: "profile:a")

        XCTAssertNil(try service.string(for: "profile:a:token"))
        XCTAssertEqual(try service.string(for: "profile:b:token"), "other")
    }

    func testAppServicesTreatsMissingEntitlementSecretReadsAsMissingValues() throws {
        let services = AppServices(keychain: MissingEntitlementKeychainStore())
        let profileID = UUID()
        let connectionID = UUID()

        XCTAssertNil(try services.hankRemoteAccessToken())
        XCTAssertNil(try services.homeAssistantToken(for: profileID))
        XCTAssertNil(try services.smbPassword(for: connectionID, profileID: profileID))
        XCTAssertNil(try services.notesMasterKey(for: profileID))
    }

    @MainActor
    func testMigrationServiceTreatsMissingEntitlementLegacyReadsAsNoLegacyState() throws {
        let schema = Schema([
            UserProfile.self,
            HomeAssistantConfig.self,
            SMBConnectionConfig.self,
            DashboardShortcut.self
        ])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let services = AppServices(keychain: MissingEntitlementKeychainStore())

        XCTAssertNoThrow(try services.migrationService.migrateIfNeeded(context: context, services: services))
        XCTAssertTrue(try UserProfile.fetchAll(in: context).isEmpty)
    }

    func testAppServicesStoresDurableBackupBookmarkDataInKeychain() throws {
        let services = AppServices(keychain: InMemoryKeychainStore())
        let profileID = UUID()
        let bookmarkData = Data([0x48, 0x61, 0x6E, 0x6B])

        try services.setDurableBackupBookmarkData(bookmarkData, for: profileID)

        XCTAssertEqual(try services.durableBackupBookmarkData(for: profileID), bookmarkData)

        try services.clearDurableBackupBookmarkData(for: profileID)

        XCTAssertNil(try services.durableBackupBookmarkData(for: profileID))
    }

    func testProfileMirrorMetadataDecodesOlderStoredPayloadWithoutDurableFields() throws {
        let profileID = UUID()
        let json = """
        {
          "profileID": "\(profileID.uuidString)",
          "checksum": "abc123",
          "lastError": "",
          "syncState": "synced",
          "lastRecoverySource": "canonical"
        }
        """.data(using: .utf8)!

        let metadata = try JSONDecoder().decode(ProfileMirrorMetadata.self, from: json)

        XCTAssertEqual(metadata.profileID, profileID)
        XCTAssertEqual(metadata.checksum, "abc123")
        XCTAssertEqual(metadata.durableLocationPath, "")
        XCTAssertEqual(metadata.durableLastError, "")
        XCTAssertNil(metadata.lastDurableWriteAt)
    }
}

private final class MissingEntitlementKeychainStore: KeychainStoring {
    func set(_ value: String, for key: String) throws {}

    func string(for key: String) throws -> String? {
        throw KeychainError.unexpectedStatus(errSecMissingEntitlement)
    }

    func deleteValue(for key: String) throws {}

    func entries(matchingPrefix prefix: String) throws -> [String: String] {
        throw KeychainError.unexpectedStatus(errSecMissingEntitlement)
    }

    func deleteValues(matchingPrefix prefix: String) throws {}
}
