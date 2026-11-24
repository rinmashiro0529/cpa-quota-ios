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

    @Test func removeAllConversationsReportsEnumerationFailure() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = ChatFilePersistence(directory: directory)
        // A regular file where the directory belongs makes enumeration fail.
        try Data("not a directory".utf8).write(to: directory.appendingPathComponent("Conversations"))

        await #expect(throws: ChatPersistenceError.self) {
            try await persistence.removeAllConversations()
        }
    }

    @Test func conversationWrittenBeforeServerBindingStillLoads() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = ChatFilePersistence(directory: directory)
        var conversation = ChatConversation(title: "旧对话", serverIdentifier: "https://cpa.example.com")
        conversation.messages.append(ChatMessage(role: .user, text: "你好"))
        var object = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(conversation)) as? [String: Any])
        #expect(object.removeValue(forKey: "serverIdentifier") != nil)
        let conversationsDir = directory.appendingPathComponent("Conversations")
        try FileManager.default.createDirectory(at: conversationsDir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object)
            .write(to: conversationsDir.appendingPathComponent("\(conversation.id.uuidString).json"))

        let loaded = try #require(try await persistence.loadConversations().first)
        #expect(loaded.id == conversation.id)
        #expect(loaded.serverIdentifier == nil)
        #expect(loaded.messages == conversation.messages)
    }

    @Test func repeatedSavesReusePreparedDirectoriesAndRecoverIfRemovedExternally() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = ChatFilePersistence(directory: directory)

        let first = ChatConversation(title: "一")
        let second = ChatConversation(title: "二")
        try await persistence.saveConversation(first)
        try await persistence.saveConversation(second)
        #expect(try await persistence.loadConversations().count == 2)

        // Removing the Conversations directory externally should cause one write failure
        // that invalidates the prepared-directory cache so the retry recreates it.
        let conversationsDir = directory.appendingPathComponent("Conversations")
        try FileManager.default.removeItem(at: conversationsDir)
        let third = ChatConversation(title: "三")
        do {
            try await persistence.saveConversation(third)
        } catch {
            try await persistence.saveConversation(third)
        }
        #expect(try await persistence.loadConversations().map(\.id) == [third.id])
    }

    @Test func externalizesImageAttachmentsAndOmitsInlineBase64FromConversationJSON() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = ChatFilePersistence(directory: directory)

        let payload = Data(repeating: 0xAB, count: 4096)
        let attachment = ChatImageAttachment(mimeType: "image/jpeg", data: payload)
        var conversation = ChatConversation(title: "图片对话", modelID: "test-model")
        conversation.messages.append(ChatMessage(role: .user, text: "看这张图", attachments: [attachment]))
        try await persistence.saveConversation(conversation)

        let attachmentURL = directory
            .appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent("\(attachment.id.uuidString).jpg")
        #expect(FileManager.default.fileExists(atPath: attachmentURL.path))
        #expect(try Data(contentsOf: attachmentURL) == payload)

        let jsonURL = directory
            .appendingPathComponent("Conversations", isDirectory: true)
            .appendingPathComponent("\(conversation.id.uuidString).json")
        let rawJSON = try String(contentsOf: jsonURL, encoding: .utf8)
        #expect(rawJSON.contains("\(attachment.id.uuidString).jpg"))
        #expect(rawJSON.count < 2000)

        let loadedSingle = try #require(try await persistence.loadConversation(conversation.id))
        #expect(loadedSingle == conversation)
        let loadedAll = try await persistence.loadConversations()
        #expect(loadedAll == [conversation])
    }

    @Test func legacyInlineAttachmentJSONLoadsAndMigratesToExternalFileOnNextSave() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = ChatFilePersistence(directory: directory)

        let payload = Data(repeating: 0x42, count: 2048)
        let attachment = ChatImageAttachment(mimeType: "image/png", data: payload)
        var conversation = ChatConversation(title: "旧版图片", modelID: "test-model")
        conversation.messages.append(ChatMessage(role: .user, text: "旧格式", attachments: [attachment]))

        // Plain JSONEncoder writes legacy inline base64 `data`.
        let conversationsDir = directory.appendingPathComponent("Conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: conversationsDir, withIntermediateDirectories: true)
        let jsonURL = conversationsDir.appendingPathComponent("\(conversation.id.uuidString).json")
        let legacyBytes = try JSONEncoder().encode(conversation)
        try legacyBytes.write(to: jsonURL, options: .atomic)
        #expect(legacyBytes.count > 2500)

        let summaries = try await persistence.loadConversationSummaries()
        #expect(summaries.map(\.id) == [conversation.id])
        let loaded = try #require(try await persistence.loadConversation(conversation.id))
        #expect(loaded == conversation)

        // Next save migrates inline data to `Attachments/<id>.png`.
        try await persistence.saveConversation(loaded)
        let attachmentURL = directory
            .appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent("\(attachment.id.uuidString).png")
        #expect(try Data(contentsOf: attachmentURL) == payload)
        let migratedBytes = try Data(contentsOf: jsonURL)
        #expect(migratedBytes.count < 1500)
    }

    @Test func orphanAttachmentFilesAreCleanedUpOnUpdateRemoveAndRemoveAll() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = ChatFilePersistence(directory: directory)

        let first = ChatImageAttachment(mimeType: "image/jpeg", data: Data([1, 2, 3, 4]))
        let second = ChatImageAttachment(mimeType: "image/png", data: Data([5, 6, 7, 8]))
        let attachmentsDir = directory.appendingPathComponent("Attachments", isDirectory: true)
        let firstURL = attachmentsDir.appendingPathComponent("\(first.id.uuidString).jpg")
        let secondURL = attachmentsDir.appendingPathComponent("\(second.id.uuidString).png")

        var conversation = ChatConversation(title: "附件清理")
        conversation.messages.append(ChatMessage(role: .user, text: "图一", attachments: [first]))
        conversation.messages.append(ChatMessage(role: .user, text: "图二", attachments: [second]))
        try await persistence.saveConversation(conversation)
        #expect(FileManager.default.fileExists(atPath: firstURL.path))
        #expect(FileManager.default.fileExists(atPath: secondURL.path))

        // Removing the first message must remove its now-unreferenced attachment file.
        conversation.messages.removeFirst()
        try await persistence.saveConversation(conversation)
        #expect(!FileManager.default.fileExists(atPath: firstURL.path))
        #expect(FileManager.default.fileExists(atPath: secondURL.path))

        // Removing the conversation must clean up its remaining attachment file.
        try await persistence.removeConversation(conversation.id)
        #expect(!FileManager.default.fileExists(atPath: secondURL.path))

        // removeAllConversations must clear both Conversations/ and Attachments/.
        let third = ChatImageAttachment(mimeType: "image/webp", data: Data([9, 10]))
        var another = ChatConversation(title: "批量清理")
        another.messages.append(ChatMessage(role: .user, text: "图三", attachments: [third]))
        try await persistence.saveConversation(another)
        let thirdURL = attachmentsDir.appendingPathComponent("\(third.id.uuidString).webp")
        #expect(FileManager.default.fileExists(atPath: thirdURL.path))

        try await persistence.removeAllConversations()
        #expect(!FileManager.default.fileExists(atPath: thirdURL.path))
        #expect(try await persistence.loadConversationSummaries().isEmpty)
    }

    @Test func summaryIndexRebuildsAfterCorruptionAndSearchesWithoutReadingAttachments() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = ChatFilePersistence(directory: directory)

        let attachment = ChatImageAttachment(mimeType: "image/jpeg", data: Data(repeating: 0xEE, count: 2048))
        var older = ChatConversation(title: "旧记录", updatedAt: Date(timeIntervalSince1970: 1000))
        older.messages.append(ChatMessage(role: .user, text: "包含特殊词：量子退火算法", attachments: [attachment]))
        var newer = ChatConversation(title: "新记录", updatedAt: Date(timeIntervalSince1970: 2000))
        newer.messages.append(ChatMessage(role: .user, text: "普通日常问答"))
        try await persistence.saveConversation(older)
        try await persistence.saveConversation(newer)

        // Corrupt index.json and delete the external image binary to prove neither
        // index rebuild nor full-text search touches Attachments/.
        let indexURL = directory
            .appendingPathComponent("Conversations", isDirectory: true)
            .appendingPathComponent("index.json")
        try Data("not-valid-json".utf8).write(to: indexURL, options: .atomic)
        let imageURL = directory
            .appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent("\(attachment.id.uuidString).jpg")
        try FileManager.default.removeItem(at: imageURL)

        let fresh = ChatFilePersistence(directory: directory)
        let summaries = try await fresh.loadConversationSummaries()
        #expect(summaries.map(\.id) == [newer.id, older.id])
        #expect(summaries.last?.previewText.contains("量子退火算法") == true)

        let matches = try await fresh.searchConversationIDs(matching: "量子退火")
        #expect(matches == [older.id])
    }

    @Test func maliciousPathTraversalAttachmentFileNameIsRejected() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = ChatFilePersistence(directory: directory)

        try await persistence.saveSettings(ChatSettings(globalInstructions: "TOP_SECRET_MARKER"))
        let conversationID = UUID()
        let attachmentID = UUID()
        let raw = """
        {
          "id": "\(conversationID.uuidString)",
          "title": "traversal",
          "systemPrompt": "",
          "reasoningEffort": "automatic",
          "isWebSearchEnabled": false,
          "messages": [{
            "id": "\(UUID().uuidString)",
            "role": "user",
            "text": "hi",
            "attachments": [{
              "id": "\(attachmentID.uuidString)",
              "mimeType": "image/jpeg",
              "fileName": "../settings.json"
            }],
            "searchSources": [],
            "status": "complete",
            "createdAt": 0
          }],
          "createdAt": 0,
          "updatedAt": 0
        }
        """
        let conversationsDir = directory.appendingPathComponent("Conversations", isDirectory: true)
        try Data(raw.utf8).write(
            to: conversationsDir.appendingPathComponent("\(conversationID.uuidString).json"),
            options: .atomic
        )

        // Because `fileName` fails safety validation and no inline `data` exists, decode fails
        // instead of reading `../settings.json`.
        await #expect(throws: ChatPersistenceError.self) {
            _ = try await persistence.loadConversation(conversationID)
        }
    }
}
