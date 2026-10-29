import Foundation
import Testing
@testable import CPAQuotaKit

@Suite("CAP usage aggregation")
struct CAPUsageAggregationTests {
    @Test func tokenAccountingFollowsTheUpstreamPrecedence() throws {
        let cases: [(String, String, Double)] = [
            ("openai", "geminiexecutor", 50),
            ("gemini", "openaiexecutor", 50),
            ("gemini", "openaicompatexecutor", 30),
            ("anthropic", "geminiexecutor", 30),
            ("openai", "openaiexecutor", 30)
        ]
        for (provider, executor, expected) in cases {
            let json = """
            [{"provider":"\(provider)","executor_type":"\(executor)","failed":false,"output_tokens":60,"reasoning_tokens":40,"latency_ns":3000000000,"ttft_ns":1000000000}]
            """
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let requests = try decoder.decode([CAPUsageRequest].self, from: Data(json.utf8))
            #expect(CAPUsageAggregation.summarize(requests).generationTPS == expected)
        }
    }

    @Test func unknownProviderWithZeroReasoningStillHasUnambiguousSpeed() throws {
        let json = #"[{"provider":"unknown","failed":false,"output_tokens":100,"reasoning_tokens":0,"latency_ns":3000000000,"ttft_ns":1000000000}]"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let requests = try decoder.decode([CAPUsageRequest].self, from: Data(json.utf8))
        #expect(CAPUsageAggregation.summarize(requests).generationTPS == 50)
    }

    @Test func modelCountersIncludePartialFailureUsageButNotItsSpeed() throws {
        let json = #"[{"model":"m","provider":"openai","failed":false,"input_tokens":10,"output_tokens":100,"reasoning_tokens":0,"latency_ns":3000000000,"ttft_ns":1000000000},{"model":"m","provider":"openai","failed":false,"input_tokens":20,"output_tokens":900,"reasoning_tokens":0,"latency_ns":31000000000,"ttft_ns":1000000000},{"model":"m","provider":"openai","failed":true,"input_tokens":3,"output_tokens":20,"latency_ns":9000000000,"ttft_ns":1000000000}]"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let requests = try decoder.decode([CAPUsageRequest].self, from: Data(json.utf8))
        let summary = try #require(CAPUsageAggregation.byModel(requests).first?.summary)
        #expect(summary.counters.requests == 3)
        #expect(summary.counters.failedRequests == 1)
        #expect(summary.counters.inputTokens == 33)
        #expect(summary.counters.outputTokens == 1020)
        #expect(summary.counters.reasoningTokens == nil)
        #expect(summary.counters.totalTokens == nil)
        #expect(summary.generationTPS == 31.25)
        #expect(summary.generationSamples == 2)
    }
    @Test func includedReasoningDoesNotRequireUnusedReasoningField() throws {
        let json = #"[{"provider":"openai","failed":false,"output_tokens":100,"latency_ns":3000000000,"ttft_ns":1000000000}]"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let requests = try decoder.decode([CAPUsageRequest].self, from: Data(json.utf8))
        let result = CAPUsageAggregation.summarize(requests)
        #expect(result.generationTPS == 50)
        #expect(result.endToEndTPS == 100.0 / 3.0)
        #expect(result.generationSamples == 1)
    }
    @Test func modelGroupsKeepProviderAndStreamSeparate() throws {
        let json = #"[{"model":"m","provider":"openai","stream":true,"failed":false,"output_tokens":100,"reasoning_tokens":0,"latency_ns":3000000000,"ttft_ns":1000000000},{"model":"m","provider":"gemini","stream":true,"failed":false,"output_tokens":60,"reasoning_tokens":40,"latency_ns":3000000000,"ttft_ns":1000000000},{"model":"m","provider":"openai","stream":false,"failed":false,"output_tokens":100,"reasoning_tokens":0,"latency_ns":3000000000,"ttft_ns":1000000000}]"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let requests = try decoder.decode([CAPUsageRequest].self, from: Data(json.utf8))
        let groups = CAPUsageAggregation.byModel(requests)
        #expect(groups.count == 3)
        #expect(groups.allSatisfy { $0.summary.generationTPS == 50 })
    }

    @Test func unknownReasoningAccountingDoesNotGuessSpeed() throws {
        let json = #"[{"provider":"unknown","failed":false,"output_tokens":100,"reasoning_tokens":20,"latency_ns":3000000000,"ttft_ns":1000000000}]"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let requests = try decoder.decode([CAPUsageRequest].self, from: Data(json.utf8))
        #expect(CAPUsageAggregation.summarize(requests).generationTPS == nil)
    }

    @Test func missingTTFTStillProvidesEndToEndSpeed() throws {
        let json = #"[{"provider":"openai","failed":false,"output_tokens":100,"reasoning_tokens":0,"latency_ns":2000000000,"ttft_ns":0}]"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let requests = try decoder.decode([CAPUsageRequest].self, from: Data(json.utf8))
        let result = CAPUsageAggregation.summarize(requests)
        #expect(result.generationTPS == nil)
        #expect(result.endToEndTPS == 50)
        #expect(result.endToEndSamples == 1)
    }

    @Test func compatibilityExecutorOverridesProviderName() throws {
        let json = #"[{"provider":"gemini","executor_type":"openaicompatexecutor","failed":false,"output_tokens":100,"reasoning_tokens":40,"latency_ns":3000000000,"ttft_ns":1000000000}]"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let requests = try decoder.decode([CAPUsageRequest].self, from: Data(json.utf8))
        #expect(CAPUsageAggregation.summarize(requests).generationTPS == 50)
    }

    @Test func separateReasoningIsNotDoubleCounted() throws {
        let json = #"[{"provider":"gemini","failed":false,"output_tokens":60,"reasoning_tokens":40,"latency_ns":3000000000,"ttft_ns":1000000000},{"provider":"anthropic","failed":false,"output_tokens":100,"reasoning_tokens":40,"latency_ns":3000000000,"ttft_ns":1000000000}]"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let requests = try decoder.decode([CAPUsageRequest].self, from: Data(json.utf8))
        #expect(CAPUsageAggregation.summarize(requests).generationTPS == 50)
    }

    @Test func generationRateWeightsDurationAndExcludesMissingTTFT() throws {
        let json = #"[{"model":"m","provider":"openai","failed":false,"output_tokens":100,"reasoning_tokens":0,"latency_ns":3000000000,"ttft_ns":1000000000},{"model":"m","provider":"openai","failed":false,"output_tokens":900,"reasoning_tokens":0,"latency_ns":31000000000,"ttft_ns":1000000000},{"model":"m","provider":"openai","failed":false,"output_tokens":100,"reasoning_tokens":0,"latency_ns":1000000000,"ttft_ns":0}]"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let requests = try decoder.decode([CAPUsageRequest].self, from: Data(json.utf8))
        let result = CAPUsageAggregation.summarize(requests)
        #expect(result.generationTPS == 31.25)
        #expect(result.generationSamples == 2)
        #expect(result.totalRequests == 3)
    }
}
