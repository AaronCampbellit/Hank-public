import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers

struct HankAssistantView: View {
    @ObservedObject var store: HankAssistantStore
    @ObservedObject var calendarStore: CalendarStore
    let bottomContentInset: CGFloat
    @State private var isDocumentPickerPresented = false
    @State private var isCameraPresented = false
    @State private var isLogSheetPresented = false
    @State private var selectedPhotos: [PhotosPickerItem] = []

    var body: some View {
        NavigationSplitView {
            sessionSidebar
        } detail: {
            conversationDetail
        }
        .navigationSplitViewStyle(.balanced)
        .hankNavigationChrome()
        .hankScreenBackground()
    }

    private var sessionSidebar: some View {
        List(selection: $store.selectedSessionID) {
            Section {
                Button(action: createConversation) {
                    Label("New Conversation", systemImage: "square.and.pencil")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .disabled(store.activeProfileID == nil)
                .listRowBackground(HankTheme.surface)
            }

            Section("Recent") {
                ForEach(store.sessions) { session in
                    Button {
                        Task {
                            await store.selectSession(session.id)
                        }
                    } label: {
                        HankAssistantSessionRow(
                            title: session.title,
                            preview: session.previewText,
                            updatedAt: session.updatedAt,
                            isSelected: store.selectedSessionID == session.id
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(store.selectedSessionID == session.id ? HankTheme.elevatedSurface : HankTheme.surface)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            Task {
                                await store.deleteSession(session.id)
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.insetGrouped)
        .navigationTitle("Hank")
        .navigationBarTitleDisplayMode(.inline)
        .hankNavigationChrome()
        .hankScreenBackground()
    }

    private func createConversation() {
        Task {
            await store.createSession()
        }
    }

    private var conversationDetail: some View {
        Group {
            if store.activeProfileID == nil {
                ContentUnavailableView(
                    "Hank",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text("Sign in to a profile before starting a conversation.")
                )
                .hankScreenBackground()
            } else if let session = store.selectedSession {
                HankAssistantConversationView(
                    session: session,
                    draftText: $store.draftText,
                    selectedPhotos: $selectedPhotos,
                    isSending: store.isSending,
                    stagedAttachments: store.stagedAttachments,
                    pendingConfirmation: store.pendingConfirmation,
                    downloadProgress: store.downloadProgress,
                    slashCommands: store.slashCommands,
                    bottomContentInset: bottomContentInset,
                    onSend: {
                        Task {
                            await store.sendDraft(using: calendarStore)
                        }
                    },
                    onOpenCard: { card in
                        store.open(card)
                    },
                    onRefresh: {
                        Task {
                            await store.refreshSelectedSession()
                        }
                    },
                    onShowLogs: {
                        isLogSheetPresented = true
                    },
                    onPickFiles: {
                        isDocumentPickerPresented = true
                    },
                    onOpenCamera: {
                        isCameraPresented = UIImagePickerController.isSourceTypeAvailable(.camera)
                    },
                    onRemoveAttachment: { attachment in
                        store.removeStagedAttachment(attachment)
                    },
                    onPreviewAttachment: { attachment in
                        store.previewStagedAttachment(attachment)
                    },
                    onSelectSlashCommand: { command in
                        store.insertSlashCommand(command)
                    },
                    onConfirm: {
                        Task {
                            await store.respondToPendingConfirmation(approved: true, using: calendarStore)
                        }
                    },
                    onCancel: {
                        Task {
                            await store.respondToPendingConfirmation(approved: false, using: calendarStore)
                        }
                    }
                )
            } else {
                ContentUnavailableView(
                    "No Conversation Selected",
                    systemImage: "message.badge",
                    description: Text("Create a conversation to start shaping the Hank assistant flow.")
                )
                .hankScreenBackground()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .hankScreenBackground()
        .fileImporter(
            isPresented: $isDocumentPickerPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
            onCompletion: handlePickedDocuments
        )
        .sheet(isPresented: $isCameraPresented) {
            HankAssistantCameraPicker { image in
                guard let data = image.jpegData(compressionQuality: 0.86) else {
                    return
                }
                let name = "Camera \(Self.photoFilenameDateFormatter.string(from: .now)).jpg"
                Task {
                    await store.stagePhoto(data: data, suggestedFilename: name, contentType: "image/jpeg")
                }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $isLogSheetPresented) {
            HankAssistantLogSheet(
                logText: store.diagnosticLogText(),
                onCopy: {
                    UIPasteboard.general.string = store.diagnosticLogText()
                    store.markLogsCopied()
                },
                onClear: {
                    store.clearLogs()
                }
            )
        }
        .quickLookPreview(attachmentPreviewURL)
        .onChange(of: selectedPhotos) { _, items in
            handleSelectedPhotos(items)
        }
    }

    private var attachmentPreviewURL: Binding<URL?> {
        Binding(
            get: { store.attachmentPreview?.url },
            set: { nextURL in
                if nextURL == nil {
                    store.attachmentPreview = nil
                }
            }
        )
    }

    private func handlePickedDocuments(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else {
            return
        }
        Task {
            for url in urls {
                let didStartAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didStartAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                await store.stageAttachment(from: url)
            }
        }
    }

    private func handleSelectedPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else {
            return
        }
        Task {
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    let contentType = item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg"
                    let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                    let name = "Photo \(Self.photoFilenameDateFormatter.string(from: .now)).\(ext)"
                    await store.stagePhoto(data: data, suggestedFilename: name, contentType: contentType)
                }
            }
            selectedPhotos = []
        }
    }

    private static let photoFilenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter
    }()
}

private struct HankAssistantLogSheet: View {
    let logText: String
    let onCopy: () -> Void
    let onClear: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(logText)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.88))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(HankTheme.background)
            .navigationTitle("Hank Chat Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Copy") {
                        onCopy()
                    }
                    Button("Clear", role: .destructive) {
                        onClear()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct HankAssistantConversationView: View {
    let session: HankAssistantSession
    @Binding var draftText: String
    @Binding var selectedPhotos: [PhotosPickerItem]
    let isSending: Bool
    let stagedAttachments: [HankAssistantStagedAttachment]
    let pendingConfirmation: HankAssistantPendingConfirmation?
    let downloadProgress: HankAssistantDownloadProgress?
    let slashCommands: [HankAssistantSlashCommand]
    let bottomContentInset: CGFloat
    let onSend: () -> Void
    let onOpenCard: (HankAssistantResultCard) -> Void
    let onRefresh: () -> Void
    let onShowLogs: () -> Void
    let onPickFiles: () -> Void
    let onOpenCamera: () -> Void
    let onRemoveAttachment: (HankAssistantStagedAttachment) -> Void
    let onPreviewAttachment: (HankAssistantStagedAttachment) -> Void
    let onSelectSlashCommand: (HankAssistantSlashCommand) -> Void
    let onConfirm: () -> Void
    let onCancel: () -> Void
    private static let pendingConfirmationScrollID = "pending-confirmation"
    private static let conversationBottomScrollID = "conversation-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(session.messages) { message in
                        HankAssistantMessageBubble(message: message, onOpenCard: onOpenCard)
                            .id(message.id)
                    }

                    if let pendingConfirmation {
                        HankAssistantConfirmationCard(
                            confirmation: pendingConfirmation,
                            isSending: isSending,
                            onConfirm: onConfirm,
                            onCancel: onCancel
                        )
                        .id(Self.pendingConfirmationScrollID)
                    }

                    if let downloadProgress {
                        HankAssistantDownloadProgressCard(progress: downloadProgress, onOpen: {
                            if let filePath = downloadProgress.filePath {
                                onOpenCard(
                                    HankAssistantResultCard(
                                        kind: .file,
                                        title: downloadProgress.title,
                                        summary: filePath,
                                        actionTitle: "Open Location",
                                        target: HankAssistantNavigationTarget(kind: .file(path: filePath))
                                    )
                                )
                            }
                        })
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.conversationBottomScrollID)
                }
                .padding(.horizontal, 18)
                .padding(.top, 20)
                .padding(.bottom, 120)
            }
            .hankScreenBackground()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composer
                    .padding(.bottom, bottomContentInset)
            }
            .task(id: session.id) {
                scrollToConversationEnd(with: proxy, animated: false)
            }
            .task(id: session.messages.last?.id) {
                scrollToConversationEnd(with: proxy, animated: false)
            }
            .onChange(of: session.messages.count) { _, _ in
                scrollToConversationEnd(with: proxy, animated: true)
            }
            .onChange(of: session.messages.last?.id) { _, _ in
                scrollToConversationEnd(with: proxy, animated: true)
            }
            .onChange(of: pendingConfirmation?.id) { _, newValue in
                guard newValue != nil else {
                    return
                }
                scrollToPendingConfirmation(with: proxy, animated: true)
            }
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    onShowLogs()
                } label: {
                    Label("Logs", systemImage: "doc.text.magnifyingglass")
                }

