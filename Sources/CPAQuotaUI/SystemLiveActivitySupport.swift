import Foundation
import CPAQuotaKit
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif
#if canImport(WidgetKit) && os(iOS)
import WidgetKit
#endif

public struct CPAQuotaLiveActivityState: Codable, Hashable, Sendable {
    public let snapshotData: Data
    public let focusedIndex: Int

    public init(snapshot: MonitoringSnapshot, focusedIndex: Int = 0) throws {
        let data = try snapshot.activityContentData()
        guard data.count <= 3_584 else {
            throw MonitoringError.invalidConfiguration
        }
        self.snapshotData = data
        self.focusedIndex = max(0, focusedIndex)
    }

    public func decodedSnapshot() -> MonitoringSnapshot? {
        try? JSONDecoder().decode(MonitoringSnapshot.self, from: snapshotData)
    }

    public var accounts: [MonitoringAccount] {
        decodedSnapshot()?.accounts ?? []
    }

    public var focusedAccount: MonitoringAccount? {
        let list = accounts
        guard !list.isEmpty else { return nil }
        return list[focusedIndex % list.count]
    }

    public func rotated() throws -> CPAQuotaLiveActivityState {
        guard let snap = decodedSnapshot() else {
            throw MonitoringError.invalidConfiguration
        }
        let nextIndex = snap.accounts.isEmpty ? 0 : (focusedIndex + 1) % snap.accounts.count
        return try CPAQuotaLiveActivityState(snapshot: snap, focusedIndex: nextIndex)
    }
}

#if canImport(ActivityKit) && os(iOS)
public struct CPAQuotaActivityAttributes: ActivityAttributes, Sendable {
    public typealias ContentState = CPAQuotaLiveActivityState

    public let sourceID: String

    public init(sourceID: String) throws {
        guard !sourceID.isEmpty, sourceID.utf8.count <= 128, !sourceID.contains("@"), !sourceID.contains("://") else {
            throw MonitoringError.invalidConfiguration
        }
        self.sourceID = sourceID
    }
}
#endif

@MainActor
public final class DefaultSystemLiveActivityDriver: SystemLiveActivityDriver {
    public private(set) var activeActivityID: String?
    public private(set) var latestPushTokenHex: String?
    public var selectedRotationIndex: Int = 0

    #if canImport(ActivityKit) && os(iOS)
    private var tokenObservationTask: Task<Void, Never>?
    private var stateObservationTask: Task<Void, Never>?
    private var lastSnapshot: MonitoringSnapshot?
    #endif

    public init() {}

    public var isSupportedOnCurrentPlatform: Bool {
        #if canImport(ActivityKit) && os(iOS)
        return true
        #else
        return false
        #endif
    }

    public var areActivitiesEnabled: Bool {
        #if canImport(ActivityKit) && os(iOS)
        return ActivityAuthorizationInfo().areActivitiesEnabled
        #else
        return false
        #endif
    }

    public func startActivity(
        sourceID: String,
        initialSnapshot: MonitoringSnapshot?,
        onPushTokenUpdate: @escaping @MainActor (String) -> Void,
        onSystemDismissed: @escaping @MainActor (String) -> Void
    ) async throws -> LocalLiveActivityRegistrationResult {
        #if canImport(ActivityKit) && os(iOS)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            throw LocalLiveActivityError.activitiesDisabled
        }
        let attributes: CPAQuotaActivityAttributes
        let fallbackSnapshot: MonitoringSnapshot
        if let initialSnapshot {
            fallbackSnapshot = initialSnapshot
        } else {
            let placeholderAccount = try MonitoringAccount(
                id: "pending",
                label: "Waiting for quota",
                provider: "cpa",
                windowID: "default",
                windowLabel: "Pending",
                status: .unavailable
            )
            fallbackSnapshot = try MonitoringSnapshot(
                sequence: 0,
                phase: .ready,
                generatedAt: Date(),
                expiresAt: Date().addingTimeInterval(600),
                accounts: [placeholderAccount]
            )
        }
        do {
            attributes = try CPAQuotaActivityAttributes(sourceID: sourceID)
        } catch {
            throw LocalLiveActivityError.startFailed
        }
        let contentState: CPAQuotaLiveActivityState
        do {
            contentState = try CPAQuotaLiveActivityState(snapshot: fallbackSnapshot, focusedIndex: selectedRotationIndex)
        } catch {
            throw LocalLiveActivityError.payloadTooLarge
        }

