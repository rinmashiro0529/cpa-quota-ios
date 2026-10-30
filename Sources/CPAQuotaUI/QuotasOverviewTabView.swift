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
        let palette = BrandPalette(colorScheme: colorScheme)
        List {
            Section {
                Picker("显示比例", selection: $session.displayMode) {
                    ForEach(QuotaDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Picker("账号筛选", selection: $session.selectedFilter) {
                    ForEach(AccountFilterCategory.allCases) { category in
                        Text(category == .all ? "全部（\(session.accounts.count)）" : category.title)
                            .tag(category)
                    }
                }
            } header: {
                Text("只读配额工作台").font(QuotaTypography.brandHeadline)
            } footer: {
                Text("不同额度窗口相互独立。未知比例、旧快照与读取错误会分别标明。")
            }
            .listRowBackground(palette.contentSurface)

            if let error = session.store?.error {
                Section("连接需要处理") {
                    let presentation = ErrorPresentation(error: error, records: session.records)
                    QuotaErrorNotice(presentation: presentation)
                    managementRecovery(presentation: presentation)
                }
                .listRowBackground(palette.contentSurface)
            }
            if let warning = session.store?.capabilityWarning {
                Section("部分读取能力受限") {
                    QuotaErrorNotice(
                        presentation: ErrorPresentation(error: warning, hasPreservedSnapshot: true)
                    )
                    Text("可选能力发现暂未完成。已读取的账号与内置读取器仍可使用，不需要删除管理密钥。")
                        .font(.subheadline)
                        .foregroundStyle(palette.textSecondary)
                }
                .listRowBackground(palette.contentSurface)
            }
            if let message = session.statusBannerMessage {
                Section {
                    Label(message, systemImage: "info.circle")
                        .font(.subheadline)
                        .foregroundStyle(palette.textSecondary)
                }
                .listRowBackground(palette.contentSurface)
            }

            if session.accounts.isEmpty {
                Section {
                    emptyState
                }
                .listRowBackground(palette.contentSurface)
            } else if session.filteredAccounts.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("没有匹配的账号", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text("调整账号筛选即可查看其他平台或状态。")
                    } actions: {
                        Button("显示全部账号") { session.selectedFilter = .all }
                            .quotaSecondaryButtonStyle()
                    }
                }
                .listRowBackground(palette.contentSurface)
            } else {
                ForEach(session.filteredAccounts) { account in
                    Section {
                        AccountQuotaCardView(
                            account: account,
                            record: session.records[account.id],
                            displayMode: session.displayMode,
                            maskEmail: session.maskEmail
                        ) {
                            session.selectedAccountIDForDetail = account.id
                        }
                    }
                    .listRowBackground(palette.contentSurface)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(BrandCanvasBackground())
        .navigationTitle("额度总览")
        .refreshable { await session.refreshAll(force: true) }
    }

    @ViewBuilder
    private var emptyState: some View {
        if session.isBusy {
            VStack(alignment: .leading, spacing: 12) {
                ProgressView("正在读取账号列表")
                Text("连接验证完成前，尚不能判断服务中是否存在账号。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
        } else if session.store?.error != nil {
            ContentUnavailableView {
                Label("暂时无法读取账号", systemImage: "exclamationmark.triangle")
            } description: {
                Text("本次读取未成功，不能据此判断服务中没有账号。请按连接错误提示恢复。")
            }
        } else {
            ContentUnavailableView {
                Label("服务中暂无授权账号", systemImage: "person.crop.circle.badge.questionmark")
            } description: {
                Text("管理接口成功返回了空列表。管理密钥仍然有效，添加授权账号后可刷新查看。")
            }
        }
    }

    @ViewBuilder
    private func managementRecovery(presentation: ErrorPresentation) -> some View {
        if let retryAfter = presentation.retryAfter, retryAfter > .now {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                recoveryActions(presentation: presentation, at: context.date)
            }
        } else {
            recoveryActions(presentation: presentation, at: .now)
        }
    }

    private func recoveryActions(presentation: ErrorPresentation, at date: Date) -> some View {
        let remaining = presentation.remainingCooldownSeconds(at: date)
        return NativeGlassActionGroup {
            VStack(alignment: .leading, spacing: 12) {
                if let remaining {
                    Label("请等待 \(remaining) 秒后重试", systemImage: "hourglass")
                        .font(.subheadline)
                        .monospacedDigit()
                }
                Button {
                    session.isPresentingConnectionSheet = true
                } label: {
                    Label("更新管理密钥或连接", systemImage: "key")
                        .frame(minHeight: 44)
                }
                .quotaPrimaryButtonStyle()
                if presentation.kind != .managementUnauthorized,
                   presentation.kind != .managementForbidden,
                   remaining == nil {
                    Button {
                        Task { await session.loadInitialIfNeeded() }
                    } label: {
                        Label("重新验证连接", systemImage: "arrow.clockwise")
                            .frame(minHeight: 44)
                    }
                    .quotaSecondaryButtonStyle()
                    .disabled(session.isBusy)
                }
            }
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
        let palette = BrandPalette(colorScheme: colorScheme)
        let snapshot = record?.snapshot
        VStack(alignment: .leading, spacing: 16) {
            Button(action: onTap) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(QuotaFormatter.maskEmail(account.displayName, enabled: maskEmail))
                            .font(QuotaTypography.brandTitle)
                            .foregroundStyle(palette.textPrimary)
                        Text(account.provider.uppercased())
                            .font(QuotaTypography.dataDetail)
                            .foregroundStyle(palette.textSecondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(palette.textSecondary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("查看账号详情与恢复操作")
            .accessibilityIdentifier("quota.account.\(account.id)")

            Text(QuotaFormatter.maskEmail(account.email, enabled: maskEmail))
                .font(QuotaTypography.dataDetail)
                .foregroundStyle(palette.textSecondary)
                .privacySensitive()
            if let plan = snapshot?.plan ?? account.plan, !plan.isEmpty {
                QuotaLabeledValue(title: "套餐", value: plan, monospaced: false)
            }
            if account.isDisabled || account.isUnavailable {
                Label(account.isDisabled ? "账号已停用" : "账号当前不可用", systemImage: "pause.circle")
                    .font(.subheadline)
                    .foregroundStyle(palette.textPrimary)
            }
            if let snapshot {
                QuotaFreshnessLabel(snapshot: snapshot)
                if record?.error != nil {
                    Label("保留上次成功快照，非本次刷新结果", systemImage: "clock.arrow.circlepath")
                        .font(.subheadline)
                        .foregroundStyle(palette.textPrimary)
                }
                ForEach(snapshot.windows) { window in
                    Divider()
                    QuotaWindowView(window: WindowPresentation(window: window), displayMode: displayMode)
                }
                if !snapshot.metrics.isEmpty {
                    Divider()
                    Text("上游摘要指标").font(.headline)
                    ForEach(snapshot.metrics.map(MetricPresentation.init)) { metric in
                        QuotaLabeledValue(title: metric.label, value: metric.formattedValue)
                    }
                }
                if let credits = CreditsPresentation(credits: snapshot.credits) {
                    Divider()
                    QuotaLabeledValue(title: credits.title, value: credits.valueText)
                    Text(credits.footnote)
                        .font(.caption)
                        .foregroundStyle(palette.textSecondary)
                }
                if snapshot.windows.isEmpty && snapshot.metrics.isEmpty && snapshot.credits == nil {
                    Text("账号已成功响应，但上游未返回可识别的额度窗口或摘要指标。")
                        .font(.subheadline)
                        .foregroundStyle(palette.textSecondary)
                }
            } else {
                Label(account.isDisabled ? "已停用，未查询" : "暂无可用额度快照", systemImage: "clock")
                    .font(.subheadline)
                    .foregroundStyle(palette.textSecondary)
            }
            if let error = record?.error {
                Divider()
                QuotaErrorNotice(
                    presentation: ErrorPresentation(error: error, hasPreservedSnapshot: snapshot != nil),
                    showsRecoveryAdvice: false
                )
            }
        }
        .padding(.vertical, 8)
        .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
