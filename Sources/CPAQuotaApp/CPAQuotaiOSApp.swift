import Foundation
#if DEBUG
@_spi(Testing) import CPAQuotaKit
#else
import CPAQuotaKit
#endif
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
        _productionSession = State(initialValue: testing ? nil : CPAQuotaSession())
        #else
        _productionSession = State(initialValue: CPAQuotaSession())
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

    var body: some View {
        Group {
            if let session {
                CPAQuotaRootView(session: session)
                    .environment(\.dynamicTypeSize, usesLargeText ? .accessibility5 : .large)
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
            session = CPAQuotaSession(
                credentialStore: credentials,
                preferences: preferences,
                monitoringCoordinator: monitoring,
                widgetSnapshotStore: .init(directoryURL: directory),
                clientFactory: { server, key in
                    CPAQuotaUITestFixtures.makeClient(server: server, managementKey: key,
                                                       slowResponse: slowResponse)
                }
            )
        } catch {
            preparationFailed = true
        }
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
