import Foundation

/// JSON-file persistence for the chat workspace. `nil` from a load means the
/// data has never been written (first run), distinct from an empty collection.
public protocol ChatPersistence: Sendable {
    /// `true` when the store maintains a lightweight summary index and supports
    /// loading individual conversations on demand without full-store decoding.
    var supportsIndexedLoading: Bool { get }
    func loadConversations() async throws -> [ChatConversation]
    func loadConversationSummaries() async throws -> [ChatConversationSummary]
    func loadConversation(_ id: UUID) async throws -> ChatConversation?
    func searchConversationIDs(matching query: String) async throws -> Set<UUID>
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

public extension ChatPersistence {
    var supportsIndexedLoading: Bool { false }

    func loadConversationSummaries() async throws -> [ChatConversationSummary] {
        try await loadConversations().map(ChatConversationSummary.init(from:))
    }

    func loadConversation(_ id: UUID) async throws -> ChatConversation? {
        try await loadConversations().first(where: { $0.id == id })
    }

    func searchConversationIDs(matching query: String) async throws -> Set<UUID> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let conversations = try await loadConversations()
        var matches = Set<UUID>()
        for conversation in conversations {
            if conversation.title.localizedCaseInsensitiveContains(trimmed)
                || conversation.messages.contains(where: { $0.text.localizedCaseInsensitiveContains(trimmed) }) {
                matches.insert(conversation.id)
            }
        }
        return matches
    }
}

public enum ChatPersistenceError: Error, Sendable {
    case invalidData
    case storageFailure
}

