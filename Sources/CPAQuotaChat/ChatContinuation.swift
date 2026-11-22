import Foundation

public struct ChatReplyAttempt: Codable, Equatable, Sendable {
    public let modelID: String?
    public var status: ChatMessage.Status
    public var failure: ChatFailure?
    public var usage: ChatTokenUsage?
}

/// Bound to the destination and credential generation the user saw, including
/// while a server-change confirmation was on screen. Contains no secret.
public struct ChatContinuation: Equatable, Sendable {
    let conversationID: UUID
    let questionID: UUID
    let replyID: UUID
    let serverID: String
    let previousServerID: String?
    let attemptCount: Int
    let revision: UInt64
    public let modelID: String
    public let previousModelID: String?
    public let isRetry: Bool
}

extension ChatMessage {
    var permitsContinuation: Bool {
        guard role == .assistant else { return false }
        switch status {
        case .interrupted, .stopped: return true
        case .failed:
            switch failure {
            case .network, .timeout, .streamInterrupted, .continuationAddedNothing: return true
            case .unauthorized, .forbidden, .modelUnavailable, .rateLimited, .upstream:
                // Retain the ability to continue the original partial reply
                // after fixing a later attempt's credential or model.
                return (attempts?.count ?? 0) > 1
            default: return false
            }
        default: return false
        }
    }

    mutating func finishAttempt(commitPending: Bool = false) {
        if commitPending, let pendingContinuation {
            text += pendingContinuation
        }
        self.pendingContinuation = nil
        guard let last = attempts?.indices.last, attempts?[last].status == .streaming else { return }
        attempts?[last].status = status
        attempts?[last].failure = failure
    }
}

/// Only a substantial full replay of the saved reply (or the clipped excerpt
/// sent to the model) can be removed. Never strip a partial tail match or
/// normalize the bytes of the saved reply.
struct ChatContinuationBoundary {
    private var targets: [String]
    private var confirmedOverlap: Int?

    init(base: String, sentExcerpt: String? = nil) {
        var candidates: [String] = []
        for candidate in [base, sentExcerpt].compactMap({ $0 }) {
            if Self.isSubstantial(candidate), !candidates.contains(candidate) {
                candidates.append(candidate)
            }
        }
        targets = candidates
    }

    private static func isSubstantial(_ text: String) -> Bool {
        text.utf8.count >= 16
            && text.lazy.filter({ $0.isLetter || $0.isNumber }).prefix(6).count == 6
    }

    /// The second value is the literal text held back while the opening bytes
    /// are still a prefix of the replay target.
    mutating func suffix(for snapshot: String) -> (visible: String, pending: String?) {
        guard !snapshot.isEmpty else { return ("", nil) }
        if let confirmedOverlap { return (dropping(confirmedOverlap, from: snapshot), nil) }
        if !targets.isEmpty {
            if let matched = targets.first(where: { snapshot.utf8.starts(with: $0.utf8) }) {
                confirmedOverlap = matched.utf8.count
                return (dropping(matched.utf8.count, from: snapshot), nil)
            }
            let matchingPrefixes = targets.filter { $0.utf8.starts(with: snapshot.utf8) }
            if !matchingPrefixes.isEmpty {
                targets = matchingPrefixes
                return ("", snapshot)
            }
            targets = []
        }
        confirmedOverlap = 0
        return (snapshot, nil)
    }

    private func dropping(_ count: Int, from text: String) -> String {
        count == 0 ? text : String(decoding: text.utf8.dropFirst(count), as: UTF8.self)
    }
}

extension ChatPromptBuilder {
    /// Pin the triggering turn before taking whole older turns. In particular
    /// boundedHistory must never evict a long unfinished assistant response.
    static func continuationContext(earlier: [ChatMessage], question: ChatMessage, reply: ChatMessage,
                                    effectivePrompt: String, budget: Int = historyTextBudget)
        -> (history: [ChatMessage], prompt: String, images: [ChatImageAttachment], omitted: Int) {
        let remaining = max(0, budget - effectivePrompt.count)
        let retry = reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Give the unfinished tail its own minimum even for oversized questions.
        let limit = max(1024, remaining)
        var partial = reply
        var fenceHint = ""
        if !retry, reply.text.count > limit {
            let head = limit / 4
            let marker = "\n[…中间内容已省略…]\n"
            let tail = reply.text.suffix(limit - head - marker.count)
            partial.text = String(reply.text.prefix(head)) + marker + tail
            if let language = openFence(in: reply.text[..<tail.startIndex]) {
                fenceHint = " 已保留的末尾片段起始于代码块内部（\(language)）。"
            }
        }
        let prior = boundedHistory(earlier, textBudget: max(0, remaining - (retry ? 0 : partial.text.count)),
                                   imageMessageLimit: historyImageMessageLimit - (question.attachments.isEmpty ? 0 : 1))
        if retry { return (prior.messages, effectivePrompt, question.attachments, prior.omittedCount) }
        var original = question
        original.text = effectivePrompt
        let instruction = "从上一条助手回复的末尾直接接写，只输出后续内容。沿用原语言、列表、缩进和未闭合的代码围栏，不要重述已有内容。"
        return (prior.messages + [original, partial], instruction + fenceHint, [], prior.omittedCount)
    }
}

/// Only a hint for the model when a long response was clipped mid-fence.
/// The actual Markdown displayed and saved is always the original.
private func openFence(in prefix: Substring) -> String? {
    var open: (marker: Character, width: Int, language: String)?
    prefix.enumerateLines { line, _ in
        let content = line.drop(while: { $0 == " " })
        guard line.count - content.count <= 3, let marker = content.first,
              marker == "`" || marker == "~" else { return }
        let width = content.prefix(while: { $0 == marker }).count
        guard width >= 3 else { return }
        let info = content.dropFirst(width).trimmingCharacters(in: .whitespaces)
        if let current = open {
            if marker == current.marker, width >= current.width, info.isEmpty { open = nil }
        } else {
            let language = info.prefix(while: { $0.isLetter || $0.isNumber || "+#-_".contains($0) }).prefix(32)
            open = (marker, width, language.isEmpty ? "未标注语言" : String(language))
        }
    }
    return open?.language
}
