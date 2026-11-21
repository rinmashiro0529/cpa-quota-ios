import Foundation
#if canImport(UIKit)
import UIKit
import UserNotifications
#endif

public struct ChatBackgroundToken: Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }
}

/// Background-task and local-notification surface for generations that keep
/// running after the app leaves the foreground. Injectable for tests.
public protocol ChatBackgroundRunner: Sendable {
    @MainActor func beginTask(expiration: @escaping @MainActor @Sendable () -> Void) -> ChatBackgroundToken
    @MainActor func endTask(_ token: ChatBackgroundToken)
    @MainActor var isAppInBackground: Bool { get }
    /// Notification body is the conversation title only — never message content.
    func notifyCompletion(conversationID: UUID, title: String) async
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

    public func notifyCompletion(conversationID: UUID, title: String) async {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "AI 对话已完成"
        content.body = title
        content.userInfo = ["conversationID": conversationID.uuidString]
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

    public func notifyCompletion(conversationID: UUID, title: String) async {}

    public func requestNotificationAuthorization() async -> Bool { false }
}
#endif
