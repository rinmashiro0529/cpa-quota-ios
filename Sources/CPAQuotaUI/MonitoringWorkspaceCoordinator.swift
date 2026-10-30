import Foundation
import Observation
import CPAQuotaKit

public struct PersistedMonitoringRecord: Codable, Equatable, Sendable, Identifiable {
    public let sessionID: UUID
    public let bridgeBaseURLString: String
    /// Opaque identity stored with the credential in Keychain. Never a token or token hash.
    /// Legacy records have no binding and require explicit, successful reconciliation.
    public let credentialBindingID: UUID?
    public let sourceID: String
    public let accountIDs: [String]
    public let durationSeconds: Int
    public let activityID: String
    public let lastKnownRevision: UInt64
    public let stopIntentRecorded: Bool
    public let terminalStatus: MonitoringSession.Status?
    public let savedAt: Date

    public var id: String {
        "\(bridgeBaseURLString)|\(credentialBindingID?.uuidString ?? "legacy")|\(sessionID.uuidString)"
    }

    public init(
        sessionID: UUID,
        bridgeBaseURLString: String,
        sourceID: String,
        accountIDs: [String],
        durationSeconds: Int,
        activityID: String,
        lastKnownRevision: UInt64,
        stopIntentRecorded: Bool,
        credentialBindingID: UUID? = nil,
        terminalStatus: MonitoringSession.Status? = nil,
        savedAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.bridgeBaseURLString = bridgeBaseURLString
        self.credentialBindingID = credentialBindingID
        self.sourceID = sourceID
        self.accountIDs = accountIDs
        self.durationSeconds = durationSeconds
        self.activityID = activityID
        self.lastKnownRevision = lastKnownRevision
        self.stopIntentRecorded = stopIntentRecorded
        self.terminalStatus = terminalStatus
        self.savedAt = savedAt
    }
}

public protocol MonitoringMetadataPersistence: Sendable {
    func loadSavedBridgeAddress() -> String?
    func saveBridgeAddress(_ address: String?)
    func loadPersistedRecords() -> [PersistedMonitoringRecord]
    func savePersistedRecords(_ records: [PersistedMonitoringRecord])
}

public final class MemoryMonitoringMetadataPersistence: MonitoringMetadataPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var bridgeAddress: String?
    private var records: [PersistedMonitoringRecord]

    public init(bridgeAddress: String? = nil, records: [PersistedMonitoringRecord] = []) {
        self.bridgeAddress = bridgeAddress
        self.records = records
    }

    public func loadSavedBridgeAddress() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return bridgeAddress
    }

    public func saveBridgeAddress(_ address: String?) {
        lock.lock()
        bridgeAddress = address
        lock.unlock()
    }

    public func loadPersistedRecords() -> [PersistedMonitoringRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    public func savePersistedRecords(_ records: [PersistedMonitoringRecord]) {
        lock.lock()
        self.records = records
        lock.unlock()
    }
}

public final class UserDefaultsMonitoringMetadataPersistence: MonitoringMetadataPersistence, @unchecked Sendable {
    private let defaults: UserDefaults
    private let keyPrefix: String

    private enum Keys {
        static let bridgeAddress = "savedMonitorBridgeAddress"
        static let records = "persistedMonitoringRecords"
    }

    public init(suiteName: String? = nil, keyPrefix: String = "CPAQuotaUI.Monitor.") {
        if let suiteName, let custom = UserDefaults(suiteName: suiteName) {
            self.defaults = custom
        } else {
            self.defaults = .standard
        }
        self.keyPrefix = keyPrefix
    }

    public func loadSavedBridgeAddress() -> String? {
        defaults.string(forKey: keyPrefix + Keys.bridgeAddress)
    }

