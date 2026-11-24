#if canImport(SwiftUI)
import SwiftUI
import CPAQuotaKit
import CPAQuotaChat

/// Per-conversation settings. Changes apply immediately to this conversation only.
struct ChatConversationOptionsView: View {
    let chat: ChatWorkspaceModel
    let conversationID: UUID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isConfirmingDelete = false
    @State private var titleDraft = ""
    @State private var systemPromptDraft = ""
    @State private var hasLoadedDrafts = false

    var body: some View {
        let palette = BrandPalette(colorScheme: colorScheme, contrast: contrast)
        Group {
            if let conversation = chat.conversation(conversationID) {
                form(conversation, palette: palette)
            } else {
                ContentUnavailableView("对话已删除", systemImage: "trash")
            }
        }
        .navigationTitle("对话选项")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    commitTextDrafts()
                    dismiss()
                }
            }
        }
        .onAppear {
            loadTextDraftsIfNeeded()
        }
        .onDisappear {
            commitTextDrafts()
        }
    }

    private func form(_ conversation: ChatConversation, palette: BrandPalette) -> some View {
        Form {
            Section("标题") {
                TextField("新对话", text: $titleDraft)
                    .onSubmit { commitTextDrafts() }
                    .accessibilityIdentifier("chat.options.title")
            }
            .listRowBackground(palette.contentSurface)

            Section {
                Picker("模型", selection: Binding(
                    get: { chat.conversation(conversationID)?.modelID ?? conversation.modelID },
                    set: { value in
                        if let value {
                            chat.selectModel(value, in: conversationID)
                        } else {
                            chat.updateConversationMetadata(conversationID) { $0.modelID = nil }
                        }
                    }
                )) {
                    Text("未选择").tag(String?.none)
                    ForEach(chat.models) { model in
                        Text(model.id).tag(Optional(model.id))
                    }
                }
                #if os(iOS)
                .pickerStyle(.navigationLink)
                #else
                .pickerStyle(.menu)
                #endif
                ChatReasoningInlineSelector(
                    effort: chat.conversation(conversationID)?.reasoningEffort ?? conversation.reasoningEffort
                ) { effort in
                    chat.selectReasoningEffort(effort, in: conversationID)
                }
                Toggle("联网搜索", isOn: binding(\.isWebSearchEnabled, in: conversation))
                    .disabled(chat.settings.searchProvider == nil && !conversation.isWebSearchEnabled)
            } header: {
                Text("模型与能力")
            } footer: {
                Text(chat.settings.searchProvider == nil
                     ? "思考等级会自动适配当前模型；若模型不支持所选等级，将自动降级或按默认发送。联网搜索需要先在对话设置中选择搜索服务。"
                     : "思考等级会自动适配当前模型；若模型不支持所选等级，将自动降级或按默认发送。开启联网搜索后，每次发送会先检索，再把结果交给模型。")
            }
            .listRowBackground(palette.contentSurface)

            Section {
                TextEditor(text: $systemPromptDraft)
                    .frame(minHeight: 120)
                    .accessibilityIdentifier("chat.options.systemPrompt")
            } header: {
                Text("本对话设定")
            } footer: {
                Text("仅作用于这段对话，排在全局规则与记忆之后。例如：“你是一名严谨的 Swift 审稿人。”")
            }
            .listRowBackground(palette.contentSurface)

            let usage = totalUsage(conversation)
            if usage.inputTokens + usage.outputTokens > 0 {
                Section("用量") {
                    QuotaLabeledValue(title: "输入 Token", value: "\(usage.inputTokens)")
                    QuotaLabeledValue(title: "输出 Token", value: "\(usage.outputTokens)")
                    if usage.reasoningTokens > 0 {
                        QuotaLabeledValue(title: "推理 Token", value: "\(usage.reasoningTokens)")
                    }
                }
                .listRowBackground(palette.contentSurface)
            }

            Section {
                if chat.failedConversationDeletions.contains(conversationID) {
                    Label("未能从本机删除这段对话，请重试。", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(palette.statusWarn)
                }
                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Label("删除这段对话", systemImage: "trash")
                        .frame(minHeight: 44)
                }
            }
            .listRowBackground(palette.contentSurface)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(BrandCanvasBackground())
        .confirmationDialog("删除这段对话？", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                Task {
                    if await chat.deleteConversation(conversationID) {
                        dismiss()
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(ChatDeletionCopy.message(isGenerating: chat.isGenerating(conversationID)))
        }
    }

    private func loadTextDraftsIfNeeded() {
        guard !hasLoadedDrafts, let conversation = chat.conversation(conversationID) else { return }
        titleDraft = conversation.title
        systemPromptDraft = conversation.systemPrompt
        hasLoadedDrafts = true
    }

    private func commitTextDrafts() {
        guard hasLoadedDrafts, chat.conversation(conversationID) != nil else { return }
        chat.updateConversationMetadata(conversationID) {
            $0.title = titleDraft
            $0.systemPrompt = systemPromptDraft
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<ChatConversation, Value>,
                                in conversation: ChatConversation) -> Binding<Value> {
        Binding(
            get: { chat.conversation(conversationID)?[keyPath: keyPath] ?? conversation[keyPath: keyPath] },
            set: { value in chat.updateConversationMetadata(conversationID) { $0[keyPath: keyPath] = value } }
        )
    }

    private func totalUsage(_ conversation: ChatConversation) -> ChatTokenUsage {
        conversation.messages.compactMap(\.usage).reduce(into: ChatTokenUsage()) { total, usage in
            total.inputTokens += usage.inputTokens
            total.outputTokens += usage.outputTokens
            total.reasoningTokens += usage.reasoningTokens
        }
    }
}
#endif
