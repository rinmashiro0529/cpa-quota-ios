import Foundation
import Testing
import AnyLanguageModel
import HTTPTypes
@testable import CPAQuotaChat
@testable import CPAQuotaKit

private struct FixtureSSETransport: AnyLanguageModel.HTTPTransport {
    let fragments: [String]
    var status: HTTPTypes.HTTPResponse.Status = .ok
    var headers: HTTPFields = [:]
    var inspectRequest: (@Sendable (Data) throws -> Void)?

    func send<Return>(request: HTTPRequest, body: Data?, timeout: Duration?,
                      responseHandler: (HTTPTypes.HTTPResponse, HTTPResponseBody) async throws -> Return) async throws -> Return {
        #expect(request.headerFields[.accept] == "text/event-stream")
        try inspectRequest?(body ?? Data())
        let json = try JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any]
        #expect((json?["stream_options"] as? [String: Bool])?["include_usage"] == true)
        let chunks = AsyncStream<Data> { continuation in
            for fragment in fragments { continuation.yield(Data(fragment.utf8)) }
            continuation.finish()
        }
        return try await responseHandler(.init(status: status, headerFields: headers), HTTPResponseBody(chunks))
    }
}

@Suite("CPA chat SSE adapter")
struct CPAChatSSETests {
    private let token = #"{"id":"fixture","object":"chat.completion.chunk","created":1,"model":"fixture-model","choices":[{"index":0,"delta":{"content":"partial"}}]}"#

    private func request() throws -> ChatEngineRequest {
        try ChatEngineRequest(baseURL: #require(URL(string: "https://example.invalid/v1")),
                              apiKey: #require(CPAClientAPIKey("test-client-key-0001")),
                              modelID: "fixture-model", prompt: "Test")
    }

    @Test(arguments: [true, false])
    func completionMarkerControlsSuccess(hasMarker: Bool) async throws {
        var fragments = ["data: \(token)\r\n\r\n"]
        if hasMarker { fragments += ["data: [DO", "NE]\r\n\r\n"] }
        let engine = AnyLanguageModelChatEngine(transport: FixtureSSETransport(fragments: fragments))
        let request = try self.request()
        var latest = ""
        do {
            for try await event in engine.stream(request) {
                if case .snapshot(let text, _) = event { latest = text }
            }
            #expect(hasMarker)
        } catch {
            #expect(!hasMarker)
            #expect(AnyLanguageModelChatEngine.failure(for: error) == .streamInterrupted)
        }
        #expect(latest == "partial")
    }

    @Test func continuationSendsOriginalTurnAndOneInternalPromptThroughSDK() async throws {
        let question = ChatMessage(role: .user, text: "original question")
        let reply = ChatMessage(role: .assistant, text: "unfinished answer", reasoning: "local reasoning only")
        let context = ChatPromptBuilder.continuationContext(earlier: [], question: question, reply: reply,
                                                            effectivePrompt: question.text)
        var request = try self.request()
        request.history = context.history
        request.prompt = context.prompt
        let transport = FixtureSSETransport(fragments: ["data: \(token)\n\n", "data: [DONE]\n\n"]) { body in
            let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            let messages = try #require(object?["messages"] as? [[String: Any]])
            #expect(messages.compactMap { $0["role"] as? String } == ["user", "assistant", "user"])
            let payload = String(decoding: body, as: UTF8.self)
            #expect(payload.contains(question.text))
            #expect(payload.contains(reply.text))
            #expect(payload.contains(context.prompt))
            #expect(!payload.contains("local reasoning only"))
        }
        for try await _ in AnyLanguageModelChatEngine(transport: transport).stream(request) {}
    }

    @Test func nonSuccessfulStatusKeepsHTTPFailureMapping() async throws {
        let engine = AnyLanguageModelChatEngine(transport: FixtureSSETransport(fragments: [], status: .unauthorized))
        let request = try self.request()
        do {
            for try await _ in engine.stream(request) {}
            Issue.record("Expected an HTTP 401 failure")
        } catch {
            #expect(AnyLanguageModelChatEngine.failure(for: error) == .unauthorized(statusCode: 401))
        }
    }
}

// MARK: - Fakes

final class FakeChatEngine: ChatEngine, @unchecked Sendable {
    private var _events: [ChatEngineEvent] = []
    private var _streamError: (any Error)?
    private var _blockUntilCancelled = false
    private var _completeResult = "生成的标题"
    var completeGate: (@Sendable () async -> Void)?
    private(set) var streamRequests: [ChatEngineRequest] = []
    private(set) var completeRequests: [ChatEngineRequest] = []

    func respond(with events: [ChatEngineEvent]) {
        _events = events; _streamError = nil; _blockUntilCancelled = false
    }
    func fail(with error: any Error) {
        _streamError = error; _blockUntilCancelled = false
    }
    func block() {
        _blockUntilCancelled = true
    }

    func stream(_ request: ChatEngineRequest) -> AsyncThrowingStream<ChatEngineEvent, any Error> {
        streamRequests.append(request)
        let events = _events
        let error = _streamError
        let blocks = _blockUntilCancelled
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            if blocks {
                continuation.onTermination = { _ in }
                return // keep the stream open after the configured snapshots
            }
            continuation.finish(throwing: error)
        }
    }

    func complete(_ request: ChatEngineRequest) async throws -> String {
        completeRequests.append(request)
        await completeGate?()
        return _completeResult
    }
}

struct FakeModelCatalog: ChatModelCatalog {
    var result: Result<[CPAModel], any Error>

    func models() async throws -> [CPAModel] {
        try result.get()
    }
}

final class FakeBackgroundRunner: ChatBackgroundRunner, @unchecked Sendable {
    private var nextToken = 0
    private var expirations: [ChatBackgroundToken: @MainActor @Sendable () -> Void] = [:]
    private(set) var endedTokens: [ChatBackgroundToken] = []
    private(set) var notifications: [UUID] = []
    var inBackground = false
    var notificationAuthorization = true
    var waitAfterNotification: (@Sendable () async -> Void)?

    @MainActor func beginTask(expiration: @escaping @MainActor @Sendable () -> Void) -> ChatBackgroundToken {
        nextToken += 1
        let token = ChatBackgroundToken(rawValue: nextToken)
        expirations[token] = expiration
        return token
    }

    @MainActor func endTask(_ token: ChatBackgroundToken) {
        expirations.removeValue(forKey: token)
        endedTokens.append(token)
    }

    @MainActor var isAppInBackground: Bool { inBackground }

    @MainActor var currentExpiration: (@MainActor @Sendable () -> Void)? { expirations.values.first }

    @MainActor func fireExpiration() {
        for callback in expirations.values { callback() }
    }

    func notifyCompletion(conversationID: UUID) async {
        notifications.append(conversationID)
        await waitAfterNotification?()
    }

    func requestNotificationAuthorization() async -> Bool {
        notificationAuthorization
    }

    func notificationAuthorizationStatus() async -> ChatNotificationAuthorization {
        notificationAuthorization ? .authorized : .denied
    }

    var notificationCount: Int { notifications.count }
}

/// Search client the test can hold open (`gate`) like a real in-flight
/// request; `release` lets it return.
final class FakeSearchClient: ChatSearchClient, @unchecked Sendable {
    private(set) var queries: [String] = []
    private var blocked = false
    private var result: [ChatSearchSource] = []

    func gate() { blocked = true }
    func release() { blocked = false }
    func respond(with sources: [ChatSearchSource]) { result = sources }

    func search(_ query: String, apiKey: String) async throws -> [ChatSearchSource] {
        queries.append(query)
        while blocked {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        return result
    }
}

/// Persistence that records write order so tests can assert writes are
/// serialized in the order they were enqueued.
actor RecordingPersistence: ChatPersistence {
    struct ConversationWrite: Equatable {
        let messageCount: Int
        let lastStatus: ChatMessage.Status?
        var lastText: String = ""
    }

    enum Operation: Equatable {
        case saveConversation(UUID, ConversationWrite)
        case removeConversation(UUID)
        case removeAllConversations
        case saveSettings
        case saveMemories(Int)
        case saveSkills(Int)
    }

    private(set) var operations: [Operation] = []
    private var failsTerminalWrites = false
    func failTerminalWrites() { failsTerminalWrites = true }
    private var storedConversations: [ChatConversation]

    init(seeded: [ChatConversation] = []) {
        storedConversations = seeded
    }

    func saves(for id: UUID) -> [ConversationWrite] {
        operations.compactMap { operation in
            guard case .saveConversation(let savedID, let write) = operation,
                  savedID == id else { return nil }
            return write
        }
    }

    func loadConversations() async throws -> [ChatConversation] { storedConversations }
    func stored(_ id: UUID) -> ChatConversation? { storedConversations.first { $0.id == id } }

    func saveConversation(_ conversation: ChatConversation) async throws {
        if failsTerminalWrites, conversation.messages.last?.status != .streaming {
            throw ChatPersistenceError.storageFailure
        }
        operations.append(.saveConversation(
            conversation.id,
            ConversationWrite(messageCount: conversation.messages.count,
                              lastStatus: conversation.messages.last?.status,
                              lastText: conversation.messages.last?.text ?? "")))
        if let index = storedConversations.firstIndex(where: { $0.id == conversation.id }) {
            storedConversations[index] = conversation
        } else {
            storedConversations.append(conversation)
        }
    }

    func removeConversation(_ id: UUID) async throws {
        operations.append(.removeConversation(id))
        storedConversations.removeAll { $0.id == id }
    }

    func removeAllConversations() async throws {
        operations.append(.removeAllConversations)
        storedConversations.removeAll()
    }

    func loadSettings() async throws -> ChatSettings? { nil }
    func saveSettings(_ settings: ChatSettings) async throws {
        operations.append(.saveSettings)
    }
    func loadMemories() async throws -> [ChatMemoryItem]? { nil }
    func saveMemories(_ items: [ChatMemoryItem]) async throws {
        operations.append(.saveMemories(items.count))
    }
    func loadSkills() async throws -> [ChatSkill]? { nil }
    func saveSkills(_ skills: [ChatSkill]) async throws {
        operations.append(.saveSkills(skills.count))
    }
}

private actor HeldDiscovery {
    private var waiting: CheckedContinuation<Void, Never>?
    private var released = false

    var hasStarted: Bool { waiting != nil }

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func release() {
        released = true
        waiting?.resume()
        waiting = nil
    }
}

/// Memory persistence whose conversation load waits for `gate` and counts loads.
private actor GatedLoadPersistence: ChatPersistence {
    private let base = ChatMemoryPersistence()
    let gate = HeldDiscovery()
    private(set) var loadCount = 0

    func seed(_ conversation: ChatConversation) async { try? await base.saveConversation(conversation) }
    func loadConversations() async throws -> [ChatConversation] {
        loadCount += 1
        await gate.wait()
        return try await base.loadConversations()
    }
    func saveConversation(_ conversation: ChatConversation) async throws { try await base.saveConversation(conversation) }
    func removeConversation(_ id: UUID) async throws { try await base.removeConversation(id) }
    func removeAllConversations() async throws { try await base.removeAllConversations() }
    func loadSettings() async throws -> ChatSettings? { nil }
    func saveSettings(_ settings: ChatSettings) async throws {}
    func loadMemories() async throws -> [ChatMemoryItem]? { nil }
    func saveMemories(_ items: [ChatMemoryItem]) async throws {}
    func loadSkills() async throws -> [ChatSkill]? { nil }
    func saveSkills(_ skills: [ChatSkill]) async throws {}
}

/// Memory persistence whose bulk removal fails until `allowRemoval()`.
private actor FailingBulkRemovalPersistence: ChatPersistence {
    private let base = ChatMemoryPersistence()
    private var removalFails = true

    func allowRemoval() { removalFails = false }
    func loadConversations() async throws -> [ChatConversation] { try await base.loadConversations() }
    func saveConversation(_ conversation: ChatConversation) async throws { try await base.saveConversation(conversation) }
    func removeConversation(_ id: UUID) async throws { try await base.removeConversation(id) }
    func removeAllConversations() async throws {
        if removalFails { throw ChatPersistenceError.storageFailure }
        try await base.removeAllConversations()
    }
    func loadSettings() async throws -> ChatSettings? { nil }
    func saveSettings(_ settings: ChatSettings) async throws {}
    func loadMemories() async throws -> [ChatMemoryItem]? { nil }
    func saveMemories(_ items: [ChatMemoryItem]) async throws {}
    func loadSkills() async throws -> [ChatSkill]? { nil }
    func saveSkills(_ skills: [ChatSkill]) async throws {}
}

private actor FailingRemovalSecretStore: ChatSecretStore {
    private var stored: [String: String] = [:]
    private var removalFails = true

    func loadSecret(account: String) async throws -> String? { stored[account] }
    func saveSecret(_ value: String, account: String) async throws { stored[account] = value }
    func removeSecret(account: String) async throws {
        if removalFails { throw CPAError(.secureStorageFailure) }
        stored[account] = nil
    }
    func allowRemoval() { removalFails = false }
}

// MARK: - Tests

@Suite("ChatWorkspaceModel")
struct ChatWorkspaceModelTests {
    private let server = try! CPAServer(baseURL: "https://cpa.example.com")

