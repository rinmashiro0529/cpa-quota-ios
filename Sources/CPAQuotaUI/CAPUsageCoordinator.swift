import Foundation
import Observation
import CPAQuotaKit

@MainActor
@Observable
public final class CAPUsageWorkspaceCoordinator {
    public private(set) var store: CAPUsageStore?
    public private(set) var client: CAPUsageClient?
    public private(set) var activeWindow: CAPUsageWindow
    public private(set) var selectedRange: CAPUsageRange = .last30Minutes
    public private(set) var managementStats: CAPUsageStats?
    public private(set) var managementStatsWindow: CAPUsageWindow?
    public private(set) var managementStatsError: CAPUsageError?
    public private(set) var isLoadingManagementStats = false

    public private(set) var requestPage: CAPUsageRequestPage?
    public private(set) var requestPageWindow: CAPUsageWindow?
    public private(set) var requestPageError: CAPUsageError?
    public private(set) var isLoadingRequestPage = false
    public private(set) var requestPageOffset = 0
    public private(set) var requestPageLimit = 50

    // Immutable presentation data is published with its original query window.
    // Large request aggregation and row identity work never run in View.body.
    private(set) var overviewPresentation: CAPOverviewPresentation?
    private(set) var initialPresentation: CAPInitialPresentation?
    private(set) var trendsPresentation: CAPTrendsPresentation?
    private(set) var groupsPresentation: CAPGroupsPresentation?
    private(set) var costsPresentation: CAPCostsPresentation?
    private(set) var requestPagePresentation: CAPRequestPagePresentation?
    private(set) var managementPresentation: CAPManagementPresentation?

    public var resourceAccess: CAPUsageResourceAccess {
        didSet {
            guard !oldValue.isSameMode(as: resourceAccess) else { return }
            rebuildStoreForAccessChange()
        }
    }

    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var overviewTask: Task<Void, Never>?
    @ObservationIgnored private var detailsTask: Task<Void, Never>?
    @ObservationIgnored private var managementTask: Task<Void, Never>?
    @ObservationIgnored private var requestPageTask: Task<Void, Never>?
    @ObservationIgnored private var overviewRequestID: UUID?
    @ObservationIgnored private var detailsRequestID: UUID?
    @ObservationIgnored private var managementRequestID: UUID?
    @ObservationIgnored private var pageRequestID: UUID?

    public init(
        resourceAccess: CAPUsageResourceAccess = .anonymous,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.resourceAccess = resourceAccess
        self.clock = clock
        self.activeWindow = CAPUsageWindow(now: clock())
    }

    public func bind(client: CAPUsageClient?) {
        cancelAll()
        self.client = client
        self.managementStats = nil
        self.managementStatsWindow = nil
        self.managementStatsError = nil
        self.requestPage = nil
        self.requestPageWindow = nil
        self.requestPageError = nil
        self.requestPageOffset = 0
        self.overviewPresentation = nil
        self.initialPresentation = nil
        self.trendsPresentation = nil
        self.groupsPresentation = nil
        self.costsPresentation = nil
        self.requestPagePresentation = nil
        self.managementPresentation = nil
        self.activeWindow = CAPUsageWindow(now: clock(), range: selectedRange)
        if let client {
            self.store = CAPUsageStore(client: client, access: resourceAccess)
        } else {
            self.store = nil
        }
    }

    /// Selection cancels in-flight reads without fetching new endpoints. Existing
    /// presentations keep their original windows until the user refreshes them.
    public func selectRange(_ range: CAPUsageRange) {
        guard selectedRange != range else { return }
        cancelAll()
        selectedRange = range
        activeWindow = CAPUsageWindow(now: clock(), range: range)
    }

    public func teardown() {
        bind(client: nil)
    }

