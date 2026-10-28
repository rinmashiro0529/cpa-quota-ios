import Foundation

public struct CAPUsageCounters: Codable, Sendable {
    public let requests: UInt64?
    public let failedRequests: UInt64?
    public let inputTokens: UInt64?
    public let outputTokens: UInt64?
    public let reasoningTokens: UInt64?
    public let cachedTokens: UInt64?
    public let cacheReadTokens: UInt64?
    public let cacheCreationTokens: UInt64?
    public let totalTokens: UInt64?
    public let totalLatencyNs: UInt64?
    public let totalTtftNs: UInt64?
    public let latencySamples: UInt64?
    public let ttftSamples: UInt64?
}

public struct CAPUsageStats: Codable, Sendable {
    public let schemaVersion: UInt32?
    public let generatedAt: String?
    public let range: String?
    public let retainedSince: String?
    public let lastUsed: String?
    public let summary: CAPUsageCounters
    public let groups: [CAPUsageStatRow]?
    public let series: [CAPUsageStatRow]?
    public let modelSeries: [CAPUsageStatRow]?
    public let sources: [String]?
}
