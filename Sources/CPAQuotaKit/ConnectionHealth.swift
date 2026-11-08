import Foundation

/// Independent display facts for a future view. `eligible` only permits another attempt and does not
/// claim that the service or data has recovered.
public struct ConnectionHealth: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case unknown
        case ready
        case failed(CPAError)
        case stale
        case coolingDown(until: Date)
        case blocked(CPAError)
    }

    public let connection: State
    public let data: State

    public init(connection: State, data: State) {
        self.connection = connection
        self.data = data
    }

    public init(record: QuotaRecord, eligibility: QuotaRetryEligibility, now: Date) {
        switch eligibility {
        case .coolingDown(let deadline) where deadline > now:
            connection = .coolingDown(until: deadline)
        case .blocked(let error):
            connection = .blocked(error)
        case .eligible, .coolingDown:
            if let error = record.error {
                connection = .failed(error)
            } else {
                connection = record.snapshot == nil ? .unknown : .ready
            }
        }
        if let snapshot = record.snapshot {
            data = snapshot.isStale(at: now) ? .stale : .ready
        } else {
            data = .unknown
        }
    }
}

public struct QuotaFreshness: Sendable, Equatable {
    public enum State: Sendable, Equatable { case unknown, fresh, stale }
    public let state: State
    public let observedAt: Date?

    public init(snapshot: QuotaSnapshot?, now: Date) {
        guard let snapshot else {
            state = .unknown
            observedAt = nil
            return
        }
        observedAt = snapshot.observedAt ?? (snapshot.source == .live ? snapshot.fetchedAt : nil)
        state = observedAt == nil ? .unknown : (snapshot.isStale(at: now) ? .stale : .fresh)
    }
}

/// Shared calendar and countdown bounds. Invalid input is unknown, not zero.
public enum QuotaTime {
    public static func isSupported(_ date: Date) -> Bool {
        WireDate.epochDate(date.timeIntervalSince1970) != nil
    }

    /// Zero permits another attempt; it does not prove a successful response.
    public static func remainingSeconds(until deadline: Date, now: Date) -> Int? {
        guard isSupported(deadline), isSupported(now) else { return nil }
        let remaining = deadline.timeIntervalSince(now)
        guard remaining.isFinite else { return nil }
        return Int(exactly: max(0, ceil(remaining)))
    }
}
