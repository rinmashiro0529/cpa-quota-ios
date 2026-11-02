import Foundation
import Testing
import CPAQuotaKit
import CPAQuotaActivity
import CPAQuotaUI

@Suite("Live Activity wire contract and local lifecycle")
struct ActivityReliabilityTests {
    private func account(_ id: String = "a", status: MonitoringAccount.Status = .ok,
                         value: Double? = nil, remaining: Double? = 0.42) throws -> MonitoringAccount {
        try MonitoringAccount(id: id, label: "Safe alias", provider: "codex", windowID: "primary",
                              windowLabel: "5 hours", remainingFraction: remaining, value: value,
                              unit: value == nil ? nil : "credits", observedAt: Date(timeIntervalSince1970: 1_800_000_000),
                              status: status)
    }

    private func snapshot(sequence: UInt64 = 2, phase: MonitoringSnapshot.Phase = .ready,
                          accounts: [MonitoringAccount]? = nil) throws -> MonitoringSnapshot {
        try MonitoringSnapshot(sequence: sequence, phase: phase,
                               generatedAt: Date(timeIntervalSince1970: 1_800_000_001),
                               expiresAt: Date(timeIntervalSince1970: 1_800_000_900),
                               accounts: accounts ?? [account()])
    }

    @Test func backendSnapshotIsTheContentStateForBothAPNsEvents() throws {
        let session = try #require(JSONSerialization.jsonObject(with: ContractFixtures.data("monitoring-v1-session.json")) as? [String: Any])
        let wireSnapshot = try #require(session["snapshot"] as? [String: Any])
        struct Payload: Decodable {
            struct APS: Decodable {
                let event: String
                let state: CPAQuotaActivity.CPAQuotaActivityAttributes.ContentState
                enum CodingKeys: String, CodingKey { case event; case state = "content-state" }
            }
            let aps: APS
        }
        for event in ["update", "end"] {
            // Go Provider.Send places this same shared snapshot directly in
            // aps.content-state; it does not create an app-specific wrapper.
            let payload: [String: Any] = ["aps": ["timestamp": 1_800_000_001, "event": event,
                                                 "stale-date": 1_800_000_900, "content-state": wireSnapshot]]
            let decoded = try JSONDecoder().decode(Payload.self, from: JSONSerialization.data(withJSONObject: payload))
            #expect(decoded.aps.event == event)
            #expect(decoded.aps.state.snapshot.sequence == 2)
            #expect(decoded.aps.state.account()?.remainingFraction == 0.42)
            let encoded = try JSONEncoder().encode(decoded.aps.state)
            let roundTrip = try #require(JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
            #expect(roundTrip.isEqual(to: wireSnapshot))
            #expect(roundTrip["snapshotData"] == nil)
            #expect(roundTrip["focusedIndex"] == nil)
        }
    }

    @Test func realEncodedContentAndAttributesRespectTheCombinedBudget() throws {
        let accounts = try (0..<5).map { index in
            try MonitoringAccount(id: String(repeating: "a", count: 100) + String(index),
                                  label: String(repeating: "A", count: 128), provider: "codex", windowID: "primary",
                                  windowLabel: String(repeating: "W", count: 128), remainingFraction: 0.42,
                                  value: 1.2, unit: String(repeating: "U", count: 128),
                                  observedAt: Date(timeIntervalSince1970: 1_800_000_000), status: .ok)
        }
        let snapshot = try snapshot(accounts: accounts)
        let state = try CPAQuotaActivity.CPAQuotaLiveActivityState(snapshot: snapshot)
        let attributes = try CPAQuotaActivity.CPAQuotaActivityAttributes(sourceID: String(repeating: "s", count: 128))
        let contentBytes = try JSONEncoder().encode(state).count
        let attributesBytes = try JSONEncoder().encode(attributes).count
        #expect(contentBytes > 3_072)
        #expect(contentBytes <= 3_584)
        #expect(attributesBytes <= 512)
        #expect(contentBytes + attributesBytes <= 4_096)
        try attributes.validateContent(state)
        // This was a valid snapshot that PR3 expanded beyond Apple's budget.
        let legacyEnvelope = ["snapshotData": try snapshot.activityContentData().base64EncodedString()]
        #expect(try JSONEncoder().encode(legacyEnvelope).count > 4_096)
    }

