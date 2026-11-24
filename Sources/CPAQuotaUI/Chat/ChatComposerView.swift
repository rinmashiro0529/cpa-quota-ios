#if canImport(SwiftUI)
import SwiftUI
import CPAQuotaKit
import CPAQuotaChat
#if canImport(PhotosUI)
import PhotosUI
#endif
#if os(iOS)
import UIKit
#endif

/// The composer is a control, so it sits on Liquid Glass (iOS 26+) rather than an opaque content surface.
struct ChatComposerView: View {
    let chat: ChatWorkspaceModel
    let conversation: ChatConversation
    @Binding var draft: String
    @Binding var attachments: [ChatImageAttachment]
    @Binding var editingMessageID: UUID?
    let onOpenSettings: () -> Void
    let onCancelEdit: () -> Void
    let onContinue: (ChatContinuation) -> Void
    let onSubmit: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var isFocused: Bool
    #if canImport(PhotosUI)
    @State private var pickerItems: [PhotosPickerItem] = []
    #endif
    @State private var isLoadingAttachments = false
    @State private var isSearchKeyMissing = false
    @State private var continuationCooldown = false
    @State private var cooldownTask: Task<Void, Never>?

    private var isGenerating: Bool { chat.isGenerating(conversation.id) }

    private var isCredentialReady: Bool {
        if case .ready = chat.credentialState { return true }
        return false
    }

    private var canSend: Bool {
        guard isCredentialReady, chat.isAvailableModel(conversation.modelID), !isGenerating, !isLoadingAttachments else { return false }
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return editingMessageID == nil ? hasText || !attachments.isEmpty : hasText
    }

    private var continuation: ChatContinuation? {
        guard draft.isEmpty, attachments.isEmpty, editingMessageID == nil, !isLoadingAttachments else { return nil }
        #if canImport(PhotosUI)
        guard pickerItems.isEmpty else { return nil }
        #endif
        return chat.continuation(for: conversation.id)
    }

    var body: some View {
        let palette = BrandPalette(colorScheme: colorScheme, contrast: contrast)
        VStack(alignment: .leading, spacing: 8) {
            if !isCredentialReady {
                blockedNotice(palette)
            } else if !chat.isAvailableModel(conversation.modelID) {
                Label(modelMissingText, systemImage: "cpu")
                    .font(.footnote)
                    .foregroundStyle(palette.textSecondary)
            } else if conversation.messages.isEmpty, chat.preferredModelUnavailable {
                Text("首选模型已不在当前目录中，本次暂用可用模型。")
                    .font(.footnote)
                    .foregroundStyle(palette.textSecondary)
            }

            if conversation.isWebSearchEnabled, chat.settings.searchProvider == nil || isSearchKeyMissing {
                HStack(spacing: 8) {
                    Label("联网搜索未就绪：还没有可用的搜索服务或搜索 API Key，发送后不会检索。", systemImage: "globe")
                        .font(.footnote)
                        .foregroundStyle(palette.textSecondary)
                    Spacer(minLength: 8)
                    Button("设置", action: onOpenSettings)
                        .font(.footnote.weight(.semibold))
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("chat.searchUnavailable")
            }

            if editingMessageID != nil {
                HStack {
                    Label("正在编辑消息，发送后将替换原消息并重新生成", systemImage: "pencil")
                        .font(.footnote)
                        .foregroundStyle(palette.textSecondary)
                    Spacer(minLength: 8)
                    Button("取消", action: onCancelEdit)
                    .font(.footnote)
                    .frame(minHeight: 44)
                }
            }

            if let continuation {
                Text(continuation.isRetry ? "重试将重新发起请求，可能产生额外用量。" : "续写将根据已有内容发起新请求，可能产生额外用量。")
                    .font(.footnote)
                    .foregroundStyle(palette.textSecondary)
            }

            let suggestions = chat.skillSuggestions(for: draft)
            if !suggestions.isEmpty {
                skillSuggestions(suggestions, palette: palette)
            }

            if !attachments.isEmpty {
                ChatAttachmentStrip(attachments: attachments) { id in
                    attachments.removeAll { $0.id == id }
                }
            }

            ChatComposerLayout(prefersStackedRows: dynamicTypeSize.isAccessibilitySize) {
                field(palette)
                HStack(spacing: 4) {
                    accessoryButtons(palette)
                    reasoningButton
                }
                sendButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .modifier(ChatComposerSurface())
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        #if canImport(PhotosUI)
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await loadAttachments(items) }
        }
        #endif
        .onChange(of: editingMessageID) { _, id in
            if id != nil { isFocused = true }
        }
        .onChange(of: isGenerating) { wasGenerating, nowGenerating in
            cooldownTask?.cancel()
            if wasGenerating, !nowGenerating {
                // Brief lockout after stop/completion prevents an accidental double-tap
                // on the stop button slot from immediately firing a billable continuation.
                continuationCooldown = true
                cooldownTask = Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    continuationCooldown = false
                }
            } else {
                continuationCooldown = false
            }
        }
        .onDisappear {
            cooldownTask?.cancel()
            continuationCooldown = false
        }
        .task(id: "\(chat.settings.searchProvider?.rawValue ?? "-")|\(conversation.isWebSearchEnabled)") {
            guard conversation.isWebSearchEnabled, let provider = chat.settings.searchProvider else {
                isSearchKeyMissing = false
                return
            }
            isSearchKeyMissing = !(await chat.hasSearchKey(for: provider))
        }
    }

