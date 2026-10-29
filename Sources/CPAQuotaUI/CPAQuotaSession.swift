import Foundation
import Observation
import CPAQuotaKit

private final class CredentialIntentCancellation: @unchecked Sendable {
    private enum State {
        case pending
        case cancelled
        case accepted
    }

    private let lock = NSLock()
    private var state = State.pending

    func cancel() {
        lock.lock()
        if case .pending = state {
            state = .cancelled
        }
        lock.unlock()
    }

    func accept() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .pending = state else { return false }
        state = .accepted
        return true
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .cancelled = state { return true }
        return false
    }

    var isAccepted: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .accepted = state { return true }
        return false
    }
}

private struct CredentialIntent: Sendable {
    enum Action: Sendable {
        case hold(server: CPAServer?)
        case remember(server: CPAServer, key: ManagementKey)
        case discard(server: CPAServer)
        case forget(server: CPAServer?)
        case rollback(server: CPAServer, intentVersion: UInt64)
    }

    let version: UInt64
    let action: Action
    let cancellation: CredentialIntentCancellation
}

private struct CredentialOutcome: Sendable {
    let version: UInt64
    let saved: Bool
    let failure: CPAError?
}

private enum StoredCredential: Sendable {
    case key(ManagementKey)
    case absent
}

private struct CredentialWriteBaseline: Sendable {
    let intentVersion: UInt64
    let servers: [String: CPAServer]
    let credentials: [String: StoredCredential]
    let cancellation: CredentialIntentCancellation
}