                Button {
                    onRefresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            if !matchingSlashCommands.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(matchingSlashCommands) { command in
                            Button {
                                onSelectSlashCommand(command)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(command.command)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color.white.opacity(0.94))
                                    Text(command.description)
                                        .font(.caption2)
                                        .foregroundStyle(Color.white.opacity(0.62))
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: 180, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(HankTheme.surface.opacity(0.88))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(HankTheme.accent.opacity(0.22), lineWidth: 1)
                            )
                            .accessibilityLabel("\(command.label) command")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                }
            }

            if !stagedAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(stagedAttachments) { attachment in
	                            HankAssistantAttachmentChip(
	                                attachment: attachment,
	                                onPreview: {
	                                    onPreviewAttachment(attachment)
	                                },
	                                onRemove: {
	                                    onRemoveAttachment(attachment)
	                                }
	                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                }
            }

            HStack(alignment: .bottom, spacing: 12) {
                Menu {
                    Button(action: onPickFiles) {
                        Label("Attach File", systemImage: "paperclip")
                    }

                    PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 6, matching: .images) {
                        Label("Choose Photo", systemImage: "photo")
                    }

                    Button(action: onOpenCamera) {
                        Label("Take Photo", systemImage: "camera")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(HankTheme.accent)
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel("Add attachment")

                TextField("Ask Hank...", text: $draftText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .foregroundStyle(Color.white)
                    .lineLimit(1 ... 5)

                Button {
                    onSend()
                } label: {
                    if isSending {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(Color.white)
                            .frame(width: 20, height: 20)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(
                                !canSend
                                    ? Color.white.opacity(0.35)
                                    : HankTheme.accent
                            )
                    }
                }
                .buttonStyle(.plain)
                .disabled(isSending || !canSend)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .hankGlassCapsule(tint: HankTheme.accent.opacity(0.12), interactive: false)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
    }

    private var canSend: Bool {
        !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !stagedAttachments.isEmpty
    }

    private var matchingSlashCommands: [HankAssistantSlashCommand] {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.starts(with: "/") else {
            return []
        }
        let query = trimmed.lowercased()
        return slashCommands
            .filter { $0.command.lowercased().starts(with: query) }
            .prefix(8)
            .map { $0 }
    }

    private func scrollToConversationEnd(with proxy: ScrollViewProxy, animated: Bool) {
        if pendingConfirmation != nil {
            scrollToPendingConfirmation(with: proxy, animated: animated)
        } else {
            scrollToBottom(with: proxy, animated: animated)
        }
    }

    private func scrollToPendingConfirmation(with proxy: ScrollViewProxy, animated: Bool) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            if animated {
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(Self.pendingConfirmationScrollID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(Self.pendingConfirmationScrollID, anchor: .bottom)
            }
        }
    }

    private func scrollToBottom(with proxy: ScrollViewProxy, animated: Bool) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            if animated {
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(Self.conversationBottomScrollID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(Self.conversationBottomScrollID, anchor: .bottom)
            }
        }
    }
}

