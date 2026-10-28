import Testing
import CPAQuotaKit

@Suite("Safe account identity")
struct BackendReliabilityIdentityTests {
    @Test func embeddedEmailCannotLeakThroughSafeLabel() {
        let account = CPAAccount(id: "private@example.com", authIndex: nil, provider: "codex",
                                 displayName: "Primary private@example.com", email: "private@example.com")
        let identity = AccountIdentity(account: account, ordinal: 2)
        #expect(identity.label == "Account 2")
        #expect(!identity.label.contains("private@example.com"))
    }
}
