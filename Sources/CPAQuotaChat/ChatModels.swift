import Foundation
import CPAQuotaKit

enum ChatAttachmentCoding {
    /// Maps attachment UUID -> external file name under `Attachments/`.
    /// When present in `JSONEncoder.userInfo`, attachments serialize as external
    /// file references instead of inline base64 data.
    static let externalFileNamesKey = CodingUserInfoKey(
        rawValue: "icu.nahida.cpaquota.chat.attachmentExternalFileNames")!
    /// Base `Attachments/` directory URL for resolving externalized attachment files.
    static let attachmentsDirectoryKey = CodingUserInfoKey(
        rawValue: "icu.nahida.cpaquota.chat.attachmentsDirectory")!

    static func isSafeFileName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\") else { return false }
        return URL(fileURLWithPath: name).lastPathComponent == name
    }
}

public struct ChatImageAttachment: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let mimeType: String
    public let data: Data

    public init(id: UUID = UUID(), mimeType: String, data: Data) {
        self.id = id
        self.mimeType = mimeType
        self.data = data
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case mimeType
        case data
        case fileName
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        mimeType = try container.decode(String.self, forKey: .mimeType)
        if let fileName = try container.decodeIfPresent(String.self, forKey: .fileName),
           ChatAttachmentCoding.isSafeFileName(fileName),
           let directory = decoder.userInfo[ChatAttachmentCoding.attachmentsDirectoryKey] as? URL {
            let fileURL = directory.appendingPathComponent(fileName, isDirectory: false)
            if let externalData = try? Data(contentsOf: fileURL) {
                data = externalData
            } else {
                data = try container.decodeIfPresent(Data.self, forKey: .data) ?? Data()
            }
        } else {
            data = try container.decode(Data.self, forKey: .data)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(mimeType, forKey: .mimeType)
        if let fileMap = encoder.userInfo[ChatAttachmentCoding.externalFileNamesKey] as? [UUID: String],
           let fileName = fileMap[id],
           ChatAttachmentCoding.isSafeFileName(fileName) {
            try container.encode(fileName, forKey: .fileName)
        } else {
            try container.encode(data, forKey: .data)
        }
    }
}

public struct ChatTokenUsage: Codable, Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var reasoningTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, reasoningTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
    }
}

public struct ChatSearchSource: Identifiable, Codable, Equatable, Sendable {
    public var id: String { url.absoluteString }
    public let title: String
    public let url: URL
    public let snippet: String

    public init(title: String, url: URL, snippet: String) {
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

public enum ChatFailure: Equatable, Sendable, Codable {
    case missingAPIKey
    case missingModel
    case unauthorized(statusCode: Int)
    case forbidden(statusCode: Int)
    case modelUnavailable(statusCode: Int)
    case rateLimited(retryAfter: Date?)
    case upstream(statusCode: Int)
    case network
    case timeout
    case invalidResponse
    case connectionChanged
    case streamInterrupted
    case continuationAddedNothing
    case searchFailed
    /// Web search was on but no search service or key was usable; the reply was generated without it.
    case searchNotConfigured
    case interruptedInBackground
    /// The app ended while a reply was streaming (found on the next launch).
    case generationInterrupted
}

public struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    public enum Status: String, Codable, Sendable {
        case complete
        case streaming
        case stopped
        case interrupted
        case failed
    }

    public let id: UUID
    public var role: Role
    public var text: String
    public var reasoning: String?
    public var attachments: [ChatImageAttachment]
    public var modelID: String?
    public var usage: ChatTokenUsage?
    /// Optional for conversations saved before continuation was introduced.
    public internal(set) var replyToID: UUID?
    public internal(set) var attempts: [ChatReplyAttempt]?
    /// Undecided opening bytes of a continuation, retained across process death.
    var pendingContinuation: String?
    /// Preserve the original expansion when a slash skill changes later.
    var expandedPrompt: String?
    /// Records whether web search finished for this turn (distinguishes zero results from an aborted search).
    var searchCompleted: Bool?
    /// Preserves the resolved web-search query so skill edits cannot alter a retried search boundary.
    var searchQuery: String?
    public var searchSources: [ChatSearchSource]
    public var status: Status
    public var failure: ChatFailure?
    public let createdAt: Date
    /// On a reply: how many earlier messages were left out of its request to
    /// stay within the history budget. `nil` when nothing was left out.
    public var omittedHistoryCount: Int?
    /// Non-nil when the requested reasoning effort was downgraded or omitted
    /// for compatibility with the target model or endpoint.
    public var reasoningResolution: ChatReasoningResolution?

    public init(
        id: UUID = UUID(), role: Role, text: String, reasoning: String? = nil,
        attachments: [ChatImageAttachment] = [], modelID: String? = nil, usage: ChatTokenUsage? = nil,
        searchSources: [ChatSearchSource] = [], status: Status = .complete, failure: ChatFailure? = nil,
        createdAt: Date = Date(), omittedHistoryCount: Int? = nil,
        reasoningResolution: ChatReasoningResolution? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.reasoning = reasoning
        self.attachments = attachments
        self.modelID = modelID
        self.usage = usage
        self.searchSources = searchSources
        self.status = status
        self.failure = failure
        self.createdAt = createdAt
        self.omittedHistoryCount = omittedHistoryCount
        self.reasoningResolution = reasoningResolution
    }
}

public enum ChatReasoningEffort: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic
    case off
    case low
    case medium
    case high
    case xhigh
    case max

