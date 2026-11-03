import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CPAQuotaKit
import CPAQuotaUI

@Suite("Monitoring workspace identity and lifecycle", .timeLimit(.minutes(1)))
@MainActor
struct MonitoringWorkspaceReliabilityTests {
    @Test func operationFeedbackShowsSpecificValidation() async {
        let coordinator = workspace(transport: WorkspaceMonitorTransport())
        await coordinator.startOrReconcileMonitoringSession()
        #expect(coordinator.bridgeFormFeedback?.summary == "请先连接监控桥接。")
        coordinator.addAccountIDDraft("invalid account!")
        #expect(coordinator.bridgeFormFeedback?.summary == "账号标识格式无效，请使用监控服务授权的原标识。")
        #expect(coordinator.bridgeFormFeedback?.diagnostics == coordinator.bridgeFormError)
    }

    @Test func cacheErrorsExposeActionableSummaryAndOriginalDiagnostic() async throws {
        for (status, summary, diagnostic) in [
            (401, "监控访问令牌鉴权失败，请检查并更新服务连接。", "桥接 Token 鉴权失败 (401 unauthorized · 已熔断当前桥接客户端后续请求)"),
            (403, "此来源或账号尚未获得监控服务授权，请联系服务维护者。", "当前 Source 或账号未获桥接白名单授权 (403 forbidden · 仅拒绝当前请求，不影响合法旧会话 DELETE)")
        ] {
            let transport = WorkspaceMonitorTransport()
            await transport.setQuotaStatus(status)
            let coordinator = workspace(transport: transport)
            await connect(coordinator, remember: false)
            coordinator.sourceIDDraft = "personal"
            await coordinator.loadCachedQuotaForDraftSource()
            let feedback = try #require(coordinator.bridgeFormFeedback)
            #expect(feedback.summary == summary)
            #expect(feedback.diagnostics == diagnostic)
            #expect(feedback.diagnostics == coordinator.bridgeFormError)
            #expect(!feedback.summary.contains(String(status)))
        }
    }

    @Test func networkFailureAndMissingStopRemainUnconfirmed() async throws {
        let failed = workspace(transport: WorkspaceMonitorTransport(createFails: true))
        await connect(failed)
        drafts(failed)
        await failed.startOrReconcileMonitoringSession()
        let network = try #require(failed.storeErrorFeedback)
        #expect(network.isUncertain)
        #expect(network.diagnostics == failed.monitoringErrorText(.network))
        #expect(failed.bridgeStatusFeedback?.isUncertain == true)

        let transport = WorkspaceMonitorTransport()
        let coordinator = workspace(transport: transport)
        await connect(coordinator)
        drafts(coordinator)
        await coordinator.startOrReconcileMonitoringSession()
        await transport.setDeleteStatus(404)
        await coordinator.stopActiveMonitoringSession()
        let status = try #require(coordinator.bridgeStatusFeedback)
        #expect(status.isUncertain)
        #expect(status.summary.contains("尚未确认"))
        #expect(status.summary.contains("不代表停止成功"))
        #expect(coordinator.store?.cancellationReceipt == nil)
        #expect(coordinator.storeErrorFeedback?.diagnostics == coordinator.monitoringErrorText(.notFound))
    }

    @Test func overallFeedbackKeepsValidationAndUnconfirmedStopVisible() async throws {
        let transport = WorkspaceMonitorTransport()
        let coordinator = workspace(transport: transport)
        await connect(coordinator)
        drafts(coordinator)
        await coordinator.startOrReconcileMonitoringSession()
        coordinator.addAccountIDDraft("invalid account!")
        await transport.setDeleteStatus(404)
        await coordinator.stopActiveMonitoringSession()
        let feedback = try #require(coordinator.operationFeedback)
        #expect(feedback.summary.contains("账号标识格式无效"))
        #expect(feedback.summary.contains("尚未确认"))
        #expect(feedback.summary.contains("不代表停止成功"))
        #expect(feedback.isUncertain)
        #expect(coordinator.bridgeFormError == "账号标识格式无效，请使用监控服务授权的原标识。")
        #expect(coordinator.store?.cancellationReceipt == nil)
    }

    @Test func temporaryCacheUsesTheBoundClientAndSharesCooldown() async throws {
        let transport = WorkspaceMonitorTransport()
        await transport.setQuotaStatus(429)
        let coordinator = workspace(transport: transport)
        await connect(coordinator, remember: false)
        coordinator.sourceIDDraft = "personal"
        await coordinator.loadCachedQuotaForDraftSource()
        await coordinator.loadCachedQuotaForDraftSource()
        #expect(await transport.count(method: "GET", suffix: "/quota") == 1)
        #expect(coordinator.cachedSourceSnapshot == nil)
        #expect(coordinator.bridgeFormError?.contains("429") == true)
    }

