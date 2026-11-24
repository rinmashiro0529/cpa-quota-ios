#if canImport(SwiftUI)
import SwiftUI
import CPAQuotaKit
import CPAQuotaChat
#if os(iOS)
import UIKit
#endif

/// Workspace-wide chat settings: credential, default model, rules, memory, skills, search and notifications.
struct ChatSettingsView: View {
    @Bindable var chat: ChatWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.brandPalette) private var palette
    @State private var manualKeyDraft = ""
    @State private var manualKeyRejected = false
    @State private var searchKeyDraft = ""
    @State private var searchKeyStatus: ChatSearchKeyStatus?
    @State private var searchKeyRejected = false
    @State private var searchKeyRemovalFailed = false
    @State private var notificationStatus: ChatNotificationAuthorization?
    @State private var isConfirmingDeleteAll = false
    @State private var isDeletingAll = false
    @State private var deleteAllFailed = false

    var body: some View {
        Form {
            credentialSection(palette)
            modelSection(palette)

            Section {
                if chat.settingsLoadFailed {
                    ChatStorageWarningRow(
                        message: "偏好设置读取失败，已暂时停用记忆附加，请重试读取。",
                        retryTitle: "重试读取设置",
                        retryAction: { await chat.retryLoadMetadata() }
                    )
                }
                if chat.unsavedSettings {
                    ChatStorageWarningRow(
                        message: "偏好设置未能保存到本机，重启后可能恢复旧状态。",
                        retryTitle: "重试保存设置",
                        retryAction: { _ = await chat.retrySaveSettings() }
                    )
                }
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
                Text("发送时依次附加全局规则、记忆和本对话设定。全局规则与记忆作用于所有已连接的 CPA 服务；切换服务时如不希望附带，可先关闭“使用记忆”。")
            }
            .listRowBackground(palette.contentSurface)

            searchSection(palette)

            Section {
                // Shown as on only when the system will actually deliver the notification.
                Toggle("后台完成时通知", isOn: Binding(
                    get: { chat.settings.notifiesOnBackgroundCompletion && notificationStatus == .authorized },
                    set: { enabled in
                        chat.settings.notifiesOnBackgroundCompletion = enabled
                        guard enabled, notificationStatus != .authorized else { return }
                        Task { await requestNotificationAuthorization() }
                    }
                ))
                .disabled(notificationStatus == .denied)
                switch notificationStatus {
                case .notDetermined:
                    Button {
                        Task { await requestNotificationAuthorization() }
                    } label: {
                        Label("允许系统通知", systemImage: "bell.badge")
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("chat.notifications.request")
                case .denied:
                    Label("系统未允许通知，可在“设置”中为 CPA Quota 开启。", systemImage: "bell.slash")
                        .font(.footnote)
                        .foregroundStyle(palette.textSecondary)
                    #if os(iOS)
                    if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                        Link(destination: settingsURL) {
                            Label("前往系统设置", systemImage: "gear")
                                .frame(minHeight: 44)
                        }
                    }
                    #endif
                default:
                    EmptyView()
                }
                Toggle("自动生成对话标题", isOn: $chat.settings.generatesTitles)
            } header: {
                Text("通知与标题")
            } footer: {
                Text("离开应用后，系统通常只允许继续生成约 30 秒；超时会保存已生成的内容并标记为中断。通知只提示回复已完成，不显示对话标题或消息内容。自动标题会额外发送一次简短请求。")
            }
            .listRowBackground(palette.contentSurface)

            Section {
                if deleteAllFailed || chat.deleteAllStateUnknown {
                    Label(chat.deleteAllStateUnknown
                          ? "删除全部对话失败，且未能确认本机是否仍有剩余记录。请重试。"
                          : "部分对话未能从本机删除，列表中保留的就是仍然存在的记录。可以重试。",
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(palette.statusWarn)
                        .accessibilityIdentifier("chat.deleteAll.failed")
                }
                Button(role: .destructive) {
                    isConfirmingDeleteAll = true
                } label: {
                    Label((deleteAllFailed || chat.deleteAllStateUnknown) ? "重试删除全部对话" : "删除全部对话", systemImage: "trash")
                        .frame(minHeight: 44)
                }
                .disabled((chat.conversationSummaries.isEmpty && !deleteAllFailed && !chat.deleteAllStateUnknown) || isDeletingAll)
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
            Button("删除全部", role: .destructive) {
                isDeletingAll = true
                Task {
                    deleteAllFailed = !(await chat.deleteAllConversations())
                    isDeletingAll = false
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将移除本机保存的全部对话记录，记忆与技能保留。")
        }
        .task(id: chat.settings.searchProvider) { await refreshSearchKeyState() }
        .task { notificationStatus = await chat.notificationAuthorizationStatus() }
        .onChange(of: chat.settings.searchProvider) { _, _ in
            // A draft typed for one service must never be saved under another.
            searchKeyDraft = ""
            searchKeyRejected = false
            searchKeyRemovalFailed = false
        }
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
                    Label(chat.persistsKey ? "移除本机保存的 Key" : "停止使用此 Key", systemImage: "trash")
                        .frame(minHeight: 44)
                }
            }
        } header: {
            Text("API Key")
        } footer: {
            Text(chat.persistsKey
                 ? "读取 Key 列表使用已保存的 CPA 管理密钥；对话请求只使用所选的客户端 API Key。所选 Key 存入仅限本设备的系统钥匙串，界面只显示末尾 4 位。"
                 : "当前连接未记住，所选的客户端 API Key 只保留到断开连接，不写入系统钥匙串；界面只显示末尾 4 位。")
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
            Picker("新对话模型", selection: $chat.settings.newConversationModelStrategy) {
                Text("沿用上次选择").tag(ChatModelStrategy.mostRecent)
                Text("固定指定模型").tag(ChatModelStrategy.fixed)
            }
            if chat.settings.newConversationModelStrategy == .fixed {
                Picker("固定模型", selection: $chat.settings.defaultModelID) {
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
            }
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
                    value: searchKeyStatusLabel,
                    monospaced: false
                )
                if searchKeyRemovalFailed {
                    Label("未能移除保存的搜索 Key，旧 Key 可能仍然生效，请重试。", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(palette.statusWarn)
                } else if searchKeyStatus == .unknown {
                    Label("无法核实搜索 Key 的钥匙串状态，请稍后重试。", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(palette.statusWarn)
                }
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
                    // Capture the service and the draft together at tap time.
                    let draft = searchKeyDraft
                    Task {
                        guard chat.settings.searchProvider == provider else { return }
                        let saved = await chat.saveSearchKey(draft, for: provider)
                        guard chat.settings.searchProvider == provider else { return }
                        searchKeyRejected = !saved
                        if saved {
                            searchKeyRemovalFailed = false
                            if searchKeyDraft == draft { searchKeyDraft = "" }
                        }
                        await refreshSearchKeyState()
                    }
                } label: {
                    Label("保存搜索 Key", systemImage: "checkmark.circle")
                        .frame(minHeight: 44)
                }
                .disabled(searchKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if searchKeyStatus == .present || searchKeyStatus == .unknown || searchKeyRemovalFailed {
                    Button(role: .destructive) {
                        Task {
                            guard chat.settings.searchProvider == provider else { return }
                            let removed = await chat.removeSearchKey(for: provider)
                            guard chat.settings.searchProvider == provider else { return }
                            searchKeyRemovalFailed = !removed
                            await refreshSearchKeyState()
                        }
                    } label: {
                        Label(searchKeyRemovalFailed ? "重试移除搜索 Key" : "移除搜索 Key", systemImage: "trash")
                            .frame(minHeight: 44)
                    }
                }
            }
        } header: {
            Text("联网搜索")
        } footer: {
            Text(chat.settings.searchProvider == .serpAPI
                 ? "搜索由所选的第三方服务完成，需要该服务自己的 API Key；搜索词会发送给该服务。注意：SerpAPI 接口要求通过 URL 查询参数传递 API Key，可能出现在代理或服务端访问日志中。在对话中点按地球图标开启。"
                 : "搜索由所选的第三方服务完成，需要该服务自己的 API Key；搜索词会发送给该服务。在对话中点按地球图标开启。")
        }
        .listRowBackground(palette.contentSurface)
    }

    private func requestNotificationAuthorization() async {
        _ = await chat.requestNotificationAuthorization()
        notificationStatus = await chat.notificationAuthorizationStatus()
        if notificationStatus == .authorized {
            chat.settings.notifiesOnBackgroundCompletion = true
        }
    }

    private var searchKeyStatusLabel: String {
        switch searchKeyStatus {
        case nil: "检查中"
        case .present: "已保存"
        case .absent: "未设置"
        case .unknown: "无法核实"
        }
    }

    private func refreshSearchKeyState() async {
        guard let provider = chat.settings.searchProvider else {
            searchKeyStatus = nil
            return
        }
        searchKeyStatus = nil
        let status = await chat.searchKeyStatus(for: provider)
        guard chat.settings.searchProvider == provider else { return }
        searchKeyStatus = status
    }
}

/// A full-height editor for long free-form instructions. Edits stay local until
/// saved or dismissed so typing never triggers per-keystroke disk writes.
struct ChatTextEditorView: View {
    let title: String
    @Binding var text: String
    let footer: String
    @State private var draftText: String
    @Environment(\.brandPalette) private var palette

    init(title: String, text: Binding<String>, footer: String) {
        self.title = title
        _text = text
        self.footer = footer
        _draftText = State(initialValue: text.wrappedValue)
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $draftText)
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
        .onDisappear {
            if text != draftText {
                text = draftText
            }
        }
    }
}
#endif