    private func rebuildStoreForAccessChange() {
        cancelAll()
        requestPage = nil
        requestPageWindow = nil
        requestPageError = nil
        requestPageOffset = 0
        overviewPresentation = nil
        initialPresentation = nil
        trendsPresentation = nil
        groupsPresentation = nil
        costsPresentation = nil
        requestPagePresentation = nil
        if let client {
            store = CAPUsageStore(client: client, access: resourceAccess)
        } else {
            store = nil
        }
    }

    public func cancelAll() {
        generation &+= 1
        overviewRequestID = nil
        detailsRequestID = nil
        managementRequestID = nil
        pageRequestID = nil
        overviewTask?.cancel()
        overviewTask = nil
        store?.cancelOverview()
        detailsTask?.cancel()
        detailsTask = nil
        store?.cancelDetails()
        managementTask?.cancel()
        managementTask = nil
        requestPageTask?.cancel()
        requestPageTask = nil
        isLoadingManagementStats = false
        isLoadingRequestPage = false
    }

    public func refreshOverview(now: Date? = nil) async {
        guard let store, !Task.isCancelled else { return }
        overviewTask?.cancel()
        let requestID = UUID()
        overviewRequestID = requestID
        let window = CAPUsageWindow(now: now ?? clock(), range: selectedRange)
        activeWindow = window
        let currentGen = generation
        let task = Task { @MainActor in
            await store.refresh(window: window)
            guard !Task.isCancelled, self.generation == currentGen,
                  self.overviewRequestID == requestID, self.store === store,
                  store.error == nil, let snapshot = store.snapshot else { return }
            self.overviewPresentation = CAPOverviewPresentation(snapshot: snapshot)
        }
        overviewTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
        if currentGen == generation, overviewRequestID == requestID {
            overviewTask = nil
            overviewRequestID = nil
        }
    }

    private enum DetailsRead: Sendable {
        case all(CAPUsageResourceQuery)
        case groups(CAPUsageResourceQuery)
        case retry(CAPUsageDetailResource)
        case retryFailed
    }

    public func refreshDetails(window: CAPUsageWindow? = nil, groupOffset: Int = 0, groupLimit: Int = 100) async {
        let window = window ?? activeWindow
        await loadDetails(.all(CAPUsageResourceQuery(window: window, groupOffset: groupOffset, groupLimit: groupLimit)))
    }

    public func refreshGroupPage(window: CAPUsageWindow, groupOffset: Int, groupLimit: Int) async {
        await loadDetails(.groups(CAPUsageResourceQuery(window: window, groupOffset: groupOffset, groupLimit: groupLimit)))
    }

    public func retryDetailResource(_ resource: CAPUsageDetailResource) async {
        await loadDetails(.retry(resource))
    }

    public func retryFailedDetails() async {
        await loadDetails(.retryFailed)
    }

    private func loadDetails(_ read: DetailsRead) async {
        guard let store, !Task.isCancelled else { return }
        detailsTask?.cancel()
        let requestID = UUID()
        detailsRequestID = requestID
        let currentGen = generation
        let task = Task { @MainActor in
            let publish: @MainActor @Sendable (CAPUsageDetailResource) -> Void = { resource in
                guard !Task.isCancelled, self.generation == currentGen,
                      self.detailsRequestID == requestID, self.store === store else { return }
                self.publishResource(resource, from: store)
            }
            switch read {
            case .all(let query):
                await store.refreshDetails(window: query.window, groupOffset: query.groupOffset,
                    groupLimit: query.groupLimit, onResourceUpdate: publish)
            case .groups(let query):
                await store.refreshGroupPage(window: query.window, groupOffset: query.groupOffset,
                    groupLimit: query.groupLimit, onResourceUpdate: publish)
            case .retry(let resource):
                await store.retryDetailResource(resource, onResourceUpdate: publish)
            case .retryFailed:
                await store.retryFailedDetails(onResourceUpdate: publish)
            }
        }
        detailsTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
        if currentGen == generation, detailsRequestID == requestID {
            detailsTask = nil
            detailsRequestID = nil
        }
    }

