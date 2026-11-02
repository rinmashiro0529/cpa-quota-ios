import Foundation
import Testing
@testable import CPAQuotaKit

@Suite("CAP usage window")
struct CAPUsageWindowTests {
    @Test func thirtyMinutesEndsAtPreviousUTCMInute() {
        let window = CAPUsageWindow(now: Date(timeIntervalSince1970: 1_800_000_059))
        #expect(window.end == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(window.start == Date(timeIntervalSince1970: 1_799_998_200))
    }
}
