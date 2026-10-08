import Foundation
import CryptoKit
import SwiftData
import UIKit
import UniformTypeIdentifiers

enum HankAssistantMessageRole: String {
    case user
    case assistant
    case system
}

struct HankAssistantNavigationTarget: Identifiable, Equatable {
    enum Kind: Equatable {
        case note(noteID: UUID, searchQuery: String?)
        case calendar(date: Date, eventID: String?)
        case file(path: String)
        case homeAssistant(entityID: String)
    }

    let id = UUID()
    let kind: Kind
}

struct HankAssistantResultCard: Identifiable, Equatable {
    enum Kind {
        case note
        case calendar
        case file
        case homeAssistant
        case projectDoc
        case media
    }

    let id: UUID
    let kind: Kind
    let title: String
    let summary: String
    let actionTitle: String
    let imageURL: URL?
    let target: HankAssistantNavigationTarget?

    init(
        id: UUID = UUID(),
        kind: Kind,
        title: String,
        summary: String,
        actionTitle: String,
        imageURL: URL? = nil,
        target: HankAssistantNavigationTarget? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.summary = summary
        self.actionTitle = actionTitle
        self.imageURL = imageURL
        self.target = target
    }
}

struct HankAssistantMessage: Identifiable, Equatable {
    let id: UUID
    let remoteID: String?
    let role: HankAssistantMessageRole
    let text: String
    let createdAt: Date
    let cards: [HankAssistantResultCard]
    let diagnostics: HankAssistantDiagnostics?

    init(
        id: UUID = UUID(),
        remoteID: String? = nil,
        role: HankAssistantMessageRole,
        text: String,
        createdAt: Date = .now,
        cards: [HankAssistantResultCard] = [],
        diagnostics: HankAssistantDiagnostics? = nil
    ) {
        self.id = id
        self.remoteID = remoteID
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.cards = cards
        self.diagnostics = diagnostics
    }
}

struct HankAssistantSession: Identifiable, Equatable {
    let id: UUID
    let remoteID: String
    var title: String
    var messages: [HankAssistantMessage]
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        remoteID: String,
        title: String,
        messages: [HankAssistantMessage],
        updatedAt: Date = .now
    ) {
        self.id = id
        self.remoteID = remoteID
        self.title = title
        self.messages = messages
        self.updatedAt = updatedAt
    }

    var previewText: String {
        guard let lastMessage = messages.last else {
            return "Start a conversation"
        }
        let trimmed = lastMessage.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Start a conversation" : trimmed
    }
}

struct HankAssistantPendingConfirmation: Identifiable, Equatable {
    let id: String
    let title: String
    let message: String
    let summary: String
    let details: [HankAssistantPendingConfirmationDetail]
    let isDestructive: Bool
    let confirmTitle: String
    let cancelTitle: String
}

struct HankAssistantDownloadProgress: Identifiable, Equatable {
    let id: String
    let title: String
    let completed: Int
    let total: Int
    let failed: Int
    let skipped: Int
    let status: String
    let filePath: String?

    var fractionCompleted: Double? {
        guard total > 0 else {
            return nil
        }
        return min(1, max(0, Double(completed) / Double(total)))
    }

    var isComplete: Bool {
        status == "completed" || (total > 0 && completed >= total)
    }
}

struct HankAssistantPendingConfirmationDetail: Equatable, Hashable {
    let label: String
    let value: String
}

struct HankAssistantAttachmentPreview: Identifiable {
    let url: URL

    var id: String { url.path }
}

struct HankAssistantDiagnostics: Equatable {
    let toolKind: String
    let intentKind: String
    let query: String
    let mediaSelectionTitle: String
    let mediaSelectionPath: String

    init(
        toolKind: String,
        intentKind: String,
        query: String,
        mediaSelectionTitle: String,
        mediaSelectionPath: String
    ) {
        self.toolKind = toolKind
        self.intentKind = intentKind
        self.query = query
        self.mediaSelectionTitle = mediaSelectionTitle
        self.mediaSelectionPath = mediaSelectionPath
    }

    init(remote: HankRemoteAssistantDiagnostics) {
        self.init(
            toolKind: remote.toolKind,
            intentKind: remote.intentKind,
            query: remote.query,
            mediaSelectionTitle: remote.mediaSelectionTitle,
            mediaSelectionPath: remote.mediaSelectionPath
        )
    }
}

struct HankAssistantLogEntry: Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let event: String
    let details: [String]

    init(id: UUID = UUID(), createdAt: Date = .now, event: String, details: [String] = []) {
        self.id = id
        self.createdAt = createdAt
        self.event = event
        self.details = details
    }
}

struct HankAssistantSlashCommand: Identifiable, Equatable {
    let command: String
    let label: String
    let description: String

    var id: String { command }
}

@MainActor
final class HankAssistantStore: ObservableObject {
    @Published private(set) var sessions: [HankAssistantSession] = []
    @Published var selectedSessionID: HankAssistantSession.ID? {
        didSet {
            persistSelectedSession()
        }
    }
    @Published var draftText = "" {
        didSet {
            persistDraft()
        }
    }
    @Published private(set) var isSending = false
    @Published private(set) var activeProfileID: UUID?
    @Published private(set) var statusText = "Ask Hank about notes, calendar, or SMB files."
    @Published private(set) var pendingConfirmation: HankAssistantPendingConfirmation?
    @Published private(set) var downloadProgress: HankAssistantDownloadProgress?
    @Published private(set) var pendingNavigationTarget: HankAssistantNavigationTarget?
    @Published private(set) var draftAttachments: [HankAssistantStagedAttachment] = []
    @Published private(set) var submittedAttachments: [HankAssistantStagedAttachment] = []
    @Published private(set) var logEntries: [HankAssistantLogEntry] = []
    @Published private(set) var slashCommands: [HankAssistantSlashCommand] = HankAssistantStore.builtinSlashCommands
    @Published var attachmentPreview: HankAssistantAttachmentPreview?

    private weak var services: AppServices?
    private var modelContext: ModelContext?
    private var restoredSelectedRemoteID: String?
    private var isRestoringPersistedState = false
    private let attachmentStaging = HankAssistantAttachmentStagingService()
    private var mediaRealtimeTask: Task<Void, Never>?

    var selectedSession: HankAssistantSession? {
        guard let selectedSessionID else {
            return nil
        }
        return sessions.first(where: { $0.id == selectedSessionID })
    }

    var stagedAttachments: [HankAssistantStagedAttachment] {
        draftAttachments + submittedAttachments
    }

    func clearLogs() {
        logEntries.removeAll()
    }

    func markLogsCopied() {
        appendLog("Logs copied")
    }

