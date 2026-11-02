import Foundation
import Testing
@testable import CPAQuotaKit
import CPAQuotaUI

@Suite("Backend candidate connection reliability")
@MainActor
struct BackendReliabilitySessionTests {
    @Test func usageClientDerivedAfterFailedSwitchSharesActiveManagementCircuit() async throws {
        let active = try ScenarioTransport(accounts: [FixtureAccount("a")])
        let candidate = try ScenarioTransport(accounts: [FixtureAccount("b")])
        await candidate.setAccountStatus(401)
        let session = CPAQuotaSession(credentialStore: MemoryCredentialStore(), preferences: MemoryPreferencesStore()) { server, key in
            CPAClient(server: server, managementKey: key,
                      transport: server.identifier == "https://a.example" ? active : candidate)
        }
        #expect(await session.makeCAPUsageClient() == nil)
        await session.connect(serverAddress: "https://a.example", managementKeyInput: "fixture-key", rememberInKeychain: true)
        await session.connect(serverAddress: "https://b.example", managementKeyInput: "fixture-key", rememberInKeychain: true)
        let usage = try #require(await session.makeCAPUsageClient())
        await active.setAccountStatus(401)
        await session.refreshAll()
        let before = await active.capturedRequests().count
        do {
            _ = try await usage.loadManagementStats(window: CAPUsageWindow(now: Date()))
            Issue.record("Expected active connection authorization circuit")
        } catch {
            #expect((error as? CPAError)?.kind == .managementUnauthorized)
        }
        #expect(await active.capturedRequests().count == before)
        #expect(session.currentServer?.identifier == "https://a.example")
    }

    @Test func initialConnectionDoesNotPublishWorkspaceUntilValidated() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a")])
        let gate = TestGate()
        await transport.setInventoryGate(gate)
        let session = CPAQuotaSession(credentialStore: MemoryCredentialStore(), preferences: MemoryPreferencesStore()) { server, key in
            CPAClient(server: server, managementKey: key, transport: transport)
        }
        let task = Task { await session.connect(serverAddress: "https://a.example", managementKeyInput: "fixture-key", rememberInKeychain: true) }
        await gate.waitForArrivals()
        #expect(!session.isWorkspaceReady)
        #expect(session.store == nil)
        #expect(session.currentServer == nil)
        await gate.open()
        await task.value
        #expect(session.isWorkspaceReady)
    }

    @Test func cancelledCandidatePreservesActiveConnectionAndSnapshot() async throws {
        let active = try ScenarioTransport(accounts: [FixtureAccount("a")])
        let candidate = try ScenarioTransport(accounts: [FixtureAccount("b")])
        let gate = TestGate()
        await candidate.setInventoryGate(gate)
        let session = CPAQuotaSession(credentialStore: MemoryCredentialStore(), preferences: MemoryPreferencesStore()) { server, key in
            CPAClient(server: server, managementKey: key,
                      transport: server.identifier == "https://a.example" ? active : candidate)
        }
        await session.connect(serverAddress: "https://a.example", managementKeyInput: "fixture-key", rememberInKeychain: true)
        let snapshot = session.records["a"]?.snapshot
        let task = Task { await session.connect(serverAddress: "https://b.example", managementKeyInput: "fixture-key", rememberInKeychain: true) }
        await gate.waitForArrivals()
        await session.cancelActiveOperation()
        let server = try CPAServer(baseURL: "https://a.example")
        #expect(session.authState == .connected(server: server, isRememberedInKeychain: true))
        #expect(session.records["a"]?.snapshot == snapshot)
        await gate.open()
        await task.value
        #expect(session.currentServer == server)
        #expect(session.records["a"]?.snapshot == snapshot)
    }

    @Test func failedCandidatePreservesActiveConnectionAndSnapshot() async throws {
        let active = try ScenarioTransport(accounts: [FixtureAccount("a")])
        let candidate = try ScenarioTransport(accounts: [FixtureAccount("b")])
        await candidate.setAccountStatus(401)
        let session = CPAQuotaSession(credentialStore: MemoryCredentialStore(), preferences: MemoryPreferencesStore()) { server, key in
            CPAClient(server: server, managementKey: key,
                      transport: server.identifier == "https://a.example" ? active : candidate)
        }
        await session.connect(serverAddress: "https://a.example", managementKeyInput: "fixture-key", rememberInKeychain: true)
        let snapshot = session.records["a"]?.snapshot
        #expect(snapshot != nil)
        await session.connect(serverAddress: "https://b.example", managementKeyInput: "bad-fixture-key", rememberInKeychain: true)
        let server = try CPAServer(baseURL: "https://a.example")
        #expect(session.authState == .connected(server: server, isRememberedInKeychain: true))
        #expect(session.currentServer == server)
        #expect(session.records["a"]?.snapshot == snapshot)
        #expect(session.connectionFormError?.kind == .managementUnauthorized)
    }
}
