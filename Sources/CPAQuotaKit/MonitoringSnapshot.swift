import Foundation

public struct MonitoringAccount: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable { case ok, stale, unavailable, failed, coolingDown = "cooling_down" }
    public let id: String
    public let label: String
    public let provider: String
    public let windowID: String
    public let windowLabel: String
    public let remainingFraction: Double?
    public let value: Double?
    public let unit: String?
    public let observedAt: Date?
    public let status: Status

    enum CodingKeys: String, CodingKey {
        case id, label, provider, value, unit, status
        case windowID = "window_id", windowLabel = "window_label"
        case remainingFraction = "remaining_fraction", observedAt = "observed_at"
    }

    public init(id: String, label: String, provider: String, windowID: String, windowLabel: String,
                remainingFraction: Double? = nil, value: Double? = nil, unit: String? = nil,
                observedAt: Date? = nil, status: Status) throws {
        guard Self.alias(id), Self.alias(provider), Self.alias(windowID),
              Self.display(label), Self.display(windowLabel), unit.map(Self.display) ?? true,
              remainingFraction.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
              value.map(\.isFinite) ?? true,
              observedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true else {
            throw MonitoringError.invalidConfiguration
        }
        self.id = id; self.label = label; self.provider = provider
        self.windowID = windowID; self.windowLabel = windowLabel
        self.remainingFraction = remainingFraction; self.value = value; self.unit = unit
        self.observedAt = observedAt; self.status = status
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        provider = try c.decode(String.self, forKey: .provider)
        windowID = try c.decode(String.self, forKey: .windowID)
        windowLabel = try c.decode(String.self, forKey: .windowLabel)
        remainingFraction = try c.decodeIfPresent(Double.self, forKey: .remainingFraction)
        value = try c.decodeIfPresent(Double.self, forKey: .value)
        unit = try c.decodeIfPresent(String.self, forKey: .unit)
        let seconds = try c.decodeIfPresent(Double.self, forKey: .observedAt)
        observedAt = seconds.map(Date.init(timeIntervalSince1970:))
        status = try c.decode(Status.self, forKey: .status)
        guard Self.alias(id), Self.alias(provider), Self.alias(windowID),
              Self.display(label), Self.display(windowLabel), unit.map(Self.display) ?? true,
              remainingFraction.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
              value.map(\.isFinite) ?? true,
              seconds.map(\.isFinite) ?? true else {
            throw DecodingError.dataCorruptedError(forKey: .label, in: c, debugDescription: "Invalid safe account")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(label, forKey: .label)
        try c.encode(provider, forKey: .provider); try c.encode(windowID, forKey: .windowID)
        try c.encode(windowLabel, forKey: .windowLabel)
        try c.encodeIfPresent(remainingFraction, forKey: .remainingFraction)
        try c.encodeIfPresent(value, forKey: .value); try c.encodeIfPresent(unit, forKey: .unit)
        try c.encodeIfPresent(observedAt?.timeIntervalSince1970, forKey: .observedAt)
        try c.encode(status, forKey: .status)
    }

    private static func alias(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 128 && text.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "_-".unicodeScalars.contains($0)
        }
    }
    private static func display(_ text: String) -> Bool {
        let lowered = text.lowercased()
        guard !text.isEmpty, text.utf8.count <= 128, !text.contains("@"), !lowered.contains("://"),
              !lowered.contains("www."), !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
        return text.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || " _-%/·.-".unicodeScalars.contains($0)
        }
    }
}

public struct MonitoringSnapshot: Codable, Sendable, Hashable {
    public enum Phase: String, Codable, Sendable { case ready, partial, failed, coolingDown = "cooling_down", stopped, expired }
    public let version: Int
    public let sequence: UInt64
    public let phase: Phase
    public let generatedAt: Date
    public let expiresAt: Date
    public let accounts: [MonitoringAccount]

    enum CodingKeys: String, CodingKey {
        case version, sequence, phase, accounts
        case generatedAt = "generated_at", expiresAt = "expires_at"
    }

    public init(sequence: UInt64, phase: Phase, generatedAt: Date, expiresAt: Date,
                accounts: [MonitoringAccount]) throws {
        guard generatedAt.timeIntervalSince1970.isFinite, expiresAt.timeIntervalSince1970.isFinite,
              (1...5).contains(accounts.count), Set(accounts.map(\.id)).count == accounts.count else {
            throw MonitoringError.invalidConfiguration
        }
        self.version = 1; self.sequence = sequence; self.phase = phase
        self.generatedAt = generatedAt; self.expiresAt = expiresAt; self.accounts = accounts
        guard try JSONEncoder().encode(self).count <= 3584 else { throw MonitoringError.invalidConfiguration }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        guard version == 1 else { throw DecodingError.dataCorruptedError(forKey: .version, in: c, debugDescription: "Unsupported version") }
        sequence = try c.decode(UInt64.self, forKey: .sequence)
        phase = try c.decode(Phase.self, forKey: .phase)
        let generated = try c.decode(Double.self, forKey: .generatedAt)
        let expires = try c.decode(Double.self, forKey: .expiresAt)
        generatedAt = Date(timeIntervalSince1970: generated)
        expiresAt = Date(timeIntervalSince1970: expires)
        accounts = try c.decode([MonitoringAccount].self, forKey: .accounts)
        guard generated.isFinite, expires.isFinite,
              (1...5).contains(accounts.count), Set(accounts.map(\.id)).count == accounts.count else {
            throw DecodingError.dataCorruptedError(forKey: .accounts, in: c, debugDescription: "Invalid snapshot")
        }
        guard try JSONEncoder().encode(self).count <= 3584 else {
            throw DecodingError.dataCorruptedError(forKey: .accounts, in: c, debugDescription: "Snapshot exceeds activity budget")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version); try c.encode(sequence, forKey: .sequence)
        try c.encode(phase, forKey: .phase); try c.encode(generatedAt.timeIntervalSince1970, forKey: .generatedAt)
        try c.encode(expiresAt.timeIntervalSince1970, forKey: .expiresAt); try c.encode(accounts, forKey: .accounts)
    }

    public func activityContentData() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= 3584 else { throw MonitoringError.invalidResponse }
        return data
    }
}
