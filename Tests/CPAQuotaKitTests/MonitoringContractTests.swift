import Foundation
import Testing
@testable import CPAQuotaKit

@Suite("Monitoring v1 shared contract")
struct MonitoringContractTests {
    private func sharedFixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("ContractFixtures").appendingPathComponent(name)
        return try Data(contentsOf: url)
    }

    private var fixture: String {
        get throws { String(decoding: try sharedFixture("monitoring-v1-session.json"), as: UTF8.self) }
    }

    @Test func sharedSessionDecodesAndSnapshotRoundTrips() throws {
        let session = try JSONDecoder().decode(MonitoringSession.self, from: Data(fixture.utf8))
        #expect(session.id.uuidString.lowercased() == "11111111-1111-4111-8111-111111111111")
        #expect(session.revision == 2)
        let snapshot = try #require(session.snapshot)
        #expect(snapshot.accounts[0].label == "账号1")
        #expect(snapshot.accounts[0].remainingFraction == 0.42)
        #expect(snapshot.generatedAt == Date(timeIntervalSince1970: 1_800_000_001))
        #expect(try JSONDecoder().decode(MonitoringSnapshot.self, from: snapshot.activityContentData()) == snapshot)
        let encoded = try JSONEncoder().encode(session)
        #expect(try JSONDecoder().decode(MonitoringSession.self, from: encoded) == session)
    }

    @Test func sharedQuotaVectorsMatchNativeParserSemantics() throws {
        let vectors = try #require(JSONSerialization.jsonObject(with: sharedFixture("quota-parity-v1.json")) as? [[String: Any]])
        #expect(vectors.count == 4)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for vector in vectors {
            let provider = try #require(vector["provider"] as? String)
            let body = try JSONSerialization.data(withJSONObject: #require(vector["body"]))
            let account = CPAAccount(id: "fixture", authIndex: "1", provider: provider, displayName: "Fixture")
            switch provider {
            case "codex":
                let snapshot = try PayloadDecoder.codex(body, account: account, now: now)
                let primary = try #require(snapshot.windows.first { $0.id == "primary" })
                let secondary = try #require(snapshot.windows.first { $0.id == "secondary" })
                #expect(primary.usedFraction == 1.25)
                #expect(primary.remainingFraction == vector["expected_primary_remaining"] as? Double)
                #expect(secondary.remainingFraction == vector["expected_secondary_remaining"] as? Double)
            case "xai":
                let snapshot = try PayloadDecoder.xai(body, account: account, now: now)
                #expect(snapshot.windows.first?.remainingFraction == vector["expected_remaining_fraction"] as? Double)
                #expect(snapshot.metrics.first { $0.id == "monthly-limit" }?.value == vector["expected_monthly_limit_usd"] as? Double)
                #expect(snapshot.metrics.first { $0.id == "used" }?.value == vector["expected_used_usd"] as? Double)
            case "plugin":
                let snapshot = try PayloadDecoder.pluginQuota(body, account: account, now: now)
                #expect(snapshot.windows.first?.remainingFraction == nil)
                #expect(snapshot.metrics.first?.value == vector["expected_value"] as? Double)
                #expect(snapshot.metrics.first?.unit == vector["expected_unit"] as? String)
            default:
                Issue.record("Unrecognized shared quota provider")
            }
        }
    }

    @Test func sessionUUIDEncodesLowercase() throws {
        let letters = try fixture.replacingOccurrences(of: "11111111-1111-4111-8111-111111111111", with: "abcdefab-cdef-4abc-8def-abcdefabcdef")
        let session = try JSONDecoder().decode(MonitoringSession.self, from: Data(letters.utf8))
        let encoded = String(decoding: try JSONEncoder().encode(session), as: UTF8.self)
        #expect(encoded.contains("abcdefab-cdef-4abc-8def-abcdefabcdef"))
    }

    @Test func controlAccountIDsMayContainAtAndDot() throws {
        let input = try fixture.replacingOccurrences(of: "fixture-upstream-account", with: "account.name@example.test")
        let session = try JSONDecoder().decode(MonitoringSession.self, from: Data(input.utf8))
        #expect(session.accountIDs == ["account.name@example.test"])
        let request = try MonitoringRegistration(id: session.id, sourceID: "personal", accountIDs: session.accountIDs, duration: .fourHours, activityID: "activity", pushToken: MonitoringPushToken("abcd"))
        #expect(request.accountIDs == session.accountIDs)
    }

    @Test func invalidLeaseAndActivityAreRejected() throws {
        let tooLong = try fixture.replacingOccurrences(of: "1800014400", with: "1800028801")
        #expect(throws: (any Error).self) { try JSONDecoder().decode(MonitoringSession.self, from: Data(tooLong.utf8)) }
        let control = try fixture.replacingOccurrences(of: "fixture-activity", with: "fixture\\nactivity")
        #expect(throws: (any Error).self) { try JSONDecoder().decode(MonitoringSession.self, from: Data(control.utf8)) }
    }

    @Test func unknownPhaseIsRejected() throws {
        let invalid = try fixture.replacingOccurrences(of: "\"ready\"", with: "\"unknown\"")
        #expect(throws: (any Error).self) { try JSONDecoder().decode(MonitoringSession.self, from: Data(invalid.utf8)) }
    }

    @Test func staleSnapshotExpiryCanPrecedeGeneration() throws {
        let stale = try fixture.replacingOccurrences(of: "1800000900", with: "1799999999")
        let snapshot = try #require(JSONDecoder().decode(MonitoringSession.self, from: Data(stale.utf8)).snapshot)
        #expect(snapshot.expiresAt < snapshot.generatedAt)
    }
}
