import Foundation
import CPAQuotaKit
import CPAQuotaActivity
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif

public typealias CPAQuotaLiveActivityState = CPAQuotaActivity.CPAQuotaLiveActivityState
public typealias CPAQuotaActivityAttributes = CPAQuotaActivity.CPAQuotaActivityAttributes
#if canImport(ActivityKit) && canImport(WidgetKit) && canImport(SwiftUI) && os(iOS)
public typealias CPAQuotaLiveActivityWidget = CPAQuotaActivity.CPAQuotaLiveActivityWidget
#endif

@MainActor
public final class DefaultSystemLiveActivityDriver: SystemLiveActivityDriver {
    public private(set) var activeActivityID: String?
    public private(set) var latestPushTokenHex: String?
    // Kept for source compatibility; selection belongs to the in-app preview.
    public var selectedRotationIndex: Int = 0
    private var observationID = UUID()
    private var tokenObservationTask: Task<Void, Never>?
    private var stateObservationTask: Task<Void, Never>?

    public init() {}

    deinit {
        tokenObservationTask?.cancel()
        stateObservationTask?.cancel()
    }

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
        onPushTokenUpdate: @escaping @MainActor (String, String) -> Void,
        onSystemDismissed: @escaping @MainActor (String) -> Void
    ) async throws -> LocalLiveActivityRegistrationResult {
        #if canImport(ActivityKit) && os(iOS)
        try Task.checkCancellation()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            throw LocalLiveActivityError.activitiesDisabled
        }
        guard activeActivityID == nil else { throw LocalLiveActivityError.startFailed }
        let attributes = try CPAQuotaActivityAttributes(sourceID: sourceID)
        let now = Date()
        let snapshot = try initialSnapshot ?? MonitoringSnapshot(
            sequence: 0, phase: .partial, generatedAt: now, expiresAt: now,
            accounts: [MonitoringAccount(id: "pending", label: "等待读数", provider: "cpa",
                                         windowID: "pending", windowLabel: "等待服务端", status: .unavailable)]
        )
        let state = try CPAQuotaLiveActivityState(snapshot: snapshot)
        do {
            try attributes.validateContent(state)
        } catch {
            throw LocalLiveActivityError.payloadTooLarge
        }
        let activity: Activity<CPAQuotaActivityAttributes>
        do {
            activity = try Activity.request(attributes: attributes,
                                            content: ActivityContent(state: state, staleDate: snapshot.expiresAt),
                                            pushType: .token)
        } catch {
            throw LocalLiveActivityError.startFailed
        }
        observe(activity, onPushTokenUpdate: onPushTokenUpdate, onSystemDismissed: onSystemDismissed)
        return LocalLiveActivityRegistrationResult(activityID: activity.id, initialPushTokenHex: latestPushTokenHex)
        #else
        throw LocalLiveActivityError.unsupportedPlatform
        #endif
    }

    public func restoreActivity(
        activityID: String,
        sourceID: String,
        onPushTokenUpdate: @escaping @MainActor (String, String) -> Void,
        onSystemDismissed: @escaping @MainActor (String) -> Void
    ) async throws -> LocalLiveActivityRegistrationResult? {
        #if canImport(ActivityKit) && os(iOS)
        try Task.checkCancellation()
        _ = try CPAQuotaActivityAttributes(sourceID: sourceID)
        guard let activity = Activity<CPAQuotaActivityAttributes>.activities.first(where: {
            $0.id == activityID && $0.attributes.sourceID == sourceID
                && ($0.activityState == .active || $0.activityState == .stale)
        }) else { return nil }
        observe(activity, onPushTokenUpdate: onPushTokenUpdate, onSystemDismissed: onSystemDismissed)
        return LocalLiveActivityRegistrationResult(activityID: activity.id, initialPushTokenHex: latestPushTokenHex)
        #else
        return nil
        #endif
    }

    public func updateActivity(activityID: String, snapshot: MonitoringSnapshot) async throws {
        #if canImport(ActivityKit) && os(iOS)
        try Task.checkCancellation()
        guard activeActivityID == activityID,
              let activity = Activity<CPAQuotaActivityAttributes>.activities.first(where: { $0.id == activityID }),
              activity.activityState == .active || activity.activityState == .stale,
              activity.content.state.accepts(snapshot) else { return }
        let state = try CPAQuotaLiveActivityState(snapshot: snapshot)
        try activity.attributes.validateContent(state)
        // A sequence check alone cannot arbitrate an APNs update arriving after
        // this read. iOS 17.2 adds a system-side timestamp comparison. On 17.0/17.1
        // leave remote content to APNs instead of stamping an old HTTP response "now".
        if #available(iOS 17.2, *) {
            await activity.update(ActivityContent(state: state, staleDate: snapshot.expiresAt),
                                  alertConfiguration: nil, timestamp: snapshot.generatedAt)
        }
        #endif
    }

    public func endActivity(activityID: String, immediate: Bool) async {
        #if canImport(ActivityKit) && os(iOS)
        // Capture the exact object and invalidate its observers before suspension.
        // A new activity started during end() must keep its own binding and token.
        let activity = Activity<CPAQuotaActivityAttributes>.activities.first { $0.id == activityID }
        if activeActivityID == activityID { detachActivity() }
        guard let activity else { return }
        let previous = activity.content.state.snapshot
        let terminal = try? MonitoringSnapshot(
            sequence: previous.sequence, phase: previous.phase == .expired ? .expired : .stopped,
            generatedAt: previous.generatedAt, expiresAt: previous.expiresAt, accounts: previous.accounts
        )
        let state = terminal.flatMap { try? CPAQuotaLiveActivityState(snapshot: $0) } ?? activity.content.state
        await activity.end(ActivityContent(state: state, staleDate: .distantPast),
                           dismissalPolicy: immediate ? .immediate : .default)
        #else
        if activeActivityID == activityID { detachActivity() }
        #endif
    }

    /// Stop observing, without pretending to cancel a backend lease or another activity.
    public func detachActivity() {
        observationID = UUID()
        tokenObservationTask?.cancel()
        tokenObservationTask = nil
        stateObservationTask?.cancel()
        stateObservationTask = nil
        activeActivityID = nil
        latestPushTokenHex = nil
    }

    #if canImport(ActivityKit) && os(iOS)
    private func observe(
        _ activity: Activity<CPAQuotaActivityAttributes>,
        onPushTokenUpdate: @escaping @MainActor (String, String) -> Void,
        onSystemDismissed: @escaping @MainActor (String) -> Void
    ) {
        detachActivity()
        activeActivityID = activity.id
        let generation = observationID
        latestPushTokenHex = activity.pushToken.flatMap(Self.tokenHex)
        tokenObservationTask = Task { [weak self] in
            for await data in activity.pushTokenUpdates {
                guard !Task.isCancelled, let self,
                      self.observationID == generation, self.activeActivityID == activity.id else { return }
                guard let hex = Self.tokenHex(data), hex != self.latestPushTokenHex else { continue }
                self.latestPushTokenHex = hex
                onPushTokenUpdate(activity.id, hex)
            }
        }
        stateObservationTask = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard !Task.isCancelled, let self,
                      self.observationID == generation, self.activeActivityID == activity.id else { return }
                if state == .dismissed || state == .ended {
                    self.detachActivity()
                    onSystemDismissed(activity.id)
                    return
                }
            }
        }
    }

    private static func tokenHex(_ data: Data) -> String? {
        let value = data.map { String(format: "%02x", $0) }.joined()
        guard (try? MonitoringPushToken(value)) != nil else { return nil }
        return value
    }
    #endif
}

