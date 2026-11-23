import Foundation
#if DEBUG
#if canImport(notify)
import notify
#endif
@_spi(Testing) import CPAQuotaKit
#else
import CPAQuotaKit
#endif
import CPAQuotaChat
import CPAQuotaUI

#if canImport(SwiftUI)
import SwiftUI

@main
struct CPAQuotaiOSApp: App {
    @State private var productionSession: CPAQuotaSession?
    #if DEBUG
    private let usesUITesting: Bool
    #endif

    init() {
        #if DEBUG
        let testing = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        usesUITesting = testing
        let session: CPAQuotaSession? = testing ? nil : CPAQuotaSession()
        #else
        let session: CPAQuotaSession? = CPAQuotaSession()
        #endif
        _productionSession = State(initialValue: session)
        #if canImport(UIKit)
        if let session {
            // Installed during launch so tapping a completion notice that starts the app still opens it.
            ChatNotificationRouter.shared.install { conversationID in
                session.activeTab = .chat
                session.chatWorkspace.requestedConversationID = conversationID
            }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if usesUITesting {
                UITestWorkspace()
            } else if let productionSession {
                CPAQuotaRootView(session: productionSession)
            }
            #else
            if let productionSession {
                CPAQuotaRootView(session: productionSession)
            }
            #endif
        }
    }
}

#if DEBUG
/// Only the XCUITest process opts into this host. The production session is not
/// constructed, so test launches never restore a user's Keychain or preferences.
private struct UITestWorkspace: View {
    @State private var session: CPAQuotaSession?
    @State private var preparationFailed = false
    @State private var isPreparing = false
    @State private var slowResponse = CPAQuotaUITestFixtures.SlowResponseControl()
    @State private var slowPhase: CPAQuotaUITestFixtures.SlowResponseControl.Phase = .idle
    private let usesLargeText = ProcessInfo.processInfo.arguments.contains("--ui-test-large-text")
    private let usesChatGate = ProcessInfo.processInfo.arguments.contains("--ui-test-chat-gate")
    @State private var gatedChat = GatedUITestChatEngine()
    @State private var chatFiles: ChatFilePersistence?
    @State private var checkpointOnDisk = false
    @State private var modelPreferenceOnDisk = false
    #if os(iOS)
    @State private var copyCheck = "校验合成消息"
    #endif

