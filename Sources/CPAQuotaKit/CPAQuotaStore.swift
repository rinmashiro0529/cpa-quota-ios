import Foundation
import Observation

@MainActor
@Observable
public final class CPAQuotaStore {
    public private(set) var accounts: [CPAAccount] = []
    public private(set) var records: [String: QuotaRecord] = [:]
    public private(set) var capabilityWarning: CPAError?
    public private(set) var isLoading = false
    public private(set) var isRefreshing = false
    public private(set) var error: CPAError?

    @ObservationIgnored private let client: CPAClient
    @ObservationIgnored private var operation: UUID?
    @ObservationIgnored private var operationTask: Task<Void, Never>?

    public init(client: CPAClient) { self.client = client }

    public func load() async { await run(force: false) }

    public func refresh(force: Bool = true) async { await run(force: force) }

    public func cancel() async {
        let task = operationTask
        operation = nil
        operationTask = nil
        isLoading = false
        isRefreshing = false
        task?.cancel()
    }

    private func run(force: Bool) async {
        guard operation == nil else { return }
        let token = UUID()
        operation = token
        isLoading = true
        error = nil
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRun(force: force, token: token)
        }
        operationTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performRun(force: Bool, token: UUID) async {
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
            isLoading = false
            isRefreshing = true

            _ = try await client.refreshAll(force: force) { [weak self] record in
                await self?.apply(record, operation: token)
            }
            try Task.checkCancellation()
            guard operation == token else { return }
            let final = await client.snapshot()
            try Task.checkCancellation()
            guard operation == token else { return }
            publish(final)
        } catch {
            guard operation == token else { return }
            let normalized = CPAError.normalize(error)
            if normalized.kind != .cancelled { self.error = normalized }
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
    }
}
