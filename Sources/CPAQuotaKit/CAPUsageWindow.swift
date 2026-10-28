import Foundation

public struct CAPUsageWindow: Codable, Equatable, Sendable {
    public let start: Date
    public let end: Date

    public init(now: Date) {
        let end = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 60) * 60)
        self.end = end
        self.start = end.addingTimeInterval(-1800)
    }
}