    private var modelMissingText: String {
        switch chat.modelListState {
        case .loading: "正在读取模型列表"
        case .failed(let failure): "模型列表读取失败：\(ChatFailurePresentation(failure).title)"
        case .loaded where chat.models.isEmpty: "CPA 没有返回可用模型"
        case .loaded where conversation.modelID != nil: "原模型已不可用，请在顶部重新选择"
        case .idle: "模型目录尚未读取，可在顶部菜单刷新"
        default: "请先在顶部选择模型"
        }
    }

    private func field(_ palette: BrandPalette) -> some View {
        TextField(editingMessageID == nil ? "输入消息，/ 使用技能" : "修改消息", text: $draft, axis: .vertical)
            .lineLimit(1...6)
            .font(.body)
            .foregroundStyle(palette.textPrimary)
            .focused($isFocused)
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .accessibilityIdentifier("chat.input")
    }

    @ViewBuilder
    private func accessoryButtons(_ palette: BrandPalette) -> some View {
        #if canImport(PhotosUI)
        #if DEBUG && os(iOS)
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
           ProcessInfo.processInfo.arguments.contains("--ui-test-chat-image") {
            Button("添加测试图片") {
                let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
                let data = renderer.pngData { context in
                    UIColor.blue.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
                }
                attachments.append(ChatImageAttachment(mimeType: "image/png", data: data))
            }
            .accessibilityIdentifier("chat.attach")
        } else {
            photoPicker
        }
        #else
        photoPicker
        #endif
        #endif
        searchButton(palette)
    }

    #if canImport(PhotosUI)
    private var photoPicker: some View {
        PhotosPicker(selection: $pickerItems, maxSelectionCount: 4, matching: .images) {
            Image(systemName: isLoadingAttachments ? "hourglass" : "photo.on.rectangle")
                .font(.title3)
                .frame(width: 44, height: 44)
        }
        .disabled(editingMessageID != nil || isGenerating || attachments.count >= 4)
        .accessibilityLabel("添加图片")
        .accessibilityIdentifier("chat.attach")
    }
    #endif

