import Foundation
import CPAQuotaKit

/// A row identity includes its query and page. The same offset in a different
/// window must never reuse the previous request's navigation identity.
struct CAPRowIdentity: Hashable, Sendable {
    let scope: String
    let windowStart: Date
    let windowEnd: Date
    let pageOffset: Int
    let fields: [String?]
    let occurrence: Int
}

struct CAPDataRow<Value: Sendable>: Identifiable, Sendable {
    let id: CAPRowIdentity
    let value: Value
}

enum CAPRowBuilder {
    static func rows<Value: Sendable>(
        _ values: [Value], window: CAPUsageWindow, scope: String, offset: Int = 0,
        identity: (Value) -> [String?]
    ) -> [CAPDataRow<Value>] {
        var occurrences: [[String?]: Int] = [:]
        return values.map { value in
            let fields = identity(value)
            let occurrence = occurrences[fields, default: 0]
            occurrences[fields] = occurrence + 1
            return CAPDataRow(id: CAPRowIdentity(scope: scope, windowStart: window.start,
                windowEnd: window.end, pageOffset: offset, fields: fields, occurrence: occurrence), value: value)
        }
    }

    static func statIdentity(_ row: CAPUsageStatRow) -> [String?] {
        [row.provider, row.model, row.hour, row.executorType, row.alias, row.source,
         row.authType, row.serviceTier, row.reasoningEffort]
    }
}

/// Built only after a successful coordinator refresh, never from a View.body.
struct CAPOverviewPresentation: Sendable {
    let snapshot: CAPUsageSnapshot
    let summary: CAPUsageSummary
    let models: [CAPDataRow<CAPUsageModelSummary>]

    init(snapshot: CAPUsageSnapshot) {
        self.snapshot = snapshot
        summary = CAPUsageAggregation.summarize(snapshot.requests.items)
        models = CAPRowBuilder.rows(snapshot.models, window: snapshot.window, scope: "models") {
            [$0.provider, $0.model, $0.stream.map(String.init)]
        }
    }
}

struct CAPRequestPagePresentation: Sendable {
    let page: CAPUsageRequestPage
    let window: CAPUsageWindow
    let rows: [CAPDataRow<CAPUsageRequest>]

    init(page: CAPUsageRequestPage, window: CAPUsageWindow) {
        self.page = page
        self.window = window
        rows = CAPRowBuilder.rows(page.items, window: window, scope: "requests", offset: page.offset) {
            [$0.sequence.map(String.init), $0.time, $0.provider, $0.model,
             $0.stream.map(String.init), $0.executorType, $0.source, $0.alias]
        }
    }
}

struct CAPInitialPresentation: Sendable {
    let snapshot: CAPUsageResourceSnapshot<CAPUsageInitialStats>
    let initialModels: [CAPDataRow<CAPUsageStatRow>]
    let initialSeries: [CAPDataRow<CAPUsageStatRow>]

    init(snapshot: CAPUsageResourceSnapshot<CAPUsageInitialStats>) {
        self.snapshot = snapshot
        initialModels = CAPRowBuilder.rows(snapshot.value.models, window: snapshot.window,
            scope: "initial.models", identity: CAPRowBuilder.statIdentity)
        initialSeries = CAPRowBuilder.rows(snapshot.value.series, window: snapshot.window,
            scope: "initial.series", identity: CAPRowBuilder.statIdentity)
    }
}

struct CAPTrendsPresentation: Sendable {
    let snapshot: CAPUsageResourceSnapshot<CAPUsageTrends>
    let trendRows: [CAPDataRow<CAPUsageStatRow>]
    let trends: CAPTrendPresentation

    init(snapshot: CAPUsageResourceSnapshot<CAPUsageTrends>) {
        self.snapshot = snapshot
        trendRows = CAPRowBuilder.rows(snapshot.value.modelSeries, window: snapshot.window,
            scope: "trends", identity: CAPRowBuilder.statIdentity)
        trends = CAPTrendPresentation(rows: trendRows)
    }
}

struct CAPGroupsPresentation: Sendable {
    let snapshot: CAPUsageResourceSnapshot<CAPUsageGroups>
    let groups: [CAPDataRow<CAPUsageStatRow>]

    init(snapshot: CAPUsageResourceSnapshot<CAPUsageGroups>) {
        self.snapshot = snapshot
        groups = CAPRowBuilder.rows(snapshot.value.items, window: snapshot.window,
            scope: "groups", offset: snapshot.query.groupOffset, identity: CAPRowBuilder.statIdentity)
    }
}

struct CAPCostsPresentation: Sendable {
    let snapshot: CAPUsageResourceSnapshot<CAPUsageCosts>
    let costModels: [CAPDataRow<CAPUsageCostItem>]
    let costSeries: [CAPDataRow<CAPUsageCostItem>]
    let missingPrices: [CAPDataRow<CAPUsageMissingPrice>]

    init(snapshot: CAPUsageResourceSnapshot<CAPUsageCosts>) {
        self.snapshot = snapshot
        costModels = CAPRowBuilder.rows(snapshot.value.models, window: snapshot.window, scope: "cost.models") {
            [$0.provider, $0.model, $0.hour]
        }
        costSeries = CAPRowBuilder.rows(snapshot.value.series, window: snapshot.window, scope: "cost.series") {
            [$0.provider, $0.model, $0.hour]
        }
        missingPrices = CAPRowBuilder.rows(snapshot.value.missingPrices, window: snapshot.window, scope: "cost.missing") {
            [$0.provider, $0.model]
        }
    }
}

