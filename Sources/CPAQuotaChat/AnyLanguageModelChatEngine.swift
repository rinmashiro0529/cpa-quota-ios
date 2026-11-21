import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import AnyLanguageModel
import HTTPTypes
import CPAQuotaKit

/// `ChatEngine` on AnyLanguageModel's `OpenAILanguageModel` in Chat Completions
/// mode against `{baseURL}chat/completions`. Each request builds a fresh
/// `LanguageModelSession` from the request's transcript.
public struct AnyLanguageModelChatEngine: ChatEngine {
    private let transport: CompletionCheckingTransport

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        // A redirect would forward the bearer key to a foreign host; refuse it.
        self.init(transport: URLSession(configuration: configuration,
                                       delegate: RedirectRefusingDelegate(), delegateQueue: nil))
    }

    init(transport: any AnyLanguageModel.HTTPTransport) {
        self.transport = CompletionCheckingTransport(base: transport)
    }

    private final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    public func stream(_ request: ChatEngineRequest) -> AsyncThrowingStream<ChatEngineEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = makeSession(for: request)
                    let response = session.streamResponse(to: makePrompt(for: request),
                                                          options: makeOptions(for: request, streaming: true))
                    for try await snapshot in response {
                        continuation.yield(.snapshot(text: snapshot.content,
                                                     reasoning: Self.reasoningText(snapshot.transcriptEntries)))
                        let usage = snapshot.usage
                        if usage.input.totalTokenCount > 0 || usage.output.totalTokenCount > 0
                            || usage.output.reasoningTokenCount > 0 {
                            continuation.yield(.usage(ChatTokenUsage(
                                inputTokens: usage.input.totalTokenCount,
                                outputTokens: usage.output.totalTokenCount,
                                reasoningTokens: usage.output.reasoningTokenCount)))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func complete(_ request: ChatEngineRequest) async throws -> String {
        let session = makeSession(for: request)
        let response = try await session.respond(to: makePrompt(for: request),
                                                 options: makeOptions(for: request))
        return response.content
    }

    private func makeSession(for request: ChatEngineRequest) -> LanguageModelSession {
        let model = OpenAILanguageModel(
            baseURL: request.baseURL,
            apiKey: request.apiKey.exposedValue,
            model: request.modelID,
            apiVariant: .chatCompletions,
            transport: transport)
        return LanguageModelSession(model: model, transcript: Self.makeTranscript(for: request))
    }

    private func makeOptions(for request: ChatEngineRequest, streaming: Bool = false) -> GenerationOptions {
        var options = GenerationOptions()
        let effort: OpenAILanguageModel.CustomGenerationOptions.ReasoningEffort? = switch request.reasoningEffort {
        case .automatic: nil
        case .low: .low
        case .medium: .medium
        case .high: .high
        }
        if streaming || effort != nil {
            // AnyLanguageModel 1.3.0 only requests usage automatically on OpenAI's own host.
            options[custom: OpenAILanguageModel.self] = .init(
                reasoningEffort: effort,
                extraBody: streaming ? ["stream_options": .object(["include_usage": .bool(true)])] : nil)
        }
        return options
    }

    private func makePrompt(for request: ChatEngineRequest) -> Prompt {
        Prompt {
            request.prompt
            request.images.compactMap { attachment in
                URL(string: "data:\(attachment.mimeType);base64,\(attachment.data.base64EncodedString())")
                    .map { Attachment<ImageAttachmentContent>(imageURL: $0) }
            }
        }
    }

    static func makeTranscript(for request: ChatEngineRequest) -> Transcript {
        var entries: [Transcript.Entry] = []
        if !request.instructions.isEmpty {
            entries.append(.instructions(Transcript.Instructions(
                segments: [.text(Transcript.TextSegment(content: request.instructions))],
                toolDefinitions: [])))
        }
        for message in request.history {
            switch message.role {
            case .user:
                var segments: [Transcript.Segment] = [
                    .text(Transcript.TextSegment(content: message.text))
                ]
                for attachment in message.attachments {
                    segments.append(.image(Transcript.ImageSegment(
                        data: attachment.data, mimeType: attachment.mimeType)))
                }
                entries.append(.prompt(Transcript.Prompt(segments: segments)))
            case .assistant:
                entries.append(.response(Transcript.Response(
                    assetIDs: [],
                    segments: [.text(Transcript.TextSegment(content: message.text))])))
            }
        }
        return Transcript(entries: entries)
    }

    static func reasoningText(_ entries: ArraySlice<Transcript.Entry>) -> String? {
        let text = entries.compactMap { entry -> String? in
            guard case .reasoning(let reasoning) = entry else { return nil }
            return reasoning.segments.compactMap { segment -> String? in
                guard case .text(let text) = segment else { return nil }
                return text.content
            }.joined()
        }.joined()
        return text.isEmpty ? nil : text
    }

    /// Maps engine-side failures to `ChatFailure`; `nil` means cancellation.
    public static func failure(for error: any Error) -> ChatFailure? {
        if error is CancellationError { return nil }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: return nil
            case .timedOut: return .timeout
            default: return .network
            }
        }
        if let error = error as? HTTPTransportError {
            switch error.kind {
            case .httpError, .providerError:
                return httpFailure(status: error.response?.status.code,
                                   retryAfter: error.response?.headerFields[.retryAfter])
            case .decodingError, .invalidRequest, .invalidResponse:
                return .invalidResponse
            default:
                return .invalidResponse
            }
        }
        if error is OpenAILanguageModelError { return .invalidResponse }
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .rateLimited(_): return .rateLimited(retryAfter: nil)
            default: return .invalidResponse
            }
        }
        if error is DecodingError { return .invalidResponse }
        return .network
    }

    static func httpFailure(status: Int?, retryAfter: String?) -> ChatFailure {
        let code = status ?? 0
        switch code {
        case 401: return .unauthorized(statusCode: code)
        case 403: return .forbidden(statusCode: code)
        case 404: return .modelUnavailable(statusCode: code)
        case 429: return .rateLimited(retryAfter: WireDate.retryAfter(retryAfter, now: Date()))
        default: return .upstream(statusCode: code)
        }
    }
}

