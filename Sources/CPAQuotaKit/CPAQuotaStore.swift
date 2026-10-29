import Foundation
import Observation

/// One refresh attempt. Account identifiers are the same sensitive identifiers as the inventory.
/// `planned` includes disabled accounts; `processed` contains callbacks for enabled accounts,
/// partitioned into `succeeded` and `failed`. `skipped` contains disabled accounts and accounts
/// not processed when an operation is cancelled or aborted. An empty `planned` set while loading
/// means the inventory is not yet known. `completed` may still include account-level failures.
public struct QuotaOperation: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case loading, refreshing, completed, cancelled, failed }
    public let id: UUID
    public var phase: Phase
    public var planned: Set<String>
    public var processed: Set<String>
    public var succeeded: Set<String>
    public var failed: Set<String>
    public var skipped: Set<String>
}

@MainActor
@Observable
public final class CPAQuotaStore {
    public private(set) var accounts: [CPAAccount] = []
    public private(set) var records: [String: QuotaRecord] = [:]
    public private(set) var capabilityWarning: CPAError?
    public private(set) var isLoading = false
    public private(set) var isRefreshing = false
    public private(set) var error: CPAError?
    public private(set) var refreshOperation: QuotaOperation?

    @ObservationIgnored private let client: CPAClient
    @ObservationIgnored private var operation: UUID?
    @ObservationIgnored private var operationTask: Task<Void, Never>?

    public init(client: CPAClient) { self.client = client }

    public func load() async { await run(force: false) }

    public func refresh(force: Bool = true) async { await run(force: force) }

    public func refresh(accountID: String, force: Bool = true) async {
        await run(force: force, accountID: accountID)
    }

    public func makeCAPUsageClient() async -> CAPUsageClient {
        await client.makeCAPUsageClient()
    }

    public func retryEligibility(for accountID: String? = nil) async -> QuotaRetryEligibility {
        await client.retryEligibility(for: accountID)
    }

    public func cancel() async {
        let task = operationTask
        if var current = refreshOperation, current.id == operation {
            current.phase = .cancelled
            current.skipped.formUnion(current.planned.subtracting(current.processed))
            refreshOperation = current
        }
        operation = nil
        operationTask = nil
        isLoading = false
        isRefreshing = false
        task?.cancel()
    }

    private func run(force: Bool, accountID: String? = nil) async {
        guard operation == nil else { return }
        let token = UUID()
        operation = token
        refreshOperation = QuotaOperation(id: token, phase: .loading, planned: [], processed: [], succeeded: [], failed: [], skipped: [])
        isLoading = true
        error = nil
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRun(force: force, accountID: accountID, token: token)
        }
        operationTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performRun(force: Bool, accountID: String?, token: UUID) async {
        defer {
            if operation == token {
                operation = nil
                operationTask = nil
                isLoading = false
                isRefreshing = false
            }
        }
        do {
            _ = try await client.loadAccounts()
            try Task.checkCancellation()
            guard operation == token else { return }
            let initial = await client.snapshot()
            try Task.checkCancellation()
            guard operation == token else { return }
            publish(initial)
            if let accountID {
                guard initial.records.contains(where: { $0.id == accountID }) else {
                    throw CPAError(.accountNotFound)
                }
                refreshOperation?.planned = [accountID]
            } else {
                refreshOperation?.planned = Set(initial.records.map(\.id))
            }
            refreshOperation?.phase = .refreshing
            isLoading = false
            isRefreshing = true

            if let accountID {
                var failure: CPAError?
                do {
                    _ = try await client.refreshQuota(for: accountID, force: force)
                } catch {
                    failure = CPAError.normalize(error)
                }
                try Task.checkCancellation()
                guard operation == token else { return }
                let snapshot = await client.snapshot()
                if let record = snapshot.records.first(where: { $0.id == accountID }) {
                    let result = failure.map { QuotaRecord(account: record.account, snapshot: record.snapshot, error: $0) } ?? record
                    apply(result, operation: token)
                }
                if let failure, failure.isManagementBlocking || failure.kind == .cancelled {
                    throw failure
                }
            } else {
                _ = try await client.refreshAll(force: force) { [weak self] record in
                    await self?.apply(record, operation: token)
                }
            }
            try Task.checkCancellation()
            guard operation == token else { return }
            let final = await client.snapshot()
            try Task.checkCancellation()
            guard operation == token else { return }
            publish(final)
            if var current = refreshOperation, current.id == token {
                current.skipped.formUnion(current.planned.subtracting(current.processed))
                current.phase = .completed
                refreshOperation = current
            }
        } catch {
            guard operation == token else { return }
            let normalized = CPAError.normalize(error)
            if normalized.kind != .cancelled { self.error = normalized }
            if var current = refreshOperation, current.id == token {
                current.phase = normalized.kind == .cancelled ? .cancelled : .failed
                current.skipped.formUnion(current.planned.subtracting(current.processed))
                refreshOperation = current
            }
        }
    }

    private func publish(_ snapshot: CPAClient.Snapshot) {
        accounts = snapshot.records.map(\.account)
        records = Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.id, $0) })
        capabilityWarning = snapshot.capabilityWarning
    }

    private func apply(_ record: QuotaRecord, operation token: UUID) {
        guard operation == token, accounts.contains(where: { $0.id == record.id }) else { return }
        records[record.id] = record
        guard var current = refreshOperation, current.id == token else { return }
        if record.account.isDisabled {
            current.skipped.insert(record.id)
        } else {
            current.processed.insert(record.id)
            if record.error == nil {
                current.succeeded.insert(record.id)
            } else {
                current.failed.insert(record.id)
            }
        }
        refreshOperation = current
    }
}