private struct HankAssistantMessageBubble: View {
    let message: HankAssistantMessage
    let onOpenCard: (HankAssistantResultCard) -> Void

    private var isUser: Bool { message.role == .user }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 10) {
            Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.42))
                .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)

            HStack {
                if isUser {
                    Spacer(minLength: 44)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(roleTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(roleColor.opacity(0.8))

                    Text(message.text)
                        .font(.body)
                        .foregroundStyle(Color.white.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !message.cards.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(message.cards) { card in
                                HankAssistantResultCardView(card: card, onOpen: {
                                    onOpenCard(card)
                                })
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: 540, alignment: .leading)
                .background {
                    bubbleShape.fill(bubbleBackground)
                }
                .overlay(
                    bubbleShape
                        .stroke(roleColor.opacity(0.18), lineWidth: 1)
                )
                .clipShape(bubbleShape)

                if !isUser {
                    Spacer(minLength: 44)
                }
            }
        }
    }

    private var roleTitle: String {
        switch message.role {
        case .user:
            "You"
        case .assistant:
            "Hank"
        case .system:
            "System"
        }
    }

    private var roleColor: Color {
        switch message.role {
        case .user:
            HankTheme.accent
        case .assistant:
            HankTheme.accent.opacity(0.92)
        case .system:
            Color.white.opacity(0.7)
        }
    }

    private var bubbleBackground: some ShapeStyle {
        LinearGradient(
            colors: isUser
                ? [HankTheme.accent.opacity(0.22), HankTheme.accent.opacity(0.12)]
                : [HankTheme.surface.opacity(0.92), HankTheme.surface.opacity(0.72)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var bubbleShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
    }
}

private struct HankAssistantAttachmentChip: View {
    let attachment: HankAssistantStagedAttachment
    let onPreview: () -> Void
	    let onRemove: () -> Void

	    var body: some View {
	        HStack(spacing: 8) {
	            Image(systemName: attachment.kind == "image" ? "photo" : "doc")
	                .font(.system(size: 14, weight: .semibold))
	                .foregroundStyle(HankTheme.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.filename)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .lineLimit(1)

                Text("\(attachment.kind.capitalized) - \(attachment.sizeLabel)")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.58))
                    .lineLimit(1)
            }
            .frame(maxWidth: 180, alignment: .leading)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.62))
	            }
	            .buttonStyle(.plain)
	            .accessibilityLabel("Remove attachment")
	        }
	        .contentShape(Rectangle())
	        .onTapGesture(perform: onPreview)
	        .accessibilityLabel("Preview \(attachment.filename)")
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(HankTheme.surface.opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct HankAssistantCameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, dismiss: dismiss)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onCapture: (UIImage) -> Void
        let dismiss: DismissAction

        init(onCapture: @escaping (UIImage) -> Void, dismiss: DismissAction) {
            self.onCapture = onCapture
            self.dismiss = dismiss
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onCapture(image)
            }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}

