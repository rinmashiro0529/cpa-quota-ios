import Foundation
import Testing
@testable import CPAQuotaKit

@Suite("CAP usage window")
struct CAPUsageWindowTests {
    private let end = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func thirtyMinutesEndsAtPreviousUTCMInute() {
        let window = CAPUsageWindow(now: Date(timeIntervalSince1970: 1_800_000_059))
        #expect(window.end == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(window.start == Date(timeIntervalSince1970: 1_799_998_200))
    }

    @Test func boundedRangesUseCompleteMinuteAndRollingDuration() throws {
        let cases: [(range: CAPUsageRange, duration: TimeInterval)] = [
            (.last30Minutes, 1_800),
            (.last24Hours, 86_400),
            (.last7Days, 604_800),
            (.hours(try #require(CAPUsageHourCount(exactly: 1))), 3_600),
            (.hours(try #require(CAPUsageHourCount(exactly: 23))), 82_800),
            (.days(try #require(CAPUsageDayCount(exactly: 1))), 86_400),
            (.days(try #require(CAPUsageDayCount(exactly: 6))), 518_400)
        ]
        let now = end.addingTimeInterval(59)
        for sample in cases {
            let window = CAPUsageWindow(now: now, range: sample.range)
            #expect(window.end == end)
            #expect(window.end.timeIntervalSince(window.start) == sample.duration)
            #expect(sample.range.durationSeconds == sample.duration)
        }
    }

    @Test func outOfBoundsCountsAreRejectedAtConstruction() {
        for value in [0, -1, 25, Int.max] {
            #expect(CAPUsageHourCount(exactly: value) == nil)
            #expect(CAPUsageRange(hours: value) == nil)
        }
        for value in [0, -1, 8, Int.min] {
            #expect(CAPUsageDayCount(exactly: value) == nil)
            #expect(CAPUsageRange(days: value) == nil)
        }
        for value in 1...24 { #expect(CAPUsageHourCount(exactly: value) != nil) }
        for value in 1...7 { #expect(CAPUsageDayCount(exactly: value) != nil) }
    }

    @Test func selectionOptionsKeepLegacyBoundaryValuesCanonical() throws {
        #expect(CAPUsageRange.hourOptions.count == 24)
        #expect(CAPUsageRange.hourOptions.first == .hours(try #require(CAPUsageHourCount(exactly: 1))))
        #expect(CAPUsageRange.hourOptions.last == .last24Hours)
        #expect(CAPUsageRange.dayOptions.count == 7)
        #expect(CAPUsageRange.dayOptions.first == .days(try #require(CAPUsageDayCount(exactly: 1))))
        #expect(CAPUsageRange.dayOptions.last == .last7Days)
        let legacy: Set<CAPUsageRange> = [.last30Minutes]
        #expect(CAPUsageRange.hourOptions.allSatisfy { !legacy.contains($0) })
        #expect(CAPUsageRange.dayOptions.allSatisfy { !legacy.contains($0) })
    }

    @Test func codableKeepsLegacySecondsReadableAndRoundTripsNewRanges() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for (range, seconds) in [(CAPUsageRange.last30Minutes, 1_800),
                                 (CAPUsageRange.last24Hours, 86_400),
                                 (CAPUsageRange.last7Days, 604_800)] {
            let data = try encoder.encode(range)
            #expect(String(decoding: data, as: UTF8.self) == "\(seconds)")
            #expect(try decoder.decode(CAPUsageRange.self, from: data) == range)
        }
        let bounded: [(CAPUsageRange, String)] = [
            (.hours(try #require(CAPUsageHourCount(exactly: 1))), "hours:1"),
            (.hours(try #require(CAPUsageHourCount(exactly: 23))), "hours:23"),
            (.days(try #require(CAPUsageDayCount(exactly: 1))), "days:1"),
            (.days(try #require(CAPUsageDayCount(exactly: 6))), "days:6")
        ]
        for (range, text) in bounded {
            let data = try encoder.encode(range)
            #expect(String(decoding: data, as: UTF8.self) == "\"\(text)\"")
            #expect(try decoder.decode(CAPUsageRange.self, from: data) == range)
        }
    }

    @Test func codableRejectsUnknownSecondsMalformedAndOutOfBoundsValues() {
        let decoder = JSONDecoder()
        for payload in ["3600", "0", "-1800", "2592000", "7200"] {
            #expect(throws: DecodingError.self) {
                try decoder.decode(CAPUsageRange.self, from: Data(payload.utf8))
            }
        }
        for payload in ["\"hours:0\"", "\"hours:25\"", "\"days:8\"", "\"weeks:2\"", "\"hours\"", "\"garbage\"", "\"hours:x\""] {
            #expect(throws: DecodingError.self) {
                try decoder.decode(CAPUsageRange.self, from: Data(payload.utf8))
            }
        }
    }

    @Test func calendarMonthsSubtractWholeUTCMonthsFromTheMinuteEnd() throws {
        let parser = ISO8601DateFormatter()
        func monthWindow(_ end: String, months: Int) throws -> CAPUsageWindow {
            CAPUsageWindow(now: try #require(parser.date(from: end)),
                           range: .months(try #require(CAPUsageMonthCount(exactly: months))))
        }
        func instant(_ text: String) throws -> Date { try #require(parser.date(from: text)) }

        let cases: [(end: String, months: Int, start: String)] = [
            // March 31 clamps to February's last day, including leap years.
            ("2027-03-31T10:20:30Z", 1, "2027-02-28T10:20:00Z"),
            ("2028-03-31T10:20:00Z", 1, "2028-02-29T10:20:00Z"),
            // A target month with the same day keeps it; twelve months cross years.
            ("2027-03-31T10:20:00Z", 2, "2027-01-31T10:20:00Z"),
            ("2027-11-18T00:00:59Z", 12, "2026-11-18T00:00:00Z"),
            ("2028-02-29T12:00:00Z", 12, "2027-02-28T12:00:00Z")
        ]
        for sample in cases {
            let window = try monthWindow(sample.end, months: sample.months)
            let expectedStart = try instant(sample.start)
            #expect(window.start == expectedStart)
        }
        // The end itself stays on the previous complete minute.
        let leap = try monthWindow("2028-03-31T10:20:30Z", months: 1)
        let leapEnd = try instant("2028-03-31T10:20:00Z")
        let leapStart = try instant("2028-02-29T10:20:00Z")
        #expect(leap.end == leapEnd)
        #expect(leap.start == leapStart)
    }

    @Test func monthRangesHaveNoFixedDurationAndKeepValidatedBounds() throws {
        let threeMonths = CAPUsageRange.months(try #require(CAPUsageMonthCount(exactly: 3)))
        #expect(threeMonths.durationSeconds == nil)
        #expect(threeMonths.isCalendarMonthRange)
        #expect(!CAPUsageRange.hours(try #require(CAPUsageHourCount(exactly: 3))).isCalendarMonthRange)
        #expect(!CAPUsageRange.last30Minutes.isCalendarMonthRange)
        for value in [0, -1, 13, Int.max] {
            #expect(CAPUsageMonthCount(exactly: value) == nil)
            #expect(CAPUsageRange(months: value) == nil)
        }
        for value in 1...12 { #expect(CAPUsageMonthCount(exactly: value) != nil) }
        let expected: [CAPUsageRange] = (1...12).compactMap { CAPUsageRange(months: $0) }
        #expect(CAPUsageRange.monthOptions == expected)
        #expect(CAPUsageRange.monthOptions.count == 12)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let encoded = try encoder.encode(threeMonths)
        #expect(String(decoding: encoded, as: UTF8.self) == "\"months:3\"")
        #expect(try decoder.decode(CAPUsageRange.self, from: encoded) == threeMonths)
        for payload in ["\"months:0\"", "\"months:13\"", "\"months:x\""] {
            #expect(throws: DecodingError.self) {
                try decoder.decode(CAPUsageRange.self, from: Data(payload.utf8))
            }
        }
    }
}
