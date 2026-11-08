import Foundation

public struct MonitoringSession: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case active, stopped, expired }
    public enum DeliveryState: String, Codable, Sendable { case disabled, pending, sent, failed, ended }
    public let version: Int
    public let id: UUID
    public let sourceID: String
    public let accountIDs: [String]
    public let activityID: String
    public let startsAt: Double
    public let expiresAt: Double
    public let nextRefreshAt: Double?
    public let status: Status
    public let revision: UInt64
    public let snapshot: MonitoringSnapshot?
    public let deliveryState: DeliveryState

    enum CodingKeys: String, CodingKey {
        case version, id, status, revision, snapshot
        case sourceID = "source_id", accountIDs = "account_ids", activityID = "activity_id"
        case startsAt = "starts_at", expiresAt = "expires_at", nextRefreshAt = "next_refresh_at"
        case deliveryState = "delivery_state"
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(id.uuidString.lowercased(), forKey: .id)
        try c.encode(sourceID, forKey: .sourceID)
        try c.encode(accountIDs, forKey: .accountIDs)
        try c.encode(activityID, forKey: .activityID)
        try c.encode(startsAt, forKey: .startsAt)
        try c.encode(expiresAt, forKey: .expiresAt)
        try c.encodeIfPresent(nextRefreshAt, forKey: .nextRefreshAt)
        try c.encode(status, forKey: .status)
        try c.encode(revision, forKey: .revision)
        try c.encodeIfPresent(snapshot, forKey: .snapshot)
        try c.encode(deliveryState, forKey: .deliveryState)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        id = try c.decode(UUID.self, forKey: .id)
        sourceID = try c.decode(String.self, forKey: .sourceID)
        accountIDs = try c.decode([String].self, forKey: .accountIDs)
        activityID = try c.decode(String.self, forKey: .activityID)
        startsAt = try c.decode(Double.self, forKey: .startsAt)
        expiresAt = try c.decode(Double.self, forKey: .expiresAt)
        nextRefreshAt = try c.decodeIfPresent(Double.self, forKey: .nextRefreshAt)
        status = try c.decode(Status.self, forKey: .status)
        revision = try c.decode(UInt64.self, forKey: .revision)
        snapshot = try c.decodeIfPresent(MonitoringSnapshot.self, forKey: .snapshot)
        deliveryState = try c.decode(DeliveryState.self, forKey: .deliveryState)
        guard version == 1, MonitoringIdentifier.valid(sourceID), (1...5).contains(accountIDs.count),
              Set(accountIDs).count == accountIDs.count, accountIDs.allSatisfy(MonitoringIdentifier.validAccount),
              !activityID.isEmpty, activityID.utf8.count <= 256,
              !activityID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              WireDate.epochDate(startsAt) != nil, WireDate.epochDate(expiresAt) != nil,
              expiresAt > startsAt, expiresAt - startsAt <= 28800,
              nextRefreshAt.map({ WireDate.epochDate($0) != nil }) ?? true else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: c, debugDescription: "Invalid session")
        }
    }
}

enum MonitoringIdentifier {
    static func validAccount(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "_-@.".unicodeScalars.contains($0)
        }
    }
    static func valid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "_-".unicodeScalars.contains($0)
        }
    }
}

public enum MonitoringDuration: Int, Sendable { case oneHour = 3600, fourHours = 14400, eightHours = 28800 }

public struct MonitoringPushToken: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let value: String
    public init(_ value: String) throws {
        guard !value.isEmpty, value.count.isMultiple(of: 2), value.count <= 4096,
              value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }) else {
            throw MonitoringError.invalidConfiguration
        }
        self.value = value
    }
    public var description: String { "<redacted push token>" }
    public var debugDescription: String { description }
}

public struct MonitoringRegistration: Sendable {
    public let id: UUID
    public let sourceID: String
    public let accountIDs: [String]
    public let duration: MonitoringDuration
    public let activityID: String
    let pushToken: MonitoringPushToken

    public init(id: UUID, sourceID: String, accountIDs: [String], duration: MonitoringDuration,
                activityID: String, pushToken: MonitoringPushToken) throws {
        guard MonitoringIdentifier.valid(sourceID), (1...5).contains(accountIDs.count),
              Set(accountIDs).count == accountIDs.count, accountIDs.allSatisfy(MonitoringIdentifier.validAccount),
              !activityID.isEmpty, activityID.utf8.count <= 256,
              !activityID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw MonitoringError.invalidConfiguration
        }
        self.id = id; self.sourceID = sourceID; self.accountIDs = accountIDs
        self.duration = duration; self.activityID = activityID; self.pushToken = pushToken
    }
}
