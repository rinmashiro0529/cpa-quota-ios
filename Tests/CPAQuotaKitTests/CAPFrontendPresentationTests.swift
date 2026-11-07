import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CPAQuotaKit
@testable import CPAQuotaUI

private actor CAPPresentationTransport: HTTPTransport {
    private let gate: TestGate?
    private let model: String
    private var fails = false
    private var captured: [URLRequest] = []

    init(model: String = "weighted", gate: TestGate? = nil) {
        self.model = model
        self.gate = gate
    }

    func failNextReads() { fails = true }
    func capturedRequests() -> [URLRequest] { captured }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        captured.append(request)
        if let gate { await gate.enter() }
        if fails { return HTTPResponse(statusCode: 503, headers: [:], body: Data()) }
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let offset = query.first { $0.name == "offset" }?.value ?? "0"
        let limit = query.first { $0.name == "limit" }?.value ?? "500"
        let body = """
        {"total":3,"offset":\(offset),"limit":\(limit),"items":[
          {"sequence":1,"provider":"codex","model":"\(model)","failed":false,"output_tokens":100,"latency_ns":2000000000,"ttft_ns":1000000000},
          {"sequence":2,"provider":"codex","model":"\(model)","failed":false,"output_tokens":900,"latency_ns":4000000000,"ttft_ns":1000000000},
          {"sequence":3,"provider":"codex","model":"\(model)","failed":true,"output_tokens":10000,"latency_ns":2000000000,"ttft_ns":1000000000}
        ]}
        """
        return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
    }
}

