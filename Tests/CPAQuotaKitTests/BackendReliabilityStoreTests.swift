import Foundation
import Testing
@testable import CPAQuotaKit

@Suite("Backend refresh operation")
@MainActor
struct BackendReliabilityStoreTests {
    @Test func singleAccountRefreshDoesNotRefreshOtherAccounts() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a"), FixtureAccount("b")])
        let client = CPAClient(server: try CPAServer(baseURL: "https://cpa.example"),
                               managementKey: try ManagementKey("fixture-key"), transport: transport)
        let store = CPAQuotaStore(client: client)
        await store.load()
        let count = await transport.quotaRequestCount()
        await store.refresh(accountID: "a")
        #expect(await transport.quotaRequestCount() == count + 1)
        #expect(store.refreshOperation?.planned == ["a"])
        #expect(store.refreshOperation?.succeeded == ["a"])
    }

    @Test func cancelledRoundCannotOverwriteNewRound() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a")])
        let gate = TestGate()
        await transport.setGate(gate, for: "index-a")
        let client = CPAClient(server: try CPAServer(baseURL: "https://cpa.example"),
                               managementKey: try ManagementKey("fixture-key"), transport: transport)
        let store = CPAQuotaStore(client: client)
        let old = Task { await store.load() }
        await gate.waitForArrivals()
        let oldID = try #require(store.refreshOperation?.id)
        await store.cancel()
        #expect(store.refreshOperation?.phase == .cancelled)
        let nextGate = TestGate()
        await transport.setGate(nextGate, for: "index-a")
        let next = Task { await store.refresh() }
        await nextGate.waitForArrivals()
        let nextID = try #require(store.refreshOperation?.id)
        #expect(nextID != oldID)
        await gate.open()
        await old.value
        #expect(store.refreshOperation?.id == nextID)
        #expect(store.refreshOperation?.phase == .refreshing)
        await nextGate.open()
        await next.value
        #expect(store.refreshOperation?.phase == .completed)
        #expect(store.refreshOperation?.succeeded == ["a"])
    }

    @Test func repeatedIdenticalFailuresAreCountedAsProcessedEachRound() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a")])
        await transport.setReply(FixtureReply(upstreamStatus: 401), for: "index-a")
        let client = CPAClient(server: try CPAServer(baseURL: "https://cpa.example"),
                               managementKey: try ManagementKey("fixture-key"), transport: transport)
        let store = CPAQuotaStore(client: client)
        await store.load()
        let first = try #require(store.refreshOperation)
        await store.refresh()
        let second = try #require(store.refreshOperation)
        #expect(first.id != second.id)
        #expect(second.phase == .completed)
        #expect(second.planned == ["a"])
        #expect(second.processed == ["a"])
        #expect(second.failed == ["a"])
        #expect(second.succeeded.isEmpty)
    }
}
