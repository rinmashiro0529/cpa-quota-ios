import Foundation

actor QuotaRequestLimiter {
    private let limit: Int
    private var active = 0
    private var waiting: [(UUID, CheckedContinuation<Void, any Error>)] = []
    private var blocked: CPAError?

    init(limit: Int) { self.limit = max(1, limit) }

    func withPermit<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async throws -> Value {
        try await acquire()
        do {
            try Task.checkCancellation()
            let value = try await operation()
            release()
            return value
        } catch {
            if let failure = error as? CPAError, failure.isManagementBlocking {
                blocked = failure
                let queued = waiting
                waiting.removeAll()
                queued.forEach { $0.1.resume(throwing: failure) }
            }
            release()
            throw error
        }
    }

    func reset(at now: Date) {
        guard let blocked else { return }
        if let retryAfter = blocked.retryAfter, retryAfter > now { return }
        self.blocked = nil
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if let blocked { throw blocked }
        if active < limit {
            active += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiting.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func release() {
        if !waiting.isEmpty {
            let next = waiting.removeFirst()
            next.1.resume()
        } else {
            active -= 1
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        let waiter = waiting.remove(at: index)
        waiter.1.resume(throwing: CancellationError())
    }
}
