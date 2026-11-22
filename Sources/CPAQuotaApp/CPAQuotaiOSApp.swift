import Foundation
#if DEBUG
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

    var body: some View {
        Group {
            if let session {
                CPAQuotaRootView(session: session)
                    .environment(\.dynamicTypeSize, usesLargeText ? .accessibility5 : .large)
                    .safeAreaInset(edge: .bottom) {
                        if usesChatGate, gatedChat.isWaiting {
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
                                .task(id: gatedChat.generation) {
                                    guard gatedChat.generation > 0, let chatFiles else { return }
                                    checkpointOnDisk = false
                                    let deadline = ContinuousClock.now + .seconds(90)
                                    while !Task.isCancelled && ContinuousClock.now < deadline {
                                        if let records = try? await chatFiles.loadConversations(),
                                           records.contains(where: { $0.messages.last?.text == "保存片段一" && $0.messages.last?.status == .streaming }) {
                                            checkpointOnDisk = true
                                            return
                                        }
                                        try? await Task.sleep(for: .milliseconds(100))
                                    }
                                }
                        }
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
        let preferences = MemoryPreferencesStore(
            serverIdentifier: connected ? CPAQuotaUITestFixtures.serverAddress : nil
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
                chatFiles = ChatFilePersistence(directory: base.appendingPathComponent("ChatUITests/\(id.uuidString)"))
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
        [CPAModel(id: "fixture-chat-default"), CPAModel(id: "fixture-chat-alternate")]
    }
}

/// An optional test scenario with an observable boundary between reasoning and answer.
@MainActor @Observable private final class GatedUITestChatEngine: ChatEngine, ChatBackgroundRunner {
    private var current: AsyncThrowingStream<ChatEngineEvent, any Error>.Continuation?
    private(set) var generation = 0
    private var expiration: (@MainActor @Sendable () -> Void)?
    var isWaiting: Bool { current != nil }

    nonisolated func stream(_ request: ChatEngineRequest) -> AsyncThrowingStream<ChatEngineEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                guard !Task.isCancelled else { return }
                generation += 1
                let id = generation
                current = continuation
                continuation.yield(.snapshot(text: "", reasoning: "可见推理片段"))
                do {
                    try await Task.sleep(for: .seconds(120))
                    continuation.finish(throwing: URLError(.timedOut))
                } catch {
                    continuation.finish(throwing: CancellationError())
                }
                if generation == id { current = nil }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func releaseAnswer() {
        current?.yield(.snapshot(text: "放行后的正文", reasoning: "可见推理片段"))
        current?.finish()
        current = nil
    }

    func checkpoint() {
        current?.yield(.snapshot(text: "保存片段一", reasoning: "可见推理片段"))
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