    var body: some View {
        Group {
            if let session {
                CPAQuotaRootView(session: session)
                    .environment(\.dynamicTypeSize, usesLargeText ? .accessibility5 : .large)
                    .safeAreaInset(edge: .top) {
                        VStack(spacing: 2) {
                            #if os(iOS)
                            if ProcessInfo.processInfo.arguments.contains("--ui-test-chat-html"), gatedChat.generation > 0,
                               !gatedChat.isWaiting {
                                Button(copyCheck) {
                                    switch UIPasteboard.general.string {
                                    case GatedUITestChatEngine.htmlFixture: copyCheck = "完整源码一致"
                                    case "<p>Second fragment</p>\n": copyCheck = "片段源码一致"
                                    default: copyCheck = "源码不符"
                                    }
                                }
                                .accessibilityIdentifier("ui-test.chat.checkCopy")
                                .padding(.top, usesChatGate ? 58 : 0)
                            }
                            #endif
                            if usesChatGate, gatedChat.isWaiting {
                                if ProcessInfo.processInfo.arguments.contains("--ui-test-chat-scroll") {
                                    Button("追加段落") { gatedChat.extendAnswer() }
                                        .accessibilityIdentifier("ui-test.chat.extend")
                                }
                                if chatFiles != nil {
                                    HStack {
                                        Button("写入片段") { gatedChat.checkpoint() }
                                            .accessibilityIdentifier("ui-test.chat.checkpoint")
                                        Button("触发过期") { gatedChat.expire() }
                                            .accessibilityIdentifier("ui-test.chat.expire")
                                    }
                                }
                                Button("放行正文") { gatedChat.releaseAnswer() }
                                    .accessibilityIdentifier("ui-test.chat.release")
                            }
                            if usesChatGate, chatFiles != nil {
                                Text("生成请求 \(gatedChat.generation)，已写块 \(checkpointOnDisk ? 1 : 0)")
                                    .accessibilityIdentifier("ui-test.chat.counts")
                                    .allowsHitTesting(false)
                                    .task(id: gatedChat.generation) {
                                        guard gatedChat.generation > 0, let chatFiles else { return }
                                        checkpointOnDisk = false
                                        let deadline = ContinuousClock.now + .seconds(90)
                                        while !Task.isCancelled && ContinuousClock.now < deadline {
                                            if let records = try? await chatFiles.loadConversations(),
                                               records.contains(where: { $0.messages.last?.text == gatedChat.expectedCheckpoint && $0.messages.last?.status == .streaming }) {
                                                checkpointOnDisk = true
                                                return
                                            }
                                            try? await Task.sleep(for: .milliseconds(100))
                                        }
                                    }
                            }
                            if let chatFiles, ProcessInfo.processInfo.arguments.contains("--ui-test-chat-models") {
                                let selected = session.chatWorkspace.settings.recentModelIDs
                                Text(modelPreferenceOnDisk ? "模型选择已写入" : "等待模型选择")
                                    .allowsHitTesting(false)
                                    .task(id: selected) {
                                        modelPreferenceOnDisk = false
                                        guard selected != nil else { return }
                                        let deadline = ContinuousClock.now + .seconds(15)
                                        while !Task.isCancelled && ContinuousClock.now < deadline {
                                            if (try? await chatFiles.loadSettings())?.recentModelIDs == selected {
                                                modelPreferenceOnDisk = true
                                                return
                                            }
                                            try? await Task.sleep(for: .milliseconds(100))
                                        }
                                    }
                            }
                        }
                        .padding(.top, usesChatGate ? 24 : 0)
                        .frame(maxWidth: .infinity)
                    }
                    .safeAreaInset(edge: .bottom) {
                        // Do not change the presenting workspace's safe area
                        // while the real connection sheet is being dismissed.
                        if slowPhase != .idle, !session.isPresentingConnectionSheet {
                            HStack {
                                if slowPhase == .pending {
                                    Text("测试夹具：响应等待中")
                                        .accessibilityIdentifier("ui-test.slowResponse.pending")
                                    Button("释放测试响应") {
                                        Task { await slowResponse.release() }
                                    }
                                    .accessibilityIdentifier("ui-test.slowResponse.release")
                                } else {
                                    Text("测试夹具：响应已返回")
                                        .accessibilityIdentifier("ui-test.slowResponse.returned")
                                }
                            }
                            .padding(8)
                            .background(.regularMaterial)
                        }
                    }
            } else if preparationFailed {
                Text("UI 测试夹具准备失败")
                    .accessibilityIdentifier("ui-test.preparationFailed")
            } else {
                ProgressView("准备本机测试数据")
            }
        }
        .task { await prepare() }
        .task {
            for await phase in await slowResponse.phases() {
                slowPhase = phase
            }
        }
    }

