import Foundation

public struct CAPUsageStatRow: Codable, Sendable {
    public let provider: String?
    public let model: String?
    public let hour: String?
    public let executorType: String?
    public let alias: String?
    public let source: String?
    public let authType: String?
    public let serviceTier: String?
    public let reasoningEffort: String?
    public let averageLatencyNs: UInt64?
    public let averageTtftNs: UInt64?
    public let counters: CAPUsageCounters

    private enum CodingKeys: String, CodingKey {
        case provider, model, hour, executorType, alias, source, authType, serviceTier, reasoningEffort
        case averageLatencyNs, averageTtftNs
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = try values.decodeIfPresent(String.self, forKey: .provider)
        model = try values.decodeIfPresent(String.self, forKey: .model)
        hour = try values.decodeIfPresent(String.self, forKey: .hour)
        executorType = try values.decodeIfPresent(String.self, forKey: .executorType)
        alias = try values.decodeIfPresent(String.self, forKey: .alias)
        source = try values.decodeIfPresent(String.self, forKey: .source)
        authType = try values.decodeIfPresent(String.self, forKey: .authType)
        serviceTier = try values.decodeIfPresent(String.self, forKey: .serviceTier)
        reasoningEffort = try values.decodeIfPresent(String.self, forKey: .reasoningEffort)
        averageLatencyNs = try values.decodeIfPresent(UInt64.self, forKey: .averageLatencyNs)
        averageTtftNs = try values.decodeIfPresent(UInt64.self, forKey: .averageTtftNs)
        counters = try CAPUsageCounters(from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        try counters.encode(to: encoder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(provider, forKey: .provider)
        try values.encodeIfPresent(model, forKey: .model)
        try values.encodeIfPresent(hour, forKey: .hour)
        try values.encodeIfPresent(executorType, forKey: .executorType)
        try values.encodeIfPresent(alias, forKey: .alias)
        try values.encodeIfPresent(source, forKey: .source)
        try values.encodeIfPresent(authType, forKey: .authType)
        try values.encodeIfPresent(serviceTier, forKey: .serviceTier)
        try values.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        try values.encodeIfPresent(averageLatencyNs, forKey: .averageLatencyNs)
        try values.encodeIfPresent(averageTtftNs, forKey: .averageTtftNs)
    }
}

public struct CAPUsageInitialStats: Decodable, Sendable {
    public let schemaVersion: UInt32
    public let generatedAt: String
    public let range: String
    public let retainedSince: String
    public let lastUsed: String
    public let bucketSeconds: UInt64
    public let summary: CAPUsageCounters
    public let models: [CAPUsageStatRow]
    public let series: [CAPUsageStatRow]
    public let sources: [String]
}

public struct CAPUsageTrends: Decodable, Sendable {
    public let schemaVersion: UInt32
    public let generatedAt: String
    public let range: String
    public let bucketSeconds: UInt64
    public let modelSeries: [CAPUsageStatRow]
}

public struct CAPUsageGroups: Decodable, Sendable {
    public let schemaVersion: UInt32
    public let generatedAt: String
    public let range: String
    public let total: Int
    public let items: [CAPUsageStatRow]
}
