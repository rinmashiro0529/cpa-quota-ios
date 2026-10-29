#if canImport(SwiftUI)
import SwiftUI
import CPAQuotaKit

public struct CAPUsageTabView: View {
    @Bindable public var session: CPAQuotaSession
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedSection: DetailSection = .models
    @State private var groupPageSize: Int = 50
    @State private var requestPageSize: Int = 50

    public enum DetailSection: String, CaseIterable, Identifiable {
        case models = "近30m模型概览"
        case details = "趋势·分组·费用"
        case requests = "请求明细页"
        case management = "管理统计对比"

        public var id: String { rawValue }
    }

    public init(session: CPAQuotaSession) {
        self.session = session
    }

    public var body: some View {
        let palette = LiquidGlassPalette(colorScheme: colorScheme)
        let coordinator = session.capUsageCoordinator
        let store = coordinator.store

        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                headerAndControlCard(coordinator: coordinator, store: store, palette: palette)

                if let error = store?.error {
                    let desc = CAPUsagePresentation.errorDescription(error)
                    errorBanner(title: desc.title, detail: desc.detail, hasPreservedData: store?.snapshot != nil, palette: palette)
                }

                sectionPicker(palette: palette)

                switch selectedSection {
                case .models:
                    modelsOverviewSection(coordinator: coordinator, store: store, palette: palette)
                case .details:
                    detailsAnalyticsSection(coordinator: coordinator, store: store, palette: palette)
                case .requests:
                    requestPageSection(coordinator: coordinator, palette: palette)
                case .management:
                    managementStatsSection(coordinator: coordinator, palette: palette)
                }

                Spacer(minLength: 96)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func headerAndControlCard(
        coordinator: CAPUsageWorkspaceCoordinator,
        store: CAPUsageStore?,
        palette: LiquidGlassPalette
    ) -> some View {
        let activeWindow = store?.snapshot?.window ?? coordinator.activeWindow

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CAP Token 用量与严格加权 TPS")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                    Text(CAPUsagePresentation.windowBadgeText(activeWindow))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(palette.accent)
                }
                Spacer()
                if store?.isRefreshing == true || store?.isLoadingDetails == true || coordinator.isLoadingRequestPage || coordinator.isLoadingManagementStats {
                    Button {
                        coordinator.cancelAll()
                    } label: {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.small)
                            Text("取消读取")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(palette.statusError)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .liquidGlassPill(cornerRadius: 12)
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("CAP 资源接口鉴权模式（显式选择，绝不自动降级或偷偷重发管理密钥）")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(palette.textSecondary)

                HStack(spacing: 8) {
                    accessModeButton(
                        title: "匿名资源 (.anonymous)",
                        mode: .anonymous,
                        coordinator: coordinator,
                        palette: palette
                    )
                    accessModeButton(
                        title: "管理密钥 (.managementKey)",
                        mode: .managementKey,
                        coordinator: coordinator,
                        palette: palette
                    )
                }
            }

            HStack(spacing: 8) {
                Button {
                    Task { await coordinator.refreshOverview() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise")
                        Text("刷新 30m 概览")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(palette.accent)
                    )
                }
                .buttonStyle(.plain)
                .disabled(store == nil)

                Button {
                    Task { await coordinator.refreshDetails(groupOffset: 0, groupLimit: groupPageSize) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chart.xyaxis.line")
                        Text("加载四端点详情")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .liquidGlassPill(cornerRadius: 14)
                }
                .buttonStyle(.plain)
                .disabled(store == nil)
            }

            Text("口径说明：生成 TPS = 有效输出 Token 总和 ÷ 有效生成时长 (latency_ns − ttft_ns) 总和；非单请求算术平均，亦非除以 1800 秒窗口。同名模型按不同 provider 与 stream 独立分组。")
                .font(.system(size: 10))
                .foregroundStyle(palette.textMuted)
                .lineSpacing(1.5)
        }
        .padding(16)
        .liquidGlassCard(cornerRadius: 24)
    }

