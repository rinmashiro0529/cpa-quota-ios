import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CPAQuotaKit

enum MonitoringCapabilityFixture {
    static func data(sourceID: String = "personal", accountIDs: [String] = ["account-1"], used: Int = 0) throws -> Data {
        let accounts: [[String: Any]] = accountIDs.enumerated().map { index, id in
            ["id": id, "safe_id": "account-\(index + 1)", "label": "Account \(index + 1)",
             "provider": "codex", "window_id": "primary", "window_label": "5 hour"]
        }
        let capacity: [String: Any] = ["limit": 256, "used": used, "remaining": max(0, 256 - used),
            "warning_at": 205, "status": used >= 256 ? "exhausted" : used >= 205 ? "warning" : "ok",
            "can_create_session": used < 256, "can_record_cancellation": used < 256]
        return try JSONSerialization.data(withJSONObject: ["version": 1, "generated_at": 1_800_000_000,
            "sources": [["id": sourceID, "accounts": accounts]], "capacity": capacity])
    }
}

private actor CapabilityHTTPFixture: HTTPTransport {
    let body: Data
    let status: Int
    private(set) var requests: [URLRequest] = []
    init(body: Data, status: Int = 200) { self.body = body; self.status = status }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        return HTTPResponse(statusCode: status, headers: [:], body: body)
    }
}

private actor RefreshCooldownFixture: HTTPTransport {
    let id: UUID
    let limitedMethod: String?
    private(set) var calls: [String] = []
    init(id: UUID, limitedMethod: String? = nil) { self.id = id; self.limitedMethod = limitedMethod }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let method = request.httpMethod ?? "GET"
        calls.append(method)
        if method == limitedMethod || request.url?.lastPathComponent == "refresh" {
            return HTTPResponse(statusCode: 429, headers: ["Retry-After": "60"], body: Data())
        }
        if method == "DELETE" { return HTTPResponse(statusCode: 204, headers: [:], body: Data()) }
        let revision = method == "PUT" ? 2 : 1
        let json = """
        {"version":1,"id":"\(id.uuidString)","source_id":"personal","account_ids":["account-1"],"activity_id":"activity","starts_at":1800000000,"expires_at":1800003600,"status":"active","revision":\(revision),"delivery_state":"pending"}
        """
        return HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
    }
}

@Suite("Authenticated monitoring capabilities")
struct MonitoringCapabilitiesTests {
    @Test func decodesTheSharedGoContractAndChecksExactAuthorization() throws {
        let value = try JSONDecoder().decode(MonitoringCapabilities.self,
            from: ContractFixtures.data("monitoring-capabilities-v1.json"))
        #expect(value.version == 1)
        #expect(value.capacity.remaining == value.capacity.limit - value.capacity.used)
        let source = try #require(value.sources.first)
        let account = try #require(source.accounts.first)
        #expect(value.authorizes(sourceID: source.id, accountIDs: [account.id]))
        #expect(!value.authorizes(sourceID: "ungranted", accountIDs: [account.id]))
        #expect(!value.authorizes(sourceID: source.id, accountIDs: ["ungranted"]))
        #expect(!value.authorizes(sourceID: source.id, accountIDs: [account.id, account.id]))
        #expect(!value.authorizes(sourceID: source.id, accountIDs: []))
    }

    @Test func rejectsContradictoryCapacityAndDuplicateAuthorization() throws {
        let data = try MonitoringCapabilityFixture.data()
        let original = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["remaining", "warning_at", "status"] {
            var root = original
            var capacity = try #require(root["capacity"] as? [String: Any])
            if key == "status" { capacity[key] = "exhausted" }
            else { capacity[key] = -1 }
            root["capacity"] = capacity
            let invalid = try JSONSerialization.data(withJSONObject: root)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(MonitoringCapabilities.self, from: invalid) }
        }
        var root = original
        let sources = try #require(root["sources"] as? [[String: Any]])
        root["sources"] = sources + sources
        let invalid = try JSONSerialization.data(withJSONObject: root)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(MonitoringCapabilities.self, from: invalid) }
    }

    @Test func capabilitiesUsesBearerAndPreservesTheDeploymentPrefixWithoutMutating() async throws {
        let transport = CapabilityHTTPFixture(body: try MonitoringCapabilityFixture.data())
        let client = try CPAMonitorClient(baseURL: #require(URL(string: "https://example.test/monitor")),
            token: MonitorBridgeToken("synthetic-capability-token"), transport: transport)
        _ = try await client.capabilities()
        let requests = await transport.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/monitor/v1/capabilities")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-capability-token")
    }

    @Test func invalidAndOlderServicesNeverMasqueradeAsVerified() async throws {
        for (status, expected) in [(401, MonitoringError.unauthorized), (403, .forbidden), (404, .notFound), (503, .serviceUnavailable)] {
            let transport = CapabilityHTTPFixture(body: Data(), status: status)
            let client = try CPAMonitorClient(baseURL: #require(URL(string: "https://example.test")),
                token: MonitorBridgeToken("fixture"), transport: transport)
            await #expect(throws: expected) { try await client.capabilities() }
        }
        let transport = CapabilityHTTPFixture(body: Data(#"{"ok":true}"#.utf8))
        let client = try CPAMonitorClient(baseURL: #require(URL(string: "https://example.test")),
            token: MonitorBridgeToken("fixture"), transport: transport)
        await #expect(throws: MonitoringError.invalidResponse) { try await client.capabilities() }
    }

    @Test func refreshThrottleLeavesQueryCancellationAndTokenRotationAvailable() async throws {
        let id = UUID()
        let transport = RefreshCooldownFixture(id: id)
        let client = try CPAMonitorClient(baseURL: #require(URL(string: "https://example.test")),
            token: MonitorBridgeToken("fixture"), transport: transport,
            clock: { Date(timeIntervalSince1970: 1_800_000_000) })
        await #expect(throws: MonitoringError.rateLimited) { try await client.refresh(id: id) }
        await #expect(throws: MonitoringError.rateLimited) { try await client.refresh(id: id) }
        #expect(try await client.get(id: id).id == id)
        #expect(try await client.rotate(id: id, activityID: "activity", token: MonitoringPushToken("abcd"), revision: 1).revision == 2)
        #expect(try await client.stop(id: id) == nil)
        #expect(await transport.calls == ["POST", "GET", "PUT", "DELETE"])
    }

    @Test func controlOperationsHonorTheirOwnRetryAfter() async throws {
        for method in ["DELETE", "PUT"] {
            let id = UUID()
            let transport = RefreshCooldownFixture(id: id, limitedMethod: method)
            let client = try CPAMonitorClient(baseURL: #require(URL(string: "https://example.test")),
                token: MonitorBridgeToken("fixture"), transport: transport,
                clock: { Date(timeIntervalSince1970: 1_800_000_000) })
            for _ in 0..<2 {
                if method == "DELETE" {
                    await #expect(throws: MonitoringError.rateLimited) { try await client.stop(id: id) }
                } else {
                    await #expect(throws: MonitoringError.rateLimited) {
                        try await client.rotate(id: id, activityID: "activity", token: MonitoringPushToken("abcd"), revision: 1)
                    }
                }
            }
            #expect(try await client.get(id: id).id == id)
            #expect(await transport.calls == [method, "GET"])
        }
    }
}
