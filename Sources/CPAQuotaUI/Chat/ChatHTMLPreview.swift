#if os(iOS)
import SwiftUI
import WebKit

struct ChatHTMLSnippetButtons: View {
    let text: String
    let open: (ChatHTMLSnippet) -> Void
    @State private var snippets: [ChatHTMLSnippet] = []

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
        .task(id: text) {
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
    @State private var showsSource: Bool
    @State private var loadFailed = false
    @State private var revision = 0

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
            VStack(spacing: 8) {
                if Self.supportsStaticPreview {
                    Picker("显示方式", selection: $showsSource) {
                        Text("预览").tag(false)
                        Text("源码").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                }

                if showsSource || !Self.supportsStaticPreview {
                    if !Self.supportsStaticPreview {
                        Text("静态预览需要 iOS 18.4 及以上系统，当前仅展示源码，可复制使用。")
                            .font(.footnote)
                            .padding(.horizontal)
                    } else if loadFailed {
                        Text("预览载入失败，可复制源码或刷新重试。").font(.footnote)
                    }
                    ScrollView {
                        Text(verbatim: snippet.source)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    Button("复制源码") { ChatClipboard.copy(snippet.source) }
                } else {
                    StaticHTMLView(source: snippet.source) {
                        loadFailed = true
                        showsSource = true
                    }
                    .id(revision)
                }
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
                            showsSource = false
                            revision += 1
                        } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    }
                }
            }
        }
    }
}

private struct StaticHTMLView: UIViewRepresentable {
    let source: String
    let onFailure: () -> Void

    func makeUIView(context: Context) -> IsolatedChatHTMLWebView {
        let web = IsolatedChatHTMLWebView()
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
        web.onFailure = nil
        web.stopLoading()
    }
}
#endif
