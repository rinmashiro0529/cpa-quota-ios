#if canImport(SwiftUI)
import SwiftUI
import CPAQuotaKit

public struct AccountsDiagnosticsTabView: View {
    @Bindable var session: CPAQuotaSession
    @Environment(\.colorScheme) private var colorScheme

    public init(session: CPAQuotaSession) {
        self.session = session
    }

    public var body: some View {
        let palette = LiquidGlassPalette(colorScheme: colorScheme)
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("CPAQuotaStore.accounts 清单与读取能力")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                Text("账号与健康诊断")
                    .font(.system(size: 26, weight: .semibold, design: .serif))
                    .foregroundStyle(palette.textPrimary)
            }
            .padding(.horizontal, 2)

            capabilityOverviewCard(palette: palette)

            if session.accounts.isEmpty {
                VStack(spacing: 8) {
                    Text("当前无已加载的授权账号")
                        .font(.system(size: 15, weight: .semibold, design: .serif))
                        .foregroundStyle(palette.textPrimary)
                    Text("当 CPA 服务中存在授权账号时，此处将展示其平台、启用状态及读取器路由。")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(22)
                .frame(maxWidth: .infinity)
                .liquidGlassCard(cornerRadius: 24)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(session.accounts) { account in
                        accountDiagnosticRow(account: account, palette: palette)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func capabilityOverviewCard(palette: LiquidGlassPalette) -> some View {
        let globalError = session.store?.error
        let hasWarning = session.store?.capabilityWarning != nil
        let isPending = session.store == nil || session.isBusy
        let symbol = globalError != nil ? "exclamationmark.triangle"
            : (isPending ? "hourglass" : (hasWarning ? "exclamationmark.circle" : "checkmark.seal"))
        let status = globalError != nil ? "读取失败"
            : (isPending ? "尚未完成读取" : (hasWarning ? "可选能力告警" : "读取通道正常"))
        let tint = globalError != nil ? palette.statusError
            : ((isPending || hasWarning) ? palette.statusWarn : palette.statusOK)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                    Text("额度读取器支持矩阵")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                }
                Spacer()
                Text(status)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(tint)
            }

            Text("内置支持 Codex (wham/usage 代理)、CPA 插件标准化额度 (quota/fetch) 及 xAI billing 结构归一化。其他未实现平台明确标记为未支持，不伪造可用额度。")
                .font(.system(size: 11))
                .foregroundStyle(palette.textSecondary)
                .lineSpacing(2)

            if let globalError {
                let presentation = ErrorPresentation(error: globalError)
                Text("当前异常: \(presentation.title) — \(presentation.summary)")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.statusError)
                    .padding(.top, 2)
            }

            if let warning = session.store?.capabilityWarning {
                let pres = ErrorPresentation(error: warning)
                Text("当前告警: \(pres.title) — \(pres.summary)")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.statusWarn)
                    .padding(.top, 2)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassCard(cornerRadius: 24)
    }

    @ViewBuilder
    private func accountDiagnosticRow(account: CPAAccount, palette: LiquidGlassPalette) -> some View {
        let record = session.records[account.id]
        let error = record?.error

        Button {
            session.selectedAccountIDForDetail = account.id
        } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("#\(account.authIndex ?? "-")")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(palette.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(palette.trackBackground)
                            )

                        Text(account.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.textPrimary)
                            .lineLimit(1)
                    }

                    Text("\(account.provider) · \(QuotaFormatter.maskEmail(account.email, enabled: session.maskEmail))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)

                    Text("服务状态: \(account.status)")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.textMuted)
                        .lineLimit(1)

                    Text("读取通道: \(account.supportsPluginQuota ? "CPA 插件标准化接口 (quota/fetch)" : "内置平台专用读取器")")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.textMuted)
                }

                Spacer(minLength: 6)

                VStack(alignment: .trailing, spacing: 6) {
                    statusTag(account: account, error: error, palette: palette)

                    Text("查看明细")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.accent)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlassCard(cornerRadius: 22)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func statusTag(account: CPAAccount, error: CPAError?, palette: LiquidGlassPalette) -> some View {
        if account.isDisabled {
            Text("已停用 (isDisabled)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(palette.textMuted)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .liquidGlassPill(cornerRadius: 10)
        } else if account.isUnavailable {
            Text("当前不可用")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(palette.statusWarn)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule(style: .continuous)
                        .fill(palette.statusWarn.opacity(0.14))
                )
        } else if let error {
            Text(error.kind.rawValue)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(palette.statusError)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule(style: .continuous)
                        .fill(palette.statusError.opacity(0.14))
                )
        } else {
            Text("已启用")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(palette.statusOK)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule(style: .continuous)
                        .fill(palette.statusOK.opacity(0.14))
                )
        }
    }
}
#endif
