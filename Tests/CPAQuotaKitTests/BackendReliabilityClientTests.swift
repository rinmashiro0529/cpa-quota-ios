import Foundation
import Testing
@testable import CPAQuotaKit

private final class ReliabilityClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); date.addTimeInterval(seconds); lock.unlock() }
}

private actor ReliabilityConcurrency {
    private var active = 0
    private var peak = 0
    func enter() { active += 1; peak = max(peak, active) }
    func leave() { active -= 1 }
    func maximum() -> Int { peak }
}

private actor ReliabilityUpdates {
    private var records: [QuotaRecord] = []
    func record(_ record: QuotaRecord) { records.append(record) }
    func successes() -> Int { records.filter { $0.error == nil }.count }
}

@Suite("Backend management request reliability")
struct BackendReliabilityClientTests {
    @Test(arguments: [401, 403, 429])
    func batchRefreshPropagatesSharedPreflightFailureWithoutSuccessCallbacks(status: Int) async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let coordinator = CPAManagementRequestCoordinator(clock: { now })
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a"), FixtureAccount("b")])
        let client = CPAClient(server: try CPAServer(baseURL: "https://cpa.example"),
                               managementKey: try ManagementKey("fixture-key"), transport: transport,
                               clock: { now }, coordinator: coordinator)
        _ = try await client.refreshAll(force: true)
        let previousRequestCount = await transport.quotaRequestCount()
        let kind: CPAError.Kind = status == 401 ? .managementUnauthorized : status == 403 ? .managementForbidden : .rateLimited
        do {
            _ = try await coordinator.withPermit { () -> Int in
                throw CPAError(kind, layer: .management, statusCode: status)
            }
        } catch {
            #expect(CPAError.normalize(error).kind == kind)
        }
        let updates = ReliabilityUpdates()
        do {
            _ = try await client.refreshAll(force: true) { await updates.record($0) }
            Issue.record("A shared management block must fail the batch")
        } catch {
            #expect(CPAError.normalize(error).kind == kind)
        }
        #expect(await updates.successes() == 0)
        #expect(await transport.quotaRequestCount() == previousRequestCount)
    }

    @Test func waitingCallerDoesNotExecuteAfterManagementRejection() async throws {
        let coordinator = CPAManagementRequestCoordinator(limit: 1)
        let held = TestGate()
        let waitingStarted = TestGate()
        let invoked = ReliabilityConcurrency()
        let first = Task {
            try await coordinator.withPermit { () -> Int in
                await held.enter()
                throw CPAError(.managementUnauthorized, layer: .management, statusCode: 401)
            }
        }
        await held.waitForArrivals()
        let second = Task {
            await waitingStarted.enter()
            return try await coordinator.withPermit {
                await invoked.enter()
                await invoked.leave()
                return 1
            }
        }
        await waitingStarted.waitForArrivals()
        await waitingStarted.open()
        await held.open()
        do { _ = try await first.value } catch {}
        do {
            _ = try await second.value
            Issue.record("Expected shared management rejection")
        } catch {
            #expect((error as? CPAError)?.kind == .managementUnauthorized)
        }
        #expect(await invoked.maximum() == 0)
    }

    @Test func sharedCoordinatorLimitsMixedCallersToThree() async throws {
        let coordinator = CPAManagementRequestCoordinator()
        let starting = TestGate()
        let held = TestGate()
        let concurrency = ReliabilityConcurrency()
        let tasks = (0..<4).map { _ in
            Task {
                await starting.enter()
                return try await coordinator.withPermit {
                    await concurrency.enter()
                    await held.enter()
                    await concurrency.leave()
                    return 1
                }
            }
        }
        await starting.waitForArrivals(4)
        await starting.open()
        await held.waitForArrivals(3)
        await held.open()
        for task in tasks { _ = try await task.value }
        #expect(await concurrency.maximum() <= 3)
    }

    @Test func sharedManagementBlockPreventsClientInventoryRequest() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let coordinator = CPAManagementRequestCoordinator(clock: { now })
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a")])
        let client = CPAClient(server: try CPAServer(baseURL: "https://cpa.example"),
                               managementKey: try ManagementKey("fixture-key"),
                               transport: transport, clock: { now }, coordinator: coordinator)
        do {
            _ = try await coordinator.withPermit { () -> Int in
                throw CPAError(.managementForbidden, layer: .management, statusCode: 403)
            }
        } catch {}
        do {
            _ = try await client.loadAccounts()
            Issue.record("Expected shared authorization block")
        } catch {
            #expect((error as? CPAError)?.kind == .managementForbidden)
        }
        #expect(await transport.capturedRequests().isEmpty)
    }

    @Test func sharedCoordinatorMakesManagementRateLimitVisibleToOtherCallers() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let coordinator = CPAManagementRequestCoordinator(clock: { now })
        do {
            _ = try await coordinator.withPermit { () -> Int in
                throw CPAError(.rateLimited, layer: .management, statusCode: 429)
            }
            Issue.record("Expected management rate limit")
        } catch {
            #expect((error as? CPAError)?.retryAfter == now.addingTimeInterval(60))
        }
        #expect(await coordinator.retryEligibility() == .coolingDown(until: now.addingTimeInterval(60)))
        do {
            _ = try await coordinator.withPermit { 42 }
            Issue.record("Expected shared circuit to block other callers")
        } catch {
            #expect((error as? CPAError)?.kind == .rateLimited)
        }
    }

    @Test func providerRateLimitBlocksSubsequentInventory() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a")])
        await transport.setProviderStatus(429)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let client = CPAClient(server: try CPAServer(baseURL: "https://cpa.example"),
                               managementKey: try ManagementKey("fixture-key"),
                               transport: transport, clock: { now })
        for _ in 0..<2 {
            do {
                _ = try await client.loadAccounts()
                Issue.record("Expected management rate limit")
            } catch {
                #expect(CPAError.normalize(error).kind == .rateLimited)
            }
        }
        #expect(await transport.capturedRequests().count == 2)
        #expect(await client.retryEligibility() == .coolingDown(until: now.addingTimeInterval(60)))
    }

    @Test func expiredAccountCooldownAllowsRetryWithoutErasingFailureEvidence() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a")])
        let clock = ReliabilityClock(Date(timeIntervalSince1970: 1_800_000_000))
        let client = CPAClient(server: try CPAServer(baseURL: "https://cpa.example"),
                               managementKey: try ManagementKey("fixture-key"),
                               transport: transport, clock: { clock.now() })
        await transport.setReply(FixtureReply(upstreamStatus: 429, body: "{}"), for: "index-a")
        do { _ = try await client.refreshQuota(for: "a", force: true) } catch {}
        #expect(await client.retryEligibility(for: "a") == .coolingDown(until: clock.now().addingTimeInterval(60)))
        clock.advance(60)
        #expect(await client.retryEligibility(for: "a") == .eligible)
        #expect(await client.currentRecords().first?.error?.kind == .rateLimited)
    }

    @Test func upstreamRateLimitWithoutRetryAfterRemainsAccountScoped() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a"), FixtureAccount("b")])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let client = CPAClient(server: try CPAServer(baseURL: "https://cpa.example"),
                               managementKey: try ManagementKey("fixture-key"),
                               transport: transport, clock: { now })
        await transport.setReply(FixtureReply(upstreamStatus: 429, body: "{}"), for: "index-a")
        for _ in 0..<2 {
            do {
                _ = try await client.refreshQuota(for: "a", force: true)
                Issue.record("Expected account rate limit")
            } catch {
                let failure = CPAError.normalize(error)
                #expect(failure.kind == .rateLimited)
                #expect(failure.retryAfter != nil)
            }
        }
        _ = try await client.refreshQuota(for: "b", force: true)
        #expect(await transport.quotaRequestCount() == 2)
    }

    @Test func managementBlockCannotBeBypassedByCachedQuota() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a"), FixtureAccount("b")])
        let client = CPAClient(server: try CPAServer(baseURL: "https://cpa.example"),
                               managementKey: try ManagementKey("fixture-key"), transport: transport)
        _ = try await client.refreshQuota(for: "b")
        await transport.setReply(FixtureReply(outerStatus: 403), for: "index-a")
        do { _ = try await client.refreshQuota(for: "a", force: true) } catch {}
        do {
            _ = try await client.refreshQuota(for: "b")
            Issue.record("Expected management block even when another account has cached data")
        } catch {
            #expect(CPAError.normalize(error).kind == .managementForbidden)
        }
    }

    @Test func managementAuthorizationBlocksInventoryReload() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a")])
        let client = CPAClient(server: try CPAServer(baseURL: "https://cpa.example"),
                               managementKey: try ManagementKey("fixture-key"), transport: transport)
        _ = try await client.loadAccounts()
        await transport.setReply(FixtureReply(outerStatus: 401), for: "index-a")
        do { _ = try await client.refreshQuota(for: "a", force: true) } catch {}
        do {
            _ = try await client.loadAccounts()
            Issue.record("Expected authorization circuit to remain blocked")
        } catch {
            #expect(CPAError.normalize(error).kind == .managementUnauthorized)
        }
        #expect(await transport.capturedRequests().count == 3)
    }

    @Test func inventoryRateLimitWithoutRetryAfterBlocksRepeatedInventory() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a")])
        await transport.setAccountStatus(429)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let client = CPAClient(server: try CPAServer(baseURL: "https://cpa.example"),
                               managementKey: try ManagementKey("fixture-key"),
                               transport: transport, clock: { now })
        for _ in 0..<2 {
            do {
                _ = try await client.loadAccounts()
                Issue.record("Expected management rate limit")
            } catch {
                let failure = CPAError.normalize(error)
                #expect(failure.kind == .rateLimited)
                #expect(failure.retryAfter != nil)
            }
        }
        #expect(await client.retryEligibility() == .coolingDown(until: now.addingTimeInterval(60)))
        #expect(await transport.capturedRequests().count == 1)
    }
}
