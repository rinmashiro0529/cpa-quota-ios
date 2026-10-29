#if canImport(SwiftUI)
import SwiftUI
import CPAQuotaKit

public struct DynamicIslandCompanionBar: View {
    @Bindable var session: CPAQuotaSession
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var islandNamespace

    public init(session: CPAQuotaSession) {
        self.session = session
    }

    public var body: some View {
        let palette = LiquidGlassPalette(colorScheme: colorScheme)
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            let island = session.dynamicIslandState(now: context.date)
            VStack(spacing: 8) {
                if island.isExpanded {
                    expandedIslandContent(island: island, palette: palette)
                        .matchedGeometryEffect(id: "dynamicIslandContainer", in: islandNamespace)
                } else {
                    Button {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                            session.isIslandExpanded = true
                        }
                    } label: {
                        compactIslandContent(island: island, palette: palette)
                            .matchedGeometryEffect(id: "dynamicIslandContainer", in: islandNamespace)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(island.expandedTitle)
                }

                companionStatusPill(island: island, palette: palette)
                Text("应用内连接状态栏 · 系统级锁屏/灵动岛实时活动请在「监控」页配置")
                    .font(.system(size: 9.5, weight: .regular))
                    .foregroundStyle(palette.textMuted)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func compactIslandContent(
        island: DynamicIslandState,
        palette: LiquidGlassPalette
    ) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                statusIndicatorView(for: island.phase, palette: palette)
                Text(island.compactLeadingText)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(white: 0.88))
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            Text(island.compactTrailingText)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Color.white)
                .contentTransition(.numericText())
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(width: compactWidth(for: island.phase), height: 34)
        .background {
            Capsule(style: .continuous)
                .fill(Color(red: 0.035, green: 0.035, blue: 0.035))
                .shadow(color: Color.black.opacity(0.32), radius: 12, x: 0, y: 5)
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.7)
        }
    }

    @ViewBuilder
    private func expandedIslandContent(
        island: DynamicIslandState,
        palette: LiquidGlassPalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Button {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                        session.isIslandExpanded = false
                    }
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(palette.accent)
                                .frame(width: 24, height: 24)
                            Text("C")
                                .font(.system(size: 13, weight: .bold, design: .serif))
                                .foregroundStyle(Color.white)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(island.expandedTitle)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.white)
                                .lineLimit(1)

                            Text(island.expandedSubtitle)
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundStyle(Color(white: 0.68))
                                .lineLimit(1)
                        }

                        Spacer(minLength: 6)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(island.expandedTitle)，收起连接状态")
                .accessibilityValue(island.expandedSubtitle)

                if island.canCancel {
                    Button {
                        Task { await session.cancelActiveOperation() }
                    } label: {
                        Text("取消读取")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.74))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.red.opacity(0.28))
                            )
                    }
                    .buttonStyle(.plain)
                } else {
                    phasePillBadge(for: island.phase, palette: palette)
                }
            }

            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.15))
                        Capsule(style: .continuous)
                            .fill(palette.accent)
                            .frame(width: max(6, geo.size.width * island.progressFraction))
                    }
                }
                .frame(height: 5)

                Text(progressCaption(for: island))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Color(white: 0.75))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 356)
        .background {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Color(red: 0.035, green: 0.035, blue: 0.035))
                .shadow(color: Color.black.opacity(0.42), radius: 18, x: 0, y: 8)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(Color.white.opacity(0.20), lineWidth: 0.8)
        }
    }

    @ViewBuilder
    private func companionStatusPill(
        island: DynamicIslandState,
        palette: LiquidGlassPalette
    ) -> some View {
        HStack(spacing: 8) {
            switch island.phase {
            case .unconfigured:
                Image(systemName: "lock.shield")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.statusWarn)
                Text("未配置连接 · 仅支持 HTTPS 与管理密钥")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.textSecondary)

            case .syncing(let isLoadingInventory, let completed, let total):
                ProgressView()
                    .controlSize(.mini)
                    .tint(palette.accent)
                Text(isLoadingInventory ? "正在读取 auth-files 账号列表…" : "已更新额度 \(completed)/\(total)")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(palette.textPrimary)
                Button {
                    Task { await session.cancelActiveOperation() }
                } label: {
                    Text("取消")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            Capsule(style: .continuous)
                                .fill(palette.accentSoft)
                        )
                }
                .buttonStyle(.plain)

            case .rateLimited(_, let remainingSeconds):
                Image(systemName: "hourglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.statusWarn)
                Text("Retry-After 冷却等待 \(remainingSeconds)s · 到期前不强制重试")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(palette.textPrimary)

            case .managementBlocked(let kind):
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.statusError)
                Text("管理层鉴权阻断 (\(kind.rawValue)) · 已暂停队列")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.statusError)

            case .connectionFailed(let kind):
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.statusError)
                Text(ErrorPresentation(error: CPAError(kind)).title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.statusError)

            case .idle(let host, let activeCount, let totalCount):
                Circle()
                    .fill(palette.statusOK)
                    .frame(width: 6, height: 6)
                Text(host.replacingOccurrences(of: "https://", with: ""))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
                Text("|")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textMuted)
                Text("\(activeCount) 启用 / \(totalCount) 账号")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(palette.textPrimary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .liquidGlassPill(cornerRadius: 20)
    }

    @ViewBuilder
    private func statusIndicatorView(
        for phase: DynamicIslandState.Phase,
        palette: LiquidGlassPalette
    ) -> some View {
        switch phase {
        case .unconfigured:
            Circle()
                .fill(Color.orange)
                .frame(width: 7, height: 7)
        case .idle:
            Circle()
                .fill(Color.green)
                .frame(width: 7, height: 7)
        case .syncing:
            ProgressView()
                .controlSize(.mini)
                .tint(palette.accent)
        case .rateLimited:
            Image(systemName: "hourglass")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.orange)
        case .managementBlocked, .connectionFailed:
            Circle()
                .fill(Color.red)
                .frame(width: 7, height: 7)
        }
    }

    @ViewBuilder
    private func phasePillBadge(
        for phase: DynamicIslandState.Phase,
        palette: LiquidGlassPalette
    ) -> some View {
        switch phase {
        case .unconfigured:
            Text("未连接")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.orange.opacity(0.22)))
        case .idle:
            Text("LIVE")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.green.opacity(0.22)))
        case .syncing:
            EmptyView()
        case .rateLimited(_, let remaining):
            Text("\(remaining)s")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Color.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.orange.opacity(0.24)))
        case .connectionFailed:
            Text("异常")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.red)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.red.opacity(0.24)))
        case .managementBlocked:
            Text("阻断")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.red)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.red.opacity(0.24)))
        }
    }

    private func progressCaption(for island: DynamicIslandState) -> String {
        if case .syncing(let isLoadingInventory, let completed, let total) = island.phase {
            return isLoadingInventory ? "读取中" : "\(completed)/\(total) 已更新"
        }
        return "轻点收起"
    }

    private func compactWidth(for phase: DynamicIslandState.Phase) -> CGFloat {
        switch phase {
        case .syncing, .rateLimited, .connectionFailed:
            return 208
        case .unconfigured, .idle, .managementBlocked:
            return 168
        }
    }
}
#endif
