import SwiftData
import UIKit
import XCTest
@testable import Hank

final class SupportLogicTests: XCTestCase {
    func testNotificationSettingsDecodeDefaultsMissingCategoryToggles() throws {
        let data = Data(#"{"user_id":"usr_1","updated_at":"2026-05-09T12:00:00Z"}"#.utf8)
        let decoder = JSONDecoder()
        HankRemoteDateCoding.configure(decoder)

        let settings = try decoder.decode(HankRemoteNotificationSettings.self, from: data)

        XCTAssertEqual(settings.userID, "usr_1")
        XCTAssertTrue(settings.storage)
        XCTAssertTrue(settings.notes)
        XCTAssertTrue(settings.dashboardEntities)
        XCTAssertNotNil(settings.updatedAt)
    }

    func testAssistantStagedAttachmentDecodeDefaultsSubmittedState() throws {
        let id = UUID()
        let profileID = UUID()
        let data = Data("""
        {
          "id": "\(id.uuidString)",
          "clientAttachmentID": "\(id.uuidString)",
          "profileID": "\(profileID.uuidString)",
          "sessionRemoteID": "asess_1",
          "filename": "report.pdf",
          "contentType": "application/pdf",
          "kind": "document",
          "sizeBytes": 42,
          "checksumSHA256": "abc123",
          "localRelativePath": "\(profileID.uuidString)/asess_1/\(id.uuidString)/report.pdf",
          "createdAt": 0,
          "expiresAt": 3600
        }
        """.utf8)

        let attachment = try JSONDecoder().decode(HankAssistantStagedAttachment.self, from: data)

        XCTAssertFalse(attachment.isSubmitted)

        var submitted = attachment
        submitted.isSubmitted = true
        let roundTripped = try JSONDecoder().decode(
            HankAssistantStagedAttachment.self,
            from: JSONEncoder().encode(submitted)
        )
        XCTAssertTrue(roundTripped.isSubmitted)
    }

    @MainActor
    func testFileBrowserBackgroundSearchWarmupFeedsLaterSearch() async {
        let store = FileBrowserStore()
        let docs = SMBItem(path: "docs", name: "docs", isDirectory: true, size: nil, modifiedAt: nil)
        let nested = SMBItem(path: "docs/manuals", name: "manuals", isDirectory: true, size: nil, modifiedAt: nil)
        let guide = SMBItem(path: "docs/manuals/guide.pdf", name: "guide.pdf", isDirectory: false, size: 80, modifiedAt: nil)
        let service = RecordingSMBService(
            listings: [
                "": [docs],
                "docs": [nested],
                "docs/manuals": [guide]
            ]
        )
        let services = AppServices(keychain: InMemoryKeychainStore(), smbService: service)

        store.primeForTesting(items: [docs], currentPath: "")
        store.warmSearchIndex(services: services)
        store.searchText = "manuals guide"

        await store.performSearch(using: service)

        XCTAssertEqual(store.browserItems.map(\.path), ["docs/manuals/guide.pdf"])
        XCTAssertEqual(store.searchState, .ready(1))
        XCTAssertFalse(store.isSearchIndexWarming)
        XCTAssertTrue(service.downloadRequests.isEmpty)
    }

    @MainActor
    func testFileBrowserLoadStartsOnConnectionsPageWhenConnectionsExist() async throws {
        let context = try makeModelContext(schema: [HankRemoteSettings.self, SavedSMBConnection.self, SMBConnectionConfig.self])
        let profileID = UUID()
        let connection = SavedSMBConnection(
            profileID: profileID,
            displayName: "Media",
            host: "nas.local",
            shareName: "media",
            username: "alex",
            port: 445,
            startPath: "",
            isDefault: true
        )
        context.insert(connection)
        try context.save()

        let service = RecordingSMBService(listings: ["": []], connectDelayNanoseconds: 100_000_000)
        let services = AppServices(keychain: InMemoryKeychainStore(), smbService: service)
        try services.setSMBPassword("secret", for: connection.id, profileID: profileID)
        let store = FileBrowserStore()

        await store.load(profileID: profileID, modelContext: context, services: services)

        XCTAssertEqual(store.connectionState, .connections)
        XCTAssertTrue(store.isShowingConnectionsPage)
        XCTAssertEqual(store.availableConnections.map(\.displayName), ["Media"])
        XCTAssertEqual(store.selectedConnectionID, connection.id)
    }

    @MainActor
    func testFileBrowserSwitchesConnectionsUsingCachedStateImmediately() async throws {
        let context = try makeModelContext(schema: [HankRemoteSettings.self, SavedSMBConnection.self, SMBConnectionConfig.self])
        let profileID = UUID()
        let firstConnection = SavedSMBConnection(
            profileID: profileID,
            displayName: "Archive",
            host: "nas.local",
            shareName: "media",
            username: "alex",
            port: 445,
            startPath: "archive",
            isDefault: true
        )
        let secondConnection = SavedSMBConnection(
            profileID: profileID,
            displayName: "Projects",
            host: "nas.local",
            shareName: "media",
            username: "alex",
            port: 445,
            startPath: "projects",
            isDefault: false
        )
        context.insert(firstConnection)
        context.insert(secondConnection)
        try context.save()

        let archivedFile = SMBItem(path: "archive/Taxes.pdf", name: "Taxes.pdf", isDirectory: false, size: 1, modifiedAt: nil)
        let updatedArchivedFile = SMBItem(path: "archive/Taxes 2026.pdf", name: "Taxes 2026.pdf", isDirectory: false, size: 1, modifiedAt: nil)
        let projectFile = SMBItem(path: "projects/Plan.md", name: "Plan.md", isDirectory: false, size: 1, modifiedAt: nil)
        let service = RecordingSMBService(
            listings: [
                "archive": [archivedFile],
                "projects": [projectFile]
            ],
            connectDelayNanoseconds: 120_000_000
        )
        let services = AppServices(keychain: InMemoryKeychainStore(), smbService: service)
        try services.saveHankRemoteSettings(HankRemoteSettingsSnapshot(isEnabled: true, cloudURL: "http://127.0.0.1:1"), in: context)
        try services.setHankRemoteAccessToken("session-token")
        try services.setSMBPassword("secret-a", for: firstConnection.id, profileID: profileID)
        try services.setSMBPassword("secret-b", for: secondConnection.id, profileID: profileID)
        let store = FileBrowserStore()

        await store.load(profileID: profileID, modelContext: context, services: services)
        await store.selectConnection(firstConnection.id, profileID: profileID, modelContext: context, services: services)
        await waitUntil {
            store.connectionState == .connected && store.browserItems.map(\.name) == ["Taxes.pdf"]
        }

        await store.selectConnection(secondConnection.id, profileID: profileID, modelContext: context, services: services)
        await waitUntil {
            store.connectionState == .connected && store.browserItems.map(\.name) == ["Plan.md"]
        }

        service.listings["archive"] = [updatedArchivedFile]

        await store.selectConnection(firstConnection.id, profileID: profileID, modelContext: context, services: services)

        XCTAssertEqual(store.connectionState, .connected)
        XCTAssertEqual(store.browserItems.map(\.name), ["Taxes.pdf"])

        await waitUntil {
            store.browserItems.map(\.name) == ["Taxes 2026.pdf"]
        }
    }

    @MainActor
    func testFileBrowserLoadCoalescesOverlappingRefreshes() async throws {
        let context = try makeModelContext(schema: [HankRemoteSettings.self, SavedSMBConnection.self, SMBConnectionConfig.self])
        let profileID = UUID()
        let connection = SavedSMBConnection(
            profileID: profileID,
            displayName: "Media",
            host: "nas.local",
            shareName: "media",
            username: "alex",
            port: 445,
            startPath: "",
            isDefault: true
        )
        context.insert(connection)
        try context.save()

        let service = RecordingSMBService(
            listings: ["": []],
            connectDelayNanoseconds: 100_000_000
        )
        let services = AppServices(keychain: InMemoryKeychainStore(), smbService: service)
        try services.saveHankRemoteSettings(HankRemoteSettingsSnapshot(isEnabled: true, cloudURL: "http://127.0.0.1:1"), in: context)
        try services.setHankRemoteAccessToken("session-token")
        try services.setSMBPassword("secret", for: connection.id, profileID: profileID)
        let store = FileBrowserStore()

        let firstLoad = Task {
            await store.load(profileID: profileID, modelContext: context, services: services)
        }
        let secondLoad = Task {
            await store.load(profileID: profileID, modelContext: context, services: services)
        }

        await firstLoad.value
        await secondLoad.value
        await waitUntil {
            !store.isConnectionLoading(connection.id)
        }

        XCTAssertEqual(service.connectCallCount, 1)
        XCTAssertEqual(service.listRequests, [""])
        XCTAssertEqual(store.connectionState, .connections)
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testFileBrowserBackgroundPreservesConnectedDirectoryCache() async throws {
        let context = try makeModelContext(schema: [HankRemoteSettings.self, SavedSMBConnection.self, SMBConnectionConfig.self])
        let profileID = UUID()
        let connection = SavedSMBConnection(
            profileID: profileID,
            displayName: "Media",
            host: "nas.local",
            shareName: "media",
            username: "alex",
            port: 445,
            startPath: "shows",
            isDefault: true
        )
        context.insert(connection)
        try context.save()

        let episode = SMBItem(path: "shows/Episode.mkv", name: "Episode.mkv", isDirectory: false, size: 1, modifiedAt: nil)
        let service = RecordingSMBService(listings: ["shows": [episode]])
        let services = AppServices(keychain: InMemoryKeychainStore(), smbService: service)
        try services.saveHankRemoteSettings(HankRemoteSettingsSnapshot(isEnabled: true, cloudURL: "http://127.0.0.1:1"), in: context)
        try services.setHankRemoteAccessToken("session-token")
        try services.setSMBPassword("secret", for: connection.id, profileID: profileID)
        let store = FileBrowserStore()

        await store.load(profileID: profileID, modelContext: context, services: services)
        await store.selectConnection(connection.id, profileID: profileID, modelContext: context, services: services)
        await waitUntil {
            store.connectionState == .connected && store.browserItems.map(\.name) == ["Episode.mkv"]
        }

        store.prepareForAppBackground()

        XCTAssertEqual(store.connectionState, .connected)
        XCTAssertEqual(store.currentPath, "shows")
        XCTAssertEqual(store.browserItems.map(\.name), ["Episode.mkv"])
    }

    @MainActor
    func testFileBrowserSearchRestoresPersistedIndexWithoutRecrawlingSMB() async {
        let persistence = InMemorySearchIndexPersistence()
        let docs = SMBItem(path: "docs", name: "docs", isDirectory: true, size: nil, modifiedAt: nil)
        let receipt = SMBItem(path: "docs/receipt.pdf", name: "receipt.pdf", isDirectory: false, size: 12, modifiedAt: nil)
        let initialService = RecordingSMBService(
            listings: [
                "": [docs],
                "docs": [receipt]
            ]
        )

        let firstStore = FileBrowserStore(searchIndexPersistence: persistence)
        firstStore.primeForTesting(items: [docs], currentPath: "", searchScopeKey: "persisted-scope")
        firstStore.searchText = "receipt"
        await firstStore.performSearch(using: initialService)

        XCTAssertEqual(firstStore.browserItems.map(\.path), ["docs/receipt.pdf"])
        XCTAssertEqual(initialService.listRequests, ["docs"])

        let restoredService = RecordingSMBService(listings: ["": [docs]])
        let restoredStore = FileBrowserStore(searchIndexPersistence: persistence)
        restoredStore.primeForTesting(items: [docs], currentPath: "", searchScopeKey: "persisted-scope")
        restoredStore.searchText = "receipt"

        await restoredStore.performSearch(using: restoredService)

        XCTAssertEqual(restoredStore.browserItems.map(\.path), ["docs/receipt.pdf"])
        XCTAssertTrue(restoredService.listRequests.isEmpty)
        XCTAssertEqual(restoredStore.searchState, .ready(1))
    }

    @MainActor
    func testFileBrowserDeleteRemovesNestedResultsFromExistingSearchIndex() async {
        let store = FileBrowserStore(searchIndexPersistence: InMemorySearchIndexPersistence())
        let docs = SMBItem(path: "docs", name: "docs", isDirectory: true, size: nil, modifiedAt: nil)
        let receipt = SMBItem(path: "docs/receipt.pdf", name: "receipt.pdf", isDirectory: false, size: 12, modifiedAt: nil)
        let service = RecordingSMBService(
            listings: [
                "": [docs],
                "docs": [receipt]
            ]
        )

        store.primeForTesting(items: [docs], currentPath: "", searchScopeKey: "delete-scope")
        store.searchText = "receipt"
        await store.performSearch(using: service)

        XCTAssertEqual(store.browserItems.map(\.path), ["docs/receipt.pdf"])

        service.listings[""] = []
        store.enterSelectionMode()
        store.toggleSelection(for: docs)

        await store.deleteSelectedItems(using: service)
        await store.performSearch(using: service)

        XCTAssertEqual(store.browserItems.map(\.path), [])
        XCTAssertEqual(store.searchState, .ready(0))
    }

    @MainActor
    func testFileBrowserImagePreviewUsesCacheForRepeatedOpens() async {
        let store = FileBrowserStore()
        let image = SMBItem(
            path: "photos/cabin.jpg",
            name: "cabin.jpg",
            isDirectory: false,
            size: 4,
            modifiedAt: Date(timeIntervalSince1970: 123)
        )
        let service = RecordingSMBService(
            listings: ["photos": [image]],
            downloads: ["photos/cabin.jpg": Data([0xff, 0xd8, 0xff, 0xd9])]
        )
        let services = AppServices(keychain: InMemoryKeychainStore(), smbService: service)

        store.primeForTesting(items: [image], currentPath: "photos", activeService: service)

        await store.open(image, services: services)
        await store.open(image, services: services)

        XCTAssertTrue(service.downloadRequests.isEmpty)
        XCTAssertEqual(service.downloadToFileRequests, ["photos/cabin.jpg"])
        XCTAssertNil(store.errorMessage)
    }

    func testSMBFileServiceDisconnectsPreviousRemoteSessionWhenCredentialsChange() async throws {
        let firstSession = RecordingSMBRemoteSession()
        let secondSession = RecordingSMBRemoteSession()
        let sessionSequence = RecordingSMBRemoteSessionSequence([firstSession, secondSession])
        let service = SMBFileService { _ in
            sessionSequence.next()
        }
        let firstConfig = SMBConnectionDetails(host: "nas.local", shareName: "media", username: "aaron", port: 445, startPath: "")
        let secondConfig = SMBConnectionDetails(host: "nas.local", shareName: "media", username: "alex", port: 445, startPath: "")
        let remoteAccess = HankRemoteConnectionContext(cloudURL: "http://127.0.0.1:1", sessionToken: "session-token")

        try await service.connect(config: firstConfig, password: "secret-1", context: remoteAccess)
        try await service.connect(config: secondConfig, password: "secret-2", context: remoteAccess)

        XCTAssertEqual(firstSession.disconnectCallCount, 1)
        XCTAssertEqual(secondSession.loggedInUsername, "alex")
        XCTAssertEqual(secondSession.connectedShare, "media")
    }

    func testSMBFileServiceDisconnectsPreviousRemoteSessionWhenServerAndShareChange() async throws {
        let firstSession = RecordingSMBRemoteSession()
        let secondSession = RecordingSMBRemoteSession()
        let sessionSequence = RecordingSMBRemoteSessionSequence([firstSession, secondSession])
        let service = SMBFileService { config in
            let session = sessionSequence.next()
            session.connectedConfig = config
            return session
        }
        let firstConfig = SMBConnectionDetails(host: "nas-a.local", shareName: "media-a", username: "alex", port: 445, startPath: "")
        let secondConfig = SMBConnectionDetails(host: "nas-b.local", shareName: "media-b", username: "jamie", port: 445, startPath: "")
        let remoteAccess = HankRemoteConnectionContext(cloudURL: "http://127.0.0.1:1", sessionToken: "session-token")

        try await service.connect(config: firstConfig, password: "secret-a", context: remoteAccess)
        try await service.connect(config: secondConfig, password: "secret-b", context: remoteAccess)

        XCTAssertEqual(firstSession.disconnectCallCount, 1)
        XCTAssertEqual(secondSession.connectedConfig?.host, "nas-b.local")
        XCTAssertEqual(secondSession.loggedInUsername, "jamie")
        XCTAssertEqual(secondSession.connectedShare, "media-b")
    }

    func testSMBFileServiceReusesExistingSessionWhenConfigIsUnchanged() async throws {
        let session = RecordingSMBRemoteSession()
        let factoryCallCount = MutableCounter()
        let service = SMBFileService { _ in
            factoryCallCount.value += 1
            return session
        }
        let config = SMBConnectionDetails(host: "nas.local", shareName: "media", username: "aaron", port: 445, startPath: "")
        let remoteAccess = HankRemoteConnectionContext(cloudURL: "http://127.0.0.1:1", sessionToken: "session-token")

        try await service.connect(config: config, password: "secret", context: remoteAccess)
        try await service.connect(config: config, password: "secret", context: remoteAccess)

        XCTAssertEqual(factoryCallCount.value, 1)
        XCTAssertEqual(session.disconnectCallCount, 0)
        XCTAssertEqual(session.loggedInUsername, "aaron")
        XCTAssertEqual(session.connectedShare, "media")
    }

    func testSMBFileServiceDisconnectsFailedRemoteSessionAfterLoginError() async {
        struct ExpectedError: LocalizedError {
            var errorDescription: String? { "Access denied" }
        }

        let session = RecordingSMBRemoteSession(loginError: ExpectedError())
        let service = SMBFileService { _ in session }
        let config = SMBConnectionDetails(host: "nas.local", shareName: "media", username: "aaron", port: 445, startPath: "")
        let remoteAccess = HankRemoteConnectionContext(cloudURL: "http://127.0.0.1:1", sessionToken: "session-token")

        do {
            try await service.connect(config: config, password: "secret", context: remoteAccess)
            XCTFail("Expected login error to throw")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "SMB login failed: Access denied."
            )
        }

        XCTAssertEqual(session.disconnectCallCount, 1)
    }

    func testSMBFileServiceReportsWhenRemoteShareConnectFailsAfterSuccessfulLogin() async {
        struct ExpectedError: LocalizedError {
            var errorDescription: String? { "Access Denied" }
        }

        let session = RecordingSMBRemoteSession(connectShareError: ExpectedError())
        let service = SMBFileService { _ in session }
        let config = SMBConnectionDetails(host: "nas.local", shareName: "media", username: "aaron", port: 445, startPath: "")
        let remoteAccess = HankRemoteConnectionContext(cloudURL: "http://127.0.0.1:1", sessionToken: "session-token")

        do {
            try await service.connect(config: config, password: "secret", context: remoteAccess)
            XCTFail("Expected share connect error to throw")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                #"SMB login succeeded, but Hank could not connect to share "media": Access Denied."#
            )
        }
    }

