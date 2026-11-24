import Foundation
import Testing
import AnyLanguageModel
import HTTPTypes
@testable import CPAQuotaChat
@testable import CPAQuotaKit

private final class ScriptedReasoningTransport: AnyLanguageModel.HTTPTransport, @unchecked Sendable {
    struct Step: Sendable {
        var status: HTTPTypes.HTTPResponse.Status = .ok
        var headers: HTTPFields = [:]
        var chunks: [String]
    }

    struct RecordedRequest: Sendable {
        let path: String
        let accept: String?
        let hasAnthropicAPIKey: Bool
        let bodyData: Data?

        var bodyJSON: [String: Any]? {
            bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var recorded: [RecordedRequest] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    func send<Return>(
        request: HTTPRequest,
        body: Data?,
        timeout: Duration?,
        responseHandler: (HTTPTypes.HTTPResponse, HTTPResponseBody) async throws -> Return
    ) async throws -> Return {
        let step: Step = lock.withLock {
            recorded.append(RecordedRequest(
                path: request.path ?? "",
                accept: request.headerFields[.accept],
                hasAnthropicAPIKey: request.headerFields[HTTPField.Name("x-api-key")!] != nil,
                bodyData: body
            ))
            return steps.isEmpty ? Step(status: .internalServerError, chunks: []) : steps.removeFirst()
        }
        let stream = AsyncStream<Data> { continuation in
            for chunk in step.chunks {
                continuation.yield(Data(chunk.utf8))
            }
            continuation.finish()
        }
        return try await responseHandler(.init(status: step.status, headerFields: step.headers), HTTPResponseBody(stream))
    }

    func snapshot() -> [RecordedRequest] {
        lock.withLock { recorded }
    }
}

private final class ReasoningStubEngine: ChatEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _streamRequests: [ChatEngineRequest] = []
    private var _completeRequests: [ChatEngineRequest] = []
    private var _resetCount = 0
    private var _events: [ChatEngineEvent] = [.snapshot(text: "回复", reasoning: nil)]

    var streamRequests: [ChatEngineRequest] { lock.withLock { _streamRequests } }
    var completeRequests: [ChatEngineRequest] { lock.withLock { _completeRequests } }
    var resetCount: Int { lock.withLock { _resetCount } }
    var events: [ChatEngineEvent] {
        get { lock.withLock { _events } }
        set { lock.withLock { _events = newValue } }
    }

    func stream(_ request: ChatEngineRequest) -> AsyncThrowingStream<ChatEngineEvent, any Error> {
        let events: [ChatEngineEvent] = lock.withLock {
            _streamRequests.append(request)
            return _events
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    func complete(_ request: ChatEngineRequest) async throws -> String {
        lock.withLock { _completeRequests.append(request) }
        return "简短标题"
    }

    func resetReasoningCapabilities() {
        lock.withLock { _resetCount += 1 }
    }
}

private actor FailingSettingsLoadPersistence: ChatPersistence {
    private let base = ChatMemoryPersistence()
    func loadConversations() async throws -> [ChatConversation] { try await base.loadConversations() }
    func saveConversation(_ conversation: ChatConversation) async throws { try await base.saveConversation(conversation) }
    func removeConversation(_ id: UUID) async throws { try await base.removeConversation(id) }
    func removeAllConversations() async throws { try await base.removeAllConversations() }
    func loadSettings() async throws -> ChatSettings? { throw ChatPersistenceError.storageFailure }
    func saveSettings(_ settings: ChatSettings) async throws { try await base.saveSettings(settings) }
    func loadMemories() async throws -> [ChatMemoryItem]? { nil }
    func saveMemories(_ items: [ChatMemoryItem]) async throws {}
    func loadSkills() async throws -> [ChatSkill]? { nil }
    func saveSkills(_ skills: [ChatSkill]) async throws {}
}

private struct ReasoningStubCatalog: ChatModelCatalog {
    let items: [CPAModel]
    func models() async throws -> [CPAModel] { items }
}

@Suite("Cross-provider reasoning compatibility")
struct ChatReasoningCompatibilityTests {
    private let openAISSEToken = #"{"id":"c1","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"content":"ok"}}]}"#

    private var openAISuccessChunks: [String] {
        ["data: \(openAISSEToken)\n\n", "data: [DONE]\n\n"]
    }

    private var anthropicSuccessChunks: [String] {
        [
            "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"claude-opus-4-6\",\"usage\":{\"input_tokens\":10,\"output_tokens\":1}}}\n\n",
            "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}\n\n",
            "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"先分析\"}}\n\n",
            "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n",
            "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n",
            "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"结论\"}}\n\n",
            "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n",
            "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":12}}\n\n",
            "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
        ]
    }

    private func makeRequest(
        modelID: String,
        ownedBy: String? = nil,
        effort: ChatReasoningEffort,
        instructions: String = "",
        baseURL: String = "https://cpa.example.invalid/v1"
    ) throws -> ChatEngineRequest {
        try ChatEngineRequest(
            baseURL: #require(URL(string: baseURL)),
            apiKey: #require(CPAClientAPIKey("test-client-key-0001")),
            modelID: modelID,
            modelOwnedBy: ownedBy,
            instructions: instructions,
            prompt: "Hi",
            reasoningEffort: effort
        )
    }

