import Foundation
import CPAQuotaKit

public enum FreshnessBadgeState: Equatable, Sendable {
    case liveFresh(ageText: String)
    case liveStale(ageText: String)
    case passiveFresh(ageText: String)
    case passiveStaleOrUnknown(ageText: String?)

    public var badgeText: String {
        switch self {
        case .liveFresh(let age):
            return "最近查询 · \(age)"
        case .liveStale(let age):
            return "最近查询 · 时效待确认 (\(age))"
        case .passiveFresh(let age):
            return "被动观察 · \(age)"
        case .passiveStaleOrUnknown(let age):
            if let age {
                return "被动观察 · 时效待确认 (\(age))"
            }
            return "被动观察 · 时间未知"
        }
    }

    public var isStale: Bool {
        switch self {
        case .liveFresh, .passiveFresh:
            return false
        case .liveStale, .passiveStaleOrUnknown:
            return true
        }
    }
}

public struct WindowPresentation: Identifiable, Equatable, Sendable {
    public static let resetDisclaimer = "重置时间点仅供参考，不保证到时一定恢复额度；不同额度窗口相互独立，不可相加。"

    public let id: String
    public let title: String
    public let originalTitle: String
    public let durationText: String
    public let usedFraction: Double?
    public let remainingFraction: Double?
    public let resetAt: Date?
    public let allowed: Bool?
    public let limitReached: Bool?

    public init(window: QuotaWindow) {
        self.id = window.id
        self.originalTitle = window.title
        self.title = Self.localizedWindowTitle(window.title)
        self.durationText = Self.formatDuration(window.durationSeconds)
        self.usedFraction = window.usedFraction
        self.remainingFraction = window.remainingFraction
        self.resetAt = window.resetAt
        self.allowed = window.allowed
        self.limitReached = window.limitReached
    }

    /// A percentage can report exhaustion without proving upstream enforcement.
    public var isExhausted: Bool { usedFraction.map { $0 >= 1.0 } ?? false }

    public var isExplicitlyLimited: Bool { limitReached == true || allowed == false }

    public var isOverQuota: Bool { isExhausted || isExplicitlyLimited }

    public var statusText: String? {
        if isExplicitlyLimited { return "上游已限制使用" }
        if isExhausted { return "读数已用完" }
        if isLowRemainingWarning { return "剩余额度偏低" }
        return nil
    }

    public var enforcementExplanation: String? {
        guard isExhausted, !isExplicitlyLimited else { return nil }
        return "当前比例读数已用完；是否仍可使用以上游实际响应为准。"
    }

    private static func localizedWindowTitle(_ raw: String) -> String {
        // Match only known built-in labels. Unrecognized plugin labels stay intact.
        switch raw {
        case "5-hour limit": "5 小时额度"
        case "7-day limit": "7 天额度"
        case "Monthly limit": "月度额度"
        case "Code review · 5-hour limit": "代码审查 · 5 小时额度"
        case "Code review · 7-day limit": "代码审查 · 7 天额度"
        default: raw
        }
    }

    public var isLowRemainingWarning: Bool {
        guard !isOverQuota, let remainingFraction else { return false }
        return remainingFraction <= 0.20
    }

    public func primaryPercentageText(for mode: QuotaDisplayMode) -> String {
        switch mode {
        case .remaining:
            guard let remainingFraction else { return "剩余比例未知" }
            return "\(Self.formatPercentage(remainingFraction))% 剩余"
        case .used:
            guard let usedFraction else { return "已用比例未知" }
            return "\(Self.formatPercentage(usedFraction))% 已用"
        }
    }

    public var secondaryComparisonText: String {
        switch (usedFraction, remainingFraction) {
        case (.some(let used), .some(let remaining)):
            return "已用 \(Self.formatPercentage(used))% · 剩余 \(Self.formatPercentage(remaining))%"
        case (.some(let used), .none):
            return "已用 \(Self.formatPercentage(used))% · 剩余未知"
        case (.none, .some(let remaining)):
            return "已用未知 · 剩余 \(Self.formatPercentage(remaining))%"
        case (.none, .none):
            return "已用与剩余比例均未知"
        }
    }

    private static func formatPercentage(_ fraction: Double) -> String {
        let percentage = (fraction * 100).rounded()
        if percentage.isFinite {
            guard percentage < Double(Int.max) else {
                return String(format: "%.0e", percentage)
            }
            return String(Int(percentage))
        }

        let scientific = String(format: "%.0e", fraction).split(separator: "e")
        guard scientific.count == 2, let exponent = Int(scientific[1]) else {
            return String(format: "%.0e", fraction)
        }
        return "\(scientific[0])e+\(exponent + 2)"
    }