    func testSMBFileServiceEnumeratesRemoteSharesBeforeConnectingToRequestedShare() async throws {
        let session = RecordingSMBRemoteSession(shareNames: ["media", "archive"])
        let service = SMBFileService { _ in session }
        let config = SMBConnectionDetails(host: "nas.local", shareName: "media", username: "aaron", port: 445, startPath: "")
        let remoteAccess = HankRemoteConnectionContext(cloudURL: "http://127.0.0.1:1", sessionToken: "session-token")

        try await service.connect(config: config, password: "secret", context: remoteAccess)

        XCTAssertEqual(session.listSharesCallCount, 1)
        XCTAssertEqual(session.connectedShare, "media")
    }

    func testSMBFileServiceContinuesWhenRemoteShareEnumerationFails() async throws {
        struct ExpectedError: LocalizedError {
            var errorDescription: String? { "Access Denied" }
        }

        let session = RecordingSMBRemoteSession(listSharesError: ExpectedError())
        let service = SMBFileService { _ in session }
        let config = SMBConnectionDetails(host: "nas.local", shareName: "media", username: "aaron", port: 445, startPath: "")
        let remoteAccess = HankRemoteConnectionContext(cloudURL: "http://127.0.0.1:1", sessionToken: "session-token")

        try await service.connect(config: config, password: "secret", context: remoteAccess)

        XCTAssertEqual(session.listSharesCallCount, 1)
        XCTAssertEqual(session.connectedShare, "media")
    }

