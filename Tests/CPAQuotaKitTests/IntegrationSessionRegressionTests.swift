import Foundation
import Observation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import CPAQuotaKit
import CPAQuotaUI

/// Wraps the scenario transport so a global connection failure can be injected after connecting.
actor FaultInjectingTransport: HTTPTransport {
    private let base: ScenarioTransport
    private var failure: CPAError?

    init(base: ScenarioTransport) { self.base = base }

    func setFailure(_ error: CPAError?) { failure = error }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        if let failure { throw failure }
        return try await base.send(request)
    }
}

/// Credential store double at the system boundary. It can hold saves or removals at
/// deterministic gates and fail removals on demand; it never touches a real Keychain.
actor ScriptedCredentialStore: CredentialStore {
    private var keys: [String: ManagementKey] = [:]
    private var saveGate: TestGate?
    private var gatedSaveCall: Int?
    private var loadGate: TestGate?
    private var loadFailure: CPAError?
    private var removeGate: TestGate?
    private var gatedRemoveCall: Int?
    private var removeCalls = 0
    private var failsRemoval = false
    private var failsSave = false
    private var saveCalls = 0

    func setSaveGate(_ gate: TestGate, atCall call: Int? = nil) {
        saveGate = gate
        gatedSaveCall = call
    }

    func setLoadGate(_ gate: TestGate?) { loadGate = gate }
    func setLoadFailure(_ error: CPAError?) { loadFailure = error }
    func setRemoveGate(_ gate: TestGate, atCall call: Int) {
        removeGate = gate
        gatedRemoveCall = call
    }
    func setFailsRemoval(_ flag: Bool) { failsRemoval = flag }
    func setFailsSave(_ flag: Bool) { failsSave = flag }

    func storedKey(for server: CPAServer) -> ManagementKey? { keys[server.identifier] }

    func load(for server: CPAServer) async throws -> ManagementKey? {
        let gate = loadGate
        loadGate = nil
        if let gate { await gate.enter() }
        if let loadFailure { throw loadFailure }
        return keys[server.identifier]
    }

    func save(_ key: ManagementKey, for server: CPAServer) async throws {
        saveCalls += 1
        if let gate = saveGate, gatedSaveCall == nil || gatedSaveCall == saveCalls {
            await gate.enter()
        }
        if failsSave { throw CPAError(.secureStorageFailure) }
        keys[server.identifier] = key
    }

    func remove(for server: CPAServer) async throws {
        removeCalls += 1
        if let gate = removeGate, gatedRemoveCall == removeCalls {
            await gate.enter()
        }
        if failsRemoval { throw CPAError(.secureStorageFailure) }
        keys.removeValue(forKey: server.identifier)
    }
}

private final class ObservedMetadataChange: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false

    func record() {
        lock.withLock { changed = true }
    }

    var wasObserved: Bool {
        lock.withLock { changed }
    }
}

@Suite("Integration session lifecycle regressions", .timeLimit(.minutes(1)))
@MainActor
struct IntegrationSessionRegressionTests {
    private func makeSession(
        transport: ScenarioTransport,
        credentials: ScriptedCredentialStore,
        preferences: MemoryPreferencesStore
    ) -> CPAQuotaSession {
        CPAQuotaSession(
            credentialStore: credentials,
            preferences: preferences,
            clientFactory: { server, key in
                CPAClient(server: server, managementKey: key, transport: transport)
            }
        )
    }

