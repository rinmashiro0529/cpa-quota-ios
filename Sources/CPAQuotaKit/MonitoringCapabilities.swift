import Foundation

/// Authenticated, read-only discovery. It proves this token's current service
/// authorization, not upstream health, an APNs delivery, or a capacity reservation.
public struct MonitoringCapabilities: Decodable, Equatable, Sendable {
    public struct Account: Decodable, Equatable, Sendable, Identifiable {
        public let id: String
        public let safeID: String
        public let label: String
        public let provider: String
        public let windowID: String
        public let windowLabel: String

        enum CodingKeys: String, CodingKey {
            case id, label, provider
            case safeID = "safe_id", windowID = "window_id", windowLabel = "window_label"
        }
    }

    public struct Source: Decodable, Equatable, Sendable, Identifiable {
        public let id: String
        public let accounts: [Account]
    }

    public struct Capacity: Decodable, Equatable, Sendable {
        public enum Status: String, Decodable, Sendable { case ok, warning, exhausted }
        public let limit: Int
        public let used: Int
        public let remaining: Int
        public let warningAt: Int
        public let status: Status
        public let canCreateSession: Bool
        public let canRecordCancellation: Bool

        enum CodingKeys: String, CodingKey {
            case limit, used, remaining, status
            case warningAt = "warning_at"
            case canCreateSession = "can_create_session"
            case canRecordCancellation = "can_record_cancellation"
        }
    }

    public let version: Int
    public let generatedAt: Date
    public let sources: [Source]
    public let capacity: Capacity

    enum CodingKeys: String, CodingKey {
        case version, sources, capacity
        case generatedAt = "generated_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        let timestamp = try c.decode(Double.self, forKey: .generatedAt)
        sources = try c.decode([Source].self, forKey: .sources)
        capacity = try c.decode(Capacity.self, forKey: .capacity)
        guard version == 1, timestamp.isFinite, timestamp > 0, timestamp < 253_402_300_800,
              timestamp.rounded(.towardZero) == timestamp, (1...100).contains(sources.count),
              Set(sources.map(\.id)).count == sources.count,
              sources.allSatisfy({ source in
                  MonitoringIdentifier.valid(source.id)
                    && (1...100).contains(source.accounts.count)
                    && Set(source.accounts.map(\.id)).count == source.accounts.count
                    && Set(source.accounts.map(\.safeID)).count == source.accounts.count
                    && source.accounts.allSatisfy { account in
                        MonitoringIdentifier.validAccount(account.id)
                            && MonitoringIdentifier.valid(account.safeID)
                            && Self.validLabel(account.label)
                            && MonitoringIdentifier.valid(account.provider)
                            && MonitoringIdentifier.valid(account.windowID)
                            && Self.validLabel(account.windowLabel)
                    }
              }),
              capacity.limit > 0, capacity.used >= 0, capacity.remaining >= 0,
              capacity.remaining == max(0, capacity.limit - capacity.used),
              (1...capacity.limit).contains(capacity.warningAt),
              capacity.status == (capacity.used >= capacity.limit ? .exhausted
                : capacity.used >= capacity.warningAt ? .warning : .ok),
              capacity.remaining > 0 || (!capacity.canCreateSession && !capacity.canRecordCancellation) else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: c,
                                                   debugDescription: "Invalid monitoring capabilities")
        }
        generatedAt = Date(timeIntervalSince1970: timestamp)
    }

    public func authorizes(sourceID: String, accountIDs: [String]) -> Bool {
        guard (1...5).contains(accountIDs.count), Set(accountIDs).count == accountIDs.count,
              let source = sources.first(where: { $0.id == sourceID }) else { return false }
        let authorized = Set(source.accounts.map(\.id))
        return accountIDs.allSatisfy { authorized.contains($0) }
    }

    private static func validLabel(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
