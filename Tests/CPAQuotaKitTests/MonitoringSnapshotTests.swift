import Foundation
import Testing
@testable import CPAQuotaKit

@Suite("Monitoring snapshot")
struct MonitoringSnapshotTests {
    private func fixture(version: Int = 1, label: String = "Account A") -> Data {
        Data("""
        {"version":\(version),"sequence":1,"phase":"ready","generated_at":1800000000,"expires_at":1800003600,"accounts":[{"id":"a","label":"\(label)","provider":"codex","window_id":"week","window_label":"Week","status":"ok"}]}
        """.utf8)
    }
    @Test func aliasesAndDisplayTextUseUTF8ByteLimits() throws {
        #expect(throws: Never.self) { try MonitoringAccount(id: String(repeating: "a", count: 128), label: String(repeating: "界", count: 42) + "x", provider: "codex", windowID: "primary", windowLabel: "Week", status: .ok) }
        #expect(throws: MonitoringError.invalidConfiguration) { try MonitoringAccount(id: String(repeating: "a", count: 129), label: "safe", provider: "codex", windowID: "primary", windowLabel: "Week", status: .ok) }
        #expect(throws: MonitoringError.invalidConfiguration) { try MonitoringAccount(id: "safe", label: String(repeating: "界", count: 43), provider: "codex", windowID: "primary", windowLabel: "Week", status: .ok) }
        #expect(throws: Never.self) { try MonitoringRegistration(id: UUID(), sourceID: String(repeating: "s", count: 128), accountIDs: ["a"], duration: .oneHour, activityID: "activity", pushToken: MonitoringPushToken("abcd")) }
        #expect(throws: MonitoringError.invalidConfiguration) { try MonitoringRegistration(id: UUID(), sourceID: String(repeating: "s", count: 129), accountIDs: ["a"], duration: .oneHour, activityID: "activity", pushToken: MonitoringPushToken("abcd")) }
    }

    @Test func displayTextAllowsPunctuationButRejectsRawIdentity() throws {
        let account = try MonitoringAccount(id: "account-1", label: "账号 · 1", provider: "codex", windowID: "primary", windowLabel: "5-hour limit", remainingFraction: 0.5, value: 12, unit: "credits % / requests", status: .ok)
        #expect(account.unit == "credits % / requests")
        for label in ["private@example.com", "https://example.test", "bad\nlabel"] {
            #expect(throws: (any Error).self) {
                try MonitoringAccount(id: "account-1", label: label, provider: "codex", windowID: "primary", windowLabel: "Week", status: .ok)
            }
        }
    }

    @Test func oversizedInitialContentIsRejected() throws {
        let accounts = try (0..<5).map { index in
            try MonitoringAccount(id: String(index) + String(repeating: "a", count: 127),
                                  label: String(repeating: "b", count: 128),
                                  provider: String(repeating: "c", count: 128),
                                  windowID: String(repeating: "d", count: 128),
                                  windowLabel: String(repeating: "e", count: 128), status: .ok)
        }
        #expect(throws: MonitoringError.invalidConfiguration) {
            try MonitoringSnapshot(sequence: 0, phase: .ready, generatedAt: Date(timeIntervalSince1970: 1_800_000_000), expiresAt: Date(timeIntervalSince1970: 1_800_000_100), accounts: accounts)
        }
    }

    @Test func publicInitialContentRejectsInvalidFraction() throws {
        let account = try MonitoringAccount(id: "a", label: "账号1", provider: "codex", windowID: "primary", windowLabel: "5小时", status: .unavailable)
        let snapshot = try MonitoringSnapshot(sequence: 0, phase: .partial, generatedAt: Date(timeIntervalSince1970: 1_800_000_000), expiresAt: Date(timeIntervalSince1970: 1_799_999_999), accounts: [account])
        #expect(try JSONDecoder().decode(MonitoringSnapshot.self, from: snapshot.activityContentData()) == snapshot)
        #expect(throws: MonitoringError.invalidConfiguration) {
            try MonitoringAccount(id: "a", label: "safe", provider: "codex", windowID: "primary", windowLabel: "Week", remainingFraction: 1.1, status: .ok)
        }
    }

    @Test func rejectsEmailInAccountLabel() {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(MonitoringSnapshot.self, from: fixture(label: "private@example.com")) }
    }
    @Test func rejectsUnknownVersion() {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(MonitoringSnapshot.self, from: fixture(version: 2)) }
    }
    @Test func unixSecondsAreDecodedWithoutFoundationEpoch() throws {
        let snapshot = try JSONDecoder().decode(MonitoringSnapshot.self, from: fixture())
        #expect(snapshot.generatedAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(snapshot.accounts[0].observedAt == nil)
        let encoded = try snapshot.activityContentData()
        #expect(try JSONDecoder().decode(MonitoringSnapshot.self, from: encoded) == snapshot)
    }
}
