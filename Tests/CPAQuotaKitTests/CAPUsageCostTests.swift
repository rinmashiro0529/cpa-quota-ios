import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CPAQuotaKit

private actor CAPUsageCostTransport: HTTPTransport {
    private(set) var path: String?
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        path = request.url?.path
        let json = #"{"schema_version":1,"generated_at":"2026-10-28T00:00:00Z","range":"custom","currency":"USD","estimate_basis":"current_price_book","price_book_revision":7,"summary":{"requests":2,"priced_requests":1,"unpriced_requests":1,"total_usd":0.25},"models":[{"provider":"p","model":"m","requests":1,"priced_requests":1,"unpriced_requests":0,"total_usd":0.25}],"series":[],"missing_prices":[{"provider":"p","model":"m","requests":1}]}"#
        return HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
    }
}

@Suite("CAP estimated costs")
struct CAPUsageCostTests {
    @Test func missingPriceRemainsDistinctFromZeroCost() async throws {
        let transport = CAPUsageCostTransport()
        let client = CAPUsageClient(server: try CPAServer(baseURL: "https://example.com"),
                                    managementKey: try ManagementKey("fixture"), transport: transport)
        let costs = try await client.loadCosts(window: CAPUsageWindow(now: Date()), access: .anonymous)
        #expect(costs.summary.unpricedRequests == 1)
        #expect(costs.summary.totalUsd == 0.25)
        #expect(costs.models.first?.amounts.totalUsd == 0.25)
        #expect(costs.missingPrices.first?.model == "m")
        #expect(await transport.path == "/v0/resource/plugins/cap-token-usage-tracker/costs")
    }
}
