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

@Suite("Audit connection acceptance and cancellation", .timeLimit(.minutes(1)))
@MainActor
struct AuditConnectionAcceptanceTests {
    @Test func acceptedInventoryIsVisibleBeforeOptionalCapabilityDiscoveryFinishes() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a")])
        let providerGate = TestGate()
        await transport.setProviderGate(providerGate)
        let session = CPAQuotaSession(credentialStore: MemoryCredentialStore(), preferences: MemoryPreferencesStore()) { server, key in
            CPAClient(server: server, managementKey: key, transport: transport)
        }
        session.isPresentingConnectionSheet = true
        let task = Task { await session.connect(serverAddress: "https://a.example", managementKeyInput: "fixture-key", rememberInKeychain: true) }
        await providerGate.waitForArrivals()
        #expect(session.isWorkspaceReady)
        #expect(session.accounts.map(\.id) == ["a"])
        #expect(!session.isPresentingConnectionSheet)
        #expect(session.records["a"]?.snapshot == nil)
        #expect(session.store?.isRefreshing == true)
        #expect(session.store?.refreshOperation?.planned == ["a"])
        #expect(session.completedEnabledAccountCount() == 0)
        #expect(await transport.quotaRequestCount() == 0)
        await providerGate.open()
        await task.value
        #expect(session.records["a"]?.snapshot != nil)
        #expect(session.completedEnabledAccountCount() == 1)
    }

    @Test func slowInitialQuotaCannotDelayWorkspaceOrOverwriteANewerConnection() async throws {
        let active = try ScenarioTransport(accounts: [FixtureAccount("a")])
        let replacement = try ScenarioTransport(accounts: [FixtureAccount("b")])
        let quotaGate = TestGate()
        await active.setGate(quotaGate, for: "index-a")
        let session = CPAQuotaSession(credentialStore: MemoryCredentialStore(), preferences: MemoryPreferencesStore()) { server, key in
            CPAClient(server: server, managementKey: key,
                      transport: server.identifier == "https://a.example" ? active : replacement)
        }
        let task = Task { await session.connect(serverAddress: "https://a.example", managementKeyInput: "fixture-key", rememberInKeychain: false) }
        await quotaGate.waitForArrivals()
        #expect(session.isWorkspaceReady)
        #expect(session.currentServer?.identifier == "https://a.example")
        let priorStore = try #require(session.store)
        #expect(priorStore.refreshOperation?.phase == .refreshing)
        #expect(priorStore.refreshOperation?.processed.isEmpty == true)
        await session.connect(serverAddress: "https://b.example", managementKeyInput: "fixture-key", rememberInKeychain: false)
        let acceptedSnapshot = session.records["b"]?.snapshot
        #expect(acceptedSnapshot != nil)
        await quotaGate.open()
        await task.value
        #expect(session.currentServer?.identifier == "https://b.example")
        #expect(session.records["b"]?.snapshot == acceptedSnapshot)
        #expect(session.records["a"] == nil)
        #expect(priorStore.records["a"]?.snapshot == nil)
        #expect(priorStore.refreshOperation?.phase == .cancelled)
    }

    @Test(arguments: [false, true])
    func lateInventoryAfterDismissalOrExternalNavigationCannotSwitchOrPersist(externalNavigation: Bool) async throws {
        let active = try ScenarioTransport(accounts: [FixtureAccount("a")])
        let candidate = try ScenarioTransport(accounts: [FixtureAccount("b")])
        let gate = TestGate()
        await candidate.setInventoryGate(gate)
        let credentials = MemoryCredentialStore()
        let preferences = MemoryPreferencesStore()
        let session = CPAQuotaSession(credentialStore: credentials, preferences: preferences) { server, key in
            CPAClient(server: server, managementKey: key,
                      transport: server.identifier == "https://a.example" ? active : candidate)
        }
        await session.connect(serverAddress: "https://a.example", managementKeyInput: "old-fixture-key", rememberInKeychain: true)
        let prior = session.records["a"]?.snapshot
        session.serverAddressDraft = "https://b.example"
        session.managementKeyDraft = "new-fixture-key"
        session.isPresentingConnectionSheet = true
        let task = Task { await session.connect(serverAddress: "https://b.example", managementKeyInput: "new-fixture-key", rememberInKeychain: true) }
        await gate.waitForArrivals()
        session.selectedAccountIDForDetail = "a"
        let cleanup = externalNavigation ? session.prepareForExternalNavigation() : session.dismissConnectionForm()
        // UI state and sensitive drafts are cleared before cleanup can suspend.
        #expect(!session.isPresentingConnectionSheet)
        if externalNavigation { #expect(session.selectedAccountIDForDetail == nil) }
        #expect(session.managementKeyDraft.isEmpty)
        #expect(session.currentServer?.identifier == "https://a.example")
        await cleanup.value
        await gate.open()
        await task.value
        let oldServer = try CPAServer(baseURL: "https://a.example")
        let candidateServer = try CPAServer(baseURL: "https://b.example")
        #expect(session.records["a"]?.snapshot == prior)
        #expect(session.records["b"] == nil)
        let expectedKey = try ManagementKey("old-fixture-key")
        #expect(try await credentials.load(for: oldServer) == expectedKey)
        #expect(try await credentials.load(for: candidateServer) == nil)
        #expect(preferences.loadSavedServerIdentifier() == oldServer.identifier)
    }

    @Test func dismissImmediatelyAfterSubmitPreventsAnUnstartedTaskFromConnecting() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a")])
        let session = CPAQuotaSession(credentialStore: MemoryCredentialStore(), preferences: MemoryPreferencesStore()) { server, key in
            CPAClient(server: server, managementKey: key, transport: transport)
        }
        session.isPresentingConnectionSheet = true
        session.serverAddressDraft = "https://a.example"
        session.managementKeyDraft = "fixture-key"
        session.submitConnectionDraft()
        let cleanup = session.dismissConnectionForm()
        #expect(!session.isPresentingConnectionSheet)
        #expect(session.managementKeyDraft.isEmpty)
        #expect(session.authState == .unconfigured)
        await cleanup.value
        // A new submit proves the previous task cannot consume or replace its drafts.
        session.serverAddressDraft = "https://a.example"
        session.managementKeyDraft = "replacement-key"
        await session.connect(serverAddress: "https://a.example", managementKeyInput: "replacement-key", rememberInKeychain: false)
        #expect(await transport.capturedRequests().filter { $0.url?.path.hasSuffix("/auth-files") == true }.count == 1)
        #expect(session.isWorkspaceReady)
        #expect(session.managementKeyDraft.isEmpty)
    }

    @Test func initialQuotaFailureCanRetryJustItsAccountWithoutDiscardingOthers() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a"), FixtureAccount("b")])
        await transport.setReply(FixtureReply(failure: CPAError(.network)), for: "index-b")
        let session = CPAQuotaSession(credentialStore: MemoryCredentialStore(), preferences: MemoryPreferencesStore()) { server, key in
            CPAClient(server: server, managementKey: key, transport: transport)
        }
        await session.connect(serverAddress: "https://a.example", managementKeyInput: "fixture-key", rememberInKeychain: false)
        #expect(session.isWorkspaceReady)
        let preserved = session.records["a"]?.snapshot
        #expect(preserved != nil)
        #expect(session.records["b"]?.error?.kind == .network)
        let before = await transport.quotaRequestCount()
        await transport.setReply(FixtureReply(), for: "index-b")
        await session.refreshAccount("b", force: true)
        #expect(await transport.quotaRequestCount() == before + 1)
        #expect(session.records["a"]?.snapshot == preserved)
        #expect(session.records["b"]?.snapshot != nil)
        #expect(session.records["b"]?.error == nil)
        #expect(session.store?.refreshOperation?.planned == ["b"])
        #expect(session.store?.refreshOperation?.succeeded == ["b"])
    }
}
