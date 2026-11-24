import Foundation
import CPAQuotaKit

extension ChatWorkspaceModel {
    public func isGenerating(_ conversationID: UUID) -> Bool {
        generationTasks[conversationID] != nil
    }

    /// Stored memories are withheld whenever preferences could not be restored,
    /// so a failed settings read can never override a user's disabled setting.
    private var effectiveMemoriesForPrompt: [ChatMemoryItem] {
        (settingsLoadFailed || memoriesLoadFailed) ? [] : memories
    }

    /// `nil` when the conversation may be continued on the bound server as is.
    public func serverChange(for conversationID: UUID) -> ChatServerChange? {
        guard let server, let conversation = conversation(conversationID),
              !conversation.messages.isEmpty,
              conversation.serverIdentifier != server.identifier else { return nil }
        return ChatServerChange(
            conversationID: conversationID,
            previousServerIdentifier: conversation.serverIdentifier,
            currentServerIdentifier: server.identifier,
            messageCount: conversation.messages.count,
            imageCount: conversation.messages.reduce(0) { $0 + $1.attachments.count },
            credentialRevision: credentialRevision)
    }

    private func isServerChangeAllowed(for conversationID: UUID,
                                       confirming confirmation: ChatServerChange?) -> Bool {
        if let confirmation {
            guard confirmation.conversationID == conversationID,
                  confirmation.currentServerIdentifier == server?.identifier,
                  isCurrent(confirmation.credentialRevision) else { return false }
            if let current = serverChange(for: conversationID) {
                return confirmation.previousServerIdentifier == current.previousServerIdentifier
            }
            return true
        }
        return serverChange(for: conversationID) == nil
    }

    /// Why a rerun (regenerate / edit and resend) cannot start right now.
    /// Reruns check this before truncating anything.
    public func generationBlocker(for conversationID: UUID) -> ChatFailure? {
        guard case .ready = credentialState, server != nil, activeKey != nil else { return .missingAPIKey }
        guard isAvailableModel(conversation(conversationID)?.modelID) else { return .missingModel }
        return nil
    }

