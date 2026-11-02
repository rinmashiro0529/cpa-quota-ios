import Foundation

public struct CAPUsageCostAmounts: Decodable, Sendable {
    public let requests: UInt64?
    public let pricedRequests: UInt64?
    public let unpricedRequests: UInt64?
    public let inputUsd: Double?
    public let outputUsd: Double?
    public let cacheReadUsd: Double?
    public let cacheCreationUsd: Double?
    public let totalUsd: Double?
}

public struct CAPUsageMissingPrice: Decodable, Sendable {
    public let provider: String
    public let model: String
    public let requests: UInt64
}

public struct CAPUsageCostItem: Decodable, Sendable {
    public let provider: String
    public let model: String
    public let hour: String?
    public let amounts: CAPUsageCostAmounts

    private enum CodingKeys: String, CodingKey { case provider, model, hour }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = try values.decode(String.self, forKey: .provider)
        model = try values.decode(String.self, forKey: .model)
        hour = try values.decodeIfPresent(String.self, forKey: .hour)
        amounts = try CAPUsageCostAmounts(from: decoder)
    }
}

public struct CAPUsageCosts: Decodable, Sendable {
    public let schemaVersion: UInt32
    public let generatedAt: String
    public let range: String
    public let currency: String
    public let estimateBasis: String
    public let priceBookRevision: UInt64
    public let summary: CAPUsageCostAmounts
    public let models: [CAPUsageCostItem]
    public let series: [CAPUsageCostItem]
    public let missingPrices: [CAPUsageMissingPrice]
}
