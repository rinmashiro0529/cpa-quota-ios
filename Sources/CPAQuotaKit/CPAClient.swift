import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public actor CPAClient {
    public let server: CPAServer
    public private(set) var serverVersion: String?
    public private(set) var capabilityWarning: CPAError?

    private let key: ManagementKey
    private let transport: any HTTPTransport
    private let clock: @Sendable () -> Date
    private let cacheLifetime: TimeInterval
    private let limiter = QuotaRequestLimiter(limit: 3)
    private var entries: [AccountEntry] = []
    private var records: [String: QuotaRecord] = [:]
    private var pluginProviders: Set<String> = []
    private var hasInventory = false
    private var epoch: UInt64 = 0
    private var inventoryFlight: InventoryFlight?
    private var flights: [String: QuotaFlight] = [:]

    private struct InventoryResult: Sendable {
        let inventory: DecodedInventory
        let providers: Set<String>
        let warning: CPAError?
        let version: String?
    }

    private struct InventoryFlight: Sendable {
        let token: UUID
        let epoch: UInt64
        let task: Task<InventoryResult, any Error>
    }

    private struct QuotaFlight: Sendable {
        let token: UUID
        let task: Task<QuotaSnapshot, any Error>
    }

    private final class QuotaCancellationScope: @unchecked Sendable {
        private let lock = NSLock()
        private var tasks: [Task<QuotaSnapshot, any Error>] = []
        private var cancelled = false

        func register(_ task: Task<QuotaSnapshot, any Error>) {
            lock.lock()
            if cancelled {
                lock.unlock()
                task.cancel()
                return
            }
            tasks.append(task)
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let pending = tasks
            tasks.removeAll()
            lock.unlock()
            for task in pending { task.cancel() }
        }
    }

    private enum Endpoint: String {
        case accounts = "auth-files"
        case providers = "quota/providers"
        case pluginQuota = "quota/fetch"
        case proxy = "api-call"
    }

    public init(server: CPAServer, managementKey: ManagementKey) {
        self.server = server
        self.key = managementKey
        self.transport = URLSessionTransport()
        self.clock = { Date() }
        self.cacheLifetime = 60
    }

    init(server: CPAServer, managementKey: ManagementKey, transport: any HTTPTransport,
         cacheLifetime: TimeInterval = 60, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.server = server
        self.key = managementKey
        self.transport = transport
        self.clock = clock
        self.cacheLifetime = cacheLifetime
    }

    public func loadAccounts() async throws -> [CPAAccount] {
        try Task.checkCancellation()
        let flight: InventoryFlight
        if let existing = inventoryFlight, !existing.task.isCancelled {
            flight = existing
        } else {
            let task = Task { [server, key, transport, clock] in
                let response = try await Self.perform(.accounts, server: server, key: key, transport: transport, clock: clock)
                let inventory = try PayloadDecoder.inventory(response.body, now: clock())
                let providers: Set<String>
                let warning: CPAError?
                do {
                    let capabilityResponse = try await Self.perform(.providers, server: server, key: key, transport: transport, clock: clock)
                    providers = try PayloadDecoder.providers(capabilityResponse.body)
                    warning = nil
                } catch let error as CPAError where error.kind == .endpointUnavailable {
                    providers = []
                    warning = nil
                } catch {
                    let normalized = CPAError.normalize(error)
                    guard normalized.kind != .cancelled, !normalized.isManagementBlocking else {
                        throw normalized
                    }
                    providers = []
                    warning = normalized
                }
                return InventoryResult(inventory: inventory, providers: providers,
                                       warning: warning, version: response.header("X-CPA-Version"))
            }
            flight = InventoryFlight(token: UUID(), epoch: epoch, task: task)
            inventoryFlight = flight
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await flight.task.value
            } onCancel: {
                flight.task.cancel()
            }
            try Task.checkCancellation()
            guard epoch == flight.epoch else { throw CancellationError() }
            if inventoryFlight?.token == flight.token {
                applyInventory(result)
                inventoryFlight = nil
                await limiter.reset(at: clock())
                guard epoch == flight.epoch else { throw CancellationError() }
            }
            return entries.map(\.account)
        } catch {
            if inventoryFlight?.token == flight.token { inventoryFlight = nil }
            throw CPAError.normalize(error)
        }
    }

    public func currentRecords() -> [QuotaRecord] {
        entries.map { records[$0.account.id] ?? QuotaRecord(account: $0.account, snapshot: $0.passiveSnapshot) }
    }

    struct Snapshot: Sendable {
        let records: [QuotaRecord]
        let capabilityWarning: CPAError?
    }

    func snapshot() -> Snapshot {
        Snapshot(records: currentRecords(), capabilityWarning: capabilityWarning)
    }

    /// Concurrent requests for one account share a task; cancelling a waiter cancels that shared request.
    public func refreshQuota(for accountID: String, force: Bool = false) async throws -> QuotaSnapshot {
        try await refreshQuota(for: accountID, force: force, scope: nil)
    }

    private func refreshQuota(for accountID: String, force: Bool,
                              scope: QuotaCancellationScope?) async throws -> QuotaSnapshot {
        try Task.checkCancellation()
        if !hasInventory { _ = try await loadAccounts() }
        guard let entry = entries.first(where: { $0.account.id == accountID }) else {
            throw CPAError(.accountNotFound)
        }
        if entry.account.isDisabled {
            let error = CPAError(.accountDisabled)
            records[accountID] = QuotaRecord(account: entry.account, snapshot: records[accountID]?.snapshot, error: error)
            throw error
        }
        guard let authIndex = entry.account.authIndex, !authIndex.isEmpty else {
            let error = CPAError(.accountNotFound)
            records[accountID] = QuotaRecord(account: entry.account, snapshot: records[accountID]?.snapshot, error: error)
            throw error
        }
        let now = clock()
        let existingError = records[accountID]?.error
        if let error = existingError, error.kind == .rateLimited,
           let retryAfter = error.retryAfter, retryAfter > now {
            throw error
        }
        if !force, existingError?.isManagementBlocking != true,
           let cached = records[accountID]?.snapshot, cached.source == .live,
           now.timeIntervalSince(cached.fetchedAt) >= 0,
           now.timeIntervalSince(cached.fetchedAt) < cacheLifetime {
            return cached
        }

        let flight: QuotaFlight
        let requestEpoch = epoch
        if let existing = flights[accountID], !existing.task.isCancelled {
            flight = existing
        } else {
            let usePlugin = entry.account.supportsPluginQuota || pluginProviders.contains(entry.account.provider.lowercased())
            let task = Task { [server, key, transport, clock, limiter] in
                try await limiter.withPermit {
                    try await Self.fetch(entry, usePlugin: usePlugin, server: server, key: key, transport: transport, clock: clock)
                }
            }
            flight = QuotaFlight(token: UUID(), task: task)
            flights[accountID] = flight
        }
        scope?.register(flight.task)
        do {
            let snapshot = try await withTaskCancellationHandler {
                try await flight.task.value
            } onCancel: {
                flight.task.cancel()
            }
            try Task.checkCancellation()
            guard epoch == requestEpoch else { throw CancellationError() }
            guard let current = entries.first(where: { $0.account.id == accountID }),
                  Self.sameCredential(current, entry), !current.account.isDisabled else {
                throw CPAError(.accountNotFound)
            }
            if flights[accountID]?.token == flight.token {
                flights[accountID] = nil
                records[accountID] = QuotaRecord(account: current.account, snapshot: snapshot)
            }
            return snapshot
        } catch {
            let normalized = CPAError.normalize(error)
            if flights[accountID]?.token == flight.token {
                flights[accountID] = nil
                if epoch == requestEpoch, normalized.kind != .cancelled,
                   let current = entries.first(where: { $0.account.id == accountID }), Self.sameCredential(current, entry) {
                    records[accountID] = QuotaRecord(account: current.account, snapshot: records[accountID]?.snapshot, error: normalized)
                }
            }
            throw normalized
        }
    }

    public func refreshAll(
        force: Bool = false,
        onUpdate: (@Sendable (QuotaRecord) async -> Void)? = nil
    ) async throws -> [QuotaRecord] {
        try Task.checkCancellation()
        if !hasInventory { _ = try await loadAccounts() }
        let accountIDs = entries.map { $0.account.id }
        let batchEpoch = epoch
        let scope = QuotaCancellationScope()
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: QuotaRecord?.self) { group in
                var nextIndex = 0
                for _ in 0..<min(3, accountIDs.count) {
                    let id = accountIDs[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        try await self.refreshRecord(for: id, force: force,
                                                     batchEpoch: batchEpoch, scope: scope)
                    }
                }
                while let result = try await group.next() {
                    try Task.checkCancellation()
                    guard epoch == batchEpoch else { throw CancellationError() }
                    if let record = result {
                        await onUpdate?(record)
                        if let error = record.error, error.isManagementBlocking {
                            group.cancelAll()
                            throw error
                        }
                    }
                    if nextIndex < accountIDs.count {
                        let id = accountIDs[nextIndex]
                        nextIndex += 1
                        group.addTask {
                            try await self.refreshRecord(for: id, force: force,
                                                         batchEpoch: batchEpoch, scope: scope)
                        }
                    }
                }
            }
            guard epoch == batchEpoch else { throw CancellationError() }
        } onCancel: {
            scope.cancel()
        }
        try Task.checkCancellation()
        return currentRecords()
    }

    public func cancelRefreshes() {
        epoch &+= 1
        inventoryFlight?.task.cancel()
        inventoryFlight = nil
        for flight in flights.values { flight.task.cancel() }
        flights.removeAll()
    }

    private func refreshRecord(for id: String, force: Bool, batchEpoch: UInt64,
                               scope: QuotaCancellationScope) async throws -> QuotaRecord? {
        do {
            _ = try await refreshQuota(for: id, force: force, scope: scope)
        } catch {
            let normalized = CPAError.normalize(error)
            if normalized.kind == .cancelled {
                if Task.isCancelled || epoch != batchEpoch {
                    throw CancellationError()
                }
                return nil
            }
        }
        guard let entry = entries.first(where: { $0.account.id == id }) else {
            return nil
        }
        return records[id] ?? QuotaRecord(account: entry.account, snapshot: entry.passiveSnapshot)
    }

    private func applyInventory(_ result: InventoryResult) {
        let newEntries = result.inventory.entries
        var updated: [String: QuotaRecord] = [:]
        for entry in newEntries {
            let previousEntry = entries.first(where: { $0.account.id == entry.account.id })
            let previous = previousEntry.flatMap { Self.sameCredential($0, entry) ? records[entry.account.id] : nil }
            let snapshot = Self.newer(previous?.snapshot, entry.passiveSnapshot)
            let retainedError = previous?.error?.kind == .accountDisabled ? nil : previous?.error
            let error = entry.account.isDisabled ? CPAError(.accountDisabled) : retainedError
            updated[entry.account.id] = QuotaRecord(account: entry.account, snapshot: snapshot, error: error)
        }
        for (id, flight) in Array(flights) {
            guard let old = entries.first(where: { $0.account.id == id }),
                  let new = newEntries.first(where: { $0.account.id == id }),
                  Self.sameCredential(old, new), !new.account.isDisabled else {
                flight.task.cancel()
                flights[id] = nil
                continue
            }
        }
        entries = newEntries
        records = updated
        pluginProviders = result.providers
        capabilityWarning = result.warning
        serverVersion = result.version
        hasInventory = true
    }

    private static func sameCredential(_ lhs: AccountEntry, _ rhs: AccountEntry) -> Bool {
        lhs.account.id == rhs.account.id && lhs.account.authIndex == rhs.account.authIndex &&
            lhs.account.provider == rhs.account.provider && lhs.codexAccountID == rhs.codexAccountID
    }

    private static func newer(_ lhs: QuotaSnapshot?, _ rhs: QuotaSnapshot?) -> QuotaSnapshot? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        let left = lhs.observedAt ?? (lhs.source == .live ? lhs.fetchedAt : .distantPast)
        let right = rhs.observedAt ?? (rhs.source == .live ? rhs.fetchedAt : .distantPast)
        return right > left ? rhs : lhs
    }

    private struct IndexRequest: Encodable { let auth_index: String }

    private struct ProxyRequest: Encodable {
        let auth_index: String
        let method = "GET"
        let url: String
        let header: [String: String]
    }

    private static func fetch(
        _ entry: AccountEntry, usePlugin: Bool, server: CPAServer, key: ManagementKey,
        transport: any HTTPTransport, clock: @Sendable () -> Date
    ) async throws -> QuotaSnapshot {
        guard let index = entry.account.authIndex else { throw CPAError(.accountNotFound) }
        if usePlugin {
            let body = try JSONEncoder().encode(IndexRequest(auth_index: index))
            do {
                let response = try await perform(.pluginQuota, body: body, server: server, key: key, transport: transport, clock: clock)
                return try PayloadDecoder.pluginQuota(response.body, account: entry.account, now: clock())
            } catch let error as CPAError where error.statusCode == 501 {
                throw CPAError(.unsupportedProvider)
            }
        }
        let url: String
        var headers = ["Authorization": "Bearer $TOKEN$"]
        switch entry.account.provider.lowercased() {
        case "codex":
            url = "https://chatgpt.com/backend-api/wham/usage"
            headers["Content-Type"] = "application/json"
            headers["User-Agent"] = "codex_cli_rs/0.76.0 (Debian 13.0.0; x86_64) WindowsTerminal"
            if let id = entry.codexAccountID { headers["Chatgpt-Account-Id"] = id }
        case "xai":
            url = "https://cli-chat-proxy.grok.com/v1/billing"
        default:
            throw CPAError(.unsupportedProvider)
        }
        let body = try JSONEncoder().encode(ProxyRequest(auth_index: index, url: url, header: headers))
        let response = try await perform(.proxy, body: body, server: server, key: key, transport: transport, clock: clock)
        let now = clock()
        let upstream = try PayloadDecoder.unwrapAPICall(response.body, now: now)
        if entry.account.provider.lowercased() == "codex" {
            return try PayloadDecoder.codex(upstream, account: entry.account, now: now)
        }
        return try PayloadDecoder.xai(upstream, account: entry.account, now: now)
    }

    private static func perform(
        _ endpoint: Endpoint, body: Data? = nil, server: CPAServer,
        key: ManagementKey, transport: any HTTPTransport, clock: @Sendable () -> Date
    ) async throws -> HTTPResponse {
        try Task.checkCancellation()
        var request = URLRequest(url: server.endpoint(endpoint.rawValue), timeoutInterval: 75)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue("Bearer \(key.value)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let response: HTTPResponse
        do { response = try await transport.send(request) }
        catch { throw CPAError.normalize(error) }
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else {
            let status = response.statusCode
            let kind: CPAError.Kind = switch status {
            case 300..<400: .redirectRefused
            case 401: .managementUnauthorized
            case 403: .managementForbidden
            case 404, 501: .endpointUnavailable
            case 429: .rateLimited
            default: .requestRejected
            }
            throw CPAError(kind, layer: .management, statusCode: status,
                           retryAfter: WireDate.retryAfter(response.header("Retry-After"), now: clock()))
        }
        return response
    }
}
