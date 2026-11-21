#if canImport(SwiftUI)
import SwiftUI
import CPAQuotaKit
import CPAQuotaChat

/// One conversation: messages scroll as content; the composer stays in the bottom control layer.
struct ChatConversationView: View {
    @Bindable var session: CPAQuotaSession
    let conversationID: UUID
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var draft = ""
    @State private var attachments: [ChatImageAttachment] = []
    @State private var editingMessageID: UUID?
    /// The draft and images set aside while a sent message is being edited.
    @State private var stashedDraft: (text: String, attachments: [ChatImageAttachment])?
    @State private var pendingConfirmation: PendingConfirmation?
    @State private var isPresentingOptions = false
    @State private var isPresentingSettings = false
    @State private var memoryNotice: String?

    private var chat: ChatWorkspaceModel { session.chatWorkspace }

    var body: some View {
        let palette = BrandPalette(colorScheme: colorScheme, contrast: contrast)
        Group {
            if let conversation = chat.conversation(conversationID) {
                content(conversation, palette: palette)
            } else {
                ContentUnavailableView {
                    Label("对话已删除", systemImage: "trash")
                } description: {
                    Text("这段对话已从本机移除。")
                }
            }
        }
        .background(BrandCanvasBackground())
        .tint(palette.actionTint)
        .sheet(isPresented: $isPresentingOptions) {
            NavigationStack {
                ChatConversationOptionsView(chat: chat, conversationID: conversationID)
            }
            .tint(palette.actionTint)
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isPresentingSettings) {
            NavigationStack {
                ChatSettingsView(chat: chat)
            }
            .tint(palette.actionTint)
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            pendingConfirmation?.title ?? "",
            isPresented: Binding(get: { pendingConfirmation != nil },
                                 set: { if !$0 { pendingConfirmation = nil } }),
            titleVisibility: .visible,
            presenting: pendingConfirmation
        ) { confirmation in
            Button(confirmation.confirmTitle, role: confirmation.isDestructive ? .destructive : nil) {
                perform(confirmation.action, confirmingServerChange: true)
            }
            Button("取消", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    @ViewBuilder
    private func content(_ conversation: ChatConversation, palette: BrandPalette) -> some View {
        let isGenerating = chat.isGenerating(conversation.id)
        let lastAssistantID = conversation.messages.last(where: { $0.role == .assistant })?.id
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if conversation.messages.isEmpty {
                        ChatConversationEmptyState(conversation: conversation)
                            .padding(.top, 40)
                    }
                    let canRerun = chat.generationBlocker(for: conversation.id) == nil
                    ForEach(conversation.messages) { message in
                        ChatMessageView(
                            message: message,
                            isLatestAssistant: message.id == lastAssistantID,
                            isConversationGenerating: isGenerating,
                            canRerun: canRerun,
                            actions: actions(for: message, in: conversation)
                        )
                        .id(message.id)
                    }
                    if let memoryNotice {
                        Label(memoryNotice, systemImage: "checkmark.circle")
                            .font(.footnote)
                            .foregroundStyle(palette.textSecondary)
                            .frame(maxWidth: .infinity)
                            .transition(.opacity)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .modifier(ChatScrollEdgeModifier())
            .onChange(of: conversation.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if let change = chat.serverChange(for: conversation.id) {
                        ChatServerChangeNotice(change: change)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 4)
                    }
                    ChatComposerView(
                        chat: chat,
                        conversation: conversation,
                        draft: $draft,
                        attachments: $attachments,
                        editingMessageID: $editingMessageID,
                        onOpenSettings: { isPresentingSettings = true },
                        onCancelEdit: endEditing,
                        onSubmit: { submit(in: conversation) }
                    )
                }
            }
        }
        .navigationTitle(conversation.displayTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) {
                ChatModelMenu(chat: chat, conversation: conversation)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isPresentingOptions = true
                } label: {
                    Label("对话选项", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("chat.options")
            }
        }
    }

    private static let bottomAnchor = "chat.bottom"

    private func submit(in conversation: ChatConversation) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let editingMessageID {
            guard !text.isEmpty else { return }
            request(.edit(editingMessageID, text), in: conversation)
        } else {
            guard !text.isEmpty || !attachments.isEmpty else { return }
            request(.send(text, attachments), in: conversation)
        }
    }

    /// Asks first when the action would send this history to another server
    /// or delete messages after the rerun point; otherwise performs it directly.
    private func request(_ action: PendingAction, in conversation: ChatConversation) {
        let change = chat.serverChange(for: conversation.id)
        let removed = laterMessageCount(for: action, in: conversation)
        guard change != nil || removed > 0 else {
            perform(action, confirmingServerChange: false)
            return
        }
        var parts: [String] = []
        if let change {
            let images = change.imageCount > 0 ? "和 \(change.imageCount) 张图片" : ""
            let origin = change.previousServerIdentifier.map { "这段对话来自 \(ChatServerLabel.display($0))。" }
                ?? "这段对话没有记录所属的 CPA 服务。"
            parts.append("\(origin)继续会把此前的 \(change.messageCount) 条消息\(images)发送到 \(ChatServerLabel.display(change.currentServerIdentifier))，之后这段对话归属该服务。")
        }
        if removed > 0 {
            parts.append("此后的 \(removed) 条消息将被删除，无法恢复。")
        }
        pendingConfirmation = PendingConfirmation(
            action: action,
            title: change != nil ? "在当前服务继续这段对话？" : "删除后续消息并重新生成？",
            message: parts.joined(separator: "\n"),
            confirmTitle: change != nil ? "继续发送" : "删除并重新生成",
            isDestructive: removed > 0)
    }

