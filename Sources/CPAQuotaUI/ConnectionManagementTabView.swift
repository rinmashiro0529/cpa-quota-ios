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
        let palette = BrandPalette(colorScheme: colorScheme)
        Form {
            Section {
                QuotaLabeledValue(
                    title: "CPA 服务",
                    value: (session.currentServer ?? session.savedServer)?.identifier ?? "尚未配置"
                )
                .textSelection(.enabled)
                QuotaLabeledValue(title: "连接状态", value: connectionStatus, monospaced: false)
                QuotaLabeledValue(title: "凭据保存", value: storageStatus, monospaced: false)
                if let error = session.connectionFormError {
                    QuotaErrorNotice(presentation: ErrorPresentation(error: error))
                } else if let message = session.statusBannerMessage {
                    Label(message, systemImage: "info.circle")
                        .font(.subheadline)
                        .foregroundStyle(palette.textSecondary)
                }
                Button {
                    session.isPresentingConnectionSheet = true
                } label: {
                    Label("更换服务地址或更新管理密钥", systemImage: "key")
                        .frame(minHeight: 44)
                }
                .quotaPrimaryButtonStyle()
            } header: {
                Text("当前连接").font(QuotaTypography.brandHeadline)
            }
            .listRowBackground(palette.contentSurface)

            Section {
                Picker("外观", selection: $session.themeMode) {
                    ForEach(CPAThemeMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbolName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.appearance")
                .accessibilityValue(session.themeMode.title)
                Text(session.themeMode.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(palette.textSecondary)
                Picker("额度显示", selection: $session.displayMode) {
                    ForEach(QuotaDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("外观与显示")
            } footer: {
                Text("文字大小、减少透明度与减少动态效果遵循系统辅助功能设置。")
            }
            .listRowBackground(palette.contentSurface)

            Section {
                Toggle("账号邮箱局部脱敏", isOn: $session.maskEmail)
                    .accessibilityIdentifier("settings.maskEmail")
                Toggle("允许小组件显示配额", isOn: $session.sharesQuotaWithWidgets)
                    .accessibilityIdentifier("settings.widgetSharing")
                if let notice = session.widgetSharingNotice {
                    Label(notice, systemImage: "info.circle")
                        .font(.subheadline)
                        .foregroundStyle(palette.textSecondary)
                }
            } header: {
                Text("隐私")
            } footer: {
                Text("邮箱脱敏隐藏用户名中间字符，应用内显示与读屏使用相同结果。小组件共享默认关闭；开启后仅共享安全别名与最近读数，不共享管理密钥。")
            }
            .listRowBackground(palette.contentSurface)

            Section {
                DisclosureGroup("只读查询与权限范围") {
                    Text("应用可读取账号、额度与使用情况，不提供账号启停、额度重置或 CPA 配置修改。管理密钥仍保有服务端授予的管理权限，请妥善保存。")
                        .font(.body)
                        .foregroundStyle(palette.textSecondary)
                    Text("单个上游账号鉴权失败，不等于 CPA 管理密钥失效。请按该账号的错误提示恢复，无需删除其他账号的连接。")
                        .font(.subheadline)
                        .foregroundStyle(palette.textSecondary)
                }
                DisclosureGroup("本机凭据保护") {
                    Text("记住连接后，管理密钥存入仅限本设备、解锁时可用的系统钥匙串。应用不会在此显示密钥原文。")
                        .font(.body)
                        .foregroundStyle(palette.textSecondary)
                    QuotaLabeledValue(
                        title: "密钥显示",
                        value: session.currentServer != nil ? "已隐藏" : "未载入",
                        monospaced: false
                    )
                }
            }
            .listRowBackground(palette.contentSurface)

            if session.currentServer != nil || session.savedServer != nil || session.connectionFormError != nil {
                Section {
                    Button(role: .destructive) {
                        isConfirmingForget = true
                    } label: {
                        Label("忘记此连接", systemImage: "trash")
                            .frame(minHeight: 44)
                    }
                } footer: {
                    Text("移除本机保存的管理密钥，并清空本次会话中的账号与额度快照。")
                }
                .listRowBackground(palette.contentSurface)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(BrandCanvasBackground())
        .navigationTitle("连接与设置")
        .tint(palette.actionTint)
        .confirmationDialog(
            "确认忘记此 CPA 连接？",
            isPresented: $isConfirmingForget,
            titleVisibility: .visible
        ) {
            Button("移除管理密钥并断开", role: .destructive) {
                Task { await session.forgetCurrentConnection() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除保存在本机钥匙串中的管理密钥，并清空内存中的账号与额度快照。")
        }
    }

    private var connectionStatus: String {
        switch session.authState {
        case .connecting: "正在验证连接"
        case .connected: "已通过 HTTPS 连接"
        case .unconfigured: session.savedServer != nil ? "已保存，当前未连接" : "未连接"
        }
    }

    private var storageStatus: String {
        if session.connectionFormError?.kind == .secureStorageFailure
            || session.connectionFormError?.kind == .secureStorageUnavailable {
            return "上次存储操作未完成，状态待确认"
        }
        switch session.authState {
        case .connected:
            return session.isRememberedInKeychain ? "已保存至本机钥匙串" : "临时会话，未写入钥匙串"
        case .connecting:
            return "验证完成后确认保存状态"
        case .unconfigured:
            return session.savedServer != nil ? "有已保存配置，当前未连接" : "尚未保存连接"
        }
    }
}
#endif
