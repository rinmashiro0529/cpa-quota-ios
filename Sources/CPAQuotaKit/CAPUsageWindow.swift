import Foundation

/// A validated count for one CAP range unit. Construction with an
/// out-of-bounds value fails, so every instance satisfies its bounds and the
/// rolling-window math never has to guess for an unvalidated payload.
public struct CAPUsageHourCount: Hashable, Sendable {
    /// 1...24
    public let value: Int

    private init(unchecked value: Int) { self.value = value }

    public init?(exactly value: Int) {
        guard (1...24).contains(value) else { return nil }
        self.init(unchecked: value)
    }

    public static let allCases: [CAPUsageHourCount] = (1...24).compactMap { CAPUsageHourCount(exactly: $0) }
}

public struct CAPUsageDayCount: Hashable, Sendable {
    /// 1...7
    public let value: Int

    private init(unchecked value: Int) { self.value = value }

    public init?(exactly value: Int) {
        guard (1...7).contains(value) else { return nil }
        self.init(unchecked: value)
    }

    public static let allCases: [CAPUsageDayCount] = (1...7).compactMap { CAPUsageDayCount(exactly: $0) }
}

public struct CAPUsageMonthCount: Hashable, Sendable {
    /// 1...12
    public let value: Int

    private init(unchecked value: Int) { self.value = value }

    public init?(exactly value: Int) {
        guard (1...12).contains(value) else { return nil }
        self.init(unchecked: value)
    }

    public static let allCases: [CAPUsageMonthCount] = (1...12).compactMap { CAPUsageMonthCount(exactly: $0) }
}

/// Bounded ranges supported by the pinned CAP custom-range contract. They do
/// not change the request-count, pagination or byte budgets. The three legacy
/// values keep their exact cases and their seconds-based serialization; new
/// ranges serialize as "unit:count" strings and reject out-of-bounds values.
public enum CAPUsageRange: Hashable, Sendable {
    case last30Minutes
    case last24Hours
    case last7Days
    /// Rolling hours, 1...24.
    case hours(CAPUsageHourCount)
    /// Rolling 24-hour durations, 1...7.
    case days(CAPUsageDayCount)
    /// UTC Gregorian calendar months, 1...12, derived from the window end.
    case months(CAPUsageMonthCount)

    /// Rolling duration for fixed-length ranges. Calendar months have no
    /// single duration and report nil.
    public var durationSeconds: TimeInterval? {
        switch self {
        case .last30Minutes: 1_800
        case .last24Hours: 86_400
        case .last7Days: 604_800
        case .hours(let hours): TimeInterval(hours.value) * 3_600
        case .days(let days): TimeInterval(days.value) * 86_400
        case .months: nil
        }
    }

    /// Calendar-month selections derive their start from the window end
    /// instead of a fixed duration.
    public var isCalendarMonthRange: Bool {
        if case .months = self { return true }
        return false
    }

    /// Validated entry points for the bounded ranges.
    public init?(hours: Int) {
        guard let count = CAPUsageHourCount(exactly: hours) else { return nil }
        self = hours == 24 ? .last24Hours : .hours(count)
    }

    public init?(days: Int) {
        guard let count = CAPUsageDayCount(exactly: days) else { return nil }
        self = days == 7 ? .last7Days : .days(count)
    }

    public init?(months: Int) {
        guard let count = CAPUsageMonthCount(exactly: months) else { return nil }
        self = .months(count)
    }

    /// Selection-panel options. The 24-hour and 7-day entries keep the legacy
    /// values so existing selections and serialized seconds stay canonical.
    public static let hourOptions: [CAPUsageRange] = (1...24).compactMap { CAPUsageRange(hours: $0) }

    public static let dayOptions: [CAPUsageRange] = (1...7).compactMap { CAPUsageRange(days: $0) }

    public static let monthOptions: [CAPUsageRange] = CAPUsageMonthCount.allCases.map(CAPUsageRange.months)

