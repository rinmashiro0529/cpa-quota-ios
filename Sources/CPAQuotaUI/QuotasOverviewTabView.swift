#if canImport(SwiftUI)
import SwiftUI
import CPAQuotaKit

public struct QuotasOverviewTabView: View {
    @Bindable var session: CPAQuotaSession
    @Environment(\.colorScheme) private var colorScheme

    public init(session: CPAQuotaSession) {
        self.session = session
    }

    public var body: some View {
        let palette = LiquidGlassPalette(colorScheme: colorScheme)
        VStack(alignment: .leading, spacing: 14) {
            headerSection(palette: palette)

            if let globalError = session.store?.error {
                managementErrorBanner(error: globalError, palette: palette)
            }

            if let capWarning = session.store?.capabilityWarning {
                capabilityWarningBanner(warning: capWarning, palette: palette)
            }

            if let statusMessage = session.statusBannerMessage {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.statusWarn)
                    Text(statusMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textSecondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .liquidGlassCard(cornerRadius: 20)
            }

            filterPillsBar(palette: palette)

            if session.accounts.isEmpty {
                emptyAccountsStateCard(palette: palette)
            } else if session.filteredAccounts.isEmpty {
                emptyFilterMatchCard(palette: palette)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(session.filteredAccounts) { account in
                        AccountQuotaCardView(
                            account: account,
                            record: session.records[account.id],
                            displayMode: session.displayMode,
                            maskEmail: session.maskEmail
                        ) {
                            session.selectedAccountIDForDetail = account.id
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func headerSection(palette: LiquidGlassPalette) -> some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text("只读额度工作台 · 流式同步")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                Text("账号额度总览")
                    .font(.system(size: 26, weight: .semibold, design: .serif))
                    .foregroundStyle(palette.textPrimary)
            }

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    session.displayMode = (session.displayMode == .remaining) ? .used : .remaining
                }
            } label: {
                HStack(spacing: 4) {
                    Text("主视角:")
                        .foregroundStyle(palette.textSecondary)
                    Text(session.displayMode.shortTitle)
                        .fontWeight(.semibold)
                        .foregroundStyle(palette.accent)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .liquidGlassPill(cornerRadius: 16)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private func managementErrorBanner(error: CPAError, palette: LiquidGlassPalette) -> some View {
        let pres = ErrorPresentation(error: error, records: session.records)
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: pres.symbolName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.statusError)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(pres.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.statusError)

                        Text(pres.summary)
                            .font(.system(size: 11))
                            .foregroundStyle(palette.textSecondary)
                            .lineSpacing(2)

                        Text(pres.recoveryAdvice)
                            .font(.system(size: 11))
                            .foregroundStyle(palette.textMuted)
                            .lineSpacing(2)
                    }

                    Spacer(minLength: 4)

                    if let remaining = pres.remainingCooldownSeconds(at: context.date) {
                        Text("\(remaining)s")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(palette.statusWarn)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(palette.statusWarn.opacity(0.16))
                            )
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        session.isPresentingConnectionSheet = true
                    } label: {
                        Text("更新管理密钥或连接")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(palette.accent)
                            )
                    }
                    .buttonStyle(.plain)

                    if pres.kind != .managementUnauthorized,
                       pres.kind != .managementForbidden,
                       pres.remainingCooldownSeconds(at: context.date) == nil {
                        Button {
                            Task { await session.loadInitialIfNeeded() }
                        } label: {
                            Text("重新验证连接")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(palette.textPrimary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .liquidGlassPill(cornerRadius: 12)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(14)
            .liquidGlassCard(cornerRadius: 22)
        }
    }

    @ViewBuilder
    private func capabilityWarningBanner(warning: CPAError, palette: LiquidGlassPalette) -> some View {
        let pres = ErrorPresentation(error: warning, hasPreservedSnapshot: true)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 12, weight: .semibold))
                Text("可选额度能力发现告警 (\(warning.kind.rawValue))")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(palette.statusWarn)

            Text("探测 /v0/management/quota/providers 出现非阻塞异常：\(pres.summary) 已有账号列表与内置读取器（如 Codex）仍可正常使用，管理密钥无需删除。")
                .font(.system(size: 11))
                .foregroundStyle(palette.textSecondary)
                .lineSpacing(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassCard(cornerRadius: 20)
    }

    @ViewBuilder
    private func filterPillsBar(palette: LiquidGlassPalette) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(AccountFilterCategory.allCases) { category in
                    let isSelected = session.selectedFilter == category
                    let labelText: String = {
                        if category == .all {
                            return "全部 (\(session.accounts.count))"
                        }
                        return category.title
                    }()

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            session.selectedFilter = category
                        }
                    } label: {
                        Text(labelText)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? Color.white : palette.textSecondary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                            .background {
                                if isSelected {
                                    Capsule(style: .continuous)
                                        .fill(palette.accent)
                                }
                            }
                            .modifier(ConditionalPillModifier(applyPill: !isSelected))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func emptyAccountsStateCard(palette: LiquidGlassPalette) -> some View {
        let failed = session.store?.error != nil
        let title = session.isBusy ? "正在读取服务中的账号列表…"
            : (failed ? "暂时无法读取账号列表" : "服务中暂无授权账号")
        let detail = session.isBusy ? "正在验证连接并读取 auth-files，尚不能判断服务中是否存在账号。"
            : (failed ? "本次未能成功读取账号列表，不能据此判断服务中没有账号。请查看错误说明后重试。"
                : "已成功连接 CPA 管理接口，但 auth-files 尚未返回任何账号记录。这属于有效的空状态，不代表管理密钥失效。")
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(palette.textSecondary)
                .frame(width: 44, height: 44)
                .liquidGlassPill(cornerRadius: 16)

            Text(title)
                .font(.system(size: 18, weight: .semibold, design: .serif))
                .foregroundStyle(palette.textPrimary)

            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .liquidGlassCard(cornerRadius: 28)
    }

    @ViewBuilder
    private func emptyFilterMatchCard(palette: LiquidGlassPalette) -> some View {
        VStack(spacing: 8) {
            Text("当前筛选条件下没有匹配账号")
                .font(.system(size: 15, weight: .semibold, design: .serif))
                .foregroundStyle(palette.textPrimary)
            Text("可切换顶部筛选胶囊查看其他平台或状态的账号。")
                .font(.system(size: 12))
                .foregroundStyle(palette.textSecondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .liquidGlassCard(cornerRadius: 24)
    }
}

private struct ConditionalPillModifier: ViewModifier {
    let applyPill: Bool

    func body(content: Content) -> some View {
        if applyPill {
            content.liquidGlassPill(cornerRadius: 18)
        } else {
            content
        }
    }
}

public struct AccountQuotaCardView: View {
    public let account: CPAAccount
    public let record: QuotaRecord?
    public let displayMode: QuotaDisplayMode
    public let maskEmail: Bool
    public let onTap: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    public init(
        account: CPAAccount,
        record: QuotaRecord?,
        displayMode: QuotaDisplayMode,
        maskEmail: Bool,
        onTap: @escaping () -> Void
    ) {
        self.account = account
        self.record = record
        self.displayMode = displayMode
        self.maskEmail = maskEmail
        self.onTap = onTap
    }

    public var body: some View {
        let palette = LiquidGlassPalette(colorScheme: colorScheme)
        let snapshot = record?.snapshot
        let error = record?.error

        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 12) {
                headerRow(snapshot: snapshot, palette: palette)

                if let snapshot {
                    if error != nil {
                        preservedSnapshotNotice(palette: palette)
                    }

                    if !snapshot.windows.isEmpty {
                        VStack(spacing: 10) {
                            ForEach(snapshot.windows) { window in
                                windowRow(window: WindowPresentation(window: window), palette: palette)
                            }
                        }
                    }

                    if !snapshot.metrics.isEmpty {
                        metricsGrid(metrics: snapshot.metrics.map(MetricPresentation.init), palette: palette)
                    }

                    if snapshot.windows.isEmpty && snapshot.metrics.isEmpty && snapshot.credits == nil {
                        Text("该账号已成功响应，但上游未返回可识别的百分比窗口或摘要指标。")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.textSecondary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .liquidGlassPill(cornerRadius: 14)
                    }

                    if let creditsPres = CreditsPresentation(credits: snapshot.credits) {
                        HStack {
                            Text(creditsPres.title)
                                .font(.system(size: 11))
                                .foregroundStyle(palette.textSecondary)
                            Spacer()
                            Text(creditsPres.valueText)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(palette.textPrimary)
                        }
                        .padding(.horizontal, 4)
                    }
                }

                if let error {
                    isolatedErrorBanner(
                        error: error,
                        hasPreservedSnapshot: snapshot != nil,
                        palette: palette
                    )
                }
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlassCard(cornerRadius: 26)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func headerRow(snapshot: QuotaSnapshot?, palette: LiquidGlassPalette) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(account.provider.uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(palette.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(palette.accentSoft)
                        )

                    Text(QuotaFormatter.maskEmail(account.displayName, enabled: maskEmail))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                }

                HStack(spacing: 4) {
                    Text(QuotaFormatter.maskEmail(account.email, enabled: maskEmail))
                    if let plan = snapshot?.plan ?? account.plan, !plan.isEmpty {
                        Text("·")
                        Text(plan)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 4) {
                if snapshot != nil && (account.isDisabled || account.isUnavailable) {
                    Text(account.isDisabled ? "已停用" : "当前不可用")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(palette.statusWarn)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .liquidGlassPill(cornerRadius: 12)
                }
                freshnessPill(snapshot: snapshot, palette: palette)
            }
        }
    }

    @ViewBuilder
    private func freshnessPill(snapshot: QuotaSnapshot?, palette: LiquidGlassPalette) -> some View {
        if let snapshot {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                let badge = QuotaFormatter.freshnessBadge(for: snapshot, now: context.date)
                let tint = badge.isStale ? palette.statusWarn : palette.statusOK
                Text(badge.badgeText)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(tint.opacity(0.14))
                    )
            }
        } else if account.isDisabled {
            Text("已停用 · 未查询")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(palette.textMuted)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .liquidGlassPill(cornerRadius: 12)
        } else if account.isUnavailable {
            Text("当前不可用 · 无快照")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(palette.statusWarn)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .liquidGlassPill(cornerRadius: 12)
        } else {
            Text("无可用快照")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(palette.statusWarn)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(palette.statusWarn.opacity(0.14))
                )
        }
    }