    public func progressBarFraction(for mode: QuotaDisplayMode) -> Double? {
        switch mode {
        case .remaining:
            guard let remainingFraction else { return nil }
            return max(0.0, min(1.0, remainingFraction))
        case .used:
            guard let usedFraction else { return nil }
            return max(0.0, min(1.0, usedFraction))
        }
    }

    public func resetTimeText(timeZone: TimeZone = .current) -> String {
        guard let resetAt, QuotaTime.isSupported(resetAt) else { return "重置时间点未知" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MM-dd HH:mm"
        return "重置时间： \(formatter.string(from: resetAt))"
    }

    public static func formatDuration(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else {
            return "窗口长度未知"
        }
        guard let whole = Int(exactly: seconds.rounded(.towardZero)), whole > 0 else { return "窗口长度未知" }
        if whole % 86_400 == 0 {
            return "\(whole / 86_400) 天窗口 (\(whole)s)"
        }
        if whole % 3_600 == 0 {
            return "\(whole / 3_600) 小时窗口 (\(whole)s)"
        }
        if whole % 60 == 0 {
            return "\(whole / 60) 分钟窗口 (\(whole)s)"
        }
        return "\(whole) 秒窗口"
    }
}

public struct MetricPresentation: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let formattedValue: String

    public init(metric: QuotaMetric) {
        self.init(metric: metric, maskEmail: false)
    }

    public init(metric: QuotaMetric, maskEmail: Bool) {
        self.id = metric.id
        self.label = QuotaFormatter.maskEmails(in: metric.label, enabled: maskEmail)
        self.formattedValue = QuotaFormatter.maskEmails(in: Self.formatValue(
            value: metric.value,
            unit: metric.unit,
            format: metric.format,
            currency: metric.currency
        ), enabled: maskEmail)
    }

    public static func formatValue(
        value: Double?,
        unit: String?,
        format: String?,
        currency: String?
    ) -> String {
        guard let value, value.isFinite else {
            return "数值未知"
        }
        let trimmedCurrency = currency?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedCurrency, !trimmedCurrency.isEmpty {
            return String(format: "%.2f %@", value, trimmedCurrency)
        }
        let numberPart: String
        if format?.lowercased() == "integer" || value.rounded() == value {
            numberPart = String(format: "%.0f", value)
        } else {
            numberPart = String(format: "%.2f", value)
        }
        let trimmedUnit = unit?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedUnit, !trimmedUnit.isEmpty {
            return "\(numberPart) \(trimmedUnit)"
        }
        return numberPart
    }
}

public struct CreditsPresentation: Equatable, Sendable {
    public let title: String
    public let valueText: String
    public let footnote: String

    public init?(credits: QuotaCredits?) {
        guard let credits else { return nil }
        if credits.unlimited == true {
            self.title = "额外额度"
            self.valueText = "不限额 (Unlimited)"
            self.footnote = "独立于订阅窗口比例，不直接折算为百分比。"
        } else if let balance = credits.balance, balance.isFinite {
            self.title = "额外额度余额"
            self.valueText = String(format: "%.2f (上游原单位)", balance)
            self.footnote = "附加额度不等于订阅可用百分比，且原单位不预设为美元。"
        } else if credits.hasCredits == true {
            self.title = "额外额度"
            self.valueText = "已启用 · 余额数值未知"
            self.footnote = "上游声明拥有 Credits，但未返回具体余额数值。"
        } else if credits.hasCredits == false {
            self.title = "额外额度"
            self.valueText = "无额外额度"
            self.footnote = "当前账号仅使用主订阅窗口或摘要配额。"
        } else {
            return nil
        }
    }
}

/// List-level status choices keep unknown reads separate from zero remaining.
public enum QuotaAccountStatusFilter: String, CaseIterable, Identifiable, Sendable {
    case all, lowQuota, failed, pending

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .all: "全部状态"
        case .lowQuota: "额度偏低"
        case .failed: "读取异常"
        case .pending: "尚未读取"
        }
    }

    public func matches(_ account: CPAAccount, record: QuotaRecord?) -> Bool {
        switch self {
        case .all: true
        case .lowQuota: AccountQuotaSummary(record: record).hasLowQuota
        case .failed: record?.error != nil || account.isUnavailable
        case .pending: !account.isDisabled && record?.snapshot == nil && record?.error == nil
        }
    }
}

/// A compact account row shows one independent window, never a sum across windows.
public struct AccountQuotaSummary: Equatable, Sendable {
    public let window: WindowPresentation?
    public let windowCount: Int
    public let knownWindowCount: Int
    public let hasLowQuota: Bool

