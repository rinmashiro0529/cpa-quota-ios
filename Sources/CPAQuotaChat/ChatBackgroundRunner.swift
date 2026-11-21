import Foundation
#if canImport(UIKit)
import UIKit
import UserNotifications
#endif

public struct ChatBackgroundToken: Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }
}

/// Completion notification content. The text is fixed so neither the
/// conversation title (often derived from the user's message) nor any message
/// content can appear on the lock screen; only the local conversation UUID
/// travels with the notification to locate the conversation.
public enum ChatCompletionNotice {
    public static let title = "AI 对话已完成"
    public static let body = "回复已生成，打开应用查看。"
    public static let conversationIDKey = "conversationID"

    public static func userInfo(for conversationID: UUID) -> [String: String] {
        [conversationIDKey: conversationID.uuidString]
    }

    public static func conversationID(from userInfo: [AnyHashable: Any]) -> UUID? {
        (userInfo[conversationIDKey] as? String).flatMap(UUID.init(uuidString:))
    }
}

/// Background-task and local-notification surface for generations that keep
/// running after the app leaves the foreground. Injectable for tests.
public protocol ChatBackgroundRunner: Sendable {
    @MainActor func beginTask(expiration: @escaping @MainActor @Sendable () -> Void) -> ChatBackgroundToken
    @MainActor func endTask(_ token: ChatBackgroundToken)
    @MainActor var isAppInBackground: Bool { get }
    /// Shows `ChatCompletionNotice`: fixed text plus the conversation UUID only.
    func notifyCompletion(conversationID: UUID) async
    func requestNotificationAuthorization() async -> Bool
}

#if canImport(UIKit)
public struct SystemChatBackgroundRunner: ChatBackgroundRunner {
    public init() {}

    @MainActor
    public func beginTask(expiration: @escaping @MainActor @Sendable () -> Void) -> ChatBackgroundToken {
        let identifier = UIApplication.shared.beginBackgroundTask {
            MainActor.assumeIsolated { expiration() }
        }
        return ChatBackgroundToken(rawValue: identifier.rawValue)
    }

    @MainActor
    public func endTask(_ token: ChatBackgroundToken) {
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: token.rawValue))
    }

    @MainActor
    public var isAppInBackground: Bool {
        UIApplication.shared.applicationState != .active
    }

    public func notifyCompletion(conversationID: UUID) async {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = ChatCompletionNotice.title
        content.body = ChatCompletionNotice.body
        content.userInfo = ChatCompletionNotice.userInfo(for: conversationID)
        let request = UNNotificationRequest(
            identifier: "chat-completion-\(conversationID.uuidString)",
            content: content, trigger: nil)
        try? await center.add(request)
    }

    public func requestNotificationAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
    }
}
#else
public struct SystemChatBackgroundRunner: ChatBackgroundRunner {
    public init() {}

    @MainActor
    public func beginTask(expiration: @escaping @MainActor @Sendable () -> Void) -> ChatBackgroundToken {
        ChatBackgroundToken(rawValue: 0)
    }

    @MainActor
    public func endTask(_ token: ChatBackgroundToken) {}

    @MainActor
    public var isAppInBackground: Bool { false }

    public func notifyCompletion(conversationID: UUID) async {}

    public func requestNotificationAuthorization() async -> Bool { false }
}
#endif
