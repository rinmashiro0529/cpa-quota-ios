import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct HTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let timeout: TimeInterval
    private let maximumResponseBytes: Int
    private let protocolClasses: [AnyClass]?

    init(timeout: TimeInterval = 75,
         maximumResponseBytes: Int = 4_194_304,
         protocolClasses: [AnyClass]? = nil) {
        self.timeout = max(timeout, 0.1)
        self.maximumResponseBytes = max(maximumResponseBytes, 1)
        self.protocolClasses = protocolClasses
    }

    func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        return configuration
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let collector = ResponseCollector(maximumResponseBytes: maximumResponseBytes)
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: makeConfiguration(),
                                 delegate: collector,
                                 delegateQueue: delegateQueue)
        let task = session.dataTask(with: request)
        collector.attach(session: session, task: task)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResponse, any Error>) in
                collector.installAndResume(continuation)
            }
        } onCancel: {
            collector.cancel()
        }
    }
}

// Every mutable field below is guarded by `lock`, and the continuation is
// resumed at most once regardless of completion, cancellation, or size abort.
final class ResponseCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maximumResponseBytes: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HTTPResponse, any Error>?
    private var pendingOutcome: Result<HTTPResponse, any Error>?
    private var buffer = Data()
    private var response: HTTPURLResponse?
    private var session: URLSession?
    private var task: URLSessionTask?
    private var finished = false

    init(maximumResponseBytes: Int) {
        self.maximumResponseBytes = maximumResponseBytes
        super.init()
    }

    func attach(session: URLSession, task: URLSessionTask) {
        lock.lock()
        self.session = session
        self.task = task
        lock.unlock()
    }

    func installAndResume(_ continuation: CheckedContinuation<HTTPResponse, any Error>) {
        var task: URLSessionTask?

        lock.lock()
        if let outcome = pendingOutcome {
            pendingOutcome = nil
            lock.unlock()
            continuation.resume(with: outcome)
            return
        }
        if !finished {
            self.continuation = continuation
            task = self.task
        }
        lock.unlock()

        task?.resume()
    }

    func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
        finish(.failure(CancellationError()))
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let declared = Self.declaredLength(of: response)

        lock.lock()
        let done = finished
        if !done {
            self.response = http
        }
        lock.unlock()

        if done {
            completionHandler(.cancel)
            dataTask.cancel()
            return
        }
        if let declared, declared > Int64(maximumResponseBytes) {
            finish(.failure(CPAError(.responseTooLarge)))
            completionHandler(.cancel)
            dataTask.cancel()
            return
        }
        guard http != nil else {
            finish(.failure(CPAError(.invalidResponse)))
            completionHandler(.cancel)
            dataTask.cancel()
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        if data.count > maximumResponseBytes - buffer.count {
            lock.unlock()
            finish(.failure(CPAError(.responseTooLarge)))
            dataTask.cancel()
            return
        }
        buffer.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            finish(.failure(Self.sanitize(error)))
            return
        }

        lock.lock()
        let response = self.response
        let body = self.buffer
        lock.unlock()

        guard let response else {
            finish(.failure(CPAError(.invalidResponse)))
            return
        }
        if let declared = Self.declaredLength(of: response),
           declared > Int64(maximumResponseBytes) {
            finish(.failure(CPAError(.responseTooLarge)))
            return
        }
        finish(.success(HTTPResponse(statusCode: response.statusCode,
                                     headers: Self.headers(of: response),
                                     body: body)))
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    private func finish(_ result: Result<HTTPResponse, any Error>) {
        let continuation: CheckedContinuation<HTTPResponse, any Error>?
        let session: URLSession?

        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        continuation = self.continuation
        self.continuation = nil
        session = self.session
        self.session = nil
        self.task = nil
        self.response = nil
        buffer.removeAll(keepingCapacity: false)
        if continuation == nil {
            pendingOutcome = result
        }
        lock.unlock()

        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }

    private static func declaredLength(of response: URLResponse) -> Int64? {
        if let http = response as? HTTPURLResponse,
           let header = http.value(forHTTPHeaderField: "Content-Length"),
           let value = Int64(header.trimmingCharacters(in: .whitespaces)), value >= 0 {
            return value
        }
        let expected = response.expectedContentLength
        return expected >= 0 ? expected : nil
    }

    private static func headers(of response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let name = key as? String else { continue }
            result[name] = String(describing: value)
        }
        return result
    }

    private static func sanitize(_ error: any Error) -> any Error {
        if error is CancellationError { return CancellationError() }
        if let error = error as? CPAError { return error }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return CPAError(.network) }
        switch nsError.code {
        case NSURLErrorCancelled:
            return CancellationError()
        case NSURLErrorTimedOut:
            return CPAError(.timeout)
        case NSURLErrorBadURL, NSURLErrorUnsupportedURL,
             NSURLErrorBadServerResponse, NSURLErrorCannotParseResponse:
            return CPAError(.invalidResponse)
        default:
            return CPAError(.network)
        }
    }
}
