import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CPAQuotaKit

private enum StubFailure: Sendable {
    case urlError(code: Int)
    case unknown(domain: String, code: Int, message: String)

    var error: any Error {
        switch self {
        case let .urlError(code):
            return NSError(domain: NSURLErrorDomain, code: code, userInfo: nil)
        case let .unknown(domain, code, message):
            return NSError(domain: domain, code: code,
                           userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}

private enum StubScenario: Sendable {
    case respond(status: Int, headers: [String: String], body: Data)
    case stream(status: Int, headers: [String: String], chunks: [Data])
    case fail(StubFailure)
    case hang
}

private final class StubState: @unchecked Sendable {
    private let lock = NSLock()
    private var scenario: StubScenario = .respond(status: 200, headers: [:], body: Data())
    private var requests: [URLRequest] = []

    func setScenario(_ scenario: StubScenario) {
        lock.lock()
        self.scenario = scenario
        lock.unlock()
    }

    func currentScenario() -> StubScenario {
        lock.lock()
        defer { lock.unlock() }
        return scenario
    }

    func record(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    func lastRequest() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return requests.last
    }

    func reset() {
        lock.lock()
        scenario = .respond(status: 200, headers: [:], body: Data())
        requests.removeAll()
        lock.unlock()
    }
}

private final class StubURLProtocol: URLProtocol {
    private static let state = StubState()

    static func setScenario(_ scenario: StubScenario) { state.setScenario(scenario) }
    static func reset() { state.reset() }
    static func lastRequest() -> URLRequest? { state.lastRequest() }

    private let stopLock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.state.record(request)
        switch Self.state.currentScenario() {
        case let .respond(status, headers, body):
            guard deliver(status: status, headers: headers) else { return }
            if !body.isEmpty {
                client?.urlProtocol(self, didLoad: body)
            }
            client?.urlProtocolDidFinishLoading(self)
        case let .stream(status, headers, chunks):
            guard deliver(status: status, headers: headers) else { return }
            for chunk in chunks {
                if isStopped { return }
                client?.urlProtocol(self, didLoad: chunk)
            }
            client?.urlProtocolDidFinishLoading(self)
        case let .fail(failure):
            client?.urlProtocol(self, didFailWithError: failure.error)
        case .hang:
            break
        }
    }

    override func stopLoading() {
        stopLock.lock()
        stopped = true
        stopLock.unlock()
    }

    private var isStopped: Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopped
    }

    private func deliver(status: Int, headers: [String: String]) -> Bool {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url,
                                             statusCode: status,
                                             httpVersion: "HTTP/1.1",
                                             headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return false
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        return true
    }
}

private final class RedirectCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var called = false
    private var redirected: URLRequest?

    func record(_ request: URLRequest?) {
        lock.lock()
        called = true
        redirected = request
        lock.unlock()
    }

    func snapshot() -> (called: Bool, redirected: URLRequest?) {
        lock.lock()
        defer { lock.unlock() }
        return (called, redirected)
    }
}

@Suite(.serialized)
struct HTTPTransportTests {
    private func makeTransport(maximumResponseBytes: Int = 4096) -> URLSessionTransport {
        let protocolClasses: [AnyClass] = [StubURLProtocol.self]
        return URLSessionTransport(timeout: 5,
                                   maximumResponseBytes: maximumResponseBytes,
                                   protocolClasses: protocolClasses)
    }

    private func makeRequest() -> URLRequest {
        var request = URLRequest(url: URL(string: "https://cpa.example/v0/management/quota/fetch")!)
        request.httpMethod = "GET"
        request.setValue("Bearer test-key", forHTTPHeaderField: "Authorization")
        return request
    }

    @Test func returnsStatusHeadersAndBody() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.setScenario(.respond(status: 200,
                                             headers: ["Content-Type": "application/json", "X-Trace": "abc"],
                                             body: Data("{\"ok\":true}".utf8)))

        let response = try await makeTransport().send(makeRequest())

        #expect(response.statusCode == 200)
        #expect(response.body == Data("{\"ok\":true}".utf8))
        #expect(response.header("content-type") == "application/json")
        #expect(response.header("x-TRACE") == "abc")
        #expect(response.header("missing") == nil)
        #expect(StubURLProtocol.lastRequest()?.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    }

