#if canImport(SwiftUI)
import SwiftUI
import CPAQuotaKit
import CPAQuotaChat

/// Workspace-wide chat settings: credential, default model, rules, memory, skills, search and notifications.
struct ChatSettingsView: View {
    @Bindable var chat: ChatWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var manualKeyDraft = ""
    @State private var manualKeyRejected = false
    @State private var searchKeyDraft = ""
    @State private var searchKeySaved: Bool?
    @State private var searchKeyRejected = false
    @State private var notificationDenied = false
    @State private var isConfirmingDeleteAll = false

    var body: some View {
        let palette = BrandPalette(colorScheme: colorScheme, contrast: contrast)
        Form {
            credentialSection(palette)
            modelSection(palette)

            Section {
                NavigationLink {
                    ChatTextEditorView(
                        title: "全局规则",
                        text: $chat.settings.globalInstructions,
                        footer: "对所有对话生效，例如回答语言、格式偏好或身份设定。"
                    )
                } label: {
                    LabeledContent("全局规则", value: chat.settings.globalInstructions.isEmpty ? "未设置" : "已设置")
                }
                Toggle("使用记忆", isOn: $chat.settings.isMemoryEnabled)
                NavigationLink {
                    ChatMemoryListView(chat: chat)
                } label: {
                    LabeledContent("管理记忆", value: "\(chat.memories.count) 条")
                }
                NavigationLink {
                    ChatSkillListView(chat: chat)
                } label: {
                    LabeledContent("斜杠技能", value: "\(chat.skills.count) 个")
                }
            } header: {
                Text("规则、记忆与技能")
            } footer: {
                Text("发送时依次附加全局规则、记忆和本对话设定。记忆可以在消息菜单中“加入记忆”，也可以在这里手动添加。")
            }
            .listRowBackground(palette.contentSurface)

            searchSection(palette)

            Section {
                Toggle("后台完成时通知", isOn: Binding(
                    get: { chat.settings.notifiesOnBackgroundCompletion },
                    set: { enabled in
                        chat.settings.notifiesOnBackgroundCompletion = enabled
                        guard enabled else { return }
                        Task { notificationDenied = !(await chat.requestNotificationAuthorization()) }
                    }
                ))
                if notificationDenied {
                    Label("系统未允许通知，可在“设置”中为 CPA Quota 开启。", systemImage: "bell.slash")
                        .font(.footnote)
                        .foregroundStyle(palette.textSecondary)
                }
                Toggle("自动生成对话标题", isOn: $chat.settings.generatesTitles)
            } header: {
                Text("通知与标题")
            } footer: {
                Text("离开应用后，系统通常只允许继续生成约 30 秒；超时会保存已生成的内容并标记为中断。通知只显示对话标题，不显示消息内容。自动标题会额外发送一次简短请求。")
            }
            .listRowBackground(palette.contentSurface)

            Section {
                Button(role: .destructive) {
                    isConfirmingDeleteAll = true
                } label: {
                    Label("删除全部对话", systemImage: "trash")
                        .frame(minHeight: 44)
                }
                .disabled(chat.conversations.isEmpty)
            } footer: {
                Text("对话、记忆与技能只保存在本机，不会上传到 CPA 以外的服务。")
            }
            .listRowBackground(palette.contentSurface)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(BrandCanvasBackground())
        .navigationTitle("对话设置")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
        .confirmationDialog("删除全部对话？", isPresented: $isConfirmingDeleteAll, titleVisibility: .visible) {
            Button("删除全部", role: .destructive) { chat.deleteAllConversations() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将移除本机保存的全部对话记录，记忆与技能保留。")
        }
        .task(id: chat.settings.searchProvider) { await refreshSearchKeyState() }
        .onChange(of: chat.server) { _, _ in
            manualKeyDraft = ""
            manualKeyRejected = false
        }
    }

    // MARK: Credential

    private func credentialSection(_ palette: BrandPalette) -> some View {
        Section {
            ChatCredentialStatusRow(chat: chat)
            if chat.keyRemovalFailed {
                Label("未能移除保存的 Key。请重试。", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(palette.statusWarn)
            }

            if !chat.discoveredKeys.isEmpty {
                ForEach(chat.discoveredKeys, id: \.self) { key in
                    Button {
                        Task { await chat.selectKey(key) }
                    } label: {
                        HStack {
                            Label(key.hint, systemImage: "key")
                                .font(QuotaTypography.dataDetail)
                                .foregroundStyle(palette.textPrimary)
                            Spacer()
                            if isSelected(key) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(palette.actionTint)
                                    .accessibilityLabel("当前使用")
                            }
                        }
                        .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("chat.key.option")
                }
            }

            Button {
                Task { await chat.discoverKeys() }
            } label: {
                Label(chat.isDiscoveringKeys ? "正在读取" : "从 CPA 读取可用 Key", systemImage: "arrow.down.circle")
                    .frame(minHeight: 44)
            }
            .disabled(chat.server == nil || chat.isDiscoveringKeys)
            .accessibilityIdentifier("chat.key.discover")

            SecureField("手动填写客户端 API Key", text: $manualKeyDraft)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .accessibilityIdentifier("chat.key.manual")
            if manualKeyRejected {
                Label("Key 不能为空，也不能包含换行等控制字符。", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(palette.statusWarn)
            }
            Button {
                let input = manualKeyDraft
                let server = chat.server
                manualKeyRejected = CPAClientAPIKey(input) == nil
                guard !manualKeyRejected else { return }
                Task {
                    guard chat.server == server else { return }
                    if await chat.useManualKey(input), chat.server == server, manualKeyDraft == input {
                        manualKeyDraft = ""
                    }
                }
            } label: {
                Label("使用手动填写的 Key", systemImage: "checkmark.circle")
                    .frame(minHeight: 44)
            }
            .disabled(chat.server == nil || manualKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if isCredentialReady || (chat.keyRemovalFailed && chat.credentialState != .loading) {
                Button(role: .destructive) {
                    let server = chat.server
                    Task {
                        guard chat.server == server else { return }
                        await chat.removeStoredKey()
                    }
                } label: {
                    Label("移除本机保存的 Key", systemImage: "trash")
                        .frame(minHeight: 44)
                }
            }
        } header: {
            Text("API Key").font(QuotaTypography.brandHeadline)
        } footer: {
            Text("读取 Key 列表使用已保存的 CPA 管理密钥；对话请求只使用所选的客户端 API Key。所选 Key 存入仅限本设备的系统钥匙串，界面只显示末尾 4 位。")
        }
        .listRowBackground(palette.contentSurface)
    }

    private func isSelected(_ key: CPAClientAPIKey) -> Bool {
        if case .ready(let hint, let isManual) = chat.credentialState { return !isManual && hint == key.hint }
        return false
    }

    // MARK: Models

    private func modelSection(_ palette: BrandPalette) -> some View {
        Section {
            Picker("新对话默认模型", selection: $chat.settings.defaultModelID) {
                Text("列表中的第一个").tag(String?.none)
                ForEach(chat.models) { model in
                    Text(model.id).tag(Optional(model.id))
                }
            }
            #if os(iOS)
            .pickerStyle(.navigationLink)
            #else
            .pickerStyle(.menu)
            #endif
            switch chat.modelListState {
            case .idle:
                EmptyView()
            case .loading:
                ProgressView("正在读取模型列表")
            case .loaded:
                QuotaLabeledValue(title: "可用模型", value: "\(chat.models.count) 个")
            case .failed(let failure):
                ChatFailureNotice(failure: failure)
            }
            Button {
                Task { await chat.refreshModels() }
            } label: {
                Label("刷新模型列表", systemImage: "arrow.clockwise")
                    .frame(minHeight: 44)
            }
            .disabled(!isCredentialReady || chat.modelListState == .loading)
        } header: {
            Text("模型")
        } footer: {
            Text("模型列表来自 CPA 的 /v1/models，取决于服务端配置的账号与别名。")
        }
        .listRowBackground(palette.contentSurface)
    }

    private var isCredentialReady: Bool {
        if case .ready = chat.credentialState { return true }
        return false
    }

    // MARK: Search

    private func searchSection(_ palette: BrandPalette) -> some View {
        Section {
            Picker("搜索服务", selection: $chat.settings.searchProvider) {
                Text("不使用").tag(ChatSearchProvider?.none)
                ForEach(ChatSearchProvider.allCases) { provider in
                    Text(provider.displayName).tag(Optional(provider))
                }
            }
            if let provider = chat.settings.searchProvider {
                QuotaLabeledValue(
                    title: "\(provider.displayName) Key",
                    value: searchKeySaved == nil ? "检查中" : (searchKeySaved == true ? "已保存" : "未设置"),
                    monospaced: false
                )
                SecureField("填写 \(provider.displayName) API Key", text: $searchKeyDraft)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                if searchKeyRejected {
                    Label("Key 格式无效或未能保存。", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(palette.statusWarn)
                }
                Button {
                    Task {
                        let saved = await chat.saveSearchKey(searchKeyDraft, for: provider)
                        searchKeyRejected = !saved
                        if saved { searchKeyDraft = "" }
                        await refreshSearchKeyState()
                    }
                } label: {
                    Label("保存搜索 Key", systemImage: "checkmark.circle")
                        .frame(minHeight: 44)
                }
                .disabled(searchKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if searchKeySaved == true {
                    Button(role: .destructive) {
                        Task {
                            await chat.removeSearchKey(for: provider)
                            await refreshSearchKeyState()
                        }
                    } label: {
                        Label("移除搜索 Key", systemImage: "trash")
                            .frame(minHeight: 44)
                    }
                }
            }
        } header: {
            Text("联网搜索")
        } footer: {
            Text("搜索由所选的第三方服务完成，需要该服务自己的 API Key；搜索词会发送给该服务。在对话中点按地球图标开启。")
        }
        .listRowBackground(palette.contentSurface)
    }

    private func refreshSearchKeyState() async {
        guard let provider = chat.settings.searchProvider else {
            searchKeySaved = nil
            return
        }
        searchKeySaved = nil
        searchKeySaved = await chat.hasSearchKey(for: provider)
    }
}

/// A full-height editor for long free-form instructions.
struct ChatTextEditorView: View {
    let title: String
    @Binding var text: String
    let footer: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let palette = BrandPalette(colorScheme: colorScheme, contrast: contrast)
        Form {
            Section {
                TextEditor(text: $text)
                    .frame(minHeight: 240)
            } footer: {
                Text(footer)
            }
            .listRowBackground(palette.contentSurface)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(BrandCanvasBackground())
        .navigationTitle(title)
    }
}
#endif