    func diagnosticLogText() -> String {
        var lines: [String] = []
        lines.append("Hank Chat Diagnostic Log")
        lines.append("Generated: \(Self.logTimestamp(.now))")
        lines.append("Active profile: \(activeProfileID?.uuidString ?? "none")")
        if let selectedSession {
            lines.append("Selected session: \(selectedSession.title) (\(selectedSession.remoteID))")
            lines.append("Messages: \(selectedSession.messages.count)")
        } else {
            lines.append("Selected session: none")
        }
        lines.append("")

        if logEntries.isEmpty {
            lines.append("No chat events recorded on this device yet.")
        } else {
            for entry in logEntries {
                lines.append("[\(Self.logTimestamp(entry.createdAt))] \(entry.event)")
                for detail in entry.details {
                    lines.append("  \(detail)")
                }
            }
        }

        if let selectedSession, !selectedSession.messages.isEmpty {
            lines.append("")
            lines.append("Visible messages:")
            for message in selectedSession.messages.suffix(20) {
                lines.append("- \(message.role.rawValue) \(message.remoteID ?? "local") at \(Self.logTimestamp(message.createdAt))")
                lines.append("  text: \(Self.oneLine(message.text, limit: 240))")
                if !message.cards.isEmpty {
                    lines.append("  cards: \(message.cards.count)")
                }
                if let diagnostics = message.diagnostics {
                    lines.append("  diagnostics: \(Self.diagnosticsSummary(diagnostics))")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    func resetToHome() {
        selectedSessionID = nil
        pendingConfirmation = nil
        downloadProgress = nil
        pendingNavigationTarget = nil
    }

    func stageAttachment(from url: URL) async {
        guard let profileID = activeProfileID else {
            statusText = "Sign in to a profile before attaching files."
            return
        }
        do {
            let attachment = try attachmentStaging.stageFile(
                from: url,
                profileID: profileID,
                sessionRemoteID: selectedSession?.remoteID
            )
            draftAttachments.append(attachment)
            statusText = "Attachment staged."
        } catch {
            statusText = error.localizedDescription
        }
    }

    func stagePhoto(data: Data, suggestedFilename: String, contentType: String) async {
        guard let profileID = activeProfileID else {
            statusText = "Sign in to a profile before attaching images."
            return
        }
        do {
            let attachment = try attachmentStaging.stageData(
                data,
                filename: suggestedFilename,
                contentType: contentType,
                kind: "image",
                profileID: profileID,
                sessionRemoteID: selectedSession?.remoteID
            )
            draftAttachments.append(attachment)
            statusText = "Image staged."
        } catch {
            statusText = error.localizedDescription
        }
    }

    func removeStagedAttachment(_ attachment: HankAssistantStagedAttachment) {
        do {
            try attachmentStaging.remove(attachment)
            draftAttachments.removeAll { $0.id == attachment.id }
            let wasSubmitted = submittedAttachments.contains { $0.id == attachment.id }
            submittedAttachments.removeAll { $0.id == attachment.id }
            if wasSubmitted {
                discardSubmittedAttachment(attachment)
            }
            statusText = stagedAttachments.isEmpty ? "Attachment removed." : "Attachment queue updated."
        } catch {
            statusText = error.localizedDescription
        }
    }

    func previewStagedAttachment(_ attachment: HankAssistantStagedAttachment) {
        guard attachmentStaging.fileExists(for: attachment) else {
            statusText = "The staged upload is no longer available on this device."
            return
        }
        attachmentPreview = HankAssistantAttachmentPreview(url: attachmentStaging.fileURL(for: attachment))
    }

    func load(profileID: UUID?, modelContext: ModelContext, services: AppServices) {
        let previousProfileID = activeProfileID
        if previousProfileID == profileID, profileID != nil {
            self.modelContext = modelContext
            self.services = services
            Task {
                await refreshInstalledAppSlashCommandsIfPossible()
            }
            return
        }
        activeProfileID = profileID
        self.modelContext = modelContext
        self.services = services
        isSending = false
        pendingConfirmation = nil
        downloadProgress = nil
        pendingNavigationTarget = nil

        guard let profileID else {
            if let previousProfileID {
                try? attachmentStaging.removeAll(for: previousProfileID)
            }
            isRestoringPersistedState = true
            draftText = ""
            selectedSessionID = nil
            isRestoringPersistedState = false
            sessions = []
            draftAttachments = []
            submittedAttachments = []
            restoredSelectedRemoteID = nil
            mediaRealtimeTask?.cancel()
            mediaRealtimeTask = nil
            slashCommands = Self.builtinSlashCommands
            statusText = "Sign in to a profile before starting a conversation."
            appendLog("Assistant unloaded", ["previous_profile=\(previousProfileID?.uuidString ?? "none")"])
            return
        }

        restoredSelectedRemoteID = UserDefaults.standard.string(forKey: selectedSessionDefaultsKey(for: profileID))
        isRestoringPersistedState = true
        draftText = UserDefaults.standard.string(forKey: draftDefaultsKey(for: profileID)) ?? ""
        isRestoringPersistedState = false
        let loadedAttachments = (try? attachmentStaging.loadAttachments(for: profileID)) ?? []
        draftAttachments = loadedAttachments.filter { !$0.isSubmitted }
        submittedAttachments = loadedAttachments.filter(\.isSubmitted)

        Task {
            await refreshSessions()
        }
        startMediaRealtimeSubscription()
        appendLog("Assistant loaded", ["profile=\(profileID.uuidString)"])
    }

    func refreshSessions() async {
        do {
            guard let services else {
                appendLog("Session refresh skipped", ["reason=missing_services"])
                return
            }
            guard let context = try remoteContext() else {
                sessions = [
                    HankAssistantSession(
                        remoteID: "local-placeholder",
                        title: "Hank Assistant",
                        messages: [
                            HankAssistantMessage(
                                role: .assistant,
                                text: "Enable Hank Remote in Settings to use the Hank assistant."
                            )
                        ]
                    )
                ]
                selectedSessionID = sessions.first?.id
                statusText = "Hank Remote is not configured."
                appendLog("Session refresh skipped", ["reason=remote_not_configured"])
                return
            }

            let remoteSessions = try await services.hankRemoteService.assistantSessions(context: context)
            await refreshInstalledAppSlashCommands(context: context, services: services)
            let existing = Dictionary(uniqueKeysWithValues: sessions.map { ($0.remoteID, $0) })
            sessions = remoteSessions.map { remote in
                var local = existing[remote.id] ?? HankAssistantSession(
                    remoteID: remote.id,
                    title: remote.title,
                    messages: [],
                    updatedAt: remote.updatedAt
                )
                local.title = remote.title
                local.updatedAt = remote.updatedAt
                return local
            }

            sortSessions()
            ensureSelectedSession()
            await refreshSelectedSession()
            statusText = "Assistant connected."
            appendLog("Sessions refreshed", ["count=\(sessions.count)"])
        } catch {
            sessions = [
                HankAssistantSession(
                    remoteID: "error-placeholder",
                    title: "Hank Assistant",
                    messages: [HankAssistantMessage(role: .system, text: error.localizedDescription)]
                )
            ]
            selectedSessionID = sessions.first?.id
            statusText = error.localizedDescription
            appendLog("Session refresh failed", ["error=\(error.localizedDescription)"])
        }
    }

    func refreshSelectedSessionMessages() async {
        await refreshSelectedSession()
    }

    func insertSlashCommand(_ command: HankAssistantSlashCommand) {
        let firstToken = draftText.prefix { !$0.isWhitespace }
        let suffixStart = draftText.index(draftText.startIndex, offsetBy: firstToken.count)
        let suffix = String(draftText[suffixStart...])
        if firstToken.starts(with: "/") {
            draftText = command.command + suffix
        } else if draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draftText = command.command + " "
        } else {
            draftText = command.command + " " + draftText
        }
    }

    func refreshSelectedSession() async {
        guard let sessionID = selectedSessionID else {
            return
        }
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else {
            return
        }
        do {
            guard let services, let context = try remoteContext() else {
                return
            }
            let remoteSession = try await services.hankRemoteService.assistantSession(
                sessionID: sessions[index].remoteID,
                context: context
            )
            let messages = try await services.hankRemoteService.assistantMessages(
                sessionID: sessions[index].remoteID,
                context: context
            )
            sessions[index].title = remoteSession.title
            sessions[index].messages = messages.map(Self.localMessage(from:))
            sessions[index].updatedAt = max(
                remoteSession.updatedAt,
                sessions[index].messages.last?.createdAt ?? sessions[index].updatedAt
            )
            sortSessions()
            statusText = "Assistant session refreshed."
            appendLog(
                "Messages refreshed",
                [
                    "session=\(sessions[index].remoteID)",
                    "messages=\(sessions[index].messages.count)"
                ]
            )
        } catch {
            statusText = error.localizedDescription
            appendLog("Message refresh failed", ["error=\(error.localizedDescription)"])
        }
    }

    func selectSession(_ sessionID: HankAssistantSession.ID) async {
        guard selectedSessionID != sessionID else {
            return
        }
        selectedSessionID = sessionID
        pendingConfirmation = nil
        await refreshSelectedSession()
    }

    func deleteSession(_ sessionID: HankAssistantSession.ID) async {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else {
            return
        }
        do {
            guard let services, let context = try remoteContext() else {
                statusText = "Enable Hank Remote to use the assistant."
                return
            }
            let remoteID = sessions[index].remoteID
            try await services.hankRemoteService.deleteAssistantSession(
                sessionID: remoteID,
                context: context
            )
            sessions.remove(at: index)
            if selectedSessionID == sessionID {
                selectedSessionID = sessions.first?.id
                pendingConfirmation = nil
                if selectedSessionID != nil {
                    await refreshSelectedSession()
                }
            }
            statusText = "Assistant session deleted."
        } catch {
            statusText = error.localizedDescription
        }
    }

    func createSession() async {
        do {
            guard let services, let context = try remoteContext() else {
                statusText = "Enable Hank Remote to use the assistant."
                return
            }
            let created = try await services.hankRemoteService.createAssistantSession(context: context)
            let local = HankAssistantSession(
                remoteID: created.id,
                title: created.title,
                messages: [],
                updatedAt: created.updatedAt
            )
            sessions.insert(local, at: 0)
            selectedSessionID = local.id
            pendingConfirmation = nil
            statusText = "Assistant session ready."
            appendLog("Session created", ["session=\(created.id)"])
        } catch {
            statusText = error.localizedDescription
            appendLog("Session create failed", ["error=\(error.localizedDescription)"])
        }
    }

    func sendDraft(using calendarStore: CalendarStore) async {
        let trimmedDraft = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        let queuedAttachments = draftAttachments
        guard !trimmedDraft.isEmpty || !queuedAttachments.isEmpty else {
            return
        }
        guard let activeProfileID else {
            statusText = "Sign in to a profile before starting a conversation."
            return
        }

        isSending = true
        defer { isSending = false }

        do {
            guard let services, let context = try remoteContext() else {
                statusText = "Enable Hank Remote to use the assistant."
                return
            }
            await prepareCalendarContextIfPossible(using: calendarStore)

            if selectedSession == nil {
                await createSession()
            }

            guard let sessionID = selectedSessionID,
                  let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }) else {
                return
            }
            let remoteSessionID = sessions[sessionIndex].remoteID
            draftAttachments = try attachmentStaging.bind(draftAttachments, profileID: activeProfileID, sessionRemoteID: remoteSessionID)
            let attachmentsToSend = draftAttachments

            pendingConfirmation = nil
            let displayText = trimmedDraft.isEmpty ? Self.attachmentOnlyMessageText(for: attachmentsToSend) : trimmedDraft
            let userMessage = HankAssistantMessage(role: .user, text: displayText)
            sessions[sessionIndex].messages.append(userMessage)
            appendLog(
                "User message sent",
                [
                    "session=\(remoteSessionID)",
                    "text=\(Self.oneLine(displayText, limit: 180))",
                    "attachments=\(attachmentsToSend.count)"
                ]
            )
            if sessions[sessionIndex].title == "New Conversation" {
                sessions[sessionIndex].title = sessionTitle(from: displayText)
            }
            sessions[sessionIndex].updatedAt = .now
            sortSessions()
            draftText = ""
            statusText = "Waiting for Hank..."

            let run = try await services.hankRemoteService.sendAssistantMessage(
                sessionID: sessions[sessionIndex].remoteID,
                content: displayText,
                attachments: attachmentsToSend.map(HankRemoteAssistantAttachmentUpload.init(stagedAttachment:)),
                deviceID: deviceIdentifier,
                timezone: TimeZone.current.identifier,
                context: context
            )
            recordRun(run, stage: "initial")
            markAttachmentsSubmitted(attachmentsToSend)
            try await continueRun(
                run,
                localSessionID: sessionID,
                calendarStore: calendarStore,
                context: context
            )
        } catch {
            statusText = error.localizedDescription
            appendLog("Send failed", ["error=\(error.localizedDescription)"])
            appendSystemMessage(error.localizedDescription)
        }
    }

    func respondToPendingConfirmation(approved: Bool, using calendarStore: CalendarStore) async {
        guard let pendingConfirmation else {
            return
        }

        isSending = true
        defer { isSending = false }

        do {
            guard let services, let context = try remoteContext() else {
                statusText = "Enable Hank Remote to use the assistant."
                return
            }
            if approved {
                await prepareCalendarContextIfPossible(using: calendarStore)
            }

            self.pendingConfirmation = nil
            statusText = approved ? "Applying confirmed action..." : "Cancelling action..."
            appendLog(
                approved ? "Confirmation approved" : "Confirmation cancelled",
                [
                    "run=\(pendingConfirmation.id)",
                    "title=\(Self.oneLine(pendingConfirmation.title, limit: 120))"
                ]
            )

            let run = try await services.hankRemoteService.confirmAssistantRun(
                runID: pendingConfirmation.id,
                approved: approved,
                context: context
            )
            recordRun(run, stage: "confirmed")

            guard let sessionID = selectedSessionID else {
                return
            }
            try await continueRun(
                run,
                localSessionID: sessionID,
                calendarStore: calendarStore,
                context: context
            )
        } catch {
            statusText = error.localizedDescription
            appendLog("Confirmation failed", ["error=\(error.localizedDescription)"])
            appendSystemMessage(error.localizedDescription)
        }
    }

    func open(_ card: HankAssistantResultCard) {
        guard let target = card.target else {
            statusText = "This result does not include an in-app destination yet."
            return
        }
        pendingNavigationTarget = target
    }

    func consumePendingNavigationTarget() {
        pendingNavigationTarget = nil
    }

    private func continueRun(
        _ initialRun: HankRemoteAssistantRun,
        localSessionID: HankAssistantSession.ID,
        calendarStore: CalendarStore,
        context: HankRemoteConnectionContext
    ) async throws {
        guard let services else {
            return
        }

        var run = initialRun
        var pollCount = 0

        while true {
            recordRun(run, stage: pollCount == 0 ? "step" : "poll \(pollCount)")
            if let sessionIndex = sessions.firstIndex(where: { $0.id == localSessionID }) {
                appendAssistantMessageIfNeeded(run.assistantMessage, to: sessionIndex)
            }

            if run.requiresConfirmation {
                let actionSummary = run.pendingActionSummary
                pendingConfirmation = HankAssistantPendingConfirmation(
                    id: run.id,
                    title: actionSummary?.title.nilIfBlank ?? "Confirmation Needed",
                    message: actionSummary?.confirmationMessage.nilIfBlank ?? run.assistantMessage?.text.nilIfBlank ?? "Hank needs confirmation before continuing.",
                    summary: actionSummary?.summary.nilIfBlank ?? "",
                    details: actionSummary?.details.map {
                        HankAssistantPendingConfirmationDetail(label: $0.label, value: $0.value)
                    } ?? [],
                    isDestructive: actionSummary?.isDestructive ?? false,
                    confirmTitle: "Confirm",
                    cancelTitle: "Cancel"
                )
                statusText = "Waiting for confirmation."
                appendLog(
                    "Confirmation requested",
                    [
                        "run=\(run.id)",
                        "kind=\(actionSummary?.kind ?? "unknown")",
                        "title=\(Self.oneLine(actionSummary?.title.nilIfBlank ?? "Confirmation Needed", limit: 120))"
                    ]
                )
                return
            }

            if run.requiresClientTools, let request = run.clientToolRequest {
                statusText = statusText(for: request.toolName)
                appendLog("Client tool requested", ["run=\(run.id)", "tool=\(request.toolName)"])
                do {
                    let result = try await executeClientTool(request, using: calendarStore)
                    appendLog("Client tool completed", ["run=\(run.id)", "tool=\(request.toolName)"])
                    run = try await services.hankRemoteService.submitAssistantClientToolResults(
                        runID: run.id,
                        results: [(toolName: request.toolName, result: result, error: nil)],
                        context: context
                    )
                } catch {
                    let payload = clientToolErrorPayload(for: request, error: error)
                    appendLog(
                        "Client tool failed",
                        [
                            "run=\(run.id)",
                            "tool=\(request.toolName)",
                            "error=\(payload.message)"
                        ]
                    )
                    run = try await services.hankRemoteService.submitAssistantClientToolResults(
                        runID: run.id,
                        results: [(toolName: request.toolName, result: payload.result, error: payload.message)],
                        context: context
                    )
                }
                continue
            }

            if isTerminalRunState(run.state) {
                statusText = statusTextForTerminalState(run.state)
                appendLog("Run finished", ["run=\(run.id)", "state=\(run.state)"])
                return
            }

            guard pollCount < 15 else {
                statusText = "Hank is still working. Pull to refresh this session if the reply does not appear."
                appendLog("Run still working", ["run=\(run.id)", "polls=\(pollCount)"])
                return
            }

            pollCount += 1
            statusText = "Hank is working..."
            try await Task.sleep(for: .milliseconds(450))
            run = try await services.hankRemoteService.assistantRun(runID: run.id, context: context)
        }
    }

    private func executeClientTool(
        _ request: HankRemoteAssistantClientToolRequest,
        using calendarStore: CalendarStore
    ) async throws -> [String: Any] {
        switch request.toolName {
        case "calendar.search":
            return try await searchCalendar(arguments: request.arguments, using: calendarStore)
        case "calendar.create_event":
            return try await createCalendarEvent(arguments: request.arguments, using: calendarStore)
        case "calendar.update_event":
            return try await updateCalendarEvent(arguments: request.arguments, using: calendarStore)
        case "attachments.commit":
            return try await commitAttachments(arguments: request.arguments)
        default:
            throw HankAssistantStoreError.unsupportedClientTool(request.toolName)
        }
    }

    private func searchCalendar(
        arguments: [String: AnyDecodable],
        using calendarStore: CalendarStore
    ) async throws -> [String: Any] {
        let query = stringValue(for: "query", in: arguments)?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
        guard !query.isEmpty else {
            throw HankAssistantStoreError.invalidClientToolArguments
        }
        let limit = intValue(for: "limit", in: arguments) ?? 10
        let matches = await calendarStore.assistantSearchEvents(query: query, limit: max(1, min(limit, 25)))
        return [
            "query": query,
            "matches": matches.map(Self.calendarEventResultPayload(from:))
        ]
    }

    private func createCalendarEvent(
        arguments: [String: AnyDecodable],
        using calendarStore: CalendarStore
    ) async throws -> [String: Any] {
        let payload = try await calendarStore.assistantCreateEvent(
            title: stringValue(for: "title", in: arguments) ?? "Untitled Event",
            startDate: try dateValue(for: "starts_at", in: arguments),
            endDate: try dateValue(for: "ends_at", in: arguments),
            isAllDay: boolValue(for: "is_all_day", in: arguments) ?? false,
            calendarIdentifier: stringValue(for: "calendar_id", in: arguments),
            location: stringValue(for: "location", in: arguments) ?? "",
            notes: stringValue(for: "notes", in: arguments) ?? ""
        )
        return Self.calendarEventResultPayload(from: payload)
    }

    private func updateCalendarEvent(
        arguments: [String: AnyDecodable],
        using calendarStore: CalendarStore
    ) async throws -> [String: Any] {
        guard let eventIdentifier = stringValue(for: "event_id", in: arguments)
            ?? stringValue(for: "event_identifier", in: arguments) else {
            throw HankAssistantStoreError.invalidClientToolArguments
        }

        let payload = try await calendarStore.assistantUpdateEvent(
            eventIdentifier: eventIdentifier,
            title: stringValue(for: "title", in: arguments),
            startDate: optionalDateValue(for: "starts_at", in: arguments),
            endDate: optionalDateValue(for: "ends_at", in: arguments),
            isAllDay: boolValue(for: "is_all_day", in: arguments),
            location: stringValue(for: "location", in: arguments),
            notes: stringValue(for: "notes", in: arguments)
        )
        return Self.calendarEventResultPayload(from: payload)
    }

    private func commitAttachments(arguments: [String: AnyDecodable]) async throws -> [String: Any] {
        guard let services, let modelContext, let profileID = activeProfileID, let context = try remoteContext() else {
            throw HankAssistantStoreError.invalidClientToolArguments
        }
        let attachmentIDs = stringArrayValue(for: "attachment_ids", in: arguments)
        guard !attachmentIDs.isEmpty else {
            throw HankAssistantStoreError.invalidClientToolArguments
        }
        let selectedAttachments = stagedAttachments.filter { attachmentIDs.contains($0.clientAttachmentID) }
        guard selectedAttachments.count == attachmentIDs.count else {
            throw HankAssistantStoreError.missingStagedAttachment
        }
        for attachment in selectedAttachments where !attachmentStaging.fileExists(for: attachment) {
            throw HankAssistantStoreError.missingStagedAttachment
        }

        let destinationKind = stringValue(for: "destination_kind", in: arguments) ?? ""
        switch destinationKind {
        case "note_attachment":
            let noteID = stringValue(for: "note_id", in: arguments)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !noteID.isEmpty else {
                throw HankAssistantStoreError.invalidClientToolArguments
            }
            let noteScope = stringValue(for: "note_scope", in: arguments) ?? "profile"
            var files: [[String: Any]] = []
            do {
                for attachment in selectedAttachments {
                    let uploaded = try await services.hankRemoteService.uploadNoteAttachment(
                        scope: noteScope,
                        noteID: noteID,
                        fileAt: attachmentStaging.fileURL(for: attachment),
                        filename: attachment.filename,
                        contentType: attachment.contentType,
                        context: context
                    )
                    files.append([
                        "client_attachment_id": attachment.clientAttachmentID,
                        "attachment_id": uploaded.id,
                        "filename": uploaded.filename,
                        "content_type": uploaded.contentType,
                        "size_bytes": uploaded.sizeBytes
                    ])
                }
            } catch {
                let rollbackFailures = await rollbackNoteAttachments(
                    files,
                    noteScope: noteScope,
                    noteID: noteID,
                    services: services,
                    context: context
                )
                if rollbackFailures.isEmpty {
                    throw error
                }
                let remainingFiles = files.filter { file in
                    guard let attachmentID = file["attachment_id"] as? String else {
                        return false
                    }
                    return rollbackFailures.contains(attachmentID)
                }
                removeCommittedAttachments(selectedAttachments.filter { attachment in
                    remainingFiles.contains { ($0["client_attachment_id"] as? String) == attachment.clientAttachmentID }
                })
                throw HankAssistantPartialCommitError(
                    message: "Some note attachments were stored, but Hank could not finish or roll back the full batch: \(error.localizedDescription)",
                    result: baseAttachmentCommitResult(
                        destinationKind: "note_attachment",
                        attachmentIDs: attachmentIDs,
                        extra: [
                            "note_id": noteID,
                            "note_scope": noteScope,
                            "note_title": stringValue(for: "note_title", in: arguments) ?? "Note",
                            "files": remainingFiles
                        ]
                    )
                )
            }
            removeCommittedAttachments(selectedAttachments)
            return [
                "destination_kind": "note_attachment",
                "note_id": noteID,
                "note_scope": noteScope,
                "note_title": stringValue(for: "note_title", in: arguments) ?? "Note",
                "attachment_ids": attachmentIDs,
                "files": files
            ]

        case "smb":
            let targetPath = FileBrowserPathing.normalized(stringValue(for: "target_path", in: arguments) ?? "")
            guard let resolvedConnection = try await services.preferredSMBConnection(for: profileID, in: modelContext) else {
                throw HankAssistantStoreError.noSMBConnection
            }
            let smbService = await services.sharedSMBService(for: resolvedConnection)
            let password = try services.smbPassword(for: resolvedConnection, profileID: profileID) ?? ""
            try await smbService.connect(
                config: resolvedConnection.details,
                password: password,
                context: resolvedConnection.remoteAccess
            )
            var existingNames = Set(try await smbService.list(path: targetPath).map(\.name))
            var files: [[String: Any]] = []
            do {
                for attachment in selectedAttachments {
                    let targetName = FileBrowserPathing.uniqueCopyName(
                        for: attachment.filename,
                        existingNames: existingNames,
                        isDirectory: false
                    )
                    existingNames.insert(targetName)
                    let destinationPath = FileBrowserPathing.childPath(named: targetName, in: targetPath)
                    try await smbService.upload(fileAt: attachmentStaging.fileURL(for: attachment), path: destinationPath)
                    files.append([
                        "client_attachment_id": attachment.clientAttachmentID,
                        "filename": targetName,
                        "path": destinationPath,
                        "content_type": attachment.contentType,
                        "size_bytes": attachment.sizeBytes
                    ])
                }
            } catch {
                let rollbackFailures = await rollbackSMBUploads(files, using: smbService)
                if rollbackFailures.isEmpty {
                    throw error
                }
                let remainingFiles = files.filter { file in
                    guard let path = file["path"] as? String else {
                        return false
                    }
                    return rollbackFailures.contains(path)
                }
                removeCommittedAttachments(selectedAttachments.filter { attachment in
                    remainingFiles.contains { ($0["client_attachment_id"] as? String) == attachment.clientAttachmentID }
                })
                recordAssistantSMBUploads(remainingFiles, targetPath: targetPath, connection: resolvedConnection)
                throw HankAssistantPartialCommitError(
                    message: "Some File Server uploads were stored, but Hank could not finish or roll back the full batch: \(error.localizedDescription)",
                    result: baseAttachmentCommitResult(
                        destinationKind: "smb",
                        attachmentIDs: attachmentIDs,
                        extra: [
                            "target_path": targetPath,
                            "files": remainingFiles
                        ]
                    )
                )
            }
            removeCommittedAttachments(selectedAttachments)
            recordAssistantSMBUploads(files, targetPath: targetPath, connection: resolvedConnection)
            return [
                "destination_kind": "smb",
                "target_path": targetPath,
                "attachment_ids": attachmentIDs,
                "files": files
            ]

        default:
            throw HankAssistantStoreError.invalidClientToolArguments
        }
    }

    private func removeCommittedAttachments(_ attachments: [HankAssistantStagedAttachment]) {
        for attachment in attachments {
            try? attachmentStaging.remove(attachment)
        }
        let committedIDs = Set(attachments.map(\.id))
        draftAttachments.removeAll { committedIDs.contains($0.id) }
        submittedAttachments.removeAll { committedIDs.contains($0.id) }
    }

    private func markAttachmentsSubmitted(_ attachments: [HankAssistantStagedAttachment]) {
        guard !attachments.isEmpty else {
            return
        }
        let submittedIDs = Set(attachments.map(\.id))
        var nextSubmitted = submittedAttachments
        draftAttachments.removeAll { attachment in
            guard submittedIDs.contains(attachment.id) else {
                return false
            }
            var submitted = attachment
            submitted.isSubmitted = true
            try? attachmentStaging.update(submitted)
            nextSubmitted.removeAll { $0.id == submitted.id }
            nextSubmitted.append(submitted)
            return true
        }
        submittedAttachments = nextSubmitted.sorted { $0.createdAt < $1.createdAt }
    }

    private func discardSubmittedAttachment(_ attachment: HankAssistantStagedAttachment) {
        guard let sessionRemoteID = attachment.sessionRemoteID else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            do {
                guard let services = self.services, let context = try self.remoteContext() else {
                    return
                }
                try await services.hankRemoteService.discardAssistantAttachment(
                    sessionID: sessionRemoteID,
                    clientAttachmentID: attachment.clientAttachmentID,
                    context: context
                )
            } catch {
                self.statusText = error.localizedDescription
            }
        }
    }