    // MARK: - Persistence & Model Classification

    @Test func reasoningEffortPreservesLegacyCodableAndExplicitOrder() throws {
        #expect(ChatReasoningEffort.explicitLevels == [.off, .low, .medium, .high, .xhigh, .max])
        let legacyJSON = #"["automatic","low","medium","high"]"#
        let decoded = try JSONDecoder().decode([ChatReasoningEffort].self, from: Data(legacyJSON.utf8))
        #expect(decoded == [.automatic, .low, .medium, .high])

        let legacySettingsJSON = #"{"globalInstructions":"hi","isMemoryEnabled":true,"notifiesOnBackgroundCompletion":true,"generatesTitles":true}"#
        let settings = try JSONDecoder().decode(ChatSettings.self, from: Data(legacySettingsJSON.utf8))
        #expect(settings.recentReasoningEfforts == nil)

        let encodedAll = try JSONEncoder().encode(ChatReasoningEffort.allCases)
        let roundTrip = try JSONDecoder().decode([ChatReasoningEffort].self, from: encodedAll)
        #expect(roundTrip == ChatReasoningEffort.allCases)
    }

    @Test func protocolAndAnthropicGenerationClassification() throws {
        #expect(ChatReasoningPolicy.anthropicBaseURL(from: try #require(URL(string: "https://a.test/v1"))).absoluteString == "https://a.test/")
        #expect(ChatReasoningPolicy.anthropicBaseURL(from: try #require(URL(string: "https://a.test/proxy/v1/"))).absoluteString == "https://a.test/proxy")
        // SEC-01: preserve percent-encoded path segments byte-for-byte.
        #expect(ChatReasoningPolicy.anthropicBaseURL(from: try #require(URL(string: "https://a.test/tenant%3Aa/v1"))).absoluteString == "https://a.test/tenant%3Aa")

        #expect(ChatReasoningPolicy.isAnthropicModel(modelID: "claude-opus-4-6", ownedBy: nil))
        #expect(ChatReasoningPolicy.isAnthropicModel(modelID: "anthropic/claude-sonnet-4-5", ownedBy: nil))
        #expect(ChatReasoningPolicy.isAnthropicModel(modelID: "custom-alias", ownedBy: "anthropic"))
        #expect(!ChatReasoningPolicy.isAnthropicModel(modelID: "gpt-5.4", ownedBy: "openai"))
        #expect(!ChatReasoningPolicy.isAnthropicModel(modelID: "gemini-2.5-pro", ownedBy: "google"))

        #expect(ChatReasoningPolicy.initialAnthropicStyle(for: "claude-opus-4-6") == .adaptive)
        #expect(ChatReasoningPolicy.initialAnthropicStyle(for: "claude-opus-4-6-20260101") == .adaptive)
        #expect(ChatReasoningPolicy.initialAnthropicStyle(for: "claude-opus-4-7") == .adaptive)
        #expect(ChatReasoningPolicy.initialAnthropicStyle(for: "claude-sonnet-5") == .adaptive)
        #expect(ChatReasoningPolicy.initialAnthropicStyle(for: "claude-sonnet-4-5") == .budget)
        #expect(ChatReasoningPolicy.initialAnthropicStyle(for: "claude-sonnet-4-5-20250929") == .budget)
        // EFF-09: 8-digit release dates must not be misparsed as minor versions.
        #expect(ChatReasoningPolicy.initialAnthropicStyle(for: "claude-sonnet-4-20250514") == .budget)
        #expect(ChatReasoningPolicy.initialAnthropicStyle(for: "claude-opus-4-20250514") == .budget)
        #expect(ChatReasoningPolicy.initialAnthropicStyle(for: "claude-3-7-sonnet-20250219") == .budget)
    }

    @Test func openAIResponsesPlanEncodesReasoningObject() {
        let plan = ChatReasoningPolicy.makePlan(
            requested: .xhigh,
            protocolKind: .openAIResponses,
            modelID: "gpt-5.4",
            profile: .init()
        )
        #expect(plan.openAIWireEffort == "xhigh")
        #expect(plan.openAIResponsesReasoningObject == ["effort": .string("xhigh")])
    }

    // MARK: - OpenAI Chat Completions Mapping & 400 Self-Healing

    @Test func openAISendsExpectedWireEffortAcrossAllLevels() async throws {
        let cases: [(ChatReasoningEffort, String?)] = [
            (.automatic, nil),
            (.off, "none"),
            (.low, "low"),
            (.medium, "medium"),
            (.high, "high"),
            (.xhigh, "xhigh"),
            (.max, "max"),
        ]
        for (effort, expectedWire) in cases {
            let transport = ScriptedReasoningTransport(steps: [.init(chunks: openAISuccessChunks)])
            let engine = AnyLanguageModelChatEngine(transport: transport)
            let req = try makeRequest(modelID: "gpt-5.4", ownedBy: "openai", effort: effort)
            var resolution: ChatReasoningResolution?
            for try await event in engine.stream(req) {
                if case .reasoningResolution(let res) = event { resolution = res }
            }
            let sent = try #require(transport.snapshot().first)
            #expect(sent.path.hasSuffix("/v1/chat/completions"))
            #expect(sent.bodyJSON?["reasoning_effort"] as? String == expectedWire)
            #expect(resolution?.outcome == .applied)
        }
    }

