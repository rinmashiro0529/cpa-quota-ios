#if canImport(SwiftUI)
import SwiftUI
import CPAQuotaKit
import CPAQuotaChat
#if canImport(SwiftStreamingMarkdown)
import SwiftStreamingMarkdown
#endif
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct ChatMessageActions {
    let copy: () -> Void
    let previewHTML: (ChatHTMLSnippet) -> Void
    let regenerate: (() -> Void)?
    let edit: (() -> Void)?
    let remember: () -> Void
    let delete: () -> Void
}

struct ChatMessageView: View {
    let message: ChatMessage
    let isLatestAssistant: Bool
    let isConversationGenerating: Bool
    /// Regenerate needs a usable key and model; a disabled entry never truncates.
    let canRerun: Bool
    let actions: ChatMessageActions
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let palette = BrandPalette(colorScheme: colorScheme, contrast: contrast)
        Group {
            switch message.role {
            case .user:
                VStack(alignment: .trailing, spacing: 0) {
                    userBody(palette)
                    if let edit = actions.edit {
                        Button(action: edit) {
                            Label("编辑并重新发送", systemImage: "pencil")
                                .labelStyle(.iconOnly)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(palette.textSecondary)
                        .disabled(isConversationGenerating)
                        .accessibilityIdentifier("chat.edit")
                    }
                }
            case .assistant: assistantBody(palette)
            }
        }
        .contextMenu { menu }
    }

    // MARK: User

    private func userBody(_ palette: BrandPalette) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            if !message.attachments.isEmpty {
                ChatAttachmentStrip(attachments: message.attachments)
            }
            if !message.text.isEmpty {
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(palette.textPrimary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(palette.accentSoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 40)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(userAccessibilityLabel)
        .accessibilityIdentifier("chat.message.user")
    }

    private var userAccessibilityLabel: String {
        let images = message.attachments.isEmpty ? "" : "\(message.attachments.count) 张图片"
        switch (message.text.isEmpty, images.isEmpty) {
        case (false, false): return "我：\(message.text)，\(images)"
        case (true, false): return "我：\(images)"
        default: return "我：\(message.text)"
        }
    }

    // MARK: Assistant

    private func assistantBody(_ palette: BrandPalette) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(palette.accent)
                    .accessibilityHidden(true)
                Text(message.attempts?.last?.modelID ?? message.modelID ?? "助手")
                    .font(.caption.monospaced())
                    .foregroundStyle(palette.textMuted)
                    .lineLimit(1)
            }

            if let reasoning = message.reasoning, !reasoning.isEmpty {
                ChatReasoningView(reasoning: reasoning, isStreaming: message.status == .streaming && message.text.isEmpty)
            }