    @Test func lateCacheCannotCrossBridgeOrUpdateAnActivity() async throws {
        let gate = WorkspaceGate()
        let first = WorkspaceMonitorTransport(quotaGate: gate)
        let second = WorkspaceMonitorTransport()
        let driver = WorkspaceActivityDriver()
        let coordinator = workspace(transport: first, second: second, driver: driver)
        await connect(coordinator)
        coordinator.sourceIDDraft = "personal"
        let read = Task { await coordinator.loadCachedQuotaForDraftSource() }
        await gate.waitUntilEntered()
        await connect(coordinator, host: "second.invalid", token: "second-fixture-token")
        coordinator.sourceIDDraft = "other"
        await gate.open()
        await read.value
        #expect(coordinator.cachedSourceSnapshot == nil)
        #expect(coordinator.cachedSourceID == nil)
        #expect(driver.updatedIDs.isEmpty)
    }

    @Test func historyNeverRoutesAnOldUUIDToAnotherBridge() async throws {
        let first = WorkspaceMonitorTransport()
        let second = WorkspaceMonitorTransport()
        let coordinator = workspace(transport: first, second: second)
        await connect(coordinator)
        drafts(coordinator)
        await coordinator.startOrReconcileMonitoringSession()
        let original = try #require(coordinator.persistedRecords.first)
        await connect(coordinator, host: "second.invalid", token: "second-fixture-token")
        await coordinator.loadPersistedRecord(original)
        await coordinator.stopActiveMonitoringSession()
        #expect(await second.totalCount() == 0)
        #expect(coordinator.persistedRecords.contains(original))
        #expect(coordinator.store?.sessionID == nil)
        #expect(coordinator.store?.detachedSessions.count == 1)
    }

    @Test func changedCredentialRequiresGetProofAndDoesNotInheritCancellation() async throws {
        let transport = WorkspaceMonitorTransport()
        let coordinator = workspace(transport: transport)
        await connect(coordinator)
        drafts(coordinator)
        await coordinator.startOrReconcileMonitoringSession()
        let original = try #require(coordinator.persistedRecords.first)
        let oldBinding = coordinator.credentialBindingID
        await connect(coordinator, token: "new-principal-fixture")
        #expect(coordinator.credentialBindingID != oldBinding)
        #expect(coordinator.store?.sessionID == nil)
        await transport.setGetsHidden(true)
        await coordinator.loadPersistedRecord(original)
        await coordinator.stopActiveMonitoringSession()
        #expect(await transport.count(method: "DELETE") == 0)
        #expect(coordinator.persistedRecords.contains(original))
        await transport.setGetsHidden(false)
        await coordinator.loadPersistedRecord(original)
        let adopted = try #require(coordinator.persistedRecords.first)
        #expect(adopted.credentialBindingID == coordinator.credentialBindingID)
        #expect(adopted.sessionID == original.sessionID)
        #expect(!adopted.stopIntentRecorded)
        #expect(coordinator.store?.sessionID == original.sessionID)
    }

    @Test func firstAsynchronousTokenUsesExactlyOneActivityAndOneImmutableIntent() async throws {
        let transport = WorkspaceMonitorTransport()
        let driver = WorkspaceActivityDriver(initialToken: nil)
        let coordinator = workspace(transport: transport, driver: driver)
        await connect(coordinator)
        drafts(coordinator)
        await coordinator.startOrReconcileMonitoringSession()
        let id = try #require(coordinator.pendingCreateUUID)
        #expect(coordinator.isWaitingForPushToken)
        #expect(driver.startCount == 1)
        #expect(await transport.totalCount() == 0)
        coordinator.sourceIDDraft = "changed"
        coordinator.selectedAccountIDsDraft = ["other"]
        await coordinator.startOrReconcileMonitoringSession()
        #expect(driver.startCount == 1)
        driver.emitToken("bb22")
        await waitUntil { coordinator.store?.state == .available && !coordinator.isBusy }
        #expect(coordinator.store?.session?.id == id)
        #expect(coordinator.store?.session?.sourceID == "personal")
        #expect(coordinator.store?.session?.accountIDs == ["account-1"])
        #expect(await transport.count(method: "POST", suffix: "/sessions") == 1)
        #expect(driver.startCount == 1)
        #expect(coordinator.pendingCreateUUID == nil)
    }

    @Test func tokenCallbackBeforeStartReturnsIsNotLost() async throws {
        let transport = WorkspaceMonitorTransport()
        let driver = WorkspaceActivityDriver(initialToken: nil, tokenDuringStart: "bb22")
        let coordinator = workspace(transport: transport, driver: driver)
        await connect(coordinator)
        drafts(coordinator)
        await coordinator.startOrReconcileMonitoringSession()
        #expect(coordinator.store?.state == .available)
        #expect(await transport.count(method: "POST", suffix: "/sessions") == 1)
        #expect(await transport.lastToken() == "bb22")
    }

