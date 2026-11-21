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

    private var isGenerating: Bool { chat.isGenerating(conversation.id) }

    private var isCredentialReady: Bool {
        if case .ready = chat.credentialState { return true }
        return false
    }

    private var canSend: Bool {
        guard isCredentialReady, conversation.modelID != nil, !isGenerating, !isLoadingAttachments else { return false }
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return editingMessageID == nil ? hasText || !attachments.isEmpty : hasText
    }

    var body: some View {
        let palette = BrandPalette(colorScheme: colorScheme, contrast: contrast)
        VStack(alignment: .leading, spacing: 8) {
            if !isCredentialReady {
                blockedNotice(palette)
            } else if conversation.modelID == nil {
                Label(modelMissingText, systemImage: "cpu")
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

            let suggestions = chat.skillSuggestions(for: draft)
            if !suggestions.isEmpty {
                skillSuggestions(suggestions, palette: palette)
            }

            if !attachments.isEmpty {
                ChatAttachmentStrip(attachments: attachments) { id in
                    attachments.removeAll { $0.id == id }
                }
            }

            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    field(palette)
                    HStack(spacing: 8) {
                        accessoryButtons(palette)
                        Spacer(minLength: 0)
                        sendButton(palette)
                    }
                }
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    accessoryButtons(palette)
                    field(palette)
                    sendButton(palette)
                }
            }
        }
        .padding(12)
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
        default: "请先在顶部选择模型"
        }
    }

    private func field(_ palette: BrandPalette) -> some View {
        TextField(editingMessageID == nil ? "输入消息，/ 使用技能" : "修改消息", text: $draft, axis: .vertical)
            .lineLimit(1...6)
            .font(.body)
            .foregroundStyle(palette.textPrimary)
            .focused($isFocused)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .accessibilityIdentifier("chat.input")
    }

    @ViewBuilder
    private func accessoryButtons(_ palette: BrandPalette) -> some View {
        #if canImport(PhotosUI)
        PhotosPicker(selection: $pickerItems, maxSelectionCount: 4, matching: .images) {
            Image(systemName: isLoadingAttachments ? "hourglass" : "photo.on.rectangle")
                .font(.title3)
                .frame(width: 44, height: 44)
        }
        .disabled(editingMessageID != nil || isGenerating || attachments.count >= 4)
        .accessibilityLabel("添加图片")
        .accessibilityIdentifier("chat.attach")
        #endif
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

    @ViewBuilder
    private func sendButton(_ palette: BrandPalette) -> some View {
        if isGenerating {
            Button {
                chat.stop(conversation.id)
            } label: {
                Image(systemName: "stop.fill")
                    .font(.headline)
                    .frame(width: 44, height: 44)
            }
            .modifier(ChatRoundButtonStyle(prominent: false))
            .accessibilityLabel("停止生成")
            .accessibilityIdentifier("chat.stop")
        } else {
            Button(action: onSubmit) {
                Image(systemName: editingMessageID == nil ? "arrow.up" : "checkmark")
                    .font(.headline.weight(.bold))
                    .frame(width: 44, height: 44)
            }
            .modifier(ChatRoundButtonStyle(prominent: true))
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

private struct ChatRoundButtonStyle: ViewModifier {
    let prominent: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder
    func body(content: Content) -> some View {
        let palette = BrandPalette(colorScheme: colorScheme, contrast: contrast)
        if #available(iOS 26.0, macOS 26.0, *) {
            if prominent {
                content
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .tint(palette.accent)
                    .foregroundStyle(palette.textOnAccent)
            } else {
                content
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
            }
        } else {
            // Same fallback as the primary button style: a readable foreground
            // on a bordered control instead of white on the light accent.
            content
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .tint(prominent ? palette.actionTint : palette.textSecondary)
                .foregroundStyle(palette.textPrimary)
        }
    }
}
#endif
