import Foundation
import Testing
@testable import CPAQuotaKit

private let reviewNow = Date(timeIntervalSince1970: 1_800_000_000)

private func reviewClient(_ transport: ScenarioTransport) throws -> CPAClient {
    CPAClient(server: try CPAServer(baseURL: "https://cpa.example"),
              managementKey: try ManagementKey("fixture-key"),
              transport: transport,
              clock: { reviewNow })
}

@Suite("Review regressions: client orchestration", .timeLimit(.minutes(1)))
struct ReviewClientRegressionTests {
    @Test func successfulReloadRecoversFromCachedManagementError() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a")])
        let client = try reviewClient(transport)
        _ = try await client.loadAccounts()
        _ = try await client.refreshQuota(for: "a", force: true)

        await transport.setReply(FixtureReply(outerStatus: 401), for: "index-a")
        do {
            _ = try await client.refreshQuota(for: "a", force: true)
            Issue.record("Expected management authorization failure")
        } catch {
            #expect(CPAError.normalize(error).kind == .managementUnauthorized)
        }

        await transport.setReply(FixtureReply(), for: "index-a")
        _ = try await client.loadAccounts()

        let records = try await client.refreshAll(force: false)
        let record = try #require(records.first { $0.id == "a" })
        #expect(record.error == nil)
        #expect(record.snapshot?.windows.count == 2)
        #expect(await transport.quotaRequestCount() == 3)
    }

    @Test func providerDiscoveryServerErrorStillReturnsAccounts() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a")])
        await transport.setProviderStatus(500)
        let client = try reviewClient(transport)

        let accounts = try await client.loadAccounts()
        #expect(accounts.map(\.id) == ["a"])
        let warning = await client.capabilityWarning
        #expect(warning?.kind == .requestRejected)

        let snapshot = try await client.refreshQuota(for: "a", force: true)
        #expect(snapshot.windows.count == 2)
    }

    @Test func providerDiscoveryMalformedBodyStillReturnsAccounts() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a")])
        await transport.setProviderRawBody(Data(#"{"unexpected":true}"#.utf8))
        let client = try reviewClient(transport)

        let accounts = try await client.loadAccounts()
        #expect(accounts.map(\.id) == ["a"])
        let warning = await client.capabilityWarning
        #expect(warning?.kind == .invalidResponse)
    }

    @Test func providerDiscoveryManagementAuthFailuresAreNotSilentlyDowngraded() async throws {
        let cases: [(Int, CPAError.Kind)] = [
            (401, .managementUnauthorized),
            (403, .managementForbidden)
        ]
        for (status, expected) in cases {
            let transport = try ScenarioTransport(accounts: [FixtureAccount("a")])
            await transport.setProviderStatus(status)
            let client = try reviewClient(transport)
            do {
                _ = try await client.loadAccounts()
                Issue.record("Expected management failure for provider discovery")
            } catch {
                #expect(CPAError.normalize(error).kind == expected)
            }
        }
    }

    @Test func providerDiscoveryRateLimitIsNotSilentlyDowngraded() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a")])
        await transport.setProviderStatus(429)
        let client = try reviewClient(transport)
        do {
            _ = try await client.loadAccounts()
            Issue.record("Expected provider rate limit")
        } catch {
            let error = CPAError.normalize(error)
            #expect(error.kind == .rateLimited)
            #expect(error.layer == .management)
        }
    }

    @Test func cancellingProviderDiscoveryIsNotSilentlyDowngraded() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a")])
        let gate = TestGate()
        await transport.setProviderGate(gate)
        let client = try reviewClient(transport)

        let task = Task { try await client.loadAccounts() }
        await gate.waitForArrivals()
        task.cancel()
        await gate.open()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch {
            #expect(CPAError.normalize(error).kind == .cancelled)
        }
    }

    @Test func successfulReloadKeepsUpstreamFailureEvidence() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a")])
        let client = try reviewClient(transport)
        _ = try await client.loadAccounts()
        _ = try await client.refreshQuota(for: "a", force: true)

        await transport.setReply(FixtureReply(upstreamStatus: 401), for: "index-a")
        do {
            _ = try await client.refreshQuota(for: "a", force: true)
            Issue.record("Expected upstream authorization failure")
        } catch {
            #expect(CPAError.normalize(error).kind == .upstreamUnauthorized)
        }

        await transport.setReply(FixtureReply(), for: "index-a")
        _ = try await client.loadAccounts()
        _ = try await client.refreshQuota(for: "a", force: false)

        let record = try #require(await client.currentRecords().first { $0.id == "a" })
        #expect(record.error?.kind == .upstreamUnauthorized)
        #expect(record.snapshot?.windows.count == 2)
    }

    @Test func successfulReloadKeepsManagementRateLimitEvidence() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a")])
        let client = try reviewClient(transport)
        _ = try await client.loadAccounts()

        await transport.setReply(
            FixtureReply(outerStatus: 429, outerHeaders: ["Retry-After": "120"]),
            for: "index-a"
        )
        do {
            _ = try await client.refreshQuota(for: "a", force: true)
            Issue.record("Expected management rate limit")
        } catch {
            let error = CPAError.normalize(error)
            #expect(error.kind == .rateLimited)
            #expect(error.layer == .management)
            #expect(error.retryAfter == reviewNow.addingTimeInterval(120))
        }

        await transport.setReply(FixtureReply(), for: "index-a")
        _ = try await client.loadAccounts()
        do {
            _ = try await client.refreshQuota(for: "a", force: true)
            Issue.record("Expected retained management rate limit")
        } catch {
            #expect(CPAError.normalize(error).kind == .rateLimited)
        }
        #expect(await transport.quotaRequestCount() == 1)
    }

    @Test func successfulReloadKeepsFutureManagementRetryAfterForOtherAccounts() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a"), FixtureAccount("b")])
        let client = try reviewClient(transport)
        _ = try await client.loadAccounts()

        await transport.setReply(
            FixtureReply(outerStatus: 429, outerHeaders: ["Retry-After": "120"]),
            for: "index-a"
        )
        do {
            _ = try await client.refreshQuota(for: "a", force: true)
            Issue.record("Expected management rate limit")
        } catch {
            #expect(CPAError.normalize(error).kind == .rateLimited)
        }

        _ = try await client.loadAccounts()
        do {
            _ = try await client.refreshQuota(for: "b", force: true)
            Issue.record("Expected global management retry-after to block b")
        } catch {
            let error = CPAError.normalize(error)
            #expect(error.kind == .rateLimited)
            #expect(error.layer == .management)
            #expect(error.retryAfter == reviewNow.addingTimeInterval(120))
        }
        #expect(await transport.quotaRequestCount() == 1)
    }

    @Test func removingAnInFlightAccountDoesNotCancelTheWholeBatch() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a"), FixtureAccount("b")])
        let client = try reviewClient(transport)
        _ = try await client.loadAccounts()

        let gate = TestGate()
        await transport.setGate(gate, for: "index-a")
        let bulk = Task { try await client.refreshAll(force: true) }
        await gate.waitForArrivals()

        try await transport.setInventory([FixtureAccount("b")])
        _ = try await client.loadAccounts()
        await gate.open()

        let records = try await bulk.value
        let b = try #require(records.first { $0.id == "b" })
        #expect(b.snapshot?.windows.count == 2)
        #expect(!records.contains { $0.id == "a" })
    }

    @Test func explicitClientCancellationStillCancelsTheWholeBatch() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a"), FixtureAccount("b")])
        let client = try reviewClient(transport)
        _ = try await client.loadAccounts()

        let gate = TestGate()
        await transport.setGate(gate, for: "index-a")
        let bulk = Task { try await client.refreshAll(force: true) }
        await gate.waitForArrivals()

        await client.cancelRefreshes()
        await gate.open()

        do {
            _ = try await bulk.value
            Issue.record("Expected cancellation")
        } catch {
            #expect(CPAError.normalize(error).kind == .cancelled)
        }
    }
}

