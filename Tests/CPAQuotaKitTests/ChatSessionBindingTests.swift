import Foundation
import Testing
@testable import CPAQuotaKit
@testable import CPAQuotaChat
import CPAQuotaUI

@Suite("Chat binding follows the connection's remembered state")
@MainActor
struct ChatSessionBindingTests {
    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test func unrememberedConnectionNeitherUsesNorKeepsStoredClientKey() async throws {
        let server = try CPAServer(baseURL: "https://a.example")
        let secrets = MemorySecretStore()
        let account = ChatSecrets.clientAPIKeyAccount(for: server)
        try await secrets.saveSecret(#"{"v":1,"key":"test-client-key-0001","manual":true}"#, account: account)
        let chat = ChatWorkspaceModel(persistence: ChatMemoryPersistence(), secrets: secrets,
                                      modelCatalog: { _, _ in FakeModelCatalog(result: .success([])) })
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a")])
        let session = CPAQuotaSession(credentialStore: MemoryCredentialStore(),
                                      preferences: MemoryPreferencesStore(),
                                      clientFactory: { server, key in
                                          CPAClient(server: server, managementKey: key, transport: transport)
                                      },
                                      chatWorkspace: chat)

        await session.connect(serverAddress: "https://a.example", managementKeyInput: "fixture-key",
                              rememberInKeychain: false)
        let settled = await waitUntil { chat.server == server && chat.credentialState != .loading }
        #expect(settled)
        #expect(!chat.persistsKey)
        #expect(chat.credentialState != .ready(hint: "••••0001", isManual: true))
        #expect(try await secrets.loadSecret(account: account) == nil)

        await session.connect(serverAddress: "https://a.example", managementKeyInput: "fixture-key",
                              rememberInKeychain: true)
        let rebound = await waitUntil { chat.server == server && chat.persistsKey }
        #expect(rebound)
    }
}
