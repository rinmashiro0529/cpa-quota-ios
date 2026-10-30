import Foundation
import Testing
import CPAQuotaActivity
import CPAQuotaKit
import CPAQuotaUI

@Suite("Native surface privacy, navigation, and recovery contracts")
struct NativeActivityAndWidgetTests {
    private let observed = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(id: String = UUID().uuidString, fraction: Double? = 0.42,
                       observedAt: Date? = Date(timeIntervalSince1970: 1_800_000_000),
                       validUntil: Date? = nil, status: QuotaWidgetEntry.Status = .ready) throws -> QuotaWidgetEntry {
        try QuotaWidgetEntry(id: id, label: "账号 1", provider: "codex", windowLabel: "5 小时",
                             remainingFraction: fraction, observedAt: observedAt, validUntil: validUntil, status: status)
    }

    @Test func deepLinksCarryOnlyValidatedNavigationHints() throws {
        let aliases = ["personal", "team_2", "监控来源"]
        for alias in aliases {
            let link = CPAQuotaDeepLink.monitoring(sourceID: alias)
            #expect(CPAQuotaDeepLink(url: link.url) == link)
            #expect(link.url.absoluteString.contains("token") == false)
        }
        #expect(CPAQuotaDeepLink(url: CPAQuotaDeepLink.quotas.url) == .quotas)
        for raw in [
            "https://monitor?source=personal", "cpaquota://monitor?source=a&source=b",
            "cpaquota://monitor?source=a&token=secret", "cpaquota://monitor?source=person%40example.com",
            "cpaquota://monitor/private?source=a", "cpaquota://monitor?source=a#fragment",
            "cpaquota://user:secret@monitor?source=a", "cpaquota://monitor:443?source=a",
            "cpaquota://quotas?account=raw-id", "cpaquota://monitor?source=", "cpaquota://unknown"
        ] {
            #expect(CPAQuotaDeepLink(url: try #require(URL(string: raw))) == nil)
        }
    }