    // Public enum cases can construct these aliases directly. Use the same
    // identity for comparison, hashing and encoding, without erasing units.
    private enum Representation: Hashable {
        case legacySeconds(Int)
        case bounded(unit: String, count: Int)
    }

    private var representation: Representation {
        switch self {
        case .last30Minutes: .legacySeconds(1_800)
        case .last24Hours: .legacySeconds(86_400)
        case .last7Days: .legacySeconds(604_800)
        case .hours(let hours): hours.value == 24 ? .legacySeconds(86_400) : .bounded(unit: "hours", count: hours.value)
        case .days(let days): days.value == 7 ? .legacySeconds(604_800) : .bounded(unit: "days", count: days.value)
        case .months(let months): .bounded(unit: "months", count: months.value)
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.representation == rhs.representation }

    public func hash(into hasher: inout Hasher) { hasher.combine(representation) }
}

extension CAPUsageRange: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Legacy payloads are plain seconds and only the three historic values
        // are readable; any other integer is rejected instead of re-guessed.
        if let seconds = try? container.decode(Int.self) {
            switch seconds {
            case 1_800: self = .last30Minutes
            case 86_400: self = .last24Hours
            case 604_800: self = .last7Days
            default:
                throw DecodingError.dataCorruptedError(in: container,
                    debugDescription: "Unsupported legacy CAP usage range seconds: \(seconds)")
            }
            return
        }
        let text = try container.decode(String.self)
        let parts = text.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let count = Int(parts[1]) else {
            throw DecodingError.dataCorruptedError(in: container,
                debugDescription: "Malformed CAP usage range: \(text)")
        }
        let parsed: CAPUsageRange?
        switch parts[0] {
        case "hours": parsed = CAPUsageRange(hours: count)
        case "days": parsed = CAPUsageRange(days: count)
        case "months": parsed = CAPUsageRange(months: count)
        default: parsed = nil
        }
        guard let parsed else {
            throw DecodingError.dataCorruptedError(in: container,
                debugDescription: "Out-of-bounds or unknown CAP usage range: \(text)")
        }
        self = parsed
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch representation {
        case .legacySeconds(let seconds): try container.encode(seconds)
        case .bounded(let unit, let count): try container.encode("\(unit):\(count)")
        }
    }
}

public struct CAPUsageWindow: Codable, Equatable, Sendable {
    public let start: Date
    public let end: Date

    /// The end lands on the previous complete minute; fixed-length ranges
    /// subtract their rolling duration from it.
    public init(now: Date, range: CAPUsageRange = .last30Minutes) {
        let end = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 60) * 60)
        self.end = end
        switch range {
        case .last30Minutes: self.start = end.addingTimeInterval(-1_800)
        case .last24Hours: self.start = end.addingTimeInterval(-86_400)
        case .last7Days: self.start = end.addingTimeInterval(-604_800)
        case .hours(let hours): self.start = end.addingTimeInterval(TimeInterval(hours.value) * -3_600)
        case .days(let days): self.start = end.addingTimeInterval(TimeInterval(days.value) * -86_400)
        case .months(let months): self.start = Self.utcCalendarMonthStart(monthsBack: months.value, from: end)
        }
    }

    private static let utcGregorian: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        // "UTC" is a fixed ICU identifier; the fallback keeps construction total.
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone.current
        return calendar
    }()

    /// Subtracts whole UTC Gregorian months from a minute-aligned end. A
    /// target month without the source day pins to that month's last day
    /// (Mar 31 minus one month lands on Feb 28, or Feb 29 in a leap year),
    /// keeping the end's clock time. Display in the device time zone never
    /// changes the absolute range.
    private static func utcCalendarMonthStart(monthsBack: Int, from end: Date) -> Date {
        utcGregorian.date(byAdding: .month, value: -monthsBack, to: end, wrappingComponents: false) ?? end
    }
}
