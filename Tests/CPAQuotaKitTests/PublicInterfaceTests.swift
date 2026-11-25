import Foundation
import Testing
import CPAQuotaKit

@Suite("Public frontend integration contract")
struct PublicInterfaceTests {
    @Test @MainActor
    func constructsFrontendStateAndCredentialFlowWithoutInternalAccess() async throws {
        let server = try CPAServer(baseURL: "https://cpa.example")
        let key = try ManagementKey("public-contract-fixture")
        let vault: any CredentialStore = MemoryCredentialStore()
        try await vault.save(key, for: server)
        let restored = try #require(try await vault.load(for: server))
        #expect(restored.description == "<redacted management key>")
        let client = CPAClient(server: server, managementKey: restored)
        let store = CPAQuotaStore(client: client)
        #expect(store.accounts.isEmpty)
        #expect(store.records.isEmpty)
        #expect(!store.isLoading)
        #expect(!store.isRefreshing)
        #expect(store.error == nil)
        await store.cancel()
        try await vault.remove(for: server)
        #expect(try await vault.load(for: server) == nil)
    }
}
