import Foundation
import Observation
import CPAQuotaKit

/// Non-UI chat workspace: credential binding, model catalog, conversation
/// state, generation orchestration, persistence and secrets. All mutations
/// happen on the main actor; engine work runs in child tasks.
@MainActor @Observable
public final class ChatWorkspaceModel {
    private let persistence: any ChatPersistence
    private let secrets: any ChatSecretStore
    private let engine: any ChatEngine
    private let searchClient: @Sendable (ChatSearchProvider) -> any ChatSearchClient
    private let modelCatalog: @Sendable (CPAServer, CPAClientAPIKey) -> any ChatModelCatalog
    private let backgroundRunner: any ChatBackgroundRunner
    private var discoveryFactory: (@Sendable () async -> CPAAPIKeyDiscovery?)?

    public init(
        persistence: any ChatPersistence = ChatFilePersistence.default,
        secrets: any ChatSecretStore = KeychainSecretStore(),
        engine: any ChatEngine = AnyLanguageModelChatEngine(),
        searchClient: @escaping @Sendable (ChatSearchProvider) -> any ChatSearchClient = { ChatSearch.client(for: $0) },
        modelCatalog: @escaping @Sendable (CPAServer, CPAClientAPIKey) -> any ChatModelCatalog = { CPAModelCatalogClient(server: $0, apiKey: $1) },
        backgroundRunner: any ChatBackgroundRunner = SystemChatBackgroundRunner()
    ) {
        self.persistence = persistence
        self.secrets = secrets
        self.engine = engine
        self.searchClient = searchClient
        self.modelCatalog = modelCatalog
        self.backgroundRunner = backgroundRunner
    }

    // MARK: - Server binding & credentials

    public private(set) var server: CPAServer?
    public private(set) var credentialState: ChatCredentialState = .unbound
    public private(set) var discoveredKeys: [CPAClientAPIKey] = []
    public private(set) var isDiscoveringKeys = false
    public private(set) var keyDiscoveryError: CPAError?
    private var activeKey: CPAClientAPIKey?
    private var activeKeyIsManual = false

    private struct StoredKey: Codable {
        var v: Int
        var key: String
        var manual: Bool
    }

    /// Binds the workspace to the accepted CPA connection. Rebinding the same
    /// server is a no-op unless the state needs recovery (`.failed`/`.missingKey`).
    public func bind(server: CPAServer?, discovery: @escaping @Sendable () async -> CPAAPIKeyDiscovery?) async {
        guard let server else {
            unbind()
            return
        }
        if self.server == server, !isRecoverable {
            return
        }
        self.server = server
        self.discoveryFactory = discovery
        self.discoveredKeys = []
        self.keyDiscoveryError = nil
        credentialState = .loading
        do {
            if let stored = try await secrets.loadSecret(
                account: ChatSecrets.clientAPIKeyAccount(for: server)),
               let decoded = decodeStoredKey(stored) {
                await activate(key: decoded.key, isManual: decoded.manual)
                return
            }
            credentialState = .missingKey
        } catch let error as CPAError {
            credentialState = .failed(error)
        } catch {
            credentialState = .failed(CPAError(.secureStorageFailure))
        }
        await discoverKeys()
    }

    private var isRecoverable: Bool {
        if case .missingKey = credentialState { return true }
        if case .failed = credentialState { return true }
        return false
    }

    private func unbind() {
        server = nil
        discoveryFactory = nil
        activeKey = nil
        activeKeyIsManual = false
        credentialState = .unbound
        discoveredKeys = []
        isDiscoveringKeys = false
        keyDiscoveryError = nil
        models = []
        modelListState = .idle
    }

    private func activate(key: CPAClientAPIKey, isManual: Bool) async {
        activeKey = key
        activeKeyIsManual = isManual
        credentialState = .ready(hint: key.hint, isManual: isManual)
        await refreshModels()
    }

    public func discoverKeys() async {
        guard server != nil, let discoveryFactory else { return }
        guard !isDiscoveringKeys else { return }
        isDiscoveringKeys = true
        defer { isDiscoveringKeys = false }
        guard let discovery = await discoveryFactory() else {
            keyDiscoveryError = nil
            return
        }
        do {
            let keys = try await discovery.keys()
            discoveredKeys = keys
            keyDiscoveryError = nil
            if keys.count == 1 {
                await selectKey(keys[0])
            }
            // 0 or several keys: stay .missingKey and let the UI show the list.
        } catch let error as CPAError {
            keyDiscoveryError = error
        } catch {
            keyDiscoveryError = CPAError(.network)
        }
    }

