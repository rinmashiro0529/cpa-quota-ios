#if canImport(SwiftUI)
import SwiftUI
import CPAQuotaKit

public struct ConnectionManagementTabView: View {
    @Bindable var session: CPAQuotaSession
    @Environment(\.colorScheme) private var colorScheme
    @State private var isConfirmingForget = false

    public init(session: CPAQuotaSession) {
        self.session = session
    }

    public var body: some View {
        let palette = LiquidGlassPalette(colorScheme: colorScheme)
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("CPAServer 与 Keychain 凭据状态")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                Text("连接与会话管理")
                    .font(.system(size: 26, weight: .semibold, design: .serif))
                    .foregroundStyle(palette.textPrimary)
            }
            .padding(.horizontal, 2)

            serverConnectionCard(palette: palette)

            appearanceAndPreferencesCard(palette: palette)

            securityBoundaryCard(palette: palette)

            actionButtonsSection(palette: palette)
        }
        .confirmationDialog(
            "确认忘记此 CPA 连接？",
            isPresented: $isConfirmingForget,
            titleVisibility: .visible
        ) {
            Button("从 Keychain 移除管理密钥并断开", role: .destructive) {
                Task { await session.forgetCurrentConnection() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("该操作将删除保存在本机 Keychain 中的管理密钥，并清空内存中的账号与额度快照。")
        }
    }

    @ViewBuilder
    private func serverConnectionCard(palette: LiquidGlassPalette) -> some View {
        let storageError = session.connectionFormError?.kind == .secureStorageFailure
            || session.connectionFormError?.kind == .secureStorageUnavailable
        let rememberedServer = session.savedServer
        let displayedServer = session.currentServer ?? rememberedServer
        let storageStatus: String = {
            if storageError { return "存储状态待确认（上次操作未完成）" }
            switch session.authState {
            case .connected:
                return session.isRememberedInKeychain
                    ? "已保存 (WhenUnlockedThisDeviceOnly)" : "内存临时会话 (未写入 Keychain)"
            case .connecting:
                return "正在验证，尚未确认本次保存状态"
            case .unconfigured:
                return rememberedServer != nil ? "有已保存配置，当前未连接" : "尚未保存连接"
            }
        }()
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("规范化服务标识 (server.identifier)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                Spacer()
                Text(session.currentServer != nil ? "HTTPS 已锁定"
                    : (rememberedServer != nil ? "已保存，未连接" : "未连接"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(session.currentServer != nil ? palette.statusOK : palette.statusWarn)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill((session.currentServer != nil ? palette.statusOK : palette.statusWarn).opacity(0.14))
                    )
            }

            Text(displayedServer?.identifier ?? "尚未配置 CPA 服务地址")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(palette.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .liquidGlassPill(cornerRadius: 14)

            infoRow(
                label: "Keychain 凭据保存状态",
                value: storageStatus,
                palette: palette
            )

            infoRow(
                label: "管理密钥脱敏状态",
                value: session.currentServer != nil ? "<redacted management key>" : "未载入",
                palette: palette
            )

            if let error = session.connectionFormError {
                let presentation = ErrorPresentation(error: error)
                VStack(alignment: .leading, spacing: 4) {
                    Text(presentation.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.statusError)
                    Text(presentation.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textSecondary)
                    Text(presentation.recoveryAdvice)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textMuted)
                }
            } else if let message = session.statusBannerMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.statusWarn)
            }
        }
        .padding(16)
        .liquidGlassCard(cornerRadius: 26)
    }

    @ViewBuilder
    private func appearanceAndPreferencesCard(palette: LiquidGlassPalette) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("界面外观与展示偏好")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.textPrimary)

            VStack(alignment: .leading, spacing: 6) {
                Text("深浅色外观模式")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.textSecondary)

                HStack(spacing: 6) {
                    ForEach(CPAThemeMode.allCases) { mode in
                        let isSelected = session.themeMode == mode
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                session.themeMode = mode
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: mode.symbolName)
                                    .font(.system(size: 11, weight: .semibold))
                                Text(mode.title)
                                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                            }
                            .foregroundStyle(isSelected ? Color.white : palette.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(palette.accent)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .liquidGlassPill(cornerRadius: 16)

                Text(session.themeMode.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(palette.textMuted)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("额度进度条主视角")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.textSecondary)

                HStack(spacing: 6) {
                    ForEach(QuotaDisplayMode.allCases) { mode in
                        let isSelected = session.displayMode == mode
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                session.displayMode = mode
                            }
                        } label: {
                            Text(mode.title)
                                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                                .foregroundStyle(isSelected ? Color.white : palette.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background {
                                    if isSelected {
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(palette.accent)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .liquidGlassPill(cornerRadius: 16)
            }

            Toggle(isOn: $session.maskEmail) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("账号邮箱局部脱敏")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                    Text("开启后默认隐藏邮箱用户名中间字符，防止截屏或旁观泄露")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.textSecondary)
                }
            }
            .tint(palette.accent)
        }
        .padding(16)
        .liquidGlassCard(cornerRadius: 26)
    }

    @ViewBuilder
    private func securityBoundaryCard(palette: LiquidGlassPalette) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("只读查询与权限边界说明")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.textPrimary)

            Text("本客户端仅发起只读账号与额度查询，不包含 OAuth 登录、账号启停、额度重置或修改 CPA 配置。请注意：CPA 管理密钥本身仍具备服务端原有管理权限；单个上游账号鉴权失效（upstreamUnauthorized）不代表 CPA 管理密钥失效。")
                .font(.system(size: 11))
                .foregroundStyle(palette.textSecondary)
                .lineSpacing(2.5)
        }
        .padding(15)
        .liquidGlassCard(cornerRadius: 24)
    }

    @ViewBuilder
    private func actionButtonsSection(palette: LiquidGlassPalette) -> some View {
        VStack(spacing: 10) {
            Button {
                session.isPresentingConnectionSheet = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 13, weight: .semibold))
                    Text("更换服务地址或更新管理密钥")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .liquidGlassCard(cornerRadius: 18)
            }
            .buttonStyle(.plain)

            if session.currentServer != nil || session.savedServer != nil || session.connectionFormError != nil {
                Button {
                    isConfirmingForget = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .semibold))
                        Text("忘记此连接 (从 Keychain 移除凭据)")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.statusError)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(palette.statusError.opacity(0.11))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(palette.statusError.opacity(0.26), lineWidth: 0.9)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func infoRow(label: String, value: String, palette: LiquidGlassPalette) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(palette.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(palette.textPrimary)
        }
    }
}
#endif