    @ViewBuilder
    private func accessModeButton(
        title: String,
        mode: CAPUsageResourceAccess,
        coordinator: CAPUsageWorkspaceCoordinator,
        palette: LiquidGlassPalette
    ) -> some View {
        let isSelected = coordinator.resourceAccess.isSameMode(as: mode)
        Button {
            coordinator.resourceAccess = mode
        } label: {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.white : palette.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(palette.accent)
                    }
                }
        }
        .buttonStyle(.plain)
        .liquidGlassPill(cornerRadius: 10)
    }

    @ViewBuilder
    private func sectionPicker(palette: LiquidGlassPalette) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(DetailSection.allCases) { sec in
                    let isSelected = selectedSection == sec
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedSection = sec
                        }
                    } label: {
                        Text(sec.rawValue)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? Color.white : palette.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background {
                                if isSelected {
                                    Capsule(style: .continuous).fill(palette.accent)
                                } else {
                                    Capsule(style: .continuous).fill(palette.pillTintOverlay)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func modelsOverviewSection(
        coordinator: CAPUsageWorkspaceCoordinator,
        store: CAPUsageStore?,
        palette: LiquidGlassPalette
    ) -> some View {
        if let snapshot = store?.snapshot {
            let overallSummary = CAPUsageAggregation.summarize(snapshot.requests.items)
            VStack(alignment: .leading, spacing: 14) {
                completenessCard(
                    completeness: snapshot.requests.completeness,
                    itemCount: snapshot.requests.items.count,
                    overallSummary: overallSummary,
                    palette: palette
                )

                if snapshot.models.isEmpty {
                    emptyCard(
                        title: "当前 30 分钟窗口内无请求记录",
                        subtitle: "截至 \(CAPUsagePresentation.windowBadgeText(snapshot.window)) 暂未捕获模型调用记录。",
                        palette: palette
                    )
                } else {
                    ForEach(Array(snapshot.models.enumerated()), id: \.offset) { _, item in
                        modelSummaryCard(item: item, palette: palette)
                    }
                }
            }
        } else {
            emptyCard(
                title: "尚未加载近 30 分钟 CAP 概览",
                subtitle: "点击上方「刷新 30m 概览」按当前连接获取截至最后完整分钟的请求集合与模型加权 TPS。切换标签不会自动发起全量请求风暴。",
                palette: palette
            )
        }
    }

    @ViewBuilder
    private func completenessCard(
        completeness: CAPUsageCompleteness,
        itemCount: Int,
        overallSummary: CAPUsageSummary,
        palette: LiquidGlassPalette
    ) -> some View {
        let badgeTint: Color = {
            switch completeness {
            case .singlePage: return palette.statusOK
            case .offsetUnverified: return palette.accent
            case .truncated: return palette.statusWarn
            }
        }()

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(CAPUsagePresentation.completenessTitle(completeness))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(badgeTint)
                Spacer()
                Text("已获取 \(itemCount) 条记录")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.textSecondary)
            }

            Text(CAPUsagePresentation.completenessSubtitle(completeness, itemCount: itemCount))
                .font(.system(size: 11))
                .foregroundStyle(palette.textSecondary)
                .lineSpacing(1.5)

            Divider().overlay(palette.trackBackground)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                counterMetricPill(label: "窗口加权生成 TPS", value: CAPUsagePresentation.generationTPSText(overallSummary), palette: palette)
                counterMetricPill(label: "生成 TPS 样本覆盖", value: CAPUsagePresentation.generationCoverageText(overallSummary), palette: palette)
                counterMetricPill(label: "窗口端到端速度", value: CAPUsagePresentation.endToEndTPSText(overallSummary), palette: palette)
                counterMetricPill(label: "总请求 / 失败请求", value: "\(CAPUsagePresentation.formatCounter(overallSummary.counters.requests)) / \(CAPUsagePresentation.formatCounter(overallSummary.counters.failedRequests))", palette: palette)
                counterMetricPill(label: "输入 / 输出 Token", value: "\(CAPUsagePresentation.formatCounter(overallSummary.counters.inputTokens)) / \(CAPUsagePresentation.formatCounter(overallSummary.counters.outputTokens))", palette: palette)
                counterMetricPill(label: "Reasoning / 总 Token", value: "\(CAPUsagePresentation.formatCounter(overallSummary.counters.reasoningTokens)) / \(CAPUsagePresentation.formatCounter(overallSummary.counters.totalTokens))", palette: palette)
            }
        }
        .padding(15)
        .liquidGlassCard(cornerRadius: 22)
    }

    @ViewBuilder
    private func modelSummaryCard(item: CAPUsageModelSummary, palette: LiquidGlassPalette) -> some View {
        let summary = item.summary
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.model ?? "未知模型 (nil)")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(palette.textPrimary)
                    HStack(spacing: 6) {
                        Text("Provider: \(item.provider ?? "未知 (nil)")")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(palette.accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(palette.accentSoft))

                        Text(CAPUsagePresentation.streamLabel(item.stream))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(palette.textSecondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .liquidGlassPill(cornerRadius: 8)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(CAPUsagePresentation.generationTPSText(summary))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(summary.generationTPS != nil ? palette.statusOK : palette.statusWarn)
                    Text(CAPUsagePresentation.generationCoverageText(summary))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(palette.textMuted)
                }
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                counterMetricPill(label: "端到端速度", value: CAPUsagePresentation.endToEndTPSText(summary), palette: palette)
                counterMetricPill(label: "请求数 (失败)", value: "\(CAPUsagePresentation.formatCounter(summary.counters.requests)) (\(CAPUsagePresentation.formatCounter(summary.counters.failedRequests)) 失败)", palette: palette)
                counterMetricPill(label: "Input / Output", value: "\(CAPUsagePresentation.formatCounter(summary.counters.inputTokens)) / \(CAPUsagePresentation.formatCounter(summary.counters.outputTokens))", palette: palette)
                counterMetricPill(label: "Reasoning / Total", value: "\(CAPUsagePresentation.formatCounter(summary.counters.reasoningTokens)) / \(CAPUsagePresentation.formatCounter(summary.counters.totalTokens))", palette: palette)
                counterMetricPill(label: "Cache Read / Write", value: "\(CAPUsagePresentation.formatCounter(summary.counters.cacheReadTokens)) / \(CAPUsagePresentation.formatCounter(summary.counters.cacheCreationTokens))", palette: palette)
                counterMetricPill(label: "Cached Tokens", value: CAPUsagePresentation.formatCounter(summary.counters.cachedTokens), palette: palette)
            }
        }
        .padding(14)
        .liquidGlassCard(cornerRadius: 20)
    }

    @ViewBuilder
    private func detailsAnalyticsSection(
        coordinator: CAPUsageWorkspaceCoordinator,
        store: CAPUsageStore?,
        palette: LiquidGlassPalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let detailsError = store?.detailsError {
                let desc = CAPUsagePresentation.errorDescription(detailsError)
                errorBanner(
                    title: "详情刷新失败 · \(desc.title)",
                    detail: "\(desc.detail) 已保留上次成功详情（若有），不会伪造四端点一致成功。",
                    hasPreservedData: store?.details != nil,
                    palette: palette
                )
            }

            if let details = store?.details {
                // 1. Initial Stats Card
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("1. Initial 端点统计 (/stats/initial)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.textPrimary)
                        Spacer()
                        Text("生成时间: \(details.initial.generatedAt)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(palette.textMuted)
                    }
                    Text("时间桶分辨率: \(details.initial.bucketSeconds)s · 保留起点: \(details.initial.retainedSince) · 最后使用: \(details.initial.lastUsed)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(palette.textSecondary)

                    if !details.initial.sources.isEmpty {
                        Text("Sources: \(details.initial.sources.joined(separator: ", "))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(palette.accent)
                    }

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                        counterMetricPill(label: "Initial 总请求 / 失败", value: "\(CAPUsagePresentation.formatCounter(details.initial.summary.requests)) / \(CAPUsagePresentation.formatCounter(details.initial.summary.failedRequests))", palette: palette)
                        counterMetricPill(label: "Initial Input / Output", value: "\(CAPUsagePresentation.formatCounter(details.initial.summary.inputTokens)) / \(CAPUsagePresentation.formatCounter(details.initial.summary.outputTokens))", palette: palette)
                        counterMetricPill(label: "Initial Reasoning / Total", value: "\(CAPUsagePresentation.formatCounter(details.initial.summary.reasoningTokens)) / \(CAPUsagePresentation.formatCounter(details.initial.summary.totalTokens))", palette: palette)
                        counterMetricPill(label: "Latency / TTFT 样本", value: "\(CAPUsagePresentation.formatCounter(details.initial.summary.latencySamples)) / \(CAPUsagePresentation.formatCounter(details.initial.summary.ttftSamples))", palette: palette)
                    }
                }
                .padding(14)
                .liquidGlassCard(cornerRadius: 20)

                // 2. Costs Card
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("2. Costs 费用估算与缺价覆盖 (/costs)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.textPrimary)
                        Spacer()
                        Text("生成: \(details.costs.generatedAt)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(palette.textMuted)
                    }
                    Text(CAPUsagePresentation.costReliabilityBanner(details.costs))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(details.costs.missingPrices.isEmpty && (details.costs.summary.unpricedRequests ?? 0) == 0 ? palette.statusOK : palette.statusWarn)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                        counterMetricPill(label: "估算总费用 (\(details.costs.currency))", value: CAPUsagePresentation.formatUSD(details.costs.summary.totalUsd, currency: details.costs.currency), palette: palette)
                        counterMetricPill(label: "已计价 / 未计价请求", value: "\(CAPUsagePresentation.formatCounter(details.costs.summary.pricedRequests)) / \(CAPUsagePresentation.formatCounter(details.costs.summary.unpricedRequests))", palette: palette)
                        counterMetricPill(label: "Input / Output 费用", value: "\(CAPUsagePresentation.formatUSD(details.costs.summary.inputUsd, currency: details.costs.currency)) / \(CAPUsagePresentation.formatUSD(details.costs.summary.outputUsd, currency: details.costs.currency))", palette: palette)
                        counterMetricPill(label: "Cache Read / Write 费用", value: "\(CAPUsagePresentation.formatUSD(details.costs.summary.cacheReadUsd, currency: details.costs.currency)) / \(CAPUsagePresentation.formatUSD(details.costs.summary.cacheCreationUsd, currency: details.costs.currency))", palette: palette)
                    }

                    if !details.costs.missingPrices.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("缺失价格表项 (缺价不等于免费 $0):")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(palette.statusWarn)
                            ForEach(Array(details.costs.missingPrices.enumerated()), id: \.offset) { _, mp in
                                Text("• \(mp.provider) / \(mp.model) — 未计价请求 \(mp.requests) 次")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(palette.textSecondary)
                            }
                        }
                        .padding(10)
                        .liquidGlassPill(cornerRadius: 12)
                    }
                }
                .padding(14)
                .liquidGlassCard(cornerRadius: 20)

                // 3. Trends Card
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("3. Trends 逐模型时间桶 (/stats/trends)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.textPrimary)
                        Spacer()
                        Text("桶宽 \(details.trends.bucketSeconds)s · 生成: \(details.trends.generatedAt)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(palette.textMuted)
                    }
                    if details.trends.modelSeries.isEmpty {
                        Text("当前窗口无趋势时间桶记录。")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.textSecondary)
                    } else {
                        ForEach(Array(details.trends.modelSeries.prefix(20).enumerated()), id: \.offset) { _, row in
                            statRowItem(row: row, palette: palette)
                        }
                    }
                }
                .padding(14)
                .liquidGlassCard(cornerRadius: 20)

                // 4. Groups Card with pagination
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("4. Groups 多维分组明细 (/stats/groups)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.textPrimary)
                        Spacer()
                        Text("生成: \(details.groups.generatedAt)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(palette.textMuted)
                    }

                    Text(CAPUsagePresentation.groupPaginationBanner(
                        offset: details.groupOffset,
                        limit: details.groupLimit,
                        count: details.groups.items.count,
                        total: details.groups.total
                    ))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(palette.accent)

                    HStack(spacing: 8) {
                        Button {
                            let prev = max(0, details.groupOffset - details.groupLimit)
                            Task { await coordinator.refreshDetails(groupOffset: prev, groupLimit: details.groupLimit) }
                        } label: {
                            Text("上一页分组")
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .liquidGlassPill(cornerRadius: 10)
                        }
                        .buttonStyle(.plain)
                        .disabled(details.groupOffset <= 0 || store?.isLoadingDetails == true)

                        Button {
                            let next = details.groupOffset + details.groupLimit
                            Task { await coordinator.refreshDetails(groupOffset: next, groupLimit: details.groupLimit) }
                        } label: {
                            Text("下一页分组")
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .liquidGlassPill(cornerRadius: 10)
                        }
                        .buttonStyle(.plain)
                        .disabled(details.groupOffset + details.groups.items.count >= details.groups.total || store?.isLoadingDetails == true)
                    }

                    ForEach(Array(details.groups.items.enumerated()), id: \.offset) { _, row in
                        statRowItem(row: row, palette: palette)
                    }
                }
                .padding(14)
                .liquidGlassCard(cornerRadius: 20)
            } else {
                emptyCard(
                    title: "尚未读取四端点详情 (initial / trends / groups / costs)",
                    subtitle: "点击顶部「加载四端点详情」读取；各端点拥有独立响应生成时间，固定窗口不代表跨端点原子数据库快照。",
                    palette: palette
                )
            }
        }
    }

    @ViewBuilder
    private func requestPageSection(
        coordinator: CAPUsageWorkspaceCoordinator,
        palette: LiquidGlassPalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("单页请求日志浏览 (/requests)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                Spacer()
                Button {
                    Task { await coordinator.loadRequestPage(offset: coordinator.requestPageOffset, limit: requestPageSize) }
                } label: {
                    Text(coordinator.isLoadingRequestPage ? "读取中…" : "加载当前页")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .liquidGlassPill(cornerRadius: 10)
                }
                .buttonStyle(.plain)
            }

            if let err = coordinator.requestPageError {
                let desc = CAPUsagePresentation.errorDescription(err)
                errorBanner(title: desc.title, detail: desc.detail, hasPreservedData: coordinator.requestPage != nil, palette: palette)
            }

            if let page = coordinator.requestPage {
                Text("请求明细分页：当前显示 \(page.items.count) 条 (offset \(page.offset), limit \(page.limit)) / 报告总计 \(page.total) 条 · 价格簿版本: \(page.priceBookRevision.map { "#\($0)" } ?? "未知")")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(palette.accent)

                HStack(spacing: 8) {
                    Button {
                        let prev = max(0, page.offset - page.limit)
                        Task { await coordinator.loadRequestPage(offset: prev, limit: page.limit) }
                    } label: {
                        Text("上一页")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .liquidGlassPill(cornerRadius: 10)
                    }
                    .buttonStyle(.plain)
                    .disabled(page.offset <= 0 || coordinator.isLoadingRequestPage)

                    Button {
                        let next = page.offset + page.limit
                        Task { await coordinator.loadRequestPage(offset: next, limit: page.limit) }
                    } label: {
                        Text("下一页")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .liquidGlassPill(cornerRadius: 10)
                    }
                    .buttonStyle(.plain)
                    .disabled(page.offset + page.items.count >= page.total || coordinator.isLoadingRequestPage)
                }

                ForEach(Array(page.items.enumerated()), id: \.offset) { _, req in
                    requestRowItem(req: req, palette: palette)
                }
            } else {
                emptyCard(
                    title: "按需分页查看单条请求明细",
                    subtitle: "点击「加载当前页」查看请求序列号、模型、Provider、Stream、Token 用量与 TTFT/Latency 指标。失败请求可能包含部分 Token 用量，但不计入成功生成 TPS 样本。",
                    palette: palette
                )
            }
        }
        .padding(14)
        .liquidGlassCard(cornerRadius: 22)
    }

    @ViewBuilder
    private func managementStatsSection(
        coordinator: CAPUsageWorkspaceCoordinator,
        palette: LiquidGlassPalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("管理路由聚合统计 (/v0/management/.../stats)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                Spacer()
                Button {
                    Task { await coordinator.refreshManagementStats() }
                } label: {
                    Text(coordinator.isLoadingManagementStats ? "读取中…" : "读取管理统计")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .liquidGlassPill(cornerRadius: 10)
                }
                .buttonStyle(.plain)
            }

            if let err = coordinator.managementStatsError {
                let desc = CAPUsagePresentation.errorDescription(err)
                errorBanner(title: desc.title, detail: desc.detail, hasPreservedData: coordinator.managementStats != nil, palette: palette)
            }

            if let stats = coordinator.managementStats {
                Text("生成时间: \(stats.generatedAt ?? "未知") · 保留起点: \(stats.retainedSince ?? "未知") · 最后使用: \(stats.lastUsed ?? "未知")")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(palette.textSecondary)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    counterMetricPill(label: "请求数 / 失败数", value: "\(CAPUsagePresentation.formatCounter(stats.summary.requests)) / \(CAPUsagePresentation.formatCounter(stats.summary.failedRequests))", palette: palette)
                    counterMetricPill(label: "Input / Output", value: "\(CAPUsagePresentation.formatCounter(stats.summary.inputTokens)) / \(CAPUsagePresentation.formatCounter(stats.summary.outputTokens))", palette: palette)
                    counterMetricPill(label: "Reasoning / Total", value: "\(CAPUsagePresentation.formatCounter(stats.summary.reasoningTokens)) / \(CAPUsagePresentation.formatCounter(stats.summary.totalTokens))", palette: palette)
                    counterMetricPill(label: "Latency / TTFT 样本", value: "\(CAPUsagePresentation.formatCounter(stats.summary.latencySamples)) / \(CAPUsagePresentation.formatCounter(stats.summary.ttftSamples))", palette: palette)
                }
            } else {
                emptyCard(
                    title: "尚未读取管理路由统计",
                    subtitle: "管理统计始终使用管理 Bearer 鉴权并共享管理层 3 并发与 401/403/429 熔断保护。",
                    palette: palette
                )
            }
        }
        .padding(14)
        .liquidGlassCard(cornerRadius: 22)
    }

    @ViewBuilder
    private func statRowItem(row: CAPUsageStatRow, palette: LiquidGlassPalette) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(row.provider ?? "未知") · \(row.model ?? "未知")")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(palette.textPrimary)
                Spacer()
                if let hour = row.hour {
                    Text(hour)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(palette.textMuted)
                }
            }
            Text("Executor: \(row.executorType ?? "-") · Source: \(row.source ?? "-") · Tier: \(row.serviceTier ?? "-") · Effort: \(row.reasoningEffort ?? "-")")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(palette.textSecondary)
            Text("Req: \(CAPUsagePresentation.formatCounter(row.counters.requests)) (失败 \(CAPUsagePresentation.formatCounter(row.counters.failedRequests))) · In/Out: \(CAPUsagePresentation.formatCounter(row.counters.inputTokens))/\(CAPUsagePresentation.formatCounter(row.counters.outputTokens)) · AvgLat: \(CAPUsagePresentation.formatNanosecondsAsMillis(row.averageLatencyNs)) · AvgTTFT: \(CAPUsagePresentation.formatNanosecondsAsMillis(row.averageTtftNs))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(palette.textSecondary)
        }
        .padding(10)
        .liquidGlassPill(cornerRadius: 12)
    }

    @ViewBuilder
    private func requestRowItem(req: CAPUsageRequest, palette: LiquidGlassPalette) -> some View {
        let isFailed = req.failed == true
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("#\(req.sequence.map(String.init) ?? "?") · \(req.provider ?? "未知") / \(req.model ?? "未知")")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(palette.textPrimary)
                Spacer()
                Text(isFailed ? "失败 (\(req.failureStatus.map(String.init) ?? "err"))" : (req.result ?? "成功"))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isFailed ? palette.statusError : palette.statusOK)
            }
            Text("时间: \(req.time ?? "未知") · \(CAPUsagePresentation.streamLabel(req.stream)) · Executor: \(req.executorType ?? "-")")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(palette.textSecondary)
            Text("In: \(CAPUsagePresentation.formatCounter(req.inputTokens)) · Out: \(CAPUsagePresentation.formatCounter(req.outputTokens)) · Reasoning: \(CAPUsagePresentation.formatCounter(req.reasoningTokens)) · Total: \(CAPUsagePresentation.formatCounter(req.totalTokens))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(palette.textSecondary)
            Text("TTFT: \(CAPUsagePresentation.formatNanosecondsAsMillis(req.ttftNs)) · Latency: \(CAPUsagePresentation.formatNanosecondsAsMillis(req.latencyNs))\(isFailed ? " · (失败请求不纳入成功生成 TPS 样本)" : "")")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(isFailed ? palette.statusWarn : palette.textMuted)
        }
        .padding(10)
        .liquidGlassPill(cornerRadius: 12)
    }

    @ViewBuilder
    private func counterMetricPill(label: String, value: String, palette: LiquidGlassPalette) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassPill(cornerRadius: 12)
    }

    @ViewBuilder
    private func errorBanner(title: String, detail: String, hasPreservedData: Bool, palette: LiquidGlassPalette) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(palette.statusError)

            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(palette.textSecondary)

            if hasPreservedData {
                Text("已保留上一次有效快照数据供对比查阅。")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(palette.statusWarn)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassCard(cornerRadius: 18)
    }

    @ViewBuilder
    private func emptyCard(title: String, subtitle: String, palette: LiquidGlassPalette) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(palette.textSecondary)
                .lineSpacing(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassCard(cornerRadius: 20)
    }
}
#endif
