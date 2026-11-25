import Foundation
import CPAQuotaKit

/// Connection status data only. This type never renders or represents a system Live Activity.
public struct ConnectionStatusPresentation: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case unconfigured
        case idle(host: String, activeCount: Int, totalCount: Int)
        case syncing(isLoadingInventory: Bool, completedCount: Int, totalCount: Int)
        case rateLimited(layer: CPAError.Layer?, remainingSeconds: Int)
        case managementBlocked(kind: CPAError.Kind)
        case connectionFailed(kind: CPAError.Kind)
    }

    public let phase: Phase
    public let isExpanded: Bool

    public init(phase: Phase, isExpanded: Bool) {
        self.phase = phase
        self.isExpanded = isExpanded
    }

    public var compactLeadingText: String {
        switch phase {
        case .unconfigured:
            return "CPA"
        case .idle(let host, _, _):
            return Self.shortHostLabel(host)
        case .syncing:
            return "同步中"
        case .rateLimited:
            return "限流冷却"
        case .managementBlocked:
            return "鉴权阻断"
        case .connectionFailed:
            return "连接异常"
        }
    }

    public var compactTrailingText: String {
        switch phase {
        case .unconfigured:
            return "未连接"
        case .idle(_, let activeCount, let totalCount):
            return "\(activeCount)/\(totalCount) 启用"
        case .syncing(let isLoadingInventory, let completedCount, let totalCount):
            if isLoadingInventory {
                return "读取清单"
            }
            return "\(completedCount)/\(max(1, totalCount))"
        case .rateLimited(_, let remainingSeconds):
            return "\(remainingSeconds)s"
        case .managementBlocked:
            return "需验证"
        case .connectionFailed(let kind):
            return Self.connectionFailureLabel(kind)
        }
    }

    public var expandedTitle: String {
        switch phase {
        case .unconfigured:
            return "等待配置个人 CPA 连接"
        case .idle:
            return "CPA 额度连接就绪"
        case .syncing(let isLoadingInventory, let completedCount, let totalCount):
            if isLoadingInventory {
                return "正在读取授权账号与能力清单"
            }
            return "正在并发同步额度 (\(completedCount)/\(totalCount))"
        case .rateLimited(let layer, _):
            let layerText = layer == .management ? "管理层" : "上游"
            return "触发\(layerText)限流冷却 (Retry-After)"
        case .managementBlocked:
            return "CPA 管理层鉴权已熔断"
        case .connectionFailed:
            return "CPA 连接出现异常"
        }
    }

    public var expandedSubtitle: String {
        switch phase {
        case .unconfigured:
            return "需要 HTTPS 服务地址与管理密钥"
        case .idle(let host, let activeCount, let totalCount):
            return "\(host) · \(activeCount) 个启用账号 / 共 \(totalCount) 个"
        case .syncing:
            return "客户端最多 3 并发请求 · 完成即逐行发布"
        case .rateLimited(_, let remainingSeconds):
            return "冷却剩余 \(remainingSeconds) 秒 · 到期前不强制重试"
        case .managementBlocked(let kind):
            return "\(kind.rawValue) · 已停止排队请求以防封禁"
        case .connectionFailed(let kind):
            return "\(Self.connectionFailureLabel(kind))（\(kind.rawValue)）· 请检查网络或服务地址后重试"
        }
    }

    /// Text consumed by the connection settings page, not a claim that TLS implies authorization.
    public var connectionPageText: String {
        switch phase {
        case .unconfigured: "未连接"
        case .idle: "已连接"
        case .syncing: "正在同步"
        case .rateLimited: "限流冷却中"
        case .managementBlocked(let kind): "管理鉴权已阻断：\(Self.connectionFailureLabel(kind))"
        case .connectionFailed(let kind):
            kind == .rateLimited ? "限流后待验证" : "连接异常：\(Self.connectionFailureLabel(kind))"
        }
    }

    public var connectionPageRecovery: String? {
        switch phase {
        case .managementBlocked:
            "请更新服务地址或管理密钥，并显式重新连接；原连接的鉴权熔断不会自动解除。"
        case .connectionFailed(let kind):
            kind == .rateLimited
                ? "倒计时结束不代表连接或数据已恢复；请在允许重试后显式刷新验证。"
                : "请检查网络或服务地址后重试。"
        default: nil
        }
    }

    public var progressFraction: Double {
        switch phase {
        case .unconfigured:
            return 0.0
        case .idle:
            return 1.0
        case .syncing(let isLoadingInventory, let completedCount, let totalCount):
            if isLoadingInventory { return 0.0 }
            guard totalCount > 0 else { return 0.0 }
            return max(0.0, min(1.0, Double(completedCount) / Double(totalCount)))
        case .rateLimited:
            return 0.0 // A cooldown duration is not a measurable completed-work fraction.
        case .managementBlocked:
            return 0.0
        case .connectionFailed:
            return 0.0
        }
    }

    public var canCancel: Bool {
        if case .syncing = phase { return true }
        return false
    }

    private static func connectionFailureLabel(_ kind: CPAError.Kind) -> String {
        switch kind {
        case .invalidServer: "地址无效"
        case .invalidManagementKey: "密钥无效"
        case .managementUnauthorized: "管理鉴权失败"
        case .managementForbidden: "管理访问受限"
        case .endpointUnavailable: "端点不可用"
        case .requestRejected: "请求被拒"
        case .accountNotFound: "账号信息缺失"
        case .accountDisabled: "账号已停用"
        case .unsupportedProvider: "平台未支持"
        case .upstreamUnauthorized: "上游鉴权失效"
        case .upstreamFailure: "上游异常"
        case .rateLimited: "限流冷却"
        case .network: "网络"
        case .timeout: "超时"
        case .cancelled: "已取消"
        case .invalidResponse: "响应异常"
        case .responseTooLarge: "响应过大"
        case .redirectRefused: "重定向被拒"
        case .secureStorageUnavailable: "安全存储不可用"
        case .secureStorageFailure: "安全存储异常"
        }
    }

    public static func shortHostLabel(_ rawHost: String) -> String {
        let cleaned = rawHost
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        if let firstSegment = cleaned.split(separator: ".").first, !firstSegment.isEmpty {
            return String(firstSegment.prefix(10))
        }
        return String(cleaned.prefix(10))
    }
}

@available(*, deprecated, renamed: "ConnectionStatusPresentation")
public typealias DynamicIslandState = ConnectionStatusPresentation
