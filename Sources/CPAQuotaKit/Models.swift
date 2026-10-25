import Foundation

public struct CPAAccount: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let authIndex: String?
    public let provider: String
    public let displayName: String
    public let email: String?
    public let status: String
    public let isDisabled: Bool
    public let isUnavailable: Bool
    public let supportsPluginQuota: Bool
    public let plan: String?

    public init(id: String, authIndex: String?, provider: String, displayName: String,
                email: String? = nil, status: String = "unknown", isDisabled: Bool = false,
                isUnavailable: Bool = false, supportsPluginQuota: Bool = false, plan: String? = nil) {
        self.id = id
        self.authIndex = authIndex
        self.provider = provider
        self.displayName = displayName
        self.email = email
        self.status = status
        self.isDisabled = isDisabled
        self.isUnavailable = isUnavailable
        self.supportsPluginQuota = supportsPluginQuota
        self.plan = plan
    }
}

public enum QuotaSource: String, Codable, Sendable {
    case passive
    case live
}

public struct QuotaWindow: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let durationSeconds: TimeInterval?
    public let usedFraction: Double?
    public let resetAt: Date?
    public let allowed: Bool?
    public let limitReached: Bool?

    public init(id: String, title: String, durationSeconds: TimeInterval? = nil,
                usedFraction: Double? = nil, resetAt: Date? = nil,
                allowed: Bool? = nil, limitReached: Bool? = nil) {
        self.id = id
        self.title = title
        self.durationSeconds = durationSeconds.flatMap {
            $0.isFinite && $0 > 0 && Int(exactly: $0.rounded(.towardZero)) != nil ? $0 : nil
        }
        self.usedFraction = usedFraction.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.resetAt = resetAt
        self.allowed = allowed
        self.limitReached = limitReached
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, durationSeconds, usedFraction, resetAt, allowed, limitReached
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(String.self, forKey: .id),
            title: try values.decode(String.self, forKey: .title),
            durationSeconds: try values.decodeIfPresent(Double.self, forKey: .durationSeconds),
            usedFraction: try values.decodeIfPresent(Double.self, forKey: .usedFraction),
            resetAt: try values.decodeIfPresent(Date.self, forKey: .resetAt),
            allowed: try values.decodeIfPresent(Bool.self, forKey: .allowed),
            limitReached: try values.decodeIfPresent(Bool.self, forKey: .limitReached)
        )
    }

    public var remainingFraction: Double? {
        guard let usedFraction, usedFraction.isFinite, usedFraction >= 0 else { return nil }
        return max(0, min(1, 1 - usedFraction))
    }
}

public struct QuotaMetric: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let value: Double?
    public let unit: String?
    public let format: String?
    public let currency: String?

    public init(id: String, label: String, value: Double?, unit: String? = nil,
                format: String? = nil, currency: String? = nil) {
        self.id = id
        self.label = label
        self.value = value.flatMap { $0.isFinite ? $0 : nil }
        self.unit = unit
        self.format = format
        self.currency = currency
    }
}

public struct QuotaCredits: Codable, Equatable, Sendable {
    public let hasCredits: Bool?
    public let unlimited: Bool?
    public let balance: Double?

    public init(hasCredits: Bool?, unlimited: Bool?, balance: Double?) {
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.balance = balance.flatMap { $0.isFinite ? $0 : nil }
    }
}

public struct QuotaSnapshot: Codable, Equatable, Sendable {
    public let accountID: String
    public let provider: String
    public let source: QuotaSource
    public let fetchedAt: Date
    public let observedAt: Date?
    public let plan: String?
    public let windows: [QuotaWindow]
    public let metrics: [QuotaMetric]
    public let credits: QuotaCredits?

    public init(accountID: String, provider: String, source: QuotaSource, fetchedAt: Date,
                observedAt: Date? = nil, plan: String? = nil, windows: [QuotaWindow] = [],
                metrics: [QuotaMetric] = [], credits: QuotaCredits? = nil) {
        self.accountID = accountID
        self.provider = provider
        self.source = source
        self.fetchedAt = fetchedAt
        self.observedAt = observedAt
        self.plan = plan
        self.windows = windows
        self.metrics = metrics
        self.credits = credits
    }

    public func isStale(at date: Date = Date(), maximumAge: TimeInterval = 300) -> Bool {
        guard maximumAge.isFinite, maximumAge > 0,
              let timestamp = source == .passive ? observedAt : (observedAt ?? fetchedAt) else { return true }
        let age = date.timeIntervalSince(timestamp)
        return !age.isFinite || age < -60 || age >= maximumAge
    }
}

public struct QuotaRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: String { account.id }
    public let account: CPAAccount
    public let snapshot: QuotaSnapshot?
    public let error: CPAError?

    public init(account: CPAAccount, snapshot: QuotaSnapshot? = nil, error: CPAError? = nil) {
        self.account = account
        self.snapshot = snapshot
        self.error = error
    }
}

struct AccountEntry: Sendable {
    let account: CPAAccount
    let codexAccountID: String?
    let passiveSnapshot: QuotaSnapshot?
}

struct DecodedInventory: Sendable {
    let entries: [AccountEntry]
    let observedAt: Date?
}
