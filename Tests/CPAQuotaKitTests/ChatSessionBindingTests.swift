import Foundation
import Testing
@testable import CPAQuotaKit
@testable import CPAQuotaChat
import CPAQuotaUI

private actor FailingChatKeyRemovalStore: ChatSecretStore {
    private var stored: [String: String] = [:]
    private var removalFails = true

    func loadSecret(account: String) async throws -> String? { stored[account] }
    func saveSecret(_ value: String, account: String) async throws { stored[account] = value }
    func removeSecret(account: String) async throws {
        if removalFails { throw CPAError(.secureStorageFailure) }
        stored[account] = nil
    }
    func allowRemoval() { removalFails = false }
}

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

    @Test func forgetKeepsTheConnectionRememberedWhenTheChatKeyCannotBeRemoved() async throws {
        let server = try CPAServer(baseURL: "https://a.example")
        let secrets = FailingChatKeyRemovalStore()
        let credentials = MemoryCredentialStore()
        let chat = ChatWorkspaceModel(persistence: ChatMemoryPersistence(), secrets: secrets,
                                      modelCatalog: { _, _ in FakeModelCatalog(result: .success([])) })
        let transport = try ScenarioTransport(accounts: [FixtureAccount("a")])
        let session = CPAQuotaSession(credentialStore: credentials,
                                      preferences: MemoryPreferencesStore(),
                                      clientFactory: { server, key in
                                          CPAClient(server: server, managementKey: key, transport: transport)
                                      },
                                      chatWorkspace: chat)
        await session.connect(serverAddress: "https://a.example", managementKeyInput: "fixture-key",
                              rememberInKeychain: true)
        #expect(session.isRememberedInKeychain)

        await session.forgetCurrentConnection()
        // The management key is gone but the chat key is not: the session must stop
        // claiming a remembered connection, stay connected, and keep forget retryable.
        #expect(try await credentials.load(for: server) == nil)
        #expect(!session.isRememberedInKeychain)
        #expect(session.savedServer == nil)
        #expect(session.currentServer == server)
        #expect(session.authState == .connected(server: server, isRememberedInKeychain: false))
        let rebound = await waitUntil { chat.server == server && !chat.persistsKey && chat.keyRemovalFailed }
        #expect(rebound)

        await secrets.allowRemoval()
        await session.forgetCurrentConnection()
        #expect(session.authState == .unconfigured)
        #expect(try await secrets.loadSecret(account: ChatSecrets.clientAPIKeyAccount(for: server)) == nil)
    }
}
