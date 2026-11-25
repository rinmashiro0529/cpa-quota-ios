import Foundation
import CPAQuotaKit

/// Streaming inference for one user prompt.
public protocol ChatEngine: Sendable {
    /// Snapshots are cumulative (full text so far), not deltas.
    func stream(_ request: ChatEngineRequest) -> AsyncThrowingStream<ChatEngineEvent, any Error>
    /// One-shot completion used for background work such as title generation.
    func complete(_ request: ChatEngineRequest) async throws -> String
    /// Clears any session-scoped protocol or reasoning capability cache.
    func resetReasoningCapabilities()
}

public extension ChatEngine {
    func resetReasoningCapabilities() {}
}

public struct ChatEngineRequest: Sendable {
    /// Server inference root: `server.baseURL` + `v1/`.
    public var baseURL: URL
    public var apiKey: CPAClientAPIKey
    public var modelID: String
    /// Optional `owned_by` metadata from `/v1/models` for protocol detection.
    public var modelOwnedBy: String?
    public var instructions: String
    public var history: [ChatMessage]
    public var prompt: String
    public var images: [ChatImageAttachment]
    public var reasoningEffort: ChatReasoningEffort

    public init(
        baseURL: URL, apiKey: CPAClientAPIKey, modelID: String, modelOwnedBy: String? = nil,
        instructions: String = "", history: [ChatMessage] = [], prompt: String,
        images: [ChatImageAttachment] = [], reasoningEffort: ChatReasoningEffort = .automatic
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.modelID = modelID
        self.modelOwnedBy = modelOwnedBy
        self.instructions = instructions
        self.history = history
        self.prompt = prompt
        self.images = images
        self.reasoningEffort = reasoningEffort
    }
}

public enum ChatEngineEvent: Sendable {
    case snapshot(text: String, reasoning: String?)
    case usage(ChatTokenUsage)
    case reasoningResolution(ChatReasoningResolution)
}

/// `GET /v1/models` sources; `CPAModelCatalogClient` conforms so tests can fake it.
public protocol ChatModelCatalog: Sendable {
    func models() async throws -> [CPAModel]
}

extension CPAModelCatalogClient: ChatModelCatalog {}

/// Secret account names in `ChatSecretStore`.
public enum ChatSecrets {
    public static func clientAPIKeyAccount(for server: CPAServer) -> String {
        "client-api-key|\(server.identifier)"
    }

    public static func searchKeyAccount(for provider: ChatSearchProvider) -> String {
        "search-key|\(provider.rawValue)"
    }
}