    @MainActor
    func testSettingsSMBValidationUsesIsolatedServiceInstance() async throws {
        let context = try makeModelContext(schema: [HankRemoteSettings.self, SavedSMBConnection.self, SMBConnectionConfig.self])
        let profileID = UUID()
        let sharedService = RecordingSMBService()
        let validationService = RecordingSMBService()
        let validationFactoryCallCount = MutableCounter()
        let store = SettingsStore { _ in
            validationFactoryCallCount.value += 1
            return validationService
        }
        let services = AppServices(keychain: InMemoryKeychainStore(), smbService: sharedService)
        try services.saveHankRemoteSettings(HankRemoteSettingsSnapshot(isEnabled: true, cloudURL: "http://127.0.0.1:1"), in: context)
        try services.setHankRemoteAccessToken("session-token")

        store.smb = SMBConnectionDetails(host: "nas.local", shareName: "media", username: "alex", port: 445, startPath: "")
        store.smbPassword = "secret"

        await store.testSMB(profileID: profileID, modelContext: context, services: services)

        XCTAssertEqual(validationFactoryCallCount.value, 1)
        XCTAssertEqual(validationService.connectCallCount, 1)
        XCTAssertEqual(validationService.listRequests, [""])
        XCTAssertEqual(validationService.disconnectCallCount, 1)
        XCTAssertEqual(sharedService.connectCallCount, 0)
        XCTAssertTrue(sharedService.listRequests.isEmpty)
        XCTAssertEqual(store.infoMessage, "SMB connection succeeded.")
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testNotesWorkspaceLoadUsesRemoteOfflineCacheWithoutSMBServiceInstances() async throws {
        let context = try makeModelContext(schema: [UserProfile.self, HankRemoteSettings.self, NotesConfig.self, SavedSMBConnection.self, SMBConnectionConfig.self])
        let profileID = UUID()
        let profile = UserProfile(
            id: profileID,
            username: "remote-notes",
            displayName: "Remote Notes",
            passwordHash: "hash",
            passwordSalt: "salt",
            authModeRawValue: UserProfileAuthMode.hankRemote.rawValue,
            remoteUserID: "remote-notes-user",
            remoteEmail: "remote-notes@example.com"
        )
        let notesConfig = NotesConfig(
            profileID: profileID,
            storageLocationRawValue: NotesStorageLocation.smb.rawValue
        )
        let smbConfig = SavedSMBConnection(
            profileID: profileID,
            displayName: "Media",
            host: "nas.local",
            shareName: "media",
            username: "alex",
            port: 445,
            startPath: "",
            isDefault: true
        )
        context.insert(profile)
        context.insert(notesConfig)
        context.insert(smbConfig)
        try context.save()

        let sharedService = RecordingSMBService()
        let transientService = RecordingSMBService()
        let transientFactoryCallCount = MutableCounter()
        let services = AppServices(
            keychain: InMemoryKeychainStore(),
            smbService: sharedService,
            smbServiceFactory: { _ in
                transientFactoryCallCount.value += 1
                return transientService
            }
        )
        try services.setSMBPassword("secret", for: smbConfig.id, profileID: profileID)
        try services.saveHankRemoteSettings(HankRemoteSettingsSnapshot(isEnabled: true, cloudURL: "http://127.0.0.1:1"), in: context)
        try services.setHankRemoteAccessToken("session-token")

        var cachedWorkspace = NoteTreeManager.makeDefaultArchive()
        let noteID = try XCTUnwrap(cachedWorkspace.entries.first?.id)
        NoteTreeManager.rename(noteID: noteID, to: "Remote Cache", entries: &cachedWorkspace.entries)
        try await services.notesService.saveWorkspace(
            cachedWorkspace,
            profileID: profileID,
            modelContext: context,
            services: services
        )

        let workspace = try await services.notesService.loadWorkspace(
            profileID: profileID,
            modelContext: context,
            services: services
        )

        XCTAssertEqual(workspace.entries.count, 1)
        XCTAssertEqual(workspace.entries.first?.title, "Remote Cache")
        XCTAssertEqual(transientFactoryCallCount.value, 0)
        XCTAssertEqual(transientService.connectCallCount, 0)
        XCTAssertEqual(transientService.disconnectCallCount, 0)
        XCTAssertEqual(sharedService.connectCallCount, 0)
        XCTAssertTrue(sharedService.listRequests.isEmpty)
    }

    @MainActor
    func testSavedSMBConnectionsMigrateLegacyConfigAndPassword() throws {
        let context = try makeModelContext(schema: [SavedSMBConnection.self, SMBConnectionConfig.self])
        let profileID = UUID()
        let legacyConfig = SMBConnectionConfig(
            profileID: profileID,
            host: "legacy.local",
            shareName: "archive",
            username: "alex",
            port: 445,
            startPath: "docs"
        )
        context.insert(legacyConfig)
        try context.save()

        let services = AppServices(keychain: InMemoryKeychainStore())
        try services.keychain.set("legacy-secret", for: "profile:\(profileID.uuidString.lowercased()):smb-password")

        let connections = try services.savedSMBConnections(for: profileID, in: context)

        XCTAssertEqual(connections.count, 1)
        XCTAssertEqual(connections.first?.connectionDetails.host, "legacy.local")
        XCTAssertEqual(connections.first?.connectionDetails.shareName, "archive")
        XCTAssertEqual(connections.first?.connectionDetails.startPath, "docs")
        XCTAssertEqual(try services.smbPassword(for: connections[0].id, profileID: profileID), "legacy-secret")
        XCTAssertNil(try SMBConnectionConfig.fetch(for: profileID, in: context))
    }

    func testHankRemoteHomeRoleDecodesLegacyOwnerAsAdmin() throws {
        let role = try JSONDecoder().decode(HankRemoteHomeRole.self, from: Data(#""owner""#.utf8))

        XCTAssertEqual(role, .admin)
    }

    func testHankRemoteConnectionContextIgnoresLegacyHomeID() throws {
        let context = try makeModelContext(schema: [HankRemoteSettings.self])
        let services = AppServices(keychain: InMemoryKeychainStore())
        try services.saveHankRemoteSettings(
            HankRemoteSettingsSnapshot(
                isEnabled: true,
                cloudURL: "http://127.0.0.1:8080",
                homeID: "   "
            ),
            in: context
        )
        try services.setHankRemoteAccessToken("session-token")

        let remoteContext = try services.hankRemoteConnectionContext(in: context)

        XCTAssertEqual(remoteContext?.cloudURL, "http://127.0.0.1:8080")
        XCTAssertEqual(remoteContext?.sessionToken, "session-token")
    }

    func testHankRemoteConnectionContextHasNoHomeIDField() {
        let context = HankRemoteConnectionContext(
            cloudURL: "http://127.0.0.1:8080",
            sessionToken: "session-token"
        )

        let labels = Mirror(reflecting: context).children.compactMap(\.label)

        XCTAssertEqual(labels, ["cloudURL", "sessionToken"])
    }

    func testAppCommandEnvelopeDoesNotSendHomeID() throws {
        let bodyData = try JSONSerialization.data(withJSONObject: ["path": "/Documents"])

        let envelope = try HankRemoteService.appCommandEnvelope(
            command: "files.list",
            bodyData: bodyData,
            requestID: "request-1",
            timestamp: "2026-04-30T19:00:00Z"
        )

        XCTAssertNil(envelope["home_id"])
        XCTAssertEqual(envelope["request_id"] as? String, "request-1")
        XCTAssertEqual(envelope["type"] as? String, "app.command")
        let payload = try XCTUnwrap(envelope["payload"] as? [String: Any])
        XCTAssertEqual(payload["command"] as? String, "files.list")
        XCTAssertNil(payload["home_id"])
        XCTAssertNotNil(payload["body"] as? [String: Any])
    }

    func testTransferCacheKeyUsesSingletonNamespace() {
        let key = HankRemoteService.transferCacheKey(
            operation: "download",
            cloudURL: "https://remote.example",
            sourceID: "media",
            path: "/docs/report.pdf"
        )

        XCTAssertEqual(key, "singleton|download|https://remote.example|media|/docs/report.pdf")
        XCTAssertFalse(key.contains("home_id"))
    }

    func testFileOperationJobSnapshotDecodesServerShapeAndStatus() throws {
        let data = Data(
            """
            {
              "id": "filejob_123",
              "operation": "move",
              "source_id": "media",
              "destination_source_id": "archive",
              "from_path": "Movies/Example.mkv",
              "to_path": "Archive/Example.mkv",
              "is_directory": false,
              "status": "rollback_required",
              "bytes_total": 2048,
              "bytes_done": 1024,
              "files_total": 1,
              "files_done": 0,
              "error_message": "copy verification failed: checksum mismatch",
              "created_at": "2026-06-01T12:00:00Z",
              "updated_at": "2026-06-01T12:00:02Z"
            }
            """.utf8
        )
        let decoder = JSONDecoder()
        HankRemoteDateCoding.configure(decoder)

        let job = try decoder.decode(HankRemoteFileOperationJobSnapshot.self, from: data)

        XCTAssertEqual(job.id, "filejob_123")
        XCTAssertEqual(job.sourceID, "media")
        XCTAssertEqual(job.destinationSourceID, "archive")
        XCTAssertEqual(job.bytesDone, 1024)
        XCTAssertTrue(HankRemoteService.isTerminalFileOperationJobStatus(job.status))
        XCTAssertEqual(
            HankRemoteService.fileOperationFailureMessage(status: job.status, errorMessage: job.errorMessage),
            "copy verification failed: checksum mismatch"
        )
        XCTAssertNil(HankRemoteService.fileOperationFailureMessage(status: "completed", errorMessage: nil))
    }

    func testSharedSMBProfileFormReadsCanonicalPublicConfig() throws {
        let data = Data(
            """
            {
              "home_id": "home_1",
              "service_type": "smb",
              "public_config": {
                "host": " nas.local ",
                "share": "media",
                "domain": "WORKGROUP",
                "username": "aaron"
              },
              "status": "healthy"
            }
            """.utf8
        )
        let decoder = JSONDecoder()
        HankRemoteDateCoding.configure(decoder)

        let profile = try decoder.decode(HankRemoteServiceProfile.self, from: data)
        let form = HankRemoteSMBServiceProfileForm(publicConfigJSON: profile.publicConfigJSON)

        XCTAssertEqual(form.host, "nas.local")
        XCTAssertEqual(form.share, "media")
        XCTAssertEqual(form.domain, "WORKGROUP")
        XCTAssertEqual(form.username, "aaron")

        let canonical = HankRemoteSMBServiceProfileForm(
            publicConfigJSON: #"{"host":"files.local","share":"archive","domain":"LAB","username":"casey"}"#
        )
        XCTAssertEqual(canonical.host, "files.local")
        XCTAssertEqual(canonical.share, "archive")
        XCTAssertEqual(canonical.domain, "LAB")
        XCTAssertEqual(canonical.username, "casey")
    }

    func testSMBConnectionDetailsIgnoresLegacyServerAliasKeys() throws {
        let data = Data(
            """
            {
              "source_id": "media",
              "host": "nas.local",
              "share": "Movies",
              "smb_domain": "WORKGROUP",
              "smb_username": "aaron",
              "start_path": "Library"
            }
            """.utf8
        )

        let details = try JSONDecoder().decode(SMBConnectionDetails.self, from: data)

        XCTAssertEqual(details.host, "nas.local")
        XCTAssertEqual(details.normalizedRemoteSourceID, "")
        XCTAssertEqual(details.shareName, "")
        XCTAssertEqual(details.trimmedDomain, "")
        XCTAssertEqual(details.trimmedUsername, "")
        XCTAssertEqual(details.normalizedStartPath, "")
    }

    func testHankRemoteStorageStatusDecodesDocumentedShape() throws {
        let data = Data(
            """
            {
              "config": {
                "target_type": "local",
                "target_path": "/var/backups/hank",
                "full_schedule": "0 2 * * 0",
                "differential_schedule": "0 2 * * 1-6",
                "checksum_interval_seconds": 86400,
                "restore_verification_schedule": "0 3 * * 0",
                "retained_full_backup_count": 4,
                "restore_confirmation_phrase": "RESTORE HANK"
              },
              "checksum": {
                "enabled": true,
                "last_check_at": "2026-04-30T18:00:00Z",
                "last_amcheck_at": "2026-04-30T18:05:00Z",
                "failure_count": 1,
                "corruption_detected": true,
                "last_error": "checksum mismatch"
              },
              "backup": {
                "target_type": "local",
                "target_path": "/var/backups/hank",
                "backups": [
                  {
                    "label": "20260430-020000F",
                    "type": "full",
                    "created_at": "2026-04-30T02:00:00Z",
                    "size_bytes": 2048
                  }
                ],
                "last_successful_backup_at": "2026-04-30T02:00:00Z",
                "failure_count": 2
              },
              "restore": {
                "last_restore_test_at": "2026-04-30T03:00:00Z",
                "last_primary_restore_at": null,
                "pending_intent_count": 0,
                "confirmation_phrase": "RESTORE HANK"
              },
              "tasks": [
                {
                  "id": "task_1",
                  "operation": "backup",
                  "status": "running",
                  "message": "Running differential backup",
                  "step": "archive-push",
                  "backup_type": "differential",
                  "backup_label": "20260430-020000D",
                  "queued_at": "2026-04-30T18:00:00Z",
                  "started_at": "2026-04-30T18:01:00Z",
                  "updated_at": "2026-04-30T18:02:00Z"
                }
              ],
              "events": [
                {
                  "id": "evt_1",
                  "time": "2026-04-30T18:10:00Z",
                  "severity": "critical",
                  "operation": "checksum",
                  "status": "failed",
                  "message": "corruption detected",
                  "backup_label": "20260430-020000F",
                  "details": { "redacted": true }
                }
              ],
              "failures": [
                {
                  "id": "evt_2",
                  "time": "2026-04-30T18:11:00Z",
                  "severity": "error",
                  "operation": "backup",
                  "status": "failed",
                  "message": "backup failed"
                }
              ]
            }
            """.utf8
        )
        let decoder = JSONDecoder()
        HankRemoteDateCoding.configure(decoder)

        let status = try decoder.decode(HankRemoteStorageStatus.self, from: data)

        XCTAssertEqual(status.config.targetPath, "/var/backups/hank")
        XCTAssertTrue(status.checksum.corruptionDetected)
        XCTAssertEqual(status.backup.backups.first?.label, "20260430-020000F")
        XCTAssertEqual(status.restore.confirmationPhrase, "RESTORE HANK")
        XCTAssertEqual(status.tasks.first?.status, .running)
        XCTAssertEqual(status.tasks.first?.backupType, "differential")
        XCTAssertEqual(status.events.first?.severity, .critical)
        XCTAssertEqual(status.failures.first?.operation, .backup)
    }

    func testHankRemoteAssistantSettingsDecodesAndEncodesUpdateShape() throws {
        let data = Data(
            """
            {
              "settings": {
                "home_id": "home_1",
                "user_id": "user_1",
                "profile_notes_enabled": true,
                "home_notes_enabled": false,
                "files_enabled": true,
                "calendar_enabled": false,
                "homeassistant_enabled": true,
                "project_docs_enabled": false,
                "conversations_enabled": true,
                "system_prompt": "Use Hank context only.",
                "max_context_items": 20,
                "created_at": "2026-05-04T12:00:00Z",
                "updated_at": "2026-05-04T12:10:00Z",
                "updated_by": "user_1"
              },
              "defaults": {
                "system_prompt": "Default prompt",
                "max_context_items": 20
              },
              "sources": [
                {
                  "key": "home_notes",
                  "label": "Shared notes",
                  "enabled": false,
                  "description": "Notes shared with your Home."
                }
              ]
            }
            """.utf8
        )
        let decoder = JSONDecoder()
        HankRemoteDateCoding.configure(decoder)

        let response = try decoder.decode(HankRemoteAssistantSettingsResponse.self, from: data)

        XCTAssertEqual(response.settings.homeID, "home_1")
        XCTAssertFalse(response.settings.homeNotesEnabled)
        XCTAssertEqual(response.sources.first?.key, "home_notes")

        let update = HankRemoteAssistantSettingsUpdate(
            profileNotesEnabled: true,
            homeNotesEnabled: true,
            filesEnabled: false,
            calendarEnabled: true,
            homeAssistantEnabled: false,
            projectDocsEnabled: true,
            conversationsEnabled: false,
            systemPrompt: "Updated prompt"
        )
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(update)) as? [String: Any]

        XCTAssertEqual(encoded?["profile_notes_enabled"] as? Bool, true)
        XCTAssertEqual(encoded?["home_notes_enabled"] as? Bool, true)
        XCTAssertEqual(encoded?["files_enabled"] as? Bool, false)
        XCTAssertEqual(encoded?["homeassistant_enabled"] as? Bool, false)
        XCTAssertEqual(encoded?["system_prompt"] as? String, "Updated prompt")
    }

    func testHankRemoteAssistantRunDecodesPendingActionSummary() throws {
        let data = Data(
            """
            {
              "id": "run_1",
              "state": "waiting_confirmation",
              "requires_client_tools": false,
              "requires_confirmation": true,
              "pending_action_summary": {
                "kind": "calendar_create",
                "title": "Create calendar event",
                "summary": "Hank will ask this device to create the calendar event after you approve it.",
                "confirmation_message": "Confirm creating `Dentist` on May 3.",
                "is_destructive": false,
                "details": [
                  { "label": "Event", "value": "Dentist" },
                  { "label": "Requested date", "value": "May 3" },
                  { "label": "All day", "value": "Yes" }
                ]
              }
            }
            """.utf8
        )
        let decoder = JSONDecoder()
        HankRemoteDateCoding.configure(decoder)

        let run = try decoder.decode(HankRemoteAssistantRun.self, from: data)

        XCTAssertTrue(run.requiresConfirmation)
        XCTAssertEqual(run.pendingActionSummary?.kind, "calendar_create")
        XCTAssertEqual(run.pendingActionSummary?.title, "Create calendar event")
        XCTAssertEqual(run.pendingActionSummary?.confirmationMessage, "Confirm creating `Dentist` on May 3.")
        XCTAssertEqual(run.pendingActionSummary?.details.first?.label, "Event")
        XCTAssertEqual(run.pendingActionSummary?.details.first?.value, "Dentist")
    }

    @MainActor
    func testHankRemoteAssistantMessageDecodesMediaResultCard() throws {
        let data = Data(
            """
            {
              "id": "msg_1",
              "role": "assistant",
              "text": "I found these options.",
              "created_at": "2026-05-23T12:00:00Z",
              "diagnostics": {
                "tool_kind": "media.search",
                "intent_kind": "media.search",
                "query": "normal"
              },
              "cards": [
                {
                  "kind": "media",
                  "title": "1. SpongeBob SquarePants",
                  "summary": "TV show • 1999 • Animation, Comedy",
                  "action_title": "Reply with 1 to select",
                  "image_url": "https://image.example/spongebob.jpg",
                  "media_option_id": "media_1",
                  "media_type": "series",
                  "year": 1999,
                  "job_id": "job_1"
                }
              ]
            }
            """.utf8
        )
        let decoder = JSONDecoder()
        HankRemoteDateCoding.configure(decoder)

        let message = try decoder.decode(HankRemoteAssistantMessage.self, from: data)
        let card = try XCTUnwrap(message.cards.first)

        XCTAssertEqual(card.kind, "media")
        XCTAssertEqual(card.mediaOptionID, "media_1")
        XCTAssertEqual(card.mediaType, "series")
        XCTAssertEqual(card.year, 1999)
        XCTAssertEqual(card.jobID, "job_1")
        XCTAssertEqual(card.imageURL?.absoluteString, "https://image.example/spongebob.jpg")
        XCTAssertEqual(message.diagnostics?.toolKind, "media.search")
        XCTAssertEqual(message.diagnostics?.query, "normal")
        if case .media = HankAssistantStore.cardKind(from: card.kind) {
        } else {
            XCTFail("Expected media cards to map to the media result renderer.")
        }
    }

    @MainActor
    func testHankRemoteAssistantMessageDecodesPosterURLFallbackAndMissingHistoryFields() throws {
        let data = Data(
            """
            {
              "id": "msg_history",
              "role": "assistant",
              "created_at": "2026-05-23T12:00:00Z",
              "cards": [
                {
                  "kind": "media",
                  "title": "1. Example Movie",
                  "summary": "Movie",
                  "poster_url": "https://image.example/poster.jpg"
                }
              ]
            }
            """.utf8
        )
        let decoder = JSONDecoder()
        HankRemoteDateCoding.configure(decoder)

        let message = try decoder.decode(HankRemoteAssistantMessage.self, from: data)

        XCTAssertEqual(message.text, "")
        XCTAssertEqual(message.cards.first?.imageURL?.absoluteString, "https://image.example/poster.jpg")
        XCTAssertNil(message.diagnostics)
    }

    func testHankRemoteAssistantRunDecodesMediaConfirmationSummary() throws {
        let data = Data(
            """
            {
              "id": "run_1",
              "state": "waiting_confirmation",
              "requires_client_tools": false,
              "requires_confirmation": true,
              "diagnostics": {
                "tool_kind": "media.search",
                "intent_kind": "media.plan_download",
                "query": "spongebob movie",
                "media_selection_title": "SpongeBob SquarePants"
              },
              "pending_action_summary": {
                "kind": "media_download",
                "title": "Download SpongeBob SquarePants",
                "summary": "Hank will download 42 media files to the Media share root after you approve.",
                "confirmation_message": "Download 42 episodes of SpongeBob SquarePants?",
                "is_destructive": false,
                "details": [
                  { "label": "Items", "value": "42" },
                  { "label": "1080p", "value": "40" },
                  { "label": "720p fallbacks", "value": "2" }
                ]
              }
            }
            """.utf8
        )
        let decoder = JSONDecoder()
        HankRemoteDateCoding.configure(decoder)

        let run = try decoder.decode(HankRemoteAssistantRun.self, from: data)

        XCTAssertTrue(run.requiresConfirmation)
        XCTAssertEqual(run.pendingActionSummary?.kind, "media_download")
        XCTAssertEqual(run.pendingActionSummary?.title, "Download SpongeBob SquarePants")
        XCTAssertEqual(run.pendingActionSummary?.confirmationMessage, "Download 42 episodes of SpongeBob SquarePants?")
        XCTAssertEqual(run.pendingActionSummary?.details.map(\.label), ["Items", "1080p", "720p fallbacks"])
        XCTAssertEqual(run.diagnostics?.toolKind, "media.search")
        XCTAssertEqual(run.diagnostics?.query, "spongebob movie")
    }

    func testOpenAIStatusAndLinkStartDecodeBothAuthModes() throws {
        let decoder = JSONDecoder()
        HankRemoteDateCoding.configure(decoder)

        let authorizationData = Data(
            """
            {
              "configured": true,
              "linked": true,
              "auth_mode": "authorization_url",
              "auth_provider": "openai_oauth",
              "scopes": "openid profile email",
              "redirect_uri": "https://remote.example/v1/oauth/openai/callback",
              "token_type": "Bearer",
              "scope": "openid profile email",
              "expires_at": "2026-05-05T12:00:00Z",
              "updated_at": "2026-05-04T12:00:00Z"
            }
            """.utf8
        )
        let status = try decoder.decode(HankRemoteOpenAIAccountStatus.self, from: authorizationData)

        XCTAssertTrue(status.configured)
        XCTAssertTrue(status.linked)
        XCTAssertEqual(status.authMode, "authorization_url")
        XCTAssertEqual(status.authProvider, "openai_oauth")

        let browserStart = try decoder.decode(
            HankRemoteOpenAIAccountLinkStart.self,
            from: Data(#"{ "authorization_url": "https://auth.openai.com/oauth/authorize?state=abc" }"#.utf8)
        )

        XCTAssertEqual(browserStart.authMode, "authorization_url")
        XCTAssertEqual(browserStart.authorizationURL?.host(), "auth.openai.com")

        let deviceStart = try decoder.decode(
            HankRemoteOpenAIAccountLinkStart.self,
            from: Data(
                """
                {
                  "auth_mode": "device_code",
                  "verification_url": "https://chatgpt.com/activate",
                  "user_code": "ABCD-EFGH",
                  "expires_at": "2026-05-04T12:15:00Z",
                  "poll_after_seconds": 5
                }
                """.utf8
            )
        )

        XCTAssertEqual(deviceStart.authMode, "device_code")
        XCTAssertEqual(deviceStart.userCode, "ABCD-EFGH")
        XCTAssertEqual(deviceStart.pollAfterSeconds, 5)

        let deviceStatus = try decoder.decode(
            HankRemoteOpenAIAccountStatus.self,
            from: Data(
                """
                {
                  "configured": true,
                  "linked": false,
                  "auth_mode": "device_code",
                  "auth_provider": "chatgpt_codex",
                  "pending": {
                    "state": "pending",
                    "verification_url": "https://chatgpt.com/activate",
                    "user_code": "ABCD-EFGH",
                    "expires_at": "2026-05-04T12:15:00Z",
                    "poll_after_seconds": 5
                  }
                }
                """.utf8
            )
        )

        XCTAssertEqual(deviceStatus.pending?.state, "pending")
        XCTAssertEqual(deviceStatus.pending?.userCode, "ABCD-EFGH")
    }

    func testInstalledAppSlashCommandsDecodeFromHomeAppsResponse() throws {
        let data = Data(
            """
            {
              "apps": [
                {
                  "id": "hermes",
                  "name": "Hermes",
                  "version": "1.0.0",
                  "description": "Route explicit /Hermes prompts to a local Hermes API server.",
                  "enabled": true,
                  "status": "ready",
                  "user_access": "home_members",
                  "slash_commands": [
                    {
                      "command": "/Hermes",
                      "command_id": "chat",
                      "description": "Send a prompt to Hermes."
                    }
                  ],
                  "commands": [
                    {
                      "id": "chat",
                      "mode": "request_response",
                      "timeout_seconds": 120,
                      "admin_only": true
                    }
                  ]
                },
                {
                  "id": "gramaton",
                  "name": "Gramaton",
                  "version": "1.0.0",
                  "description": "Search Gramaton.",
                  "enabled": false,
                  "status": "disabled",
                  "slash_commands": [
                    {
                      "command": "/gramaton",
                      "command_id": "search",
                      "description": "Search for a movie or TV show on Gramaton."
                    }
                  ]
                }
              ]
            }
            """.utf8
        )
        let response = try JSONDecoder().decode(HankRemoteInstalledAppsResponse.self, from: data)

        let commands = HankAssistantStore.installedAppSlashCommands(from: response.apps)

        XCTAssertEqual(commands.map(\.command), ["/Hermes"])
        XCTAssertEqual(response.apps.first?.userAccess, "home_members")
        XCTAssertEqual(commands.first?.label, "Hermes")
        XCTAssertEqual(commands.first?.description, "Send a prompt to Hermes.")
    }

    func testInstalledAppSlashCommandsFilterInvalidCommandsAndAppendBuiltIns() {
        let apps = [
            HankRemoteInstalledApp(
                id: "hermes",
                name: "Hermes",
                version: "1.0.0",
                description: "Hermes app.",
                enabled: true,
                status: "ready",
                slashCommands: [
                    HankRemoteInstalledAppSlashCommand(command: "Hermes", commandID: "bad", description: "Missing slash."),
                    HankRemoteInstalledAppSlashCommand(command: "/Hermes", commandID: "chat", description: "")
                ],
                commands: []
            )
        ]

        let commands = HankAssistantStore.availableSlashCommands(from: apps)

        XCTAssertEqual(commands.prefix(2).map(\.command), ["/Hermes", "/ha"])
        XCTAssertEqual(commands.first?.description, "Hermes app.")
        XCTAssertFalse(commands.map(\.command).contains("Hermes"))
    }

    func testInstalledAppSlashCommandsDoNotShadowBuiltIns() {
        let apps = [
            HankRemoteInstalledApp(
                id: "fake-files",
                name: "Fake Files",
                version: "1.0.0",
                description: "Should not replace core files command.",
                enabled: true,
                status: "ready",
                slashCommands: [
                    HankRemoteInstalledAppSlashCommand(command: "/files", commandID: "search", description: "Shadow files."),
                    HankRemoteInstalledAppSlashCommand(command: "/shipit", commandID: "run", description: "Run packaged workflow.")
                ],
                commands: []
            )
        ]

        let commands = HankAssistantStore.availableSlashCommands(from: apps)

        XCTAssertEqual(commands.map(\.command).filter { $0 == "/files" }.count, 1)
        XCTAssertEqual(commands.first?.command, "/shipit")
        XCTAssertEqual(commands.first?.label, "Fake Files")
        XCTAssertEqual(commands.first?.description, "Run packaged workflow.")
        XCTAssertEqual(commands.first(where: { $0.command == "/files" })?.label, "Files")
    }

    func testAppWebSocketURLUsesTicketPath() throws {
        let url = try XCTUnwrap(
            HankRemoteService.appWebSocketURL(
                from: "https://remote.example",
                websocketPath: "/ws/app?app_ticket=ticket_123"
            )
        )

        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.host(), "remote.example")
        XCTAssertEqual(url.path(), "/ws/app")
        XCTAssertEqual(url.query(), "app_ticket=ticket_123")
        XCTAssertFalse(url.absoluteString.contains("session_token"))
    }

    private func makeModelContext(schema: [any PersistentModel.Type]) throws -> ModelContext {
        let container = try ModelContainer(for: Schema(schema), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        return ModelContext(container)
    }

    @MainActor
    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        pollIntervalNanoseconds: UInt64 = 20_000_000,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !condition() && DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }
}

private final class MutableCounter: @unchecked Sendable {
    var value = 0
}

private final class RecordingSMBService: SMBServicing, @unchecked Sendable {
    var listings: [String: [SMBItem]]
    var downloads: [String: Data]
    let connectDelayNanoseconds: UInt64
    private(set) var createdDirectories: [String] = []
    private(set) var uploads: [(path: String, data: Data)] = []
    private(set) var dataUploadRequests: [String] = []
    private(set) var fileUploadRequests: [String] = []
    private(set) var moves: [(from: String, to: String)] = []
    private(set) var deletions: [(path: String, isDirectory: Bool)] = []
    private(set) var downloadRequests: [String] = []
    private(set) var downloadToFileRequests: [String] = []
    private(set) var listRequests: [String] = []
    private(set) var connectCallCount = 0
    private(set) var disconnectCallCount = 0

    init(
        listings: [String: [SMBItem]] = [:],
        downloads: [String: Data] = [:],
        connectDelayNanoseconds: UInt64 = 0
    ) {
        self.listings = listings
        self.downloads = downloads
        self.connectDelayNanoseconds = connectDelayNanoseconds
    }

    func connect(
        config: SMBConnectionDetails,
        password: String,
        context: HankRemoteConnectionContext
    ) async throws {
        connectCallCount += 1
        if connectDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: connectDelayNanoseconds)
        }
    }

