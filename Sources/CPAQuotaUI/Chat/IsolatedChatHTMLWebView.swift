#if os(iOS)
import WebKit

/// A fresh, scriptless document for one immutable assistant snippet.
@MainActor final class IsolatedChatHTMLWebView: WKWebView, WKNavigationDelegate, WKUIDelegate {
    private static var cachedRuleList: WKContentRuleList?
    private static var ruleListCompilation: Task<WKContentRuleList, any Error>?

    var onFinish: (() -> Void)?
    var onFailure: (() -> Void)?
    private var permitsInitialLoad = false
    private var initialNavigation: WKNavigation?

    init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.dataDetectorTypes = []
        super.init(frame: .zero, configuration: config)
        isOpaque = false
        backgroundColor = .clear
        scrollView.backgroundColor = .clear
        navigationDelegate = self
        uiDelegate = self
        allowsLinkPreview = false
        allowsBackForwardNavigationGestures = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func sharedContentRuleList() async throws -> WKContentRuleList {
        if let cachedRuleList { return cachedRuleList }
        if let existing = ruleListCompilation {
            return try await existing.value
        }
        let task = Task<WKContentRuleList, any Error> { @MainActor in
            let rules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
            guard let blocker = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "chat-static-html-v1", encodedContentRuleList: rules)
            else { throw URLError(.cannotLoadFromNetwork) }
            return blocker
        }
        ruleListCompilation = task
        do {
            let compiled = try await task.value
            cachedRuleList = compiled
            ruleListCompilation = nil
            return compiled
        } catch {
            ruleListCompilation = nil
            throw error
        }
    }

    func loadSnapshot(_ source: String) async throws {
        guard #available(iOS 18.4, *) else { throw URLError(.unsupportedURL) }
        let blocker = try await Self.sharedContentRuleList()
        try Task.checkCancellation()
        configuration.userContentController.add(blocker)
        let head = """
            <!doctype html><meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; form-action 'none'; base-uri 'none'">
            <meta http-equiv="x-dns-prefetch-control" content="off">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="color-scheme" content="light dark">
            <style>:root { color-scheme: light dark; } body { font: -apple-system-body; overflow-wrap: anywhere; margin: 16px; background: #FAF8F4; color: #181715; } @media (prefers-color-scheme: dark) { body { background: #131211; color: #F4F0EA; } }</style>
            """
        permitsInitialLoad = true
        initialNavigation = loadHTMLString(head + source, baseURL: nil)
        if initialNavigation == nil { throw URLError(.cannotDecodeContentData) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if navigation === initialNavigation { onFinish?() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard permitsInitialLoad, action.targetFrame?.isMainFrame == true,
              action.navigationType == .other, action.request.url?.absoluteString == "about:blank"
        else { return .cancel }
        permitsInitialLoad = false
        return .allow
    }

    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        (.cancelAuthenticationChallenge, nil)
    }

    func webView(_ webView: WKWebView, contextMenuConfigurationFor elementInfo: WKContextMenuElementInfo) async
        -> UIContextMenuConfiguration? { nil }

    @available(iOS 18.4, *)
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? { nil }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if navigation === initialNavigation { onFailure?() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if navigation === initialNavigation { onFailure?() }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { onFailure?() }
}
#endif
