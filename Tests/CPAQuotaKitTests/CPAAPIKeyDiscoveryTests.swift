import Foundation
import Testing
@testable import CPAQuotaKit

@Suite("CPAAPIKeyDiscovery")
struct CPAAPIKeyDiscoveryTests {
    private let server = try! CPAServer(baseURL: "https://cpa.example.com")
    private let managementKey = try! ManagementKey("test-management-key-0001")
    private static let v0Path = "/v0/management/api-keys"
    private static let v8Path = "/v8/management/config/access/api-keys"

    private func makeDiscovery(_ transport: StubHTTPTransport) -> CPAAPIKeyDiscovery {
        CPAAPIKeyDiscovery(server: server, managementKey: managementKey, transport: transport,
                           coordinator: CPAManagementRequestCoordinator(), clock: { Date() })
    }

    @Test func v0SuccessParsesDeduplicatesAndDropsInvalid() async throws {
        let transport = StubHTTPTransport()
        await transport.respond(Self.v0Path, status: 200, body: """
            {"api-keys":["test-client-key-0001","  ","test-client-key-0001","test-client-key-0002"]}
            """)
        let keys = try await makeDiscovery(transport).keys()
        #expect(keys.map(\.exposedValue) == ["test-client-key-0001", "test-client-key-0002"])

        let request = await transport.requests().first
        #expect(request?.httpMethod == "GET")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer test-management-key-0001")
    }

    @Test func v0NullListReturnsEmpty() async throws {
        let transport = StubHTTPTransport()
        await transport.respond(Self.v0Path, status: 200, body: #"{"api-keys":null}"#)
        #expect(try await makeDiscovery(transport).keys() == [])
    }

    @Test func v0NotFoundFallsBackToV8WrappedObject() async throws {
        let transport = StubHTTPTransport()
        await transport.respond(Self.v0Path, status: 404)
        await transport.respond(Self.v8Path, status: 200,
                                body: #"{"api-keys":["test-client-key-0009"]}"#)
        let keys = try await makeDiscovery(transport).keys()
        #expect(keys.map(\.exposedValue) == ["test-client-key-0009"])
        let paths = await transport.requests().compactMap { $0.url?.path }
        #expect(paths == [Self.v0Path, Self.v8Path])
    }

    @Test func v0NotFoundFallsBackToV8BareArray() async throws {
        let transport = StubHTTPTransport()
        await transport.respond(Self.v0Path, status: 404)
        await transport.respond(Self.v8Path, status: 200,
                                body: #"["test-client-key-0008"]"#)
        #expect(try await makeDiscovery(transport).keys().map(\.exposedValue) == ["test-client-key-0008"])
    }

    @Test func bothNotFoundReturnsEmpty() async throws {
        let transport = StubHTTPTransport()
        await transport.respond(Self.v0Path, status: 404)
        await transport.respond(Self.v8Path, status: 404)
        #expect(try await makeDiscovery(transport).keys() == [])
    }

    @Test(arguments: [(401, CPAError.Kind.managementUnauthorized),
                      (403, CPAError.Kind.managementForbidden)])
    func v0AuthFailuresMapToManagementKinds(status: Int, kind: CPAError.Kind) async throws {
        let transport = StubHTTPTransport()
        await transport.respond(Self.v0Path, status: status)
        do {
            _ = try await makeDiscovery(transport).keys()
            Issue.record("expected throw")
        } catch let error as CPAError {
            #expect(error.kind == kind)
            #expect(error.layer == .management)
            #expect(error.statusCode == status)
        }
    }

    @Test func v0RateLimitedMapsWithRetryAfter() async throws {
        let transport = StubHTTPTransport()
        await transport.respond(Self.v0Path, status: 429, headers: ["Retry-After": "45"])
        do {
            _ = try await makeDiscovery(transport).keys()
            Issue.record("expected throw")
        } catch let error as CPAError {
            #expect(error.kind == .rateLimited)
            #expect(error.statusCode == 429)
            #expect(error.retryAfter != nil)
        }
    }

    @Test func v8AuthFailurePropagates() async throws {
        let transport = StubHTTPTransport()
        await transport.respond(Self.v0Path, status: 404)
        await transport.respond(Self.v8Path, status: 401)
        do {
            _ = try await makeDiscovery(transport).keys()
            Issue.record("expected throw")
        } catch let error as CPAError {
            #expect(error.kind == .managementUnauthorized)
        }
    }
}
