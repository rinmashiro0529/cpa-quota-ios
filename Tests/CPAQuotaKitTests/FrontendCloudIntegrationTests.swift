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

    func recordedURLs() -> [String] { requestURLs }

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
        if urlString.contains("/v0/resource/plugins/cap-token-usage-tracker/requests") {
            if shouldFailOverview {
                return HTTPResponse(statusCode: 503, headers: [:], body: Data())
            }
            let json = #"{"generated_at":"2026-10-29T12:00:00Z","range":"custom","price_book_revision":3,"total":2,"offset":0,"limit":500,"items":[{"sequence":10,"time":"2026-10-29T11:58:00Z","provider":"openai","model":"gpt-5","executor_type":"codex","stream":true,"failed":false,"input_tokens":120,"output_tokens":90,"reasoning_tokens":0,"total_tokens":210,"latency_ns":4000000000,"ttft_ns":1000000000},{"sequence":11,"time":"2026-10-29T11:59:00Z","provider":"openai","model":"gpt-5","executor_type":"codex","stream":true,"failed":true,"failure_status":502,"input_tokens":50}]}"#
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
        }
        if urlString.contains("/v0/resource/plugins/cap-token-usage-tracker/stats/initial") {
            let json = #"{"schema_version":1,"generated_at":"2026-10-29T12:00:00Z","range":"custom","retained_since":"2026-10-01T00:00:00Z","last_used":"2026-10-29T11:59:00Z","bucket_seconds":300,"summary":{"requests":2,"failed_requests":1,"input_tokens":170,"output_tokens":90,"total_tokens":260},"models":[],"series":[],"sources":["codex"]}"#
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
        }
        if urlString.contains("/v0/resource/plugins/cap-token-usage-tracker/stats/trends") {
            let json = #"{"schema_version":1,"generated_at":"2026-10-29T12:00:00Z","range":"custom","bucket_seconds":300,"model_series":[]}"#
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
        }
        if urlString.contains("/v0/resource/plugins/cap-token-usage-tracker/stats/groups") {
            let json = #"{"schema_version":1,"generated_at":"2026-10-29T12:00:00Z","range":"custom","total":1,"items":[{"provider":"openai","model":"gpt-5","requests":2,"failed_requests":1,"total_tokens":260}]}"#
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
        }
        if urlString.contains("/v0/resource/plugins/cap-token-usage-tracker/costs") {
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
            session.activeTab = tab
        }
        let callsAfterTabSwitch = await transport.recordedCount()
        #expect(callsAfterTabSwitch == callsBeforeTabSwitch)

        // Refresh 30m overview and verify strict weighted TPS (90 tokens / 3s = 30.0 token/s)
        await session.capUsageCoordinator.refreshOverview(now: Date(timeIntervalSince1970: 1_793_275_230))
        let snapshot = try #require(session.capUsageCoordinator.store?.snapshot)
        #expect(snapshot.requests.completeness == .singlePage)
        #expect(snapshot.models.count == 1)
        #expect(snapshot.models.first?.summary.generationTPS == 30.0)
        #expect(snapshot.models.first?.summary.generationSamples == 1)
        #expect(snapshot.models.first?.summary.totalRequests == 2)

        // Subsequent failure preserves previous overview snapshot (U11)
        await transport.setShouldFailOverview(true)
        await session.capUsageCoordinator.refreshOverview(now: Date(timeIntervalSince1970: 1_793_275_290))
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
    func workspaceRefreshTargetsCAPAndDoesNotStartUnconfiguredMonitoring() async throws {
        let transport = FrontendCAPMockTransport()
        let session = CPAQuotaSession(
            credentialStore: MemoryCredentialStore(), preferences: MemoryPreferencesStore(),
            clientFactory: { server, key in CPAClient(server: server, managementKey: key, transport: transport) }
        )
        await session.connect(serverAddress: "https://cpa.example.test", managementKeyInput: "synthetic-key", rememberInKeychain: false)
        let before = await transport.recordedCount()
        session.activeTab = .usage
        await session.refreshCurrentWorkspace()
        #expect(session.capUsageCoordinator.store?.snapshot != nil)
        let requests = await transport.recordedURLs()
        #expect(Array(requests.dropFirst(before)).count == 1)
        #expect(requests.last?.contains("/v0/resource/plugins/cap-token-usage-tracker/requests") == true)
        session.activeTab = .monitoring
        await session.refreshCurrentWorkspace()
        #expect(await transport.recordedCount() == requests.count)
        #expect(session.monitoringCoordinator.store == nil)
        #expect(session.monitoringCoordinator.pendingCreateUUID == nil)
        #expect(!session.isPresentingConnectionSheet)
    }

    @Test @MainActor
    func monitoringCoordinatorReconcilesTimedOutCreateWithSameUUIDAndHonorsDelete204Vs404And507() async throws {
        let bridgeStorage = MemoryCredentialStore()
        let bridgeCredStore = MonitoringBridgeCredentialStore(storage: bridgeStorage)
        let metadata = MemoryMonitoringMetadataPersistence()
        let liveDriver = SyntheticLiveActivityDriver()

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
                    transport: DynamicMonitorScenarioTransport()
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
        for id in ["acc-1", "acc-2", "acc-3", "acc-4", "acc-5", "acc-6"] {
            coordinator.addAccountIDDraft(id)
        }
        #expect(coordinator.selectedAccountIDsDraft.count == 5)

        // 1. Start session -> POST times out -> state becomes .uncertain and pendingCreateUUID is preserved (U16)
        await coordinator.startOrReconcileMonitoringSession()
        let firstUUID = try #require(coordinator.pendingCreateUUID)
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
    func liveActivityStateUsesFlatWireContractAndSafeLocalAccountSelection() throws {
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

        let state = try CPAQuotaLiveActivityState(snapshot: snapshot)
        let encoded = try JSONEncoder().encode(state)
        #expect(encoded.count <= 3_584)
        let wire = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(wire["snapshotData"] == nil)
        #expect(wire["focusedIndex"] == nil)
        #expect(wire["version"] as? Int == 1)
        #expect(state.account(at: 0)?.id == "codex-a")
        #expect(state.account(at: 1)?.id == "claude-b")
        #expect(state.account(at: 2)?.id == "codex-a")
        #expect(state.account(at: -1)?.id == "claude-b")

    }
}

private actor DynamicMonitorScenarioTransport: HTTPTransport {
    private var step = 0
    private var registeredID: String?
    private var registeredActivityID: String?

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        step += 1
        switch step {
        case 1:
            // Capture the actual POST rather than mutating a variable inside a Sendable closure.
            #expect(request.httpMethod == "POST")
            let body = try #require(request.httpBody)
            let registration = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            registeredID = try #require(registration["id"] as? String)
            registeredActivityID = try #require(registration["activity_id"] as? String)
            throw URLError(.timedOut)
        case 2:
            // Step 2: GET /v1/monitoring/sessions/{id} reconciles the exact same UUID
            let id = try #require(registeredID)
            let activityID = try #require(registeredActivityID)
            #expect(request.httpMethod == "GET")
            #expect(request.url?.lastPathComponent == id)
            let json = """
            {"version":1,"id":"\(id)","source_id":"prod-cpa","account_ids":["acc-1","acc-2","acc-3","acc-4","acc-5"],"activity_id":"\(activityID)","starts_at":1800000000,"expires_at":1800014400,"next_refresh_at":1800000300,"status":"active","revision":1,"delivery_state":"sent"}
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
