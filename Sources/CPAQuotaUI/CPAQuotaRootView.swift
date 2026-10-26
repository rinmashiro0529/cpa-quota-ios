#if canImport(SwiftUI)
import SwiftUI
import CPAQuotaKit

public struct CPAQuotaRootView: View {
    @Bindable var session: CPAQuotaSession
    @State private var didPerformInitialRestore = false

    public init(session: CPAQuotaSession) {
        self.session = session
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            AmbientGlassCanvasBackground()

            VStack(spacing: 0) {
                DynamicIslandCompanionBar(session: session)

                ScrollView {
                    VStack(spacing: 16) {
                        if case .unconfigured = session.authState, session.activeTab != .connection {
                            LoginOnboardingView(session: session, showCloseButton: false)
                                .padding(.top, 8)
                        } else {
                            switch session.activeTab {
                            case .quotas:
                                QuotasOverviewTabView(session: session)
                            case .accounts:
                                AccountsDiagnosticsTabView(session: session)
                            case .connection:
                                ConnectionManagementTabView(session: session)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 108)
                }
                .refreshable {
                    if case .connected = session.authState {
                        await session.refreshAll(force: true)
                    }
                }
            }

            FloatingGlassTabBar(session: session)
        }
        .preferredColorScheme(session.themeMode.preferredColorScheme)
        .sheet(isPresented: $session.isPresentingConnectionSheet) {
            ScrollView {
                LoginOnboardingView(session: session, showCloseButton: true)
                    .padding(20)
            }
            .background(AmbientGlassCanvasBackground())
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(
            item: Binding<CPAAccount?>(
                get: {
                    guard let id = session.selectedAccountIDForDetail else { return nil }
                    return session.accounts.first(where: { $0.id == id })
                },
                set: { newValue in
                    session.selectedAccountIDForDetail = newValue?.id
                }
            )
        ) { selectedAccount in
            AccountDetailSheetView(session: session, account: selectedAccount)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .task {
            guard !didPerformInitialRestore else { return }
            didPerformInitialRestore = true
            await session.restoreSessionIfAvailable()
        }
    }
}
#endif
