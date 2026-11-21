import Foundation
import Testing
@testable import CPAQuotaChat
@testable import CPAQuotaKit

@Suite("ChatPromptBuilder")
struct ChatPromptBuilderTests {
    private let day = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14

    @Test func ordersSectionsAndAlwaysIncludesDate() {
        var conversation = ChatConversation()
        conversation.systemPrompt = "只回答技术问题"
        let settings = ChatSettings(globalInstructions: "保持简洁", isMemoryEnabled: true)
        let memories = [
            ChatMemoryItem(text: "普通记忆", isPinned: false,
                           createdAt: Date(timeIntervalSince1970: 2)),
            ChatMemoryItem(text: "置顶记忆", isPinned: true,
                           createdAt: Date(timeIntervalSince1970: 3)),
        ]
        let instructions = ChatPromptBuilder.instructions(
            settings: settings, memories: memories, conversation: conversation, now: day)

        #expect(instructions.contains("当前日期：2023-11-14"))
        #expect(instructions.contains("[全局规则]\n保持简洁"))
        #expect(instructions.contains("[关于用户的记忆]"))
        #expect(instructions.contains("[本对话设定]\n只回答技术问题"))

        let dateIndex = instructions.range(of: "当前日期")!.lowerBound
        let globalIndex = instructions.range(of: "[全局规则]")!.lowerBound
        let memoryIndex = instructions.range(of: "[关于用户的记忆]")!.lowerBound
        let systemIndex = instructions.range(of: "[本对话设定]")!.lowerBound
        #expect(dateIndex < globalIndex)
        #expect(globalIndex < memoryIndex)
        #expect(memoryIndex < systemIndex)
    }

    @Test func pinnedMemoryComesFirst() {
        let settings = ChatSettings(isMemoryEnabled: true)
        let memories = [
            ChatMemoryItem(text: "普通较旧", isPinned: false,
                           createdAt: Date(timeIntervalSince1970: 1)),
            ChatMemoryItem(text: "置顶较新", isPinned: true,
                           createdAt: Date(timeIntervalSince1970: 9)),
            ChatMemoryItem(text: "普通较新", isPinned: false,
                           createdAt: Date(timeIntervalSince1970: 5)),
        ]
        let instructions = ChatPromptBuilder.instructions(
            settings: settings, memories: memories, conversation: ChatConversation(), now: day)
        #expect(instructions.contains("- 置顶较新\n- 普通较旧\n- 普通较新"))
    }

    @Test func omitsEmptySections() {
        let settings = ChatSettings(globalInstructions: "", isMemoryEnabled: true)
        let instructions = ChatPromptBuilder.instructions(
            settings: settings, memories: [], conversation: ChatConversation(), now: day)
        #expect(!instructions.contains("[全局规则]"))
        #expect(!instructions.contains("[关于用户的记忆]"))
        #expect(!instructions.contains("[本对话设定]"))
    }

    @Test func memoryDisabledOmitsMemorySection() {
        let settings = ChatSettings(isMemoryEnabled: false)
        let instructions = ChatPromptBuilder.instructions(
            settings: settings,
            memories: [ChatMemoryItem(text: "不该出现")],
            conversation: ChatConversation(), now: day)
        #expect(!instructions.contains("[关于用户的记忆]"))
        #expect(!instructions.contains("不该出现"))
    }

    @Test func appliesSkillToModelPromptKeepingRest() {
        let skill = ChatSkill(command: "translate", title: "翻译", prompt: "翻译以下内容。")
        let (modelPrompt, matched, rest) = ChatPromptBuilder.applySkill(
            to: "/Translate 你好世界", skills: [skill])
        #expect(matched?.id == skill.id)
        #expect(modelPrompt == "翻译以下内容。\n\n你好世界")
        #expect(rest == "你好世界")
    }

    @Test func noSkillLeavesTextUntouched() {
        let (modelPrompt, matched, _) = ChatPromptBuilder.applySkill(
            to: "/unknown 你好", skills: [ChatSkill(command: "translate", title: "t", prompt: "p")])
        #expect(matched == nil)
        #expect(modelPrompt == "/unknown 你好")

        let (plain, matched2, _) = ChatPromptBuilder.applySkill(to: "没有命令", skills: [])
        #expect(matched2 == nil)
        #expect(plain == "没有命令")
    }

    @Test func searchInjectionNumbersSources() {
        let sources = [
            ChatSearchSource(title: "结果一", url: URL(string: "https://a.example.com")!,
                             snippet: "摘要一"),
            ChatSearchSource(title: "结果二", url: URL(string: "https://b.example.com")!,
                             snippet: "摘要二"),
        ]
        let prompt = ChatPromptBuilder.searchInjectedPrompt("用户问题内容", sources: sources)
        #expect(prompt.hasPrefix("以下是联网搜索结果"))
        #expect(prompt.contains("[1] 结果一\nhttps://a.example.com\n摘要一"))
        #expect(prompt.contains("[2] 结果二\nhttps://b.example.com\n摘要二"))
        #expect(prompt.hasSuffix("用户问题：用户问题内容"))
    }
}

@Suite("ChatSkill")
@MainActor
struct ChatSkillTests {
    @Test func normalizedCommandStripsSlashCaseAndSpaces() {
        #expect(ChatPromptBuilder.normalizedCommand("Translate") == "translate")
        #expect(ChatPromptBuilder.normalizedCommand("/translate") == "translate")
        #expect(ChatPromptBuilder.normalizedCommand("  //TRAN SLATE  ") == "translate")
    }

    @Test func saveSkillNormalizesCommand() async {
        let workspace = ChatWorkspaceModel(
            persistence: ChatMemoryPersistence(), secrets: MemorySecretStore())
        await workspace.loadIfNeeded()
        let skill = ChatSkill(command: " /My Skill ", title: "自定义", prompt: "提示词")
        workspace.saveSkill(skill)
        #expect(workspace.skills.contains { $0.id == skill.id && $0.command == "myskill" })
    }

    @Test func defaultSkillsSeededOnFirstLoad() async {
        let workspace = ChatWorkspaceModel(
            persistence: ChatMemoryPersistence(), secrets: MemorySecretStore())
        await workspace.loadIfNeeded()
        let commands = workspace.skills.map(\.command)
        #expect(commands.contains("translate"))
        #expect(commands.contains("summarize"))
        #expect(commands.contains("polish"))
        #expect(commands.contains("explain"))
    }

    @Test func suggestionsMatchPrefixOfPartialCommand() async {
        let workspace = ChatWorkspaceModel(
            persistence: ChatMemoryPersistence(), secrets: MemorySecretStore())
        await workspace.loadIfNeeded()
        let hits = workspace.skillSuggestions(for: "/tra")
        #expect(hits.map(\.command) == ["translate"])
        #expect(workspace.skillSuggestions(for: "/").isEmpty)
        #expect(workspace.skillSuggestions(for: "/tra ").isEmpty)
        #expect(workspace.skillSuggestions(for: "no slash").isEmpty)
    }
}
