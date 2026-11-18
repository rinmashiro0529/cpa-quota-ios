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

@Suite("Time presentation boundaries")
struct TimePresentationBoundaryTests {
    @Test func invalidDurationsRemainUnknownInsteadOfTrapping() {
        for value in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, Double(Int.max), -1, 0] {
            #expect(WindowPresentation.formatDuration(value) == "窗口长度未知")
        }
        #expect(WindowPresentation.formatDuration(3600) == "1 小时窗口 (3600s)")
    }

    @Test func invalidInstantsNeverLookFreshOrReachDateFormatter() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for seconds in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -62_135_596_801, 253_402_300_800] {
            let date = Date(timeIntervalSince1970: seconds)
            #expect(QuotaFormatter.relativeAgeString(from: date, to: now) == "时间偏移异常")
            #expect(QuotaFormatter.exactTimestampString(date) == "时间未知")
            #expect(QuotaTime.remainingSeconds(until: date, now: now) == nil)
            let error = ErrorPresentation(error: CPAError(.rateLimited, retryAfter: date))
            #expect(error.remainingCooldownSeconds(at: now) == nil)
        }
    }

    @Test func countdownKeepsRoundingAndUnknownSeparateFromExpired() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(QuotaTime.remainingSeconds(until: now.addingTimeInterval(0.1), now: now) == 1)
        #expect(QuotaTime.remainingSeconds(until: now, now: now) == 0)
        #expect(QuotaTime.remainingSeconds(until: now.addingTimeInterval(-5), now: now) == 0)
        #expect(QuotaTime.remainingSeconds(until: now, now: Date(timeIntervalSince1970: .infinity)) == nil)
        #expect(QuotaTime.isSupported(Date(timeIntervalSince1970: -62_135_596_800)))
        #expect(QuotaTime.isSupported(Date(timeIntervalSince1970: 253_402_300_799)))
        #expect(QuotaFormatter.relativeAgeString(from: now.addingTimeInterval(-300), to: now) == "5 分钟前")
    }

    @MainActor
    @Test func expiredCAPCooldownDoesNotClaimFreshData() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let result = CAPUsagePresentation.errorDescription(.resourceRejected(statusCode: 429, retryAt: now.addingTimeInterval(-1)), now: now)
        #expect(result.detail.contains("等待重试验证"))
        #expect(!result.detail.contains("0 秒"))
        let presentation = ConnectionStatusPresentation(phase: .connectionFailed(kind: .rateLimited), isExpanded: false)
        #expect(presentation.connectionPageText == "限流后待验证")
    }
}