@Suite("CAP native presentation preserves query and data meaning")
struct CAPFrontendPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: Data(json.utf8))
    }

    @Test func trendKeepsRealZeroAndUnknownAndDoesNotInventBuckets() throws {
        let rows = try decode([CAPUsageStatRow].self, #"""
        [
          {"provider":"codex","model":"m","hour":"2026-10-30T10:00:00Z","requests":0},
          {"provider":"codex","model":"m","hour":"2026-10-30T10:10:00.123Z","output_tokens":12},
          {"provider":"codex","model":"m","hour":"not-a-time","requests":99},
          {"provider":"codex","model":"m","requests":88}
        ]
        """#)
        let values = CAPRowBuilder.rows(rows, window: CAPUsageWindow(now: now),
            scope: "trends", identity: CAPRowBuilder.statIdentity)
        let result = CAPTrendPresentation(rows: values)
        #expect(values.count == 4)
        #expect(result.unplottableTimeCount == 2)
        let series = try #require(result.series.first)
        #expect(series.points.count == 2)
        #expect(CAPTrendMetric.requests.value(series.points[0]) == 0)
        #expect(CAPTrendMetric.requests.value(series.points[1]) == nil)
        #expect(CAPTrendMetric.outputTokens.value(series.points[0]) == nil)
        #expect(CAPTrendMetric.outputTokens.value(series.points[1]) == 12)
        #expect(series.points[1].date.timeIntervalSince(series.points[0].date) > 600)
    }

    @Test func trendDoesNotCombineIdenticalModelsFromDifferentSources() throws {
        let rows = try decode([CAPUsageStatRow].self, #"""
        [
          {"provider":"codex","model":"m","source":"first","hour":"2026-10-30T10:00:00Z","requests":1},
          {"provider":"codex","model":"m","source":"second","hour":"2026-10-30T10:00:00Z","requests":9}
        ]
        """#)
        let result = CAPTrendPresentation(rows: CAPRowBuilder.rows(rows,
            window: CAPUsageWindow(now: now), scope: "trends", identity: CAPRowBuilder.statIdentity))
        #expect(result.series.count == 2)
        #expect(result.series[0].id != result.series[1].id)
        #expect(result.series.allSatisfy { $0.points.count == 1 })
    }

    @Test func trendCountsUseNumericConversionInsteadOfFloatingPointBitPatterns() throws {
        let cases: [(json: String, expected: Double)] = [
            ("0", 0),
            ("12", 12),
            ("9007199254740992", 9_007_199_254_740_992),
            // Double rounds UInt64.max to 2^64; the exact integer remains in the data table.
            ("18446744073709551615", 18_446_744_073_709_551_616)
        ]
        for sample in cases {
            let rows = try decode([CAPUsageStatRow].self, """
            [{"hour":"2026-10-30T10:00:00Z","requests":\(sample.json),
              "output_tokens":\(sample.json),"total_tokens":\(sample.json),"average_latency_ns":2500000}]
            """)
            let presentation = CAPTrendPresentation(rows: CAPRowBuilder.rows(rows,
                window: CAPUsageWindow(now: now), scope: "numeric-conversion", identity: CAPRowBuilder.statIdentity))
            let point = try #require(presentation.series.first?.points.first)
            #expect(CAPTrendMetric.requests.value(point) == sample.expected)
            #expect(CAPTrendMetric.outputTokens.value(point) == sample.expected)
            #expect(CAPTrendMetric.totalTokens.value(point) == sample.expected)
            #expect(CAPTrendMetric.averageLatency.value(point) == 2.5)
        }
    }

    @Test func requestIdentityIncludesWindowPageAndDuplicateOccurrence() throws {
        let page = try decode(CAPUsageRequestPage.self,
            #"{"total":2,"offset":0,"limit":50,"items":[{"sequence":1,"model":"m"},{"sequence":1,"model":"m"}]}"#)
        let window = CAPUsageWindow(now: now)
        let first = CAPRequestPagePresentation(page: page, window: window)
        let repeated = CAPRequestPagePresentation(page: page, window: window)
        let otherWindow = CAPRequestPagePresentation(page: page, window: CAPUsageWindow(now: now.addingTimeInterval(600)))
        #expect(Set(first.rows.map(\.id)).count == 2)
        #expect(first.rows.map(\.id) == repeated.rows.map(\.id))
        #expect(first.rows[0].id != otherWindow.rows[0].id)
        let nextPage = try decode(CAPUsageRequestPage.self,
            #"{"total":52,"offset":50,"limit":50,"items":[{"sequence":1,"model":"m"}]}"#)
        #expect(first.rows[0].id != CAPRequestPagePresentation(page: nextPage, window: window).rows[0].id)
    }

    @Test func windowBadgeShowsBothAbsoluteDatesInInjectedTimeZone() throws {
        let zone = try #require(TimeZone(secondsFromGMT: 8 * 3600))
        let parser = ISO8601DateFormatter()
        let cases = [
            ("2026-10-30T04:00:00Z", "窗口 · 2026-10-30 11:30–2026-10-30 12:00"),
            ("2026-10-30T16:15:00Z", "窗口 · 2026-10-30 23:45–2026-10-31 00:15"),
            ("2026-12-31T16:15:00Z", "窗口 · 2026-12-31 23:45–2027-01-01 00:15")
        ]
        for (end, expected) in cases {
            let date = try #require(parser.date(from: end))
            #expect(CAPUsagePresentation.windowBadgeText(CAPUsageWindow(now: date), timeZone: zone) == expected)
        }
    }

    @Test(arguments: CAPUsageRange.allCases)
    func boundedRangeUsesCompleteMinuteAndElapsedDuration(_ range: CAPUsageRange) {
        let current = now.addingTimeInterval(37)
        let window = CAPUsageWindow(now: current, range: range)
        #expect(window.end == now)
        #expect(window.end.timeIntervalSince(window.start) == range.duration)
        #expect([1800, 86400, 604800].contains(range.rawValue))
    }

    @Test func retentionCannotPromoteUnavailableHistoryToCompleteStatistics() throws {
        let parser = ISO8601DateFormatter()
        let end = try #require(parser.date(from: "2026-10-30T12:00:00Z"))
        let window = CAPUsageWindow(now: end, range: .last7Days)
        for missing in [nil, "", "not-a-date"] as [String?] {
            #expect(CAPUsagePresentation.retentionDescription(retainedSince: missing, window: window).contains("尚未确认"))
        }
        #expect(CAPUsagePresentation.retentionDescription(retainedSince: "2026-10-30T12:00:00Z", window: window).contains("不能据此认定"))
        #expect(CAPUsagePresentation.retentionDescription(retainedSince: "2026-10-29T12:00:00.000Z", window: window).contains("不能视为全窗口统计"))
        #expect(CAPUsagePresentation.retentionDescription(retainedSince: "2026-10-23T12:00:00Z", window: window).contains("仍可能影响完整性"))
    }

    @Test func failureRateKeepsUnknownAndInconsistentCountersUnknown() throws {
        let cases = [("{}", "未知"), (#"{"requests":2}"#, "未知"),
            (#"{"requests":0,"failed_requests":0}"#, "暂无请求"),
            (#"{"requests":2,"failed_requests":1}"#, "50.0%"),
            (#"{"requests":2,"failed_requests":3}"#, "未知")]
        for (json, expected) in cases {
            #expect(CAPUsagePresentation.failureRateText(try decode(CAPUsageCounters.self, json)) == expected)
        }
    }

    @Test @MainActor func selectingRangeRetainsSnapshotAndNextPageUsesSelectedWindow() async throws {
        let transport = CAPPresentationTransport()
        let current = now
        let coordinator = CAPUsageWorkspaceCoordinator(clock: { current })
        coordinator.bind(client: CAPUsageClient(server: try CPAServer(baseURL: "https://cap.example.test"),
            managementKey: try ManagementKey("fixture-only"), transport: transport))
        await coordinator.refreshOverview(now: now)
        let first = try #require(coordinator.overviewPresentation)
        let requestCount = await transport.capturedRequests().count
        coordinator.selectRange(.last7Days)
        #expect(await transport.capturedRequests().count == requestCount)
        #expect(coordinator.overviewPresentation?.snapshot.window == first.snapshot.window)
        #expect(coordinator.activeWindow == CAPUsageWindow(now: now, range: .last7Days))
        await coordinator.loadRequestPage()
        #expect(coordinator.requestPageWindow == coordinator.activeWindow)
        let request = try #require(await transport.capturedRequests().last)
        let requestURL = try #require(request.url)
        let query = try #require(URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?.queryItems)
        let formatter = ISO8601DateFormatter()
        #expect(query.first { $0.name == "range" }?.value == "custom")
        #expect(query.first { $0.name == "start" }?.value == formatter.string(from: coordinator.activeWindow.start))
        #expect(query.first { $0.name == "end" }?.value == formatter.string(from: coordinator.activeWindow.end))
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func paginationStopsAtEmptyLastOrOverflowingPages() {
        #expect(CAPPageNavigation.nextOffset(offset: 0, limit: 50, count: 50, total: 100) == 50)
        #expect(CAPPageNavigation.nextOffset(offset: 50, limit: 50, count: 50, total: 100) == nil)
        #expect(CAPPageNavigation.nextOffset(offset: 0, limit: 50, count: 0, total: 100) == nil)
        #expect(CAPPageNavigation.nextOffset(offset: Int.max - 1, limit: 50, count: 1, total: Int.max) == nil)
    }

    @Test func metadataPrivacyMasksEachEmailWithoutChangingStoredIdentity() {
        let original = "first@example.test、second@example.test"
        let masked = CAPDisplay.privacyValue(original, masksEmail: true)
        #expect(masked == "fi***t@example.test、se***d@example.test")
        #expect(CAPDisplay.privacyValue(original, masksEmail: false) == original)
        #expect(CAPDisplay.privacyValue("2026-10-30T10:00:00Z", masksEmail: true) == "2026-10-30T10:00:00Z")
    }

    @Test @MainActor func summaryUsesWeightedSamplesAndFailureRetainsItsOriginalWindow() async throws {
        let transport = CAPPresentationTransport()
        let client = CAPUsageClient(server: try CPAServer(baseURL: "https://cap.example.test"),
            managementKey: try ManagementKey("fixture-only"), transport: transport)
        let coordinator = CAPUsageWorkspaceCoordinator()
        coordinator.bind(client: client)
        await coordinator.refreshOverview(now: now)
        let initial = try #require(coordinator.overviewPresentation)
        #expect(initial.snapshot.window == CAPUsageWindow(now: now))
        #expect(initial.summary.generationSamples == 2)
        #expect(initial.summary.totalRequests == 3)
        #expect(initial.summary.generationTPS == 250)
        #expect(initial.summary.counters.outputTokens == 11_000)
        #expect(initial.summary.counters.inputTokens == nil)
        await transport.failNextReads()
        await coordinator.refreshOverview(now: now.addingTimeInterval(600))
        #expect(coordinator.store?.error != nil)
        #expect(coordinator.overviewPresentation?.snapshot.window == initial.snapshot.window)
        #expect(coordinator.overviewPresentation?.summary.generationTPS == 250)
        coordinator.resourceAccess = .managementKey
        #expect(coordinator.overviewPresentation == nil)
        #expect(coordinator.requestPagePresentation == nil)
        #expect(coordinator.initialPresentation == nil)
        #expect(coordinator.trendsPresentation == nil)
        #expect(coordinator.groupsPresentation == nil)
        #expect(coordinator.costsPresentation == nil)
    }

    @Test @MainActor func lateOldWorkspaceCannotPublishPresentationIntoNewConnection() async throws {
        let gate = TestGate()
        let old = CAPPresentationTransport(model: "old", gate: gate)
        let replacement = CAPPresentationTransport(model: "new")
        let coordinator = CAPUsageWorkspaceCoordinator()
        coordinator.bind(client: CAPUsageClient(server: try CPAServer(baseURL: "https://old.example.test"),
            managementKey: try ManagementKey("fixture-old"), transport: old))
        let initial = Task { await coordinator.refreshOverview(now: now) }
        await gate.waitForArrivals()
        coordinator.bind(client: CAPUsageClient(server: try CPAServer(baseURL: "https://new.example.test"),
            managementKey: try ManagementKey("fixture-new"), transport: replacement))
        let newer = now.addingTimeInterval(600)
        await coordinator.refreshOverview(now: newer)
        await gate.open()
        await initial.value
        let presentation = try #require(coordinator.overviewPresentation)
        #expect(presentation.snapshot.window == CAPUsageWindow(now: newer))
        #expect(presentation.models.map { $0.value.model } == ["new"])
        coordinator.teardown()
        #expect(coordinator.overviewPresentation == nil)
        #expect(coordinator.managementPresentation == nil)
    }
}