    @Test func decodingAppliesSafeSnapshotValidationAndDoesNotAcceptTheOldEnvelope() throws {
        let safe = try snapshot()
        let encoded = try safe.activityContentData()
        let legacy: [String: Any] = ["snapshotData": encoded.base64EncodedString(), "focusedIndex": -1]
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CPAQuotaActivity.CPAQuotaLiveActivityState.self,
                                     from: JSONSerialization.data(withJSONObject: legacy))
        }
        var root = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var account = try #require((root["accounts"] as? [[String: Any]])?.first)
        account["label"] = "private@example.test"
        root["accounts"] = [account]
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CPAQuotaActivity.CPAQuotaLiveActivityState.self,
                                     from: JSONSerialization.data(withJSONObject: root))
        }
        account["label"] = String(repeating: "L", count: 128)
        account["provider"] = String(repeating: "p", count: 128)
        account["window_id"] = String(repeating: "w", count: 128)
        account["window_label"] = String(repeating: "W", count: 128)
        account["unit"] = String(repeating: "U", count: 128)
        root["accounts"] = (0..<5).map { index in
            var item = account
            item["id"] = String(repeating: "a", count: 127) + String(index)
            return item
        }
        #expect(try JSONSerialization.data(withJSONObject: root).count > 3_584)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CPAQuotaActivity.CPAQuotaLiveActivityState.self,
                                     from: JSONSerialization.data(withJSONObject: root))
        }
    }

    @Test func sourceAttributesValidateDirectAndDecodedInputs() throws {
        for invalid in ["", "name@example.test", "https://server.test", "line\nbreak", "has space", String(repeating: "a", count: 129)] {
            #expect(throws: MonitoringError.invalidConfiguration) {
                try CPAQuotaActivity.CPAQuotaActivityAttributes(sourceID: invalid)
            }
            let encoded = try JSONEncoder().encode(["sourceID": invalid])
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(CPAQuotaActivity.CPAQuotaActivityAttributes.self, from: encoded)
            }
        }
        let attributes = try CPAQuotaActivity.CPAQuotaActivityAttributes(sourceID: "来源_1")
        #expect(try JSONDecoder().decode(CPAQuotaActivity.CPAQuotaActivityAttributes.self,
                                        from: JSONEncoder().encode(attributes)) == attributes)
    }

    @Test func budgetUsesEncodedBytesForUnicodeAndEscapedSlashes() throws {
        let accounts = try (0..<3).map { index in
            try MonitoringAccount(id: "account-\(index)", label: String(repeating: "号", count: 40),
                                  provider: "plugin", windowID: "remaining", windowLabel: String(repeating: "窗", count: 40),
                                  value: Double.greatestFiniteMagnitude, unit: String(repeating: "/", count: 128), status: .stale)
        }
        let state = try CPAQuotaActivity.CPAQuotaLiveActivityState(snapshot: snapshot(accounts: accounts))
        let attributes = try CPAQuotaActivity.CPAQuotaActivityAttributes(sourceID: String(repeating: "源", count: 40))
        let content = try JSONEncoder().encode(state)
        let staticData = try JSONEncoder().encode(attributes)
        #expect(content.count <= 3_584)
        #expect(content.count + staticData.count <= 4_096)
        try attributes.validateContent(state)
        #expect(try JSONDecoder().decode(CPAQuotaActivity.CPAQuotaLiveActivityState.self, from: content) == state)
    }

    @Test func localSelectionHandlesExtremeIndicesWithoutChangingTheWire() throws {
        let state = try CPAQuotaActivity.CPAQuotaLiveActivityState(snapshot: snapshot(accounts: [account("a"), account("b"), account("c")]))
        let before = state.snapshot
        for index in [Int.min, -4, -1, 0, 1, 4, Int.max] {
            let selected = try #require(state.account(at: index))
            #expect(state.accounts.contains(selected))
        }
        #expect(state.account(at: -1)?.id == "c")
        #expect(state.snapshot == before)
        #expect(CPAQuotaActivity.CPAQuotaLiveActivityState.normalizedIndex(Int.min, count: 0) == 0)
    }

    @Test func localUpdatesRequireANewerServerSequence() throws {
        let current = try CPAQuotaActivity.CPAQuotaLiveActivityState(snapshot: snapshot(sequence: 4))
        #expect(try !current.accepts(snapshot(sequence: 3)))
        #expect(try !current.accepts(snapshot(sequence: 4)))
        #expect(try !current.accepts(snapshot(sequence: 4, phase: .failed)))
        #expect(try current.accepts(snapshot(sequence: 5)))
        let last = try CPAQuotaActivity.CPAQuotaLiveActivityState(snapshot: snapshot(sequence: .max))
        #expect(try !last.accepts(snapshot(sequence: 0)))
    }

    @Test func remoteSnapshotCanMatchLocalPlaceholderWithoutLosingStaleOrTerminalStatus() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let pending = try MonitoringAccount(id: "pending", label: "等待读数", provider: "cpa",
                                            windowID: "pending", windowLabel: "等待服务端", status: .unavailable)
        let remote = try MonitoringSnapshot(sequence: 0, phase: .partial, generatedAt: now,
                                            expiresAt: now, accounts: [pending])
        let decoded = try JSONDecoder().decode(MonitoringSnapshot.self, from: remote.activityContentData())
        #expect(decoded == remote)
        #expect(CPAQuotaActivityPresentation.status(snapshot: decoded, account: pending, isStale: true) == "数据已过期")
        for phase in [MonitoringSnapshot.Phase.stopped, .expired] {
            let terminal = try MonitoringSnapshot(sequence: 0, phase: phase, generatedAt: now,
                                                  expiresAt: now, accounts: [pending])
            #expect(CPAQuotaActivityPresentation.status(snapshot: terminal, account: pending, isStale: true)
                    == (phase == .stopped ? "已停止" : "已到期"))
        }
    }

    @Test func retainedValuesNeverConcealStaleOrTerminalStatus() throws {
        let account = try account()
        #expect(try CPAQuotaActivityPresentation.status(snapshot: snapshot(), account: account, isStale: true) == "数据已过期")
        #expect(try CPAQuotaActivityPresentation.status(snapshot: snapshot(phase: .expired), account: account, isStale: true) == "已到期")
        #expect(try CPAQuotaActivityPresentation.status(snapshot: snapshot(phase: .stopped), account: account, isStale: false) == "已停止")
        #expect(try CPAQuotaActivityPresentation.status(snapshot: snapshot(phase: .partial), account: account, isStale: false) == "部分可用")
        #expect(try CPAQuotaActivityPresentation.status(snapshot: snapshot(), account: self.account(status: .stale), isStale: false) == "上次读数")
        #expect(try CPAQuotaActivityPresentation.status(snapshot: snapshot(), account: self.account(status: .failed), isStale: false) == "读取失败")
        #expect(try CPAQuotaActivityPresentation.compactStatus(snapshot: snapshot(phase: .expired), account: account, isStale: true) == "到期")
        #expect(try CPAQuotaActivityPresentation.compactStatus(snapshot: snapshot(), account: account, isStale: true) == "旧值")
        #expect(try CPAQuotaActivityPresentation.compactStatus(snapshot: snapshot(), account: account, isStale: false) == nil)
        #expect(try CPAQuotaActivityPresentation.value(self.account(remaining: nil)) == "未知")
        #expect(try CPAQuotaActivityPresentation.value(self.account(value: 0, remaining: nil)) == "0.00 credits")
    }

    @Test @MainActor func syntheticLifecycleTargetsExactIDsAndRestoresOnlyTheMatchingSource() async throws {
        let driver = SyntheticLiveActivityDriver()
        let first = try await driver.startActivity(sourceID: "source-a", initialSnapshot: nil,
                                                  onPushTokenUpdate: { _, _ in }, onSystemDismissed: { _ in })
        driver.detachActivity()
        let second = try await driver.startActivity(sourceID: "source-b", initialSnapshot: nil,
                                                   onPushTokenUpdate: { _, _ in }, onSystemDismissed: { _ in })
        #expect(first.activityID != second.activityID)
        let mismatch = try await driver.restoreActivity(activityID: first.activityID, sourceID: "source-b",
                                                        onPushTokenUpdate: { _, _ in }, onSystemDismissed: { _ in })
        #expect(mismatch == nil)
        #expect(driver.activeActivityID == second.activityID)
        await driver.endActivity(activityID: "not-present", immediate: true)
        #expect(driver.activeActivityID == second.activityID)
        let restored = try await driver.restoreActivity(activityID: first.activityID, sourceID: "source-a",
                                                       onPushTokenUpdate: { _, _ in }, onSystemDismissed: { _ in })
        #expect(restored?.activityID == first.activityID)
        #expect(driver.startCount == 2)
        await driver.endActivity(activityID: second.activityID, immediate: true)
        #expect(driver.activeActivityID == first.activityID)
        #expect(driver.endedActivityIDs == [second.activityID])
        driver.detachActivity()
        await driver.endActivity(activityID: first.activityID, immediate: true)
        #expect(driver.endedActivityIDs == [second.activityID, first.activityID])
    }

    @Test @MainActor func asynchronousTokenIsAttributedAndDetachStopsCallbacks() async throws {
        let driver = SyntheticLiveActivityDriver(simulatedPushTokenHex: nil)
        var events: [String] = []
        let activity = try await driver.startActivity(sourceID: "source", initialSnapshot: nil,
                                                     onPushTokenUpdate: { id, token in events.append(id + ":" + token) },
                                                     onSystemDismissed: { _ in })
        #expect(activity.initialPushTokenHex == nil)
        driver.simulateSystemPushTokenRotation("aabb")
        #expect(events == [activity.activityID + ":aabb"])
        driver.detachActivity()
        driver.simulateSystemPushTokenRotation("ccdd")
        #expect(events.count == 1)
        #expect(driver.latestPushTokenHex == nil)
        #expect(driver.startCount == 1)
    }

    @Test @MainActor func syntheticDriverDoesNotPublishLateOrForeignSnapshots() async throws {
        let driver = SyntheticLiveActivityDriver()
        let activity = try await driver.startActivity(sourceID: "source", initialSnapshot: snapshot(sequence: 2),
                                                     onPushTokenUpdate: { _, _ in }, onSystemDismissed: { _ in })
        try await driver.updateActivity(activityID: activity.activityID, snapshot: snapshot(sequence: 4))
        try await driver.updateActivity(activityID: activity.activityID, snapshot: snapshot(sequence: 3))
        try await driver.updateActivity(activityID: "foreign", snapshot: snapshot(sequence: 9))
        #expect(driver.lastUpdatedSnapshot?.sequence == 4)
    }
}
