#if canImport(SwiftUI)
import SwiftUI
import CPAQuotaKit
import CPAQuotaChat

/// One conversation: messages scroll as content; the composer stays in the bottom control layer.
struct ChatConversationView: View {
    @Bindable var session: CPAQuotaSession
    let conversationID: UUID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var draft = ""
    @State private var attachments: [ChatImageAttachment] = []
    @State private var editingMessageID: UUID?
    /// The draft and images set aside while a sent message is being edited.
    @State private var stashedDraft: (text: String, attachments: [ChatImageAttachment])?
    @State private var pendingConfirmation: PendingConfirmation?
    @State private var htmlPreview: ChatHTMLSnippet?
    @State private var isPresentingOptions = false
    @State private var isPresentingSettings = false
    @State private var memoryNotice: String?
    @State private var memoryNoticeTask: Task<Void, Never>?

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
        #if os(iOS)
        .sheet(item: $htmlPreview) { ChatHTMLPreview(snippet: $0) }
        #endif
        .tint(palette.actionTint)
        .onChange(of: chat.conversation(conversationID) == nil) { _, deleted in
            // Deleting from the options sheet returns to the list instead of an empty page.
            if deleted { dismiss() }
        }
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
                perform(confirmation.action, serverChange: confirmation.serverChange)
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
                    Color.clear
                        .frame(height: 1)
                        .padding(.bottom, 12)
                        .id(Self.bottomAnchor)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .modifier(ChatScrollEdgeModifier())
            .modifier(ChatStreamingAutoScrollModifier(
                proxy: proxy,
                bottomAnchor: Self.bottomAnchor,
                messageCount: conversation.messages.count
            ))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if chat.unsavedConversations.contains(conversation.id) {
                        Label("最新内容未能保存到本机", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(palette.statusWarn)
                    }
                    // Above the composer, so the notice is visible wherever the remembered message was.
                    if let memoryNotice {
                        Label(memoryNotice, systemImage: "checkmark.circle")
                            .font(.footnote)
                            .foregroundStyle(palette.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                            .padding(.bottom, 4)
                            .transition(.opacity)
                    }
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
                        onContinue: { request(.continueReply($0), in: conversation) },
                        onSubmit: { submit(in: conversation) }
                    )
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("chat.composer")
            }
        }
        .onChange(of: conversation.messages.last.map { "\($0.id)|\($0.status.rawValue)" }) { old, _ in
            guard old != nil, let last = conversation.messages.last, last.role == .assistant else { return }
            switch last.status {
            case .complete: announce(last.failure.map { "回复已完成，\(ChatFailurePresentation($0).title)" } ?? "回复已完成")
            case .failed: announce("回复生成失败")
            case .stopped: announce("已停止生成")
            case .interrupted: announce("生成已中断")
            case .streaming: break
            }
        }
        .navigationTitle(conversation.displayTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) {
                ChatModelMenu(chat: chat, conversation: conversation,
                              onOpenSettings: { isPresentingSettings = true })
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
        let replacesInterrupted: Bool
        if case .regenerate(let id) = action {
            replacesInterrupted = conversation.messages.first { $0.id == id }?.status == .interrupted
        } else {
            replacesInterrupted = false
        }
        var parts: [String] = []
        if case .continueReply(let target) = action, target.previousModelID != target.modelID {
            let previous = target.previousModelID ?? "未知模型"
            parts.append("上一请求使用「\(previous)」，本次将使用「\(target.modelID)」。")
        }
        guard change != nil || removed > 0 || replacesInterrupted || !parts.isEmpty else {
            perform(action, serverChange: nil)
            return
        }
        if replacesInterrupted { parts.append("将发送一次新的生成请求并替换这条中断的回复，可能产生新的用量。") }
        if let change {
            let images = change.imageCount > 0 ? "和 \(change.imageCount) 张图片" : ""
            let origin = change.previousServerIdentifier.map { "这段对话来自 \(ChatServerLabel.display($0))。" }
                ?? "这段对话没有记录所属的 CPA 服务。"
            parts.append("\(origin)继续会把此前的 \(change.messageCount) 条消息\(images)发送到 \(ChatServerLabel.display(change.currentServerIdentifier))，之后这段对话归属该服务。")
        }
        if removed > 0 {
            parts.append("此后的 \(removed) 条消息将被删除，无法恢复。")
        }
        let isContinuation: Bool
        if case .continueReply = action { isContinuation = true } else { isContinuation = false }
        pendingConfirmation = PendingConfirmation(
            action: action,
            serverChange: change,
            title: change != nil ? "在当前服务继续这段对话？" : (removed > 0 ? "删除后续消息并重新生成？" : (isContinuation ? "使用当前模型继续？" : "替换中断的回复？")),
            message: parts.joined(separator: "\n"),
            confirmTitle: change != nil ? "继续发送" : (removed > 0 ? "删除并重新生成" : (isContinuation ? "继续生成" : "确认重新生成")),
            isDestructive: removed > 0)
    }

    private func perform(_ action: PendingAction, serverChange: ChatServerChange?) {
        switch action {
        case .send(let text, let images):
            guard chat.send(text, attachments: images, in: conversationID,
                            confirmingServerChange: serverChange) else { return }
            draft = ""
            attachments = []
        case .edit(let messageID, let text):
            guard chat.editAndResend(messageID, text: text, in: conversationID,
                                     confirmingServerChange: serverChange) else { return }
            endEditing()
        case .continueReply(let target):
            guard draft.isEmpty, attachments.isEmpty, editingMessageID == nil else { return }
            chat.continueReply(target, confirmingServerChange: serverChange)
        case .regenerate(let messageID):
            chat.regenerate(messageID, in: conversationID, confirmingServerChange: serverChange)
        }
    }

    /// Messages beyond the reply being replaced; the replaced reply itself is not counted.
    private func laterMessageCount(for action: PendingAction, in conversation: ChatConversation) -> Int {
        let messages = conversation.messages
        switch action {
        case .send, .continueReply:
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

    private func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
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
            previewHTML: { htmlPreview = $0 },
            regenerate: message.role == .assistant
                ? { request(.regenerate(message.id), in: conversation) } : nil,
            edit: message.role == .user ? { beginEditing(message) } : nil,
            remember: {
                chat.addMemory(message.text)
                withAnimation { memoryNotice = "已加入记忆" }
                announce("已加入记忆")
                // A newer notice restarts the timer instead of being cleared by an older one.
                memoryNoticeTask?.cancel()
                memoryNoticeTask = Task {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    withAnimation { memoryNotice = nil }
                }
            },
            delete: { chat.deleteMessage(message.id, in: conversation.id) }
        )
    }
}

