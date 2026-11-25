#if canImport(WidgetKit) && canImport(SwiftUI) && canImport(AppIntents) && os(iOS)
import AppIntents
import SwiftUI
import WidgetKit

public struct CPAQuotaWidgetIntentsPackage: AppIntentsPackage {
    public init() {}
}

/// Only the opaque shared ID and safe labels are exposed to widget configuration.
public struct QuotaWidgetAccountEntity: AppEntity, Hashable {
    public let id: String
    public let label: String
    public let windowLabel: String
    public let provider: String

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "账号主要读数" }
    public static var defaultQuery: QuotaWidgetAccountQuery { QuotaWidgetAccountQuery() }
    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(label)", subtitle: "\(provider) · \(windowLabel)")
    }

    public init(entry: QuotaWidgetEntry) {
        id = entry.id
        label = entry.label
        windowLabel = entry.windowLabel
        provider = entry.provider
    }
}

public struct QuotaWidgetAccountQuery: EntityQuery {
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [QuotaWidgetAccountEntity] {
        let entries = SharedQuotaWidgetSnapshotStore().read()?.entries ?? []
        return entries.filter { identifiers.contains($0.id) }.map(QuotaWidgetAccountEntity.init(entry:))
    }

    public func suggestedEntities() async throws -> [QuotaWidgetAccountEntity] {
        (SharedQuotaWidgetSnapshotStore().read()?.entries ?? []).map(QuotaWidgetAccountEntity.init(entry:))
    }
}

public struct QuotaWidgetConfiguration: WidgetConfigurationIntent {
    public static var title: LocalizedStringResource { "选择账号主要读数" }
    public static var description: IntentDescription { "选择已在应用中允许共享的账号主要读数；留空显示概况，更多窗口请在应用中查看。" }

    @Parameter(title: "账号主要读数")
    public var account: QuotaWidgetAccountEntity?

    public init() {}
}

public struct CPAQuotaWidget: Widget {
    public init() {}

    public var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: SharedQuotaWidgetSnapshotStore.widgetKind,
                               intent: QuotaWidgetConfiguration.self, provider: QuotaWidgetProvider()) { entry in
            QuotaWidgetContent(entry: entry)
                .containerBackground(for: .widget) { QuotaWidgetCanvas() }
                .widgetURL(CPAQuotaDeepLink.quotas.url)
        }
        .configurationDisplayName("CPA 配额")
        .description("查看最近观察到的配额与数据时间。请先在应用设置中启用小组件共享。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryCircular])
    }
}

private struct QuotaWidgetCanvas: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        colorScheme == .dark
            ? Color(red: 0.075, green: 0.071, blue: 0.067)
            : Color(red: 0.980, green: 0.973, blue: 0.957)
    }
}

private struct QuotaWidgetTimelineEntry: TimelineEntry {
    let date: Date
    let snapshot: QuotaWidgetSnapshot?
    let selectedID: String?

    var selectedEntries: [QuotaWidgetEntry] {
        guard let snapshot else { return [] }
        guard let selectedID else { return snapshot.entries }
        // A missing selection never silently switches to a different account.
        return snapshot.entries.filter { $0.id == selectedID }
    }
}

private struct QuotaWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> QuotaWidgetTimelineEntry {
        QuotaWidgetTimelineEntry(date: Date(), snapshot: nil, selectedID: nil)
    }

    func snapshot(for configuration: QuotaWidgetConfiguration, in context: Context) async -> QuotaWidgetTimelineEntry {
        QuotaWidgetTimelineEntry(date: Date(), snapshot: SharedQuotaWidgetSnapshotStore().read(),
                                selectedID: configuration.account?.id)
    }

    func timeline(for configuration: QuotaWidgetConfiguration, in context: Context) async -> Timeline<QuotaWidgetTimelineEntry> {
        let now = Date()
        let shared = SharedQuotaWidgetSnapshotStore().read()
        let first = QuotaWidgetTimelineEntry(date: now, snapshot: shared, selectedID: configuration.account?.id)
        let dates = QuotaWidgetSnapshot.timelineDates(now: now, entries: first.selectedEntries)
        let entries = dates.map {
            QuotaWidgetTimelineEntry(date: $0, snapshot: shared, selectedID: configuration.account?.id)
        }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(900)))
    }
}

private struct QuotaWidgetContent: View {
    let entry: QuotaWidgetTimelineEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color {
        colorScheme == .dark
            ? Color(red: 0.886, green: 0.502, blue: 0.376)
            : Color(red: 0.824, green: 0.427, blue: 0.298)
    }
    private var displayDate: Date { max(entry.date, Date()) }

    private var limit: Int {
        if dynamicTypeSize.isAccessibilitySize { return 1 }
        switch family {
        case .systemLarge: return 3
        case .systemMedium: return 2
        default: return 1
        }
    }

