import Foundation
import CPAQuotaKit
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

@main
struct CPAQuotaProbe {
    struct Summary: Encodable {
        let accounts: Int
        let enabled: Int
        let succeeded: Int
        let failed: Int
        let providers: [ProviderSummary]
    }

    struct ProviderSummary: Encodable {
        let provider: String
        let accounts: Int
        let enabled: Int
        let succeeded: Int
        let windows: Int
        let metrics: Int
        let errors: [String: Int]
    }

    struct Failure: Encodable { let error: String }

    static func main() async {
        do {
            guard CommandLine.arguments.count == 2 else {
                emit(Failure(error: "usage: cpa-quota-probe <https-server>; management key must arrive on stdin"))
                exit(EXIT_FAILURE)
            }
            let server = try CPAServer(baseURL: CommandLine.arguments[1])
            let key = try readKey()
            let client = CPAClient(server: server, managementKey: key)
            let records = try await client.refreshAll(force: true)
            let grouped = Dictionary(grouping: records, by: { $0.account.provider })
            let providers = grouped.keys.sorted().map { provider in
                let rows = grouped[provider] ?? []
                let enabled = rows.filter { !$0.account.isDisabled }
                let succeeded = enabled.filter { $0.error == nil && $0.snapshot?.source == .live }
                let errors = Dictionary(grouping: rows.compactMap { $0.error?.kind.rawValue }, by: { $0 })
                    .mapValues(\.count)
                return ProviderSummary(provider: provider, accounts: rows.count, enabled: enabled.count,
                                       succeeded: succeeded.count,
                                       windows: succeeded.reduce(0) { $0 + ($1.snapshot?.windows.count ?? 0) },
                                       metrics: succeeded.reduce(0) { $0 + ($1.snapshot?.metrics.count ?? 0) },
                                       errors: errors)
            }
            let enabled = records.filter { !$0.account.isDisabled }.count
            let succeeded = providers.reduce(0) { $0 + $1.succeeded }
            emit(Summary(accounts: records.count, enabled: enabled, succeeded: succeeded,
                         failed: enabled - succeeded, providers: providers))
            if succeeded != enabled { exit(EXIT_FAILURE) }
        } catch {
            let kind = (error as? CPAError)?.kind.rawValue ?? "probeFailure"
            emit(Failure(error: kind))
            exit(EXIT_FAILURE)
        }
    }

    private static func readKey() throws -> ManagementKey {
        var input = Data()
        while let chunk = try FileHandle.standardInput.read(upToCount: 8193 - input.count), !chunk.isEmpty {
            input.append(chunk)
            guard input.count <= 8192 else { throw CPAError(.invalidManagementKey) }
        }
        guard let text = String(data: input, encoding: .utf8) else { throw CPAError(.invalidManagementKey) }
        return try ManagementKey(text)
    }

    private static func emit<Value: Encodable>(_ value: Value) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            print("{\"error\":\"encodingFailure\"}")
            return
        }
        print(text)
    }
}
