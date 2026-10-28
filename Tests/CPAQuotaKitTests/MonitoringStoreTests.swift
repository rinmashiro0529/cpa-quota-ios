import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CPAQuotaKit

private actor FailureTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse { throw URLError(.cannotConnectToHost) }
}

private actor LateRegistrationTransport: HTTPTransport {
    let id: UUID
    private var response: CheckedContinuation<HTTPResponse, any Error>?
    private var entered: CheckedContinuation<Void, Never>?
    private var hasEntered = false
    init(id: UUID) { self.id = id }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        if request.httpMethod == "DELETE" { return HTTPResponse(statusCode: 204, headers: [:], body: Data()) }
        hasEntered = true
        entered?.resume(); entered = nil
        return try await withCheckedThrowingContinuation { response = $0 }
    }
    func waitForPost() async {
        if hasEntered { return }
        await withCheckedContinuation { entered = $0 }
    }
    func releasePost() {
        let json = """
        {"version":1,"id":"\(id.uuidString)","source_id":"source","account_ids":["alias"],"activity_id":"activity","starts_at":1800000000,"expires_at":1800014400,"status":"active","revision":1,"delivery_state":"pending"}
        """
        response?.resume(returning: HTTPResponse(statusCode: 201, headers: [:], body: Data(json.utf8)))
        response = nil
    }
}