    @Test func openAINonReasoningModelStripsParameterAndCachesResult() async throws {
        let reject400 = #"{"error":{"message":"Unrecognized request argument supplied: reasoning_effort","type":"invalid_request_error","param":"reasoning_effort"}}"#
        let transport = ScriptedReasoningTransport(steps: [
            .init(status: .badRequest, chunks: [reject400]),
            .init(chunks: openAISuccessChunks),
            .init(chunks: openAISuccessChunks),
        ])
        let engine = AnyLanguageModelChatEngine(transport: transport)
        let req = try makeRequest(modelID: "gpt-4o-mini", ownedBy: "openai", effort: .max)

        var firstResolution: ChatReasoningResolution?
        for try await event in engine.stream(req) {
            if case .reasoningResolution(let res) = event { firstResolution = res }
        }
        #expect(firstResolution == ChatReasoningResolution(requested: .max, applied: nil, outcome: .omitted))

        var secondResolution: ChatReasoningResolution?
        for try await event in engine.stream(req) {
            if case .reasoningResolution(let res) = event { secondResolution = res }
        }
        #expect(secondResolution == ChatReasoningResolution(requested: .max, applied: nil, outcome: .omitted))

        let recorded = transport.snapshot()
        #expect(recorded.count == 3) // turn 1: max -> 400 -> omitted; turn 2: omitted directly from cache
        #expect(recorded[0].bodyJSON?["reasoning_effort"] as? String == "max")
        #expect(recorded[1].bodyJSON?["reasoning_effort"] == nil)
        #expect(recorded[2].bodyJSON?["reasoning_effort"] == nil)
    }

    @Test func openAIEffortOutOfRangeParsesAllowedValuesAndStepsDownInOneRetry() async throws {
        let reject400 = #"{"error":{"message":"Invalid value: 'max'. Supported values are: 'low', 'medium', and 'high'.","param":"reasoning_effort","code":"invalid_reasoning_effort"}}"#
        let transport = ScriptedReasoningTransport(steps: [
            .init(status: .badRequest, chunks: [reject400]),
            .init(chunks: openAISuccessChunks),
            .init(chunks: openAISuccessChunks),
        ])
        let engine = AnyLanguageModelChatEngine(transport: transport)
        let req = try makeRequest(modelID: "o3-mini", ownedBy: "openai", effort: .max)

        var firstResolution: ChatReasoningResolution?
        for try await event in engine.stream(req) {
            if case .reasoningResolution(let res) = event { firstResolution = res }
        }
        #expect(firstResolution == ChatReasoningResolution(requested: .max, applied: .high, outcome: .downgraded))

        // Second turn should go straight to "high" with zero 400 roundtrip.
        for try await _ in engine.stream(req) {}
        let recorded = transport.snapshot()
        #expect(recorded.count == 3)
        #expect(recorded[0].bodyJSON?["reasoning_effort"] as? String == "max")
        #expect(recorded[1].bodyJSON?["reasoning_effort"] as? String == "high")
        #expect(recorded[2].bodyJSON?["reasoning_effort"] as? String == "high")
    }

    @Test func openAIOffRejectedByForcedReasoningModelWalksLadderAndFallsBackToOmit() async throws {
        let rejectNone = #"{"error":{"message":"Unsupported value: 'none' is not supported for reasoning_effort on this model.","param":"reasoning_effort"}}"#
        let rejectMinimal = #"{"error":{"message":"Unsupported value: 'minimal' is not supported for reasoning_effort on this model.","param":"reasoning_effort"}}"#
        let rejectLow = #"{"error":{"message":"Unsupported value: 'low' is not supported for reasoning_effort on this model.","param":"reasoning_effort"}}"#
        let transport = ScriptedReasoningTransport(steps: [
            .init(status: .badRequest, chunks: [rejectNone]),
            .init(status: .badRequest, chunks: [rejectMinimal]),
            .init(status: .badRequest, chunks: [rejectLow]),
            .init(chunks: openAISuccessChunks),
        ])
        let engine = AnyLanguageModelChatEngine(transport: transport)
        let req = try makeRequest(modelID: "o3", ownedBy: "openai", effort: .off)

        var resolution: ChatReasoningResolution?
        for try await event in engine.stream(req) {
            if case .reasoningResolution(let res) = event { resolution = res }
        }
        #expect(resolution == ChatReasoningResolution(requested: .off, applied: nil, outcome: .omitted))
        let recorded = transport.snapshot()
        #expect(recorded.map { $0.bodyJSON?["reasoning_effort"] as? String } == ["none", "minimal", "low", nil])
    }

