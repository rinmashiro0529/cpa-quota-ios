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

/// An opaque local identity accompanies the token in the same protected value.
/// It identifies this credential, not a principal asserted by the remote server.
public struct MonitoringBridgeCredential: Sendable {
    public let bindingID: UUID
    public let address: MonitorBridgeAddress
    public let token: MonitorBridgeToken

    public func matches(_ token: MonitorBridgeToken) -> Bool { self.token.value == token.value }
}

public actor MonitoringBridgeCredentialStore {
    private let storage: any CredentialStore
    private var isReadingOrWriting = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private struct Record: Codable {
        let schemaVersion: Int
        let bindingID: UUID
        let token: String
    }
    // The internal space distinguishes this from any valid legacy bridge token.
    private static let recordPrefix = "CPAQuotaBridgeCredentialRecord "

    public init() {
        storage = KeychainCredentialStore(service: "CPAQuotaKit.MonitorBridgeCredentials")
    }

    public init(storage: any CredentialStore) { self.storage = storage }

    public func load(for address: MonitorBridgeAddress) async throws -> MonitorBridgeToken? {
        await acquire()
        defer { release() }
        do {
            return try await read(address)?.token
        } catch {
            throw Self.storageFailure(error)
        }
    }

    public func save(_ token: MonitorBridgeToken, for address: MonitorBridgeAddress) async throws {
        _ = try await bind(token, for: address, remember: true)
    }

    /// Legacy plain tokens are upgraded only after a single protected write succeeds.
    public func loadCredential(for address: MonitorBridgeAddress) async throws -> MonitoringBridgeCredential? {
        await acquire()
        defer { release() }
        do {
            try Task.checkCancellation()
            guard let value = try await read(address) else { return nil }
            let credential = MonitoringBridgeCredential(bindingID: value.bindingID ?? UUID(), address: address, token: value.token)
            if value.bindingID == nil { try await write(credential) }
            return credential
        } catch {
            throw Self.storageFailure(error)
        }
    }

    /// Token and identity are committed atomically. A new token always gets a new identity.
    public func bind(_ token: MonitorBridgeToken, for address: MonitorBridgeAddress,
                     remember: Bool, previous: MonitoringBridgeCredential? = nil) async throws -> MonitoringBridgeCredential {
        await acquire()
        defer { release() }
        do {
            try Task.checkCancellation()
            let existing = try await read(address)
            let binding: UUID
            if let existing, existing.token.value == token.value, let id = existing.bindingID {
                binding = id
            } else if let previous, previous.address == address, previous.matches(token) {
                binding = previous.bindingID
            } else {
                binding = UUID()
            }
            let credential = MonitoringBridgeCredential(bindingID: binding, address: address, token: token)
            try Task.checkCancellation()
            if remember {
                try await write(credential)
            } else {
                try await storage.remove(for: address.credentialScope())
            }
            return credential
        } catch {
            throw Self.storageFailure(error)
        }
    }

    public func remove(for address: MonitorBridgeAddress) async throws {
        await acquire()
        defer { release() }
        do {
            try await storage.remove(for: address.credentialScope())
        } catch {
            throw Self.storageFailure(error)
        }
    }

    private func read(_ address: MonitorBridgeAddress) async throws -> (token: MonitorBridgeToken, bindingID: UUID?)? {
        let scope = try address.credentialScope()
        let data: Data?
        if let records = storage as? any CredentialRecordStore {
            data = try await records.loadRecord(for: scope)
        } else {
            data = try await storage.load(for: scope).map { Data($0.value.utf8) }
        }
        guard let data else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { throw CPAError(.secureStorageFailure) }
        if text.hasPrefix(Self.recordPrefix) {
            let payload = Data(text.dropFirst(Self.recordPrefix.count).utf8)
            let record = try JSONDecoder().decode(Record.self, from: payload)
            guard record.schemaVersion == 1 else { throw CPAError(.secureStorageFailure) }
            return (try MonitorBridgeToken(record.token), record.bindingID)
        }
        return (try MonitorBridgeToken(text), nil)
    }

    private func write(_ credential: MonitoringBridgeCredential) async throws {
        let record = Record(schemaVersion: 1, bindingID: credential.bindingID, token: credential.token.value)
        var data = Data(Self.recordPrefix.utf8)
        data.append(try JSONEncoder().encode(record))
        let scope = try credential.address.credentialScope()
        if let records = storage as? any CredentialRecordStore {
            try await records.saveRecord(data, for: scope)
        } else {
            // Compatibility for existing injected CredentialStore implementations.
            // Production Keychain and Memory stores use the bounded raw-record path.
            guard let text = String(data: data, encoding: .utf8) else { throw CPAError(.secureStorageFailure) }
            try await storage.save(ManagementKey(text), for: scope)
        }
    }

    private func acquire() async {
        if isReadingOrWriting {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            isReadingOrWriting = true
        }
    }

    private func release() {
        if waiters.isEmpty { isReadingOrWriting = false }
        else { waiters.removeFirst().resume() }
    }

    private static func storageFailure(_ error: any Error) -> CPAError {
        if let error = error as? CPAError,
           error.kind == .secureStorageFailure || error.kind == .secureStorageUnavailable {
            return error
        }
        return CPAError(.secureStorageFailure)
    }
}
