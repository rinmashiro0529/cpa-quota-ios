import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct MonitorBridgeToken: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let value: String
    public init(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 4096,
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
            throw MonitoringError.invalidConfiguration
        }
        self.value = value
    }
    public var description: String { "<redacted bridge token>" }
    public var debugDescription: String { description }
}

public enum MonitoringError: Error, Sendable, Equatable {
    case invalidConfiguration, network, invalidResponse, unauthorized, forbidden, rateLimited, rejected, redirectRefused, conflict, notFound, capacityExceeded, serviceUnavailable
}

public actor CPAMonitorClient {
    private let baseURL: URL
    private let token: MonitorBridgeToken
    private let transport: any HTTPTransport
    private let clock: @Sendable () -> Date
    private var blocked: MonitoringError?
    private enum RequestLane: Hashable { case standard, refresh, cancellation, token }
    private var cooldowns: [RequestLane: Date] = [:]
    public var retryAt: Date? { cooldowns[.standard] }

    public init(baseURL: URL, token: MonitorBridgeToken) throws {
        self.baseURL = try Self.normalize(baseURL)
        self.token = token
        self.transport = URLSessionTransport()
        self.clock = { Date() }
    }

    init(baseURL: URL, token: MonitorBridgeToken, transport: any HTTPTransport,
         clock: @escaping @Sendable () -> Date = { Date() }) throws {
        self.baseURL = try Self.normalize(baseURL)
        self.token = token
        self.transport = transport
        self.clock = clock
    }

    private static func normalize(_ url: URL) throws -> URL {
        try MonitorBridgeAddress(baseURL: url).baseURL
    }

    private struct CreateBody: Encodable {
        let id: String; let source_id: String; let account_ids: [String]
        let duration_seconds: Int; let activity_id: String; let push_token: String
    }
    private struct TokenBody: Encodable { let push_token: String; let revision: UInt64 }

    public func create(_ registration: MonitoringRegistration) async throws -> MonitoringSession {
        let body = CreateBody(id: registration.id.uuidString.lowercased(), source_id: registration.sourceID,
                              account_ids: registration.accountIDs, duration_seconds: registration.duration.rawValue,
                              activity_id: registration.activityID, push_token: registration.pushToken.value)
        let data = try await perform("POST", path: ["v1", "monitoring", "sessions"], body: JSONEncoder().encode(body))
        let session = try decodeSession(data, id: registration.id)
        guard session.sourceID == registration.sourceID, session.accountIDs == registration.accountIDs,
              session.activityID == registration.activityID else { throw MonitoringError.invalidResponse }
        return session
    }

    public func get(id: UUID) async throws -> MonitoringSession {
        try decodeSession(await perform("GET", path: sessionPath(id)), id: id)
    }

    public func rotate(id: UUID, activityID: String, token: MonitoringPushToken, revision: UInt64) async throws -> MonitoringSession {
        guard revision < UInt64.max else { throw MonitoringError.invalidConfiguration }
        let body = try JSONEncoder().encode(TokenBody(push_token: token.value, revision: revision))
        let session = try decodeSession(await perform("PUT", path: sessionPath(id) + ["token"], body: body), id: id)
        guard session.activityID == activityID, session.revision == revision + 1 else { throw MonitoringError.invalidResponse }
        return session
    }

    public func refresh(id: UUID) async throws -> MonitoringSession {
        try decodeSession(await perform("POST", path: sessionPath(id) + ["refresh"]), id: id)
    }

    public func stop(id: UUID) async throws -> MonitoringSession? {
        let data = try await perform("DELETE", path: sessionPath(id), allowNoContent: true)
        if data.isEmpty { return nil }
        let session = try decodeSession(data, id: id)
        guard session.status != .active else { throw MonitoringError.invalidResponse }
        return session
    }

    public func cachedQuota(sourceID: String) async throws -> MonitoringSnapshot {
        guard MonitoringIdentifier.valid(sourceID) else { throw MonitoringError.invalidConfiguration }
        let data = try await perform("GET", path: ["v1", "sources", sourceID, "quota"])
        do { return try JSONDecoder().decode(MonitoringSnapshot.self, from: data) }
        catch { throw MonitoringError.invalidResponse }
    }

    public func capabilities() async throws -> MonitoringCapabilities {
        let data = try await perform("GET", path: ["v1", "capabilities"])
        do { return try JSONDecoder().decode(MonitoringCapabilities.self, from: data) }
        catch { throw MonitoringError.invalidResponse }
    }

    private func sessionPath(_ id: UUID) -> [String] { ["v1", "monitoring", "sessions", id.uuidString.lowercased()] }

    private func decodeSession(_ data: Data, id: UUID) throws -> MonitoringSession {
        do {
            let session = try JSONDecoder().decode(MonitoringSession.self, from: data)
            guard session.id == id else { throw MonitoringError.invalidResponse }
            return session
        } catch { throw MonitoringError.invalidResponse }
    }

    private func perform(_ method: String, path: [String], body: Data? = nil, allowNoContent: Bool = false) async throws -> Data {
        try Task.checkCancellation()
        if let blocked { throw blocked }
        let isRefresh = method == "POST" && path.last == "refresh"
        let lane: RequestLane = isRefresh ? .refresh : method == "DELETE" ? .cancellation
            : method == "PUT" && path.last == "token" ? .token : .standard
        // Honor each lane's own Retry-After without letting a refresh rejection
        // block reads, cancellation, or replacement of an expired push token.
        if let deadline = cooldowns[lane], deadline > clock() { throw MonitoringError.rateLimited }
        cooldowns[lane] = nil
        var url = baseURL
        for component in path { url.appendPathComponent(component) }
        var request = URLRequest(url: url, timeoutInterval: 75)
        request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let response: HTTPResponse
        do { response = try await transport.send(request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw MonitoringError.network }
        try Task.checkCancellation()
        guard response.body.count <= 4_194_304 else { throw MonitoringError.invalidResponse }
        switch response.statusCode {
        case 200, 201:
            guard !response.body.isEmpty else { throw MonitoringError.invalidResponse }
            return response.body
        case 202 where method == "POST" && path.last == "refresh":
            guard !response.body.isEmpty else { throw MonitoringError.invalidResponse }
            return response.body
        case 204 where allowNoContent:
            guard response.body.isEmpty else { throw MonitoringError.invalidResponse }
            return Data()
        case 300..<400: throw MonitoringError.redirectRefused
        case 401: blocked = .unauthorized; throw MonitoringError.unauthorized
        case 403: throw MonitoringError.forbidden
        case 404: throw MonitoringError.notFound
        case 409: throw MonitoringError.conflict
        case 507: throw MonitoringError.capacityExceeded
        case 500..<600: throw MonitoringError.serviceUnavailable
        case 429:
            let now = clock()
            let parsed = WireDate.retryAfter(response.header("Retry-After"), now: now)
            let deadline = max(parsed ?? now.addingTimeInterval(60), now.addingTimeInterval(1))
            cooldowns[lane] = deadline
            throw MonitoringError.rateLimited
        default: throw MonitoringError.rejected
        }
    }
}