    public func saveBridgeAddress(_ address: String?) {
        let key = keyPrefix + Keys.bridgeAddress
        if let address, !address.isEmpty {
            defaults.set(address, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    public func loadPersistedRecords() -> [PersistedMonitoringRecord] {
        guard let data = defaults.data(forKey: keyPrefix + Keys.records) else { return [] }
        return (try? JSONDecoder().decode([PersistedMonitoringRecord].self, from: data)) ?? []
    }

    public func savePersistedRecords(_ records: [PersistedMonitoringRecord]) {
        let key = keyPrefix + Keys.records
        if records.isEmpty {
            defaults.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: key)
        }
    }
}

public struct LocalLiveActivityRegistrationResult: Sendable, Equatable {
    public let activityID: String
    public let initialPushTokenHex: String?

    public init(activityID: String, initialPushTokenHex: String?) {
        self.activityID = activityID
        self.initialPushTokenHex = initialPushTokenHex
    }
}

public enum LocalLiveActivityError: Error, Sendable, Equatable {
    case unsupportedPlatform
    case activitiesDisabled
    case payloadTooLarge
    case startFailed
}

/// System-owned activities are identified only by their exact ID and safe source
/// alias. An unassociated activity must never be adopted by guessing a bridge.
public struct LocalLiveActivityDescriptor: Equatable, Sendable, Identifiable {
    public let id: String
    public let sourceID: String

    public init(id: String, sourceID: String) {
        self.id = id
        self.sourceID = sourceID
    }
}

@MainActor
public protocol SystemLiveActivityDriver: AnyObject {
    var isSupportedOnCurrentPlatform: Bool { get }
    var areActivitiesEnabled: Bool { get }
    var activeActivityID: String? { get }
    var latestPushTokenHex: String? { get }
    var selectedRotationIndex: Int { get set }
    var currentSnapshot: MonitoringSnapshot? { get }

    func startActivity(
        sourceID: String,
        initialSnapshot: MonitoringSnapshot?,
        onPushTokenUpdate: @escaping @MainActor (String, String) -> Void,
        onSystemDismissed: @escaping @MainActor (String) -> Void
    ) async throws -> LocalLiveActivityRegistrationResult

    func restoreActivity(
        activityID: String,
        sourceID: String,
        onPushTokenUpdate: @escaping @MainActor (String, String) -> Void,
        onSystemDismissed: @escaping @MainActor (String) -> Void
    ) async throws -> LocalLiveActivityRegistrationResult?

    func updateActivity(activityID: String, snapshot: MonitoringSnapshot) async throws
    func endActivity(activityID: String, immediate: Bool) async
    func detachActivity()
    func currentActivities() -> [LocalLiveActivityDescriptor]
    func observeAuthorizationChanges(_ onChange: @escaping @MainActor (Bool) -> Void)
    func setContentUpdateHandler(_ onChange: @escaping @MainActor (String, MonitoringSnapshot) -> Void)
    func stopObservingAuthorizationChanges()
}

/// Defaults preserve the injectable driver contract used by existing test clients.
public extension SystemLiveActivityDriver {
    var currentSnapshot: MonitoringSnapshot? { nil }
    func currentActivities() -> [LocalLiveActivityDescriptor] { [] }
    func observeAuthorizationChanges(_ onChange: @escaping @MainActor (Bool) -> Void) {
        onChange(areActivitiesEnabled)
    }
    func setContentUpdateHandler(_ onChange: @escaping @MainActor (String, MonitoringSnapshot) -> Void) {}
    func stopObservingAuthorizationChanges() {}
}

@MainActor
@Observable
public final class MonitoringWorkspaceCoordinator {
    public enum BridgeState: Equatable, Sendable {
        case unconfigured
        case connected(address: URL, isSavedInKeychain: Bool)
    }

    public private(set) var bridgeState: BridgeState = .unconfigured
    public private(set) var store: MonitoringStore?
    public private(set) var activeAddress: MonitorBridgeAddress?
    public private(set) var credentialBindingID: UUID?
    public private(set) var isSavedInKeychain = false
    public private(set) var bridgeFormError: String?
    public private(set) var bridgeStatusNotice: String?
    public private(set) var cachedSourceSnapshot: MonitoringSnapshot?
    public private(set) var cachedSourceID: String?
    public private(set) var persistedRecords: [PersistedMonitoringRecord] = []
    public private(set) var pendingCreateUUID: UUID?
    public private(set) var isWaitingForPushToken = false
    public private(set) var isChangingBridge = false
    public private(set) var isSessionActionInProgress = false
    public private(set) var isRotatingToken = false
    public private(set) var isLoadingCachedQuota = false
    public private(set) var activitiesEnabled = false
    public private(set) var localActivitySnapshot: MonitoringSnapshot?
    public private(set) var localActivities: [LocalLiveActivityDescriptor] = []
    public private(set) var unassociatedActivities: [LocalLiveActivityDescriptor] = []
    public private(set) var isEndingLocalActivity = false
    public private(set) var isReconcilingSystemState = false
    public var isBusy: Bool { isChangingBridge || isSessionActionInProgress || isRotatingToken || isLoadingCachedQuota }
    public var localActivityID: String? { attachedActivityID }
    public var isSystemActivitySupported: Bool { liveActivityDriver.isSupportedOnCurrentPlatform }

    public var bridgeURLDraft = ""
    public var bridgeTokenDraft = ""
    public var rememberBridgeDraft = true
    public var sourceIDDraft = "" {
        didSet {
            if sourceIDDraft.trimmingCharacters(in: .whitespacesAndNewlines) != cachedSourceID {
                cachedSourceSnapshot = nil
                cachedSourceID = nil
            }
        }
    }
    public var selectedAccountIDsDraft: [String] = []
    public var newAccountIDDraft = ""
    public var durationDraft: MonitoringDuration = .fourHours
    public var manualActivityIDDraft = ""
    public var manualPushTokenDraft = ""

    private struct Connection {
        let credential: MonitoringBridgeCredential
        let client: CPAMonitorClient
        let generation: UInt64
        var address: MonitorBridgeAddress { credential.address }
        var bindingID: UUID { credential.bindingID }
    }

    private struct PendingIntent {
        let id: UUID
        let sourceID: String
        let accountIDs: [String]
        let duration: MonitoringDuration
        var activityID: String?
        var registration: MonitoringRegistration?
        var submittedToken: String?
        var wasSubmitted: Bool
    }

    private struct TokenUpdate {
        let activityID: String
        let sessionID: UUID
        let token: String
    }

    @ObservationIgnored private let credentialStore: MonitoringBridgeCredentialStore
    @ObservationIgnored private let metadataStore: any MonitoringMetadataPersistence
    @ObservationIgnored private let clientFactory: @Sendable (URL, MonitorBridgeToken) throws -> CPAMonitorClient
    @ObservationIgnored public let liveActivityDriver: any SystemLiveActivityDriver
    @ObservationIgnored private var connection: Connection?
    @ObservationIgnored private var connectionGeneration: UInt64 = 0
    @ObservationIgnored private var configurationGeneration: UInt64 = 0
    @ObservationIgnored private var configurationTask: Task<Void, Never>?
    @ObservationIgnored private var configurationAddresses: Set<MonitorBridgeAddress> = []
    @ObservationIgnored private var pendingIntent: PendingIntent?
    @ObservationIgnored private var operationID: UUID?
    @ObservationIgnored private var tokenTask: Task<Void, Never>?
    @ObservationIgnored private var tokenWorkID: UUID?
    @ObservationIgnored private var cacheOperationID: UUID?
    @ObservationIgnored private var latestToken: TokenUpdate?
    @ObservationIgnored private var acknowledgedToken: String?
    @ObservationIgnored private var blockedToken: String?
    private var attachedActivityID: String?
    @ObservationIgnored private var isObservingSystemChanges = false
    @ObservationIgnored private var detachedConnections: [UUID: Connection] = [:]

    public init(
        credentialStore: MonitoringBridgeCredentialStore = MonitoringBridgeCredentialStore(),
        metadataStore: any MonitoringMetadataPersistence = UserDefaultsMonitoringMetadataPersistence(),
        liveActivityDriver: (any SystemLiveActivityDriver)? = nil,
        clientFactory: @escaping @Sendable (URL, MonitorBridgeToken) throws -> CPAMonitorClient = { url, token in
            try CPAMonitorClient(baseURL: url, token: token)
        }
    ) {
        self.credentialStore = credentialStore
        self.metadataStore = metadataStore
        self.clientFactory = clientFactory
        self.liveActivityDriver = liveActivityDriver ?? DefaultSystemLiveActivityDriver()
        self.activitiesEnabled = self.liveActivityDriver.areActivitiesEnabled
        persistedRecords = metadataStore.loadPersistedRecords()
        bridgeURLDraft = metadataStore.loadSavedBridgeAddress() ?? ""
    }

    /// Install once at app bootstrap, independently of the selected tab.
    public func beginSystemActivityObservation() {
        activitiesEnabled = liveActivityDriver.areActivitiesEnabled
        guard !isObservingSystemChanges else { return }
        isObservingSystemChanges = true
        liveActivityDriver.observeAuthorizationChanges { [weak self] enabled in
            self?.activitiesEnabled = enabled
        }
        liveActivityDriver.setContentUpdateHandler { [weak self] activityID, snapshot in
            guard let self, self.attachedActivityID == activityID else { return }
            // APNs content is a display snapshot, not an HTTP session/revision
            // receipt. Do not mutate MonitoringStore or its cancellation state.
            if let previous = self.localActivitySnapshot, snapshot.sequence < previous.sequence { return }
            self.localActivitySnapshot = snapshot
        }
    }

    /// Call when the application scene becomes active. Coalesces overlapping
    /// activations and never starts a replacement Activity or guesses ownership.
    public func handleSceneActivation() async {
        beginSystemActivityObservation()
        guard !isReconcilingSystemState else { return }
        isReconcilingSystemState = true
        defer {
            refreshLocalActivityInventory()
            isReconcilingSystemState = false
        }
        if connection == nil {
            await restoreBridgeIfAvailable()
        } else if !isBusy {
            if store?.sessionID != nil || pendingIntent?.wasSubmitted == true {
                await reconcileCurrentSession()
            } else if pendingIntent == nil {
                await restoreMatchingRecord()
            }
        }
        if let id = attachedActivityID, liveActivityDriver.activeActivityID == id {
            localActivitySnapshot = liveActivityDriver.currentSnapshot
        }
    }

    public func applicationDidBecomeActive() async {
        await handleSceneActivation()
    }

    /// The link contains only a safe source alias, not a credential or remote
    /// session ID. It can select a record only when ownership is unambiguous.
    public func openSourceFromDeepLink(_ sourceID: String) async {
        guard (try? CPAQuotaActivityAttributes(sourceID: sourceID)) != nil else {
            bridgeFormError = "无法识别此监控链接。"
            return
        }
        guard pendingIntent == nil, !isBusy else {
            bridgeStatusNotice = "请先完成或取消当前操作，再从恢复记录选择此来源。"
            return
        }
        let sourceRecords = persistedRecords.filter { $0.sourceID == sourceID && !isConfirmedTerminal($0) }
        guard let context = connection, sourceRecords.count == 1,
              let record = sourceRecords.first, matches(record, context) else {
            bridgeStatusNotice = "请在监控恢复记录中选择原服务与会话。此链接只标识来源，未自动绑定凭据或启动监控。"
            return
        }
        await loadPersistedRecord(record)
    }

    public func refreshLocalActivityInventory() {
        activitiesEnabled = liveActivityDriver.areActivitiesEnabled
        let activities = liveActivityDriver.currentActivities()
        localActivities = activities
        unassociatedActivities = activities.filter { activity in
            activity.id != attachedActivityID && !persistedRecords.contains {
                $0.activityID == activity.id && $0.sourceID == activity.sourceID
            }
        }
        // Known records on a different bridge stay in recovery history. Their
        // presence is not permission to bind them to the current credential.
    }

    /// End only this device's system presentation. Remote cancellation is a
    /// separate action and remains available even when the bridge is offline.
    public func stopLocalActivityDisplay() async {
        guard !isEndingLocalActivity,
              let activityID = attachedActivityID ?? liveActivityDriver.activeActivityID else { return }
        isEndingLocalActivity = true
        defer { isEndingLocalActivity = false; refreshLocalActivityInventory() }
        if let intent = pendingIntent, !intent.wasSubmitted, intent.activityID == activityID,
           let context = connection {
            removeRecord(id: intent.id, context: context)
            clearPendingIntent()
        }
        latestToken = nil
        blockedToken = nil
        tokenTask?.cancel()
        tokenTask = nil
        tokenWorkID = nil
        isRotatingToken = false
        if attachedActivityID == activityID {
            attachedActivityID = nil
            localActivitySnapshot = nil
        }
        await liveActivityDriver.endActivity(activityID: activityID, immediate: true)
        bridgeStatusNotice = "已停止本机实时活动显示。远端监控未因此取消；如需结束采集，请另选“停止监控”。"
    }

    /// Explicit user cleanup for the request-success/persist-ID crash window.
    /// There is no automatic association or remote action for these activities.
    public func endUnassociatedActivity(_ descriptor: LocalLiveActivityDescriptor) async {
        guard liveActivityDriver.currentActivities().contains(descriptor),
              !persistedRecords.contains(where: {
                  $0.activityID == descriptor.id && $0.sourceID == descriptor.sourceID
              }), attachedActivityID != descriptor.id else { return }
        await liveActivityDriver.endActivity(activityID: descriptor.id, immediate: true)
        refreshLocalActivityInventory()
        bridgeStatusNotice = "已关闭未关联的本机实时活动；没有推测或更改任何远端会话。"
    }

    /// Explicit cleanup remains possible after forgetting a bridge credential.
    /// The ID must still exist in this app's system-owned inventory.
    public func endLocalActivity(_ descriptor: LocalLiveActivityDescriptor) async {
        guard liveActivityDriver.currentActivities().contains(descriptor) else { return }
        if descriptor.id == attachedActivityID {
            await stopLocalActivityDisplay()
            return
        }
        await liveActivityDriver.endActivity(activityID: descriptor.id, immediate: true)
        refreshLocalActivityInventory()
        bridgeStatusNotice = "已停止此本机实时活动显示。原远端监控与恢复记录保持不变。"
    }

    public func restoreBridgeIfAvailable() async {
        beginSystemActivityObservation()
        defer { refreshLocalActivityInventory() }
        guard connection == nil, !isChangingBridge,
              let saved = metadataStore.loadSavedBridgeAddress(),
              let url = URL(string: saved), let address = try? MonitorBridgeAddress(baseURL: url) else { return }
        configurationGeneration &+= 1
        let generation = configurationGeneration
        isChangingBridge = true
        configurationAddresses.insert(address)
        let previous = configurationTask
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.configurationGeneration == generation else { return }
            do {
                guard let credential = try await self.credentialStore.loadCredential(for: address) else { return }
                guard self.configurationGeneration == generation else { return }
                let client = try self.clientFactory(address.baseURL, credential.token)
                self.bindClient(client, credential: credential, isSaved: true)
            } catch {
                guard self.configurationGeneration == generation else { return }
                self.bridgeFormError = "桥接安全存储读取失败，请重新连接。"
            }
        }
        configurationTask = task
        await task.value
        guard configurationGeneration == generation else { return }
        finishConfiguration()
        await restoreMatchingRecord()
    }

    public func connectBridge(rawURLString: String, rawTokenString: String, rememberInKeychain: Bool) async {
        guard !isChangingBridge else {
            bridgeFormError = "桥接凭据正在处理，请等待完成后再连接；仍可选择仅在本机忘记。"
            return
        }
        let address: MonitorBridgeAddress
        let token: MonitorBridgeToken
        let client: CPAMonitorClient
        do {
            guard let url = URL(string: rawURLString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw MonitoringError.invalidConfiguration
            }
            address = try MonitorBridgeAddress(baseURL: url)
            token = try MonitorBridgeToken(rawTokenString)
            client = try clientFactory(address.baseURL, token)
        } catch {
            bridgeFormError = "请检查 HTTPS 桥接地址与独立桥接 Token。"
            return
        }
        configurationGeneration &+= 1
        let generation = configurationGeneration
        isChangingBridge = true
        bridgeFormError = nil
        bridgeStatusNotice = nil
        configurationAddresses.insert(address)
        let previousTask = configurationTask
        let priorCredential = connection?.credential
        let task = Task { @MainActor [weak self] in
            await previousTask?.value
            guard let self, self.configurationGeneration == generation else { return }
            do {
                let credential = try await self.credentialStore.bind(token, for: address,
                    remember: rememberInKeychain, previous: priorCredential)
                guard self.configurationGeneration == generation else { return }
                self.metadataStore.saveBridgeAddress(rememberInKeychain ? address.baseURL.absoluteString : nil)
                self.bindClient(client, credential: credential, isSaved: rememberInKeychain)
                self.bridgeURLDraft = address.baseURL.absoluteString
                self.bridgeTokenDraft = ""
            } catch let error as CPAError {
                guard self.configurationGeneration == generation else { return }
                self.bridgeFormError = ErrorPresentation(error: error).summary
            } catch {
                guard self.configurationGeneration == generation else { return }
                self.bridgeFormError = "桥接凭据保存或移除失败，原连接保持不变。"
            }
        }
        configurationTask = task
        await task.value
        guard configurationGeneration == generation else { return }
        finishConfiguration()
        guard connection?.client === client else { return }
        await restoreMatchingRecord()
    }

    private func finishConfiguration(clearAddresses: Bool = true) {
        isChangingBridge = false
        configurationTask = nil
        if clearAddresses { configurationAddresses.removeAll() }
    }

    private func bindClient(_ client: CPAMonitorClient, credential: MonitoringBridgeCredential, isSaved: Bool) {
        cancelLocalWork()
        if let store {
            let old = connection
            store.replaceClient(client)
            if let old { captureDetachedConnections(old) }
        } else {
            store = MonitoringStore(client: client)
        }
        connectionGeneration &+= 1
        connection = Connection(credential: credential, client: client, generation: connectionGeneration)
        activeAddress = credential.address
        credentialBindingID = credential.bindingID
        isSavedInKeychain = isSaved
        bridgeState = .connected(address: credential.address.baseURL, isSavedInKeychain: isSaved)
        cachedSourceSnapshot = nil
        cachedSourceID = nil
    }

    private func restoreMatchingRecord() async {
        guard let context = connection else { return }
        guard let record = persistedRecords.first(where: { matches($0, context) && !isConfirmedTerminal($0) }) else { return }
        await loadPersistedRecord(record)
    }

    /// Leaves remote leases untouched, but releases every in-memory client and callback.
    public func forgetBridgeLocallyOnly() async {
        configurationGeneration &+= 1
        let generation = configurationGeneration
        let currentID = store?.sessionID ?? pendingCreateUUID
        var addresses = configurationAddresses
        if let activeAddress { addresses.insert(activeAddress) }
        if let saved = metadataStore.loadSavedBridgeAddress(), let url = URL(string: saved),
           let address = try? MonitorBridgeAddress(baseURL: url) { addresses.insert(address) }
        isChangingBridge = true
        bridgeFormError = nil
        let previousTask = configurationTask
        let task = Task { @MainActor [weak self] in
            await previousTask?.value
            guard let self, self.configurationGeneration == generation else { return }
            do {
                for address in addresses {
                    try await self.credentialStore.remove(for: address)
                    if self.activeAddress == address {
                        self.isSavedInKeychain = false
                        self.bridgeState = .connected(address: address.baseURL, isSavedInKeychain: false)
                        self.metadataStore.saveBridgeAddress(nil)
                    }
                }
                guard self.configurationGeneration == generation else { return }
                self.cancelLocalWork()
                self.connectionGeneration &+= 1
                self.connection = nil
                self.store = nil
                self.detachedConnections.removeAll()
                self.metadataStore.saveBridgeAddress(nil)
                self.activeAddress = nil
                self.credentialBindingID = nil
                self.isSavedInKeychain = false
                self.bridgeState = .unconfigured
                self.bridgeTokenDraft = ""
                self.manualPushTokenDraft = ""
                self.cachedSourceSnapshot = nil
                self.cachedSourceID = nil
                self.bridgeStatusNotice = currentID == nil
                    ? "已移除本机桥接凭据并断开连接。"
                    : "已移除本机桥接凭据并断开连接；远端监控未因此停止。已保留原桥接与会话索引，重新连接后可对账或停止，租约也会有限期到期。"
            } catch let error as CPAError {
                guard self.configurationGeneration == generation else { return }
                self.bridgeFormError = ErrorPresentation(error: error).summary
            } catch {
                guard self.configurationGeneration == generation else { return }
                self.bridgeFormError = "未能移除桥接凭据，连接和对账记录已保留。"
            }
        }
        configurationTask = task
        await task.value
        guard configurationGeneration == generation else { return }
        finishConfiguration(clearAddresses: connection == nil)
    }

    public func stopAndForgetBridge() async {
        guard let context = connection else { await forgetBridgeLocallyOnly(); return }
        if store?.sessionID != nil || pendingIntent != nil {
            await stopActiveMonitoringSession()
            guard isCurrent(context) else { return }
            guard pendingIntent == nil, store?.sessionID == nil || isCurrentSessionTerminal else {
                bridgeStatusNotice = "尚未确认停止，已保留原凭据与会话索引；可再次对账，或明确选择仅在本机忘记。"
                return
            }
        }
        await forgetBridgeLocallyOnly()
    }

    public func addAccountIDDraft(_ rawID: String) {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !selectedAccountIDsDraft.contains(id) else { return }
        guard Self.isValidAccountSelection(id) else {
            bridgeFormError = "账号标识格式无效，请使用监控服务授权的原标识。"
            return
        }
        guard selectedAccountIDsDraft.count < 5 else { bridgeFormError = "单次监控最多选择 5 个授权账号。"; return }
        selectedAccountIDsDraft.append(id)
        newAccountIDDraft = ""
        bridgeFormError = nil
    }

    public func removeAccountIDDraft(_ id: String) { selectedAccountIDsDraft.removeAll { $0 == id } }

    public func startOrReconcileMonitoringSession() async {
        guard let context = connection, let store else { bridgeFormError = "请先连接监控桥接。"; return }
        guard let operation = beginOperation(context) else { return }
        defer { finishOperation(operation) }

        if pendingIntent == nil {
            guard store.sessionID == nil || isCurrentSessionTerminal else {
                bridgeFormError = "现有会话尚未确认结束，请先查询或停止；未创建新的系统活动。"
                return
            }
            let source = sourceIDDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (try? CPAQuotaActivityAttributes(sourceID: source)) != nil,
                  (1...5).contains(selectedAccountIDsDraft.count),
                  Set(selectedAccountIDsDraft).count == selectedAccountIDsDraft.count,
                  selectedAccountIDsDraft.allSatisfy(Self.isValidAccountSelection) else {
                bridgeFormError = "请填写授权 Source ID 并选择 1–5 个账号。"
                return
            }
            let intent = PendingIntent(id: UUID(), sourceID: source, accountIDs: selectedAccountIDsDraft,
                duration: durationDraft, activityID: nil, registration: nil, submittedToken: nil, wasSubmitted: false)
            pendingIntent = intent
            pendingCreateUUID = intent.id
            latestToken = nil
            acknowledgedToken = nil
            blockedToken = nil
            saveIntent(intent, context: context)
        }
        guard var intent = pendingIntent else { return }

        if intent.wasSubmitted {
            await store.load(id: intent.id)
            guard isCurrent(context, operation) else { return }
            captureDetachedConnections(context)
            if store.state == .available, sessionMatchesIntent(store.session, intent) {
                await acceptLoadedSession(context, operation: operation)
                return
            }
            guard store.error == .notFound, intent.registration != nil else {
                bridgeStatusNotice = "原会话仍待对账。未更换 UUID 或重建活动；不能恢复原注册时，请明确停止该 UUID 后再开始。"
                return
            }
        }

        if intent.activityID == nil {
            let manualID = manualActivityIDDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            let manualToken = manualPushTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if !manualID.isEmpty, !manualToken.isEmpty {
                intent.activityID = manualID
                pendingIntent = intent
                latestToken = TokenUpdate(activityID: manualID, sessionID: intent.id, token: manualToken.lowercased())
            } else {
                do {
                    let result = try await liveActivityDriver.startActivity(sourceID: intent.sourceID, initialSnapshot: nil,
                        onPushTokenUpdate: tokenCallback(context: context, sessionID: intent.id),
                        onSystemDismissed: dismissalCallback(context: context))
                    guard isCurrent(context, operation), pendingIntent?.id == intent.id else {
                        await liveActivityDriver.endActivity(activityID: result.activityID, immediate: true)
                        return
                    }
                    intent.activityID = result.activityID
                    pendingIntent = intent
                    saveIntent(intent, context: context)
                    guard liveActivityDriver.activeActivityID == result.activityID else {
                        latestToken = nil
                        bridgeFormError = "系统活动在启动期间已结束；未注册远端会话。请取消本次启动后重试。"
                        return
                    }
                    attachedActivityID = result.activityID
                    localActivitySnapshot = liveActivityDriver.currentSnapshot
                    // A callback may run before this continuation. Keep the newer observed token.
                    if latestToken?.sessionID != intent.id || latestToken?.activityID != result.activityID {
                        latestToken = result.initialPushTokenHex.map {
                            TokenUpdate(activityID: result.activityID, sessionID: intent.id, token: $0.lowercased())
                        }
                    }
                } catch {
                    guard isCurrent(context, operation) else { return }
                    bridgeFormError = "系统实时活动无法启动，请检查系统授权。已保留创建意图，未发送假令牌。"
                    return
                }
            }
        }
        guard let activityID = intent.activityID else { return }
        if intent.registration == nil {
            guard let update = latestToken, update.sessionID == intent.id, update.activityID == activityID else {
                isWaitingForPushToken = true
                bridgeStatusNotice = "正在等待此系统活动的推送令牌；无需再次创建活动，可随时取消本次启动。"
                return
            }
            do {
                intent.registration = try MonitoringRegistration(id: intent.id, sourceID: intent.sourceID,
                    accountIDs: intent.accountIDs, duration: intent.duration, activityID: activityID,
                    pushToken: MonitoringPushToken(update.token))
                intent.submittedToken = update.token
            } catch {
                blockedToken = update.token
                bridgeFormError = "注册参数或活动令牌无效；未发送注册请求。"
                return
            }
        }
        guard let registration = intent.registration else { return }
        intent.wasSubmitted = true
        pendingIntent = intent
        isWaitingForPushToken = false
        saveIntent(intent, context: context)
        await store.start(registration)
        guard isCurrent(context, operation) else { return }
        captureDetachedConnections(context)
        syncPersistedState(context)
        if store.state == .available, sessionMatchesIntent(store.session, intent) {
            acknowledgedToken = intent.submittedToken
            await acceptLoadedSession(context, operation: operation)
        } else {
            bridgeStatusNotice = "创建结果尚未确认，原 UUID、活动和注册内容已保留。下一次先查询原会话，不盲目另建。"
        }
    }

    public func loadPersistedRecord(_ record: PersistedMonitoringRecord) async {
        guard pendingIntent?.wasSubmitted != false else {
            bridgeStatusNotice = "当前正在等待原活动令牌；请先完成或取消本次本地启动，再切换历史会话。"
            return
        }
        guard let context = connection, let store else {
            bridgeURLDraft = record.bridgeBaseURLString
            bridgeFormError = "请先重新连接此记录的原桥接。"
            return
        }
        guard sameAddress(record, context) else {
            bridgeURLDraft = record.bridgeBaseURLString
            bridgeFormError = "此记录属于另一桥接，请连接其原地址后再查询；没有向当前桥接发送该 UUID。"
            return
        }
        guard let operation = beginOperation(context) else { return }
        defer { finishOperation(operation) }
        var selected = record
        if !matches(record, context) {
            // A GET proves visibility to this credential; 404 never authorizes DELETE for an old binding.
            do {
                let result = try await context.client.get(id: record.sessionID)
                guard isCurrent(context, operation) else { return }
                guard sessionMatchesRecord(result, record) else { throw MonitoringError.invalidResponse }
                selected = recordFor(result, context: context, existing: record)
                replaceRecord(record, with: selected)
            } catch {
                guard isCurrent(context, operation) else { return }
                bridgeFormError = "未能确认历史记录属于当前凭据；已保留原记录，不能据此发送停止或认定已停止。"
                return
            }
        }
        sourceIDDraft = selected.sourceID
        selectedAccountIDsDraft = selected.accountIDs
        durationDraft = MonitoringDuration(rawValue: selected.durationSeconds) ?? .fourHours
        pendingIntent = PendingIntent(id: selected.sessionID, sourceID: selected.sourceID,
            accountIDs: selected.accountIDs, duration: durationDraft,
            activityID: selected.activityID.isEmpty ? nil : selected.activityID,
            registration: nil, submittedToken: nil, wasSubmitted: true)
        pendingCreateUUID = selected.sessionID
        await store.load(id: selected.sessionID)
        guard isCurrent(context, operation) else { return }
        captureDetachedConnections(context)
        syncPersistedState(context)
        if store.state == .available, sessionMatchesRecord(store.session, selected) {
            await acceptLoadedSession(context, operation: operation)
        } else {
            bridgeStatusNotice = "已保留原桥接、凭据标识与 UUID；当前结果仍待对账，404 不代表停止。"
        }
    }

    public func reconcileCurrentSession() async {
        guard pendingIntent?.wasSubmitted != false else {
            bridgeStatusNotice = "正在等待原活动的系统令牌，尚未发送注册；无需查询其他会话。"
            return
        }
        guard let context = connection, let store else { return }
        guard let id = store.sessionID ?? pendingCreateUUID else {
            if let record = persistedRecords.first(where: { matches($0, context) && !isConfirmedTerminal($0) }) {
                await loadPersistedRecord(record)
            } else { bridgeFormError = "请从历史记录中选择属于原桥接的会话。" }
            return
        }
        guard let operation = beginOperation(context) else { return }
        defer { finishOperation(operation) }
        await store.load(id: id)
        guard isCurrent(context, operation) else { return }
        captureDetachedConnections(context)
        syncPersistedState(context)
        if store.state == .available { await acceptLoadedSession(context, operation: operation) }
    }

    public func refreshActiveMonitoringSession() async {
        guard pendingIntent?.wasSubmitted != false else { return }
        guard let context = connection, let store, store.sessionID != nil,
              let operation = beginOperation(context) else { return }
        defer { finishOperation(operation) }
        await store.refresh()
        guard isCurrent(context, operation) else { return }
        syncPersistedState(context)
        if store.state == .available {
            await updateBoundActivity(context, operation: operation)
            if isCurrent(context, operation) { bridgeStatusNotice = "服务端已接受刷新意图；这不是设备送达回执。" }
        }
    }

    public func stopActiveMonitoringSession() async {
        guard let context = connection, let store, !isChangingBridge else { return }
        guard let id = store.sessionID ?? pendingIntent?.id else { return }
        tokenTask?.cancel()
        tokenTask = nil
        tokenWorkID = nil
        isRotatingToken = false
        blockedToken = latestToken?.token
        let operation = UUID()
        operationID = operation
        isSessionActionInProgress = true
        defer { finishOperation(operation) }

        if let intent = pendingIntent, !intent.wasSubmitted, store.sessionID != intent.id {
            let activityID = intent.activityID
            removeRecord(id: intent.id, context: context)
            clearPendingIntent()
            if let activityID { await liveActivityDriver.endActivity(activityID: activityID, immediate: true) }
            guard isCurrent(context, operation) else { return }
            attachedActivityID = nil
            localActivitySnapshot = nil
            bridgeStatusNotice = "已取消本次本地启动；尚未发出远端注册请求。"
            return
        }
        if store.sessionID == nil {
            await store.load(id: id)
            guard isCurrent(context, operation) else { return }
        }
        await store.stop()
        guard isCurrent(context, operation) else { return }
        syncPersistedState(context)
        if isCurrentSessionTerminal {
            let activityID = store.session?.activityID ?? pendingIntent?.activityID ?? attachedActivityID
            clearPendingIntent()
            if let activityID { await liveActivityDriver.endActivity(activityID: activityID, immediate: true) }
            guard isCurrent(context, operation) else { return }
            attachedActivityID = nil
            localActivitySnapshot = nil
            bridgeStatusNotice = "原桥接已确认终态或持久取消意图；本地绑定活动已结束。该回执不证明 APNs end 已送达。"
        } else {
            bridgeStatusNotice = "停止结果未确认，已保留原 UUID；404、超时或 507 均不代表停止成功。"
        }
    }

    public func loadCachedQuotaForDraftSource() async {
        guard let context = connection else { bridgeFormError = "请先连接监控桥接。"; return }
        let source = sourceIDDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { bridgeFormError = "请先填写授权 Source ID。"; return }
        guard cacheOperationID == nil else { return }
        let readID = UUID()
        cacheOperationID = readID
        isLoadingCachedQuota = true
        defer {
            if cacheOperationID == readID { cacheOperationID = nil; isLoadingCachedQuota = false }
        }
        do {
            let snapshot = try await context.client.cachedQuota(sourceID: source)
            guard isCurrent(context), source == sourceIDDraft.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            cachedSourceSnapshot = snapshot
            cachedSourceID = source
            bridgeStatusNotice = "已读取来源缓存，供本页查看；它不代表所选账号的活动注册内容。"
        } catch {
            guard isCurrent(context), source == sourceIDDraft.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            bridgeFormError = monitoringErrorText(error as? MonitoringError)
        }
    }

    public func handleSystemPushTokenRotation(newTokenHex: String) async {
        guard let context = connection, let session = store?.session,
              liveActivityDriver.activeActivityID == session.activityID else { return }
        receiveToken(activityID: session.activityID, token: newTokenHex, sessionID: session.id, context: context)
        await tokenTask?.value
    }

    private func tokenCallback(context: Connection, sessionID: UUID) -> @MainActor (String, String) -> Void {
        let generation = context.generation
        return { [weak self] activityID, token in
            guard let self, let current = self.connection, current.generation == generation else { return }
            self.receiveToken(activityID: activityID, token: token, sessionID: sessionID, context: current)
        }
    }

    private func receiveToken(activityID: String, token: String, sessionID: UUID, context: Connection) {
        guard isCurrent(context), (try? MonitoringPushToken(token)) != nil else { return }
        if let pending = pendingIntent, pending.id == sessionID {
            guard pending.activityID == nil || pending.activityID == activityID else { return }
        } else {
            guard let session = store?.session, session.id == sessionID, session.status == .active,
                  session.activityID == activityID, attachedActivityID == activityID else { return }
        }
        latestToken = TokenUpdate(activityID: activityID, sessionID: sessionID, token: token.lowercased())
        if blockedToken != token.lowercased() { blockedToken = nil }
        scheduleTokenWork()
    }

    private func scheduleTokenWork() {
        guard tokenTask == nil, operationID == nil, !isChangingBridge, let context = connection,
              let update = latestToken, update.token != blockedToken else { return }
        let create = pendingIntent.map { !$0.wasSubmitted && $0.id == update.sessionID && $0.activityID == update.activityID } ?? false
        let rotate = store?.session.map { $0.status == .active && $0.id == update.sessionID && $0.activityID == update.activityID } ?? false
        guard create || (rotate && acknowledgedToken != update.token) else { return }
        let workID = UUID()
        tokenWorkID = workID
        tokenTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.isCurrent(context), self.tokenWorkID == workID else { return }
            if create { await self.startOrReconcileMonitoringSession() }
            else { await self.drainTokenUpdates(context) }
            guard self.isCurrent(context), self.tokenWorkID == workID else { return }
            self.tokenTask = nil
            self.tokenWorkID = nil
            self.scheduleTokenWork()
        }
    }

