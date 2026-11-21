import Foundation
import Testing
@testable import CPAQuotaKit

@Suite("CPAModelCatalogClient")
struct CPAModelCatalogClientTests {
    private let server = try! CPAServer(baseURL: "https://cpa.example.com")
    private let key = CPAClientAPIKey("test-client-key-0001")!

    private func makeClient(_ transport: StubHTTPTransport) -> CPAModelCatalogClient {
        CPAModelCatalogClient(server: server, apiKey: key, transport: transport)
    }

    @Test func parsesDeduplicatesAndSortsModels() async throws {
        let transport = StubHTTPTransport()
        await transport.respond("/v1/models", status: 200, body: """
            {"data":[
                {"id":"beta-model","owned_by":"provider-b"},
                {"id":"alpha-model","owned_by":"provider-a"},
                {"id":"beta-model","owned_by":"provider-b"},
                {"id":"  "},
                {"name":"no-id-entry"}
            ]}
            """)
        let models = try await makeClient(transport).models()
        #expect(models.map(\.id) == ["alpha-model", "beta-model"])
        #expect(models[1].ownedBy == "provider-b")
    }

    @Test func sendsBearerClientKey() async throws {
        let transport = StubHTTPTransport()
        await transport.respond("/v1/models", status: 200, body: #"{"data":[]}"#)
        _ = try await makeClient(transport).models()
        let request = await transport.requests().first
        #expect(request?.httpMethod == "GET")
        #expect(request?.url?.absoluteString == "https://cpa.example.com/v1/models")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer test-client-key-0001")
    }

    @Test(arguments: [401, 403])
    func unauthorizedStatusesMapToRequestRejected(status: Int) async throws {
        let transport = StubHTTPTransport()
        await transport.respond("/v1/models", status: status)
        do {
            _ = try await makeClient(transport).models()
            Issue.record("expected throw")
        } catch let error as CPAError {
            #expect(error.kind == .requestRejected)
            #expect(error.statusCode == status)
            #expect(error.layer == nil)
        }
    }

    @Test func notFoundMapsToEndpointUnavailable() async throws {
        let transport = StubHTTPTransport()
        await transport.respond("/v1/models", status: 404)
        do {
            _ = try await makeClient(transport).models()
            Issue.record("expected throw")
        } catch let error as CPAError {
            #expect(error.kind == .endpointUnavailable)
            #expect(error.statusCode == 404)
        }
    }

    @Test func rateLimitedCarriesRetryAfter() async throws {
        let transport = StubHTTPTransport()
        await transport.respond("/v1/models", status: 429, headers: ["Retry-After": "30"])
        do {
            _ = try await makeClient(transport).models()
            Issue.record("expected throw")
        } catch let error as CPAError {
            #expect(error.kind == .rateLimited)
            #expect(error.statusCode == 429)
            #expect(error.retryAfter != nil)
        }
    }

    @Test func otherStatusesMapToRequestRejected() async throws {
        let transport = StubHTTPTransport()
        await transport.respond("/v1/models", status: 502)
        do {
            _ = try await makeClient(transport).models()
            Issue.record("expected throw")
        } catch let error as CPAError {
            #expect(error.kind == .requestRejected)
            #expect(error.statusCode == 502)
        }
    }

    @Test func redirectIsRefused() async throws {
        let transport = StubHTTPTransport()
        await transport.respond("/v1/models", status: 302)
        do {
            _ = try await makeClient(transport).models()
            Issue.record("expected throw")
        } catch let error as CPAError {
            #expect(error.kind == .redirectRefused)
        }
    }

    @Test func malformedBodyIsInvalidResponse() async throws {
        let transport = StubHTTPTransport()
        await transport.respond("/v1/models", status: 200, body: "not json")
        do {
            _ = try await makeClient(transport).models()
            Issue.record("expected throw")
        } catch let error as CPAError {
            #expect(error.kind == .invalidResponse)
        }
    }
}
