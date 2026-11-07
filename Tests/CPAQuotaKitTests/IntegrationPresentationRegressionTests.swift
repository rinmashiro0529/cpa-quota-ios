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

@Suite("Audit quota semantics and privacy")
struct AuditQuotaPresentationTests {
    @Test(arguments: [0.0, 0.2, 0.999, 1.0, 1.01])
    func exhaustedReadingIsDistinctFromExplicitUpstreamEnforcement(_ used: Double) {
        let presentation = WindowPresentation(window: QuotaWindow(id: "window", title: "5-hour limit", usedFraction: used))
        #expect(presentation.isExhausted == (used >= 1))
        #expect(!presentation.isExplicitlyLimited)
        #expect(presentation.isOverQuota == (used >= 1))
        if used >= 1 {
            #expect(presentation.statusText == "读数已用完")
            #expect(presentation.enforcementExplanation != nil)
            #expect(!presentation.isLowRemainingWarning)
        } else if used == 0.999 {
            #expect(presentation.statusText == "剩余额度偏低")
        } else {
            #expect(presentation.statusText == nil)
        }
    }

    @Test func explicitUpstreamFlagsTakePrecedenceEvenWithoutKnownPercentage() {
        for window in [
            QuotaWindow(id: "allowed", title: "Custom", usedFraction: 0, allowed: false),
            QuotaWindow(id: "limited", title: "Custom", limitReached: true),
            QuotaWindow(id: "both", title: "Custom", usedFraction: 1, allowed: false, limitReached: true)
        ] {
            let presentation = WindowPresentation(window: window)
            #expect(presentation.isExplicitlyLimited)
            #expect(presentation.statusText == "上游已限制使用")
            #expect(presentation.enforcementExplanation == nil)
        }
        let unknown = WindowPresentation(window: QuotaWindow(id: "unknown", title: "Custom"))
        #expect(!unknown.isOverQuota)
        #expect(unknown.primaryPercentageText(for: .remaining) == "剩余比例未知")
    }

    @Test func listUsesLowestKnownIndependentWindowAndPreservesUnknownCount() {
        let account = CPAAccount(id: "a", authIndex: "index-a", provider: "codex", displayName: "Fixture")
        let snapshot = QuotaSnapshot(accountID: account.id, provider: account.provider, source: .live, fetchedAt: Date(), windows: [
            QuotaWindow(id: "weekly", title: "7-day limit", usedFraction: 0.2),
            QuotaWindow(id: "hourly", title: "5-hour limit", usedFraction: 0.9),
            QuotaWindow(id: "unknown", title: "自定义限额")
        ])
        let record = QuotaRecord(account: account, snapshot: snapshot)
        let summary = AccountQuotaSummary(record: record)
        #expect(summary.window?.id == "hourly")
        #expect(summary.window?.primaryPercentageText(for: .remaining) == "10% 剩余")
        #expect(summary.windowCount == 3)
        #expect(summary.knownWindowCount == 2)
        #expect(summary.selectionText?.contains("1 个窗口比例未知") == true)
        #expect(summary.hasLowQuota)
        #expect(QuotaAccountStatusFilter.lowQuota.matches(account, record: record))
        #expect(!QuotaAccountStatusFilter.pending.matches(account, record: record))
    }

    @Test func emptyAndFailedReadsAreNeverCountedAsZeroQuota() {
        let pending = CPAAccount(id: "pending", authIndex: "p", provider: "codex", displayName: "Pending")
        let failed = CPAAccount(id: "failed", authIndex: "f", provider: "codex", displayName: "Failed")
        let disabled = CPAAccount(id: "disabled", authIndex: "d", provider: "codex", displayName: "Disabled", isDisabled: true)
        let records = [failed.id: QuotaRecord(account: failed, error: CPAError(.network))]
        let summary = QuotaOverviewSummary(accounts: [pending, failed, disabled], records: records)
        #expect(summary.accountCount == 3)
        #expect(summary.snapshotCount == 0)
        #expect(summary.lowQuotaCount == 0)
        #expect(summary.pendingCount == 1)
        #expect(summary.failedCount == 1)
        #expect(AccountQuotaSummary(record: records[failed.id]).window == nil)
    }