private actor QueueTransport: HTTPTransport {
    var responses: [HTTPResponse]
    init(_ responses: [HTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        guard !responses.isEmpty else { throw URLError(.cannotConnectToHost) }
        return responses.removeFirst()
    }
}

private func sessionResponse(_ id: UUID, status: String = "active", revision: Int = 1) -> HTTPResponse {
    let json = """
    {"version":1,"id":"\(id.uuidString)","source_id":"source","account_ids":["alias"],"activity_id":"activity","starts_at":1800000000,"expires_at":1800014400,"status":"\(status)","revision":\(revision),"delivery_state":"pending"}
    """
    return HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
}

@Suite("Monitoring store")
@MainActor
struct MonitoringStoreTests {
    private func registration(_ id: UUID) throws -> MonitoringRegistration {
        try MonitoringRegistration(id: id, sourceID: "source", accountIDs: ["alias"], duration: .fourHours, activityID: "activity", pushToken: MonitoringPushToken("abcd"))
    }

    @Test func detachedSessionCanBeReconciledStoppedAndRemoved() async throws {
        let id = UUID()
        let transport = QueueTransport([sessionResponse(id), sessionResponse(id), sessionResponse(id, status: "stopped")])
        let client = try CPAMonitorClient(baseURL: #require(URL(string: "https://a.example.test")), token: MonitorBridgeToken("test"), transport: transport)
        let other = try CPAMonitorClient(baseURL: #require(URL(string: "https://b.example.test")), token: MonitorBridgeToken("test"), transport: FailureTransport())
        let store = MonitoringStore(client: client)
        await store.start(try registration(id))
        store.replaceClient(other)
        let handle = try #require(store.detachedSessions.first?.handle)
        #expect(try await store.loadDetached(handle: handle).id == id)
        #expect(try await store.stopDetached(handle: handle)?.status == .stopped)
        try store.removeDetached(handle: handle)
        #expect(store.detachedSessions.isEmpty)
    }

    @Test func stoppedSessionCanStartNewIdentity() async throws {
        let first = UUID(), second = UUID()
        let transport = QueueTransport([sessionResponse(first), sessionResponse(first, status: "stopped"), sessionResponse(second)])
        let client = try CPAMonitorClient(baseURL: #require(URL(string: "https://example.test")), token: MonitorBridgeToken("test"), transport: transport)
        let store = MonitoringStore(client: client)
        await store.start(try registration(first))
        await store.stop()
        await store.start(try registration(second))
        #expect(store.sessionID == second)
        #expect(store.session?.id == second)
        #expect(store.detachedSessions.map(\.id) == [first])
        #expect(store.state == .available)
    }

    @Test func failedRetryKeepsKnownSessionAndDifferentLoadDoesNotMisbind() async throws {
        let first = UUID(), second = UUID()
        let transport = QueueTransport([sessionResponse(first)])
        let client = try CPAMonitorClient(baseURL: #require(URL(string: "https://example.test")), token: MonitorBridgeToken("test"), transport: transport)
        let store = MonitoringStore(client: client)
        await store.start(try registration(first))
        await store.start(try registration(first))
        #expect(store.session?.id == first)
        #expect(store.state == .uncertain)
        await store.load(id: second)
        #expect(store.sessionID == second)
        #expect(store.session == nil)
        #expect(store.detachedSessions.map(\.id) == [first])
    }

    @Test func olderSnapshotSequenceDoesNotReplaceKnownSession() async throws {
        let id = UUID()
        func response(sequence: Int) -> HTTPResponse {
            let base = String(decoding: sessionResponse(id, revision: 3).body, as: UTF8.self)
            let snapshot = """
            "delivery_state":"pending","snapshot":{"version":1,"sequence":\(sequence),"phase":"ready","generated_at":1800000001,"expires_at":1800000900,"accounts":[{"id":"safe","label":"Safe","provider":"codex","window_id":"primary","window_label":"Week","status":"ok"}]}}
            """
            let data = Data(base.replacingOccurrences(of: "\"delivery_state\":\"pending\"}", with: snapshot).utf8)
            return HTTPResponse(statusCode: 200, headers: [:], body: data)
        }
        let transport = QueueTransport([response(sequence: 3), response(sequence: 2)])
        let client = try CPAMonitorClient(baseURL: #require(URL(string: "https://example.test")), token: MonitorBridgeToken("test"), transport: transport)
        let store = MonitoringStore(client: client)
        await store.start(try registration(id))
        await store.refresh()
        #expect(store.session?.snapshot?.sequence == 3)
        #expect(store.error == .invalidResponse)
    }

    @Test func snapshotUpdateDoesNotRequireSessionRevisionChange() async throws {
        let id = UUID()
        func response(sequence: Int, revision: Int) -> HTTPResponse {
            let base = String(decoding: sessionResponse(id, revision: revision).body, as: UTF8.self)
            let snapshot = """
            "delivery_state":"pending","snapshot":{"version":1,"sequence":\(sequence),"phase":"ready","generated_at":1800000001,"expires_at":1800000900,"accounts":[{"id":"safe","label":"Safe · 1","provider":"codex","window_id":"primary","window_label":"5-hour limit","unit":"credits % / requests","status":"ok"}]}}
            """
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(base.replacingOccurrences(of: "\"delivery_state\":\"pending\"}", with: snapshot).utf8))
        }
        let transport = QueueTransport([response(sequence: 1, revision: 1), response(sequence: 2, revision: 1)])
        let client = try CPAMonitorClient(baseURL: #require(URL(string: "https://example.test")), token: MonitorBridgeToken("test"), transport: transport)
        let store = MonitoringStore(client: client)
        await store.start(try registration(id))
        await store.refresh()
        #expect(store.session?.revision == 1)
        #expect(store.session?.snapshot?.sequence == 2)
        #expect(store.session?.snapshot?.accounts[0].unit == "credits % / requests")
    }

    @Test func olderRevisionDoesNotReplaceKnownSession() async throws {
        let id = UUID()
        let transport = QueueTransport([sessionResponse(id, revision: 3), sessionResponse(id, revision: 2)])
        let client = try CPAMonitorClient(baseURL: #require(URL(string: "https://example.test")), token: MonitorBridgeToken("test"), transport: transport)
        let store = MonitoringStore(client: client)
        await store.start(try registration(id))
        await store.refresh()
        #expect(store.session?.revision == 3)
        #expect(store.state == .uncertain)
        #expect(store.error == .invalidResponse)
    }

    @Test func switchRetainsOldIdentityAndIgnoresLateResponse() async throws {
        let id = UUID()
        let transport = LateRegistrationTransport(id: id)
        let client = try CPAMonitorClient(baseURL: #require(URL(string: "https://a.example.test")), token: MonitorBridgeToken("test"), transport: transport)
        let other = try CPAMonitorClient(baseURL: #require(URL(string: "https://b.example.test")), token: MonitorBridgeToken("test"), transport: FailureTransport())
        let store = MonitoringStore(client: client)
        let registration = try MonitoringRegistration(id: id, sourceID: "source", accountIDs: ["alias"], duration: .fourHours, activityID: "activity", pushToken: MonitoringPushToken("abcd"))
        let start = Task { await store.start(registration) }
        await transport.waitForPost()
        store.replaceClient(other)
        await transport.releasePost()
        await start.value
        #expect(store.sessionID == nil)
        #expect(store.state == .idle)
        #expect(store.detachedSessions.map(\.id) == [id])
    }

    @Test func lateCreateResponseCannotOverwriteStopIntent() async throws {
        let id = UUID()
        let transport = LateRegistrationTransport(id: id)
        let client = try CPAMonitorClient(baseURL: #require(URL(string: "https://example.test")), token: MonitorBridgeToken("test"), transport: transport)
        let store = MonitoringStore(client: client)
        let registration = try MonitoringRegistration(id: id, sourceID: "source", accountIDs: ["alias"], duration: .fourHours, activityID: "activity", pushToken: MonitoringPushToken("abcd"))
        let start = Task { await store.start(registration) }
        await transport.waitForPost()
        await store.cancelPending()
        #expect(store.state == .stopIntentRecorded)
        await transport.releasePost()
        await start.value
        #expect(store.state == .stopIntentRecorded)
        #expect(store.sessionID == id)
        #expect(store.session == nil)
    }

    @Test func failedRegistrationAndStopKeepTheSessionIDAndUncertainState() async throws {
        let client = try CPAMonitorClient(baseURL: #require(URL(string: "https://example.test")), token: MonitorBridgeToken("test"), transport: FailureTransport())
        let store = MonitoringStore(client: client)
        let id = UUID()
        let registration = try MonitoringRegistration(id: id, sourceID: "source", accountIDs: ["alias"], duration: .fourHours, activityID: "activity", pushToken: MonitoringPushToken("abcd"))
        await store.start(registration)
        #expect(store.sessionID == id)
        #expect(store.state == .uncertain)
        await store.stop()
        #expect(store.sessionID == id)
        #expect(store.state == .uncertain)
        #expect(store.error == .network)
    }
}
