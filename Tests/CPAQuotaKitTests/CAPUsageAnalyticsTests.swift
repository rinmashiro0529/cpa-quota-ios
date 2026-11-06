import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CPAQuotaKit
@testable import CPAQuotaUI

private actor CAPUsageAnalyticsTransport: HTTPTransport {
    private var failing = false
    private var paths: [String] = []
    private var captured: [URLRequest] = []
    private var failures: [CAPUsageDetailResource: Int] = [:]
    private var timeout: CAPUsageDetailResource?
    private var generation = "2026-10-28T00:00:00Z"
    private let gate: TestGate?
    init(gate: TestGate? = nil) { self.gate = gate }
    func fail() { failing = true }
    func fail(_ resource: CAPUsageDetailResource, status: Int?) { failures[resource] = status }
    func timeOut(_ resource: CAPUsageDetailResource?) { timeout = resource }
    func useGeneration(_ value: String) { generation = value }
    func requests() -> [String] { paths }
    func capturedRequests() -> [URLRequest] { captured }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let path = request.url?.path ?? ""
        paths.append(path)
        captured.append(request)
        let resource = CAPUsageDetailResource.allCases.first { path.hasSuffix($0.testPath) }
        if resource == .costs, let gate { await gate.enter() }
        if let resource, resource == timeout { throw URLError(.timedOut) }
        if let resource, let status = failures[resource] {
            return HTTPResponse(statusCode: status, headers: ["Retry-After": "120"], body: Data())
        }
        if failing { return HTTPResponse(statusCode: 503, headers: [:], body: Data()) }
        let body: String
        if path.hasSuffix("/stats/initial") {
            body = #"{"schema_version":2,"generated_at":"2026-10-28T00:00:00Z","range":"custom","retained_since":"2026-10-01T00:00:00Z","last_used":"2026-10-27T23:59:00Z","bucket_seconds":300,"summary":{"requests":1,"input_tokens":25,"reasoning_tokens":40,"failed_requests":0},"models":[{"model":"m","requests":1,"output_tokens":12}],"series":[],"sources":[]}"#
        } else if path.hasSuffix("/stats/trends") {
            body = #"{"schema_version":2,"generated_at":"2026-10-28T00:00:00Z","range":"custom","bucket_seconds":300,"model_series":[{"hour":"2026-10-27T23:55:00Z","model":"m","output_tokens":12}]}"#
        } else if path.hasSuffix("/costs") {
            body = #"{"schema_version":1,"generated_at":"2026-10-28T00:00:00Z","range":"custom","currency":"USD","estimate_basis":"current_price_book","price_book_revision":1,"summary":{"requests":1,"priced_requests":1,"unpriced_requests":0,"total_usd":0.25},"models":[],"series":[],"missing_prices":[]}"#
        } else {
            body = #"{"schema_version":2,"generated_at":"2026-10-28T00:00:00Z","range":"custom","total":1,"items":[{"provider":"openai","model":"m","requests":1,"output_tokens":12}]}"#
        }
        return HTTPResponse(statusCode: 200, headers: [:],
            body: Data(body.replacingOccurrences(of: "2026-10-28T00:00:00Z", with: generation).utf8))
    }
}

private extension CAPUsageDetailResource {
    var testPath: String {
        switch self {
        case .initial: "/stats/initial"
        case .trends: "/stats/trends"
        case .groups: "/stats/groups"
        case .costs: "/costs"
        }
    }
}

