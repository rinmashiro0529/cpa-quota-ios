import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import CPAQuotaKit

/// Path-keyed stub transport for catalog/discovery endpoints, simpler than
/// `ScenarioTransport` which is wired for quota flows.
actor StubHTTPTransport: HTTPTransport {
    struct Stub: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()
    }

    private var routes: [String: Stub] = [:]
    private var recordedRequests: [URLRequest] = []
    private var beforeResponse: (@Sendable () async -> Void)?

    func holdResponses(_ wait: @escaping @Sendable () async -> Void) {
        beforeResponse = wait
    }

    func respond(_ path: String, status: Int, body: String = "", headers: [String: String] = [:]) {
        routes[path] = Stub(status: status, headers: headers, body: Data(body.utf8))
    }

    func requests() -> [URLRequest] { recordedRequests }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        recordedRequests.append(request)
        await beforeResponse?()
        let path = request.url?.path ?? ""
        guard let stub = routes[path] else {
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        return HTTPResponse(statusCode: stub.status, headers: stub.headers, body: stub.body)
    }
}
