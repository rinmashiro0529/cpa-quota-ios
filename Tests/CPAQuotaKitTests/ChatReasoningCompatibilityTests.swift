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
    private(set) var streamRequests: [ChatEngineRequest] = []
    private(set) var completeRequests: [ChatEngineRequest] = []
    private(set) var resetCount = 0
    var events: [ChatEngineEvent] = [.snapshot(text: "回复", reasoning: nil)]

    func stream(_ request: ChatEngineRequest) -> AsyncThrowingStream<ChatEngineEvent, any Error> {
        streamRequests.append(request)
        let events = self.events
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    func complete(_ request: ChatEngineRequest) async throws -> String {
        completeRequests.append(request)
        return "简短标题"
    }

    func resetReasoningCapabilities() {
        resetCount += 1
    }
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

        #expect(ChatReasoningPolicy.isAnthropicModel(modelID: "claude-opus-4-6", ownedBy: nil))
        #expect(ChatReasoningPolicy.isAnthropicModel(modelID: "anthropic/claude-sonnet-4-5", ownedBy: nil))
        #expect(ChatReasoningPolicy.isAnthropicModel(modelID: "custom-alias", ownedBy: "anthropic"))
        #expect(!ChatReasoningPolicy.isAnthropicModel(modelID: "gpt-5.4", ownedBy: "openai"))
        #expect(!ChatReasoningPolicy.isAnthropicModel(modelID: "gemini-2.5-pro", ownedBy: "google"))

        #expect(ChatReasoningPolicy.initialAnthropicStyle(for: "claude-opus-4-6") == .adaptive)
        #expect(ChatReasoningPolicy.initialAnthropicStyle(for: "claude-opus-4-7") == .adaptive)
        #expect(ChatReasoningPolicy.initialAnthropicStyle(for: "claude-sonnet-5") == .adaptive)
        #expect(ChatReasoningPolicy.initialAnthropicStyle(for: "claude-sonnet-4-5") == .budget)
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

    @Test func openAIOffRejectedByForcedReasoningModelFallsBackToOmit() async throws {
        let reject400 = #"{"error":{"message":"Unsupported value: 'none' is not supported for reasoning_effort on this model.","param":"reasoning_effort"}}"#
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
        #expect(resolution == ChatReasoningResolution(requested: .off, applied: nil, outcome: .omitted))
        let recorded = transport.snapshot()
        #expect(recorded.count == 2)
        #expect(recorded[0].bodyJSON?["reasoning_effort"] as? String == "none")
        #expect(recorded[1].bodyJSON?["reasoning_effort"] == nil)
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

    @Test func anthropicEndpoint404FallsBackToOpenAIChatCompletionsAndCachesServer() async throws {
        let transport = ScriptedReasoningTransport(steps: [
            .init(status: .notFound, chunks: [#"{"error":"not found"}"#]),
            .init(chunks: openAISuccessChunks),
            .init(chunks: openAISuccessChunks),
        ])
        let engine = AnyLanguageModelChatEngine(transport: transport)
        let req = try makeRequest(modelID: "claude-opus-4-6", ownedBy: "anthropic", effort: .high)

        var firstResolution: ChatReasoningResolution?
        for try await event in engine.stream(req) {
            if case .reasoningResolution(let res) = event { firstResolution = res }
        }
        #expect(firstResolution?.usedFallbackProtocol == true)
        #expect(firstResolution?.outcome == .applied)

        // Second request skips /v1/messages directly.
        for try await _ in engine.stream(req) {}
        let recorded = transport.snapshot()
        #expect(recorded.count == 3)
        #expect(recorded[0].path == "/v1/messages")
        #expect(recorded[1].path == "/v1/chat/completions")
        #expect(recorded[1].bodyJSON?["reasoning_effort"] as? String == "high")
        #expect(recorded[2].path == "/v1/chat/completions")

        // Reset clears cached fallback.
        engine.resetReasoningCapabilities()
        let freshTransport = ScriptedReasoningTransport(steps: [.init(chunks: anthropicSuccessChunks)])
        let freshEngine = AnyLanguageModelChatEngine(transport: freshTransport)
        for try await _ in freshEngine.stream(req) {}
        #expect((freshTransport.snapshot()).first?.path == "/v1/messages")
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
}
