#if os(iOS) && targetEnvironment(simulator)
import Foundation
import Network
import Testing
import WebKit
@testable import CPAQuotaUI

@MainActor
struct ChatHTMLIsolationTests {
    @available(iOS 18.4, *)
    @Test func staticPreviewKeepsInlineStyleAndBlocksExternalContent() async throws {
        let server = try LoopbackFixture()
        defer { server.stop() }
        try await wait { server.port != nil }
        let base = "http://127.0.0.1:\(try #require(server.port))"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("private.html")
        try "<p>PRIVATE-FIXTURE</p>".write(to: file, atomically: true, encoding: .utf8)

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let control = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: config)
        control.loadFileURL(file, allowingReadAccessTo: directory)
        try await wait { try await self.text(control, "document.body.innerText.trim()") == "PRIVATE-FIXTURE" }
        control.loadHTMLString("<link rel='stylesheet' href='\(base)/control.css'><p id='probe'>CSS</p>", baseURL: nil)
        try await wait { try await self.text(control, "getComputedStyle(document.querySelector('#probe')).paddingLeft") == "17px" }
        control.load(URLRequest(url: try #require(URL(string: base + "/control-navigation"))))
        try await wait { try await self.text(control, "document.body.innerText.trim()") == "Loopback fixture" }
        #expect(server.paths.contains("/control.css") && server.paths.contains("/control-navigation"))

        let preview = IsolatedChatHTMLWebView()
        preview.frame = control.frame
        #expect(!preview.configuration.websiteDataStore.isPersistent)
        #expect(!preview.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        try await preview.loadSnapshot("""
            <link rel="stylesheet" href="\(base)/blocked.css">
            <p id="probe" style="color:rgb(17,34,51)">STATIC-FIXTURE</p>
            <script>document.querySelector('#probe').textContent='Script ran'</script>
            <iframe src="\(file.absoluteString)"></iframe>
            <a id="link" href="\(base)/blocked-navigation">Go</a>
            <a id="popup" target="_blank" href="\(base)/blocked-popup">New window</a>
            """)
        try await wait { try await self.text(preview, "document.querySelector('#probe')?.textContent") == "STATIC-FIXTURE" && !preview.isLoading }
        #expect(try await text(preview, "getComputedStyle(document.querySelector('#probe')).color") == "rgb(17, 34, 51)")
        #expect(try await text(preview, "try {document.querySelector('iframe').contentDocument?.body?.innerText || 'unreadable'} catch { 'unreadable' }") == "unreadable")
        _ = try await preview.evaluateJavaScript("document.getElementById('popup').click(); document.getElementById('link').click(); true")
        // Give WebKit's network process time to deliver a request to the same
        // listener that served both positive controls.
        try await Task.sleep(for: .seconds(1))
        #expect(preview.url?.absoluteString == "about:blank")
        #expect(try await text(preview, "document.querySelector('#probe').textContent") == "STATIC-FIXTURE")
        #expect(server.paths.filter { $0.hasPrefix("/blocked") }.isEmpty)
        print("HTML isolation fixture observed \(server.paths.sorted()); final URL \(preview.url?.absoluteString ?? "nil")")
    }

    private func text(_ web: WKWebView, _ expression: String) async throws -> String? {
        try await web.evaluateJavaScript(expression) as? String
    }

    private func wait(for condition: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if (try? await condition()) == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw URLError(.timedOut)
    }
}

/// An ephemeral, loopback-only origin shared by the control and the real preview.
@MainActor private final class LoopbackFixture {
    private let listener: NWListener
    private(set) var paths: [String] = []
    private(set) var port: UInt16?

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { Task { @MainActor in self?.port = self?.listener.port?.rawValue } }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                connection.start(queue: .main)
                self?.receive(connection, buffered: Data())
            }
        }
        listener.start(queue: .main)
    }

    func stop() { listener.cancel() }

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, finished, error in
            Task { @MainActor in
                guard let data, error == nil else { connection.cancel(); return }
                let buffer = buffered + data
                let request = String(decoding: buffer, as: UTF8.self)
                guard request.contains("\r\n\r\n") else {
                    if finished || buffer.count > 8192 { connection.cancel() }
                    else { self.receive(connection, buffered: buffer) }
                    return
                }
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                self.paths.append(path)
                let css = path.hasSuffix(".css")
                let body = css ? "#probe {padding-left:17px}" : "<p>Loopback fixture</p>"
                let headers = "HTTP/1.1 200 OK\r\nContent-Type: \(css ? "text/css" : "text/html")\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
                connection.send(content: Data((headers + body).utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}
#endif
