import Foundation
import Observation
import CPAQuotaKit

public struct PersistedMonitoringRecord: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let bridgeBaseURLString: String
    public let sourceID: String
    public let accountIDs: [String]
    public let durationSeconds: Int
    public let activityID: String
    public let lastKnownRevision: UInt64
    public let stopIntentRecorded: Bool
    public let savedAt: Date

    public init(
        sessionID: UUID,
        bridgeBaseURLString: String,
        sourceID: String,
        accountIDs: [String],
        durationSeconds: Int,
        activityID: String,
        lastKnownRevision: UInt64,
        stopIntentRecorded: Bool,
        savedAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.bridgeBaseURLString = bridgeBaseURLString
        self.sourceID = sourceID
        self.accountIDs = accountIDs
        self.durationSeconds = durationSeconds
        self.activityID = activityID
        self.lastKnownRevision = lastKnownRevision
        self.stopIntentRecorded = stopIntentRecorded
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

@MainActor
public protocol SystemLiveActivityDriver: AnyObject {
    var isSupportedOnCurrentPlatform: Bool { get }
    var areActivitiesEnabled: Bool { get }
    var activeActivityID: String? { get }
    var latestPushTokenHex: String? { get }
    var selectedRotationIndex: Int { get set }

    func startActivity(
        sourceID: String,
        initialSnapshot: MonitoringSnapshot?,
        onPushTokenUpdate: @escaping @MainActor (String) -> Void,
        onSystemDismissed: @escaping @MainActor (String) -> Void
    ) async throws -> LocalLiveActivityRegistrationResult

    func updateActivity(snapshot: MonitoringSnapshot) async throws
    func endActivity(immediate: Bool) async
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
    public private(set) var isSavedInKeychain = false
    public private(set) var bridgeFormError: String?
    public private(set) var bridgeStatusNotice: String?
    public private(set) var cachedSourceSnapshot: MonitoringSnapshot?
    public private(set) var persistedRecords: [PersistedMonitoringRecord] = []

    public var bridgeURLDraft: String = ""
    public var bridgeTokenDraft: String = ""
    public var rememberBridgeDraft: Bool = true

    public var sourceIDDraft: String = ""
    public var selectedAccountIDsDraft: [String] = []
    public var newAccountIDDraft: String = ""
    public var durationDraft: MonitoringDuration = .fourHours
    public var manualActivityIDDraft: String = ""
    public var manualPushTokenDraft: String = ""

    /// Pending UUID preserved across create timeouts so retries reconcile the same UUID instead of minting a new one (U16).
    public private(set) var pendingCreateUUID: UUID?

    @ObservationIgnored private let credentialStore: MonitoringBridgeCredentialStore
    @ObservationIgnored private let metadataStore: any MonitoringMetadataPersistence
    @ObservationIgnored private let clientFactory: @Sendable (URL, MonitorBridgeToken) throws -> CPAMonitorClient
    @ObservationIgnored public let liveActivityDriver: any SystemLiveActivityDriver

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
        self.persistedRecords = metadataStore.loadPersistedRecords()
        if let saved = metadataStore.loadSavedBridgeAddress() {
            self.bridgeURLDraft = saved
        }
    }

    public func restoreBridgeIfAvailable() async {
        bridgeFormError = nil
        guard let saved = metadataStore.loadSavedBridgeAddress(),
              let rawURL = URL(string: saved) else {
            return
        }
        do {
            let address = try MonitorBridgeAddress(baseURL: rawURL)
            guard let token = try await credentialStore.load(for: address) else {
                bridgeState = .unconfigured
                isSavedInKeychain = false
                return
            }
            let client = try clientFactory(address.baseURL, token)
            bindClient(client, address: address, isSaved: true)
            await reconcilePersistedRecordIfMatching(address: address)
        } catch let error as CPAError {
            bridgeFormError = ErrorPresentation(error: error).summary
        } catch {
            bridgeFormError = "桥接地址或安全存储读取失败，请重新验证桥接配置。"
        }
    }

    public func connectBridge(
        rawURLString: String,
        rawTokenString: String,
        rememberInKeychain: Bool
    ) async {
        bridgeFormError = nil
        bridgeStatusNotice = nil
        let trimmedURL = rawURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsedURL = URL(string: trimmedURL) else {
            bridgeFormError = "请输入合法的 HTTPS 监控桥接地址（不含用户名密码、查询参数或锚点）。"
            return
        }
        let address: MonitorBridgeAddress
        let token: MonitorBridgeToken
        let client: CPAMonitorClient
        do {
            address = try MonitorBridgeAddress(baseURL: parsedURL)
            token = try MonitorBridgeToken(rawTokenString)
            client = try clientFactory(address.baseURL, token)
        } catch MonitoringError.invalidConfiguration {
            bridgeFormError = "桥接地址需为安全 HTTPS URL，且桥接 Token 不能为空或包含控制字符。"
            return
        } catch {
            bridgeFormError = "桥接配置格式无效，请检查 HTTPS 地址与独立桥接 Token。"
            return
        }

        var savedFlag = false
        if rememberInKeychain {
            do {
                try await credentialStore.save(token, for: address)
                metadataStore.saveBridgeAddress(address.baseURL.absoluteString)
                savedFlag = true
            } catch let error as CPAError {
                bridgeFormError = ErrorPresentation(error: error).summary
                savedFlag = false
            } catch {
                bridgeFormError = ErrorPresentation(error: CPAError(.secureStorageFailure)).summary
                savedFlag = false
            }
        } else {
            if let oldAddress = activeAddress {
                try? await credentialStore.remove(for: oldAddress)
            }
            metadataStore.saveBridgeAddress(nil)
        }

        bindClient(client, address: address, isSaved: savedFlag)
        bridgeURLDraft = address.baseURL.absoluteString
        bridgeTokenDraft = ""
        await reconcilePersistedRecordIfMatching(address: address)
    }

    private func bindClient(_ client: CPAMonitorClient, address: MonitorBridgeAddress, isSaved: Bool) {
        if let existingStore = store {
            existingStore.replaceClient(client)
        } else {
            store = MonitoringStore(client: client)
        }
        activeAddress = address
        isSavedInKeychain = isSaved
        bridgeState = .connected(address: address.baseURL, isSavedInKeychain: isSaved)
    }

    private func reconcilePersistedRecordIfMatching(address: MonitorBridgeAddress) async {
        guard let store else { return }
        if let record = persistedRecords.first(where: { $0.bridgeBaseURLString == address.baseURL.absoluteString }) {
            sourceIDDraft = record.sourceID
            selectedAccountIDsDraft = record.accountIDs
            if let dur = MonitoringDuration(rawValue: record.durationSeconds) {
                durationDraft = dur
            }
            if !record.stopIntentRecorded {
                await store.load(id: record.sessionID)
                syncPersistedStateFromStore()
            }
        }
    }

    /// Forget local bridge credentials only. Does NOT claim the remote monitoring session has stopped (MON-01, U19).
    public func forgetBridgeLocallyOnly() async {
        bridgeFormError = nil
        let targetAddress: MonitorBridgeAddress? = activeAddress ?? {
            guard let saved = metadataStore.loadSavedBridgeAddress(), let url = URL(string: saved) else { return nil }
            return try? MonitorBridgeAddress(baseURL: url)
        }()

        if let targetAddress {
            do {
                try await credentialStore.remove(for: targetAddress)
            } catch let error as CPAError {
                bridgeFormError = ErrorPresentation(error: error).summary
                return
            } catch {
                bridgeFormError = ErrorPresentation(error: CPAError(.secureStorageFailure)).summary
                return
            }
        }

        metadataStore.saveBridgeAddress(nil)
        isSavedInKeychain = false
        activeAddress = nil
        bridgeState = .unconfigured
        bridgeTokenDraft = ""

        if let currentID = store?.sessionID {
            bridgeStatusNotice = "已从本机 Keychain 移除桥接凭据。注意：仅在本机忘记凭据不等于服务端监控已停止（会话 \(currentID.uuidString.prefix(8))… 将按服务端有限期租约自然到期兜底，或重新连接后显式停止）。"
        } else {
            bridgeStatusNotice = "已从本机 Keychain 移除桥接凭据。"
        }
    }

    /// Attempt to stop the remote session first, verify 204 cancellation receipt, then forget local credentials.
    public func stopAndForgetBridge() async {
        bridgeFormError = nil
        if let store, store.sessionID != nil {
            await stopActiveMonitoringSession()
            if store.state != .stopIntentRecorded && store.session?.status != .stopped && store.session?.status != .expired {
                bridgeStatusNotice = "服务端停止未获得确认回执（状态不明 uncertain），已保留会话 UUID 供后续对账；若仍需仅清除本机凭据，请选择「仅在本机忘记桥接凭据」。"
                return
            }
        }
        await forgetBridgeLocallyOnly()
    }

    public func addAccountIDDraft(_ rawID: String) {
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !selectedAccountIDsDraft.contains(trimmed) else { return }
        guard selectedAccountIDsDraft.count < 5 else {
            bridgeFormError = "单次监控会话最多选择 5 个授权账号 ID（1–5 个）。"
            return
        }
        selectedAccountIDsDraft.append(trimmed)
        newAccountIDDraft = ""
        bridgeFormError = nil
    }

    public func removeAccountIDDraft(_ id: String) {
        selectedAccountIDsDraft.removeAll { $0 == id }
    }

    public func startOrReconcileMonitoringSession() async {
        bridgeFormError = nil
        bridgeStatusNotice = nil
        guard let store, let activeAddress else {
            bridgeFormError = "尚未配置监控桥接连接，无法启动监控会话。"
            return
        }

        let trimmedSource = sourceIDDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty else {
            bridgeFormError = "请填写部署侧配置的授权 Source ID（桥接不提供任意来源枚举接口）。"
            return
        }
        guard (1...5).contains(selectedAccountIDsDraft.count) else {
            bridgeFormError = "请指定 1–5 个部署白名单授权的 CPA 账号 ID。"
            return
        }

        // If a previous create timed out or became uncertain with a known pendingCreateUUID, reconcile it first (U16)!
        if let existingPending = pendingCreateUUID,
           store.sessionID == existingPending,
           store.state == .uncertain {
            await store.load(id: existingPending)
            syncPersistedStateFromStore()
            if store.state == .available {
                pendingCreateUUID = nil
                bridgeStatusNotice = "已使用原 UUID (\(existingPending.uuidString.prefix(8))…) 与服务端完成对账恢复，未重复创建新会话。"
                return
            }
        }

        var resolvedActivityID = manualActivityIDDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        var resolvedPushTokenHex = manualPushTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)

        if resolvedActivityID.isEmpty || resolvedPushTokenHex.isEmpty {
            if liveActivityDriver.isSupportedOnCurrentPlatform && liveActivityDriver.areActivitiesEnabled {
                do {
                    let result = try await liveActivityDriver.startActivity(
                        sourceID: trimmedSource,
                        initialSnapshot: cachedSourceSnapshot
                    ) { [weak self] newTokenHex in
                        guard let self else { return }
                        Task { @MainActor in
                            await self.handleSystemPushTokenRotation(newTokenHex: newTokenHex)
                        }
                    } onSystemDismissed: { [weak self] dismissedActivityID in
                        guard let self else { return }
                        Task { @MainActor in
                            self.handleUserDismissedActivity(activityID: dismissedActivityID)
                        }
                    }
                    if resolvedActivityID.isEmpty {
                        resolvedActivityID = result.activityID
                    }
                    if resolvedPushTokenHex.isEmpty, let tokenHex = result.initialPushTokenHex {
                        resolvedPushTokenHex = tokenHex
                    }
                } catch {
                    // Fall through to check if activity ID & push token are present
                }
            }
        }

        guard !resolvedActivityID.isEmpty, !resolvedPushTokenHex.isEmpty else {
            bridgeFormError = "缺少真实 Activity ID 或 APNs 活动 Push Token（当前环境未启用系统 Live Activity 推送令牌）。客户端拒绝生成假 Token 或创建假会话。"
            return
        }

        let sessionUUID = pendingCreateUUID ?? UUID()
        let registration: MonitoringRegistration
        do {
            let pushToken = try MonitoringPushToken(resolvedPushTokenHex)
            registration = try MonitoringRegistration(
                id: sessionUUID,
                sourceID: trimmedSource,
                accountIDs: selectedAccountIDsDraft,
                duration: durationDraft,
                activityID: resolvedActivityID,
                pushToken: pushToken
            )
        } catch {
            bridgeFormError = "监控注册参数校验未通过：请确认 Source ID、账号 ID (1–5个) 与十六进制偶数长度 Push Token 符合安全合同。"
            return
        }

        pendingCreateUUID = sessionUUID
        upsertPersistedRecord(
            PersistedMonitoringRecord(
                sessionID: sessionUUID,
                bridgeBaseURLString: activeAddress.baseURL.absoluteString,
                sourceID: trimmedSource,
                accountIDs: selectedAccountIDsDraft,
                durationSeconds: durationDraft.rawValue,
                activityID: resolvedActivityID,
                lastKnownRevision: 1,
                stopIntentRecorded: false
            )
        )

        await store.start(registration)
        syncPersistedStateFromStore()

        if store.state == .available {
            pendingCreateUUID = nil
            if let snapshot = store.session?.snapshot {
                try? await liveActivityDriver.updateActivity(snapshot: snapshot)
            }
        } else if store.state == .uncertain {
            bridgeStatusNotice = "创建请求结果未确认（可能超时或网络中断）。已固定保留会话 UUID (\(sessionUUID.uuidString.prefix(8))…)，点击「对账恢复 / 重试」将按同一 UUID 查询或幂等恢复，不会盲目新建 UUID。"
        }
    }

    public func reconcileCurrentSession() async {
        guard let store else { return }
        guard let id = store.sessionID ?? pendingCreateUUID ?? persistedRecords.first?.sessionID else {
            bridgeFormError = "当前没有待对账的监控会话 UUID。"
            return
        }
        await store.load(id: id)
        syncPersistedStateFromStore()
        if let snapshot = store.session?.snapshot {
            try? await liveActivityDriver.updateActivity(snapshot: snapshot)
        }
        if store.state == .available {
            pendingCreateUUID = nil
            bridgeStatusNotice = "会话 \(id.uuidString.prefix(8))… 对账完成（状态: \(store.session?.status.rawValue ?? "未知")，revision: \(store.session?.revision ?? 0)）。"
        }
    }

    public func refreshActiveMonitoringSession() async {
        guard let store, store.sessionID != nil else { return }
        await store.refresh()
        syncPersistedStateFromStore()
        if let snapshot = store.session?.snapshot {
            try? await liveActivityDriver.updateActivity(snapshot: snapshot)
        }
        if store.state == .available {
            bridgeStatusNotice = "已收到服务端刷新响应（注意：HTTP 200/202 仅代表服务端接受刷新意图或返回当前会话，不代表 APNs 已送达设备）。"
        }
    }

    public func stopActiveMonitoringSession() async {
        guard let store, let id = store.sessionID else { return }
        await store.stop()
        syncPersistedStateFromStore()
        if store.state == .stopIntentRecorded {
            pendingCreateUUID = nil
            await liveActivityDriver.endActivity(immediate: true)
            bridgeStatusNotice = "服务端已返回 HTTP 204 持久取消墓碑回执（会话 \(id.uuidString.prefix(8))… 已记录停止意图；回执代表服务端取消约束生效，不直接代表 APNs end 已送达）。"
        } else if let session = store.session, session.status != .active {
            pendingCreateUUID = nil
            await liveActivityDriver.endActivity(immediate: true)
            bridgeStatusNotice = "监控会话已处于终态 (\(session.status.rawValue))。"
        } else {
            bridgeStatusNotice = "停止请求未获得 204 确认（当前状态 uncertain，错误: \(monitoringErrorText(store.error))）。404/超时/507 均不会伪造取消回执，会话 UUID 已保留供后续对账或再次停止。"
        }
    }

    public func loadCachedQuotaForDraftSource() async {
        bridgeFormError = nil
        let trimmedSource = sourceIDDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty else {
            bridgeFormError = "请先输入授权 Source ID 再读取缓存快照。"
            return
        }
        guard let activeAddress,
              let token = try? await credentialStore.load(for: activeAddress),
              let client = try? clientFactory(activeAddress.baseURL, token) else {
            bridgeFormError = "请先连接并保存有效的桥接凭据后再读取缓存快照。"
            return
        }
        do {
            let snap = try await client.cachedQuota(sourceID: trimmedSource)
            cachedSourceSnapshot = snap
            try? await liveActivityDriver.updateActivity(snapshot: snap)
            bridgeStatusNotice = "已读取 Source '\(trimmedSource)' 缓存快照（seq #\(snap.sequence)，phase: \(snap.phase.rawValue)）。"
        } catch let error as MonitoringError {
            bridgeFormError = monitoringErrorText(error)
        } catch {
            bridgeFormError = "读取 Source 缓存快照失败。"
        }
    }

    public func handleSystemPushTokenRotation(newTokenHex: String) async {
        guard let store,
              let session = store.session,
              session.status == .active else { return }
        guard let token = try? MonitoringPushToken(newTokenHex) else { return }
        await store.rotate(token: token, revision: session.revision)
        syncPersistedStateFromStore()
    }

    public func handleUserDismissedActivity(activityID: String) {
        bridgeStatusNotice = "用户在系统锁屏/灵动岛关闭了本地 Live Activity (\(activityID))。注意：本地关闭活动不会自动撤销服务端监控租约；如需停止服务端采集，请点击「停止监控会话 (DELETE)」。"
    }

    public func reconcileDetached(handle: UUID) async {
        guard let store else { return }
        do {
            let result = try await store.loadDetached(handle: handle)
            bridgeStatusNotice = "分离会话 \(result.id.uuidString.prefix(8))… 对账状态：\(result.status.rawValue) (rev \(result.revision))。"
        } catch let error as MonitoringError {
            bridgeFormError = "分离会话对账未完成：\(monitoringErrorText(error))"
        } catch {
            bridgeFormError = "分离会话对账失败。"
        }
    }

    public func stopDetached(handle: UUID) async {
        guard let store else { return }
        do {
            let result = try await store.stopDetached(handle: handle)
            if result == nil {
                bridgeStatusNotice = "分离会话已获得服务端 DELETE 204 持久取消回执，现在可安全从列表移除。"
            } else {
                bridgeStatusNotice = "分离会话停止返回状态：\(result?.status.rawValue ?? "未知")。"
            }
        } catch let error as MonitoringError {
            bridgeFormError = "分离会话停止未确认：\(monitoringErrorText(error))（404/超时/507 不产生取消回执，请保留对账）。"
        } catch {
            bridgeFormError = "分离会话停止请求失败。"
        }
    }

    public func removeDetached(handle: UUID) {
        guard let store else { return }
        do {
            try store.removeDetached(handle: handle)
            bridgeStatusNotice = "已移除已确认结束的分离会话记录。"
        } catch {
            bridgeFormError = "仅在获得 DELETE 204 取消回执或确认会话处于非 active 终态后，才允许移除分离会话。"
        }
    }

    private func syncPersistedStateFromStore() {
        guard let store, let id = store.sessionID, let activeAddress else { return }
        let existing = persistedRecords.first { $0.sessionID == id }
        let record = PersistedMonitoringRecord(
            sessionID: id,
            bridgeBaseURLString: activeAddress.baseURL.absoluteString,
            sourceID: store.session?.sourceID ?? existing?.sourceID ?? sourceIDDraft,
            accountIDs: store.session?.accountIDs ?? existing?.accountIDs ?? selectedAccountIDsDraft,
            durationSeconds: existing?.durationSeconds ?? durationDraft.rawValue,
            activityID: store.session?.activityID ?? existing?.activityID ?? manualActivityIDDraft,
            lastKnownRevision: store.session?.revision ?? existing?.lastKnownRevision ?? 1,
            stopIntentRecorded: store.state == .stopIntentRecorded || store.cancellationReceipt != nil
        )
        upsertPersistedRecord(record)
    }

    private func upsertPersistedRecord(_ record: PersistedMonitoringRecord) {
        if let idx = persistedRecords.firstIndex(where: { $0.sessionID == record.sessionID }) {
            persistedRecords[idx] = record
        } else {
            persistedRecords.insert(record, at: 0)
        }
        metadataStore.savePersistedRecords(persistedRecords)
    }

    public func removePersistedRecord(sessionID: UUID) {
        if let store, store.sessionID == sessionID, store.state != .stopIntentRecorded, store.session?.status == .active {
            bridgeFormError = "当前活动会话仍在运行或未获停止确认，不能直接遗忘其对账记录。"
            return
        }
        persistedRecords.removeAll { $0.sessionID == sessionID }
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