private struct HankAssistantConfirmationCard: View {
    let confirmation: HankAssistantPendingConfirmation
    let isSending: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Review Download", systemImage: "arrow.down.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(HankTheme.accent.opacity(0.92))

            Text(confirmation.title)
                .font(.headline)
                .foregroundStyle(Color.white)

            Text(primaryText)
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.76))

            detailsGrid

            HStack(spacing: 10) {
                Button(confirmation.cancelTitle, action: onCancel)
                    .buttonStyle(.bordered)
                    .tint(.white.opacity(0.35))

                Button(confirmation.confirmTitle, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .tint(confirmation.isDestructive ? HankTheme.error : HankTheme.accent)
            }
            .disabled(isSending)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hankCard(fill: HankTheme.surface)
    }

    private var primaryText: String {
        let summary = confirmation.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? confirmation.message : summary
    }

    @ViewBuilder
    private var detailsGrid: some View {
        let visibleDetails = confirmation.details.filter { !$0.value.isEmpty }.prefix(4)
        if !visibleDetails.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(Array(visibleDetails), id: \.self) { detail in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(detail.label)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.white.opacity(0.52))
                        Text(detail.value)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Color.white.opacity(0.9))
                            .lineLimit(2)
                    }
                }
            }
        }
    }
}

private struct HankAssistantDownloadProgressCard: View {
    let progress: HankAssistantDownloadProgress
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(progress.isComplete ? "Download Complete" : "Downloading Media", systemImage: progress.isComplete ? "checkmark.circle" : "arrow.down.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(HankTheme.accent.opacity(0.92))

            Text(progress.title)
                .font(.headline)
                .foregroundStyle(Color.white)

            if let fraction = progress.fractionCompleted {
                ProgressView(value: fraction)
                    .tint(HankTheme.accent)
            } else {
                ProgressView()
                    .tint(HankTheme.accent)
            }

            Text(statusText)
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.68))

            if progress.isComplete, progress.filePath != nil {
                Button("Open Location", action: onOpen)
                    .buttonStyle(.borderedProminent)
                    .tint(HankTheme.accent)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hankCard(fill: HankTheme.surface)
    }

    private var statusText: String {
        var parts = ["\(progress.completed)/\(progress.total) item(s)"]
        if progress.skipped > 0 {
            parts.append("\(progress.skipped) already present")
        }
        if progress.failed > 0 {
            parts.append("\(progress.failed) failed")
        }
        return parts.joined(separator: " • ")
    }
}

