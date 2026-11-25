import Foundation
import CPAQuotaKit

extension ChatWorkspaceModel {
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
        temporaryRecentReasoningEfforts.removeAll()
        manualReasoningConversationIDs.removeAll()
        persistsKey = true
        discoveryFactory = nil
        activeKey = nil
        credentialState = .unbound
        discoveredKeys = []
        keyRemovalFailed = false
        models = []
        modelListState = .idle
        engine.resetReasoningCapabilities()
    }

    func advanceCredentialRevision() {
        credentialRevision &+= 1
        isDiscoveringKeys = false
        keyDiscoveryError = nil
        for (id, generation) in generationTasks {
            if stopReasons[id] == nil { stopReasons[id] = .connectionChanged }
            generation.task.cancel()
        }
        for task in titleTasks.values { task.cancel() }
    }

    func isCurrent(_ revision: UInt64) -> Bool {
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
        engine.resetReasoningCapabilities()
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
        let previousModelListState = modelListState
        let revision: UInt64?
        if self.server == server {
            advanceCredentialRevision()
            revision = credentialRevision
            credentialState = .loading
            keyRemovalFailed = false
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
                modelListState = previousModelListState == .loading ? .idle : previousModelListState
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

    // MARK: - Model catalog & model preferences

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
            engine.resetReasoningCapabilities()
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

    func preferredReasoningEffort(for modelID: String?) -> ChatReasoningEffort {
        guard let server, let modelID else { return .automatic }
        if persistsKey, !settingsLoadFailed {
            return settings.rememberedReasoningEffort(for: modelID, server: server.identifier) ?? .automatic
        }
        return temporaryRecentReasoningEfforts[modelID] ?? .automatic
    }

    private var preferredModelID: String? {
        switch settings.newConversationModelStrategy {
        case .fixed: return settings.defaultModelID
        case .mostRecent:
            guard let server else { return nil }
            return persistsKey ? settings.recentModelIDs?[server.identifier] : temporaryRecentModelID
        }
    }

    var defaultModelID: String? {
        guard modelListState == .loaded else { return nil }
        if let preferred = preferredModelID, isAvailableModel(preferred) {
            return preferred
        }
        return models.first?.id
    }

    /// Conversations opened before the model list arrived get the default model.
    private func assignDefaultModelWhereMissing() {
        guard let server, let modelID = defaultModelID else { return }
        let rememberedEffort = preferredReasoningEffort(for: modelID)
        for index in conversations.indices where conversations[index].messages.isEmpty
            && (conversations[index].serverIdentifier == nil || conversations[index].serverIdentifier == server.identifier)
            && !isAvailableModel(conversations[index].modelID) {
            conversations[index].serverIdentifier = server.identifier
            conversations[index].modelID = modelID
            if !manualReasoningConversationIDs.contains(conversations[index].id) {
                conversations[index].reasoningEffort = rememberedEffort
            }
            syncSummary(for: conversations[index], reorder: false)
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
        guard let server, isAvailableModel(id), let existing = conversation(conversationID) else { return }
        let shouldAdoptRememberedEffort = existing.messages.isEmpty
            && !manualReasoningConversationIDs.contains(conversationID)
        let rememberedEffort = shouldAdoptRememberedEffort ? preferredReasoningEffort(for: id) : nil
        updateConversationMetadata(conversationID) {
            $0.modelID = id
            if let rememberedEffort {
                $0.reasoningEffort = rememberedEffort
            }
        }
        if persistsKey, !settingsLoadFailed {
            settings.rememberModel(id, for: server.identifier)
        } else {
            temporaryRecentModelID = id
        }
    }

    /// Updates a conversation's reasoning effort and remembers the preference for its active model.
    public func selectReasoningEffort(_ effort: ChatReasoningEffort, in conversationID: UUID) {
        guard let existing = conversation(conversationID) else { return }
        manualReasoningConversationIDs.insert(conversationID)
        updateConversationMetadata(conversationID) { $0.reasoningEffort = effort }
        guard let server, let modelID = existing.modelID else { return }
        if persistsKey, !settingsLoadFailed {
            settings.rememberReasoningEffort(effort, for: modelID, server: server.identifier)
        } else {
            temporaryRecentReasoningEfforts[modelID] = effort
        }
    }
}
