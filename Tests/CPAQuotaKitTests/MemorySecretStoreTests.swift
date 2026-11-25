import Foundation
import Testing
@testable import CPAQuotaKit

@Suite("MemorySecretStore")
struct MemorySecretStoreTests {
    @Test func saveLoadRemoveRoundTrip() async throws {
        let store = MemorySecretStore()
        #expect(try await store.loadSecret(account: "a") == nil)

        try await store.saveSecret("test-client-key-0001", account: "a")
        #expect(try await store.loadSecret(account: "a") == "test-client-key-0001")

        try await store.removeSecret(account: "a")
        #expect(try await store.loadSecret(account: "a") == nil)
    }

    @Test func accountsAreIndependent() async throws {
        let store = MemorySecretStore()
        try await store.saveSecret("key-a", account: "a")
        try await store.saveSecret("key-b", account: "b")

        try await store.removeSecret(account: "a")
        #expect(try await store.loadSecret(account: "a") == nil)
        #expect(try await store.loadSecret(account: "b") == "key-b")
    }

    @Test func overwriteKeepsLatest() async throws {
        let store = MemorySecretStore()
        try await store.saveSecret("first", account: "a")
        try await store.saveSecret("second", account: "a")
        #expect(try await store.loadSecret(account: "a") == "second")
    }

    @Test func removingMissingAccountIsHarmless() async throws {
        let store = MemorySecretStore()
        try await store.removeSecret(account: "missing")
    }
}
