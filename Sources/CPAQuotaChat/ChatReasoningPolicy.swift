import Foundation
import AnyLanguageModel

/// Inference protocol selected for a chat request.
public enum ChatAPIProtocol: String, Hashable, Sendable {
    case openAIChatCompletions
    case openAIResponses
    case anthropicMessages
}

/// Anthropic Claude thinking API generations.
public enum AnthropicThinkingStyle: String, Hashable, Sendable {
    /// Claude 4.6 / 4.7 / 5+ adaptive thinking paired with `output_config.effort`.
    case adaptive
    /// Claude 3.7 / 4.0 / 4.5 extended thinking with `thinking.budget_tokens`.
    case budget
}

/// Concrete wire parameters computed for one request attempt.
public struct ChatReasoningWirePlan: Equatable, Sendable {
    public let protocolKind: ChatAPIProtocol
    public let requested: ChatReasoningEffort
    public let applied: ChatReasoningEffort?
    /// OpenAI Chat Completions `reasoning_effort` or Responses `reasoning.effort` value.
    public let openAIWireEffort: String?
    public let anthropicStyle: AnthropicThinkingStyle?
    /// Anthropic `output_config.effort` value when using `.adaptive`.
    public let anthropicEffort: String?
    /// Anthropic `thinking.budget_tokens` value when using `.budget`.
    public let anthropicBudgetTokens: Int?
    /// Anthropic required `max_tokens` value (always > `anthropicBudgetTokens` when set).
    public let anthropicMaxTokens: Int?
    /// `true` when an explicit user choice had to be stripped for compatibility.
    public let omittedForCompatibility: Bool

    public func resolution(usedFallbackProtocol: Bool) -> ChatReasoningResolution {
        if requested == .automatic {
            return ChatReasoningResolution(
                requested: requested,
                applied: nil,
                outcome: .applied,
                usedFallbackProtocol: usedFallbackProtocol
            )
        }
        if omittedForCompatibility {
            return ChatReasoningResolution(
                requested: requested,
                applied: nil,
                outcome: .omitted,
                usedFallbackProtocol: usedFallbackProtocol
            )
        }
        if let applied, applied != requested {
            return ChatReasoningResolution(
                requested: requested,
                applied: applied,
                outcome: .downgraded,
                usedFallbackProtocol: usedFallbackProtocol
            )
        }
        return ChatReasoningResolution(
            requested: requested,
            applied: applied ?? requested,
            outcome: .applied,
            usedFallbackProtocol: usedFallbackProtocol
        )
    }

    /// JSON payload fragment for OpenAI Responses API `reasoning` object.
    public var openAIResponsesReasoningObject: [String: JSONValue]? {
        guard protocolKind == .openAIResponses, let effort = openAIWireEffort else { return nil }
        return ["effort": .string(effort)]
    }
}

/// Classified upstream rejection that can safely trigger deterministic fallback
/// when zero response output has been streamed yet.
public enum ChatReasoningRejection: Equatable, Sendable {
    /// Target server does not expose or accept Anthropic `/v1/messages`.
    case anthropicEndpointUnsupported
    /// Model or upstream does not accept reasoning/thinking configuration at all.
    case parameterUnsupported
    /// Specific effort value was rejected; `allowedValues` holds any values parsed from the error body.
    case effortValueUnsupported(allowedValues: Set<String>)
    /// Anthropic model/proxy rejected adaptive thinking or `output_config.effort`.
    case anthropicAdaptiveUnsupported
    /// Anthropic 4.7+ rejected `thinking.budget_tokens` or `thinking.type = enabled`.
    case anthropicBudgetUnsupported
    /// Anthropic rejected `max_tokens` exceeding the model ceiling.
    case anthropicMaxTokensLimit(maximum: Int)
}

/// Session-scoped memory of verified protocol/model reasoning constraints.
/// Kept in memory only so server/model upgrades are picked up cleanly on refresh or relaunch.
public final class ChatReasoningCapabilityCache: @unchecked Sendable {
    public struct ModelProfile: Equatable, Sendable {
        public var reasoningUnsupported = false
        public var unsupportedOpenAIValues = Set<String>()
        public var allowedOpenAIValues: Set<String>?
        public var preferredAnthropicStyle: AnthropicThinkingStyle?
        public var unsupportedAnthropicEfforts = Set<String>()
        public var allowedAnthropicEfforts: Set<String>?
        public var anthropicMaxTokensCeiling: Int?

