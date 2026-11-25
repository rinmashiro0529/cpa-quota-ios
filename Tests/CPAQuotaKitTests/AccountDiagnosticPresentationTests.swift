import Testing
import CPAQuotaKit
import CPAQuotaUI

@Suite("Native account diagnostics preserve capability and privacy semantics")
struct AccountDiagnosticPresentationTests {
    @Test
    func unrecognizedProviderDoesNotClaimAnExistingBuiltInReader() {
        let account = CPAAccount(id: "other", authIndex: "1", provider: "other", displayName: "Other")
        let presentation = AccountDiagnosticPresentation(account: account, error: nil, maskEmail: true)
        #expect(presentation.readerDescription.contains("没有该平台的内置读取器"))
        #expect(presentation.readerDescription.contains("服务端发现的插件能力"))
    }

    @Test
    func declaredPluginDoesNotOverrideAnActualUnsupportedResult() {
        let account = CPAAccount(id: "plugin", authIndex: "2", provider: "other", displayName: "Plugin", supportsPluginQuota: true)
        let presentation = AccountDiagnosticPresentation(
            account: account, error: CPAError(.unsupportedProvider), maskEmail: true
        )
        #expect(presentation.readerDescription == "暂不支持读取该平台的额度。")
        #expect(presentation.severity == ErrorPresentation(error: CPAError(.unsupportedProvider)).severity)
    }

    @Test
    func disabledAccountIsNotPresentedAsCriticalBecauseOfAnOlderError() {
        let account = CPAAccount(id: "disabled", authIndex: "3", provider: "codex", displayName: "Disabled", isDisabled: true)
        let presentation = AccountDiagnosticPresentation(
            account: account, error: CPAError(.upstreamUnauthorized), maskEmail: true
        )
        #expect(presentation.accountStatus == "已停用")
        #expect(presentation.severity == .neutral)
    }

    @Test
    func visualAndAccessibilityStringsShareTheSameMaskedValues() {
        let account = CPAAccount(id: "private", authIndex: "4", provider: "codex", displayName: "private@example.com", email: "private@example.com")
        let masked = AccountDiagnosticPresentation(account: account, error: nil, maskEmail: true)
        #expect(masked.displayName == "pr***e@example.com")
        #expect(masked.email == masked.displayName)
        let visible = AccountDiagnosticPresentation(account: account, error: nil, maskEmail: false)
        #expect(visible.displayName == "private@example.com")
        #expect(visible.email == "private@example.com")
    }
}
