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
            return "实时查询 · \(age)"
        case .liveStale(let age):
            return "实时查询 · 陈旧 (\(age))"
        case .passiveFresh(let age):
            return "被动观察 · \(age)"
        case .passiveStaleOrUnknown(let age):
            if let age {
                return "被动观察 · 陈旧 (\(age))"
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
    public let durationText: String
    public let usedFraction: Double?
    public let remainingFraction: Double?
    public let resetAt: Date?
    public let allowed: Bool?
    public let limitReached: Bool?

    public init(window: QuotaWindow) {
        self.id = window.id
        self.title = window.title
        self.durationText = Self.formatDuration(window.durationSeconds)
        self.usedFraction = window.usedFraction
        self.remainingFraction = window.remainingFraction
        self.resetAt = window.resetAt
        self.allowed = window.allowed
        self.limitReached = window.limitReached
    }

    public var isOverQuota: Bool {
        if let usedFraction, usedFraction > 1.0 { return true }
        if limitReached == true { return true }
        if allowed == false { return true }
        return false
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
        guard let resetAt else { return "重置时间点未知" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MM-dd HH:mm"
        return "重置时间点: \(formatter.string(from: resetAt))"
    }

    public static func formatDuration(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else {
            return "窗口长度未知"
        }
        let whole = Int(seconds.rounded(.towardZero))
        guard whole > 0 else { return "窗口长度未知" }
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
        self.id = metric.id
        self.label = metric.label
        self.formattedValue = Self.formatValue(
            value: metric.value,
            unit: metric.unit,
            format: metric.format,
            currency: metric.currency
        )
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
            self.title = "附加 Credits 状态"
            self.valueText = "不限额 (Unlimited)"
            self.footnote = "独立于订阅窗口比例，不直接折算为百分比。"
        } else if let balance = credits.balance, balance.isFinite {
            self.title = "附加 Credits 余额"
            self.valueText = String(format: "%.2f (上游原单位)", balance)
            self.footnote = "附加额度不等于订阅可用百分比，且原单位不预设为美元。"
        } else if credits.hasCredits == true {
            self.title = "附加 Credits 状态"
            self.valueText = "已启用 · 余额数值未知"
            self.footnote = "上游声明拥有 Credits，但未返回具体余额数值。"
        } else if credits.hasCredits == false {
            self.title = "附加 Credits 状态"
            self.valueText = "无额外 Credits"
            self.footnote = "当前账号仅使用主订阅窗口或摘要配额。"
        } else {
            return nil
        }
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
        let delta = Int(now.timeIntervalSince(date).rounded())
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
        guard let date else { return "时间未知" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    public static func maskEmail(_ email: String?, enabled: Bool) -> String {
        guard let raw = email?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return "未提供邮箱标识"
        }
        guard enabled else { return raw }
        let parts = raw.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return raw }
        let name = String(parts[0])
        let domain = String(parts[1])
        if name.count <= 2 {
            let prefix = name.prefix(1)
            return "\(prefix)***@\(domain)"
        }
        let prefix = name.prefix(2)
        let suffix = name.suffix(1)
        return "\(prefix)***\(suffix)@\(domain)"
    }
}
