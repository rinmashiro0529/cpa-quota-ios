#if canImport(SwiftUI)
import SwiftUI
import CPAQuotaKit
import CPAQuotaChat

enum ChatDestination: Hashable {
    case conversation(UUID)
}

/// Root of the AI chat tab: conversation history plus the entry to chat settings.
public struct ChatWorkspaceView: View {
    @Bindable var session: CPAQuotaSession
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var searchText = ""
    @State private var isPresentingSettings = false
    @State private var pendingConversation: UUID?
    @State private var renaming: ChatConversation?
    @State private var renameDraft = ""
    @State private var pendingDeletion: ChatConversation?

    public init(session: CPAQuotaSession) {
        self.session = session
    }

    private var chat: ChatWorkspaceModel { session.chatWorkspace }

    private var visibleConversations: [ChatConversation] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return chat.conversations }
        return chat.conversations.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(query)
                || $0.messages.contains { $0.text.localizedCaseInsensitiveContains(query) }
        }
    }

    public var body: some View {
        let palette = BrandPalette(colorScheme: colorScheme, contrast: contrast)
        List {
            if !isCredentialReady {
                Section {
                    ChatCredentialStatusRow(chat: chat)
                    Button {
                        isPresentingSettings = true
                    } label: {
                        Label("选择 API Key", systemImage: "key")
                            .frame(minHeight: 44)
                    }
                    .quotaPrimaryButtonStyle()
                    .accessibilityIdentifier("chat.chooseKey")
                } header: {
                    Text("对话凭据").font(QuotaTypography.brandHeadline)
                } footer: {
                    Text("对话使用 CPA 客户端 API Key 调用模型，与管理密钥分开保存。")
                }
                .listRowBackground(palette.contentSurface)
            }

            if !chat.isLoaded {
                Section {
                    ProgressView("正在读取本机对话记录")
                        .frame(maxWidth: .infinity)
                }
                .listRowBackground(palette.contentSurface)
            } else if chat.conversations.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("还没有对话", systemImage: "bubble.left.and.text.bubble.right")
                    } description: {
                        Text("新建对话后，可选择 CPA 提供的任一模型。对话记录只保存在本机。")
                    } actions: {
                        Button {
                            startConversation()
                        } label: {
                            Label("新建对话", systemImage: "square.and.pencil")
                                .frame(minHeight: 44)
                        }
                        .quotaSecondaryButtonStyle()
                        .accessibilityIdentifier("chat.emptyNew")
                    }
                }
                .listRowBackground(palette.contentSurface)
            } else if visibleConversations.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .listRowBackground(palette.contentSurface)
            } else {
                Section {
                    ForEach(visibleConversations) { conversation in
                        NavigationLink(value: ChatDestination.conversation(conversation.id)) {
                            ChatConversationRow(conversation: conversation,
                                                isGenerating: chat.isGenerating(conversation.id))
                        }
                        .accessibilityIdentifier("chat.conversation.\(conversation.id.uuidString)")
                        .swipeActions(edge: .trailing) {
                            // No destructive role: the row must stay until the deletion is confirmed.
                            Button {
                                pendingDeletion = conversation
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            .tint(palette.statusError)
                        }
                        .contextMenu {
                            Button {
                                renameDraft = conversation.title
                                renaming = conversation
                            } label: {
                                Label("重命名", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                pendingDeletion = conversation
                            } label: {
                                Label("删除对话", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("最近对话")
                }
                .listRowBackground(palette.contentSurface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(BrandCanvasBackground())
        .navigationTitle(CPAWorkspaceTab.chat.title)
        .searchable(text: $searchText, prompt: "搜索对话标题或内容")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    startConversation()
                } label: {
                    Label("新建对话", systemImage: "square.and.pencil")
                }
                .disabled(!chat.isLoaded)
                .accessibilityIdentifier("chat.new")
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    isPresentingSettings = true
                } label: {
                    Label("对话设置", systemImage: "slider.horizontal.3")
                }
                .accessibilityIdentifier("chat.settings")
            }
        }
        .navigationDestination(for: ChatDestination.self) { destination in
            switch destination {
            case .conversation(let id):
                ChatConversationView(session: session, conversationID: id)
            }
        }
        .navigationDestination(item: $pendingConversation) { id in
            ChatConversationView(session: session, conversationID: id)
        }
        .sheet(isPresented: $isPresentingSettings) {
            NavigationStack {
                ChatSettingsView(chat: chat)
            }
            .tint(palette.actionTint)
            .presentationDragIndicator(.visible)
        }
        .alert("重命名对话", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("对话标题", text: $renameDraft)
            Button("保存") {
                if let renaming { chat.renameConversation(renaming.id, title: renameDraft) }
                renaming = nil
            }
            Button("取消", role: .cancel) { renaming = nil }
        }
        .confirmationDialog(
            "删除这段对话？",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { conversation in
            Button("删除", role: .destructive) { chat.deleteConversation(conversation.id) }
            Button("取消", role: .cancel) {}
        } message: { conversation in
            Text(ChatDeletionCopy.message(isGenerating: chat.isGenerating(conversation.id)))
        }
        .tint(palette.actionTint)
        .task { await chat.loadIfNeeded() }
    }

    private var isCredentialReady: Bool {
        if case .ready = chat.credentialState { return true }
        return false
    }

    private func startConversation() {
        pendingConversation = chat.createConversation()
    }
}

struct ChatConversationRow: View {
    let conversation: ChatConversation
    let isGenerating: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let palette = BrandPalette(colorScheme: colorScheme, contrast: contrast)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(conversation.displayTitle)
                    .font(.headline)
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isGenerating {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在生成")
                } else {
                    Text(conversation.updatedAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(palette.textMuted)
                }
            }
            Text(conversation.previewText)
                .font(.subheadline)
                .foregroundStyle(palette.textSecondary)
                .lineLimit(2)
            if let model = conversation.modelID {
                Text(model)
                    .font(QuotaTypography.dataDetail)
                    .foregroundStyle(palette.textMuted)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Shows where the chat credential stands without ever revealing the key.
struct ChatCredentialStatusRow: View {
    let chat: ChatWorkspaceModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let palette = BrandPalette(colorScheme: colorScheme, contrast: contrast)
        switch chat.credentialState {
        case .unbound:
            Label("尚未连接 CPA 服务", systemImage: "link")
                .foregroundStyle(palette.textSecondary)
        case .loading:
            ProgressView("正在读取 API Key")
        case .missingKey:
            VStack(alignment: .leading, spacing: 6) {
                Label(chat.isDiscoveringKeys ? "正在从 CPA 读取可用 API Key" : "尚未选择 API Key",
                      systemImage: "key.slash")
                    .foregroundStyle(palette.textPrimary)
                if let error = chat.keyDiscoveryError {
                    QuotaErrorNotice(presentation: ErrorPresentation(error: error), showsRecoveryAdvice: false)
                } else if chat.discoveredKeys.count > 1 {
                    Text("CPA 配置了 \(chat.discoveredKeys.count) 把客户端 API Key，请选择本机对话使用的一把。")
                        .font(.subheadline)
                        .foregroundStyle(palette.textSecondary)
                } else if !chat.isDiscoveringKeys {
                    Text("没有读取到可用的客户端 API Key，可以手动填写。")
                        .font(.subheadline)
                        .foregroundStyle(palette.textSecondary)
                }
            }
        case .ready(let hint, let isManual):
            QuotaLabeledValue(title: isManual ? "手动填写的 Key" : "CPA 客户端 Key", value: hint)
        case .failed(let error):
            QuotaErrorNotice(presentation: ErrorPresentation(error: error), showsRecoveryAdvice: false)
        }
    }
}
#endif
