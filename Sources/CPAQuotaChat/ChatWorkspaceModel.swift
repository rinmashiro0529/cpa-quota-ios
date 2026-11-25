import Foundation
import Observation
import CPAQuotaKit

/// Non-UI chat workspace: credential binding, model catalog, conversation
/// state, generation orchestration, persistence and secrets. All mutations
/// happen on the main actor; engine work runs in child tasks.
///
/// Implementation is decomposed by responsibility across:
/// - `ChatWorkspaceModel.swift` (state, indexing, drafts)
/// - `ChatWorkspaceModel+Credentials.swift` (server binding, keys, model catalog)
/// - `ChatWorkspaceModel+Storage.swift` (persistence, lazy hydration, CRUD)
/// - `ChatWorkspaceModel+Generation.swift` (streaming, continuation, search, titles)
/// - `ChatWorkspaceModel+Library.swift` (memories, skills, search keys, notifications)
@MainActor @Observable
public final class ChatWorkspaceModel {
    let persistence: any ChatPersistence
    let secrets: any ChatSecretStore
    let engine: any ChatEngine
    let searchClient: @Sendable (ChatSearchProvider) -> any ChatSearchClient
    let modelCatalog: @Sendable (CPAServer, CPAClientAPIKey) -> any ChatModelCatalog
    let backgroundRunner: any ChatBackgroundRunner
    let streamingPersistInterval: Duration
    let maxHydratedConversations: Int
    var discoveryFactory: (@Sendable () async -> CPAAPIKeyDiscovery?)?

    public init(
        persistence: any ChatPersistence = ChatFilePersistence.default,
        secrets: any ChatSecretStore = KeychainSecretStore(),
        engine: any ChatEngine = AnyLanguageModelChatEngine(),
        searchClient: @escaping @Sendable (ChatSearchProvider) -> any ChatSearchClient = { ChatSearch.client(for: $0) },
        modelCatalog: @escaping @Sendable (CPAServer, CPAClientAPIKey) -> any ChatModelCatalog = { CPAModelCatalogClient(server: $0, apiKey: $1) },
        backgroundRunner: any ChatBackgroundRunner = SystemChatBackgroundRunner(),
        streamingPersistInterval: Duration = .seconds(2),
        maxHydratedConversations: Int = 16
    ) {
        self.persistence = persistence
        self.secrets = secrets
        self.engine = engine
        self.searchClient = searchClient
        self.modelCatalog = modelCatalog
        self.backgroundRunner = backgroundRunner
        self.streamingPersistInterval = streamingPersistInterval
        self.maxHydratedConversations = max(1, maxHydratedConversations)
    }

    // MARK: - Server binding & credentials state

    public internal(set) var server: CPAServer?
    public internal(set) var credentialState: ChatCredentialState = .unbound
    public internal(set) var discoveredKeys: [CPAClientAPIKey] = []
    public internal(set) var isDiscoveringKeys = false
    public internal(set) var keyDiscoveryError: CPAError?
    var activeKey: CPAClientAPIKey?
    var temporaryRecentModelID: String?
    var temporaryRecentReasoningEfforts: [String: ChatReasoningEffort] = [:]
    @ObservationIgnored var manualReasoningConversationIDs = Set<UUID>()
    @ObservationIgnored var catalogRequest = UUID()
    @ObservationIgnored var credentialRevision: UInt64 = 0
    @ObservationIgnored var keyWriteTail: Task<Void, any Error>?
    public internal(set) var keyRemovalFailed = false
    /// `false` for a connection the user chose not to remember: the client
    /// key then lives only in memory and nothing is written to the Keychain.
    public internal(set) var persistsKey = true

    // MARK: - Model catalog state

    public internal(set) var models: [CPAModel] = []
    public internal(set) var modelListState: ChatModelListState = .idle

    // MARK: - Conversations & storage state

    public struct ConversationDraft: Equatable, Sendable {
        public var text: String
        public var attachments: [ChatImageAttachment]

        public init(text: String = "", attachments: [ChatImageAttachment] = []) {
            self.text = text
            self.attachments = attachments
        }

        public var isEmpty: Bool {
            text.isEmpty && attachments.isEmpty
        }
    }