    @MainActor
    private func prepare() async {
        guard session == nil, !isPreparing else { return }
        isPreparing = true
        let credentials = MemoryCredentialStore()
        let connected = ProcessInfo.processInfo.arguments.contains("--fixture=connected")
        let theme = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--ui-test-theme=") }
            .flatMap { CPAThemeMode(rawValue: String($0.dropFirst("--ui-test-theme=".count))) }
        let preferences = MemoryPreferencesStore(
            serverIdentifier: connected ? CPAQuotaUITestFixtures.serverAddress : nil,
            themeMode: theme ?? .system
        )
        do {
            if connected {
                let server = try CPAServer(baseURL: CPAQuotaUITestFixtures.serverAddress)
                let key = try ManagementKey(CPAQuotaUITestFixtures.managementKey)
                try await credentials.save(key, for: server)
            }
            let monitoring = MonitoringWorkspaceCoordinator(
                credentialStore: MonitoringBridgeCredentialStore(storage: MemoryCredentialStore()),
                metadataStore: MemoryMonitoringMetadataPersistence()
            )
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("CPAQuotaUITest-\(UUID().uuidString)", isDirectory: true)
            let slowResponse = slowResponse
            let storeArgument = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--ui-test-chat-store=") }
            if let storeArgument {
                guard let id = UUID(uuidString: String(storeArgument.dropFirst("--ui-test-chat-store=".count))) else {
                    preparationFailed = true
                    return
                }
                let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true)
                let root = base.appendingPathComponent("ChatUITests/\(id.uuidString)")
                chatFiles = ChatFilePersistence(directory: root)
                if ProcessInfo.processInfo.arguments.contains("--ui-test-chat-legacy") {
                    let url = root.appendingPathComponent("settings.json")
                    if !FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                        let old = #"{"globalInstructions":"legacy fixture","isMemoryEnabled":false,"defaultModelID":"fixture-chat-alternate","notifiesOnBackgroundCompletion":false,"generatesTitles":false}"#
                        try Data(old.utf8).write(to: url, options: .atomic)
                    }
                }
            }
            session = CPAQuotaSession(
                credentialStore: credentials,
                preferences: preferences,
                monitoringCoordinator: monitoring,
                widgetSnapshotStore: .init(directoryURL: directory),
                clientFactory: { server, key in
                    CPAQuotaUITestFixtures.makeClient(server: server, managementKey: key,
                                                       slowResponse: slowResponse)
                },
                chatWorkspace: ChatWorkspaceModel(
                    persistence: chatFiles.map { $0 as any ChatPersistence } ?? ChatMemoryPersistence(),
                    secrets: MemorySecretStore(),
                    engine: usesChatGate ? gatedChat as any ChatEngine : UITestChatEngine(),
                    modelCatalog: { _, _ in UITestChatModelCatalog() },
                    backgroundRunner: usesChatGate ? gatedChat as any ChatBackgroundRunner : SystemChatBackgroundRunner(),
                    streamingPersistInterval: chatFiles == nil ? .seconds(2) : .zero)
            )
        } catch {
            preparationFailed = true
        }
    }
}

private struct UITestChatModelCatalog: ChatModelCatalog {
    func models() async throws -> [CPAModel] {
        if ProcessInfo.processInfo.arguments.contains("--ui-test-removed-model") {
            return [CPAModel(id: "fixture-chat-default")]
        }
        return [CPAModel(id: "fixture-chat-default"), CPAModel(id: "fixture-chat-alternate")]
    }
}

/// An optional test scenario with an observable boundary between reasoning and answer.
@MainActor @Observable private final class GatedUITestChatEngine: ChatEngine, ChatBackgroundRunner {
    private var current: AsyncThrowingStream<ChatEngineEvent, any Error>.Continuation?
    private var currentID: UUID?
    private var releaseToken: Int32?
    private(set) var generation = 0
    private var checkpointBase = ""
    private var checkpointSuffix: String { checkpointBase.isEmpty ? "保存片段一" : "追加片段二" }
    var expectedCheckpoint: String { checkpointBase + checkpointSuffix }
    private var paragraphs: [String] = []
    private var expiration: (@MainActor @Sendable () -> Void)?
    var isWaiting: Bool { current != nil }