    @Test
    func cancellingInitialValidationDoesNotPersistOrReportConnected() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("account-1")])
        await transport.setAccountStatus(401)
        let inventoryGate = TestGate()
        await transport.setInventoryGate(inventoryGate)

        let credentials = ScriptedCredentialStore()
        let preferences = MemoryPreferencesStore()
        let session = makeSession(transport: transport, credentials: credentials, preferences: preferences)
        let server = try CPAServer(baseURL: "https://cancel.example")

        let connectTask = Task {
            await session.connect(
                serverAddress: "https://cancel.example",
                managementKeyInput: "unverified-management-key",
                rememberInKeychain: true
            )
        }
        await inventoryGate.waitForArrivals(1)
        await session.cancelActiveOperation()
        await inventoryGate.open()
        await connectTask.value

        #expect(session.authState == .unconfigured)
        #expect(session.store == nil)
        #expect(session.currentServer == nil)
        #expect(await credentials.storedKey(for: server) == nil)
        #expect(preferences.loadSavedServerIdentifier() == nil)
    }

    @Test
    func callerTaskCancellationDuringRememberedCredentialSaveRemovesTheNewKey() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("account-1")])
        let credentials = ScriptedCredentialStore()
        let preferences = MemoryPreferencesStore()
        let session = makeSession(transport: transport, credentials: credentials, preferences: preferences)
        let server = try CPAServer(baseURL: "https://cancel-save.example")
        let saveGate = TestGate()
        await credentials.setSaveGate(saveGate, atCall: 1)

        let connectTask = Task {
            await session.connect(
                serverAddress: "https://cancel-save.example",
                managementKeyInput: "verified-management-key",
                rememberInKeychain: true
            )
        }
        await saveGate.waitForArrivals(1)
        connectTask.cancel()
        await saveGate.open()
        await connectTask.value

        #expect(session.authState == .unconfigured)
        #expect(session.store == nil)
        #expect(session.currentServer == nil)
        #expect(await credentials.storedKey(for: server) == nil)
        #expect(preferences.loadSavedServerIdentifier() == nil)
    }

    @Test
    func forgettingDuringInitialValidationDiscardsLateConnectSuccess() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("account-1")])
        await transport.setAccountStatus(401)
        let inventoryGate = TestGate()
        await transport.setInventoryGate(inventoryGate)

        let credentials = ScriptedCredentialStore()
        let preferences = MemoryPreferencesStore()
        let session = makeSession(transport: transport, credentials: credentials, preferences: preferences)
        let server = try CPAServer(baseURL: "https://forget.example")

        let connectTask = Task {
            await session.connect(
                serverAddress: "https://forget.example",
                managementKeyInput: "unverified-management-key",
                rememberInKeychain: true
            )
        }
        await inventoryGate.waitForArrivals(1)
        await session.forgetCurrentConnection()
        await inventoryGate.open()
        await connectTask.value

        #expect(session.authState == .unconfigured)
        #expect(session.store == nil)
        #expect(session.currentServer == nil)
        #expect(await credentials.storedKey(for: server) == nil)
        #expect(preferences.loadSavedServerIdentifier() == nil)
    }

    @Test
    func callerTaskCancellationDuringValidationDoesNotPersistOrReportConnected() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("account-1")])
        await transport.setAccountStatus(401)
        let inventoryGate = TestGate()
        await transport.setInventoryGate(inventoryGate)

        let credentials = ScriptedCredentialStore()
        let preferences = MemoryPreferencesStore()
        let session = makeSession(transport: transport, credentials: credentials, preferences: preferences)
        let server = try CPAServer(baseURL: "https://task-cancel.example")

        let connectTask = Task {
            await session.connect(
                serverAddress: "https://task-cancel.example",
                managementKeyInput: "unverified-management-key",
                rememberInKeychain: true
            )
        }
        await inventoryGate.waitForArrivals(1)
        connectTask.cancel()
        await inventoryGate.open()
        await connectTask.value

        #expect(session.authState == .unconfigured)
        #expect(session.store == nil)
        #expect(session.currentServer == nil)
        #expect(await credentials.storedKey(for: server) == nil)
        #expect(preferences.loadSavedServerIdentifier() == nil)
    }

    @Test
    func forgetSurfacesCredentialRemovalFailureAndRemainsRetryable() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("account-1")])
        let credentials = ScriptedCredentialStore()
        let preferences = MemoryPreferencesStore()
        let session = makeSession(transport: transport, credentials: credentials, preferences: preferences)
        let server = try CPAServer(baseURL: "https://forget-failure.example")

        await session.connect(
            serverAddress: "https://forget-failure.example",
            managementKeyInput: "remembered-management-key",
            rememberInKeychain: true
        )
        #expect(session.authState == .connected(server: server, isRememberedInKeychain: true))

        await credentials.setFailsRemoval(true)
        await session.forgetCurrentConnection()

        #expect(session.authState == .connected(server: server, isRememberedInKeychain: true))
        #expect(session.connectionFormError?.kind == .secureStorageFailure)
        #expect(session.statusBannerMessage != nil)
        #expect(await credentials.storedKey(for: server) != nil)
        #expect(preferences.loadSavedServerIdentifier() == "https://forget-failure.example")

        await credentials.setFailsRemoval(false)
        await session.forgetCurrentConnection()

        #expect(session.authState == .unconfigured)
        #expect(session.connectionFormError == nil)
        #expect(session.statusBannerMessage == nil)
        #expect(session.store == nil)
        #expect(session.currentServer == nil)
        #expect(await credentials.storedKey(for: server) == nil)
        #expect(preferences.loadSavedServerIdentifier() == nil)
    }

    @Test
    func supersededConnectionDoesNotOverwriteNewerSessionState() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("account-1")])
        let credentials = ScriptedCredentialStore()
        let preferences = MemoryPreferencesStore()
        let session = makeSession(transport: transport, credentials: credentials, preferences: preferences)
        let firstServer = try CPAServer(baseURL: "https://first.example")
        let secondServer = try CPAServer(baseURL: "https://second.example")

        let firstSaveGate = TestGate()
        await credentials.setSaveGate(firstSaveGate, atCall: 1)

        let firstConnect = Task {
            await session.connect(
                serverAddress: "https://first.example",
                managementKeyInput: "first-management-key",
                rememberInKeychain: true
            )
        }
        await firstSaveGate.waitForArrivals(1)

        let secondInventoryGate = TestGate()
        await transport.setInventoryGate(secondInventoryGate)
        let secondConnect = Task {
            await session.connect(
                serverAddress: "https://second.example",
                managementKeyInput: "second-management-key",
                rememberInKeychain: true
            )
        }
        await secondInventoryGate.waitForArrivals(1)
        await secondInventoryGate.open()

        await firstSaveGate.open()
        await secondConnect.value
        await firstConnect.value

        #expect(session.authState == .connected(server: secondServer, isRememberedInKeychain: true))
        #expect(session.currentServer == secondServer)
        #expect(preferences.loadSavedServerIdentifier() == "https://second.example")
        #expect(await credentials.storedKey(for: secondServer)?.value == "second-management-key")
        #expect(await credentials.storedKey(for: firstServer) == nil)
    }

    @Test
    func lateSaveFromSupersededConnectionDoesNotOverwriteNewerCredential() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("account-1")])
        let credentials = ScriptedCredentialStore()
        let preferences = MemoryPreferencesStore()
        let session = makeSession(transport: transport, credentials: credentials, preferences: preferences)
        let server = try CPAServer(baseURL: "https://same-server.example")

        let firstSaveGate = TestGate()
        await credentials.setSaveGate(firstSaveGate, atCall: 1)

        let firstConnect = Task {
            await session.connect(
                serverAddress: "https://same-server.example",
                managementKeyInput: "first-management-key",
                rememberInKeychain: true
            )
        }
        await firstSaveGate.waitForArrivals(1)

        let secondInventoryGate = TestGate()
        await transport.setInventoryGate(secondInventoryGate)
        let secondConnect = Task {
            await session.connect(
                serverAddress: "https://same-server.example",
                managementKeyInput: "second-management-key",
                rememberInKeychain: true
            )
        }
        await secondInventoryGate.waitForArrivals(1)
        await secondInventoryGate.open()
        await firstSaveGate.open()
        await firstConnect.value
        await secondConnect.value

        #expect(await credentials.storedKey(for: server)?.value == "second-management-key")
        #expect(session.authState == .connected(server: server, isRememberedInKeychain: true))
        #expect(preferences.loadSavedServerIdentifier() == "https://same-server.example")
    }

    @Test
    func managementBlockWinsWhileRefreshIsStillLoading() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("account-1")])
        let session = makeSession(transport: transport, credentials: ScriptedCredentialStore(),
                                  preferences: MemoryPreferencesStore())
        await session.connect(serverAddress: "https://projection.example", managementKeyInput: "management-key", rememberInKeychain: false)
        await transport.setAccountStatus(401)
        let gate = TestGate()
        await transport.setInventoryGate(gate)
        let refresh = Task { await session.refreshAll(force: true) }
        await gate.waitForArrivals()
        let store = try #require(session.store)
        #expect(store.isLoading)
        let observed = ObservedMetadataChange()
        withObservationTracking {
            _ = store.refreshOperation
        } onChange: {
            MainActor.assumeIsolated {
                if store.isLoading, store.error?.kind == .managementUnauthorized,
                   session.connectionStatus().connectionPageText.contains("管理鉴权已阻断") {
                    observed.record()
                }
            }
        }
        await gate.open()
        await refresh.value
        #expect(observed.wasObserved)
    }

    @Test
    func connectingNewContextTakesPrecedenceOverExistingManagementBlock() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("account-1")])
        let session = makeSession(transport: transport, credentials: ScriptedCredentialStore(),
                                  preferences: MemoryPreferencesStore())
        await session.connect(serverAddress: "https://projection.example", managementKeyInput: "management-key", rememberInKeychain: false)
        await transport.setAccountStatus(401)
        await session.refreshAll(force: true)
        #expect(session.connectionStatus().connectionPageText.contains("管理鉴权已阻断"))
        await transport.setAccountStatus(200)
        let gate = TestGate()
        await transport.setInventoryGate(gate)
        let reconnect = Task {
            await session.connect(serverAddress: "https://new.example", managementKeyInput: "new-key", rememberInKeychain: false)
        }
        await gate.waitForArrivals()
        if case .connecting = session.authState {} else { Issue.record("Expected connecting state") }
        #expect(session.connectionStatus().phase == .syncing(isLoadingInventory: true, completedCount: 0, totalCount: 1))
        #expect(session.connectionStatus().connectionPageRecovery == nil)
        await gate.open()
        await reconnect.value
    }

    @Test
    func managementRejectionUpdatesConnectionPageUntilExplicitReconnect() async throws {
        for status in [401, 403] {
            let transport = try ScenarioTransport(accounts: [FixtureAccount("account-1")])
            let session = makeSession(transport: transport, credentials: ScriptedCredentialStore(),
                                      preferences: MemoryPreferencesStore())
            await session.connect(serverAddress: "https://projection.example", managementKeyInput: "management-key", rememberInKeychain: false)
            await transport.setAccountStatus(status)
            await session.refreshAll(force: true)
            let expected: CPAError.Kind = status == 401 ? .managementUnauthorized : .managementForbidden
            #expect(session.connectionStatus().phase == .managementBlocked(kind: expected))
            #expect(session.connectionStatus().connectionPageText.contains("管理鉴权已阻断"))
            #expect(session.connectionStatus().connectionPageRecovery?.contains("重新连接") == true)
            await transport.setAccountStatus(200)
            await session.refreshAll(force: true)
            #expect(session.connectionStatus().phase == .managementBlocked(kind: expected))
            await session.connect(serverAddress: "https://projection.example", managementKeyInput: "new-management-key", rememberInKeychain: false)
            #expect(session.connectionStatus().connectionPageText == "已连接")
        }
    }

    @Test
    func upstreamUnauthorizedDoesNotBecomeManagementBlock() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("account-1")])
        let session = makeSession(transport: transport, credentials: ScriptedCredentialStore(),
                                  preferences: MemoryPreferencesStore())
        await session.connect(serverAddress: "https://projection.example", managementKeyInput: "management-key", rememberInKeychain: false)
        await transport.setReply(FixtureReply(upstreamStatus: 401), for: "index-account-1")
        await session.refreshAll(force: true)
        #expect(session.records["account-1"]?.error?.kind == .upstreamUnauthorized)
        #expect(session.connectionStatus().connectionPageText == "已连接")
        #expect(session.connectionStatus().connectionPageRecovery == nil)
    }

    @Test
    func globalNetworkFailureIsNotProjectedAsIdleReady() async throws {
        let base = try ScenarioTransport(accounts: [FixtureAccount("account-1")])
        let transport = FaultInjectingTransport(base: base)
        let credentials = ScriptedCredentialStore()
        let preferences = MemoryPreferencesStore()
        let session = CPAQuotaSession(
            credentialStore: credentials,
            preferences: preferences,
            clientFactory: { server, key in
                CPAClient(server: server, managementKey: key, transport: transport)
            }
        )

        await session.connect(
            serverAddress: "https://projection.example",
            managementKeyInput: "management-key",
            rememberInKeychain: false
        )
        #expect(session.store?.error == nil)

        await transport.setFailure(CPAError(.network))
        await session.refreshAll(force: true)
        #expect(session.store?.error?.kind == .network)

        let state = session.connectionStatus()
        #expect(state.phase == .connectionFailed(kind: .network))
        #expect(state.compactLeadingText == "连接异常")
        #expect(state.compactTrailingText == "网络")
        #expect(state.expandedTitle == "CPA 连接出现异常")
        #expect(state.expandedSubtitle.contains("网络"))
        #expect(state.progressFraction == 0.0)
        #expect(!state.canCancel)
    }

    @Test
    func refreshProgressDoesNotCountRecordsFromThePreviousRound() async throws {
        let transport = try ScenarioTransport(accounts: [
            FixtureAccount("first-account"),
            FixtureAccount("second-account")
        ])
        let credentials = ScriptedCredentialStore()
        let preferences = MemoryPreferencesStore()
        let session = makeSession(transport: transport, credentials: credentials, preferences: preferences)

        await session.connect(
            serverAddress: "https://progress.example",
            managementKeyInput: "management-key",
            rememberInKeychain: false
        )
        #expect(session.completedEnabledAccountCount() == 2)
        #expect(!session.isBusy)

        let requestGate = TestGate()
        await transport.setGate(requestGate, for: "index-first-account")
        let refreshTask = Task { await session.refreshAll(force: true) }
        await requestGate.waitForArrivals(1)

        #expect(session.isBusy)
        #expect(session.completedEnabledAccountCount() < session.accounts.count)
        #expect(session.connectionStatus().progressFraction < 1.0)

        await requestGate.open()
        await refreshTask.value

        #expect(!session.isBusy)
        #expect(session.completedEnabledAccountCount() == 2)
    }

    @Test
    func forgetDuringLateCredentialSaveLeavesNoStoredCredential() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("account-1")])
        let credentials = ScriptedCredentialStore()
        let preferences = MemoryPreferencesStore()
        let session = makeSession(transport: transport, credentials: credentials, preferences: preferences)
        let server = try CPAServer(baseURL: "https://late-forget.example")

        let saveGate = TestGate()
        await credentials.setSaveGate(saveGate, atCall: 1)

        let connectTask = Task {
            await session.connect(
                serverAddress: "https://late-forget.example",
                managementKeyInput: "late-management-key",
                rememberInKeychain: true
            )
        }
        await saveGate.waitForArrivals(1)

        let forgetTask = Task { await session.forgetCurrentConnection() }
        await saveGate.open()
        await connectTask.value
        await forgetTask.value

        #expect(session.authState == .unconfigured)
        #expect(session.store == nil)
        #expect(session.currentServer == nil)
        #expect(await credentials.storedKey(for: server) == nil)
        #expect(preferences.loadSavedServerIdentifier() == nil)
    }

    @Test
    func staleRestoreDoesNotOverwriteAConnectionStartedLater() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("account-1")])
        let credentials = ScriptedCredentialStore()
        let preferences = MemoryPreferencesStore(serverIdentifier: "https://restored.example")
        let restoredServer = try CPAServer(baseURL: "https://restored.example")
        let restoredKey = try ManagementKey("restored-management-key")
        try await credentials.save(restoredKey, for: restoredServer)

        let loadGate = TestGate()
        await credentials.setLoadGate(loadGate)

        let session = makeSession(transport: transport, credentials: credentials, preferences: preferences)
        let restoreTask = Task { await session.restoreSessionIfAvailable() }
        await loadGate.waitForArrivals(1)

        let newServer = try CPAServer(baseURL: "https://new-connection.example")
        await session.connect(
            serverAddress: "https://new-connection.example",
            managementKeyInput: "new-management-key",
            rememberInKeychain: true
        )

        await loadGate.open()
        await restoreTask.value

        #expect(session.authState == .connected(server: newServer, isRememberedInKeychain: true))
        #expect(session.currentServer == newServer)
        #expect(preferences.loadSavedServerIdentifier() == "https://new-connection.example")
        #expect(await credentials.storedKey(for: newServer)?.value == "new-management-key")
    }

    @Test
    func lateCompensationWriteCannotResurrectAForgottenCredential() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("account-1")])
        let credentials = ScriptedCredentialStore()
        let preferences = MemoryPreferencesStore()
        let session = makeSession(transport: transport, credentials: credentials, preferences: preferences)
        let server = try CPAServer(baseURL: "https://compensation.example")

        let firstSaveGate = TestGate()
        await credentials.setSaveGate(firstSaveGate, atCall: 1)

        let firstConnect = Task {
            await session.connect(
                serverAddress: "https://compensation.example",
                managementKeyInput: "first-management-key",
                rememberInKeychain: true
            )
        }
        await firstSaveGate.waitForArrivals(1)

        await transport.setAccountStatus(401)
        let secondInventoryGate = TestGate()
        await transport.setInventoryGate(secondInventoryGate)
        let secondConnect = Task {
            await session.connect(
                serverAddress: "https://compensation.example",
                managementKeyInput: "second-unverified-key",
                rememberInKeychain: true
            )
        }
        await secondInventoryGate.waitForArrivals(1)
        await secondInventoryGate.open()

        await firstSaveGate.open()
        await firstConnect.value
        await secondConnect.value

        #expect(session.authState == .unconfigured)
        #expect(session.connectionFormError?.kind == .managementUnauthorized)
        #expect(await credentials.storedKey(for: server) == nil)
        #expect(preferences.loadSavedServerIdentifier() == nil)
    }

    @Test
    func rejectedStoredCredentialDoesNotPublishConnectedAfterColdRestore() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("account-1")])
        await transport.setAccountStatus(401)
        let credentials = ScriptedCredentialStore()
        let preferences = MemoryPreferencesStore(serverIdentifier: "https://restore-auth.example")
        let server = try CPAServer(baseURL: "https://restore-auth.example")
        let storedKey = try ManagementKey("stored-management-key")
        try await credentials.save(storedKey, for: server)

        let session = makeSession(transport: transport, credentials: credentials, preferences: preferences)
        await session.restoreSessionIfAvailable()

        #expect(session.authState == .unconfigured)
        #expect(session.connectionFormError?.kind == .managementUnauthorized)
        #expect(session.store == nil)
        #expect(!session.isRememberedInKeychain)
        #expect(preferences.loadSavedServerIdentifier() == "https://restore-auth.example")
        #expect(await credentials.storedKey(for: server) != nil)
    }

    @Test
    func networkFailureOnColdRestoreKeepsKnownConnectionButNotReadyProjection() async throws {
        let base = try ScenarioTransport(accounts: [FixtureAccount("account-1")])
        let transport = FaultInjectingTransport(base: base)
        await transport.setFailure(CPAError(.network))

        let credentials = ScriptedCredentialStore()
        let preferences = MemoryPreferencesStore(serverIdentifier: "https://restore-network.example")
        let server = try CPAServer(baseURL: "https://restore-network.example")
        try await credentials.save(ManagementKey("stored-management-key"), for: server)

        let session = CPAQuotaSession(
            credentialStore: credentials,
            preferences: preferences,
            clientFactory: { server, key in
                CPAClient(server: server, managementKey: key, transport: transport)
            }
        )
        await session.restoreSessionIfAvailable()

        #expect(session.authState == .connected(server: server, isRememberedInKeychain: true))
        #expect(session.store?.error?.kind == .network)
        #expect(session.connectionStatus().phase == .connectionFailed(kind: .network))
        #expect(session.connectionStatus().expandedTitle != "CPA 额度连接就绪")
        #expect(session.connectionStatus().connectionPageText == "连接异常：网络")
        #expect(session.connectionStatus().connectionPageRecovery != nil)
    }

    @Test
    func forgettingAfterColdCredentialLoadFailureRemovesTheSavedServerCredential() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("account-1")])
        let credentials = ScriptedCredentialStore()
        let server = try CPAServer(baseURL: "https://cold-load-failure.example")
        try await credentials.save(ManagementKey("stored-management-key"), for: server)
        await credentials.setLoadFailure(CPAError(.secureStorageFailure))
        let preferences = MemoryPreferencesStore(serverIdentifier: server.identifier)
        let session = makeSession(transport: transport, credentials: credentials, preferences: preferences)

        await session.restoreSessionIfAvailable()

        #expect(session.authState == .unconfigured)
        #expect(session.currentServer == nil)
        #expect(session.connectionFormError?.kind == .secureStorageFailure)
        #expect(session.statusBannerMessage != nil)

        await credentials.setLoadFailure(nil)
        await session.forgetCurrentConnection()

        #expect(session.authState == .unconfigured)
        #expect(await credentials.storedKey(for: server) == nil)
        #expect(preferences.loadSavedServerIdentifier() == nil)
    }

    @Test
    func forgetWithoutRestoringUsesSavedServerIdentifierToRemoveCredential() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("account-1")])
        let credentials = ScriptedCredentialStore()
        let server = try CPAServer(baseURL: "https://forget-without-restore.example")
        try await credentials.save(ManagementKey("stored-management-key"), for: server)
        let preferences = MemoryPreferencesStore(serverIdentifier: server.identifier)
        let session = makeSession(transport: transport, credentials: credentials, preferences: preferences)
        #expect(session.savedServer == server)
        let change = ObservedMetadataChange()
        withObservationTracking {
            _ = session.savedServer
        } onChange: {
            change.record()
        }

        await session.forgetCurrentConnection()

        #expect(change.wasObserved)
        #expect(session.authState == .unconfigured)
        #expect(session.savedServer == nil)
        #expect(await credentials.storedKey(for: server) == nil)
        #expect(preferences.loadSavedServerIdentifier() == nil)
    }

    @Test
    func cancelledColdRestoreDoesNotLeaveAConnectedSession() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("account-1")])
        let inventoryGate = TestGate()
        await transport.setInventoryGate(inventoryGate)

        let credentials = ScriptedCredentialStore()
        let preferences = MemoryPreferencesStore(serverIdentifier: "https://restore-cancel.example")
        let server = try CPAServer(baseURL: "https://restore-cancel.example")
        let storedKey = try ManagementKey("stored-management-key")
        try await credentials.save(storedKey, for: server)

        let session = makeSession(transport: transport, credentials: credentials, preferences: preferences)
        let restoreTask = Task { await session.restoreSessionIfAvailable() }
        await inventoryGate.waitForArrivals(1)
        restoreTask.cancel()
        await inventoryGate.open()
        await restoreTask.value

        #expect(session.authState == .unconfigured)
        #expect(session.store == nil)
        #expect(!session.isRememberedInKeychain)
        #expect(preferences.loadSavedServerIdentifier() == "https://restore-cancel.example")
        #expect(await credentials.storedKey(for: server) != nil)
    }

    @Test
    func explicitCancelDuringCredentialLoadPreservesStoredCredential() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("account-1")])
        let credentials = ScriptedCredentialStore()
        let preferences = MemoryPreferencesStore(serverIdentifier: "https://restore-explicit-cancel.example")
        let server = try CPAServer(baseURL: "https://restore-explicit-cancel.example")
        let storedKey = try ManagementKey("stored-management-key")
        try await credentials.save(storedKey, for: server)

        let loadGate = TestGate()
        await credentials.setLoadGate(loadGate)
        let session = makeSession(transport: transport, credentials: credentials, preferences: preferences)
        let restoreTask = Task { await session.restoreSessionIfAvailable() }
        await loadGate.waitForArrivals(1)

        #expect(session.authState == .connecting(serverIdentifier: "https://restore-explicit-cancel.example"))
        #expect(session.isBusy)
        #expect(session.connectionStatus().canCancel)
        #expect(session.connectionStatus().progressFraction == 0.0)

        await session.cancelActiveOperation()
        await loadGate.open()
        await restoreTask.value

        #expect(session.authState == .unconfigured)
        #expect(session.store == nil)
        #expect(session.currentServer == nil)
        #expect(await credentials.storedKey(for: server)?.value == "stored-management-key")
        #expect(preferences.loadSavedServerIdentifier() == "https://restore-explicit-cancel.example")
    }

    @Test
    func rememberFalseRemovalFailureIsVisibleAndReportsRealPersistence() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("account-1")])
        let credentials = ScriptedCredentialStore()
        let preferences = MemoryPreferencesStore()
        let server = try CPAServer(baseURL: "https://remember-false.example")
        let previousKey = try ManagementKey("previously-stored-key")
        try await credentials.save(previousKey, for: server)
        await credentials.setFailsRemoval(true)

        let session = makeSession(transport: transport, credentials: credentials, preferences: preferences)
        await session.connect(
            serverAddress: "https://remember-false.example",
            managementKeyInput: "ephemeral-management-key",
            rememberInKeychain: false
        )

        #expect(session.authState == .connected(server: server, isRememberedInKeychain: false))
        #expect(session.connectionFormError?.kind == .secureStorageFailure)
        #expect(session.statusBannerMessage != nil)
        #expect(preferences.loadSavedServerIdentifier() == nil)
        #expect(await credentials.storedKey(for: server)?.value == "previously-stored-key")
    }

    @Test
    func failedNewCredentialSavePreservesThePreviousSavedServer() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("account-1")])
        let credentials = ScriptedCredentialStore()
        let preferences = MemoryPreferencesStore()
        let session = makeSession(transport: transport, credentials: credentials, preferences: preferences)
        let serverA = try CPAServer(baseURL: "https://save-failure-a.example")
        let serverB = try CPAServer(baseURL: "https://save-failure-b.example")

        await session.connect(
            serverAddress: serverA.identifier,
            managementKeyInput: "management-key-a",
            rememberInKeychain: true
        )
        #expect(session.savedServer == serverA)
        #expect(await credentials.storedKey(for: serverA)?.value == "management-key-a")

        await credentials.setFailsSave(true)
        await session.connect(
            serverAddress: serverB.identifier,
            managementKeyInput: "management-key-b",
            rememberInKeychain: true
        )

        #expect(session.authState == .connected(server: serverB, isRememberedInKeychain: false))
        #expect(session.connectionFormError?.kind == .secureStorageFailure)
        #expect(session.statusBannerMessage != nil)
        #expect(session.savedServer == serverA)
        #expect(preferences.loadSavedServerIdentifier() == serverA.identifier)
        #expect(await credentials.storedKey(for: serverA)?.value == "management-key-a")
        #expect(await credentials.storedKey(for: serverB) == nil)
    }

    @Test
    func acceptedCredentialSwitchIsNotRolledBackByLaterFailedConnection() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("account-1")])
        let credentials = ScriptedCredentialStore()
        let preferences = MemoryPreferencesStore()
        let session = makeSession(transport: transport, credentials: credentials, preferences: preferences)
        let serverA = try CPAServer(baseURL: "https://accepted-a.example")
        let serverB = try CPAServer(baseURL: "https://accepted-b.example")

        await session.connect(
            serverAddress: serverA.identifier,
            managementKeyInput: "management-key-a",
            rememberInKeychain: true
        )
        await session.connect(
            serverAddress: serverB.identifier,
            managementKeyInput: "management-key-b",
            rememberInKeychain: true
        )

        await transport.setAccountStatus(401)
        await session.connect(
            serverAddress: "https://rejected-after-accept.example",
            managementKeyInput: "unverified-management-key",
            rememberInKeychain: true
        )

        #expect(session.authState == .connected(server: serverB, isRememberedInKeychain: true))
        #expect(session.currentServer == serverB)
        #expect(session.connectionFormError?.kind == .managementUnauthorized)
        #expect(session.savedServer == serverB)
        #expect(preferences.loadSavedServerIdentifier() == serverB.identifier)
        #expect(await credentials.storedKey(for: serverA) == nil)
        #expect(await credentials.storedKey(for: serverB)?.value == "management-key-b")
    }

    @Test
    func switchCleanupFailureIsVisibleAndKeepsRealCredentialState() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("account-1")])
        let credentials = ScriptedCredentialStore()
        let preferences = MemoryPreferencesStore()
        let firstServer = try CPAServer(baseURL: "https://old-server.example")
        let secondServer = try CPAServer(baseURL: "https://new-server.example")

        let session = makeSession(transport: transport, credentials: credentials, preferences: preferences)
        await session.connect(
            serverAddress: "https://old-server.example",
            managementKeyInput: "old-management-key",
            rememberInKeychain: true
        )
        #expect(await credentials.storedKey(for: firstServer)?.value == "old-management-key")

        await credentials.setFailsRemoval(true)
        await session.connect(
            serverAddress: "https://new-server.example",
            managementKeyInput: "new-management-key",
            rememberInKeychain: true
        )

        #expect(session.authState == .connected(server: secondServer, isRememberedInKeychain: true))
        #expect(session.connectionFormError?.kind == .secureStorageFailure)
        #expect(session.statusBannerMessage != nil)
        #expect(preferences.loadSavedServerIdentifier() == "https://new-server.example")
        #expect(await credentials.storedKey(for: secondServer)?.value == "new-management-key")
        #expect(await credentials.storedKey(for: firstServer) != nil)
    }

    @Test
    func cancellingSwitchDuringOldCredentialRemovalRestoresTheEntirePriorCredentialSet() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("account-1")])
        let credentials = ScriptedCredentialStore()
        let preferences = MemoryPreferencesStore()
        let session = makeSession(transport: transport, credentials: credentials, preferences: preferences)
        let serverA = try CPAServer(baseURL: "https://transaction-a.example")
        let serverB = try CPAServer(baseURL: "https://transaction-b.example")

        await session.connect(
            serverAddress: serverA.identifier,
            managementKeyInput: "management-key-a",
            rememberInKeychain: true
        )
        #expect(await credentials.storedKey(for: serverA)?.value == "management-key-a")
        #expect(session.savedServer == serverA)

        let removalGate = TestGate()
        await credentials.setRemoveGate(removalGate, atCall: 1)
        let switchTask = Task {
            await session.connect(
                serverAddress: serverB.identifier,
                managementKeyInput: "management-key-b",
                rememberInKeychain: true
            )
        }
        await removalGate.waitForArrivals(1)
        #expect(await credentials.storedKey(for: serverB)?.value == "management-key-b")

        switchTask.cancel()
        await removalGate.open()
        await switchTask.value

        #expect(session.authState == .connected(server: serverA, isRememberedInKeychain: true))
        #expect(session.currentServer == serverA)
        #expect(session.savedServer == serverA)
        #expect(await credentials.storedKey(for: serverA)?.value == "management-key-a")
        #expect(await credentials.storedKey(for: serverB) == nil)
    }

    @Test(arguments: [true, false])
    func dismissingCandidateDuringCredentialMutationRestoresPreviouslyAcceptedConnection(rememberCandidate: Bool) async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("account-1")])
        let credentials = ScriptedCredentialStore()
        let preferences = MemoryPreferencesStore()
        let session = makeSession(transport: transport, credentials: credentials, preferences: preferences)
        let serverA = try CPAServer(baseURL: "https://dismissed-mutation-a.example")
        let serverB = try CPAServer(baseURL: "https://dismissed-mutation-b.example")
        await session.connect(
            serverAddress: serverA.identifier,
            managementKeyInput: "management-key-a",
            rememberInKeychain: true
        )
        let priorStore = try #require(session.store)
        let mutationGate = TestGate()
        if rememberCandidate {
            // Hold the candidate's save after the accepted connection's first save.
            await credentials.setSaveGate(mutationGate, atCall: 2)
        } else {
            // Hold the second delete: at least one key mutation has already
            // completed, independent of the dictionary's iteration order.
            await credentials.setRemoveGate(mutationGate, atCall: 2)
        }
        session.isPresentingConnectionSheet = true
        let switchTask = Task {
            await session.connect(
                serverAddress: serverB.identifier,
                managementKeyInput: "management-key-b",
                rememberInKeychain: rememberCandidate
            )
        }
        await mutationGate.waitForArrivals()
        session.managementKeyDraft = "unsubmitted-sensitive-draft"
        let cleanup = session.dismissConnectionForm()
        #expect(session.managementKeyDraft.isEmpty)
        #expect(!session.isPresentingConnectionSheet)
        #expect(session.authState == .connected(server: serverA, isRememberedInKeychain: true))
        #expect(session.store === priorStore)
        await mutationGate.open()
        await cleanup.value
        await switchTask.value
        #expect(session.currentServer == serverA)
        #expect(session.savedServer == serverA)
        #expect(session.store === priorStore)
        #expect(preferences.loadSavedServerIdentifier() == serverA.identifier)
        #expect(await credentials.storedKey(for: serverA)?.value == "management-key-a")
        #expect(await credentials.storedKey(for: serverB) == nil)
        #expect(session.managementKeyDraft.isEmpty)
    }

    @Test
    func inventorySyncDoesNotClaimACompletionPercentage() {
        let state = ConnectionStatusPresentation(
            phase: .syncing(isLoadingInventory: true, completedCount: 0, totalCount: 0),
            isExpanded: false
        )

        #expect(state.progressFraction == 0.0)
    }

    @Test
    func zeroOfKnownQuotaRequestsHasZeroProgress() {
        let state = ConnectionStatusPresentation(
            phase: .syncing(isLoadingInventory: false, completedCount: 0, totalCount: 3),
            isExpanded: false
        )
        let partial = ConnectionStatusPresentation(
            phase: .syncing(isLoadingInventory: false, completedCount: 1, totalCount: 3),
            isExpanded: false
        )

        #expect(state.progressFraction == 0.0)
        #expect(abs(partial.progressFraction - (1.0 / 3.0)) < 0.000_001)
    }
}