@Suite("Review regressions: observable store", .timeLimit(.minutes(1)))
@MainActor
struct ReviewStoreRegressionTests {
    @Test func explicitStoreCancellationStillCancelsTheWholeOperation() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a"), FixtureAccount("b")])
        let gate = TestGate()
        await transport.setGate(gate, for: "index-a")
        let store = CPAQuotaStore(client: try reviewClient(transport))

        let task = Task { await store.load() }
        await gate.waitForArrivals()
        await store.cancel()
        await gate.open()
        await task.value

        #expect(!store.isLoading)
        #expect(!store.isRefreshing)
        #expect(store.records["a"]?.snapshot == nil)
        #expect(store.error == nil)
    }

    @Test func storePublishesCapabilityWarning() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a")])
        await transport.setProviderStatus(500)
        let store = CPAQuotaStore(client: try reviewClient(transport))

        await store.load()

        #expect(store.accounts.map(\.id) == ["a"])
        #expect(store.capabilityWarning?.kind == .requestRejected)
        #expect(store.error == nil)
        #expect(store.records["a"]?.snapshot != nil)
    }

    @Test func storeCancellationThenImmediateLoadSucceeds() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a")])
        let gate = TestGate()
        await transport.setGate(gate, for: "index-a")
        let store = CPAQuotaStore(client: try reviewClient(transport))

        let old = Task { await store.load() }
        await gate.waitForArrivals()
        await store.cancel()
        let new = Task { await store.load() }
        await gate.open()
        await old.value
        await new.value

        #expect(store.accounts.map(\.id) == ["a"])
        #expect(store.records["a"]?.snapshot?.windows.count == 2)
        #expect(store.records["a"]?.error == nil)
        #expect(!store.isLoading)
        #expect(!store.isRefreshing)
    }
}
