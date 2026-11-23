import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reads the server's client API key list with the management key.
/// `GET /v0/management/api-keys` answers `{"api-keys": [String] | null}`;
/// older builds without that route get the generic config-path read at
/// `GET /v8/management/config/access/api-keys` (a bare `[String]` or the
/// same object). Two 404s mean the server exposes no key list.
public actor CPAAPIKeyDiscovery {
    private let server: CPAServer
    private let key: ManagementKey
    private let transport: any HTTPTransport
    private let clock: @Sendable () -> Date
    private let limiter: CPAManagementRequestCoordinator

    init(server: CPAServer, managementKey: ManagementKey, transport: any HTTPTransport,
         coordinator: CPAManagementRequestCoordinator, clock: @escaping @Sendable () -> Date) {
        self.server = server
        self.key = managementKey
        self.transport = transport
        self.clock = clock
        self.limiter = coordinator
    }

    public func keys() async throws -> [CPAClientAPIKey] {
        do {
            let response = try await perform(server.endpoint("api-keys"))
            return try Self.decode(response.body)
        } catch let error as CPAError where error.kind == .endpointUnavailable {
            do {
                let response = try await perform(server.v8Endpoint("config/access/api-keys"))
                return try Self.decode(response.body)
            } catch let fallbackError as CPAError where fallbackError.kind == .endpointUnavailable {
                return []
            }
        }
    }

    private func perform(_ url: URL) async throws -> HTTPResponse {
        let key = self.key
        let transport = self.transport
        let clock = self.clock
        return try await limiter.withPermit {
            try Task.checkCancellation()
            var request = URLRequest(url: url, timeoutInterval: 75)
            request.httpMethod = "GET"
            request.setValue("Bearer \(key.value)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let response: HTTPResponse
            do { response = try await transport.send(request) }
            catch { throw CPAError.normalize(error) }
            try Task.checkCancellation()
            guard (200..<300).contains(response.statusCode) else {
                let status = response.statusCode
                let kind: CPAError.Kind = switch status {
                case 300..<400: .redirectRefused
                case 401: .managementUnauthorized
                case 403: .managementForbidden
                case 404, 501: .endpointUnavailable
                case 429: .rateLimited
                default: .requestRejected
                }
                let retryAfter = WireDate.retryAfter(response.header("Retry-After"), now: clock())
                throw CPAError(kind, layer: .management, statusCode: status,
                               retryAfter: status == 429 ? (retryAfter ?? clock().addingTimeInterval(60)) : retryAfter)
            }
            return response
        }
    }

    static func decode(_ data: Data) throws -> [CPAClientAPIKey] {
        let root = try WireJSON.decode(data)
        let items: [WireJSON]
        switch root {
        case .array(let list):
            items = list
        case .object:
            guard let value = root.lookup("api-keys") else { throw CPAError(.invalidResponse) }
            if value == .null { return [] }
            guard let list = value.arrayItems else { throw CPAError(.invalidResponse) }
            items = list
        default:
            throw CPAError(.invalidResponse)
        }
        var seen = Set<CPAClientAPIKey>()
        var keys: [CPAClientAPIKey] = []
        for item in items {
            guard case .string(let raw) = item,
                  let key = CPAClientAPIKey(raw), seen.insert(key).inserted else { continue }
            keys.append(key)
        }
        return keys
    }
}
