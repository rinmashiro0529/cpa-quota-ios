#if canImport(SwiftUI)
import SwiftUI
import CPAQuotaKit

public struct LoginOnboardingView: View {
    @Bindable var session: CPAQuotaSession
    @Environment(\.colorScheme) private var colorScheme
    public let showCloseButton: Bool

    public init(session: CPAQuotaSession, showCloseButton: Bool = false) {
        self.session = session
        self.showCloseButton = showCloseButton
    }

    public var body: some View {
        let palette = LiquidGlassPalette(colorScheme: colorScheme)
        let isConnecting: Bool = {
            if case .connecting = session.authState { return true }
            return false
        }()

        VStack(spacing: 20) {
            if showCloseButton {
                HStack {
                    Spacer()
                    Button {
                        session.isPresentingConnectionSheet = false
                    } label: {
                        Text("关闭")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(palette.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .liquidGlassPill(cornerRadius: 16)
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(palette.accent)
                        .frame(width: 52, height: 52)
                        .shadow(color: palette.accent.opacity(0.32), radius: 12, x: 0, y: 6)

                    Text("C")
                        .font(.system(size: 26, weight: .semibold, design: .serif))
                        .foregroundStyle(Color.white)
                }

                Text("连接个人 CPA 服务")
                    .font(.system(size: 24, weight: .semibold, design: .serif))
                    .foregroundStyle(palette.textPrimary)

                Text("只读查询已授权账号与实时额度窗口。管理凭据仅在验证成功后存入系统 Keychain（WhenUnlockedThisDeviceOnly）。")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 8)
            }

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("HTTPS 服务地址 (CPAServer)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.textSecondary)

                    TextField("https://cpa.example.com", text: $session.serverAddressDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(palette.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .liquidGlassPill(cornerRadius: 16)

                    normalizationPreviewText(palette: palette)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("管理密钥 (ManagementKey)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(palette.textSecondary)

                        Spacer()

                        Text("非普通推理 API Key")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(palette.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(palette.accentSoft)
                            )
                    }

                    SecureField("输入 CPA 管理 Bearer 密钥", text: $session.managementKeyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(palette.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .liquidGlassPill(cornerRadius: 16)

                    Text("安全承诺：ManagementKey 不可 Codable，客户端绝不将密钥写入 UserDefaults、URL、剪贴板日志或崩溃遥测。")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.textMuted)
                        .lineSpacing(2)
                }

                Toggle(isOn: $session.rememberCredentialsDraft) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("记住此连接")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(palette.textPrimary)
                        Text("连接验证成功后保存至本机 Keychain，支持随时主动移除")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.textSecondary)
                    }
                }
                .tint(palette.accent)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .liquidGlassPill(cornerRadius: 18)

                if let formError = session.connectionFormError {
                    let pres = ErrorPresentation(error: formError)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: pres.symbolName)
                                .font(.system(size: 12, weight: .semibold))
                            Text(pres.title)
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(palette.statusError)

                        Text(pres.summary)
                            .font(.system(size: 11))
                            .foregroundStyle(palette.textSecondary)

                        Text(pres.recoveryAdvice)
                            .font(.system(size: 11))
                            .foregroundStyle(palette.textMuted)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(palette.statusError.opacity(0.10))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(palette.statusError.opacity(0.28), lineWidth: 0.8)
                    )
                }

                Button {
                    Task {
                        await session.connect(
                            serverAddress: session.serverAddressDraft,
                            managementKeyInput: session.managementKeyDraft,
                            rememberInKeychain: session.rememberCredentialsDraft
                        )
                    }
                } label: {
                    HStack(spacing: 8) {
                        if isConnecting {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Color.white)
                            Text("正在验证管理密钥并读取账号…")
                        } else {
                            Image(systemName: "checkmark.shield")
                                .font(.system(size: 14, weight: .semibold))
                            Text("验证连接并进入工作台")
                        }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(palette.accent)
                            .shadow(color: palette.accent.opacity(0.28), radius: 10, x: 0, y: 4)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isConnecting)
            }
            .padding(18)
            .liquidGlassCard(cornerRadius: 28, prominent: true)
        }
    }

    @ViewBuilder
    private func normalizationPreviewText(palette: LiquidGlassPalette) -> some View {
        let trimmed = session.serverAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Text("支持根地址、反代前缀，自动还原 /management.html 或 /v0/management 后缀。")
                .font(.system(size: 10))
                .foregroundStyle(palette.textMuted)
        } else {
            switch CPAQuotaSession.previewNormalizedServer(trimmed) {
            case .success(let normalized):
                Text("规范化标识: \(normalized.identifier)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(palette.statusOK)
            case .failure(let error):
                Text(ErrorPresentation(error: error).summary)
                    .font(.system(size: 10))
                    .foregroundStyle(palette.statusError)
            }
        }
    }
}
#endif