            if message.text.isEmpty, message.status == .streaming {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(message.reasoning?.isEmpty == false ? "正在思考" : "正在生成")
                        .font(.subheadline)
                        .foregroundStyle(palette.textSecondary)
                }
                .accessibilityElement(children: .combine)
            } else if !message.text.isEmpty {
                ChatMarkdownText(text: message.text)
                    .accessibilityIdentifier("chat.message.assistant")
                    .foregroundStyle(palette.textPrimary)
                #if os(iOS)
                // Earlier WebKit versions cannot veto the system file picker.
                if #available(iOS 18.4, *) {
                    ChatHTMLSnippetButtons(text: message.text, open: actions.previewHTML)
                }
                #endif
            }

            if !message.searchSources.isEmpty {
                ChatSourcesView(sources: message.searchSources)
            }

            statusFooter(palette)

            if message.status != .streaming {
                actionBar(palette)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func statusFooter(_ palette: BrandPalette) -> some View {
        if message.status == .stopped {
            Label("已停止生成", systemImage: "stop.circle")
                .font(.footnote)
                .foregroundStyle(palette.textSecondary)
        }
        if let failure = message.failure {
            ChatFailureNotice(failure: failure)
        }
        if let omitted = message.omittedHistoryCount, omitted > 0 {
            Label("较早的 \(omitted) 条消息未随本轮发送", systemImage: "text.badge.minus")
                .font(.footnote)
                .foregroundStyle(palette.textSecondary)
        }
        if let attempts = message.attempts, attempts.count > 1 {
            let unknown = attempts.contains { $0.usage == nil }
            Text("共 \(attempts.count) 次请求" + (unknown ? " · 含用量未返回的请求" : ""))
                .font(.caption)
                .foregroundStyle(palette.textMuted)
        }
        if let usage = message.usage, message.status != .streaming,
           usage.inputTokens + usage.outputTokens > 0 {
            Text(usageText(usage))
                .font(.caption.monospacedDigit())
                .foregroundStyle(palette.textMuted)
        }
    }

    private func usageText(_ usage: ChatTokenUsage) -> String {
        var parts = ["输入 \(usage.inputTokens)", "输出 \(usage.outputTokens)"]
        if usage.reasoningTokens > 0 { parts.append("推理 \(usage.reasoningTokens)") }
        return parts.joined(separator: " · ") + " Token"
    }

    private func actionBar(_ palette: BrandPalette) -> some View {
        HStack(spacing: 4) {
            if !message.text.isEmpty {
                Button(action: actions.copy) {
                    Label("复制", systemImage: "doc.on.doc")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
            }
            if let regenerate = actions.regenerate, isLatestAssistant, !isConversationGenerating {
                Button(action: regenerate) {
                    Label("重新生成", systemImage: "arrow.clockwise")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .disabled(!canRerun)
                .accessibilityIdentifier("chat.regenerate")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.subheadline)
        .foregroundStyle(palette.textSecondary)
        .frame(minHeight: 44)
    }

    // MARK: Menu

    @ViewBuilder
    private var menu: some View {
        if !message.text.isEmpty {
            Button(action: actions.copy) {
                Label("复制", systemImage: "doc.on.doc")
            }
        }
        if let edit = actions.edit, !isConversationGenerating {
            Button(action: edit) {
                Label("编辑并重新发送", systemImage: "pencil")
            }
        }
        if let regenerate = actions.regenerate, !isConversationGenerating {
            Button(action: regenerate) {
                Label("重新生成", systemImage: "arrow.clockwise")
            }
            .disabled(!canRerun)
        }
        if !message.text.isEmpty {
            Button(action: actions.remember) {
                Label("加入记忆", systemImage: "brain")
            }
        }
        if !isConversationGenerating {
            Divider()
            Button(role: .destructive, action: actions.delete) {
                Label("删除消息", systemImage: "trash")
            }
        }
    }
}

/// Collapsed by default once the answer starts, so long reasoning does not push the reply away.
struct ChatReasoningView: View {
    let reasoning: String
    let isStreaming: Bool
    @State private var isExpanded = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let palette = BrandPalette(colorScheme: colorScheme, contrast: contrast)
        DisclosureGroup(isExpanded: Binding(get: { isExpanded || isStreaming }, set: { isExpanded = $0 })) {
            Text(reasoning)
                .font(.subheadline)
                .foregroundStyle(palette.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Label(isStreaming ? "正在思考" : "思考过程", systemImage: "brain.head.profile")
                .font(.subheadline)
                .foregroundStyle(palette.textSecondary)
        }
        .padding(12)
        .background(palette.insetSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct ChatSourcesView: View {
    let sources: [ChatSearchSource]
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let palette = BrandPalette(colorScheme: colorScheme, contrast: contrast)
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                    Link(destination: source.url) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("[\(index + 1)] \(source.title)")
                                .font(.subheadline)
                                .foregroundStyle(palette.textPrimary)
                                .lineLimit(2)
                            Text(source.url.host ?? source.url.absoluteString)
                                .font(.caption.monospaced())
                                .foregroundStyle(palette.textMuted)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            Label("参考来源 \(sources.count) 条", systemImage: "globe")
                .font(.subheadline)
                .foregroundStyle(palette.textSecondary)
        }
        .padding(12)
        .quotaContentSurface(cornerRadius: 14)
    }
}

struct ChatFailureNotice: View {
    let failure: ChatFailure
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let palette = BrandPalette(colorScheme: colorScheme, contrast: contrast)
        let presentation = ChatFailurePresentation(failure)
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(presentation.title).foregroundStyle(palette.textPrimary)
            } icon: {
                Image(systemName: presentation.symbolName).foregroundStyle(tint(presentation.severity, palette))
            }
            .font(.subheadline.weight(.semibold))
            Text(presentation.summary)
                .font(.footnote)
                .foregroundStyle(palette.textSecondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .quotaContentSurface(cornerRadius: 14)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private func tint(_ severity: ErrorSeverityLevel, _ palette: BrandPalette) -> Color {
        switch severity {
        case .neutral: palette.textSecondary
        case .warning: palette.statusWarn
        case .critical: palette.statusError
        }
    }
}

/// Streaming-aware Markdown on iOS; plain inline Markdown where the renderer is unavailable.
struct ChatMarkdownText: View {
    let text: String

    var body: some View {
        #if canImport(SwiftStreamingMarkdown)
        MarkdownView(text: text)
            .frame(maxWidth: .infinity, alignment: .leading)
        #else
        Text((try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text))
            .font(.body)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        #endif
    }
}

struct ChatAttachmentStrip: View {
    let attachments: [ChatImageAttachment]
    var onRemove: ((UUID) -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    ChatAttachmentThumbnail(attachment: attachment)
                        .overlay(alignment: .topTrailing) {
                            if let onRemove {
                                Button {
                                    onRemove(attachment.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                        .font(.title3)
                                        .frame(width: 44, height: 44, alignment: .topTrailing)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("移除图片")
                            }
                        }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }
}

struct ChatAttachmentThumbnail: View {
    let attachment: ChatImageAttachment
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let image = Self.image(from: attachment.data) {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(BrandPalette(colorScheme: colorScheme).textMuted)
            }
        }
        .frame(width: 72, height: 72)
        .background(BrandPalette(colorScheme: colorScheme).insetSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityLabel("图片附件")
    }

    static func image(from data: Data) -> Image? {
        #if os(iOS)
        UIImage(data: data).map { Image(uiImage: $0) }
        #elseif os(macOS)
        NSImage(data: data).map { Image(nsImage: $0) }
        #else
        nil
        #endif
    }
}
#endif