    @Test func readsAndHistoryCannotDiscardAnUnsubmittedActivity() async throws {
        let transport = WorkspaceMonitorTransport()
        let driver = WorkspaceActivityDriver(initialToken: nil)
        let coordinator = workspace(transport: transport, driver: driver)
        await connect(coordinator)
        drafts(coordinator)
        await coordinator.startOrReconcileMonitoringSession()
        let pending = try #require(coordinator.pendingCreateUUID)
        let history = PersistedMonitoringRecord(sessionID: UUID(), bridgeBaseURLString: "https://first.invalid",
            sourceID: "personal", accountIDs: ["account-1"], durationSeconds: 14400,
            activityID: "old-activity", lastKnownRevision: 1, stopIntentRecorded: false)
        await coordinator.reconcileCurrentSession()
        await coordinator.refreshActiveMonitoringSession()
        await coordinator.loadPersistedRecord(history)
        #expect(coordinator.pendingCreateUUID == pending)
        #expect(coordinator.store?.sessionID == nil)
        #expect(coordinator.isWaitingForPushToken)
        #expect(await transport.totalCount() == 0)
        await coordinator.stopActiveMonitoringSession()
        #expect(await transport.totalCount() == 0)
    }

    @Test func restoreUsesTheLatestObservedTokenAndStartRequiresALiveActivity() async throws {
        let transport = WorkspaceMonitorTransport()
        let driver = WorkspaceActivityDriver(tokenDuringRestore: "cc33")
        let coordinator = workspace(transport: transport, driver: driver)
        await connect(coordinator)
        drafts(coordinator)
        await coordinator.startOrReconcileMonitoringSession()
        await waitUntil { coordinator.store?.session?.revision == 2 && !coordinator.isBusy }
        #expect(await transport.lastToken() == "cc33")
        #expect(await transport.count(method: "PUT") == 1)

        let endedTransport = WorkspaceMonitorTransport()
        let endedDriver = WorkspaceActivityDriver(endDuringStart: true)
        let ended = workspace(transport: endedTransport, driver: endedDriver)
        await connect(ended)
        drafts(ended)
        await ended.startOrReconcileMonitoringSession()
        #expect(await endedTransport.totalCount() == 0)
        #expect(ended.pendingCreateUUID != nil)
        await ended.stopActiveMonitoringSession()
        #expect(ended.pendingCreateUUID == nil)
    }

    @Test func createCancellationPersistsTheReceiptAndAllowsANewUUID() async throws {
        let gate = WorkspaceGate()
        let transport = WorkspaceMonitorTransport(createGate: gate)
        let driver = WorkspaceActivityDriver()
        let coordinator = workspace(transport: transport, driver: driver)
        await connect(coordinator)
        drafts(coordinator)
        let create = Task { await coordinator.startOrReconcileMonitoringSession() }
        await gate.waitUntilEntered()
        let oldID = try #require(coordinator.pendingCreateUUID)
        await coordinator.stopActiveMonitoringSession()
        #expect(coordinator.store?.state == .stopIntentRecorded)
        #expect(coordinator.persistedRecords.first?.stopIntentRecorded == true)
        #expect(coordinator.pendingCreateUUID == nil)
        await gate.open()
        await create.value
        await coordinator.startOrReconcileMonitoringSession()
        #expect(coordinator.store?.state == .available)
        #expect(coordinator.store?.sessionID != oldID)
        #expect(driver.endedIDs == ["activity-1"])
        #expect(driver.startCount == 2)
    }

    @Test func waitingForTokenCanBeCancelledWithoutARequestOrOrphanActivity() async throws {
        let transport = WorkspaceMonitorTransport()
        let driver = WorkspaceActivityDriver(initialToken: nil)
        let coordinator = workspace(transport: transport, driver: driver)
        await connect(coordinator)
        drafts(coordinator)
        await coordinator.startOrReconcileMonitoringSession()
        await coordinator.stopActiveMonitoringSession()
        driver.emitOldToken("cc33")
        await Task.yield()
        #expect(coordinator.pendingCreateUUID == nil)
        #expect(coordinator.persistedRecords.isEmpty)
        #expect(driver.endedIDs == ["activity-1"])
        #expect(await transport.totalCount() == 0)
    }

    @Test func forgetReleasesAllClientsAndRejectsOldCallbacks() async throws {
        let transport = WorkspaceMonitorTransport()
        let driver = WorkspaceActivityDriver()
        let coordinator = workspace(transport: transport, driver: driver)
        await connect(coordinator)
        drafts(coordinator)
        await coordinator.startOrReconcileMonitoringSession()
        let count = await transport.totalCount()
        await coordinator.forgetBridgeLocallyOnly()
        await coordinator.reconcileCurrentSession()
        await coordinator.refreshActiveMonitoringSession()
        await coordinator.stopActiveMonitoringSession()
        driver.emitOldToken("cc33")
        await Task.yield()
        #expect(coordinator.store == nil)
        #expect(coordinator.credentialBindingID == nil)
        #expect(coordinator.bridgeState == .unconfigured)
        #expect(!coordinator.persistedRecords.isEmpty)
        #expect(await transport.totalCount() == count)
    }

