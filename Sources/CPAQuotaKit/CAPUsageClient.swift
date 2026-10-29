import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum CAPUsageError: Error, Equatable, Sendable {
    case pluginUnavailable
    case invalidResponse
    case network
    case management(CPAError)
    case resourceRejected(statusCode: Int, retryAt: Date?)

    public var retryAt: Date? {
        switch self {
        case .management(let error): error.retryAfter
        case .resourceRejected(_, let date): date
        default: nil
        }
    }
}

public enum CAPUsageResourceAccess: Sendable {
    case anonymous
    case managementKey
}

public actor CAPUsageClient {
    private let server: CPAServer
    private let managementKey: ManagementKey
    private let transport: any HTTPTransport
    private let coordinator: CPAManagementRequestCoordinator
    private let clock: @Sendable () -> Date
    private var resourceRetryAt: Date?

    private func checkResourceEligibility() throws {
        if let deadline = resourceRetryAt {
            if deadline > clock() {
                throw CAPUsageError.resourceRejected(statusCode: 429, retryAt: deadline)
            }
            resourceRetryAt = nil
        }
    }

    private func recordResourceRateLimit(until deadline: Date?) -> CAPUsageError {
        let now = clock()
        let proposed = deadline.map { $0 > now ? $0 : now.addingTimeInterval(60) } ?? now.addingTimeInterval(60)
        resourceRetryAt = max(resourceRetryAt ?? proposed, proposed)
        return .resourceRejected(statusCode: 429, retryAt: resourceRetryAt)
    }

    public init(server: CPAServer, managementKey: ManagementKey,
                coordinator: CPAManagementRequestCoordinator? = nil,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.server = server
        self.managementKey = managementKey
        self.transport = URLSessionTransport()
        self.coordinator = coordinator ?? CPAManagementRequestCoordinator(clock: clock)
        self.clock = clock
    }

    init(server: CPAServer, managementKey: ManagementKey, transport: any HTTPTransport,
         coordinator: CPAManagementRequestCoordinator? = nil,
         clock: @escaping @Sendable () -> Date = { Date() }) {
        self.server = server
        self.managementKey = managementKey
        self.transport = transport
        self.coordinator = coordinator ?? CPAManagementRequestCoordinator(clock: clock)
        self.clock = clock
    }

    public func loadInitialStats(window: CAPUsageWindow, access: CAPUsageResourceAccess) async throws -> CAPUsageInitialStats {
        try await decodeResource(path: "stats/initial", window: window, query: [], access: access)
    }

    public func loadTrends(window: CAPUsageWindow, access: CAPUsageResourceAccess) async throws -> CAPUsageTrends {
        try await decodeResource(path: "stats/trends", window: window, query: [], access: access)
    }

    public func loadGroups(window: CAPUsageWindow, offset: Int, limit: Int, access: CAPUsageResourceAccess) async throws -> CAPUsageGroups {
        guard offset >= 0, (1...500).contains(limit) else { throw CAPUsageError.invalidResponse }
        return try await decodeResource(path: "stats/groups", window: window,
                                        query: [URLQueryItem(name: "offset", value: String(offset)),
                                                URLQueryItem(name: "limit", value: String(limit))], access: access)
    }

    private func decodeResource<Value: Decodable & Sendable>(path: String, window: CAPUsageWindow,
                                                               query: [URLQueryItem], access: CAPUsageResourceAccess) async throws -> Value {
        let data = try await fetchResource(path: path, window: window, query: query, access: access)
        return try decode(Value.self, from: data)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        try Task.checkCancellation()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let value: Value
        do { value = try decoder.decode(type, from: data) }
        catch { throw CAPUsageError.invalidResponse }
        try Task.checkCancellation()
        return value
    }

    public func loadCosts(window: CAPUsageWindow, access: CAPUsageResourceAccess) async throws -> CAPUsageCosts {
        try await decodeResource(path: "costs", window: window, query: [], access: access)
    }

    public func loadWindowRequests(window: CAPUsageWindow, access: CAPUsageResourceAccess) async throws -> CAPUsageRequestCollection {
        var items: [CAPUsageRequest] = []
        var seen = Set<UInt64>()
        var bytes = 0
        var initialTotal: Int?
        for pageIndex in 0..<10 {
            try Task.checkCancellation()
            if bytes > 4_194_304 {
                return CAPUsageRequestCollection(items: items, completeness: .truncated)
            }
            let offset = pageIndex * 500
            let result = try await fetchRequestPage(window: window, offset: offset, limit: 500, access: access)
            guard result.bytes <= 8_388_608 - bytes else {
                return CAPUsageRequestCollection(items: items, completeness: .truncated)
            }
            bytes += result.bytes
            let page = result.page
            if initialTotal == nil { initialTotal = page.total }
            var duplicate = false
            for item in page.items {
                if let sequence = item.sequence, !seen.insert(sequence).inserted {
                    duplicate = true
                } else {
                    items.append(item)
                }
            }
            if duplicate || page.total != initialTotal || offset + page.items.count > page.total {
                return CAPUsageRequestCollection(items: items, completeness: .truncated)
            }
            if offset + page.items.count == page.total {
                return CAPUsageRequestCollection(items: items, completeness: pageIndex == 0 ? .singlePage : .offsetUnverified)
            }
            if page.items.count < 500 {
                return CAPUsageRequestCollection(items: items, completeness: .truncated)
            }
        }
        return CAPUsageRequestCollection(items: items, completeness: .truncated)
    }

    public func loadRequestPage(window: CAPUsageWindow, offset: Int, limit: Int,
                                access: CAPUsageResourceAccess) async throws -> CAPUsageRequestPage {
        try await fetchRequestPage(window: window, offset: offset, limit: limit, access: access).page
    }

    private func fetchRequestPage(window: CAPUsageWindow, offset: Int, limit: Int,
                                  access: CAPUsageResourceAccess) async throws -> (page: CAPUsageRequestPage, bytes: Int) {
        guard offset >= 0, (1...500).contains(limit) else { throw CAPUsageError.invalidResponse }
        let data = try await fetchResource(path: "requests", window: window,
                                           query: [URLQueryItem(name: "offset", value: String(offset)),
                                                   URLQueryItem(name: "limit", value: String(limit))], access: access)
        let page = try decode(CAPUsageRequestPage.self, from: data)
        guard page.total >= 0, page.offset == offset, page.limit == limit, page.items.count <= limit else {
            throw CAPUsageError.invalidResponse
        }
        return (page, data.count)
    }

    private func fetchResource(path: String, window: CAPUsageWindow, query: [URLQueryItem],
                               access: CAPUsageResourceAccess) async throws -> Data {
        let base = server.baseURL.appendingPathComponent("v0/resource/plugins/cap-token-usage-tracker/\(path)")
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw CAPUsageError.invalidResponse
        }
        let formatter = ISO8601DateFormatter()
        components.queryItems = [URLQueryItem(name: "range", value: "custom"),
                                 URLQueryItem(name: "start", value: formatter.string(from: window.start)),
                                 URLQueryItem(name: "end", value: formatter.string(from: window.end))] + query
        guard let url = components.url else { throw CAPUsageError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if case .managementKey = access {
            request.setValue("Bearer \(managementKey.value)", forHTTPHeaderField: "Authorization")
        }
        let immutableRequest = request
        let transport = self.transport
        let clock = self.clock
        let response: HTTPResponse
        do {
            response = try await coordinator.withPermit {
                try await self.checkResourceEligibility()
                let response = try await transport.send(immutableRequest)
                if case .managementKey = access {
                    switch response.statusCode {
                    case 401: throw CPAError(.managementUnauthorized, layer: .management, statusCode: 401)
                    case 403: throw CPAError(.managementForbidden, layer: .management, statusCode: 403)
                    case 429:
                        throw CPAError(.rateLimited, layer: .management, statusCode: 429,
                                       retryAfter: WireDate.retryAfter(response.header("Retry-After"), now: clock()))
                    default: break
                    }
                } else if response.statusCode == 429 {
                    throw await self.recordResourceRateLimit(until: WireDate.retryAfter(response.header("Retry-After"), now: clock()))
                }
                return response
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CPAError {
            throw error
        } catch let error as CAPUsageError {
            throw error
        } catch {
            throw CAPUsageError.network
        }
        try Task.checkCancellation()
        guard response.statusCode != 404 else { throw CAPUsageError.pluginUnavailable }
        guard response.statusCode == 200 else {
            throw CAPUsageError.resourceRejected(statusCode: response.statusCode, retryAt: nil)
        }
        guard response.body.count <= 4_194_304 else { throw CAPUsageError.invalidResponse }
        return response.body
    }

    public func loadManagementStats(window: CAPUsageWindow) async throws -> CAPUsageStats {
        let base = server.endpoint("plugins/cap-token-usage-tracker/stats")
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw CAPUsageError.invalidResponse
        }
        let formatter = ISO8601DateFormatter()
        components.queryItems = [URLQueryItem(name: "range", value: "custom"),
                                 URLQueryItem(name: "start", value: formatter.string(from: window.start)),
                                 URLQueryItem(name: "end", value: formatter.string(from: window.end))]
        guard let url = components.url else { throw CAPUsageError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(managementKey.value)", forHTTPHeaderField: "Authorization")
        let transport = self.transport
        let clock = self.clock
        let immutableRequest = request
        let response: HTTPResponse
        do {
            response = try await coordinator.withPermit {
                let response = try await transport.send(immutableRequest)
                switch response.statusCode {
                case 401:
                    throw CPAError(.managementUnauthorized, layer: .management, statusCode: 401)
                case 403:
                    throw CPAError(.managementForbidden, layer: .management, statusCode: 403)
                case 429:
                    let retry = WireDate.retryAfter(response.header("Retry-After"), now: clock())
                    throw CPAError(.rateLimited, layer: .management, statusCode: 429, retryAfter: retry)
                default:
                    return response
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CPAError {
            throw error
        } catch let error as CAPUsageError {
            throw error
        } catch {
            throw CAPUsageError.network
        }
        try Task.checkCancellation()
        guard response.statusCode != 404 else { throw CAPUsageError.pluginUnavailable }
        guard response.statusCode == 200, response.body.count <= 4_194_304 else {
            throw CAPUsageError.invalidResponse
        }
        return try decode(CAPUsageStats.self, from: response.body)
    }
}
