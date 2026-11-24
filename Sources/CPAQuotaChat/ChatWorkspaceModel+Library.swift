import Foundation

extension ChatWorkspaceModel {
    static let defaultSkills: [ChatSkill] = [
        ChatSkill(command: "translate", title: "翻译",
                  prompt: "将以下内容翻译成中文；如果原文已是中文，则翻译成英文。只输出译文。"),
        ChatSkill(command: "summarize", title: "总结",
                  prompt: "用要点总结以下内容，保留关键数字与结论。"),
        ChatSkill(command: "polish", title: "润色",
                  prompt: "润色以下文字，使表达更清晰自然，保持原意与语言。"),
        ChatSkill(command: "explain", title: "解释代码",
                  prompt: "逐段解释以下代码的作用，并指出潜在问题。"),
    ]

    // MARK: - Memories

    @discardableResult
    public func retrySaveMemories() async -> Bool {
        await persistMemories(memories).value
    }

    public func addMemory(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        memories.append(ChatMemoryItem(text: trimmed))
        persistMemories(memories)
    }

    public func updateMemory(_ item: ChatMemoryItem) {
        guard let index = memories.firstIndex(where: { $0.id == item.id }) else { return }
        memories[index] = item
        persistMemories(memories)
    }

    public func deleteMemory(_ id: UUID) {
        memories.removeAll { $0.id == id }
        persistMemories(memories)
    }

    // MARK: - Skills

    @discardableResult
    public func retrySaveSkills() async -> Bool {
        await persistSkills(skills).value
    }

    public func hasConflictingSkillCommand(_ command: String, excluding id: UUID?) -> Bool {
        let normalized = ChatPromptBuilder.normalizedCommand(command)
        guard !normalized.isEmpty else { return false }
        return skills.contains {
            $0.id != id && ChatPromptBuilder.normalizedCommand($0.command) == normalized
        }
    }

    public func saveSkill(_ skill: ChatSkill) {
        var normalized = skill
        normalized.command = ChatPromptBuilder.normalizedCommand(skill.command)
        guard !normalized.command.isEmpty,
              !hasConflictingSkillCommand(normalized.command, excluding: skill.id) else { return }
        if let index = skills.firstIndex(where: { $0.id == skill.id }) {
            skills[index] = normalized
        } else {
            skills.append(normalized)
        }
        persistSkills(skills)
    }

    public func deleteSkill(_ id: UUID) {
        skills.removeAll { $0.id == id }
        persistSkills(skills)
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

    // MARK: - Search keys

    public func searchKeyStatus(for provider: ChatSearchProvider) async -> ChatSearchKeyStatus {
        do {
            guard let value = try await secrets.loadSecret(
                account: ChatSecrets.searchKeyAccount(for: provider)) else { return .absent }
            return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .absent : .present
        } catch {
            return .unknown
        }
    }

    public func hasSearchKey(for provider: ChatSearchProvider) async -> Bool {
        await searchKeyStatus(for: provider) == .present
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

    @discardableResult
    public func removeSearchKey(for provider: ChatSearchProvider) async -> Bool {
        do {
            try await secrets.removeSecret(account: ChatSecrets.searchKeyAccount(for: provider))
            return true
        } catch {
            return false
        }
    }

    // MARK: - Notifications

    public func requestNotificationAuthorization() async -> Bool {
        await backgroundRunner.requestNotificationAuthorization()
    }

    public func notificationAuthorizationStatus() async -> ChatNotificationAuthorization {
        await backgroundRunner.notificationAuthorizationStatus()
    }
}