    @Test func sharedReadingsRejectRawIdentityAndUnsafeDisplayFields() throws {
        #expect(throws: QuotaWidgetSnapshotError.self) {
            _ = try entry(id: "raw-account-id")
        }
        for label in ["person@example.com", "https://private.invalid", "www.private.invalid", "name\nsecret"] {
            #expect(throws: QuotaWidgetSnapshotError.self) {
                _ = try QuotaWidgetEntry(id: UUID().uuidString, label: label, provider: "cpa",
                                        windowLabel: "Quota", status: .unavailable)
            }
        }
        #expect(throws: QuotaWidgetSnapshotError.self) { _ = try entry(fraction: .infinity) }
        #expect(throws: QuotaWidgetSnapshotError.self) { _ = try entry(fraction: -0.01) }
        #expect(throws: QuotaWidgetSnapshotError.self) { _ = try entry(fraction: 1.01) }
    }

    @Test func decodingDoesNotBypassSafeEntryValidationOrVersionChecks() throws {
        let sample = try QuotaWidgetSnapshot(generatedAt: observed, entries: [entry()])
        let data = try JSONEncoder().encode(sample)
        var root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var entries = try #require(root["entries"] as? [[String: Any]])
        entries[0]["label"] = "secret@example.com"
        root["entries"] = entries
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(QuotaWidgetSnapshot.self, from: JSONSerialization.data(withJSONObject: root))
        }
        root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        root["version"] = 2
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(QuotaWidgetSnapshot.self, from: JSONSerialization.data(withJSONObject: root))
        }
    }

    @Test func freshnessUsesObservationTimeAndUnknownIsNotZero() throws {
        let reading = try entry()
        #expect(reading.status(at: observed.addingTimeInterval(299)) == .ready)
        #expect(reading.status(at: observed.addingTimeInterval(300)) == .stale)
        #expect(reading.status(at: observed.addingTimeInterval(-61)) == .stale)
        let shortened = try entry(validUntil: observed.addingTimeInterval(60))
        #expect(shortened.status(at: observed.addingTimeInterval(60)) == .stale)
        let cannotExtend = try entry(validUntil: observed.addingTimeInterval(3_600))
        #expect(cannotExtend.status(at: observed.addingTimeInterval(301)) == .stale)
        #expect(try entry(observedAt: nil).status(at: observed) == .unavailable)
        #expect(try entry(status: .failed).status(at: observed) == .failed)
        #expect(try entry(fraction: nil).formattedValue == "未知")
        #expect(try entry(fraction: 0).formattedValue == "0%")
        // A fresh publication date cannot make an old observation current.
        let republished = try QuotaWidgetSnapshot(generatedAt: observed.addingTimeInterval(600), entries: [reading])
        #expect(republished.entries[0].status(at: republished.generatedAt) == .stale)
    }

    @Test func duplicateOpaqueIDsAndUnboundedSnapshotsAreRejected() throws {
        let id = UUID().uuidString
        let first = try entry(id: id)
        let second = try entry(id: id.lowercased())
        #expect(first.id == second.id)
        #expect(throws: QuotaWidgetSnapshotError.self) {
            _ = try QuotaWidgetSnapshot(generatedAt: observed, entries: [first, second])
        }
        let excessive = try (0...QuotaWidgetSnapshot.maximumEntries).map { _ in try entry() }
        #expect(throws: QuotaWidgetSnapshotError.self) {
            _ = try QuotaWidgetSnapshot(generatedAt: observed, entries: excessive)
        }
    }

    @Test func sharedFileRoundTripsFailsClosedAndClearsWithoutCredentials() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedQuotaWidgetSnapshotStore(directoryURL: directory)
        #expect(store.read() == nil)
        let snapshot = try QuotaWidgetSnapshot(generatedAt: observed, entries: [entry(fraction: 0)])
        try store.write(snapshot)
        #expect(store.read() == snapshot)
        let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let text = try String(contentsOf: file, encoding: .utf8)
        for forbidden in ["account_id", "bridge", "token", "password", "baseURL"] {
            #expect(!text.contains(forbidden))
        }
        try Data(repeating: 0, count: QuotaWidgetSnapshot.maximumEncodedBytes + 1).write(to: file)
        #expect(store.read() == nil)
        try store.write(snapshot)
        try store.clear()
        #expect(store.read() == nil)
        try store.clear()
    }

    @Test @MainActor func authorizationChangesAreObservableWithoutEnteringTheMonitoringTab() {
        let driver = SyntheticLiveActivityDriver()
        let coordinator = MonitoringWorkspaceCoordinator(
            credentialStore: MonitoringBridgeCredentialStore(storage: MemoryCredentialStore()),
            metadataStore: MemoryMonitoringMetadataPersistence(), liveActivityDriver: driver
        )
        coordinator.beginSystemActivityObservation()
        #expect(coordinator.activitiesEnabled)
        driver.areActivitiesEnabled = false
        #expect(!coordinator.activitiesEnabled)
        coordinator.beginSystemActivityObservation()
        driver.areActivitiesEnabled = true
        #expect(coordinator.activitiesEnabled)
        #expect(driver.startCount == 0)
    }

    @Test @MainActor func unassociatedActivityIsNeverAdoptedAndOnlyEndsByExplicitChoice() async throws {
        let driver = SyntheticLiveActivityDriver()
        let registration = try await driver.startActivity(sourceID: "source-a", initialSnapshot: nil,
                                                          onPushTokenUpdate: { _, _ in }, onSystemDismissed: { _ in })
        driver.detachActivity() // Simulate request succeeding before its ID was persisted.
        let coordinator = MonitoringWorkspaceCoordinator(
            credentialStore: MonitoringBridgeCredentialStore(storage: MemoryCredentialStore()),
            metadataStore: MemoryMonitoringMetadataPersistence(), liveActivityDriver: driver
        )
        await coordinator.applicationDidBecomeActive()
        let unassociated = try #require(coordinator.unassociatedActivities.first)
        #expect(unassociated.id == registration.activityID)
        #expect(coordinator.localActivityID == nil)
        #expect(coordinator.pendingCreateUUID == nil)
        #expect(coordinator.store == nil)
        #expect(driver.startCount == 1)
        #expect(driver.endedActivityIDs.isEmpty)
        await coordinator.endUnassociatedActivity(unassociated)
        #expect(driver.endedActivityIDs == [registration.activityID])
        #expect(coordinator.unassociatedActivities.isEmpty)
        #expect(coordinator.persistedRecords.isEmpty)
    }
}
