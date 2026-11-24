#if canImport(SwiftUI)
import SwiftUI
import CPAQuotaKit
import CPAQuotaChat

/// One conversation: messages scroll as content; the composer stays in the bottom control layer.
struct ChatConversationView: View {
    @Bindable var session: CPAQuotaSession
    let conversationID: UUID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.brandPalette) private var palette
    @State private var draft = ""
    @State private var attachments: [ChatImageAttachment] = []
    @State private var editingMessageID: UUID?
    /// The draft and images set aside while a sent message is being edited.
    @State private var stashedDraft: (text: String, attachments: [ChatImageAttachment])?
    @State private var loadedDraftConversationID: UUID?
    @State private var pendingConfirmation: PendingConfirmation?
    @State private var htmlPreview: ChatHTMLSnippet?
    @State private var isPresentingOptions = false
    @State private var isPresentingSettings = false
    @State private var memoryNotice: String?
    @State private var memoryNoticeTask: Task<Void, Never>?
    @State private var isScrolledAwayFromBottom = false
    @State private var scrollToBottomTrigger = 0
    @State private var emptyStateMinHeight: CGFloat = 0

    private var chat: ChatWorkspaceModel { session.chatWorkspace }

    var body: some View {
        Group {
            if let conversation = chat.conversation(conversationID) {
                content(conversation)
            } else if chat.hasConversation(conversationID) {
                ProgressView("正在读取对话")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .toolbar(.hidden, for: .tabBar)
        .sheet(item: $htmlPreview) { ChatHTMLPreview(snippet: $0) }
        #endif
        .tint(palette.actionTint)
        .task(id: conversationID) {
            _ = await chat.loadConversationIfNeeded(conversationID)
        }
        .onChange(of: !chat.hasConversation(conversationID)) { _, deleted in
            // Deleting from the options sheet returns to the list instead of an empty page.
            if deleted { dismiss() }
        }
        .onAppear {
            restoreDraftIfNeeded()
        }
        .onChange(of: conversationID) { oldID, _ in
            persistCurrentDraft(for: oldID)
            loadedDraftConversationID = nil
            editingMessageID = nil
            stashedDraft = nil
            isScrolledAwayFromBottom = false
            restoreDraftIfNeeded()
        }
        .onChange(of: draft) { _, _ in
            guard loadedDraftConversationID == conversationID, editingMessageID == nil else { return }
            persistCurrentDraft(for: conversationID)
        }
        .onChange(of: attachments) { _, _ in
            guard loadedDraftConversationID == conversationID, editingMessageID == nil else { return }
            persistCurrentDraft(for: conversationID)
        }
        .onDisappear {
            persistCurrentDraft(for: conversationID)
            memoryNoticeTask?.cancel()
            memoryNoticeTask = nil
        }
        .sheet(isPresented: $isPresentingOptions) {
            NavigationStack {
                ChatConversationOptionsView(chat: chat, conversationID: conversationID)
            }
            .brandPaletteEnvironment()
            .tint(palette.actionTint)
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isPresentingSettings) {
            NavigationStack {
                ChatSettingsView(chat: chat)
            }
            .brandPaletteEnvironment()
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
    private func content(_ conversation: ChatConversation) -> some View {
        let isGenerating = chat.isGenerating(conversation.id)
        let lastAssistant = conversation.messages.last(where: { $0.role == .assistant })
        let lastAssistantID = lastAssistant?.id
        let activeReasoningNotice: String? = {
            guard let resolution = lastAssistant?.reasoningResolution,
                  resolution.outcome != .applied,
                  resolution.requested == conversation.reasoningEffort,
                  lastAssistant?.modelID == conversation.modelID
            else { return nil }
            return resolution.noticeText
        }()
        ScrollViewReader { proxy in
            ScrollView {
                if conversation.messages.isEmpty {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        ChatConversationEmptyState(conversation: conversation)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, minHeight: max(0, emptyStateMinHeight))
                } else {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        let canRerun = chat.generationBlocker(for: conversation.id) == nil
                        ForEach(conversation.messages) { message in
                            ChatMessageView(
                                message: message,
                                isLatestAssistant: message.id == lastAssistantID,
                                isConversationGenerating: isGenerating,
                                canRerun: canRerun,
                                actions: actions(for: message)
                            )
                            .equatable()
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
            }
            .scrollDismissesKeyboard(.interactively)
            .modifier(ChatScrollEdgeModifier())
            .modifier(ChatStreamingAutoScrollModifier(
                proxy: proxy,
                bottomAnchor: Self.bottomAnchor,
                isGenerating: isGenerating,
                messageCount: conversation.messages.count,
                latestTextLength: conversation.messages.last?.text.count ?? 0,
                scrollToBottomTrigger: scrollToBottomTrigger,
                isScrolledAwayFromBottom: $isScrolledAwayFromBottom,
                visibleViewportHeight: $emptyStateMinHeight
            ))
            .overlay(alignment: .bottomTrailing) {
                if isScrolledAwayFromBottom, !conversation.messages.isEmpty {
                    Button {
                        scrollToBottomTrigger &+= 1
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(palette.textPrimary)
                            .frame(width: 36, height: 36)
                            .background(.regularMaterial, in: Circle())
                            .overlay {
                                Circle()
                                    .strokeBorder(palette.trackBackground, lineWidth: 0.75)
                                    .allowsHitTesting(false)
                            }
                            .shadow(color: Color.black.opacity(0.12), radius: 4, y: 2)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 16)
                    .padding(.bottom, 8)
                    .accessibilityLabel("回到底部")
                    .accessibilityIdentifier("chat.scrollToBottom")
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
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
                        activeReasoningNotice: activeReasoningNotice,
                        draft: $draft,
                        attachments: $attachments,
                        editingMessageID: $editingMessageID,
                        onOpenSettings: { isPresentingSettings = true },
                        onCancelEdit: endEditing,
                        onContinue: { request(.continueReply($0)) },
                        onSubmit: { submit() }
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

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let editingMessageID {
            guard !text.isEmpty else { return }
            request(.edit(editingMessageID, text))
        } else {
            guard !text.isEmpty || !attachments.isEmpty else { return }
            request(.send(text, attachments))
        }
    }

    /// Asks first when the action would send this history to another server
    /// or delete messages after the rerun point; otherwise performs it directly.
    private func request(_ action: PendingAction) {
        guard let conversation = chat.conversation(conversationID) else { return }
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
            chat.clearDraft(for: conversationID)
        case .edit(let messageID, let text):
            guard chat.editAndResend(messageID, text: text, in: conversationID,
                                     confirmingServerChange: serverChange) else { return }
            endEditing()
        case .continueReply(let target):
            guard draft.isEmpty, attachments.isEmpty, editingMessageID == nil else { return }
            chat.continueReply(target, confirmingServerChange: serverChange)
        case .regenerate(let messageID):
            chat.regenerate(messageID, in: conversationID, confirmingServerChange: serverChange)
        case .deleteMessage(let messageID):
            chat.deleteMessage(messageID, in: conversationID)
        }
    }

    /// Messages beyond the reply being replaced; the replaced reply itself is not counted.
    private func laterMessageCount(for action: PendingAction, in conversation: ChatConversation) -> Int {
        let messages = conversation.messages
        switch action {
        case .send, .continueReply, .deleteMessage:
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

    private func restoreDraftIfNeeded() {
        guard loadedDraftConversationID != conversationID else { return }
        let saved = chat.draft(for: conversationID)
        draft = saved.text
        attachments = saved.attachments
        loadedDraftConversationID = conversationID
    }

    private func persistCurrentDraft(for id: UUID) {
        guard chat.hasConversation(id) else {
            chat.clearDraft(for: id)
            return
        }
        if let stashedDraft, editingMessageID != nil {
            chat.saveDraft(.init(text: stashedDraft.text, attachments: stashedDraft.attachments), for: id)
        } else {
            chat.saveDraft(.init(text: draft, attachments: attachments), for: id)
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
        persistCurrentDraft(for: conversationID)
    }

    private func actions(for message: ChatMessage) -> ChatMessageActions {
        ChatMessageActions(
            copy: { ChatClipboard.copy(message.text) },
            previewHTML: { htmlPreview = $0 },
            regenerate: message.role == .assistant
                ? { request(.regenerate(message.id)) } : nil,
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
            delete: {
                pendingConfirmation = PendingConfirmation(
                    action: .deleteMessage(message.id),
                    serverChange: nil,
                    title: "删除这条消息？",
                    message: "删除后无法恢复。",
                    confirmTitle: "删除",
                    isDestructive: true
                )
            },
            openSettings: { isPresentingSettings = true },
            refreshModels: { Task { await chat.refreshModels() } }
        )
    }
}

private enum PendingAction {
    case continueReply(ChatContinuation)
    case send(String, [ChatImageAttachment])
    case edit(UUID, String)
    case regenerate(UUID)
    case deleteMessage(UUID)
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
    @Environment(\.brandPalette) private var palette

    var body: some View {
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
    @Environment(\.brandPalette) private var palette

    var body: some View {
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
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }
}

/// Title plus the active model; picking a model applies to this conversation only.
struct ChatModelMenu: View {
    let chat: ChatWorkspaceModel
    let conversation: ChatConversation
    let onOpenSettings: () -> Void
    @Environment(\.brandPalette) private var palette

    var body: some View {
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
    let isGenerating: Bool
    let messageCount: Int
    let latestTextLength: Int
    let scrollToBottomTrigger: Int
    @Binding var isScrolledAwayFromBottom: Bool
    @Binding var visibleViewportHeight: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPinnedToBottom = true
    @State private var isUserScrolling = false
    @State private var pendingFollow: Task<Void, Never>?
    @State private var remainingAnimationFollows = 0

    @ViewBuilder
    func body(content: Content) -> some View {
        let base = content
            .onChange(of: messageCount) { oldCount, newCount in
                guard newCount > oldCount, !isUserScrolling else { return }
                isPinnedToBottom = true
                isScrolledAwayFromBottom = false
                remainingAnimationFollows = 2
                scheduleFollow()
            }
            .onChange(of: scrollToBottomTrigger) { _, _ in
                cancelFollow()
                isPinnedToBottom = true
                isScrolledAwayFromBottom = false
                remainingAnimationFollows = 2
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            }
        if #available(iOS 18.0, macOS 15.0, *) {
            base
                // Anchor empty conversations to the top so AX5/landscape content scrolls downward
                // cleanly instead of colliding with the navigation bar; active threads anchor bottom.
                .defaultScrollAnchor(messageCount == 0 ? .top : .bottom, for: .initialOffset)
                .defaultScrollAnchor(messageCount == 0 ? .top : .bottom, for: .alignment)
                .onScrollPhaseChange { oldPhase, newPhase, context in
                    let wasScrolling = oldPhase == .interacting || oldPhase == .decelerating
                    let isScrolling = newPhase == .interacting || newPhase == .decelerating
                    isUserScrolling = newPhase == .tracking || isScrolling
                    if isUserScrolling {
                        remainingAnimationFollows = 0
                        cancelFollow()
                    }
                    if wasScrolling || isScrolling {
                        let distance = ScrollMetrics(context.geometry).distanceFromBottom
                        isPinnedToBottom = distance <= 24
                        updateScrolledAwayState(distance: distance)
                    } else if oldPhase == .animating, newPhase == .idle,
                              isPinnedToBottom, !isUserScrolling,
                              messageCount > 0, remainingAnimationFollows > 0 {
                        // Multi-pass Markdown layout can finish expanding after the first animated scroll;
                        // re-snap once or twice if still short of the true bottom.
                        let distance = ScrollMetrics(context.geometry).distanceFromBottom
                        if distance > 4 {
                            remainingAnimationFollows -= 1
                            scheduleFollow()
                        }
                    }
                }
                .onScrollGeometryChange(for: ScrollMetrics.self) { ScrollMetrics($0) } action: { oldValue, newValue in
                    if abs(visibleViewportHeight - newValue.visibleHeight) >= 1 {
                        visibleViewportHeight = newValue.visibleHeight
                    }
                    updateScrolledAwayState(distance: newValue.distanceFromBottom)
                    if messageCount > 0, oldValue.bottomOffset != newValue.bottomOffset, newValue.distanceFromBottom > 1 {
                        remainingAnimationFollows = 2
                        scheduleFollow()
                    }
                }
                .onChange(of: latestTextLength) { oldLength, newLength in
                    if isGenerating, newLength > oldLength {
                        remainingAnimationFollows = 2
                        scheduleFollow()
                    }
                }
                .onDisappear(perform: cancelFollow)
        } else {
            base
                .defaultScrollAnchor(messageCount == 0 ? .top : .bottom)
                .onDisappear(perform: cancelFollow)
        }
    }

    private func updateScrolledAwayState(distance: CGFloat) {
        let shouldShow = isScrolledAwayFromBottom ? distance > 48 : distance > 120
        guard shouldShow != isScrolledAwayFromBottom else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
            isScrolledAwayFromBottom = shouldShow
        }
    }

    private func scheduleFollow() {
        guard isPinnedToBottom, !isUserScrolling, pendingFollow == nil else { return }
        // A text change and its layout can arrive in the same update. Let both use one request.
        pendingFollow = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            pendingFollow = nil
            guard isPinnedToBottom, !isUserScrolling else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        }
    }

    private func cancelFollow() {
        pendingFollow?.cancel()
        pendingFollow = nil
    }

    private struct ScrollMetrics: Equatable, Sendable {
        let bottomOffset: CGFloat
        let distanceFromBottom: CGFloat
        let visibleHeight: CGFloat

        @available(iOS 18.0, macOS 15.0, *)
        init(_ geometry: ScrollGeometry) {
            bottomOffset = max(
                -geometry.contentInsets.top,
                geometry.contentSize.height + geometry.contentInsets.bottom - geometry.containerSize.height
            )
            distanceFromBottom = max(0, bottomOffset - geometry.contentOffset.y)
            visibleHeight = max(0, (geometry.containerSize.height - geometry.contentInsets.top - geometry.contentInsets.bottom).rounded(.down))
        }
    }
}
#endif