        public init() {}
    }

    private struct ModelKey: Hashable {
        let server: String
        let modelID: String
    }

    private let lock = NSLock()
    private var anthropicUnsupportedServers = Set<String>()
    private var profiles: [ModelKey: ModelProfile] = [:]

    public init() {}

    public func isAnthropicEndpointUnsupported(for server: String) -> Bool {
        lock.withLock { anthropicUnsupportedServers.contains(server) }
    }

    public func markAnthropicEndpointUnsupported(for server: String) {
        lock.withLock { _ = anthropicUnsupportedServers.insert(server) }
    }

    public func profile(for server: String, modelID: String) -> ModelProfile {
        lock.withLock { profiles[ModelKey(server: server, modelID: modelID)] ?? ModelProfile() }
    }

    public func updateProfile(for server: String, modelID: String, _ mutate: (inout ModelProfile) -> Void) {
        lock.withLock {
            let key = ModelKey(server: server, modelID: modelID)
            var current = profiles[key] ?? ModelProfile()
            mutate(&current)
            profiles[key] = current
        }
    }

    public func reset() {
        lock.withLock {
            anthropicUnsupportedServers.removeAll()
            profiles.removeAll()
        }
    }
}

/// Pure planning and error classification logic for cross-provider reasoning compatibility.
public enum ChatReasoningPolicy {
    public static let defaultAnthropicMaxTokens = 16_384
    public static let anthropicOutputHeadroom = 8_192
    public static let minimumAnthropicBudgetTokens = 1_024
    public static let defaultAnthropicMaxTokensCap = 64_000

    public static func serverKey(for baseURL: URL) -> String {
        anthropicBaseURL(from: baseURL).absoluteString.lowercased()
    }

    /// Strips a trailing `/v1` segment from `ChatEngineRequest.baseURL` because
    /// `AnthropicLanguageModel` appends `v1/messages` itself.
    public static func anthropicBaseURL(from inferenceBaseURL: URL) -> URL {
        guard var components = URLComponents(url: inferenceBaseURL, resolvingAgainstBaseURL: false) else {
            return inferenceBaseURL
        }
        var path = components.path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        if path.lowercased() == "/v1" {
            components.path = "/"
            return components.url ?? inferenceBaseURL
        }
        if path.lowercased().hasSuffix("/v1") {
            components.path = String(path.dropLast(3))
            if components.path.isEmpty { components.path = "/" }
            return components.url ?? inferenceBaseURL
        }
        return inferenceBaseURL
    }

    /// Detects whether a catalog entry represents an Anthropic Claude model.
    public static func isAnthropicModel(modelID: String, ownedBy: String?) -> Bool {
        if let ownedBy {
            let owner = ownedBy.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if owner == "anthropic" || owner == "claude" || owner.contains("anthropic") {
                return true
            }
        }
        let lowered = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let leaf = lowered.split(separator: "/").last.map(String.init) ?? lowered
        return leaf.hasPrefix("claude-") || leaf.hasPrefix("claude_") || leaf == "claude"
    }

    /// Picks the initial Anthropic thinking API generation from model naming conventions.
    /// Unknown Claude aliases default to `.adaptive`; 400 self-healing flips to `.budget` if needed.
    public static func initialAnthropicStyle(for modelID: String) -> AnthropicThinkingStyle {
        let lowered = modelID.lowercased()
        let leaf = lowered.split(separator: "/").last.map(String.init) ?? lowered

        // Patterns: claude-opus-4-6, claude-sonnet-4.6, claude-4-5-sonnet, claude-3-7-sonnet, claude-sonnet-5
        if let (major, minor) = extractClaudeVersion(from: leaf) {
            if major >= 5 { return .adaptive }
            if major == 4 && minor >= 6 { return .adaptive }
            return .budget
        }
        return .adaptive
    }