    public func selectKey(_ key: CPAClientAPIKey) async {
        guard let server else { return }
        do {
            try await saveStoredKey(key, manual: false, for: server)
        } catch let error as CPAError {
            credentialState = .failed(error)
            return
        } catch {
            credentialState = .failed(CPAError(.secureStorageFailure))
            return
        }
        await activate(key: key, isManual: false)
    }

    @discardableResult
    public func useManualKey(_ text: String) async -> Bool {
        guard let server, let key = CPAClientAPIKey(text) else { return false }
        do {
            try await saveStoredKey(key, manual: true, for: server)
        } catch let error as CPAError {
            credentialState = .failed(error)
            return false
        } catch {
            credentialState = .failed(CPAError(.secureStorageFailure))
            return false
        }
        await activate(key: key, isManual: true)
        return true
    }

    public func removeStoredKey() async {
        guard let server else { return }
        try? await secrets.removeSecret(account: ChatSecrets.clientAPIKeyAccount(for: server))
        activeKey = nil
        activeKeyIsManual = false
        credentialState = .missingKey
        models = []
        modelListState = .idle
    }

    /// Removes another server's stored key; unbinds if it is the bound server.
    public func forget(server: CPAServer) async {
        try? await secrets.removeSecret(account: ChatSecrets.clientAPIKeyAccount(for: server))
        if self.server == server {
            unbind()
        }
    }

