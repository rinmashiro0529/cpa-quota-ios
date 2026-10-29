import Foundation

public struct CAPUsageRequest: Codable, Sendable {
    public let sequence: UInt64?
    public let time: String?
    public let result: String?
    public let stream: Bool?
    public let model: String?
    public let provider: String?
    public let executorType: String?
    public let alias: String?
    public let source: String?
    public let authType: String?
    public let serviceTier: String?
    public let reasoningEffort: String?
    public let failed: Bool?
    public let failureStatus: Int?
    public let requests: UInt64?
    public let failedRequests: UInt64?
    public let inputTokens: UInt64?
    public let outputTokens: UInt64?
    public let reasoningTokens: UInt64?
    public let cachedTokens: UInt64?
    public let cacheReadTokens: UInt64?
    public let cacheCreationTokens: UInt64?
    public let totalTokens: UInt64?
    public let latencyNs: UInt64?
    public let ttftNs: UInt64?
    public let generationNs: UInt64?
    public let tps: Double?
    public let endToEndTps: Double?
    public let cacheHit: Bool?
}

public struct CAPUsageSummary: Sendable {
    public let counters: CAPUsageCounters
    public let generationTPS: Double?
    public let generationSamples: Int
    public let endToEndTPS: Double?
    public let endToEndSamples: Int
    public let totalRequests: Int
}

public struct CAPUsageModelSummary: Sendable {
    public let provider: String?
    public let model: String?
    public let stream: Bool?
    public let summary: CAPUsageSummary
}

public enum CAPUsageAggregation {
    public static func byModel(_ requests: [CAPUsageRequest]) -> [CAPUsageModelSummary] {
        struct Key: Hashable {
            let provider: String?
            let model: String?
            let stream: Bool?
        }
        let grouped = Dictionary(grouping: requests) { Key(provider: $0.provider, model: $0.model, stream: $0.stream) }
        return grouped.map { key, values in
            CAPUsageModelSummary(provider: key.provider, model: key.model, stream: key.stream, summary: summarize(values))
        }.sorted {
            if $0.provider != $1.provider { return ($0.provider ?? "") < ($1.provider ?? "") }
            if $0.model != $1.model { return ($0.model ?? "") < ($1.model ?? "") }
            return ($0.stream == true ? 2 : $0.stream == false ? 1 : 0) < ($1.stream == true ? 2 : $1.stream == false ? 1 : 0)
        }
    }
    private static func counters(_ requests: [CAPUsageRequest]) -> CAPUsageCounters {
        func sum(_ key: KeyPath<CAPUsageRequest, UInt64?>) -> UInt64? {
            var total: UInt64 = 0
            for request in requests {
                guard let value = request[keyPath: key] else { return nil }
                let result = total.addingReportingOverflow(value)
                guard !result.overflow else { return nil }
                total = result.partialValue
            }
            return total
        }
        return CAPUsageCounters(
            requests: UInt64(requests.count),
            failedRequests: requests.allSatisfy({ $0.failed != nil }) ? UInt64(requests.filter { $0.failed == true }.count) : nil,
            inputTokens: sum(\.inputTokens), outputTokens: sum(\.outputTokens),
            reasoningTokens: sum(\.reasoningTokens), cachedTokens: sum(\.cachedTokens),
            cacheReadTokens: sum(\.cacheReadTokens), cacheCreationTokens: sum(\.cacheCreationTokens),
            totalTokens: sum(\.totalTokens), totalLatencyNs: sum(\.latencyNs), totalTtftNs: sum(\.ttftNs),
            latencySamples: requests.allSatisfy({ $0.latencyNs != nil }) ? UInt64(requests.filter { ($0.latencyNs ?? 0) > 0 }.count) : nil,
            ttftSamples: requests.allSatisfy({ $0.ttftNs != nil }) ? UInt64(requests.filter { ($0.ttftNs ?? 0) > 0 }.count) : nil)
    }

    public static func summarize(_ requests: [CAPUsageRequest]) -> CAPUsageSummary {
        var tokens = 0.0
        var nanoseconds = 0.0
        var samples = 0
        var endTokens = 0.0
        var endNanoseconds = 0.0
        var endSamples = 0
        for request in requests {
            guard request.failed == false, let output = request.outputTokens,
                  let latency = request.latencyNs, latency > 0 else { continue }
            let provider = (request.provider ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let executor = (request.executorType ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let combined = provider + " " + executor
            let included = executor == "openaicompatexecutor" || provider == "openai-compatibility" ||
                provider.hasPrefix("openai-compatible-") || combined.contains("claude") || combined.contains("anthropic")
            let separate = ["gemini", "aistudio", "antigravity", "vertex", "interaction"]
                .contains { combined.contains($0) }
            let knownIncluded = ["openai", "codex", "xai", "grok", "kimi", "qwen", "deepseek", "openrouter"]
                .contains { combined.contains($0) }
            let effective: Double
            // Match the upstream precedence: explicit included, separate reasoning,
            // then generic included providers. Provider and executor may disagree.
            if included {
                effective = Double(output)
            } else if separate {
                guard let reasoning = request.reasoningTokens else { continue }
                effective = Double(output) + Double(reasoning)
            } else if knownIncluded || request.reasoningTokens == 0 {
                effective = Double(output)
            } else {
                continue
            }
            guard effective > 0 else { continue }
            endTokens += effective
            endNanoseconds += Double(latency)
            endSamples += 1
            guard let ttft = request.ttftNs, ttft > 0, latency > ttft else { continue }
            tokens += effective
            nanoseconds += Double(latency - ttft)
            samples += 1
        }
        return CAPUsageSummary(counters: counters(requests),
                               generationTPS: samples == 0 ? nil : tokens * 1_000_000_000 / nanoseconds,
                               generationSamples: samples,
                               endToEndTPS: endSamples == 0 ? nil : endTokens * 1_000_000_000 / endNanoseconds,
                               endToEndSamples: endSamples,
                               totalRequests: requests.count)
    }
}
