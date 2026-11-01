import Foundation
import CPAQuotaKit
import CPAQuotaActivity

/// Publishes a privacy-limited read model. The account-to-UUID map stays in app-private preferences.
@MainActor
public final class QuotaWidgetPublisher {
    private let store: any QuotaWidgetSnapshotWriting
    private let preferences: any PreferencesStore
    private var sourceIdentifier: String?
    private var opaqueIdentifiers: [String: String] = [:]
    private var aliases: [String: Int] = [:]

    var publishedAliases: [String: String] {
        var result: [String: String] = [:]
        for (identity, uuid) in opaqueIdentifiers {
            if let number = aliases[uuid] { result[identity] = "账号 \(number)" }
        }
        return result
    }

    static func identity(for account: CPAAccount) throws -> String {
        let components: [String?] = [account.id, account.provider, account.authIndex]
        return String(decoding: try JSONEncoder().encode(components), as: UTF8.self)
    }

    public init(store: any QuotaWidgetSnapshotWriting = SharedQuotaWidgetSnapshotStore(),
                preferences: any PreferencesStore = UserDefaultsPreferencesStore()) {
        self.store = store
        self.preferences = preferences
    }

    public func publish(
        sourceIdentifier: String, accounts: [CPAAccount], records: [String: QuotaRecord],
        now: Date = Date()
    ) throws {
        if self.sourceIdentifier != sourceIdentifier {
            do {
                try store.clear()
            } catch {
                throw QuotaWidgetSnapshotError.previousSnapshotClearFailed
            }
            opaqueIdentifiers = preferences.loadWidgetAccountIdentifiers(for: sourceIdentifier)
                .filter { UUID(uuidString: $0.value) != nil }
            aliases = preferences.loadWidgetAccountAliases(for: sourceIdentifier)
            self.sourceIdentifier = sourceIdentifier
        }
        let previousIdentifiers = opaqueIdentifiers
        let previousAliases = aliases
        do {
            let snapshot = try projection(accounts: accounts, records: records, now: now)
            try store.write(snapshot)
        } catch {
            opaqueIdentifiers = previousIdentifiers
            aliases = previousAliases
            throw error
        }
        preferences.saveWidgetAccountIdentifiers(opaqueIdentifiers, aliases: aliases, for: sourceIdentifier)
    }

    public func clear() throws {
        try store.clear()
    }

    public func forgetIdentity() {
        preferences.clearWidgetAccountIdentifiers()
        opaqueIdentifiers.removeAll()
        aliases.removeAll()
        sourceIdentifier = nil
    }

    /// Only fixed display vocabulary crosses into the shared container. Server labels, URLs,
    /// account IDs, auth indexes, emails, management keys and raw errors are never copied.
    func projection(
        accounts: [CPAAccount], records: [String: QuotaRecord], now: Date
    ) throws -> QuotaWidgetSnapshot {
        let visible = try accounts.prefix(QuotaWidgetSnapshot.maximumEntries).map { account in
            // An ordered JSON array distinguishes nil from an empty index and cannot collide
            // through delimiters in server-provided values. This key stays app-private.
            let identity = try Self.identity(for: account)
            return (account: account, identity: identity)
        }
        let retainedIDs = Set(visible.map(\.identity))
        opaqueIdentifiers = opaqueIdentifiers.filter { retainedIDs.contains($0.key) }
        for item in visible where opaqueIdentifiers[item.identity] == nil {
            opaqueIdentifiers[item.identity] = UUID().uuidString
        }
        let retainedUUIDs = Set(opaqueIdentifiers.values)
        var used = Set<Int>()
        var validAliases: [String: Int] = [:]
        for uuid in retainedUUIDs.sorted() {
            if let number = aliases[uuid], (1...QuotaWidgetSnapshot.maximumEntries).contains(number), used.insert(number).inserted {
                validAliases[uuid] = number
            }
        }
        for item in visible {
            guard let uuid = opaqueIdentifiers[item.identity], validAliases[uuid] == nil,
                  let number = (1...QuotaWidgetSnapshot.maximumEntries).first(where: { !used.contains($0) }) else { continue }
            validAliases[uuid] = number
            used.insert(number)
        }
        aliases = validAliases
        let entries = try visible.map { item in
            let account = item.account
            let opaqueID = opaqueIdentifiers[item.identity]!
            let alias = aliases[opaqueID]!
            let record = records[account.id].flatMap { candidate in
                candidate.account.provider == account.provider
                    && candidate.account.authIndex == account.authIndex ? candidate : nil
            }
            let snapshot = record?.snapshot
            let freshness = QuotaFreshness(snapshot: snapshot, now: now)
            let window = snapshot?.windows.first
            let metric = window == nil ? snapshot?.metrics.first : nil
            let status: QuotaWidgetEntry.Status
            if account.isDisabled || account.isUnavailable {
                status = .unavailable
            } else if record?.error != nil {
                status = .failed
            } else {
                switch freshness.state {
                case .fresh: status = .ready
                case .stale: status = .stale
                case .unknown: status = .unavailable
                }
            }
            return try QuotaWidgetEntry(
                id: opaqueID,
                label: "账号 \(alias)",
                provider: Self.providerLabel(account.provider),
                windowLabel: Self.windowLabel(window, hasMetric: metric != nil),
                remainingFraction: window?.remainingFraction,
                value: metric?.value,
                unit: Self.safeUnit(metric?.unit),
                observedAt: freshness.observedAt,
                status: status
            )
        }
        return try QuotaWidgetSnapshot(generatedAt: now, entries: entries)
    }

    private static func providerLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "codex": "Codex"
        case "openai": "OpenAI"
        case "claude", "anthropic": "Claude"
        case "gemini": "Gemini"
        case "antigravity": "Antigravity"
        case "qwen": "Qwen"
        case "iflow": "iFlow"
        case "kiro": "Kiro"
        case "copilot": "Copilot"
        default: "其他提供方"
        }
    }

    private static func windowLabel(_ window: QuotaWindow?, hasMetric: Bool) -> String {
        guard let duration = window?.durationSeconds else {
            return hasMetric ? "首项额度指标" : "主要额度窗口"
        }
        if duration.truncatingRemainder(dividingBy: 86_400) == 0 {
            return "\(Int(duration / 86_400)) 天窗口"
        }
        if duration.truncatingRemainder(dividingBy: 3_600) == 0 {
            return "\(Int(duration / 3_600)) 小时窗口"
        }
        return "主要额度窗口"
    }

    private static func safeUnit(_ raw: String?) -> String? {
        guard let raw else { return nil }
        switch raw.lowercased() {
        case "usd": return "USD"
        case "cny": return "CNY"
        case "eur": return "EUR"
        case "requests", "request": return "requests"
        case "tokens", "token": return "tokens"
        case "credits", "credit": return "credits"
        case "%", "percent": return "%"
        default: return nil
        }
    }
}
