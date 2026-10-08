import Foundation
import UniformTypeIdentifiers

enum LocalFileArea: String, CaseIterable, Identifiable, Sendable, Codable {
    case inbox
    case imported
    case documents

    var id: Self { self }

    var title: String {
        switch self {
        case .inbox:
            "Inbox"
        case .imported:
            "Imported"
        case .documents:
            "Documents"
        }
    }
}

struct LocalFileItem: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64?
    let modifiedAt: Date?

    var id: URL { url }
}

enum IncomingShareDestination: Equatable, Sendable {
    case notes
    case localInbox
    case smb(path: String)
}

struct IncomingSharePayload: Identifiable, Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case text
        case url
        case file
    }

    let id: UUID
    let kind: Kind
    let suggestedName: String
    let relativePath: String
    let receivedAt: Date
    let destinationNoteID: UUID?

    init(
        id: UUID = UUID(),
        kind: Kind,
        suggestedName: String,
        relativePath: String,
        receivedAt: Date = .now,
        destinationNoteID: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.suggestedName = suggestedName
        self.relativePath = relativePath
        self.receivedAt = receivedAt
        self.destinationNoteID = destinationNoteID
    }

    var canImportToNotes: Bool {
        switch kind {
        case .text, .url:
            return true
        case .file:
            return false
        }
    }

    var notesActionTitle: String {
        switch kind {
        case .url:
            return "Add Link To Notes"
        case .text, .file:
            return "Add To Notes"
        }
    }

    var notesSuggestedTitle: String {
        let trimmedName = suggestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle: String

        switch kind {
        case .text:
            fallbackTitle = "Shared Note"
        case .url:
            fallbackTitle = "Shared Link"
        case .file:
            fallbackTitle = "Shared File"
        }

        guard !trimmedName.isEmpty else {
            return fallbackTitle
        }

        let url = URL(fileURLWithPath: trimmedName)
        let baseName = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return baseName.isEmpty ? fallbackTitle : baseName
    }

    func decodeNotesText(from data: Data) throws -> String {
        guard canImportToNotes else {
            throw IncomingSharePayloadError.unsupportedNotesImport
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw IncomingSharePayloadError.unreadableTextContent
        }

        return text
    }
}

struct SharedNoteDestination: Identifiable, Hashable, Codable, Sendable {
    let noteID: UUID
    let title: String
    let breadcrumb: String
    let updatedAt: Date

    var id: UUID { noteID }
}

enum IncomingSharePayloadError: LocalizedError {
    case unsupportedNotesImport
    case unreadableTextContent

    var errorDescription: String? {
        switch self {
        case .unsupportedNotesImport:
            return "Only shared text and links can be added to Notes."
        case .unreadableTextContent:
            return "The shared text could not be read."
        }
    }
}

enum LocalFileServiceError: LocalizedError {
    case missingAppGroup
    case missingPayloadFile
    case emptyImport

    var errorDescription: String? {
        switch self {
        case .missingAppGroup:
            "Hank could not open its shared import container."
        case .missingPayloadFile:
            "The shared item is no longer available."
        case .emptyImport:
            "Choose at least one file to import."
        }
    }
}

final class LocalFileService: @unchecked Sendable {
    static let appGroupIdentifier = "group.com.dropfile.Hank"
    static let incomingManifestName = "incoming-shares.json"
    static let noteDestinationIndexName = "note-destinations.json"

    private let fileManager: FileManager
    private let sharedContainerURLProvider: (FileManager) -> URL?

