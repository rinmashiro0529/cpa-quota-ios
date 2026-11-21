import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import AnyLanguageModel
import CPAQuotaKit

/// `ChatEngine` on AnyLanguageModel's `OpenAILanguageModel` in Chat Completions
/// mode against `{baseURL}chat/completions`. Each request builds a fresh
/// `LanguageModelSession` from the request's transcript.
public struct AnyLanguageModelChatEngine: ChatEngine {
    private let transport: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        // A redirect would forward the bearer key to a foreign host; refuse it.
        transport = URLSession(configuration: configuration,
                               delegate: RedirectRefusingDelegate(), delegateQueue: nil)
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
                                                          options: makeOptions(for: request))
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

    private func makeOptions(for request: ChatEngineRequest) -> GenerationOptions {
        var options = GenerationOptions()
        switch request.reasoningEffort {
        case .automatic:
            break
        case .low, .medium, .high:
            let effort: OpenAILanguageModel.CustomGenerationOptions.ReasoningEffort =
                switch request.reasoningEffort {
                case .low: .low
                case .medium: .medium
                case .high: .high
                case .automatic: .low // unreachable
                }
            options[custom: OpenAILanguageModel.self] = .init(reasoningEffort: effort)
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
        case 429: return .rateLimited(retryAfter: parseRetryAfter(retryAfter))
        default: return .upstream(statusCode: code)
        }
    }

    private static func parseRetryAfter(_ value: String?) -> Date? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        if let seconds = Double(trimmed), seconds.isFinite, seconds >= 0 {
            return Date().addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: trimmed)
    }
}
