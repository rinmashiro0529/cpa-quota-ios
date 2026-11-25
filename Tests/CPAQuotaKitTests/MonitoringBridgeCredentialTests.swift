import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CPAQuotaKit

@Suite("Monitoring bridge credentials")
struct MonitoringBridgeCredentialTests {
    @Test func savedCredentialAuthenticatesItsBridge() async throws {
        let store = MonitoringBridgeCredentialStore(storage: MemoryCredentialStore())
        let address = try MonitorBridgeAddress(baseURL: #require(URL(string: "https://bridge.invalid/prefix")))
        let token = try MonitorBridgeToken(String(repeating: "t", count: 32))
        try await store.save(token, for: address)
        let loaded = try #require(await store.load(for: address))
        let transport = BridgeCredentialHTTPFixture()
        let client = try CPAMonitorClient(baseURL: address.baseURL, token: loaded, transport: transport)
        _ = try await client.cachedQuota(sourceID: "personal")
        #expect(await transport.authorization() == "Bearer " + String(repeating: "t", count: 32))
    }

    @Test func bridgePathsRemainSeparateIncludingManagementSuffix() async throws {
        let store = MonitoringBridgeCredentialStore(storage: MemoryCredentialStore())
        let first = try MonitorBridgeAddress(baseURL: #require(URL(string: "https://BRIDGE.invalid:443/prefix/")))
        let same = try MonitorBridgeAddress(baseURL: #require(URL(string: "https://bridge.invalid/prefix")))
        let second = try MonitorBridgeAddress(baseURL: #require(URL(string: "https://bridge.invalid/prefix/v0/management")))
        #expect(first == same)
        try await store.save(MonitorBridgeToken(String(repeating: "a", count: 32)), for: first)
        try await store.save(MonitorBridgeToken(String(repeating: "b", count: 32)), for: second)
        #expect(try await header(from: store, for: same) == "Bearer " + String(repeating: "a", count: 32))
        #expect(try await header(from: store, for: second) == "Bearer " + String(repeating: "b", count: 32))
        try await store.remove(for: first)
        #expect(try await store.load(for: same) == nil)
        #expect(try await header(from: store, for: second) == "Bearer " + String(repeating: "b", count: 32))
        try await store.remove(for: first)
    }

    @Test func bridgeCredentialDoesNotReplaceManagementCredential() async throws {
        let underlying = MemoryCredentialStore()
        let address = try MonitorBridgeAddress(baseURL: #require(URL(string: "https://bridge.invalid")))
        let server = try CPAServer(baseURL: address.baseURL)
        try await underlying.save(ManagementKey("existing-management-fixture"), for: server)
        let store = MonitoringBridgeCredentialStore(storage: underlying)
        try await store.save(MonitorBridgeToken(String(repeating: "t", count: 32)), for: address)
        let old = try #require(await underlying.load(for: server))
        let transport = BridgeCredentialHTTPFixture()
        let client = CPAClient(server: server, managementKey: old, transport: transport)
        _ = try await client.loadAccounts()
        #expect(await transport.authorization() == "Bearer existing-management-fixture")
        #expect(try await header(from: store, for: address) == "Bearer " + String(repeating: "t", count: 32))
    }

    @Test func failedSaveAndRemovePreserveLastCredentialAndReportSafeFailure() async throws {
        let underlying = BridgeCredentialFailureFixture()
        let store = MonitoringBridgeCredentialStore(storage: underlying)
        let address = try MonitorBridgeAddress(baseURL: #require(URL(string: "https://bridge.invalid")))
        try await store.save(MonitorBridgeToken(String(repeating: "a", count: 32)), for: address)
        await underlying.setFailing(true)
        do {
            try await store.save(MonitorBridgeToken(String(repeating: "b", count: 32)), for: address)
            Issue.record("Expected storage failure")
        } catch let error as CPAError {
            #expect(error.kind == .secureStorageFailure)
            #expect(!String(describing: error).contains("sensitive-fixture"))
        }
        do {
            try await store.remove(for: address)
            Issue.record("Expected removal failure")
        } catch let error as CPAError {
            #expect(error.kind == .secureStorageFailure)
        }
        #expect(try await header(from: store, for: address) == "Bearer " + String(repeating: "a", count: 32))
    }

    @Test func unsafeBridgeAddressIsRejectedBeforeCredentialAccess() throws {
        for text in ["http://bridge.invalid", "https://user:pass@bridge.invalid", "https://bridge.invalid/?key=x", "https://bridge.invalid/#fragment", "https://bridge.invalid/a/%2f/b", "https://bridge.invalid/a/%00/b"] {
            #expect(throws: MonitoringError.invalidConfiguration) {
                _ = try MonitorBridgeAddress(baseURL: #require(URL(string: text)))
            }
        }
    }

    #if !canImport(Security)
    @Test func defaultStoreNeverFallsBackToPlaintextWithoutKeychain() async throws {
        let store = MonitoringBridgeCredentialStore()
        let address = try MonitorBridgeAddress(baseURL: #require(URL(string: "https://bridge.invalid")))
        do {
            _ = try await store.load(for: address)
            Issue.record("Expected unavailable secure storage")
        } catch let error as CPAError {
            #expect(error.kind == .secureStorageUnavailable)
        }
    }
    #endif

    private func header(from store: MonitoringBridgeCredentialStore, for address: MonitorBridgeAddress) async throws -> String? {
        let token = try #require(await store.load(for: address))
        let transport = BridgeCredentialHTTPFixture()
        let client = try CPAMonitorClient(baseURL: address.baseURL, token: token, transport: transport)
        _ = try await client.cachedQuota(sourceID: "personal")
        return await transport.authorization()
    }
}

private actor BridgeCredentialHTTPFixture: HTTPTransport {
    private var captured: String?

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        captured = request.value(forHTTPHeaderField: "Authorization")
        if request.url?.path.hasSuffix("/auth-files") == true {
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"files":[]}"#.utf8))
        }
        if request.url?.path.hasSuffix("/quota/providers") == true {
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"providers":[]}"#.utf8))
        }
        let body = #"{"version":1,"sequence":1,"phase":"ready","generated_at":1800000001,"expires_at":1800000900,"accounts":[{"id":"account-1","label":"账号1","provider":"codex","window_id":"primary","window_label":"5小时","remaining_fraction":0.42,"observed_at":1800000000,"status":"ok"}]}"#
        return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
    }

    func authorization() -> String? { captured }
}

private actor BridgeCredentialFailureFixture: CredentialStore {
    private let memory = MemoryCredentialStore()
    private var failing = false
    private struct Failure: Error, CustomStringConvertible {
        var description: String { "sensitive-fixture" }
    }

    func setFailing(_ value: Bool) { failing = value }
    func load(for server: CPAServer) async throws -> ManagementKey? { try await memory.load(for: server) }
    func save(_ key: ManagementKey, for server: CPAServer) async throws {
        if failing { throw Failure() }
        try await memory.save(key, for: server)
    }
    func remove(for server: CPAServer) async throws {
        if failing { throw Failure() }
        try await memory.remove(for: server)
    }
}