    private func publishResource(_ resource: CAPUsageDetailResource, from store: CAPUsageStore) {
        switch resource {
        case .initial:
            if store.initialState.error == nil, let snapshot = store.initialState.snapshot {
                initialPresentation = CAPInitialPresentation(snapshot: snapshot)
            }
        case .trends:
            if store.trendsState.error == nil, let snapshot = store.trendsState.snapshot {
                trendsPresentation = CAPTrendsPresentation(snapshot: snapshot)
            }
        case .groups:
            if store.groupsState.error == nil, let snapshot = store.groupsState.snapshot {
                groupsPresentation = CAPGroupsPresentation(snapshot: snapshot)
            }
        case .costs:
            if store.costsState.error == nil, let snapshot = store.costsState.snapshot {
                costsPresentation = CAPCostsPresentation(snapshot: snapshot)
            }
        }
    }

    public func refreshManagementStats() async {
        guard let client, !Task.isCancelled else { return }
        managementTask?.cancel()
        let requestID = UUID()
        managementRequestID = requestID
        isLoadingManagementStats = true
        managementStatsError = nil
        let window = activeWindow
        let currentGen = generation
        let task = Task { @MainActor in
            defer {
                if self.generation == currentGen, self.managementRequestID == requestID {
                    self.isLoadingManagementStats = false
                    self.managementTask = nil
                    self.managementRequestID = nil
                }
            }
            do {
                let stats = try await client.loadManagementStats(window: window)
                guard !Task.isCancelled, self.generation == currentGen,
                      self.managementRequestID == requestID else { return }
                self.managementStats = stats
                self.managementStatsWindow = window
                self.managementPresentation = CAPManagementPresentation(stats: stats, window: window)
            } catch is CancellationError {
            } catch let error as CAPUsageError {
                guard !Task.isCancelled, self.generation == currentGen,
                      self.managementRequestID == requestID else { return }
                self.managementStatsError = error
            } catch let error as CPAError {
                guard !Task.isCancelled, self.generation == currentGen,
                      self.managementRequestID == requestID else { return }
                self.managementStatsError = .management(error)
            } catch {
                guard !Task.isCancelled, self.generation == currentGen,
                      self.managementRequestID == requestID else { return }
                self.managementStatsError = .network
            }
        }
        managementTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
    }

    public func loadRequestPage(window: CAPUsageWindow? = nil, offset: Int = 0, limit: Int = 50) async {
        guard let client, !Task.isCancelled else { return }
        requestPageTask?.cancel()
        let requestID = UUID()
        pageRequestID = requestID
        isLoadingRequestPage = true
        requestPageError = nil
        let window = window ?? activeWindow
        let access = resourceAccess
        let currentGen = generation
        let task = Task { @MainActor in
            defer {
                if self.generation == currentGen, self.pageRequestID == requestID {
                    self.isLoadingRequestPage = false
                    self.requestPageTask = nil
                    self.pageRequestID = nil
                }
            }
            do {
                let page = try await client.loadRequestPage(
                    window: window,
                    offset: offset,
                    limit: limit,
                    access: access
                )
                guard !Task.isCancelled, self.generation == currentGen,
                      self.pageRequestID == requestID else { return }
                self.requestPage = page
                self.requestPageWindow = window
                self.requestPageOffset = offset
                self.requestPageLimit = limit
                self.requestPagePresentation = CAPRequestPagePresentation(page: page, window: window)
            } catch is CancellationError {
            } catch let error as CAPUsageError {
                guard !Task.isCancelled, self.generation == currentGen,
                      self.pageRequestID == requestID else { return }
                self.requestPageError = error
            } catch let error as CPAError {
                guard !Task.isCancelled, self.generation == currentGen,
                      self.pageRequestID == requestID else { return }
                self.requestPageError = .management(error)
            } catch {
                guard !Task.isCancelled, self.generation == currentGen,
                      self.pageRequestID == requestID else { return }
                self.requestPageError = .network
            }
        }
        requestPageTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
    }
}

