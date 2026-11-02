import Foundation
import Testing
@testable import CPAQuotaKit

@Suite("CPA client orchestration", .timeLimit(.minutes(1)))
struct CPAClientTests {
    private func client(_ transport: ScenarioTransport) throws -> CPAClient {
        CPAClient(server: try CPAServer(baseURL: "https://cpa.example"),
                  managementKey: try ManagementKey("fixture-key"), transport: transport)
    }

    @Test func usesFixedReadOnlyCodexTemplateAndServerTokenSubstitution() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a")])
        let client = try client(transport)
        let accounts = try await client.loadAccounts()
        #expect(accounts.count == 1)
        #expect(await client.serverVersion == "fixture-version")
        let snapshot = try await client.refreshQuota(for: "a")
        #expect(snapshot.source == .live)
        #expect(snapshot.windows.count == 2)
        let requests = await transport.capturedRequests()
        let request = try #require(requests.first { $0.httpMethod == "POST" })
        #expect(request.url?.absoluteString == "https://cpa.example/v0/management/api-call")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
        let payload = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect(payload["method"] as? String == "GET")
        #expect(payload["url"] as? String == "https://chatgpt.com/backend-api/wham/usage")
        let headers = payload["header"] as? [String: String]
        #expect(headers?["Authorization"] == "Bearer $TOKEN$")
        #expect(headers?["Chatgpt-Account-Id"] == "fixture-owner")
        #expect(!requests.contains { $0.url?.path.contains("reset") == true })
    }

    @Test func pluginUsesNormalizedEndpointAndPreservesSummary() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("p", provider: "freetier", plugin: true)])
        await transport.setReply(FixtureReply(body: Fixtures.pluginBody), for: "index-p")
        let client = try client(transport)
        let results = try await client.refreshAll()
        let record = try #require(results.first)
        #expect(record.error == nil)
        #expect(record.snapshot?.metrics.count == 1)
        #expect(record.snapshot?.windows.isEmpty == true)
        let requests = await transport.capturedRequests()
        #expect(requests.last?.url?.path.hasSuffix("/quota/fetch") == true)
    }

    @Test func providerDiscoveryCanEnableAPluginWithoutAccountFlag() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("p", provider: "custom")])
        await transport.setProviders(["custom"])
        await transport.setReply(FixtureReply(body: Fixtures.pluginBody), for: "index-p")
        let results = try await client(transport).refreshAll()
        #expect(results.first?.snapshot?.metrics.count == 1)
    }

    @Test func olderCapabilityEndpointDoesNotBreakBuiltInReader() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a")])
        await transport.setProviderStatus(404)
        let results = try await client(transport).refreshAll()
        #expect(results.first?.error == nil)
        #expect(results.first?.snapshot?.windows.count == 2)
    }

    @Test func disabledAndUnsupportedAccountsAreNotQueried() async throws {
        let transport = try ScenarioTransport(accounts: [
            FixtureAccount("disabled", disabled: true), FixtureAccount("unknown", provider: "future-platform")
        ])
        let results = try await client(transport).refreshAll(force: true)
        #expect(results.first { $0.id == "disabled" }?.error?.kind == .accountDisabled)
        #expect(results.first { $0.id == "unknown" }?.error?.kind == .unsupportedProvider)
        #expect(await transport.quotaRequestCount() == 0)
    }

    @Test func liveCacheAvoidsRepeatCallsAndForceBypassesIt() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a")])
        let client = try client(transport)
        _ = try await client.refreshQuota(for: "a")
        _ = try await client.refreshQuota(for: "a")
        #expect(await transport.quotaRequestCount() == 1)
        _ = try await client.refreshQuota(for: "a", force: true)
        #expect(await transport.quotaRequestCount() == 2)
    }

    @Test func concurrentRefreshesForOneAccountShareARequest() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a")])
        await transport.setDelay(.milliseconds(40))
        let client = try client(transport)
        _ = try await client.loadAccounts()
        try await withThrowingTaskGroup(of: QuotaSnapshot.self) { group in
            for _ in 0..<12 { group.addTask { try await client.refreshQuota(for: "a", force: true) } }
            for try await result in group { #expect(result.windows.count == 2) }
        }
        #expect(await transport.quotaRequestCount() == 1)
    }

    @Test func directConcurrentCallsStillRespectTheThreeRequestLimit() async throws {
        let accounts = (0..<9).map { FixtureAccount("account-\($0)") }
        let transport = try ScenarioTransport(accounts: accounts)
        await transport.setDelay(.milliseconds(20))
        let client = try client(transport)
        _ = try await client.loadAccounts()
        try await withThrowingTaskGroup(of: QuotaSnapshot.self) { group in
            for account in accounts {
                group.addTask { try await client.refreshQuota(for: account.id, force: true) }
            }
            for try await _ in group {}
        }
        #expect(await transport.peakConcurrency() <= 3)
        #expect(await transport.quotaRequestCount() == 9)
    }

    @Test func aFailedAccountDoesNotEraseSuccessfulAccounts() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("good"), FixtureAccount("bad")])
        await transport.setReply(FixtureReply(upstreamStatus: 401, body: #"{"error":"private-upstream-text"}"#), for: "index-bad")
        let records = try await client(transport).refreshAll(force: true)
        #expect(records.first { $0.id == "good" }?.snapshot != nil)
        #expect(records.first { $0.id == "bad" }?.error?.kind == .upstreamUnauthorized)
        #expect(records.first { $0.id == "bad" }?.error?.localizedDescription.contains("private-upstream-text") == false)
    }

    @Test func transientFailureRetainsLastGoodQuotaAndFailureEvidence() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a")])
        let client = try client(transport)
        let good = try await client.refreshQuota(for: "a")
        await transport.setReply(FixtureReply(failure: CPAError(.network)), for: "index-a")
        do {
            _ = try await client.refreshQuota(for: "a", force: true)
            Issue.record("Expected network failure")
        } catch { #expect(CPAError.normalize(error).kind == .network) }
        _ = try await client.refreshQuota(for: "a")
        let record = try #require(await client.currentRecords().first)
        #expect(record.snapshot == good)
        #expect(record.error?.kind == .network)
    }

    @Test func reloadRemovesDeletedAccountsAndInvalidatesChangedCredentialCache() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a"), FixtureAccount("b")])
        let client = try client(transport)
        _ = try await client.refreshAll()
        try await transport.setInventory([FixtureAccount("a", index: "replacement-index")])
        _ = try await client.loadAccounts()
        let records = await client.currentRecords()
        #expect(records.count == 1)
        #expect(records.first?.id == "a")
        #expect(records.first?.snapshot == nil)
    }

    @Test func disablingAnAccountRetainsItsLastSnapshotWithoutQuerying() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a")])
        let client = try client(transport)
        let good = try await client.refreshQuota(for: "a")
        try await transport.setInventory([FixtureAccount("a", disabled: true)])
        _ = try await client.loadAccounts()
        let records = try await client.refreshAll(force: true)
        #expect(records.first?.snapshot == good)
        #expect(records.first?.error?.kind == .accountDisabled)
        #expect(await transport.quotaRequestCount() == 1)
    }

    @Test func managementAuthorizationFailureStopsSchedulingMoreAccounts() async throws {
        let accounts = (0..<10).map { FixtureAccount("account-\($0)") }
        let transport = try ScenarioTransport(accounts: accounts)
        for account in accounts { await transport.setReply(FixtureReply(outerStatus: 401), for: "index-\(account.id)") }
        let client = try client(transport)
        do {
            _ = try await client.refreshAll(force: true)
            Issue.record("Expected management authorization failure")
        } catch { #expect(CPAError.normalize(error).kind == .managementUnauthorized) }
        #expect(await transport.quotaRequestCount() <= 3)
    }

    @Test func directParallelAuthorizationFailuresAlsoStopTheQueue() async throws {
        let accounts = (0..<9).map { FixtureAccount("account-\($0)") }
        let transport = try ScenarioTransport(accounts: accounts)
        for account in accounts { await transport.setReply(FixtureReply(outerStatus: 401), for: "index-\(account.id)") }
        let client = try client(transport)
        _ = try await client.loadAccounts()
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask {
                    do {
                        _ = try await client.refreshQuota(for: account.id, force: true)
                        Issue.record("Expected management authorization failure")
                    } catch { #expect(CPAError.normalize(error).kind == .managementUnauthorized) }
                }
            }
        }
        #expect(await transport.quotaRequestCount() <= 3)
    }

    @Test func explicitSuccessfulReloadDoesNotClearTheAuthorizationCircuit() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a")])
        let client = try client(transport)
        await transport.setReply(FixtureReply(outerStatus: 401), for: "index-a")
        do { _ = try await client.refreshQuota(for: "a", force: true) }
        catch { #expect(CPAError.normalize(error).kind == .managementUnauthorized) }
        await transport.setReply(FixtureReply(), for: "index-a")
        do {
            _ = try await client.loadAccounts()
            Issue.record("Expected retained management authorization block")
        } catch {
            #expect(CPAError.normalize(error).kind == .managementUnauthorized)
        }
        #expect(await transport.capturedRequests().count == 3)
    }

    @Test func zeroCacheLifetimeRevalidatesEveryRead() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a")])
        let client = CPAClient(server: try CPAServer(baseURL: "https://cpa.example"),
                               managementKey: try ManagementKey("fixture-key"), transport: transport, cacheLifetime: 0)
        _ = try await client.refreshQuota(for: "a")
        _ = try await client.refreshQuota(for: "a")
        #expect(await transport.quotaRequestCount() == 2)
    }

    @Test func retryAfterPreventsEvenForcedEarlyRetries() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a")])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let client = CPAClient(server: try CPAServer(baseURL: "https://cpa.example"),
                               managementKey: try ManagementKey("fixture-key"), transport: transport, clock: { now })
        await transport.setReply(FixtureReply(upstreamStatus: 429, body: "{}", retryAfter: "120"), for: "index-a")
        for _ in 0..<2 {
            do {
                _ = try await client.refreshQuota(for: "a", force: true)
                Issue.record("Expected quota rate limit")
            } catch {
                let error = CPAError.normalize(error)
                #expect(error.kind == .rateLimited)
                #expect(error.retryAfter == now.addingTimeInterval(120))
            }
        }
        #expect(await transport.quotaRequestCount() == 1)
    }

    @Test func progressIsDeliveredBeforeASlowAccountFinishes() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("fast"), FixtureAccount("slow")])
        let gate = TestGate()
        await transport.setGate(gate, for: "index-slow")
        let collector = UpdateCollector()
        let client = try client(transport)
        let task = Task { try await client.refreshAll { await collector.append($0) } }
        await gate.waitForArrivals()
        await collector.waitForCount(1)
        #expect(await collector.values().first?.id == "fast")
        await gate.open()
        #expect(try await task.value.count == 2)
    }

    @Test func cancelledLateRepliesDoNotPublishQuota() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a")])
        let gate = TestGate()
        await transport.setGate(gate, for: "index-a")
        let client = try client(transport)
        _ = try await client.loadAccounts()
        let task = Task { try await client.refreshQuota(for: "a", force: true) }
        await gate.waitForArrivals()
        await client.cancelRefreshes()
        await gate.open()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch { #expect(CPAError.normalize(error).kind == .cancelled) }
        #expect(await client.currentRecords().first?.snapshot == nil)
    }
}
