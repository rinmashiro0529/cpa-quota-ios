import Foundation
import Testing
@testable import CPAQuotaKit

@Suite("Server and public model invariants")
struct CoreModelTests {
    @Test func serverCanonicalizationAndPrefix() throws {
        let server = try CPAServer(baseURL: " HTTPS://CPA.EXAMPLE:443/proxy/v0/management/ ")
        #expect(server.identifier == "https://cpa.example/proxy")
        #expect(server.endpoint("quota/fetch").absoluteString == "https://cpa.example/proxy/v0/management/quota/fetch")
        let managementPage = try CPAServer(baseURL: "https://cpa.example/proxy/management.html")
        #expect(server == managementPage)
    }

    @Test(arguments: [
        "http://cpa.example", "ftp://cpa.example", "https://user:pass@cpa.example",
        "https://cpa.example?key=fixture", "https://cpa.example/#quota", "file:///tmp/test",
        "https://cpa.example/%2e%2e/private", "https://cpa.example/proxy%2Fother",
        "https://cpa.example:0", "https://cpa.example:65536"
    ])
    func rejectsUnsafeServerAddresses(_ address: String) {
        #expect(throws: CPAError.self) { try CPAServer(baseURL: address) }
    }

    @Test func decodingServerRevalidatesSecurityPolicy() throws {
        let payload = Data(#"{"baseURL":"http://unsafe.example"}"#.utf8)
        #expect(throws: CPAError.self) { try JSONDecoder().decode(CPAServer.self, from: payload) }
        let server = try CPAServer(baseURL: "https://cpa.example")
        let decoded = try JSONDecoder().decode(CPAServer.self, from: JSONEncoder().encode(server))
        #expect(decoded == server)
    }

    @Test func managementKeyRedactsDescriptions() throws {
        let key = try ManagementKey("  fixture-management-key\n")
        #expect(key.value == "fixture-management-key")
        #expect(!String(describing: key).contains("fixture-management-key"))
        #expect(!String(reflecting: key).contains("fixture-management-key"))
        #expect(throws: CPAError.self) { try ManagementKey(" ") }
        #expect(throws: CPAError.self) { try ManagementKey("fixture\r\nX-Injection: value") }
        #expect(throws: CPAError.self) { try ManagementKey(String(repeating: "x", count: 4097)) }
    }

    @Test func missingAndInvalidFractionsStayUnknown() {
        let missing = QuotaWindow(id: "missing", title: "Unknown")
        #expect(missing.usedFraction == nil)
        #expect(missing.remainingFraction == nil)
        let invalid = QuotaWindow(id: "negative", title: "Unknown", usedFraction: -0.2)
        #expect(invalid.usedFraction == nil)
        #expect(invalid.remainingFraction == nil)
        let over = QuotaWindow(id: "over", title: "Over limit", usedFraction: 1.5)
        #expect(over.usedFraction == 1.5)
        #expect(over.remainingFraction == 0)
        let valid = QuotaWindow(id: "valid", title: "Primary", usedFraction: 0.58)
        #expect(abs((valid.remainingFraction ?? -1) - 0.42) < 0.000001)
        #expect(QuotaWindow(id: "nan", title: "Invalid", usedFraction: .nan).remainingFraction == nil)
    }

    @Test func invalidDurationsAndDecodedNegativeRatiosStayUnknown() throws {
        #expect(QuotaWindow(id: "a", title: "Bad", durationSeconds: -1).durationSeconds == nil)
        #expect(QuotaWindow(id: "a", title: "Bad", durationSeconds: 1e100).durationSeconds == nil)
        #expect(QuotaWindow(id: "a", title: "Fractional", durationSeconds: 0.5).durationSeconds == 0.5)
        let payload = Data(#"{"id":"a","title":"Unknown","usedFraction":-0.5,"durationSeconds":1e100}"#.utf8)
        let decoded = try JSONDecoder().decode(QuotaWindow.self, from: payload)
        #expect(decoded.usedFraction == nil)
        #expect(decoded.remainingFraction == nil)
        #expect(decoded.durationSeconds == nil)
    }

    @Test func unknownCreditsAndNonfiniteMetricsAreNotZero() {
        let credits = QuotaCredits(hasCredits: false, unlimited: false, balance: nil)
        #expect(credits.balance == nil)
        #expect(credits.hasCredits == false)
        #expect(QuotaMetric(id: "bad", label: "Bad", value: .infinity).value == nil)
    }

    @Test func passiveFreshnessUsesItsOwnObservation() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let missing = QuotaSnapshot(accountID: "fixture", provider: "codex", source: .passive, fetchedAt: now)
        #expect(missing.isStale(at: now))
        let old = QuotaSnapshot(accountID: "fixture", provider: "codex", source: .passive, fetchedAt: now,
                                observedAt: now.addingTimeInterval(-600))
        #expect(old.isStale(at: now))
        let live = QuotaSnapshot(accountID: "fixture", provider: "codex", source: .live, fetchedAt: now)
        #expect(!live.isStale(at: now.addingTimeInterval(10)))
        #expect(live.isStale(at: now.addingTimeInterval(300)))
        let future = QuotaSnapshot(accountID: "fixture", provider: "codex", source: .passive, fetchedAt: now,
                                   observedAt: now.addingTimeInterval(120))
        #expect(future.isStale(at: now))
    }

    @Test func errorsDoNotEchoSensitiveDetails() {
        let error = NSError(domain: "fixture-secret", code: 10,
                            userInfo: [NSLocalizedDescriptionKey: "Authorization: Bearer fixture-secret"])
        #expect(!CPAError.normalize(error).localizedDescription.contains("fixture-secret"))
        #expect(CPAError.normalize(URLError(.timedOut)).kind == .timeout)
        #expect(CPAError.normalize(CancellationError()).kind == .cancelled)
    }
}
