import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CPAModel: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let ownedBy: String?

    public init(id: String, ownedBy: String? = nil) {
        self.id = id
        self.ownedBy = ownedBy
    }
}

/// Reads `GET {server}/v1/models` with a client API key. This is an inference
/// endpoint, not a management one: statuses map to plain `CPAError` kinds and
/// no management-layer limiter circuit is shared.
public actor CPAModelCatalogClient {
    private let server: CPAServer
    private let apiKey: CPAClientAPIKey
    private let transport: any HTTPTransport
    private let clock: @Sendable () -> Date

    public init(server: CPAServer, apiKey: CPAClientAPIKey) {
        self.init(server: server, apiKey: apiKey, transport: URLSessionTransport())
    }

    init(server: CPAServer, apiKey: CPAClientAPIKey, transport: any HTTPTransport,
         clock: @escaping @Sendable () -> Date = { Date() }) {
        self.server = server
        self.apiKey = apiKey
        self.transport = transport
        self.clock = clock
    }

    public func models() async throws -> [CPAModel] {
        try Task.checkCancellation()
        var request = URLRequest(
            url: server.baseURL.appendingPathComponent("v1").appendingPathComponent("models"),
            timeoutInterval: 75)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey.exposedValue)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response: HTTPResponse
        do { response = try await transport.send(request) }
        catch { throw CPAError.normalize(error) }
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else {
            let status = response.statusCode
            let kind: CPAError.Kind = switch status {
            case 300..<400: .redirectRefused
            case 404: .endpointUnavailable
            case 429: .rateLimited
            default: .requestRejected
            }
            let retryAfter = WireDate.retryAfter(response.header("Retry-After"), now: clock())
            throw CPAError(kind, statusCode: status,
                           retryAfter: status == 429 ? (retryAfter ?? clock().addingTimeInterval(60)) : retryAfter)
        }
        return try Self.decode(response.body)
    }

    static func decode(_ data: Data) throws -> [CPAModel] {
        let root = try WireJSON.decode(data)
        guard let items = root.arrayAt("data") else { throw CPAError(.invalidResponse) }
        var seen = Set<String>()
        var models: [CPAModel] = []
        for item in items {
            guard let id = nonEmptyWireString(item.stringAt("id")), seen.insert(id).inserted else {
                continue
            }
            models.append(CPAModel(id: id, ownedBy: nonEmptyWireString(item.stringAt("owned_by"))))
        }
        return models.sorted { $0.id < $1.id }
    }
}
