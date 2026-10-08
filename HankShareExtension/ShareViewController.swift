import MobileCoreServices
import UniformTypeIdentifiers
import UIKit

private struct IncomingSharePayload: Codable {
    enum Kind: String, Codable {
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

    var canImportToNotes: Bool {
        kind != .file
    }

    func withDestination(_ noteID: UUID) -> IncomingSharePayload {
        IncomingSharePayload(
            id: id,
            kind: kind,
            suggestedName: suggestedName,
            relativePath: relativePath,
            receivedAt: receivedAt,
            destinationNoteID: noteID
        )
    }
}

private struct SharedNoteDestination: Codable, Hashable {
    let noteID: UUID
    let title: String
    let breadcrumb: String
    let updatedAt: Date
}

private final class PayloadCompletionBox: @unchecked Sendable {
    private let handler: (IncomingSharePayload?) -> Void

    init(_ handler: @escaping (IncomingSharePayload?) -> Void) {
        self.handler = handler
    }

    func callAsFunction(_ payload: IncomingSharePayload?) {
        handler(payload)
    }
}

private final class ItemProviderBox: @unchecked Sendable {
    let provider: NSItemProvider

    init(_ provider: NSItemProvider) {
        self.provider = provider
    }
}

final class ShareViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let manifestName = "incoming-shares.json"
    private let noteDestinationIndexName = "note-destinations.json"