    func list(path: String) async throws -> [SMBItem] {
        let normalizedPath = FileBrowserPathing.normalized(path)
        listRequests.append(normalizedPath)
        return listings[normalizedPath] ?? []
    }

    func download(path: String) async throws -> Data {
        let normalizedPath = FileBrowserPathing.normalized(path)
        downloadRequests.append(normalizedPath)
        return downloads[normalizedPath] ?? Data()
    }

    func download(path: String, to localURL: URL) async throws {
        let normalizedPath = FileBrowserPathing.normalized(path)
        downloadToFileRequests.append(normalizedPath)
        let data = downloads[normalizedPath] ?? Data()
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: localURL, options: [.atomic])
    }

    func createDirectory(path: String) async throws {
        createdDirectories.append(FileBrowserPathing.normalized(path))
    }

    func upload(data: Data, path: String) async throws {
        let normalizedPath = FileBrowserPathing.normalized(path)
        dataUploadRequests.append(normalizedPath)
        uploads.append((normalizedPath, data))
    }

    func upload(fileAt localURL: URL, path: String) async throws {
        let normalizedPath = FileBrowserPathing.normalized(path)
        fileUploadRequests.append(normalizedPath)
        let data = try Data(contentsOf: localURL)
        uploads.append((normalizedPath, data))
    }

    func move(from: String, to: String, isDirectory: Bool) async throws {
        moves.append((FileBrowserPathing.normalized(from), FileBrowserPathing.normalized(to)))
    }

    func delete(path: String, isDirectory: Bool) async throws {
        deletions.append((FileBrowserPathing.normalized(path), isDirectory))
    }

    func disconnect() async {
        disconnectCallCount += 1
    }
}

