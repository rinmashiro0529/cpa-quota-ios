import Foundation
import CPAQuotaKit

/// Describes declared account capabilities without inventing the route actually
/// selected by the client's separate provider discovery.
public struct AccountDiagnosticPresentation: Equatable, Sendable {
    public let displayName: String
    public let email: String
    public let accountStatus: String
    public let statusSymbol: String
    public let severity: ErrorSeverityLevel
    public let readerDescription: String

    public init(account: CPAAccount, error: CPAError?, maskEmail: Bool) {
        self.displayName = QuotaFormatter.maskEmail(account.displayName, enabled: maskEmail)
        self.email = QuotaFormatter.maskEmail(account.email, enabled: maskEmail)

        if account.isDisabled {
            accountStatus = "已停用"
            statusSymbol = "pause.circle"
            severity = .neutral
        } else if account.isUnavailable {
            accountStatus = "当前不可用"
            statusSymbol = "exclamationmark.circle"
            severity = .warning
        } else if let error {
            let presentation = ErrorPresentation(error: error)
            accountStatus = presentation.title
            statusSymbol = presentation.symbolName
            severity = presentation.severity
        } else {
            accountStatus = "已启用"
            statusSymbol = "checkmark.circle"
            severity = .neutral
        }

        if error?.kind == .unsupportedProvider {
            readerDescription = "本次查询返回未支持的平台，不代表拥有可用配额。"
        } else if account.supportsPluginQuota {
            readerDescription = "账号声明支持 CPA 标准化额度插件。"
        } else {
            switch account.provider.lowercased() {
            case "codex":
                readerDescription = "提供 Codex 内置读取器；服务端发现的插件能力优先。"
            case "xai":
                readerDescription = "提供 xAI billing 内置读取器；服务端发现的插件能力优先。"
            default:
                readerDescription = "没有该平台的内置读取器。能否读取取决于服务端发现的插件能力与实际查询结果。"
            }
        }
    }
}
