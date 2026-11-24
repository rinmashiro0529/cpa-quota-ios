import Foundation
import CPAQuotaKit
import CPAQuotaChat
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// User-facing copy for chat failures. The client API key is never part of any text.
public struct ChatFailurePresentation: Equatable, Sendable {
    public let title: String
    public let summary: String
    public let symbolName: String
    public let severity: ErrorSeverityLevel

    public init(_ failure: ChatFailure) {
        switch failure {
        case .missingAPIKey:
            title = "尚未选择 API Key"
            summary = "请在对话设置中选择或填写一把 CPA 客户端 API Key，再重新发送。"
            symbolName = "key.slash"
            severity = .warning
        case .missingModel:
            title = "尚未选择模型"
            summary = "请先从 CPA 提供的模型列表中选择一个模型。"
            symbolName = "cpu"
            severity = .warning
        case .unauthorized:
            title = "API Key 鉴权失败"
            summary = "CPA 拒绝了当前客户端 API Key。请在对话设置中重新选择或更换 Key。"
            symbolName = "lock.trianglebadge.exclamationmark"
            severity = .critical
        case .forbidden:
            title = "无权使用此模型"
            summary = "当前 API Key 没有调用此模型的权限。可以换用其他模型或 Key。"
            symbolName = "hand.raised"
            severity = .warning
        case .modelUnavailable:
            title = "模型不可用"
            summary = "CPA 未找到或暂时无法提供此模型。请刷新模型列表后重新选择。"
            symbolName = "questionmark.square.dashed"
            severity = .warning
        case .rateLimited(let retryAfter):
            title = "请求过于频繁"
            if let retryAfter {
                summary = "CPA 或上游触发了限流，可在 \(retryAfter.formatted(date: .omitted, time: .shortened)) 之后重试。"
            } else {
                summary = "CPA 或上游触发了限流，请稍后重试。"
            }
            symbolName = "hourglass"
            severity = .warning
        case .upstream:
            title = "模型服务响应异常"
            summary = "CPA 或上游返回了错误。已生成的内容会保留，可以重新生成。"
            symbolName = "exclamationmark.icloud"
            severity = .warning
        case .network:
            title = "网络连接失败"
            summary = "无法安全连接到 CPA 服务。请检查网络后重新生成。"
            symbolName = "wifi.exclamationmark"
            severity = .warning
        case .timeout:
            title = "等待回复超时"
            summary = "模型长时间没有返回内容，已结束本次请求。"
            symbolName = "clock.badge.exclamationmark"
            severity = .warning
        case .connectionChanged:
            title = "连接已更换"
            summary = "服务器或 API Key 已更换，本次生成已中断。"
            symbolName = "server.rack"
            severity = .neutral
        case .streamInterrupted:
            title = "回复传输中断"
            summary = "服务在生成结束前断开了连接，已收到的内容保留在对话中。"
            symbolName = "wifi.exclamationmark"
            severity = .warning
        case .continuationAddedNothing:
            title = "续写没有产生新内容"
            summary = "续写没有产生新内容，可再次续写。"
            symbolName = "text.badge.plus"
            severity = .neutral
        case .invalidResponse:
            title = "回复格式无法识别"
            summary = "CPA 返回的数据不是可识别的对话格式。可以换用其他模型重试。"
            symbolName = "doc.questionmark"
            severity = .warning
        case .searchFailed:
            title = "联网搜索未完成"
            summary = "本次回答没有使用搜索结果。请检查搜索服务的 API Key 或稍后重试。"
            symbolName = "magnifyingglass"
            severity = .neutral
        case .searchNotConfigured:
            title = "本次未联网搜索"
            summary = "联网搜索已开启，但还没有可用的搜索服务或搜索 API Key，本次回答没有使用搜索结果。可在对话设置中补全。"
            symbolName = "magnifyingglass"
            severity = .neutral
        case .interruptedInBackground:
            title = "后台生成已中断"
            summary = "系统分配的后台时间已用完。重新生成会发送新请求并替换这条回复。"
            symbolName = "moon.zzz"
            severity = .neutral
        case .generationInterrupted:
            title = "生成已中断"
            summary = "上次生成未完成，以下为本机恢复的内容。重新生成会发送新请求并替换这条回复。"
            symbolName = "pause.circle"
            severity = .neutral
        }
    }
}

