#if canImport(ActivityKit) && canImport(WidgetKit) && canImport(SwiftUI) && os(iOS)
import ActivityKit
import SwiftUI
import WidgetKit
import CPAQuotaKit

public struct CPAQuotaLiveActivityWidget: Widget {
    public init() {}

    public var body: some WidgetConfiguration {
        ActivityConfiguration(for: CPAQuotaActivityAttributes.self) { context in
            let snapshot = context.state.snapshot
            let account = context.state.account()
            let status = CPAQuotaActivityPresentation.status(snapshot: snapshot, account: account, isStale: context.isStale)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("CPA 额度监控", systemImage: "chart.bar.xaxis")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(status)
                        .font(.caption.weight(.semibold))
                }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account?.label ?? "等待读数")
                            .font(.headline)
                            .lineLimit(1)
                        Text(account?.windowLabel ?? "等待服务端")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    Text(CPAQuotaActivityPresentation.value(account))
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .privacySensitive()
                HStack {
                    observedTime(account)
                    Spacer()
                    if snapshot.accounts.count > 1 {
                        Text("另有 \(snapshot.accounts.count - 1) 个账号 · App 内查看")
                            .font(.caption2)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.secondary)
            }
            .padding(12)
            .accessibilityElement(children: .combine)
        } dynamicIsland: { context in
            let snapshot = context.state.snapshot
            let account = context.state.account()
            let value = CPAQuotaActivityPresentation.value(account)
            let status = CPAQuotaActivityPresentation.status(snapshot: snapshot, account: account, isStale: context.isStale)
            let compactStatus = CPAQuotaActivityPresentation.compactStatus(snapshot: snapshot, account: account, isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(account?.label ?? "CPA 额度")
                        .font(.headline)
                        .lineLimit(1)
                        .privacySensitive()
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(value)
                        .font(.headline.monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .privacySensitive()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(status).fontWeight(.semibold)
                            Spacer()
                            Text(account?.windowLabel ?? "等待服务端").lineLimit(1)
                        }
                        HStack {
                            observedTime(account)
                            Spacer()
                            if snapshot.accounts.count > 1 {
                                Text("另有 \(snapshot.accounts.count - 1) 个账号")
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .accessibilityElement(children: .combine)
                }
            } compactLeading: {
                Image(systemName: compactStatus == nil ? "chart.bar.xaxis" : "exclamationmark.circle")
                    .accessibilityLabel("CPA 额度监控，\(status)")
            } compactTrailing: {
                Text(compactStatus ?? value)
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .privacySensitive()
                    .accessibilityLabel("\(status)，\(value)")
            } minimal: {
                Image(systemName: compactStatus == nil ? "chart.bar.xaxis" : "exclamationmark.circle")
                    .accessibilityLabel("CPA 额度监控，\(status)，\(value)")
            }
        }
    }

    @ViewBuilder
    private func observedTime(_ account: MonitoringAccount?) -> some View {
        if let observedAt = account?.observedAt {
            HStack(spacing: 3) {
                Text("观察于")
                Text(observedAt, style: .time)
            }
            .font(.caption2)
        } else {
            Text("观察时间未知").font(.caption2)
        }
    }
}
#endif