private final class InMemorySearchIndexPersistence: SMBSearchIndexPersisting {
    private var entriesByScope: [String: [SMBSearchIndexEntry]] = [:]

    func loadEntries(for scopeKey: String) throws -> [SMBSearchIndexEntry]? {
        entriesByScope[scopeKey]
    }

    func saveEntries(_ entries: [SMBSearchIndexEntry], for scopeKey: String) throws {
        entriesByScope[scopeKey] = entries
    }

    func deleteEntries(for scopeKey: String) throws {
        entriesByScope.removeValue(forKey: scopeKey)
    }
}

private final class RecordingSMBRemoteSession: SMBRemoteSession, @unchecked Sendable {
    private let loginError: Error?
    private let listSharesError: Error?
    private let connectShareError: Error?
    private(set) var shareNames: [String]
    private(set) var loggedInUsername: String?
    private(set) var loggedInDomain: String?
    private(set) var connectedShare: String?
    private(set) var listSharesCallCount = 0
    private(set) var disconnectCallCount = 0
    var connectedConfig: SMBConnectionDetails?

    init(loginError: Error? = nil, listSharesError: Error? = nil, connectShareError: Error? = nil, shareNames: [String] = []) {
        self.loginError = loginError
        self.listSharesError = listSharesError
        self.connectShareError = connectShareError
        self.shareNames = shareNames
    }

