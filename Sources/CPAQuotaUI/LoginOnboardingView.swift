#if canImport(SwiftUI)
import SwiftUI
import CPAQuotaKit

public struct LoginOnboardingView: View {
    @Bindable var session: CPAQuotaSession
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedField: Field?
    public let showCloseButton: Bool

    private enum Field: Hashable {
        case address
        case managementKey
    }

    public init(session: CPAQuotaSession, showCloseButton: Bool = false) {
        self.session = session
        self.showCloseButton = showCloseButton
    }

    private var isConnecting: Bool {
        if case .connecting = session.authState { return true }
        return false
    }

    private var canSubmit: Bool {
        !isConnecting
            && !session.serverAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !session.managementKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var body: some View {
        let palette = BrandPalette(colorScheme: colorScheme)
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("连接个人 CPA 服务")
                        .font(QuotaTypography.brandTitle)
                        .foregroundStyle(palette.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text("查看已授权账号、额度窗口与使用情况。连接验证成功后，可将凭据保存在本机钥匙串。")
                        .font(.body)
                        .foregroundStyle(palette.textSecondary)
                }
                .padding(.vertical, 8)
            }
            .listRowBackground(palette.contentSurface)

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("HTTPS 服务地址").font(.subheadline)
                    TextField("https://cpa.example.com", text: $session.serverAddressDraft)
                        .font(QuotaTypography.data)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .address)
                        .submitLabel(.next)
                        .accessibilityLabel("HTTPS 服务地址")
                        .accessibilityIdentifier("connection.server")
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                }
                .disabled(isConnecting)
                normalizationPreview
            } header: {
                Text("服务地址")
            } footer: {
                Text("支持根地址与反向代理前缀，也可直接粘贴管理页面地址。")
            }
            .listRowBackground(palette.contentSurface)

            Section {
                SecureField("输入 CPA 管理密钥", text: $session.managementKeyDraft)
                    .font(QuotaTypography.data)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .managementKey)
                    .submitLabel(.go)
                    .accessibilityLabel("CPA 管理密钥")
                    .accessibilityIdentifier("connection.key")
                    .privacySensitive()
                    .disabled(isConnecting)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .textContentType(.password)
                    #endif
                Toggle("记住此连接", isOn: $session.rememberCredentialsDraft)
                    .disabled(isConnecting)
            } header: {
                Text("管理凭据")
            } footer: {
                Text("使用 CPA 管理密钥，普通推理 API Key 不适用于此处。记住连接后，凭据保存在本机钥匙串，可随时从连接管理中移除。")
            }
            .listRowBackground(palette.contentSurface)

            if let error = session.connectionFormError {
                Section("连接未完成") {
                    QuotaErrorNotice(presentation: ErrorPresentation(error: error))
                }
                .listRowBackground(palette.contentSurface)
            }

            Section {
                Button(action: submit) {
                    Label(isConnecting ? "正在验证连接" : "验证连接并进入工作台", systemImage: "checkmark.shield")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .quotaPrimaryButtonStyle()
                .disabled(!canSubmit)
                .accessibilityIdentifier("connection.submit")
                if isConnecting {
                    ProgressView("正在验证管理密钥并读取账号")
                        .accessibilityLabel("正在连接，请稍候")
                }
            }
            .listRowBackground(palette.contentSurface)
        }
        .formStyle(.grouped)
        .scrollDismissesKeyboard(.interactively)
        .scrollContentBackground(.hidden)
        .background(BrandCanvasBackground())
        .navigationTitle(showCloseButton ? "更新连接" : "欢迎使用 CPA Quota")
        .onSubmit {
            if focusedField == .address {
                focusedField = .managementKey
            } else if canSubmit {
                submit()
            }
        }
        .toolbar {
            if showCloseButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        session.isPresentingConnectionSheet = false
                    }
                    .accessibilityLabel("关闭连接设置")
                }
            }
        }
    }

    @ViewBuilder
    private var normalizationPreview: some View {
        let trimmed = session.serverAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            switch CPAQuotaSession.previewNormalizedServer(trimmed) {
            case .success(let normalized):
                QuotaLabeledValue(title: "将连接至", value: normalized.identifier)
                    .textSelection(.enabled)
            case .failure(let error):
                Label(ErrorPresentation(error: error).summary, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func submit() {
        guard canSubmit else { return }
        focusedField = nil
        Task {
            await session.connect(
                serverAddress: session.serverAddressDraft,
                managementKeyInput: session.managementKeyDraft,
                rememberInKeychain: session.rememberCredentialsDraft
            )
        }
    }
}
#endif