private enum PendingAction {
    case continueReply(ChatContinuation)
    case send(String, [ChatImageAttachment])
    case edit(UUID, String)
    case regenerate(UUID)
}

private struct PendingConfirmation {
    let action: PendingAction
    let serverChange: ChatServerChange?
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
    let onOpenSettings: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let palette = BrandPalette(colorScheme: colorScheme, contrast: contrast)
        Menu {
            Picker("模型", selection: Binding(
                get: { conversation.modelID },
                set: { value in
                    if let value { chat.selectModel(value, in: conversation.id) }
                }
            )) {
                ForEach(chat.models) { model in
                    Text(model.id).tag(Optional(model.id))
                }
            }
            Divider()
            switch chat.modelListState {
            case .loading:
                Text("正在读取模型列表")
            case .failed(let failure):
                Text(ChatFailurePresentation(failure).title)
                if failure.suggestsDifferentKey {
                    Button {
                        onOpenSettings()
                    } label: {
                        Label("更换 API Key", systemImage: "key")
                    }
                }
            case .loaded where chat.models.isEmpty:
                Text("CPA 没有返回可用模型")
            default:
                EmptyView()
            }
            Button {
                Task { await chat.refreshModels() }
            } label: {
                Label("刷新模型列表", systemImage: "arrow.clockwise")
            }
            .disabled(chat.modelListState == .loading)
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

/// Follows streaming growth while the reader stays at the bottom without yanking them back once they scroll up.
private struct ChatStreamingAutoScrollModifier: ViewModifier {
    let proxy: ScrollViewProxy
    let bottomAnchor: String
    let messageCount: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPinnedToBottom = true
    @State private var isUserScrolling = false
    @State private var isAnimating = false

    @ViewBuilder
    func body(content: Content) -> some View {
        let base = content
            .onChange(of: messageCount) { oldCount, newCount in
                guard newCount > oldCount, !isUserScrolling else { return }
                isPinnedToBottom = true
                scrollToBottom()
            }
        if #available(iOS 18.0, macOS 15.0, *) {
            base
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .alignment)
                .onScrollPhaseChange { oldPhase, newPhase, context in
                    let didScroll = oldPhase == .interacting || oldPhase == .decelerating
                    let isScrolling = newPhase == .interacting || newPhase == .decelerating
                    let metrics = ScrollMetrics(context.geometry)
                    isUserScrolling = newPhase == .tracking || isScrolling
                    isAnimating = newPhase == .animating
                    if didScroll || isScrolling {
                        isPinnedToBottom = metrics.distanceFromBottom <= 24
                    }
                    if newPhase == .idle {
                        followBottomIfNeeded(metrics)
                    }
                }
                .onScrollGeometryChange(for: ScrollMetrics.self) { ScrollMetrics($0) } action: { oldValue, newValue in
                    guard oldValue.bottomOffset != newValue.bottomOffset else { return }
                    followBottomIfNeeded(newValue)
                }
        } else {
            base.defaultScrollAnchor(.bottom)
        }
    }

    private func followBottomIfNeeded(_ metrics: ScrollMetrics) {
        guard isPinnedToBottom, !isUserScrolling, !isAnimating, metrics.distanceFromBottom > 1 else { return }
        scrollToBottom()
    }

    private func scrollToBottom() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        }
    }

    private struct ScrollMetrics: Equatable, Sendable {
        let bottomOffset: CGFloat
        let distanceFromBottom: CGFloat

        @available(iOS 18.0, macOS 15.0, *)
        init(_ geometry: ScrollGeometry) {
            bottomOffset = max(
                -geometry.contentInsets.top,
                geometry.contentSize.height + geometry.contentInsets.bottom - geometry.containerSize.height
            )
            distanceFromBottom = max(0, bottomOffset - geometry.contentOffset.y)
        }
    }
}
#endif
