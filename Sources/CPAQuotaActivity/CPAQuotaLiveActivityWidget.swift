#if canImport(ActivityKit) && canImport(WidgetKit) && canImport(SwiftUI) && os(iOS)
import ActivityKit
import SwiftUI
import WidgetKit
import CPAQuotaKit

public struct CPAQuotaLiveActivityWidget: Widget {
    public init() {}

    public var body: some WidgetConfiguration {
        ActivityConfiguration(for: CPAQuotaActivityAttributes.self) { context in
            QuotaLockScreenActivityView(state: context.state, isStale: context.isStale)
                .widgetURL(CPAQuotaDeepLink.monitoring(sourceID: context.attributes.sourceID).url)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("额度监控", systemImage: "chart.bar.xaxis")
                        .font(.caption.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(activityStatus(context.state, isStale: context.isStale))
                        .font(.caption.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    QuotaActivityDetailView(state: context.state, isStale: context.isStale)
                }
            } compactLeading: {
                QuotaActivityCompactView(state: context.state, isStale: context.isStale, role: .leading)
            } compactTrailing: {
                QuotaActivityCompactView(state: context.state, isStale: context.isStale, role: .trailing)
            } minimal: {
                QuotaActivityCompactView(state: context.state, isStale: context.isStale, role: .minimal)
            }
            .widgetURL(CPAQuotaDeepLink.monitoring(sourceID: context.attributes.sourceID).url)
        }
    }
}

private func activityStatus(_ state: CPAQuotaLiveActivityState, isStale: Bool) -> String {
    CPAQuotaActivityPresentation.status(snapshot: state.snapshot, account: state.account(), isStale: isStale)
}

private func activitySymbol(_ state: CPAQuotaLiveActivityState, isStale: Bool) -> String {
    let status = CPAQuotaActivityPresentation.compactStatus(snapshot: state.snapshot, account: state.account(), isStale: isStale)
    switch status {
    case "结束", "到期": return "checkmark.circle"
    case "旧值": return "clock.badge.exclamationmark"
    case "失败": return "exclamationmark.triangle"
    case "限流": return "hourglass"
    case "未知": return "questionmark.circle"
    case "部分": return "exclamationmark.circle"
    default: return "chart.bar.xaxis"
    }
}

private struct QuotaLockScreenActivityView: View {
    let state: CPAQuotaLiveActivityState
    let isStale: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !dynamicTypeSize.isAccessibilitySize {
                HStack(alignment: .firstTextBaseline) {
                    Label("CPA 额度监控", systemImage: "chart.bar.xaxis")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(activityStatus(state, isStale: isStale))
                        .font(.caption.weight(.semibold))
                }
            }
            QuotaActivityDetailView(state: state, isStale: isStale)
        }
        .padding()
    }
}

private struct QuotaActivityDetailView: View {
    let state: CPAQuotaLiveActivityState
    let isStale: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var account: MonitoringAccount? { state.account() }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if dynamicTypeSize.isAccessibilitySize {
                Text(CPAQuotaActivityPresentation.value(account))
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .privacySensitive()
                Text(activityStatus(state, isStale: isStale))
                    .font(.caption)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        accountHeading
                        Spacer(minLength: 0)
                        reading
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        accountHeading
                        reading
                    }
                }
            }
            HStack(alignment: .firstTextBaseline) {
                if let observedAt = account?.observedAt {
                    Text("观察于 \(observedAt, format: .dateTime.hour().minute())")
                } else {
                    Text("观察时间未知")
                }
                if !dynamicTypeSize.isAccessibilitySize, state.accounts.count > 1 {
                    Spacer(minLength: 8)
                    Text("另有 \(state.accounts.count - 1) 个账号")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        // expiresAt describes snapshot freshness, not the remote lease. There
        // is deliberately no fabricated lease timer on any Activity surface.
    }

    private var accountHeading: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(account?.label ?? "等待读数")
                .font(.headline)
            Text(account?.windowLabel ?? "等待首次采集")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .privacySensitive()
    }

    private var reading: some View {
        Text(CPAQuotaActivityPresentation.value(account))
            .font(.title3.weight(.semibold).monospacedDigit())
            .fixedSize()
            .privacySensitive()
            .accessibilityLabel("最近读数，\(CPAQuotaActivityPresentation.value(account))，\(activityStatus(state, isStale: isStale))")
    }
}

private enum QuotaActivityCompactRole: Equatable { case leading, trailing, minimal }

private struct QuotaActivityCompactView: View {
    let state: CPAQuotaLiveActivityState
    let isStale: Bool
    let role: QuotaActivityCompactRole

    @ViewBuilder
    var body: some View {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            QuotaActivityLimitedWidthView(state: state, isStale: isStale, role: role)
        } else {
            QuotaActivityCompactContent(state: state, isStale: isStale, role: role, isLimited: false)
        }
        #else
        QuotaActivityCompactContent(state: state, isStale: isStale, role: role, isLimited: false)
        #endif
    }
}

#if compiler(>=6.4)
@available(iOS 27.0, *)
private struct QuotaActivityLimitedWidthView: View {
    let state: CPAQuotaLiveActivityState
    let isStale: Bool
    let role: QuotaActivityCompactRole
    @Environment(\.isDynamicIslandLimitedInWidth) private var isLimited

    var body: some View {
        QuotaActivityCompactContent(state: state, isStale: isStale, role: role, isLimited: isLimited)
    }
}
#endif

private struct QuotaActivityCompactContent: View {
    let state: CPAQuotaLiveActivityState
    let isStale: Bool
    let role: QuotaActivityCompactRole
    let isLimited: Bool

    private var status: String { activityStatus(state, isStale: isStale) }

    @ViewBuilder
    var body: some View {
        if role == .trailing && !isLimited {
            let text = CPAQuotaActivityPresentation.compactStatus(snapshot: state.snapshot, account: state.account(), isStale: isStale)
                ?? CPAQuotaActivityPresentation.value(state.account())
            ViewThatFits(in: .horizontal) {
                Text(text)
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .fixedSize()
                    .privacySensitive()
                    .accessibilityLabel("\(status)，\(text)")
                statusIcon
            }
        } else {
            // The OS owns the island's frame. Small presentations convey the
            // actual status with one symbol; expanded/Lock Screen retain values.
            statusIcon
        }
    }

    private var statusIcon: some View {
        Image(systemName: activitySymbol(state, isStale: isStale))
            .font(.caption.weight(.semibold))
            .accessibilityLabel("CPA 额度监控，\(status)")
        // No numeric value in the minimal accessibility label, including when
        // the system hides sensitive content on the Lock Screen.
    }
}
#endif