    @Test func configurationDisablesSharedCookiesAndCaches() {
        let configuration = makeTransport().makeConfiguration()

        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test func doesNotSendSharedCookies() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.setScenario(.respond(status: 200, headers: [:], body: Data()))

        let cookie = HTTPCookie(properties: [
            .domain: "cpa.example",
            .path: "/",
            .name: "session",
            .value: "shared-secret",
            .secure: "TRUE"
        ])
        if let cookie {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
        defer {
            HTTPCookieStorage.shared.cookies?
                .filter { $0.name == "session" && $0.domain == "cpa.example" }
                .forEach { HTTPCookieStorage.shared.deleteCookie($0) }
        }

        _ = try await makeTransport().send(makeRequest())

        #expect(StubURLProtocol.lastRequest()?.value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test func rejectsOversizedDeclaredContentLength() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.setScenario(.respond(status: 200,
                                             headers: ["Content-Length": "8192"],
                                             body: Data()))

        do {
            _ = try await makeTransport(maximumResponseBytes: 1024).send(makeRequest())
            Issue.record("expected responseTooLarge")
        } catch let error as CPAError {
            #expect(error.kind == .responseTooLarge)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func rejectsBodyThatExceedsLimitWhileStreaming() async throws {
        StubURLProtocol.reset()
        let chunks = (0..<4).map { _ in Data(repeating: 0x41, count: 400) }
        StubURLProtocol.setScenario(.stream(status: 200, headers: [:], chunks: chunks))

        do {
            _ = try await makeTransport(maximumResponseBytes: 1000).send(makeRequest())
            Issue.record("expected responseTooLarge")
        } catch let error as CPAError {
            #expect(error.kind == .responseTooLarge)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func mapsTimedOutTransportErrorToTimeout() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.setScenario(.fail(.urlError(code: URLError.Code.timedOut.rawValue)))

        do {
            _ = try await makeTransport().send(makeRequest())
            Issue.record("expected timeout")
        } catch let error as CPAError {
            #expect(error.kind == .timeout)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func mapsConnectionFailureToNetwork() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.setScenario(.fail(.urlError(code: URLError.Code.cannotConnectToHost.rawValue)))

        do {
            _ = try await makeTransport().send(makeRequest())
            Issue.record("expected network failure")
        } catch let error as CPAError {
            #expect(error.kind == .network)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func mapsCancelledTransportErrorToCancellation() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.setScenario(.fail(.urlError(code: URLError.Code.cancelled.rawValue)))

        do {
            _ = try await makeTransport().send(makeRequest())
            Issue.record("expected cancellation")
        } catch is CancellationError {
            // expected
        } catch let error as CPAError {
            #expect(error.kind == .cancelled)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func unknownErrorsDoNotLeakTheirDescription() async throws {
        StubURLProtocol.reset()
        let secret = "Bearer SECRET-TOKEN-123 https://cpa.example/v0/management?token=SECRET-TOKEN-123"
        StubURLProtocol.setScenario(.fail(.unknown(domain: "CPAQuotaKitTests.Sensitive",
                                                   code: 42,
                                                   message: secret)))

        do {
            _ = try await makeTransport().send(makeRequest())
            Issue.record("expected network failure")
        } catch let error as CPAError {
            #expect(error.kind == .network)
            #expect(error.statusCode == nil)
            let description = String(describing: error)
            #expect(description.contains("SECRET-TOKEN-123") == false)
            #expect(description.contains("cpa.example") == false)
            #expect(error.errorDescription?.contains("SECRET-TOKEN-123") == false)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func preCancelledTaskEndsAsCancellation() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.setScenario(.hang)
        let transport = makeTransport()
        let request = makeRequest()

        let attempt = Task<HTTPResponse, any Error> {
            withUnsafeCurrentTask { task in
                if let task { task.cancel() }
            }
            return try await transport.send(request)
        }

        do {
            _ = try await attempt.value
            Issue.record("expected cancellation")
        } catch is CancellationError {
            // expected
        } catch let error as CPAError {
            #expect(error.kind == .cancelled)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func cancellationSurfacesAsCancellation() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.setScenario(.hang)
        let request = makeRequest()
        let transport = makeTransport()

        let task = Task { try await transport.send(request) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch is CancellationError {
            // expected
        } catch let error as CPAError {
            #expect(error.kind == .cancelled)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func redirectHandlerRefusesToFollow() throws {
        let collector = ResponseCollector(maximumResponseBytes: 1024)
        let session = URLSession(configuration: .ephemeral, delegate: collector, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let url = URL(string: "https://cpa.example/v0/management/quota/fetch")!
        let task = session.dataTask(with: url)
        let response = HTTPURLResponse(url: url,
                                       statusCode: 302,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Location": "https://attacker.example/"])!
        let redirectRequest = URLRequest(url: URL(string: "https://attacker.example/")!)
        let capture = RedirectCapture()

        collector.urlSession(session,
                             task: task,
                             willPerformHTTPRedirection: response,
                             newRequest: redirectRequest) { request in
            capture.record(request)
        }

        let snapshot = capture.snapshot()
        #expect(snapshot.called)
        #expect(snapshot.redirected == nil)
    }
}
