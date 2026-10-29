import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CPAQuotaKit
import CPAQuotaUI

private actor FrontendCAPMockTransport: HTTPTransport {
    private(set) var requestURLs: [String] = []
    private var shouldFailOverview = false

    func setShouldFailOverview(_ value: Bool) {
        shouldFailOverview = value
    }

    func recordedCount() -> Int {
        requestURLs.count
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let urlString = request.url?.absoluteString ?? ""
        requestURLs.append(urlString)

        if urlString.contains("/v0/management/auth-files") {
            let body = #"{"files":[{"id":"acc-alpha","provider":"codex","email":"alpha@example.com","disabled":false},{"id":"acc-beta","provider":"claude","email":"beta@example.com","disabled":false}]}"#
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
        }
        if urlString.contains("/v0/management/api-call") {
            let wrapper = #"{"status_code":200,"header":{},"body":"{\"plan_type\":\"pro\",\"rate_limit\":{\"allowed\":true,\"limit_reached\":false,\"primary_window\":{\"used_percent\":25,\"limit_window_seconds\":3600,\"reset_at\":1900003600}}}"}"#
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(wrapper.utf8))
        }
        if urlString.contains("/_resources/cap/api/requests") {
            if shouldFailOverview {
                return HTTPResponse(statusCode: 503, headers: [:], body: Data())
            }
            let json = #"{"generated_at":"2026-10-29T12:00:00Z","range":"custom","price_book_revision":3,"total":2,"offset":0,"limit":500,"items":[{"sequence":10,"time":"2026-10-29T11:58:00Z","provider":"openai","model":"gpt-5","executor_type":"codex","stream":true,"failed":false,"input_tokens":120,"output_tokens":90,"reasoning_tokens":0,"total_tokens":210,"latency_ns":4000000000,"ttft_ns":1000000000},{"sequence":11,"time":"2026-10-29T11:59:00Z","provider":"openai","model":"gpt-5","executor_type":"codex","stream":true,"failed":true,"failure_status":502,"input_tokens":50}]}"#
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
        }
        if urlString.contains("/_resources/cap/api/initial") {
            let json = #"{"schema_version":1,"generated_at":"2026-10-29T12:00:00Z","range":"custom","retained_since":"2026-10-01T00:00:00Z","last_used":"2026-10-29T11:59:00Z","bucket_seconds":300,"summary":{"requests":2,"failed_requests":1,"input_tokens":170,"output_tokens":90,"total_tokens":260},"models":[],"series":[],"sources":["codex"]}"#
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
        }
        if urlString.contains("/_resources/cap/api/trends") {
            let json = #"{"schema_version":1,"generated_at":"2026-10-29T12:00:00Z","range":"custom","bucket_seconds":300,"model_series":[]}"#
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
        }
        if urlString.contains("/_resources/cap/api/groups") {
            let json = #"{"schema_version":1,"generated_at":"2026-10-29T12:00:00Z","range":"custom","total":1,"items":[{"provider":"openai","model":"gpt-5","requests":2,"failed_requests":1,"total_tokens":260}]}"#
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
        }
        if urlString.contains("/_resources/cap/api/costs") {
            let json = #"{"schema_version":1,"generated_at":"2026-10-29T12:00:00Z","range":"custom","currency":"USD","estimate_basis":"list_price","price_book_revision":3,"summary":{"requests":2,"priced_requests":1,"unpriced_requests":1,"total_usd":0.015},"models":[],"series":[],"missing_prices":[{"provider":"openai","model":"gpt-5-unpriced","requests":1}]}"#
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
        }
        if urlString.contains("/v0/management/plugins/cap-token-usage-tracker/stats") {
            let json = #"{"schema_version":1,"generated_at":"2026-10-29T12:00:00Z","range":"custom","retained_since":"2026-10-01T00:00:00Z","last_used":"2026-10-29T11:59:00Z","summary":{"requests":2,"failed_requests":1,"total_tokens":260},"groups":[],"series":[],"model_series":[],"sources":["codex"]}"#
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
        }
        return HTTPResponse(statusCode: 404, headers: [:], body: Data())
    }
}

private actor FrontendMonitorMockTransport: HTTPTransport {
    private var responses: [Result<HTTPResponse, any Error>]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [Result<HTTPResponse, any Error>]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            return HTTPResponse(statusCode: 503, headers: [:], body: Data())
        }
        let next = responses.removeFirst()
        return try next.get()
    }

    func requestMethodsAndPaths() -> [String] {
        requests.map { "\($0.httpMethod ?? "GET") \($0.url?.path ?? "")" }
    }
}

private final class InMemoryMonitoringMetadataPersistence: MonitoringMetadataPersistence, @unchecked Sendable {
    var savedBridgeAddress: String?
    var records: [PersistedMonitoringRecord] = []

    func loadSavedBridgeAddress() -> String? { savedBridgeAddress }
    func saveBridgeAddress(_ address: String?) { savedBridgeAddress = address }
    func loadPersistedRecords() -> [PersistedMonitoringRecord] { records }
    func savePersistedRecords(_ newRecords: [PersistedMonitoringRecord]) { records = newRecords }
}

