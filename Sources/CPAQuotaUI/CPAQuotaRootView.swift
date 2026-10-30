#if canImport(SwiftUI)
import SwiftUI
import CPAQuotaKit
import CPAQuotaActivity

/// Each workspace owns its navigation history. System bars own their safe areas and materials.
public struct CPAQuotaRootView: View {
    @Bindable var session: CPAQuotaSession
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var paths: [CPAWorkspaceTab: NavigationPath] = [:]
    @State private var deepLinkGeneration: UInt64 = 0

    public init(session: CPAQuotaSession) {
        self.session = session
    }

    public var body: some View {
        TabView(selection: $session.activeTab) {
            ForEach(CPAWorkspaceTab.allCases) { tab in
                NavigationStack(path: path(for: tab)) {
                    workspace(tab)
                        .navigationTitle(tab.title)
                        .background(BrandCanvasBackground())
                        .accessibilityIdentifier("workspace.\(tab.rawValue)")
                        .toolbar {
                            if tab != .usage {
                                ToolbarItem(placement: .primaryAction) {
                                    Button {
                                        Task { await session.performCurrentWorkspaceAction() }
                                    } label: {
                                        Label(session.currentWorkspaceActionLabel,
                                              systemImage: session.currentWorkspaceCanCancelRead ? "xmark" : "arrow.clockwise")
                                    }
                                    .disabled(session.currentWorkspaceActionDisabled)
                                    .accessibilityIdentifier("workspace.refresh")
                                }
                            }
                        }
                }
                .tabItem {
                    Label(tab.title, systemImage: tab.symbolName)
                        .accessibilityIdentifier("tab.\(tab.rawValue)")
                }
                .tag(tab)
            }
        }
        .tint(BrandPalette(colorScheme: colorScheme).actionTint)
        .preferredColorScheme(session.themeMode.preferredColorScheme)
        .sheet(item: presentedSheet) { sheet in
            NavigationStack {
                switch sheet {
                case .connection:
                    LoginOnboardingView(session: session, showCloseButton: true)
                case .account(let account):
                    AccountDetailSheetView(session: session, account: account)
                }
            }
            .tint(BrandPalette(colorScheme: colorScheme).actionTint)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .task { await session.restoreApplicationIfAvailable() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await session.applicationDidBecomeActive() }
        }
        .onChange(of: session.store.map(ObjectIdentifier.init)) { _, _ in
            // Account/CAP destinations from the previous accepted connection must not survive a switch.
            for tab in [CPAWorkspaceTab.quotas, .usage, .accounts, .connection] {
                paths[tab] = NavigationPath()
            }
            session.selectedAccountIDForDetail = nil
        }
        .onChange(of: session.capUsageCoordinator.store.map(ObjectIdentifier.init)) { _, _ in
            paths[.usage] = NavigationPath()
        }
        .onOpenURL { url in
            guard let destination = CPAQuotaDeepLink(url: url) else { return }
            deepLinkGeneration &+= 1
            let generation = deepLinkGeneration
            session.isPresentingConnectionSheet = false
            session.selectedAccountIDForDetail = nil
            switch destination {
            case .quotas:
                session.activeTab = .quotas
                paths[.quotas] = NavigationPath()
            case .monitoring:
                session.activeTab = .monitoring
                paths[.monitoring] = NavigationPath()
            }
            Task {
                await session.restoreApplicationIfAvailable()
                guard generation == deepLinkGeneration else { return }
                if case .monitoring(let sourceID) = destination {
                    await session.monitoringCoordinator.openSourceFromDeepLink(sourceID)
                }
            }
        }
    }

    @ViewBuilder
    private func workspace(_ tab: CPAWorkspaceTab) -> some View {
        if !session.isWorkspaceReady, tab != .connection, tab != .monitoring {
            LoginOnboardingView(session: session, showCloseButton: false)
        } else {
            switch tab {
            case .quotas: QuotasOverviewTabView(session: session)
            case .usage: CAPUsageTabView(session: session)
            case .monitoring: MonitoringTabView(session: session)
            case .accounts: AccountsDiagnosticsTabView(session: session)
            case .connection: ConnectionManagementTabView(session: session)
            }
        }
    }

    private func path(for tab: CPAWorkspaceTab) -> Binding<NavigationPath> {
        Binding(get: { paths[tab] ?? NavigationPath() }, set: { paths[tab] = $0 })
    }

    private enum PresentedSheet: Identifiable {
        case connection
        case account(CPAAccount)

        var id: String {
            switch self {
            case .connection: "connection"
            case .account(let account): "account.\(account.id)"
            }
        }
    }

    /// One presentation owner prevents a connection form and account detail competing for a sheet.
    private var presentedSheet: Binding<PresentedSheet?> {
        Binding {
            if session.isPresentingConnectionSheet { return .connection }
            guard let id = session.selectedAccountIDForDetail,
                  let account = session.accounts.first(where: { $0.id == id }) else { return nil }
            return .account(account)
        } set: { value in
            guard value == nil else { return }
            session.isPresentingConnectionSheet = false
            session.selectedAccountIDForDetail = nil
        }
    }
}
#endif