    private func rollbackNoteAttachments(
        _ files: [[String: Any]],
        noteScope: String,
        noteID: String,
        services: AppServices,
        context: HankRemoteConnectionContext
    ) async -> Set<String> {
        var failedDeletes = Set<String>()
        for file in files {
            guard let attachmentID = file["attachment_id"] as? String, !attachmentID.isEmpty else {
                continue
            }
            do {
                try await services.hankRemoteService.deleteNoteAttachment(
                    scope: noteScope,
                    noteID: noteID,
                    attachmentID: attachmentID,
                    context: context
                )
            } catch {
                failedDeletes.insert(attachmentID)
            }
        }
        return failedDeletes
    }

    private func rollbackSMBUploads(_ files: [[String: Any]], using smbService: SMBServicing) async -> Set<String> {
        var failedDeletes = Set<String>()
        for file in files {
            guard let path = file["path"] as? String, !path.isEmpty else {
                continue
            }
            do {
                try await smbService.delete(path: path, isDirectory: false)
            } catch {
                failedDeletes.insert(path)
            }
        }
        return failedDeletes
    }

    private func baseAttachmentCommitResult(
        destinationKind: String,
        attachmentIDs: [String],
        extra: [String: Any]
    ) -> [String: Any] {
        var result: [String: Any] = [
            "destination_kind": destinationKind,
            "attachment_ids": attachmentIDs
        ]
        for (key, value) in extra {
            result[key] = value
        }
        return result
    }