    private func searchButton(_ palette: BrandPalette) -> some View {
        Button {
            chat.updateConversation(conversation.id) { $0.isWebSearchEnabled.toggle() }
        } label: {
            Image(systemName: conversation.isWebSearchEnabled ? "globe.badge.chevron.backward" : "globe")
                .font(.title3)
                .foregroundStyle(conversation.isWebSearchEnabled ? palette.actionTint : palette.textSecondary)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        // Still allow switching it off after the search service was removed.
        .disabled(chat.settings.searchProvider == nil && !conversation.isWebSearchEnabled)
        .accessibilityLabel(chat.settings.searchProvider == nil ? "联网搜索（未设置搜索服务）" : "联网搜索")
        .accessibilityValue(conversation.isWebSearchEnabled ? "已开启" : "已关闭")
        .accessibilityIdentifier("chat.webSearch")
    }

    private var reasoningButton: some View {
        ChatReasoningTriggerButton(effort: conversation.reasoningEffort) { effort in
            chat.selectReasoningEffort(effort, in: conversation.id)
        }
    }

    @ViewBuilder
    private var sendButton: some View {
        if isGenerating {
            Button {
                chat.stop(conversation.id)
            } label: {
                Image(systemName: "stop.fill")
                    .font(.headline)
            }
            .buttonStyle(ChatRoundButtonStyle(prominent: false))
            .accessibilityLabel("停止生成")
            .accessibilityIdentifier("chat.stop")
        } else if let target = continuation {
            Button {
                guard !continuationCooldown, continuation == target else { return }
                onContinue(target)
            } label: {
                Image(systemName: target.isRetry ? "arrow.clockwise" : "arrow.up.right")
                    .font(.headline.weight(.bold))
            }
            .buttonStyle(ChatRoundButtonStyle(prominent: true))
            .disabled(continuationCooldown)
            .accessibilityLabel(target.isRetry ? "重试生成回复" : "续写上一条回复")
            .accessibilityHint("发起一次新的生成请求，可能产生额外用量")
            .accessibilityIdentifier(target.isRetry ? "chat.retry" : "chat.continue")
        } else {
            Button(action: onSubmit) {
                Image(systemName: editingMessageID == nil ? "arrow.up" : "checkmark")
                    .font(.headline.weight(.bold))
            }
            .buttonStyle(ChatRoundButtonStyle(prominent: true))
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel(editingMessageID == nil ? "发送" : "发送修改")
            .accessibilityIdentifier("chat.send")
        }
    }

    private func skillSuggestions(_ skills: [ChatSkill], palette: BrandPalette) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(skills) { skill in
                    Button {
                        draft = "/\(skill.command) "
                    } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("/\(skill.command)")
                                .font(.subheadline.monospaced().weight(.semibold))
                                .foregroundStyle(palette.textPrimary)
                            Text(skill.title)
                                .font(.caption)
                                .foregroundStyle(palette.textSecondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(minHeight: 44)
                        .background(palette.insetSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat.skill.\(skill.command)")
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    private func blockedNotice(_ palette: BrandPalette) -> some View {
        HStack(spacing: 8) {
            Label(blockedText, systemImage: "key.slash")
                .font(.footnote)
                .foregroundStyle(palette.textSecondary)
            Spacer(minLength: 8)
            Button("设置", action: onOpenSettings)
                .font(.footnote.weight(.semibold))
                .frame(minHeight: 44)
        }
    }

    private var blockedText: String {
        switch chat.credentialState {
        case .unbound: "尚未连接 CPA 服务"
        case .loading: "正在读取 API Key"
        case .missingKey: "请先选择或填写 API Key"
        case .failed: "API Key 读取失败"
        case .ready: ""
        }
    }

    #if canImport(PhotosUI)
    private func loadAttachments(_ items: [PhotosPickerItem]) async {
        isLoadingAttachments = true
        defer {
            isLoadingAttachments = false
            pickerItems = []
        }
        for item in items {
            guard attachments.count < 4,
                  let data = try? await item.loadTransferable(type: Data.self),
                  let attachment = ChatImageEncoder.attachment(from: data) else { continue }
            attachments.append(attachment)
        }
    }
    #endif
}

/// Keep the field and buttons mounted when the keyboard or available width changes.
private struct ChatComposerLayout: Layout {
    let prefersStackedRows: Bool

    private let spacing: CGFloat = 4
    private let minimumFieldWidth: CGFloat = 140

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        metrics(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let row = metrics(width: bounds.width, subviews: subviews)
        let fieldX = bounds.minX + (row.stacked ? 0 : row.controls.width + spacing)
        let fieldY = row.stacked ? bounds.minY : bounds.maxY - row.fieldHeight
        subviews[0].place(at: CGPoint(x: fieldX, y: fieldY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: row.fieldWidth, height: nil))
        let controlsCenterY = bounds.maxY - max(row.controls.height, row.send.height) / 2
        subviews[1].place(at: CGPoint(x: bounds.minX, y: controlsCenterY),
                          anchor: .leading, proposal: .unspecified)
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: controlsCenterY),
                          anchor: .trailing, proposal: .unspecified)
    }

    private func metrics(width: CGFloat?, subviews: Subviews) -> (
        size: CGSize, fieldWidth: CGFloat, fieldHeight: CGFloat, controls: CGSize, send: CGSize, stacked: Bool
    ) {
        let controls = subviews[1].sizeThatFits(.unspecified)
        let send = subviews[2].sizeThatFits(.unspecified)
        let buttonsWidth = controls.width + send.width + 2 * spacing
        let width = width ?? buttonsWidth + minimumFieldWidth
        let stacked = prefersStackedRows || width - buttonsWidth < minimumFieldWidth
        let fieldWidth = stacked ? width : width - buttonsWidth
        let fieldHeight = subviews[0].sizeThatFits(ProposedViewSize(width: fieldWidth, height: nil)).height
        let buttonsHeight = max(controls.height, send.height)
        let height = stacked ? fieldHeight + spacing + buttonsHeight : max(fieldHeight, buttonsHeight)
        return (CGSize(width: width, height: height), fieldWidth, fieldHeight, controls, send, stacked)
    }
}

/// Images are downscaled and re-encoded before they are stored or sent.
enum ChatImageEncoder {
    static let maximumPixelLength: CGFloat = 1536

    static func attachment(from data: Data) -> ChatImageAttachment? {
        #if os(iOS)
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width * image.scale, image.size.height * image.scale)
        let ratio = min(1, maximumPixelLength / max(longest, 1))
        let target = CGSize(width: image.size.width * image.scale * ratio,
                            height: image.size.height * image.scale * ratio)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let jpeg = rendered.jpegData(compressionQuality: 0.8) else { return nil }
        return ChatImageAttachment(mimeType: "image/jpeg", data: jpeg)
        #else
        // ponytail: other platforms pass the original bytes; only iOS ships the chat UI.
        return data.count <= 8_000_000 ? ChatImageAttachment(mimeType: "image/jpeg", data: data) : nil
        #endif
    }
}

private struct ChatComposerSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            let palette = BrandPalette(colorScheme: colorScheme, contrast: contrast)
            content
                .background(.regularMaterial, in: shape)
                .overlay {
                    shape.strokeBorder(palette.trackBackground, lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
        }
    }
}

private struct ChatRoundButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let palette = BrandPalette(colorScheme: colorScheme, contrast: contrast)
        let isProminent = prominent && isEnabled
        configuration.label
            .foregroundStyle(isProminent ? palette.textOnAccent : palette.textPrimary)
            .frame(width: 36, height: 36)
            .background {
                if #available(iOS 26.0, macOS 26.0, *) {
                    let glass = isProminent ? Glass.regular.tint(palette.accent) : Glass.regular
                    // Keep the glass decorative so the button owns the press as its enabled state changes.
                    Circle().fill(.clear)
                        .glassEffect(glass, in: Circle())
                        .allowsHitTesting(false)
                } else {
                    Circle().fill(isProminent ? palette.accent : palette.insetSurface)
                        .allowsHitTesting(false)
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.55)
            // Match the composer row's hit area without increasing the visible circle.
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}
#endif