        let content = ActivityContent(state: contentState, staleDate: fallbackSnapshot.expiresAt)
        let activity: Activity<CPAQuotaActivityAttributes>
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: .token
            )
        } catch {
            throw LocalLiveActivityError.startFailed
        }

        self.activeActivityID = activity.id
        self.lastSnapshot = fallbackSnapshot
        let initialTokenHex = activity.pushToken.map { data in
            data.map { String(format: "%02x", $0) }.joined()
        }
        self.latestPushTokenHex = initialTokenHex

        tokenObservationTask?.cancel()
        tokenObservationTask = Task { [weak self] in
            for await tokenData in activity.pushTokenUpdates {
                let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                await MainActor.run {
                    self?.latestPushTokenHex = hex
                    onPushTokenUpdate(hex)
                }
            }
        }

        stateObservationTask?.cancel()
        stateObservationTask = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                if state == .dismissed || state == .ended {
                    let dismissedID = activity.id
                    await MainActor.run {
                        if self?.activeActivityID == dismissedID {
                            self?.activeActivityID = nil
                        }
                        onSystemDismissed(dismissedID)
                    }
                }
            }
        }

        return LocalLiveActivityRegistrationResult(
            activityID: activity.id,
            initialPushTokenHex: initialTokenHex
        )
        #else
        throw LocalLiveActivityError.unsupportedPlatform
        #endif
    }

    public func updateActivity(snapshot: MonitoringSnapshot) async throws {
        #if canImport(ActivityKit) && os(iOS)
        self.lastSnapshot = snapshot
        guard let targetID = activeActivityID,
              let activity = Activity<CPAQuotaActivityAttributes>.activities.first(where: { $0.id == targetID }) else {
            return
        }
        let state = try CPAQuotaLiveActivityState(snapshot: snapshot, focusedIndex: selectedRotationIndex)
        let content = ActivityContent(state: state, staleDate: snapshot.expiresAt)
        await activity.update(content)
        #endif
    }

    public func endActivity(immediate: Bool) async {
        #if canImport(ActivityKit) && os(iOS)
        tokenObservationTask?.cancel()
        tokenObservationTask = nil
        stateObservationTask?.cancel()
        stateObservationTask = nil
        for activity in Activity<CPAQuotaActivityAttributes>.activities {
            if activeActivityID == nil || activity.id == activeActivityID {
                await activity.end(nil, dismissalPolicy: immediate ? .immediate : .default)
            }
        }
        activeActivityID = nil
        latestPushTokenHex = nil
        #else
        activeActivityID = nil
        latestPushTokenHex = nil
        #endif
    }
}

/// Testable / synthetic driver used strictly in automated tests or explicit preview mode.
@MainActor
public final class SyntheticLiveActivityDriver: SystemLiveActivityDriver {
    public var isSupportedOnCurrentPlatform: Bool
    public var areActivitiesEnabled: Bool
    public private(set) var activeActivityID: String?
    public private(set) var latestPushTokenHex: String?
    public var selectedRotationIndex: Int = 0
    public private(set) var lastUpdatedSnapshot: MonitoringSnapshot?
    public private(set) var endedImmediately: Bool?

    private var pushTokenCallback: (@MainActor (String) -> Void)?
    private var dismissCallback: (@MainActor (String) -> Void)?
    private let simulatedActivityID: String
    private let simulatedPushTokenHex: String?

    public init(
        isSupported: Bool = true,
        areEnabled: Bool = true,
        simulatedActivityID: String = "synthetic-live-activity-1",
        simulatedPushTokenHex: String? = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    ) {
        self.isSupportedOnCurrentPlatform = isSupported
        self.areActivitiesEnabled = areEnabled
        self.simulatedActivityID = simulatedActivityID
        self.simulatedPushTokenHex = simulatedPushTokenHex
    }

    public func startActivity(
        sourceID: String,
        initialSnapshot: MonitoringSnapshot?,
        onPushTokenUpdate: @escaping @MainActor (String) -> Void,
        onSystemDismissed: @escaping @MainActor (String) -> Void
    ) async throws -> LocalLiveActivityRegistrationResult {
        guard isSupportedOnCurrentPlatform else { throw LocalLiveActivityError.unsupportedPlatform }
        guard areActivitiesEnabled else { throw LocalLiveActivityError.activitiesDisabled }
        if let initialSnapshot {
            _ = try CPAQuotaLiveActivityState(snapshot: initialSnapshot, focusedIndex: selectedRotationIndex)
        }
        activeActivityID = simulatedActivityID
        latestPushTokenHex = simulatedPushTokenHex
        lastUpdatedSnapshot = initialSnapshot
        pushTokenCallback = onPushTokenUpdate
        dismissCallback = onSystemDismissed
        return LocalLiveActivityRegistrationResult(
            activityID: simulatedActivityID,
            initialPushTokenHex: simulatedPushTokenHex
        )
    }

    public func updateActivity(snapshot: MonitoringSnapshot) async throws {
        _ = try CPAQuotaLiveActivityState(snapshot: snapshot, focusedIndex: selectedRotationIndex)
        lastUpdatedSnapshot = snapshot
    }

    public func endActivity(immediate: Bool) async {
        endedImmediately = immediate
        activeActivityID = nil
        latestPushTokenHex = nil
    }

    public func simulateSystemPushTokenRotation(_ newHex: String) {
        latestPushTokenHex = newHex
        pushTokenCallback?(newHex)
    }

    public func simulateUserDismissal() {
        let id = activeActivityID ?? simulatedActivityID
        activeActivityID = nil
        dismissCallback?(id)
    }
}