    private func recordAssistantSMBUploads(
        _ files: [[String: Any]],
        targetPath: String,
        connection: ResolvedSMBConnection
    ) {
        guard !files.isEmpty else {
            return
        }
        let scopeKey = FileBrowserStore.searchIndexScopeKey(for: connection.details)
        let persistence = DiskSMBSearchIndexPersistence()
        var entries = (try? persistence.loadEntries(for: scopeKey)) ?? []
        let now = Date()
        let uploadedEntries = files.compactMap { file -> SMBSearchIndexEntry? in
            guard let path = file["path"] as? String, !path.isEmpty else {
                return nil
            }
            let name = (file["filename"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? URL(fileURLWithPath: path).lastPathComponent
            return SMBSearchIndexEntry(
                path: FileBrowserPathing.normalized(path),
                name: name.isEmpty ? "Uploaded file" : name,
                isDirectory: false,
                size: Self.int64Value(file["size_bytes"]),
                modifiedAt: now
            )
        }
        guard !uploadedEntries.isEmpty else {
            return
        }
        let byPath = Dictionary(uniqueKeysWithValues: uploadedEntries.map { ($0.path, $0) })
        entries.removeAll { byPath[$0.path] != nil }
        entries.append(contentsOf: uploadedEntries)
        try? persistence.saveEntries(entries.sorted { $0.path < $1.path }, for: scopeKey)
        NotificationCenter.default.post(
            name: .hankAssistantSMBUploadDidCommit,
            object: nil,
            userInfo: [
                "scope_key": scopeKey,
                "target_path": FileBrowserPathing.normalized(targetPath),
                "files": uploadedEntries
            ]
        )
    }

    private func clientToolErrorPayload(
        for request: HankRemoteAssistantClientToolRequest,
        error: Error
    ) -> (result: [String: Any], message: String) {
        if let partial = error as? HankAssistantPartialCommitError {
            return (partial.result, partial.message)
        }

        var result = request.arguments.mapValues(\.value)
        if request.toolName == "attachments.commit",
           let storeError = error as? HankAssistantStoreError,
           case .missingStagedAttachment = storeError {
            let attachmentIDs = stringArrayValue(for: "attachment_ids", in: request.arguments)
            result["error_code"] = "missing_staged_attachment"
            result["expired_attachment_ids"] = attachmentIDs
            result["attachment_ids"] = attachmentIDs
        }
        return (result, error.localizedDescription)
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        if let value = value as? Int64 {
            return value
        }
        if let value = value as? Int {
            return Int64(value)
        }
        if let value = value as? Double {
            return Int64(value)
        }
        if let value = value as? String {
            return Int64(value)
        }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? Int64 {
            return Int(value)
        }
        if let value = value as? Double {
            return Int(value)
        }
        if let value = value as? String {
            return Int(value)
        }
        return nil
    }

    private func appendAssistantMessageIfNeeded(_ message: HankRemoteAssistantMessage?, to sessionIndex: Int) {
        guard let message else {
            return
        }
        if sessions[sessionIndex].messages.contains(where: { $0.remoteID == message.id }) {
            return
        }

        let localMessage = Self.localMessage(from: message)
        sessions[sessionIndex].messages.append(localMessage)
        sessions[sessionIndex].updatedAt = max(sessions[sessionIndex].updatedAt, localMessage.createdAt)
        sortSessions()
        var details = [
            "message=\(message.id)",
            "cards=\(message.cards.count)",
            "text=\(Self.oneLine(message.text, limit: 180))"
        ]
        if let diagnostics = localMessage.diagnostics {
            details.append("diagnostics=\(Self.diagnosticsSummary(diagnostics))")
        }
        appendLog("Assistant message received", details)
    }

    private func appendSystemMessage(_ text: String, filePath: String? = nil) {
        guard let sessionID = selectedSessionID,
              let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }) else {
            return
        }
        let cards: [HankAssistantResultCard]
        if let filePath, !filePath.isEmpty {
            cards = [
                HankAssistantResultCard(
                    kind: .file,
                    title: "Downloaded media",
                    summary: filePath,
                    actionTitle: "Open Location",
                    target: HankAssistantNavigationTarget(kind: .file(path: filePath))
                )
            ]
        } else {
            cards = []
        }
        sessions[sessionIndex].messages.append(HankAssistantMessage(role: .system, text: text, cards: cards))
        sessions[sessionIndex].updatedAt = .now
        sortSessions()
        appendLog("System message added", ["text=\(Self.oneLine(text, limit: 180))"])
    }

