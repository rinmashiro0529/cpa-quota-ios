import Foundation
#if canImport(Security)
import Security
#endif

/// Stores arbitrary chat credentials (client API keys, search provider keys)
/// under caller-chosen account names. Values are opaque secrets to the store.
public protocol ChatSecretStore: Sendable {
    func loadSecret(account: String) async throws -> String?
    func saveSecret(_ value: String, account: String) async throws
    func removeSecret(account: String) async throws
}

public actor MemorySecretStore: ChatSecretStore {
    private var secrets: [String: String] = [:]

    public init() {}

    public func loadSecret(account: String) async throws -> String? {
        secrets[account]
    }

    public func saveSecret(_ value: String, account: String) async throws {
        secrets[account] = value
    }

    public func removeSecret(account: String) async throws {
        secrets.removeValue(forKey: account)
    }
}

#if canImport(Security)
public actor KeychainSecretStore: ChatSecretStore {
    private let service: String

    public init(service: String = "CPAQuotaKit.ChatCredentials") {
        self.service = service
    }

    public func loadSecret(account: String) async throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, data.count <= 16_384,
                  let text = String(data: data, encoding: .utf8) else {
                throw CPAError(.secureStorageFailure)
            }
            return text
        case errSecItemNotFound:
            return nil
        default:
            throw CPAError(.secureStorageFailure, statusCode: Int(status))
        }
    }

    public func saveSecret(_ value: String, account: String) async throws {
        let data = Data(value.utf8)
        guard data.count <= 16_384 else { throw CPAError(.secureStorageFailure) }
        let query = baseQuery(account: account)

        let updateStatus = SecItemUpdate(query as CFDictionary,
                                         updateAttributes(for: data) as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            let addStatus = SecItemAdd(addAttributes(for: account, data: data) as CFDictionary, nil)
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

    public func removeSecret(account: String) async throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CPAError(.secureStorageFailure, statusCode: Int(status))
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func updateAttributes(for data: Data) -> [String: Any] {
        [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
    }

    private func addAttributes(for account: String, data: Data) -> [String: Any] {
        // Synchronizable defaults to false; omit it so it never combines with ThisDeviceOnly.
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
    }
}
#else
// No Security framework: refuse secure storage instead of falling back to plaintext.
public actor KeychainSecretStore: ChatSecretStore {
    private let service: String

    public init(service: String = "CPAQuotaKit.ChatCredentials") {
        self.service = service
    }

    public func loadSecret(account: String) async throws -> String? {
        throw CPAError(.secureStorageUnavailable)
    }

    public func saveSecret(_ value: String, account: String) async throws {
        throw CPAError(.secureStorageUnavailable)
    }

    public func removeSecret(account: String) async throws {
        throw CPAError(.secureStorageUnavailable)
    }
}
#endif
