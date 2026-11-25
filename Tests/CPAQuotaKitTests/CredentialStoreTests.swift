import Foundation
import Testing
@testable import CPAQuotaKit

@Suite("CredentialStore")
struct CredentialStoreTests {
    @Test func memoryStoreRoundTripsUpdatesAndRemoves() async throws {
        let store = MemoryCredentialStore()
        let server = try CPAServer(baseURL: "https://cpa.example")

        let missing = try await store.load(for: server)
        #expect(missing == nil)

        try await store.save(try ManagementKey("first-key"), for: server)
        var loaded = try await store.load(for: server)
        #expect(loaded?.value == "first-key")

        try await store.save(try ManagementKey("second-key"), for: server)
        loaded = try await store.load(for: server)
        #expect(loaded?.value == "second-key")

        try await store.remove(for: server)
        loaded = try await store.load(for: server)
        #expect(loaded == nil)

        try await store.remove(for: server)
        loaded = try await store.load(for: server)
        #expect(loaded == nil)
    }

    @Test func memoryStoreIsolatesServers() async throws {
        let store = MemoryCredentialStore()
        let first = try CPAServer(baseURL: "https://a.example")
        let second = try CPAServer(baseURL: "https://b.example:8443")

        try await store.save(try ManagementKey("first-key"), for: first)
        try await store.save(try ManagementKey("second-key"), for: second)

        var loaded = try await store.load(for: first)
        #expect(loaded?.value == "first-key")
        loaded = try await store.load(for: second)
        #expect(loaded?.value == "second-key")

        try await store.remove(for: first)
        loaded = try await store.load(for: first)
        #expect(loaded == nil)
        loaded = try await store.load(for: second)
        #expect(loaded?.value == "second-key")
    }

    #if !canImport(Security)
    @Test func keychainStoreIsUnavailableWithoutSecurityFramework() async throws {
        let store = KeychainCredentialStore()
        let server = try CPAServer(baseURL: "https://cpa.example")
        let key = try ManagementKey("keychain-key")

        await expectSecureStorageUnavailable {
            _ = try await store.load(for: server)
        }
        await expectSecureStorageUnavailable {
            try await store.save(key, for: server)
        }
        await expectSecureStorageUnavailable {
            try await store.remove(for: server)
        }
    }
    #endif
}

#if !canImport(Security)
private func expectSecureStorageUnavailable(_ operation: () async throws -> Void) async {
    do {
        try await operation()
        Issue.record("expected secureStorageUnavailable")
    } catch let error as CPAError {
        #expect(error.kind == .secureStorageUnavailable)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}
#endif
