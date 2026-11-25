import Foundation
import Testing
@testable import CPAQuotaKit

@Suite("CPAClientAPIKey")
struct CPAClientAPIKeyTests {
    @Test func acceptsAndTrimsValidKey() {
        let key = CPAClientAPIKey("  test-client-key-0001  ")
        #expect(key != nil)
        #expect(key?.exposedValue == "test-client-key-0001")
    }

    @Test func rejectsEmptyAndWhitespaceOnly() {
        #expect(CPAClientAPIKey("") == nil)
        #expect(CPAClientAPIKey("   \n\t ") == nil)
    }

    @Test func rejectsControlCharacters() {
        #expect(CPAClientAPIKey("test-key\u{0000}abcd") == nil)
        #expect(CPAClientAPIKey("test-key\u{0007}") == nil)
        #expect(CPAClientAPIKey("test\u{001F}key") == nil)
    }

    @Test func rejectsOversizedKey() {
        let oversized = String(repeating: "a", count: 4097)
        #expect(CPAClientAPIKey(oversized) == nil)
        let atLimit = String(repeating: "a", count: 4096)
        #expect(CPAClientAPIKey(atLimit) != nil)
    }

    @Test func redactsDescription() {
        let key = CPAClientAPIKey("test-client-key-0001")!
        #expect(key.description == "<redacted client API key>")
        #expect(key.debugDescription == "<redacted client API key>")
        #expect(!key.description.contains("test-client-key"))
        #expect(!key.debugDescription.contains("test-client-key"))
    }

    @Test func hintIsSuffixOnly() {
        let key = CPAClientAPIKey("test-client-key-0001")!
        #expect(key.hint == "••••0001")
        #expect(!key.hint.contains("test-client-key"))
    }

    @Test func shortKeyHintIsPlainMask() {
        let key = CPAClientAPIKey("12345678")!
        #expect(key.hint == "••••")
        #expect(!key.hint.contains("12345678"))
    }

    @Test func hashableAndEquatable() {
        let a = CPAClientAPIKey("test-client-key-0001")!
        let b = CPAClientAPIKey("test-client-key-0001")!
        let c = CPAClientAPIKey("test-client-key-0002")!
        #expect(a == b)
        #expect(a != c)
        #expect(Set([a, b, c]).count == 2)
    }
}
