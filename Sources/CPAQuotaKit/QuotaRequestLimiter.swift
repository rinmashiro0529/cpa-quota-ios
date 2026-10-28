import Foundation

public actor CPAManagementRequestCoordinator {
    private let limit: Int
    private let clock: @Sendable () -> Date
    private var active = 0
    private var waiting: [(UUID, CheckedContinuation<Void, any Error>)] = []
    private var blocked: CPAError?

    public init(limit: Int = 3, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.limit = min(3, max(1, limit))
        self.clock = clock
    }

    public func withPermit<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async throws -> Value {
        try await acquire(at: clock())
        do {
            try Task.checkCancellation()
            try check(at: clock())
            let value = try await operation()
            release()
            return value
        } catch {
            guard let original = error as? CPAError, original.isManagementBlocking else {
                release()
                throw error
            }
            let failure = original.kind == .rateLimited && original.retryAfter == nil
                ? CPAError(.rateLimited, layer: .management, statusCode: original.statusCode,
                           retryAfter: clock().addingTimeInterval(60))
                : original
            if let existing = blocked {
                if existing.kind == .rateLimited && failure.kind != .rateLimited {
                    blocked = failure
                } else if existing.kind == .rateLimited && failure.kind == .rateLimited,
                          let oldDeadline = existing.retryAfter, let newDeadline = failure.retryAfter,
                          newDeadline > oldDeadline {
                    blocked = failure
                }
            } else {
                blocked = failure
            }
            let queued = waiting
            waiting.removeAll()
            let circuitError = blocked ?? failure
            queued.forEach { $0.1.resume(throwing: circuitError) }
            release()
            throw failure
        }
    }

    public func retryEligibility() -> QuotaRetryEligibility {
        let now = clock()
        do {
            try check(at: now)
            return .eligible
        } catch {
            let failure = CPAError.normalize(error)
            if failure.kind == .rateLimited, let deadline = failure.retryAfter, deadline > now {
                return .coolingDown(until: deadline)
            }
            return .blocked(failure)
        }
    }

    func check() throws {
        try check(at: clock())
    }

    private func check(at now: Date) throws {
        if let failure = blocked, failure.kind == .rateLimited,
           let deadline = failure.retryAfter, deadline <= now {
            blocked = nil
        }
        if let blocked { throw blocked }
    }

    private func acquire(at now: Date) async throws {
        try Task.checkCancellation()
        try check(at: now)
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