private struct HankAssistantResultCardView: View {
    let card: HankAssistantResultCard
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let imageURL = card.imageURL {
                HankAssistantResultCardImage(url: imageURL)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label(cardKindTitle, systemImage: cardSystemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HankTheme.accent.opacity(0.92))

                Text(card.title)
                    .font(.headline)
                    .foregroundStyle(Color.white)

                Text(card.summary)
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.74))

                if card.target != nil {
                    Button(card.actionTitle, action: onOpen)
                        .buttonStyle(.borderedProminent)
                        .tint(HankTheme.accent)
                } else {
                    Text(card.actionTitle)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hankCard(fill: HankTheme.surface)
    }

    private var cardKindTitle: String {
        switch card.kind {
        case .note:
            "Note Result"
        case .calendar:
            "Calendar Result"
        case .file:
            "File Result"
        case .homeAssistant:
            "Home Assistant Result"
        case .projectDoc:
            "Project Doc Result"
        case .media:
            "Media Result"
        }
    }

    private var cardSystemImage: String {
        switch card.kind {
        case .note:
            "note.text"
        case .calendar:
            "calendar"
        case .file:
            "folder"
        case .homeAssistant:
            "bolt.horizontal"
        case .projectDoc:
            "doc.text.magnifyingglass"
        case .media:
            "film"
        }
    }
}

private struct HankAssistantResultCardImage: View {
    let url: URL

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
            case .failure:
                placeholder(systemImage: "photo")
            case .empty:
                placeholder(systemImage: "film")
            @unknown default:
                placeholder(systemImage: "film")
            }
        }
        .frame(width: 64, height: 96)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .accessibilityHidden(true)
    }

    private func placeholder(systemImage: String) -> some View {
        ZStack {
            Color.white.opacity(0.06)
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.42))
        }
    }
}

private struct HankAssistantSessionRow: View {
    let title: String
    let preview: String
    let updatedAt: Date
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(isSelected ? 0.96 : 0.88))
                    .lineLimit(1)

                Spacer(minLength: 12)

                Text(updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.46))
                    .lineLimit(1)
            }

            Text(preview)
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.62))
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isSelected ? HankTheme.accent.opacity(0.18) : Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isSelected ? HankTheme.accent.opacity(0.28) : Color.white.opacity(0.05), lineWidth: 1)
        )
    }
}
