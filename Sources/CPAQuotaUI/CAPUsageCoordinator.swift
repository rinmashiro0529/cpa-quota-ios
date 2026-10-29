import Foundation
import Observation
import CPAQuotaKit

@MainActor
@Observable
public final class CAPUsageWorkspaceCoordinator {
    public private(set) var store: CAPUsageStore?
    public private(set) var client: CAPUsageClient?
    public private(set) var activeWindow: CAPUsageWindow
    public private(set) var managementStats: CAPUsageStats?
    public private(set) var managementStatsError: CAPUsageError?
    public private(set) var isLoadingManagementStats = false

    public private(set) var requestPage: CAPUsageRequestPage?
    public private(set) var requestPageError: CAPUsageError?
    public private(set) var isLoadingRequestPage = false
    public private(set) var requestPageOffset = 0
    public private(set) var requestPageLimit = 50

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
        generation &+= 1
        self.client = client
        self.managementStats = nil
        self.managementStatsError = nil
        self.requestPage = nil
        self.requestPageError = nil
        self.requestPageOffset = 0
        self.activeWindow = CAPUsageWindow(now: clock())
        if let client {
            self.store = CAPUsageStore(client: client, access: resourceAccess)
        } else {
            self.store = nil
        }
    }

    public func teardown() {
        bind(client: nil)
    }

    private func rebuildStoreForAccessChange() {
        cancelAll()
        generation &+= 1
        requestPage = nil
        requestPageError = nil
        requestPageOffset = 0
        if let client {
            store = CAPUsageStore(client: client, access: resourceAccess)
        } else {
            store = nil
        }
    }

    public func cancelAll() {
        overviewTask?.cancel()
        overviewTask = nil
        detailsTask?.cancel()
        detailsTask = nil
        managementTask?.cancel()
        managementTask = nil
        requestPageTask?.cancel()
        requestPageTask = nil
        isLoadingManagementStats = false
        isLoadingRequestPage = false
    }

    public func refreshOverview(now: Date? = nil) async {
        guard let store else { return }
        overviewTask?.cancel()
        let window = CAPUsageWindow(now: now ?? clock())
        activeWindow = window
        let currentGen = generation
        let task = Task { @MainActor in
            await store.refresh(window: window)
        }
        overviewTask = task
        await task.value
        if currentGen == generation {
            overviewTask = nil
        }
    }

    public func refreshDetails(groupOffset: Int = 0, groupLimit: Int = 100) async {
        guard let store else { return }
        detailsTask?.cancel()
        let window = store.snapshot?.window ?? activeWindow
        let currentGen = generation
        let task = Task { @MainActor in
            await store.refreshDetails(window: window, groupOffset: groupOffset, groupLimit: groupLimit)
        }
        detailsTask = task
        await task.value
        if currentGen == generation {
            detailsTask = nil
        }
    }

    public func refreshManagementStats() async {
        guard let client else { return }
        managementTask?.cancel()
        isLoadingManagementStats = true
        managementStatsError = nil
        let window = store?.snapshot?.window ?? activeWindow
        let currentGen = generation
        let task = Task { @MainActor in
            do {
                let stats = try await client.loadManagementStats(window: window)
                guard !Task.isCancelled, self.generation == currentGen else { return }
                self.managementStats = stats
            } catch is CancellationError {
            } catch let error as CAPUsageError {
                guard self.generation == currentGen else { return }
                self.managementStatsError = error
            } catch let error as CPAError {
                guard self.generation == currentGen else { return }
                self.managementStatsError = .management(error)
            } catch {
                guard self.generation == currentGen else { return }
                self.managementStatsError = .network
            }
            if self.generation == currentGen {
                self.isLoadingManagementStats = false
            }
        }
        managementTask = task
        await task.value
    }

    public func loadRequestPage(offset: Int = 0, limit: Int = 50) async {
        guard let client else { return }
        requestPageTask?.cancel()
        isLoadingRequestPage = true
        requestPageError = nil
        let window = store?.snapshot?.window ?? activeWindow
        let access = resourceAccess
        let currentGen = generation
        let task = Task { @MainActor in
            do {
                let page = try await client.loadRequestPage(
                    window: window,
                    offset: offset,
                    limit: limit,
                    access: access
                )
                guard !Task.isCancelled, self.generation == currentGen else { return }
                self.requestPage = page
                self.requestPageOffset = offset
                self.requestPageLimit = limit
            } catch is CancellationError {
            } catch let error as CAPUsageError {
                guard self.generation == currentGen else { return }
                self.requestPageError = error
            } catch let error as CPAError {
                guard self.generation == currentGen else { return }
                self.requestPageError = .management(error)
            } catch {
                guard self.generation == currentGen else { return }
                self.requestPageError = .network
            }
            if self.generation == currentGen {
                self.isLoadingRequestPage = false
            }
        }
        requestPageTask = task
        await task.value
    }
}