    private var hasProcessedItems = false
    private var stagedPayloads: [IncomingSharePayload] = []
    private var noteDestinations: [SharedNoteDestination] = []
    private var pendingNotePayload: IncomingSharePayload?

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .large)
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let cancelButton = UIButton(type: .system)
    private var isAwaitingDismissal = false

    override func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
        noteDestinations = loadCachedNoteDestinations()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasProcessedItems else {
            return
        }
        hasProcessedItems = true
        stageSharedItems()
    }

    private func configureUI() {
        view.backgroundColor = .systemBackground

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.text = "Share To Hank"

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 0
        subtitleLabel.text = "Preparing your item…"

        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.startAnimating()

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.isHidden = true
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "NoteCell")

        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        view.addSubview(titleLabel)
        view.addSubview(subtitleLabel)
        view.addSubview(activityIndicator)
        view.addSubview(tableView)
        view.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            activityIndicator.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 20),
            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            tableView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 12),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: cancelButton.topAnchor, constant: -12),

            cancelButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            cancelButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            cancelButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            cancelButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    private func stageSharedItems() {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            finish()
            return
        }

        let attachments = extensionItems.flatMap { $0.attachments ?? [] }
        guard !attachments.isEmpty else {
            finish()
            return
        }

        let group = DispatchGroup()
        let payloadLock = NSLock()
        var nextPayloads: [IncomingSharePayload] = []

        for provider in attachments {
            group.enter()
            load(provider: provider) { payload in
                if let payload {
                    payloadLock.lock()
                    nextPayloads.append(payload)
                    payloadLock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            self.activityIndicator.stopAnimating()
            self.stagedPayloads = nextPayloads.sorted { $0.receivedAt < $1.receivedAt }

            guard !self.stagedPayloads.isEmpty else {
                self.finish()
                return
            }

            if self.stagedPayloads.count == 1,
               let payload = self.stagedPayloads.first,
               payload.canImportToNotes,
               !self.noteDestinations.isEmpty {
                self.pendingNotePayload = payload
                self.subtitleLabel.text = "Choose a Hank note to append this item."
                self.tableView.isHidden = false
                self.tableView.reloadData()
                return
            }

            self.commit(payloads: self.stagedPayloads)
        }
    }

    private func load(provider: NSItemProvider, completion: @escaping (IncomingSharePayload?) -> Void) {
        let completionBox = PayloadCompletionBox(completion)
        let providerBox = ItemProviderBox(provider)
        let suggestedName = provider.suggestedName

        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                completionBox(Self.stageTextItem(item, suggestedName: "Shared Link.txt", kind: .url))
            }
            return
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                completionBox(Self.stageTextItem(item, suggestedName: "Shared Text.txt", kind: .text))
            }
            return
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let payload = Self.stageFileItem(item, suggestedName: suggestedName) {
                    completionBox(payload)
                    return
                }

                Self.loadFileRepresentation(from: providerBox, suggestedName: suggestedName, completion: completionBox)
            }
            return
        }

        if Self.preferredFileTypeIdentifier(for: provider) != nil {
            Self.loadFileRepresentation(from: providerBox, suggestedName: suggestedName, completion: completionBox)
            return
        }

        completionBox(nil)
    }

    private func commit(payloads: [IncomingSharePayload]) {
        do {
            try append(payloads: payloads)
            openHank(for: payloads)
        } catch {
            subtitleLabel.text = error.localizedDescription
            tableView.isHidden = true
            return
        }
    }

    private func loadCachedNoteDestinations() -> [SharedNoteDestination] {
        guard let root = Self.sharedRoot() else {
            return []
        }

        let url = root.appendingPathComponent(noteDestinationIndexName)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([SharedNoteDestination].self, from: data) else {
            return []
        }

        return decoded.sorted { lhs, rhs in
            if lhs.breadcrumb == rhs.breadcrumb {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return lhs.breadcrumb.localizedCaseInsensitiveCompare(rhs.breadcrumb) == .orderedAscending
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        noteDestinations.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "NoteCell", for: indexPath)
        let destination = noteDestinations[indexPath.row]
        var configuration = UIListContentConfiguration.subtitleCell()
        configuration.text = destination.title
        configuration.secondaryText = destination.breadcrumb.isEmpty ? "Top level note" : destination.breadcrumb
        cell.contentConfiguration = configuration
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let pendingNotePayload else {
            return
        }
        let destination = noteDestinations[indexPath.row]
        commit(payloads: [pendingNotePayload.withDestination(destination.noteID)])
    }

    @objc
    private func cancelTapped() {
        if isAwaitingDismissal {
            finish()
            return
        }
        finish()
    }

    nonisolated private static func loadFileRepresentation(
        from providerBox: ItemProviderBox,
        suggestedName: String?,
        completion: PayloadCompletionBox
    ) {
        guard let typeIdentifier = preferredFileTypeIdentifier(for: providerBox.provider) else {
            completion(nil)
            return
        }

        providerBox.provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
            completion(url.flatMap { stageFile(at: $0, suggestedName: suggestedName) })
        }
    }

    nonisolated private static func preferredFileTypeIdentifier(for provider: NSItemProvider) -> String? {
        let preferredTypes = [
            UTType.image.identifier,
            UTType.movie.identifier,
            UTType.audio.identifier,
            UTType.pdf.identifier,
            UTType.content.identifier,
            UTType.data.identifier,
            UTType.item.identifier
        ]

        for typeIdentifier in preferredTypes where provider.hasItemConformingToTypeIdentifier(typeIdentifier) {
            return typeIdentifier
        }

        return provider.registeredTypeIdentifiers.first { identifier in
            guard let type = UTType(identifier) else {
                return false
            }
            return type.conforms(to: .content) || type.conforms(to: .data) || type.conforms(to: .item)
        }
    }

    nonisolated private static func stageTextItem(
        _ item: NSSecureCoding?,
        suggestedName: String,
        kind: IncomingSharePayload.Kind
    ) -> IncomingSharePayload? {
        if let url = item as? URL {
            return stageText(url.absoluteString, suggestedName: suggestedName, kind: kind)
        }

        if let string = item as? String {
            return stageText(string, suggestedName: suggestedName, kind: kind)
        }

        if let string = item as? NSString {
            return stageText(string as String, suggestedName: suggestedName, kind: kind)
        }

        if let attributed = item as? NSAttributedString {
            return stageText(attributed.string, suggestedName: suggestedName, kind: kind)
        }

        return nil
    }

    nonisolated private static func stageFileItem(_ item: NSSecureCoding?, suggestedName: String?) -> IncomingSharePayload? {
        guard let sourceURL = item as? URL else {
            return nil
        }

        return stageFile(at: sourceURL, suggestedName: suggestedName)
    }

    nonisolated private static func stageFile(at sourceURL: URL, suggestedName: String?) -> IncomingSharePayload? {
        guard let root = sharedRoot() else {
            return nil
        }

        let id = UUID()
        let fileName = sanitizedFileName(suggestedName, fallback: sourceURL.lastPathComponent)
        let relativePath = "Staged/\(id.uuidString)/\(fileName)"
        let destinationURL = root.appendingPathComponent(relativePath)

        do {
            try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destinationURL)
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return IncomingSharePayload(
                id: id,
                kind: .file,
                suggestedName: fileName,
                relativePath: relativePath,
                receivedAt: .now,
                destinationNoteID: nil
            )
        } catch {
            return nil
        }
    }

    nonisolated private static func sanitizedFileName(_ suggestedName: String?, fallback: String) -> String {
        let trimmedName = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedName.isEmpty {
            return trimmedName
        }

        let fallbackName = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallbackName.isEmpty ? "Shared File" : fallbackName
    }

    nonisolated private static func stageText(
        _ text: String,
        suggestedName: String,
        kind: IncomingSharePayload.Kind
    ) -> IncomingSharePayload? {
        guard let root = sharedRoot() else {
            return nil
        }

        let id = UUID()
        let normalized = normalizedSharedText(text, suggestedName: suggestedName, preferredKind: kind)
        let relativePath = "Staged/\(id.uuidString)/\(normalized.suggestedName)"
        let destinationURL = root.appendingPathComponent(relativePath)

        do {
            try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(normalized.text.utf8).write(to: destinationURL, options: [.atomic])
            return IncomingSharePayload(
                id: id,
                kind: normalized.kind,
                suggestedName: normalized.suggestedName,
                relativePath: relativePath,
                receivedAt: .now,
                destinationNoteID: nil
            )
        } catch {
            return nil
        }
    }

    nonisolated private static func normalizedSharedText(
        _ rawText: String,
        suggestedName: String,
        preferredKind: IncomingSharePayload.Kind
    ) -> (text: String, kind: IncomingSharePayload.Kind, suggestedName: String) {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = normalizedURL(from: trimmed) else {
            return (rawText, preferredKind, suggestedName)
        }

        return (url.absoluteString, .url, "Shared Link.txt")
    }

    nonisolated private static func normalizedURL(from rawValue: String) -> URL? {
        guard !rawValue.isEmpty else {
            return nil
        }

        if !rawValue.contains("://") {
            guard !rawValue.contains(" "), !rawValue.contains("\n"), rawValue.contains(".") else {
                return nil
            }
            return URL(string: "https://\(rawValue)")
        }

        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(location: 0, length: rawValue.utf16.count)
        if let match = detector?.firstMatch(in: rawValue, options: [], range: range),
           match.range == range,
           let url = match.url {
            return url
        }
        return URL(string: rawValue)
    }

    private func append(payloads: [IncomingSharePayload]) throws {
        guard let root = Self.sharedRoot() else {
            return
        }

        let manifestURL = root.appendingPathComponent(manifestName)
        let existing: [IncomingSharePayload]
        if let data = try? Data(contentsOf: manifestURL),
           let decoded = try? JSONDecoder().decode([IncomingSharePayload].self, from: data) {
            existing = decoded
        } else {
            existing = []
        }

        let data = try JSONEncoder().encode(existing + payloads)
        try data.write(to: manifestURL, options: [.atomic])
    }

    nonisolated private static func sharedRoot() -> URL? {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.dropfile.Hank") else {
            return nil
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func openHank(for payloads: [IncomingSharePayload]) {
        let route: String
        if payloads.count == 1, payloads.first?.canImportToNotes == true {
            route = "hank://import?destination=notes"
        } else {
            route = "hank://import"
        }

        guard let url = URL(string: route) else {
            return
        }

        extensionContext?.open(url) { [weak self] success in
            guard !success else {
                Task { @MainActor [weak self] in
                    self?.finish()
                }
                return
            }
            Task { @MainActor [weak self] in
                self?.showSavedForLaterState()
            }
        }
    }

    @MainActor
    private func showSavedForLaterState() {
        isAwaitingDismissal = true
        activityIndicator.stopAnimating()
        tableView.isHidden = true
        subtitleLabel.text = "Saved to Hank. If the app did not open automatically, open Hank later and your import will still be available."
        cancelButton.setTitle("Done", for: .normal)
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