public enum CAPUsagePresentation {
    public static func rangeTitle(_ range: CAPUsageRange) -> String {
        switch range {
        case .last30Minutes: "30 分钟"
        case .last24Hours: "24 小时"
        case .last7Days: "7 天"
        }
    }

    /// A retention timestamp describes available history, not completeness or a
    /// frozen multi-endpoint snapshot. Missing/malformed metadata stays unknown.
    public static func retentionDescription(retainedSince: String?, window: CAPUsageWindow) -> String {
        guard let retainedSince, !retainedSince.isEmpty else {
            return "服务端保留范围尚未确认；当前结果不能证明所选范围都有数据。"
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        guard let retainedStart = fractional.date(from: retainedSince) ?? standard.date(from: retainedSince),
              retainedStart.timeIntervalSince1970.isFinite else {
            return "服务端保留范围尚未确认；当前结果不能证明所选范围都有数据。"
        }
        if retainedStart >= window.end {
            return "查询窗口早于服务端保留起点，不能据此认定该时段没有用量。"
        }
        if retainedStart > window.start {
            return "查询窗口起点早于服务端保留起点，较早时段的数据不可用；不能视为全窗口统计。"
        }
        return "服务端保留起点覆盖此窗口；迟到写入、分页和响应预算仍可能影响完整性。"
    }

    public static func windowBadgeText(_ window: CAPUsageWindow, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "窗口 · \(formatter.string(from: window.start))–\(formatter.string(from: window.end))"
    }

    public static func streamLabel(_ stream: Bool?) -> String {
        switch stream {
        case .some(true): "Stream"
        case .some(false): "Non-Stream"
        case .none: "Stream 未知"
        }
    }

    public static func generationTPSText(_ summary: CAPUsageSummary) -> String {
        guard let tps = summary.generationTPS, tps.isFinite, summary.generationSamples > 0 else {
            return "无有效生成 TPS 样本"
        }
        return String(format: "%.2f token/s", tps)
    }

    public static func generationCoverageText(_ summary: CAPUsageSummary) -> String {
        "有效生成样本 \(summary.generationSamples) / 总请求 \(summary.totalRequests)"
    }

    public static func endToEndTPSText(_ summary: CAPUsageSummary) -> String {
        guard let tps = summary.endToEndTPS, tps.isFinite, summary.endToEndSamples > 0 else {
            return "无端到端速度样本"
        }
        return String(format: "%.2f token/s (样本 %d/%d)", tps, summary.endToEndSamples, summary.totalRequests)
    }

    public static func completenessTitle(_ completeness: CAPUsageCompleteness) -> String {
        switch completeness {
        case .singlePage:
            return "当前窗口的响应为单页"
        case .offsetUnverified:
            return "已读取至报告末页"
        case .truncated:
            return "数据不完整"
        }
    }

    public static func completenessSubtitle(_ completeness: CAPUsageCompleteness, itemCount: Int) -> String {
        switch completeness {
        case .singlePage:
            return "当前响应在单页内返回 \(itemCount) 条记录；不排除后续迟到写入。"
        case .offsetUnverified:
            return "已读取 \(itemCount) 条记录至报告末页；读取期间数据可能变化，跨页结果并非冻结快照。"
        case .truncated:
            return "已保守停止于 \(itemCount) 条记录（受 10 页 / 5000 条 / 4MiB 单页 / 8MiB 总预算或去重一致性保护），不可视为全窗口完整统计。"
        }
    }

    public static func formatCounter(_ value: UInt64?) -> String {
        guard let value else { return "未知" }
        return "\(value)"
    }

    public static func formatNanosecondsAsMillis(_ ns: UInt64?) -> String {
        guard let ns else { return "未知" }
        let ms = Double(ns) / 1_000_000.0
        return String(format: "%.1f ms", ms)
    }

    public static func formatUSD(_ amount: Double?, currency: String = "USD") -> String {
        guard let amount, amount.isFinite else { return "未知" }
        return String(format: "%.4f %@", amount, currency)
    }

    public static func costReliabilityBanner(_ costs: CAPUsageCosts) -> String {
        let unpriced = costs.summary.unpricedRequests
        let missingCount = costs.missingPrices.count
        if unpriced.map({ $0 > 0 }) == true || missingCount > 0 {
            return "存在未计价请求 (\(formatCounter(unpriced)) 次) 或缺失价格条目 (\(missingCount) 个模型) · 缺价不等于免费 ($0)"
        }
        guard costCoverageIsComplete(costs) else { return "计价覆盖未知或计数不一致，不能据此认定所有请求都已计价。" }
        return "价格簿版本 #\(costs.priceBookRevision) · 估算基准: \(costs.estimateBasis)"
    }

    public static func costCoverageIsComplete(_ costs: CAPUsageCosts) -> Bool {
        guard let requests = costs.summary.requests, let priced = costs.summary.pricedRequests,
              let unpriced = costs.summary.unpricedRequests else { return false }
        return requests == priced && unpriced == 0 && costs.missingPrices.isEmpty
    }

    public static func requestOutcomeText(_ request: CAPUsageRequest) -> String {
        switch request.failed {
        case .some(true): "失败 (\(request.failureStatus.map(String.init) ?? "err"))"
        case .some(false): request.result ?? "成功"
        case .none: "结果未知"
        }
    }

    public static func failureRateText(_ counters: CAPUsageCounters) -> String {
        guard let requests = counters.requests, let failed = counters.failedRequests,
              failed <= requests else { return "未知" }
        guard requests > 0 else { return "暂无请求" }
        return String(format: "%.1f%%", Double(failed) / Double(requests) * 100)
    }

    public static func groupPaginationBanner(offset: Int, limit: Int, count: Int, total: Int) -> String {
        "当前显示 \(count) 项 (offset \(offset), limit \(limit)) / 报告总计 \(total) 项 · 单页结果不代表已加载全部"
    }

    public static func errorDescription(_ error: CAPUsageError, now: Date = Date()) -> (title: String, detail: String) {
        switch error {
        case .pluginUnavailable:
            return (
                "当前服务未提供 CAP 用量接口",
                "请在 CPA 服务端检查 CAP 用量插件是否已安装并启用。额度页面仍可独立使用。"
            )
        case .invalidResponse:
            return (
                "响应数据异常，暂时无法显示",
                "无法显示本次用量结果，请检查服务端和插件版本后重试。额度页面仍可独立使用。"
            )
        case .network:
            return (
                "CAP 用量网络请求失败",
                "无法安全连接至 CPA 用量端点，请检查网络或服务状态。"
            )
        case .management(let cpaError):
            let pres = ErrorPresentation(error: cpaError)
            return (pres.title, pres.summary + " " + pres.recoveryAdvice)
        case .resourceRejected(let statusCode, let retryAt):
            if statusCode == 429 {
                if let retryAt, let secs = QuotaTime.remainingSeconds(until: retryAt, now: now), secs > 0 {
                    return (
                        "CAP 资源接口触发限流 (429)",
                        "独立资源冷却中（剩余约 \(secs) 秒），冷却结束前不会绕过限制重复请求。"
                    )
                }
                return ("CAP 资源接口触发限流 (429)", "上次请求被限流，等待重试验证；倒计时结束不代表服务已恢复。")
            }
            if statusCode == 401 || statusCode == 403 {
                return (
                    "CAP 资源访问被拒绝 (HTTP \(statusCode))",
                    "当前认证方式无权读取该资源；不会自动切换认证方式或重发管理密钥。"
                )
            }
            return (
                "CAP 资源请求被拒绝 (HTTP \(statusCode))",
                "服务端拒绝了本次 CAP 资源读取请求。"
            )
        }
    }
}


extension CAPUsageResourceAccess {
    public func isSameMode(as other: CAPUsageResourceAccess) -> Bool {
        switch (self, other) {
        case (.anonymous, .anonymous), (.managementKey, .managementKey):
            return true
        default:
            return false
        }
    }
}