@Suite("CAP analytics resources")
struct CAPUsageAnalyticsTests {
    @Test @MainActor func detailRefreshPublishesOneWindowAndPreservesItOnFailure() async throws {
        let transport = CAPUsageAnalyticsTransport()
        let client = CAPUsageClient(server: try CPAServer(baseURL: "https://example.com"),
                                    managementKey: try ManagementKey("fixture"), transport: transport)
        let store = CAPUsageStore(client: client, access: .anonymous)
        let window = CAPUsageWindow(now: Date(timeIntervalSince1970: 1_800_000_000))
        await store.refreshDetails(window: window)
        #expect(store.details?.initial.summary.inputTokens == 25)
        #expect(store.details?.initial.summary.outputTokens == nil)
        #expect(store.details?.costs.summary.totalUsd == 0.25)
        #expect(store.details?.groups.total == 1)
        #expect(store.details?.groupLimit == 100)
        #expect(store.details?.window == window)
        #expect(!store.isLoadingDetails)
        await transport.fail()
        await store.refreshDetails(window: CAPUsageWindow(now: Date(timeIntervalSince1970: 1_800_000_600)))
        #expect(store.details?.window == window)
        #expect(store.detailsError != nil)
    }
    @Test @MainActor func groupPageReadsOnlyGroupsAndPreservesOtherResponseTimes() async throws {
        let transport = CAPUsageAnalyticsTransport()
        let client = CAPUsageClient(server: try CPAServer(baseURL: "https://example.com"),
                                    managementKey: try ManagementKey("fixture"), transport: transport)
        let store = CAPUsageStore(client: client, access: .anonymous)
        let window = CAPUsageWindow(now: Date(timeIntervalSince1970: 1_800_000_000))
        await store.refreshDetails(window: window)
        let original = try #require(store.details)
        let before = await transport.requests()
        await store.refreshGroupPage(window: window, groupOffset: 100, groupLimit: 100)
        let after = await transport.requests()
        let page = try #require(store.details)
        #expect(after.count == before.count + 1)
        #expect(after.last?.hasSuffix("/stats/groups") == true)
        #expect(page.window == window)
        #expect(page.groupOffset == 100)
        #expect(page.initial.generatedAt == original.initial.generatedAt)
        #expect(page.trends.generatedAt == original.trends.generatedAt)
        #expect(page.costs.generatedAt == original.costs.generatedAt)
        #expect(page.initial.summary.inputTokens == 25)
        await transport.fail()
        await store.refreshGroupPage(window: window, groupOffset: 200, groupLimit: 100)
        #expect(store.details?.groupOffset == 100)
        #expect(store.detailsError != nil)
    }

    @Test func readsInitialTrendAndGroups() async throws {
        let client = CAPUsageClient(server: try CPAServer(baseURL: "https://example.com"),
                                    managementKey: try ManagementKey("fixture"), transport: CAPUsageAnalyticsTransport())
        let window = CAPUsageWindow(now: Date())
        let initial = try await client.loadInitialStats(window: window, access: .anonymous)
        let trends = try await client.loadTrends(window: window, access: .anonymous)
        let groups = try await client.loadGroups(window: window, offset: 0, limit: 100, access: .anonymous)
        #expect(initial.models.first?.counters.outputTokens == 12)
        #expect(trends.modelSeries.first?.hour == "2026-10-27T23:55:00Z")
        #expect(groups.items.first?.provider == "openai")
    }
}

