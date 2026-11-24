import Foundation
import CPAQuotaKit

extension ChatWorkspaceModel {
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
        let store = persistence
        async let loadedSettings: Result<ChatSettings?, any Error> = {
            do { return .success(try await store.loadSettings()) }
            catch { return .failure(error) }
        }()
        async let loadedMemories: Result<[ChatMemoryItem]?, any Error> = {
            do { return .success(try await store.loadMemories()) }
            catch { return .failure(error) }
        }()
        async let loadedSkills: Result<[ChatSkill]?, any Error> = {
            do { return .success(try await store.loadSkills()) }
            catch { return .failure(error) }
        }()

        if store.supportsIndexedLoading {
            let storedSummaries = ((try? await store.loadConversationSummaries()) ?? [])
                .filter { $0.messageCount > 0 }
            let localIDs = Set(conversations.map(\.id))
            let localSummaries = conversations.map(ChatConversationSummary.init(from:))
            let mergedSummaries = storedSummaries.filter { !localIDs.contains($0.id) } + localSummaries
            conversationSummaries = mergedSummaries.sorted { $0.updatedAt > $1.updatedAt }

            // Immediately hydrate any conversation that died mid-stream so interrupted replies recover on launch.
            for summary in storedSummaries where summary.hasStreamingMessage && !localIDs.contains(summary.id) {
                if let loaded = try? await store.loadConversation(summary.id), !loaded.messages.isEmpty {
                    conversations.append(loaded)
                    touchHydrated(loaded.id)
                }
            }
            conversations.sort { $0.updatedAt > $1.updatedAt }
            rebuildConversationIndex()
            recoverOrphanedReplies()
        } else {
            let stored = ((try? await store.loadConversations()) ?? [])
                .filter { !$0.messages.isEmpty }
            // Keep anything created in memory meanwhile instead of overwriting it.
            let created = conversations.filter { local in !stored.contains { $0.id == local.id } }
            conversations = (stored + created).sorted { $0.updatedAt > $1.updatedAt }
            rebuildConversationIndex()
            recoverOrphanedReplies()
            conversationSummaries = conversations.map(ChatConversationSummary.init(from:))
        }

