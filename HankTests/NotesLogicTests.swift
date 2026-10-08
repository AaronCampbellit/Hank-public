import CryptoKit
import SwiftData
import UIKit
import XCTest
@testable import Hank

final class NotesLogicTests: XCTestCase {
    func testHankLinkRoutingUsesInAppBrowserForHTTPS() {
        let url = URL(string: "https://example.com")!

        XCTAssertEqual(HankLinkRouting.route(for: url), .inAppBrowser(url))
    }

    func testHankLinkRoutingUsesInAppBrowserForHTTP() {
        let url = URL(string: "http://example.com")!

        XCTAssertEqual(HankLinkRouting.route(for: url), .inAppBrowser(url))
    }

    func testHankLinkRoutingUsesExternalRouteForMailto() {
        let url = URL(string: "mailto:test@example.com")!

        XCTAssertEqual(HankLinkRouting.route(for: url), .external(url))
    }

    func testHankLinkRoutingUsesExternalRouteForTelephone() {
        let url = URL(string: "tel:1234567890")!

        XCTAssertEqual(HankLinkRouting.route(for: url), .external(url))
    }

    func testHankLinkRoutingHandlesWebLinksWithInAppBrowserCallback() {
        let url = URL(string: "https://example.com")!
        var inAppBrowserURL: URL?
        var externalURL: URL?

        HankLinkRouting.handle(
            url,
            openInAppBrowser: { inAppBrowserURL = $0 },
            openExternally: { externalURL = $0 }
        )

        XCTAssertEqual(inAppBrowserURL, url)
        XCTAssertNil(externalURL)
    }

    func testHankLinkRoutingHandlesNonWebLinksWithExternalCallback() {
        let url = URL(string: "mailto:test@example.com")!
        var inAppBrowserURL: URL?
        var externalURL: URL?

        HankLinkRouting.handle(
            url,
            openInAppBrowser: { inAppBrowserURL = $0 },
            openExternally: { externalURL = $0 }
        )

        XCTAssertNil(inAppBrowserURL)
        XCTAssertEqual(externalURL, url)
    }