    private func perform(_ action: PendingAction, confirmingServerChange: Bool) {
        switch action {
        case .send(let text, let images):
            guard chat.send(text, attachments: images, in: conversationID,
                            confirmingServerChange: confirmingServerChange) else { return }
            draft = ""
            attachments = []
        case .edit(let messageID, let text):
            guard chat.editAndResend(messageID, text: text, in: conversationID,
                                     confirmingServerChange: confirmingServerChange) else { return }
            endEditing()
        case .regenerate(let messageID):
            chat.regenerate(messageID, in: conversationID, confirmingServerChange: confirmingServerChange)
        }
    }

    /// Messages beyond the reply being replaced; the replaced reply itself is not counted.
    private func laterMessageCount(for action: PendingAction, in conversation: ChatConversation) -> Int {
        let messages = conversation.messages
        switch action {
        case .send:
            return 0
        case .regenerate(let id):
            guard let index = messages.firstIndex(where: { $0.id == id }) else { return 0 }
            return messages.count - index - 1
        case .edit(let id, _):
            guard let index = messages.firstIndex(where: { $0.id == id }) else { return 0 }
            let replyOffset = index + 1 < messages.count && messages[index + 1].role == .assistant ? 2 : 1
            return max(0, messages.count - index - replyOffset)
        }
    }

    private func beginEditing(_ message: ChatMessage) {
        if editingMessageID == nil {
            stashedDraft = (draft, attachments)
        }
        editingMessageID = message.id
        draft = message.text
        attachments = []
    }

    private func endEditing() {
        editingMessageID = nil
        draft = stashedDraft?.text ?? ""
        attachments = stashedDraft?.attachments ?? []
        stashedDraft = nil
    }

    private func actions(for message: ChatMessage, in conversation: ChatConversation) -> ChatMessageActions {
        ChatMessageActions(
            copy: { ChatClipboard.copy(message.text) },
            regenerate: message.role == .assistant
                ? { request(.regenerate(message.id), in: conversation) } : nil,
            edit: message.role == .user ? { beginEditing(message) } : nil,
            remember: {
                chat.addMemory(message.text)
                withAnimation { memoryNotice = "已加入记忆" }
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation { memoryNotice = nil }
                }
            },
            delete: { chat.deleteMessage(message.id, in: conversation.id) }
        )
    }
}

private enum PendingAction {
    case send(String, [ChatImageAttachment])
    case edit(UUID, String)
    case regenerate(UUID)
}

private struct PendingConfirmation {
    let action: PendingAction
    let title: String
    let message: String
    let confirmTitle: String
    let isDestructive: Bool
}

/// States which server this history came from before anything is sent to the current one.
private struct ChatServerChangeNotice: View {
    let change: ChatServerChange
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let palette = BrandPalette(colorScheme: colorScheme, contrast: contrast)
        Label(text, systemImage: "server.rack")
            .font(.footnote)
            .foregroundStyle(palette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("chat.serverChange")
    }

    private var text: String {
        let current = ChatServerLabel.display(change.currentServerIdentifier)
        guard let previous = change.previousServerIdentifier else {
            return "这段对话没有记录所属服务，继续发送前会先确认。当前连接：\(current)"
        }
        return "这段对话来自 \(ChatServerLabel.display(previous))，当前连接：\(current)。继续发送前会先确认。"
    }
}

private struct ChatConversationEmptyState: View {
    let conversation: ChatConversation
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let palette = BrandPalette(colorScheme: colorScheme, contrast: contrast)
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.largeTitle)
                .foregroundStyle(palette.accent)
                .accessibilityHidden(true)
            Text("开始对话")
                .font(QuotaTypography.brandTitle)
                .foregroundStyle(palette.textPrimary)
            Text(conversation.modelID.map { "当前模型：\($0)" } ?? "请先在顶部选择模型")
                .font(.subheadline)
                .foregroundStyle(palette.textSecondary)
            Text("输入 / 可使用技能；对话记录只保存在本机。")
                .font(.footnote)
                .foregroundStyle(palette.textMuted)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

/// Title plus the active model; picking a model applies to this conversation only.
struct ChatModelMenu: View {
    let chat: ChatWorkspaceModel
    let conversation: ChatConversation
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let palette = BrandPalette(colorScheme: colorScheme, contrast: contrast)
        Menu {
            Picker("模型", selection: Binding(
                get: { conversation.modelID },
                set: { value in chat.updateConversation(conversation.id) { $0.modelID = value } }
            )) {
                ForEach(chat.models) { model in
                    Text(model.id).tag(Optional(model.id))
                }
            }
            Divider()
            Button {
                Task { await chat.refreshModels() }
            } label: {
                Label("刷新模型列表", systemImage: "arrow.clockwise")
            }
        } label: {
            VStack(spacing: 0) {
                Text(conversation.displayTitle)
                    .font(.headline)
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 3) {
                    Text(conversation.modelID ?? "选择模型")
                        .font(.caption.monospaced())
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(palette.textSecondary)
            }
            .frame(maxWidth: 240)
        }
        .accessibilityLabel("模型：\(conversation.modelID ?? "未选择")")
        .accessibilityIdentifier("chat.modelMenu")
    }
}

/// Soft scroll edges are the iOS 26+ treatment for content under system bars.
private struct ChatScrollEdgeModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            content
        }
    }
}
#endif
