import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CPAQuotaKit

private struct RedirectTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        HTTPResponse(statusCode: 302, headers: [:], body: Data())
    }
}

private actor UnauthorizedTransport: HTTPTransport {
    private(set) var calls = 0
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        calls += 1
        return HTTPResponse(statusCode: 401, headers: [:], body: Data("secret".utf8))
    }
}

private actor RateLimitTransport: HTTPTransport {
    private(set) var calls = 0
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        calls += 1
        return HTTPResponse(statusCode: 429, headers: [:], body: Data())
    }
}

private struct SessionResponseTransport: HTTPTransport {
    let id: UUID
    let revision: UInt64
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let json = """
        {"version":1,"id":"\(id.uuidString)","source_id":"source","account_ids":["alias"],"activity_id":"activity","starts_at":1800000000,"expires_at":1800014400,"status":"active","revision":\(revision),"delivery_state":"pending"}
        """
        return HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
    }
}

private struct StatusTransport: HTTPTransport {
    let status: Int
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: [:], body: Data())
    }
}

private struct AcceptedRefreshTransport: HTTPTransport {
    let id: UUID
    let status: Int
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let json = """
        {"version":1,"id":"\(id.uuidString)","source_id":"source","account_ids":["alias"],"activity_id":"activity","starts_at":1800000000,"expires_at":1800014400,"status":"active","revision":1,"delivery_state":"pending"}
        """
        return HTTPResponse(statusCode: status, headers: [:], body: Data(json.utf8))
    }
}

private actor ScopedForbiddenTransport: HTTPTransport {
    private(set) var calls = 0
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        calls += 1
        return HTTPResponse(statusCode: request.httpMethod == "DELETE" ? 204 : 403, headers: [:], body: Data())
    }
}

private actor CapacityTransport: HTTPTransport {
    let existingID: UUID
    private(set) var calls = 0
    private var stopped = false
    init(existingID: UUID) { self.existingID = existingID }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        calls += 1
        if request.httpMethod == "POST" {
            return HTTPResponse(statusCode: 507, headers: [:], body: Data("capacity exhausted".utf8))
        }
        if request.httpMethod == "DELETE" { stopped = true }
        let status = stopped ? "stopped" : "active"
        let revision = stopped ? 2 : 1
        let json = """
        {"version":1,"id":"\(existingID.uuidString)","source_id":"source","account_ids":["alias"],"activity_id":"activity","starts_at":1800000000,"expires_at":1800014400,"status":"\(status)","revision":\(revision),"delivery_state":"pending"}
        """
        return HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
    }
}