/// Serializes every credential side effect behind the newest submitted intent.
/// Actor calls may re-enter at store awaits, so each await is followed by a version check.
private actor CredentialStoreCoordinator {
    private let store: any CredentialStore
    private var latestIntent: CredentialIntent?
    private var latestSeedVersion: UInt64 = 0
    private var ownedServers: [String: CPAServer] = [:]
    private var confirmedCredentials: [String: StoredCredential] = [:]
    private var taintedServers: Set<String> = []
    private var latestWriteBaseline: CredentialWriteBaseline?
    private var appliedOutcome: CredentialOutcome?
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(store: any CredentialStore) {
        self.store = store
    }

    func register(_ server: CPAServer, version: UInt64) {
        guard version > latestSeedVersion,
              (latestIntent?.version ?? 0) <= version else { return }
        latestSeedVersion = version
        ownedServers[server.identifier] = server
    }

    func seed(_ key: ManagementKey, for server: CPAServer, version: UInt64) {
        guard version > latestSeedVersion,
              (latestIntent?.version ?? 0) <= version else { return }
        latestSeedVersion = version
        ownedServers[server.identifier] = server
        confirmedCredentials[server.identifier] = .key(key)
    }

    func submit(_ intent: CredentialIntent) {
        guard intent.version > (latestIntent?.version ?? 0) else { return }
        latestIntent = intent
    }

    func finalize(_ version: UInt64) -> Bool {
        guard latestIntent?.version == version else { return false }
        guard let baseline = latestWriteBaseline, baseline.intentVersion == version else { return true }
        guard baseline.cancellation.isAccepted else { return false }
        latestWriteBaseline = nil
        return true
    }

    func synchronize() async -> CredentialOutcome {
        await acquire()
        if let intent = latestIntent, appliedOutcome?.version == intent.version, let appliedOutcome {
            release()
            return appliedOutcome
        }
        let outcome = await converge()
        release()
        return outcome
    }

    private func acquire() async {
        if !isBusy {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    private func converge() async -> CredentialOutcome {
        var outcome = CredentialOutcome(version: 0, saved: false, failure: nil)
        while let intent = latestIntent {
            if appliedOutcome?.version == intent.version, let appliedOutcome {
                return appliedOutcome
            }
            var priorTransactionFailure: CPAError?
            if let baseline = latestWriteBaseline, baseline.intentVersion < intent.version {
                if case .rollback = intent.action {
                    priorTransactionFailure = nil
                } else if baseline.cancellation.isAccepted {
                    latestWriteBaseline = nil
                } else {
                    priorTransactionFailure = await rollbackTransaction(baseline, using: intent.version)
                    guard latestIntent?.version == intent.version else { continue }
                    if priorTransactionFailure == nil {
                        latestWriteBaseline = nil
                    }
                }
            }
            var saved = false
            var failure: CPAError?
            switch intent.action {
            case .hold(let server):
                if let server {
                    ownedServers[server.identifier] = server
                    if confirmedCredentials[server.identifier] == nil {
                        do {
                            let existing = try await store.load(for: server)
                            guard latestIntent?.version == intent.version else { continue }
                            confirmedCredentials[server.identifier] = existing.map(StoredCredential.key) ?? .absent
                        } catch {
                            guard latestIntent?.version == intent.version else { continue }
                            failure = Self.storageError(error)
                        }
                    }
                }
                if failure == nil {
                    failure = await restoreConfirmedCredentials(for: intent.version)
                }
            case .remember(let server, let key):
                ownedServers[server.identifier] = server
                failure = await loadUnconfirmedCredentials(version: intent.version)
                guard latestIntent?.version == intent.version else { continue }
                if failure == nil {
                    latestWriteBaseline = CredentialWriteBaseline(
                        intentVersion: intent.version,
                        servers: ownedServers,
                        credentials: confirmedCredentials,
                        cancellation: intent.cancellation
                    )
                }
                if failure == nil, !intent.cancellation.isCancelled {
                    do {
                        try await store.save(key, for: server)
                        guard latestIntent?.version == intent.version else {
                            if let baseline = latestWriteBaseline {
                                taintedServers.formUnion(baseline.servers.keys)
                            } else {
                                taintedServers.insert(server.identifier)
                            }
                            continue
                        }
                        if intent.cancellation.isCancelled {
                            if let baseline = latestWriteBaseline {
                                failure = await rollbackTransaction(baseline, using: intent.version)
                            }
                        } else {
                            confirmedCredentials[server.identifier] = .key(key)
                            taintedServers.remove(server.identifier)
                            saved = true
                            failure = await removeOtherConfirmedServers(keeping: server, version: intent.version)
                            if intent.cancellation.isCancelled, let baseline = latestWriteBaseline {
                                saved = false
                                failure = await rollbackTransaction(baseline, using: intent.version) ?? failure
                            }
                        }
                    } catch {
                        guard latestIntent?.version == intent.version else {
                            if let baseline = latestWriteBaseline {
                                taintedServers.formUnion(baseline.servers.keys)
                            } else {
                                taintedServers.insert(server.identifier)
                            }
                            continue
                        }
                        let saveError = Self.storageError(error)
                        if intent.cancellation.isCancelled, let baseline = latestWriteBaseline {
                            failure = await rollbackTransaction(baseline, using: intent.version) ?? saveError
                        } else {
                            failure = saveError
                        }
                    }
                }
            case .discard(let server):
                latestWriteBaseline = nil
                ownedServers[server.identifier] = server
                failure = await removeAllOwnedCredentials(version: intent.version)
            case .forget(let server):
                latestWriteBaseline = nil
                if let server { ownedServers[server.identifier] = server }
                failure = await removeAllOwnedCredentials(version: intent.version)
            case .rollback(let server, let intentVersion):
                if let baseline = latestWriteBaseline,
                   baseline.intentVersion == intentVersion,
                   baseline.servers[server.identifier] == server {
                    failure = await rollbackTransaction(baseline, using: intent.version)
                    if failure == nil {
                        latestWriteBaseline = nil
                    }
                } else {
                    failure = CPAError(.secureStorageFailure)
                }
            }
            guard latestIntent?.version == intent.version else { continue }
            if failure == nil,
               let baseline = latestWriteBaseline,
               baseline.intentVersion < intent.version {
                latestWriteBaseline = nil
            }
            outcome = CredentialOutcome(
                    version: intent.version,
                    saved: saved,
                    failure: failure ?? priorTransactionFailure
                )
            appliedOutcome = outcome
            return outcome
        }
        return outcome
    }

    private func loadUnconfirmedCredentials(version: UInt64) async -> CPAError? {
        while let server = ownedServers.values.first(where: {
            confirmedCredentials[$0.identifier] == nil
        }) {
            guard latestIntent?.version == version else { return nil }
            do {
                let existing = try await store.load(for: server)
                guard latestIntent?.version == version else { return nil }
                confirmedCredentials[server.identifier] = existing.map(StoredCredential.key) ?? .absent
            } catch {
                guard latestIntent?.version == version else { return nil }
                return Self.storageError(error)
            }
        }
        return nil
    }

    private func rollbackTransaction(_ baseline: CredentialWriteBaseline, using version: UInt64) async -> CPAError? {
        guard latestIntent?.version == version else { return nil }
        for (identifier, server) in baseline.servers {
            ownedServers[identifier] = server
            confirmedCredentials[identifier] = baseline.credentials[identifier] ?? .absent
            taintedServers.insert(identifier)
        }
        return await restoreConfirmedCredentials(for: version)
    }

    private func restoreConfirmedCredentials(for version: UInt64) async -> CPAError? {
        for server in Array(ownedServers.values) {
            guard latestIntent?.version == version else { return nil }
            guard taintedServers.contains(server.identifier),
                  let expected = confirmedCredentials[server.identifier] else { continue }
            do {
                switch expected {
                case .absent:
                    try await store.remove(for: server)
                case .key(let expectedKey):
                    try await store.save(expectedKey, for: server)
                }
                guard latestIntent?.version == version else {
                    taintedServers.insert(server.identifier)
                    return nil
                }
                taintedServers.remove(server.identifier)
            } catch {
                guard latestIntent?.version == version else {
                    taintedServers.insert(server.identifier)
                    return nil
                }
                return Self.storageError(error)
            }
        }
        return nil
    }

    private func removeOtherConfirmedServers(keeping server: CPAServer, version: UInt64) async -> CPAError? {
        guard let baseline = latestWriteBaseline, baseline.intentVersion == version else {
            return CPAError(.secureStorageFailure)
        }
        for candidate in baseline.servers.values where candidate.identifier != server.identifier {
            guard latestIntent?.version == version else { return nil }
            do {
                try await store.remove(for: candidate)
                guard latestIntent?.version == version else {
                    taintedServers.insert(candidate.identifier)
                    return nil
                }
                confirmedCredentials[candidate.identifier] = .absent
                taintedServers.remove(candidate.identifier)
            } catch {
                guard latestIntent?.version == version else {
                    taintedServers.insert(candidate.identifier)
                    return nil
                }
                return Self.storageError(error)
            }
        }
        return nil
    }

    private func removeAllOwnedCredentials(version: UInt64) async -> CPAError? {
        for server in Array(ownedServers.values) {
            guard latestIntent?.version == version else { return nil }
            do {
                try await store.remove(for: server)
                guard latestIntent?.version == version else {
                    taintedServers.insert(server.identifier)
                    return nil
                }
                confirmedCredentials[server.identifier] = .absent
                taintedServers.remove(server.identifier)
            } catch {
                guard latestIntent?.version == version else {
                    taintedServers.insert(server.identifier)
                    return nil
                }
                return Self.storageError(error)
            }
        }
        return nil
    }

    private static func storageError(_ error: any Error) -> CPAError {
        (error as? CPAError) ?? CPAError(.secureStorageFailure)
    }
}

@MainActor
@Observable
public final class CPAQuotaSession {
    public enum AuthState: Equatable, Sendable {
        case unconfigured
        case connecting(serverIdentifier: String)
        case connected(server: CPAServer, isRememberedInKeychain: Bool)
    }

    public private(set) var authState: AuthState = .unconfigured
    public private(set) var store: CPAQuotaStore?
    public private(set) var currentServer: CPAServer?
    public private(set) var savedServer: CPAServer?
    public private(set) var isRememberedInKeychain = false
    public private(set) var connectionFormError: CPAError?
    public private(set) var statusBannerMessage: String?

    public var activeTab: CPAWorkspaceTab = .quotas
    public var selectedFilter: AccountFilterCategory = .all
    public var isIslandExpanded = false
    public var selectedAccountIDForDetail: String?
    public var isPresentingConnectionSheet = false

    public let capUsageCoordinator = CAPUsageWorkspaceCoordinator()
    public let monitoringCoordinator = MonitoringWorkspaceCoordinator()

    public var serverAddressDraft: String = ""
    public var managementKeyDraft: String = ""
    public var rememberCredentialsDraft: Bool = true

    public var themeMode: CPAThemeMode {
        didSet { preferences.saveThemeMode(themeMode) }
    }

    public var displayMode: QuotaDisplayMode {
        didSet { preferences.saveDisplayMode(displayMode) }
    }

    public var maskEmail: Bool {
        didSet { preferences.saveMaskEmail(maskEmail) }
    }

    @ObservationIgnored private let credentialStore: any CredentialStore
    @ObservationIgnored private let credentialCoordinator: CredentialStoreCoordinator
    @ObservationIgnored private let preferences: any PreferencesStore
    @ObservationIgnored private let clientFactory: @Sendable (CPAServer, ManagementKey) -> CPAClient
    @ObservationIgnored private var operationGeneration: UInt64 = 0
    @ObservationIgnored private var pendingServer: CPAServer?
    @ObservationIgnored private var pendingStore: CPAQuotaStore?
    @ObservationIgnored private var credentialIntentVersion: UInt64 = 0
    @ObservationIgnored private var progressRoundID: UInt64 = 0
    @ObservationIgnored private var isProgressRoundActive = false

    public init(
        credentialStore: any CredentialStore = KeychainCredentialStore(),
        preferences: any PreferencesStore = UserDefaultsPreferencesStore(),
        clientFactory: @escaping @Sendable (CPAServer, ManagementKey) -> CPAClient = { server, key in
            CPAClient(server: server, managementKey: key)
        }
    ) {
        self.credentialStore = credentialStore
        self.credentialCoordinator = CredentialStoreCoordinator(store: credentialStore)
        self.preferences = preferences
        self.clientFactory = clientFactory
        self.themeMode = preferences.loadThemeMode()
        self.displayMode = preferences.loadDisplayMode()
        self.maskEmail = preferences.loadMaskEmail()
        if let savedIdentifier = preferences.loadSavedServerIdentifier() {
            self.savedServer = try? CPAServer(baseURL: savedIdentifier)
            self.serverAddressDraft = savedIdentifier
        }
    }

    private func updateSavedServer(_ server: CPAServer?) {
        preferences.saveServerIdentifier(server?.identifier)
        savedServer = server
    }

    public static func previewNormalizedServer(_ rawAddress: String) -> Result<CPAServer, CPAError> {
        do {
            let server = try CPAServer(baseURL: rawAddress)
            return .success(server)
        } catch let error as CPAError {
            return .failure(error)
        } catch {
            return .failure(CPAError(.invalidServer))
        }
    }

    public func restoreSessionIfAvailable() async {
        let startGeneration = operationGeneration
        guard let savedIdentifier = preferences.loadSavedServerIdentifier(),
              !savedIdentifier.isEmpty else {
            guard startGeneration == operationGeneration else { return }
            authState = .unconfigured
            return
        }

        let server: CPAServer
        do {
            server = try CPAServer(baseURL: savedIdentifier)
        } catch let error as CPAError {
            connectionFormError = error
            authState = .unconfigured
            return
        } catch {
            connectionFormError = CPAError(.invalidServer)
            authState = .unconfigured
            return
        }

        operationGeneration &+= 1
        let generation = operationGeneration
        pendingServer = server
        authState = .connecting(serverIdentifier: server.identifier)
        serverAddressDraft = server.identifier
        connectionFormError = nil
        statusBannerMessage = nil
        let registrationVersion = nextCredentialIntent(action: .hold(server: server)).version
        await credentialCoordinator.register(server, version: registrationVersion)
        guard generation == operationGeneration else { return }

        do {
            guard let restoredKey = try await credentialStore.load(for: server) else {
                guard generation == operationGeneration else { return }
                pendingServer = nil
                authState = .unconfigured
                return
            }
            guard generation == operationGeneration else { return }
            if Task.isCancelled {
                await abandonRestore(server: server, generation: generation)
                return
            }

            let seedVersion = nextCredentialIntent(action: .hold(server: server)).version
            await credentialCoordinator.seed(restoredKey, for: server, version: seedVersion)
            guard generation == operationGeneration else { return }
            let holdIntent = nextCredentialIntent(action: .hold(server: server))
            await credentialCoordinator.submit(holdIntent)
            let holdOutcome = await credentialCoordinator.synchronize()
            guard generation == operationGeneration, !Task.isCancelled else {
                if generation == operationGeneration {
                    await abandonRestore(server: server, generation: generation)
                }
                return
            }
            if let failure = holdOutcome.failure {
                presentStorageFailure(failure)
            }

            if let existingStore = store {
                await existingStore.cancel()
            }
            guard generation == operationGeneration else { return }
            let client = clientFactory(server, restoredKey)
            let newStore = CPAQuotaStore(client: client)
            pendingStore = newStore

            let progressRound = beginProgressRound()
            await newStore.load()
            endProgressRound(progressRound)
            guard generation == operationGeneration, !Task.isCancelled else {
                if generation == operationGeneration {
                    await newStore.cancel()
                    await abandonRestore(server: server, generation: generation)
                }
                return
            }

            if let loadError = newStore.error,
               loadError.kind == .managementUnauthorized || loadError.kind == .managementForbidden {
                await newStore.cancel()
                guard generation == operationGeneration else { return }
                pendingStore = nil
                store = nil
                currentServer = nil
                capUsageCoordinator.teardown()
                isRememberedInKeychain = false
                pendingServer = nil
                if let failure = holdOutcome.failure {
                    presentStorageFailure(failure)
                    statusBannerMessage = "\(ErrorPresentation(error: loadError).summary) \(ErrorPresentation(error: failure).summary)"
                } else {
                    connectionFormError = loadError
                }
                authState = .unconfigured
                return
            }

            let capClient = await newStore.makeCAPUsageClient()
            guard generation == operationGeneration, !Task.isCancelled else {
                if generation == operationGeneration {
                    await newStore.cancel()
                    await abandonRestore(server: server, generation: generation)
                }
                return
            }
            pendingStore = nil
            store = newStore
            currentServer = server
            pendingServer = nil
            isRememberedInKeychain = true
            capUsageCoordinator.bind(client: capClient)
            authState = .connected(server: server, isRememberedInKeychain: true)
        } catch let error as CPAError {
            guard generation == operationGeneration else { return }
            if Task.isCancelled {
                await abandonRestore(server: server, generation: generation)
                return
            }
            pendingServer = nil
            presentStorageFailure(error)
            authState = .unconfigured
        } catch {
            guard generation == operationGeneration else { return }
            if Task.isCancelled {
                await abandonRestore(server: server, generation: generation)
                return
            }
            pendingServer = nil
            presentStorageFailure(CPAError(.secureStorageFailure))
            authState = .unconfigured
        }
    }

    private func presentStorageFailure(_ error: CPAError) {
        connectionFormError = error
        statusBannerMessage = ErrorPresentation(error: error).summary
    }

    private func abandonRestore(server: CPAServer, generation: UInt64) async {
        guard generation == operationGeneration else { return }
        operationGeneration &+= 1
        let rollbackGeneration = operationGeneration
        let rollbackIntent = nextCredentialIntent(action: .hold(server: server))
        await credentialCoordinator.submit(rollbackIntent)
        let outcome = await credentialCoordinator.synchronize()
        guard rollbackGeneration == operationGeneration else { return }
        if let failure = outcome.failure {
            presentStorageFailure(failure)
        }
        pendingServer = nil
        pendingStore = nil
        store = nil
        currentServer = nil
        capUsageCoordinator.teardown()
        isRememberedInKeychain = false
        authState = .unconfigured
    }

    public func connect(
        serverAddress: String,
        managementKeyInput: String,
        rememberInKeychain: Bool
    ) async {
        connectionFormError = nil
        statusBannerMessage = nil

        let server: CPAServer
        let managementKey: ManagementKey
        do {
            server = try CPAServer(baseURL: serverAddress)
            managementKey = try ManagementKey(managementKeyInput)
        } catch let error as CPAError {
            connectionFormError = error
            return
        } catch {
            connectionFormError = CPAError(.invalidServer)
            return
        }

        operationGeneration &+= 1
        let generation = operationGeneration
        pendingServer = server
        authState = .connecting(serverIdentifier: server.identifier)
        let previousCandidate = pendingStore
        pendingStore = nil
        if let previousCandidate {
            await previousCandidate.cancel()
        }
        guard generation == operationGeneration else { return }

        if let savedServer, savedServer != server {
            let registrationVersion = nextCredentialIntent(action: .hold(server: savedServer)).version
            await credentialCoordinator.register(savedServer, version: registrationVersion)
            guard generation == operationGeneration else { return }
        }

        let holdIntent = nextCredentialIntent(action: .hold(server: server))
        await credentialCoordinator.submit(holdIntent)

        let client = clientFactory(server, managementKey)
        let newStore = CPAQuotaStore(client: client)
        pendingStore = newStore

        let progressRound = beginProgressRound()
        await newStore.load()
        endProgressRound(progressRound)

        guard generation == operationGeneration, !Task.isCancelled else {
            if generation == operationGeneration {
                await newStore.cancel()
                await abandonConnect(server: server, generation: generation)
            }
            return
        }

        if let loadError = newStore.error {
            let reconcileIntent = nextCredentialIntent(action: .hold(server: server))
            await credentialCoordinator.submit(reconcileIntent)
            let reconcileOutcome = await credentialCoordinator.synchronize()
            guard generation == operationGeneration else { return }
            if let failure = reconcileOutcome.failure {
                presentStorageFailure(failure)
                statusBannerMessage = "\(ErrorPresentation(error: loadError).summary) \(statusBannerMessage ?? "")"
            } else {
                connectionFormError = loadError
            }
            pendingStore = nil
            pendingServer = nil
            restoreActiveAuthState()
            return
        }

        // Prepare all connection-scoped clients before accepting credential side
        // effects. The accepted quota and CAP contexts are then published together.
        let capClient = await newStore.makeCAPUsageClient()
        guard generation == operationGeneration, !Task.isCancelled else {
            if generation == operationGeneration {
                await newStore.cancel()
                await abandonConnect(server: server, generation: generation)
            }
            return
        }

        let action: CredentialIntent.Action = rememberInKeychain
            ? .remember(server: server, key: managementKey)
            : .discard(server: server)
        let commitIntent = nextCredentialIntent(action: action)
        await credentialCoordinator.submit(commitIntent)
        let credentialOutcome = await withTaskCancellationHandler {
            await credentialCoordinator.synchronize()
        } onCancel: {
            commitIntent.cancellation.cancel()
        }

        guard generation == operationGeneration, !Task.isCancelled else {
            if generation == operationGeneration {
                if let failure = credentialOutcome.failure {
                    presentStorageFailure(failure)
                }
                await newStore.cancel()
                await abandonConnect(
                    server: server,
                    generation: generation,
                    cancelledIntentVersion: rememberInKeychain ? commitIntent.version : nil
                )
            }
            return
        }
        // A newer intent owns the credential state; this attempt must not publish.
        guard credentialOutcome.version == commitIntent.version else { return }
        guard commitIntent.cancellation.accept() else {
            if let failure = credentialOutcome.failure {
                presentStorageFailure(failure)
            }
            await newStore.cancel()
            await abandonConnect(
                server: server,
                generation: generation,
                cancelledIntentVersion: rememberInKeychain ? commitIntent.version : nil
            )
            return
        }

        let savedToKeychain = credentialOutcome.saved && rememberInKeychain
        if let failure = credentialOutcome.failure {
            presentStorageFailure(failure)
        }
        if savedToKeychain {
            updateSavedServer(server)
        } else if credentialOutcome.failure == nil {
            updateSavedServer(nil)
        }

        let previousStore = store
        self.store = newStore
        self.currentServer = server
        pendingStore = nil
        self.serverAddressDraft = server.identifier
        self.managementKeyDraft = ""
        self.isRememberedInKeychain = savedToKeychain
        pendingServer = nil
        capUsageCoordinator.bind(client: capClient)
        self.authState = .connected(server: server, isRememberedInKeychain: savedToKeychain)
        self.isPresentingConnectionSheet = false
        _ = await credentialCoordinator.finalize(commitIntent.version)
        await previousStore?.cancel()
    }

    private func restoreActiveAuthState() {
        if let currentServer, store != nil {
            authState = .connected(server: currentServer, isRememberedInKeychain: isRememberedInKeychain)
        } else {
            authState = .unconfigured
        }
    }

    private func abandonConnect(
        server: CPAServer,
        generation: UInt64,
        cancelledIntentVersion: UInt64? = nil
    ) async {
        guard generation == operationGeneration else { return }
        operationGeneration &+= 1
        let rollbackGeneration = operationGeneration
        let action: CredentialIntent.Action = if let cancelledIntentVersion {
            .rollback(server: server, intentVersion: cancelledIntentVersion)
        } else {
            .hold(server: server)
        }
        let rollbackIntent = nextCredentialIntent(action: action)
        await credentialCoordinator.submit(rollbackIntent)
        let outcome = await credentialCoordinator.synchronize()
        guard rollbackGeneration == operationGeneration else { return }
        if let failure = outcome.failure {
            presentStorageFailure(failure)
        }
        pendingServer = nil
        pendingStore = nil
        restoreActiveAuthState()
    }

    public func refreshAll(force: Bool = true) async {
        guard let store else { return }
        let ownsRound = !isProgressRoundActive
        let round = ownsRound ? beginProgressRound() : 0
        await store.refresh(force: force)
        if ownsRound { endProgressRound(round) }
    }

    public func makeCAPUsageClient() async -> CAPUsageClient? {
        guard let activeStore = store, currentServer != nil else { return nil }
        let generation = operationGeneration
        let client = await activeStore.makeCAPUsageClient()
        guard generation == operationGeneration, store === activeStore, currentServer != nil,
              !Task.isCancelled else { return nil }
        return client
    }

    public func refreshAccount(_ accountID: String, force: Bool = true) async {
        guard let store else { return }
        await store.refresh(accountID: accountID, force: force)
    }

    public func loadInitialIfNeeded() async {
        guard let store else { return }
        let ownsRound = !isProgressRoundActive
        let round = ownsRound ? beginProgressRound() : 0
        await store.load()
        if ownsRound { endProgressRound(round) }
    }

    private func nextCredentialIntent(action: CredentialIntent.Action) -> CredentialIntent {
        credentialIntentVersion = max(credentialIntentVersion, operationGeneration) &+ 1
        return CredentialIntent(
            version: credentialIntentVersion,
            action: action,
            cancellation: CredentialIntentCancellation()
        )
    }

    private func beginProgressRound() -> UInt64 {
        progressRoundID &+= 1
        isProgressRoundActive = true
        return progressRoundID
    }

    private func endProgressRound(_ id: UInt64) {
        guard progressRoundID == id else { return }
        isProgressRoundActive = false
    }

    public func cancelActiveOperation() async {
        if case .connecting = authState {
            operationGeneration &+= 1
            let generation = operationGeneration
            let server = pendingServer ?? currentServer
            let intent = nextCredentialIntent(action: .hold(server: server))
            await credentialCoordinator.submit(intent)
            let outcome = await credentialCoordinator.synchronize()
            guard generation == operationGeneration else { return }
            guard outcome.version == intent.version else { return }
            if let failure = outcome.failure {
                presentStorageFailure(failure)
            }
            if let pendingStore {
                await pendingStore.cancel()
                guard generation == operationGeneration else { return }
            }
            pendingStore = nil
            pendingServer = nil
            restoreActiveAuthState()
            return
        }
        guard let store else { return }
        await store.cancel()
    }

    public func forgetCurrentConnection() async {
        // Invalidate in-flight work before touching storage so a late write cannot publish state.
        operationGeneration &+= 1
        let generation = operationGeneration
        let server = currentServer ?? pendingServer ?? preferences.loadSavedServerIdentifier().flatMap {
            try? CPAServer(baseURL: $0)
        }
        let intent = nextCredentialIntent(action: .forget(server: server))
        await credentialCoordinator.submit(intent)
        let outcome = await credentialCoordinator.synchronize()

        guard generation == operationGeneration, outcome.version == intent.version else { return }

        if let failure = outcome.failure {
            // At least one credential is still stored: do not claim the forget completed.
            presentStorageFailure(failure)
            if case .connecting = authState {
                // The attempt was already invalidated; it cannot reach a connected state.
                if let existingStore = store {
                    await existingStore.cancel()
                    guard generation == operationGeneration else { return }
                }
                store = nil
                currentServer = nil
                isRememberedInKeychain = false
                capUsageCoordinator.teardown()
                authState = .unconfigured
            }
            return
        }

        if let candidate = pendingStore {
            await candidate.cancel()
            guard generation == operationGeneration else { return }
            pendingStore = nil
        }
        if let existingStore = store {
            await existingStore.cancel()
            guard generation == operationGeneration else { return }
        }
        updateSavedServer(nil)
        store = nil
        currentServer = nil
        isRememberedInKeychain = false
        connectionFormError = nil
        statusBannerMessage = nil
        managementKeyDraft = ""
        selectedAccountIDForDetail = nil
        capUsageCoordinator.teardown()
        authState = .unconfigured
    }

    public var accounts: [CPAAccount] {
        store?.accounts ?? []
    }

    public var records: [String: QuotaRecord] {
        store?.records ?? [:]
    }

    public var isWorkspaceReady: Bool {
        currentServer != nil && store != nil
    }

    public var isBusy: Bool {
        if case .connecting = authState { return true }
        guard let store else { return false }
        return store.isLoading || store.isRefreshing
    }

    public var filteredAccounts: [CPAAccount] {
        let allAccounts = accounts
        switch selectedFilter {
        case .all:
            return allAccounts
        case .active:
            return allAccounts.filter { account in
                !account.isDisabled && !account.isUnavailable && records[account.id]?.error == nil
            }
        case .codex:
            return allAccounts.filter { $0.provider.lowercased() == "codex" }
        case .plugin:
            return allAccounts.filter { $0.provider.lowercased() != "codex" }
        case .attention:
            return allAccounts.filter { account in
                account.isDisabled || account.isUnavailable || records[account.id]?.error != nil
            }
        }
    }

    public func completedEnabledAccountCount() -> Int {
        let enabledIDs = Set(accounts.filter { !$0.isDisabled }.map(\.id))
        if let operation = store?.refreshOperation {
            return operation.processed.intersection(enabledIDs).count
        }
        return 0
    }

    public func dynamicIslandState(now: Date = Date()) -> DynamicIslandState {
        if case .connecting = authState {
            return DynamicIslandState(
                phase: .syncing(isLoadingInventory: true, completedCount: 0, totalCount: 1),
                isExpanded: isIslandExpanded
            )
        }
        guard let currentServer, let store else {
            return DynamicIslandState(phase: .unconfigured, isExpanded: isIslandExpanded)
        }

        let enabledCount = store.accounts.filter { !$0.isDisabled }.count
        let totalCount = store.accounts.count

        if store.isLoading || store.isRefreshing {
            return DynamicIslandState(
                phase: .syncing(
                    isLoadingInventory: store.isLoading,
                    completedCount: completedEnabledAccountCount(),
                    totalCount: enabledCount
                ),
                isExpanded: isIslandExpanded
            )
        }

        if let globalError = store.error {
            if globalError.kind == .rateLimited,
               let retryAfter = globalError.retryAfter {
                let remaining = Int(ceil(retryAfter.timeIntervalSince(now)))
                if remaining > 0 {
                    return DynamicIslandState(
                        phase: .rateLimited(layer: globalError.layer, remainingSeconds: remaining),
                        isExpanded: isIslandExpanded
                    )
                }
            }
            if globalError.kind == .managementUnauthorized || globalError.kind == .managementForbidden {
                return DynamicIslandState(
                    phase: .managementBlocked(kind: globalError.kind),
                    isExpanded: isIslandExpanded
                )
            }
            if globalError.kind != .rateLimited {
                return DynamicIslandState(
                    phase: .connectionFailed(kind: globalError.kind),
                    isExpanded: isIslandExpanded
                )
            }
        }

        for record in store.records.values {
            if let err = record.error, err.kind == .rateLimited, let retryAfter = err.retryAfter {
                let remaining = Int(ceil(retryAfter.timeIntervalSince(now)))
                if remaining > 0 {
                    return DynamicIslandState(
                        phase: .rateLimited(layer: err.layer, remainingSeconds: remaining),
                        isExpanded: isIslandExpanded
                    )
                }
            }
        }

        return DynamicIslandState(
            phase: .idle(
                host: currentServer.identifier,
                activeCount: enabledCount,
                totalCount: totalCount
            ),
            isExpanded: isIslandExpanded
        )
    }
}
