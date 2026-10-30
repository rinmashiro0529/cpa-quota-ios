#if canImport(SwiftUI)
import SwiftUI
import CPAQuotaKit
#if canImport(Charts)
import Charts
#endif

extension View {
    func capPageStyle() -> some View { modifier(CAPPageStyle()) }
}

private struct CAPEmailMaskPreference: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var capMasksEmail: Bool {
        get { self[CAPEmailMaskPreference.self] }
        set { self[CAPEmailMaskPreference.self] = newValue }
    }
}

private struct CAPPageStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        content
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(BrandCanvasBackground())
            .tint(BrandPalette(colorScheme: colorScheme).actionTint)
    }
}

struct CAPValueRow: View {
    let title: String
    let value: String
    @Environment(\.capMasksEmail) private var masksEmail
    var body: some View {
        QuotaLabeledValue(title: title, value: CAPDisplay.privacyValue(value, masksEmail: masksEmail))
    }
}

struct CAPEmptyState: View {
    let title: String
    let systemImage: String
    let detail: String
    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: { Text(detail) }
    }
}

struct CAPErrorNotice: View {
    let error: CAPUsageError
    let preservesData: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var severity: ErrorSeverityLevel {
        switch error {
        case .management(let underlying): ErrorPresentation(error: underlying).severity
        case .resourceRejected(let status, _): status == 401 || status == 403 ? .critical : .warning
        case .pluginUnavailable, .invalidResponse, .network: .warning
        }
    }

