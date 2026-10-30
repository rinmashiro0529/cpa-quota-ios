#if canImport(SwiftUI)
import SwiftUI
import CPAQuotaKit

public struct CAPUsageTabView: View {
    @Bindable public var session: CPAQuotaSession
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedSection: DetailSection = .models
    @State private var groupPageSize = 50
    @State private var requestPageSize = 50

    public enum DetailSection: String, CaseIterable, Identifiable {
        case models = "近30m模型概览"
        case details = "趋势·分组·费用"
        case requests = "请求明细页"
        case management = "管理统计对比"
        public var id: String { rawValue }
    }

    public init(session: CPAQuotaSession) { self.session = session }

    private var coordinator: CAPUsageWorkspaceCoordinator { session.capUsageCoordinator }
    private var palette: BrandPalette { BrandPalette(colorScheme: colorScheme) }
    private var isBusy: Bool {
        coordinator.store?.isRefreshing == true || coordinator.store?.isLoadingDetails == true ||
        coordinator.isLoadingRequestPage || coordinator.isLoadingManagementStats
    }
    private var displayedWindow: CAPUsageWindow {
        switch selectedSection {
        case .models: coordinator.overviewPresentation?.snapshot.window ?? coordinator.activeWindow
        case .details: coordinator.analyticsPresentation?.snapshot.window ?? coordinator.activeWindow
        case .requests: coordinator.requestPagePresentation?.window ?? coordinator.activeWindow
        case .management: coordinator.managementPresentation?.window ?? coordinator.activeWindow
        }
    }