    /// Hydrated conversations currently loaded in memory, ordered by `updatedAt` descending.
    public internal(set) var conversations: [ChatConversation] = []
    /// Lightweight metadata for every known conversation (hydrated and unhydrated),
    /// ordered by `updatedAt` descending.
    public internal(set) var conversationSummaries: [ChatConversationSummary] = []
    /// Conversations currently hydrating from disk on demand.
    public internal(set) var loadingConversationIDs = Set<UUID>()
    /// Per-conversation unsent composer drafts retained across navigation.
    /// Kept `@ObservationIgnored` so typing never invalidates the workspace views.
    @ObservationIgnored var drafts: [UUID: ConversationDraft] = [:]
    /// Fast lookup table from conversation ID to its current index in `conversations`.
    @ObservationIgnored var conversationIndexByID: [UUID: Int] = [:]
    /// Most-recently-used ordering for hydrated conversations when indexed lazy loading is active.
    @ObservationIgnored var hydratedAccessOrder: [UUID] = []
    @ObservationIgnored var hydrationTasks: [UUID: Task<ChatConversation?, Never>] = [:]
    @ObservationIgnored var pendingSummaryRenames: [UUID: String] = [:]
    /// `true` only after history, settings, memories and skills are restored.
    public internal(set) var isLoaded = false
    @ObservationIgnored var loadTask: Task<Void, Never>?

    struct Generation {
        let id: UUID
        let task: Task<Void, Never>
    }

    enum StopReason {
        case userStopped
        case connectionChanged
        case backgroundExpired
    }

    var generationTasks: [UUID: Generation] = [:]
    var stopReasons: [UUID: StopReason] = [:]
    var titleTasks: [UUID: Task<Void, Never>] = [:]
    /// Serializes persistence writes so an older snapshot can never land after a newer one.
    @ObservationIgnored var persistTail: Task<Void, Never>?

    public internal(set) var unsavedConversations = Set<UUID>()
    public internal(set) var failedConversationDeletions = Set<UUID>()
    public internal(set) var deleteAllStateUnknown = false
    public internal(set) var settingsLoadFailed = false
    public internal(set) var memoriesLoadFailed = false
    public internal(set) var skillsLoadFailed = false
    public internal(set) var unsavedSettings = false
    public internal(set) var unsavedMemories = false
    public internal(set) var unsavedSkills = false
    @ObservationIgnored var isApplyingLoadedSettings = false

    // MARK: - Settings, memories, skills state

    public var settings = ChatSettings() {
        didSet {
            guard !isApplyingLoadedSettings else { return }
            persistSettings(settings)
        }
    }

    public internal(set) var memories: [ChatMemoryItem] = []
    public internal(set) var skills: [ChatSkill] = []

    /// Set when a completion notification is opened; the chat UI shows that
    /// conversation and clears the request.
    public var requestedConversationID: UUID?

    // MARK: - Lookup & draft helpers

    public func conversation(_ id: UUID) -> ChatConversation? {
        guard let index = conversationIndex(for: id) else { return nil }
        return conversations[index]
    }

    public func hasConversation(_ id: UUID) -> Bool {
        conversationIndex(for: id) != nil || conversationSummaries.contains(where: { $0.id == id })
    }

    public func summary(for id: UUID) -> ChatConversationSummary? {
        conversationSummaries.first(where: { $0.id == id })
    }

    public func draft(for conversationID: UUID) -> ConversationDraft {
        drafts[conversationID] ?? ConversationDraft()
    }

    public func saveDraft(_ draft: ConversationDraft, for conversationID: UUID) {
        if draft.isEmpty {
            drafts.removeValue(forKey: conversationID)
        } else {
            drafts[conversationID] = draft
        }
    }

    public func clearDraft(for conversationID: UUID) {
        drafts.removeValue(forKey: conversationID)
    }

    // MARK: - Internal index & summary synchronization

    func conversationIndex(for id: UUID) -> Int? {
        if let index = conversationIndexByID[id],
           index < conversations.count,
           conversations[index].id == id {
            return index
        }
        if let index = conversations.firstIndex(where: { $0.id == id }) {
            conversationIndexByID[id] = index
            return index
        }
        return nil
    }

    func rebuildConversationIndex() {
        conversationIndexByID.removeAll(keepingCapacity: true)
        for (index, conversation) in conversations.enumerated() {
            conversationIndexByID[conversation.id] = index
        }
    }

    func syncSummary(for conversation: ChatConversation, reorder: Bool) {
        let updated = ChatConversationSummary(from: conversation)
        if let index = conversationSummaries.firstIndex(where: { $0.id == conversation.id }) {
            conversationSummaries[index] = updated
            if reorder {
                conversationSummaries.sort { $0.updatedAt > $1.updatedAt }
            }
        } else {
            conversationSummaries.insert(updated, at: 0)
            if reorder {
                conversationSummaries.sort { $0.updatedAt > $1.updatedAt }
            }
        }
    }

    func touchHydrated(_ id: UUID) {
        hydratedAccessOrder.removeAll { $0 == id }
        hydratedAccessOrder.append(id)
    }
}