    /// Returns `false` without changing anything when the conversation belongs
    /// to another server and no matching `ChatServerChange` confirmation is supplied.
    @discardableResult
    public func send(_ text: String, attachments: [ChatImageAttachment], in conversationID: UUID,
                     confirmingServerChange confirmation: ChatServerChange? = nil) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty,
              generationTasks[conversationID] == nil,
              isServerChangeAllowed(for: conversationID, confirming: confirmation),
              let conversation = self.conversation(conversationID) else { return false }
        startGeneration(text: text, attachments: attachments, conversation: conversation)
        drafts.removeValue(forKey: conversationID)
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
    public func continueReply(_ target: ChatContinuation,
                              confirmingServerChange confirmation: ChatServerChange? = nil) -> Bool {
        let id = target.conversationID
        guard continuation(for: id) == target,
              isServerChangeAllowed(for: id, confirming: confirmation) else { return false }
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
        // Record the new streaming attempt before persisting so a crash during
        // search recovery never overwrites the previous completed attempt.
        reply.attempts?.append(ChatReplyAttempt(modelID: target.modelID, status: .streaming))
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
        if target.isRetry, saved.searchCompleted != true, sources.isEmpty, conversation.isWebSearchEnabled {
            let query = saved.searchQuery ?? ChatPromptBuilder.applySkill(to: question.text, skills: skills).rest
            if saved.searchQuery == nil {
                reply.searchQuery = query
                mutateAssistant(saved.id, in: id) { $0.searchQuery = query }
            }
            sources = await performSearch(query, enabled: true, assistantID: saved.id,
                                          in: id, revision: target.revision, attemptID: attemptID)
            // If the conversation was deleted or superseded, exit without re-persisting it.
            guard generationTasks[id]?.id == attemptID else { return }
            guard isCurrent(target.revision) else {
                finishAborted(assistantID: saved.id, in: id)
                mutateAssistant(saved.id, in: id) { $0.finishAttempt(commitPending: false) }
                if let updated = self.conversation(id) {
                    syncSummary(for: updated, reorder: false)
                    await persist(updated).value
                }
                return
            }
            reply.searchSources = sources
        }

        // Re-verify target model availability after async search completes.
        guard isAvailableModel(target.modelID) else {
            mutateAssistant(saved.id, in: id) {
                $0.status = .failed
                $0.failure = .missingModel
                $0.finishAttempt(commitPending: false)
            }
            if let updated = self.conversation(id) {
                syncSummary(for: updated, reorder: false)
                await persist(updated).value
            }
            return
        }

        let effectivePrompt = ChatPromptBuilder.searchInjectedPrompt(original, sources: sources)
        let context = ChatPromptBuilder.continuationContext(
            earlier: eligibleHistory(conversation), question: question, reply: reply, effectivePrompt: effectivePrompt)
        reply.omittedHistoryCount = context.omitted > 0 ? context.omitted : nil
        let modelOwnedBy = models.first(where: { $0.id == target.modelID })?.ownedBy
        mutateAssistant(saved.id, in: id) {
            $0.omittedHistoryCount = reply.omittedHistoryCount
            $0.reasoningResolution = nil
        }
        let request = ChatEngineRequest(baseURL: server.baseURL.appendingPathComponent("v1"), apiKey: apiKey,
                                        modelID: target.modelID, modelOwnedBy: modelOwnedBy,
                                        instructions: ChatPromptBuilder.instructions(settings: settings,
                                                                                     memories: effectiveMemoriesForPrompt,
                                                                                     conversation: conversation),
                                        history: context.history, prompt: context.prompt, images: context.images,
                                        reasoningEffort: conversation.reasoningEffort)
        let sentExcerpt = target.isRetry ? nil : context.history.last?.text
        _ = await consume(request, in: id, assistant: reply, revision: target.revision, attemptID: attemptID,
                          isContinuation: true, attemptAlreadyAppended: true, sentReplyExcerpt: sentExcerpt)
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
                           confirmingServerChange confirmation: ChatServerChange? = nil) -> Bool {
        guard canRerun(conversationID, confirmingServerChange: confirmation),
              var conversation = self.conversation(conversationID),
              let index = conversation.messages.firstIndex(where: { $0.id == assistantMessageID }),
              index > 0 else { return false }
        let reply = conversation.messages[index]
        let question = conversation.messages[index - 1]
        guard reply.role == .assistant, question.role == .user,
              reply.replyToID == nil || reply.replyToID == question.id else { return false }
        conversation.messages.removeSubrange(index...)
        // The triggering user message is now the last one.
        updateConversationSilently(conversation)
        startGeneration(text: nil, attachments: [], conversation: conversation)
        return true
    }

