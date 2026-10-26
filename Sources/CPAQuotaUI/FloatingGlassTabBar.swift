#if canImport(SwiftUI)
import SwiftUI

public struct FloatingGlassTabBar: View {
    @Bindable var session: CPAQuotaSession
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var tabNamespace

    public init(session: CPAQuotaSession) {
        self.session = session
    }

    public var body: some View {
        let palette = LiquidGlassPalette(colorScheme: colorScheme)
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(CPAWorkspaceTab.allCases) { tab in
                    let isSelected = session.activeTab == tab
                    Button {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.80)) {
                            session.activeTab = tab
                        }
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: tab.symbolName)
                                .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                            Text(tab.title)
                                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                        }
                        .foregroundStyle(isSelected ? palette.accent : palette.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .fill(palette.accentSoft)
                                    .matchedGeometryEffect(id: "activeTabSelection", in: tabNamespace)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.title)
                }
            }
            .padding(6)
            .liquidGlassCard(cornerRadius: 28, prominent: true)

            Button {
                Task {
                    if session.isBusy {
                        await session.cancelActiveOperation()
                    } else if case .connected = session.authState {
                        await session.refreshAll(force: true)
                    } else {
                        session.isPresentingConnectionSheet = true
                    }
                }
            } label: {
                ZStack {
                    if session.isBusy {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(palette.statusError)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(palette.accent)
                    }
                }
                .frame(width: 50, height: 50)
                .liquidGlassCard(cornerRadius: 25, prominent: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(session.isBusy ? "取消当前读取" : "刷新全部账号额度")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}
#endif