@Suite("CAP independent resource recovery")
@MainActor
struct CAPPartialResourceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeClient(_ transport: CAPUsageAnalyticsTransport) throws -> CAPUsageClient {
        let now = now
        return CAPUsageClient(server: try CPAServer(baseURL: "https://example.test/prefix"),
            managementKey: try ManagementKey("synthetic-key"), transport: transport, clock: { now })
    }

    private func hasSnapshot(_ resource: CAPUsageDetailResource, in store: CAPUsageStore) -> Bool {
        switch resource {
        case .initial: store.initialState.snapshot != nil
        case .trends: store.trendsState.snapshot != nil
        case .groups: store.groupsState.snapshot != nil
        case .costs: store.costsState.snapshot != nil
        }
    }

    @Test func changingRangeKeepsPublishedWindowsAndRetryUsesTheFailedQuery() async throws {
        let transport = CAPUsageAnalyticsTransport()
        let current = now
        let coordinator = CAPUsageWorkspaceCoordinator(clock: { current })
        coordinator.bind(client: try makeClient(transport))
        await coordinator.refreshDetails()
        let original = try #require(coordinator.costsPresentation)
        await transport.fail(.costs, status: 503)
        coordinator.selectRange(.last24Hours)
        #expect(await transport.requests().count == 4)
        await coordinator.refreshDetails()
        let failedWindow = CAPUsageWindow(now: now, range: .last24Hours)
        #expect(coordinator.initialPresentation?.snapshot.window == failedWindow)
        #expect(coordinator.costsPresentation?.snapshot.window == original.snapshot.window)
        coordinator.selectRange(.last7Days)
        let before = await transport.requests().count
        await transport.fail(.costs, status: nil)
        await coordinator.retryDetailResource(.costs)
        let requests = await transport.capturedRequests()
        #expect(requests.count == before + 1)
        #expect(requests.last?.url?.path.hasSuffix("/costs") == true)
        #expect(coordinator.costsPresentation?.snapshot.window == failedWindow)
        #expect(coordinator.activeWindow == CAPUsageWindow(now: now, range: .last7Days))
        let query = try #require(URLComponents(url: try #require(requests.last?.url), resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.first { $0.name == "start" }?.value == ISO8601DateFormatter().string(from: failedWindow.start))
    }

    @Test func selectingRangeCancelsLateResourceWithoutDiscardingPublishedSuccesses() async throws {
        let gate = TestGate()
        let transport = CAPUsageAnalyticsTransport(gate: gate)
        let current = now
        let coordinator = CAPUsageWorkspaceCoordinator(clock: { current })
        coordinator.bind(client: try makeClient(transport))
        let reading = Task { await coordinator.refreshDetails() }
        await gate.waitForArrivals()
        #expect(coordinator.initialPresentation != nil)
        coordinator.selectRange(.last7Days)
        #expect(coordinator.store?.isLoadingDetails == false)
        await gate.open()
        await reading.value
        #expect(coordinator.initialPresentation?.snapshot.window == CAPUsageWindow(now: now))
        #expect(coordinator.costsPresentation == nil)
        #expect(coordinator.store?.costsState.error == nil)
        #expect(await transport.requests().count == 4)
    }

    @Test(arguments: CAPUsageDetailResource.allCases, [401, 403, 404, 503])
    func firstReadKeepsSuccessfulRegionsAndRetryReadsOnlyFailure(_ resource: CAPUsageDetailResource, status: Int) async throws {
        let transport = CAPUsageAnalyticsTransport()
        await transport.fail(resource, status: status)
        let store = CAPUsageStore(client: try makeClient(transport), access: .anonymous)
        let window = CAPUsageWindow(now: now)
        await store.refreshDetails(window: window)
        #expect(store.failedDetailResources == [resource])
        for other in CAPUsageDetailResource.allCases {
            #expect(hasSnapshot(other, in: store) == (other != resource))
        }
        #expect(!store.isLoadingDetails)
        #expect(store.details == nil)
        let before = await transport.requests().count
        await transport.fail(resource, status: nil)
        await store.retryDetailResource(resource)
        let requests = await transport.capturedRequests()
        #expect(requests.count == before + 1)
        #expect(requests.last?.url?.path.hasSuffix(resource.testPath) == true)
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        #expect(store.failedDetailResources.isEmpty)
        #expect(store.details?.window == window)
    }

    @Test(arguments: CAPUsageDetailResource.allCases)
    func timeoutDoesNotHideOtherResources(_ resource: CAPUsageDetailResource) async throws {
        let transport = CAPUsageAnalyticsTransport()
        await transport.timeOut(resource)
        let store = CAPUsageStore(client: try makeClient(transport), access: .anonymous)
        await store.refreshDetails(window: CAPUsageWindow(now: now))
        #expect(store.failedDetailResources == [resource])
        #expect(store.detailsError == .network)
        #expect(CAPUsageDetailResource.allCases.filter { hasSnapshot($0, in: store) }.count == 3)
        await transport.timeOut(nil)
        let before = await transport.requests().count
        await store.retryFailedDetails()
        #expect(await transport.requests().count == before + 1)
        #expect(store.failedDetailResources.isEmpty)
    }

    @Test func successPublishesBeforeTheFinalResourceCompletes() async throws {
        let gate = TestGate()
        let transport = CAPUsageAnalyticsTransport(gate: gate)
        let now = now
        let coordinator = CAPUsageWorkspaceCoordinator(clock: { now })
        coordinator.bind(client: try makeClient(transport))
        let task = Task { await coordinator.refreshDetails() }
        await gate.waitForArrivals()
        #expect(coordinator.initialPresentation != nil)
        #expect(coordinator.trendsPresentation != nil)
        #expect(coordinator.groupsPresentation != nil)
        #expect(coordinator.costsPresentation == nil)
        #expect(coordinator.store?.costsState.isLoading == true)
        #expect(coordinator.store?.initialState.isLoading == false)
        await gate.open()
        await task.value
        #expect(coordinator.costsPresentation != nil)
    }

    @Test func failedRefreshKeepsOnlyThatResourcesOriginalWindowAndGeneration() async throws {
        let transport = CAPUsageAnalyticsTransport()
        let store = CAPUsageStore(client: try makeClient(transport), access: .anonymous)
        let oldWindow = CAPUsageWindow(now: now)
        let newWindow = CAPUsageWindow(now: now.addingTimeInterval(600))
        await store.refreshDetails(window: oldWindow)
        await transport.useGeneration("2026-10-28T00:10:00Z")
        await transport.fail(.costs, status: 503)
        await store.refreshDetails(window: newWindow)
        #expect(store.initialState.snapshot?.window == newWindow)
        #expect(store.initialState.snapshot?.value.generatedAt == "2026-10-28T00:10:00Z")
        #expect(!store.initialState.isShowingPreviousResult)
        #expect(store.costsState.snapshot?.window == oldWindow)
        #expect(store.costsState.snapshot?.value.generatedAt == "2026-10-28T00:00:00Z")
        #expect(store.costsState.requestedQuery?.window == newWindow)
        #expect(store.costsState.isShowingPreviousResult)
        #expect(store.details?.window == oldWindow)
        await transport.fail(.costs, status: nil)
        await store.retryFailedDetails()
        #expect(store.costsState.snapshot?.window == newWindow)
        #expect(store.costsState.snapshot?.value.generatedAt == "2026-10-28T00:10:00Z")
        #expect(!store.costsState.isShowingPreviousResult)
        #expect(store.details?.window == newWindow)
    }

    @Test func failedGroupRetryUsesAttemptedOffsetAndPreservesOtherRegions() async throws {
        let transport = CAPUsageAnalyticsTransport()
        let store = CAPUsageStore(client: try makeClient(transport), access: .anonymous)
        let window = CAPUsageWindow(now: now)
        await store.refreshDetails(window: window, groupLimit: 50)
        await transport.fail(.groups, status: 503)
        await store.refreshGroupPage(window: window, groupOffset: 50, groupLimit: 50)
        #expect(store.groupsState.snapshot?.query.groupOffset == 0)
        #expect(store.groupsState.requestedQuery?.groupOffset == 50)
        #expect(store.groupsState.isShowingPreviousResult)
        #expect(!store.initialState.isShowingPreviousResult)
        await transport.fail(.groups, status: nil)
        let before = await transport.requests().count
        await store.retryFailedDetails()
        let requests = await transport.capturedRequests()
        #expect(requests.count == before + 1)
        let last = try #require(requests.last?.url)
        let query = URLComponents(url: last, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.first { $0.name == "offset" }?.value == "50")
        #expect(store.groupsState.snapshot?.query.groupOffset == 50)
        #expect(!store.groupsState.isShowingPreviousResult)
    }

    @Test(arguments: CAPUsageDetailResource.allCases)
    func resourceRateLimitCannotBeBypassedByRegionRetry(_ resource: CAPUsageDetailResource) async throws {
        let transport = CAPUsageAnalyticsTransport()
        await transport.fail(resource, status: 429)
        let store = CAPUsageStore(client: try makeClient(transport), access: .anonymous)
        await store.refreshDetails(window: CAPUsageWindow(now: now))
        #expect(store.detailsError?.retryAt == now.addingTimeInterval(120))
        let before = await transport.requests().count
        await transport.fail(resource, status: nil)
        await store.retryDetailResource(resource)
        await store.retryFailedDetails()
        #expect(await transport.requests().count == before)
        #expect(store.failedDetailResources.contains(resource))
    }

    @Test(arguments: CAPUsageDetailResource.allCases, [401, 403])
    func managementCircuitRemainsClosedForEveryRegion(_ resource: CAPUsageDetailResource, status: Int) async throws {
        let transport = CAPUsageAnalyticsTransport()
        await transport.fail(resource, status: status)
        let store = CAPUsageStore(client: try makeClient(transport), access: .managementKey)
        await store.refreshDetails(window: CAPUsageWindow(now: now))
        let before = await transport.requests().count
        await transport.fail(resource, status: nil)
        await store.retryFailedDetails()
        await store.refreshDetails(window: CAPUsageWindow(now: now.addingTimeInterval(600)))
        let requests = await transport.capturedRequests()
        #expect(requests.count == before)
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-key" })
        #expect(store.detailsError == .management(CPAError(
            status == 401 ? .managementUnauthorized : .managementForbidden, layer: .management, statusCode: status)))
    }
}