    public var body: some View {
        List {
            controls
            if coordinator.store == nil {
                Section {
                    CAPEmptyState(title: "连接服务后查看用量", systemImage: "chart.bar.xaxis",
                        detail: "请在连接页面配置 CPA 服务。这里不会自动加载数据或改变资源访问权限。")
                }
            } else {
                switch selectedSection {
                case .models: modelsSection
                case .details: analyticsSection
                case .requests: requestsSection
                case .management: managementSection
                }
            }
        }
        .capPageStyle()
        .environment(\.capMasksEmail, session.maskEmail)
        .navigationTitle("用量")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if isBusy {
                    Button("取消读取", systemImage: "xmark") { coordinator.cancelAll() }
                        .accessibilityIdentifier("cap.cancel")
                } else {
                    Button("刷新当前栏目", systemImage: "arrow.clockwise") {
                        Task { await refreshCurrentSection() }
                    }
                    .disabled(coordinator.store == nil)
                    .accessibilityIdentifier("cap.refresh")
                }
            }
        }
        .refreshable { await refreshCurrentSection() }
    }

    private var controls: some View {
        Section {
            Picker("栏目", selection: $selectedSection) {
                ForEach(DetailSection.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("cap.sectionPicker")
            CAPValueRow(title: "查询窗口", value: CAPUsagePresentation.windowBadgeText(displayedWindow))
            if isBusy {
                Label { Text("正在读取，已显示的数据仍属于原窗口。") } icon: { ProgressView() }
                    .font(.subheadline)
                    .accessibilityElement(children: .combine)
            }
            DisclosureGroup("访问方式与统计口径") {
                Picker("资源访问", selection: Binding(
                    get: { coordinator.resourceAccess.isSameMode(as: .managementKey) },
                    set: { coordinator.resourceAccess = $0 ? .managementKey : .anonymous }
                )) {
                    Text("匿名").tag(false)
                    Text("管理密钥").tag(true)
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("cap.resourceAccess")
                Text("资源请求只使用你选定的权限；失败时不会自动附加管理密钥。管理统计始终使用管理权限。切换方式会清除原资源快照。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("生成 TPS 按有效输出 Token 总和 ÷ 有效生成时长总和计算；生成时长为 latency − TTFT。它不是单次速度的平均，也不除以 30 分钟窗口。同名模型的不同平台与流式模式分别统计。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("窗口截至最后完整分钟。缺失字段保持未知；失败请求可保留部分用量，但不计入成功生成 TPS。分页到末页也不能证明跨页是数据库原子快照。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var modelsSection: some View {
        if let error = coordinator.store?.error {
            Section { CAPErrorNotice(error: error, preservesData: coordinator.overviewPresentation != nil) }
        }
        if let presentation = coordinator.overviewPresentation {
            let snapshot = presentation.snapshot
            Section("窗口概览") {
                Label(CAPUsagePresentation.completenessTitle(snapshot.requests.completeness),
                    systemImage: snapshot.requests.completeness == .singlePage ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(snapshot.requests.completeness == .singlePage ? palette.statusOK : palette.statusWarn)
                    .accessibilityIdentifier("cap.overview.loaded")
                Text(CAPUsagePresentation.completenessSubtitle(snapshot.requests.completeness,
                    itemCount: snapshot.requests.items.count))
                    .font(.footnote).foregroundStyle(.secondary)
                CAPSummaryRows(summary: presentation.summary)
                NavigationLink("全部窗口计数与样本") {
                    CAPSummaryDetailView(title: "窗口统计", summary: presentation.summary, window: snapshot.window)
                }
            }
            Section("模型 · 平台 · 流式模式") {
                if presentation.models.isEmpty {
                    CAPEmptyState(title: "当前窗口没有请求", systemImage: "tray",
                        detail: "此结果仅对应显示的查询窗口。")
                }
                ForEach(presentation.models) { item in
                    NavigationLink {
                        CAPModelDetailView(item: item.value, window: snapshot.window)
                    } label: { CAPModelRow(item: item.value) }
                }
            }
        } else {
            Section {
                CAPEmptyState(title: "查看近 30 分钟用量", systemImage: "chart.bar",
                    detail: "按需读取请求集合、模型用量与加权速度。切换栏目不会自动加载全部端点。")
                Button("读取概览", systemImage: "arrow.clockwise") {
                    Task { await coordinator.refreshOverview() }
                }
                .disabled(coordinator.store?.isRefreshing == true)
                .accessibilityIdentifier("cap.loadOverview")
            }
        }
    }

    @ViewBuilder private var analyticsSection: some View {
        Section {
            Picker("分组每页条数", selection: $groupPageSize) {
                Text("25").tag(25)
                Text("50").tag(50)
                Text("100").tag(100)
            }
            .pickerStyle(.menu)
            Button("读取趋势、分组和费用", systemImage: "chart.xyaxis.line") {
                Task { await coordinator.refreshDetails(groupOffset: 0, groupLimit: groupPageSize) }
            }
            .disabled(coordinator.store?.isLoadingDetails == true)
            .accessibilityIdentifier("cap.loadAnalytics")
            Text("四个响应分别生成。即使查询窗口相同，也不表示同一时刻的原子快照。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        if let error = coordinator.store?.detailsError {
            Section { CAPErrorNotice(error: error, preservesData: coordinator.analyticsPresentation != nil) }
        }
        if let presentation = coordinator.analyticsPresentation {
            Section("分析") {
                NavigationLink {
                    CAPInitialStatsView(presentation: presentation)
                } label: {
                    CAPDestinationLabel(title: "汇总与保留范围", systemImage: "sum",
                        detail: "生成于 \(presentation.snapshot.initial.generatedAt)")
                }
                .accessibilityIdentifier("cap.analytics.loaded")
                NavigationLink {
                    CAPTrendsView(presentation: presentation)
                } label: {
                    CAPDestinationLabel(title: "时间桶趋势", systemImage: "chart.dots.scatter",
                        detail: "\(presentation.trendRows.count) 个返回桶 · \(presentation.snapshot.trends.bucketSeconds) 秒分辨率")
                }
                NavigationLink {
                    CAPCostsView(presentation: presentation)
                } label: {
                    CAPDestinationLabel(title: "费用与计价覆盖", systemImage: "creditcard",
                        detail: CAPUsagePresentation.formatUSD(presentation.snapshot.costs.summary.totalUsd,
                            currency: presentation.snapshot.costs.currency))
                }
                NavigationLink {
                    CAPGroupsView(coordinator: coordinator)
                } label: {
                    CAPDestinationLabel(title: "分组明细", systemImage: "square.stack.3d.up",
                        detail: "已加载 \(presentation.groups.count) 项 · 报告总计 \(presentation.snapshot.groups.total) 项")
                }
            }
            Section("费用覆盖") {
                Label(CAPUsagePresentation.costReliabilityBanner(presentation.snapshot.costs),
                    systemImage: CAPUsagePresentation.costCoverageIsComplete(presentation.snapshot.costs) ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(CAPUsagePresentation.costCoverageIsComplete(presentation.snapshot.costs) ? palette.statusOK : palette.statusWarn)
            }
        } else {
            Section {
                CAPEmptyState(title: "尚未读取分析", systemImage: "chart.xyaxis.line",
                    detail: "读取后可以分别查看汇总、完整趋势表、分页分组与费用明细。")
            }
        }
    }

    @ViewBuilder private var requestsSection: some View {
        Section {
            Picker("每页请求数", selection: $requestPageSize) {
                Text("25").tag(25)
                Text("50").tag(50)
                Text("100").tag(100)
            }
            .pickerStyle(.menu)
            Button("读取当前窗口首页", systemImage: "list.bullet.rectangle") {
                Task { await coordinator.loadRequestPage(offset: 0, limit: requestPageSize) }
            }
            .disabled(coordinator.isLoadingRequestPage)
            .accessibilityIdentifier("cap.loadRequests")
        }
        if let error = coordinator.requestPageError {
            Section { CAPErrorNotice(error: error, preservesData: coordinator.requestPagePresentation != nil) }
        }
        if let presentation = coordinator.requestPagePresentation {
            let page = presentation.page
            Section("分页与来源") {
                CAPValueRow(title: "已加载 / 报告总计", value: "\(page.items.count) / \(page.total)")
                    .accessibilityIdentifier("cap.requests.loaded")
                CAPValueRow(title: "页偏移 / 每页上限", value: "\(page.offset) / \(page.limit)")
                CAPValueRow(title: "生成时间", value: page.generatedAt ?? "未知")
                CAPValueRow(title: "价格簿版本", value: page.priceBookRevision.map { "#\($0)" } ?? "未知")
                Text("翻页固定当前请求窗口；服务端迟到写入仍可能改变分页内容。")
                    .font(.footnote).foregroundStyle(.secondary)
                requestPagination(presentation)
            }
            Section("请求") {
                if presentation.rows.isEmpty {
                    CAPEmptyState(title: "此页没有请求", systemImage: "tray",
                        detail: "空页不代表其他页或其他窗口没有记录。")
                }
                ForEach(presentation.rows) { item in
                    NavigationLink {
                        CAPRequestDetailView(request: item.value, window: presentation.window,
                            generatedAt: page.generatedAt, priceBookRevision: page.priceBookRevision)
                    } label: { CAPRequestRow(request: item.value) }
                }
            }
        } else {
            Section {
                CAPEmptyState(title: "按需查看请求明细", systemImage: "list.bullet.rectangle",
                    detail: "保留请求结果的成功、失败与未知三种状态，以及完整 Token、TTFT、延迟和来源字段。")
            }
        }
    }

    private func requestPagination(_ presentation: CAPRequestPagePresentation) -> some View {
        let page = presentation.page
        let next = CAPPageNavigation.nextOffset(offset: page.offset, limit: page.limit,
            count: page.items.count, total: page.total)
        return HStack {
            Button("上一页", systemImage: "chevron.backward") {
                Task { await coordinator.loadRequestPage(window: presentation.window,
                    offset: max(0, page.offset - page.limit), limit: page.limit) }
            }
            .disabled(page.offset <= 0 || coordinator.isLoadingRequestPage)
            Spacer()
            Button("下一页", systemImage: "chevron.forward") {
                guard let next else { return }
                Task { await coordinator.loadRequestPage(window: presentation.window, offset: next, limit: page.limit) }
            }
            .disabled(next == nil || coordinator.isLoadingRequestPage)
        }
        .buttonStyle(.borderless)
        .frame(minHeight: 44)
    }

    @ViewBuilder private var managementSection: some View {
        Section {
            Button("读取管理统计", systemImage: "arrow.clockwise") {
                Task { await coordinator.refreshManagementStats() }
            }
            .disabled(coordinator.isLoadingManagementStats)
            .accessibilityIdentifier("cap.loadManagement")
            Text("使用管理权限，保留管理请求的并发与限流保护。下面的来源分别显示各自窗口和生成时间。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        if let error = coordinator.managementStatsError {
            Section { CAPErrorNotice(error: error, preservesData: coordinator.managementPresentation != nil) }
        }
        if let presentation = coordinator.managementPresentation {
            Section("管理统计") {
                CAPValueRow(title: "统计窗口", value: CAPUsagePresentation.windowBadgeText(presentation.window))
                    .accessibilityIdentifier("cap.management.loaded")
                CAPValueRow(title: "生成时间", value: presentation.stats.generatedAt ?? "未知")
                CAPValueRow(title: "请求 / 失败", value: "\(CAPDisplay.counter(presentation.stats.summary.requests)) / \(CAPDisplay.counter(presentation.stats.summary.failedRequests))")
                CAPValueRow(title: "总 Token", value: CAPDisplay.counter(presentation.stats.summary.totalTokens))
                NavigationLink("全部管理统计与来源") {
                    CAPManagementDetailView(presentation: presentation)
                }
            }
        } else {
            Section {
                CAPEmptyState(title: "尚未读取管理统计", systemImage: "server.rack",
                    detail: "这组统计使用独立管理路由；资源端点成功不代表管理权限有效。")
            }
        }
        if let resource = coordinator.analyticsPresentation {
            Section("资源汇总 · 独立来源") {
                CAPValueRow(title: "统计窗口", value: CAPUsagePresentation.windowBadgeText(resource.snapshot.window))
                CAPValueRow(title: "生成时间", value: resource.snapshot.initial.generatedAt)
                CAPValueRow(title: "请求 / 失败", value: "\(CAPDisplay.counter(resource.snapshot.initial.summary.requests)) / \(CAPDisplay.counter(resource.snapshot.initial.summary.failedRequests))")
                CAPValueRow(title: "总 Token", value: CAPDisplay.counter(resource.snapshot.initial.summary.totalTokens))
                NavigationLink("全部资源汇总") { CAPInitialStatsView(presentation: resource) }
                Text("不同来源不相加；窗口或生成时间不同也不能直接当作同一时刻的差额。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func refreshCurrentSection() async {
        switch selectedSection {
        case .models: await coordinator.refreshOverview()
        case .details: await coordinator.refreshDetails(groupOffset: 0, groupLimit: groupPageSize)
        case .requests: await coordinator.loadRequestPage(offset: 0, limit: requestPageSize)
        case .management: await coordinator.refreshManagementStats()
        }
    }
}
#endif
