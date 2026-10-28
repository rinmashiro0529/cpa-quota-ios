import Foundation
import Testing
import CPAQuotaKit

@Suite("Connection health and freshness")
struct BackendReliabilityHealthTests {
    @Test func noObservationIsNotAHealthyConnection() {
        let account = CPAAccount(id: "a", authIndex: nil, provider: "codex", displayName: "A")
        let health = ConnectionHealth(record: QuotaRecord(account: account), eligibility: .eligible, now: Date())
        #expect(health.connection == .unknown)
        #expect(health.data == .unknown)
    }
    @Test func expiredCooldownDoesNotClaimRecoveredOrFreshData() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = QuotaSnapshot(accountID: "a", provider: "codex", source: .live,
                                     fetchedAt: now.addingTimeInterval(-301), observedAt: nil)
        let account = CPAAccount(id: "a", authIndex: nil, provider: "codex", displayName: "A")
        let record = QuotaRecord(account: account, snapshot: snapshot,
                                 error: CPAError(.rateLimited, layer: .management, retryAfter: now.addingTimeInterval(-1)))
        let health = ConnectionHealth(record: record, eligibility: .eligible, now: now)
        #expect(health.connection == .failed(CPAError(.rateLimited, layer: .management, retryAfter: now.addingTimeInterval(-1))))
        #expect(health.data == .stale)
        #expect(QuotaFreshness(snapshot: snapshot, now: now).state == .stale)
    }
}
