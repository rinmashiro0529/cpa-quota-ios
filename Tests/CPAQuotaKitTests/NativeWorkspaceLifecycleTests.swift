import Foundation
import Testing
@testable import CPAQuotaKit
@testable import CPAQuotaUI
import CPAQuotaActivity

private final class FaultingWidgetWriter: QuotaWidgetSnapshotWriting, @unchecked Sendable {
    let store: SharedQuotaWidgetSnapshotStore
    var failWrite = false
    var failClear = false

    init(store: SharedQuotaWidgetSnapshotStore) { self.store = store }
    func write(_ snapshot: QuotaWidgetSnapshot) throws {
        if failWrite { throw QuotaWidgetSnapshotError.sharedContainerUnavailable }
        try store.write(snapshot)
    }
    func clear() throws {
        if failClear { throw QuotaWidgetSnapshotError.sharedContainerUnavailable }
        try store.clear()
    }
}

@Suite("Native shell restoration and private widget publishing", .timeLimit(.minutes(1)))
@MainActor
struct NativeWorkspaceLifecycleTests {
    @Test
    func coldLaunchRestoresBothConnectionsOnceWithoutOpeningMonitoring() async throws {
        let server = try CPAServer(baseURL: "https://quota.invalid")
        let credentials = MemoryCredentialStore()
        try await credentials.save(ManagementKey("fixture-management"), for: server)
        let bridge = try MonitorBridgeAddress(baseURL: #require(URL(string: "https://bridge.invalid")))
        let bridgeCredentials = MonitoringBridgeCredentialStore(storage: MemoryCredentialStore())
        try await bridgeCredentials.save(MonitorBridgeToken("fixture-bridge-token"), for: bridge)
        let monitor = MonitoringWorkspaceCoordinator(
            credentialStore: bridgeCredentials,
            metadataStore: MemoryMonitoringMetadataPersistence(bridgeAddress: bridge.baseURL.absoluteString),
            liveActivityDriver: SyntheticLiveActivityDriver(isSupported: false)
        )
        let transport = try ScenarioTransport(accounts: [FixtureAccount("private-account")])
        let gate = TestGate()
        await transport.setInventoryGate(gate)
        let preferences = MemoryPreferencesStore(serverIdentifier: server.identifier)
        let session = CPAQuotaSession(
            credentialStore: credentials, preferences: preferences, monitoringCoordinator: monitor,
            clientFactory: { server, key in
                CPAClient(server: server, managementKey: key, transport: transport)
            }
        )
        let first = Task { await session.restoreApplicationIfAvailable() }
        await gate.waitForArrivals()
        let second = Task { await session.restoreApplicationIfAvailable() }
        await Task.yield()
        await gate.open()
        await first.value
        await second.value
        await session.restoreApplicationIfAvailable()
        let requests = await transport.capturedRequests()
        #expect(requests.filter { $0.url?.path.hasSuffix("/auth-files") == true }.count == 1)
        #expect(session.isWorkspaceReady)
        #expect(session.activeTab == .quotas)
        #expect(monitor.activeAddress == bridge)
    }

    @Test
    func explicitWidgetConsentPublishesAndRevocationRemovesTheSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sharedStore = SharedQuotaWidgetSnapshotStore(directoryURL: directory)
        let transport = try ScenarioTransport(accounts: [FixtureAccount("private-account")])
        let preferences = MemoryPreferencesStore()
        let session = CPAQuotaSession(
            credentialStore: MemoryCredentialStore(), preferences: preferences,
            monitoringCoordinator: isolatedMonitor(), widgetSnapshotStore: sharedStore,
            clientFactory: { server, key in
                CPAClient(server: server, managementKey: key, transport: transport)
            }
        )
        await session.connect(serverAddress: "https://quota.invalid",
                              managementKeyInput: "fixture-management", rememberInKeychain: false)
        #expect(sharedStore.read() == nil)
        #expect(!session.sharesQuotaWithWidgets)
        session.sharesQuotaWithWidgets = true
        let snapshot = try #require(sharedStore.read())
        #expect(snapshot.entries.count == 1)
        #expect(snapshot.entries[0].label == "账号 1")
        let fraction = try #require(snapshot.entries[0].remainingFraction)
        #expect(abs(fraction - 0.42) < 0.000_001)
        #expect(preferences.loadSharesQuotaWithWidgets())
        session.sharesQuotaWithWidgets = false
        #expect(sharedStore.read() == nil)
        #expect(!preferences.loadSharesQuotaWithWidgets())
    }