/// AnyLanguageModel 1.3.0 treats EOF as success even if CPA didn't finish the SSE stream.
private struct CompletionCheckingTransport: AnyLanguageModel.HTTPTransport {
    let base: any AnyLanguageModel.HTTPTransport

    func send<Return>(request: HTTPRequest, body: Data?, timeout: Duration?,
                      responseHandler: (HTTPResponse, HTTPResponseBody) async throws -> Return) async throws -> Return {
        try await base.send(request: request, body: body, timeout: timeout) { response, chunks in
            guard request.headerFields[.accept] == "text/event-stream", response.status.kind == .successful else {
                return try await responseHandler(response, chunks)
            }
            return try await responseHandler(response, HTTPResponseBody(CompletionCheckedChunks(body: chunks)))
        }
    }
}

private struct CompletionCheckedChunks: AsyncSequence {
    let body: HTTPResponseBody

    func makeAsyncIterator() -> Iterator { Iterator(upstream: body.makeAsyncIterator()) }

    struct Iterator: AsyncIteratorProtocol {
        var upstream: HTTPResponseBody.AsyncIterator
        private var line = [UInt8]()
        private var exceedsMarkerLength = false
        private var sawCompletion = false

        init(upstream: HTTPResponseBody.AsyncIterator) { self.upstream = upstream }

        mutating func next() async throws -> Data? {
            try Task.checkCancellation()
            if sawCompletion { return nil }
            guard let chunk = try await upstream.next() else {
                throw HTTPTransportError(kind: .decodingError)
            }
            // A marker can be split across network chunks. Keep only a bounded
            // line prefix so ordinary long JSON events need no extra buffering.
            for byte in chunk {
                switch byte {
                case 10, 13: // LF and CR (including CRLF)
                    if !exceedsMarkerLength {
                        let text = String(decoding: line, as: UTF8.self)
                        if text.hasPrefix("data:"),
                           text.dropFirst(5).trimmingCharacters(in: .whitespaces) == "[DONE]" {
                            sawCompletion = true
                        }
                    }
                    line.removeAll(keepingCapacity: true)
                    exceedsMarkerLength = false
                default:
                    if line.count < 64 { line.append(byte) }
                    else { exceedsMarkerLength = true }
                }
            }
            return chunk
        }
    }
}
