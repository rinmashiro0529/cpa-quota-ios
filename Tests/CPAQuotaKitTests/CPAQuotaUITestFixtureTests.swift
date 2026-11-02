#if DEBUG
import Foundation
import Testing
@_spi(Testing) import CPAQuotaKit

@Suite("UI transport fixtures pass the production wire contracts")
struct CPAQuotaUITestFixtureTests {
    @Test
    func fixturesProduceRealAccountsWindowsCreditsAndUnknownMetrics() async throws {
        let client = CPAQuotaUITestFixtures.makeClient(
            server: try CPAServer(baseURL: CPAQuotaUITestFixtures.serverAddress),
            managementKey: try ManagementKey(CPAQuotaUITestFixtures.managementKey)
        )
        let accounts = try await client.loadAccounts()
        #expect(Set(accounts.map(\.id)) == ["ui-main", "ui-empty", "ui-plugin"])
        let main = try await client.refreshQuota(for: "ui-main")
        #expect(main.windows.count == 2)
        #expect(abs((main.windows.first?.remainingFraction ?? -1) - 0.42) < 0.000001)
        #expect(main.credits?.balance == 12.5)
        let empty = try await client.refreshQuota(for: "ui-empty")
        #expect(empty.windows.first?.remainingFraction == 0)
        let plugin = try await client.refreshQuota(for: "ui-plugin")
        #expect(plugin.metrics.contains { $0.label == "剩余请求数" && $0.value == 123 })
        #expect(plugin.metrics.contains { $0.label == "未提供数值" && $0.value == nil })
    }

    @Test
    func invalidFixtureCredentialIsARealManagementUnauthorizedError() async throws {
        let client = CPAQuotaUITestFixtures.makeClient(
            server: try CPAServer(baseURL: CPAQuotaUITestFixtures.serverAddress),
            managementKey: try ManagementKey("ui-test-invalid-key")
        )
        do {
            _ = try await client.loadAccounts()
            Issue.record("The local HTTP 401 response must not be accepted as a connection.")
        } catch let error as CPAError {
            #expect(error.kind == .managementUnauthorized)
            #expect(error.statusCode == 401)
        }
    }

    @Test
    func capFixturesHonorRequestedPageSizeAndAllAnalyticsContracts() async throws {
        let client = CPAQuotaUITestFixtures.makeClient(
            server: try CPAServer(baseURL: CPAQuotaUITestFixtures.serverAddress),
            managementKey: try ManagementKey(CPAQuotaUITestFixtures.managementKey)
        )
        let cap = await client.makeCAPUsageClient()
        let window = CAPUsageWindow(now: Date())
        let page = try await cap.loadRequestPage(window: window, offset: 0, limit: 50, access: .anonymous)
        #expect(page.limit == 50)
        #expect(page.items.count == 2)
        #expect(page.items.first?.model == "fixture-model")
        let first = try await cap.loadRequestPage(window: window, offset: 0, limit: 1, access: .anonymous)
        let second = try await cap.loadRequestPage(window: window, offset: 1, limit: 1, access: .anonymous)
        #expect(first.items.count == 1 && second.items.count == 1)
        #expect(first.items.first?.sequence != second.items.first?.sequence)
        let initial = try await cap.loadInitialStats(window: window, access: .anonymous)
        let trends = try await cap.loadTrends(window: window, access: .anonymous)
        let groups = try await cap.loadGroups(window: window, offset: 0, limit: 50, access: .anonymous)
        let costs = try await cap.loadCosts(window: window, access: .anonymous)
        let management = try await cap.loadManagementStats(window: window)
        #expect(initial.summary.requests == 2)
        #expect(trends.modelSeries.count == 1)
        #expect(groups.total == 1)
        #expect(costs.summary.unpricedRequests == 1)
        #expect(management.summary.requests == 2)
    }
}
#endif
