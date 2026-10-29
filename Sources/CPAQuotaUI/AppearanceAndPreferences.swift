import Foundation

public enum CPAThemeMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色羊皮纸"
        case .dark: "深色曜石"
        }
    }

    public var subtitle: String {
        switch self {
        case .system: "自动匹配 iOS 系统深浅色外观设置"
        case .light: "Claude 暖调羊皮纸基底与高透液态玻璃"
        case .dark: "深邃暖曜石基底与低眩光暗珀液态玻璃"
        }
    }

    public var symbolName: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon.stars"
        }
    }
}

public enum QuotaDisplayMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case remaining
    case used

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .remaining: "剩余可用比例 (Remaining)"
        case .used: "已用额度比例 (Used)"
        }
    }

    public var shortTitle: String {
        switch self {
        case .remaining: "剩余可用 %"
        case .used: "已用比例 %"
        }
    }
}

public enum CPAWorkspaceTab: String, CaseIterable, Codable, Sendable, Identifiable {
    case quotas
    case usage
    case monitoring
    case accounts
    case connection

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .quotas: "额度总览"
        case .usage: "CAP用量"
        case .monitoring: "监控与活动"
        case .accounts: "账号诊断"
        case .connection: "连接管理"
        }
    }

    public var symbolName: String {
        switch self {
        case .quotas: "chart.bar.xaxis"
        case .usage: "waveform.path.ecg.rectangle"
        case .monitoring: "bell.badge.waveform"
        case .accounts: "person.2.badge.gearshape"
        case .connection: "lock.shield"
        }
    }
}

public enum AccountFilterCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case all
    case active
    case codex
    case plugin
    case attention

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "全部"
        case .active: "启用中"
        case .codex: "Codex"
        case .plugin: "插件与其他"
        case .attention: "异常或停用"
        }
    }
}

public protocol PreferencesStore: Sendable {
    func loadSavedServerIdentifier() -> String?
    func saveServerIdentifier(_ identifier: String?)
    func loadThemeMode() -> CPAThemeMode
    func saveThemeMode(_ mode: CPAThemeMode)
    func loadDisplayMode() -> QuotaDisplayMode
    func saveDisplayMode(_ mode: QuotaDisplayMode)
    func loadMaskEmail() -> Bool
    func saveMaskEmail(_ mask: Bool)
}

public final class MemoryPreferencesStore: PreferencesStore, @unchecked Sendable {
    private let lock = NSLock()
    private var serverIdentifier: String?
    private var themeMode: CPAThemeMode
    private var displayMode: QuotaDisplayMode
    private var maskEmail: Bool

    public init(
        serverIdentifier: String? = nil,
        themeMode: CPAThemeMode = .system,
        displayMode: QuotaDisplayMode = .remaining,
        maskEmail: Bool = true
    ) {
        self.serverIdentifier = serverIdentifier
        self.themeMode = themeMode
        self.displayMode = displayMode
        self.maskEmail = maskEmail
    }

    public func loadSavedServerIdentifier() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return serverIdentifier
    }

    public func saveServerIdentifier(_ identifier: String?) {
        lock.lock()
        serverIdentifier = identifier
        lock.unlock()
    }

    public func loadThemeMode() -> CPAThemeMode {
        lock.lock()
        defer { lock.unlock() }
        return themeMode
    }

    public func saveThemeMode(_ mode: CPAThemeMode) {
        lock.lock()
        themeMode = mode
        lock.unlock()
    }

    public func loadDisplayMode() -> QuotaDisplayMode {
        lock.lock()
        defer { lock.unlock() }
        return displayMode
    }

    public func saveDisplayMode(_ mode: QuotaDisplayMode) {
        lock.lock()
        displayMode = mode
        lock.unlock()
    }

    public func loadMaskEmail() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return maskEmail
    }

    public func saveMaskEmail(_ mask: Bool) {
        lock.lock()
        maskEmail = mask
        lock.unlock()
    }
}

public final class UserDefaultsPreferencesStore: PreferencesStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let keyPrefix: String

    private enum Keys {
        static let serverIdentifier = "savedServerIdentifier"
        static let themeMode = "themeMode"
        static let displayMode = "displayMode"
        static let maskEmail = "maskEmail"
    }

    public init(suiteName: String? = nil, keyPrefix: String = "CPAQuotaUI.") {
        if let suiteName, let custom = UserDefaults(suiteName: suiteName) {
            self.defaults = custom
        } else {
            self.defaults = .standard
        }
        self.keyPrefix = keyPrefix
    }

    public func loadSavedServerIdentifier() -> String? {
        defaults.string(forKey: keyPrefix + Keys.serverIdentifier)
    }

    public func saveServerIdentifier(_ identifier: String?) {
        let key = keyPrefix + Keys.serverIdentifier
        if let identifier, !identifier.isEmpty {
            defaults.set(identifier, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    public func loadThemeMode() -> CPAThemeMode {
        guard let raw = defaults.string(forKey: keyPrefix + Keys.themeMode),
              let mode = CPAThemeMode(rawValue: raw) else {
            return .system
        }
        return mode
    }

    public func saveThemeMode(_ mode: CPAThemeMode) {
        defaults.set(mode.rawValue, forKey: keyPrefix + Keys.themeMode)
    }

    public func loadDisplayMode() -> QuotaDisplayMode {
        guard let raw = defaults.string(forKey: keyPrefix + Keys.displayMode),
              let mode = QuotaDisplayMode(rawValue: raw) else {
            return .remaining
        }
        return mode
    }

    public func saveDisplayMode(_ mode: QuotaDisplayMode) {
        defaults.set(mode.rawValue, forKey: keyPrefix + Keys.displayMode)
    }

    public func loadMaskEmail() -> Bool {
        let key = keyPrefix + Keys.maskEmail
        if defaults.object(forKey: key) == nil {
            return true
        }
        return defaults.bool(forKey: key)
    }

    public func saveMaskEmail(_ mask: Bool) {
        defaults.set(mask, forKey: keyPrefix + Keys.maskEmail)
    }
}
