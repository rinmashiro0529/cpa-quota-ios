#if os(iOS)
import SwiftUI
import WebKit

struct ChatHTMLSnippetButtons: View {
    let text: String
    var isStreaming: Bool = false
    let open: (ChatHTMLSnippet) -> Void
    @State private var snippets: [ChatHTMLSnippet] = []

    private struct ParseTrigger: Equatable {
        let text: String
        let isStreaming: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(snippets) { snippet in
                Button { open(snippet) } label: {
                    Label("HTML 片段 \(snippet.id)", systemImage: "doc.richtext")
                        .frame(minHeight: 44)
                }
                .accessibilityHint("打开此片段的静态预览")
                .accessibilityIdentifier("chat.html.snippet.\(snippet.id)")
            }
        }
        .task(id: ParseTrigger(text: text, isStreaming: isStreaming)) {
            if isStreaming {
                // Coalesce Markdown AST parsing while tokens arrive rapidly;
                // once streaming completes, parse immediately without delay.
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            let parsed = await Self.parse(text)
            if !Task.isCancelled { snippets = parsed }
        }
    }

    private nonisolated static func parse(_ text: String) async -> [ChatHTMLSnippet] {
        guard !Task.isCancelled else { return [] }
        return ChatHTMLSnippet.extract(from: text)
    }
}

struct ChatHTMLPreview: View {
    let snippet: ChatHTMLSnippet
    @Environment(\.dismiss) private var dismiss
    @Environment(\.brandPalette) private var palette
    @State private var showsSource: Bool
    @State private var loadFailed = false
    @State private var isLoadingPreview = true
    @State private var revision = 0
    @State private var justCopiedSource = false
    @State private var copyFeedbackTask: Task<Void, Never>?

    private static var supportsStaticPreview: Bool {
        if #available(iOS 18.4, *) { return true }
        return false
    }

    init(snippet: ChatHTMLSnippet) {
        self.snippet = snippet
        _showsSource = State(initialValue: !Self.supportsStaticPreview)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                if Self.supportsStaticPreview {
                    Picker("显示方式", selection: $showsSource) {
                        Text("预览").tag(false)
                        Text("源码").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }

                if showsSource || !Self.supportsStaticPreview {
                    if !Self.supportsStaticPreview {
                        Text("静态预览需要 iOS 18.4 及以上系统，当前仅展示源码，可复制使用。")
                            .font(.footnote)
                            .foregroundStyle(palette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                    } else if loadFailed {
                        Text("预览载入失败，可复制源码或刷新重试。")
                            .font(.footnote)
                            .foregroundStyle(palette.statusWarn)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                    }
                    ScrollView {
                        Text(verbatim: snippet.source)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(palette.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                    .quotaContentSurface(cornerRadius: 14)
                    .padding(.horizontal, 16)

                    Button {
                        ChatClipboard.copy(snippet.source)
                        justCopiedSource = true
                        copyFeedbackTask?.cancel()
                        copyFeedbackTask = Task {
                            try? await Task.sleep(for: .milliseconds(1500))
                            guard !Task.isCancelled else { return }
                            justCopiedSource = false
                        }
                    } label: {
                        Label(justCopiedSource ? "已复制源码" : "复制源码",
                              systemImage: justCopiedSource ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .quotaSecondaryButtonStyle()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                } else {
                    ZStack {
                        StaticHTMLView(
                            source: snippet.source,
                            onFinish: { isLoadingPreview = false },
                            onFailure: {
                                isLoadingPreview = false
                                loadFailed = true
                                showsSource = true
                            }
                        )
                        .id(revision)
                        if isLoadingPreview {
                            ProgressView("正在载入静态预览")
                                .padding(12)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
            .background(BrandCanvasBackground())
            .onChange(of: showsSource) { _, showingSource in
                if !showingSource { isLoadingPreview = true }
            }
            .onDisappear {
                copyFeedbackTask?.cancel()
                copyFeedbackTask = nil
            }
            .navigationTitle("HTML 片段 \(snippet.id)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                if Self.supportsStaticPreview {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            loadFailed = false
                            isLoadingPreview = true
                            showsSource = false
                            revision += 1
                        } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    }
                }
            }
        }
        .brandPaletteEnvironment()
    }
}

private struct StaticHTMLView: UIViewRepresentable {
    let source: String
    let onFinish: () -> Void
    let onFailure: () -> Void

    func makeUIView(context: Context) -> IsolatedChatHTMLWebView {
        let web = IsolatedChatHTMLWebView()
        web.onFinish = onFinish
        web.onFailure = onFailure
        context.coordinator.load = Task {
            do { try await web.loadSnapshot(source) }
            catch { if !Task.isCancelled { onFailure() } }
        }
        return web
    }

    func updateUIView(_ web: IsolatedChatHTMLWebView, context: Context) {}

    final class Coordinator {
        var load: Task<Void, Never>?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleUIView(_ web: IsolatedChatHTMLWebView, coordinator: Coordinator) {
        coordinator.load?.cancel()
        web.onFinish = nil
        web.onFailure = nil
        web.stopLoading()
    }
}
#endif
