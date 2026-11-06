#if canImport(SwiftUI)
import SwiftUI
import CPAQuotaKit

public struct QuotasOverviewTabView: View {
    @Bindable var session: CPAQuotaSession
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var searchText = ""
    @State private var statusFilter: QuotaAccountStatusFilter = .all

    public init(session: CPAQuotaSession) {
        self.session = session
    }

    private var visibleAccounts: [CPAAccount] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return session.filteredAccounts.filter { account in
            guard statusFilter.matches(account, record: session.records[account.id]) else { return false }
            guard !query.isEmpty else { return true }
            let fields = [account.displayName, account.email ?? "", account.provider]
            return fields.map { QuotaFormatter.maskEmails(in: $0, enabled: session.maskEmail) }
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    public var body: some View {
        let palette = BrandPalette(colorScheme: colorScheme, contrast: contrast)
        let summary = QuotaOverviewSummary(accounts: session.accounts, records: session.records)
        List {
            Section {
                QuotaLabeledValue(title: "账号快照", value: "\(summary.snapshotCount) / \(summary.accountCount)")
                Text("低额读数 \(summary.lowQuotaCount) · 读取异常 \(summary.failedCount) · 尚未读取 \(summary.pendingCount)")
                    .font(.subheadline)
                    .foregroundStyle(palette.textSecondary)
                    .monospacedDigit()
                refreshProgress
                Picker("读取状态", selection: $statusFilter) {
                    ForEach(QuotaAccountStatusFilter.allCases) { status in
                        Text(status.title).tag(status)
                    }
                }
                .accessibilityIdentifier("quota.statusFilter")
            } header: {
                Text("额度摘要").font(QuotaTypography.brandHeadline)
            } footer: {
                Text("各窗口独立计算；列表显示最低已知剩余窗口。")
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
                    QuotaErrorNotice(presentation: ErrorPresentation(error: warning, hasPreservedSnapshot: true))
                    Text("部分额度来源的能力暂未确定。已读取的账号和内置读取器仍可使用。")
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
                Section { emptyState }
                    .listRowBackground(palette.contentSurface)
            } else if visibleAccounts.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("没有匹配的账号", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text("调整搜索词、账号筛选或读取状态即可查看其他账号。")
                    } actions: {
                        Button("显示全部账号") {
                            session.selectedFilter = .all
                            statusFilter = .all
                            searchText = ""
                        }
                        .quotaSecondaryButtonStyle()
                    }
                }
                .listRowBackground(palette.contentSurface)
            } else {
                Section("账号额度") {
                    ForEach(visibleAccounts) { account in
                        AccountQuotaCardView(
                            account: account,
                            record: session.records[account.id],
                            displayMode: session.displayMode,
                            maskEmail: session.maskEmail,
                            isRefreshing: isRefreshing(account),
                            canRetry: !session.isBusy && !account.isDisabled && !managementIsBlocked,
                            onRetry: { Task { await session.refreshAccount(account.id, force: true) } },
                            onTap: { session.selectedAccountIDForDetail = account.id }
                        )
                    }
                }
                .listRowBackground(palette.contentSurface)
            }
        }
        .searchable(text: $searchText, prompt: "搜索账号、邮箱或平台")
        .scrollContentBackground(.hidden)
        .background(BrandCanvasBackground())
        .navigationTitle("额度总览")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("显示比例", selection: $session.displayMode) {
                        ForEach(QuotaDisplayMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .accessibilityIdentifier("quota.displayMode")
                    Picker("账号筛选", selection: $session.selectedFilter) {
                        ForEach(AccountFilterCategory.allCases) { category in
                            Text(category.title).tag(category)
                        }
                    }
                    .accessibilityIdentifier("quota.accountFilter")
                } label: {
                    Label("显示与筛选", systemImage: "line.3.horizontal.decrease")
                }
                .accessibilityIdentifier("quota.options")
            }
        }
        .refreshable { await session.refreshAll(force: true) }
    }

    private var managementIsBlocked: Bool {
        guard let error = session.store?.error else { return false }
        return error.kind == .managementUnauthorized || error.kind == .managementForbidden
    }

    private func isRefreshing(_ account: CPAAccount) -> Bool {
        guard session.store?.isRefreshing == true, !account.isDisabled,
              let operation = session.store?.refreshOperation else { return false }
        return operation.planned.contains(account.id) && !operation.processed.contains(account.id)
    }

    @ViewBuilder
    private var refreshProgress: some View {
        if let operation = session.store?.refreshOperation {
            let enabledIDs = Set(session.accounts.filter { !$0.isDisabled }.map(\.id))
            let total = operation.planned.intersection(enabledIDs).count
            let processed = operation.processed.intersection(enabledIDs).count
            if operation.phase == .loading {
                ProgressView("正在更新账号列表")
            } else if operation.phase == .refreshing {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(processed), total: Double(max(total, 1)))
                    Text("后台刷新 \(processed) / \(total) · 已成功 \(operation.succeeded.count) · 失败 \(operation.failed.count)")
                        .font(.caption)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("quota.refreshProgress")
            } else if operation.phase == .cancelled {
                Label("本轮已取消 · 已处理 \(processed) / \(total)", systemImage: "pause.circle")
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if session.isBusy {
            ProgressView("正在读取账号列表")
                .padding(.vertical, 12)
        } else if session.store?.error != nil {
            ContentUnavailableView {
                Label("暂时无法读取账号", systemImage: "exclamationmark.triangle")
            } description: {
                Text("暂时无法读取账号列表，请按连接错误提示恢复。")
            }
        } else {
            ContentUnavailableView {
                Label("服务中暂无授权账号", systemImage: "person.crop.circle.badge.questionmark")
            } description: {
                Text("当前服务中暂无授权账号。请在 CPA 服务端添加账号后刷新。")
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
    public let isRefreshing: Bool
    public let canRetry: Bool
    public let onRetry: (() -> Void)?
    public let onTap: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    public init(
        account: CPAAccount,
        record: QuotaRecord?,
        displayMode: QuotaDisplayMode,
        maskEmail: Bool,
        isRefreshing: Bool = false,
        canRetry: Bool = true,
        onRetry: (() -> Void)? = nil,
        onTap: @escaping () -> Void
    ) {
        self.account = account
        self.record = record
        self.displayMode = displayMode
        self.maskEmail = maskEmail
        self.isRefreshing = isRefreshing
        self.canRetry = canRetry
        self.onRetry = onRetry
        self.onTap = onTap
    }

    public var body: some View {
        let palette = BrandPalette(colorScheme: colorScheme, contrast: contrast)
        let snapshot = record?.snapshot
        let summary = AccountQuotaSummary(record: record)
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onTap) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(QuotaFormatter.maskEmails(in: account.displayName, enabled: maskEmail))
                            .font(QuotaTypography.brandHeadline)
                            .foregroundStyle(palette.textPrimary)
                        Text(QuotaFormatter.maskEmails(in: account.provider.uppercased(), enabled: maskEmail))
                            .font(.caption)
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
            .privacySensitive()
            .accessibilityHint("查看所有额度窗口、账号详情与恢复操作")
            .accessibilityIdentifier("quota.account.\(account.id)")

            if account.isDisabled || account.isUnavailable {
                Label(account.isDisabled ? "账号已停用" : "账号当前不可用", systemImage: "pause.circle")
                    .font(.subheadline)
            }
            if let snapshot {
                if let window = summary.window {
                    QuotaLabeledValue(
                        title: QuotaFormatter.maskEmails(in: window.title, enabled: maskEmail),
                        value: window.primaryPercentageText(for: displayMode)
                    )
                    if let selection = summary.selectionText {
                        Text(selection).font(.caption).foregroundStyle(palette.textSecondary)
                    }
                    if let status = window.statusText {
                        Label(status, systemImage: window.isOverQuota ? "exclamationmark.circle" : "exclamationmark.triangle")
                            .font(.subheadline)
                    }
                } else if let metric = snapshot.metrics.first.map(MetricPresentation.init) {
                    QuotaLabeledValue(title: QuotaFormatter.maskEmails(in: metric.label, enabled: maskEmail), value: metric.formattedValue)
                } else if let credits = CreditsPresentation(credits: snapshot.credits) {
                    QuotaLabeledValue(title: credits.title, value: credits.valueText)
                } else {
                    Text("已响应，额度数据未知").font(.subheadline)
                }
                QuotaFreshnessLabel(snapshot: snapshot)
                if record?.error != nil {
                    Text("保留上次成功快照").font(.caption).foregroundStyle(palette.textSecondary)
                }
            } else if isRefreshing {
                ProgressView("等待本轮额度读取")
            } else {
                Text(account.isDisabled ? "已停用，未查询" : "尚无额度快照")
                    .font(.subheadline)
                    .foregroundStyle(palette.textSecondary)
            }
            if let error = record?.error {
                let presentation = ErrorPresentation(error: error, hasPreservedSnapshot: snapshot != nil)
                Label(presentation.title, systemImage: presentation.symbolName)
                    .font(.subheadline)
                    .foregroundStyle(palette.textPrimary)
            }
            if onRetry != nil, !account.isDisabled, record?.error != nil || (snapshot == nil && !isRefreshing) {
                if let retryAfter = record?.error?.retryAfter, retryAfter > .now {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        retryAction(at: context.date)
                    }
                } else {
                    retryAction(at: .now)
                }
            }
        }
        .foregroundStyle(palette.textPrimary)
        .padding(.vertical, 6)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func retryAction(at date: Date) -> some View {
        let remaining = (record?.error).flatMap { ErrorPresentation(error: $0).remainingCooldownSeconds(at: date) }
        return Button {
            onRetry?()
        } label: {
            Label(remaining.map { "请等待 \($0) 秒" } ?? "重试此账号", systemImage: remaining == nil ? "arrow.clockwise" : "hourglass")
                .frame(minHeight: 44)
        }
        .quotaSecondaryButtonStyle()
        .disabled(!canRetry || remaining != nil || isRefreshing)
        .accessibilityIdentifier("quota.retry.\(account.id)")
    }
}
#endif
