import Foundation

public enum CAPUsageCompleteness: Sendable, Equatable {
    case singlePage
    case offsetUnverified
    case truncated
}

public struct CAPUsageRequestCollection: Sendable {
    public let items: [CAPUsageRequest]
    public let completeness: CAPUsageCompleteness
}

public struct CAPUsageRequestPage: Decodable, Sendable {
    public let generatedAt: String?
    public let range: String?
    public let priceBookRevision: UInt64?
    public let total: Int
    public let offset: Int
    public let limit: Int
    public let items: [CAPUsageRequest]

    private enum CodingKeys: String, CodingKey { case generatedAt, range, priceBookRevision, total, offset, limit, items }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try values.decodeIfPresent(String.self, forKey: .generatedAt)
        range = try values.decodeIfPresent(String.self, forKey: .range)
        priceBookRevision = try values.decodeIfPresent(UInt64.self, forKey: .priceBookRevision)
        total = try values.decode(Int.self, forKey: .total)
        offset = try values.decode(Int.self, forKey: .offset)
        limit = try values.decode(Int.self, forKey: .limit)
        items = try values.decode([CAPUsageRequest].self, forKey: .items)
    }
}