    private func drainTokenUpdates(_ context: Connection) async {
        guard let store, let operation = beginOperation(context) else { return }
        isRotatingToken = true
        defer {
            if isCurrent(context, operation) { isRotatingToken = false }
            finishOperation(operation)
        }
        while !Task.isCancelled, isCurrent(context, operation), let update = latestToken,
              update.token != acknowledgedToken, update.token != blockedToken,
              let session = store.session, session.id == update.sessionID, session.status == .active,
              session.activityID == update.activityID, attachedActivityID == update.activityID {
            guard let token = try? MonitoringPushToken(update.token) else { return }
            await store.rotate(token: token, revision: session.revision)
            guard !Task.isCancelled, isCurrent(context, operation) else { return }
            if store.state != .available, let error = store.error,
               [MonitoringError.conflict, .network, .serviceUnavailable].contains(error) {
                // One reconciliation and one retry per observed token, never an unbounded retry loop.
                await store.load(id: update.sessionID)
                guard !Task.isCancelled, isCurrent(context, operation) else { return }
                if store.state == .available, let fresh = store.session, fresh.status == .active {
                    await store.rotate(token: token, revision: fresh.revision)
                    guard !Task.isCancelled, isCurrent(context, operation) else { return }
                }
            }
            syncPersistedState(context)
            guard store.state == .available else {
                blockedToken = update.token
                bridgeStatusNotice = "活动令牌更新未确认；已保留最新令牌，可在查询对账后重试，未替换活动身份。"
                return
            }
            acknowledgedToken = update.token
        }
    }

