import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CPAQuotaKit

private actor CAPUsageCircuitTransport: HTTPTransport {
    private(set) var calls = 0
    let status: Int
    let headers: [String: String]
    init(status: Int = 401, headers: [String: String] = [:]) {
        self.status = status
        self.headers = headers
    }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        calls += 1
        return HTTPResponse(statusCode: status, headers: headers, body: Data())
    }
}

@Suite("Shared management circuit")
struct CAPUsageCoordinatorTests {
    @Test func retryAfterUsesInjectedClock() async throws {
        let transport = CAPUsageCircuitTransport(status: 429, headers: ["Retry-After": "120"])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let coordinator = CPAManagementRequestCoordinator(clock: { now })
        let usage = CAPUsageClient(server: try CPAServer(baseURL: "https://example.com"),
                                   managementKey: try ManagementKey("fixture"), transport: transport,
                                   coordinator: coordinator, clock: { now })
        do {
            _ = try await usage.loadManagementStats(window: CAPUsageWindow(now: now))
            Issue.record("Expected rate limit")
        } catch let error as CPAError {
            #expect(error.retryAfter == now.addingTimeInterval(120))
        }
    }

    @Test(arguments: [403, 429]) func usageFailureBlocksQuota(_ status: Int) async throws {
        let transport = CAPUsageCircuitTransport(status: status)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let coordinator = CPAManagementRequestCoordinator(clock: { now })
        let server = try CPAServer(baseURL: "https://example.com")
        let key = try ManagementKey("fixture")
        let quota = CPAClient(server: server, managementKey: key, transport: transport, clock: { now }, coordinator: coordinator)
        let usage = CAPUsageClient(server: server, managementKey: key, transport: transport, coordinator: coordinator)
        do {
            _ = try await usage.loadManagementStats(window: CAPUsageWindow(now: now))
            Issue.record("Expected a management failure")
        } catch let error as CPAError {
            #expect(error.layer == .management)
            #expect(error.kind == (status == 403 ? .managementForbidden : .rateLimited))
            if status == 429 { #expect(error.retryAfter == now.addingTimeInterval(60)) }
        }
        await #expect(throws: CPAError.self) { try await quota.loadAccounts() }
        #expect(await transport.calls == 1)
    }

    @Test(arguments: [403, 429]) func quotaFailureBlocksUsage(_ status: Int) async throws {
        let transport = CAPUsageCircuitTransport(status: status)
        let coordinator = CPAManagementRequestCoordinator()
        let server = try CPAServer(baseURL: "https://example.com")
        let key = try ManagementKey("fixture")
        let quota = CPAClient(server: server, managementKey: key, transport: transport, coordinator: coordinator)
        let usage = CAPUsageClient(server: server, managementKey: key, transport: transport, coordinator: coordinator)
        await #expect(throws: CPAError.self) { try await quota.loadAccounts() }
        await #expect(throws: CPAError.self) { try await usage.loadManagementStats(window: CAPUsageWindow(now: Date())) }
        #expect(await transport.calls == 1)
    }

    @Test func quotaUnauthorizedBlocksUsageWithoutSecondNetworkCall() async throws {
        let transport = CAPUsageCircuitTransport()
        let coordinator = CPAManagementRequestCoordinator()
        let server = try CPAServer(baseURL: "https://example.com")
        let key = try ManagementKey("fixture")
        let quota = CPAClient(server: server, managementKey: key, transport: transport, coordinator: coordinator)
        let usage = CAPUsageClient(server: server, managementKey: key, transport: transport, coordinator: coordinator)
        await #expect(throws: CPAError.self) { try await quota.loadAccounts() }
        await #expect(throws: CPAError.self) { try await usage.loadManagementStats(window: CAPUsageWindow(now: Date())) }
        #expect(await transport.calls == 1)
    }

    @Test func usageUnauthorizedBlocksQuotaWithoutSecondNetworkCall() async throws {
        let transport = CAPUsageCircuitTransport()
        let coordinator = CPAManagementRequestCoordinator()
        let server = try CPAServer(baseURL: "https://example.com")
        let key = try ManagementKey("fixture")
        let quota = CPAClient(server: server, managementKey: key, transport: transport, coordinator: coordinator)
        let usage = CAPUsageClient(server: server, managementKey: key, transport: transport, coordinator: coordinator)
        await #expect(throws: CPAError.self) { try await usage.loadManagementStats(window: CAPUsageWindow(now: Date())) }
        await #expect(throws: CPAError.self) { try await quota.loadAccounts() }
        #expect(await transport.calls == 1)
    }
}