    @Test func restartKeepsTheUncertainUUIDAndDoesNotCreateAnotherActivity() async throws {
        let transport = WorkspaceMonitorTransport(createFails: true)
        let credentials = MonitoringBridgeCredentialStore(storage: MemoryCredentialStore())
        let metadata = MemoryMonitoringMetadataPersistence()
        let first = workspace(transport: transport, credentials: credentials, metadata: metadata)
        await connect(first)
        drafts(first)
        await first.startOrReconcileMonitoringSession()
        let id = try #require(first.pendingCreateUUID)
        let driver = WorkspaceActivityDriver()
        let second = workspace(transport: transport, credentials: credentials, metadata: metadata, driver: driver)
        await second.restoreBridgeIfAvailable()
        #expect(second.pendingCreateUUID == id)
        await second.startOrReconcileMonitoringSession()
        #expect(second.pendingCreateUUID == id)
        #expect(second.store?.sessionID == id)
        #expect(driver.startCount == 0)
        #expect(await transport.count(method: "POST", suffix: "/sessions") == 1)
    }

    @Test func tokenRotationCoalescesAndNeverAppliesAnOldActivityTokenToNewBridge() async throws {
        let gate = WorkspaceGate()
        let first = WorkspaceMonitorTransport(rotateGate: gate)
        let second = WorkspaceMonitorTransport()
        let driver = WorkspaceActivityDriver()
        let coordinator = workspace(transport: first, second: second, driver: driver)
        await connect(coordinator)
        drafts(coordinator)
        await coordinator.startOrReconcileMonitoringSession()
        driver.emitToken("bb22")
        await gate.waitUntilEntered()
        driver.emitToken("cc33")
        await gate.open()
        await waitUntil { coordinator.store?.session?.revision == 3 && !coordinator.isBusy }
        #expect(await first.lastToken() == "cc33")
        #expect(await first.count(method: "PUT") == 2)
        await connect(coordinator, host: "second.invalid", token: "second-fixture-token")
        drafts(coordinator)
        await coordinator.startOrReconcileMonitoringSession()
        driver.emitOldToken("dd44")
        await Task.yield()
        #expect(await second.count(method: "PUT") == 0)
    }

