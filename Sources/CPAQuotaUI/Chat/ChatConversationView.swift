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
                    ForEach(conversation.messages) { message in
                        ChatMessageView(
                            message: message,
                            isLatestAssistant: message.id == lastAssistantID,
                            isConversationGenerating: isGenerating,
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
                ChatComposerView(
                    chat: chat,
                    conversation: conversation,
                    draft: $draft,
                    attachments: $attachments,
                    editingMessageID: $editingMessageID,
                    onOpenSettings: { isPresentingSettings = true },
                    onSubmit: { submit(in: conversation) }
                )
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
            chat.editAndResend(editingMessageID, text: text, in: conversation.id)
            self.editingMessageID = nil
        } else {
            guard !text.isEmpty || !attachments.isEmpty else { return }
            chat.send(text, attachments: attachments, in: conversation.id)
            attachments = []
        }
        draft = ""
    }

    private func actions(for message: ChatMessage, in conversation: ChatConversation) -> ChatMessageActions {
        ChatMessageActions(
            copy: { ChatClipboard.copy(message.text) },
            regenerate: message.role == .assistant
                ? { chat.regenerate(message.id, in: conversation.id) } : nil,
            edit: message.role == .user ? {
                editingMessageID = message.id
                draft = message.text
                attachments = []
            } : nil,
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