    private func dismissalCallback(context: Connection) -> @MainActor (String) -> Void {
        let generation = context.generation
        return { [weak self] id in
            guard let self, self.connection?.generation == generation, self.attachedActivityID == id else { return }
            self.handleUserDismissedActivity(activityID: id)
        }
    }

    public func handleUserDismissedActivity(activityID: String) {
        guard attachedActivityID == activityID else { return }
        attachedActivityID = nil
        localActivitySnapshot = nil
        latestToken = nil
        tokenTask?.cancel()
        tokenTask = nil
        tokenWorkID = nil
        isRotatingToken = false
        bridgeStatusNotice = "系统活动已结束或移除；远端租约未因此自动取消，可查询并明确停止。"
    }

    public func reconcileDetached(handle: UUID) async {
        guard let store, let context = detachedConnections[handle], let current = connection else { return }
        do {
            let result = try await store.loadDetached(handle: handle)
            guard isCurrent(current), detachedConnections[handle]?.client === context.client else { return }
            syncDetached(handle, context: context)
            bridgeStatusNotice = "原桥接分离会话已查询：\(result.status.rawValue)。"
        } catch {
            guard isCurrent(current) else { return }
            bridgeFormError = "原桥接分离会话查询未确认。"
        }
    }

    public func stopDetached(handle: UUID) async {
        guard let store, let context = detachedConnections[handle], let current = connection else { return }
        do {
            _ = try await store.stopDetached(handle: handle)
            guard isCurrent(current), detachedConnections[handle]?.client === context.client else { return }
            syncDetached(handle, context: context)
            if let item = store.detachedSessions.first(where: { $0.handle == handle }),
               item.stopIntentRecorded || item.lastSession.map({ $0.status != .active }) == true {
                let activityID = item.lastSession?.activityID ?? persistedRecords.first {
                    $0.sessionID == item.id && matches($0, context)
                }?.activityID
                if let activityID, !activityID.isEmpty {
                    await liveActivityDriver.endActivity(activityID: activityID, immediate: true)
                }
                guard isCurrent(current) else { return }
            }
            bridgeStatusNotice = "原桥接已确认分离会话终态或取消意图。"
        } catch {
            guard isCurrent(current) else { return }
            bridgeFormError = "分离会话停止未确认，已保留其原桥接索引。"
        }
    }

