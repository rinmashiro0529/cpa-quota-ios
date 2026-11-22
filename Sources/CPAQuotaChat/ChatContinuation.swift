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
            case .network, .timeout, .streamInterrupted: return true
            case .unauthorized, .forbidden, .modelUnavailable, .rateLimited, .upstream:
                // Retain the ability to continue the original partial reply
                // after fixing a later attempt's credential or model.
                return (attempts?.count ?? 0) > 1
            default: return false
            }
        default: return false
        }
    }

    mutating func finishAttempt() {
        if let pendingContinuation {
            text += pendingContinuation
            self.pendingContinuation = nil
        }
        guard let last = attempts?.indices.last else { return }
        attempts?[last].status = status
        attempts?[last].failure = failure
    }
}

/// Only the boundary of the new request can be removed. Never normalize
/// Markdown, whitespace, or the bytes of the saved reply.
struct ChatContinuationBoundary {
    private let tail: [UInt8]
    private var fullReply: String?
    private var confirmedOverlap: Int?

    init(base: String) {
        tail = Array(base.utf8.suffix(1024))
        fullReply = base.utf8.count > tail.count ? base : nil
    }

    /// The second value is the literal text to preserve if the stream ends
    /// (or the process dies) before we can disambiguate the opening bytes.
    mutating func suffix(for snapshot: String) -> (visible: String, pending: String?) {
        guard !snapshot.isEmpty else { return ("", nil) }
        if let confirmedOverlap { return (dropping(confirmedOverlap, from: snapshot), nil) }
        if let fullReply {
            if snapshot.utf8.starts(with: fullReply.utf8) {
                confirmedOverlap = fullReply.utf8.count
                return (dropping(fullReply.utf8.count, from: snapshot), nil)
            }
            if fullReply.utf8.starts(with: snapshot.utf8) { return ("", snapshot) }
            self.fullReply = nil
        }
        let prefix = Array(snapshot.utf8.prefix(tail.count))
        var possibleLongerMatch = false
        var overlap = 0
        for start in tail.indices {
            let candidate = tail[start...]
            // Short words, indentation and fence delimiters are commonly
            // intentional repetitions. Only discard substantial exact text.
            guard candidate.count >= 16, tail[start] & 0xc0 != 0x80,
                  candidate.prefix(prefix.count).elementsEqual(prefix.prefix(candidate.count))
            else { continue }
            let literal = String(decoding: candidate, as: UTF8.self)
            guard literal.lazy.filter({ $0.isLetter || $0.isNumber }).prefix(6).count == 6 else { continue }
            if candidate.count > prefix.count {
                possibleLongerMatch = true
            } else {
                overlap = candidate.count
                break
            }
        }
        let suffix = dropping(overlap, from: snapshot)
        if possibleLongerMatch { return ("", suffix) }
        confirmedOverlap = overlap
        return (suffix, nil)
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
