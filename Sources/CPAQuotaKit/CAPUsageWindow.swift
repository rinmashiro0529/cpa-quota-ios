import Foundation

/// Bounded durations supported by the pinned CAP custom-range contract.
/// They do not change the request-count, pagination or byte budgets.
public enum CAPUsageRange: Int, CaseIterable, Codable, Hashable, Sendable {
    case last30Minutes = 1800
    case last24Hours = 86400
    case last7Days = 604800

    public var duration: TimeInterval { TimeInterval(rawValue) }
}

public struct CAPUsageWindow: Codable, Equatable, Sendable {
    public let start: Date
    public let end: Date

    public init(now: Date, range: CAPUsageRange = .last30Minutes) {
        let end = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 60) * 60)
        self.end = end
        self.start = end.addingTimeInterval(-range.duration)
    }
}
