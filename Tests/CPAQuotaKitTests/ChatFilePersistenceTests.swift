import Foundation
import Testing
@testable import CPAQuotaChat
@testable import CPAQuotaKit

@Suite("ChatFilePersistence")
struct ChatFilePersistenceTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatFilePersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func conversationRoundTrips() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = ChatFilePersistence(directory: directory)

        var conversation = ChatConversation(title: "对话", modelID: "test-model")
        conversation.messages.append(ChatMessage(role: .user, text: "你好"))
        conversation.messages.append(ChatMessage(
            role: .assistant, text: "你好！", modelID: "test-model",
            usage: ChatTokenUsage(inputTokens: 5, outputTokens: 3, reasoningTokens: 1)))
        try await persistence.saveConversation(conversation)

        let loaded = try await persistence.loadConversations()
        #expect(loaded.count == 1)
        #expect(loaded.first == conversation)
    }

    @Test func settingsMemoriesSkillsRoundTrip() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = ChatFilePersistence(directory: directory)

        #expect(try await persistence.loadSettings() == nil)
        #expect(try await persistence.loadMemories() == nil)
        #expect(try await persistence.loadSkills() == nil)

        let settings = ChatSettings(globalInstructions: "规则", defaultModelID: "m",
                                    searchProvider: .tavily)
        try await persistence.saveSettings(settings)
        #expect(try await persistence.loadSettings() == settings)

        let memories = [ChatMemoryItem(text: "记住我", isPinned: true)]
        try await persistence.saveMemories(memories)
        #expect(try await persistence.loadMemories() == memories)

        let skills = [ChatSkill(command: "t", title: "T", prompt: "p")]
        try await persistence.saveSkills(skills)
        #expect(try await persistence.loadSkills() == skills)
    }

    @Test func removeAndRemoveAllConversations() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = ChatFilePersistence(directory: directory)

        let a = ChatConversation(title: "a")
        let b = ChatConversation(title: "b")
        try await persistence.saveConversation(a)
        try await persistence.saveConversation(b)
        try await persistence.removeConversation(a.id)
        #expect(try await persistence.loadConversations().map(\.id) == [b.id])

        try await persistence.removeAllConversations()
        #expect(try await persistence.loadConversations().isEmpty)
    }

    @Test func corruptConversationFileDoesNotTakeDownOthers() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = ChatFilePersistence(directory: directory)

        let good = ChatConversation(title: "good")
        try await persistence.saveConversation(good)
        let conversationsDir = directory.appendingPathComponent("Conversations")
        try Data("broken".utf8).write(to: conversationsDir.appendingPathComponent("\(UUID().uuidString).json"))

        let loaded = try await persistence.loadConversations()
        #expect(loaded.map(\.id) == [good.id])
    }
}