    @Test func connectionWritesAreSerializedAndForgetSupersedesAnInFlightWrite() async throws {
        let storage = WorkspaceCredentialStorage()
        let credentials = MonitoringBridgeCredentialStore(storage: storage)
        let coordinator = workspace(transport: WorkspaceMonitorTransport(), credentials: credentials)
        await connect(coordinator, token: "original-fixture")
        let gate = WorkspaceGate()
        await storage.setWriteGate(gate)
        let connecting = Task { await connect(coordinator, token: "candidate-fixture") }
        await gate.waitUntilEntered()
        await connect(coordinator, token: "rejected-concurrent-fixture")
        #expect(coordinator.bridgeFormError?.contains("正在处理") == true)
        let forgetting = Task { await coordinator.forgetBridgeLocallyOnly() }
        await gate.open()
        await connecting.value
        await forgetting.value
        let address = try MonitorBridgeAddress(baseURL: #require(URL(string: "https://first.invalid")))
        #expect(try await credentials.load(for: address) == nil)
        #expect(coordinator.store == nil)
        #expect(coordinator.bridgeState == .unconfigured)
        #expect(await storage.writeCount() == 2)
    }

    @Test func protectedBindingPreservesFullTokenLengthAndLegacyMigrationIsAtomic() async throws {
        let storage = WorkspaceCredentialStorage()
        let credentials = MonitoringBridgeCredentialStore(storage: storage)
        let address = try MonitorBridgeAddress(baseURL: #require(URL(string: "https://first.invalid/prefix")))
        let maximum = try MonitorBridgeToken(String(repeating: "t", count: 4096))
        let first = try await credentials.bind(maximum, for: address, remember: true)
        let repeated = try await credentials.bind(maximum, for: address, remember: true)
        #expect(first.bindingID == repeated.bindingID)
        #expect(try await credentials.loadCredential(for: address)?.bindingID == first.bindingID)
        #expect(try await credentials.loadCredential(for: address)?.matches(maximum) == true)
        let changed = try await credentials.bind(MonitorBridgeToken("changed-fixture"), for: address, remember: true)
        #expect(changed.bindingID != first.bindingID)
        let scope = try address.credentialScope()
        let legacy = Data("legacy-fixture-token".utf8)
        try await storage.saveRecord(legacy, for: scope)
        await storage.setFailWrite(true)
        await #expect(throws: CPAError.self) { _ = try await credentials.loadCredential(for: address) }
        #expect(try await storage.loadRecord(for: scope) == legacy)
        await storage.setFailWrite(false)
        let migrated = try #require(await credentials.loadCredential(for: address))
        #expect(try await credentials.loadCredential(for: address)?.bindingID == migrated.bindingID)
        #expect(migrated.matches(try MonitorBridgeToken("legacy-fixture-token")))
        #expect(throws: CPAError.self) { _ = try ManagementKey(String(repeating: "x", count: 4097)) }
    }

    @Test func localPresentationCanEndWhenRemoteCancellationIsRejected() async throws {
        let transport = WorkspaceMonitorTransport()
        let driver = WorkspaceActivityDriver()
        let coordinator = workspace(transport: transport, driver: driver)
        await connect(coordinator)
        drafts(coordinator)
        await coordinator.startOrReconcileMonitoringSession()
        let originalID = try #require(coordinator.store?.sessionID)
        await transport.setDeleteStatus(507)
        await coordinator.stopActiveMonitoringSession()
        #expect(coordinator.store?.error == .capacityExceeded)
        #expect(coordinator.store?.cancellationReceipt == nil)
        #expect(driver.endedIDs.isEmpty)
        let requests = await transport.totalCount()
        await coordinator.stopLocalActivityDisplay()
        #expect(driver.endedIDs == ["activity-1"])
        #expect(coordinator.localActivityID == nil)
        #expect(coordinator.store?.sessionID == originalID)
        #expect(coordinator.store?.cancellationReceipt == nil)
        #expect(coordinator.persistedRecords.first?.stopIntentRecorded == false)
        #expect(await transport.totalCount() == requests)
        await coordinator.reconcileCurrentSession()
        #expect(coordinator.store?.session?.status == .active)
        #expect(coordinator.localActivityID == nil)
        #expect(driver.startCount == 1)
    }

    @Test func endingOldLocalActivityCannotClearANewBridgeActivityOrNotice() async throws {
        let first = WorkspaceMonitorTransport()
        let second = WorkspaceMonitorTransport()
        let gate = WorkspaceGate()
        let driver = WorkspaceActivityDriver(endGate: gate)
        let coordinator = workspace(transport: first, second: second, driver: driver)
        await connect(coordinator)
        drafts(coordinator)
        await coordinator.startOrReconcileMonitoringSession()
        let ending = Task { await coordinator.stopLocalActivityDisplay() }
        await gate.waitUntilEntered()
        await connect(coordinator, host: "second.invalid", token: "second-fixture-token")
        drafts(coordinator)
        await coordinator.startOrReconcileMonitoringSession()
        let currentNotice = coordinator.bridgeStatusNotice
        #expect(coordinator.localActivityID == "activity-2")
        await gate.open()
        await ending.value
        #expect(driver.endedIDs == ["activity-1"])
        #expect(driver.activeActivityID == "activity-2")
        #expect(coordinator.localActivityID == "activity-2")
        #expect(coordinator.bridgeStatusNotice == currentNotice)
        #expect(await first.count(method: "DELETE") == 0)
        #expect(await second.count(method: "DELETE") == 0)
    }

    @Test func localEndWhileWaitingForTokenCancelsOnlyTheUnsubmittedIntent() async throws {
        let transport = WorkspaceMonitorTransport()
        let driver = WorkspaceActivityDriver(initialToken: nil)
        let coordinator = workspace(transport: transport, driver: driver)
        await connect(coordinator)
        drafts(coordinator)
        await coordinator.startOrReconcileMonitoringSession()
        await coordinator.stopLocalActivityDisplay()
        driver.emitOldToken("cc33")
        await Task.yield()
        #expect(coordinator.pendingCreateUUID == nil)
        #expect(!coordinator.isWaitingForPushToken)
        #expect(coordinator.persistedRecords.isEmpty)
        #expect(driver.endedIDs == ["activity-1"])
        #expect(await transport.totalCount() == 0)
    }

    @Test func appActivationRestoresTheExactActivityWithoutVisitingATabOrStartingAnother() async throws {
        let transport = WorkspaceMonitorTransport()
        let credentials = MonitoringBridgeCredentialStore(storage: MemoryCredentialStore())
        let metadata = MemoryMonitoringMetadataPersistence()
        let driver = WorkspaceActivityDriver()
        let first = workspace(transport: transport, credentials: credentials, metadata: metadata, driver: driver)
        await connect(first)
        drafts(first)
        await first.startOrReconcileMonitoringSession()
        let original = try #require(first.store?.sessionID)
        driver.detachActivity()
        let restored = workspace(transport: transport, credentials: credentials, metadata: metadata, driver: driver)
        await restored.applicationDidBecomeActive()
        #expect(restored.store?.sessionID == original)
        #expect(restored.localActivityID == "activity-1")
        #expect(restored.unassociatedActivities.isEmpty)
        await restored.applicationDidBecomeActive()
        #expect(driver.startCount == 1)
        #expect(await transport.count(method: "POST", suffix: "/sessions") == 1)
    }

    @Test func sourceDeepLinkRejectsUnknownAndAmbiguousBindingsWithoutChangingDrafts() async throws {
        let transport = WorkspaceMonitorTransport()
        let other = PersistedMonitoringRecord(
            sessionID: UUID(), bridgeBaseURLString: "https://other.invalid",
            sourceID: "personal", accountIDs: ["other-account"], durationSeconds: 3_600,
            activityID: "other-activity", lastKnownRevision: 1, stopIntentRecorded: false,
            credentialBindingID: UUID()
        )
        let metadata = MemoryMonitoringMetadataPersistence(records: [other])
        let coordinator = workspace(transport: transport, metadata: metadata)
        await connect(coordinator)
        drafts(coordinator)
        await coordinator.startOrReconcileMonitoringSession()
        let original = coordinator.store?.sessionID
        coordinator.sourceIDDraft = "current-draft"
        let requests = await transport.totalCount()
        await coordinator.openSourceFromDeepLink("unknown-source")
        await coordinator.openSourceFromDeepLink("personal")
        #expect(coordinator.sourceIDDraft == "current-draft")
        #expect(coordinator.store?.sessionID == original)
        #expect(coordinator.persistedRecords.contains(other))
        #expect(await transport.totalCount() == requests)
    }

    @Test func invalidSelectionDoesNotCreateASystemActivity() async throws {
        let transport = WorkspaceMonitorTransport()
        let driver = WorkspaceActivityDriver()
        let coordinator = workspace(transport: transport, driver: driver)
        await connect(coordinator)
        coordinator.sourceIDDraft = "personal"
        coordinator.selectedAccountIDsDraft = ["not/a-valid-id"]
        await coordinator.startOrReconcileMonitoringSession()
        #expect(driver.startCount == 0)
        #expect(coordinator.pendingCreateUUID == nil)
        #expect(await transport.totalCount() == 0)
    }

    @Test func knownLocalActivityCanBeExplicitlyEndedAfterForgettingTheBridge() async throws {
        let transport = WorkspaceMonitorTransport()
        let driver = WorkspaceActivityDriver()
        let coordinator = workspace(transport: transport, driver: driver)
        await connect(coordinator)
        drafts(coordinator)
        await coordinator.startOrReconcileMonitoringSession()
        let originalRecord = try #require(coordinator.persistedRecords.first)
        await coordinator.forgetBridgeLocallyOnly()
        coordinator.refreshLocalActivityInventory()
        let local = try #require(coordinator.localActivities.first)
        let requests = await transport.totalCount()
        await coordinator.endLocalActivity(local)
        #expect(driver.endedIDs == ["activity-1"])
        #expect(coordinator.bridgeState == .unconfigured)
        #expect(coordinator.store == nil)
        #expect(coordinator.persistedRecords.contains(originalRecord))
        #expect(await transport.totalCount() == requests)
    }

    private func workspace(transport: WorkspaceMonitorTransport, second: WorkspaceMonitorTransport? = nil,
        credentials: MonitoringBridgeCredentialStore? = nil,
        metadata: MemoryMonitoringMetadataPersistence = MemoryMonitoringMetadataPersistence(),
        driver: WorkspaceActivityDriver? = nil) -> MonitoringWorkspaceCoordinator {
        MonitoringWorkspaceCoordinator(credentialStore: credentials ?? MonitoringBridgeCredentialStore(storage: MemoryCredentialStore()),
            metadataStore: metadata, liveActivityDriver: driver ?? WorkspaceActivityDriver(), clientFactory: { url, token in
                try CPAMonitorClient(baseURL: url, token: token,
                    transport: url.host == "second.invalid" ? (second ?? transport) : transport)
            })
    }

    private func connect(_ coordinator: MonitoringWorkspaceCoordinator, host: String = "first.invalid",
                         token: String = "bridge-fixture-token", remember: Bool = true) async {
        await coordinator.connectBridge(rawURLString: "https://" + host, rawTokenString: token, rememberInKeychain: remember)
    }

    private func drafts(_ coordinator: MonitoringWorkspaceCoordinator) {
        coordinator.sourceIDDraft = "personal"
        coordinator.selectedAccountIDsDraft = ["account-1"]
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async {
        for _ in 0..<10_000 {
            if predicate() { return }
            await Task.yield()
        }
        Issue.record("Expected the bounded synthetic operation to finish")
    }
}

private actor WorkspaceGate {
    private var entered = false
    private var opened = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        entryWaiters.forEach { $0.resume() }; entryWaiters.removeAll()
        if !opened { await withCheckedContinuation { releaseWaiters.append($0) } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entryWaiters.append($0) } }
    }
    func open() {
        opened = true
        releaseWaiters.forEach { $0.resume() }; releaseWaiters.removeAll()
    }
}

private actor WorkspaceCredentialStorage: CredentialRecordStore {
    private var values: [String: Data] = [:]
    private var gate: WorkspaceGate?
    private var writes = 0
    private var failWrite = false
    func setWriteGate(_ gate: WorkspaceGate) { self.gate = gate }
    func setFailWrite(_ value: Bool) { failWrite = value }
    func writeCount() -> Int { writes }
    func load(for server: CPAServer) async throws -> ManagementKey? {
        guard let data = values[server.identifier], let text = String(data: data, encoding: .utf8) else { return nil }
        return try ManagementKey(text)
    }
    func save(_ key: ManagementKey, for server: CPAServer) async throws {
        try await saveRecord(Data(key.value.utf8), for: server)
    }
    func remove(for server: CPAServer) async throws { values.removeValue(forKey: server.identifier) }
    func loadRecord(for server: CPAServer) async throws -> Data? { values[server.identifier] }
    func saveRecord(_ data: Data, for server: CPAServer) async throws {
        let pending = gate; gate = nil
        await pending?.wait()
        if failWrite { throw CPAError(.secureStorageFailure) }
        writes += 1
        values[server.identifier] = data
    }
}

@MainActor
private final class WorkspaceActivityDriver: SystemLiveActivityDriver {
    let isSupportedOnCurrentPlatform = true
    let areActivitiesEnabled = true
    private(set) var activeActivityID: String?
    private(set) var latestPushTokenHex: String?
    var selectedRotationIndex = 0
    private(set) var startCount = 0
    private(set) var endedIDs: [String] = []
    private(set) var updatedIDs: [String] = []
    private var callbacks: [(@MainActor (String, String) -> Void)] = []
    private var sources: [String: String] = [:]
    private let initialToken: String?
    private let tokenDuringStart: String?
    private let tokenDuringRestore: String?
    private let endDuringStart: Bool
    private let endGate: WorkspaceGate?
    init(initialToken: String? = "aa11", tokenDuringStart: String? = nil,
         tokenDuringRestore: String? = nil, endDuringStart: Bool = false, endGate: WorkspaceGate? = nil) {
        self.initialToken = initialToken; self.tokenDuringStart = tokenDuringStart
        self.tokenDuringRestore = tokenDuringRestore; self.endDuringStart = endDuringStart
        self.endGate = endGate
    }
    func startActivity(sourceID: String, initialSnapshot: MonitoringSnapshot?,
        onPushTokenUpdate: @escaping @MainActor (String, String) -> Void,
        onSystemDismissed: @escaping @MainActor (String) -> Void) async throws -> LocalLiveActivityRegistrationResult {
        startCount += 1
        let id = "activity-\(startCount)"
        sources[id] = sourceID
        activeActivityID = id
        latestPushTokenHex = tokenDuringStart ?? initialToken
        callbacks.append(onPushTokenUpdate)
        if let tokenDuringStart { onPushTokenUpdate(id, tokenDuringStart) }
        if endDuringStart { activeActivityID = nil; onSystemDismissed(id) }
        return LocalLiveActivityRegistrationResult(activityID: id, initialPushTokenHex: initialToken)
    }
    func restoreActivity(activityID: String, sourceID: String,
        onPushTokenUpdate: @escaping @MainActor (String, String) -> Void,
        onSystemDismissed: @escaping @MainActor (String) -> Void) async throws -> LocalLiveActivityRegistrationResult? {
        guard sources[activityID] == sourceID else { return nil }
        activeActivityID = activityID
        // Replace the current observer without discarding old callbacks used by stale-event tests.
        if callbacks.isEmpty { callbacks.append(onPushTokenUpdate) }
        else { callbacks[callbacks.count - 1] = onPushTokenUpdate }
        let initial = latestPushTokenHex
        if let tokenDuringRestore {
            latestPushTokenHex = tokenDuringRestore
            onPushTokenUpdate(activityID, tokenDuringRestore)
        }
        return LocalLiveActivityRegistrationResult(activityID: activityID, initialPushTokenHex: initial)
    }
    func updateActivity(activityID: String, snapshot: MonitoringSnapshot) async throws {
        if sources[activityID] != nil { updatedIDs.append(activityID) }
    }
    func endActivity(activityID: String, immediate: Bool) async {
        if activeActivityID == activityID { activeActivityID = nil; latestPushTokenHex = nil }
        await endGate?.wait()
        if sources.removeValue(forKey: activityID) != nil { endedIDs.append(activityID) }
        if activeActivityID == activityID { activeActivityID = nil; latestPushTokenHex = nil }
    }
    func detachActivity() { activeActivityID = nil; latestPushTokenHex = nil }
    func currentActivities() -> [LocalLiveActivityDescriptor] {
        sources.map { LocalLiveActivityDescriptor(id: $0.key, sourceID: $0.value) }
            .sorted { $0.id < $1.id }
    }
    func emitToken(_ token: String) {
        guard let id = activeActivityID else { return }
        latestPushTokenHex = token
        callbacks.last?(id, token)
    }
    func emitOldToken(_ token: String) { callbacks.first?("activity-1", token) }
}

private actor WorkspaceMonitorTransport: HTTPTransport {
    private struct Create: Codable, Sendable, Equatable {
        let id: String; let source_id: String; let account_ids: [String]
        let duration_seconds: Int; let activity_id: String; let push_token: String
    }
    private struct Session: Encodable, Sendable {
        let version = 1
        let id: String; let source_id: String; let account_ids: [String]; let activity_id: String
        let starts_at: Double; let expires_at: Double
        var status = "active"; var revision: UInt64 = 1
        let delivery_state = "disabled"
    }
    private var requests: [(String, String)] = []
    private var sessions: [String: Session] = [:]
    private var registrations: [String: Create] = [:]
    private var tokens: [String: String] = [:]
    private var cancelled: Set<String> = []
    private var createGate: WorkspaceGate?
    private var quotaGate: WorkspaceGate?
    private var rotateGate: WorkspaceGate?
    private let createFails: Bool
    private var quotaStatus = 200
    private var getsHidden = false
    private var deleteStatus: Int?
    init(createGate: WorkspaceGate? = nil, quotaGate: WorkspaceGate? = nil,
         rotateGate: WorkspaceGate? = nil, createFails: Bool = false) {
        self.createGate = createGate; self.quotaGate = quotaGate; self.rotateGate = rotateGate; self.createFails = createFails
    }
    func setQuotaStatus(_ status: Int) { quotaStatus = status }
    func setGetsHidden(_ value: Bool) { getsHidden = value }
    func setDeleteStatus(_ value: Int) { deleteStatus = value }
    func totalCount() -> Int { requests.count }
    func count(method: String, suffix: String? = nil) -> Int {
        requests.filter { $0.0 == method && (suffix == nil || $0.1.hasSuffix(suffix!)) }.count
    }
    func lastToken() -> String? { tokens.values.first }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let method = request.httpMethod ?? "GET", path = request.url?.path ?? ""
        requests.append((method, path))
        if path.hasSuffix("/quota") {
            let gate = quotaGate; quotaGate = nil
            await gate?.wait()
            if quotaStatus != 200 { return response(quotaStatus) }
            let json = #"{"version":1,"sequence":1,"phase":"ready","generated_at":1800000000,"expires_at":1800000600,"accounts":[{"id":"safe-account","label":"Safe account","provider":"cpa","window_id":"quota","window_label":"Quota","status":"unavailable"}]}"#
            return response(200, Data(json.utf8))
        }
        if method == "POST", path.hasSuffix("/sessions") {
            let body = try JSONDecoder().decode(Create.self, from: request.httpBody ?? Data())
            let gate = createGate; createGate = nil
            await gate?.wait()
            if createFails { throw URLError(.timedOut) }
            if cancelled.contains(body.id) { return response(409) }
            if let old = registrations[body.id], old != body { return response(409) }
            registrations[body.id] = body
            let session = sessions[body.id] ?? Session(id: body.id, source_id: body.source_id,
                account_ids: body.account_ids, activity_id: body.activity_id,
                starts_at: 1_800_000_000, expires_at: 1_800_000_000 + Double(body.duration_seconds))
            sessions[body.id] = session
            tokens[body.id] = body.push_token
            return response(201, try JSONEncoder().encode(session))
        }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 4 else { return response(404) }
        let id = parts[3]
        if method == "DELETE" {
            if let deleteStatus { return response(deleteStatus) }
            cancelled.insert(id)
            guard var session = sessions[id] else { return response(204) }
            if session.status == "active" { session.status = "stopped"; session.revision += 1 }
            sessions[id] = session
            return response(200, try JSONEncoder().encode(session))
        }
        guard var session = sessions[id], !getsHidden else { return response(404) }
        if method == "PUT", path.hasSuffix("/token") {
            struct TokenBody: Decodable { let push_token: String; let revision: UInt64 }
            let body = try JSONDecoder().decode(TokenBody.self, from: request.httpBody ?? Data())
            guard body.revision == session.revision, session.status == "active" else { return response(409) }
            session.revision += 1
            sessions[id] = session
            tokens[id] = body.push_token
            let gate = rotateGate; rotateGate = nil
            await gate?.wait()
        }
        return response(200, try JSONEncoder().encode(session))
    }
    private func response(_ status: Int, _ body: Data = Data()) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: [:], body: body)
    }
}