        applyLoadedSettings(await loadedSettings)
        applyLoadedMemories(await loadedMemories)
        applyLoadedSkills(await loadedSkills)
    }

    /// Lazily hydrates a single conversation from disk when it is opened.
    /// Concurrent requests for the same ID coalesce into one load.
    @discardableResult
    public func loadConversationIfNeeded(_ id: UUID) async -> ChatConversation? {
        if let existing = conversation(id) {
            touchHydrated(id)
            return existing
        }
        if let existingTask = hydrationTasks[id] {
            return await existingTask.value
        }
        guard hasConversation(id) else { return nil }
        let store = persistence
        loadingConversationIDs.insert(id)
        let task = Task<ChatConversation?, Never> { @MainActor in
            defer {
                self.loadingConversationIDs.remove(id)
                self.hydrationTasks.removeValue(forKey: id)
            }
            guard let loaded = try? await store.loadConversation(id) else { return nil }
            // If the conversation was deleted while loading, do not resurrect it.
            guard self.hasConversation(id) else { return nil }
            if let existing = self.conversation(id) {
                self.touchHydrated(id)
                return existing
            }
            var hydrated = loaded
            if let pendingTitle = self.pendingSummaryRenames[id] {
                hydrated.title = pendingTitle
            }
            var recovered = false
            if self.generationTasks[id] == nil {
                for messageIndex in hydrated.messages.indices where hydrated.messages[messageIndex].status == .streaming {
                    hydrated.messages[messageIndex].status = .interrupted
                    hydrated.messages[messageIndex].failure = .generationInterrupted
                    hydrated.messages[messageIndex].finishAttempt(commitPending: false)
                    recovered = true
                }
            }
            self.conversations.append(hydrated)
            self.conversations.sort { $0.updatedAt > $1.updatedAt }
            self.rebuildConversationIndex()
            self.syncSummary(for: hydrated, reorder: false)
            self.touchHydrated(id)
            if recovered {
                self.persist(hydrated)
            }
            self.evictHydratedConversationsIfNeeded(preserving: id)
            return hydrated
        }
        hydrationTasks[id] = task
        return await task.value
    }

    /// Evicts oldest inactive hydrated conversations to keep memory bounded
    /// when backed by indexed disk storage.
    func evictHydratedConversationsIfNeeded(preserving protectedID: UUID?) {
        guard persistence.supportsIndexedLoading, conversations.count > maxHydratedConversations else { return }
        var remainingOrder: [UUID] = []
        var evictedAny = false
        for id in hydratedAccessOrder {
            let overLimit = conversations.count > maxHydratedConversations
            if overLimit, canEvictHydratedConversation(id, preserving: protectedID) {
                if let index = conversationIndex(for: id) {
                    conversations.remove(at: index)
                    rebuildConversationIndex()
                    evictedAny = true
                    continue
                }
            }
            remainingOrder.append(id)
        }
        hydratedAccessOrder = remainingOrder
        if evictedAny {
            rebuildConversationIndex()
        }
    }

    private func canEvictHydratedConversation(_ id: UUID, preserving protectedID: UUID?) -> Bool {
        guard id != protectedID,
              generationTasks[id] == nil,
              titleTasks[id] == nil,
              !unsavedConversations.contains(id),
              !failedConversationDeletions.contains(id),
              drafts[id] == nil,
              let convo = conversation(id),
              !convo.messages.isEmpty else {
            return false
        }
        return true
    }

    /// Searches conversation titles and message text across both hydrated
    /// conversations and unhydrated on-disk records without decoding images.
    public func searchConversationIDs(matching query: String) async -> Set<UUID> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var matches = Set<UUID>()
        var hydratedIDs = Set<UUID>()

        for conversation in conversations {
            hydratedIDs.insert(conversation.id)
            if conversation.title.localizedCaseInsensitiveContains(trimmed)
                || conversation.messages.contains(where: { $0.text.localizedCaseInsensitiveContains(trimmed) }) {
                matches.insert(conversation.id)
            }
        }

        var needsDiskSearch = false
        for summary in conversationSummaries where !hydratedIDs.contains(summary.id) {
            if summary.title.localizedCaseInsensitiveContains(trimmed)
                || summary.previewText.localizedCaseInsensitiveContains(trimmed) {
                matches.insert(summary.id)
            } else {
                needsDiskSearch = true
            }
        }

        if needsDiskSearch, let diskMatches = try? await persistence.searchConversationIDs(matching: trimmed) {
            let knownIDs = Set(conversationSummaries.map(\.id))
            for id in diskMatches where knownIDs.contains(id) && !hydratedIDs.contains(id) {
                matches.insert(id)
            }
        }
        return matches
    }

    /// Retries loading any workspace metadata whose initial read failed.
    public func retryLoadMetadata() async {
        if settingsLoadFailed { await loadSettingsFromDisk() }
        if memoriesLoadFailed { await loadMemoriesFromDisk() }
        if skillsLoadFailed { await loadSkillsFromDisk() }
    }

    private func loadSettingsFromDisk() async {
        let result: Result<ChatSettings?, any Error>
        do { result = .success(try await persistence.loadSettings()) }
        catch { result = .failure(error) }
        applyLoadedSettings(result)
    }

    private func applyLoadedSettings(_ result: Result<ChatSettings?, any Error>) {
        switch result {
        case .success(let stored):
            if let stored {
                isApplyingLoadedSettings = true
                settings = stored
                isApplyingLoadedSettings = false
            }
            settingsLoadFailed = false
        case .failure:
            settingsLoadFailed = true
        }
    }

    private func loadMemoriesFromDisk() async {
        let result: Result<[ChatMemoryItem]?, any Error>
        do { result = .success(try await persistence.loadMemories()) }
        catch { result = .failure(error) }
        applyLoadedMemories(result)
    }

    private func applyLoadedMemories(_ result: Result<[ChatMemoryItem]?, any Error>) {
        switch result {
        case .success(let stored):
            memories = stored ?? []
            memoriesLoadFailed = false
        case .failure:
            memories = []
            memoriesLoadFailed = true
        }
    }

    private func loadSkillsFromDisk() async {
        let result: Result<[ChatSkill]?, any Error>
        do { result = .success(try await persistence.loadSkills()) }
        catch { result = .failure(error) }
        applyLoadedSkills(result)
    }

    private func applyLoadedSkills(_ result: Result<[ChatSkill]?, any Error>) {
        switch result {
        case .success(let stored):
            if let stored {
                skills = stored
            } else {
                skills = Self.defaultSkills
                persistSkills(skills)
            }
            skillsLoadFailed = false
        case .failure:
            // Never overwrite an unreadable skills file with defaults.
            skills = []
            skillsLoadFailed = true
        }
    }

    /// A reply still marked `.streaming` with no running task was cut off when
    /// the app ended; it is kept as interrupted so it can be regenerated.
    func recoverOrphanedReplies() {
        for index in conversations.indices where generationTasks[conversations[index].id] == nil {
            var changed = false
            for messageIndex in conversations[index].messages.indices
            where conversations[index].messages[messageIndex].status == .streaming {
                conversations[index].messages[messageIndex].status = .interrupted
                conversations[index].messages[messageIndex].failure = .generationInterrupted
                conversations[index].messages[messageIndex].finishAttempt(commitPending: false)
                changed = true
            }
            if changed {
                syncSummary(for: conversations[index], reorder: false)
                persist(conversations[index])
            }
        }
    }

    /// Merges conversations persisted after our snapshot (e.g. written while
    /// the app was suspended); newer `updatedAt` wins per conversation.
    public func reloadNewerConversations() async {
        if persistence.supportsIndexedLoading {
            let onDisk = ((try? await persistence.loadConversationSummaries()) ?? [])
                .filter { $0.messageCount > 0 }
            var summaryChanged = false
            var hydratedChanged = false
            for remote in onDisk {
                if let summaryIndex = conversationSummaries.firstIndex(where: { $0.id == remote.id }) {
                    if remote.updatedAt > conversationSummaries[summaryIndex].updatedAt {
                        conversationSummaries[summaryIndex] = remote
                        summaryChanged = true
                        if let cIndex = conversationIndex(for: remote.id),
                           let refreshed = try? await persistence.loadConversation(remote.id) {
                            conversations[cIndex] = refreshed
                            hydratedChanged = true
                        }
                    }
                } else {
                    conversationSummaries.append(remote)
                    summaryChanged = true
                }
            }
            if summaryChanged {
                conversationSummaries.sort { $0.updatedAt > $1.updatedAt }
            }
            if hydratedChanged {
                conversations.sort { $0.updatedAt > $1.updatedAt }
                rebuildConversationIndex()
            }
            return
        }

        let onDisk = (try? await persistence.loadConversations()) ?? []
        var changed = false
        for remote in onDisk {
            if let index = conversationIndex(for: remote.id) {
                if remote.updatedAt > conversations[index].updatedAt {
                    conversations[index] = remote
                    syncSummary(for: remote, reorder: false)
                    changed = true
                }
            } else {
                conversations.append(remote)
                syncSummary(for: remote, reorder: false)
                changed = true
            }
        }
        if changed {
            conversations.sort { $0.updatedAt > $1.updatedAt }
            rebuildConversationIndex()
            conversationSummaries.sort { $0.updatedAt > $1.updatedAt }
        }
    }

    /// Reuses an existing empty conversation instead of stacking up new ones,
    /// resetting per-conversation settings so nothing leaks across servers.
    @discardableResult
    public func createConversation() -> UUID {
        let modelID = defaultModelID
        let effort = preferredReasoningEffort(for: modelID)
        if let index = conversations.firstIndex(where: { $0.messages.isEmpty && generationTasks[$0.id] == nil }) {
            var reused = conversations.remove(at: index)
            reused.title = ""
            reused.systemPrompt = ""
            reused.reasoningEffort = effort
            reused.isWebSearchEnabled = false
            reused.serverIdentifier = server?.identifier
            reused.modelID = modelID
            reused.updatedAt = Date()
            manualReasoningConversationIDs.remove(reused.id)
            drafts.removeValue(forKey: reused.id)
            conversations.insert(reused, at: 0)
            rebuildConversationIndex()
            syncSummary(for: reused, reorder: true)
            touchHydrated(reused.id)
            return reused.id
        }
        let conversation = ChatConversation(modelID: modelID, reasoningEffort: effort,
                                            serverIdentifier: server?.identifier)
        conversations.insert(conversation, at: 0)
        rebuildConversationIndex()
        syncSummary(for: conversation, reorder: true)
        touchHydrated(conversation.id)
        return conversation.id
    }

    /// Removes a conversation only after its backing file is removed (or absent).
    /// Returns `false` and keeps the conversation visible for retry on failure.
    @discardableResult
    public func deleteConversation(_ id: UUID) async -> Bool {
        generationTasks[id]?.task.cancel()
        generationTasks[id] = nil
        stopReasons[id] = nil
        titleTasks[id]?.cancel()
        titleTasks[id] = nil
        hydrationTasks[id]?.cancel()
        hydrationTasks[id] = nil
        loadingConversationIDs.remove(id)
        let store = persistence
        let previous = persistTail
        let removal = Task { () -> Bool in
            await previous?.value
            do {
                try await store.removeConversation(id)
                return true
            } catch {
                return false
            }
        }
        persistTail = Task { _ = await removal.value }
        guard await removal.value else {
            failedConversationDeletions.insert(id)
            return false
        }
        conversations.removeAll { $0.id == id }
        conversationSummaries.removeAll { $0.id == id }
        hydratedAccessOrder.removeAll { $0 == id }
        pendingSummaryRenames.removeValue(forKey: id)
        rebuildConversationIndex()
        manualReasoningConversationIDs.remove(id)
        drafts.removeValue(forKey: id)
        unsavedConversations.remove(id)
        failedConversationDeletions.remove(id)
        return true
    }

    /// Returns `false` when some records could not be removed; those are read
    /// back from disk so the list shows what is still stored and the user can retry.
    @discardableResult
    public func deleteAllConversations() async -> Bool {
        for generation in generationTasks.values { generation.task.cancel() }
        for task in titleTasks.values { task.cancel() }
        for task in hydrationTasks.values { task.cancel() }
        generationTasks.removeAll()
        stopReasons.removeAll()
        titleTasks.removeAll()
        hydrationTasks.removeAll()
        loadingConversationIDs.removeAll()
        // Clear first: cancelled generations then find no conversation to write back.
        conversations.removeAll()
        conversationSummaries.removeAll()
        hydratedAccessOrder.removeAll()
        pendingSummaryRenames.removeAll()
        conversationIndexByID.removeAll()
        drafts.removeAll()
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
            do {
                if persistence.supportsIndexedLoading {
                    let remainingSummaries = try await persistence.loadConversationSummaries()
                        .filter { stored in stored.messageCount > 0 && !conversationSummaries.contains { $0.id == stored.id } }
                    conversationSummaries.append(contentsOf: remainingSummaries)
                    conversationSummaries.sort { $0.updatedAt > $1.updatedAt }
                    for summary in remainingSummaries where summary.hasStreamingMessage {
                        if let loaded = try? await persistence.loadConversation(summary.id) {
                            conversations.append(loaded)
                            touchHydrated(loaded.id)
                        }
                    }
                    conversations.sort { $0.updatedAt > $1.updatedAt }
                    rebuildConversationIndex()
                    recoverOrphanedReplies()
                } else {
                    let remaining = try await persistence.loadConversations()
                        .filter { stored in !stored.messages.isEmpty && !conversations.contains { $0.id == stored.id } }
                    conversations.append(contentsOf: remaining)
                    conversations.sort { $0.updatedAt > $1.updatedAt }
                    rebuildConversationIndex()
                    recoverOrphanedReplies()
                    conversationSummaries = conversations.map(ChatConversationSummary.init(from:))
                }
                deleteAllStateUnknown = false
            } catch {
                deleteAllStateUnknown = true
            }
            return false
        }
        deleteAllStateUnknown = false
        failedConversationDeletions.removeAll()
        unsavedConversations.removeAll()
        return true
    }

    public func renameConversation(_ id: UUID, title: String) {
        if conversationIndex(for: id) != nil {
            pendingSummaryRenames.removeValue(forKey: id)
            updateConversationMetadata(id) { $0.title = title }
            return
        }
        guard let summaryIndex = conversationSummaries.firstIndex(where: { $0.id == id }) else { return }
        guard conversationSummaries[summaryIndex].title != title else { return }
        pendingSummaryRenames[id] = title
        conversationSummaries[summaryIndex].title = title
        Task { @MainActor in
            guard await self.loadConversationIfNeeded(id) != nil,
                  self.pendingSummaryRenames[id] == title else { return }
            self.pendingSummaryRenames.removeValue(forKey: id)
            guard let index = self.conversationIndex(for: id) else { return }
            self.conversations[index].title = title
            self.syncSummary(for: self.conversations[index], reorder: false)
            self.persist(self.conversations[index])
        }
    }

    /// Updates per-conversation metadata (title, system prompt, model, reasoning,
    /// web search) without bumping `updatedAt` or re-sorting the conversation list.
    public func updateConversationMetadata(_ id: UUID, _ mutate: (inout ChatConversation) -> Void) {
        guard let index = conversationIndex(for: id) else { return }
        let before = conversations[index]
        mutate(&conversations[index])
        guard conversations[index] != before else { return }
        syncSummary(for: conversations[index], reorder: false)
        persist(conversations[index])
    }

    public func updateConversation(_ id: UUID, _ mutate: (inout ChatConversation) -> Void) {
        guard let index = conversationIndex(for: id) else { return }
        mutate(&conversations[index])
        conversations[index].updatedAt = Date()
        let updated = conversations[index]
        conversations.sort { $0.updatedAt > $1.updatedAt }
        rebuildConversationIndex()
        syncSummary(for: updated, reorder: true)
        persist(updated)
    }

    /// Mutates without bumping `updatedAt` (message-level edits).
    func updateConversationSilently(_ conversation: ChatConversation) {
        guard let index = conversationIndex(for: conversation.id) else { return }
        var copy = conversation
        copy.updatedAt = conversations[index].updatedAt
        conversations[index] = copy
        syncSummary(for: copy, reorder: false)
        persist(copy)
    }

    func applyConversation(_ conversation: ChatConversation) {
        if let index = conversationIndex(for: conversation.id) {
            conversations[index] = conversation
            conversations.sort { $0.updatedAt > $1.updatedAt }
            rebuildConversationIndex()
        } else {
            conversations.insert(conversation, at: 0)
            conversations.sort { $0.updatedAt > $1.updatedAt }
            rebuildConversationIndex()
        }
        syncSummary(for: conversation, reorder: true)
        touchHydrated(conversation.id)
    }

    // MARK: - Serialized persistence queue

    @discardableResult
    func enqueuePersist(_ work: @escaping @MainActor @Sendable () async -> Void) -> Task<Void, Never> {
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
    func persist(_ conversation: ChatConversation) -> Task<Void, Never> {
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

    @discardableResult
    func persistSettings(_ value: ChatSettings) -> Task<Bool, Never> {
        let store = persistence
        let previous = persistTail
        let write = Task { @MainActor () -> Bool in
            await previous?.value
            do {
                try await store.saveSettings(value)
                self.unsavedSettings = false
                self.settingsLoadFailed = false
                return true
            } catch {
                self.unsavedSettings = true
                return false
            }
        }
        persistTail = Task { _ = await write.value }
        return write
    }

    @discardableResult
    public func retrySaveSettings() async -> Bool {
        await persistSettings(settings).value
    }

    @discardableResult
    func persistMemories(_ value: [ChatMemoryItem]) -> Task<Bool, Never> {
        let store = persistence
        let previous = persistTail
        let write = Task { @MainActor () -> Bool in
            await previous?.value
            do {
                try await store.saveMemories(value)
                self.unsavedMemories = false
                return true
            } catch {
                self.unsavedMemories = true
                return false
            }
        }
        persistTail = Task { _ = await write.value }
        return write
    }

    @discardableResult
    func persistSkills(_ value: [ChatSkill]) -> Task<Bool, Never> {
        let store = persistence
        let previous = persistTail
        let write = Task { @MainActor () -> Bool in
            await previous?.value
            do {
                try await store.saveSkills(value)
                self.unsavedSkills = false
                return true
            } catch {
                self.unsavedSkills = true
                return false
            }
        }
        persistTail = Task { _ = await write.value }
        return write
    }
}
