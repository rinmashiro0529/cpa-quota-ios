#if DEBUG
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Debug-only protocol fixtures for the separate XCUITest runner. Responses go
/// through the production CPAClient, wire decoders, stores, and presenters.
/// This factory and every fixture payload are absent from Release builds.
@_spi(Testing) public enum CPAQuotaUITestFixtures {
    public static let serverAddress = "https://ui-test.invalid"
    public static let managementKey = "ui-test-valid-key"

    public static func makeClient(server: CPAServer, managementKey: ManagementKey) -> CPAClient {
        CPAClient(server: server, managementKey: managementKey, transport: UITestHTTPTransport())
    }
}

private struct UITestHTTPTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        try Task.checkCancellation()
        guard let url = request.url, url.host == "ui-test.invalid" else {
            return response(status: 404, json: "{}")
        }
        let path = url.path
        if path.hasPrefix("/v0/management/"),
           request.value(forHTTPHeaderField: "Authorization") != "Bearer ui-test-valid-key" {
            return response(status: 401, json: "{}")
        }
        if path.hasSuffix("/auth-files") {
            return response(json: #"{"files":[{"id":"ui-main","auth_index":"ui-index-main","provider":"codex","label":"主要账号","email":"native@example.com","status":"active","disabled":false,"id_token":{"chatgpt_account_id":"ui-owner","plan_type":"team"}},{"id":"ui-empty","auth_index":"ui-index-empty","provider":"codex","label":"额度已用完","email":"zero@example.com","status":"active","disabled":false},{"id":"ui-plugin","auth_index":"ui-index-plugin","provider":"fixture-plugin","label":"摘要指标账号","email":"summary@example.com","status":"active","disabled":false,"supports_quota":true}]}"#)
        }
        if path.hasSuffix("/quota/providers") {
            return response(json: #"{"providers":[{"provider":"fixture-plugin","supported_providers":["fixture-plugin"]}]}"#)
        }
        if path.hasSuffix("/quota/fetch") {
            return response(json: #"{"subscription":{"plan":"标准套餐"},"summary":[{"key":"requests","label":"剩余请求数","value":123,"unit":"requests"},{"key":"unknown","label":"未提供数值","value":null,"unit":"tokens"}]}"#)
        }
        if path.hasSuffix("/api-call") {
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            let empty = body?["auth_index"] as? String == "ui-index-empty"
            let now = Date().timeIntervalSince1970
            let quota: [String: Any] = [
                "plan_type": "team",
                "rate_limit": [
                    "allowed": !empty,
                    "limit_reached": empty,
                    "primary_window": ["used_percent": empty ? 100 : 58, "limit_window_seconds": 18_000, "reset_at": now + 3_600],
                    "secondary_window": ["used_percent": 9, "limit_window_seconds": 604_800, "reset_at": now + 86_400]
                ],
                "credits": ["has_credits": true, "unlimited": false, "balance": 12.5]
            ]
            let encodedQuota = try JSONSerialization.data(withJSONObject: quota)
            return try response(object: [
                "status_code": 200, "header": [String: String](),
                "body": String(decoding: encodedQuota, as: UTF8.self)
            ])
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = components?.queryItems ?? []
        let offset = Int(query.first { $0.name == "offset" }?.value ?? "0") ?? 0
        let limit = Int(query.first { $0.name == "limit" }?.value ?? "50") ?? 50
        let formatter = ISO8601DateFormatter()
        let endString = query.first { $0.name == "end" }?.value
        let end = endString.flatMap { formatter.date(from: $0) } ?? Date()
        let stamp = formatter.string(from: end)
        let requestTime = formatter.string(from: end.addingTimeInterval(-60))
        let summary: [String: Any] = [
            "requests": 2, "failed_requests": 1, "input_tokens": 170,
            "output_tokens": 90, "total_tokens": 260
        ]
        let model: [String: Any] = [
            "provider": "openai", "model": "fixture-model", "hour": requestTime,
            "requests": 2, "failed_requests": 1, "input_tokens": 170,
            "output_tokens": 90, "total_tokens": 260
        ]
        var common: [String: Any] = ["schema_version": 1, "generated_at": stamp, "range": "custom"]
        if path.hasSuffix("/cap-token-usage-tracker/requests") {
            let items: [[String: Any]] = [
                ["sequence": 10, "time": requestTime, "provider": "openai", "model": "fixture-model", "executor_type": "codex", "stream": true, "failed": false, "input_tokens": 120, "output_tokens": 90, "reasoning_tokens": 0, "total_tokens": 210, "latency_ns": 4_000_000_000, "ttft_ns": 1_000_000_000],
                ["sequence": 11, "time": requestTime, "provider": "openai", "model": "fixture-model", "executor_type": "codex", "stream": true, "failed": true, "failure_status": 502, "input_tokens": 50]
            ]
            common["price_book_revision"] = 3
            common["total"] = items.count
            common["offset"] = offset
            common["limit"] = limit
            common["items"] = Array(items.dropFirst(max(0, offset)).prefix(max(0, limit)))
            return try response(object: common)
        }
        if path.hasSuffix("/stats/initial") {
            common["retained_since"] = stamp
            common["last_used"] = requestTime
            common["bucket_seconds"] = 300
            common["summary"] = summary
            common["models"] = [model]
            common["series"] = [model]
            common["sources"] = ["codex"]
            return try response(object: common)
        }
        if path.hasSuffix("/stats/trends") {
            common["bucket_seconds"] = 300
            common["model_series"] = [model]
            return try response(object: common)
        }
        if path.hasSuffix("/stats/groups") {
            common["total"] = 1
            common["items"] = offset == 0 ? [model] : []
            return try response(object: common)
        }
        if path.hasSuffix("/cap-token-usage-tracker/costs") {
            common["currency"] = "USD"
            common["estimate_basis"] = "list_price"
            common["price_book_revision"] = 3
            common["summary"] = ["requests": 2, "priced_requests": 1, "unpriced_requests": 1, "total_usd": 0.015]
            common["models"] = [] as [String]
            common["series"] = [] as [String]
            common["missing_prices"] = [["provider": "openai", "model": "fixture-unpriced", "requests": 1]]
            return try response(object: common)
        }
        if path.hasSuffix("/management/plugins/cap-token-usage-tracker/stats") {
            common["retained_since"] = stamp
            common["last_used"] = requestTime
            common["summary"] = summary
            common["groups"] = [model]
            common["series"] = [model]
            common["model_series"] = [model]
            common["sources"] = ["codex"]
            return try response(object: common)
        }
        return response(status: 404, json: "{}")
    }

    private func response(status: Int = 200, json: String) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: ["Content-Type": "application/json"], body: Data(json.utf8))
    }

    private func response(object: [String: Any]) throws -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"],
                     body: try JSONSerialization.data(withJSONObject: object))
    }
}
#endif