    @Test
    func widgetProjectionDoesNotExportIdentityOrForgePassiveFreshness() throws {
        let publisher = QuotaWidgetPublisher(preferences: MemoryPreferencesStore())
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let account = CPAAccount(id: "private-id", authIndex: "private-auth-index",
                                 provider: "private@provider.invalid", displayName: "private-display",
                                 email: "private@example.invalid")
        let snapshot = QuotaSnapshot(accountID: account.id, provider: account.provider,
                                     source: .passive, fetchedAt: now, windows: [
                                        QuotaWindow(id: "private-window", title: "private@label.invalid",
                                                    durationSeconds: 18_000, usedFraction: 0)
                                     ])
        let result = try publisher.projection(accounts: [account],
                                              records: [account.id: QuotaRecord(account: account, snapshot: snapshot)],
                                              now: now)
        let data = try JSONEncoder().encode(result)
        let encoded = String(decoding: data, as: UTF8.self)
        #expect(!encoded.contains("private"))
        #expect(!encoded.contains("@"))
        #expect(result.entries[0].observedAt == nil)
        #expect(result.entries[0].status == .unavailable)
        #expect(result.entries[0].remainingFraction == 1)
        #expect(result.entries[0].windowLabel == "5 小时窗口")
    }

    @Test
    func configuredWidgetIdentitySurvivesRelaunchButCannotCrossSources() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sharedStore = SharedQuotaWidgetSnapshotStore(directoryURL: directory)
        let preferences = MemoryPreferencesStore()
        let account = CPAAccount(id: "same-local-id", authIndex: nil, provider: "codex", displayName: "Private")
        let first = QuotaWidgetPublisher(store: sharedStore, preferences: preferences)
        try first.publish(sourceIdentifier: "https://first.invalid", accounts: [account], records: [:])
        let firstID = try #require(sharedStore.read()?.entries.first?.id)
        let restored = QuotaWidgetPublisher(store: sharedStore, preferences: preferences)
        try restored.publish(sourceIdentifier: "https://first.invalid", accounts: [account], records: [:])
        #expect(sharedStore.read()?.entries.first?.id == firstID)
        try restored.publish(sourceIdentifier: "https://second.invalid", accounts: [account], records: [:])
        #expect(sharedStore.read()?.entries.first?.id != firstID)
        restored.forgetIdentity()
        #expect(preferences.loadWidgetAccountIdentifiers(for: "https://second.invalid").isEmpty)
    }

    @Test
    func widgetFailedRefreshPreservesReadingWithAnExplicitFailureState() throws {
        let publisher = QuotaWidgetPublisher(preferences: MemoryPreferencesStore())
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let account = CPAAccount(id: "account", authIndex: nil, provider: "codex", displayName: "Account")
        let snapshot = QuotaSnapshot(accountID: account.id, provider: account.provider,
                                     source: .live, fetchedAt: now.addingTimeInterval(-600),
                                     windows: [QuotaWindow(id: "primary", title: "5h", usedFraction: 1)])
        let result = try publisher.projection(
            accounts: [account],
            records: [account.id: QuotaRecord(account: account, snapshot: snapshot, error: CPAError(.network))],
            now: now
        )
        #expect(result.entries[0].remainingFraction == 0)
        #expect(result.entries[0].status == .failed)
        #expect(result.entries[0].observedAt == snapshot.fetchedAt)
    }

    @Test
    func rebindingAnAccountDoesNotReuseAConfiguredWidgetOrItsOldReading() throws {
        let publisher = QuotaWidgetPublisher(preferences: MemoryPreferencesStore())
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let first = CPAAccount(id: "same-id", authIndex: "old-index", provider: "codex", displayName: "First")
        let second = CPAAccount(id: "same-id", authIndex: "new-index", provider: "codex", displayName: "Second")
        let snapshot = QuotaSnapshot(accountID: first.id, provider: first.provider, source: .live,
                                     fetchedAt: now, windows: [QuotaWindow(id: "primary", title: "5h", usedFraction: 0.5)])
        let records = [first.id: QuotaRecord(account: first, snapshot: snapshot)]
        let before = try publisher.projection(accounts: [first], records: records, now: now)
        let after = try publisher.projection(accounts: [second], records: records, now: now)
        #expect(before.entries[0].id != after.entries[0].id)
        #expect(after.entries[0].remainingFraction == nil)
        #expect(after.entries[0].status == .unavailable)
    }

    @Test
    func sourceChangeClearsBeforeFailedWriteAndRetriesFailedClear() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shared = SharedQuotaWidgetSnapshotStore(directoryURL: directory)
        let writer = FaultingWidgetWriter(store: shared)
        let publisher = QuotaWidgetPublisher(store: writer, preferences: MemoryPreferencesStore())
        let account = CPAAccount(id: "account", authIndex: nil, provider: "codex", displayName: "Account")
        try publisher.publish(sourceIdentifier: "a", accounts: [account], records: [:])
        let original = try #require(shared.read())
        writer.failClear = true
        #expect(throws: QuotaWidgetSnapshotError.previousSnapshotClearFailed) {
            try publisher.publish(sourceIdentifier: "b", accounts: [account], records: [:])
        }
        #expect(shared.read() == original)
        writer.failClear = false
        writer.failWrite = true
        #expect(throws: QuotaWidgetSnapshotError.sharedContainerUnavailable) {
            try publisher.publish(sourceIdentifier: "b", accounts: [account], records: [:])
        }
        #expect(shared.read() == nil)
        writer.failWrite = false
        try publisher.publish(sourceIdentifier: "b", accounts: [account], records: [:])
        #expect(shared.read()?.entries.first?.id != original.entries.first?.id)
    }

    @Test
    func connectionFailurePreservesOldSnapshotAndClearFailureIsRetried() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shared = SharedQuotaWidgetSnapshotStore(directoryURL: directory)
        let writer = FaultingWidgetWriter(store: shared)
        let transport = try ScenarioTransport(accounts: [FixtureAccount("private-account")])
        let session = CPAQuotaSession(
            credentialStore: MemoryCredentialStore(), preferences: MemoryPreferencesStore(),
            monitoringCoordinator: isolatedMonitor(), widgetSnapshotWriter: writer,
            clientFactory: { server, key in CPAClient(server: server, managementKey: key, transport: transport) }
        )
        await session.connect(serverAddress: "https://a.invalid", managementKeyInput: "fixture-management", rememberInKeychain: false)
        session.sharesQuotaWithWidgets = true
        let original = try #require(shared.read())
        await transport.setAccountStatus(401)
        await session.connect(serverAddress: "https://b.invalid", managementKeyInput: "fixture-management", rememberInKeychain: false)
        #expect(shared.read() == original)
        await transport.setAccountStatus(200)
        writer.failClear = true
        await session.connect(serverAddress: "https://b.invalid", managementKeyInput: "fixture-management", rememberInKeychain: false)
        #expect(shared.read() == original)
        #expect(session.widgetSharingNotice?.contains("旧来源") == true)
        writer.failClear = false
        await session.applicationDidBecomeActive()
        let retried = try #require(shared.read())
        #expect(retried.entries.first?.id != original.entries.first?.id)
        writer.failWrite = true
        await session.connect(serverAddress: "https://c.invalid", managementKeyInput: "fixture-management", rememberInKeychain: false)
        #expect(shared.read() == nil)
        #expect(session.widgetSharingNotice?.contains("暂不可用") == true)
    }

    private func isolatedMonitor() -> MonitoringWorkspaceCoordinator {
        MonitoringWorkspaceCoordinator(
            credentialStore: MonitoringBridgeCredentialStore(storage: MemoryCredentialStore()),
            metadataStore: MemoryMonitoringMetadataPersistence(),
            liveActivityDriver: SyntheticLiveActivityDriver(isSupported: false)
        )
    }
}
