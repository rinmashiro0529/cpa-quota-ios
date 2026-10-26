import Foundation
import Testing
import CPAQuotaKit
import CPAQuotaUI

@Suite("Integration presentation regressions")
struct IntegrationPresentationRegressionTests {
    @Test
    func globalFailureDoesNotClaimHistoryWhenRecordsHaveNoSnapshot() {
        let account = CPAAccount(id: "first", authIndex: "index-first", provider: "codex", displayName: "First")
        let record = QuotaRecord(account: account, error: CPAError(.managementUnauthorized))
        let presentation = ErrorPresentation(error: CPAError(.managementUnauthorized), records: [account.id: record])

        #expect(!presentation.recoveryAdvice.contains("最后一次成功获取的快照"))
    }

    @Test
    func extremeFiniteUsageFormatsWithoutIntegerOverflow() {
        let window = QuotaWindow(id: "extreme", title: "Extreme usage", usedFraction: 1e20)
        let presentation = WindowPresentation(window: window)

        #expect(presentation.primaryPercentageText(for: .used) == "1e+22% 已用")
        #expect(presentation.secondaryComparisonText == "已用 1e+22% · 剩余 0%")

        let overflowing = WindowPresentation(window: QuotaWindow(
            id: "overflowing",
            title: "Overflowing usage",
            usedFraction: Double.greatestFiniteMagnitude
        ))
        #expect(overflowing.primaryPercentageText(for: .used) == "2e+310% 已用")
        #expect(!overflowing.secondaryComparisonText.contains("inf"))
    }
}