struct CAPManagementPresentation: Sendable {
    let stats: CAPUsageStats
    let window: CAPUsageWindow
    let groups: [CAPDataRow<CAPUsageStatRow>]
    let series: [CAPDataRow<CAPUsageStatRow>]
    let modelSeries: [CAPDataRow<CAPUsageStatRow>]

    init(stats: CAPUsageStats, window: CAPUsageWindow) {
        self.stats = stats
        self.window = window
        groups = CAPRowBuilder.rows(stats.groups ?? [], window: window,
            scope: "management.groups", identity: CAPRowBuilder.statIdentity)
        series = CAPRowBuilder.rows(stats.series ?? [], window: window,
            scope: "management.series", identity: CAPRowBuilder.statIdentity)
        modelSeries = CAPRowBuilder.rows(stats.modelSeries ?? [], window: window,
            scope: "management.models", identity: CAPRowBuilder.statIdentity)
    }
}

struct CAPTrendSeriesID: Hashable, Sendable {
    let dimensions: [String?]
}

struct CAPTrendPoint: Identifiable, Sendable {
    let id: CAPRowIdentity
    let date: Date
    let row: CAPUsageStatRow
}

struct CAPTrendSeries: Identifiable, Sendable {
    let id: CAPTrendSeriesID
    let title: String
    let points: [CAPTrendPoint]
}

enum CAPTrendMetric: String, CaseIterable, Identifiable, Sendable {
    case requests = "请求数"
    case outputTokens = "输出 Token"
    case totalTokens = "总 Token"
    case averageLatency = "平均延迟"

    var id: String { rawValue }
    var unit: String { self == .averageLatency ? "毫秒" : rawValue }

    func value(_ point: CAPTrendPoint) -> Double? {
        // A bare Double.init function reference can select init(bitPattern:)
        // for UInt64. Use explicit numeric conversion for every counter.
        switch self {
        case .requests: point.row.counters.requests.map { Double($0) }
        case .outputTokens: point.row.counters.outputTokens.map { Double($0) }
        case .totalTokens: point.row.counters.totalTokens.map { Double($0) }
        case .averageLatency: point.row.averageLatencyNs.map { Double($0) / 1_000_000 }
        }
    }
}

/// Keep the returned buckets. Missing timestamps/values stay in the table and
/// are excluded from the chart; no zero filling, interpolation, or reaggregation.
struct CAPTrendPresentation: Sendable {
    let series: [CAPTrendSeries]
    let unplottableTimeCount: Int

    init(rows: [CAPDataRow<CAPUsageStatRow>]) {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        var grouped: [CAPTrendSeriesID: [CAPTrendPoint]] = [:]
        var order: [CAPTrendSeriesID] = []
        var titles: [CAPTrendSeriesID: String] = [:]
        var invalid = 0
        for item in rows {
            let row = item.value
            guard let hour = row.hour,
                  let date = fractional.date(from: hour) ?? standard.date(from: hour),
                  date.timeIntervalSince1970.isFinite else {
                invalid += 1
                continue
            }
            let key = CAPTrendSeriesID(dimensions: [row.provider, row.model, row.executorType,
                row.alias, row.source, row.authType, row.serviceTier, row.reasoningEffort])
            if grouped[key] == nil {
                order.append(key)
                titles[key] = "\(row.provider ?? "未知平台") · \(row.model ?? "未知模型") · 分组 \(order.count)"
            }
            grouped[key, default: []].append(CAPTrendPoint(id: item.id, date: date, row: row))
        }
        series = order.map { key in
            CAPTrendSeries(id: key, title: titles[key] ?? "未知模型",
                points: (grouped[key] ?? []).sorted { $0.date < $1.date })
        }
        unplottableTimeCount = invalid
    }
}

enum CAPPageNavigation {
    static func nextOffset(offset: Int, limit: Int, count: Int, total: Int) -> Int? {
        guard offset >= 0, limit > 0, count > 0, total >= 0 else { return nil }
        let end = offset.addingReportingOverflow(count)
        let next = offset.addingReportingOverflow(limit)
        guard !end.overflow, !next.overflow, end.partialValue < total,
              next.partialValue < total else { return nil }
        return next.partialValue
    }
}

enum CAPDisplay {
    /// CAP source and alias fields may contain an email even though they are
    /// diagnostic metadata. The privacy preference also applies to their AX text.
    static func privacyValue(_ value: String, masksEmail: Bool) -> String {
        QuotaFormatter.maskEmails(in: value, enabled: masksEmail)
    }

    static func counter(_ value: UInt64?) -> String { value.map(String.init) ?? "未知" }
    static func milliseconds(_ value: UInt64?) -> String {
        guard let value else { return "未知" }
        return String(format: "%.1f ms", Double(value) / 1_000_000)
    }
    static func rate(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "未知" }
        return String(format: "%.2f token/s", value)
    }
    static func boolean(_ value: Bool?) -> String {
        switch value {
        case .some(true): "是"
        case .some(false): "否"
        case nil: "未知"
        }
    }
}