#if canImport(SwiftUI)
public struct SystemLiveActivityPreviewCard: View {
    public let sourceID: String
    public let snapshot: MonitoringSnapshot
    @Binding public var focusedIndex: Int
    public let palette: LiquidGlassPalette

    public init(
        sourceID: String,
        snapshot: MonitoringSnapshot,
        focusedIndex: Binding<Int>,
        palette: LiquidGlassPalette
    ) {
        self.sourceID = sourceID
        self.snapshot = snapshot
        self._focusedIndex = focusedIndex
        self.palette = palette
    }

    public var body: some View {
        let accounts = snapshot.accounts
        let safeIndex = accounts.isEmpty ? 0 : (focusedIndex % accounts.count)
        let currentAccount = accounts.isEmpty ? nil : accounts[safeIndex]

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("系统活动安全载荷视图 (MonitoringSnapshot)", systemImage: "platter.filled.top.iphone")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                Spacer()
                Text("seq #\(snapshot.sequence) · \(snapshot.phase.rawValue)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(palette.accent)
            }

            if let currentAccount {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(currentAccount.label)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.textPrimary)
                        Text(currentAccount.provider.uppercased())
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(palette.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(palette.accentSoft))
                        Spacer()
                        Text("状态: \(currentAccount.status.rawValue)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(palette.textSecondary)
                    }

                    HStack {
                        Text("\(currentAccount.windowLabel) (\(currentAccount.windowID))")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.textSecondary)
                        Spacer()
                        if let rem = currentAccount.remainingFraction {
                            Text(String(format: "%.0f%% 剩余", (rem * 100).rounded()))
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(palette.statusOK)
                        } else if let val = currentAccount.value {
                            Text("\(String(format: "%.2f", val)) \(currentAccount.unit ?? "")")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(palette.textPrimary)
                        } else {
                            Text("读数未知 (nil)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(palette.statusWarn)
                        }
                    }

                    HStack {
                        Text("观察时间: \(QuotaFormatter.exactTimestampString(currentAccount.observedAt))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(palette.textMuted)
                        Spacer()
                        if accounts.count > 1 {
                            Button {
                                focusedIndex = (safeIndex + 1) % accounts.count
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                    Text("切换展示账号 (\(safeIndex + 1)/\(accounts.count))")
                                }
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(palette.accent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(10)
                .liquidGlassPill(cornerRadius: 14)
            } else {
                Text("当前监控快照暂无可显示的授权安全账号别名。")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textSecondary)
            }

            if let payloadBytes = try? snapshot.activityContentData().count {
                Text("动态载荷体积: \(payloadBytes) / 3584 Bytes 预算上限 · 不含原始邮箱/管理密钥/URL")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(palette.textMuted)
            }
        }
        .padding(14)
        .liquidGlassCard(cornerRadius: 20)
    }
}
#endif

#if canImport(ActivityKit) && canImport(WidgetKit) && canImport(SwiftUI) && os(iOS)
public struct CPAQuotaLiveActivityWidget: Widget {
    public init() {}

    public var body: some WidgetConfiguration {
        ActivityConfiguration(for: CPAQuotaActivityAttributes.self) { context in
            let snapshot = context.state.decodedSnapshot()
            let account = context.state.focusedAccount
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("CPA 额度监控 · \(context.attributes.sourceID)")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if let snapshot {
                        Text("seq #\(snapshot.sequence) · \(snapshot.phase.rawValue)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                if let account {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(account.label) · \(account.windowLabel)")
                                .font(.system(size: 13, weight: .bold))
                            Text("观察: \(QuotaFormatter.exactTimestampString(account.observedAt))")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let rem = account.remainingFraction {
                            Text(String(format: "%.0f%%", (rem * 100).rounded()))
                                .font(.system(size: 16, weight: .bold, design: .monospaced))
                        } else if let val = account.value {
                            Text("\(String(format: "%.1f", val)) \(account.unit ?? "")")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                        } else {
                            Text(account.status.rawValue)
                                .font(.system(size: 12, design: .monospaced))
                        }
                    }
                } else {
                    Text("等待授权来源快照更新…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
        } dynamicIsland: { context in
            let account = context.state.focusedAccount
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(account?.label ?? context.attributes.sourceID)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let rem = account?.remainingFraction {
                        Text(String(format: "%.0f%%", (rem * 100).rounded()))
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                    } else {
                        Text(account?.status.rawValue ?? "--")
                            .font(.system(size: 11, design: .monospaced))
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(account?.windowLabel ?? "监控会话")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(QuotaFormatter.exactTimestampString(account?.observedAt))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Text(account?.provider.prefix(4).uppercased() ?? "CPA")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            } compactTrailing: {
                if let rem = account?.remainingFraction {
                    Text(String(format: "%.0f%%", (rem * 100).rounded()))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                } else {
                    Text("--")
                        .font(.system(size: 11, design: .monospaced))
                }
            } minimal: {
                Text("Q")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
            }
        }
    }
}
#endif