/// Direct recovery action offered beside an inline chat failure notice.
public enum ChatFailureRecoveryAction: Equatable, Sendable {
    case openSettings(title: String)
    case refreshModels
    case regenerate
}

extension ChatFailure {
    /// The key was rejected for this request; choosing another key may help.
    var suggestsDifferentKey: Bool {
        switch self {
        case .unauthorized, .forbidden: true
        default: false
        }
    }

    public var recoveryAction: ChatFailureRecoveryAction? {
        switch self {
        case .missingAPIKey, .unauthorized, .forbidden, .searchNotConfigured, .searchFailed:
            .openSettings(title: "前往对话设置")
        case .modelUnavailable, .missingModel:
            .refreshModels
        case .rateLimited, .upstream, .network, .timeout, .streamInterrupted,
             .interruptedInBackground, .generationInterrupted, .invalidResponse:
            .regenerate
        case .connectionChanged, .continuationAddedNothing:
            nil
        }
    }
}

extension ChatReasoningEffort {
    var title: String {
        switch self {
        case .automatic: "自动"
        case .off: "关闭"
        case .low: "低"
        case .medium: "中"
        case .high: "高"
        case .xhigh: "极高"
        case .max: "最大"
        }
    }

    /// Compact tick label shown beneath the discrete slider stops.
    var compactTickTitle: String {
        switch self {
        case .automatic: "自动"
        case .off: "关"
        case .low: "低"
        case .medium: "中"
        case .high: "高"
        case .xhigh: "极高"
        case .max: "最大"
        }
    }

    var summary: String {
        switch self {
        case .automatic: "跟随模型默认策略，不附加思考参数"
        case .off: "关闭额外思考，优先最快响应"
        case .low: "轻度思考，适合简单问答"
        case .medium: "均衡思考深度与响应速度"
        case .high: "深度推理，适合复杂问题"
        case .xhigh: "极高推理强度，适合高难分析"
        case .max: "最大思考预算，追求最高质量"
        }
    }

    var symbolName: String {
        switch self {
        case .automatic: "sparkles"
        case .off: "bolt.slash"
        case .low, .medium, .high, .xhigh, .max: "brain"
        }
    }
}

extension ChatReasoningResolution {
    var noticeText: String? {
        switch outcome {
        case .applied:
            return nil
        case .downgraded:
            if let applied {
                return "当前模型不支持「\(requested.title)」，本次已按「\(applied.title)」发送"
            }
            return "当前模型不支持「\(requested.title)」，本次已降级发送"
        case .omitted:
            if requested == .off {
                return "当前模型无法关闭思考，本次已按默认发送"
            }
            return "当前模型不支持思考等级，本次已按默认发送"
        }
    }
}

extension ChatConversation {
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "新对话" : trimmed
    }

    var previewText: String {
        guard let last = messages.last(where: { !$0.text.isEmpty }) else { return "暂无消息" }
        let flattened = last.text.replacingOccurrences(of: "\n", with: " ")
        return String(flattened.prefix(80))
    }
}

enum ChatDeletionCopy {
    static func message(isGenerating: Bool) -> String {
        isGenerating
            ? "正在生成的回复将停止。对话记录只保存在本机，删除后无法恢复。"
            : "对话记录只保存在本机，删除后无法恢复。"
    }
}

/// Human-readable form of a `CPAServer.identifier` (host, port and path; no scheme).
enum ChatServerLabel {
    static func display(_ identifier: String) -> String {
        guard let url = URL(string: identifier), let host = url.host else { return identifier }
        let port = url.port.map { ":\($0)" } ?? ""
        let path = url.path == "/" ? "" : url.path
        return host + port + path
    }
}

enum ChatClipboard {
    @MainActor
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

#if canImport(SwiftUI)
import SwiftUI

/// Shared warning and optional retry row for local persistence load/save failures.
struct ChatStorageWarningRow: View {
    let message: String
    var retryTitle: String? = nil
    var retryAction: (() async -> Void)? = nil
    @Environment(\.brandPalette) private var palette
    @State private var isRetrying = false

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(palette.statusWarn)
        if let retryTitle, let retryAction {
            Button {
                guard !isRetrying else { return }
                isRetrying = true
                Task {
                    await retryAction()
                    isRetrying = false
                }
            } label: {
                Label(retryTitle, systemImage: "arrow.clockwise")
                    .frame(minHeight: 44)
            }
            .disabled(isRetrying)
        }
    }
}
#endif