    private func startMediaRealtimeSubscription() {
        mediaRealtimeTask?.cancel()
        guard let services else {
            return
        }
        let context: HankRemoteConnectionContext
        do {
            guard let resolvedContext = try remoteContext() else {
                return
            }
            context = resolvedContext
        } catch {
            statusText = error.localizedDescription
            return
        }

        mediaRealtimeTask = Task { [weak self] in
            do {
                try await services.hankRemoteService.subscribeRealtime(
                    topics: ["media.downloads"],
                    context: context
                )
                for await event in await services.hankRemoteService.realtimeEvents() {
                    guard event.event == "media.download_progress" || event.event == "media.download_completed" else {
                        continue
                    }
                    await MainActor.run {
                        self?.handleMediaRealtimeEvent(event)
                    }
                }
            } catch {
                await MainActor.run {
                    self?.statusText = error.localizedDescription
                    self?.appendLog("Realtime subscription failed", ["error=\(error.localizedDescription)"])
                }
            }
        }
    }

    private func handleMediaRealtimeEvent(_ event: HankRemoteRealtimeEvent) {
        guard let payload = event.payload,
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return
        }
        let title = (object["title"] as? String)?.nilIfBlank ?? "Media download"
        let completed = Self.intValue(object["completed_count"]) ?? 0
        let total = Self.intValue(object["total_count"]) ?? 0
        let failed = Self.intValue(object["failed_count"]) ?? 0
        let skipped = Self.intValue(object["skipped_count"]) ?? 0
        let status = (object["status"] as? String)?.nilIfBlank ?? "running"
        let filePath = [
            object["file_path"],
            object["path"],
            object["destination_path"],
            object["share_path"]
        ]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        downloadProgress = HankAssistantDownloadProgress(
            id: (object["job_id"] as? String)?.nilIfBlank ?? title,
            title: title,
            completed: completed,
            total: total,
            failed: failed,
            skipped: skipped,
            status: event.event == "media.download_completed" ? "completed" : status,
            filePath: filePath
        )