    func testRemoteNotePayloadPreservesLiveSyncMetadata() throws {
        let noteJSON = """
        {
          "note_id": "85c075d0-3e83-40fd-93e1-b076af638f00",
          "title": "Kitchen Plan",
          "content": "fallback",
          "body_markdown": "# Kitchen\\n- lights",
          "body_format": "markdown",
          "revision": "rev-2",
          "updated_at": "2026-04-28T12:15:30Z",
          "page_type": "text",
          "parent_id": "11111111-1111-4111-8111-111111111111",
          "sort_order": 7,
          "owner_user_id": "user_owner",
          "shared": true,
          "preview": "Kitchen",
          "tags": ["home"]
        }
        """
        let summaryJSON = """
        {
          "id": "85c075d0-3e83-40fd-93e1-b076af638f00",
          "title": "Kitchen Plan",
          "updated_at": "2026-04-28T12:15:30Z",
          "revision": "rev-2",
          "page_type": "text",
          "parent_id": "11111111-1111-4111-8111-111111111111",
          "sort_order": 7,
          "body_format": "markdown",
          "owner_user_id": "user_owner",
          "shared": true,
          "preview": "Kitchen",
          "tags": ["home"]
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let note = try decoder.decode(HankRemoteNotesFetchResponse.self, from: Data(noteJSON.utf8))
        let summary = try decoder.decode(HankRemoteNoteSummary.self, from: Data(summaryJSON.utf8))

        XCTAssertEqual(note.bodyMarkdown, "# Kitchen\n- lights")
        XCTAssertEqual(note.content, "fallback")
        XCTAssertEqual(note.bodyFormat, "markdown")
        XCTAssertEqual(note.parentID, "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(note.sortOrder, 7)
        XCTAssertTrue(note.shared)
        XCTAssertEqual(summary.parentID, note.parentID)
        XCTAssertEqual(summary.sortOrder, note.sortOrder)
        XCTAssertEqual(summary.bodyFormat, note.bodyFormat)
        XCTAssertTrue(summary.shared)
    }

    func testRemoteNotebookPayloadPreservesNotebookPageType() throws {
        let noteJSON = """
        {
          "note_id": "11111111-1111-4111-8111-111111111111",
          "title": "Projects",
          "content": "",
          "revision": "rev-1",
          "updated_at": "2026-04-28T12:15:30Z",
          "page_type": "notebook",
          "sort_order": 0
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let note = try decoder.decode(HankRemoteNotesFetchResponse.self, from: Data(noteJSON.utf8))

        XCTAssertEqual(NotePageType(rawValue: note.pageType), .notebook)
    }

    @MainActor
    func testRemoteNoteTextMergePreservesExistingFormatting() {
        let existing = NSMutableAttributedString(string: "Hello world")
        existing.addAttributes(
            [.font: UIFont.systemFont(ofSize: 17)],
            range: NSRange(location: 0, length: existing.length)
        )
        existing.addAttributes(
            [.font: UIFont.boldSystemFont(ofSize: 17)],
            range: NSRange(location: 6, length: 5)
        )

        let merged = NotesStore.attributedText(
            replacingStringWith: "Hello server",
            preservingFormattingFrom: existing
        )

        XCTAssertEqual(merged.string, "Hello server")
        let leadingFont = merged.attribute(.font, at: 1, effectiveRange: nil) as? UIFont
        let replacementFont = merged.attribute(.font, at: 6, effectiveRange: nil) as? UIFont
        XCTAssertFalse(leadingFont?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? true)
        XCTAssertTrue(replacementFont?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false)
    }

    @MainActor
    func testNoteTreeCreateDuplicateDeleteAndSubpageFlow() throws {
        var workspace = NoteTreeManager.makeDefaultArchive()
        let rootID = try XCTUnwrap(workspace.entries.first?.id)

        let childID = NoteTreeManager.createNote(
            entries: &workspace.entries,
            bodies: &workspace.bodies,
            parentID: rootID,
            after: nil,
            title: "Child"
        )
        let siblingID = NoteTreeManager.createNote(
            entries: &workspace.entries,
            bodies: &workspace.bodies,
            parentID: nil,
            after: rootID,
            title: "Sibling"
        )

        XCTAssertEqual(NoteTreeManager.outlineItems(entries: workspace.entries).map(\.entry.title), ["Note", "Child", "Sibling"])
        XCTAssertEqual(workspace.entries.first(where: { $0.id == rootID })?.pageType, .notebook)
        XCTAssertEqual(workspace.entries.first(where: { $0.id == childID })?.pageType, .text)

        let duplicateID = try NoteTreeManager.duplicate(noteID: rootID, entries: &workspace.entries, bodies: &workspace.bodies)
        XCTAssertTrue(workspace.entries.contains(where: { $0.id == duplicateID }))
        XCTAssertTrue(workspace.entries.contains(where: { $0.title == "Note Copy" }))

        NoteTreeManager.delete(noteID: siblingID, entries: &workspace.entries, bodies: &workspace.bodies)
        XCTAssertFalse(workspace.entries.contains(where: { $0.id == siblingID }))
        XCTAssertTrue(workspace.entries.contains(where: { $0.id == childID }))
    }

    @MainActor
    func testNoteTreeMoveAndReparentRejectsDescendantTargets() throws {
        var workspace = NoteTreeManager.makeDefaultArchive()
        let rootID = try XCTUnwrap(workspace.entries.first?.id)
        let childID = NoteTreeManager.createNote(
            entries: &workspace.entries,
            bodies: &workspace.bodies,
            parentID: rootID,
            after: nil,
            title: "Child"
        )
        let siblingID = NoteTreeManager.createNote(
            entries: &workspace.entries,
            bodies: &workspace.bodies,
            parentID: nil,
            after: rootID,
            title: "Sibling"
        )

        try NoteTreeManager.reparent(noteID: siblingID, targetParentID: rootID, entries: &workspace.entries)
        XCTAssertEqual(workspace.entries.first(where: { $0.id == siblingID })?.parentID, rootID)
        XCTAssertEqual(workspace.entries.first(where: { $0.id == rootID })?.pageType, .notebook)

        XCTAssertThrowsError(
            try NoteTreeManager.reparent(noteID: rootID, targetParentID: childID, entries: &workspace.entries)
        ) { error in
            XCTAssertEqual(error.localizedDescription, NotesServiceError.cannotMoveIntoDescendant.localizedDescription)
        }
        XCTAssertThrowsError(
            try NoteTreeManager.reparent(noteID: rootID, targetParentID: rootID, entries: &workspace.entries)
        ) { error in
            XCTAssertEqual(error.localizedDescription, NotesServiceError.cannotMoveIntoDescendant.localizedDescription)
        }

        NoteTreeManager.moveDown(noteID: childID, entries: &workspace.entries)
        let childSortOrder = workspace.entries.first(where: { $0.id == childID })?.sortOrder
        let siblingSortOrder = workspace.entries.first(where: { $0.id == siblingID })?.sortOrder
        XCTAssertNotEqual(childSortOrder, siblingSortOrder)
    }

    @MainActor
    func testOutlineItemsRemainFiniteWhenManifestContainsCycle() throws {
        let now = Date()
        let rootID = UUID()
        let firstID = UUID()
        let secondID = UUID()
        let entries = [
            NoteManifestEntry(
                id: rootID,
                title: "Root",
                parentID: nil,
                sortOrder: 0,
                createdAt: now,
                updatedAt: now
            ),
            NoteManifestEntry(
                id: firstID,
                title: "First",
                parentID: secondID,
                sortOrder: 0,
                createdAt: now,
                updatedAt: now
            ),
            NoteManifestEntry(
                id: secondID,
                title: "Second",
                parentID: firstID,
                sortOrder: 0,
                createdAt: now,
                updatedAt: now
            )
        ]

        let items = NoteTreeManager.outlineItems(entries: entries)

        XCTAssertEqual(Set(items.map(\.id)), Set([rootID, firstID, secondID]))
    }

    @MainActor
    func testNotesServiceCachesRemoteWorkspaceWithoutLegacyLocalArchive() async throws {
        let tempRoot = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let notesService = ProfileNotesService(localRootProvider: localRootProvider(baseURL: tempRoot))
        let services = AppServices(
            keychain: InMemoryKeychainStore(),
            smbService: NotesRecordingSMBService(),
            notesService: notesService
        )
        let container = try makeNotesContainer()
        let context = ModelContext(container)
        try configureRemoteNotesAccess(in: context, services: services)
        let profile = try makeRemoteNotesProfile(username: "notes-user", displayName: "Notes User", in: context)

        var workspace = NoteTreeManager.makeDefaultArchive()
        let noteID = try XCTUnwrap(workspace.entries.first?.id)
        NoteTreeManager.rename(noteID: noteID, to: "Cached Remote", entries: &workspace.entries)
        workspace.bodies[noteID] = try richTextData("Available offline")
        try await notesService.saveWorkspace(workspace, profileID: profile.id, modelContext: context, services: services)

        let rootURL = tempRoot.appendingPathComponent(profile.id.uuidString.lowercased(), isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.path))

        let loadedWorkspace = try await notesService.loadWorkspace(
            profileID: profile.id,
            modelContext: context,
            services: services
        )
        XCTAssertEqual(loadedWorkspace.entries.first?.title, "Cached Remote")
        XCTAssertEqual(try plainString(from: loadedWorkspace.bodies[noteID] ?? Data()), "Available offline")
        XCTAssertEqual(loadedWorkspace.configuration.resolvedPath, "Hank Remote profile notes (pending sync)")
    }