    var body: some View {
        let description = CAPUsagePresentation.errorDescription(error)
        let palette = BrandPalette(colorScheme: colorScheme)
        VStack(alignment: .leading, spacing: 8) {
            Label(description.title, systemImage: severity == .critical ? "exclamationmark.octagon" : "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(severity == .critical ? palette.statusError : severity == .neutral ? palette.textSecondary : palette.statusWarn)
            Text(description.detail).font(.subheadline)
            if preservesData {
                Label("保留上次成功结果，请以它原有的窗口和生成时间为准。", systemImage: "clock")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

struct CAPDestinationLabel: View {
    let title: String
    let systemImage: String
    let detail: String
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        } icon: { Image(systemName: systemImage) }
    }
}

struct CAPSummaryRows: View {
    let summary: CAPUsageSummary
    var body: some View {
        CAPValueRow(title: "加权生成速度", value: CAPUsagePresentation.generationTPSText(summary))
        CAPValueRow(title: "生成样本覆盖", value: CAPUsagePresentation.generationCoverageText(summary))
        CAPValueRow(title: "端到端速度", value: CAPUsagePresentation.endToEndTPSText(summary))
        CAPValueRow(title: "请求 / 失败", value: "\(CAPDisplay.counter(summary.counters.requests)) / \(CAPDisplay.counter(summary.counters.failedRequests))")
        CAPValueRow(title: "输入 / 输出 Token", value: "\(CAPDisplay.counter(summary.counters.inputTokens)) / \(CAPDisplay.counter(summary.counters.outputTokens))")
        CAPValueRow(title: "推理 / 总 Token", value: "\(CAPDisplay.counter(summary.counters.reasoningTokens)) / \(CAPDisplay.counter(summary.counters.totalTokens))")
    }
}

struct CAPCounterRows: View {
    let counters: CAPUsageCounters
    var body: some View {
        CAPValueRow(title: "请求数", value: CAPDisplay.counter(counters.requests))
        CAPValueRow(title: "失败请求", value: CAPDisplay.counter(counters.failedRequests))
        CAPValueRow(title: "输入 Token", value: CAPDisplay.counter(counters.inputTokens))
        CAPValueRow(title: "输出 Token", value: CAPDisplay.counter(counters.outputTokens))
        CAPValueRow(title: "推理 Token", value: CAPDisplay.counter(counters.reasoningTokens))
        CAPValueRow(title: "总 Token", value: CAPDisplay.counter(counters.totalTokens))
        CAPValueRow(title: "缓存 Token", value: CAPDisplay.counter(counters.cachedTokens))
        CAPValueRow(title: "缓存读取 Token", value: CAPDisplay.counter(counters.cacheReadTokens))
        CAPValueRow(title: "缓存写入 Token", value: CAPDisplay.counter(counters.cacheCreationTokens))
        CAPValueRow(title: "总延迟", value: CAPDisplay.milliseconds(counters.totalLatencyNs))
        CAPValueRow(title: "总首 Token 延迟", value: CAPDisplay.milliseconds(counters.totalTtftNs))
        CAPValueRow(title: "延迟样本", value: CAPDisplay.counter(counters.latencySamples))
        CAPValueRow(title: "首 Token 延迟样本", value: CAPDisplay.counter(counters.ttftSamples))
    }
}

struct CAPSummaryDetailView: View {
    let title: String
    let summary: CAPUsageSummary
    let window: CAPUsageWindow
    var body: some View {
        List {
            Section { CAPValueRow(title: "查询窗口", value: CAPUsagePresentation.windowBadgeText(window)) }
            Section("速度与覆盖") { CAPSummaryRows(summary: summary) }
            Section("完整计数") { CAPCounterRows(counters: summary.counters) }
        }
        .capPageStyle().navigationTitle(title)
    }
}

struct CAPModelRow: View {
    let item: CAPUsageModelSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.model ?? "未知模型").font(.headline).fontDesign(.monospaced)
            Text("\(item.provider ?? "未知平台") · \(CAPUsagePresentation.streamLabel(item.stream))")
                .font(.subheadline).foregroundStyle(.secondary)
            Text(CAPUsagePresentation.generationTPSText(item.summary)).font(.body.monospacedDigit())
            Text(CAPUsagePresentation.generationCoverageText(item.summary))
                .font(.footnote).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

struct CAPModelDetailView: View {
    let item: CAPUsageModelSummary
    let window: CAPUsageWindow
    var body: some View {
        List {
            Section("模型与窗口") {
                CAPValueRow(title: "模型", value: item.model ?? "未知")
                CAPValueRow(title: "平台", value: item.provider ?? "未知")
                CAPValueRow(title: "传输模式", value: CAPUsagePresentation.streamLabel(item.stream))
                CAPValueRow(title: "查询窗口", value: CAPUsagePresentation.windowBadgeText(window))
            }
            Section("速度与覆盖") { CAPSummaryRows(summary: item.summary) }
            Section("完整计数") { CAPCounterRows(counters: item.summary.counters) }
        }
        .capPageStyle().navigationTitle("模型用量")
    }
}

struct CAPStatRowLabel: View {
    let row: CAPUsageStatRow
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(row.provider ?? "未知平台") · \(row.model ?? "未知模型")").font(.headline)
            if let hour = row.hour { Text(hour).font(.subheadline.monospaced()).foregroundStyle(.secondary) }
            Text("请求 \(CAPDisplay.counter(row.counters.requests)) · 输出 \(CAPDisplay.counter(row.counters.outputTokens)) Token")
                .font(.subheadline).monospacedDigit()
            Text("平均延迟 \(CAPDisplay.milliseconds(row.averageLatencyNs)) · 首 Token \(CAPDisplay.milliseconds(row.averageTtftNs))")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

struct CAPStatDetailView: View {
    let row: CAPUsageStatRow
    let window: CAPUsageWindow
    let generatedAt: String?
    var body: some View {
        List {
            Section("来源与维度") {
                CAPValueRow(title: "查询窗口", value: CAPUsagePresentation.windowBadgeText(window))
                CAPValueRow(title: "响应生成", value: generatedAt ?? "未知")
                CAPValueRow(title: "时间桶", value: row.hour ?? "未提供")
                CAPValueRow(title: "平台", value: row.provider ?? "未知")
                CAPValueRow(title: "模型", value: row.model ?? "未知")
                CAPValueRow(title: "执行器", value: row.executorType ?? "未提供")
                CAPValueRow(title: "别名", value: row.alias ?? "未提供")
                CAPValueRow(title: "来源", value: row.source ?? "未提供")
                CAPValueRow(title: "认证方式", value: row.authType ?? "未提供")
                CAPValueRow(title: "服务等级", value: row.serviceTier ?? "未提供")
                CAPValueRow(title: "推理强度", value: row.reasoningEffort ?? "未提供")
            }
            Section("延迟") {
                CAPValueRow(title: "平均延迟", value: CAPDisplay.milliseconds(row.averageLatencyNs))
                CAPValueRow(title: "平均首 Token 延迟", value: CAPDisplay.milliseconds(row.averageTtftNs))
            }
            Section("完整计数") { CAPCounterRows(counters: row.counters) }
        }
        .capPageStyle().navigationTitle("统计明细")
    }
}

struct CAPStatCollectionView: View {
    let title: String
    let rows: [CAPDataRow<CAPUsageStatRow>]
    let window: CAPUsageWindow
    let generatedAt: String?
    var body: some View {
        List {
            Section {
                CAPValueRow(title: "查询窗口", value: CAPUsagePresentation.windowBadgeText(window))
                CAPValueRow(title: "响应生成", value: generatedAt ?? "未知")
                CAPValueRow(title: "返回条数", value: "\(rows.count)")
            }
            Section("全部返回记录") {
                if rows.isEmpty { Text("当前响应没有此类记录。").foregroundStyle(.secondary) }
                ForEach(rows) { item in
                    NavigationLink {
                        CAPStatDetailView(row: item.value, window: window, generatedAt: generatedAt)
                    } label: { CAPStatRowLabel(row: item.value) }
                }
            }
        }
        .capPageStyle().navigationTitle(title)
    }
}

struct CAPInitialStatsView: View {
    let presentation: CAPAnalyticsPresentation
    var body: some View {
        let initial = presentation.snapshot.initial
        let window = presentation.snapshot.window
        List {
            Section("来源与保留范围") {
                CAPValueRow(title: "查询窗口", value: CAPUsagePresentation.windowBadgeText(window))
                CAPValueRow(title: "生成时间", value: initial.generatedAt)
                CAPValueRow(title: "保留起点", value: initial.retainedSince)
                CAPValueRow(title: "最后使用", value: initial.lastUsed)
                CAPValueRow(title: "时间桶宽度", value: "\(initial.bucketSeconds) 秒")
                CAPValueRow(title: "来源", value: initial.sources.isEmpty ? "未列出来源" : initial.sources.joined(separator: "、"))
                DisclosureGroup("响应诊断") {
                    CAPValueRow(title: "Schema", value: "\(initial.schemaVersion)")
                    CAPValueRow(title: "Range", value: initial.range)
                    CAPValueRow(title: "端点", value: "/stats/initial")
                }
            }
            Section("汇总") { CAPCounterRows(counters: initial.summary) }
            Section("完整明细") {
                NavigationLink("模型统计 · \(presentation.initialModels.count) 项") {
                    CAPStatCollectionView(title: "模型统计", rows: presentation.initialModels,
                        window: window, generatedAt: initial.generatedAt)
                }
                NavigationLink("时间序列 · \(presentation.initialSeries.count) 项") {
                    CAPStatCollectionView(title: "时间序列", rows: presentation.initialSeries,
                        window: window, generatedAt: initial.generatedAt)
                }
            }
        }
        .capPageStyle().navigationTitle("资源汇总")
    }
}

struct CAPTrendsView: View {
    let presentation: CAPAnalyticsPresentation
    @State private var selectedSeriesID: CAPTrendSeriesID?
    @State private var metric: CAPTrendMetric = .requests
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var chartHeight: CGFloat = 220

    private var selectedSeries: CAPTrendSeries? {
        presentation.trends.series.first { $0.id == selectedSeriesID } ?? presentation.trends.series.first
    }

    var body: some View {
        List {
            Section("返回的时间桶") {
                CAPValueRow(title: "查询窗口", value: CAPUsagePresentation.windowBadgeText(presentation.snapshot.window))
                CAPValueRow(title: "生成时间", value: presentation.snapshot.trends.generatedAt)
                CAPValueRow(title: "桶宽度", value: "\(presentation.snapshot.trends.bucketSeconds) 秒")
                Picker("指标", selection: $metric) {
                    ForEach(CAPTrendMetric.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                if let series = selectedSeries {
                    Picker("模型与来源组", selection: Binding(
                        get: { selectedSeries?.id ?? series.id }, set: { selectedSeriesID = $0 }
                    )) {
                        ForEach(presentation.trends.series) { Text($0.title).tag($0.id) }
                    }
                    .pickerStyle(.menu)
                    trendChart(series)
                    if let first = series.points.first {
                        DisclosureGroup("当前来源组维度") {
                            CAPValueRow(title: "平台", value: first.row.provider ?? "未知")
                            CAPValueRow(title: "模型", value: first.row.model ?? "未知")
                            CAPValueRow(title: "执行器", value: first.row.executorType ?? "未提供")
                            CAPValueRow(title: "来源", value: first.row.source ?? "未提供")
                            CAPValueRow(title: "别名", value: first.row.alias ?? "未提供")
                            CAPValueRow(title: "认证方式", value: first.row.authType ?? "未提供")
                            CAPValueRow(title: "服务等级", value: first.row.serviceTier ?? "未提供")
                            CAPValueRow(title: "推理强度", value: first.row.reasoningEffort ?? "未提供")
                        }
                    }
                } else {
                    CAPEmptyState(title: "没有可绘制的时间桶", systemImage: "chart.dots.scatter",
                        detail: "原始记录仍可在完整数据表查看。不会根据缺失时间生成数据。")
                }
                Text("每个点对应服务返回的一条时间桶记录；缺值不绘制，真实零值仍为零。散点之间不连接，不补桶、不插值，也不将不同来源合并。")
                    .font(.footnote).foregroundStyle(.secondary)
                if presentation.trends.unplottableTimeCount > 0 {
                    Label("\(presentation.trends.unplottableTimeCount) 条记录没有可解析的时间，仅在完整数据表展示。", systemImage: "exclamationmark.circle")
                        .font(.footnote)
                }
            }
            Section {
                NavigationLink("完整数据表 · \(presentation.trendRows.count) 项") {
                    CAPStatCollectionView(title: "完整趋势数据", rows: presentation.trendRows,
                        window: presentation.snapshot.window, generatedAt: presentation.snapshot.trends.generatedAt)
                }
                .accessibilityHint("提供图表中所有返回记录、缺失值与各维度的文字明细")
                DisclosureGroup("响应诊断") {
                    CAPValueRow(title: "Schema", value: "\(presentation.snapshot.trends.schemaVersion)")
                    CAPValueRow(title: "Range", value: presentation.snapshot.trends.range)
                    CAPValueRow(title: "端点", value: "/stats/trends")
                }
            }
        }
        .capPageStyle().navigationTitle("时间桶趋势")
    }

    @ViewBuilder private func trendChart(_ series: CAPTrendSeries) -> some View {
        let plottedCount = series.points.filter { metric.value($0) != nil }.count
        if plottedCount == 0 {
            Text("此来源组未提供当前指标；请切换指标或查看完整数据表。")
                .foregroundStyle(.secondary)
        } else {
            #if canImport(Charts)
            Chart(series.points) { point in
                if let value = metric.value(point) {
                    PointMark(x: .value("时间桶", point.date), y: .value(metric.rawValue, value))
                        .foregroundStyle(BrandPalette(colorScheme: colorScheme).accent)
                        .accessibilityLabel(Text(point.row.hour ?? "时间桶"))
                        .accessibilityValue(Text("\(metric.rawValue)，\(value.formatted()) \(metric.unit)"))
                }
            }
            .chartXAxisLabel("返回的时间桶")
            .chartYAxisLabel(metric.unit)
            .frame(height: chartHeight)
            .accessibilityLabel("\(series.title)，\(metric.rawValue)趋势，共 \(plottedCount) 个有效点")
            #else
            Text("当前平台使用下方完整数据表查看时间桶。").foregroundStyle(.secondary)
            #endif
            Text("当前指标有效点 \(plottedCount) / 有效时间桶 \(series.points.count)")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct CAPGroupsView: View {
    @Bindable var coordinator: CAPUsageWorkspaceCoordinator
    var body: some View {
        List {
            if let error = coordinator.store?.detailsError {
                Section { CAPErrorNotice(error: error, preservesData: coordinator.analyticsPresentation != nil) }
            }
            if let presentation = coordinator.analyticsPresentation {
                let snapshot = presentation.snapshot
                Section("分页与来源") {
                    CAPValueRow(title: "查询窗口", value: CAPUsagePresentation.windowBadgeText(snapshot.window))
                    CAPValueRow(title: "生成时间", value: snapshot.groups.generatedAt)
                    Text(CAPUsagePresentation.groupPaginationBanner(offset: snapshot.groupOffset,
                        limit: snapshot.groupLimit, count: presentation.groups.count, total: snapshot.groups.total))
                        .font(.subheadline)
                    pagination(snapshot)
                    Text("翻页继续使用此窗口。四个端点分别响应，生成时间可能不同；失败时保留上一页。")
                        .font(.footnote).foregroundStyle(.secondary)
                    DisclosureGroup("响应诊断") {
                        CAPValueRow(title: "Schema", value: "\(snapshot.groups.schemaVersion)")
                        CAPValueRow(title: "Range", value: snapshot.groups.range)
                        CAPValueRow(title: "端点", value: "/stats/groups")
                    }
                }
                Section("本页全部分组") {
                    if presentation.groups.isEmpty { Text("本页没有分组记录。").foregroundStyle(.secondary) }
                    ForEach(presentation.groups) { item in
                        NavigationLink {
                            CAPStatDetailView(row: item.value, window: snapshot.window, generatedAt: snapshot.groups.generatedAt)
                        } label: { CAPStatRowLabel(row: item.value) }
                    }
                }
            } else {
                CAPEmptyState(title: "暂无分组快照", systemImage: "square.stack.3d.up",
                    detail: "返回分析栏目读取数据。连接或访问方式改变后，旧资源快照会清除。")
            }
        }
        .capPageStyle().navigationTitle("分组明细")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if coordinator.store?.isLoadingDetails == true {
                    Button("取消读取", systemImage: "xmark") { coordinator.cancelAll() }
                }
            }
        }
    }

    private func pagination(_ snapshot: CAPUsageDetailSnapshot) -> some View {
        let next = CAPPageNavigation.nextOffset(offset: snapshot.groupOffset, limit: snapshot.groupLimit,
            count: snapshot.groups.items.count, total: snapshot.groups.total)
        return HStack {
            Button("上一页", systemImage: "chevron.backward") {
                Task { await coordinator.refreshDetails(window: snapshot.window,
                    groupOffset: max(0, snapshot.groupOffset - snapshot.groupLimit), groupLimit: snapshot.groupLimit) }
            }
            .disabled(snapshot.groupOffset <= 0 || coordinator.store?.isLoadingDetails == true)
            Spacer()
            Button("下一页", systemImage: "chevron.forward") {
                guard let next else { return }
                Task { await coordinator.refreshDetails(window: snapshot.window, groupOffset: next, groupLimit: snapshot.groupLimit) }
            }
            .disabled(next == nil || coordinator.store?.isLoadingDetails == true)
        }
        .buttonStyle(.borderless)
        .frame(minHeight: 44)
    }
}

struct CAPCostAmountRows: View {
    let amounts: CAPUsageCostAmounts
    let currency: String
    var body: some View {
        CAPValueRow(title: "请求数", value: CAPDisplay.counter(amounts.requests))
        CAPValueRow(title: "已计价请求", value: CAPDisplay.counter(amounts.pricedRequests))
        CAPValueRow(title: "未计价请求", value: CAPDisplay.counter(amounts.unpricedRequests))
        CAPValueRow(title: "总费用", value: CAPUsagePresentation.formatUSD(amounts.totalUsd, currency: currency))
        CAPValueRow(title: "输入费用", value: CAPUsagePresentation.formatUSD(amounts.inputUsd, currency: currency))
        CAPValueRow(title: "输出费用", value: CAPUsagePresentation.formatUSD(amounts.outputUsd, currency: currency))
        CAPValueRow(title: "缓存读取费用", value: CAPUsagePresentation.formatUSD(amounts.cacheReadUsd, currency: currency))
        CAPValueRow(title: "缓存写入费用", value: CAPUsagePresentation.formatUSD(amounts.cacheCreationUsd, currency: currency))
    }
}

struct CAPCostsView: View {
    let presentation: CAPAnalyticsPresentation
    var body: some View {
        let costs = presentation.snapshot.costs
        List {
            Section("估算与覆盖") {
                CAPValueRow(title: "查询窗口", value: CAPUsagePresentation.windowBadgeText(presentation.snapshot.window))
                CAPValueRow(title: "生成时间", value: costs.generatedAt)
                CAPValueRow(title: "币种", value: costs.currency)
                CAPValueRow(title: "估算依据", value: costs.estimateBasis)
                CAPValueRow(title: "价格簿版本", value: "#\(costs.priceBookRevision)")
                Label(CAPUsagePresentation.costReliabilityBanner(costs), systemImage: "info.circle")
                    .font(.subheadline)
                CAPCostAmountRows(amounts: costs.summary, currency: costs.currency)
            }
            Section("费用明细") {
                NavigationLink("按模型 · \(presentation.costModels.count) 项") {
                    CAPCostCollectionView(title: "模型费用", rows: presentation.costModels,
                        costs: costs, window: presentation.snapshot.window)
                }
                NavigationLink("按时间 · \(presentation.costSeries.count) 项") {
                    CAPCostCollectionView(title: "时间桶费用", rows: presentation.costSeries,
                        costs: costs, window: presentation.snapshot.window)
                }
            }
            Section("缺失价格") {
                if presentation.missingPrices.isEmpty {
                    Text("响应没有列出缺价条目；仍须结合已计价、未计价计数判断覆盖。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(presentation.missingPrices) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(item.value.provider) · \(item.value.model)").font(.headline)
                        Text("未计价请求 \(item.value.requests) 次 · 缺价不等于免费")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Section {
                DisclosureGroup("响应诊断") {
                    CAPValueRow(title: "Schema", value: "\(costs.schemaVersion)")
                    CAPValueRow(title: "Range", value: costs.range)
                    CAPValueRow(title: "端点", value: "/costs")
                }
            }
        }
        .capPageStyle().navigationTitle("费用与计价覆盖")
    }
}

struct CAPCostCollectionView: View {
    let title: String
    let rows: [CAPDataRow<CAPUsageCostItem>]
    let costs: CAPUsageCosts
    let window: CAPUsageWindow
    var body: some View {
        List {
            Section {
                CAPValueRow(title: "查询窗口", value: CAPUsagePresentation.windowBadgeText(window))
                CAPValueRow(title: "响应生成", value: costs.generatedAt)
                CAPValueRow(title: "币种 / 价格簿", value: "\(costs.currency) / #\(costs.priceBookRevision)")
            }
            Section("全部返回记录") {
                if rows.isEmpty { Text("响应没有此类费用明细。").foregroundStyle(.secondary) }
                ForEach(rows) { item in
                    DisclosureGroup {
                        CAPCostAmountRows(amounts: item.value.amounts, currency: costs.currency)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(item.value.provider) · \(item.value.model)").font(.headline)
                            if let hour = item.value.hour { Text(hour).font(.subheadline).foregroundStyle(.secondary) }
                            Text(CAPUsagePresentation.formatUSD(item.value.amounts.totalUsd, currency: costs.currency))
                                .font(.body.monospacedDigit())
                        }
                    }
                }
            }
        }
        .capPageStyle().navigationTitle(title)
    }
}

struct CAPRequestRow: View {
    let request: CAPUsageRequest
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        let palette = BrandPalette(colorScheme: colorScheme)
        VStack(alignment: .leading, spacing: 5) {
            Text(request.model ?? "未知模型").font(.headline).fontDesign(.monospaced)
            Text("\(request.provider ?? "未知平台") · \(request.time ?? "时间未知")")
                .font(.subheadline).foregroundStyle(.secondary)
            Label(CAPUsagePresentation.requestOutcomeText(request),
                systemImage: request.failed == true ? "xmark.circle" : request.failed == false ? "checkmark.circle" : "questionmark.circle")
                .font(.subheadline)
                .foregroundStyle(request.failed == true ? palette.statusError : request.failed == false ? palette.statusOK : palette.textSecondary)
            Text("输出 \(CAPDisplay.counter(request.outputTokens)) Token · 首 Token \(CAPDisplay.milliseconds(request.ttftNs))")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

struct CAPRequestDetailView: View {
    let request: CAPUsageRequest
    let window: CAPUsageWindow
    let generatedAt: String?
    let priceBookRevision: UInt64?
    var body: some View {
        List {
            Section("请求与响应来源") {
                CAPValueRow(title: "请求序号", value: request.sequence.map(String.init) ?? "未提供")
                CAPValueRow(title: "请求时间", value: request.time ?? "未知")
                CAPValueRow(title: "结果", value: CAPUsagePresentation.requestOutcomeText(request))
                CAPValueRow(title: "原始结果", value: request.result ?? "未提供")
                CAPValueRow(title: "失败状态码", value: request.failureStatus.map(String.init) ?? "未提供")
                CAPValueRow(title: "查询窗口", value: CAPUsagePresentation.windowBadgeText(window))
                CAPValueRow(title: "响应生成", value: generatedAt ?? "未知")
                CAPValueRow(title: "价格簿版本", value: priceBookRevision.map { "#\($0)" } ?? "未知")
            }
            Section("用量") {
                CAPValueRow(title: "输入 Token", value: CAPDisplay.counter(request.inputTokens))
                CAPValueRow(title: "输出 Token", value: CAPDisplay.counter(request.outputTokens))
                CAPValueRow(title: "推理 Token", value: CAPDisplay.counter(request.reasoningTokens))
                CAPValueRow(title: "总 Token", value: CAPDisplay.counter(request.totalTokens))
                CAPValueRow(title: "缓存 Token", value: CAPDisplay.counter(request.cachedTokens))
                CAPValueRow(title: "缓存读取 Token", value: CAPDisplay.counter(request.cacheReadTokens))
                CAPValueRow(title: "缓存写入 Token", value: CAPDisplay.counter(request.cacheCreationTokens))
                CAPValueRow(title: "缓存命中", value: CAPDisplay.boolean(request.cacheHit))
                CAPValueRow(title: "报告请求数", value: CAPDisplay.counter(request.requests))
                CAPValueRow(title: "报告失败数", value: CAPDisplay.counter(request.failedRequests))
            }
            Section("延迟与服务报告速度") {
                CAPValueRow(title: "首 Token 延迟", value: CAPDisplay.milliseconds(request.ttftNs))
                CAPValueRow(title: "端到端延迟", value: CAPDisplay.milliseconds(request.latencyNs))
                CAPValueRow(title: "生成时长", value: CAPDisplay.milliseconds(request.generationNs))
                CAPValueRow(title: "服务报告 TPS", value: CAPDisplay.rate(request.tps))
                CAPValueRow(title: "服务报告端到端 TPS", value: CAPDisplay.rate(request.endToEndTps))
                Text("这里保留单条请求的原始报告。概览的加权速度由有效样本重新计算，不以这些单次速度取平均；失败或结果未知的请求不会作为成功生成样本。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("模型与诊断维度") {
                CAPValueRow(title: "平台", value: request.provider ?? "未知")
                CAPValueRow(title: "模型", value: request.model ?? "未知")
                CAPValueRow(title: "传输模式", value: CAPUsagePresentation.streamLabel(request.stream))
                CAPValueRow(title: "执行器", value: request.executorType ?? "未提供")
                CAPValueRow(title: "别名", value: request.alias ?? "未提供")
                CAPValueRow(title: "来源", value: request.source ?? "未提供")
                CAPValueRow(title: "认证方式", value: request.authType ?? "未提供")
                CAPValueRow(title: "服务等级", value: request.serviceTier ?? "未提供")
                CAPValueRow(title: "推理强度", value: request.reasoningEffort ?? "未提供")
            }
        }
        .capPageStyle().navigationTitle("请求明细")
    }
}

struct CAPManagementDetailView: View {
    let presentation: CAPManagementPresentation
    var body: some View {
        let stats = presentation.stats
        List {
            Section("管理来源") {
                CAPValueRow(title: "查询窗口", value: CAPUsagePresentation.windowBadgeText(presentation.window))
                CAPValueRow(title: "生成时间", value: stats.generatedAt ?? "未知")
                CAPValueRow(title: "保留起点", value: stats.retainedSince ?? "未知")
                CAPValueRow(title: "最后使用", value: stats.lastUsed ?? "未知")
                CAPValueRow(title: "来源", value: stats.sources.map { $0.isEmpty ? "空列表" : $0.joined(separator: "、") } ?? "未提供")
                DisclosureGroup("响应诊断") {
                    CAPValueRow(title: "Schema", value: stats.schemaVersion.map(String.init) ?? "未提供")
                    CAPValueRow(title: "Range", value: stats.range ?? "未提供")
                    CAPValueRow(title: "认证", value: "管理密钥")
                }
            }
            Section("完整汇总") { CAPCounterRows(counters: stats.summary) }
            Section("完整明细") {
                if stats.groups != nil {
                    NavigationLink("分组 · \(presentation.groups.count) 项") {
                        CAPStatCollectionView(title: "管理分组", rows: presentation.groups,
                            window: presentation.window, generatedAt: stats.generatedAt)
                    }
                } else { CAPValueRow(title: "分组", value: "未提供") }
                if stats.series != nil {
                    NavigationLink("时间序列 · \(presentation.series.count) 项") {
                        CAPStatCollectionView(title: "管理时间序列", rows: presentation.series,
                            window: presentation.window, generatedAt: stats.generatedAt)
                    }
                } else { CAPValueRow(title: "时间序列", value: "未提供") }
                if stats.modelSeries != nil {
                    NavigationLink("模型时间序列 · \(presentation.modelSeries.count) 项") {
                        CAPStatCollectionView(title: "管理模型序列", rows: presentation.modelSeries,
                            window: presentation.window, generatedAt: stats.generatedAt)
                    }
                } else { CAPValueRow(title: "模型时间序列", value: "未提供") }
            }
        }
        .capPageStyle().navigationTitle("管理统计")
    }
}
#endif