    @ViewBuilder
    private func preservedSnapshotNotice(palette: LiquidGlassPalette) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 11, weight: .semibold))
            Text("历史成功快照保留 · 非本次刷新新结果")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(palette.statusWarn)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(palette.statusWarn.opacity(0.12))
        )
    }

    @ViewBuilder
    private func windowRow(window: WindowPresentation, palette: LiquidGlassPalette) -> some View {
        let barColor: Color = {
            if window.isOverQuota { return palette.statusError }
            if window.isLowRemainingWarning { return palette.statusWarn }
            return palette.accent
        }()

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(window.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)

                Text(window.durationText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(palette.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(palette.trackBackground)
                    )

                Spacer(minLength: 4)

                Text(window.primaryPercentageText(for: displayMode))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(barColor)
                    .contentTransition(.numericText())
            }

            if let fraction = window.progressBarFraction(for: displayMode) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(palette.trackBackground)
                        Capsule(style: .continuous)
                            .fill(barColor)
                            .frame(width: max(4, geo.size.width * fraction))
                    }
                }
                .frame(height: 7)
            }

            HStack {
                Text(window.secondaryComparisonText)
                    .font(.system(size: 10, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(palette.textSecondary)

                Spacer()

                Text(window.resetTimeText())
                    .font(.system(size: 10, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(palette.textSecondary)
            }
        }
        .padding(11)
        .liquidGlassPill(cornerRadius: 16)
    }

    @ViewBuilder
    private func metricsGrid(metrics: [MetricPresentation], palette: LiquidGlassPalette) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("标准化摘要指标 (Summary-Only)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                Spacer()
                Text("\(metrics.count) 项指标")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(palette.textMuted)
            }

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                spacing: 8
            ) {
                ForEach(metrics) { metric in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(metric.label)
                            .font(.system(size: 10))
                            .foregroundStyle(palette.textSecondary)
                            .lineLimit(1)

                        Text(metric.formattedValue)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(palette.textPrimary)
                            .lineLimit(1)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .liquidGlassPill(cornerRadius: 14)
                }
            }
        }
    }

    @ViewBuilder
    private func isolatedErrorBanner(
        error: CPAError,
        hasPreservedSnapshot: Bool,
        palette: LiquidGlassPalette
    ) -> some View {
        let pres = ErrorPresentation(error: error, hasPreservedSnapshot: hasPreservedSnapshot)
        let tint: Color = {
            switch pres.severity {
            case .neutral: return palette.textSecondary
            case .warning: return palette.statusWarn
            case .critical: return palette.statusError
            }
        }()

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: pres.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                Text("\(pres.title) (\(error.kind.rawValue))")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(tint)

            Text(pres.summary)
                .font(.system(size: 10))
                .foregroundStyle(palette.textSecondary)
                .lineSpacing(1.5)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(tint.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tint.opacity(0.24), lineWidth: 0.8)
        )
    }
}
#endif