@Suite("Frontend Cloud Integration Tests (CAP Usage, Monitoring, Live Activity, Tab Routing)")
struct FrontendCloudIntegrationTests {

    @Test
    func capUsagePresentationFormatsNullsCompletenessAndMissingPricesHonestly() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_095)
        let window = CAPUsageWindow(now: now)
        #expect(window.end == Date(timeIntervalSince1970: 1_800_000_060))
        #expect(window.start == Date(timeIntervalSince1970: 1_799_998_260))

        let emptySummary = CAPUsageAggregation.summarize([])
        #expect(CAPUsagePresentation.generationTPSText(emptySummary) == "无有效生成 TPS 样本")
        #expect(CAPUsagePresentation.generationCoverageText(emptySummary) == "有效生成样本 0 / 总请求 0")
        #expect(CAPUsagePresentation.formatUSD(nil) == "未知 (nil)")
        #expect(CAPUsagePresentation.formatCounter(nil) == "未知 (nil)")
        #expect(CAPUsagePresentation.formatNanosecondsAsMillis(nil) == "未知 (nil)")

        #expect(CAPUsagePresentation.completenessTitle(.singlePage).contains("singlePage"))
        #expect(CAPUsagePresentation.completenessTitle(.offsetUnverified).contains("offsetUnverified"))
        #expect(CAPUsagePresentation.completenessTitle(.truncated).contains("truncated"))
    }

    @Test @MainActor
    func sessionConnectBindsCAPUsageAndForgetTearsDownWithoutTabSwitchStorms() async throws {
        let transport = FrontendCAPMockTransport()
        let credentials = MemoryCredentialStore()
        let prefs = MemoryPreferencesStore()

        let session = CPAQuotaSession(
            credentialStore: credentials,
            preferences: prefs,
            clientFactory: { server, key in
                CPAClient(server: server, managementKey: key, transport: transport)
            }
        )

        await session.connect(
            serverAddress: "https://cpa.example.com",
            managementKeyInput: "mgmt-secret-key",
            rememberInKeychain: true
        )

        #expect(session.capUsageCoordinator.client != nil)
        #expect(session.capUsageCoordinator.store != nil)

        // Switching tabs across all 5 workspace tabs must not trigger automatic network storms (U24).
        let callsBeforeTabSwitch = await transport.recordedCount()
        for tab in CPAWorkspaceTab.allCases {
            session.selectedTab = tab
        }
        let callsAfterTabSwitch = await transport.recordedCount()
        #expect(callsAfterTabSwitch == callsBeforeTabSwitch)

        // Refresh 30m overview and verify strict weighted TPS (90 tokens / 3s = 30.0 token/s)
        await session.capUsageCoordinator.refreshOverview(now: Date(timeIntervalSince1970: 1_800_000_090))
        let snapshot = try #require(session.capUsageCoordinator.store?.snapshot)
        #expect(snapshot.requests.completeness == .singlePage)
        #expect(snapshot.models.count == 1)
        #expect(snapshot.models.first?.summary.generationTPS == 30.0)
        #expect(snapshot.models.first?.summary.generationSamples == 1)
        #expect(snapshot.models.first?.summary.totalRequests == 2)

        // Subsequent failure preserves previous overview snapshot (U11)
        await transport.setShouldFailOverview(true)
        await session.capUsageCoordinator.refreshOverview(now: Date(timeIntervalSince1970: 1_800_000_180))
        #expect(session.capUsageCoordinator.store?.snapshot?.models.first?.summary.generationTPS == 30.0)
        #expect(session.capUsageCoordinator.store?.error != nil)

        // Details & management stats
        await session.capUsageCoordinator.refreshDetails(groupOffset: 0, groupLimit: 100)
        let details = try #require(session.capUsageCoordinator.store?.details)
        #expect(details.costs.missingPrices.count == 1)
        #expect(CAPUsagePresentation.costReliabilityBanner(details.costs).contains("缺价不等于免费"))

        await session.capUsageCoordinator.refreshManagementStats()
        #expect(session.capUsageCoordinator.managementStats?.summary.requests == 2)

        // Forget connection tears down CAPUsageWorkspaceCoordinator state (U05, U11)
        await session.forgetCurrentConnection()
        #expect(session.capUsageCoordinator.client == nil)
        #expect(session.capUsageCoordinator.store == nil)
        #expect(session.capUsageCoordinator.managementStats == nil)
    }

    @Test @MainActor
    func monitoringCoordinatorReconcilesTimedOutCreateWithSameUUIDAndHonorsDelete204Vs404And507() async throws {
        let bridgeStorage = MemoryCredentialStore()
        let bridgeCredStore = MonitoringBridgeCredentialStore(storage: bridgeStorage)
        let metadata = InMemoryMonitoringMetadataPersistence()
        let liveDriver = SyntheticLiveActivityDriver()

        var capturedUUID: UUID?
        let coordinator = MonitoringWorkspaceCoordinator(
            credentialStore: bridgeCredStore,
            metadataStore: metadata,
            liveActivityDriver: liveDriver,
            clientFactory: { url, token in
                // First request (POST create) fails with network timeout;
                // Second request (GET reconcile) succeeds for that exact UUID;
                // Third request (DELETE stop) fails with 507 capacityExceeded;
                // Fourth request (DELETE stop) succeeds with 204 No Content.
                try CPAMonitorClient(
                    baseURL: url,
                    token: token,
                    transport: DynamicMonitorScenarioTransport(uuidProvider: { capturedUUID })
                )
            }
        )

        await coordinator.connectBridge(
            rawURLString: "https://monitor.example.com",
            rawTokenString: "bridge-token-123",
            rememberInKeychain: true
        )
        #expect(coordinator.isSavedInKeychain)

        coordinator.sourceIDDraft = "prod-cpa"
        coordinator.populateAccountsFromCPASession(["acc-1", "acc-2", "acc-3", "acc-4", "acc-5", "acc-6"])
        #expect(coordinator.selectedAccountIDsDraft.count == 5)

        // 1. Start session -> POST times out -> state becomes .uncertain and pendingCreateUUID is preserved (U16)
        await coordinator.startOrReconcileMonitoringSession()
        let firstUUID = try #require(coordinator.pendingCreateUUID)
        capturedUUID = firstUUID
        #expect(coordinator.store?.state == .uncertain)
        #expect(coordinator.persistedRecords.first?.sessionID == firstUUID)

        // 2. Retry / Reconcile -> uses GET with the exact same firstUUID instead of minting a new UUID (U16)
        await coordinator.startOrReconcileMonitoringSession()
        #expect(coordinator.store?.state == .available)
        #expect(coordinator.store?.session?.id == firstUUID)
        #expect(coordinator.pendingCreateUUID == nil)

        // 3. Stop session when server returns 507 -> does NOT record cancellation receipt (U17, U19)
        await coordinator.stopActiveMonitoringSession()
        #expect(coordinator.store?.state == .uncertain)
        #expect(coordinator.store?.error == .capacityExceeded)
        #expect(coordinator.store?.cancellationReceipt == nil)

        // 4. Stop session when server returns 204 -> records cancellationReceipt and ends local Live Activity (U17)
        await coordinator.stopActiveMonitoringSession()
        #expect(coordinator.store?.state == .stopIntentRecorded)
        #expect(coordinator.store?.cancellationReceipt?.id == firstUUID)
        #expect(liveDriver.endedImmediately == true)
    }

    @Test
    func liveActivityStateEnforces3584ByteCeilingAndRotatesAccounts() throws {
        let acc1 = try MonitoringAccount(
            id: "codex-a",
            label: "Codex Primary",
            provider: "codex",
            windowID: "5h",
            windowLabel: "5h Window",
            remainingFraction: 0.72,
            observedAt: Date(timeIntervalSince1970: 1_800_000_000),
            status: .ok
        )
        let acc2 = try MonitoringAccount(
            id: "claude-b",
            label: "Claude Backup",
            provider: "claude",
            windowID: "24h",
            windowLabel: "24h Window",
            remainingFraction: 0.35,
            observedAt: Date(timeIntervalSince1970: 1_800_000_000),
            status: .ok
        )
        let snapshot = try MonitoringSnapshot(
            sequence: 7,
            phase: .ready,
            generatedAt: Date(timeIntervalSince1970: 1_800_000_010),
            expiresAt: Date(timeIntervalSince1970: 1_800_000_610),
            accounts: [acc1, acc2]
        )

        let state0 = try CPAQuotaLiveActivityState(snapshot: snapshot, focusedIndex: 0)
        #expect(state0.snapshotData.count <= 3_584)
        #expect(state0.focusedAccount?.id == "codex-a")

        let state1 = try state0.rotated()
        #expect(state1.focusedAccount?.id == "claude-b")

        let state2 = try state1.rotated()
        #expect(state2.focusedAccount?.id == "codex-a")
    }
}

private actor DynamicMonitorScenarioTransport: HTTPTransport {
    private var step = 0
    private let uuidProvider: @Sendable () -> UUID?

    init(uuidProvider: @escaping @Sendable () -> UUID?) {
        self.uuidProvider = uuidProvider
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        step += 1
        switch step {
        case 1:
            // Step 1: POST /v1/monitoring/sessions times out
            throw URLError(.timedOut)
        case 2:
            // Step 2: GET /v1/monitoring/sessions/{id} reconciles the exact same UUID
            let id = (uuidProvider() ?? UUID()).uuidString.lowercased()
            let json = """
            {"version":1,"id":"\(id)","source_id":"prod-cpa","account_ids":["acc-1","acc-2","acc-3","acc-4","acc-5"],"activity_id":"synthetic-live-activity-1","starts_at":1800000000,"expires_at":1800014400,"next_refresh_at":1800000300,"status":"active","revision":1,"delivery_state":"sent"}
            """
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
        case 3:
            // Step 3: DELETE returns 507 capacityExceeded
            return HTTPResponse(statusCode: 507, headers: [:], body: Data())
        default:
            // Step 4: DELETE returns 204 No Content
            return HTTPResponse(statusCode: 204, headers: [:], body: Data())
        }
    }
}
