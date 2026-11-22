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
    private let streamingPersistInterval: Duration
    private var discoveryFactory: (@Sendable () async -> CPAAPIKeyDiscovery?)?

    public init(
        persistence: any ChatPersistence = ChatFilePersistence.default,
        secrets: any ChatSecretStore = KeychainSecretStore(),
        engine: any ChatEngine = AnyLanguageModelChatEngine(),
        searchClient: @escaping @Sendable (ChatSearchProvider) -> any ChatSearchClient = { ChatSearch.client(for: $0) },
        modelCatalog: @escaping @Sendable (CPAServer, CPAClientAPIKey) -> any ChatModelCatalog = { CPAModelCatalogClient(server: $0, apiKey: $1) },
        backgroundRunner: any ChatBackgroundRunner = SystemChatBackgroundRunner(),
        streamingPersistInterval: Duration = .seconds(2)
    ) {
        self.persistence = persistence
        self.secrets = secrets
        self.engine = engine
        self.searchClient = searchClient
        self.modelCatalog = modelCatalog
        self.backgroundRunner = backgroundRunner
        self.streamingPersistInterval = streamingPersistInterval
    }

    // MARK: - Server binding & credentials

    public private(set) var server: CPAServer?
    public private(set) var credentialState: ChatCredentialState = .unbound
    public private(set) var discoveredKeys: [CPAClientAPIKey] = []
    public private(set) var isDiscoveringKeys = false
    public private(set) var keyDiscoveryError: CPAError?
    private var activeKey: CPAClientAPIKey?
    private var temporaryRecentModelID: String?
    @ObservationIgnored private var catalogRequest = UUID()
    @ObservationIgnored private var credentialRevision: UInt64 = 0
    @ObservationIgnored private var keyWriteTail: Task<Void, any Error>?
    public private(set) var keyRemovalFailed = false
    /// `false` for a connection the user chose not to remember: the client
    /// key then lives only in memory and nothing is written to the Keychain.
    public private(set) var persistsKey = true

    private struct StoredKey: Codable {
        var v: Int
        var key: String
        var manual: Bool
    }

    /// Binds the workspace to the accepted CPA connection. Rebinding the same
    /// server is a no-op unless the state needs recovery (`.failed`/`.missingKey`)
    /// or the remembered state changed.
    ///
    /// With `persistsKey == false` the Keychain is neither read nor written;
    /// a client key stored earlier for this server is removed so the
    /// unremembered connection leaves no credential behind.
    public func bind(server: CPAServer?, persistsKey: Bool = true,
                     discovery: @escaping @Sendable () async -> CPAAPIKeyDiscovery?) async {
        guard !Task.isCancelled else { return }
        guard let server else {
            unbind()
            return
        }
        if self.server == server, self.persistsKey == persistsKey, !isRecoverable { return }
        unbind()
        let revision = credentialRevision
        self.server = server
        self.persistsKey = persistsKey
        discoveryFactory = discovery
        credentialState = .loading
        _ = await keyWriteTail?.result
        guard isCurrent(revision) else { return }
        guard persistsKey else {
            let store = secrets
            let account = ChatSecrets.clientAPIKeyAccount(for: server)
            do {
                try await enqueueKeyWrite { try await store.removeSecret(account: account) }.value
            } catch {
                guard isCurrent(revision) else { return }
                keyRemovalFailed = true
            }
            guard isCurrent(revision) else { return }
            credentialState = .missingKey
            await discoverKeys()
            return
        }
        do {
            let stored = try await secrets.loadSecret(account: ChatSecrets.clientAPIKeyAccount(for: server))
            guard isCurrent(revision) else { return }
            if let stored, let decoded = decodeStoredKey(stored) {
                await activate(key: decoded.key, isManual: decoded.manual)
                return
            }
            credentialState = .missingKey
        } catch {
            guard isCurrent(revision) else { return }
            credentialState = .failed(storageError(error))
        }
        await discoverKeys()
    }

    private var isRecoverable: Bool {
        if case .missingKey = credentialState { return true }
        if case .failed = credentialState { return true }
        return false
    }

    package func unbind() {
        advanceCredentialRevision()
        server = nil
        temporaryRecentModelID = nil
        persistsKey = true
        discoveryFactory = nil
        activeKey = nil
        credentialState = .unbound
        discoveredKeys = []
        keyRemovalFailed = false
        models = []
        modelListState = .idle
    }

    private func advanceCredentialRevision() {
        credentialRevision &+= 1
        isDiscoveringKeys = false
        keyDiscoveryError = nil
        for (id, generation) in generationTasks {
            if stopReasons[id] == nil { stopReasons[id] = .connectionChanged }
            generation.task.cancel()
        }
        for task in titleTasks.values { task.cancel() }
    }

    private func isCurrent(_ revision: UInt64) -> Bool {
        revision == credentialRevision && !Task.isCancelled
    }

    private func storageError(_ error: any Error) -> CPAError {
        (error as? CPAError) ?? CPAError(.secureStorageFailure)
    }

    private func activate(key: CPAClientAPIKey, isManual: Bool) async {
        activeKey = key
        credentialState = .ready(hint: key.hint, isManual: isManual)
        await refreshModels()
    }

    public func discoverKeys() async {
        guard server != nil, let discoveryFactory, credentialState != .loading,
              !isDiscoveringKeys, !Task.isCancelled else { return }
        let revision = credentialRevision
        isDiscoveringKeys = true
        defer { if revision == credentialRevision { isDiscoveringKeys = false } }
        guard let discovery = await discoveryFactory(), isCurrent(revision) else { return }
        do {
            let keys = try await discovery.keys()
            guard isCurrent(revision) else { return }
            discoveredKeys = keys
            keyDiscoveryError = nil
            if keys.count == 1 {
                await selectKey(keys[0])
            }
        } catch {
            guard isCurrent(revision) else { return }
            keyDiscoveryError = (error as? CPAError) ?? CPAError(.network)
        }
    }

    public func selectKey(_ key: CPAClientAPIKey) async {
        guard discoveredKeys.contains(key) else { return }
        _ = await installKey(key, manual: false)
    }

    @discardableResult
    public func useManualKey(_ text: String) async -> Bool {
        guard let key = CPAClientAPIKey(text) else { return false }
        return await installKey(key, manual: true)
    }

    private func installKey(_ key: CPAClientAPIKey, manual: Bool) async -> Bool {
        guard let server, credentialState != .loading, !Task.isCancelled else { return false }
        advanceCredentialRevision()
        let revision = credentialRevision
        activeKey = nil
        credentialState = .loading
        // An unremembered connection keeps reporting a stale entry it could not remove.
        if persistsKey { keyRemovalFailed = false }
        models = []
        modelListState = .idle
        do {
            if persistsKey { try await saveStoredKey(key, manual: manual, for: server) }
        } catch {
            guard isCurrent(revision) else { return false }
            credentialState = .failed(storageError(error))
            return false
        }
        guard isCurrent(revision) else { return false }
        await activate(key: key, isManual: manual)
        return isCurrent(revision)
    }

    public func removeStoredKey() async {
        guard let server, credentialState != .loading else { return }
        // The error is exposed via keyRemovalFailed; the same button remains usable.
        try? await deleteStoredKey(for: server, unbindAfterSuccess: false)
    }

    /// Only unbind after a successful Keychain removal. The caller can retry a failure.
    public func forget(server: CPAServer) async throws {
        try await deleteStoredKey(for: server, unbindAfterSuccess: true)
    }

    private func deleteStoredKey(for server: CPAServer, unbindAfterSuccess: Bool) async throws {
        let previousState = credentialState
        let revision: UInt64?
        if self.server == server {
            advanceCredentialRevision()
            revision = credentialRevision
            credentialState = .loading
            keyRemovalFailed = false
            modelListState = models.isEmpty ? .idle : .loaded
        } else {
            revision = nil
        }
        let store = secrets
        let account = ChatSecrets.clientAPIKeyAccount(for: server)
        do {
            try await enqueueKeyWrite { try await store.removeSecret(account: account) }.value
        } catch {
            if let revision, revision == credentialRevision {
                keyRemovalFailed = true
                credentialState = previousState == .loading ? .failed(storageError(error)) : previousState
            }
            throw storageError(error)
        }
        guard let revision, revision == credentialRevision else { return }
        if unbindAfterSuccess {
            unbind()
        } else {
            activeKey = nil
            credentialState = .missingKey
            models = []
            modelListState = .idle
        }
    }

    private func enqueueKeyWrite(_ work: @escaping @Sendable () async throws -> Void) -> Task<Void, any Error> {
        let previous = keyWriteTail
        let next = Task {
            _ = await previous?.result
            try await work()
        }
        keyWriteTail = next
        return next
    }

    private func saveStoredKey(_ key: CPAClientAPIKey, manual: Bool, for server: CPAServer) async throws {
        let stored = StoredKey(v: 1, key: key.exposedValue, manual: manual)
        let data = try JSONEncoder().encode(stored)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CPAError(.secureStorageFailure)
        }
        let store = secrets
        let account = ChatSecrets.clientAPIKeyAccount(for: server)
        try await enqueueKeyWrite { try await store.saveSecret(text, account: account) }.value
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
        guard case .ready = credentialState, let server, let activeKey, !Task.isCancelled else { return }
        let revision = credentialRevision
        let request = UUID()
        catalogRequest = request
        modelListState = .loading
        do {
            let refreshed = try await modelCatalog(server, activeKey).models()
            guard isCurrent(revision), catalogRequest == request else { return }
            models = refreshed
            modelListState = .loaded
            assignDefaultModelWhereMissing()
        } catch let error as CPAError {
            guard isCurrent(revision), catalogRequest == request else { return }
            modelListState = .failed(Self.chatFailure(for: error))
        } catch {
            guard isCurrent(revision), catalogRequest == request else { return }
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
        case .requestRejected where code == 401:
            return .unauthorized(statusCode: code)
        case .requestRejected where code == 403:
            return .forbidden(statusCode: code)
        case .upstreamFailure, .requestRejected:
            return .upstream(statusCode: code)
        default:
            return .invalidResponse
        }
    }

    // MARK: - Conversations

    public private(set) var conversations: [ChatConversation] = []
    /// `true` only after history, settings, memories and skills are restored.
    public private(set) var isLoaded = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    private struct Generation {
        let id: UUID
        let task: Task<Void, Never>
    }
    private var generationTasks: [UUID: Generation] = [:]
    private var stopReasons: [UUID: StopReason] = [:]
    public private(set) var unsavedConversations = Set<UUID>()
    private var titleTasks: [UUID: Task<Void, Never>] = [:]

    private enum StopReason {
        case userStopped
        case connectionChanged
        case backgroundExpired
    }

    /// Concurrent callers share one load; `isLoaded` turns on when it finishes.
    public func loadIfNeeded() async {
        if let loadTask {
            await loadTask.value
            return
        }
        guard !isLoaded else { return }
        let task = Task { await self.performLoad() }
        loadTask = task
        await task.value
    }

    private func performLoad() async {
        defer { isLoaded = true }
        let stored = ((try? await persistence.loadConversations()) ?? [])
            .filter { !$0.messages.isEmpty }
        // Keep anything created in memory meanwhile instead of overwriting it.
        let created = conversations.filter { local in !stored.contains { $0.id == local.id } }
        conversations = (stored + created).sorted { $0.updatedAt > $1.updatedAt }
        recoverOrphanedReplies()
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

    /// A reply still marked `.streaming` with no running task was cut off when
    /// the app ended; it is kept as interrupted so it can be regenerated.
    private func recoverOrphanedReplies() {
        for index in conversations.indices where generationTasks[conversations[index].id] == nil {
            var changed = false
            for messageIndex in conversations[index].messages.indices
            where conversations[index].messages[messageIndex].status == .streaming {
                conversations[index].messages[messageIndex].status = .interrupted
                conversations[index].messages[messageIndex].failure = .generationInterrupted
                conversations[index].messages[messageIndex].finishAttempt()
                changed = true
            }
            if changed { persist(conversations[index]) }
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

    /// Reuses an existing empty conversation instead of stacking up new ones.
    @discardableResult
    public func createConversation() -> UUID {
        if let index = conversations.firstIndex(where: { $0.messages.isEmpty && generationTasks[$0.id] == nil }) {
            var reused = conversations.remove(at: index)
            reused.serverIdentifier = server?.identifier
            reused.modelID = defaultModelID
            reused.updatedAt = Date()
            conversations.insert(reused, at: 0)
            return reused.id
        }
        let conversation = ChatConversation(modelID: defaultModelID, serverIdentifier: server?.identifier)
        conversations.insert(conversation, at: 0)
        return conversation.id
    }

    private var preferredModelID: String? {
        switch settings.newConversationModelStrategy {
        case .fixed: return settings.defaultModelID
        case .mostRecent:
            guard let server else { return nil }
            return persistsKey ? settings.recentModelIDs?[server.identifier] : temporaryRecentModelID
        }
    }

    private var defaultModelID: String? {
        guard modelListState == .loaded else { return nil }
        if let preferred = preferredModelID, isAvailableModel(preferred) {
            return preferred
        }
        return models.first?.id
    }

    /// Conversations opened before the model list arrived get the default model.
    private func assignDefaultModelWhereMissing() {
        guard let server, let modelID = defaultModelID else { return }
        for index in conversations.indices where conversations[index].messages.isEmpty
            && (conversations[index].serverIdentifier == nil || conversations[index].serverIdentifier == server.identifier)
            && !isAvailableModel(conversations[index].modelID) {
            conversations[index].serverIdentifier = server.identifier
            conversations[index].modelID = modelID
        }
    }

    public func isAvailableModel(_ id: String?) -> Bool {
        modelListState == .loaded && id != nil && models.contains { $0.id == id }
    }

    public var preferredModelUnavailable: Bool {
        modelListState == .loaded && !models.isEmpty && preferredModelID != nil && !isAvailableModel(preferredModelID)
    }

    /// Only explicit selections in the conversation menu update the server preference.
    public func selectModel(_ id: String, in conversationID: UUID) {
        guard let server, isAvailableModel(id), conversation(conversationID) != nil else { return }
        updateConversation(conversationID) { $0.modelID = id }
        if persistsKey {
            settings.rememberModel(id, for: server.identifier)
        } else {
            temporaryRecentModelID = id
        }
    }

    public func deleteConversation(_ id: UUID) {
        generationTasks[id]?.task.cancel()
        generationTasks[id] = nil
        stopReasons[id] = nil
        titleTasks[id]?.cancel()
        titleTasks[id] = nil
        conversations.removeAll { $0.id == id }
        let store = persistence
        enqueuePersist { try? await store.removeConversation(id) }
    }

    /// Returns `false` when some records could not be removed; those are read
    /// back from disk so the list shows what is still stored and the user can retry.
    @discardableResult
    public func deleteAllConversations() async -> Bool {
        for generation in generationTasks.values { generation.task.cancel() }
        for task in titleTasks.values { task.cancel() }
        generationTasks.removeAll()
        stopReasons.removeAll()
        titleTasks.removeAll()
        // Clear first: cancelled generations then find no conversation to write back.
        conversations.removeAll()
        let store = persistence
        let previous = persistTail
        let removal = Task { () -> Bool in
            await previous?.value
            do {
                try await store.removeAllConversations()
                return true
            } catch {
                return false
            }
        }
        persistTail = Task { _ = await removal.value }
        guard await removal.value else {
            let remaining = ((try? await persistence.loadConversations()) ?? [])
                .filter { stored in !stored.messages.isEmpty && !conversations.contains { $0.id == stored.id } }
            conversations.append(contentsOf: remaining)
            conversations.sort { $0.updatedAt > $1.updatedAt }
            recoverOrphanedReplies()
            return false
        }
        return true
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

    /// `nil` when the conversation may be continued on the bound server as is.
    public func serverChange(for conversationID: UUID) -> ChatServerChange? {
        guard let server, let conversation = conversation(conversationID),
              !conversation.messages.isEmpty,
              conversation.serverIdentifier != server.identifier else { return nil }
        return ChatServerChange(
            previousServerIdentifier: conversation.serverIdentifier,
            currentServerIdentifier: server.identifier,
            messageCount: conversation.messages.count,
            imageCount: conversation.messages.reduce(0) { $0 + $1.attachments.count })
    }

    /// Why a rerun (regenerate / edit and resend) cannot start right now.
    /// Reruns check this before truncating anything.
    public func generationBlocker(for conversationID: UUID) -> ChatFailure? {
        guard case .ready = credentialState, server != nil, activeKey != nil else { return .missingAPIKey }
        guard isAvailableModel(conversation(conversationID)?.modelID) else { return .missingModel }
        return nil
    }

    /// Returns `false` without changing anything when the conversation belongs
    /// to another server and `confirmingServerChange` is not set.
    @discardableResult
    public func send(_ text: String, attachments: [ChatImageAttachment], in conversationID: UUID,
                     confirmingServerChange: Bool = false) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty,
              generationTasks[conversationID] == nil,
              confirmingServerChange || serverChange(for: conversationID) == nil,
              let conversation = self.conversation(conversationID) else { return false }
        startGeneration(text: text, attachments: attachments, conversation: conversation)
        return true
    }

    private func startGeneration(text: String?, attachments: [ChatImageAttachment], conversation: ChatConversation) {
        let revision = credentialRevision
        schedule(in: conversation.id) { attemptID in
            await self.performSend(text: text, attachments: attachments, conversation: conversation,
                                   revision: revision, attemptID: attemptID)
        }
    }

    private func schedule(in conversationID: UUID, operation: @escaping @MainActor (UUID) async -> Void) {
        let id = UUID()
        let task = Task {
            await operation(id)
            if generationTasks[conversationID]?.id == id {
                generationTasks[conversationID] = nil
                stopReasons[conversationID] = nil
            }
        }
        generationTasks[conversationID] = Generation(id: id, task: task)
    }

    public func continuation(for conversationID: UUID) -> ChatContinuation? {
        guard !isGenerating(conversationID) else { return nil }
        return continuationTarget(for: conversationID)
    }

    private func continuationTarget(for conversationID: UUID) -> ChatContinuation? {
        guard generationBlocker(for: conversationID) == nil,
              let conversation = conversation(conversationID), let server, let modelID = conversation.modelID,
              let reply = conversation.messages.last, reply.permitsContinuation,
              let question = conversation.messages.dropLast().last, question.role == .user,
              reply.replyToID == nil || reply.replyToID == question.id else { return nil }
        return ChatContinuation(conversationID: conversationID, questionID: question.id, replyID: reply.id,
                                serverID: server.identifier, previousServerID: conversation.serverIdentifier,
                                attemptCount: reply.attempts?.count ?? 0, revision: credentialRevision, modelID: modelID,
                                previousModelID: reply.attempts?.last?.modelID ?? reply.modelID,
                                isRetry: reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @discardableResult
    public func continueReply(_ target: ChatContinuation, confirmingServerChange: Bool = false) -> Bool {
        let id = target.conversationID
        guard continuation(for: id) == target,
              confirmingServerChange || serverChange(for: id) == nil else { return false }
        schedule(in: id) { attemptID in
            await self.performContinuation(target, attemptID: attemptID)
        }
        return true
    }

    private func performContinuation(_ target: ChatContinuation, attemptID: UUID) async {
        let id = target.conversationID
        guard isCurrent(target.revision), generationTasks[id]?.id == attemptID,
              continuationTarget(for: id) == target,
              let server, let apiKey = activeKey, var conversation = conversation(id),
              let saved = conversation.messages.last, let question = conversation.messages.dropLast().last else { return }
        var reply = saved
        let original: String
        if let expandedPrompt = saved.expandedPrompt {
            original = expandedPrompt
        } else if saved.attempts == nil {
            original = ChatPromptBuilder.applySkill(to: question.text, skills: skills).modelPrompt
            if original != question.text { reply.expandedPrompt = original }
        } else {
            original = question.text
        }
        if reply.attempts == nil {
            reply.attempts = [ChatReplyAttempt(modelID: saved.modelID, status: saved.status,
                                               failure: saved.failure, usage: saved.usage)]
        }
        reply.replyToID = question.id
        reply.status = .streaming
        reply.failure = nil
        conversation.messages[conversation.messages.count - 1] = reply
        conversation.serverIdentifier = server.identifier
        conversation.updatedAt = Date()
        applyConversation(conversation)
        persist(conversation)
        let token = beginBackgroundTask(in: id, assistantID: saved.id, attemptID: attemptID)
        defer { backgroundRunner.endTask(token) }

        var sources = saved.searchSources
        if target.isRetry, sources.isEmpty, conversation.isWebSearchEnabled {
            let query = ChatPromptBuilder.applySkill(to: question.text, skills: skills).rest
            sources = await performSearch(query, enabled: true, assistantID: saved.id,
                                          in: id, revision: target.revision)
            guard isCurrent(target.revision) else {
                finishAborted(assistantID: saved.id, in: id)
                if let updated = self.conversation(id) {
                    await persist(updated).value
                }
                return
            }
            reply.searchSources = sources
        }

        let effectivePrompt = ChatPromptBuilder.searchInjectedPrompt(original, sources: sources)
        let context = ChatPromptBuilder.continuationContext(
            earlier: eligibleHistory(conversation), question: question, reply: reply, effectivePrompt: effectivePrompt)
        reply.omittedHistoryCount = context.omitted > 0 ? context.omitted : nil
        mutateAssistant(saved.id, in: id) { $0.omittedHistoryCount = reply.omittedHistoryCount }
        let request = ChatEngineRequest(baseURL: server.baseURL.appendingPathComponent("v1"), apiKey: apiKey,
                                       modelID: target.modelID,
                                       instructions: ChatPromptBuilder.instructions(settings: settings, memories: memories,
                                                                                    conversation: conversation),
                                       history: context.history, prompt: context.prompt, images: context.images,
                                       reasoningEffort: conversation.reasoningEffort)
        _ = await consume(request, in: id, assistant: reply, revision: target.revision, attemptID: attemptID)
    }

    public func stop(_ conversationID: UUID) {
        guard generationTasks[conversationID] != nil, stopReasons[conversationID] == nil else { return }
        stopReasons[conversationID] = .userStopped
        generationTasks[conversationID]?.task.cancel()
    }

    /// Drops the assistant message and everything after it, then reruns from
    /// the preceding user message. Send conditions are checked first, so a
    /// rerun that cannot start never deletes anything.
    @discardableResult
    public func regenerate(_ assistantMessageID: UUID, in conversationID: UUID,
                           confirmingServerChange: Bool = false) -> Bool {
        guard canRerun(conversationID, confirmingServerChange: confirmingServerChange),
              var conversation = self.conversation(conversationID),
              let index = conversation.messages.firstIndex(where: { $0.id == assistantMessageID }),
              conversation.messages[index].role == .assistant,
              index > 0, conversation.messages[index - 1].role == .user else { return false }
        conversation.messages.removeSubrange(index...)
        // The triggering user message is now the last one.
        updateConversationSilently(conversation)
        startGeneration(text: nil, attachments: [], conversation: conversation)
        return true
    }

    /// Replaces the user message text, drops everything after it, then reruns.
    @discardableResult
    public func editAndResend(_ userMessageID: UUID, text: String, in conversationID: UUID,
                              confirmingServerChange: Bool = false) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              canRerun(conversationID, confirmingServerChange: confirmingServerChange),
              var conversation = self.conversation(conversationID),
              let index = conversation.messages.firstIndex(where: { $0.id == userMessageID }),
              conversation.messages[index].role == .user else { return false }
        conversation.messages[index].text = text
        conversation.messages.removeSubrange((index + 1)...)
        updateConversationSilently(conversation)
        startGeneration(text: nil, attachments: [], conversation: conversation)
        return true
    }

    private func canRerun(_ conversationID: UUID, confirmingServerChange: Bool) -> Bool {
        generationTasks[conversationID] == nil
            && generationBlocker(for: conversationID) == nil
            && (confirmingServerChange || serverChange(for: conversationID) == nil)
    }

    public func deleteMessage(_ id: UUID, in conversationID: UUID) {
        guard var conversation = self.conversation(conversationID) else { return }
        // A legacy reply might not have a parent ID yet. Removing its question
        // must not make an earlier, unrelated question eligible for continuation.
        if let index = conversation.messages.firstIndex(where: { $0.id == id && $0.role == .user }),
           index + 1 < conversation.messages.count, conversation.messages[index + 1].role == .assistant {
            conversation.messages[index + 1].replyToID = id
        }
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
                             conversation snapshot: ChatConversation, revision: UInt64, attemptID: UUID) async {
        let conversationID = snapshot.id
        // A cancelled or superseded task must not change the next connection's state.
        guard isCurrent(revision), conversations.contains(where: { $0.id == conversationID }) else { return }
        var conversation = snapshot

        // Append the user message unless this is a rerun.
        if let text {
            conversation.messages.append(ChatMessage(role: .user, text: text, attachments: attachments))
        }
        guard let userMessage = conversation.messages.last, userMessage.role == .user else {
            return
        }

        // Missing credential / missing model fast paths.
        guard case .ready = credentialState, let server, let apiKey = activeKey else {
            failFast(&conversation, with: .missingAPIKey, modelID: conversation.modelID)
            return
        }
        guard let modelID = conversation.modelID, isAvailableModel(modelID) else {
            failFast(&conversation, with: .missingModel, modelID: nil)
            return
        }

        // The history is about to be sent here, so the conversation now belongs to this server.
        conversation.serverIdentifier = server.identifier
        let placeholderTitle = String(userMessage.text.prefix(24))
        if conversation.title.isEmpty {
            conversation.title = placeholderTitle
        }
        // Only a title the app filled in may later be replaced by a generated one.
        let replaceableTitle: String? = conversation.title == placeholderTitle ? placeholderTitle : nil

        // Slash-skill application for the model prompt.
        let (modelPrompt, _, strippedText) = ChatPromptBuilder.applySkill(
            to: userMessage.text, skills: skills)

        // Assistant placeholder: applied and persisted before any async work so
        // the user message is visible immediately.
        var assistant = ChatMessage(role: .assistant, text: "", modelID: modelID,
                                    status: .streaming)
        assistant.replyToID = userMessage.id
        assistant.attempts = []
        assistant.expandedPrompt = modelPrompt == userMessage.text ? nil : modelPrompt
        let assistantID = assistant.id
        conversation.messages.append(assistant)
        conversation.updatedAt = Date()
        applyConversation(conversation)
        persist(conversation)

        // Instructions + history: prior complete/stopped messages only —
        // exclude the placeholder and the triggering user message (sent as `prompt`).
        let instructions = ChatPromptBuilder.instructions(
            settings: settings, memories: memories, conversation: conversation)
        let (history, omittedCount) = ChatPromptBuilder.boundedHistory(eligibleHistory(conversation))
        if omittedCount > 0 {
            mutateAssistant(assistantID, in: conversationID) { $0.omittedHistoryCount = omittedCount }
        }

        let baseURL = server.baseURL.appendingPathComponent("v1")
        let token = beginBackgroundTask(in: conversationID, assistantID: assistantID, attemptID: attemptID)
        defer { backgroundRunner.endTask(token) }

        // Optional web search injection. Cancellation mid-search ends the turn
        // below without marking the message as a search failure.
        let sources = await performSearch(strippedText, enabled: conversation.isWebSearchEnabled,
                                          assistantID: assistantID, in: conversationID, revision: revision)

        // Cancelled during the search step: end per stop reason, no engine call.
        if !isCurrent(revision) {
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
            baseURL: baseURL,
            apiKey: apiKey,
            modelID: modelID,
            instructions: instructions,
            history: history,
            prompt: prompt,
            images: userMessage.attachments,
            reasoningEffort: conversation.reasoningEffort)

        let succeeded = await consume(request, in: conversationID, assistant: assistant,
                                      revision: revision, attemptID: attemptID)
        if succeeded, isCurrent(revision), settings.generatesTitles,
           let current = self.conversation(conversationID),
           current.messages.filter({ $0.role == .assistant && $0.status == .complete }).count == 1,
           let replaceableTitle, current.title == replaceableTitle,
           let reply = current.messages.last(where: { $0.id == assistantID })?.text {
            generateTitle(conversationID: conversationID, userText: userMessage.text,
                          reply: reply, request: request, revision: revision,
                          replacing: replaceableTitle)
        }
    }

    private func performSearch(_ query: String, enabled: Bool, assistantID: UUID,
                               in conversationID: UUID, revision: UInt64) async -> [ChatSearchSource] {
        var sources: [ChatSearchSource] = []
        var searchKey: (provider: ChatSearchProvider, key: String)?
        if enabled, let provider = settings.searchProvider,
           let key = try? await secrets.loadSecret(account: ChatSecrets.searchKeyAccount(for: provider)),
           !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            searchKey = (provider, key)
        } else if enabled, isCurrent(revision) {
            // Web search is on but cannot run: say so on the reply instead of answering silently without it.
            mutateAssistant(assistantID, in: conversationID) { $0.failure = .searchNotConfigured }
        }
        if let provider = searchKey?.provider, let key = searchKey?.key {
            do {
                sources = try await searchClient(provider).search(query, apiKey: key)
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
        return sources
    }

    private func eligibleHistory(_ conversation: ChatConversation) -> [ChatMessage] {
        conversation.messages.dropLast(2).filter {
            (!$0.text.isEmpty || ($0.role == .user && !$0.attachments.isEmpty))
                && ($0.status == .complete || $0.status == .stopped)
        }
    }

    private func beginBackgroundTask(in conversationID: UUID, assistantID: UUID, attemptID: UUID) -> ChatBackgroundToken {
        backgroundRunner.beginTask { [weak self] in
            guard let self, self.generationTasks[conversationID]?.id == attemptID, self.stopReasons[conversationID] == nil,
                  self.conversation(conversationID)?.messages.last?.id == assistantID,
                  self.conversation(conversationID)?.messages.last?.status == .streaming else { return }
            self.stopReasons[conversationID] = .backgroundExpired
            self.generationTasks[conversationID]?.task.cancel()
        }
    }

    private func consume(_ request: ChatEngineRequest, in conversationID: UUID, assistant: ChatMessage,
                         revision: UInt64, attemptID: UUID) async -> Bool {
        let assistantID = assistant.id
        var boundary = ChatContinuationBoundary(base: assistant.text)
        let previousUsage = assistant.usage ?? ChatTokenUsage()
        mutateAssistant(assistantID, in: conversationID) {
            $0.attempts?.append(ChatReplyAttempt(modelID: request.modelID, status: .streaming))
        }
        if let current = conversation(conversationID) { persist(current) }
        var succeeded = false
        var lastPartialWrite = ContinuousClock.now
        do {
            for try await event in engine.stream(request) {
                try Task.checkCancellation()
                guard generationTasks[conversationID]?.id == attemptID, isCurrent(revision) else { return false }
                switch event {
                case .snapshot(let text, let reasoning):
                    let suffix = boundary.suffix(for: text)
                    mutateAssistant(assistantID, in: conversationID) {
                        $0.text = assistant.text + suffix.visible
                        $0.pendingContinuation = suffix.pending
                        if let reasoning, !reasoning.isEmpty {
                            let previous = assistant.reasoning ?? ""
                            $0.reasoning = previous.isEmpty ? reasoning : previous + "\n\n" + reasoning
                        }
                    }
                    // Throttled partial writes keep displayed text if the app is terminated mid-stream.
                    let now = ContinuousClock.now
                    if now - lastPartialWrite >= streamingPersistInterval,
                       let current = self.conversation(conversationID) {
                        lastPartialWrite = now
                        persist(current)
                    }
                case .usage(let usage):
                    mutateAssistant(assistantID, in: conversationID) {
                        if let last = $0.attempts?.indices.last { $0.attempts?[last].usage = usage }
                        $0.usage = ChatTokenUsage(inputTokens: previousUsage.inputTokens + usage.inputTokens,
                                                 outputTokens: previousUsage.outputTokens + usage.outputTokens,
                                                 reasoningTokens: previousUsage.reasoningTokens + usage.reasoningTokens)
                    }
                }
            }
            // A cancelled consumer may see the stream end normally.
            try Task.checkCancellation()
            let addedAnswerText = self.conversation(conversationID)?.messages
                .first(where: { $0.id == assistantID })
                .map { $0.text != assistant.text || !($0.pendingContinuation ?? "").isEmpty } ?? false
            if assistant.attempts?.isEmpty == false, !addedAnswerText {
                mutateAssistant(assistantID, in: conversationID) {
                    $0.status = .failed
                    $0.failure = .continuationAddedNothing
                }
            } else {
                mutateAssistant(assistantID, in: conversationID) { $0.status = .complete }
                succeeded = true
            }
        } catch {
            guard generationTasks[conversationID]?.id == attemptID else { return false }
            if !isCurrent(revision) || AnyLanguageModelChatEngine.failure(for: error) == nil {
                // Cancellation: user stop or background expiration.
                finishAborted(assistantID: assistantID, in: conversationID)
            } else {
                mutateAssistant(assistantID, in: conversationID) {
                    $0.status = .failed
                    $0.failure = AnyLanguageModelChatEngine.failure(for: error)
                }
            }
        }

        mutateAssistant(assistantID, in: conversationID) { $0.finishAttempt() }
        // Await the final write so an interrupted reply is on disk before iOS
        // can suspend the app when endTask runs.
        if let updated = self.conversation(conversationID) {
            await persist(updated).value
        }

        if succeeded, isCurrent(revision), backgroundRunner.isAppInBackground, settings.notifiesOnBackgroundCompletion {
            await backgroundRunner.notifyCompletion(conversationID: conversationID)
        }
        return succeeded
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

    /// Applied only while the title is still `replacing`, so a title the user
    /// set or changed in the meantime is never overwritten.
    private func generateTitle(conversationID: UUID, userText: String, reply: String,
                               request: ChatEngineRequest, revision: UInt64, replacing: String) {
        titleTasks[conversationID] = Task {
            defer { self.titleTasks[conversationID] = nil }
            guard isCurrent(revision), self.conversation(conversationID) != nil else { return }
            let titleRequest = ChatEngineRequest(
                baseURL: request.baseURL,
                apiKey: request.apiKey,
                modelID: request.modelID,
                prompt: "用不超过 12 个字概括以下对话的主题，只输出标题：\n\(userText)\n\(String(reply.prefix(500)))")
            guard let raw = try? await engine.complete(titleRequest), isCurrent(revision) else { return }
            var title = raw.trimmingCharacters(in: Self.titleTrimming)
            title = String(title.prefix(30))
            guard !title.isEmpty else { return }
            if let index = self.conversations.firstIndex(where: { $0.id == conversationID }),
               self.conversations[index].title == replacing {
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
            case .connectionChanged:
                $0.status = .interrupted
                $0.failure = .connectionChanged
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
    private func enqueuePersist(_ work: @escaping @MainActor @Sendable () async -> Void) -> Task<Void, Never> {
        let previous = persistTail
        let task = Task {
            await previous?.value
            await work()
        }
        persistTail = task
        return task
    }

    /// Persists a conversation. Empty conversations are never written; one
    /// that became empty has its earlier file removed so it cannot come back.
    @discardableResult
    private func persist(_ conversation: ChatConversation) -> Task<Void, Never> {
        let store = persistence
        return enqueuePersist {
            do {
                if conversation.messages.isEmpty {
                    try await store.removeConversation(conversation.id)
                } else {
                    try await store.saveConversation(conversation)
                }
                self.unsavedConversations.remove(conversation.id)
            } catch {
                self.unsavedConversations.insert(conversation.id)
            }
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

    /// `/partial` (no whitespace yet) → prefix matches on normalized commands;
    /// a lone `/` lists every skill, as the composer hint promises.
    public func skillSuggestions(for draft: String) -> [ChatSkill] {
        guard draft.hasPrefix("/") else { return [] }
        let partial = draft.dropFirst()
        guard !partial.contains(where: { $0.isWhitespace }) else { return [] }
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

    public func notificationAuthorizationStatus() async -> ChatNotificationAuthorization {
        await backgroundRunner.notificationAuthorizationStatus()
    }

    /// Set when a completion notification is opened; the chat UI shows that
    /// conversation and clears the request.
    public var requestedConversationID: UUID?
}