    @Test func openAIOffDowngradesToLowestAllowedEffortInOneRetry() async throws {
        let reject400 = #"{"error":{"message":"Invalid value: 'none'. Supported values are: 'low', 'medium', and 'high'.","param":"reasoning_effort"}}"#
        let transport = ScriptedReasoningTransport(steps: [
            .init(status: .badRequest, chunks: [reject400]),
            .init(chunks: openAISuccessChunks),
        ])
        let engine = AnyLanguageModelChatEngine(transport: transport)
        let req = try makeRequest(modelID: "o3", ownedBy: "openai", effort: .off)

        var resolution: ChatReasoningResolution?
        for try await event in engine.stream(req) {
            if case .reasoningResolution(let res) = event { resolution = res }
        }
        #expect(resolution == ChatReasoningResolution(requested: .off, applied: .low, outcome: .downgraded))
        let recorded = transport.snapshot()
        #expect(recorded.map { $0.bodyJSON?["reasoning_effort"] as? String } == ["none", "low"])
    }

    @Test func openAIMaxDowngradesToLowWhenOnlyLowIsAllowed() async throws {
        let reject400 = #"{"error":{"message":"Invalid value: 'max'. Supported values are: 'low'.","param":"reasoning_effort"}}"#
        let transport = ScriptedReasoningTransport(steps: [
            .init(status: .badRequest, chunks: [reject400]),
            .init(chunks: openAISuccessChunks),
        ])
        let engine = AnyLanguageModelChatEngine(transport: transport)
        let req = try makeRequest(modelID: "o3-restricted", ownedBy: "openai", effort: .max)

        var resolution: ChatReasoningResolution?
        for try await event in engine.stream(req) {
            if case .reasoningResolution(let res) = event { resolution = res }
        }
        #expect(resolution == ChatReasoningResolution(requested: .max, applied: .low, outcome: .downgraded))
        let recorded = transport.snapshot()
        #expect(recorded.map { $0.bodyJSON?["reasoning_effort"] as? String } == ["max", "low"])
    }

    @Test func automaticEffortValidationErrorDoesNotPoisonExplicitReasoningCache() async throws {
        let reject422 = #"{"error":{"message":"reasoning_effort is required by this proxy","param":"reasoning_effort"}}"#
        let transport = ScriptedReasoningTransport(steps: [
            .init(status: .unprocessableContent, chunks: [reject422]),
            .init(chunks: openAISuccessChunks),
        ])
        let engine = AnyLanguageModelChatEngine(transport: transport)
        let autoReq = try makeRequest(modelID: "proxy-model", ownedBy: "openai", effort: .automatic)
        do {
            for try await _ in engine.stream(autoReq) {}
            Issue.record("Expected 422 on .automatic without retry")
        } catch {
            #expect(AnyLanguageModelChatEngine.failure(for: error) == .upstream(statusCode: 422))
        }

        let highReq = try makeRequest(modelID: "proxy-model", ownedBy: "openai", effort: .high)
        for try await _ in engine.stream(highReq) {}
        let recorded = transport.snapshot()
        #expect(recorded.count == 2)
        #expect(recorded[0].bodyJSON?["reasoning_effort"] == nil)
        #expect(recorded[1].bodyJSON?["reasoning_effort"] as? String == "high")
    }

    @Test func oversizedErrorBodyIsNotClassifiedForRetry() async throws {
        let padding = String(repeating: "x", count: ChatReasoningPolicy.maximumErrorClassificationBytes + 128)
        let huge400 = #"{"error":{"message":"Unrecognized request argument supplied: reasoning_effort \#(padding)","param":"reasoning_effort"}}"#
        let transport = ScriptedReasoningTransport(steps: [
            .init(status: .badRequest, chunks: [huge400]),
            .init(chunks: openAISuccessChunks),
        ])
        let engine = AnyLanguageModelChatEngine(transport: transport)
        let req = try makeRequest(modelID: "gpt-5.4", ownedBy: "openai", effort: .high)
        do {
            for try await _ in engine.stream(req) {}
            Issue.record("Expected oversized 400 body to fail without retry")
        } catch {
            #expect(AnyLanguageModelChatEngine.failure(for: error) == .upstream(statusCode: 400))
        }
        #expect(transport.snapshot().count == 1)
    }

    @Test func staleCacheGenerationCannotPoisonCacheAfterReset() {
        let cache = ChatReasoningCapabilityCache()
        let staleGen = cache.currentGeneration()
        cache.reset()
        let plan = ChatReasoningPolicy.makePlan(
            requested: .high,
            protocolKind: .openAIChatCompletions,
            modelID: "gpt-5.4",
            profile: .init()
        )
        ChatReasoningPolicy.recordRejection(
            .parameterUnsupported,
            for: plan,
            server: "https://cpa.example.invalid/",
            modelID: "gpt-5.4",
            cache: cache,
            generation: staleGen
        )
        #expect(!cache.profile(for: "https://cpa.example.invalid/", modelID: "gpt-5.4").reasoningUnsupported)
    }