    public init(record: QuotaRecord?) {
        let windows = record?.snapshot?.windows.map(WindowPresentation.init) ?? []
        let known = windows.filter { $0.remainingFraction != nil }
        self.window = known.min { ($0.remainingFraction ?? 1) < ($1.remainingFraction ?? 1) } ?? windows.first
        self.windowCount = windows.count
        self.knownWindowCount = known.count
        self.hasLowQuota = windows.contains { $0.isOverQuota || $0.isLowRemainingWarning }
    }

    public var selectionText: String? {
        guard windowCount > 1 else { return nil }
        if knownWindowCount == 0 { return "共 \(windowCount) 个窗口，比例均未知" }
        if knownWindowCount < windowCount {
            return "已知窗口中的最低剩余；另有 \(windowCount - knownWindowCount) 个窗口比例未知"
        }
        return "\(windowCount) 个独立窗口中的最低剩余"
    }
}

public struct QuotaOverviewSummary: Equatable, Sendable {
    public let accountCount: Int
    public let snapshotCount: Int
    public let lowQuotaCount: Int
    public let failedCount: Int
    public let pendingCount: Int

    public init(accounts: [CPAAccount], records: [String: QuotaRecord]) {
        self.accountCount = accounts.count
        self.snapshotCount = accounts.filter { records[$0.id]?.snapshot != nil }.count
        self.lowQuotaCount = accounts.filter { QuotaAccountStatusFilter.lowQuota.matches($0, record: records[$0.id]) }.count
        self.failedCount = accounts.filter { QuotaAccountStatusFilter.failed.matches($0, record: records[$0.id]) }.count
        self.pendingCount = accounts.filter { QuotaAccountStatusFilter.pending.matches($0, record: records[$0.id]) }.count
    }
}

public enum QuotaFormatter {
    public static func freshnessBadge(
        for snapshot: QuotaSnapshot,
        now: Date = Date(),
        maximumAge: TimeInterval = 300
    ) -> FreshnessBadgeState {
        let stale = snapshot.isStale(at: now, maximumAge: maximumAge)
        switch snapshot.source {
        case .live:
            let reference = snapshot.observedAt ?? snapshot.fetchedAt
            let ageText = relativeAgeString(from: reference, to: now)
            return stale ? .liveStale(ageText: ageText) : .liveFresh(ageText: ageText)
        case .passive:
            guard let observedAt = snapshot.observedAt else {
                return .passiveStaleOrUnknown(ageText: nil)
            }
            let ageText = relativeAgeString(from: observedAt, to: now)
            return stale ? .passiveStaleOrUnknown(ageText: ageText) : .passiveFresh(ageText: ageText)
        }
    }

    public static func relativeAgeString(from date: Date, to now: Date = Date()) -> String {
        guard QuotaTime.isSupported(date), QuotaTime.isSupported(now),
              let delta = Int(exactly: now.timeIntervalSince(date).rounded()) else {
            return "时间偏移异常"
        }
        if delta < -60 {
            return "时间偏移异常"
        }
        if delta <= 5 {
            return "刚刚"
        }
        if delta < 60 {
            return "\(delta) 秒前"
        }
        if delta < 3_600 {
            return "\(delta / 60) 分钟前"
        }
        if delta < 86_400 {
            return "\(delta / 3_600) 小时前"
        }
        return "\(delta / 86_400) 天前"
    }

    public static func exactTimestampString(_ date: Date?, timeZone: TimeZone = .current) -> String {
        guard let date, QuotaTime.isSupported(date) else { return "时间未知" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// Mask a dedicated email field. Nonstandard input is processed as free text
    /// so a server-provided display label can never disable privacy redaction.
    public static func maskEmail(_ email: String?, enabled: Bool) -> String {
        guard let raw = email?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return "未提供邮箱标识"
        }
        return maskEmails(in: raw, enabled: enabled)
    }

    /// Shared display/accessibility policy for CPA, CAP and diagnostic labels.
    /// Match each local part independently, including Unicode and malformed
    /// addresses with a missing domain or repeated @. Ordinary text is unchanged.
    public static func maskEmails(in value: String, enabled: Bool) -> String {
        guard enabled else { return value }
        let pattern = #"(?:"[^"\r\n]*"|[\p{L}\p{N}\p{M}._%+!#$&'*=/^`{|}~\-]+)[@＠]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return value.contains("@") || value.contains("＠") ? "邮箱标识已隐藏" : value
        }
        let result = NSMutableString(string: value)
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            let matched = (value as NSString).substring(with: match.range)
            let separator = matched.suffix(1)
            let local = String(matched.dropLast())
            let replacement: String
            if local.count <= 1 {
                replacement = "***"
            } else if local.count <= 2 {
                replacement = "\(local.prefix(1))***"
            } else {
                replacement = "\(local.prefix(2))***\(local.suffix(1))"
            }
            result.replaceCharacters(in: match.range, with: "\(replacement)\(separator)")
        }
        return result as String
    }
}
