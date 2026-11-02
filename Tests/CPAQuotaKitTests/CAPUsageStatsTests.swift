import Foundation
import Testing
@testable import CPAQuotaKit

@Suite("CAP usage stats payload")
struct CAPUsageStatsTests {
    @Test func preservesAllReportedCountersWithoutInventingMissingValues() throws {
        let json = #"{"requests":3,"failed_requests":1,"input_tokens":25,"output_tokens":60,"reasoning_tokens":40,"cached_tokens":10,"cache_read_tokens":10,"total_tokens":125,"total_latency_ns":3000000000,"total_ttft_ns":1000000000,"latency_samples":2,"ttft_samples":1}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let counters = try decoder.decode(CAPUsageCounters.self, from: Data(json.utf8))
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let encoded = try #require(JSONSerialization.jsonObject(with: encoder.encode(counters)) as? [String: Any])
        #expect(encoded["input_tokens"] as? UInt64 == 25)
        #expect(encoded["failed_requests"] as? UInt64 == 1)
        #expect(encoded["reasoning_tokens"] as? UInt64 == 40)
        #expect(encoded["cache_read_tokens"] as? UInt64 == 10)
        #expect(encoded["total_latency_ns"] as? UInt64 == 3_000_000_000)
        #expect(encoded["ttft_samples"] as? UInt64 == 1)
        #expect(encoded["cache_creation_tokens"] == nil)
    }
    @Test func missingCounterIsNotAZeroCounter() throws {
        let json = #"{"schema_version":1,"generated_at":"2026-10-28T00:00:00Z","range":"custom","summary":{"requests":2},"groups":[],"series":[],"model_series":[],"sources":[]}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let stats = try decoder.decode(CAPUsageStats.self, from: Data(json.utf8))
        #expect(stats.summary.requests == 2)
        #expect(stats.summary.outputTokens == nil)
    }
}
