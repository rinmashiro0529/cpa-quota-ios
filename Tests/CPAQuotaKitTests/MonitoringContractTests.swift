import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CPAQuotaKit

private final class ContractFixtureBundleMarker: NSObject {}

enum ContractFixtures {
    static var bundle: Bundle {
        #if SWIFT_PACKAGE
        Bundle.module
        #else
        Bundle(for: ContractFixtureBundleMarker.self)
        #endif
    }

    static func url(_ name: String) throws -> URL {
        guard let url = bundle.url(forResource: name, withExtension: nil, subdirectory: "ContractFixtures") else {
            throw NSError(domain: "ContractFixtures", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Missing bundled contract fixture: \(name)"])
        }
        return url
    }

    static func data(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }
}

private actor ContractSequenceTransport: HTTPTransport {
    private var responses: [Data]
    init(_ responses: [Data]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return HTTPResponse(statusCode: 200, headers: [:], body: responses.removeFirst())
    }
}

@Suite("Monitoring v1 shared contract")
struct MonitoringContractTests {
    private func sharedFixture(_ name: String) throws -> Data {
        try ContractFixtures.data(name)
    }

    private var fixture: String {
        get throws { String(decoding: try sharedFixture("monitoring-v1-session.json"), as: UTF8.self) }
    }

    @Test func sharedFixturesAreBundledRatherThanReadFromTheSourceTree() throws {
        let resourceRoot = try #require(ContractFixtures.bundle.resourceURL)
        for name in ["monitoring-v1-session.json", "quota-parity-v1.json"] {
            let url = try ContractFixtures.url(name)
            #expect(url.path.hasPrefix(resourceRoot.path + "/"))
            #expect(try Data(contentsOf: url).isEmpty == false)
        }
    }

    @Test func sharedCPAEnvelopeVectorsMatchNativeUnwrapping() throws {
        let vectors = try #require(JSONSerialization.jsonObject(with: sharedFixture("cpa-envelope-v1.json")) as? [[String: Any]])
        #expect(!vectors.isEmpty)
        for vector in vectors {
            let name = try #require(vector["name"] as? String)
            let expected = try #require(vector["expected"] as? [String: Any])
            let valid = try #require(expected["valid"] as? Bool)
            let status = try #require(expected["status"] as? Int)
            let now = Date(timeIntervalSince1970: try #require(vector["now"] as? Double))
            let body = try JSONSerialization.data(withJSONObject: #require(vector["envelope"]))
            do {
                let result = try PayloadDecoder.unwrapAPICall(body, now: now)
                #expect(valid && (200..<300).contains(status), "Unexpected successful envelope: \(name)")
                #expect(!result.isEmpty)
            } catch let error as CPAError {
                if !valid {
                    #expect(error.kind == .invalidResponse, "Invalid envelope: \(name)")
                } else {
                    #expect(!(200..<300).contains(status), "Unexpected rejected envelope: \(name)")
                    #expect(error.layer == .upstream)
                    #expect(error.statusCode == status)
                    if status == 429 { #expect(error.kind == .rateLimited) }
                    let expectedRetry = (expected["retry_after_seconds"] as? Double).map { now.addingTimeInterval($0) }
                    #expect(error.retryAfter == expectedRetry, "Retry-After contract: \(name)")
                }
            }
        }
    }

    @Test @MainActor func serviceLifecycleSequencesAreAcceptedWithoutWeakeningStaleResponseProtection() async throws {
        let root = try #require(JSONSerialization.jsonObject(with: sharedFixture("monitoring-lifecycle-v1.json")) as? [String: Any])
        #expect(root["version"] as? Int == 1)
        let cases = try #require(root["cases"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        for testCase in cases {
            let name = try #require(testCase["name"] as? String)
            let values = try #require(testCase["sessions"] as? [[String: Any]])
            let inputs = try values.map { try JSONSerialization.data(withJSONObject: $0) }
            #expect(inputs.count >= 2)
            let first = try #require(inputs.first)
            let transport = ContractSequenceTransport(inputs + [first])
            let client = try CPAMonitorClient(baseURL: #require(URL(string: "https://contract.example.test")),
                                             token: MonitorBridgeToken("synthetic-contract-token"), transport: transport)
            let store = MonitoringStore(client: client)
            var last: MonitoringSession?
            for data in inputs {
                let expected = try JSONDecoder().decode(MonitoringSession.self, from: data)
                await store.load(id: expected.id)
                #expect(store.error == nil, "Service transition: \(name)")
                #expect(store.session == expected, "Service transition: \(name)")
                last = expected
            }
            let terminal = try #require(last)
            #expect(terminal.status != .active)
            await store.load(id: terminal.id)
            #expect(store.error == .invalidResponse, "Late active response: \(name)")
            #expect(store.session == terminal)
        }
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
