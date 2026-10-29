import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CPAQuotaKit

private actor CAPUsageAnalyticsTransport: HTTPTransport {
    private var failing = false
    func fail() { failing = true }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        if failing { return HTTPResponse(statusCode: 503, headers: [:], body: Data()) }
        let path = request.url?.path ?? ""
        let body: String
        if path.hasSuffix("/stats/initial") {
            body = #"{"schema_version":2,"generated_at":"2026-10-28T00:00:00Z","range":"custom","retained_since":"2026-10-01T00:00:00Z","last_used":"2026-10-27T23:59:00Z","bucket_seconds":300,"summary":{"requests":1,"input_tokens":25,"reasoning_tokens":40,"failed_requests":0},"models":[{"model":"m","requests":1,"output_tokens":12}],"series":[],"sources":[]}"#
        } else if path.hasSuffix("/stats/trends") {
            body = #"{"schema_version":2,"generated_at":"2026-10-28T00:00:00Z","range":"custom","bucket_seconds":300,"model_series":[{"hour":"2026-10-27T23:55:00Z","model":"m","output_tokens":12}]}"#
        } else if path.hasSuffix("/costs") {
            body = #"{"schema_version":1,"generated_at":"2026-10-28T00:00:00Z","range":"custom","currency":"USD","estimate_basis":"current_price_book","price_book_revision":1,"summary":{"requests":1,"priced_requests":1,"unpriced_requests":0,"total_usd":0.25},"models":[],"series":[],"missing_prices":[]}"#
        } else {
            body = #"{"schema_version":2,"generated_at":"2026-10-28T00:00:00Z","range":"custom","total":1,"items":[{"provider":"openai","model":"m","requests":1,"output_tokens":12}]}"#
        }
        return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
    }
}

@Suite("CAP analytics resources")
struct CAPUsageAnalyticsTests {
    @Test @MainActor func detailRefreshPublishesOneWindowAndPreservesItOnFailure() async throws {
        let transport = CAPUsageAnalyticsTransport()
        let client = CAPUsageClient(server: try CPAServer(baseURL: "https://example.com"),
                                    managementKey: try ManagementKey("fixture"), transport: transport)
        let store = CAPUsageStore(client: client, access: .anonymous)
        let window = CAPUsageWindow(now: Date(timeIntervalSince1970: 1_800_000_000))
        await store.refreshDetails(window: window)
        #expect(store.details?.initial.summary.inputTokens == 25)
        #expect(store.details?.initial.summary.outputTokens == nil)
        #expect(store.details?.costs.summary.totalUsd == 0.25)
        #expect(store.details?.groups.total == 1)
        #expect(store.details?.groupLimit == 100)
        #expect(store.details?.window == window)
        #expect(!store.isLoadingDetails)
        await transport.fail()
        await store.refreshDetails(window: CAPUsageWindow(now: Date(timeIntervalSince1970: 1_800_000_600)))
        #expect(store.details?.window == window)
        #expect(store.detailsError != nil)
    }
    @Test func readsInitialTrendAndGroups() async throws {
        let client = CAPUsageClient(server: try CPAServer(baseURL: "https://example.com"),
                                    managementKey: try ManagementKey("fixture"), transport: CAPUsageAnalyticsTransport())
        let window = CAPUsageWindow(now: Date())
        let initial = try await client.loadInitialStats(window: window, access: .anonymous)
        let trends = try await client.loadTrends(window: window, access: .anonymous)
        let groups = try await client.loadGroups(window: window, offset: 0, limit: 100, access: .anonymous)
        #expect(initial.models.first?.counters.outputTokens == 12)
        #expect(trends.modelSeries.first?.hour == "2026-10-27T23:55:00Z")
        #expect(groups.items.first?.provider == "openai")
    }
}
