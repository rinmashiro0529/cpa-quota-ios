import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import CPAQuotaKit

struct FixtureAccount: Encodable, Sendable {
    let id: String
    let auth_index: String?
    var provider = "codex"
    var disabled = false
    var supports_quota = false
    var status = "active"
    var label = "Fixture account"
    var id_token = ["chatgpt_account_id": "fixture-owner", "plan_type": "team"]

    init(_ id: String, provider: String = "codex", disabled: Bool = false, plugin: Bool = false,
         index: String? = nil) {
        self.id = id
        self.auth_index = index ?? "index-\(id)"
        self.provider = provider
        self.disabled = disabled
        self.supports_quota = plugin
    }
}

enum Fixtures {
    static let codexBody = #"{"plan_type":"team","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":58,"limit_window_seconds":18000,"reset_at":1900000000},"secondary_window":{"used_percent":9,"limit_window_seconds":604800,"reset_at":1900600000}},"credits":{"has_credits":false,"unlimited":false,"balance":null}}"#
    static let pluginBody = #"{"subscription":{"plan":"fixture"},"summary":[{"key":"requests","label":"Requests remaining","value":123,"unit":"requests"}]}"#

    static func inventory(_ accounts: [FixtureAccount]) throws -> Data {
        struct Payload: Encodable { let files: [FixtureAccount] }
        return try JSONEncoder().encode(Payload(files: accounts))
    }
}

actor TestGate {
    private var isOpen = false
    private var arrivals = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    // Deliberately ignores cancellation so a late network response can be tested.
    func enter() async {
        arrivals += 1
        let ready = arrivalWaiters.filter { $0.0 <= arrivals }
        arrivalWaiters.removeAll { $0.0 <= arrivals }
        ready.forEach { $0.1.resume() }
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func waitForArrivals(_ count: Int = 1) async {
        if arrivals >= count { return }
        await withCheckedContinuation { arrivalWaiters.append((count, $0)) }
    }

    func open() {
        isOpen = true
        let pending = waiting
        waiting.removeAll()
        pending.forEach { $0.resume() }
    }
}

struct FixtureReply: Sendable {
    var outerStatus = 200
    var upstreamStatus = 200
    var body = Fixtures.codexBody
    var failure: CPAError?
    var retryAfter: String?
    var outerHeaders: [String: String] = [:]
}

actor ScenarioTransport: HTTPTransport {
    private var inventory: Data
    private var replies: [String: FixtureReply] = [:]
    private var gates: [String: TestGate] = [:]
    private var accountStatus = 200
    private var providerStatus = 200
    private var providerNames: [String] = []
    private var providerGate: TestGate?
    private var providerRawBody: Data?
    private var requests: [URLRequest] = []
    private var active = 0
    private var maximumActive = 0
    private var delay: Duration = .zero
    private var inventoryGate: TestGate?

    init(accounts: [FixtureAccount]) throws {
        inventory = try Fixtures.inventory(accounts)
    }

    func setReply(_ reply: FixtureReply, for index: String) { replies[index] = reply }
    func setGate(_ gate: TestGate, for index: String) { gates[index] = gate }
    func setDelay(_ delay: Duration) { self.delay = delay }
    func setInventoryGate(_ gate: TestGate?) { inventoryGate = gate }
    func setInventory(_ accounts: [FixtureAccount]) throws { inventory = try Fixtures.inventory(accounts) }
    func setAccountStatus(_ status: Int) { accountStatus = status }
    func setProviderStatus(_ status: Int) { providerStatus = status }
    func setProviders(_ providers: [String]) { providerNames = providers }
    func setProviderGate(_ gate: TestGate?) { providerGate = gate }
    func setProviderRawBody(_ body: Data?) { providerRawBody = body }
    func capturedRequests() -> [URLRequest] { requests }
    func peakConcurrency() -> Int { maximumActive }
    func quotaRequestCount() -> Int { requests.filter { $0.httpMethod == "POST" }.count }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        let path = request.url?.path ?? ""
        if path.hasSuffix("/auth-files") {
            let body = inventory
            let status = accountStatus
            if let gate = inventoryGate { await gate.enter() }
            return HTTPResponse(statusCode: status, headers: ["X-Cpa-Version": "fixture-version"], body: body)
        }
        if path.hasSuffix("/quota/providers") {
            if let gate = providerGate { await gate.enter() }
            if let body = providerRawBody {
                return HTTPResponse(statusCode: providerStatus, headers: [:], body: body)
            }
            let values = providerNames.map { ["provider": $0, "supported_providers": [$0]] as [String: Any] }
            let data = try JSONSerialization.data(withJSONObject: ["providers": values])
            return HTTPResponse(statusCode: providerStatus, headers: [:], body: data)
        }
        let object = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        let index = object?["auth_index"] as? String ?? ""
        let reply = replies[index] ?? FixtureReply()
        let gate = gates[index]
        active += 1
        maximumActive = max(active, maximumActive)
        defer { active -= 1 }
        if let gate { await gate.enter() }
        if delay != .zero { try await Task.sleep(for: delay) }
        if let failure = reply.failure { throw failure }
        if path.hasSuffix("/quota/fetch") {
            return HTTPResponse(statusCode: reply.outerStatus, headers: reply.outerHeaders,
                                body: Data(reply.body.utf8))
        }
        let headers: [String: [String]] = reply.retryAfter.map { ["Retry-After": [$0]] } ?? [:]
        let body = try JSONSerialization.data(withJSONObject: [
            "status_code": reply.upstreamStatus,
            "header": headers,
            "body": reply.body
        ])
        return HTTPResponse(statusCode: reply.outerStatus, headers: reply.outerHeaders, body: body)
    }
}

actor UpdateCollector {
    private var updates: [QuotaRecord] = []
    private var waiting: [(Int, CheckedContinuation<Void, Never>)] = []

    func append(_ record: QuotaRecord) {
        updates.append(record)
        let ready = waiting.filter { $0.0 <= updates.count }
        waiting.removeAll { $0.0 <= updates.count }
        ready.forEach { $0.1.resume() }
    }

    func waitForCount(_ count: Int) async {
        if updates.count >= count { return }
        await withCheckedContinuation { waiting.append((count, $0)) }
    }

    func values() -> [QuotaRecord] { updates }
}
