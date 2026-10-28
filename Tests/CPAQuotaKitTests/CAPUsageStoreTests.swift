import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CPAQuotaKit

private actor CAPUsageChangingTransport: HTTPTransport {
    private var calls = 0
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        calls += 1
        if calls > 1 { return HTTPResponse(statusCode: 500, headers: [:], body: Data()) }
        let json = #"{"generated_at":"2026-10-28T00:00:00Z","range":"custom","price_book_revision":0,"total":1,"offset":0,"limit":500,"items":[{"sequence":42,"model":"m","provider":"openai","failed":false,"output_tokens":100,"reasoning_tokens":0,"latency_ns":3000000000,"ttft_ns":1000000000}]}"#
        return HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
    }
}

private actor CAPUsageSupersededTransport: HTTPTransport {
    private(set) var calls = 0
    private var first: CheckedContinuation<HTTPResponse, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        calls += 1
        if calls == 1 {
            return await withCheckedContinuation { continuation in
                first = continuation
                waiter?.resume()
                waiter = nil
            }
        }
        let json = #"{"total":0,"offset":0,"limit":500,"items":[]}"#
        return HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
    }
    func waitForFirstRequest() async {
        if first != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func releaseFirstPage() {
        let items = (1...500).map { "{\"sequence\":\($0),\"failed\":false}" }.joined(separator: ",")
        let json = "{\"total\":1000,\"offset\":0,\"limit\":500,\"items\":[\(items)]}"
        first?.resume(returning: HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8)))
        first = nil
    }
}

@Suite("CAP observable store")
struct CAPUsageStoreTests {
    @Test @MainActor func supersedingRefreshCancelsOldPaginationAndKeepsNewWindow() async throws {
        let transport = CAPUsageSupersededTransport()
        let client = CAPUsageClient(server: try CPAServer(baseURL: "https://example.com"),
                                    managementKey: try ManagementKey("fixture"), transport: transport)
        let store = CAPUsageStore(client: client, access: .anonymous)
        let oldWindow = CAPUsageWindow(now: Date(timeIntervalSince1970: 1_800_000_000))
        let newWindow = CAPUsageWindow(now: Date(timeIntervalSince1970: 1_800_000_600))
        let old = Task { await store.refresh(window: oldWindow) }
        await transport.waitForFirstRequest()
        await store.refresh(window: newWindow)
        await transport.releaseFirstPage()
        await old.value
        #expect(store.snapshot?.window == newWindow)
        #expect(store.error == nil)
        #expect(!store.isRefreshing)
        #expect(await transport.calls == 2)
    }
    @Test @MainActor func failurePreservesLastSuccessfulSnapshot() async throws {
        let client = CAPUsageClient(server: try CPAServer(baseURL: "https://example.com"),
                                    managementKey: try ManagementKey("fixture"), transport: CAPUsageChangingTransport())
        let store = CAPUsageStore(client: client, access: .anonymous)
        let first = CAPUsageWindow(now: Date(timeIntervalSince1970: 1_800_000_000))
        await store.refresh(window: first)
        #expect(store.snapshot?.window == first)
        #expect(store.snapshot?.models.first?.summary.generationTPS == 50)
        let second = CAPUsageWindow(now: Date(timeIntervalSince1970: 1_800_000_600))
        await store.refresh(window: second)
        #expect(store.snapshot?.window == first)
        #expect(store.error != nil)
    }
}