    func login(username: String, password: String, domain: String?) async throws {
        if let loginError {
            throw loginError
        }
        loggedInUsername = username
        loggedInDomain = domain
    }

    func listShares() async throws -> [String] {
        listSharesCallCount += 1
        if let listSharesError {
            throw listSharesError
        }
        return shareNames
    }

    func connectShare(_ shareName: String) async throws {
        if let connectShareError {
            throw connectShareError
        }
        connectedShare = shareName
    }

    func list(path: String) async throws -> [SMBItem] { [] }
    func download(path: String) async throws -> Data { Data() }
    func download(path: String, to localURL: URL) async throws {
        try Data().write(to: localURL, options: [.atomic])
    }
    func createDirectory(path: String) async throws {}
    func upload(data: Data, path: String) async throws {}
    func upload(fileAt localURL: URL, path: String) async throws {}
    func move(from: String, to: String, isDirectory: Bool) async throws {}
    func delete(path: String, isDirectory: Bool) async throws {}

    func disconnect() async {
        disconnectCallCount += 1
    }
}

private final class RecordingSMBRemoteSessionSequence: @unchecked Sendable {
    private var sessions: [RecordingSMBRemoteSession]

    init(_ sessions: [RecordingSMBRemoteSession]) {
        self.sessions = sessions
    }

    func next() -> RecordingSMBRemoteSession {
        sessions.removeFirst()
    }
}