/// An explicit test/preview implementation; production never falls back to it.
@MainActor
public final class SyntheticLiveActivityDriver: SystemLiveActivityDriver {
    public var isSupportedOnCurrentPlatform: Bool
    public var areActivitiesEnabled: Bool
    public private(set) var activeActivityID: String?
    public private(set) var latestPushTokenHex: String?
    public var selectedRotationIndex: Int = 0
    public private(set) var lastUpdatedSnapshot: MonitoringSnapshot?
    public private(set) var endedImmediately: Bool?
    public private(set) var startCount = 0
    public private(set) var endedActivityIDs: [String] = []

    private struct Record {
        let sourceID: String
        var snapshot: MonitoringSnapshot?
        var token: String?
    }
    private var records: [String: Record] = [:]
    private var pushTokenCallback: (@MainActor (String, String) -> Void)?
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
        onPushTokenUpdate: @escaping @MainActor (String, String) -> Void,
        onSystemDismissed: @escaping @MainActor (String) -> Void
    ) async throws -> LocalLiveActivityRegistrationResult {
        try Task.checkCancellation()
        guard isSupportedOnCurrentPlatform else { throw LocalLiveActivityError.unsupportedPlatform }
        guard areActivitiesEnabled else { throw LocalLiveActivityError.activitiesDisabled }
        guard activeActivityID == nil else { throw LocalLiveActivityError.startFailed }
        let attributes = try CPAQuotaActivityAttributes(sourceID: sourceID)
        if let initialSnapshot { try attributes.validateContent(CPAQuotaLiveActivityState(snapshot: initialSnapshot)) }
        startCount += 1
        let id = startCount == 1 ? simulatedActivityID : "\(simulatedActivityID)-\(startCount)"
        records[id] = Record(sourceID: sourceID, snapshot: initialSnapshot, token: simulatedPushTokenHex)
        attach(id: id, onPushTokenUpdate: onPushTokenUpdate, onSystemDismissed: onSystemDismissed)
        return LocalLiveActivityRegistrationResult(activityID: id, initialPushTokenHex: latestPushTokenHex)
    }

    public func restoreActivity(
        activityID: String,
        sourceID: String,
        onPushTokenUpdate: @escaping @MainActor (String, String) -> Void,
        onSystemDismissed: @escaping @MainActor (String) -> Void
    ) async throws -> LocalLiveActivityRegistrationResult? {
        try Task.checkCancellation()
        guard records[activityID]?.sourceID == sourceID else { return nil }
        attach(id: activityID, onPushTokenUpdate: onPushTokenUpdate, onSystemDismissed: onSystemDismissed)
        return LocalLiveActivityRegistrationResult(activityID: activityID, initialPushTokenHex: latestPushTokenHex)
    }

    public func updateActivity(activityID: String, snapshot: MonitoringSnapshot) async throws {
        try Task.checkCancellation()
        guard activeActivityID == activityID, let record = records[activityID] else { return }
        if let previous = record.snapshot, snapshot.sequence <= previous.sequence { return }
        try CPAQuotaActivityAttributes(sourceID: record.sourceID).validateContent(CPAQuotaLiveActivityState(snapshot: snapshot))
        records[activityID]?.snapshot = snapshot
        lastUpdatedSnapshot = snapshot
    }

    public func endActivity(activityID: String, immediate: Bool) async {
        guard records.removeValue(forKey: activityID) != nil else { return }
        endedImmediately = immediate
        endedActivityIDs.append(activityID)
        if activeActivityID == activityID { detachActivity() }
    }

    public func detachActivity() {
        activeActivityID = nil
        latestPushTokenHex = nil
        lastUpdatedSnapshot = nil
        pushTokenCallback = nil
        dismissCallback = nil
    }

    public func simulateSystemPushTokenRotation(_ newHex: String) {
        guard let id = activeActivityID, (try? MonitoringPushToken(newHex)) != nil else { return }
        latestPushTokenHex = newHex
        records[id]?.token = newHex
        pushTokenCallback?(id, newHex)
    }

    public func simulateUserDismissal() {
        guard let id = activeActivityID else { return }
        let callback = dismissCallback
        records.removeValue(forKey: id)
        detachActivity()
        callback?(id)
    }

    private func attach(
        id: String,
        onPushTokenUpdate: @escaping @MainActor (String, String) -> Void,
        onSystemDismissed: @escaping @MainActor (String) -> Void
    ) {
        detachActivity()
        activeActivityID = id
        latestPushTokenHex = records[id]?.token
        lastUpdatedSnapshot = records[id]?.snapshot
        pushTokenCallback = onPushTokenUpdate
        dismissCallback = onSystemDismissed
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
        let safeIndex = CPAQuotaLiveActivityState.normalizedIndex(focusedIndex, count: accounts.count)
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