    private struct Fixture {
        let workspace: ChatWorkspaceModel
        let engine: FakeChatEngine
        let secrets: MemorySecretStore
        let transport: StubHTTPTransport
        let runner: FakeBackgroundRunner
    }

    @MainActor
    private func makeFixture(
        models: [CPAModel] = [CPAModel(id: "test-model")],
        catalog: (@Sendable (CPAServer, CPAClientAPIKey) -> any ChatModelCatalog)? = nil,
        persistence: any ChatPersistence = ChatMemoryPersistence(),
        searchClient: (any ChatSearchClient)? = nil,
        streamingPersistInterval: Duration = .seconds(2)
    ) -> Fixture {
        let engine = FakeChatEngine()
        let secrets = MemorySecretStore()
        let transport = StubHTTPTransport()
        let runner = FakeBackgroundRunner()
        let workspace = ChatWorkspaceModel(
            persistence: persistence,
            secrets: secrets,
            engine: engine,
            searchClient: { _ in searchClient ?? FakeSearchClient() },
            modelCatalog: catalog ?? { _, _ in FakeModelCatalog(result: .success(models)) },
            backgroundRunner: runner,
            streamingPersistInterval: streamingPersistInterval)
        return Fixture(workspace: workspace, engine: engine, secrets: secrets,
                       transport: transport, runner: runner)
    }

    private func makeDiscovery(_ transport: StubHTTPTransport) -> CPAAPIKeyDiscovery {
        CPAAPIKeyDiscovery(server: server, managementKey: try! ManagementKey("test-management-key-0001"),
                           transport: transport, coordinator: CPAManagementRequestCoordinator(),
                           clock: { Date() })
    }