@Suite("Monitoring client")
struct MonitoringClientTests {
    @Test func capacityRejectionDoesNotBlockReadsOrStoppingAnExistingSession() async throws {
        let existingID = UUID()
        let transport = CapacityTransport(existingID: existingID)
        let client = try CPAMonitorClient(baseURL: #require(URL(string: "https://example.test")), token: MonitorBridgeToken("test"), transport: transport)
        let registration = try MonitoringRegistration(id: UUID(), sourceID: "source", accountIDs: ["alias"], duration: .oneHour,
                                                       activityID: "new-activity", pushToken: MonitoringPushToken("abcd"))
        await #expect(throws: MonitoringError.capacityExceeded) { try await client.create(registration) }
        #expect(await client.retryAt == nil)
        let stopped = try await client.stop(id: existingID)
        #expect(stopped?.status == .stopped)
        #expect(try await client.get(id: existingID).status == .stopped)
        #expect(await transport.calls == 3)
    }

    @Test func deniedSourceDoesNotPreventStoppingAnAuthorizedSession() async throws {
        let transport = ScopedForbiddenTransport()
        let client = try CPAMonitorClient(baseURL: #require(URL(string: "https://example.test")), token: MonitorBridgeToken("test"), transport: transport)
        await #expect(throws: MonitoringError.forbidden) { try await client.cachedQuota(sourceID: "not-granted") }
        let stopped = try await client.stop(id: UUID())
        #expect(stopped == nil)
        #expect(await transport.calls == 2)
    }
    @Test func rejectsControlCharactersInEncodedBasePath() throws {
        let url = try #require(URL(string: "https://example.test/prefix%0Apath"))
        #expect(throws: MonitoringError.invalidConfiguration) {
            try CPAMonitorClient(baseURL: url, token: MonitorBridgeToken("test"))
        }
    }

    @Test func pushTokenRejectsOddLengthAndAcceptsMultipleEvenLengths() throws {
        for length in [1, 3, 4095] {
            #expect(throws: MonitoringError.invalidConfiguration) {
                try MonitoringPushToken(String(repeating: "a", count: length))
            }
        }
        for length in [2, 64, 4096] {
            #expect(throws: Never.self) { try MonitoringPushToken(String(repeating: "ab", count: length / 2)) }
        }
        #expect(throws: MonitoringError.invalidConfiguration) {
            try MonitoringPushToken(String(repeating: "ab", count: 2049))
        }
    }

    @Test func pushTokenLengthIsNotFixed() throws {
        #expect(throws: Never.self) { try MonitoringPushToken("ab") }
        #expect(throws: Never.self) { try MonitoringPushToken(String(repeating: "ab", count: 1000)) }
    }

    @Test func acceptedRefreshReturnsCurrentSessionWithoutClaimingCompletion() async throws {
        let id = UUID()
        let client = try CPAMonitorClient(baseURL: #require(URL(string: "https://example.test")), token: MonitorBridgeToken("test"), transport: AcceptedRefreshTransport(id: id, status: 202))
        let result = try await client.refresh(id: id)
        #expect(result.id == id)
        #expect(result.revision == 1)
        #expect(result.deliveryState == .pending)
    }

    @Test func distinguishesMissingSessionFromServiceFailure() async throws {
        let url = try #require(URL(string: "https://example.test"))
        let missing = try CPAMonitorClient(baseURL: url, token: MonitorBridgeToken("test"), transport: StatusTransport(status: 404))
        let unavailable = try CPAMonitorClient(baseURL: url, token: MonitorBridgeToken("test"), transport: StatusTransport(status: 503))
        await #expect(throws: MonitoringError.notFound) { try await missing.get(id: UUID()) }
        await #expect(throws: MonitoringError.serviceUnavailable) { try await unavailable.get(id: UUID()) }
    }

    @Test func rotationRejectsOverflowBeforeSending() async throws {
        let transport = UnauthorizedTransport()
        let client = try CPAMonitorClient(baseURL: #require(URL(string: "https://example.test")), token: MonitorBridgeToken("test"), transport: transport)
        await #expect(throws: MonitoringError.invalidConfiguration) {
            try await client.rotate(id: UUID(), activityID: "activity", token: MonitoringPushToken("abcd"), revision: UInt64.max)
        }
        #expect(await transport.calls == 0)
    }

    @Test func rotationAcceptsNextRevision() async throws {
        let id = UUID()
        let client = try CPAMonitorClient(baseURL: #require(URL(string: "https://example.test")), token: MonitorBridgeToken("test"), transport: SessionResponseTransport(id: id, revision: 2))
        let result = try await client.rotate(id: id, activityID: "activity", token: MonitoringPushToken("abcd"), revision: 1)
        #expect(result.revision == 2)
    }

    @Test func sensitiveDescriptionsAreRedacted() throws {
        let bridge = try MonitorBridgeToken("bridge-secret")
        let push = try MonitoringPushToken("abcdef012345")
        #expect(!String(describing: bridge).contains("bridge-secret"))
        #expect(!String(reflecting: bridge).contains("bridge-secret"))
        #expect(!String(describing: push).contains("abcdef012345"))
        #expect(!String(reflecting: push).contains("abcdef012345"))
        #expect(!String(describing: MonitoringError.network).contains("https://"))
    }

    @Test func rateLimitWithoutHeaderUsesConservativeCooldown() async throws {
        let transport = RateLimitTransport()
        let client = try CPAMonitorClient(baseURL: #require(URL(string: "https://example.test")), token: MonitorBridgeToken("test"), transport: transport, clock: { Date(timeIntervalSince1970: 1800000000) })
        await #expect(throws: MonitoringError.rateLimited) { try await client.get(id: UUID()) }
        await #expect(throws: MonitoringError.rateLimited) { try await client.get(id: UUID()) }
        #expect(await transport.calls == 1)
        #expect(await client.retryAt == Date(timeIntervalSince1970: 1_800_000_060))
    }

    @Test func authorizationFailureBlocksSubsequentRequests() async throws {
        let transport = UnauthorizedTransport()
        let client = try CPAMonitorClient(baseURL: #require(URL(string: "https://example.test")), token: MonitorBridgeToken("test"), transport: transport)
        let id = UUID()
        await #expect(throws: MonitoringError.unauthorized) { try await client.get(id: id) }
        await #expect(throws: MonitoringError.unauthorized) { try await client.get(id: id) }
        #expect(await transport.calls == 1)
    }

    @Test func rejectsRedirect() async throws {
        let client = try CPAMonitorClient(baseURL: #require(URL(string: "https://example.test")), token: MonitorBridgeToken("test"), transport: RedirectTransport())
        await #expect(throws: MonitoringError.redirectRefused) { try await client.get(id: UUID()) }
    }
}