/// One JSON file per conversation under `Conversations/`, externalized image
/// binaries under `Attachments/`, a reconciled summary index at
/// `Conversations/index.json`, plus `settings.json`, `memories.json` and
/// `skills.json`. Writes are atomic; where the platform supports it the
/// directory is file-protected and excluded from backup.
public actor ChatFilePersistence: ChatPersistence {
    private static let indexFileName = "index.json"
    private static let indexVersion = 1

    private struct FileStamp: Codable, Equatable {
        let size: Int
        let modifiedMillis: Int64
    }

    private struct ConversationIndexEntry: Codable, Equatable {
        var summary: ChatConversationSummary
        var attachmentFileNames: [String]
        var fileStamp: FileStamp?
    }

    private struct ConversationIndexFile: Codable {
        var version: Int
        var entries: [String: ConversationIndexEntry]
    }

    /// Minimal projection decoded when rebuilding `index.json` or searching
    /// conversation text without touching external image binaries.
    private struct LightweightConversationRecord: Decodable {
        struct Message: Decodable {
            struct AttachmentRef: Decodable {
                let fileName: String?
            }
            let text: String
            let status: ChatMessage.Status
            let attachments: [AttachmentRef]?
        }

        let id: UUID
        let title: String
        let modelID: String?
        let serverIdentifier: String?
        let createdAt: Date
        let updatedAt: Date
        let messages: [Message]

        var summary: ChatConversationSummary {
            let preview = messages.last(where: { !$0.text.isEmpty })
                .map { String($0.text.replacingOccurrences(of: "\n", with: " ").prefix(80)) } ?? ""
            return ChatConversationSummary(
                id: id,
                title: title,
                modelID: modelID,
                serverIdentifier: serverIdentifier,
                createdAt: createdAt,
                updatedAt: updatedAt,
                messageCount: messages.count,
                previewText: preview,
                hasStreamingMessage: messages.contains { $0.status == .streaming }
            )
        }

        var externalAttachmentFileNames: [String] {
            var seen = Set<String>()
            var names: [String] = []
            for message in messages {
                for ref in message.attachments ?? [] {
                    if let fileName = ref.fileName,
                       ChatAttachmentCoding.isSafeFileName(fileName),
                       seen.insert(fileName).inserted {
                        names.append(fileName)
                    }
                }
            }
            return names
        }
    }

    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var directoriesPrepared = false
    private var cachedIndex: [UUID: ConversationIndexEntry]?
    private var persistedAttachmentHashes: [String: UInt64] = [:]

    public static let `default` = ChatFilePersistence(directory: defaultDirectory())

    public nonisolated var supportsIndexedLoading: Bool { true }

    public init(directory: URL) {
        self.directory = directory
    }

    private var conversationsDirectory: URL {
        directory.appendingPathComponent("Conversations", isDirectory: true)
    }

    private var attachmentsDirectory: URL {
        directory.appendingPathComponent("Attachments", isDirectory: true)
    }

    private var indexURL: URL {
        conversationsDirectory.appendingPathComponent(Self.indexFileName, isDirectory: false)
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
        try manager.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
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

    private func invalidateDirectoryCache() {
        directoriesPrepared = false
        cachedIndex = nil
        persistedAttachmentHashes.removeAll()
    }

    private func write(_ value: some Encodable, to url: URL) throws {
        let data: Data
        do { data = try encoder.encode(value) }
        catch { throw ChatPersistenceError.invalidData }
        do { try data.write(to: url, options: .atomic) }
        catch {
            invalidateDirectoryCache()
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

    private func conversationURL(for id: UUID) -> URL {
        conversationsDirectory.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    private func decodeConversation(from url: URL) throws -> ChatConversation {
        let data = try Data(contentsOf: url)
        decoder.userInfo[ChatAttachmentCoding.attachmentsDirectoryKey] = attachmentsDirectory
        defer { decoder.userInfo.removeValue(forKey: ChatAttachmentCoding.attachmentsDirectoryKey) }
        return try decoder.decode(ChatConversation.self, from: data)
    }

    private func listConversationFiles() throws -> [(id: UUID, url: URL, stamp: FileStamp?)] {
        let manager = FileManager.default
        let files: [URL]
        do {
            files = try manager.contentsOfDirectory(
                at: conversationsDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles])
        } catch {
            invalidateDirectoryCache()
            throw ChatPersistenceError.storageFailure
        }
        var result: [(id: UUID, url: URL, stamp: FileStamp?)] = []
        for file in files where file.pathExtension == "json" && file.lastPathComponent != Self.indexFileName {
            let stem = file.deletingPathExtension().lastPathComponent
            guard let id = UUID(uuidString: stem) else { continue }
            result.append((id, file, Self.fileStamp(for: file)))
        }
        return result
    }

    private static func fileStamp(for url: URL) -> FileStamp? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize,
              let date = values.contentModificationDate else {
            return nil
        }
        let millis = Int64((date.timeIntervalSince1970 * 1000).rounded())
        return FileStamp(size: size, modifiedMillis: millis)
    }

    private func loadRawIndexFromDisk() -> [UUID: ConversationIndexEntry]? {
        guard FileManager.default.fileExists(atPath: indexURL.path),
              let data = try? Data(contentsOf: indexURL),
              let file = try? decoder.decode(ConversationIndexFile.self, from: data),
              file.version == Self.indexVersion else {
            return nil
        }
        var entries: [UUID: ConversationIndexEntry] = [:]
        entries.reserveCapacity(file.entries.count)
        for (key, value) in file.entries {
            if let id = UUID(uuidString: key) {
                entries[id] = value
            }
        }
        return entries
    }

    private func persistIndex(_ entries: [UUID: ConversationIndexEntry]) {
        var keyed: [String: ConversationIndexEntry] = [:]
        keyed.reserveCapacity(entries.count)
        for (id, entry) in entries {
            keyed[id.uuidString] = entry
        }
        let payload = ConversationIndexFile(version: Self.indexVersion, entries: keyed)
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// Reconciles `index.json` with the files currently on disk. Unchanged files
    /// are served straight from the index without opening their JSON or images.
    private func reconciledIndex() throws -> [UUID: ConversationIndexEntry] {
        let diskFiles = try listConversationFiles()
        let hadIndexOnDisk = cachedIndex != nil || FileManager.default.fileExists(atPath: indexURL.path)
        var entries = cachedIndex ?? loadRawIndexFromDisk() ?? [:]
        var changed = !hadIndexOnDisk && !diskFiles.isEmpty

        var diskIDs = Set<UUID>()
        diskIDs.reserveCapacity(diskFiles.count)

        for item in diskFiles {
            diskIDs.insert(item.id)
            if let existing = entries[item.id],
               let existingStamp = existing.fileStamp,
               let diskStamp = item.stamp,
               existingStamp == diskStamp {
                continue
            }
            // Missing or externally updated file: decode only lightweight text/metadata.
            do {
                let data = try Data(contentsOf: item.url)
                let record = try decoder.decode(LightweightConversationRecord.self, from: data)
                entries[item.id] = ConversationIndexEntry(
                    summary: record.summary,
                    attachmentFileNames: record.externalAttachmentFileNames,
                    fileStamp: item.stamp
                )
                changed = true
            } catch {
                // A corrupt conversation file must not take down the rest.
                if entries.removeValue(forKey: item.id) != nil {
                    changed = true
                }
            }
        }

        let staleIDs = entries.keys.filter { !diskIDs.contains($0) }
        for staleID in staleIDs {
            entries.removeValue(forKey: staleID)
            changed = true
        }

        cachedIndex = entries
        if changed {
            persistIndex(entries)
        }
        return entries
    }

    private func cleanupOrphanedAttachments(candidates: [String], activeIndex: [UUID: ConversationIndexEntry]) {
        guard !candidates.isEmpty else { return }
        var referenced = Set<String>()
        for entry in activeIndex.values {
            for name in entry.attachmentFileNames {
                referenced.insert(name)
            }
        }
        let manager = FileManager.default
        for fileName in candidates where ChatAttachmentCoding.isSafeFileName(fileName) && !referenced.contains(fileName) {
            let url = attachmentsDirectory.appendingPathComponent(fileName, isDirectory: false)
            if manager.fileExists(atPath: url.path) {
                try? manager.removeItem(at: url)
            }
            persistedAttachmentHashes.removeValue(forKey: fileName)
        }
    }

    private static func attachmentFileName(for attachment: ChatImageAttachment) -> String {
        let ext: String
        switch attachment.mimeType.lowercased() {
        case "image/jpeg", "image/jpg": ext = "jpg"
        case "image/png": ext = "png"
        case "image/webp": ext = "webp"
        case "image/heic": ext = "heic"
        case "image/gif": ext = "gif"
        default: ext = "bin"
        }
        return "\(attachment.id.uuidString).\(ext)"
    }

    private static func fnv1a64(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }

    // MARK: - Conversations

    public func loadConversationSummaries() async throws -> [ChatConversationSummary] {
        try prepareDirectories()
        let entries = try reconciledIndex()
        return entries.values
            .map(\.summary)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func loadConversation(_ id: UUID) async throws -> ChatConversation? {
        try prepareDirectories()
        let url = conversationURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try decodeConversation(from: url)
        } catch {
            throw ChatPersistenceError.invalidData
        }
    }

    public func searchConversationIDs(matching query: String) async throws -> Set<UUID> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        try prepareDirectories()
        let files = try listConversationFiles()
        var matches = Set<UUID>()
        for item in files {
            guard let data = try? Data(contentsOf: item.url),
                  let record = try? decoder.decode(LightweightConversationRecord.self, from: data) else {
                continue
            }
            if record.title.localizedCaseInsensitiveContains(trimmed)
                || record.messages.contains(where: { $0.text.localizedCaseInsensitiveContains(trimmed) }) {
                matches.insert(record.id)
            }
        }
        return matches
    }

    public func loadConversations() async throws -> [ChatConversation] {
        try prepareDirectories()
        let files = try listConversationFiles()
        var conversations: [ChatConversation] = []
        for item in files {
            do {
                conversations.append(try decodeConversation(from: item.url))
            } catch {
                // A corrupt conversation file must not take down the rest.
                continue
            }
        }
        return conversations
    }

    public func saveConversation(_ conversation: ChatConversation) async throws {
        try prepareDirectories()

        // Ensure external attachment binaries are persisted atomically before the
        // conversation JSON references them.
        var externalFileMap: [UUID: String] = [:]
        var newAttachmentFiles: [String] = []
        var seenFileNames = Set<String>()
        let manager = FileManager.default

        for message in conversation.messages {
            for attachment in message.attachments {
                let fileName = Self.attachmentFileName(for: attachment)
                externalFileMap[attachment.id] = fileName
                if seenFileNames.insert(fileName).inserted {
                    newAttachmentFiles.append(fileName)
                    let fileURL = attachmentsDirectory.appendingPathComponent(fileName, isDirectory: false)
                    let contentHash = Self.fnv1a64(attachment.data)
                    if persistedAttachmentHashes[fileName] == contentHash,
                       manager.fileExists(atPath: fileURL.path) {
                        continue
                    }
                    do {
                        try attachment.data.write(to: fileURL, options: .atomic)
                        persistedAttachmentHashes[fileName] = contentHash
                    } catch {
                        invalidateDirectoryCache()
                        throw ChatPersistenceError.storageFailure
                    }
                }
            }
        }

        var entries = (try? reconciledIndex()) ?? (cachedIndex ?? [:])
        let previousAttachments = entries[conversation.id]?.attachmentFileNames ?? []

        let targetURL = conversationURL(for: conversation.id)
        encoder.userInfo[ChatAttachmentCoding.externalFileNamesKey] = externalFileMap
        defer { encoder.userInfo.removeValue(forKey: ChatAttachmentCoding.externalFileNamesKey) }
        try write(conversation, to: targetURL)

        let updatedEntry = ConversationIndexEntry(
            summary: ChatConversationSummary(from: conversation),
            attachmentFileNames: newAttachmentFiles,
            fileStamp: Self.fileStamp(for: targetURL)
        )
        entries[conversation.id] = updatedEntry
        cachedIndex = entries
        persistIndex(entries)

        let removedCandidates = previousAttachments.filter { !seenFileNames.contains($0) }
        cleanupOrphanedAttachments(candidates: removedCandidates, activeIndex: entries)
    }

    public func removeConversation(_ id: UUID) async throws {
        let url = conversationURL(for: id)
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else {
            if var entries = cachedIndex, entries.removeValue(forKey: id) != nil {
                cachedIndex = entries
                persistIndex(entries)
            }
            return
        }

        var entries = (try? reconciledIndex()) ?? (cachedIndex ?? [:])
        var attachmentCandidates = entries[id]?.attachmentFileNames ?? []
        if attachmentCandidates.isEmpty,
           let data = try? Data(contentsOf: url),
           let record = try? decoder.decode(LightweightConversationRecord.self, from: data) {
            attachmentCandidates = record.externalAttachmentFileNames
        }

        do { try manager.removeItem(at: url) }
        catch { throw ChatPersistenceError.storageFailure }

        entries.removeValue(forKey: id)
        cachedIndex = entries
        persistIndex(entries)
        cleanupOrphanedAttachments(candidates: attachmentCandidates, activeIndex: entries)
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
        var attachmentsIsDir: ObjCBool = false
        if manager.fileExists(atPath: attachmentsDirectory.path, isDirectory: &attachmentsIsDir),
           attachmentsIsDir.boolValue,
           let attachmentFiles = try? manager.contentsOfDirectory(at: attachmentsDirectory, includingPropertiesForKeys: nil) {
            for file in attachmentFiles {
                do { try manager.removeItem(at: file) } catch { failed = true }
            }
        }
        cachedIndex = nil
        persistedAttachmentHashes.removeAll()
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

    public func loadConversationSummaries() async throws -> [ChatConversationSummary] {
        conversations.values
            .sorted { $0.updatedAt > $1.updatedAt }
            .map(ChatConversationSummary.init(from:))
    }

    public func loadConversation(_ id: UUID) async throws -> ChatConversation? {
        conversations[id]
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
