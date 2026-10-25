import Foundation
#if canImport(Security)
import Security
#endif

public protocol CredentialStore: Sendable {
    func load(for server: CPAServer) async throws -> ManagementKey?
    func save(_ key: ManagementKey, for server: CPAServer) async throws
    func remove(for server: CPAServer) async throws
}

public actor MemoryCredentialStore: CredentialStore {
    private var keys: [String: ManagementKey] = [:]

    public init() {}

    public func load(for server: CPAServer) async throws -> ManagementKey? {
        keys[server.identifier]
    }

    public func save(_ key: ManagementKey, for server: CPAServer) async throws {
        keys[server.identifier] = key
    }

    public func remove(for server: CPAServer) async throws {
        keys.removeValue(forKey: server.identifier)
    }
}

#if canImport(Security)
public actor KeychainCredentialStore: CredentialStore {
    private let service: String

    public init(service: String = "CPAQuotaKit.ManagementCredentials") {
        self.service = service
    }

    public func load(for server: CPAServer) async throws -> ManagementKey? {
        var query = baseQuery(for: server)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let text = String(data: data, encoding: .utf8),
                  let key = try? ManagementKey(text) else {
                throw CPAError(.secureStorageFailure)
            }
            return key
        case errSecItemNotFound:
            return nil
        default:
            throw CPAError(.secureStorageFailure, statusCode: Int(status))
        }
    }

    public func save(_ key: ManagementKey, for server: CPAServer) async throws {
        let data = Data(key.value.utf8)
        let query = baseQuery(for: server)

        let updateStatus = SecItemUpdate(query as CFDictionary,
                                         updateAttributes(for: data) as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            let addStatus = SecItemAdd(addAttributes(for: server, data: data) as CFDictionary, nil)
            switch addStatus {
            case errSecSuccess:
                return
            case errSecDuplicateItem:
                // Another store instance created the item after our lookup; retry the update once.
                let retryStatus = SecItemUpdate(query as CFDictionary,
                                                updateAttributes(for: data) as CFDictionary)
                guard retryStatus == errSecSuccess else {
                    throw CPAError(.secureStorageFailure, statusCode: Int(retryStatus))
                }
            default:
                throw CPAError(.secureStorageFailure, statusCode: Int(addStatus))
            }
        default:
            throw CPAError(.secureStorageFailure, statusCode: Int(updateStatus))
        }
    }

    public func remove(for server: CPAServer) async throws {
        let status = SecItemDelete(baseQuery(for: server) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CPAError(.secureStorageFailure, statusCode: Int(status))
        }
    }

    private func baseQuery(for server: CPAServer) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: server.identifier
        ]
    }

    private func updateAttributes(for data: Data) -> [String: Any] {
        [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
    }

    private func addAttributes(for server: CPAServer, data: Data) -> [String: Any] {
        // Synchronizable defaults to false; omit it so it never combines with ThisDeviceOnly.
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: server.identifier,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
    }
}
#else
// No Security framework: refuse secure storage instead of falling back to plaintext.
public actor KeychainCredentialStore: CredentialStore {
    private let service: String

    public init(service: String = "CPAQuotaKit.ManagementCredentials") {
        self.service = service
    }

    public func load(for server: CPAServer) async throws -> ManagementKey? {
        throw CPAError(.secureStorageUnavailable)
    }

    public func save(_ key: ManagementKey, for server: CPAServer) async throws {
        throw CPAError(.secureStorageUnavailable)
    }

    public func remove(for server: CPAServer) async throws {
        throw CPAError(.secureStorageUnavailable)
    }
}
#endif
