import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import AnyLanguageModel
import HTTPTypes
import CPAQuotaKit

/// `ChatEngine` backed by AnyLanguageModel's OpenAI Chat Completions and Anthropic
/// Messages clients, with cross-provider reasoning effort mapping, zero-output
/// compatibility fallback, and session-scoped capability caching.
public struct AnyLanguageModelChatEngine: ChatEngine {
    // Budget for one protocol change, four explicit efforts, and a final request at the provider default.
    private static let maximumAttempts = 6
    private let transport: any AnyLanguageModel.HTTPTransport
    private let capabilityCache: ChatReasoningCapabilityCache

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

    init(
        transport: any AnyLanguageModel.HTTPTransport,
        capabilityCache: ChatReasoningCapabilityCache = ChatReasoningCapabilityCache()
    ) {
        self.transport = transport
        self.capabilityCache = capabilityCache
    }

    public func resetReasoningCapabilities() {
        capabilityCache.reset()
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
                    try await self.runStreamWithFallback(request, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func complete(_ request: ChatEngineRequest) async throws -> String {
        let serverKey = ChatReasoningPolicy.serverKey(for: request.baseURL)
        var plan = initialPlan(for: request, serverKey: serverKey)

        for attempt in 0..<Self.maximumAttempts {
            try Task.checkCancellation()
            do {
                let session = makeSession(for: request, plan: plan, live: nil)
                let response = try await session.respond(
                    to: makePrompt(for: request),
                    options: makeOptions(for: request, plan: plan, streaming: false)
                )
                return response.content
            } catch {
                guard let nextPlan = resolveFallback(
                    for: error, from: plan, serverKey: serverKey, modelID: request.modelID, attempt: attempt
                ) else {
                    throw error
                }
                plan = nextPlan
            }
        }
        preconditionFailure("Fallback loop must return or throw before exit")
    }

    private func runStreamWithFallback(
        _ request: ChatEngineRequest,
        continuation: AsyncThrowingStream<ChatEngineEvent, any Error>.Continuation
    ) async throws {
        let serverKey = ChatReasoningPolicy.serverKey(for: request.baseURL)
        var plan = initialPlan(for: request, serverKey: serverKey)
        var usedFallbackProtocol = false

        for attempt in 0..<Self.maximumAttempts {
            try Task.checkCancellation()
            let live = LiveChatSnapshots(continuation)
            do {
                let session = makeSession(for: request, plan: plan, live: live)
                let response = session.streamResponse(
                    to: makePrompt(for: request),
                    options: makeOptions(for: request, plan: plan, streaming: true)
                )
                for try await snapshot in response {
                    live.publish(text: snapshot.content,
                                 transcriptReasoning: Self.reasoningText(snapshot.transcriptEntries))
                    let usage = snapshot.usage
                    if usage.input.totalTokenCount > 0 || usage.output.totalTokenCount > 0
                        || usage.output.reasoningTokenCount > 0 {
                        live.markEmitted()
                        continuation.yield(.usage(ChatTokenUsage(
                            inputTokens: usage.input.totalTokenCount,
                            outputTokens: usage.output.totalTokenCount,
                            reasoningTokens: usage.output.reasoningTokenCount)))
                    }
                }
                continuation.yield(.reasoningResolution(plan.resolution(usedFallbackProtocol: usedFallbackProtocol)))
                return
            } catch {
                // Never retry after any output reached the caller: avoids duplicate billing or spliced text.
                guard !live.hasEmitted,
                      let nextPlan = resolveFallback(
                        for: error, from: plan, serverKey: serverKey, modelID: request.modelID, attempt: attempt
                      ) else {
                    throw error
                }
                if nextPlan.protocolKind != plan.protocolKind {
                    usedFallbackProtocol = true
                }
                plan = nextPlan
            }
        }
    }

    private func initialPlan(for request: ChatEngineRequest, serverKey: String) -> ChatReasoningWirePlan {
        ChatReasoningPolicy.makePlan(
            requested: request.reasoningEffort,
            protocolKind: ChatReasoningPolicy.initialProtocol(for: request, cache: capabilityCache),
            modelID: request.modelID,
            profile: capabilityCache.profile(for: serverKey, modelID: request.modelID)
        )
    }

    /// Updates capability cache for a zero-output rejection and returns the next plan
    /// when a strictly different retry plan is available; otherwise returns `nil`.
    private func resolveFallback(
        for error: any Error,
        from plan: ChatReasoningWirePlan,
        serverKey: String,
        modelID: String,
        attempt: Int
    ) -> ChatReasoningWirePlan? {
        guard attempt + 1 < Self.maximumAttempts,
              let rejection = ChatReasoningPolicy.classifyError(error, plan: plan) else {
            return nil
        }
        ChatReasoningPolicy.recordRejection(
            rejection,
            for: plan,
            server: serverKey,
            modelID: modelID,
            cache: capabilityCache
        )
        let nextProtocol: ChatAPIProtocol = rejection == .anthropicEndpointUnsupported
            ? .openAIChatCompletions
            : plan.protocolKind
        var nextProfile = capabilityCache.profile(for: serverKey, modelID: modelID)
        if attempt + 2 == Self.maximumAttempts {
            // Reserve the last attempt for the provider default without caching untested restrictions.
            nextProfile.reasoningUnsupported = true
        }
        let nextPlan = ChatReasoningPolicy.makePlan(
            requested: plan.requested,
            protocolKind: nextProtocol,
            modelID: modelID,
            profile: nextProfile
        )
        return nextPlan != plan ? nextPlan : nil
    }

    private func makeSession(
        for request: ChatEngineRequest,
        plan: ChatReasoningWirePlan,
        live: LiveChatSnapshots?
    ) -> LanguageModelSession {
        switch plan.protocolKind {
        case .anthropicMessages:
            let model = AnthropicLanguageModel(
                baseURL: ChatReasoningPolicy.anthropicBaseURL(from: request.baseURL),
                apiKey: request.apiKey.exposedValue,
                model: request.modelID,
                transport: CompletionCheckingTransport(base: transport, mode: .anthropicMessageStop, live: nil)
            )
            return LanguageModelSession(
                model: model,
                transcript: Self.makeTranscript(for: request, includeInstructions: false)
            )
        case .openAIChatCompletions:
            let model = OpenAILanguageModel(
                baseURL: request.baseURL,
                apiKey: request.apiKey.exposedValue,
                model: request.modelID,
                apiVariant: .chatCompletions,
                transport: CompletionCheckingTransport(base: transport, mode: .openAIDoneMarker, live: live)
            )
            return LanguageModelSession(
                model: model,
                transcript: Self.makeTranscript(for: request, includeInstructions: true)
            )
        case .openAIResponses:
            let model = OpenAILanguageModel(
                baseURL: request.baseURL,
                apiKey: request.apiKey.exposedValue,
                model: request.modelID,
                apiVariant: .responses,
                transport: CompletionCheckingTransport(base: transport, mode: .openAIDoneMarker, live: live)
            )
            return LanguageModelSession(
                model: model,
                transcript: Self.makeTranscript(for: request, includeInstructions: true)
            )
        }
    }

    private func makeOptions(
        for request: ChatEngineRequest,
        plan: ChatReasoningWirePlan,
        streaming: Bool
    ) -> GenerationOptions {
        var options = GenerationOptions()
        switch plan.protocolKind {
        case .openAIChatCompletions:
            var extraBody: [String: JSONValue] = [:]
            if streaming {
                // AnyLanguageModel 1.3.0 only requests usage automatically on OpenAI's own host.
                extraBody["stream_options"] = .object(["include_usage": .bool(true)])
            }
            if let wireEffort = plan.openAIWireEffort {
                // Use extraBody so levels beyond the SDK enum (`xhigh`, `max`) pass through cleanly.
                extraBody["reasoning_effort"] = .string(wireEffort)
            }
            if !extraBody.isEmpty {
                options[custom: OpenAILanguageModel.self] = .init(extraBody: extraBody)
            }

        case .openAIResponses:
            var extraBody: [String: JSONValue] = [:]
            if let reasoningObj = plan.openAIResponsesReasoningObject {
                extraBody["reasoning"] = .object(reasoningObj)
            }
            if !extraBody.isEmpty {
                options[custom: OpenAILanguageModel.self] = .init(extraBody: extraBody)
            }

        case .anthropicMessages:
            options.maximumResponseTokens = plan.anthropicMaxTokens ?? ChatReasoningPolicy.defaultAnthropicMaxTokens
            let thinking: AnthropicLanguageModel.CustomGenerationOptions.Thinking? = switch plan.anthropicStyle {
            case .adaptive:
                .adaptive()
            case .budget:
                plan.anthropicBudgetTokens.map { .enabled(budgetTokens: $0) }
            case nil:
                nil
            }
            let effort: AnthropicLanguageModel.CustomGenerationOptions.Effort? = plan.anthropicEffort.flatMap {
                AnthropicLanguageModel.CustomGenerationOptions.Effort(rawValue: $0)
            }
            var extraBody: [String: JSONValue] = [:]
            if !request.instructions.isEmpty {
                // Send system prompt as top-level `system` rather than an extra user turn.
                extraBody["system"] = .string(request.instructions)
            }
            if thinking != nil || effort != nil || !extraBody.isEmpty {
                options[custom: AnthropicLanguageModel.self] = .init(
                    thinking: thinking,
                    extraBody: extraBody.isEmpty ? nil : extraBody,
                    effort: effort
                )
            }
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

    static func makeTranscript(for request: ChatEngineRequest, includeInstructions: Bool = true) -> Transcript {
        var entries: [Transcript.Entry] = []
        if includeInstructions, !request.instructions.isEmpty {
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
        if error is IncompleteChatStream { return .streamInterrupted }
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

private enum StreamCompletionMode: Sendable {
    case openAIDoneMarker
    case anthropicMessageStop
}

/// AnyLanguageModel 1.3.0 treats EOF as success even if the upstream didn't finish the SSE stream.
private struct CompletionCheckingTransport: AnyLanguageModel.HTTPTransport {
    let base: any AnyLanguageModel.HTTPTransport
    let mode: StreamCompletionMode
    let live: LiveChatSnapshots?

    func send<Return>(request: HTTPRequest, body: Data?, timeout: Duration?,
                      responseHandler: (HTTPResponse, HTTPResponseBody) async throws -> Return) async throws -> Return {
        try await base.send(request: request, body: body, timeout: timeout) { response, chunks in
            guard request.headerFields[.accept] == "text/event-stream", response.status.kind == .successful else {
                return try await responseHandler(response, chunks)
            }
            return try await responseHandler(
                response,
                HTTPResponseBody(CompletionCheckedChunks(body: chunks, mode: mode, live: live))
            )
        }
    }
}

private struct IncompleteChatStream: Error {}

private struct CompletionCheckedChunks: AsyncSequence {
    let body: HTTPResponseBody
    let mode: StreamCompletionMode
    let live: LiveChatSnapshots?

    func makeAsyncIterator() -> Iterator { Iterator(upstream: body.makeAsyncIterator(), mode: mode, live: live) }

    struct Iterator: AsyncIteratorProtocol {
        var upstream: HTTPResponseBody.AsyncIterator
        let mode: StreamCompletionMode
        let live: LiveChatSnapshots?
        private var reasoningEvents = VisibleReasoningEvents()
        private var line = [UInt8]()
        private var exceedsMarkerLength = false
        private var sawCompletion = false

        init(upstream: HTTPResponseBody.AsyncIterator, mode: StreamCompletionMode, live: LiveChatSnapshots?) {
            self.upstream = upstream
            self.mode = mode
            self.live = live
        }

        mutating func next() async throws -> Data? {
            try Task.checkCancellation()
            if sawCompletion { return nil }
            guard let chunk = try await upstream.next() else {
                throw IncompleteChatStream()
            }
            // A marker can be split across network chunks. Keep only a bounded
            // line prefix so ordinary long JSON events need no extra buffering.
            for byte in chunk {
                switch byte {
                case 10, 13: // LF and CR (including CRLF)
                    if !exceedsMarkerLength {
                        let text = String(decoding: line, as: UTF8.self)
                        if isCompletionLine(text) {
                            sawCompletion = true
                        }
                    }
                    line.removeAll(keepingCapacity: true)
                    exceedsMarkerLength = false
                default:
                    if line.count < 96 { line.append(byte) }
                    else { exceedsMarkerLength = true }
                }
            }
            if let live { reasoningEvents.consume(chunk, into: live) }
            return chunk
        }

        private func isCompletionLine(_ text: String) -> Bool {
            switch mode {
            case .openAIDoneMarker:
                guard text.hasPrefix("data:") else { return false }
                return text.dropFirst(5).trimmingCharacters(in: .whitespaces) == "[DONE]"
            case .anthropicMessageStop:
                guard text.hasPrefix("data:") else { return false }
                let payload = text.dropFirst(5).trimmingCharacters(in: .whitespaces)
                return payload.contains("\"type\":\"message_stop\"") || payload.contains("\"type\": \"message_stop\"")
            }
        }
    }
}

/// Combines the SDK's cumulative answer with visible reasoning from the same request.
/// The transport and the SDK consume on different tasks; publish each pair under one lock.
private final class LiveChatSnapshots: @unchecked Sendable {
    private let lock = NSLock()
    private let output: AsyncThrowingStream<ChatEngineEvent, any Error>.Continuation
    private var text = ""
    private var reasoning = ""
    private var reasoningContent = ""
    private var emitted = false

    init(_ output: AsyncThrowingStream<ChatEngineEvent, any Error>.Continuation) {
        self.output = output
    }

    var hasEmitted: Bool {
        lock.withLock { emitted }
    }

    func markEmitted() {
        lock.withLock { emitted = true }
    }

    func append(_ delta: VisibleReasoningChunk.Choice.Delta) {
        guard delta.reasoning?.isEmpty == false || delta.reasoning_content?.isEmpty == false else { return }
        lock.withLock {
            reasoning += delta.reasoning ?? ""
            reasoningContent += delta.reasoning_content ?? ""
            emitted = true
            output.yield(.snapshot(text: text, reasoning: visibleReasoning))
        }
    }

    func publish(text: String, transcriptReasoning: String?) {
        lock.withLock {
            self.text = text
            let combinedReasoning = transcriptReasoning ?? visibleReasoning
            if !text.isEmpty || combinedReasoning?.isEmpty == false {
                emitted = true
            }
            output.yield(.snapshot(text: text, reasoning: combinedReasoning))
        }
    }

    private var visibleReasoning: String? {
        if !reasoningContent.isEmpty { return reasoningContent }
        return reasoning.isEmpty ? nil : reasoning
    }
}

/// Only these two text fields are displayable. Usage and the answer remain SDK-owned.
private struct VisibleReasoningChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let reasoning: String?
            let reasoning_content: String?
        }
        let delta: Delta
    }
    let id: String
    let choices: [Choice]
}

/// Reads complete SSE data events without consuming the SDK's body a second time.
private struct VisibleReasoningEvents {
    private var line = Data()
    private var data = Data()
    private var skipEvent = false
    private var skipLF = false
    private let prefix = Data("data:".utf8)

    mutating func consume(_ chunk: Data, into snapshots: LiveChatSnapshots) {
        for byte in chunk {
            if skipLF {
                skipLF = false
                if byte == 10 { continue }
            }
            if byte == 10 || byte == 13 {
                skipLF = byte == 13
                if line.isEmpty {
                    if !skipEvent, !data.isEmpty,
                       let event = try? JSONDecoder().decode(VisibleReasoningChunk.self, from: data),
                       let first = event.choices.first {
                        snapshots.append(first.delta)
                    }
                    data.removeAll(keepingCapacity: true)
                    skipEvent = false
                } else if !skipEvent, line.starts(with: prefix) {
                    var value = line.dropFirst(prefix.count)
                    if value.first == 32 { value = value.dropFirst() }
                    if !data.isEmpty { data.append(10) }
                    data.append(contentsOf: value)
                }
                line.removeAll(keepingCapacity: true)
            } else if line.count + data.count < 1024 * 1024 {
                line.append(byte)
            } else {
                // A large event still goes to the SDK, including its final transcript.
                skipEvent = true
                if line.isEmpty { line.append(byte) }
            }
        }
    }
}
