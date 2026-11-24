import Foundation

/// JSON-file persistence for the chat workspace. `nil` from a load means the
/// data has never been written (first run), distinct from an empty collection.
public protocol ChatPersistence: Sendable {
    func loadConversations() async throws -> [ChatConversation]
    func saveConversation(_ conversation: ChatConversation) async throws
    func removeConversation(_ id: UUID) async throws
    func removeAllConversations() async throws
    func loadSettings() async throws -> ChatSettings?
    func saveSettings(_ settings: ChatSettings) async throws
    func loadMemories() async throws -> [ChatMemoryItem]?
    func saveMemories(_ items: [ChatMemoryItem]) async throws
    func loadSkills() async throws -> [ChatSkill]?
    func saveSkills(_ skills: [ChatSkill]) async throws
}

public enum ChatPersistenceError: Error, Sendable {
    case invalidData
    case storageFailure
}

/// One JSON file per conversation under `Conversations/`, plus `settings.json`,
/// `memories.json` and `skills.json`. Writes are atomic; where the platform
/// supports it the directory is file-protected and excluded from backup.
public actor ChatFilePersistence: ChatPersistence {
    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var directoriesPrepared = false

    public static let `default` = ChatFilePersistence(directory: defaultDirectory())

    public init(directory: URL) {
        self.directory = directory
    }

    private var conversationsDirectory: URL {
        directory.appendingPathComponent("Conversations", isDirectory: true)
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CPAQuotaChat", isDirectory: true)
    }

    private func prepareDirectories() throws {
        guard !directoriesPrepared else { return }
        let manager = FileManager.default
        try manager.createDirectory(at: conversationsDirectory, withIntermediateDirectories: true)
        #if canImport(Darwin)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                  ofItemAtPath: directory.path)
        var directoryURL = directory
        try directoryURL.setResourceValues(values)
        #endif
        directoriesPrepared = true
    }

    private func write(_ value: some Encodable, to url: URL) throws {
        let data: Data
        do { data = try encoder.encode(value) }
        catch { throw ChatPersistenceError.invalidData }
        do { try data.write(to: url, options: .atomic) }
        catch {
            directoriesPrepared = false
            throw ChatPersistenceError.storageFailure
        }
    }

    private func read<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw ChatPersistenceError.storageFailure }
        do { return try decoder.decode(type, from: data) }
        catch { throw ChatPersistenceError.invalidData }
    }

    public func loadConversations() async throws -> [ChatConversation] {
        try prepareDirectories()
        let manager = FileManager.default
        let files: [URL]
        do {
            files = try manager.contentsOfDirectory(
                at: conversationsDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
        } catch {
            directoriesPrepared = false
            throw ChatPersistenceError.storageFailure
        }
        var conversations: [ChatConversation] = []
        for file in files where file.pathExtension == "json" {
            do {
                conversations.append(try decoder.decode(
                    ChatConversation.self, from: Data(contentsOf: file)))
            } catch {
                // A corrupt conversation file must not take down the rest.
                continue
            }
        }
        return conversations
    }

    public func saveConversation(_ conversation: ChatConversation) async throws {
        try prepareDirectories()
        try write(conversation, to: conversationsDirectory
            .appendingPathComponent("\(conversation.id.uuidString).json"))
    }

    public func removeConversation(_ id: UUID) async throws {
        let url = conversationsDirectory.appendingPathComponent("\(id.uuidString).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do { try FileManager.default.removeItem(at: url) }
        catch { throw ChatPersistenceError.storageFailure }
    }

    /// Attempts every file, then throws if any record could not be removed so
    /// the caller never reports a deletion that did not happen.
    public func removeAllConversations() async throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: conversationsDirectory.path, isDirectory: &isDirectory) else { return }
        guard isDirectory.boolValue else { throw ChatPersistenceError.storageFailure }
        let files: [URL]
        do {
            files = try manager.contentsOfDirectory(at: conversationsDirectory, includingPropertiesForKeys: nil)
        } catch { throw ChatPersistenceError.storageFailure }
        var failed = false
        for file in files {
            do { try manager.removeItem(at: file) } catch { failed = true }
        }
        if failed { throw ChatPersistenceError.storageFailure }
    }

    public func loadSettings() async throws -> ChatSettings? {
        try prepareDirectories()
        return try read(ChatSettings.self, from: directory.appendingPathComponent("settings.json"))
    }

    public func saveSettings(_ settings: ChatSettings) async throws {
        try prepareDirectories()
        try write(settings, to: directory.appendingPathComponent("settings.json"))
    }

    public func loadMemories() async throws -> [ChatMemoryItem]? {
        try prepareDirectories()
        return try read([ChatMemoryItem].self, from: directory.appendingPathComponent("memories.json"))
    }

    public func saveMemories(_ items: [ChatMemoryItem]) async throws {
        try prepareDirectories()
        try write(items, to: directory.appendingPathComponent("memories.json"))
    }

    public func loadSkills() async throws -> [ChatSkill]? {
        try prepareDirectories()
        return try read([ChatSkill].self, from: directory.appendingPathComponent("skills.json"))
    }

    public func saveSkills(_ skills: [ChatSkill]) async throws {
        try prepareDirectories()
        try write(skills, to: directory.appendingPathComponent("skills.json"))
    }
}

/// In-memory persistence for tests and the UI-test host.
public actor ChatMemoryPersistence: ChatPersistence {
    private var conversations: [UUID: ChatConversation] = [:]
    private var settings: ChatSettings?
    private var memories: [ChatMemoryItem]?
    private var skills: [ChatSkill]?

    public init() {}

    public func loadConversations() async throws -> [ChatConversation] {
        conversations.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func saveConversation(_ conversation: ChatConversation) async throws {
        conversations[conversation.id] = conversation
    }

    public func removeConversation(_ id: UUID) async throws {
        conversations.removeValue(forKey: id)
    }

    public func removeAllConversations() async throws {
        conversations.removeAll()
    }

    public func loadSettings() async throws -> ChatSettings? { settings }
    public func saveSettings(_ settings: ChatSettings) async throws { self.settings = settings }
    public func loadMemories() async throws -> [ChatMemoryItem]? { memories }
    public func saveMemories(_ items: [ChatMemoryItem]) async throws { memories = items }
    public func loadSkills() async throws -> [ChatSkill]? { skills }
    public func saveSkills(_ skills: [ChatSkill]) async throws { self.skills = skills }
}
