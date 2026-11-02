import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CPAQuotaKit

private actor CAPUsagePageTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        let json = #"{"generated_at":"2026-10-28T00:00:00Z","range":"custom","price_book_revision":0,"total":1,"offset":0,"limit":100,"items":[{"sequence":42,"time":"2026-10-27T23:45:00Z","provider":"gemini","model":"m","failed":false,"result":"成功","output_tokens":60,"reasoning_tokens":40,"latency_ns":3000000000,"ttft_ns":1000000000,"stream":true}]}"#
        return HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
    }
}

private actor CAPUsageTwoPageTransport: HTTPTransport {
    private(set) var offsets: [Int] = []
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let offset = Int(query.first(where: { $0.name == "offset" })?.value ?? "-1") ?? -1
        offsets.append(offset)
        let items = (offset == 0 ? 1...500 : 501...501).map { "{\"sequence\":\($0),\"failed\":false}" }.joined(separator: ",")
        let json = "{\"generated_at\":\"2026-10-28T00:00:00Z\",\"range\":\"custom\",\"price_book_revision\":0,\"total\":501,\"offset\":\(offset),\"limit\":500,\"items\":[\(items)]}"
        return HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
    }
}

private actor CAPUsageResourceRateLimitTransport: HTTPTransport {
    private(set) var calls = 0
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        calls += 1
        return HTTPResponse(statusCode: 429, headers: [:], body: Data())
    }
}

private actor CAPUsageBoundedPageTransport: HTTPTransport {
    enum Mode: Sendable { case rowLimit, duplicate, changingTotal, byteBudget, oversized }
    let mode: Mode
    private(set) var calls = 0
    private(set) var bytes = 0
    init(_ mode: Mode) { self.mode = mode }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        calls += 1
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let offset = Int(query.first { $0.name == "offset" }?.value ?? "0") ?? 0
        let start = mode == .duplicate ? 0 : offset
        let items = (1...500).map { "{\"sequence\":\(start + $0),\"failed\":false}" }.joined(separator: ",")
        let total = mode == .changingTotal && calls > 1 ? 6001 : 6000
        let padding = mode == .byteBudget ? 2_500_000 : mode == .oversized ? 4_194_305 : 0
        let json = "{\"total\":\(total),\"offset\":\(offset),\"limit\":500,\"items\":[\(items)]}" + String(repeating: " ", count: padding)
        let body = Data(json.utf8)
        bytes += body.count
        return HTTPResponse(statusCode: 200, headers: [:], body: body)
    }
}

@Suite("CAP resource requests")
struct CAPUsageResourceTests {
    @Test func automaticCollectionStopsAtTenPagesAndFiveThousandRows() async throws {
        let transport = CAPUsageBoundedPageTransport(.rowLimit)
        let client = CAPUsageClient(server: try CPAServer(baseURL: "https://example.com"), managementKey: try ManagementKey("fixture"), transport: transport)
        let result = try await client.loadWindowRequests(window: CAPUsageWindow(now: Date()), access: .anonymous)
        #expect(result.items.count == 5000)
        #expect(result.completeness == .truncated)
        #expect(await transport.calls == 10)
    }

    @Test(arguments: [CAPUsageBoundedPageTransport.Mode.duplicate, .changingTotal])
    fileprivate func paginationChangesNeverClaimCompleteness(mode: CAPUsageBoundedPageTransport.Mode) async throws {
        let transport = CAPUsageBoundedPageTransport(mode)
        let client = CAPUsageClient(server: try CPAServer(baseURL: "https://example.com"), managementKey: try ManagementKey("fixture"), transport: transport)
        let result = try await client.loadWindowRequests(window: CAPUsageWindow(now: Date()), access: .anonymous)
        #expect(result.completeness == .truncated)
        #expect(await transport.calls == 2)
        if mode == .duplicate { #expect(result.items.count == 500) }
    }

    @Test func cumulativeBudgetReservesRoomBeforeAnotherUnknownSizePage() async throws {
        let transport = CAPUsageBoundedPageTransport(.byteBudget)
        let client = CAPUsageClient(server: try CPAServer(baseURL: "https://example.com"), managementKey: try ManagementKey("fixture"), transport: transport)
        let result = try await client.loadWindowRequests(window: CAPUsageWindow(now: Date()), access: .anonymous)
        #expect(result.completeness == .truncated)
        #expect(await transport.calls == 2)
        #expect(await transport.bytes <= 8_388_608)
    }

    @Test func oversizedIndividualResponseIsRejected() async throws {
        let client = CAPUsageClient(server: try CPAServer(baseURL: "https://example.com"), managementKey: try ManagementKey("fixture"), transport: CAPUsageBoundedPageTransport(.oversized))
        await #expect(throws: CAPUsageError.invalidResponse) {
            try await client.loadWindowRequests(window: CAPUsageWindow(now: Date()), access: .anonymous)
        }
    }
    @Test func anonymousRateLimitIsVisibleAndCannotBeBypassedByAnotherResource() async throws {
        let transport = CAPUsageResourceRateLimitTransport()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let client = CAPUsageClient(server: try CPAServer(baseURL: "https://example.com"),
                                    managementKey: try ManagementKey("fixture"), transport: transport, clock: { now })
        let expected = CAPUsageError.resourceRejected(statusCode: 429, retryAt: now.addingTimeInterval(60))
        await #expect(throws: expected) {
            try await client.loadRequestPage(window: CAPUsageWindow(now: now), offset: 0, limit: 100, access: .anonymous)
        }
        await #expect(throws: expected) {
            try await client.loadCosts(window: CAPUsageWindow(now: now), access: .anonymous)
        }
        #expect(await transport.calls == 1)
    }
    @Test func boundedPaginationKeepsOneWindowAndMarksOffsetUnverified() async throws {
        let transport = CAPUsageTwoPageTransport()
        let client = CAPUsageClient(server: try CPAServer(baseURL: "https://example.com"),
                                    managementKey: try ManagementKey("fixture"), transport: transport)
        let result = try await client.loadWindowRequests(window: CAPUsageWindow(now: Date()), access: .anonymous)
        #expect(result.items.count == 501)
        #expect(result.completeness == .offsetUnverified)
        #expect(await transport.offsets == [0, 500])
    }

    @Test func explicitAnonymousAccessReadsRequestPage() async throws {
        let transport = CAPUsagePageTransport()
        let client = CAPUsageClient(server: try CPAServer(baseURL: "https://example.com/prefix"),
                                    managementKey: try ManagementKey("fixture"), transport: transport)
        let page = try await client.loadRequestPage(window: CAPUsageWindow(now: Date(timeIntervalSince1970: 1_800_000_059)), offset: 0, limit: 100, access: .anonymous)
        #expect(page.items.first?.sequence == 42)
        let request = try #require(await transport.requests.first)
        #expect(request.url?.path == "/prefix/v0/resource/plugins/cap-token-usage-tracker/requests")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let query = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "offset", value: "0")))
        #expect(query.contains(URLQueryItem(name: "limit", value: "100")))
    }
}
