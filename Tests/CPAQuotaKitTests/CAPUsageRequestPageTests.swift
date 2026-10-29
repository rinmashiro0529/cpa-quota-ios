import Foundation
import Testing
@testable import CPAQuotaKit

@Suite("CAP request page payload")
struct CAPUsageRequestPageTests {
    @Test func decodesActualPluginRequestAndItsStatus() throws {
        let json = #"{"generated_at":"2026-10-28T00:00:00Z","range":"custom","price_book_revision":2,"total":1,"offset":0,"limit":100,"items":[{"sequence":42,"time":"2026-10-27T23:45:00Z","provider":"gemini","executor_type":"geminiexecutor","model":"gemini-model","source":"fixture-source","failed":false,"failure_status":0,"result":"成功","input_tokens":25,"output_tokens":60,"reasoning_tokens":40,"total_tokens":125,"latency_ns":3000000000,"ttft_ns":1000000000,"generation_ns":2000000000,"tps":50,"end_to_end_tps":33.333333,"stream":true,"cache_hit":false}]}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let page = try decoder.decode(CAPUsageRequestPage.self, from: Data(json.utf8))
        #expect(page.total == 1)
        let request = try #require(page.items.first)
        #expect(request.sequence == 42)
        #expect(request.time == "2026-10-27T23:45:00Z")
        #expect(request.result == "成功")
        #expect(request.stream == true)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let preserved = try #require(JSONSerialization.jsonObject(with: encoder.encode(request)) as? [String: Any])
        #expect(preserved["source"] as? String == "fixture-source")
        #expect(preserved["input_tokens"] as? UInt64 == 25)
        #expect(preserved["total_tokens"] as? UInt64 == 125)
        #expect(preserved["generation_ns"] as? UInt64 == 2_000_000_000)
        #expect(preserved["tps"] as? Double == 50)
        #expect(preserved["cache_hit"] as? Bool == false)
        #expect(CAPUsageAggregation.summarize(page.items).generationTPS == 50)
    }
}
