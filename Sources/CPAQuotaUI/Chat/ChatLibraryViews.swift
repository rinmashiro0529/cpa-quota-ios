#if canImport(SwiftUI)
import SwiftUI
import CPAQuotaKit
import CPAQuotaChat

/// Facts the user wants every conversation to know. Pinned items are sent first.
struct ChatMemoryListView: View {
    let chat: ChatWorkspaceModel
    @Environment(\.brandPalette) private var palette
    @State private var draft = ""

    private var orderedMemories: [ChatMemoryItem] {
        chat.memories.sorted { lhs, rhs in
            lhs.isPinned != rhs.isPinned ? lhs.isPinned : lhs.createdAt < rhs.createdAt
        }
    }

    var body: some View {
        List {
            if chat.memoriesLoadFailed || chat.unsavedMemories {
                Section {
                    if chat.memoriesLoadFailed {
                        ChatStorageWarningRow(
                            message: "记忆读取失败，请先重试读取以避免覆盖原有内容。",
                            retryTitle: "重试读取记忆",
                            retryAction: { await chat.retryLoadMetadata() }
                        )
                    }
                    if chat.unsavedMemories {
                        ChatStorageWarningRow(
                            message: "记忆更改未能保存到本机，重启后可能恢复旧内容。",
                            retryTitle: "重试保存记忆",
                            retryAction: { _ = await chat.retrySaveMemories() }
                        )
                    }
                }
                .listRowBackground(palette.contentSurface)
            }

            Section {
                TextField("例如：我主要使用 Swift 和 Go", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .accessibilityIdentifier("chat.memory.input")
                Button {
                    chat.addMemory(draft.trimmingCharacters(in: .whitespacesAndNewlines))
                    draft = ""
                } label: {
                    Label("添加记忆", systemImage: "plus.circle")
                        .frame(minHeight: 44)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } footer: {
                Text(chat.settings.isMemoryEnabled
                     ? "记忆会附加到每次对话的指令中。"
                     : "“使用记忆”当前已关闭，以下内容不会发送给模型。")
            }
            .listRowBackground(palette.contentSurface)

            if orderedMemories.isEmpty {
                ContentUnavailableView {
                    Label("暂无记忆", systemImage: "brain")
                } description: {
                    Text("也可以在对话中长按消息，选择“加入记忆”。")
                }
                .listRowBackground(palette.contentSurface)
            } else {
                Section("已保存") {
                    ForEach(orderedMemories) { item in
                        NavigationLink {
                            ChatMemoryEditorView(chat: chat, item: item)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                if item.isPinned {
                                    Image(systemName: "pin.fill")
                                        .foregroundStyle(palette.accent)
                                        .accessibilityLabel("已置顶")
                                }
                                Text(item.text)
                                    .foregroundStyle(palette.textPrimary)
                                    .lineLimit(3)
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                var updated = item
                                updated.isPinned.toggle()
                                chat.updateMemory(updated)
                            } label: {
                                Label(item.isPinned ? "取消置顶" : "置顶", systemImage: item.isPinned ? "pin.slash" : "pin")
                            }
                            .tint(palette.actionTint)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                chat.deleteMemory(item.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
                .listRowBackground(palette.contentSurface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(BrandCanvasBackground())
        .navigationTitle("记忆")
    }
}

struct ChatMemoryEditorView: View {
    let chat: ChatWorkspaceModel
    @State private var item: ChatMemoryItem
    @Environment(\.dismiss) private var dismiss
    @Environment(\.brandPalette) private var palette

    init(chat: ChatWorkspaceModel, item: ChatMemoryItem) {
        self.chat = chat
        _item = State(initialValue: item)
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $item.text)
                    .frame(minHeight: 160)
                Toggle("置顶", isOn: $item.isPinned)
            }
            .listRowBackground(palette.contentSurface)
            Section {
                Button(role: .destructive) {
                    chat.deleteMemory(item.id)
                    dismiss()
                } label: {
                    Label("删除这条记忆", systemImage: "trash")
                        .frame(minHeight: 44)
                }
            }
            .listRowBackground(palette.contentSurface)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(BrandCanvasBackground())
        .navigationTitle("编辑记忆")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    chat.updateMemory(item)
                    dismiss()
                }
                .disabled(item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

/// Slash commands that wrap the user's text with a saved prompt.
struct ChatSkillListView: View {
    let chat: ChatWorkspaceModel
    @Environment(\.brandPalette) private var palette

    var body: some View {
        List {
            if chat.skillsLoadFailed || chat.unsavedSkills {
                Section {
                    if chat.skillsLoadFailed {
                        ChatStorageWarningRow(
                            message: "技能读取失败，已保留磁盘原有文件，请重试读取。",
                            retryTitle: "重试读取技能",
                            retryAction: { await chat.retryLoadMetadata() }
                        )
                    }
                    if chat.unsavedSkills {
                        ChatStorageWarningRow(
                            message: "技能更改未能保存到本机，重启后可能恢复旧内容。",
                            retryTitle: "重试保存技能",
                            retryAction: { _ = await chat.retrySaveSkills() }
                        )
                    }
                }
                .listRowBackground(palette.contentSurface)
            }

            Section {
                ForEach(chat.skills) { skill in
                    NavigationLink {
                        ChatSkillEditorView(chat: chat, skill: skill, isNew: false)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("/\(skill.command)")
                                .font(QuotaTypography.dataDetail.weight(.semibold))
                                .foregroundStyle(palette.textPrimary)
                            Text(skill.title)
                                .font(.subheadline)
                                .foregroundStyle(palette.textSecondary)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            chat.deleteSkill(skill.id)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            } footer: {
                Text("在输入框键入 / 和命令名即可使用，例如“/translate 你好”。技能提示词会放在你的内容之前发送。")
            }
            .listRowBackground(palette.contentSurface)
        }
        .scrollContentBackground(.hidden)
        .background(BrandCanvasBackground())
        .navigationTitle("斜杠技能")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    ChatSkillEditorView(chat: chat, skill: ChatSkill(command: "", title: "", prompt: ""), isNew: true)
                } label: {
                    Label("新建技能", systemImage: "plus")
                }
                .accessibilityIdentifier("chat.skill.new")
            }
        }
    }
}

struct ChatSkillEditorView: View {
    let chat: ChatWorkspaceModel
    let isNew: Bool
    @State private var skill: ChatSkill
    @Environment(\.dismiss) private var dismiss
    @Environment(\.brandPalette) private var palette

    init(chat: ChatWorkspaceModel, skill: ChatSkill, isNew: Bool) {
        self.chat = chat
        self.isNew = isNew
        _skill = State(initialValue: skill)
    }

    private var hasConflictingCommand: Bool {
        chat.hasConflictingSkillCommand(skill.command, excluding: isNew ? nil : skill.id)
    }

    private var isValid: Bool {
        let command = skill.command.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return !command.isEmpty && !command.contains(where: \.isWhitespace)
            && !hasConflictingCommand
            && !skill.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section {
                TextField("命令，例如 translate", text: $skill.command)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .font(QuotaTypography.data)
                if hasConflictingCommand {
                    Label("已有相同命令的技能，请更换命令名。", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(palette.statusWarn)
                        .accessibilityIdentifier("chat.skill.duplicateWarning")
                }
                TextField("名称，例如 翻译", text: $skill.title)
            } header: {
                Text("命令")
            } footer: {
                Text("命令不含空格，保存时会转为小写。")
            }
            .listRowBackground(palette.contentSurface)
            Section("提示词") {
                TextEditor(text: $skill.prompt)
                    .frame(minHeight: 160)
            }
            .listRowBackground(palette.contentSurface)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(BrandCanvasBackground())
        .navigationTitle(isNew ? "新建技能" : "编辑技能")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    chat.saveSkill(skill)
                    dismiss()
                }
                .disabled(!isValid)
            }
        }
    }
}
#endif
