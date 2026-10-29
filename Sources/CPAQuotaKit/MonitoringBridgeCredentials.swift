import Foundation

public struct MonitorBridgeAddress: Sendable, Hashable {
    public let baseURL: URL

    public init(baseURL: URL) throws {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              !baseURL.absoluteString.contains("\\"),
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            throw MonitoringError.invalidConfiguration
        }
        components.scheme = "https"
        components.host = host.lowercased()
        if components.port == 443 { components.port = nil }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        guard !path.split(separator: "/").contains(where: {
            let decoded = String($0).removingPercentEncoding ?? String($0)
            return decoded == "." || decoded == ".." || decoded.contains("/") || decoded.contains("\\")
                || decoded.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }) else { throw MonitoringError.invalidConfiguration }
        components.percentEncodedPath = path
        guard let normalized = components.url else { throw MonitoringError.invalidConfiguration }
        self.baseURL = normalized
    }

    func credentialScope() throws -> CPAServer {
        try CPAServer(baseURL: baseURL.appendingPathComponent("__monitoring_credential_scope_v1"))
    }
}

public actor MonitoringBridgeCredentialStore {
    private let storage: any CredentialStore

    public init() {
        storage = KeychainCredentialStore(service: "CPAQuotaKit.MonitorBridgeCredentials")
    }

    public init(storage: any CredentialStore) { self.storage = storage }

    public func load(for address: MonitorBridgeAddress) async throws -> MonitorBridgeToken? {
        do {
            guard let key = try await storage.load(for: address.credentialScope()) else { return nil }
            return try MonitorBridgeToken(key.value)
        } catch {
            throw Self.storageFailure(error)
        }
    }

    public func save(_ token: MonitorBridgeToken, for address: MonitorBridgeAddress) async throws {
        do {
            try await storage.save(ManagementKey(token.value), for: address.credentialScope())
        } catch {
            throw Self.storageFailure(error)
        }
    }

    public func remove(for address: MonitorBridgeAddress) async throws {
        do {
            try await storage.remove(for: address.credentialScope())
        } catch {
            throw Self.storageFailure(error)
        }
    }

    private static func storageFailure(_ error: any Error) -> CPAError {
        if let error = error as? CPAError,
           error.kind == .secureStorageFailure || error.kind == .secureStorageUnavailable {
            return error
        }
        return CPAError(.secureStorageFailure)
    }
}
