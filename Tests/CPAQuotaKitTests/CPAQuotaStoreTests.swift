import Foundation
import Testing
@testable import CPAQuotaKit

@Suite("SwiftUI-facing observable state", .timeLimit(.minutes(1)))
@MainActor
struct CPAQuotaStoreTests {
    private func store(_ transport: ScenarioTransport) throws -> CPAQuotaStore {
        CPAQuotaStore(client: CPAClient(server: try CPAServer(baseURL: "https://cpa.example"),
                                       managementKey: try ManagementKey("fixture-key"), transport: transport))
    }

    @Test func loadPublishesAccountsAndNormalizedRecords() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a")])
        let store = try store(transport)
        await store.load()
        #expect(store.accounts.map(\.id) == ["a"])
        #expect(store.records["a"]?.snapshot?.windows.count == 2)
        #expect(store.error == nil)
        #expect(!store.isLoading)
        #expect(!store.isRefreshing)
    }

    @Test func oneAccountFailureDoesNotBecomeAGlobalConnectionError() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("good"), FixtureAccount("bad")])
        await transport.setReply(FixtureReply(upstreamStatus: 401), for: "index-bad")
        let store = try store(transport)
        await store.load()
        #expect(store.error == nil)
        #expect(store.records["good"]?.snapshot != nil)
        #expect(store.records["bad"]?.error?.kind == .upstreamUnauthorized)
    }

    @Test func failedReloadPreservesExistingRowsAndQuota() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a")])
        let store = try store(transport)
        await store.load()
        let old = store.records["a"]?.snapshot
        await transport.setAccountStatus(401)
        await store.refresh()
        #expect(store.error?.kind == .managementUnauthorized)
        #expect(store.accounts.count == 1)
        #expect(store.records["a"]?.snapshot == old)
        #expect(!store.isLoading)
        #expect(!store.isRefreshing)
    }

    @Test func repeatedLoadWhileBusyDoesNotStartAnotherRefresh() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a")])
        let gate = TestGate()
        await transport.setGate(gate, for: "index-a")
        let store = try store(transport)
        let first = Task { await store.load() }
        await gate.waitForArrivals()
        await store.load()
        await store.refresh()
        #expect(await transport.quotaRequestCount() == 1)
        await gate.open()
        await first.value
        #expect(store.records["a"]?.snapshot != nil)
    }

    @Test func cancellationAndNewLoadRejectOldInventoryResults() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("old")])
        let gate = TestGate()
        await transport.setInventoryGate(gate)
        let store = try store(transport)
        let old = Task { await store.load() }
        await gate.waitForArrivals()
        await store.cancel()
        #expect(!store.isLoading)
        try await transport.setInventory([FixtureAccount("new")])
        await transport.setInventoryGate(nil)
        await store.load()
        await gate.open()
        await old.value
        #expect(store.accounts.map(\.id) == ["new"])
        #expect(store.records["new"]?.snapshot != nil)
        #expect(store.records["old"] == nil)
        #expect(store.error == nil)
    }

    @Test func cancellingAQuotaRefreshCannotPublishALateReply() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a")])
        let gate = TestGate()
        await transport.setGate(gate, for: "index-a")
        let store = try store(transport)
        let task = Task { await store.load() }
        await gate.waitForArrivals()
        #expect(store.accounts.count == 1)
        await store.cancel()
        await gate.open()
        await task.value
        #expect(store.records["a"]?.snapshot == nil)
        #expect(!store.isRefreshing)
        #expect(store.error == nil)
    }
}