    public func removeDetached(handle: UUID) {
        guard let store, let context = detachedConnections[handle],
              let item = store.detachedSessions.first(where: { $0.handle == handle }) else { return }
        do {
            try store.removeDetached(handle: handle)
            removeRecord(id: item.id, context: context)
            detachedConnections.removeValue(forKey: handle)
        } catch { bridgeFormError = "尚未确认终态或取消意图，不能移除该记录。" }
    }

    public func removePersistedRecord(_ record: PersistedMonitoringRecord) {
        guard isConfirmedTerminal(record) else { bridgeFormError = "尚未确认终态或取消意图，不能遗忘对账记录。"; return }
        persistedRecords.removeAll { $0.id == record.id }
        metadataStore.savePersistedRecords(persistedRecords)
    }

    public func removePersistedRecord(sessionID: UUID) {
        let records = persistedRecords.filter { $0.sessionID == sessionID }
        guard records.count == 1, let record = records.first else { return }
        removePersistedRecord(record)
    }

    private func beginOperation(_ context: Connection) -> UUID? {
        guard !Task.isCancelled, isCurrent(context), !isChangingBridge, operationID == nil else { return nil }
        let id = UUID()
        operationID = id
        isSessionActionInProgress = true
        bridgeFormError = nil
        bridgeStatusNotice = nil
        return id
    }