    @Test func knownWindowLabelsAreLocalizedAndCustomLabelsRetainTheirOriginalIdentity() {
        let builtIn = WindowPresentation(window: QuotaWindow(id: "hourly", title: "5-hour limit"))
        #expect(builtIn.title == "5 小时额度")
        #expect(builtIn.originalTitle == "5-hour limit")
        let custom = WindowPresentation(window: QuotaWindow(id: "custom", title: "Partner rolling window (custom)"))
        #expect(custom.title == "Partner rolling window (custom)")
        #expect(custom.originalTitle == custom.title)
    }

    @Test func freeTextMaskingRedactsEveryEmailIncludingUnicodeAndMalformedDomains() {
        let value = "Owner: first@example.test、second@example.test；用户.测试@例子.公司；broken: missing@；double: alpha@@host"
        let masked = QuotaFormatter.maskEmails(in: value, enabled: true)
        #expect(masked.contains("fi***t@example.test"))
        #expect(masked.contains("se***d@example.test"))
        #expect(masked.contains("用户***试@例子.公司"))
        #expect(masked.contains("mi***g@"))
        #expect(masked.contains("al***a@@host"))
        #expect(!masked.contains("first@example.test"))
        #expect(!masked.contains("second@example.test"))
        #expect(QuotaFormatter.maskEmail(value, enabled: true) == masked)
        #expect(QuotaFormatter.maskEmails(in: value, enabled: false) == value)
        #expect(QuotaFormatter.maskEmails(in: "无邮箱的主账号", enabled: true) == "无邮箱的主账号")
        #expect(QuotaFormatter.maskEmails(in: "张＠example.test", enabled: true) == "***＠example.test")
        #expect(QuotaFormatter.maskEmails(in: "a@example.test", enabled: true) == "***@example.test")
    }

    @Test func metricPresentationMasksEmailInLabelAndUnit() {
        let metric = QuotaMetric(id: "unit", label: "Owner first@example.test", value: 42, unit: "second@example.test", format: "integer")
        let presentation = MetricPresentation(metric: metric, maskEmail: true)
        #expect(presentation.label == "Owner fi***t@example.test")
        #expect(presentation.formattedValue == "42 se***d@example.test")
    }

    @Test func metricPresentationPreservesUnmaskedCurrencyAndNumericContracts() {
        let metric = QuotaMetric(id: "currency", label: "first@example.test", value: 25, unit: "ignored", format: "currency", currency: "second@example.test")
        let masked = MetricPresentation(metric: metric, maskEmail: true)
        #expect(masked.label == "fi***t@example.test")
        #expect(masked.formattedValue == "25.00 se***d@example.test")
        let unmasked = MetricPresentation(metric: metric, maskEmail: false)
        #expect(unmasked.label == "first@example.test")
        #expect(unmasked.formattedValue == "25.00 second@example.test")
        #expect(MetricPresentation(metric: metric).formattedValue == "25.00 second@example.test")
        let legacyInitializer: (QuotaMetric) -> MetricPresentation = MetricPresentation.init
        #expect(legacyInitializer(metric).formattedValue == "25.00 second@example.test")
        let zero = QuotaMetric(id: "zero", label: "Zero", value: 0, unit: "first@example.test", format: "integer")
        #expect(MetricPresentation(metric: zero, maskEmail: true).formattedValue == "0 fi***t@example.test")
        #expect(MetricPresentation(metric: zero, maskEmail: false).formattedValue == "0 first@example.test")
        let unknown = QuotaMetric(id: "unknown", label: "Unknown", value: nil, unit: "first@example.test")
        #expect(MetricPresentation(metric: unknown, maskEmail: true).formattedValue == "数值未知")
    }

    @Test func diagnosticsUseTheSameMaskedFreeTextAsQuotaCards() {
        let title = "主要账号 first@example.test / second@example.test"
        let account = CPAAccount(id: "a", authIndex: "fixture", provider: "codex", displayName: title)
        let presentation = AccountDiagnosticPresentation(account: account, error: nil, maskEmail: true)
        #expect(presentation.displayName == QuotaFormatter.maskEmails(in: title, enabled: true))
        #expect(!presentation.displayName.contains("first@example.test"))
        #expect(!presentation.displayName.contains("second@example.test"))
    }
}
