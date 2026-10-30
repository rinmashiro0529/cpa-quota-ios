import Foundation
import Testing
@testable import CPAQuotaKit
@testable import CPAQuotaUI
import CPAQuotaActivity

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

    private func isolatedMonitor() -> MonitoringWorkspaceCoordinator {
        MonitoringWorkspaceCoordinator(
            credentialStore: MonitoringBridgeCredentialStore(storage: MemoryCredentialStore()),
            metadataStore: MemoryMonitoringMetadataPersistence(),
            liveActivityDriver: SyntheticLiveActivityDriver(isSupported: false)
        )
    }
}