    private static func isValidAccountSelection(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128 && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "_-@.".unicodeScalars.contains($0)
        }
    }

    private func finishOperation(_ id: UUID) {
        guard operationID == id else { return }
        operationID = nil
        isSessionActionInProgress = false
        scheduleTokenWork()
    }

    private func isCurrent(_ context: Connection, _ operation: UUID? = nil) -> Bool {
        connection?.generation == context.generation && connection?.client === context.client &&
            (operation == nil || operationID == operation)
    }

    private var isCurrentSessionTerminal: Bool {
        store?.cancellationReceipt != nil || store?.session.map { $0.status != .active } == true
    }

    private func clearPendingIntent() {
        pendingIntent = nil
        pendingCreateUUID = nil
        isWaitingForPushToken = false
    }

    private func cancelLocalWork() {
        operationID = nil
        isSessionActionInProgress = false
        isRotatingToken = false
        tokenTask?.cancel()
        tokenTask = nil
        tokenWorkID = nil
        cacheOperationID = nil
        isLoadingCachedQuota = false
        latestToken = nil
        acknowledgedToken = nil
        blockedToken = nil
        attachedActivityID = nil
        localActivitySnapshot = nil
        liveActivityDriver.detachActivity()
        clearPendingIntent()
    }

    private func acceptLoadedSession(_ context: Connection, operation: UUID) async {
        guard isCurrent(context, operation), let session = store?.session else { return }
        syncPersistedState(context)
        clearPendingIntent()
        blockedToken = nil
        if session.status != .active {
            await liveActivityDriver.endActivity(activityID: session.activityID, immediate: true)
            guard isCurrent(context, operation) else { return }
            attachedActivityID = nil
            localActivitySnapshot = nil
            latestToken = nil
        } else {
            do {
                let restored = try await liveActivityDriver.restoreActivity(activityID: session.activityID,
                    sourceID: session.sourceID, onPushTokenUpdate: tokenCallback(context: context, sessionID: session.id),
                    onSystemDismissed: dismissalCallback(context: context))
                guard isCurrent(context, operation) else { return }
                attachedActivityID = restored?.activityID == liveActivityDriver.activeActivityID ? restored?.activityID : nil
                localActivitySnapshot = attachedActivityID == nil ? nil : liveActivityDriver.currentSnapshot
                // The observer may have advanced since restore captured its return value.
                // Read the driver's current token only after confirming the exact active ID.
                if let activityID = attachedActivityID, let token = liveActivityDriver.latestPushTokenHex {
                    receiveToken(activityID: activityID, token: token, sessionID: session.id, context: context)
                }
                await updateBoundActivity(context, operation: operation)
            } catch {
                guard isCurrent(context, operation) else { return }
                bridgeFormError = "远端会话已确认，但无法恢复其原系统活动；未创建替代活动或改绑令牌。"
            }
        }
        guard isCurrent(context, operation) else { return }
        bridgeStatusNotice = session.status == .active && attachedActivityID == nil
            ? "远端会话仍在运行，但本机已无对应活动。可明确停止后新建；未自动替换活动身份。"
            : "已与原桥接完成会话对账。"
    }

    private func updateBoundActivity(_ context: Connection, operation: UUID) async {
        guard isCurrent(context, operation), let session = store?.session, let snapshot = session.snapshot,
              attachedActivityID == session.activityID else { return }
        try? await liveActivityDriver.updateActivity(activityID: session.activityID, snapshot: snapshot)
    }

    private func sameAddress(_ record: PersistedMonitoringRecord, _ context: Connection) -> Bool {
        guard let url = URL(string: record.bridgeBaseURLString), let address = try? MonitorBridgeAddress(baseURL: url) else { return false }
        return address == context.address
    }

    private func matches(_ record: PersistedMonitoringRecord, _ context: Connection) -> Bool {
        sameAddress(record, context) && record.credentialBindingID == context.bindingID
    }

    private func isConfirmedTerminal(_ record: PersistedMonitoringRecord) -> Bool {
        record.stopIntentRecorded || record.terminalStatus.map { $0 != .active } == true
    }

    private func sessionMatchesRecord(_ session: MonitoringSession?, _ record: PersistedMonitoringRecord) -> Bool {
        guard let session else { return false }
        return session.id == record.sessionID && session.sourceID == record.sourceID && session.accountIDs == record.accountIDs &&
            session.activityID == record.activityID && session.revision >= record.lastKnownRevision &&
            (!isConfirmedTerminal(record) || session.status != .active)
    }

    private func sessionMatchesIntent(_ session: MonitoringSession?, _ intent: PendingIntent) -> Bool {
        guard let session else { return false }
        return session.id == intent.id && session.sourceID == intent.sourceID && session.accountIDs == intent.accountIDs &&
            session.activityID == intent.activityID
    }

    private func saveIntent(_ intent: PendingIntent, context: Connection) {
        upsert(PersistedMonitoringRecord(sessionID: intent.id, bridgeBaseURLString: context.address.baseURL.absoluteString,
            sourceID: intent.sourceID, accountIDs: intent.accountIDs, durationSeconds: intent.duration.rawValue,
            activityID: intent.activityID ?? "", lastKnownRevision: 1, stopIntentRecorded: false,
            credentialBindingID: context.bindingID))
    }

    private func recordFor(_ session: MonitoringSession, context: Connection,
                           existing: PersistedMonitoringRecord?, cancelled: Bool = false) -> PersistedMonitoringRecord {
        PersistedMonitoringRecord(sessionID: session.id, bridgeBaseURLString: context.address.baseURL.absoluteString,
            sourceID: session.sourceID, accountIDs: session.accountIDs,
            durationSeconds: existing?.durationSeconds ?? Int(session.expiresAt - session.startsAt),
            activityID: session.activityID, lastKnownRevision: session.revision, stopIntentRecorded: cancelled,
            credentialBindingID: context.bindingID, terminalStatus: session.status == .active ? nil : session.status)
    }

    private func syncPersistedState(_ context: Connection) {
        guard isCurrent(context), let store, let id = store.sessionID else { return }
        syncRecord(id: id, session: store.session, cancelled: store.cancellationReceipt != nil, context: context)
    }

    private func syncRecord(id: UUID, session: MonitoringSession?, cancelled: Bool, context: Connection) {
        let existing = persistedRecords.first { $0.sessionID == id && matches($0, context) }
        if let session {
            upsert(recordFor(session, context: context, existing: existing, cancelled: cancelled))
        } else if let existing {
            upsert(PersistedMonitoringRecord(sessionID: id, bridgeBaseURLString: existing.bridgeBaseURLString,
                sourceID: existing.sourceID, accountIDs: existing.accountIDs, durationSeconds: existing.durationSeconds,
                activityID: existing.activityID, lastKnownRevision: existing.lastKnownRevision,
                stopIntentRecorded: cancelled || existing.stopIntentRecorded, credentialBindingID: context.bindingID,
                terminalStatus: existing.terminalStatus))
        }
    }

    private func captureDetachedConnections(_ context: Connection) {
        for item in store?.detachedSessions ?? [] where detachedConnections[item.handle] == nil {
            detachedConnections[item.handle] = context
        }
    }

    private func syncDetached(_ handle: UUID, context: Connection) {
        guard let item = store?.detachedSessions.first(where: { $0.handle == handle }) else { return }
        syncRecord(id: item.id, session: item.lastSession, cancelled: item.stopIntentRecorded, context: context)
    }

    private func upsert(_ record: PersistedMonitoringRecord) {
        if let index = persistedRecords.firstIndex(where: { $0.id == record.id }) { persistedRecords[index] = record }
        else { persistedRecords.insert(record, at: 0) }
        metadataStore.savePersistedRecords(persistedRecords)
    }

    private func replaceRecord(_ old: PersistedMonitoringRecord, with record: PersistedMonitoringRecord) {
        persistedRecords.removeAll { $0.id == old.id }
        upsert(record)
    }

    private func removeRecord(id: UUID, context: Connection) {
        persistedRecords.removeAll { $0.sessionID == id && matches($0, context) }
        metadataStore.savePersistedRecords(persistedRecords)
    }

    public func monitoringErrorText(_ error: MonitoringError?) -> String {
        guard let error else { return "无错误" }
        switch error {
        case .invalidConfiguration:
            return "配置或参数校验未通过 (invalidConfiguration)"
        case .unauthorized:
            return "桥接 Token 鉴权失败 (401 unauthorized · 已熔断当前桥接客户端后续请求)"
        case .forbidden:
            return "当前 Source 或账号未获桥接白名单授权 (403 forbidden · 仅拒绝当前请求，不影响合法旧会话 DELETE)"
        case .notFound:
            return "服务端未找到该会话或来源 (404 notFound · 不等同于停止成功)"
        case .conflict:
            return "状态版本冲突或旧会话尚未确认停止 (409 conflict)"
        case .rateLimited:
            return "桥接接口触发限流冷却 (429 rateLimited)"
        case .capacityExceeded:
            return "服务端历史意图容量已满 (507 capacityExceeded · 非凭据过期，不自动盲目重试；既有会话仍可查询与停止)"
        case .serviceUnavailable:
            return "监控桥接服务暂不可用 (5xx/503 serviceUnavailable)"
        case .redirectRefused:
            return "已拒绝不安全的 HTTP 重定向 (redirectRefused)"
        case .rejected:
            return "服务端拒绝了监控请求 (rejected)"
        case .invalidResponse:
            return "服务端响应违反单调性/版本/大小合同 (invalidResponse)"
        case .network:
            return "网络或连接超时 (network · 状态保持 uncertain 待对账)"
        }
    }
}