    public var id: String { rawValue }

    /// Explicit discrete slider stops ordered from off to max.
    public static let explicitLevels: [ChatReasoningEffort] = [
        .off, .low, .medium, .high, .xhigh, .max
    ]
}

public struct ChatReasoningResolution: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Equatable, Sendable {
        case applied
        case downgraded
        case omitted
    }

    public let requested: ChatReasoningEffort
    public let applied: ChatReasoningEffort?
    public let outcome: Outcome
    public let usedFallbackProtocol: Bool

    public init(
        requested: ChatReasoningEffort,
        applied: ChatReasoningEffort?,
        outcome: Outcome,
        usedFallbackProtocol: Bool = false
    ) {
        self.requested = requested
        self.applied = applied
        self.outcome = outcome
        self.usedFallbackProtocol = usedFallbackProtocol
    }
}

public struct ChatConversation: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var modelID: String?
    public var systemPrompt: String
    public var reasoningEffort: ChatReasoningEffort
    public var isWebSearchEnabled: Bool
    public var messages: [ChatMessage]
    public let createdAt: Date
    public var updatedAt: Date
    /// `CPAServer.identifier` of the server this history was sent to. `nil`
    /// for records written before the field existed: their origin is unknown.
    public var serverIdentifier: String?

    public init(
        id: UUID = UUID(), title: String = "", modelID: String? = nil, systemPrompt: String = "",
        reasoningEffort: ChatReasoningEffort = .automatic, isWebSearchEnabled: Bool = false,
        messages: [ChatMessage] = [], createdAt: Date = Date(), updatedAt: Date? = nil,
        serverIdentifier: String? = nil
    ) {
        self.id = id
        self.title = title
        self.modelID = modelID
        self.systemPrompt = systemPrompt
        self.reasoningEffort = reasoningEffort
        self.isWebSearchEnabled = isWebSearchEnabled
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.serverIdentifier = serverIdentifier
    }
}

/// Lightweight conversation metadata used to render, sort, and maintain the
/// conversation list without loading full transcripts or image attachments.
public struct ChatConversationSummary: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var modelID: String?
    public var serverIdentifier: String?
    public let createdAt: Date
    public var updatedAt: Date
    public var messageCount: Int
    public var previewText: String
    public var hasStreamingMessage: Bool

    public init(
        id: UUID,
        title: String = "",
        modelID: String? = nil,
        serverIdentifier: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        messageCount: Int = 0,
        previewText: String = "",
        hasStreamingMessage: Bool = false
    ) {
        self.id = id
        self.title = title
        self.modelID = modelID
        self.serverIdentifier = serverIdentifier
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.messageCount = messageCount
        self.previewText = previewText
        self.hasStreamingMessage = hasStreamingMessage
    }

    public init(from conversation: ChatConversation) {
        self.id = conversation.id
        self.title = conversation.title
        self.modelID = conversation.modelID
        self.serverIdentifier = conversation.serverIdentifier
        self.createdAt = conversation.createdAt
        self.updatedAt = conversation.updatedAt
        self.messageCount = conversation.messages.count
        self.previewText = Self.previewText(for: conversation.messages)
        self.hasStreamingMessage = conversation.messages.contains { $0.status == .streaming }
    }

    static func previewText(for messages: [ChatMessage]) -> String {
        guard let last = messages.last(where: { !$0.text.isEmpty }) else { return "" }
        let flattened = last.text.replacingOccurrences(of: "\n", with: " ")
        return String(flattened.prefix(80))
    }
}