    @Test func maxFallsBackToProviderDefaultAfterProtocolAndEffortRejections() async throws {
        let efforts = ["max", "xhigh", "high", "medium"]
        let effortRejections = efforts.map { value in
            ScriptedReasoningTransport.Step(status: .badRequest, chunks: [
                #"{"error":{"message":"Invalid value: '\#(value)'","param":"reasoning_effort"}}"#,
            ])
        }
        let transport = ScriptedReasoningTransport(steps:
            [.init(status: .notFound, chunks: [#"{"error":"not found"}"#])]
            + effortRejections
            + [.init(chunks: openAISuccessChunks)]
        )
        let engine = AnyLanguageModelChatEngine(transport: transport)
        let request = try makeRequest(modelID: "claude-relay", effort: .max)
        var text = ""
        var resolution: ChatReasoningResolution?
        for try await event in engine.stream(request) {
            if case .snapshot(let value, _) = event { text = value }
            if case .reasoningResolution(let value) = event { resolution = value }
        }
        let recorded = transport.snapshot()
        #expect(recorded.map(\.path) == ["/v1/messages"] + Array(repeating: "/v1/chat/completions", count: 5))
        #expect(recorded.dropFirst().map { $0.bodyJSON?["reasoning_effort"] as? String } == efforts.map(Optional.some) + [nil])
        #expect(text == "ok")
        #expect(resolution == ChatReasoningResolution(
            requested: .max, applied: nil, outcome: .omitted, usedFallbackProtocol: true
        ))
    }

    @Test func nonReasoningErrorsAreNeverRetried() async throws {
        let contextError = #"{"error":{"message":"This model's maximum context length is 128000 tokens.","code":"context_length_exceeded"}}"#
        let transport = ScriptedReasoningTransport(steps: [
            .init(status: .badRequest, chunks: [contextError]),
            .init(chunks: openAISuccessChunks),
        ])
        let engine = AnyLanguageModelChatEngine(transport: transport)
        let req = try makeRequest(modelID: "gpt-5.4", ownedBy: "openai", effort: .high)

        do {
            for try await _ in engine.stream(req) {}
            Issue.record("Expected context length error to fail without retry")
        } catch {
            #expect(AnyLanguageModelChatEngine.failure(for: error) == .upstream(statusCode: 400))
        }
        #expect((transport.snapshot()).count == 1)
    }

    @Test func failureAfterFirstEmittedChunkNeverRetries() async throws {
        let providerError = #"data: {"error":{"message":"Invalid value: 'max'","param":"reasoning_effort"}}"#
        let transport = ScriptedReasoningTransport(steps: [
            .init(chunks: ["data: \(openAISSEToken)\n\n", "\(providerError)\n\n"]),
            .init(chunks: openAISuccessChunks),
        ])
        let engine = AnyLanguageModelChatEngine(transport: transport)
        let req = try makeRequest(modelID: "gpt-5.4", ownedBy: "openai", effort: .max)

        var text = ""
        do {
            for try await event in engine.stream(req) {
                if case .snapshot(let value, _) = event { text = value }
            }
            Issue.record("Expected stream failure after partial chunk")
        } catch {
            #expect(text == "ok")
        }
        #expect((transport.snapshot()).count == 1)
    }

    // MARK: - Anthropic Native Messages & Protocol Fallback

    @Test func anthropicAdaptiveStreamsThinkingAndTopLevelSystem() async throws {
        let transport = ScriptedReasoningTransport(steps: [.init(chunks: anthropicSuccessChunks)])
        let engine = AnyLanguageModelChatEngine(transport: transport)
        let req = try makeRequest(
            modelID: "claude-opus-4-6",
            ownedBy: "anthropic",
            effort: .xhigh,
            instructions: "保持严谨"
        )

        var latestText = ""
        var latestReasoning: String?
        var resolution: ChatReasoningResolution?
        for try await event in engine.stream(req) {
            switch event {
            case .snapshot(let text, let reasoning):
                latestText = text
                if let reasoning { latestReasoning = reasoning }
            case .reasoningResolution(let res):
                resolution = res
            case .usage:
                break
            }
        }

        #expect(latestText == "结论")
        #expect(latestReasoning == "先分析")
        #expect(resolution == ChatReasoningResolution(requested: .xhigh, applied: .xhigh, outcome: .applied))

        let sent = try #require(transport.snapshot().first)
        #expect(sent.path == "/v1/messages")
        #expect(sent.hasAnthropicAPIKey)
        #expect(sent.bodyJSON?["system"] as? String == "保持严谨")
        #expect(sent.bodyJSON?["max_tokens"] as? Int == 16_384)
        let thinking = try #require(sent.bodyJSON?["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == "adaptive")
        let outputConfig = try #require(sent.bodyJSON?["output_config"] as? [String: Any])
        #expect(outputConfig["effort"] as? String == "xhigh")
    }

    @Test func anthropicLegacyModelUsesBudgetWithSafeMaxTokens() async throws {
        let transport = ScriptedReasoningTransport(steps: [.init(chunks: anthropicSuccessChunks)])
        let engine = AnyLanguageModelChatEngine(transport: transport)
        let req = try makeRequest(modelID: "claude-sonnet-4-5", ownedBy: "anthropic", effort: .max)

        for try await _ in engine.stream(req) {}
        let sent = try #require(transport.snapshot().first)
        let thinking = try #require(sent.bodyJSON?["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == "enabled")
        let budget = try #require(thinking["budget_tokens"] as? Int)
        let maxTokens = try #require(sent.bodyJSON?["max_tokens"] as? Int)
        #expect(budget == 32_768)
        #expect(maxTokens > budget)
    }

    @Test func anthropicParadigmMismatchFlipsBetweenAdaptiveAndBudget() async throws {
        let rejectAdaptive = #"{"type":"error","error":{"type":"invalid_request_error","message":"thinking.type: Input should be 'enabled'"}}"#
        let transport = ScriptedReasoningTransport(steps: [
            .init(status: .badRequest, chunks: [rejectAdaptive]),
            .init(chunks: anthropicSuccessChunks),
        ])
        let engine = AnyLanguageModelChatEngine(transport: transport)
        // Custom alias starts with adaptive, flips to budget after 400.
        let req = try makeRequest(modelID: "claude-custom-alias", ownedBy: "anthropic", effort: .high)

        for try await _ in engine.stream(req) {}
        let recorded = transport.snapshot()
        #expect(recorded.count == 2)
        #expect((recorded[0].bodyJSON?["thinking"] as? [String: Any])?["type"] as? String == "adaptive")
        #expect((recorded[1].bodyJSON?["thinking"] as? [String: Any])?["type"] as? String == "enabled")
        #expect((recorded[1].bodyJSON?["thinking"] as? [String: Any])?["budget_tokens"] as? Int == 16_384)
    }

    @Test func anthropicMaxTokensLimitClampsCeilingAndRetries() async throws {
        let rejectMax = #"{"type":"error","error":{"type":"invalid_request_error","message":"max_tokens: 40960 > 8192, which is the maximum allowed number of output tokens"}}"#
        let transport = ScriptedReasoningTransport(steps: [
            .init(status: .badRequest, chunks: [rejectMax]),
            .init(chunks: anthropicSuccessChunks),
        ])
        let engine = AnyLanguageModelChatEngine(transport: transport)
        let req = try makeRequest(modelID: "claude-sonnet-4-5", ownedBy: "anthropic", effort: .max)

        var resolution: ChatReasoningResolution?
        for try await event in engine.stream(req) {
            if case .reasoningResolution(let res) = event { resolution = res }
        }
        let recorded = transport.snapshot()
        #expect(recorded.count == 2)
        #expect(recorded[1].bodyJSON?["max_tokens"] as? Int == 8_192)
        let budget = try #require((recorded[1].bodyJSON?["thinking"] as? [String: Any])?["budget_tokens"] as? Int)
        #expect(budget < 8_192)
        #expect(resolution?.outcome == .downgraded)
    }

    @Test func anthropicMaxTokensLimitParsesMaximumAllowedIsPhrase() async throws {
        let rejectMax = #"{"type":"error","error":{"type":"invalid_request_error","message":"max_tokens: maximum allowed is 8192"}}"#
        let transport = ScriptedReasoningTransport(steps: [
            .init(status: .badRequest, chunks: [rejectMax]),
            .init(chunks: anthropicSuccessChunks),
        ])
        let engine = AnyLanguageModelChatEngine(transport: transport)
        let req = try makeRequest(modelID: "claude-sonnet-4-5", ownedBy: "anthropic", effort: .max)

        for try await _ in engine.stream(req) {}
        let recorded = transport.snapshot()
        #expect(recorded.count == 2)
        #expect(recorded[1].bodyJSON?["max_tokens"] as? Int == 8_192)
    }

    @Test func anthropicDualParadigmRejectionDegradesToOmitWithoutPingPong() async throws {
        let rejectAdaptive = #"{"type":"error","error":{"type":"invalid_request_error","message":"thinking.type: Input should be 'enabled'"}}"#
        let rejectBudget = #"{"type":"error","error":{"type":"invalid_request_error","message":"thinking.budget_tokens is not supported for this model"}}"#
        let transport = ScriptedReasoningTransport(steps: [
            .init(status: .badRequest, chunks: [rejectAdaptive]),
            .init(status: .badRequest, chunks: [rejectBudget]),
            .init(chunks: anthropicSuccessChunks),
            .init(chunks: anthropicSuccessChunks),
        ])
        let engine = AnyLanguageModelChatEngine(transport: transport)
        let req = try makeRequest(modelID: "claude-haiku-nonthinking", ownedBy: "anthropic", effort: .high)

        var resolution: ChatReasoningResolution?
        for try await event in engine.stream(req) {
            if case .reasoningResolution(let res) = event { resolution = res }
        }
        #expect(resolution == ChatReasoningResolution(requested: .high, applied: nil, outcome: .omitted))

        // Second turn goes straight to omitted without repeating adaptive or budget probes.
        for try await _ in engine.stream(req) {}
        let recorded = transport.snapshot()
        #expect(recorded.count == 4)
        #expect((recorded[0].bodyJSON?["thinking"] as? [String: Any])?["type"] as? String == "adaptive")
        #expect((recorded[1].bodyJSON?["thinking"] as? [String: Any])?["type"] as? String == "enabled")
        #expect(recorded[2].bodyJSON?["thinking"] == nil)
        #expect(recorded[3].bodyJSON?["thinking"] == nil)
    }

    @Test func anthropic200MalformedBodyDoesNotFallbackToOpenAI() async throws {
        let transport = ScriptedReasoningTransport(steps: [
            .init(status: .ok, chunks: ["{malformed-json"]),
            .init(chunks: openAISuccessChunks),
        ])
        let engine = AnyLanguageModelChatEngine(transport: transport)
        let req = try makeRequest(modelID: "claude-opus-4-6", ownedBy: "anthropic", effort: .high)

        do {
            _ = try await engine.complete(req)
            Issue.record("Expected 200 malformed JSON to throw without falling back to OpenAI")
        } catch {
            #expect(AnyLanguageModelChatEngine.failure(for: error) == .invalidResponse)
        }
        let recorded = transport.snapshot()
        #expect(recorded.map(\.path) == ["/v1/messages"])
    }

    @Test func anthropic401FallbackCachesOnlyWhenOpenAISucceedsAndPreserves401OnFailure() async throws {
        // Case 1: Anthropic 401 followed by OpenAI 404 must surface 401 and NOT cache fallback.
        let failingTransport = ScriptedReasoningTransport(steps: [
            .init(status: .unauthorized, chunks: [#"{"error":"invalid x-api-key"}"#]),
            .init(status: .notFound, chunks: [#"{"error":"not found"}"#]),
            .init(status: .unauthorized, chunks: [#"{"error":"invalid x-api-key"}"#]),
            .init(status: .notFound, chunks: [#"{"error":"not found"}"#]),
        ])
        let failingEngine = AnyLanguageModelChatEngine(transport: failingTransport)
        let req = try makeRequest(modelID: "claude-opus-4-6", ownedBy: "anthropic", effort: .high)
        do {
            for try await _ in failingEngine.stream(req) {}
            Issue.record("Expected original 401 error when OpenAI fallback fails")
        } catch {
            #expect(AnyLanguageModelChatEngine.failure(for: error) == .unauthorized(statusCode: 401))
        }
        // Second call still attempts `/v1/messages` because fallback did not succeed.
        do {
            for try await _ in failingEngine.stream(req) {}
        } catch {}
        #expect(failingTransport.snapshot().map(\.path) == [
            "/v1/messages", "/v1/chat/completions", "/v1/messages", "/v1/chat/completions",
        ])

        // Case 2: Anthropic 401 followed by OpenAI 200 succeeds and caches fallback for turn 2.
        let succeedingTransport = ScriptedReasoningTransport(steps: [
            .init(status: .unauthorized, chunks: [#"{"error":"bearer only"}"#]),
            .init(chunks: openAISuccessChunks),
            .init(chunks: openAISuccessChunks),
        ])
        let succeedingEngine = AnyLanguageModelChatEngine(transport: succeedingTransport)
        var resolution: ChatReasoningResolution?
        for try await event in succeedingEngine.stream(req) {
            if case .reasoningResolution(let res) = event { resolution = res }
        }
        #expect(resolution?.usedFallbackProtocol == true)
        for try await _ in succeedingEngine.stream(req) {}
        #expect(succeedingTransport.snapshot().map(\.path) == [
            "/v1/messages", "/v1/chat/completions", "/v1/chat/completions",
        ])
    }

    @Test func anthropicModel404FallsBackWithoutDisablingNativeMessagesForOtherModels() async throws {
        let transport = ScriptedReasoningTransport(steps: [
            .init(status: .notFound, chunks: [
                #"{"type":"error","error":{"type":"not_found_error","message":"Model claude-relay was not found"}}"#,
            ]),
            .init(chunks: openAISuccessChunks),
            .init(chunks: openAISuccessChunks),
            .init(chunks: anthropicSuccessChunks),
            .init(chunks: anthropicSuccessChunks),
        ])
        let engine = AnyLanguageModelChatEngine(transport: transport)
        let req = try makeRequest(modelID: "claude-relay", effort: .high)
        let native = try makeRequest(modelID: "claude-opus-4-6", effort: .high)

        var firstResolution: ChatReasoningResolution?
        for try await event in engine.stream(req) {
            if case .reasoningResolution(let res) = event { firstResolution = res }
        }
        #expect(firstResolution?.usedFallbackProtocol == true)
        #expect(firstResolution?.outcome == .applied)

        // Reuse the learned route for the relay model while preserving the native model's route.
        for try await _ in engine.stream(req) {}
        for try await _ in engine.stream(native) {}
        engine.resetReasoningCapabilities()
        for try await _ in engine.stream(req) {}

        let recorded = transport.snapshot()
        #expect(recorded.map(\.path) == [
            "/v1/messages",
            "/v1/chat/completions",
            "/v1/chat/completions",
            "/v1/messages",
            "/v1/messages",
        ])
        #expect(recorded.dropFirst().first?.bodyJSON?["reasoning_effort"] as? String == "high")
    }

    // MARK: - Workspace Per-Model Memory, Title Isolation & Resolution Recording

    @Test @MainActor func workspaceRemembersReasoningPerServerAndModelAndIsolatesTitles() async throws {
        let serverA = try CPAServer(baseURL: "https://server-a.example")
        let serverB = try CPAServer(baseURL: "https://server-b.example")
        let engine = ReasoningStubEngine()
        engine.events = [
            .snapshot(text: "完整回答", reasoning: nil),
            .reasoningResolution(ChatReasoningResolution(requested: .max, applied: .high, outcome: .downgraded)),
        ]
        let workspace = ChatWorkspaceModel(
            persistence: ChatMemoryPersistence(),
            secrets: MemorySecretStore(),
            engine: engine,
            modelCatalog: { _, _ in
                ReasoningStubCatalog(items: [
                    CPAModel(id: "gpt-5.4", ownedBy: "openai"),
                    CPAModel(id: "claude-opus-4-6", ownedBy: "anthropic"),
                ])
            }
        )
        await workspace.loadIfNeeded()
        await workspace.bind(server: serverA) { nil }
        #expect(await workspace.useManualKey("test-client-key-0001"))

        let firstID = workspace.createConversation()
        #expect(workspace.conversation(firstID)?.modelID == "gpt-5.4")
        #expect(workspace.conversation(firstID)?.reasoningEffort == .automatic)

        // Remember `.max` for gpt-5.4 on serverA.
        workspace.selectReasoningEffort(.max, in: firstID)
        #expect(workspace.conversation(firstID)?.reasoningEffort == .max)

        // Send a turn: verify modelOwnedBy, effort, resolution notice, and title isolation.
        #expect(workspace.send("分析架构", attachments: [], in: firstID))
        for _ in 0..<200 where workspace.isGenerating(firstID) || engine.completeRequests.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        let sentStream = try #require(engine.streamRequests.last)
        #expect(sentStream.modelOwnedBy == "openai")
        #expect(sentStream.reasoningEffort == .max)

        let titleReq = try #require(engine.completeRequests.last)
        #expect(titleReq.reasoningEffort == .automatic)
        #expect(titleReq.modelOwnedBy == "openai")

        let assistant = try #require(workspace.conversation(firstID)?.messages.last)
        #expect(assistant.reasoningResolution == ChatReasoningResolution(requested: .max, applied: .high, outcome: .downgraded))

        // New conversation on serverA automatically adopts `.max` for gpt-5.4.
        let secondID = workspace.createConversation()
        #expect(workspace.conversation(secondID)?.modelID == "gpt-5.4")
        #expect(workspace.conversation(secondID)?.reasoningEffort == .max)

        // Switching to claude-opus-4-6 in an empty conversation switches to claude's own preference (`.automatic`).
        workspace.selectModel("claude-opus-4-6", in: secondID)
        #expect(workspace.conversation(secondID)?.reasoningEffort == .automatic)
        workspace.selectReasoningEffort(.xhigh, in: secondID)

        // Switching to serverB must NOT leak serverA's preferences.
        await workspace.bind(server: serverB) { nil }
        #expect(await workspace.useManualKey("test-client-key-0002"))
        let serverBID = workspace.createConversation()
        #expect(workspace.conversation(serverBID)?.reasoningEffort == .automatic)
        #expect(engine.resetCount > 0)
    }

    @Test @MainActor func modelRemovalAdoptsFallbackRememberedEffortAndFailedSettingsUsesTemporaryCache() async throws {
        final class SwitchableCatalog: ChatModelCatalog, @unchecked Sendable {
            private let lock = NSLock()
            private var items: [CPAModel]
            init(_ items: [CPAModel]) { self.items = items }
            func set(_ items: [CPAModel]) { lock.withLock { self.items = items } }
            func models() async throws -> [CPAModel] { lock.withLock { items } }
        }
        let server = try CPAServer(baseURL: "https://server-c.example")
        let catalog = SwitchableCatalog([
            CPAModel(id: "model-a", ownedBy: "openai"),
            CPAModel(id: "model-b", ownedBy: "openai"),
        ])
        let workspace = ChatWorkspaceModel(
            persistence: FailingSettingsLoadPersistence(),
            secrets: MemorySecretStore(),
            engine: ReasoningStubEngine(),
            modelCatalog: { _, _ in catalog }
        )
        await workspace.loadIfNeeded()
        #expect(workspace.settingsLoadFailed)
        await workspace.bind(server: server) { nil }
        #expect(await workspace.useManualKey("test-client-key-0003"))

        // EFF-10: Even when settings failed to load, remembered efforts round-trip via temporary cache.
        let id1 = workspace.createConversation()
        workspace.selectModel("model-b", in: id1)
        workspace.selectReasoningEffort(.off, in: id1)
        workspace.selectModel("model-a", in: id1)
        workspace.selectReasoningEffort(.max, in: id1)

        // Create a fresh empty conversation (non-manual) adopting model-a's `.max` from temporary cache.
        let id2 = workspace.createConversation()
        #expect(id2 == id1) // reused empty conversation, manual flag cleared!
        #expect(workspace.conversation(id2)?.modelID == "model-a")
        #expect(workspace.conversation(id2)?.reasoningEffort == .max)

        // EFF-08: Removing model-a falls back to model-b and adopts model-b's remembered `.off`
        // instead of keeping model-a's `.max`.
        catalog.set([CPAModel(id: "model-b", ownedBy: "openai")])
        await workspace.refreshModels()
        #expect(workspace.conversation(id2)?.modelID == "model-b")
        #expect(workspace.conversation(id2)?.reasoningEffort == .off)
    }
}
