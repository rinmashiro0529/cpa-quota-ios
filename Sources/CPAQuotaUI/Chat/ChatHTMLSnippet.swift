import Foundation
import Markdown

struct ChatHTMLSnippet: Identifiable, Equatable, Sendable {
    let id: Int
    let source: String

    static func extract(from text: String) -> [Self] {
        guard text.localizedCaseInsensitiveContains("html"),
              text.contains("~~~") || text.contains("```") else { return [] }

        // CommonMark gives an unterminated fence a CodeBlock too. Check its
        // source range and literal line count before offering a streaming preview.
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        var walker = CodeBlocks()
        walker.visit(Document(parsing: text))
        let starts = Set(walker.blocks.compactMap { $0.range?.lowerBound.line })
        var snippets: [Self] = []
        for block in walker.blocks where block.language?.lowercased() == "html" {
            guard let range = block.range else { continue }
            let first = range.lowerBound.line
            let last = range.upperBound.line
            guard first > 0, last <= lines.count, last > first, !starts.contains(last),
                  block.code.utf8.reduce(0, { $0 + ($1 == 10 ? 1 : 0) }) == last - first - 1 else { continue }
            let opening = lines[first - 1].utf8.dropFirst(range.lowerBound.column - 1)
            guard let marker = opening.first, marker == 96 || marker == 126 else { continue }
            let width = opening.prefix(while: { $0 == marker }).count
            let closing = lines[last - 1].utf8.drop(while: { $0 == 32 || $0 == 9 || $0 == 62 })
            let run = closing.prefix(while: { $0 == marker }).count
            guard width >= 3, run >= width, closing.dropFirst(run).allSatisfy({ $0 == 32 || $0 == 9 })
            else { continue }
            snippets.append(Self(id: snippets.count + 1, source: block.code))
        }
        return snippets
    }

    private struct CodeBlocks: MarkupWalker {
        var blocks: [CodeBlock] = []
        mutating func visitCodeBlock(_ block: CodeBlock) { blocks.append(block) }
    }
}