public enum CAPUsagePresentation {
    public static func windowBadgeText(_ window: CAPUsageWindow, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return "近 30 分钟 · 截至 \(formatter.string(from: window.end)) (\(formatter.string(from: window.start))–\(formatter.string(from: window.end)))"
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
            return "单页完整 (singlePage)"
        case .offsetUnverified:
            return "分页已达末页 · 未冻结快照 (offsetUnverified)"
        case .truncated:
            return "已截断 · 达分页/体积预算或页异常 (truncated)"
        }
    }

    public static func completenessSubtitle(_ completeness: CAPUsageCompleteness, itemCount: Int) -> String {
        switch completeness {
        case .singlePage:
            return "当前响应在单页内返回 \(itemCount) 条记录；不排除后续迟到写入。"
        case .offsetUnverified:
            return "已读取 \(itemCount) 条记录至报告末页，但分页 offset 不提供跨页原子快照证明。"
        case .truncated:
            return "已保守停止于 \(itemCount) 条记录（受 10 页 / 5000 条 / 4MiB 单页 / 8MiB 总预算或去重一致性保护），不可视为全窗口完整统计。"
        }
    }

    public static func formatCounter(_ value: UInt64?) -> String {
        guard let value else { return "未知 (nil)" }
        return "\(value)"
    }

    public static func formatNanosecondsAsMillis(_ ns: UInt64?) -> String {
        guard let ns else { return "未知 (nil)" }
        let ms = Double(ns) / 1_000_000.0
        return String(format: "%.1f ms", ms)
    }

    public static func formatUSD(_ amount: Double?, currency: String = "USD") -> String {
        guard let amount, amount.isFinite else { return "未知 (nil)" }
        return String(format: "%.4f %@", amount, currency)
    }

    public static func costReliabilityBanner(_ costs: CAPUsageCosts) -> String {
        let unpriced = costs.summary.unpricedRequests ?? 0
        let missingCount = costs.missingPrices.count
        if unpriced > 0 || missingCount > 0 {
            return "存在未计价请求 (\(unpriced) 次) 或缺失价格条目 (\(missingCount) 个模型) · 缺价不等于免费 ($0)"
        }
        return "价格簿版本 #\(costs.priceBookRevision) · 估算基准: \(costs.estimateBasis)"
    }

    public static func groupPaginationBanner(offset: Int, limit: Int, count: Int, total: Int) -> String {
        "当前显示 \(count) 项 (offset \(offset), limit \(limit)) / 报告总计 \(total) 项 · 单页结果不代表已加载全部"
    }

    public static func errorDescription(_ error: CAPUsageError, now: Date = Date()) -> (title: String, detail: String) {
        switch error {
        case .pluginUnavailable:
            return (
                "CAP 用量插件路由不可用 (404)",
                "服务端未安装或未暴露 cap-token-usage-tracker 路由；客户端不会将 404 伪装为空统计。"
            )
        case .invalidResponse:
            return (
                "CAP 响应格式或预算校验未通过",
                "响应超过 4MiB 上限、字段类型不符或分页参数异常，已拒绝解析。"
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
                if let retryAt {
                    let secs = max(0, Int(ceil(retryAt.timeIntervalSince(now))))
                    return (
                        "CAP 资源接口触发限流 (429)",
                        "独立资源冷却中（剩余约 \(secs) 秒），冷却结束前不会绕过限制重复请求。"
                    )
                }
                return ("CAP 资源接口触发限流 (429)", "独立资源冷却中，请稍后重试。")
            }
            if statusCode == 401 || statusCode == 403 {
                return (
                    "CAP 资源访问被拒绝 (HTTP \(statusCode))",
                    "当前认证模式无权读取该资源；客户端严格遵守显式认证选择，不会自动升级或降级偷偷重发管理密钥。"
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
