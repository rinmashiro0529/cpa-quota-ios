import Foundation
import CPAQuotaKit
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif

/// The ActivityKit wire state is exactly the monitoring v1 snapshot sent by Go.
/// In particular, there is no Data/Base64 envelope or device-only selection key.
public struct CPAQuotaLiveActivityState: Codable, Hashable, Sendable {
    public let snapshot: MonitoringSnapshot

    public init(snapshot: MonitoringSnapshot) throws {
        _ = try snapshot.activityContentData()
        self.snapshot = snapshot
    }

    public init(from decoder: any Decoder) throws {
        try self.init(snapshot: MonitoringSnapshot(from: decoder))
    }

    public func encode(to encoder: any Encoder) throws {
        try snapshot.encode(to: encoder)
    }

    public var accounts: [MonitoringAccount] { snapshot.accounts }

    /// A local presentation choice, never part of the remote content-state.
    public func account(at index: Int = 0) -> MonitoringAccount? {
        guard !accounts.isEmpty else { return nil }
        return accounts[Self.normalizedIndex(index, count: accounts.count)]
    }

    public static func normalizedIndex(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let remainder = index % count
        return remainder < 0 ? remainder + count : remainder
    }

    /// Compare the server's sequence, not the time an HTTP response arrived.
    /// The native driver also supplies the original timestamp to ActivityKit.
    public func accepts(_ incoming: MonitoringSnapshot) -> Bool {
        incoming.sequence > snapshot.sequence
    }
}

/// Shared by the app and its widget extension through the same Swift module.
/// Only the deployment's safe source alias belongs in the static attributes.
public struct CPAQuotaActivityAttributes: Codable, Hashable, Sendable {
    public typealias ContentState = CPAQuotaLiveActivityState
    public let sourceID: String

    public init(sourceID: String) throws {
        guard !sourceID.isEmpty, sourceID.utf8.count <= 128,
              sourceID.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || "_-".unicodeScalars.contains($0)
              }) else {
            throw MonitoringError.invalidConfiguration
        }
        self.sourceID = sourceID
    }

    enum CodingKeys: String, CodingKey { case sourceID }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(sourceID: container.decode(String.self, forKey: .sourceID))
    }

    public func validateContent(_ content: ContentState) throws {
        let encoder = JSONEncoder()
        let attributesBytes = try encoder.encode(self).count
        let contentBytes = try encoder.encode(content).count
        guard attributesBytes <= 512, contentBytes <= 3_584,
              attributesBytes + contentBytes <= 4_096 else {
            throw MonitoringError.invalidConfiguration
        }
    }
}

#if canImport(ActivityKit) && os(iOS)
extension CPAQuotaActivityAttributes: ActivityAttributes {}
#endif

/// Presentation decisions shared by every system surface and model tests.
/// A retained number is still useful, but never implies that stale data is live.
public enum CPAQuotaActivityPresentation {
    public static func compactStatus(snapshot: MonitoringSnapshot, account: MonitoringAccount?, isStale: Bool) -> String? {
        if snapshot.phase == .stopped { return "结束" }
        if snapshot.phase == .expired { return "到期" }
        if isStale || account?.status == .stale { return "旧值" }
        if snapshot.phase == .failed || account?.status == .failed { return "失败" }
        if snapshot.phase == .coolingDown || account?.status == .coolingDown { return "限流" }
        if account == nil || account?.status == .unavailable { return "未知" }
        if snapshot.phase == .partial { return "部分" }
        return nil
    }

    public static func status(snapshot: MonitoringSnapshot, account: MonitoringAccount?, isStale: Bool) -> String {
        switch snapshot.phase {
        case .stopped: return "已停止"
        case .expired: return "已到期"
        default: break
        }
        if isStale { return "数据已过期" }
        switch account?.status {
        case .stale: return "上次读数"
        case .failed: return "读取失败"
        case .unavailable: return "暂不可用"
        case .coolingDown: return "限流等待"
        case .ok, nil: break
        }
        switch snapshot.phase {
        case .partial: return "部分可用"
        case .failed: return "读取失败"
        case .coolingDown: return "限流等待"
        case .ready: return account == nil ? "等待读数" : "最近读数"
        case .stopped: return "已停止"
        case .expired: return "已到期"
        }
    }

    public static func value(_ account: MonitoringAccount?) -> String {
        guard let account else { return "未知" }
        if let fraction = account.remainingFraction {
            return String(format: "%.0f%%", (fraction * 100).rounded())
        }
        if let value = account.value {
            if abs(value) >= 1_000_000 || (value != 0 && abs(value) < 0.005) {
                return value.formatted(.number.notation(.scientific).precision(.significantDigits(1...6)))
                    + (account.unit.map { " " + $0 } ?? "")
            }
            return String(format: "%.2f", value) + (account.unit.map { " " + $0 } ?? "")
        }
        return "未知"
    }
}