        if event.event == "media.download_completed" {
            let message: String
            if failed > 0 {
                message = "\(title) finished with \(failed) failed item(s). \(completed)/\(total) item(s) processed."
            } else {
                message = "\(title) finished downloading. \(completed)/\(total) item(s) processed."
            }
            statusText = message
            appendSystemMessage(message, filePath: filePath)
            appendLog(
                "Media download completed",
                [
                    "title=\(Self.oneLine(title, limit: 120))",
                    "completed=\(completed)",
                    "total=\(total)",
                    "failed=\(failed)",
                    "skipped=\(skipped)"
                ]
            )
        } else {
            var text = "\(title): \(completed)/\(total) item(s) processed."
            if skipped > 0 {
                text += " \(skipped) already present."
            }
            if failed > 0 {
                text += " \(failed) failed."
            }
            statusText = status == "running" ? text : "\(title): \(status)"
            appendLog(
                "Media download progress",
                [
                    "title=\(Self.oneLine(title, limit: 120))",
                    "completed=\(completed)",
                    "total=\(total)",
                    "failed=\(failed)",
                    "skipped=\(skipped)",
                    "status=\(status)"
                ]
            )
        }
    }

    private func recordRun(_ run: HankRemoteAssistantRun, stage: String) {
        var details = [
            "stage=\(stage)",
            "run=\(run.id)",
            "state=\(run.state)",
            "requires_client_tools=\(run.requiresClientTools)",
            "requires_confirmation=\(run.requiresConfirmation)"
        ]
        if let request = run.clientToolRequest {
            details.append("client_tool=\(request.toolName)")
        }
        if let action = run.pendingActionSummary {
            details.append("pending_action=\(action.kind)")
            details.append("pending_title=\(Self.oneLine(action.title, limit: 120))")
        }
        if let message = run.assistantMessage {
            details.append("assistant_message=\(message.id)")
            details.append("assistant_cards=\(message.cards.count)")
        }
        if let diagnostics = run.diagnostics.map(HankAssistantDiagnostics.init(remote:)) {
            details.append("diagnostics=\(Self.diagnosticsSummary(diagnostics))")
        } else if let diagnostics = run.assistantMessage?.diagnostics.map(HankAssistantDiagnostics.init(remote:)) {
            details.append("diagnostics=\(Self.diagnosticsSummary(diagnostics))")
        }
        appendLog("Assistant run", details)
    }

    private func appendLog(_ event: String, _ details: [String] = []) {
        let sanitized = details
            .map { Self.oneLine($0, limit: 320) }
            .filter { !$0.isEmpty }
        logEntries.append(HankAssistantLogEntry(event: event, details: sanitized))
        if logEntries.count > 300 {
            logEntries.removeFirst(logEntries.count - 300)
        }
    }

    private static func diagnosticsSummary(_ diagnostics: HankAssistantDiagnostics) -> String {
        var parts = [
            "tool=\(diagnostics.toolKind)",
            "intent=\(diagnostics.intentKind)"
        ]
        if !diagnostics.query.isEmpty {
            parts.append("query=\(diagnostics.query)")
        }
        if !diagnostics.mediaSelectionTitle.isEmpty {
            parts.append("media_selection=\(diagnostics.mediaSelectionTitle)")
        }
        if !diagnostics.mediaSelectionPath.isEmpty {
            parts.append("media_path=\(diagnostics.mediaSelectionPath)")
        }
        return parts.joined(separator: " ")
    }

    private static func oneLine(_ value: String, limit: Int) -> String {
        let compact = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count > limit else {
            return compact
        }
        return String(compact.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private static func logTimestamp(_ date: Date) -> String {
        date.formatted(.dateTime.year().month().day().hour().minute().second())
    }

    private func remoteContext() throws -> HankRemoteConnectionContext? {
        guard let services, let modelContext else {
            return nil
        }
        return try services.hankRemoteConnectionContext(in: modelContext)
    }

    private func prepareCalendarContextIfPossible(using calendarStore: CalendarStore) async {
        guard let profileID = activeProfileID,
              let modelContext,
              let services else {
            return
        }
        statusText = "Refreshing calendar context..."
        await calendarStore.prepareAssistantCalendarIndex(
            profileID: profileID,
            modelContext: modelContext,
            services: services
        )
    }

    private func refreshInstalledAppSlashCommands(
        context: HankRemoteConnectionContext,
        services: AppServices
    ) async {
        do {
            let apps = try await services.hankRemoteService.installedApps(context: context)
            slashCommands = Self.availableSlashCommands(from: apps)
            appendLog("Installed app commands refreshed", ["count=\(slashCommands.count - Self.builtinSlashCommands.count)"])
        } catch {
            slashCommands = Self.builtinSlashCommands
            appendLog("Installed app commands unavailable", ["error=\(error.localizedDescription)"])
        }
    }

    private func refreshInstalledAppSlashCommandsIfPossible() async {
        do {
            guard let services, let context = try remoteContext() else {
                slashCommands = Self.builtinSlashCommands
                return
            }
            await refreshInstalledAppSlashCommands(context: context, services: services)
        } catch {
            slashCommands = Self.builtinSlashCommands
            appendLog("Installed app commands unavailable", ["error=\(error.localizedDescription)"])
        }
    }

    private func ensureSelectedSession() {
        if let restoredSelectedRemoteID,
           let restoredSession = sessions.first(where: { $0.remoteID == restoredSelectedRemoteID }) {
            selectedSessionID = restoredSession.id
            self.restoredSelectedRemoteID = nil
            return
        }

        if let selectedSessionID,
           sessions.contains(where: { $0.id == selectedSessionID }) {
            return
        }
        self.selectedSessionID = sessions.first?.id
    }

    private func sortSessions() {
        sessions.sort { $0.updatedAt > $1.updatedAt }
        if let selectedSessionID,
           sessions.contains(where: { $0.id == selectedSessionID }) == false {
            self.selectedSessionID = sessions.first?.id
        }
    }

    private var deviceIdentifier: String {
        UIDevice.current.name
    }

    private func sessionTitle(from prompt: String) -> String {
        let compact = prompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if compact.count <= 42 {
            return compact
        }
        return String(compact.prefix(42)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private func statusText(for toolName: String) -> String {
        switch toolName {
        case "calendar.search":
            return "Checking calendar..."
        case "calendar.create_event":
            return "Creating calendar event..."
        case "calendar.update_event":
            return "Updating calendar event..."
        default:
            return "Executing \(toolName)..."
        }
    }

    private func isTerminalRunState(_ state: String) -> Bool {
        switch state.lowercased() {
        case "completed", "complete", "failed", "cancelled", "canceled":
            return true
        default:
            return false
        }
    }

    private func statusTextForTerminalState(_ state: String) -> String {
        switch state.lowercased() {
        case "failed":
            return "Assistant run failed."
        case "cancelled", "canceled":
            return "Assistant action cancelled."
        default:
            return "Assistant response ready."
        }
    }

    private func persistSelectedSession() {
        guard let profileID = activeProfileID else {
            return
        }
        let defaults = UserDefaults.standard
        if isRestoringPersistedState {
            return
        }
        guard let selectedSessionID,
              let remoteID = sessions.first(where: { $0.id == selectedSessionID })?.remoteID else {
            defaults.removeObject(forKey: selectedSessionDefaultsKey(for: profileID))
            return
        }
        defaults.set(remoteID, forKey: selectedSessionDefaultsKey(for: profileID))
    }

    private func persistDraft() {
        guard let profileID = activeProfileID else {
            return
        }
        guard !isRestoringPersistedState else {
            return
        }
        UserDefaults.standard.set(draftText, forKey: draftDefaultsKey(for: profileID))
    }

    private func selectedSessionDefaultsKey(for profileID: UUID) -> String {
        "HankAssistant.selectedSession.\(profileID.uuidString)"
    }

    private func draftDefaultsKey(for profileID: UUID) -> String {
        "HankAssistant.draft.\(profileID.uuidString)"
    }

    private static func localMessage(from remote: HankRemoteAssistantMessage) -> HankAssistantMessage {
        HankAssistantMessage(
            remoteID: remote.id,
            role: role(from: remote.role),
            text: remote.text,
            createdAt: remote.createdAt,
            cards: remote.cards.map { card in
                HankAssistantResultCard(
                    kind: cardKind(from: card.kind),
                    title: card.title,
                    summary: card.summary,
                    actionTitle: card.actionTitle,
                    imageURL: card.imageURL,
                    target: navigationTarget(from: card)
                )
            },
            diagnostics: remote.diagnostics.map(HankAssistantDiagnostics.init(remote:))
        )
    }

    private static func role(from rawValue: String) -> HankAssistantMessageRole {
        HankAssistantMessageRole(rawValue: rawValue) ?? .assistant
    }

    nonisolated static let builtinSlashCommands: [HankAssistantSlashCommand] = [
        HankAssistantSlashCommand(command: "/ha", label: "Home Assistant", description: "Route a query to Home Assistant."),
        HankAssistantSlashCommand(command: "/files", label: "Files", description: "Search File Server."),
        HankAssistantSlashCommand(command: "/notes", label: "Notes", description: "Search or list notes."),
        HankAssistantSlashCommand(command: "/append", label: "Append", description: "Append text to a note."),
        HankAssistantSlashCommand(command: "/calendar", label: "Calendar", description: "Search calendar context."),
        HankAssistantSlashCommand(command: "/docs", label: "Docs", description: "Search Hank project docs."),
        HankAssistantSlashCommand(command: "/status", label: "Status", description: "Show enabled HankAI surfaces.")
    ]

    nonisolated static func availableSlashCommands(from apps: [HankRemoteInstalledApp]) -> [HankAssistantSlashCommand] {
        var seenCommands = Set(builtinSlashCommands.map { slashCommandKey($0.command) })
        let appCommands = installedAppSlashCommands(from: apps).filter { command in
            seenCommands.insert(slashCommandKey(command.command)).inserted
        }
        return appCommands + builtinSlashCommands
    }

    nonisolated static func installedAppSlashCommands(from apps: [HankRemoteInstalledApp]) -> [HankAssistantSlashCommand] {
        apps.flatMap { app -> [HankAssistantSlashCommand] in
            guard app.enabled else {
                return []
            }
            return app.slashCommands.compactMap { slashCommand in
                let command = slashCommand.command.trimmingCharacters(in: .whitespacesAndNewlines)
                guard command.starts(with: "/") else {
                    return nil
                }
                let label = app.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let description = slashCommand.description.nilIfBlank
                    ?? app.description.nilIfBlank
                    ?? "Run installed app workflow."
                return HankAssistantSlashCommand(
                    command: command,
                    label: label.isEmpty ? String(command.dropFirst()) : label,
                    description: description
                )
            }
        }
    }

    private nonisolated static func slashCommandKey(_ command: String) -> String {
        command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func cardKind(from rawValue: String) -> HankAssistantResultCard.Kind {
        switch rawValue {
        case "calendar":
            return .calendar
        case "file":
            return .file
        case "homeassistant", "home_assistant":
            return .homeAssistant
        case "project_doc":
            return .projectDoc
        case "media":
            return .media
        default:
            return .note
        }
    }

    private static func navigationTarget(from card: HankRemoteAssistantResultCard) -> HankAssistantNavigationTarget? {
        switch card.kind {
        case "note":
            guard let noteID = card.noteID.flatMap(UUID.init(uuidString:)) else {
                return nil
            }
            return HankAssistantNavigationTarget(kind: .note(noteID: noteID, searchQuery: card.searchText))
        case "calendar":
            guard let date = card.targetDate else {
                return nil
            }
            return HankAssistantNavigationTarget(kind: .calendar(date: date, eventID: card.eventID))
        case "file":
            let path = card.path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !path.isEmpty else {
                return nil
            }
            return HankAssistantNavigationTarget(kind: .file(path: path))
        case "homeassistant", "home_assistant":
            let entityID = [
                card.searchText,
                card.path,
                card.title
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
            guard !entityID.isEmpty else {
                return nil
            }
            return HankAssistantNavigationTarget(kind: .homeAssistant(entityID: entityID))
        default:
            return nil
        }
    }

    private static func calendarEventResultPayload(from payload: CalendarAssistantEventPayload) -> [String: Any] {
        [
            "event_id": payload.id,
            "title": payload.title,
            "calendar_title": payload.calendarTitle,
            "location": payload.location,
            "notes": payload.notes,
            "starts_at": ISO8601DateFormatter().string(from: payload.startDate),
            "ends_at": ISO8601DateFormatter().string(from: payload.endDate),
            "is_all_day": payload.isAllDay
        ]
    }

    private static func attachmentOnlyMessageText(for attachments: [HankAssistantStagedAttachment]) -> String {
        if attachments.count == 1, let filename = attachments.first?.filename {
            return "Uploaded \(filename)."
        }
        return "Uploaded \(attachments.count) attachments."
    }

    private func stringValue(for key: String, in arguments: [String: AnyDecodable]) -> String? {
        arguments[key]?.value as? String
    }

    private func stringArrayValue(for key: String, in arguments: [String: AnyDecodable]) -> [String] {
        if let values = arguments[key]?.value as? [String] {
            return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        if let values = arguments[key]?.value as? [Any] {
            return values.compactMap { value in
                (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
        }
        if let value = stringValue(for: key, in: arguments)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return [value]
        }
        return []
    }

    private func boolValue(for key: String, in arguments: [String: AnyDecodable]) -> Bool? {
        arguments[key]?.value as? Bool
    }

    private func intValue(for key: String, in arguments: [String: AnyDecodable]) -> Int? {
        if let int = arguments[key]?.value as? Int {
            return int
        }
        if let double = arguments[key]?.value as? Double {
            return Int(double)
        }
        if let string = arguments[key]?.value as? String {
            return Int(string)
        }
        return nil
    }

    private func optionalDateValue(for key: String, in arguments: [String: AnyDecodable]) -> Date? {
        guard let raw = stringValue(for: key, in: arguments) else {
            return nil
        }
        return ISO8601DateFormatter().date(from: raw)
    }

    private func dateValue(for key: String, in arguments: [String: AnyDecodable]) throws -> Date {
        guard let date = optionalDateValue(for: key, in: arguments) else {
            throw HankAssistantStoreError.invalidClientToolArguments
        }
        return date
    }
}

enum HankAssistantStoreError: LocalizedError {
    case unsupportedClientTool(String)
    case invalidClientToolArguments
    case missingStagedAttachment
    case noSMBConnection

    var errorDescription: String? {
        switch self {
        case .unsupportedClientTool(let toolName):
            return "Unsupported assistant client tool: \(toolName)"
        case .invalidClientToolArguments:
            return "The assistant returned invalid client tool arguments."
        case .missingStagedAttachment:
            return "The staged upload is no longer available on this device."
        case .noSMBConnection:
            return "No File Server connection is available for this profile."
        }
    }
}

struct HankAssistantPartialCommitError: LocalizedError, @unchecked Sendable {
    let message: String
    let result: [String: Any]

    var errorDescription: String? {
        message
    }
}

private enum HankAssistantAttachmentStagingError: LocalizedError {
    case fileTooLarge(limitBytes: Int64)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge(let limitBytes):
            return "Attachments must be \(ByteCountFormatter.string(fromByteCount: limitBytes, countStyle: .file)) or smaller."
        }
    }
}

struct HankAssistantStagedAttachment: Identifiable, Codable, Equatable {
    let id: UUID
    var clientAttachmentID: String
    var profileID: UUID
    var sessionRemoteID: String?
    var filename: String
    var contentType: String
    var kind: String
    var sizeBytes: Int64
    var checksumSHA256: String
    var localRelativePath: String
    var createdAt: Date
    var expiresAt: Date
    var isSubmitted: Bool = false

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case clientAttachmentID
        case profileID
        case sessionRemoteID
        case filename
        case contentType
        case kind
        case sizeBytes
        case checksumSHA256
        case localRelativePath
        case createdAt
        case expiresAt
        case isSubmitted
    }

    init(
        id: UUID,
        clientAttachmentID: String,
        profileID: UUID,
        sessionRemoteID: String?,
        filename: String,
        contentType: String,
        kind: String,
        sizeBytes: Int64,
        checksumSHA256: String,
        localRelativePath: String,
        createdAt: Date,
        expiresAt: Date,
        isSubmitted: Bool = false
    ) {
        self.id = id
        self.clientAttachmentID = clientAttachmentID
        self.profileID = profileID
        self.sessionRemoteID = sessionRemoteID
        self.filename = filename
        self.contentType = contentType
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.checksumSHA256 = checksumSHA256
        self.localRelativePath = localRelativePath
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.isSubmitted = isSubmitted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        clientAttachmentID = try container.decode(String.self, forKey: .clientAttachmentID)
        profileID = try container.decode(UUID.self, forKey: .profileID)
        sessionRemoteID = try container.decodeIfPresent(String.self, forKey: .sessionRemoteID)
        filename = try container.decode(String.self, forKey: .filename)
        contentType = try container.decode(String.self, forKey: .contentType)
        kind = try container.decode(String.self, forKey: .kind)
        sizeBytes = try container.decode(Int64.self, forKey: .sizeBytes)
        checksumSHA256 = try container.decode(String.self, forKey: .checksumSHA256)
        localRelativePath = try container.decode(String.self, forKey: .localRelativePath)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        isSubmitted = try container.decodeIfPresent(Bool.self, forKey: .isSubmitted) ?? false
    }
}

private final class HankAssistantAttachmentStagingService {
    private let fileManager = FileManager.default
    private let lifetime: TimeInterval = 48 * 60 * 60
    private let maxAttachmentBytes: Int64 = 100 * 1024 * 1024

    private var rootURL: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("Hank", isDirectory: true)
            .appendingPathComponent("AssistantAttachmentStaging", isDirectory: true)
    }

    private var manifestURL: URL {
        rootURL.appendingPathComponent("manifest.json", isDirectory: false)
    }

    func loadAttachments(for profileID: UUID) throws -> [HankAssistantStagedAttachment] {
        var manifest = try loadManifest()
        let now = Date()
        let expired = manifest.filter { $0.expiresAt <= now || fileExists(for: $0) == false }
        for attachment in expired {
            try? removeFile(for: attachment)
        }
        manifest.removeAll { $0.expiresAt <= now || fileExists(for: $0) == false }
        try saveManifest(manifest)
        return manifest
            .filter { $0.profileID == profileID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func stageFile(from sourceURL: URL, profileID: UUID, sessionRemoteID: String?) throws -> HankAssistantStagedAttachment {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let filename = safeFilename(sourceURL.lastPathComponent.isEmpty ? "Attachment" : sourceURL.lastPathComponent)
        let contentType = UTType(filenameExtension: sourceURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        if let sourceSize = try? fileSize(sourceURL), sourceSize > maxAttachmentBytes {
            throw HankAssistantAttachmentStagingError.fileTooLarge(limitBytes: maxAttachmentBytes)
        }
        let target = try destinationURL(profileID: profileID, sessionRemoteID: sessionRemoteID, filename: filename)
        try fileManager.copyItem(at: sourceURL, to: target.url)
        let size = try fileSize(target.url)
        guard size <= maxAttachmentBytes else {
            try? fileManager.removeItem(at: target.url)
            throw HankAssistantAttachmentStagingError.fileTooLarge(limitBytes: maxAttachmentBytes)
        }
        let checksum = try checksumSHA256(for: target.url)
        let attachment = HankAssistantStagedAttachment(
            id: target.id,
            clientAttachmentID: target.id.uuidString,
            profileID: profileID,
            sessionRemoteID: sessionRemoteID,
            filename: filename,
            contentType: contentType,
            kind: contentType.hasPrefix("image/") ? "image" : "document",
            sizeBytes: size,
            checksumSHA256: checksum,
            localRelativePath: relativePath(for: target.url),
            createdAt: .now,
            expiresAt: Date().addingTimeInterval(lifetime)
        )
        try appendToManifest(attachment)
        return attachment
    }

    func stageData(
        _ data: Data,
        filename: String,
        contentType: String,
        kind: String,
        profileID: UUID,
        sessionRemoteID: String?
    ) throws -> HankAssistantStagedAttachment {
        guard Int64(data.count) <= maxAttachmentBytes else {
            throw HankAssistantAttachmentStagingError.fileTooLarge(limitBytes: maxAttachmentBytes)
        }
        let safeName = safeFilename(filename)
        let target = try destinationURL(profileID: profileID, sessionRemoteID: sessionRemoteID, filename: safeName)
        try data.write(to: target.url, options: .atomic)
        let digest = SHA256.hash(data: data)
        let attachment = HankAssistantStagedAttachment(
            id: target.id,
            clientAttachmentID: target.id.uuidString,
            profileID: profileID,
            sessionRemoteID: sessionRemoteID,
            filename: safeName,
            contentType: contentType.isEmpty ? "application/octet-stream" : contentType,
            kind: kind,
            sizeBytes: Int64(data.count),
            checksumSHA256: digest.map { String(format: "%02x", $0) }.joined(),
            localRelativePath: relativePath(for: target.url),
            createdAt: .now,
            expiresAt: Date().addingTimeInterval(lifetime)
        )
        try appendToManifest(attachment)
        return attachment
    }

    func bind(
        _ attachments: [HankAssistantStagedAttachment],
        profileID: UUID,
        sessionRemoteID: String
    ) throws -> [HankAssistantStagedAttachment] {
        guard !attachments.isEmpty else {
            return []
        }
        var manifest = try loadManifest()
        var rebound = attachments
        for index in rebound.indices where rebound[index].profileID == profileID && rebound[index].sessionRemoteID != sessionRemoteID {
            let oldURL = fileURL(for: rebound[index])
            let directory = rootURL
                .appendingPathComponent(profileID.uuidString, isDirectory: true)
                .appendingPathComponent(sessionRemoteID, isDirectory: true)
                .appendingPathComponent(rebound[index].id.uuidString, isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let newURL = directory.appendingPathComponent(rebound[index].filename, isDirectory: false)
            if fileManager.fileExists(atPath: newURL.path) {
                try fileManager.removeItem(at: newURL)
            }
            try fileManager.moveItem(at: oldURL, to: newURL)
            try? removeEmptyParentFolders(for: oldURL)
            rebound[index].sessionRemoteID = sessionRemoteID
            rebound[index].localRelativePath = relativePath(for: newURL)
            if let manifestIndex = manifest.firstIndex(where: { $0.id == rebound[index].id }) {
                manifest[manifestIndex] = rebound[index]
            }
        }
        try saveManifest(manifest)
        return rebound
    }

    func update(_ attachment: HankAssistantStagedAttachment) throws {
        var manifest = try loadManifest()
        if let index = manifest.firstIndex(where: { $0.id == attachment.id }) {
            manifest[index] = attachment
        } else {
            manifest.append(attachment)
        }
        try saveManifest(manifest)
    }

    func fileURL(for attachment: HankAssistantStagedAttachment) -> URL {
        rootURL.appendingPathComponent(attachment.localRelativePath, isDirectory: false)
    }

    func fileExists(for attachment: HankAssistantStagedAttachment) -> Bool {
        fileManager.fileExists(atPath: fileURL(for: attachment).path)
    }

    func remove(_ attachment: HankAssistantStagedAttachment) throws {
        try removeFile(for: attachment)
        var manifest = try loadManifest()
        manifest.removeAll { $0.id == attachment.id }
        try saveManifest(manifest)
    }

    func removeAll(for profileID: UUID) throws {
        var manifest = try loadManifest()
        let matches = manifest.filter { $0.profileID == profileID }
        for attachment in matches {
            try? removeFile(for: attachment)
        }
        manifest.removeAll { $0.profileID == profileID }
        try saveManifest(manifest)
    }

    private func destinationURL(profileID: UUID, sessionRemoteID: String?, filename: String) throws -> (id: UUID, url: URL) {
        let id = UUID()
        let directory = rootURL
            .appendingPathComponent(profileID.uuidString, isDirectory: true)
            .appendingPathComponent(sessionRemoteID ?? "pending", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return (id, directory.appendingPathComponent(filename, isDirectory: false))
    }

    private func appendToManifest(_ attachment: HankAssistantStagedAttachment) throws {
        var manifest = try loadManifest()
        manifest.removeAll { $0.id == attachment.id }
        manifest.append(attachment)
        try saveManifest(manifest)
    }

    private func loadManifest() throws -> [HankAssistantStagedAttachment] {
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return []
        }
        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder().decode([HankAssistantStagedAttachment].self, from: data)
    }

    private func saveManifest(_ manifest: [HankAssistantStagedAttachment]) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    private func checksumSHA256(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: 1024 * 1024)
            guard !data.isEmpty else {
                return false
            }
            hasher.update(data: data)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func relativePath(for url: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else {
            return url.lastPathComponent
        }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    private func removeFile(for attachment: HankAssistantStagedAttachment) throws {
        let url = fileURL(for: attachment)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try? removeEmptyParentFolders(for: url)
    }

    private func removeEmptyParentFolders(for fileURL: URL) throws {
        var directory = fileURL.deletingLastPathComponent()
        while directory.path.hasPrefix(rootURL.path), directory.path != rootURL.path {
            if (try? fileManager.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
                try fileManager.removeItem(at: directory)
                directory.deleteLastPathComponent()
            } else {
                break
            }
        }
    }

    private func safeFilename(_ value: String) -> String {
        let base = URL(fileURLWithPath: value).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._- "))
        let cleaned = base.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return cleaned.isEmpty ? "Attachment" : String(cleaned.prefix(180))
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