    @MainActor
    private func bind(_ fixture: Fixture, apiKeys: [String]? = nil) async {
        if let apiKeys {
            let keys = apiKeys.map { "\"\($0)\"" }.joined(separator: ",")
            let body = "{\"api-keys\":[\(keys)]}"
            await fixture.transport.respond("/v0/management/api-keys", status: 200, body: body)
        }
        let discovery = makeDiscovery(fixture.transport)
        await fixture.workspace.bind(server: server) { discovery }
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 5_000_000_000,
        _ condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    @Test @MainActor func bindAutoSelectsSingleDiscoveredKey() async throws {
        let fixture = makeFixture()
        await fixture.workspace.loadIfNeeded()
        await bind(fixture, apiKeys: ["test-client-key-0001"])

        guard case .ready(let hint, let isManual) = await fixture.workspace.credentialState else {
            Issue.record("expected .ready")
            return
        }
        #expect(hint == "••••0001")
        #expect(!isManual)
        #expect(await fixture.workspace.server == server)

        // The stored secret must contain the key JSON for this server.
        let account = ChatSecrets.clientAPIKeyAccount(for: server)
        let stored = try await fixture.secrets.loadSecret(account: account)
        #expect(stored?.contains("test-client-key-0001") == true)

        _ = await waitUntil { [workspace = fixture.workspace] in
            await MainActor.run { workspace.modelListState == .loaded }
        }
        #expect(await fixture.workspace.models.map(\.id) == ["test-model"])
    }

    @Test @MainActor func multipleDiscoveredKeysStayMissingKey() async {
        let fixture = makeFixture()
        await fixture.workspace.loadIfNeeded()
        await bind(fixture, apiKeys: ["test-client-key-0001", "test-client-key-0002"])

        #expect(await fixture.workspace.credentialState == .missingKey)
        #expect(await fixture.workspace.discoveredKeys.count == 2)
    }

    @Test @MainActor func sendStreamsTextReasoningUsageAndGeneratesTitle() async {
        let fixture = makeFixture()
        fixture.engine.respond(with: [
            .snapshot(text: "你好", reasoning: "在想"),
            .snapshot(text: "你好，世界", reasoning: "在想中"),
            .usage(ChatTokenUsage(inputTokens: 10, outputTokens: 4, reasoningTokens: 2)),
        ])
        await fixture.workspace.loadIfNeeded()
        await bind(fixture, apiKeys: ["test-client-key-0001"])
        let conversationID = await fixture.workspace.createConversation()
        await fixture.workspace.send("介绍你自己", attachments: [], in: conversationID)

        let done = await waitUntil { [workspace = fixture.workspace] in
            await MainActor.run { !workspace.isGenerating(conversationID) }
        }
        #expect(done)

        let conversation = await fixture.workspace.conversation(conversationID)
        let assistant = conversation?.messages.last(where: { $0.role == .assistant })
        #expect(assistant?.status == .complete)
        #expect(assistant?.text == "你好，世界")
        #expect(assistant?.reasoning == "在想中")
        #expect(assistant?.usage == ChatTokenUsage(inputTokens: 10, outputTokens: 4, reasoningTokens: 2))

        let titled = await waitUntil { [workspace = fixture.workspace] in
            await MainActor.run { workspace.conversation(conversationID)?.title == "生成的标题" }
        }
        #expect(titled)
        let titleRequest = fixture.engine.completeRequests.first
        #expect(titleRequest?.prompt.contains("用不超过 12 个字概括") == true)
        #expect(titleRequest?.instructions == "")
    }

    @Test @MainActor func stopProducesStoppedStatus() async {
        let fixture = makeFixture()
        fixture.engine.block()
        await fixture.workspace.loadIfNeeded()
        await bind(fixture, apiKeys: ["test-client-key-0001"])
        let conversationID = await fixture.workspace.createConversation()
        await fixture.workspace.send("停", attachments: [], in: conversationID)

        _ = await waitUntil { [workspace = fixture.workspace] in
            await MainActor.run { workspace.isGenerating(conversationID) }
        }
        await fixture.workspace.stop(conversationID)

        let done = await waitUntil { [workspace = fixture.workspace] in
            await MainActor.run { !workspace.isGenerating(conversationID) }
        }
        #expect(done)
        let assistant = await fixture.workspace.conversation(conversationID)?
            .messages.last(where: { $0.role == .assistant })
        #expect(assistant?.status == .stopped)
    }

    @Test @MainActor func engineErrorMapsToFailed() async {
        let fixture = makeFixture()
        fixture.engine.fail(with: URLError(.notConnectedToInternet))
        await fixture.workspace.loadIfNeeded()
        await bind(fixture, apiKeys: ["test-client-key-0001"])
        let conversationID = await fixture.workspace.createConversation()
        await fixture.workspace.send("会失败", attachments: [], in: conversationID)

        _ = await waitUntil { [workspace = fixture.workspace] in
            await MainActor.run { !workspace.isGenerating(conversationID) }
        }
        let assistant = await fixture.workspace.conversation(conversationID)?
            .messages.last(where: { $0.role == .assistant })
        #expect(assistant?.status == .failed)
        #expect(assistant?.failure == .network)
    }

    @Test @MainActor func missingKeyAppendsFailedPair() async {
        let fixture = makeFixture()
        await fixture.workspace.loadIfNeeded()
        // No keys on the server → stays .missingKey.
        await fixture.transport.respond("/v0/management/api-keys", status: 200,
                                        body: #"{"api-keys":[]}"#)
        await fixture.transport.respond("/v8/management/config/access/api-keys", status: 404)
        await bind(fixture, apiKeys: [])

        #expect(await fixture.workspace.credentialState == .missingKey)
        let conversationID = await fixture.workspace.createConversation()
        await fixture.workspace.send("发不出去", attachments: [], in: conversationID)

        _ = await waitUntil { [workspace = fixture.workspace] in
            await MainActor.run { !workspace.isGenerating(conversationID) }
        }
        let messages = await fixture.workspace.conversation(conversationID)?.messages ?? []
        #expect(messages.count == 2)
        #expect(messages[0].role == .user)
        #expect(messages[1].status == .failed)
        #expect(messages[1].failure == .missingAPIKey)
    }

    @Test @MainActor func missingModelAppendsFailedPair() async {
        let fixture = makeFixture(models: []) // catalog empty → no modelID
        await fixture.workspace.loadIfNeeded()
        await bind(fixture, apiKeys: ["test-client-key-0001"])
        let conversationID = await fixture.workspace.createConversation()
        #expect(await fixture.workspace.conversation(conversationID)?.modelID == nil)
        await fixture.workspace.send("没有模型", attachments: [], in: conversationID)

        _ = await waitUntil { [workspace = fixture.workspace] in
            await MainActor.run { !workspace.isGenerating(conversationID) }
        }
        let assistant = await fixture.workspace.conversation(conversationID)?
            .messages.last(where: { $0.role == .assistant })
        #expect(assistant?.status == .failed)
        #expect(assistant?.failure == .missingModel)
    }

    @Test @MainActor func regenerateTruncatesAndReruns() async {
        let fixture = makeFixture()
        fixture.engine.respond(with: [.snapshot(text: "第一版", reasoning: nil)])
        await fixture.workspace.loadIfNeeded()
        await bind(fixture, apiKeys: ["test-client-key-0001"])
        let conversationID = await fixture.workspace.createConversation()
        await fixture.workspace.send("问", attachments: [], in: conversationID)
        _ = await waitUntil { [workspace = fixture.workspace] in
            await MainActor.run { !workspace.isGenerating(conversationID) }
        }

        let firstAssistant = await fixture.workspace.conversation(conversationID)?
            .messages.last(where: { $0.role == .assistant })
        #expect(firstAssistant?.text == "第一版")

        fixture.engine.respond(with: [.snapshot(text: "第二版", reasoning: nil)])
        await fixture.workspace.regenerate(firstAssistant!.id, in: conversationID)
        _ = await waitUntil { [workspace = fixture.workspace] in
            await MainActor.run { !workspace.isGenerating(conversationID) }
        }

        let messages = await fixture.workspace.conversation(conversationID)?.messages ?? []
        #expect(messages.count == 2)
        #expect(messages[0].role == .user)
        #expect(messages[1].role == .assistant)
        #expect(messages[1].text == "第二版")
        #expect(messages[1].id != firstAssistant?.id)
        #expect(fixture.engine.streamRequests.count == 2)
    }

    @Test @MainActor func editAndResendTruncatesLaterMessages() async {
        let fixture = makeFixture()
        fixture.engine.respond(with: [.snapshot(text: "回一", reasoning: nil)])
        await fixture.workspace.loadIfNeeded()
        await bind(fixture, apiKeys: ["test-client-key-0001"])
        let conversationID = await fixture.workspace.createConversation()
        await fixture.workspace.send("旧问题", attachments: [], in: conversationID)
        _ = await waitUntil { [workspace = fixture.workspace] in
            await MainActor.run { !workspace.isGenerating(conversationID) }
        }
        await fixture.workspace.send("第二个问题", attachments: [], in: conversationID)
        _ = await waitUntil { [workspace = fixture.workspace] in
            await MainActor.run { !workspace.isGenerating(conversationID) }
        }
        // Two complete turns exist before the edit, so truncation is observable.
        #expect(fixture.workspace.conversation(conversationID)?.messages.count == 4)

        let firstUser = await fixture.workspace.conversation(conversationID)?
            .messages.first(where: { $0.role == .user })
        fixture.engine.respond(with: [.snapshot(text: "新回答", reasoning: nil)])
        await fixture.workspace.editAndResend(firstUser!.id, text: "编辑后的问题", in: conversationID)
        _ = await waitUntil { [workspace = fixture.workspace] in
            await MainActor.run { !workspace.isGenerating(conversationID) }
        }

        let messages = await fixture.workspace.conversation(conversationID)?.messages ?? []
        #expect(messages.count == 2)
        #expect(messages[0].text == "编辑后的问题")
        #expect(messages[0].id == firstUser?.id)
        #expect(messages[1].text == "新回答")
        // The regenerated history must see the edited text.
        #expect(fixture.engine.streamRequests.last?.prompt.contains("编辑后的问题") == true)
    }

    @Test @MainActor func forgetRemovesStoredKeyAndUnbinds() async throws {
        let fixture = makeFixture()
        await fixture.workspace.loadIfNeeded()
        await bind(fixture, apiKeys: ["test-client-key-0001"])
        #expect(await fixture.workspace.credentialState != .missingKey)

        try await fixture.workspace.forget(server: server)
        #expect(await fixture.workspace.credentialState == .unbound)
        #expect(await fixture.workspace.server == nil)
        let account = ChatSecrets.clientAPIKeyAccount(for: server)
        #expect(try await fixture.secrets.loadSecret(account: account) == nil)
    }

    @Test @MainActor func lateKeyDiscoveryDoesNotInstallIntoNewConnection() async throws {
        let fixture = makeFixture()
        let gate = HeldDiscovery()
        let other = try CPAServer(baseURL: "https://other.example.com")
        let discovery = makeDiscovery(fixture.transport)
        await fixture.transport.respond("/v0/management/api-keys", status: 200,
                                        body: #"{"api-keys":["test-client-key-0001"]}"#)
        await fixture.transport.holdResponses { await gate.wait() }
        let pending = Task {
            await fixture.workspace.bind(server: server) { discovery }
        }
        let requested = await waitUntil { await gate.hasStarted }
        await fixture.workspace.bind(server: other) { nil }
        await gate.release()
        await pending.value

        #expect(requested)
        #expect(fixture.workspace.server == other)
        #expect(fixture.workspace.credentialState == .missingKey)
        #expect(fixture.workspace.discoveredKeys.isEmpty)
        let account = ChatSecrets.clientAPIKeyAccount(for: other)
        #expect(try await fixture.secrets.loadSecret(account: account) == nil)
    }

    @Test @MainActor func changingConnectionSuppressesOldReplyTitleRequest() async throws {
        let gate = HeldDiscovery()
        let fixture = makeFixture()
        fixture.runner.inBackground = true
        fixture.runner.waitAfterNotification = { await gate.wait() }
        fixture.engine.respond(with: [.snapshot(text: "Old reply", reasoning: nil)])
        await fixture.workspace.loadIfNeeded()
        fixture.workspace.settings.generatesTitles = true
        fixture.workspace.settings.notifiesOnBackgroundCompletion = true
        await bind(fixture, apiKeys: ["test-client-key-0001"])
        let id = fixture.workspace.createConversation()
        fixture.workspace.send("Original question", attachments: [], in: id)
        let notified = await waitUntil { await gate.hasStarted }
        let other = try CPAServer(baseURL: "https://other.example.com")
        await fixture.workspace.bind(server: other) { nil }
        await gate.release()
        let finished = await waitUntil { [workspace = fixture.workspace] in
            await MainActor.run { !workspace.isGenerating(id) }
        }

        #expect(notified && finished)
        #expect(fixture.engine.streamRequests.first?.baseURL.host == server.baseURL.host)
        #expect(fixture.engine.completeRequests.isEmpty)
        #expect(fixture.workspace.conversation(id)?.title == "Original question")
    }

    @Test @MainActor func keyRemovalFailureStaysVisibleAndCanBeRetried() async throws {
        let secrets = FailingRemovalSecretStore()
        let workspace = ChatWorkspaceModel(persistence: ChatMemoryPersistence(), secrets: secrets,
                                           modelCatalog: { _, _ in FakeModelCatalog(result: .success([])) })
        await workspace.bind(server: server) { nil }
        #expect(await workspace.useManualKey("test-client-key-0001"))

        await workspace.removeStoredKey()
        #expect(workspace.keyRemovalFailed)
        #expect(workspace.credentialState == .ready(hint: "••••0001", isManual: true))
        do {
            try await workspace.forget(server: server)
            Issue.record("Forgetting a connection reported success despite a Keychain error")
        } catch let error as CPAError {
            #expect(error.kind == .secureStorageFailure)
        }
        #expect(workspace.server == server)

        await secrets.allowRemoval()
        try await workspace.forget(server: server)
        #expect(workspace.credentialState == .unbound)
        #expect(!workspace.keyRemovalFailed)
        #expect(try await secrets.loadSecret(account: ChatSecrets.clientAPIKeyAccount(for: server)) == nil)
    }

    @Test @MainActor func manualKeyMarksIsManual() async {
        let fixture = makeFixture()
        await fixture.workspace.loadIfNeeded()
        await bind(fixture, apiKeys: [])

        let accepted = await fixture.workspace.useManualKey("test-manual-key-9999")
        #expect(accepted)
        guard case .ready(let hint, let isManual) = await fixture.workspace.credentialState else {
            Issue.record("expected .ready")
            return
        }
        #expect(isManual)
        #expect(hint == "••••9999")

        #expect(await fixture.workspace.useManualKey("   ") == false)
    }

    @Test @MainActor func backgroundExpirationInterruptsAndNotifiesOnSuccess() async {
        let fixture = makeFixture()
        fixture.engine.block()
        await fixture.workspace.loadIfNeeded()
        await bind(fixture, apiKeys: ["test-client-key-0001"])
        let conversationID = await fixture.workspace.createConversation()
        await fixture.workspace.send("后台", attachments: [], in: conversationID)
        _ = await waitUntil { [workspace = fixture.workspace] in
            await MainActor.run { workspace.isGenerating(conversationID) }
        }

        await fixture.runner.fireExpiration()
        _ = await waitUntil { [workspace = fixture.workspace] in
            await MainActor.run { !workspace.isGenerating(conversationID) }
        }
        let assistant = await fixture.workspace.conversation(conversationID)?
            .messages.last(where: { $0.role == .assistant })
        #expect(assistant?.status == .interrupted)
        #expect(assistant?.failure == .interruptedInBackground)
        #expect(fixture.runner.notificationCount == 0)
    }

    @Test @MainActor func notificationOnlyWhenInBackgroundAndEnabled() async {
        let fixture = makeFixture()
        fixture.engine.respond(with: [.snapshot(text: "完成", reasoning: nil)])
        await fixture.workspace.loadIfNeeded()
        await bind(fixture, apiKeys: ["test-client-key-0001"])

        // Foreground success → no notification.
        let foregroundID = await fixture.workspace.createConversation()
        await fixture.workspace.send("前台", attachments: [], in: foregroundID)
        _ = await waitUntil { [workspace = fixture.workspace] in
            await MainActor.run { !workspace.isGenerating(foregroundID) }
        }
        #expect(fixture.runner.notificationCount == 0)

        // Background success → one notification with the conversation title.
        fixture.runner.inBackground = true
        let backgroundID = await fixture.workspace.createConversation()
        await fixture.workspace.send("后台完成", attachments: [], in: backgroundID)
        _ = await waitUntil { [workspace = fixture.workspace] in
            await MainActor.run { !workspace.isGenerating(backgroundID) }
        }
        #expect(fixture.runner.notificationCount == 1)
    }

    @Test @MainActor func checkpointSurvivesFailedTerminalWrite() async throws {
        let store = RecordingPersistence()
        await store.failTerminalWrites()
        let fixture = makeFixture(persistence: store, streamingPersistInterval: .zero)
        await fixture.workspace.loadIfNeeded()
        await bind(fixture, apiKeys: ["test-client-key-0001"])
        fixture.workspace.settings.generatesTitles = false
        fixture.engine.respond(with: [.snapshot(text: "T1", reasoning: "R1")])
        fixture.engine.block()
        let id = fixture.workspace.createConversation()
        fixture.workspace.send("B5", attachments: [], in: id)
        let written = await waitUntil { await store.stored(id)?.messages.last?.text == "T1" }
        #expect(written)
        fixture.runner.fireExpiration()
        fixture.workspace.stop(id)
        let ended = await waitUntil { await !fixture.workspace.isGenerating(id) }
        #expect(ended)
        #expect(fixture.workspace.conversation(id)?.messages.last?.failure == .interruptedInBackground)
        #expect(fixture.workspace.unsavedConversations.contains(id))
        let lastWrite = try #require(await store.stored(id)?.messages.last)
        #expect(lastWrite.status == .streaming && lastWrite.reasoning == "R1")
        #expect(fixture.runner.endedTokens.count == 1 && fixture.runner.notifications.isEmpty)
        #expect(fixture.engine.streamRequests.count == 1)
    }

    @Test @MainActor func expiryAfterCompletionCannotReplaceTerminalState() async {
        let fixture = makeFixture()
        await fixture.workspace.loadIfNeeded()
        await bind(fixture, apiKeys: ["test-client-key-0001"])
        fixture.workspace.settings.generatesTitles = false
        fixture.runner.inBackground = true
        let gate = HeldDiscovery()
        fixture.runner.waitAfterNotification = { await gate.wait() }
        fixture.engine.respond(with: [.snapshot(text: "T1", reasoning: "R1")])
        let id = fixture.workspace.createConversation()
        fixture.workspace.send("B5", attachments: [], in: id)
        let notified = await waitUntil { await gate.hasStarted }
        #expect(notified)
        fixture.runner.fireExpiration()
        await gate.release()
        let ended = await waitUntil { await !fixture.workspace.isGenerating(id) }
        #expect(ended)
        #expect(fixture.workspace.conversation(id)?.messages.last?.status == .complete)
        #expect(fixture.runner.endedTokens.count == 1 && fixture.runner.notifications.count == 1)
    }

    // MARK: - Search step

    /// Configures web search on the workspace + conversation and returns a
    /// gated search client.
    @MainActor
    private func enableSearch(_ fixture: Fixture, search: FakeSearchClient,
                              in conversationID: UUID) async {
        fixture.workspace.settings.searchProvider = .tavily
        _ = await fixture.workspace.saveSearchKey("test-search-key-0001", for: .tavily)
        fixture.workspace.updateConversation(conversationID) { $0.isWebSearchEnabled = true }
    }

    @Test @MainActor func userMessageAndPlaceholderVisibleWhileSearchSuspended() async {
        let search = FakeSearchClient()
        search.gate()
        search.respond(with: [
            ChatSearchSource(title: "结果", url: URL(string: "https://example.test/1")!,
                             snippet: "摘要"),
        ])
        let fixture = makeFixture(searchClient: search)
        fixture.engine.respond(with: [.snapshot(text: "回答", reasoning: nil)])
        await fixture.workspace.loadIfNeeded()
        await bind(fixture, apiKeys: ["test-client-key-0001"])
        let conversationID = await fixture.workspace.createConversation()
        await enableSearch(fixture, search: search, in: conversationID)

        fixture.workspace.send("查一下", attachments: [], in: conversationID)

        // While the search request is still in flight, the user message and
        // the streaming placeholder must already be visible.
        let visible = await waitUntil { [workspace = fixture.workspace] in
            await MainActor.run {
                guard let conversation = workspace.conversation(conversationID),
                      conversation.messages.count == 2 else { return false }
                return conversation.messages[0].role == .user
                    && conversation.messages[0].text == "查一下"
                    && conversation.messages[1].role == .assistant
                    && conversation.messages[1].status == .streaming
            }
        }
        #expect(visible)

        search.release()
        _ = await waitUntil { [workspace = fixture.workspace] in
            await MainActor.run { !workspace.isGenerating(conversationID) }
        }
        #expect(search.queries == ["查一下"])
        let assistant = fixture.workspace.conversation(conversationID)?
            .messages.last(where: { $0.role == .assistant })
        #expect(assistant?.status == .complete)
        #expect(assistant?.searchSources.count == 1)
        #expect(fixture.engine.streamRequests.last?.prompt.contains("[1] 结果") == true)
    }

    @Test @MainActor func stopDuringSearchEndsStoppedWithoutSearchFailedOrEngineCall() async {
        let search = FakeSearchClient()
        search.gate()
        let fixture = makeFixture(searchClient: search)
        await fixture.workspace.loadIfNeeded()
        await bind(fixture, apiKeys: ["test-client-key-0001"])
        let conversationID = await fixture.workspace.createConversation()
        await enableSearch(fixture, search: search, in: conversationID)

        fixture.workspace.send("查一下", attachments: [], in: conversationID)

        // Wait until the search request is actually in flight.
        let inFlight = await waitUntil { search.queries == ["查一下"] }
        #expect(inFlight)
        fixture.workspace.stop(conversationID)
        search.release()

        let done = await waitUntil { [workspace = fixture.workspace] in
            await MainActor.run { !workspace.isGenerating(conversationID) }
        }
        #expect(done)
        let assistant = fixture.workspace.conversation(conversationID)?
            .messages.last(where: { $0.role == .assistant })
        #expect(assistant?.status == .stopped)
        #expect(assistant?.failure == nil)
        #expect(fixture.engine.streamRequests.isEmpty)
    }

    // MARK: - Persistence ordering

    @Test @MainActor func persistenceWritesAreSerializedAndFinalStateLandsLast() async {
        let persistence = RecordingPersistence()
        let fixture = makeFixture(persistence: persistence)
        fixture.engine.respond(with: [.snapshot(text: "回复", reasoning: nil)])
        fixture.workspace.settings.generatesTitles = false
        fixture.workspace.settings.notifiesOnBackgroundCompletion = false
        await fixture.workspace.loadIfNeeded()
        await bind(fixture, apiKeys: ["test-client-key-0001"])
        let conversationID = await fixture.workspace.createConversation()
        fixture.workspace.send("你好", attachments: [], in: conversationID)

        // isGenerating only clears after the final write is awaited, so once
        // generation is done the last write on disk is the final state.
        let done = await waitUntil { [workspace = fixture.workspace] in
            await MainActor.run { !workspace.isGenerating(conversationID) }
        }
        #expect(done)
        let writes = await persistence.saves(for: conversationID)
        #expect(writes.count >= 2)
        #expect(writes.first?.lastStatus == .streaming)
        #expect(writes.last?.lastStatus == .complete)
    }

    @Test @MainActor func emptyConversationIsNeverPersisted() async {
        let persistence = RecordingPersistence()
        let fixture = makeFixture(persistence: persistence)
        await fixture.workspace.loadIfNeeded()
        await bind(fixture, apiKeys: ["test-client-key-0001"])
        let conversationID = await fixture.workspace.createConversation()
        fixture.workspace.updateConversation(conversationID) { $0.title = "空会话" }

        // Enqueue a guaranteed write after the skipped ones, then wait for it:
        // proves the queue drained with no conversation write for this id.
        fixture.workspace.addMemory("标记")
        let drained = await waitUntil {
            await persistence.operations.contains(.saveMemories(1))
        }
        #expect(drained)
        let saves = await persistence.saves(for: conversationID)
        #expect(saves.isEmpty)
    }

    @Test @MainActor func loadDropsConversationsWithNoMessages() async {
        let populated = ChatConversation(
            modelID: "test-model",
            messages: [ChatMessage(role: .user, text: "留")])
        let empty = ChatConversation(modelID: "test-model")
        let persistence = RecordingPersistence(seeded: [empty, populated])
        let fixture = makeFixture(persistence: persistence)
        await fixture.workspace.loadIfNeeded()
        #expect(fixture.workspace.conversations.map(\.id) == [populated.id])
    }

    // MARK: - Audit regressions (batch 1)

    @MainActor
    private func completeTurn(_ fixture: Fixture, _ text: String, in id: UUID) async {
        fixture.workspace.send(text, attachments: [], in: id)
        _ = await waitUntil { [workspace = fixture.workspace] in
            await MainActor.run { !workspace.isGenerating(id) }
        }
    }

    @Test @MainActor func deletingLastMessageRemovesConversationFromDisk() async {
        let persistence = RecordingPersistence()
        let fixture = makeFixture(persistence: persistence)
        fixture.engine.respond(with: [.snapshot(text: "回复", reasoning: nil)])
        fixture.workspace.settings.generatesTitles = false
        await fixture.workspace.loadIfNeeded()
        await bind(fixture, apiKeys: ["test-client-key-0001"])
        let id = fixture.workspace.createConversation()
        await completeTurn(fixture, "要删的问题", in: id)
        #expect(await persistence.stored(id) != nil)

        for message in fixture.workspace.conversation(id)?.messages ?? [] {
            fixture.workspace.deleteMessage(message.id, in: id)
        }
        fixture.workspace.addMemory("标记")
        let drained = await waitUntil { await persistence.operations.contains(.saveMemories(1)) }
        #expect(drained)
        #expect(await persistence.stored(id) == nil)

        let relaunched = makeFixture(persistence: persistence)
        await relaunched.workspace.loadIfNeeded()
        #expect(relaunched.workspace.conversation(id) == nil)
    }

    @Test @MainActor func rerunWithoutSendConditionsKeepsLaterMessages() async throws {
        let fixture = makeFixture()
        fixture.engine.respond(with: [.snapshot(text: "回答", reasoning: nil)])
        fixture.workspace.settings.generatesTitles = false
        await fixture.workspace.loadIfNeeded()
        await bind(fixture, apiKeys: ["test-client-key-0001"])
        let id = fixture.workspace.createConversation()
        await completeTurn(fixture, "第一问", in: id)
        await completeTurn(fixture, "第二问", in: id)
        let before = try #require(fixture.workspace.conversation(id)?.messages)
        #expect(before.count == 4)

        // Missing model: nothing may be truncated.
        fixture.workspace.updateConversation(id) { $0.modelID = nil }
        fixture.workspace.regenerate(before[1].id, in: id)
        fixture.workspace.editAndResend(before[0].id, text: "改过的第一问", in: id)
        #expect(fixture.workspace.conversation(id)?.messages == before)

        // Missing key: nothing may be truncated either.
        fixture.workspace.updateConversation(id) { $0.modelID = "test-model" }
        await fixture.workspace.removeStoredKey()
        #expect(fixture.workspace.credentialState == .missingKey)
        fixture.workspace.regenerate(before[1].id, in: id)
        fixture.workspace.editAndResend(before[0].id, text: "改过的第一问", in: id)
        _ = await waitUntil { [workspace = fixture.workspace] in
            await MainActor.run { !workspace.isGenerating(id) }
        }
        #expect(fixture.workspace.conversation(id)?.messages == before)
        #expect(fixture.engine.streamRequests.count == 2)
    }

    @Test @MainActor func loadMarksOrphanedStreamingRepliesInterrupted() async {
        let user = ChatMessage(role: .user, text: "问")
        let partial = ChatMessage(role: .assistant, text: "半截回复", modelID: "test-model", status: .streaming)
        let seeded = ChatConversation(modelID: "test-model", messages: [user, partial])
        let persistence = RecordingPersistence(seeded: [seeded])
        let fixture = makeFixture(persistence: persistence)
        await fixture.workspace.loadIfNeeded()

        let recovered = fixture.workspace.conversation(seeded.id)?.messages.last
        #expect(recovered?.status == .interrupted)
        #expect(recovered?.failure == .generationInterrupted)
        #expect(recovered?.text == "半截回复")
        let rewritten = await waitUntil {
            await persistence.saves(for: seeded.id).last?.lastStatus == .interrupted
        }
        #expect(rewritten)
    }

    @Test @MainActor func conversationFromAnotherServerNeedsConfirmationBeforeSending() async throws {
        let fixture = makeFixture()
        fixture.engine.respond(with: [.snapshot(text: "回答", reasoning: nil)])
        fixture.workspace.settings.generatesTitles = false
        await fixture.workspace.loadIfNeeded()
        await bind(fixture, apiKeys: ["test-client-key-0001"])
        let id = fixture.workspace.createConversation()
        await completeTurn(fixture, "只给 A 看的问题", in: id)
        #expect(fixture.workspace.conversation(id)?.serverIdentifier == server.identifier)
        #expect(fixture.workspace.serverChange(for: id) == nil)

        let other = try CPAServer(baseURL: "https://other.example.com")
        await fixture.workspace.bind(server: other) { nil }
        #expect(await fixture.workspace.useManualKey("test-client-key-0002"))
        let change = try #require(fixture.workspace.serverChange(for: id))
        #expect(change.previousServerIdentifier == server.identifier)
        #expect(change.currentServerIdentifier == other.identifier)
        #expect(change.messageCount == 2)

        let before = try #require(fixture.workspace.conversation(id)?.messages)
        #expect(!fixture.workspace.send("继续", attachments: [], in: id))
        #expect(!fixture.workspace.regenerate(before[1].id, in: id))
        #expect(!fixture.workspace.editAndResend(before[0].id, text: "改", in: id))
        #expect(fixture.workspace.conversation(id)?.messages == before)
        #expect(fixture.engine.streamRequests.count == 1)

        #expect(fixture.workspace.send("继续", attachments: [], in: id, confirmingServerChange: true))
        _ = await waitUntil { [workspace = fixture.workspace] in
            await MainActor.run { !workspace.isGenerating(id) }
        }
        #expect(fixture.engine.streamRequests.count == 2)
        #expect(fixture.engine.streamRequests.last?.baseURL.host == other.baseURL.host)
        #expect(fixture.workspace.conversation(id)?.serverIdentifier == other.identifier)
        #expect(fixture.workspace.serverChange(for: id) == nil)
    }

    @Test @MainActor func legacyConversationWithoutServerNeedsConfirmation() async throws {
        let legacy = ChatConversation(
            modelID: "test-model",
            messages: [ChatMessage(role: .user, text: "旧问题"),
                       ChatMessage(role: .assistant, text: "旧回答", modelID: "test-model")])
        let fixture = makeFixture(persistence: RecordingPersistence(seeded: [legacy]))
        await fixture.workspace.loadIfNeeded()
        await bind(fixture, apiKeys: ["test-client-key-0001"])

        let change = try #require(fixture.workspace.serverChange(for: legacy.id))
        #expect(change.previousServerIdentifier == nil)
        #expect(!fixture.workspace.send("继续", attachments: [], in: legacy.id))
        #expect(fixture.engine.streamRequests.isEmpty)
        // A fresh conversation on the bound server needs no confirmation.
        let fresh = fixture.workspace.createConversation()
        #expect(fixture.workspace.serverChange(for: fresh) == nil)
        #expect(fixture.workspace.conversation(fresh)?.serverIdentifier == server.identifier)
    }

    @Test @MainActor func completionNotificationCarriesNoConversationText() async {
        let fixture = makeFixture()
        fixture.engine.respond(with: [.snapshot(text: "私密回复", reasoning: nil)])
        fixture.runner.inBackground = true
        await fixture.workspace.loadIfNeeded()
        await bind(fixture, apiKeys: ["test-client-key-0001"])
        let id = fixture.workspace.createConversation()
        await completeTurn(fixture, "锁屏上不该出现的问题", in: id)

        #expect(fixture.runner.notifications == [id])
        for text in [ChatCompletionNotice.title, ChatCompletionNotice.body] {
            #expect(!text.contains("锁屏上不该出现"))
            #expect(!text.contains("私密回复"))
        }
        #expect(ChatCompletionNotice.userInfo(for: id) == ["conversationID": id.uuidString])
        #expect(ChatCompletionNotice.conversationID(from: ["conversationID": id.uuidString]) == id)
    }

    @Test @MainActor func deleteAllReportsFailureAndKeepsRemainingRecordsVisible() async {
        let seeded = [
            ChatConversation(messages: [ChatMessage(role: .user, text: "一")]),
            ChatConversation(messages: [ChatMessage(role: .user, text: "二")]),
        ]
        let persistence = FailingBulkRemovalPersistence()
        for conversation in seeded { try? await persistence.saveConversation(conversation) }
        let fixture = makeFixture(persistence: persistence)
        await fixture.workspace.loadIfNeeded()
        #expect(fixture.workspace.conversations.count == 2)

        #expect(await fixture.workspace.deleteAllConversations() == false)
        #expect(Set(fixture.workspace.conversations.map(\.id)) == Set(seeded.map(\.id)))

        await persistence.allowRemoval()
        #expect(await fixture.workspace.deleteAllConversations())
        #expect(fixture.workspace.conversations.isEmpty)
        #expect(await (try? persistence.loadConversations())?.isEmpty == true)
    }

    @Test @MainActor func streamingRepliesArePersistedBeforeTheyFinish() async {
        let persistence = RecordingPersistence()
        let fixture = makeFixture(persistence: persistence, streamingPersistInterval: .zero)
        fixture.engine.respond(with: [
            .snapshot(text: "部分", reasoning: nil),
            .snapshot(text: "部分回复", reasoning: nil),
        ])
        fixture.workspace.settings.generatesTitles = false
        await fixture.workspace.loadIfNeeded()
        await bind(fixture, apiKeys: ["test-client-key-0001"])
        let id = fixture.workspace.createConversation()
        await completeTurn(fixture, "问", in: id)

        let writes = await persistence.saves(for: id)
        #expect(writes.contains { $0.lastStatus == .streaming && $0.lastText == "部分" })
        #expect(writes.last?.lastStatus == .complete)
        #expect(writes.last?.lastText == "部分回复")
    }

    @Test @MainActor func unrememberedConnectionKeepsClientKeyInMemoryOnly() async throws {
        let fixture = makeFixture()
        fixture.engine.respond(with: [.snapshot(text: "回答", reasoning: nil)])
        fixture.workspace.settings.generatesTitles = false
        await fixture.workspace.loadIfNeeded()
        let account = ChatSecrets.clientAPIKeyAccount(for: server)
        // A key stored by an earlier remembered connection.
        await fixture.workspace.bind(server: server) { nil }
        #expect(await fixture.workspace.useManualKey("test-client-key-0009"))
        #expect(try await fixture.secrets.loadSecret(account: account) != nil)

        await fixture.transport.respond("/v0/management/api-keys", status: 200,
                                        body: #"{"api-keys":["test-client-key-0001"]}"#)
        let discovery = makeDiscovery(fixture.transport)
        await fixture.workspace.bind(server: server, persistsKey: false) { discovery }

        #expect(!fixture.workspace.persistsKey)
        #expect(fixture.workspace.credentialState == .ready(hint: "••••0001", isManual: false))
        #expect(try await fixture.secrets.loadSecret(account: account) == nil)
        #expect(await fixture.workspace.useManualKey("test-client-key-0002"))
        #expect(try await fixture.secrets.loadSecret(account: account) == nil)

        let id = fixture.workspace.createConversation()
        await completeTurn(fixture, "临时连接", in: id)
        #expect(fixture.engine.streamRequests.last?.apiKey.exposedValue == "test-client-key-0002")
    }

    // MARK: - Audit regressions (batch 2)

    @Test @MainActor func concurrentLoadsShareOneReadAndKeepConversationsCreatedMeanwhile() async {
        let persistence = GatedLoadPersistence()
        let stored = ChatConversation(messages: [ChatMessage(role: .user, text: "旧记录")])
        await persistence.seed(stored)
        let fixture = makeFixture(persistence: persistence)
        let first = Task { await fixture.workspace.loadIfNeeded() }
        let second = Task { await fixture.workspace.loadIfNeeded() }
        let started = await waitUntil { await persistence.gate.hasStarted }
        #expect(started)
        #expect(!fixture.workspace.isLoaded)
        let created = fixture.workspace.createConversation()

        await persistence.gate.release()
        await first.value
        await second.value
        #expect(fixture.workspace.isLoaded)
        #expect(await persistence.loadCount == 1)
        #expect(Set(fixture.workspace.conversations.map(\.id)) == [stored.id, created])
    }

    @Test @MainActor func imageOnlyQuestionStaysInLaterHistory() async {
        let fixture = makeFixture()
        fixture.engine.respond(with: [.snapshot(text: "这是一只猫", reasoning: nil)])
        fixture.workspace.settings.generatesTitles = false
        await fixture.workspace.loadIfNeeded()
        await bind(fixture, apiKeys: ["test-client-key-0001"])
        let id = fixture.workspace.createConversation()
        let image = ChatImageAttachment(mimeType: "image/jpeg", data: Data([0xFF, 0xD8, 0xFF]))
        fixture.workspace.send("", attachments: [image], in: id)
        _ = await waitUntil { [workspace = fixture.workspace] in
            await MainActor.run { !workspace.isGenerating(id) }
        }
        await completeTurn(fixture, "图里是什么颜色", in: id)

        let history = fixture.engine.streamRequests.last?.history ?? []
        #expect(history.first?.role == .user)
        #expect(history.first?.attachments == [image])
        #expect(history.count == 2)
    }

    @Test @MainActor func generatedTitleNeverReplacesAUserTitle() async {
        let fixture = makeFixture()
        fixture.engine.respond(with: [.snapshot(text: "回答", reasoning: nil)])
        await fixture.workspace.loadIfNeeded()
        await bind(fixture, apiKeys: ["test-client-key-0001"])

        // Set before the first message.
        let preset = fixture.workspace.createConversation()
        fixture.workspace.renameConversation(preset, title: "我的标题")
        await completeTurn(fixture, "第一个问题", in: preset)
        _ = await waitUntil(timeoutNanoseconds: 500_000_000) { [workspace = fixture.workspace] in
            await MainActor.run { workspace.conversation(preset)?.title != "我的标题" }
        }
        #expect(fixture.workspace.conversation(preset)?.title == "我的标题")

        // Renamed while the title request is still running.
        let gate = HeldDiscovery()
        fixture.engine.completeGate = { await gate.wait() }
        let renamed = fixture.workspace.createConversation()
        await completeTurn(fixture, "另一个问题", in: renamed)
        let requested = await waitUntil { await gate.hasStarted }
        fixture.workspace.renameConversation(renamed, title: "改过的标题")
        await gate.release()
        _ = await waitUntil(timeoutNanoseconds: 1_000_000_000) { [workspace = fixture.workspace] in
            await MainActor.run { workspace.conversation(renamed)?.title != "改过的标题" }
        }
        #expect(requested)
        #expect(fixture.workspace.conversation(renamed)?.title == "改过的标题")
    }

    @Test @MainActor func modelCatalogAuthorizationStatusesSuggestAnotherKey() {
        #expect(ChatWorkspaceModel.chatFailure(for: CPAError(.requestRejected, statusCode: 401))
                == .unauthorized(statusCode: 401))
        #expect(ChatWorkspaceModel.chatFailure(for: CPAError(.requestRejected, statusCode: 403))
                == .forbidden(statusCode: 403))
        #expect(ChatWorkspaceModel.chatFailure(for: CPAError(.requestRejected, statusCode: 500))
                == .upstream(statusCode: 500))
    }

    @Test @MainActor func conversationOpenedBeforeModelsLoadGetsDefaultModel() async {
        let fixture = makeFixture()
        await fixture.workspace.loadIfNeeded()
        let id = fixture.workspace.createConversation()
        #expect(fixture.workspace.conversation(id)?.modelID == nil)
        await bind(fixture, apiKeys: ["test-client-key-0001"])
        let assigned = await waitUntil { [workspace = fixture.workspace] in
            await MainActor.run { workspace.conversation(id)?.modelID == "test-model" }
        }
        #expect(assigned)
    }

    @Test @MainActor func continueAfterNetworkLossAndAgainAfterColdStart() async throws {
        let persistence = ChatMemoryPersistence()
        let first = makeFixture(persistence: persistence)
        let chat = first.workspace
        await chat.loadIfNeeded()
        await bind(first, apiKeys: ["test-client-key-0001"])
        let id = chat.createConversation()
        let image = ChatImageAttachment(mimeType: "image/png", data: Data([1, 2]))
        let original = "```swift\nlet resultingValue"
        first.engine.respond(with: [.snapshot(text: original, reasoning: "r1"), .usage(.init(inputTokens: 100))])
        first.engine.fail(with: URLError(.networkConnectionLost))
        #expect(chat.send("Finish this", attachments: [image], in: id))
        try await waitForGeneration(chat, id: id)
        let reply = try #require(chat.conversation(id)?.messages.last)
        #expect(reply.failure == .network)
        let target = try #require(chat.continuation(for: id))
        #expect(!target.isRetry)

        first.engine.respond(with: [.snapshot(text: "let res", reasoning: nil),
                                    .snapshot(text: "let resultingValue = ", reasoning: "r2"),
                                    .usage(.init(inputTokens: 8)), .usage(.init(inputTokens: 12))])
        first.engine.fail(with: URLError(.timedOut))
        #expect(chat.continueReply(target))
        #expect(!chat.continueReply(target))
        try await waitForGeneration(chat, id: id)
        #expect(!chat.continueReply(target))
        let req = try #require(first.engine.streamRequests.last)
        #expect(req.history.map(\.text) == ["Finish this", original])
        #expect(req.history.first?.attachments == [image])
        #expect(req.images.isEmpty)
        #expect(req.prompt.contains("直接接写"))
        #expect(first.engine.streamRequests.count == 2)

        let reopened = makeFixture(persistence: persistence)
        await reopened.workspace.loadIfNeeded()
        await bind(reopened, apiKeys: ["test-client-key-0001"])
        #expect(reopened.engine.streamRequests.isEmpty)
        let saved = try #require(reopened.workspace.conversation(id)?.messages.last)
        #expect(saved.id == reply.id)
        #expect(saved.text == original + "let resultingValue = ")
        #expect(saved.usage?.inputTokens == 112)
        #expect(saved.reasoning == "r1\n\nr2")
        reopened.engine.respond(with: [.snapshot(text: "42\n```", reasoning: nil)])
        let again = try #require(reopened.workspace.continuation(for: id))
        #expect(reopened.workspace.continueReply(again))
        try await waitForGeneration(reopened.workspace, id: id)
        let final = try #require(reopened.workspace.conversation(id)?.messages)
        #expect(final.map(\.id) == [req.history[0].id, reply.id])
        #expect(final.last?.text == original + "let resultingValue = 42\n```")
        #expect(final.last?.attempts?.map(\.status) == [.failed, .failed, .complete])
        #expect(final.last?.attempts?.compactMap(\.usage).count == 2)
        #expect(final.last?.reasoning == saved.reasoning)
        #expect(final.last?.createdAt == reply.createdAt)
        #expect(reopened.workspace.continuation(for: id) == nil)
    }

    @MainActor
    private func waitForGeneration(_ chat: ChatWorkspaceModel, id: UUID) async throws {
        let finished = await waitUntil { await !chat.isGenerating(id) }
        try #require(finished)
    }

    @Test @MainActor func continuationThatOnlyReplaysSavedTextFailsWithUsageAndCanRetry() async throws {
        let question = ChatMessage(role: .user, text: "Continue")
        let initialUsage = ChatTokenUsage(inputTokens: 3, outputTokens: 4)
        var reply = ChatMessage(role: .assistant, text: "First, install the package.",
                                modelID: "test-model", usage: initialUsage, status: .stopped)
        reply.attempts = [ChatReplyAttempt(modelID: "test-model", status: .stopped,
                                           failure: nil, usage: initialUsage)]
        let seeded = ChatConversation(modelID: "test-model", messages: [question, reply],
                                      serverIdentifier: server.identifier)
        let fixture = makeFixture(persistence: RecordingPersistence(seeded: [seeded]))
        await fixture.workspace.loadIfNeeded()
        await bind(fixture, apiKeys: ["test-client-key-0001"])
        fixture.engine.respond(with: [
            .snapshot(text: reply.text, reasoning: nil),
            .usage(.init(inputTokens: 5, outputTokens: 6)),
        ])

        let target = try #require(fixture.workspace.continuation(for: seeded.id))
        #expect(fixture.workspace.continueReply(target))
        try await waitForGeneration(fixture.workspace, id: seeded.id)

        let result = try #require(fixture.workspace.conversation(seeded.id)?.messages.last)
        #expect(result.id == reply.id)
        #expect(result.text == reply.text)
        #expect(result.status == .failed)
        #expect(result.failure == .continuationAddedNothing)
        #expect(result.attempts?.count == 2)
        #expect(result.attempts?.last?.usage == ChatTokenUsage(inputTokens: 5, outputTokens: 6))
        #expect(result.usage == ChatTokenUsage(inputTokens: 8, outputTokens: 10))
        #expect(fixture.workspace.continuation(for: seeded.id) != nil)
    }

    @Test @MainActor func emptyRetryWithNoStreamTextRemainsRetryEligible() async throws {
        let question = ChatMessage(role: .user, text: "Try again")
        var reply = ChatMessage(role: .assistant, text: "", modelID: "test-model", status: .interrupted)
        reply.attempts = [ChatReplyAttempt(modelID: "test-model", status: .interrupted,
                                           failure: nil, usage: nil)]
        let seeded = ChatConversation(modelID: "test-model", messages: [question, reply],
                                      serverIdentifier: server.identifier)
        let fixture = makeFixture(persistence: RecordingPersistence(seeded: [seeded]))
        await fixture.workspace.loadIfNeeded()
        await bind(fixture, apiKeys: ["test-client-key-0001"])

        let target = try #require(fixture.workspace.continuation(for: seeded.id))
        #expect(target.isRetry)
        #expect(fixture.workspace.continueReply(target))
        try await waitForGeneration(fixture.workspace, id: seeded.id)

        let result = try #require(fixture.workspace.conversation(seeded.id)?.messages.last)
        #expect(result.status == .failed)
        #expect(result.failure == .continuationAddedNothing)
        #expect(fixture.workspace.continuation(for: seeded.id) != nil)
    }

    @Test @MainActor func legacyContinuationRestoresAndReusesSlashSkillPrompt() async throws {
        let question = ChatMessage(role: .user, text: "/translate Hello")
        var reply = ChatMessage(role: .assistant, text: "unfinished response",
                                modelID: "test-model", status: .interrupted)
        reply.attempts = nil
        reply.expandedPrompt = nil
        let seeded = ChatConversation(modelID: "test-model", messages: [question, reply],
                                      serverIdentifier: server.identifier)
        let fixture = makeFixture(persistence: RecordingPersistence(seeded: [seeded]))
        await fixture.workspace.loadIfNeeded()
        await bind(fixture, apiKeys: ["test-client-key-0001"])
        let chat = fixture.workspace
        let skill = try #require(chat.skills.first(where: { $0.command == "translate" }))
        fixture.engine.respond(with: [.snapshot(text: " more", reasoning: nil)])
        fixture.engine.fail(with: URLError(.networkConnectionLost))

        let firstTarget = try #require(chat.continuation(for: seeded.id))
        #expect(chat.continueReply(firstTarget))
        try await waitForGeneration(chat, id: seeded.id)

        let expansion = skill.prompt + "\n\nHello"
        let firstRequest = try #require(fixture.engine.streamRequests.last)
        #expect(firstRequest.history.contains(where: { $0.text == expansion }))
        #expect(chat.conversation(seeded.id)?.messages.last?.expandedPrompt == expansion)
        chat.deleteSkill(skill.id)
        #expect(!chat.skills.contains(where: { $0.command == "translate" }))
        fixture.engine.respond(with: [.snapshot(text: " again", reasoning: nil)])
        fixture.engine.fail(with: URLError(.networkConnectionLost))

        let secondTarget = try #require(chat.continuation(for: seeded.id))
        #expect(chat.continueReply(secondTarget))
        try await waitForGeneration(chat, id: seeded.id)

        let secondRequest = try #require(fixture.engine.streamRequests.last)
        #expect(secondRequest.history.contains(where: { $0.text == expansion }))
    }

    @Test @MainActor func nonLegacyContinuationWithoutExpansionUsesRawSlashText() async throws {
        let question = ChatMessage(role: .user, text: "/translate Hello")
        var reply = ChatMessage(role: .assistant, text: "unfinished response",
                                modelID: "test-model", status: .interrupted)
        reply.attempts = [ChatReplyAttempt(modelID: "test-model", status: .interrupted,
                                           failure: nil, usage: nil)]
        let seeded = ChatConversation(modelID: "test-model", messages: [question, reply],
                                      serverIdentifier: server.identifier)
        let fixture = makeFixture(persistence: RecordingPersistence(seeded: [seeded]))
        await fixture.workspace.loadIfNeeded()
        await bind(fixture, apiKeys: ["test-client-key-0001"])
        fixture.engine.respond(with: [.snapshot(text: " more", reasoning: nil)])

        let target = try #require(fixture.workspace.continuation(for: seeded.id))
        #expect(fixture.workspace.continueReply(target))
        try await waitForGeneration(fixture.workspace, id: seeded.id)

        let request = try #require(fixture.engine.streamRequests.last)
        #expect(request.history.contains(where: { $0.text == question.text }))
        #expect(!request.history.contains(where: { $0.text.contains("将以下内容翻译成中文") }))
        #expect(fixture.workspace.conversation(seeded.id)?.messages.last?.expandedPrompt == nil)
    }

    @Test @MainActor func retryReasoningOnlyLegacyReplyRequiresCurrentDestinationAndParent() async throws {
        let question = ChatMessage(role: .user, text: "original")
        let reply = ChatMessage(role: .assistant, text: "", reasoning: "saved", modelID: "test-model", status: .interrupted)
        let seeded = ChatConversation(modelID: "test-model", messages: [question, reply], serverIdentifier: "other")
        let fixture = makeFixture(persistence: RecordingPersistence(seeded: [seeded]))
        let chat = fixture.workspace
        let id = seeded.id
        await chat.loadIfNeeded()
        await bind(fixture, apiKeys: ["test-client-key-0001"])
        let target = try #require(chat.continuation(for: id))
        #expect(target.isRetry)
        #expect(!chat.continueReply(target))
        chat.updateConversation(id) { $0.modelID = "removed" }
        #expect(chat.continuation(for: id) == nil)
        chat.updateConversation(id) { $0.modelID = "test-model" }
        await chat.removeStoredKey()
        #expect(chat.continuation(for: id) == nil)
        #expect(await chat.useManualKey("test-client-key-0002"))
        #expect(!chat.continueReply(target, confirmingServerChange: true))
        chat.updateConversation(id) { $0.messages.append(ChatMessage(role: .user, text: "later")) }
        #expect(chat.continuation(for: id) == nil)
        chat.updateConversation(id) { $0.messages.removeLast() }
        #expect(fixture.engine.streamRequests.isEmpty)
        let current = try #require(chat.continuation(for: id))
        fixture.engine.respond(with: [.snapshot(text: "answer", reasoning: nil)])
        #expect(chat.continueReply(current, confirmingServerChange: true))
        try await waitForGeneration(chat, id: id)
        let request = try #require(fixture.engine.streamRequests.last)
        #expect(request.prompt == question.text)
        #expect(request.history.isEmpty)
        let messages = try #require(chat.conversation(id)?.messages)
        #expect(messages.map(\.id) == seeded.messages.map(\.id))
        #expect(messages.last?.reasoning == "saved")
        #expect(messages.last?.text == "answer")
    }

    @Test func continuationBoundariesKeepLiteralWhitespaceFencesAndWordFragments() {
        for (base, new, expected) in [
            ("inter", "national", "national"),
            ("```swift\n", "    let", "    let"),
            ("Hello ", " world", " world"),
            ("a\n", "\n", "\n"),
            ("foo", "foo", "foo"),
            ("👩‍💻", "✅", "✅"),
            ("上一次输出的这一行文字", "输出的这一行文字。", "输出的这一行文字。")
        ] {
            var boundary = ChatContinuationBoundary(base: base)
            var visible = ""
            for i in 1...new.count {
                let result = boundary.suffix(for: String(new.prefix(i)))
                visible = result.visible + (result.pending ?? "")
            }
            #expect(visible == expected)
        }
        let long = String(repeating: "A long complete paragraph. ", count: 150)
        var replay = ChatContinuationBoundary(base: long)
        #expect(replay.suffix(for: String(long.prefix(1200))).visible.isEmpty)
        #expect(replay.suffix(for: long + "next").visible == "next")
        let base = "import sys\nprint(\"Processing complete\")\n"
        let continuation = "print(\"Processing complete\")\nprint(\"done\")\n"
        var repeatedLine = ChatContinuationBoundary(base: base)
        #expect(repeatedLine.suffix(for: continuation).visible == continuation)
        var fullReplay = ChatContinuationBoundary(base: base)
        #expect(fullReplay.suffix(for: base.prefix(8).description).visible.isEmpty)
        #expect(fullReplay.suffix(for: base + "next").visible == "next")
        var boundary = ChatContinuationBoundary(base: "line with enough distinct letters")
        let undecided = boundary.suffix(for: "line with")
        #expect(undecided.visible.isEmpty)
        #expect(undecided.pending == "line with")
        let diverged = boundary.suffix(for: "line with more")
        #expect(diverged.visible == "line with more")
        #expect(diverged.pending == nil)
        #expect(boundary.suffix(for: "line with more text").visible == "line with more text")
    }

    @Test @MainActor func staleExpirationCannotCancelTheNextAttemptOnTheSameReply() async throws {
        let fixture = makeFixture()
        await fixture.workspace.loadIfNeeded()
        await bind(fixture, apiKeys: ["test-client-key-0001"])
        let chat = fixture.workspace
        let id = chat.createConversation()
        fixture.engine.respond(with: [.snapshot(text: "partial", reasoning: nil)])
        fixture.engine.block()
        #expect(chat.send("question", attachments: [], in: id))
        let emitted = await waitUntil { await chat.conversation(id)?.messages.last?.text == "partial" }
        try #require(emitted)
        let expired = try #require(fixture.runner.currentExpiration)
        expired()
        try await waitForGeneration(chat, id: id)
        fixture.engine.respond(with: [.snapshot(text: " plus", reasoning: nil)])
        fixture.engine.block()
        #expect(chat.continueReply(try #require(chat.continuation(for: id))))
        let appended = await waitUntil { await chat.conversation(id)?.messages.last?.text == "partial plus" }
        try #require(appended)
        expired()
        chat.stop(id)
        try await waitForGeneration(chat, id: id)
        #expect(chat.conversation(id)?.messages.last?.text == "partial plus")
        #expect(chat.conversation(id)?.messages.last?.status == .stopped)
        #expect(fixture.runner.endedTokens.count == 2)
        #expect(chat.continuation(for: id) != nil)
    }

    @Test func longContinuationPinsCurrentTurnAndDropsOlderHistory() {
        let question = ChatMessage(role: .user, text: "q")
        let reply = ChatMessage(role: .assistant, text: String(repeating: "long ", count: 500) + "\n```swift\n"
                                + String(repeating: "code ", count: 1500) + "last-tail")
        let context = ChatPromptBuilder.continuationContext(
            earlier: [question], question: question, reply: reply, effectivePrompt: "expanded original", budget: 1800)
        #expect(context.omitted == 1)
        #expect(context.history.map(\.id) == [question.id, reply.id])
        #expect(context.history[0].text == "expanded original")
        #expect(context.history[1].text.hasSuffix("last-tail"))
        #expect(context.history[1].text.count < 1800)
        #expect(context.prompt.contains("swift"))
    }

    @Test @MainActor func newConversationReusesAnEmptyOne() async {
        let fixture = makeFixture()
        fixture.engine.respond(with: [.snapshot(text: "回答", reasoning: nil)])
        fixture.workspace.settings.generatesTitles = false
        await fixture.workspace.loadIfNeeded()
        await bind(fixture, apiKeys: ["test-client-key-0001"])
        let first = fixture.workspace.createConversation()
        #expect(fixture.workspace.createConversation() == first)
        #expect(fixture.workspace.conversations.count == 1)

        await completeTurn(fixture, "问", in: first)
        let second = fixture.workspace.createConversation()
        #expect(second != first)
        #expect(fixture.workspace.conversations.count == 2)
    }

    @Test func legacyModelStrategyKeepsSettings() throws {
        let json = #"{"globalInstructions":"fixture","isMemoryEnabled":false,"defaultModelID":"pinned","searchProvider":"brave","notifiesOnBackgroundCompletion":false,"generatesTitles":false}"#
        let settings = try JSONDecoder().decode(ChatSettings.self, from: Data(json.utf8))
        #expect(settings.newConversationModelStrategy == .fixed)
        #expect(settings.globalInstructions == "fixture")
        #expect(settings.searchProvider == .brave)
        #expect(!settings.isMemoryEnabled && !settings.notifiesOnBackgroundCompletion && !settings.generatesTitles)
        let withoutID = json.replacingOccurrences(of: #","defaultModelID":"pinned""#, with: "")
        #expect(try JSONDecoder().decode(ChatSettings.self, from: Data(withoutID.utf8)).newConversationModelStrategy == .mostRecent)
    }

    @Test @MainActor func explicitModelChoicesAreScopedToRememberedServers() async throws {
        let other = try CPAServer(baseURL: "https://b.example.invalid")
        let fixture = makeFixture(catalog: { server, _ in
            let ids = server == other ? ["shared", "third"] : ["shared", "second"]
            return FakeModelCatalog(result: .success(ids.map { CPAModel(id: $0) }))
        })
        let workspace = fixture.workspace
        await workspace.loadIfNeeded()
        await bind(fixture, apiKeys: ["test-client-key-0001"])
        let first = workspace.createConversation()
        workspace.selectModel("second", in: first)
        fixture.engine.respond(with: [.snapshot(text: "done", reasoning: nil)])
        await completeTurn(fixture, "M1", in: first)
        let empty = workspace.createConversation()
        #expect(workspace.conversation(empty)?.modelID == "second")
        await workspace.bind(server: other) { nil }
        #expect(await workspace.useManualKey("fixture-client-b"))
        #expect(workspace.createConversation() == empty)
        #expect(workspace.conversation(empty)?.modelID == "shared")
        workspace.selectModel("second", in: empty)
        #expect(workspace.conversation(empty)?.modelID == "shared")
        workspace.selectModel("third", in: empty)
        await workspace.bind(server: server) { nil }
        #expect(workspace.createConversation() == empty)
        #expect(workspace.conversation(empty)?.modelID == "second")
        #expect(workspace.conversation(first)?.modelID == "second")
        await workspace.bind(server: other, persistsKey: false) { nil }
        #expect(await workspace.useManualKey("fixture-session-only"))
        #expect(workspace.createConversation() == empty)
        #expect(workspace.conversation(empty)?.modelID == "shared")
        workspace.selectModel("shared", in: empty)
        #expect(workspace.settings.recentModelIDs?[other.identifier] == "third")
        #expect(fixture.engine.streamRequests.count == 1)
    }

    @Test @MainActor func lateCatalogFromPreviousKeyCannotAuthorizeAModel() async throws {
        struct WaitingCatalog: ChatModelCatalog {
            let gate: HeldDiscovery
            func models() async throws -> [CPAModel] {
                await gate.wait()
                return [CPAModel(id: "obsolete")]
            }
        }
        let gate = HeldDiscovery()
        let engine = FakeChatEngine()
        let workspace = ChatWorkspaceModel(persistence: ChatMemoryPersistence(), secrets: MemorySecretStore(),
                                          engine: engine, modelCatalog: { _, key in
            if key.hint.hasSuffix("0001") { return WaitingCatalog(gate: gate) }
            return FakeModelCatalog(result: .success([CPAModel(id: "current")]))
        })
        await workspace.bind(server: server) { nil }
        let old = Task { await workspace.useManualKey("fixture-key-0001") }
        #expect(await waitUntil { await gate.hasStarted })
        let empty = workspace.createConversation()
        #expect(workspace.modelListState == .loading)
        #expect(workspace.generationBlocker(for: empty) == .missingModel)
        #expect(await workspace.useManualKey("fixture-key-0002"))
        await gate.release()
        _ = await old.value
        #expect(workspace.models.map(\.id) == ["current"])
        #expect(workspace.conversation(empty)?.modelID == "current")
        #expect(engine.streamRequests.isEmpty)
    }

    @Test @MainActor func failedCatalogBlocksPreviouslyWorkingModel() async throws {
        let fixture = makeFixture(catalog: { _, key in
            key.hint.hasSuffix("0001")
                ? FakeModelCatalog(result: .success([CPAModel(id: "working")]))
                : FakeModelCatalog(result: .failure(CPAError(.requestRejected, statusCode: 403)))
        })
        let workspace = fixture.workspace
        await workspace.loadIfNeeded()
        await bind(fixture, apiKeys: ["test-client-key-0001"])
        let id = workspace.createConversation()
        fixture.engine.respond(with: [.snapshot(text: "old reply", reasoning: nil)])
        await completeTurn(fixture, "prompt", in: id)
        let previous = try #require(workspace.conversation(id)?.messages)
        #expect(await workspace.useManualKey("test-client-key-0002"))
        #expect(workspace.modelListState == .failed(.forbidden(statusCode: 403)))
        #expect(workspace.conversation(id)?.modelID == "working")
        #expect(!workspace.regenerate(try #require(previous.last?.id), in: id))
        #expect(workspace.conversation(id)?.messages == previous)
        #expect(fixture.engine.streamRequests.count == 1)
    }

    @Test @MainActor func invalidModelDoesNotTruncateAnExistingReply() async throws {
        let fixture = makeFixture()
        let workspace = fixture.workspace
        await workspace.loadIfNeeded()
        await bind(fixture, apiKeys: ["test-client-key-0001"])
        let id = workspace.createConversation()
        fixture.engine.respond(with: [.snapshot(text: "fixture", reasoning: nil)])
        await completeTurn(fixture, "M4", in: id)
        let before = try #require(workspace.conversation(id)?.messages)
        workspace.updateConversation(id) { $0.modelID = "removed" }
        #expect(!workspace.regenerate(try #require(before.last?.id), in: id))
        #expect(workspace.conversation(id)?.messages == before)
        #expect(fixture.engine.streamRequests.count == 1)
        workspace.settings.defaultModelID = "removed"
        workspace.settings.newConversationModelStrategy = .fixed
        let fresh = workspace.createConversation()
        #expect(workspace.preferredModelUnavailable)
        #expect(workspace.conversation(fresh)?.modelID == "test-model")
        #expect(workspace.settings.defaultModelID == "removed")
    }

    @Test @MainActor func longHistoryIsBoundedAndTheReplySaysHowMuchWasLeftOut() async throws {
        let long = String(repeating: "长", count: 25_000)
        var messages: [ChatMessage] = []
        for _ in 0..<3 {
            messages.append(ChatMessage(role: .user, text: long))
            messages.append(ChatMessage(role: .assistant, text: "好", modelID: "test-model"))
        }
        let seeded = ChatConversation(modelID: "test-model", messages: messages,
                                      serverIdentifier: server.identifier)
        let fixture = makeFixture(persistence: RecordingPersistence(seeded: [seeded]))
        fixture.engine.respond(with: [.snapshot(text: "回答", reasoning: nil)])
        fixture.workspace.settings.generatesTitles = false
        await fixture.workspace.loadIfNeeded()
        await bind(fixture, apiKeys: ["test-client-key-0001"])
        await completeTurn(fixture, "继续", in: seeded.id)

        let history = try #require(fixture.engine.streamRequests.last?.history)
        #expect(history.count == 4)
        #expect(history.reduce(0) { $0 + $1.text.count } <= ChatPromptBuilder.historyTextBudget)
        let reply = fixture.workspace.conversation(seeded.id)?.messages.last
        #expect(reply?.omittedHistoryCount == 2)
    }

    @Test @MainActor func webSearchWithoutAKeyIsMarkedOnTheReply() async {
        let search = FakeSearchClient()
        let fixture = makeFixture(searchClient: search)
        fixture.engine.respond(with: [.snapshot(text: "未检索的回答", reasoning: nil)])
        fixture.workspace.settings.generatesTitles = false
        await fixture.workspace.loadIfNeeded()
        await bind(fixture, apiKeys: ["test-client-key-0001"])
        let id = fixture.workspace.createConversation()
        fixture.workspace.settings.searchProvider = .tavily
        fixture.workspace.updateConversation(id) { $0.isWebSearchEnabled = true }
        await completeTurn(fixture, "查一下", in: id)

        let reply = fixture.workspace.conversation(id)?.messages.last
        #expect(reply?.status == .complete)
        #expect(reply?.failure == .searchNotConfigured)
        #expect(search.queries.isEmpty)
        #expect(fixture.engine.streamRequests.count == 1)
    }
}
private actor StreamObservation {
    var requests = 0
    var reads = 0
    var snapshots: [(text: String, reasoning: String?)] = []
    func opened() { requests += 1 }
    func read(_ bytes: Data) -> Data { reads += 1; return bytes }
    func received(_ event: ChatEngineEvent) {
        if case .snapshot(let text, let reasoning) = event { snapshots.append((text, reasoning)) }
    }
}

private struct GatedTransport: AnyLanguageModel.HTTPTransport {
    let chunks: AsyncStream<Data>
    let observation: StreamObservation

    func send<Return>(request: HTTPRequest, body: Data?, timeout: Duration?,
                      responseHandler: (HTTPTypes.HTTPResponse, HTTPResponseBody) async throws -> Return) async throws -> Return {
        await observation.opened()
        return try await responseHandler(.init(status: .ok), HTTPResponseBody(chunks.map { await observation.read($0) }))
    }
}

extension CPAChatSSETests {
    @Test func usageWithoutVisibleReasoningDoesNotProduceReasoningText() async throws {
        let usage = #"{"id":"fixture","choices":[],"usage":{"prompt_tokens":1,"completion_tokens":4,"completion_tokens_details":{"reasoning_tokens":3}}}"#
        let parts = ["data: \(token)\n\n", "data: \(usage)\n\n", "data: [DONE]\n\n"]
        let engine = AnyLanguageModelChatEngine(transport: FixtureSSETransport(fragments: parts))
        var lastUsage: ChatTokenUsage?
        var lastText: String?
        for try await event in engine.stream(try request()) {
            switch event {
            case .snapshot(let text, let reasoning):
                lastText = text
                #expect(reasoning == nil)
            case .usage(let usage): lastUsage = usage
            }
        }
        #expect(lastText == "partial")
        #expect(lastUsage?.reasoningTokens == 3)
    }

    private func event(_ delta: String) -> Data {
        Data("data: {\"id\":\"fixture\",\"choices\":[{\"index\":0,\"delta\":\(delta)}]}\r\n\r\n".utf8)
    }

    @Test func visibleReasoningArrivesBeforeBodyAndCompletion() async throws {
        let observation = StreamObservation()
        let (chunks, feed) = AsyncStream<Data>.makeStream()
        let engine = AnyLanguageModelChatEngine(transport: GatedTransport(chunks: chunks, observation: observation))
        let stream = engine.stream(try request())
        let consumer = Task {
            for try await event in stream { await observation.received(event) }
        }
        defer { feed.finish(); consumer.cancel() }
        let first = event(#"{"reasoning_content":"甲"}"#)
        let split = try #require(first.firstIndex(of: 0xe7)) + 1
        feed.yield(first.prefix(split))
        feed.yield(first.suffix(from: split))
        feed.yield(event(#"{"reasoning_content":"乙"}"#))
        let deadline = ContinuousClock.now + .seconds(4)
        while await observation.snapshots.last?.reasoning != "甲乙", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await observation.reads == 3)
        #expect(await observation.snapshots.last?.reasoning == "甲乙")
        #expect(await observation.snapshots.allSatisfy { $0.text.isEmpty })
        feed.yield(event(#"{"content":"A"}"#))
        feed.yield(event(#"{"content":"B","reasoning_content":"丙"}"#))
        feed.yield(Data("data: [DONE]\r\n\r\n".utf8))
        feed.finish()
        try await consumer.value
        let snapshots = await observation.snapshots
        #expect(snapshots.last?.text == "AB")
        #expect(snapshots.last?.reasoning == "甲乙丙")
        #expect(snapshots.filter { !$0.text.isEmpty }.allSatisfy { $0.reasoning?.hasPrefix("甲乙") == true })
        #expect(await observation.requests == 1)
    }

    @Test @MainActor func stoppingTheLiveRequestKeepsItsReasoningOnlyCheckpoint() async throws {
        let (chunks, feed) = AsyncStream<Data>.makeStream()
        defer { feed.finish() }
        let observation = StreamObservation()
        let engine = AnyLanguageModelChatEngine(transport: GatedTransport(chunks: chunks, observation: observation))
        let workspace = ChatWorkspaceModel(
            persistence: ChatMemoryPersistence(), secrets: MemorySecretStore(), engine: engine,
            modelCatalog: { _, _ in FakeModelCatalog(result: .success([CPAModel(id: "fixture")])) },
            backgroundRunner: FakeBackgroundRunner())
        await workspace.loadIfNeeded()
        await workspace.bind(server: try CPAServer(baseURL: "https://sse.example.invalid")) { nil }
        #expect(await workspace.useManualKey("fixture-key-for-gate"))
        let id = workspace.createConversation()
        #expect(workspace.send("Stop after R1", attachments: [], in: id))
        feed.yield(event(#"{"reasoning_content":"R1"}"#))
        let deadline = ContinuousClock.now + .seconds(5)
        while workspace.conversation(id)?.messages.last?.reasoning != "R1", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pending = try #require(workspace.conversation(id)?.messages.last)
        #expect(pending.reasoning == "R1" && pending.text.isEmpty && pending.status == .streaming)
        workspace.stop(id)
        feed.finish()
        let stoppedDeadline = ContinuousClock.now + .seconds(5)
        while workspace.isGenerating(id), ContinuousClock.now < stoppedDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let last = try #require(workspace.conversation(id)?.messages.last)
        #expect(last.reasoning == "R1" && last.text.isEmpty && last.status == .stopped)
        #expect(await observation.requests == 1)
    }
}