    init(
        fileManager: FileManager = .default,
        sharedContainerURLProvider: ((FileManager) -> URL?)? = nil
    ) {
        self.fileManager = fileManager
        self.sharedContainerURLProvider = sharedContainerURLProvider
            ?? { $0.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier) }
    }

    func rootDirectory() throws -> URL {
        let root = try AppFileLocations.applicationSupportDirectory(fileManager: fileManager)
            .appendingPathComponent("LocalFiles", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        for area in LocalFileArea.allCases {
            try fileManager.createDirectory(at: directory(for: area, root: root), withIntermediateDirectories: true)
        }
        return root
    }

    func directory(for area: LocalFileArea) throws -> URL {
        try directory(for: area, root: rootDirectory())
    }

    func list(area: LocalFileArea) throws -> [LocalFileItem] {
        let directory = try directory(for: area)
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        return try urls
            .map(makeItem)
            .sorted {
                if $0.isDirectory != $1.isDirectory {
                    return $0.isDirectory && !$1.isDirectory
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    @discardableResult
    func importFile(at sourceURL: URL, to area: LocalFileArea = .imported) throws -> URL {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let destinationDirectory = try directory(for: area)
        let destination = try uniqueDestinationURL(
            named: sourceURL.lastPathComponent.isEmpty ? "Imported File" : sourceURL.lastPathComponent,
            in: destinationDirectory,
            isDirectory: sourceURL.hasDirectoryPath
        )
        try fileManager.copyItem(at: sourceURL, to: destination)
        return destination
    }

    @discardableResult
    func writeText(_ text: String, suggestedName: String, to area: LocalFileArea = .inbox) throws -> URL {
        let directory = try directory(for: area)
        let fileName = suggestedName.isEmpty ? "Shared Text.txt" : suggestedName
        let destination = try uniqueDestinationURL(named: fileName, in: directory, isDirectory: false)
        try Data(text.utf8).write(to: destination, options: [.atomic])
        return destination
    }

    func remove(_ item: LocalFileItem) throws {
        try fileManager.removeItem(at: item.url)
    }

    func sharedContainerURL() throws -> URL {
        guard let url = sharedContainerURLProvider(fileManager) else {
            throw LocalFileServiceError.missingAppGroup
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func incomingPayloads() throws -> [IncomingSharePayload] {
        let manifestURL = try sharedContainerURL().appendingPathComponent(Self.incomingManifestName)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return []
        }
        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder().decode([IncomingSharePayload].self, from: data)
            .sorted { $0.receivedAt < $1.receivedAt }
    }

    func cachedNoteDestinations() throws -> [SharedNoteDestination] {
        let url = try sharedContainerURL().appendingPathComponent(Self.noteDestinationIndexName)
        guard fileManager.fileExists(atPath: url.path) else {
            return []
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([SharedNoteDestination].self, from: data)
            .sorted { lhs, rhs in
                if lhs.breadcrumb == rhs.breadcrumb {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return lhs.breadcrumb.localizedCaseInsensitiveCompare(rhs.breadcrumb) == .orderedAscending
            }
    }

    func writeCachedNoteDestinations(_ destinations: [SharedNoteDestination]) throws {
        let url = try sharedContainerURL().appendingPathComponent(Self.noteDestinationIndexName)
        let data = try JSONEncoder().encode(destinations)
        try data.write(to: url, options: [.atomic])
    }

    func sourceURL(for payload: IncomingSharePayload) throws -> URL {
        let url = try sharedContainerURL().appendingPathComponent(payload.relativePath)
        guard fileManager.fileExists(atPath: url.path) else {
            throw LocalFileServiceError.missingPayloadFile
        }
        return url
    }

    func clearIncomingPayload(_ payload: IncomingSharePayload) throws {
        var payloads = try incomingPayloads()
        payloads.removeAll { $0.id == payload.id }
        let manifestURL = try sharedContainerURL().appendingPathComponent(Self.incomingManifestName)
        let data = try JSONEncoder().encode(payloads)
        try data.write(to: manifestURL, options: [.atomic])

        let sourceURL = try sharedContainerURL().appendingPathComponent(payload.relativePath)
        if fileManager.fileExists(atPath: sourceURL.path) {
            try fileManager.removeItem(at: sourceURL)
        }
    }

    private func directory(for area: LocalFileArea, root: URL) -> URL {
        root.appendingPathComponent(area.rawValue, isDirectory: true)
    }

    private func makeItem(url: URL) throws -> LocalFileItem {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        return LocalFileItem(
            url: url,
            name: url.lastPathComponent,
            isDirectory: values.isDirectory == true,
            size: values.fileSize.map(Int64.init),
            modifiedAt: values.contentModificationDate
        )
    }

    private func uniqueDestinationURL(named name: String, in directory: URL, isDirectory: Bool) throws -> URL {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Imported File" : name
        var candidate = directory.appendingPathComponent(cleanName, isDirectory: isDirectory)
        guard fileManager.fileExists(atPath: candidate.path) else {
            return candidate
        }

        let baseURL = URL(fileURLWithPath: cleanName)
        let ext = isDirectory ? "" : baseURL.pathExtension
        let baseName = ext.isEmpty ? cleanName : baseURL.deletingPathExtension().lastPathComponent
        var counter = 1

        while fileManager.fileExists(atPath: candidate.path) {
            let nextName = ext.isEmpty ? "\(baseName) \(counter)" : "\(baseName) \(counter).\(ext)"
            candidate = directory.appendingPathComponent(nextName, isDirectory: isDirectory)
            counter += 1
        }

        return candidate
    }
}