    nonisolated func stream(_ request: ChatEngineRequest) -> AsyncThrowingStream<ChatEngineEvent, any Error> {
        AsyncThrowingStream { continuation in
            let id = UUID()
            let task = Task { @MainActor in
                guard !Task.isCancelled else { return }
                if ProcessInfo.processInfo.arguments.contains("--ui-test-chat-continuation"),
                   let partial = request.history.last, partial.role == .assistant {
                    checkpointBase = partial.text
                } else {
                    checkpointBase = ""
                }
                generation += 1
                currentID = id
                current = continuation
                paragraphs = []
                let html = ProcessInfo.processInfo.arguments.contains("--ui-test-chat-html")
                continuation.yield(.snapshot(text: html ? Self.firstHTMLChunk : "", reasoning: "可见推理片段"))
                // The UI test can release the next chunk while a modal preview
                // covers the in-app fixture buttons. Only this debug engine listens.
                if html, let gate = ProcessInfo.processInfo.environment["CPA_UI_HTML_GATE"],
                   let uuid = UUID(uuidString: gate) {
                    var token: Int32 = 0
                    let name = "icu.nahida.cpaquota.html." + uuid.uuidString
                    if notify_register_dispatch(name, &token, .main, { [weak self] _ in
                        Task { @MainActor in
                            self?.releaseAnswer()
                            notify_post(name + ".released")
                        }
                    }) == NOTIFY_STATUS_OK { releaseToken = token }
                }
            }
            continuation.onTermination = { [weak self] _ in
                task.cancel()
                Task { @MainActor in
                    guard let self, self.currentID == id else { return }
                    if let token = self.releaseToken { notify_cancel(token); self.releaseToken = nil }
                    self.current = nil
                    self.currentID = nil
                }
            }
        }
    }

    func releaseAnswer() {
        let answer = ProcessInfo.processInfo.arguments.contains("--ui-test-chat-html") ? Self.htmlFixture : "放行后的正文"
        current?.yield(.snapshot(text: answer, reasoning: "可见推理片段"))
        current?.finish()
        current = nil
    }

    static let firstHTMLChunk = """
        Complete snippets
        ~~~html
        <p style="min-height:150vh">First fragment</p><p>First fixture end
        ~~~
        ~~~text
        ordinary code
        ~~~
        ~~~html
        """
    static let htmlFixture = firstHTMLChunk + "\n" + """
        <p>Second fragment</p>
        ~~~
        ~~~html
        <p>incomplete
        """

    func checkpoint() {
        current?.yield(.snapshot(text: checkpointSuffix, reasoning: "可见推理片段"))
    }

    func extendAnswer() {
        let first = paragraphs.count + 1
        paragraphs += (first..<(first + 18)).map { "阅读段落 \($0)" }
        current?.yield(.snapshot(text: paragraphs.joined(separator: "\n\n"), reasoning: "可见推理片段"))
    }

    func expire() { expiration?() }
    func beginTask(expiration: @escaping @MainActor @Sendable () -> Void) -> ChatBackgroundToken {
        self.expiration = expiration
        return ChatBackgroundToken(rawValue: 1)
    }
    func endTask(_ token: ChatBackgroundToken) { expiration = nil }
    var isAppInBackground: Bool { false }
    func notifyCompletion(conversationID: UUID) async {}
    func requestNotificationAuthorization() async -> Bool { false }
    func notificationAuthorizationStatus() async -> ChatNotificationAuthorization { .denied }

    func complete(_ request: ChatEngineRequest) async throws -> String { "夹具对话" }
}

private actor UITestChatEngine: ChatEngine {
    private var attempt = 0

    nonisolated func stream(_ request: ChatEngineRequest) -> AsyncThrowingStream<ChatEngineEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let attempt = await self.nextAttempt()
                if attempt == 1 {
                    continuation.yield(.snapshot(text: "第一段夹具回复", reasoning: nil))
                    // Keep the initial reply in progress until the test stops it.
                    do {
                        try await Task.sleep(for: .seconds(60))
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                } else {
                    continuation.yield(.snapshot(text: "重新生成的夹具回复", reasoning: nil))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func complete(_ request: ChatEngineRequest) async throws -> String { "夹具对话" }

    private func nextAttempt() -> Int {
        attempt += 1
        return attempt
    }
}
#endif
#else
@main
struct CPAQuotaiOSAppFallback {
    static func main() {
        print("CPAQuotaApp requires an Apple platform with SwiftUI runtime.")
    }
}
#endif
