import Foundation
import CPAQuotaKit

/// Pure prompt assembly: instructions sections, slash-skill application, and
/// web-search injection. No I/O; everything is unit-testable.
public enum ChatPromptBuilder {
    /// Sections in order, empty sections omitted, joined by a blank line:
    /// date, global instructions, pinned memories (only when enabled),
    /// then the conversation's own system prompt.
    public static func instructions(
        settings: ChatSettings,
        memories: [ChatMemoryItem],
        conversation: ChatConversation,
        now: Date = Date()
    ) -> String {
        var sections: [String] = []
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        sections.append("当前日期：\(formatter.string(from: now))")

        let global = settings.globalInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !global.isEmpty {
            sections.append("[全局规则]\n\(global)")
        }

        if settings.isMemoryEnabled, !memories.isEmpty {
            let ordered = memories.sorted {
                ($0.isPinned ? 0 : 1, $0.createdAt) < ($1.isPinned ? 0 : 1, $1.createdAt)
            }
            let lines = ordered.map { "- \($0.text)" }.joined(separator: "\n")
            sections.append("[关于用户的记忆]\n\(lines)")
        }

        let system = conversation.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty {
            sections.append("[本对话设定]\n\(system)")
        }

        return sections.joined(separator: "\n\n")
    }

    /// When `text` is `/{command}` followed by whitespace or end, and a skill's
    /// normalized command matches case-insensitively, the model prompt becomes
    /// `{skill.prompt}\n\n{rest}`. The displayed message keeps the original text.
    public static func applySkill(
        to text: String,
        skills: [ChatSkill]
    ) -> (modelPrompt: String, skill: ChatSkill?, rest: String) {
        guard text.hasPrefix("/") else { return (text, nil, text) }
        let body = text.dropFirst()
        let commandEnd = body.firstIndex(where: { $0.isWhitespace }) ?? body.endIndex
        let command = String(body[..<commandEnd])
        guard !command.isEmpty else { return (text, nil, text) }
        let rest = String(body[commandEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let skill = skills.first(where: {
            normalizedCommand($0.command).caseInsensitiveCompare(command) == .orderedSame
        }) else {
            return (text, nil, text)
        }
        return (skill.prompt + "\n\n" + rest, skill, rest)
    }

    /// Search results prepended to the prompt with numbered source markers.
    public static func searchInjectedPrompt(_ prompt: String, sources: [ChatSearchSource]) -> String {
        guard !sources.isEmpty else { return prompt }
        var text = "以下是联网搜索结果，可在回答中引用并用 [编号] 标注来源：\n"
        for (index, source) in sources.enumerated() {
            text += "[\(index + 1)] \(source.title)\n\(source.url.absoluteString)\n\(source.snippet)\n"
        }
        text += "\n用户问题：\(prompt)"
        return text
    }

    /// `/命令 ` and `Command` normalize to `command`: trimmed, no leading `/`,
    /// lowercased, whitespace removed.
    public static func normalizedCommand(_ command: String) -> String {
        var value = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasPrefix("/") { value.removeFirst() }
        value.removeAll(where: { $0.isWhitespace })
        return value
    }
}
