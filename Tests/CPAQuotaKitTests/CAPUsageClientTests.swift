import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CPAQuotaKit

private struct CAPUsageNotFoundTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        HTTPResponse(statusCode: 404, headers: [:], body: Data())
    }
}

private struct CAPUsageStatsTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let body = Data(#"{"schema_version":1,"generated_at":"2026-10-28T00:00:00Z","range":"custom","summary":{"requests":3,"output_tokens":200},"groups":[],"series":[],"model_series":[],"sources":[]}"#.utf8)
        return HTTPResponse(statusCode: 200, headers: [:], body: body)
    }
}

private actor CAPUsageRecordingTransport: HTTPTransport {
    private(set) var request: URLRequest?
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        self.request = request
        return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"summary":{}}"#.utf8))
    }
}

private struct CAPUsageFailingTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        throw NSError(domain: "fixture-secret", code: 1)
    }
}

private actor CAPUsageCancellationTransport: HTTPTransport {
    private var response: CheckedContinuation<HTTPResponse, Never>?
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        await withCheckedContinuation { continuation in
            response = continuation
            entered = true
            waiter?.resume()
            waiter = nil
        }
    }
    func waitForRequest() async {
        if entered { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release(resource: Bool) {
        let json = resource ? #"{"total":0,"offset":0,"limit":100,"items":[]}"# : #"{"summary":{}}"#
        response?.resume(returning: HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8)))
        response = nil
    }
}

@Suite("CAP usage client")
struct CAPUsageClientTests {
    @Test(arguments: [false, true]) func cancelledReadRejectsTransportThatIgnoresCancellation(resource: Bool) async throws {
        let transport = CAPUsageCancellationTransport()
        let client = CAPUsageClient(server: try CPAServer(baseURL: "https://example.com"),
                                    managementKey: try ManagementKey("fixture"), transport: transport)
        let task = Task {
            let window = CAPUsageWindow(now: Date())
            if resource {
                _ = try await client.loadRequestPage(window: window, offset: 0, limit: 100, access: .anonymous)
            } else {
                _ = try await client.loadManagementStats(window: window)
            }
        }
        await transport.waitForRequest()
        task.cancel()
        await transport.release(resource: resource)
        do {
            try await task.value
            Issue.record("A cancelled request must not return a late success")
        } catch is CancellationError {
        }
    }
    @Test func networkErrorsDoNotExposeUnderlyingDetails() async throws {
        let client = CAPUsageClient(server: try CPAServer(baseURL: "https://example.com"),
                                    managementKey: try ManagementKey("fixture"),
                                    transport: CAPUsageFailingTransport())
        await #expect(throws: CAPUsageError.network) {
            try await client.loadManagementStats(window: CAPUsageWindow(now: Date()))
        }
    }

    @Test func managementRequestUsesFixedWindowAndBearer() async throws {
        let transport = CAPUsageRecordingTransport()
        let client = CAPUsageClient(server: try CPAServer(baseURL: "https://example.com/proxy"),
                                    managementKey: try ManagementKey("fixture"), transport: transport)
        let window = CAPUsageWindow(now: Date(timeIntervalSince1970: 1_800_000_059))
        _ = try await client.loadManagementStats(window: window)
        let request = try #require(await transport.request)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/proxy/v0/management/plugins/cap-token-usage-tracker/stats")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
        let query = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "range", value: "custom")))
        #expect(query.contains(URLQueryItem(name: "start", value: "2027-01-15T07:30:00Z")))
        #expect(query.contains(URLQueryItem(name: "end", value: "2027-01-15T08:00:00Z")))
    }

    @Test func readsTypedManagementSummary() async throws {
        let client = CAPUsageClient(server: try CPAServer(baseURL: "https://example.com"),
                                    managementKey: try ManagementKey("fixture"),
                                    transport: CAPUsageStatsTransport())
        let stats = try await client.loadManagementStats(window: CAPUsageWindow(now: Date()))
        #expect(stats.summary.requests == 3)
        #expect(stats.summary.outputTokens == 200)
    }

    @Test func missingPluginIsAnErrorNotAnEmptyResult() async throws {
        let client = CAPUsageClient(server: try CPAServer(baseURL: "https://example.com"),
                                    managementKey: try ManagementKey("fixture"),
                                    transport: CAPUsageNotFoundTransport())
        await #expect(throws: CAPUsageError.pluginUnavailable) {
            try await client.loadManagementStats(window: CAPUsageWindow(now: Date()))
        }
    }
}