    /// Replaces the user message text, drops everything after it, then reruns.
    @discardableResult
    public func editAndResend(_ userMessageID: UUID, text: String, in conversationID: UUID,
                              confirmingServerChange confirmation: ChatServerChange? = nil) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              canRerun(conversationID, confirmingServerChange: confirmation),
              var conversation = self.conversation(conversationID),
              let index = conversation.messages.firstIndex(where: { $0.id == userMessageID }),
              conversation.messages[index].role == .user else { return false }
        conversation.messages[index].text = text
        conversation.messages.removeSubrange((index + 1)...)
        updateConversationSilently(conversation)
        startGeneration(text: nil, attachments: [], conversation: conversation)
        return true
    }

    private func canRerun(_ conversationID: UUID, confirmingServerChange confirmation: ChatServerChange?) -> Bool {
        generationTasks[conversationID] == nil
            && generationBlocker(for: conversationID) == nil
            && isServerChangeAllowed(for: conversationID, confirming: confirmation)
    }

    public func deleteMessage(_ id: UUID, in conversationID: UUID) {
        guard var conversation = self.conversation(conversationID) else { return }
        // A legacy reply might not have a parent ID yet. Removing its question
        // must not make an earlier, unrelated question eligible for continuation,
        // and must also clear derived prompt/query copies of the deleted question.
        if let index = conversation.messages.firstIndex(where: { $0.id == id && $0.role == .user }),
           index + 1 < conversation.messages.count, conversation.messages[index + 1].role == .assistant {
            conversation.messages[index + 1].replyToID = id
            conversation.messages[index + 1].expandedPrompt = nil
            conversation.messages[index + 1].searchQuery = nil
        }
        for messageIndex in conversation.messages.indices where conversation.messages[messageIndex].replyToID == id {
            conversation.messages[messageIndex].expandedPrompt = nil
            conversation.messages[messageIndex].searchQuery = nil
        }
        conversation.messages.removeAll { $0.id == id }
        updateConversationSilently(conversation)
    }

    /// `text` nil means the triggering user message is already the last
    /// message (regenerate / editAndResend); otherwise it is appended.
    private func performSend(text: String?, attachments: [ChatImageAttachment],
                             conversation snapshot: ChatConversation, revision: UInt64, attemptID: UUID) async {
        let conversationID = snapshot.id
        // A cancelled or superseded task must not change the next connection's state.
        guard isCurrent(revision), conversationIndex(for: conversationID) != nil else { return }
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
        assistant.searchQuery = conversation.isWebSearchEnabled ? strippedText : nil
        let assistantID = assistant.id
        conversation.messages.append(assistant)
        conversation.updatedAt = Date()
        applyConversation(conversation)
        persist(conversation)

        // Instructions + history: prior complete/stopped messages only —
        // exclude the placeholder and the triggering user message (sent as `prompt`).
        let instructions = ChatPromptBuilder.instructions(
            settings: settings, memories: effectiveMemoriesForPrompt, conversation: conversation)
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
                                          assistantID: assistantID, in: conversationID,
                                          revision: revision, attemptID: attemptID)

        // If the conversation was deleted or superseded during search, exit without re-persisting it.
        guard generationTasks[conversationID]?.id == attemptID else { return }
        // Cancelled during the search step: end per stop reason, no engine call.
        if !isCurrent(revision) {
            finishAborted(assistantID: assistantID, in: conversationID)
            if let updated = self.conversation(conversationID) {
                syncSummary(for: updated, reorder: false)
                await persist(updated).value
            }
            return
        }

        // Re-verify model availability after async search completes.
        guard isAvailableModel(modelID) else {
            mutateAssistant(assistantID, in: conversationID) {
                $0.status = .failed
                $0.failure = .missingModel
            }
            if let updated = self.conversation(conversationID) {
                syncSummary(for: updated, reorder: false)
                await persist(updated).value
            }
            return
        }

        let prompt = sources.isEmpty
            ? modelPrompt
            : ChatPromptBuilder.searchInjectedPrompt(modelPrompt, sources: sources)
        let modelOwnedBy = models.first(where: { $0.id == modelID })?.ownedBy
        let request = ChatEngineRequest(
            baseURL: baseURL,
            apiKey: apiKey,
            modelID: modelID,
            modelOwnedBy: modelOwnedBy,
            instructions: instructions,
            history: history,
            prompt: prompt,
            images: userMessage.attachments,
            reasoningEffort: conversation.reasoningEffort)

        let succeeded = await consume(request, in: conversationID, assistant: assistant,
                                      revision: revision, attemptID: attemptID,
                                      isContinuation: false, attemptAlreadyAppended: false,
                                      sentReplyExcerpt: nil)
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
                               in conversationID: UUID, revision: UInt64,
                               attemptID: UUID) async -> [ChatSearchSource] {
        var sources: [ChatSearchSource] = []
        var searchKey: (provider: ChatSearchProvider, key: String)?
        if enabled, let provider = settings.searchProvider {
            do {
                let loaded = try await secrets.loadSecret(account: ChatSecrets.searchKeyAccount(for: provider))
                guard isCurrent(revision), generationTasks[conversationID]?.id == attemptID else { return [] }
                if let loaded, !loaded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    searchKey = (provider, loaded)
                } else {
                    // Web search is on but cannot run: say so on the reply instead of answering silently without it.
                    mutateAssistant(assistantID, in: conversationID) { $0.failure = .searchNotConfigured }
                }
            } catch {
                guard isCurrent(revision), generationTasks[conversationID]?.id == attemptID else { return [] }
                // Keychain lookup failed: report search failure instead of claiming the key is unconfigured.
                mutateAssistant(assistantID, in: conversationID) { $0.failure = .searchFailed }
            }
        } else if enabled, isCurrent(revision), generationTasks[conversationID]?.id == attemptID {
            // Web search is on but cannot run: say so on the reply instead of answering silently without it.
            mutateAssistant(assistantID, in: conversationID) { $0.failure = .searchNotConfigured }
        }
        if let provider = searchKey?.provider, let key = searchKey?.key {
            guard isCurrent(revision), generationTasks[conversationID]?.id == attemptID else { return [] }
            do {
                let fetched = try await searchClient(provider).search(query, apiKey: key)
                guard isCurrent(revision), generationTasks[conversationID]?.id == attemptID else { return [] }
                sources = fetched
                mutateAssistant(assistantID, in: conversationID) {
                    $0.searchCompleted = true
                    if !sources.isEmpty {
                        $0.searchSources = sources
                    }
                }
            } catch {
                guard isCurrent(revision), generationTasks[conversationID]?.id == attemptID else { return [] }
                mutateAssistant(assistantID, in: conversationID) {
                    $0.failure = .searchFailed
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
                         revision: UInt64, attemptID: UUID, isContinuation: Bool,
                         attemptAlreadyAppended: Bool, sentReplyExcerpt: String?) async -> Bool {
        let assistantID = assistant.id
        var boundary = ChatContinuationBoundary(base: assistant.text, sentExcerpt: sentReplyExcerpt)
        let previousUsage = assistant.usage ?? ChatTokenUsage()
        if !attemptAlreadyAppended {
            mutateAssistant(assistantID, in: conversationID) {
                $0.attempts?.append(ChatReplyAttempt(modelID: request.modelID, status: .streaming))
            }
            if let current = conversation(conversationID) { persist(current) }
        }
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
                        syncSummary(for: current, reorder: false)
                        persist(current)
                    }
                case .usage(let usage):
                    mutateAssistant(assistantID, in: conversationID) {
                        if let last = $0.attempts?.indices.last { $0.attempts?[last].usage = usage }
                        $0.usage = ChatTokenUsage(inputTokens: previousUsage.inputTokens + usage.inputTokens,
                                                  outputTokens: previousUsage.outputTokens + usage.outputTokens,
                                                  reasoningTokens: previousUsage.reasoningTokens + usage.reasoningTokens)
                    }
                case .reasoningResolution(let resolution):
                    mutateAssistant(assistantID, in: conversationID) {
                        $0.reasoningResolution = resolution.outcome == .applied ? nil : resolution
                    }
                }
            }
            // A cancelled consumer may see the stream end normally.
            try Task.checkCancellation()
            let addedAnswerText = self.conversation(conversationID)?.messages
                .last(where: { $0.id == assistantID })
                .map { $0.text != assistant.text || !($0.pendingContinuation ?? "").isEmpty } ?? false
            if isContinuation, !addedAnswerText {
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

        mutateAssistant(assistantID, in: conversationID) { $0.finishAttempt(commitPending: succeeded) }
        // Await the final write so an interrupted reply is on disk before iOS
        // can suspend the app when endTask runs.
        if let updated = self.conversation(conversationID) {
            syncSummary(for: updated, reorder: false)
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

    private func mutateAssistant(_ id: UUID, in conversationID: UUID,
                                 _ mutate: (inout ChatMessage) -> Void) {
        guard let cIndex = conversationIndex(for: conversationID) else { return }
        let messages = conversations[cIndex].messages
        if let lastIndex = messages.indices.last, messages[lastIndex].id == id {
            mutate(&conversations[cIndex].messages[lastIndex])
            return
        }
        guard let mIndex = messages.firstIndex(where: { $0.id == id }) else { return }
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
                modelOwnedBy: request.modelOwnedBy,
                prompt: "用不超过 12 个字概括以下对话的主题，只输出标题：\n\(userText)\n\(String(reply.prefix(500)))",
                reasoningEffort: .automatic)
            guard let raw = try? await engine.complete(titleRequest), isCurrent(revision) else { return }
            var title = raw.trimmingCharacters(in: Self.titleTrimming)
            title = String(title.prefix(30))
            guard !title.isEmpty else { return }
            if let index = self.conversationIndex(for: conversationID),
               self.conversations[index].title == replacing {
                self.conversations[index].title = title
                self.syncSummary(for: self.conversations[index], reorder: false)
                self.persist(self.conversations[index])
            }
        }
    }

    private static let titleTrimming: CharacterSet = {
        var set = CharacterSet.whitespacesAndNewlines
        set.insert(charactersIn: "\"'“”‘’「」『』")
        return set
    }()

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
}
