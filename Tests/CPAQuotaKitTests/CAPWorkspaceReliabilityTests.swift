import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Observation
import Testing
@testable import CPAQuotaKit
import CPAQuotaUI

private actor WorkspaceCAPTransport: HTTPTransport {
    private let gatedSuffix: String?
    private let gates: [TestGate]
    private let throwAfterFirstGate: Bool
    private var gatedCalls = 0
    private var captured: [URLRequest] = []
    private var cancelledCalls = 0
    private var failingSuffix: String?

    init(gatedSuffix: String? = nil, gates: [TestGate] = [], throwAfterFirstGate: Bool = false) {
        self.gatedSuffix = gatedSuffix
        self.gates = gates
        self.throwAfterFirstGate = throwAfterFirstGate
    }

    func requests() -> [URLRequest] { captured }
    func cancelledCount() -> Int { cancelledCalls }
    func fail(_ suffix: String?) { failingSuffix = suffix }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        captured.append(request)
        let path = request.url?.path ?? ""
        if let gatedSuffix, path.hasSuffix(gatedSuffix) {
            let index = gatedCalls
            gatedCalls += 1
            if index < gates.count { await gates[index].enter() }
            if index == 0, throwAfterFirstGate { throw CPAError(.network) }
        }
        if Task.isCancelled { cancelledCalls += 1 }
        if let failingSuffix, path.hasSuffix(failingSuffix) {
            return HTTPResponse(statusCode: 503, headers: [:], body: Data())
        }
        if request.url?.host == "c.example.test", path.hasSuffix("/auth-files") {
            return HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
        let body: String
        if path.hasSuffix("/auth-files") {
            body = #"{"files":[]}"#
        } else if path.hasSuffix("/quota/providers") {
            body = #"{"providers":[]}"#
        } else if path.hasSuffix("/requests") {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let offset = query.first { $0.name == "offset" }?.value.flatMap(Int.init) ?? 0
            let limit = query.first { $0.name == "limit" }?.value.flatMap(Int.init) ?? 50
            body = "{\"total\":\(offset),\"offset\":\(offset),\"limit\":\(limit),\"items\":[]}"
        } else if path.hasSuffix("/stats/initial") {
            body = #"{"schema_version":1,"generated_at":"fixture","range":"custom","retained_since":"fixture","last_used":"fixture","bucket_seconds":300,"summary":{"requests":0},"models":[],"series":[],"sources":[]}"#
        } else if path.hasSuffix("/stats/trends") {
            body = #"{"schema_version":1,"generated_at":"fixture","range":"custom","bucket_seconds":300,"model_series":[]}"#
        } else if path.hasSuffix("/stats/groups") {
            body = #"{"schema_version":1,"generated_at":"fixture","range":"custom","total":0,"items":[]}"#
        } else if path.hasSuffix("/costs") {
            body = #"{"schema_version":1,"generated_at":"fixture","range":"custom","currency":"USD","estimate_basis":"list_price","price_book_revision":1,"summary":{"requests":0,"priced_requests":0,"unpriced_requests":0,"total_usd":0},"models":[],"series":[],"missing_prices":[]}"#
        } else if path.hasSuffix("/stats") {
            body = #"{"schema_version":1,"generated_at":"fixture","range":"custom","summary":{"requests":0},"groups":[],"series":[],"model_series":[],"sources":[]}"#
        } else {
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
    }
}

enum WorkspaceOperation: CaseIterable, Equatable, Sendable {
    case overview, details, management, page
    var suffix: String {
        switch self {
        case .overview, .page: "/requests"
        case .details: "/stats/initial"
        case .management: "/stats"
        }
    }
}

@Suite("CAP workspace request ownership and connection identity")
@MainActor
struct CAPWorkspaceReliabilityTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func coordinator(_ transport: WorkspaceCAPTransport) throws -> CAPUsageWorkspaceCoordinator {
        let client = CAPUsageClient(server: try CPAServer(baseURL: "https://a.example.test"),
                                    managementKey: try ManagementKey("synthetic-key"), transport: transport)
        let now = now
        let coordinator = CAPUsageWorkspaceCoordinator(clock: { now })
        coordinator.bind(client: client)
        return coordinator
    }

    private func run(_ operation: WorkspaceOperation, on coordinator: CAPUsageWorkspaceCoordinator) async {
        switch operation {
        case .overview: await coordinator.refreshOverview(now: now)
        case .details: await coordinator.refreshDetails()
        case .management: await coordinator.refreshManagementStats()
        case .page: await coordinator.loadRequestPage()
        }
    }

    private func hasResult(_ operation: WorkspaceOperation, in coordinator: CAPUsageWorkspaceCoordinator) -> Bool {
        switch operation {
        case .overview: coordinator.store?.snapshot != nil
        case .details: coordinator.store?.details != nil
        case .management: coordinator.managementStats != nil
        case .page: coordinator.requestPage != nil
        }
    }

    @Test(arguments: [WorkspaceOperation.overview, .details])
    func oldCompletionCannotRemoveTheReplacementCancellationHandle(_ operation: WorkspaceOperation) async throws {
        let firstGate = TestGate(), secondGate = TestGate()
        let transport = WorkspaceCAPTransport(gatedSuffix: operation.suffix, gates: [firstGate, secondGate])
        let coordinator = try coordinator(transport)
        let first = Task { await run(operation, on: coordinator) }
        await firstGate.waitForArrivals()
        let second = Task { await run(operation, on: coordinator) }
        await secondGate.waitForArrivals()
        await firstGate.open()
        await first.value
        coordinator.cancelAll()
        await secondGate.open()
        await second.value
        #expect(!hasResult(operation, in: coordinator))
        #expect(await transport.cancelledCount() == 2)
    }

    @Test(arguments: [WorkspaceOperation.management, .page], [false, true])
    func oldCancellationCannotFinishTheReplacementLoadingState(_ operation: WorkspaceOperation, lateFailure: Bool) async throws {
        let firstGate = TestGate(), secondGate = TestGate()
        let transport = WorkspaceCAPTransport(gatedSuffix: operation.suffix, gates: [firstGate, secondGate],
                                              throwAfterFirstGate: lateFailure)
        let coordinator = try coordinator(transport)
        let first = Task { await run(operation, on: coordinator) }
        await firstGate.waitForArrivals()
        let second = Task { await run(operation, on: coordinator) }
        await secondGate.waitForArrivals()
        await firstGate.open()
        await first.value
        let remainedLoading = operation == .management ? coordinator.isLoadingManagementStats : coordinator.isLoadingRequestPage
        let previousError = operation == .management ? coordinator.managementStatsError : coordinator.requestPageError
        await secondGate.open()
        await second.value
        #expect(remainedLoading)
        #expect(previousError == nil)
        #expect(hasResult(operation, in: coordinator))
        #expect(coordinator.managementStatsError == nil)
        #expect(coordinator.requestPageError == nil)
    }

    @Test(arguments: WorkspaceOperation.allCases)
    func cancellingOuterTaskCancelsItsOwnRequest(_ operation: WorkspaceOperation) async throws {
        let gate = TestGate()
        let transport = WorkspaceCAPTransport(gatedSuffix: operation.suffix, gates: [gate])
        let coordinator = try coordinator(transport)
        let task = Task { await run(operation, on: coordinator) }
        await gate.waitForArrivals()
        task.cancel()
        await gate.open()
        await task.value
        #expect(!hasResult(operation, in: coordinator))
        #expect(await transport.cancelledCount() == 1)
    }

    @Test(arguments: [false, true])
    func failedCandidateAfterPublicationKeepsCAPBoundToTheAcceptedConnection(restoring: Bool) async throws {
        let transport = WorkspaceCAPTransport()
        let credentials = MemoryCredentialStore()
        let preferences = MemoryPreferencesStore()
        let session = CPAQuotaSession(credentialStore: credentials, preferences: preferences,
                                      clientFactory: { server, key in
            CPAClient(server: server, managementKey: key, transport: transport)
        })
        await session.connect(serverAddress: "https://a.example.test", managementKeyInput: "synthetic-a", rememberInKeychain: false)
        if restoring {
            let server = try CPAServer(baseURL: "https://b.example.test")
            try await credentials.save(ManagementKey("synthetic-b"), for: server)
            preferences.saveServerIdentifier(server.identifier)
        }
        let nextFinished = TestGate()
        withObservationTracking {
            _ = session.currentServer
        } onChange: {
            Task { @MainActor in
                await session.connect(serverAddress: "https://c.example.test", managementKeyInput: "synthetic-c", rememberInKeychain: false)
                await nextFinished.open()
            }
        }
        if restoring {
            await session.restoreSessionIfAvailable()
        } else {
            await session.connect(serverAddress: "https://b.example.test", managementKeyInput: "synthetic-b", rememberInKeychain: false)
        }
        await nextFinished.enter()
        #expect(session.currentServer?.baseURL.host == "b.example.test")
        #expect(session.connectionFormError?.kind == .managementUnauthorized)
        await session.capUsageCoordinator.refreshManagementStats()
        let request = try #require(await transport.requests().last { $0.url?.path.hasSuffix("/stats") == true })
        #expect(request.url?.host == "b.example.test")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-b")
    }

    @Test func datasetsRetainTheirWindowAndPaginationUsesTheDisplayedWindow() async throws {
        let transport = WorkspaceCAPTransport()
        let coordinator = try coordinator(transport)
        let first = CAPUsageWindow(now: now)
        let later = CAPUsageWindow(now: now.addingTimeInterval(600))
        await coordinator.refreshOverview(now: now)
        await coordinator.refreshDetails()
        await coordinator.loadRequestPage(offset: 50, limit: 50)
        await coordinator.refreshManagementStats()
        #expect(coordinator.store?.details?.window == first)
        #expect(coordinator.requestPageWindow == first)
        #expect(coordinator.managementStatsWindow == first)

        await coordinator.refreshOverview(now: later.end)
        #expect(coordinator.store?.snapshot?.window == later)
        #expect(coordinator.store?.details?.window == first)
        #expect(coordinator.requestPageWindow == first)
        #expect(coordinator.managementStatsWindow == first)

        await coordinator.loadRequestPage(window: first, offset: 100, limit: 50)
        await coordinator.refreshDetails(window: first, groupOffset: 100, groupLimit: 100)
        let requests = await transport.requests()
        for suffix in ["/requests", "/stats/groups"] {
            let request = try #require(requests.last { $0.url?.path.hasSuffix(suffix) == true })
            let url = try #require(request.url)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            #expect(query?.first { $0.name == "start" }?.value == ISO8601DateFormatter().string(from: first.start))
            #expect(query?.first { $0.name == "end" }?.value == ISO8601DateFormatter().string(from: first.end))
            #expect(query?.first { $0.name == "offset" }?.value == "100")
        }

        await transport.fail("/requests")
        await coordinator.loadRequestPage(offset: 0, limit: 50)
        #expect(coordinator.requestPageWindow == first)
        #expect(coordinator.requestPage?.offset == 100)
        #expect(coordinator.requestPageError != nil)
        await transport.fail(nil)
        await coordinator.loadRequestPage(offset: 0, limit: 50)
        #expect(coordinator.requestPageWindow == later)
        #expect(coordinator.requestPage?.offset == 0)
        await coordinator.refreshManagementStats()
        #expect(coordinator.managementStatsWindow == later)
    }

    @Test(arguments: WorkspaceOperation.allCases)
    func rebindingCannotPublishThePreviousConnectionsLateResult(_ operation: WorkspaceOperation) async throws {
        let gate = TestGate()
        let oldTransport = WorkspaceCAPTransport(gatedSuffix: operation.suffix, gates: [gate])
        let coordinator = try coordinator(oldTransport)
        let previous = Task { await run(operation, on: coordinator) }
        await gate.waitForArrivals()
        let newTransport = WorkspaceCAPTransport()
        let client = CAPUsageClient(server: try CPAServer(baseURL: "https://b.example.test"),
                                    managementKey: try ManagementKey("synthetic-b"), transport: newTransport)
        coordinator.bind(client: client)
        await run(operation, on: coordinator)
        await gate.open()
        await previous.value
        #expect(coordinator.client === client)
        #expect(hasResult(operation, in: coordinator))
        #expect(coordinator.managementStatsError == nil)
        #expect(coordinator.requestPageError == nil)
        #expect(await oldTransport.cancelledCount() == 1)
    }

    @Test func unknownOutcomesAndPriceCoverageRemainUnknown() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let unknown = try decoder.decode(CAPUsageRequest.self, from: Data("{}".utf8))
        let success = try decoder.decode(CAPUsageRequest.self, from: Data(#"{"failed":false}"#.utf8))
        let failed = try decoder.decode(CAPUsageRequest.self, from: Data(#"{"failed":true,"failure_status":503}"#.utf8))
        #expect(CAPUsagePresentation.requestOutcomeText(unknown) == "结果未知")
        #expect(CAPUsagePresentation.requestOutcomeText(success) == "成功")
        #expect(CAPUsagePresentation.requestOutcomeText(failed).contains("503"))
        for summary in [#"{}"#, #"{"requests":2,"priced_requests":1,"unpriced_requests":0}"#] {
            let body = "{\"schema_version\":1,\"generated_at\":\"fixture\",\"range\":\"custom\",\"currency\":\"USD\",\"estimate_basis\":\"list_price\",\"price_book_revision\":1,\"summary\":\(summary),\"models\":[],\"series\":[],\"missing_prices\":[]}"
            let costs = try decoder.decode(CAPUsageCosts.self, from: Data(body.utf8))
            #expect(!CAPUsagePresentation.costCoverageIsComplete(costs))
            #expect(CAPUsagePresentation.costReliabilityBanner(costs).contains("未知"))
        }
    }
}
