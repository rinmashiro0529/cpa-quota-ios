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
    private var contentObservationTask: Task<Void, Never>?
    private var authorizationObservationTask: Task<Void, Never>?
    private var contentUpdateHandler: (@MainActor (String, MonitoringSnapshot) -> Void)?

    public init() {}

    deinit {
        tokenObservationTask?.cancel()
        stateObservationTask?.cancel()
        contentObservationTask?.cancel()
        authorizationObservationTask?.cancel()
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

    public var currentSnapshot: MonitoringSnapshot? {
        #if canImport(ActivityKit) && os(iOS)
        guard let activeActivityID else { return nil }
        return Activity<CPAQuotaActivityAttributes>.activities.first {
            $0.id == activeActivityID && ($0.activityState == .active || $0.activityState == .stale)
        }?.content.state.snapshot
        #else
        return nil
        #endif
    }

    public func currentActivities() -> [LocalLiveActivityDescriptor] {
        #if canImport(ActivityKit) && os(iOS)
        return Activity<CPAQuotaActivityAttributes>.activities.compactMap {
            guard $0.activityState == .active || $0.activityState == .stale else { return nil }
            return LocalLiveActivityDescriptor(id: $0.id, sourceID: $0.attributes.sourceID)
        }
        #else
        return []
        #endif
    }

    public func observeAuthorizationChanges(_ onChange: @escaping @MainActor (Bool) -> Void) {
        stopObservingAuthorizationChanges()
        onChange(areActivitiesEnabled)
        #if canImport(ActivityKit) && os(iOS)
        authorizationObservationTask = Task {
            for await enabled in ActivityAuthorizationInfo().activityEnablementUpdates {
                guard !Task.isCancelled else { return }
                onChange(enabled)
            }
        }
        #endif
    }

    public func stopObservingAuthorizationChanges() {
        authorizationObservationTask?.cancel()
        authorizationObservationTask = nil
    }

    public func setContentUpdateHandler(_ onChange: @escaping @MainActor (String, MonitoringSnapshot) -> Void) {
        contentUpdateHandler = onChange
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
        guard activeActivityID == activityID else { return }
        try await Self.updateSystemActivity(activityID: activityID, snapshot: snapshot)
        #endif
    }

    public func endActivity(activityID: String, immediate: Bool) async {
        // Invalidate this activity's observers before suspension. A new activity
        // started during end() must keep its own binding and token.
        if activeActivityID == activityID { detachActivity() }
        #if canImport(ActivityKit) && os(iOS)
        await Self.endSystemActivity(activityID: activityID, immediate: immediate)
        #endif
    }

    #if canImport(ActivityKit) && os(iOS)
    // ActivityKit's Activity is non-Sendable and its async mutation APIs are
    // nonisolated. Pass only value types across the actor boundary, and obtain
    // the framework object inside the same nonisolated operation that uses it.
    nonisolated private static func updateSystemActivity(activityID: String, snapshot: MonitoringSnapshot) async throws {
        try Task.checkCancellation()
        guard let activity = Activity<CPAQuotaActivityAttributes>.activities.first(where: { $0.id == activityID }),
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
    }

    nonisolated private static func endSystemActivity(activityID: String, immediate: Bool) async {
        guard let activity = Activity<CPAQuotaActivityAttributes>.activities.first(where: { $0.id == activityID }) else { return }
        let previous = activity.content.state.snapshot
        let terminal = try? MonitoringSnapshot(
            sequence: previous.sequence, phase: previous.phase == .expired ? .expired : .stopped,
            generatedAt: previous.generatedAt, expiresAt: previous.expiresAt, accounts: previous.accounts
        )
        let state = terminal.flatMap { try? CPAQuotaLiveActivityState(snapshot: $0) } ?? activity.content.state
        await activity.end(ActivityContent(state: state, staleDate: .distantPast),
                           dismissalPolicy: immediate ? .immediate : .default)
    }
    #endif

    /// Stop observing, without pretending to cancel a backend lease or another activity.
    public func detachActivity() {
        observationID = UUID()
        tokenObservationTask?.cancel()
        tokenObservationTask = nil
        stateObservationTask?.cancel()
        stateObservationTask = nil
        contentObservationTask?.cancel()
        contentObservationTask = nil
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
        contentObservationTask = Task { [weak self] in
            for await content in activity.contentUpdates {
                guard !Task.isCancelled, let self,
                      self.observationID == generation, self.activeActivityID == activity.id else { return }
                self.contentUpdateHandler?(activity.id, content.state.snapshot)
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
    public var areActivitiesEnabled: Bool {
        didSet { authorizationCallback?(areActivitiesEnabled) }
    }
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
    private var authorizationCallback: (@MainActor (Bool) -> Void)?
    private var contentUpdateHandler: (@MainActor (String, MonitoringSnapshot) -> Void)?
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
        contentUpdateHandler?(activityID, snapshot)
    }

    public var currentSnapshot: MonitoringSnapshot? {
        guard let activeActivityID else { return nil }
        return records[activeActivityID]?.snapshot
    }

    public func currentActivities() -> [LocalLiveActivityDescriptor] {
        records.map { LocalLiveActivityDescriptor(id: $0.key, sourceID: $0.value.sourceID) }
            .sorted { $0.id < $1.id }
    }

    public func observeAuthorizationChanges(_ onChange: @escaping @MainActor (Bool) -> Void) {
        authorizationCallback = onChange
        onChange(areActivitiesEnabled)
    }

    public func stopObservingAuthorizationChanges() { authorizationCallback = nil }

    public func setContentUpdateHandler(_ onChange: @escaping @MainActor (String, MonitoringSnapshot) -> Void) {
        contentUpdateHandler = onChange
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
/// An in-app diagnostic presentation of the safe payload. It is not a system
/// island mock-up and does not claim that APNs has reached this device.
public struct SystemLiveActivityPreviewCard: View {
    public let sourceID: String
    public let snapshot: MonitoringSnapshot
    @Binding public var focusedIndex: Int
    public let palette: BrandPalette

    public init(sourceID: String, snapshot: MonitoringSnapshot,
                focusedIndex: Binding<Int>, palette: BrandPalette) {
        self.sourceID = sourceID
        self.snapshot = snapshot
        self._focusedIndex = focusedIndex
        self.palette = palette
    }

    public var body: some View {
        let index = CPAQuotaLiveActivityState.normalizedIndex(focusedIndex, count: snapshot.accounts.count)
        let account = snapshot.accounts.isEmpty ? nil : snapshot.accounts[index]
        VStack(alignment: .leading, spacing: 12) {
            Label("系统活动数据检查", systemImage: "doc.text.magnifyingglass")
                .font(.headline)
            if let account {
                Text(account.label).font(.headline)
                QuotaLabeledValue(title: account.windowLabel, value: CPAQuotaActivityPresentation.value(account))
                Text(CPAQuotaActivityPresentation.status(snapshot: snapshot, account: account,
                                                        isStale: Date() >= snapshot.expiresAt))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("观察于 \(QuotaFormatter.exactTimestampString(account.observedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if snapshot.accounts.count > 1 {
                    Button("查看下一个账号（\(index + 1) / \(snapshot.accounts.count)）") {
                        focusedIndex = (index + 1) % snapshot.accounts.count
                    }
                    .quotaSecondaryButtonStyle()
                }
            } else {
                Text("暂无安全读数").foregroundStyle(.secondary)
            }
            DisclosureGroup("载荷详情") {
                QuotaLabeledValue(title: "来源", value: sourceID)
                QuotaLabeledValue(title: "Sequence", value: String(snapshot.sequence))
                if let bytes = try? snapshot.activityContentData().count {
                    QuotaLabeledValue(title: "动态内容字节", value: "\(bytes) / 3584")
                }
                Text("这是应用内的数据检查，不是设备送达或系统呈现回执。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(palette.textPrimary)
        .padding()
        .quotaContentSurface()
    }
}
#endif
