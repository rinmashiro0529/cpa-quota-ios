import Foundation
import CPAQuotaKit

public enum ErrorSeverityLevel: String, Equatable, Sendable {
    case neutral
    case warning
    case critical
}

public struct ErrorPresentation: Equatable, Sendable {
    public let kind: CPAError.Kind
    public let layer: CPAError.Layer?
    public let statusCode: Int?
    public let retryAfter: Date?
    public let title: String
    public let summary: String
    public let recoveryAdvice: String
    public let symbolName: String
    public let severity: ErrorSeverityLevel
    public let preservesManagementKey: Bool
    public let isManagementBlocking: Bool

    public init(error: CPAError, records: [String: QuotaRecord]) {
        self.init(error: error, hasPreservedSnapshot: records.values.contains { $0.snapshot != nil })
    }

    public init(error: CPAError, hasPreservedSnapshot: Bool = false) {
        self.kind = error.kind
        self.layer = error.layer
        self.statusCode = error.statusCode
        self.retryAfter = error.retryAfter

        let snapshotNote = hasPreservedSnapshot
            ? "当前界面保留的是最后一次成功获取的快照，并非本次刷新的新结果。"
            : ""

        switch error.kind {
        case .invalidServer:
            self.title = "服务地址格式无效"
            self.summary = "请输入合法的 HTTPS CPA 服务地址，不得包含内嵌用户名密码、Query 参数、Fragment 片段或相对点路径。"
            self.recoveryAdvice = "请检查并修正服务地址后重新连接；系统会自动还原 /management.html 或 /v0/management 后缀。"
            self.symbolName = "link.badge.plus"
            self.severity = .warning
            self.preservesManagementKey = true
            self.isManagementBlocking = false

        case .invalidManagementKey:
            self.title = "管理密钥格式无效"
            self.summary = "请输入非空的 CPA 管理密钥（Bearer Key），不得包含控制字符。"
            self.recoveryAdvice = "请确认输入的是 CPA 管理密钥而非普通推理 API Key，修正后重试。"
            self.symbolName = "key.slash"
            self.severity = .warning
            self.preservesManagementKey = false
            self.isManagementBlocking = false

        case .managementUnauthorized:
            self.title = "CPA 管理密钥鉴权失败"
            self.summary = "服务器拒绝了当前管理密钥（HTTP \(error.statusCode ?? 401)）。已暂停后续排队查询，避免连续失败触发 IP 封禁。"
            self.recoveryAdvice = "请前往「连接管理」更新有效的管理密钥；各上游账号本身未被删除。\(snapshotNote)"
            self.symbolName = "lock.trianglebadge.exclamationmark"
            self.severity = .critical
            self.preservesManagementKey = false
            self.isManagementBlocking = true

        case .managementForbidden:
            self.title = "CPA 管理访问受限或暂时封禁"
            self.summary = "远程管理接口拒绝访问或当前 IP 处于临时封禁保护期（HTTP \(error.statusCode ?? 403)）。"
            self.recoveryAdvice = "请勿连续高频重试；检查服务器管理访问策略或等待封禁期结束，然后通过「更新管理密钥或连接」显式重新连接。\(snapshotNote)"
            self.symbolName = "hand.raised.slash"
            self.severity = .critical
            self.preservesManagementKey = true
            self.isManagementBlocking = true

        case .endpointUnavailable:
            self.title = "管理端点不可用"
            self.summary = "当前 CPA 实例未开启或不支持请求的额度管理端点（HTTP \(error.statusCode ?? 404)）。"
            self.recoveryAdvice = "请核对 CPA 服务端版本与反代前缀配置。\(snapshotNote)"
            self.symbolName = "network.slash"
            self.severity = .warning
            self.preservesManagementKey = true
            self.isManagementBlocking = false

        case .requestRejected:
            self.title = "额度查询请求被拒绝"
            self.summary = "CPA 服务拒绝了本次额度请求（HTTP \(error.statusCode ?? 400)）。"
            self.recoveryAdvice = "请稍后刷新账号列表并重新同步。\(snapshotNote)"
            self.symbolName = "exclamationmark.octagon"
            self.severity = .warning
            self.preservesManagementKey = true
            self.isManagementBlocking = false

        case .accountNotFound:
            self.title = "未找到对应账号记录"
            self.summary = "目标账号在当前清单中不存在，或缺少必要的 auth_index 路由标识。"
            self.recoveryAdvice = "请先重新加载完整账号列表后再查询该账号。\(snapshotNote)"
            self.symbolName = "person.crop.circle.badge.questionmark"
            self.severity = .warning
            self.preservesManagementKey = true
            self.isManagementBlocking = false

        case .accountDisabled:
            self.title = "账号已停用"
            self.summary = "该账号在 CPA 服务中处于停用状态，客户端按合同跳过上游查询。"
            self.recoveryAdvice = "本应用为只读查询工具，不会自动启用账号；如需启用请在 CPA 服务端管理页操作。"
            self.symbolName = "pause.circle"
            self.severity = .neutral
            self.preservesManagementKey = true
            self.isManagementBlocking = false

        case .unsupportedProvider:
            self.title = "平台暂未支持"
            self.summary = "当前没有匹配该平台（Provider）的内置或插件额度读取器。"
            self.recoveryAdvice = "客户端按合同如实显示未支持状态，不会伪造零额度或无限额度。"
            self.symbolName = "cube.transparent"
            self.severity = .neutral
            self.preservesManagementKey = true
            self.isManagementBlocking = false

        case .upstreamUnauthorized:
            self.title = "单账号上游鉴权失效"
            self.summary = "该上游账号凭据已过期或权限不足（HTTP \(error.statusCode ?? 401)），不影响其他正常账号。"
            self.recoveryAdvice = "请在服务端更新该上游账号授权；您的 CPA 管理密钥依然有效，无需重新登录。\(snapshotNote)"
            self.symbolName = "person.badge.key"
            self.severity = .warning
            self.preservesManagementKey = true
            self.isManagementBlocking = false

        case .upstreamFailure:
            self.title = "上游平台响应异常"
            self.summary = "上游额度接口返回错误状态（HTTP \(error.statusCode ?? 502)）。"
            self.recoveryAdvice = "其他账号仍可正常查看，请稍后对该账号单独重试。\(snapshotNote)"
            self.symbolName = "cloud.bolt"
            self.severity = .warning
            self.preservesManagementKey = true
            self.isManagementBlocking = false

        case .rateLimited:
            let layerLabel = error.layer == .management ? "CPA 管理层" : "上游账号层"
            self.title = "触发限流保护 (\(layerLabel))"
            self.summary = "请求过于频繁（HTTP \(error.statusCode ?? 429)），服务端要求冷却等待。"
            self.recoveryAdvice = "客户端严格遵守 Retry-After 时间点，在冷却结束前不会抢发重试请求。\(snapshotNote)"
            self.symbolName = "hourglass"
            self.severity = .warning
            self.preservesManagementKey = true
            self.isManagementBlocking = (error.layer == .management)

        case .network:
            self.title = "安全网络连接失败"
            self.summary = "无法与 CPA 服务器建立安全的 HTTPS 连接。"
            self.recoveryAdvice = "请检查当前网络环境、DNS 或服务端 TLS 证书状态。\(snapshotNote)"
            self.symbolName = "wifi.exclamationmark"
            self.severity = .warning
            self.preservesManagementKey = true
            self.isManagementBlocking = false

        case .timeout:
            self.title = "读取请求超时"
            self.summary = "服务器或上游接口在规定时间内未完成响应。"
            self.recoveryAdvice = "可稍后手动触发刷新。\(snapshotNote)"
            self.symbolName = "clock.badge.exclamationmark"
            self.severity = .warning
            self.preservesManagementKey = true
            self.isManagementBlocking = false

        case .cancelled:
            self.title = "读取已取消"
            self.summary = "当前额度查询已被主动取消。"
            self.recoveryAdvice = "取消操作不代表额度耗尽或连接失效，已有快照保持不变。"
            self.symbolName = "xmark.circle"
            self.severity = .neutral
            self.preservesManagementKey = true
            self.isManagementBlocking = false

        case .invalidResponse:
            self.title = "响应数据结构不兼容"
            self.summary = "服务端返回了无法解析的响应格式（已按安全规范屏蔽原始响应正文）。"
            self.recoveryAdvice = "请确认 CPA 与插件版本是否符合当前数据合同。\(snapshotNote)"
            self.symbolName = "doc.questionmark"
            self.severity = .warning
            self.preservesManagementKey = true
            self.isManagementBlocking = false

        case .responseTooLarge:
            self.title = "响应体积超出安全上限"
            self.summary = "服务端返回的数据长度超过客户端安全接收阈值。"
            self.recoveryAdvice = "已中止解析以保护内存安全，请检查服务端接口输出。\(snapshotNote)"
            self.symbolName = "arrow.up.doc"
            self.severity = .warning
            self.preservesManagementKey = true
            self.isManagementBlocking = false

        case .redirectRefused:
            self.title = "已拒绝不安全的重定向"
            self.summary = "CPA 管理接口尝试发起 HTTP 重定向，已被客户端安全策略拦截。"
            self.recoveryAdvice = "请直接配置最终的 HTTPS 根地址或反代前缀地址，避免重定向泄漏凭据。"
            self.symbolName = "arrow.uturn.right.circle"
            self.severity = .critical
            self.preservesManagementKey = true
            self.isManagementBlocking = false

        case .secureStorageUnavailable:
            self.title = "系统安全存储不可用"
            self.summary = "当前运行环境不支持 Apple Security Keychain 安全凭据存储。"
            self.recoveryAdvice = "为防止管理密钥明文落盘，客户端拒绝降级存储，当前仅可使用内存临时会话。"
            self.symbolName = "externaldrive.badge.exclamationmark"
            self.severity = .warning
            self.preservesManagementKey = true
            self.isManagementBlocking = false

        case .secureStorageFailure:
            self.title = "Keychain 读写操作未完成"
            self.summary = "系统 Keychain 返回状态异常（状态码 \(error.statusCode ?? -1)）。"
            self.recoveryAdvice = "请确认设备处于已解锁状态（WhenUnlockedThisDeviceOnly）后重试。"
            self.symbolName = "key.horizontal"
            self.severity = .warning
            self.preservesManagementKey = true
            self.isManagementBlocking = false
        }
    }

    public func remainingCooldownSeconds(at now: Date = Date()) -> Int? {
        guard let retryAfter else { return nil }
        let remaining = Int(ceil(retryAfter.timeIntervalSince(now)))
        return remaining > 0 ? remaining : nil
    }
}