@Suite("Codex home card regular window selection")
struct CodexHomeWindowSelectionTests {
    private func codexRecord(_ windows: [QuotaWindow], source: QuotaSource = .live) -> QuotaRecord {
        let account = CPAAccount(id: "codex-1", authIndex: "index-1", provider: "codex", displayName: "Fixture")
        return QuotaRecord(account: account, snapshot: QuotaSnapshot(
            accountID: account.id, provider: account.provider, source: source,
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000), windows: windows))
    }

    @Test func bothRegularWindowsAppearInFiveHourThenSevenDayOrder() {
        let record = codexRecord([
            QuotaWindow(id: "primary", title: "5-hour limit", durationSeconds: 18_000, usedFraction: 0.58),
            QuotaWindow(id: "secondary", title: "7-day limit", durationSeconds: 604_800, usedFraction: 0.09)
        ])
        let selection = CodexRegularWindowSelection.select(from: record)
        #expect(selection != nil)
        let entries = selection?.entries ?? []
        #expect(entries.map(\.slot) == [.fiveHour, .sevenDay])
        #expect(entries[0].window.primaryPercentageText(for: .remaining) == "42% 剩余")
        #expect(entries[1].window.primaryPercentageText(for: .remaining) == "91% 剩余")
    }

    @Test func sevenDayWindowKeepsItsOrderEvenWhenItIsThePrimaryId() {
        let record = codexRecord([
            QuotaWindow(id: "primary", title: "7-day limit", durationSeconds: 604_800, usedFraction: 0.09),
            QuotaWindow(id: "secondary", title: "5-hour limit", durationSeconds: 18_000, usedFraction: 0.58)
        ])
        let entries = CodexRegularWindowSelection.select(from: record)?.entries ?? []
        #expect(entries.map(\.slot) == [.fiveHour, .sevenDay])
        #expect(entries[0].window.id == "secondary")
    }

    @Test(arguments: [CodexRegularWindowSlot.sevenDay, .fiveHour])
    func singleRegularWindowShowsOnlyItsOwnRow(_ slot: CodexRegularWindowSlot) {
        let window = QuotaWindow(id: slot == .sevenDay ? "secondary" : "primary",
                                 title: slot == .sevenDay ? "7-day limit" : "5-hour limit",
                                 durationSeconds: slot.durationSeconds, usedFraction: 0.3)
        let entries = CodexRegularWindowSelection.select(from: codexRecord([window]))?.entries ?? []
        #expect(entries.map(\.slot) == [slot])
    }

    @Test func auxiliaryAndMonthlyWindowsNeverSatisfyTheRegularContract() {
        let record = codexRecord([
            QuotaWindow(id: "code-review-primary", title: "Code review · 5-hour limit", durationSeconds: 18_000, usedFraction: 0.9),
            QuotaWindow(id: "code-review-secondary", title: "Code review · 7-day limit", durationSeconds: 604_800, usedFraction: 0.9),
            QuotaWindow(id: "gpt-5-codex-1-primary", title: "5-hour limit", durationSeconds: 18_000, usedFraction: 0.9),
            QuotaWindow(id: "primary", title: "Monthly limit", durationSeconds: 2_592_000, usedFraction: 0.5),
            QuotaWindow(id: "primary", title: "5-hour limit", durationSeconds: 17_999, usedFraction: 0.5)
        ])
        let selection = CodexRegularWindowSelection.select(from: record)
        #expect(selection?.entries.isEmpty == true)
        // The provider-agnostic fallback keeps describing the same snapshot.
        let summary = AccountQuotaSummary(record: record)
        #expect(summary.window?.id == "code-review-primary")
        #expect(summary.hasLowQuota)
    }

    @Test func hiddenWindowWarningsStayVisibleOnTheRegularCard() {
        let healthy = QuotaWindow(id: "primary", title: "5-hour limit", durationSeconds: 18_000, usedFraction: 0.58)
        let depleted = QuotaWindow(id: "code-review-primary", title: "Code review · 5-hour limit", durationSeconds: 18_000, usedFraction: 1)
        let limited = QuotaWindow(id: "model-primary", title: "Model limit", durationSeconds: 18_000, allowed: false)
        let shownLow = QuotaWindow(id: "secondary", title: "7-day limit", durationSeconds: 604_800, usedFraction: 0.95)
        for auxiliary in [depleted, limited] {
            let record = codexRecord([healthy, auxiliary])
            #expect(AccountQuotaSummary(record: record).hasLowQuota)
            let selection = CodexRegularWindowSelection.select(from: record)
            #expect(selection?.entries.map(\.slot) == [.fiveHour])
            #expect(selection?.hasHiddenLowQuota == true)
        }
        let shownOnly = CodexRegularWindowSelection.select(from: codexRecord([healthy, shownLow]))
        #expect(shownOnly?.hasHiddenLowQuota == false)
    }

    @Test func duplicateDurationsPreferKnownRatioThenPrimaryId() {
        let unknownPrimary = QuotaWindow(id: "primary", title: "5-hour limit", durationSeconds: 18_000)
        let knownSecondary = QuotaWindow(id: "secondary", title: "5-hour limit", durationSeconds: 18_000, usedFraction: 0.3)
        let entries = CodexRegularWindowSelection.select(from: codexRecord([unknownPrimary, knownSecondary]))?.entries ?? []
        #expect(entries.map(\.window.id) == ["secondary"])

        let knownPrimary = QuotaWindow(id: "primary", title: "5-hour limit", durationSeconds: 18_000, usedFraction: 0.2)
        let unknownSecondary = QuotaWindow(id: "secondary", title: "5-hour limit", durationSeconds: 18_000)
        let reordered = CodexRegularWindowSelection.select(from: codexRecord([knownPrimary, unknownSecondary]))?.entries ?? []
        #expect(reordered.map(\.window.id) == ["primary"])

        // With ratios on both sides, the primary id wins independent of order.
        let bothKnown = CodexRegularWindowSelection.select(from: codexRecord([unknownSecondary, knownPrimary]))?.entries ?? []
        #expect(bothKnown.map(\.window.id) == ["primary"])
    }

    @Test func unknownRatiosStayUnknownWithoutAZeroBar() {
        let record = codexRecord([
            QuotaWindow(id: "primary", title: "5-hour limit", durationSeconds: 18_000),
            QuotaWindow(id: "secondary", title: "7-day limit", durationSeconds: 604_800)
        ])
        let entries = CodexRegularWindowSelection.select(from: record)?.entries ?? []
        #expect(entries.count == 2)
        for entry in entries {
            #expect(entry.window.primaryPercentageText(for: .remaining) == "剩余比例未知")
            #expect(entry.window.progressBarFraction(for: .remaining) == nil)
            #expect(entry.window.progressBarFraction(for: .used) == nil)
            #expect(!entry.window.isOverQuota)
        }
    }

    @Test func realZeroUsageAndOverQuotaWarningsSurvivePerWindow() {
        let record = codexRecord([
            QuotaWindow(id: "primary", title: "5-hour limit", durationSeconds: 18_000, usedFraction: 0,
                        allowed: false, limitReached: true),
            QuotaWindow(id: "secondary", title: "7-day limit", durationSeconds: 604_800, usedFraction: 1.0)
        ])
        let entries = CodexRegularWindowSelection.select(from: record)?.entries ?? []
        #expect(entries[0].window.primaryPercentageText(for: .remaining) == "100% 剩余")
        #expect(entries[0].window.progressBarFraction(for: .remaining) == 1.0)
        #expect(entries[0].window.statusText == "上游已限制使用")
        #expect(entries[1].window.primaryPercentageText(for: .used) == "100% 已用")
        #expect(entries[1].window.statusText == "读数已用完")
    }

    @Test(arguments: ["codex", "Codex", " codex "])
    func codexProviderIsMatchedCaseInsensitivelyAfterTrimming(_ provider: String) {
        let account = CPAAccount(id: "c", authIndex: "i", provider: provider, displayName: "Fixture")
        let record = QuotaRecord(account: account, snapshot: QuotaSnapshot(
            accountID: account.id, provider: account.provider, source: .live, fetchedAt: Date(),
            windows: [QuotaWindow(id: "primary", title: "5-hour limit", durationSeconds: 18_000, usedFraction: 0.5)]))
        #expect(CodexRegularWindowSelection.select(from: record)?.entries.count == 1)
    }

    @Test func nonCodexProvidersKeepTheProviderAgnosticCard() {
        let account = CPAAccount(id: "p", authIndex: "i", provider: "freetier", displayName: "Fixture")
        let record = QuotaRecord(account: account, snapshot: QuotaSnapshot(
            accountID: account.id, provider: account.provider, source: .live, fetchedAt: Date(),
            windows: [QuotaWindow(id: "primary", title: "5-hour limit", durationSeconds: 18_000, usedFraction: 0.5)]))
        #expect(CodexRegularWindowSelection.select(from: record) == nil)
        #expect(AccountQuotaSummary(record: record).window?.id == "primary")
    }

    @Test func passiveRegularWindowsAreSelectedToo() {
        let record = codexRecord([
            QuotaWindow(id: "primary", title: "5-hour limit", durationSeconds: 18_000, usedFraction: 0.47),
            QuotaWindow(id: "secondary", title: "7-day limit", durationSeconds: 604_800, usedFraction: 0.07)
        ], source: .passive)
        let entries = CodexRegularWindowSelection.select(from: record)?.entries ?? []
        #expect(entries.map(\.slot) == [.fiveHour, .sevenDay])
        #expect(entries[1].window.primaryPercentageText(for: .remaining) == "93% 剩余")
    }
}