    @ViewBuilder
    var body: some View {
        if family == .accessoryCircular {
            circular
        } else if family == .accessoryRectangular {
            rectangular
        } else {
            ViewThatFits(in: .vertical) {
                overview.fixedSize(horizontal: false, vertical: true)
                compactOverview
            }
        }
    }

    private var overview: some View {
            VStack(alignment: .leading, spacing: 8) {
                Label("配额概况", systemImage: "chart.bar.xaxis")
                    .font(.caption.weight(.semibold))
                    .widgetAccentable()
                if entry.selectedEntries.isEmpty {
                    empty
                } else {
                    ForEach(Array(entry.selectedEntries.prefix(limit))) { account in
                        widgetRow(account)
                    }
                    if entry.selectedEntries.count > limit {
                        Text("另有 \(entry.selectedEntries.count - limit) 项 · 打开应用查看")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
    }

    @ViewBuilder
    private var compactOverview: some View {
        if let account = entry.selectedEntries.first {
            VStack(alignment: .leading, spacing: 4) {
                Text(account.label).font(.caption).lineLimit(1)
                HStack(spacing: 8) {
                    ViewThatFits(in: .horizontal) {
                        Text(account.formattedValue)
                            .font(.headline.monospacedDigit())
                            .fixedSize()
                        Text("打开查看").font(.caption)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: statusSymbol(account))
                }
            }
            .privacySensitive()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(account.label)，\(account.windowLabel)，\(account.formattedValue)，\(statusText(account))")
            .accessibilityValue(account.observedAt.map {
                "观察于 \($0.formatted(date: .abbreviated, time: .shortened))"
            } ?? "观察时间未知")
        } else {
            Text("打开 CPA Quota 查看额度").font(.caption)
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.selectedID == nil ? "尚无共享读数" : "此配额窗口暂不可用")
                .font(.headline)
            Text("打开应用，启用小组件共享并刷新配额。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func widgetRow(_ account: QuotaWidgetEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(account.label)
                .font(.subheadline.weight(.semibold))
            Text(account.windowLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if family == .systemSmall || dynamicTypeSize.isAccessibilitySize {
                Text(account.formattedValue)
                    .font(.title3.weight(.semibold).monospacedDigit())
                statusAndTime(account)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(account.formattedValue)
                        .font(.headline.monospacedDigit())
                    Spacer(minLength: 0)
                    statusAndTime(account)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .privacySensitive()
        .accessibilityElement(children: .combine)
    }

    private func statusAndTime(_ account: QuotaWidgetEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(statusText(account), systemImage: statusSymbol(account))
            if let observedAt = account.observedAt {
                Text(observedAt, format: .dateTime.hour().minute())
                    .accessibilityLabel("观察于 \(observedAt.formatted(date: .abbreviated, time: .shortened))")
            } else {
                Text("观察时间未知")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var rectangular: some View {
        if let account = entry.selectedEntries.first {
            VStack(alignment: .leading) {
                Text(account.label).font(.headline)
                Text("\(account.formattedValue) · \(statusText(account))").font(.caption)
                if let observedAt = account.observedAt {
                    Text("观察于 \(observedAt, format: .dateTime.hour().minute())").font(.caption2)
                }
            }
            .privacySensitive()
            .accessibilityElement(children: .combine)
        } else {
            Label("打开 CPA Quota 查看额度", systemImage: "chart.bar.xaxis")
        }
    }

    @ViewBuilder
    private var circular: some View {
        if let account = entry.selectedEntries.first,
           account.status(at: displayDate) == .ready, let remaining = account.remainingFraction {
            Gauge(value: remaining) {
                Text("剩余")
            } currentValueLabel: {
                Text(account.formattedValue).monospacedDigit()
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(accent)
            .privacySensitive()
            .accessibilityLabel("\(account.label)，\(account.windowLabel)")
            .accessibilityValue("剩余 \(account.formattedValue)")
        } else {
            Image(systemName: entry.selectedEntries.first.map(statusSymbol) ?? "questionmark.circle")
                .accessibilityLabel(entry.selectedEntries.first.map(statusText) ?? "配额未知，打开应用查看")
        }
    }

    private func statusText(_ account: QuotaWidgetEntry) -> String {
        switch account.status(at: displayDate) {
        case .ready: return "最近读数"
        case .stale: return "上次读数"
        case .unavailable: return "暂不可用"
        case .failed: return "读取失败"
        }
    }

    private func statusSymbol(_ account: QuotaWidgetEntry) -> String {
        switch account.status(at: displayDate) {
        case .ready: return "clock"
        case .stale: return "clock.badge.exclamationmark"
        case .unavailable: return "questionmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }
}
#endif