    private static func extractClaudeVersion(from text: String) -> (Int, Int)? {
        let patterns = [
            #"claude-(?:opus|sonnet|haiku)-(\d+)[.-](\d+)"#,
            #"claude-(\d+)[.-](\d+)-(?:opus|sonnet|haiku)"#,
            #"claude-(\d+)[.-](\d+)"#,
            #"claude-(?:opus|sonnet|haiku)-(\d+)(?!\d)"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
                continue
            }
            if match.numberOfRanges >= 3,
               let r1 = Range(match.range(at: 1), in: text),
               let r2 = Range(match.range(at: 2), in: text),
               let major = Int(text[r1]),
               let minor = Int(text[r2]) {
                return (major, minor)
            }
            if match.numberOfRanges >= 2,
               let r1 = Range(match.range(at: 1), in: text),
               let major = Int(text[r1]) {
                return (major, 0)
            }
        }
        return nil
    }

    public static func initialProtocol(for request: ChatEngineRequest, cache: ChatReasoningCapabilityCache) -> ChatAPIProtocol {
        let key = serverKey(for: request.baseURL)
        if isAnthropicModel(modelID: request.modelID, ownedBy: request.modelOwnedBy),
           !cache.isAnthropicEndpointUnsupported(for: key) {
            return .anthropicMessages
        }
        return .openAIChatCompletions
    }

    public static func makePlan(
        requested: ChatReasoningEffort,
        protocolKind: ChatAPIProtocol,
        modelID: String,
        profile: ChatReasoningCapabilityCache.ModelProfile
    ) -> ChatReasoningWirePlan {
        switch protocolKind {
        case .openAIChatCompletions, .openAIResponses:
            return makeOpenAIPlan(requested: requested, protocolKind: protocolKind, profile: profile)
        case .anthropicMessages:
            return makeAnthropicPlan(requested: requested, modelID: modelID, profile: profile)
        }
    }

    private static func makeOpenAIPlan(
        requested: ChatReasoningEffort,
        protocolKind: ChatAPIProtocol,
        profile: ChatReasoningCapabilityCache.ModelProfile
    ) -> ChatReasoningWirePlan {
        if requested == .automatic {
            return ChatReasoningWirePlan(
                protocolKind: protocolKind,
                requested: .automatic,
                applied: nil,
                openAIWireEffort: nil,
                anthropicStyle: nil,
                anthropicEffort: nil,
                anthropicBudgetTokens: nil,
                anthropicMaxTokens: nil,
                omittedForCompatibility: false
            )
        }
        if profile.reasoningUnsupported {
            return omittedPlan(protocolKind: protocolKind, requested: requested, anthropicMaxTokens: nil)
        }

        let candidates = openAICandidates(for: requested)
        for candidate in candidates {
            if profile.unsupportedOpenAIValues.contains(candidate.wire) {
                continue
            }
            if let allowed = profile.allowedOpenAIValues, !allowed.contains(candidate.wire) {
                continue
            }
            return ChatReasoningWirePlan(
                protocolKind: protocolKind,
                requested: requested,
                applied: candidate.effort,
                openAIWireEffort: candidate.wire,
                anthropicStyle: nil,
                anthropicEffort: nil,
                anthropicBudgetTokens: nil,
                anthropicMaxTokens: nil,
                omittedForCompatibility: false
            )
        }

        return omittedPlan(protocolKind: protocolKind, requested: requested, anthropicMaxTokens: nil)
    }

    private static func makeAnthropicPlan(
        requested: ChatReasoningEffort,
        modelID: String,
        profile: ChatReasoningCapabilityCache.ModelProfile
    ) -> ChatReasoningWirePlan {
        let ceiling = profile.anthropicMaxTokensCeiling
        let baseMaxTokens = min(defaultAnthropicMaxTokens, ceiling ?? defaultAnthropicMaxTokensCap)

        if requested == .automatic {
            return ChatReasoningWirePlan(
                protocolKind: .anthropicMessages,
                requested: .automatic,
                applied: nil,
                openAIWireEffort: nil,
                anthropicStyle: nil,
                anthropicEffort: nil,
                anthropicBudgetTokens: nil,
                anthropicMaxTokens: baseMaxTokens,
                omittedForCompatibility: false
            )
        }

        // Omitting `thinking` disables thinking across all Anthropic Claude generations
        // without triggering 400 errors on non-thinking Claude models.
        if requested == .off {
            return ChatReasoningWirePlan(
                protocolKind: .anthropicMessages,
                requested: .off,
                applied: .off,
                openAIWireEffort: nil,
                anthropicStyle: nil,
                anthropicEffort: nil,
                anthropicBudgetTokens: nil,
                anthropicMaxTokens: baseMaxTokens,
                omittedForCompatibility: false
            )
        }

        if profile.reasoningUnsupported {
            return omittedPlan(protocolKind: .anthropicMessages, requested: requested, anthropicMaxTokens: baseMaxTokens)
        }

        let style = profile.preferredAnthropicStyle ?? initialAnthropicStyle(for: modelID)
        switch style {
        case .adaptive:
            for candidate in anthropicEffortCandidates(for: requested) {
                if profile.unsupportedAnthropicEfforts.contains(candidate.wire) {
                    continue
                }
                if let allowed = profile.allowedAnthropicEfforts, !allowed.contains(candidate.wire) {
                    continue
                }
                return ChatReasoningWirePlan(
                    protocolKind: .anthropicMessages,
                    requested: requested,
                    applied: candidate.effort,
                    openAIWireEffort: nil,
                    anthropicStyle: .adaptive,
                    anthropicEffort: candidate.wire,
                    anthropicBudgetTokens: nil,
                    anthropicMaxTokens: baseMaxTokens,
                    omittedForCompatibility: false
                )
            }
            return omittedPlan(protocolKind: .anthropicMessages, requested: requested, anthropicMaxTokens: baseMaxTokens)

        case .budget:
            guard let rawBudget = anthropicBudgetTokens(for: requested) else {
                return omittedPlan(protocolKind: .anthropicMessages, requested: requested, anthropicMaxTokens: baseMaxTokens)
            }
            let effectiveCap = ceiling ?? defaultAnthropicMaxTokensCap
            if effectiveCap <= minimumAnthropicBudgetTokens {
                return omittedPlan(protocolKind: .anthropicMessages, requested: requested, anthropicMaxTokens: effectiveCap)
            }
            let maxBudget = max(minimumAnthropicBudgetTokens, effectiveCap - 1_024)
            let clampedBudget = min(rawBudget, maxBudget)
            let desiredMaxTokens = max(clampedBudget + anthropicOutputHeadroom, defaultAnthropicMaxTokens)
            let finalMaxTokens = min(desiredMaxTokens, effectiveCap)
            let finalBudget = min(clampedBudget, max(minimumAnthropicBudgetTokens, finalMaxTokens - 1_024))
            let effectiveEffort = effortForAnthropicBudget(finalBudget, requested: requested)
            return ChatReasoningWirePlan(
                protocolKind: .anthropicMessages,
                requested: requested,
                applied: effectiveEffort,
                openAIWireEffort: nil,
                anthropicStyle: .budget,
                anthropicEffort: nil,
                anthropicBudgetTokens: finalBudget,
                anthropicMaxTokens: finalMaxTokens,
                omittedForCompatibility: false
            )
        }
    }

    private static func omittedPlan(
        protocolKind: ChatAPIProtocol,
        requested: ChatReasoningEffort,
        anthropicMaxTokens: Int?
    ) -> ChatReasoningWirePlan {
        ChatReasoningWirePlan(
            protocolKind: protocolKind,
            requested: requested,
            applied: nil,
            openAIWireEffort: nil,
            anthropicStyle: nil,
            anthropicEffort: nil,
            anthropicBudgetTokens: nil,
            anthropicMaxTokens: anthropicMaxTokens,
            omittedForCompatibility: true
        )
    }

    /// Deterministic downgrade ladder for OpenAI-compatible `reasoning_effort` values.
    public static func openAICandidates(for effort: ChatReasoningEffort) -> [(effort: ChatReasoningEffort, wire: String)] {
        switch effort {
        case .automatic: []
        case .off: [(.off, "none")]
        case .low: [(.low, "low")]
        case .medium: [(.medium, "medium"), (.low, "low")]
        case .high: [(.high, "high"), (.medium, "medium"), (.low, "low")]
        case .xhigh: [(.xhigh, "xhigh"), (.high, "high"), (.medium, "medium")]
        case .max: [(.max, "max"), (.xhigh, "xhigh"), (.high, "high"), (.medium, "medium")]
        }
    }

    /// Deterministic downgrade ladder for Anthropic `output_config.effort`.
    public static func anthropicEffortCandidates(for effort: ChatReasoningEffort) -> [(effort: ChatReasoningEffort, wire: String)] {
        switch effort {
        case .automatic, .off: []
        case .low: [(.low, "low")]
        case .medium: [(.medium, "medium"), (.low, "low")]
        case .high: [(.high, "high"), (.medium, "medium"), (.low, "low")]
        case .xhigh: [(.xhigh, "xhigh"), (.high, "high"), (.medium, "medium")]
        case .max: [(.max, "max"), (.xhigh, "xhigh"), (.high, "high"), (.medium, "medium")]
        }
    }

    public static func anthropicBudgetTokens(for effort: ChatReasoningEffort) -> Int? {
        switch effort {
        case .automatic, .off: nil
        case .low: 2_048
        case .medium: 8_192
        case .high: 16_384
        case .xhigh: 24_576
        case .max: 32_768
        }
    }

    private static func effortForAnthropicBudget(_ budget: Int, requested: ChatReasoningEffort) -> ChatReasoningEffort {
        guard let target = anthropicBudgetTokens(for: requested), budget < target else {
            return requested
        }
        if budget >= 24_576 { return .xhigh }
        if budget >= 16_384 { return .high }
        if budget >= 8_192 { return .medium }
        return .low
    }

    /// Applies a classified rejection to the session capability cache.
    public static func recordRejection(
        _ rejection: ChatReasoningRejection,
        for plan: ChatReasoningWirePlan,
        server: String,
        modelID: String,
        cache: ChatReasoningCapabilityCache
    ) {
        switch rejection {
        case .anthropicEndpointUnsupported:
            cache.markAnthropicEndpointUnsupported(for: server)
        case .parameterUnsupported:
            cache.updateProfile(for: server, modelID: modelID) { $0.reasoningUnsupported = true }
        case .effortValueUnsupported(let allowed):
            cache.updateProfile(for: server, modelID: modelID) { profile in
                switch plan.protocolKind {
                case .openAIChatCompletions, .openAIResponses:
                    if let wire = plan.openAIWireEffort {
                        profile.unsupportedOpenAIValues.insert(wire)
                    }
                    if !allowed.isEmpty {
                        profile.allowedOpenAIValues = allowed
                    }
                case .anthropicMessages:
                    if let wire = plan.anthropicEffort {
                        profile.unsupportedAnthropicEfforts.insert(wire)
                    }
                    if !allowed.isEmpty {
                        profile.allowedAnthropicEfforts = allowed
                    }
                }
            }
        case .anthropicAdaptiveUnsupported:
            cache.updateProfile(for: server, modelID: modelID) { profile in
                if profile.preferredAnthropicStyle == .budget {
                    profile.reasoningUnsupported = true
                } else {
                    profile.preferredAnthropicStyle = .budget
                }
            }
        case .anthropicBudgetUnsupported:
            cache.updateProfile(for: server, modelID: modelID) { profile in
                if profile.preferredAnthropicStyle == .adaptive {
                    profile.reasoningUnsupported = true
                } else {
                    profile.preferredAnthropicStyle = .adaptive
                }
            }
        case .anthropicMaxTokensLimit(let maximum):
            cache.updateProfile(for: server, modelID: modelID) { profile in
                let clamped = max(256, maximum)
                if let existing = profile.anthropicMaxTokensCeiling {
                    profile.anthropicMaxTokensCeiling = min(existing, clamped)
                } else {
                    profile.anthropicMaxTokensCeiling = clamped
                }
            }
        }
    }

    // MARK: - Error classification

    public static func classifyError(
        _ error: any Error,
        plan: ChatReasoningWirePlan
    ) -> ChatReasoningRejection? {
        if error is CancellationError { return nil }
        if let transportError = error as? HTTPTransportError {
            return classifyTransportError(transportError, plan: plan)
        }
        if plan.protocolKind == .anthropicMessages, error is DecodingError {
            return .anthropicEndpointUnsupported
        }
        return nil
    }

    static func classifyTransportError(
        _ error: HTTPTransportError,
        plan: ChatReasoningWirePlan
    ) -> ChatReasoningRejection? {
        let status = error.response?.status.code

        // Anthropic endpoint fallback on relays that only expose `/v1/chat/completions`
        // or reject `x-api-key` auth on `/v1/messages`.
        if plan.protocolKind == .anthropicMessages {
            if error.kind == .decodingError || error.kind == .invalidResponse {
                return .anthropicEndpointUnsupported
            }
            if let status, [401, 404, 405, 501].contains(status) {
                return .anthropicEndpointUnsupported
            }
        }

        // Only 400 / 422 HTTP errors or SSE providerError events may indicate parameter rejection.
        let isValidationError: Bool = switch error.kind {
        case .httpError:
            status == 400 || status == 422
        case .providerError:
            status == nil || status == 400 || status == 422 || status == 200
        default:
            false
        }
        guard isValidationError else { return nil }

        let details = extractErrorDetails(from: error.body)
        let combined = details.combinedLowercased

        // Non-reasoning rejections must never trigger retries.
        let nonReasoningMarkers = [
            "context_length_exceeded",
            "context window",
            "maximum context length",
            "prompt is too long",
            "content_filter",
            "content policy",
            "safety",
            "insufficient_quota",
            "billing",
            "rate limit",
            "invalid_api_key",
            "image",
        ]
        if nonReasoningMarkers.contains(where: { combined.contains($0) }) {
            return nil
        }

        // 1. Anthropic `max_tokens` ceiling exceeded.
        if plan.protocolKind == .anthropicMessages,
           combined.contains("max_tokens"),
           let limit = extractMaxTokensLimit(from: details.rawText) {
            return .anthropicMaxTokensLimit(maximum: limit)
        }

        // 2. Anthropic adaptive vs budget paradigm conflict.
        if plan.protocolKind == .anthropicMessages {
            let mentionsBudget = combined.contains("budget_tokens") || combined.contains("thinking.budget")
            let mentionsAdaptive = combined.contains("adaptive") || combined.contains("output_config")
            let mentionsThinking = combined.contains("thinking") || combined.contains("effort")

            if plan.anthropicStyle == .budget,
               (mentionsBudget || combined.contains("should be 'adaptive'") || combined.contains("must be 'adaptive'") || combined.contains("use adaptive")),
               (combined.contains("deprecated") || combined.contains("adaptive") || combined.contains("not supported") || combined.contains("unsupported") || combined.contains("remove")) {
                return .anthropicBudgetUnsupported
            }
            if plan.anthropicStyle == .adaptive,
               (mentionsAdaptive || combined.contains("should be 'enabled'") || combined.contains("must be 'enabled'")),
               (combined.contains("not supported") || combined.contains("unsupported") || combined.contains("unrecognized") || combined.contains("extra inputs") || combined.contains("unknown") || combined.contains("invalid") || combined.contains("should be 'enabled'") || combined.contains("must be 'enabled'")) {
                // Distinguish effort value rejection from adaptive/output_config schema rejection.
                if let effort = plan.anthropicEffort,
                   combined.contains("effort"),
                   isEffortValueRejection(combined: combined, sentValue: effort) {
                    return .effortValueUnsupported(allowedValues: extractAllowedEffortValues(from: details.rawText))
                }
                return .anthropicAdaptiveUnsupported
            }
            if !mentionsThinking && !mentionsAdaptive && !mentionsBudget {
                return nil
            }
        }

        let mentionsReasoningField =
            details.paramLowercased.contains("reasoning")
            || details.paramLowercased.contains("thinking")
            || details.paramLowercased.contains("effort")
            || details.paramLowercased.contains("output_config")
            || combined.contains("reasoning_effort")
            || combined.contains("reasoning.effort")
            || combined.contains("invalid_reasoning_effort")
            || combined.contains("thinking_config")
            || combined.contains("thinkingbudget")
            || combined.contains("budget_tokens")
            || combined.contains("output_config")
            || (combined.contains("thinking") && (combined.contains("not supported") || combined.contains("unsupported") || combined.contains("extra inputs") || combined.contains("unrecognized") || combined.contains("unknown")))
            || (combined.contains("reasoning") && (combined.contains("not supported") || combined.contains("unsupported") || combined.contains("unrecognized") || combined.contains("unknown") || combined.contains("invalid")))

        guard mentionsReasoningField else {
            return nil
        }

        // 3. Specific effort value out of range vs entire parameter unsupported.
        let sentValue = plan.openAIWireEffort ?? plan.anthropicEffort
        if let sentValue, isEffortValueRejection(combined: combined, sentValue: sentValue) {
            return .effortValueUnsupported(allowedValues: extractAllowedEffortValues(from: details.rawText))
        }

        // 4. Whole reasoning/thinking parameter rejected by non-reasoning model or proxy.
        let unsupportedFieldMarkers = [
            "unrecognized",
            "unknown field",
            "unknown parameter",
            "extra inputs are not permitted",
            "extra_forbidden",
            "is not supported",
            "not supported",
            "unsupported parameter",
            "unsupported field",
            "does not support",
            "cannot be used",
            "not allowed",
            "not permitted",
            "not enabled",
        ]
        if unsupportedFieldMarkers.contains(where: { combined.contains($0) }) {
            return .parameterUnsupported
        }

        // Fallback: if the error explicitly names `reasoning_effort` or `thinking` with an invalid status.
        if let sentValue {
            let allowed = extractAllowedEffortValues(from: details.rawText)
            if !allowed.isEmpty || combined.contains(sentValue) {
                return .effortValueUnsupported(allowedValues: allowed)
            }
        }
        return .parameterUnsupported
    }

    private struct ErrorDetails {
        let rawText: String
        let paramLowercased: String
        let combinedLowercased: String
    }

    private static func extractErrorDetails(from body: Data?) -> ErrorDetails {
        guard let body, !body.isEmpty else {
            return ErrorDetails(rawText: "", paramLowercased: "", combinedLowercased: "")
        }
        let raw = String(decoding: body, as: UTF8.self)
        var parts = [raw]
        var param = ""
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            let container = (object["error"] as? [String: Any]) ?? object
            for key in ["message", "code", "type", "param", "detail"] {
                if let text = container[key] as? String {
                    parts.append(text)
                    if key == "param" { param = text }
                }
            }
        }
        return ErrorDetails(
            rawText: raw,
            paramLowercased: param.lowercased(),
            combinedLowercased: parts.joined(separator: " ").lowercased()
        )
    }

    private static func isEffortValueRejection(combined: String, sentValue: String) -> Bool {
        if combined.contains("invalid_reasoning_effort") { return true }
        if combined.contains("supported values")
            || combined.contains("allowed values")
            || combined.contains("valid values")
            || combined.contains("must be one of")
            || combined.contains("expected one of")
            || combined.contains("invalid value") {
            return true
        }
        let quotedSent = ["'\(sentValue)'", "\"\(sentValue)\"", "`\(sentValue)`"]
        if quotedSent.contains(where: { combined.contains($0) }) {
            return true
        }
        return false
    }

    /// Parses known effort tokens declared in an error message's allowed-values list.
    static func extractAllowedEffortValues(from text: String) -> Set<String> {
        let lowered = text.lowercased()
        let anchors = ["supported values", "allowed values", "valid values", "must be one of", "expected one of", "one of:"]
        guard let anchorRange = anchors.compactMap({ lowered.range(of: $0) }).first else {
            return []
        }
        let tail = String(lowered[anchorRange.upperBound...])
        let known = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
        var found = Set<String>()
        for token in known {
            let pattern = #"(?<![a-z0-9_])"# + token + #"(?![a-z0-9_])"#
            if let regex = try? NSRegularExpression(pattern: pattern),
               regex.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)) != nil {
                found.insert(token)
            }
        }
        return found
    }

    /// Parses numeric `max_tokens` ceilings such as `max_tokens: 40960 > 8192` or `maximum allowed is 16384`.
    static func extractMaxTokensLimit(from text: String) -> Int? {
        let lowered = text.lowercased()
        let patterns = [
            #"max_tokens[^0-9]*\d+\s*>\s*(\d+)"#,
            #"maximum(?:\s+allowed|\s+is|\s+of)?\s*[:=]?\s*(\d+)"#,
            #"at most\s+(\d+)"#,
            #"<=?\s*(\d+)"#,
            #"limit(?:\s+of|\s+is)?\s*[:=]?\s*(\d+)"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)),
                  match.numberOfRanges >= 2,
                  let range = Range(match.range(at: 1), in: lowered),
                  let value = Int(lowered[range]),
                  value >= 256, value <= 200_000 else {
                continue
            }
            return value
        }
        return nil
    }
}