    @MainActor
    func testDeviceOnlyProfileRequiresHankRemoteForNotes() async throws {
        let tempRoot = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let notesService = ProfileNotesService(localRootProvider: localRootProvider(baseURL: tempRoot))
        let services = AppServices(
            keychain: InMemoryKeychainStore(),
            smbService: NotesRecordingSMBService(),
            notesService: notesService
        )
        let container = try makeNotesContainer()
        let context = ModelContext(container)
        let profile = UserProfile(username: "device-only", displayName: "Device Only", passwordHash: "hash", passwordSalt: "salt")
        context.insert(profile)
        try context.save()

        do {
            _ = try await notesService.loadWorkspace(
                profileID: profile.id,
                modelContext: context,
                services: services
            )
            XCTFail("Device-only profiles should not open server-backed Notes.")
        } catch {
            XCTAssertEqual(error.localizedDescription, NotesServiceError.serverRequired.localizedDescription)
        }
    }

    @MainActor
    func testNotesStorageMigrationIsDisabledForServerBackedNotes() async throws {
        let tempRoot = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let notesService = ProfileNotesService(localRootProvider: localRootProvider(baseURL: tempRoot))
        let services = AppServices(
            keychain: InMemoryKeychainStore(),
            smbService: NotesRecordingSMBService(),
            notesService: notesService
        )
        let container = try makeNotesContainer()
        let context = ModelContext(container)
        try configureRemoteNotesAccess(in: context, services: services)
        let profile = try makeRemoteNotesProfile(username: "server-notes", displayName: "Server Notes", in: context)

        do {
            _ = try await notesService.migrateStorage(
                profileID: profile.id,
                to: .smb,
                modelContext: context,
                services: services
            )
            XCTFail("Notes storage migration should not be available once Hank Remote owns Notes.")
        } catch {
            XCTAssertEqual(error.localizedDescription, NotesServiceError.serverRequired.localizedDescription)
        }
    }