/// Continuing a conversation on a server other than the one its history was
/// sent to. Sending requires passing this bound token back so a destination or
/// credential change while the confirmation is on screen cannot slip through.
public struct ChatServerChange: Equatable, Sendable {
    public let conversationID: UUID
    /// `nil` when the conversation predates server binding.
    public let previousServerIdentifier: String?
    public let currentServerIdentifier: String
    public let messageCount: Int
    public let imageCount: Int
    let credentialRevision: UInt64
}

public struct ChatMemoryItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var text: String
    public var isPinned: Bool
    public let createdAt: Date

    public init(id: UUID = UUID(), text: String, isPinned: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.isPinned = isPinned
        self.createdAt = createdAt
    }
}

/// A slash command: `/command` in the composer applies `prompt` to the user's text.
public struct ChatSkill: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var command: String
    public var title: String
    public var prompt: String

    public init(id: UUID = UUID(), command: String, title: String, prompt: String) {
        self.id = id
        self.command = command
        self.title = title
        self.prompt = prompt
    }
}

public enum ChatSearchProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case tavily
    case brave
    case exa
    case serper
    case serpAPI

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .tavily: "Tavily"
        case .brave: "Brave Search"
        case .exa: "Exa"
        case .serper: "Serper"
        case .serpAPI: "SerpAPI"
        }
    }
}

public enum ChatModelStrategy: String, Codable, Sendable {
    case mostRecent, fixed
}

public struct ChatSettings: Codable, Equatable, Sendable {
    public var globalInstructions: String
    public var isMemoryEnabled: Bool
    public var defaultModelID: String?
    // Optional storage keeps settings written before the strategy existed readable.
    private var modelStrategy: ChatModelStrategy?
    public var newConversationModelStrategy: ChatModelStrategy {
        get { modelStrategy ?? (defaultModelID == nil ? .mostRecent : .fixed) }
        set { modelStrategy = newValue }
    }
    public private(set) var recentModelIDs: [String: String]?
    /// Per-server, per-model last explicit reasoning selection.
    /// Optional storage keeps settings written before this preference existed readable.
    public private(set) var recentReasoningEfforts: [String: [String: ChatReasoningEffort]]?

    mutating func rememberModel(_ id: String, for server: String) {
        if recentModelIDs == nil { recentModelIDs = [:] }
        recentModelIDs?[server] = id
    }

    mutating func rememberReasoningEffort(_ effort: ChatReasoningEffort, for modelID: String, server: String) {
        if recentReasoningEfforts == nil { recentReasoningEfforts = [:] }
        var perServer = recentReasoningEfforts?[server] ?? [:]
        perServer[modelID] = effort
        recentReasoningEfforts?[server] = perServer
    }

    func rememberedReasoningEffort(for modelID: String, server: String) -> ChatReasoningEffort? {
        recentReasoningEfforts?[server]?[modelID]
    }
    public var searchProvider: ChatSearchProvider?
    public var notifiesOnBackgroundCompletion: Bool
    public var generatesTitles: Bool

    public init(
        globalInstructions: String = "", isMemoryEnabled: Bool = true, defaultModelID: String? = nil,
        searchProvider: ChatSearchProvider? = nil, notifiesOnBackgroundCompletion: Bool = true,
        generatesTitles: Bool = true
    ) {
        self.globalInstructions = globalInstructions
        self.isMemoryEnabled = isMemoryEnabled
        self.defaultModelID = defaultModelID
        self.searchProvider = searchProvider
        self.notifiesOnBackgroundCompletion = notifiesOnBackgroundCompletion
        self.generatesTitles = generatesTitles
    }
}

public enum ChatCredentialState: Equatable, Sendable {
    /// No CPA connection is bound to the chat workspace.
    case unbound
    /// Bound, but no client API key is stored for this server.
    case missingKey
    case loading
    /// `hint` is a redacted suffix such as `••••0001`, never the key itself.
    case ready(hint: String, isManual: Bool)
    case failed(CPAError)
}

public enum ChatNotificationAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
}

public enum ChatModelListState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(ChatFailure)
}

public enum ChatSearchKeyStatus: Equatable, Sendable {
    case present
    case absent
    case unknown
}