    private func saveStoredKey(_ key: CPAClientAPIKey, manual: Bool, for server: CPAServer) async throws {
        let stored = StoredKey(v: 1, key: key.exposedValue, manual: manual)
        let data = try JSONEncoder().encode(stored)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CPAError(.secureStorageFailure)
        }
        try await secrets.saveSecret(text, account: ChatSecrets.clientAPIKeyAccount(for: server))
    }

    private func decodeStoredKey(_ text: String) -> (key: CPAClientAPIKey, manual: Bool)? {
        guard let data = text.data(using: .utf8),
              let stored = try? JSONDecoder().decode(StoredKey.self, from: data),
              stored.v == 1,
              let key = CPAClientAPIKey(stored.key) else {
            return nil
        }
        return (key, stored.manual)
    }

    // MARK: - Model catalog

    public private(set) var models: [CPAModel] = []
    public private(set) var modelListState: ChatModelListState = .idle

    public func refreshModels() async {
        guard let server, let activeKey else {
            models = []
            modelListState = .idle
            return
        }
        modelListState = .loading
        do {
            models = try await modelCatalog(server, activeKey).models()
            modelListState = .loaded
        } catch let error as CPAError {
            modelListState = .failed(Self.chatFailure(for: error))
        } catch {
            modelListState = .failed(AnyLanguageModelChatEngine.failure(for: error) ?? .network)
        }
    }

    static func chatFailure(for error: CPAError) -> ChatFailure {
        let code = error.statusCode ?? 0
        switch error.kind {
        case .managementUnauthorized, .upstreamUnauthorized:
            return .unauthorized(statusCode: code)
        case .managementForbidden:
            return .forbidden(statusCode: code)
        case .endpointUnavailable:
            return .modelUnavailable(statusCode: code)
        case .rateLimited:
            return .rateLimited(retryAfter: error.retryAfter)
        case .timeout:
            return .timeout
        case .network, .redirectRefused:
            return .network
        case .upstreamFailure, .requestRejected:
            return .upstream(statusCode: code)
        default:
            return .invalidResponse
        }
    }

    // MARK: - Conversations

    public private(set) var conversations: [ChatConversation] = []
    public private(set) var isLoaded = false
    private var generationTasks: [UUID: Task<Void, Never>] = [:]
    private var stopReasons: [UUID: StopReason] = [:]
    private var titleTasks: [UUID: Task<Void, Never>] = [:]

    private enum StopReason {
        case userStopped
        case backgroundExpired
    }

    public func loadIfNeeded() async {
        guard !isLoaded else { return }
        isLoaded = true
        conversations = ((try? await persistence.loadConversations()) ?? [])
            .filter { !$0.messages.isEmpty }
            .sorted { $0.updatedAt > $1.updatedAt }
        if let stored = try? await persistence.loadSettings() {
            settings = stored
        }
        memories = (try? await persistence.loadMemories()) ?? []
        if let stored = try? await persistence.loadSkills() {
            skills = stored
        } else {
            skills = Self.defaultSkills
            let value = skills
            let store = persistence
            enqueuePersist { try? await store.saveSkills(value) }
        }
    }

    /// Merges conversations persisted after our snapshot (e.g. written while
    /// the app was suspended); newer `updatedAt` wins per conversation.
    public func reloadNewerConversations() async {
        let onDisk = (try? await persistence.loadConversations()) ?? []
        var changed = false
        for remote in onDisk {
            if let index = conversations.firstIndex(where: { $0.id == remote.id }) {
                if remote.updatedAt > conversations[index].updatedAt {
                    conversations[index] = remote
                    changed = true
                }
            } else {
                conversations.append(remote)
                changed = true
            }
        }
        if changed {
            conversations.sort { $0.updatedAt > $1.updatedAt }
        }
    }

    public func conversation(_ id: UUID) -> ChatConversation? {
        conversations.first(where: { $0.id == id })
    }

    @discardableResult
    public func createConversation() -> UUID {
        let modelID: String? = if let preferred = settings.defaultModelID,
                                  models.contains(where: { $0.id == preferred }) {
            preferred
        } else {
            models.first?.id
        }
        let conversation = ChatConversation(modelID: modelID)
        conversations.insert(conversation, at: 0)
        return conversation.id
    }

    public func deleteConversation(_ id: UUID) {
        generationTasks[id]?.cancel()
        generationTasks[id] = nil
        stopReasons[id] = nil
        titleTasks[id]?.cancel()
        titleTasks[id] = nil
        conversations.removeAll { $0.id == id }
        let store = persistence
        enqueuePersist { try? await store.removeConversation(id) }
    }

    public func deleteAllConversations() {
        for task in generationTasks.values { task.cancel() }
        for task in titleTasks.values { task.cancel() }
        generationTasks.removeAll()
        stopReasons.removeAll()
        titleTasks.removeAll()
        conversations.removeAll()
        let store = persistence
        enqueuePersist { try? await store.removeAllConversations() }
    }

    public func renameConversation(_ id: UUID, title: String) {
        updateConversation(id) { $0.title = title }
    }

    public func updateConversation(_ id: UUID, _ mutate: (inout ChatConversation) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        mutate(&conversations[index])
        conversations[index].updatedAt = Date()
        let updated = conversations[index]
        conversations.sort { $0.updatedAt > $1.updatedAt }
        persist(updated)
    }

    public func isGenerating(_ conversationID: UUID) -> Bool {
        generationTasks[conversationID] != nil
    }

    // MARK: - Generation

    public func send(_ text: String, attachments: [ChatImageAttachment], in conversationID: UUID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty,
              generationTasks[conversationID] == nil,
              let conversation = self.conversation(conversationID) else { return }
        generationTasks[conversationID] = Task {
            await self.performSend(text: text, attachments: attachments, conversation: conversation)
        }
    }

    public func stop(_ conversationID: UUID) {
        guard generationTasks[conversationID] != nil else { return }
        stopReasons[conversationID] = .userStopped
        generationTasks[conversationID]?.cancel()
    }

    /// Drops the assistant message and everything after it, then reruns from
    /// the preceding user message.
    public func regenerate(_ assistantMessageID: UUID, in conversationID: UUID) {
        guard generationTasks[conversationID] == nil,
              var conversation = self.conversation(conversationID),
              let index = conversation.messages.firstIndex(where: { $0.id == assistantMessageID }),
              conversation.messages[index].role == .assistant else { return }
        conversation.messages.removeSubrange(index...)
        // The triggering user message is now the last one (if any).
        updateConversationSilently(conversation)
        guard conversation.messages.last?.role == .user else { return }
        generationTasks[conversationID] = Task {
            await self.performSend(text: nil, attachments: [], conversation: conversation)
        }
    }

    /// Replaces the user message text, drops everything after it, then reruns.
    public func editAndResend(_ userMessageID: UUID, text: String, in conversationID: UUID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              generationTasks[conversationID] == nil,
              var conversation = self.conversation(conversationID),
              let index = conversation.messages.firstIndex(where: { $0.id == userMessageID }),
              conversation.messages[index].role == .user else { return }
        conversation.messages[index].text = text
        conversation.messages.removeSubrange((index + 1)...)
        updateConversationSilently(conversation)
        generationTasks[conversationID] = Task {
            await self.performSend(text: nil, attachments: [], conversation: conversation)
        }
    }

    public func deleteMessage(_ id: UUID, in conversationID: UUID) {
        guard var conversation = self.conversation(conversationID) else { return }
        conversation.messages.removeAll { $0.id == id }
        updateConversationSilently(conversation)
    }

    /// Mutates without bumping `updatedAt` (message-level edits).
    private func updateConversationSilently(_ conversation: ChatConversation) {
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
        var copy = conversation
        copy.updatedAt = conversations[index].updatedAt
        conversations[index] = copy
        persist(copy)
    }

    /// `text` nil means the triggering user message is already the last
    /// message (regenerate / editAndResend); otherwise it is appended.
    private func performSend(text: String?, attachments: [ChatImageAttachment],
                             conversation snapshot: ChatConversation) async {
        let conversationID = snapshot.id
        defer {
            generationTasks[conversationID] = nil
            stopReasons[conversationID] = nil
        }
        // A deleted conversation must not be resurrected by a cancelled task's late run.
        guard conversations.contains(where: { $0.id == conversationID }) else { return }
        var conversation = snapshot

        // Append the user message unless this is a rerun.
        if let text {
            conversation.messages.append(ChatMessage(role: .user, text: text, attachments: attachments))
        }
        guard let userMessage = conversation.messages.last, userMessage.role == .user else {
            return
        }

        // Missing credential / missing model fast paths.
        guard case .ready = credentialState, let apiKey = activeKey else {
            failFast(&conversation, with: .missingAPIKey, modelID: conversation.modelID)
            return
        }
        guard let modelID = conversation.modelID, !modelID.isEmpty else {
            failFast(&conversation, with: .missingModel, modelID: nil)
            return
        }

        if conversation.title.isEmpty {
            conversation.title = String(userMessage.text.prefix(24))
        }

        // Slash-skill application for the model prompt.
        let (modelPrompt, _, strippedText) = ChatPromptBuilder.applySkill(
            to: userMessage.text, skills: skills)

        // Assistant placeholder: applied and persisted before any async work so
        // the user message is visible immediately.
        let assistant = ChatMessage(role: .assistant, text: "", modelID: modelID,
                                    status: .streaming)
        let assistantID = assistant.id
        conversation.messages.append(assistant)
        conversation.updatedAt = Date()
        applyConversation(conversation)
        persist(conversation)

        // Instructions + history: prior complete/stopped messages only —
        // exclude the placeholder and the triggering user message (sent as `prompt`).
        let instructions = ChatPromptBuilder.instructions(
            settings: settings, memories: memories, conversation: conversation)
        let history = conversation.messages.dropLast(2).filter {
            !$0.text.isEmpty && ($0.status == .complete || $0.status == .stopped)
        }

        guard let server else { return }
        let token = backgroundRunner.beginTask { [weak self] in
            guard let self else { return }
            self.stopReasons[conversationID] = .backgroundExpired
            self.generationTasks[conversationID]?.cancel()
        }
        defer { backgroundRunner.endTask(token) }

        // Optional web search injection. Cancellation mid-search ends the turn
        // below without marking the message as a search failure.
        var sources: [ChatSearchSource] = []
        if conversation.isWebSearchEnabled, let provider = settings.searchProvider,
           let key = try? await secrets.loadSecret(
               account: ChatSecrets.searchKeyAccount(for: provider)),
           !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                sources = try await searchClient(provider).search(strippedText, apiKey: key)
                if !sources.isEmpty {
                    mutateAssistant(assistantID, in: conversationID) {
                        $0.searchSources = sources
                    }
                }
            } catch {
                if !Task.isCancelled {
                    mutateAssistant(assistantID, in: conversationID) {
                        $0.failure = .searchFailed
                    }
                }
            }
        }

        // Cancelled during the search step: end per stop reason, no engine call.
        if Task.isCancelled {
            finishAborted(assistantID: assistantID, in: conversationID)
            if let updated = self.conversation(conversationID) {
                await persist(updated).value
            }
            return
        }

        let prompt = sources.isEmpty
            ? modelPrompt
            : ChatPromptBuilder.searchInjectedPrompt(modelPrompt, sources: sources)
        let request = ChatEngineRequest(
            baseURL: server.baseURL.appendingPathComponent("v1"),
            apiKey: apiKey,
            modelID: modelID,
            instructions: instructions,
            history: history,
            prompt: prompt,
            images: userMessage.attachments,
            reasoningEffort: conversation.reasoningEffort)

        var succeeded = false
        do {
            for try await event in engine.stream(request) {
                switch event {
                case .snapshot(let text, let reasoning):
                    mutateAssistant(assistantID, in: conversationID) {
                        $0.text = text
                        $0.reasoning = reasoning
                    }
                case .usage(let usage):
                    mutateAssistant(assistantID, in: conversationID) {
                        $0.usage = usage
                    }
                }
            }
            // A cancelled consumer may see the stream end normally.
            try Task.checkCancellation()
            mutateAssistant(assistantID, in: conversationID) { $0.status = .complete }
            succeeded = true
        } catch {
            if AnyLanguageModelChatEngine.failure(for: error) == nil {
                // Cancellation: user stop or background expiration.
                finishAborted(assistantID: assistantID, in: conversationID)
            } else {
                mutateAssistant(assistantID, in: conversationID) {
                    $0.status = .failed
                    $0.failure = AnyLanguageModelChatEngine.failure(for: error)
                }
            }
        }

        // Await the final write so an interrupted reply is on disk before iOS
        // can suspend the app when endTask runs.
        if let updated = self.conversation(conversationID) {
            await persist(updated).value
        }

        if succeeded {
            if backgroundRunner.isAppInBackground, settings.notifiesOnBackgroundCompletion {
                let title = self.conversation(conversationID)?.title ?? ""
                await backgroundRunner.notifyCompletion(
                    conversationID: conversationID,
                    title: title.isEmpty ? "新对话" : title)
            }
            if settings.generatesTitles,
               let current = self.conversation(conversationID),
               current.messages.filter({ $0.role == .assistant && $0.status == .complete }).count == 1,
               let reply = current.messages.last(where: { $0.id == assistantID })?.text {
                generateTitle(conversationID: conversationID, userText: userMessage.text,
                              reply: reply, apiKey: apiKey, modelID: modelID)
            }
        }
    }

    private func failFast(_ conversation: inout ChatConversation, with failure: ChatFailure,
                          modelID: String?) {
        conversation.messages.append(ChatMessage(
            role: .assistant, text: "", modelID: modelID, status: .failed, failure: failure))
        conversation.updatedAt = Date()
        applyConversation(conversation)
        persist(conversation)
    }

    private func applyConversation(_ conversation: ChatConversation) {
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else {
            conversations.insert(conversation, at: 0)
            return
        }
        conversations[index] = conversation
        conversations.sort { $0.updatedAt > $1.updatedAt }
    }

    private func mutateAssistant(_ id: UUID, in conversationID: UUID,
                                 _ mutate: (inout ChatMessage) -> Void) {
        guard let cIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let mIndex = conversations[cIndex].messages.firstIndex(where: { $0.id == id }) else {
            return
        }
        mutate(&conversations[cIndex].messages[mIndex])
    }

    private func generateTitle(conversationID: UUID, userText: String, reply: String,
                               apiKey: CPAClientAPIKey, modelID: String) {
        guard let server else { return }
        titleTasks[conversationID] = Task {
            defer { self.titleTasks[conversationID] = nil }
            let request = ChatEngineRequest(
                baseURL: server.baseURL.appendingPathComponent("v1"),
                apiKey: apiKey,
                modelID: modelID,
                instructions: "",
                history: [],
                prompt: "用不超过 12 个字概括以下对话的主题，只输出标题：\n\(userText)\n\(String(reply.prefix(500)))")
            guard let raw = try? await engine.complete(request) else { return }
            var title = raw.trimmingCharacters(in: Self.titleTrimming)
            title = String(title.prefix(30))
            guard !title.isEmpty else { return }
            if let index = self.conversations.firstIndex(where: { $0.id == conversationID }) {
                self.conversations[index].title = title
                self.persist(self.conversations[index])
            }
        }
    }

    private static let titleTrimming: CharacterSet = {
        var set = CharacterSet.whitespacesAndNewlines
        set.insert(charactersIn: "\"'“”‘’「」『』")
        return set
    }()

    private static let defaultSkills: [ChatSkill] = [
        ChatSkill(command: "translate", title: "翻译",
                  prompt: "将以下内容翻译成中文；如果原文已是中文，则翻译成英文。只输出译文。"),
        ChatSkill(command: "summarize", title: "总结",
                  prompt: "用要点总结以下内容，保留关键数字与结论。"),
        ChatSkill(command: "polish", title: "润色",
                  prompt: "润色以下文字，使表达更清晰自然，保持原意与语言。"),
        ChatSkill(command: "explain", title: "解释代码",
                  prompt: "逐段解释以下代码的作用，并指出潜在问题。"),
    ]

    private func finishAborted(assistantID: UUID, in conversationID: UUID) {
        let reason = stopReasons[conversationID] ?? .userStopped
        mutateAssistant(assistantID, in: conversationID) {
            switch reason {
            case .userStopped:
                $0.status = .stopped
            case .backgroundExpired:
                $0.status = .interrupted
                $0.failure = .interruptedInBackground
            }
        }
    }

    // MARK: - Persistence

    /// Serializes persistence writes so an older snapshot can never land
    /// after a newer one.
    private var persistTail: Task<Void, Never>?

    @discardableResult
    private func enqueuePersist(_ work: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let previous = persistTail
        let task = Task {
            await previous?.value
            await work()
        }
        persistTail = task
        return task
    }

    /// Persists a conversation; empty conversations are never written.
    @discardableResult
    private func persist(_ conversation: ChatConversation) -> Task<Void, Never> {
        let store = persistence
        return enqueuePersist {
            guard !conversation.messages.isEmpty else { return }
            try? await store.saveConversation(conversation)
        }
    }

    // MARK: - Settings, memories, skills, search keys

    public var settings = ChatSettings() {
        didSet {
            let value = settings
            let store = persistence
            enqueuePersist { try? await store.saveSettings(value) }
        }
    }

    public private(set) var memories: [ChatMemoryItem] = []

    public func addMemory(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        memories.append(ChatMemoryItem(text: trimmed))
        let value = memories
        let store = persistence
        enqueuePersist { try? await store.saveMemories(value) }
    }

    public func updateMemory(_ item: ChatMemoryItem) {
        guard let index = memories.firstIndex(where: { $0.id == item.id }) else { return }
        memories[index] = item
        let value = memories
        let store = persistence
        enqueuePersist { try? await store.saveMemories(value) }
    }

    public func deleteMemory(_ id: UUID) {
        memories.removeAll { $0.id == id }
        let value = memories
        let store = persistence
        enqueuePersist { try? await store.saveMemories(value) }
    }

    public private(set) var skills: [ChatSkill] = []

    public func saveSkill(_ skill: ChatSkill) {
        var normalized = skill
        normalized.command = ChatPromptBuilder.normalizedCommand(skill.command)
        guard !normalized.command.isEmpty else { return }
        if let index = skills.firstIndex(where: { $0.id == skill.id }) {
            skills[index] = normalized
        } else {
            skills.append(normalized)
        }
        let value = skills
        let store = persistence
        enqueuePersist { try? await store.saveSkills(value) }
    }

    public func deleteSkill(_ id: UUID) {
        skills.removeAll { $0.id == id }
        let value = skills
        let store = persistence
        enqueuePersist { try? await store.saveSkills(value) }
    }

    /// `/partial` (no whitespace yet) → prefix matches on normalized commands.
    public func skillSuggestions(for draft: String) -> [ChatSkill] {
        guard draft.hasPrefix("/"), draft.count > 1 else { return [] }
        let partial = draft.dropFirst()
        guard !partial.isEmpty, !partial.contains(where: { $0.isWhitespace }) else { return [] }
        let needle = partial.lowercased()
        return skills.filter {
            ChatPromptBuilder.normalizedCommand($0.command).hasPrefix(needle)
        }
    }

    public func hasSearchKey(for provider: ChatSearchProvider) async -> Bool {
        guard let value = try? await secrets.loadSecret(
            account: ChatSecrets.searchKeyAccount(for: provider)) else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @discardableResult
    public func saveSearchKey(_ text: String, for provider: ChatSearchProvider) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            try await secrets.saveSecret(trimmed, account: ChatSecrets.searchKeyAccount(for: provider))
            return true
        } catch {
            return false
        }
    }

    public func removeSearchKey(for provider: ChatSearchProvider) async {
        try? await secrets.removeSecret(account: ChatSecrets.searchKeyAccount(for: provider))
    }

    public func requestNotificationAuthorization() async -> Bool {
        await backgroundRunner.requestNotificationAuthorization()
    }
}