    @MainActor
    func testBackupRoundTripExcludesServerBackedNotesPayload() async throws {
        let tempRoot = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let notesService = ProfileNotesService(localRootProvider: localRootProvider(baseURL: tempRoot))
        let services = AppServices(
            keychain: InMemoryKeychainStore(),
            smbService: NotesRecordingSMBService(),
            notesService: notesService
        )
        let schema = Schema([
            UserProfile.self,
            HomeAssistantConfig.self,
            SavedSMBConnection.self,
            SMBConnectionConfig.self,
            SavedCalendarSource.self,
            NotesConfig.self,
            DashboardShortcut.self,
            HankRemoteSettings.self
        ])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        try configureRemoteNotesAccess(in: context, services: services)

        let sourceProfile = UserProfile(
            username: "source",
            displayName: "Source",
            passwordHash: "hash",
            passwordSalt: "salt",
            authModeRawValue: UserProfileAuthMode.hankRemote.rawValue,
            remoteUserID: "remote-user-1",
            remoteEmail: "source@example.com"
        )
        context.insert(sourceProfile)
        context.insert(
            HomeAssistantConfig(
                profileID: sourceProfile.id,
                baseURLString: "http://home.local",
                port: 8124,
                displayName: "Home Lab",
                allowSelfSignedLocal: false
            )
        )

        let primaryConnection = SavedSMBConnection(
            profileID: sourceProfile.id,
            displayName: "Primary Share",
            host: "nas.local",
            shareName: "Primary",
            username: "aaron",
            port: 445,
            startPath: "docs",
            isDefault: true,
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let archiveConnection = SavedSMBConnection(
            profileID: sourceProfile.id,
            displayName: "Archive Share",
            host: "nas.local",
            shareName: "Archive",
            username: "aaron",
            port: 1445,
            startPath: "history",
            isDefault: false,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        context.insert(primaryConnection)
        context.insert(archiveConnection)

        context.insert(
            SavedCalendarSource(
                profileID: sourceProfile.id,
                kindRawValue: SavedCalendarSourceKind.deviceCalendar.rawValue,
                displayName: "Family Calendar",
                remoteIdentifier: "family-device-id",
                sourceTitle: "iCloud"
            )
        )
        context.insert(
            SavedCalendarSource(
                profileID: sourceProfile.id,
                kindRawValue: SavedCalendarSourceKind.webSubscription.rawValue,
                displayName: "Team Feed",
                urlString: "https://example.com/team.ics",
                detailText: "Subscription",
                isEnabled: false
            )
        )
        context.insert(
            DashboardShortcut(
                profileID: sourceProfile.id,
                entityID: "light.kitchen",
                labelOverride: "Kitchen",
                tileSizeRawValue: DashboardTileSize.expanded.rawValue,
                sortOrder: 0,
                gridRow: 2,
                gridColumn: 1,
                isEnabled: true
            )
        )
        try services.setHomeAssistantToken("ha-token", for: sourceProfile.id)
        try services.setSMBPassword("primary-password", for: primaryConnection.id, profileID: sourceProfile.id)
        try services.setSMBPassword("archive-password", for: archiveConnection.id, profileID: sourceProfile.id)
        try context.save()

        let exportedData = try services.backupService.exportSnapshotData(profile: sourceProfile, modelContext: context, services: services)
        let snapshot = try services.backupService.decodeSnapshot(from: exportedData)

        XCTAssertEqual(snapshot.schemaVersion, ProfileBackupSnapshot.currentSchemaVersion)
        XCTAssertEqual(snapshot.profile.authModeRawValue, UserProfileAuthMode.hankRemote.rawValue)
        XCTAssertEqual(snapshot.profile.remoteUserID, "remote-user-1")
        XCTAssertEqual(snapshot.profile.remoteEmail, "source@example.com")
        XCTAssertEqual(snapshot.homeAssistant.configuration.baseURLString, "http://home.local")
        XCTAssertEqual(snapshot.homeAssistant.configuration.port, 8124)
        XCTAssertEqual(snapshot.homeAssistant.configuration.displayName, "Home Lab")
        XCTAssertEqual(snapshot.homeAssistant.token, "ha-token")
        XCTAssertEqual(snapshot.savedSMBConnections.count, 2)
        XCTAssertEqual(snapshot.savedSMBConnections.first(where: \.isDefault)?.displayName, "Primary Share")
        XCTAssertEqual(snapshot.savedSMBConnections.first(where: { $0.displayName == "Archive Share" })?.password, "archive-password")
        XCTAssertEqual(snapshot.savedCalendarSources.count, 2)
        XCTAssertTrue(snapshot.savedCalendarSources.contains(where: { $0.displayName == "Family Calendar" && $0.kindRawValue == SavedCalendarSourceKind.deviceCalendar.rawValue }))
        XCTAssertTrue(snapshot.savedCalendarSources.contains(where: { $0.displayName == "Team Feed" && $0.isEnabled == false }))
        XCTAssertEqual(snapshot.dashboardTiles.count, 1)
        XCTAssertEqual(snapshot.dashboardTiles.first?.entityID, "light.kitchen")
        XCTAssertNil(snapshot.notes)

        let restoredProfile = try services.backupService.restore(
            snapshot: snapshot,
            target: .newProfile,
            modelContext: context,
            services: services
        )

        let restoredHomeAssistant = try XCTUnwrap(HomeAssistantConfig.fetch(for: restoredProfile.id, in: context))
        XCTAssertEqual(restoredProfile.authMode, .hankRemote)
        XCTAssertEqual(restoredProfile.remoteUserID, "remote-user-1")
        XCTAssertEqual(restoredProfile.remoteEmail, "source@example.com")
        XCTAssertEqual(restoredHomeAssistant.connectionConfiguration.baseURLString, "http://home.local")
        XCTAssertEqual(restoredHomeAssistant.connectionConfiguration.port, 8124)
        XCTAssertEqual(try services.homeAssistantToken(for: restoredProfile.id), "ha-token")

        let restoredConnections = try services.savedSMBConnections(for: restoredProfile.id, in: context)
        XCTAssertEqual(restoredConnections.count, 2)
        XCTAssertEqual(restoredConnections.first(where: \.isDefault)?.effectiveDisplayName, "Primary Share")
        let restoredArchive = try XCTUnwrap(restoredConnections.first(where: { $0.effectiveDisplayName == "Archive Share" }))
        XCTAssertEqual(try services.smbPassword(for: restoredArchive.id, profileID: restoredProfile.id), "archive-password")

        let restoredCalendarSources = try SavedCalendarSource.fetchAll(for: restoredProfile.id, in: context)
        XCTAssertEqual(restoredCalendarSources.count, 2)
        XCTAssertTrue(restoredCalendarSources.contains(where: { $0.displayName == "Family Calendar" }))
        XCTAssertTrue(restoredCalendarSources.contains(where: { $0.displayName == "Team Feed" && $0.isEnabled == false }))

        let restoredDashboardTiles = try DashboardShortcut.fetchOrdered(for: restoredProfile.id, in: context)
        XCTAssertEqual(restoredDashboardTiles.count, 1)
        XCTAssertEqual(restoredDashboardTiles.first?.entityID, "light.kitchen")
    }

    @MainActor
    func testBackupImportNotesOnlyMergesIntoExistingWorkspace() async throws {
        let tempRoot = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let notesService = ProfileNotesService(localRootProvider: localRootProvider(baseURL: tempRoot))
        let services = AppServices(
            keychain: InMemoryKeychainStore(),
            smbService: NotesRecordingSMBService(),
            notesService: notesService
        )
        let container = try makeNotesContainer()
        let context = ModelContext(container)
        try configureRemoteNotesAccess(in: context, services: services)

        var importedWorkspace = NoteTreeManager.makeDefaultArchive()
        let sourceRootID = try XCTUnwrap(importedWorkspace.entries.first?.id)
        NoteTreeManager.rename(noteID: sourceRootID, to: "Imported Root", entries: &importedWorkspace.entries)
        importedWorkspace.bodies[sourceRootID] = try richTextData("Imported root body")
        let sourceChildID = NoteTreeManager.createNote(
            entries: &importedWorkspace.entries,
            bodies: &importedWorkspace.bodies,
            parentID: sourceRootID,
            after: nil,
            title: "Imported Child"
        )
        importedWorkspace.bodies[sourceChildID] = try richTextData("Imported child body")
        let snapshot = profileBackupSnapshot(notes: try legacyBackupNotes(from: importedWorkspace))

        let targetProfile = try makeRemoteNotesProfile(username: "import-target", displayName: "Import Target", in: context)
        var targetWorkspace = NoteTreeManager.makeDefaultArchive()
        let targetRootID = try XCTUnwrap(targetWorkspace.entries.first?.id)
        NoteTreeManager.rename(noteID: targetRootID, to: "Existing Note", entries: &targetWorkspace.entries)
        targetWorkspace.bodies[targetRootID] = try richTextData("Keep me")
        try await notesService.saveWorkspace(targetWorkspace, profileID: targetProfile.id, modelContext: context, services: services)

        let restoredProfile = try await services.backupService.restore(
            snapshot: snapshot,
            mode: .importNotes(profileID: targetProfile.id),
            modelContext: context,
            services: services
        )
        XCTAssertEqual(restoredProfile?.id, targetProfile.id)

        let mergedWorkspace = try await notesService.loadWorkspace(
            profileID: targetProfile.id,
            modelContext: context,
            services: services
        )

        let importedFolder = try XCTUnwrap(mergedWorkspace.entries.first(where: { $0.parentID == nil && $0.title.hasPrefix("Imported from Backup ") }))
        let importedRoot = try XCTUnwrap(mergedWorkspace.entries.first(where: { $0.parentID == importedFolder.id && $0.title == "Imported Root" }))
        let importedChild = try XCTUnwrap(mergedWorkspace.entries.first(where: { $0.parentID == importedRoot.id && $0.title == "Imported Child" }))

        XCTAssertTrue(mergedWorkspace.entries.contains(where: { $0.parentID == nil && $0.title == "Existing Note" }))
        XCTAssertFalse(mergedWorkspace.entries.contains(where: { $0.id == sourceRootID || $0.id == sourceChildID }))
        XCTAssertEqual(try plainString(from: mergedWorkspace.bodies[targetRootID] ?? Data()), "Keep me")
        XCTAssertEqual(try plainString(from: mergedWorkspace.bodies[importedRoot.id] ?? Data()), "Imported root body")
        XCTAssertEqual(try plainString(from: mergedWorkspace.bodies[importedChild.id] ?? Data()), "Imported child body")
    }

    @MainActor
    func testBackupImportNotesOnlyRejectsIncompleteNoteArchive() async throws {
        let tempRoot = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let notesService = ProfileNotesService(localRootProvider: localRootProvider(baseURL: tempRoot))
        let services = AppServices(
            keychain: InMemoryKeychainStore(),
            smbService: NotesRecordingSMBService(),
            notesService: notesService
        )
        let container = try makeNotesContainer()
        let context = ModelContext(container)
        try configureRemoteNotesAccess(in: context, services: services)

        var importedWorkspace = NoteTreeManager.makeDefaultArchive()
        let sourceRootID = try XCTUnwrap(importedWorkspace.entries.first?.id)
        importedWorkspace.bodies[sourceRootID] = try richTextData("Body that must survive")
        let exportedNotes = try legacyBackupNotes(from: importedWorkspace)
        let missingBodyFileName = "\(sourceRootID.uuidString.lowercased()).rtf.enc"
        var damagedNoteFiles = exportedNotes.archive.notes
        damagedNoteFiles.removeValue(forKey: missingBodyFileName)
        let damagedSnapshot = profileBackupSnapshot(notes: ProfileBackupNotes(
            configuration: exportedNotes.configuration,
            masterKey: exportedNotes.masterKey,
            archive: EncryptedNoteArchiveSnapshot(
                manifest: exportedNotes.archive.manifest,
                notes: damagedNoteFiles
            )
        ))

        let targetProfile = try makeRemoteNotesProfile(username: "broken-target", displayName: "Broken Target", in: context)
        var targetWorkspace = NoteTreeManager.makeDefaultArchive()
        let targetRootID = try XCTUnwrap(targetWorkspace.entries.first?.id)
        targetWorkspace.bodies[targetRootID] = try richTextData("Keep existing notes")
        try await notesService.saveWorkspace(targetWorkspace, profileID: targetProfile.id, modelContext: context, services: services)

        do {
            _ = try await services.backupService.restore(
                snapshot: damagedSnapshot,
                mode: .importNotes(profileID: targetProfile.id),
                modelContext: context,
                services: services
            )
            XCTFail("Expected notes import to reject an incomplete archive")
        } catch {
            XCTAssertEqual(error.localizedDescription, NotesServiceError.incompleteEncryptedArchive.localizedDescription)
        }

        let untouchedWorkspace = try await notesService.loadWorkspace(
            profileID: targetProfile.id,
            modelContext: context,
            services: services
        )
        XCTAssertEqual(untouchedWorkspace.entries.count, 1)
        XCTAssertEqual(try plainString(from: untouchedWorkspace.bodies[targetRootID] ?? Data()), "Keep existing notes")
    }

    @MainActor
    func testNotesStoreShowsRootPageOnInitialLoad() async throws {
        let tempRoot = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let notesService = ProfileNotesService(localRootProvider: localRootProvider(baseURL: tempRoot))
        let services = AppServices(
            keychain: InMemoryKeychainStore(),
            smbService: NotesRecordingSMBService(),
            notesService: notesService
        )
        let container = try makeNotesContainer()
        let context = ModelContext(container)
        try configureRemoteNotesAccess(in: context, services: services)
        let profile = try makeRemoteNotesProfile(username: "selected-user", displayName: "Selected User", in: context)
        try await seedRemoteNotesWorkspace(profileID: profile.id, notesService: notesService, context: context, services: services)

        let store = NotesStore()
        await store.load(profileID: profile.id, modelContext: context, services: services)

        XCTAssertEqual(store.loadState, .ready)
        XCTAssertNil(store.selectedNoteID)
        XCTAssertEqual(store.landingState, .root)
    }

    @MainActor
    func testNotesStorePreservesSelectionWhenReloadingSameProfile() async throws {
        let tempRoot = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let notesService = ProfileNotesService(localRootProvider: localRootProvider(baseURL: tempRoot))
        let services = AppServices(
            keychain: InMemoryKeychainStore(),
            smbService: NotesRecordingSMBService(),
            notesService: notesService
        )
        let container = try makeNotesContainer()
        let context = ModelContext(container)
        try configureRemoteNotesAccess(in: context, services: services)
        let profile = try makeRemoteNotesProfile(username: "reload-user", displayName: "Reload User", in: context)
        try await seedRemoteNotesWorkspace(profileID: profile.id, notesService: notesService, context: context, services: services)

        let store = NotesStore()
        await store.load(profileID: profile.id, modelContext: context, services: services)
        try store.importPlainTextNote(title: "Second Note", text: "Second body")
        let secondNoteID = try XCTUnwrap(store.selectedNoteID)
        await store.persistNow()

        store.select(try XCTUnwrap(store.outlineItems.first(where: { $0.id != secondNoteID })?.id))
        store.select(secondNoteID)
        await store.load(profileID: profile.id, modelContext: context, services: services)

        XCTAssertEqual(store.selectedNoteID, secondNoteID)
    }

    @MainActor
    func testNotesStorePreservesRootPageWhenReloadingSameProfile() async throws {
        let tempRoot = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let notesService = ProfileNotesService(localRootProvider: localRootProvider(baseURL: tempRoot))
        let services = AppServices(
            keychain: InMemoryKeychainStore(),
            smbService: NotesRecordingSMBService(),
            notesService: notesService
        )
        let container = try makeNotesContainer()
        let context = ModelContext(container)
        try configureRemoteNotesAccess(in: context, services: services)
        let profile = try makeRemoteNotesProfile(username: "root-user", displayName: "Root User", in: context)
        try await seedRemoteNotesWorkspace(profileID: profile.id, notesService: notesService, context: context, services: services)

        let store = NotesStore()
        await store.load(profileID: profile.id, modelContext: context, services: services)
        try store.importPlainTextNote(title: "Second Note", text: "Second body")
        store.showRoot()

        await store.load(profileID: profile.id, modelContext: context, services: services)

        XCTAssertNil(store.selectedNoteID)
        XCTAssertEqual(store.landingState, .root)
    }

    @MainActor
    func testNotesStoreAppendsSharedTextToExistingNote() async throws {
        let tempRoot = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let notesService = ProfileNotesService(localRootProvider: localRootProvider(baseURL: tempRoot))
        let services = AppServices(
            keychain: InMemoryKeychainStore(),
            smbService: NotesRecordingSMBService(),
            notesService: notesService
        )
        let container = try makeNotesContainer()
        let context = ModelContext(container)
        try configureRemoteNotesAccess(in: context, services: services)
        let profile = try makeRemoteNotesProfile(username: "shared-text-user", displayName: "Shared Text User", in: context)
        try await seedRemoteNotesWorkspace(profileID: profile.id, notesService: notesService, context: context, services: services)

        let store = NotesStore()
        await store.load(profileID: profile.id, modelContext: context, services: services)
        try store.importPlainTextNote(title: "Existing", text: "")
        let noteID = try XCTUnwrap(store.selectedNoteID)

        store.updateBody(NSAttributedString(string: "Existing note"))
        try store.appendSharedContent(to: noteID, kind: .text, text: "Shared text")

        XCTAssertEqual(store.selectedNoteID, noteID)
        XCTAssertEqual(store.noteBody.string, "Existing note\n\nShared text")
    }

    @MainActor
    func testNotesStoreAppendsSharedLinkAsHyperlink() async throws {
        let tempRoot = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let notesService = ProfileNotesService(localRootProvider: localRootProvider(baseURL: tempRoot))
        let services = AppServices(
            keychain: InMemoryKeychainStore(),
            smbService: NotesRecordingSMBService(),
            notesService: notesService
        )
        let container = try makeNotesContainer()
        let context = ModelContext(container)
        try configureRemoteNotesAccess(in: context, services: services)
        let profile = try makeRemoteNotesProfile(username: "shared-link-user", displayName: "Shared Link User", in: context)
        try await seedRemoteNotesWorkspace(profileID: profile.id, notesService: notesService, context: context, services: services)

        let store = NotesStore()
        await store.load(profileID: profile.id, modelContext: context, services: services)
        try store.importPlainTextNote(title: "Shared Link", text: "")
        let noteID = try XCTUnwrap(store.selectedNoteID)

        try store.appendSharedContent(to: noteID, kind: .url, text: "example.com")

        XCTAssertEqual(store.noteBody.string, "https://example.com")
        let link = store.noteBody.attribute(.link, at: 0, effectiveRange: nil) as? URL
        XCTAssertEqual(link, URL(string: "https://example.com"))
    }

    @MainActor
    func testNotesStorePromotesSharedURLShapedTextIntoHyperlink() async throws {
        let tempRoot = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let notesService = ProfileNotesService(localRootProvider: localRootProvider(baseURL: tempRoot))
        let services = AppServices(
            keychain: InMemoryKeychainStore(),
            smbService: NotesRecordingSMBService(),
            notesService: notesService
        )
        let container = try makeNotesContainer()
        let context = ModelContext(container)
        try configureRemoteNotesAccess(in: context, services: services)
        let profile = try makeRemoteNotesProfile(username: "shared-text-link-user", displayName: "Shared Text Link User", in: context)
        try await seedRemoteNotesWorkspace(profileID: profile.id, notesService: notesService, context: context, services: services)

        let store = NotesStore()
        await store.load(profileID: profile.id, modelContext: context, services: services)
        try store.importPlainTextNote(title: "Shared Text Link", text: "")
        let noteID = try XCTUnwrap(store.selectedNoteID)

        try store.appendSharedContent(to: noteID, kind: .text, text: "example.com")

        XCTAssertEqual(store.noteBody.string, "https://example.com")
        let link = store.noteBody.attribute(.link, at: 0, effectiveRange: nil) as? URL
        XCTAssertEqual(link, URL(string: "https://example.com"))
    }

    @MainActor
    func testNotesStoreBuildsTagRollupAcrossNotes() async throws {
        let tempRoot = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let notesService = ProfileNotesService(localRootProvider: localRootProvider(baseURL: tempRoot))
        let services = AppServices(
            keychain: InMemoryKeychainStore(),
            smbService: NotesRecordingSMBService(),
            notesService: notesService
        )
        let container = try makeNotesContainer()
        let context = ModelContext(container)
        try configureRemoteNotesAccess(in: context, services: services)
        let profile = try makeRemoteNotesProfile(username: "tag-user", displayName: "Tag User", in: context)
        try await seedRemoteNotesWorkspace(profileID: profile.id, notesService: notesService, context: context, services: services)

        let store = NotesStore()
        await store.load(profileID: profile.id, modelContext: context, services: services)
        try store.importPlainTextNote(title: "First", text: "#todo: First task")
        try store.importPlainTextNote(title: "Second", text: "#todo: Second task\n#later: Not now")

        XCTAssertEqual(store.availableTags, ["later", "todo"])

        store.selectTag("todo")
        XCTAssertEqual(store.tagRollupItems.map(\.lineText), ["Second task", "First task"])
    }

    @MainActor
    func testNotesStoreSearchResultsIncludeBodyPreview() async throws {
        let tempRoot = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let notesService = ProfileNotesService(localRootProvider: localRootProvider(baseURL: tempRoot))
        let services = AppServices(
            keychain: InMemoryKeychainStore(),
            smbService: NotesRecordingSMBService(),
            notesService: notesService
        )
        let container = try makeNotesContainer()
        let context = ModelContext(container)
        try configureRemoteNotesAccess(in: context, services: services)
        let profile = try makeRemoteNotesProfile(username: "search-user", displayName: "Search User", in: context)
        try await seedRemoteNotesWorkspace(profileID: profile.id, notesService: notesService, context: context, services: services)

        let store = NotesStore()
        await store.load(profileID: profile.id, modelContext: context, services: services)
        try store.importPlainTextNote(title: "Search", text: "A long body with the matching needle inside the note.")
        store.searchText = "needle"

        XCTAssertEqual(store.searchResults.count, 1)
        XCTAssertTrue(store.searchResults[0].preview.localizedCaseInsensitiveContains("needle"))
    }

    @MainActor
    func testNotesStoreKanbanConversionPreservesTextBodyWhenToggledBack() async throws {
        let tempRoot = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let notesService = ProfileNotesService(localRootProvider: localRootProvider(baseURL: tempRoot))
        let services = AppServices(
            keychain: InMemoryKeychainStore(),
            smbService: NotesRecordingSMBService(),
            notesService: notesService
        )
        let container = try makeNotesContainer()
        let context = ModelContext(container)
        try configureRemoteNotesAccess(in: context, services: services)
        let profile = try makeRemoteNotesProfile(username: "kanban-user", displayName: "Kanban User", in: context)
        try await seedRemoteNotesWorkspace(profileID: profile.id, notesService: notesService, context: context, services: services)

        let store = NotesStore()
        await store.load(profileID: profile.id, modelContext: context, services: services)
        try store.importPlainTextNote(title: "Kanban", text: "Preserve me")

        store.convertSelectedToKanban()
        XCTAssertEqual(store.selectedPageType, .kanban)
        let board = try XCTUnwrap(store.selectedBoard)
        XCTAssertEqual(board.columns.map(\.title), ["Inbox"])
        XCTAssertEqual(board.columns.first?.cards.map(\.text), ["Preserve me"])

        store.convertSelectedToText()
        XCTAssertEqual(store.selectedPageType, .text)
        XCTAssertEqual(store.noteBody.string, "Preserve me")
    }

    private func makeNotesContainer() throws -> ModelContainer {
        let schema = Schema([
            UserProfile.self,
            HomeAssistantConfig.self,
            SavedSMBConnection.self,
            SMBConnectionConfig.self,
            NotesConfig.self,
            SavedCalendarSource.self,
            DashboardShortcut.self,
            HankRemoteSettings.self
        ])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @MainActor
    private func configureRemoteNotesAccess(in context: ModelContext, services: AppServices) throws {
        try services.saveHankRemoteSettings(
            HankRemoteSettingsSnapshot(isEnabled: true, cloudURL: "http://127.0.0.1:1"),
            in: context
        )
        try services.setHankRemoteAccessToken("session-token")
    }

    @MainActor
    private func makeRemoteNotesProfile(
        username: String,
        displayName: String,
        in context: ModelContext
    ) throws -> UserProfile {
        let profile = UserProfile(
            username: username,
            displayName: displayName,
            passwordHash: "hash",
            passwordSalt: "salt",
            authModeRawValue: UserProfileAuthMode.hankRemote.rawValue,
            remoteUserID: "remote-\(UUID().uuidString.lowercased())",
            remoteEmail: "\(username)@example.com"
        )
        context.insert(profile)
        try context.save()
        return profile
    }

    @MainActor
    private func seedRemoteNotesWorkspace(
        _ workspace: NotesWorkspaceSnapshot = NoteTreeManager.makeDefaultArchive(),
        profileID: UUID,
        notesService: ProfileNotesService,
        context: ModelContext,
        services: AppServices
    ) async throws {
        try await notesService.saveWorkspace(workspace, profileID: profileID, modelContext: context, services: services)
    }

    private func profileBackupSnapshot(notes: ProfileBackupNotes?) -> ProfileBackupSnapshot {
        ProfileBackupSnapshot(
            schemaVersion: ProfileBackupSnapshot.currentSchemaVersion,
            exportedAt: .now,
            profile: ProfileBackupProfile(
                username: "import-source",
                displayName: "Import Source",
                passwordHash: "hash",
                passwordSalt: "salt",
                authModeRawValue: UserProfileAuthMode.hankRemote.rawValue,
                remoteUserID: "remote-import-source",
                remoteEmail: "import-source@example.com"
            ),
            homeAssistant: ProfileBackupHomeAssistant(
                configuration: HomeAssistantConnectionConfiguration(),
                token: "",
                trustedCertificates: []
            ),
            smb: ProfileBackupSMB(
                configuration: SMBConnectionDetails(),
                password: ""
            ),
            savedSMBConnections: [],
            savedCalendarSources: [],
            dashboardTiles: [],
            notes: notes
        )
    }

    private func legacyBackupNotes(
        from workspace: NotesWorkspaceSnapshot,
        keyData: Data = Data(repeating: 3, count: 32)
    ) throws -> ProfileBackupNotes {
        let key = SymmetricKey(data: keyData)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        func seal(_ data: Data) throws -> Data {
            let sealedBox = try AES.GCM.seal(data, using: key)
            guard let combined = sealedBox.combined else {
                throw NotesServiceError.invalidEncryptedArchive
            }
            return combined
        }

        let manifestData = try encoder.encode(NoteTreeManager.normalizedEntries(workspace.entries))
        var noteFiles: [String: Data] = [:]
        for entry in workspace.entries {
            noteFiles["\(entry.id.uuidString.lowercased()).rtf.enc"] = try seal(workspace.bodies[entry.id] ?? Data())
            if let board = workspace.boards[entry.id] {
                noteFiles["\(entry.id.uuidString.lowercased()).kanban.enc"] = try seal(try encoder.encode(board))
            }
        }

        return ProfileBackupNotes(
            configuration: ProfileBackupNotesConfiguration(storageLocation: .device, pendingSMBMigration: false),
            masterKey: keyData.base64EncodedString(),
            archive: EncryptedNoteArchiveSnapshot(
                manifest: try seal(manifestData),
                notes: noteFiles
            )
        )
    }

    private func richTextData(_ string: String) throws -> Data {
        let attributed = NSAttributedString(string: string)
        return try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    private func plainString(from data: Data) throws -> String {
        guard !data.isEmpty else {
            return ""
        }
        if let attributed = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ) {
            return attributed.string
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func localRootProvider(baseURL: URL) -> (UUID, FileManager) throws -> URL {
        { profileID, fileManager in
            let root = baseURL.appendingPathComponent(profileID.uuidString.lowercased(), isDirectory: true)
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            return root
        }
    }
}

private final class NotesRecordingSMBService: SMBServicing, @unchecked Sendable {
    private(set) var storage: [String: Data] = [:]
    private(set) var directories: Set<String> = [""]

    func connect(
        config: SMBConnectionDetails,
        password: String,
        context: HankRemoteConnectionContext
    ) async throws {}

    func list(path: String) async throws -> [SMBItem] {
        let normalizedPath = FileBrowserPathing.normalized(path)
        guard directories.contains(normalizedPath) else {
            throw SMBServiceError.notConnected
        }

        let prefix = normalizedPath.isEmpty ? "" : "\(normalizedPath)/"
        var itemsByName: [String: SMBItem] = [:]

        for directory in directories where directory.hasPrefix(prefix) && directory != normalizedPath {
            let remainder = String(directory.dropFirst(prefix.count))
            guard let component = remainder.split(separator: "/").first.map(String.init), !component.isEmpty else {
                continue
            }
            let childPath = FileBrowserPathing.childPath(named: component, in: normalizedPath)
            itemsByName[component] = SMBItem(path: childPath, name: component, isDirectory: true, size: nil, modifiedAt: nil)
        }

        for (path, data) in storage where path.hasPrefix(prefix) {
            let remainder = String(path.dropFirst(prefix.count))
            guard let component = remainder.split(separator: "/").first.map(String.init), !component.isEmpty else {
                continue
            }
            let childPath = FileBrowserPathing.childPath(named: component, in: normalizedPath)
            if itemsByName[component] == nil {
                itemsByName[component] = SMBItem(path: childPath, name: component, isDirectory: false, size: Int64(data.count), modifiedAt: nil)
            }
        }

        return itemsByName.values.sorted { $0.name < $1.name }
    }

    func download(path: String) async throws -> Data {
        storage[FileBrowserPathing.normalized(path)] ?? Data()
    }

    func download(path: String, to localURL: URL) async throws {
        let data = storage[FileBrowserPathing.normalized(path)] ?? Data()
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: localURL, options: [.atomic])
    }

    func createDirectory(path: String) async throws {
        directories.insert(FileBrowserPathing.normalized(path))
    }

    func upload(data: Data, path: String) async throws {
        let normalizedPath = FileBrowserPathing.normalized(path)
        directories.insert(FileBrowserPathing.parentPath(of: normalizedPath))
        storage[normalizedPath] = data
    }

    func upload(fileAt localURL: URL, path: String) async throws {
        let data = try Data(contentsOf: localURL)
        try await upload(data: data, path: path)
    }

    func move(from: String, to: String, isDirectory: Bool) async throws {
        let fromPath = FileBrowserPathing.normalized(from)
        let toPath = FileBrowserPathing.normalized(to)
        storage[toPath] = storage[fromPath]
        storage.removeValue(forKey: fromPath)
    }

    func delete(path: String, isDirectory: Bool) async throws {
        let normalizedPath = FileBrowserPathing.normalized(path)
        if isDirectory {
            directories.remove(normalizedPath)
            storage = storage.filter { !$0.key.hasPrefix(normalizedPath + "/") }
        } else {
            storage.removeValue(forKey: normalizedPath)
        }
    }

    func disconnect() async {}
}

@MainActor
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}
