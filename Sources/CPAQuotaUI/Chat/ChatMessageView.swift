#if canImport(SwiftUI)
import SwiftUI
import CPAQuotaKit
import CPAQuotaChat
#if canImport(SwiftStreamingMarkdown)
import SwiftStreamingMarkdown
#endif
#if canImport(ImageIO)
import ImageIO
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
    let openSettings: (() -> Void)?
    let refreshModels: (() -> Void)?
}

struct ChatMessageView: View, Equatable {
    let message: ChatMessage
    let isLatestAssistant: Bool
    let isConversationGenerating: Bool
    /// Regenerate needs a usable key and model; a disabled entry never truncates.
    let canRerun: Bool
    let actions: ChatMessageActions
    @Environment(\.brandPalette) private var palette
    @State private var justCopied = false
    @State private var copyFeedbackTask: Task<Void, Never>?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message
            && lhs.isLatestAssistant == rhs.isLatestAssistant
            && lhs.isConversationGenerating == rhs.isConversationGenerating
            && lhs.canRerun == rhs.canRerun
    }

    var body: some View {
        Group {
            switch message.role {
            case .user:
                HStack(alignment: .bottom, spacing: 4) {
                    Spacer(minLength: actions.edit == nil ? 40 : 0)
                    if let edit = actions.edit {
                        Button(action: edit) {
                            Label("编辑并重新发送", systemImage: "pencil")
                                .labelStyle(.iconOnly)
                                .font(.subheadline)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(palette.textMuted)
                        .disabled(isConversationGenerating)
                        .accessibilityIdentifier("chat.edit")
                    }
                    userBody
                }
            case .assistant:
                assistantBody
            }
        }
        .contextMenu { menu }
        .onDisappear {
            copyFeedbackTask?.cancel()
            copyFeedbackTask = nil
        }
    }

    // MARK: User

    private var userBody: some View {
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

    private var assistantBody: some View {
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
                    ChatHTMLSnippetButtons(
                        text: message.text,
                        isStreaming: message.status == .streaming,
                        open: actions.previewHTML
                    )
                }
                #endif
            }

            if !message.searchSources.isEmpty {
                ChatSourcesView(sources: message.searchSources)
            }

            statusFooter

            if message.status != .streaming {
                actionBar
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var statusFooter: some View {
        if message.status == .stopped {
            Label("已停止生成", systemImage: "stop.circle")
                .font(.footnote)
                .foregroundStyle(palette.textSecondary)
        }
        if let failure = message.failure {
            ChatFailureNotice(
                failure: failure,
                onOpenSettings: actions.openSettings,
                onRefreshModels: actions.refreshModels,
                onRegenerate: (isLatestAssistant && !isConversationGenerating && canRerun) ? actions.regenerate : nil
            )
        }
        if let omitted = message.omittedHistoryCount, omitted > 0 {
            Label("较早的 \(omitted) 条消息未随本轮发送", systemImage: "text.badge.minus")
                .font(.footnote)
                .foregroundStyle(palette.textSecondary)
        }
        if let reasoningNotice = message.reasoningResolution?.noticeText {
            Label(reasoningNotice, systemImage: "slider.horizontal.3")
                .font(.footnote)
                .foregroundStyle(palette.textSecondary)
                .accessibilityIdentifier("chat.message.reasoningNotice")
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

    private var actionBar: some View {
        HStack(spacing: 4) {
            if !message.text.isEmpty {
                Button {
                    actions.copy()
                    triggerCopyFeedback()
                } label: {
                    Label(justCopied ? "已复制" : "复制",
                          systemImage: justCopied ? "checkmark" : "doc.on.doc")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(justCopied ? palette.statusOK : palette.textSecondary)
                .accessibilityIdentifier("doc.on.doc")
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

    private func triggerCopyFeedback() {
        justCopied = true
        copyFeedbackTask?.cancel()
        copyFeedbackTask = Task {
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            justCopied = false
        }
    }

    // MARK: Menu

    @ViewBuilder
    private var menu: some View {
        if !message.text.isEmpty {
            Button {
                actions.copy()
                triggerCopyFeedback()
            } label: {
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

/// Collapsed by default once the answer starts, while still allowing the user to collapse
/// or expand manually at any time during streaming.
struct ChatReasoningView: View {
    let reasoning: String
    let isStreaming: Bool
    @State private var isExpanded: Bool
    @State private var hasUserToggled = false
    @Environment(\.brandPalette) private var palette

    init(reasoning: String, isStreaming: Bool) {
        self.reasoning = reasoning
        self.isStreaming = isStreaming
        _isExpanded = State(initialValue: isStreaming)
    }

    var body: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { isExpanded },
            set: { newValue in
                hasUserToggled = true
                isExpanded = newValue
            }
        )) {
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
        .onChange(of: isStreaming) { _, nowStreaming in
            if !hasUserToggled {
                isExpanded = nowStreaming
            }
        }
    }
}

struct ChatSourcesView: View {
    let sources: [ChatSearchSource]
    @Environment(\.brandPalette) private var palette

    var body: some View {
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
    var onOpenSettings: (() -> Void)? = nil
    var onRefreshModels: (() -> Void)? = nil
    var onRegenerate: (() -> Void)? = nil
    @Environment(\.brandPalette) private var palette

    var body: some View {
        let presentation = ChatFailurePresentation(failure)
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text(presentation.title).foregroundStyle(palette.textPrimary)
                } icon: {
                    Image(systemName: presentation.symbolName).foregroundStyle(tint(presentation.severity))
                }
                .font(.subheadline.weight(.semibold))
                Text(presentation.summary)
                    .font(.footnote)
                    .foregroundStyle(palette.textSecondary)
            }
            .accessibilityElement(children: .combine)

            recoveryButton
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .quotaContentSurface(cornerRadius: 14)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var recoveryButton: some View {
        switch failure.recoveryAction {
        case .openSettings(let title):
            if let onOpenSettings {
                actionButton(title: title, symbol: "slider.horizontal.3", action: onOpenSettings)
            }
        case .refreshModels:
            if let onRefreshModels {
                actionButton(title: "刷新模型列表", symbol: "arrow.clockwise", action: onRefreshModels)
            }
        case .regenerate:
            if let onRegenerate {
                actionButton(title: "重新生成", symbol: "arrow.clockwise", action: onRegenerate)
            }
        case nil:
            EmptyView()
        }
    }

    private func actionButton(title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(palette.actionTint)
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func tint(_ severity: ErrorSeverityLevel) -> Color {
        switch severity {
        case .neutral: palette.textSecondary
        case .warning: palette.statusWarn
        case .critical: palette.statusError
        }
    }
}

/// Uses inline Markdown when the rich renderer or its color assets are unavailable.
struct ChatMarkdownText: View {
    let text: String

    @ViewBuilder
    var body: some View {
        #if os(iOS) && canImport(SwiftStreamingMarkdown)
        if Self.hasRendererColors {
            MarkdownView(text: text)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            inlineMarkdown
        }
        #else
        inlineMarkdown
        #endif
    }

    private var inlineMarkdown: some View {
        Text((try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text))
            .font(.body)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    #if os(iOS) && canImport(SwiftStreamingMarkdown)
    private static let hasRendererColors: Bool = {
        // The pinned renderer uses this named color for paragraphs and headings.
        guard let url = Bundle.main.url(forResource: "SwiftStreamingMarkdown_SwiftStreamingMarkdown", withExtension: "bundle"),
              let bundle = Bundle(url: url) else { return false }
        return UIColor(named: "Colors/Copilot/Theme/Foreground/Primary/750", in: bundle, compatibleWith: nil) != nil
    }()
    #endif
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

#if os(iOS) || os(macOS)
private final class ChatThumbnailCache: @unchecked Sendable {
    static let shared = ChatThumbnailCache()

    #if os(iOS)
    typealias PlatformImage = UIImage
    #else
    typealias PlatformImage = NSImage
    #endif

    private let cache: NSCache<NSUUID, PlatformImage> = {
        let cache = NSCache<NSUUID, PlatformImage>()
        cache.countLimit = 128
        return cache
    }()

    func cachedImage(for id: UUID) -> PlatformImage? {
        cache.object(forKey: id as NSUUID)
    }

    func store(_ image: PlatformImage, for id: UUID) {
        cache.setObject(image, forKey: id as NSUUID)
    }

    nonisolated static func decodeThumbnail(from data: Data, maxPixelSize: Int = 216) -> PlatformImage? {
        #if canImport(ImageIO)
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return fallbackImage(from: data)
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return fallbackImage(from: data)
        }
        #if os(iOS)
        return UIImage(cgImage: cgImage)
        #else
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
        #else
        return fallbackImage(from: data)
        #endif
    }

    private nonisolated static func fallbackImage(from data: Data) -> PlatformImage? {
        #if os(iOS)
        UIImage(data: data)
        #else
        NSImage(data: data)
        #endif
    }
}
#endif

struct ChatAttachmentThumbnail: View {
    let attachment: ChatImageAttachment
    @Environment(\.brandPalette) private var palette
    @State private var decodedImage: Image?
    @State private var decodeFailed = false

    private var cachedImage: Image? {
        #if os(iOS)
        ChatThumbnailCache.shared.cachedImage(for: attachment.id).map { Image(uiImage: $0) }
        #elseif os(macOS)
        ChatThumbnailCache.shared.cachedImage(for: attachment.id).map { Image(nsImage: $0) }
        #else
        nil
        #endif
    }

    var body: some View {
        Group {
            if let image = decodedImage ?? cachedImage {
                image
                    .resizable()
                    .scaledToFill()
            } else if decodeFailed {
                Image(systemName: "photo")
                    .foregroundStyle(palette.textMuted)
            } else {
                Color.clear
            }
        }
        .frame(width: 72, height: 72)
        .background(palette.insetSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityLabel("图片附件")
        .task(id: attachment.id) {
            #if os(iOS) || os(macOS)
            if let cached = ChatThumbnailCache.shared.cachedImage(for: attachment.id) {
                decodedImage = Self.swiftUIImage(cached)
                decodeFailed = false
                return
            }
            let id = attachment.id
            let data = attachment.data
            let decoded = await Task.detached(priority: .userInitiated) {
                ChatThumbnailCache.decodeThumbnail(from: data)
            }.value
            guard !Task.isCancelled else { return }
            if let decoded {
                ChatThumbnailCache.shared.store(decoded, for: id)
                decodedImage = Self.swiftUIImage(decoded)
                decodeFailed = false
            } else {
                decodeFailed = true
            }
            #else
            decodeFailed = true
            #endif
        }
    }

    #if os(iOS) || os(macOS)
    private static func swiftUIImage(_ image: ChatThumbnailCache.PlatformImage) -> Image {
        #if os(iOS)
        Image(uiImage: image)
        #else
        Image(nsImage: image)
        #endif
    }
    #endif

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
