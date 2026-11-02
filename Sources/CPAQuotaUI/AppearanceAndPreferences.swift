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
        case .system: "自动匹配系统的浅色或深色外观"
        case .light: "暖调羊皮纸背景，搭配原生系统控件"
        case .dark: "暖曜石背景与柔和赤陶强调色"
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
        case .remaining: "剩余比例"
        case .used: "已用比例"
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
        case .usage: "CAP 用量"
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
    func loadSharesQuotaWithWidgets() -> Bool
    func saveSharesQuotaWithWidgets(_ enabled: Bool)
    func loadWidgetAccountIdentifiers(for sourceIdentifier: String) -> [String: String]
    func saveWidgetAccountIdentifiers(_ identifiers: [String: String], for sourceIdentifier: String)
    func loadWidgetAccountAliases(for sourceIdentifier: String) -> [String: Int]
    func saveWidgetAccountIdentifiers(_ identifiers: [String: String], aliases: [String: Int], for sourceIdentifier: String)
    func clearWidgetAccountIdentifiers()
}

public extension PreferencesStore {
    // Existing clients opt out until they implement persistence for the explicit sharing choice.
    func loadSharesQuotaWithWidgets() -> Bool { false }
    func saveSharesQuotaWithWidgets(_ enabled: Bool) {}
    func loadWidgetAccountIdentifiers(for sourceIdentifier: String) -> [String: String] { [:] }
    func saveWidgetAccountIdentifiers(_ identifiers: [String: String], for sourceIdentifier: String) {}
    func loadWidgetAccountAliases(for sourceIdentifier: String) -> [String: Int] { [:] }
    func saveWidgetAccountIdentifiers(_ identifiers: [String: String], aliases: [String: Int], for sourceIdentifier: String) {
        saveWidgetAccountIdentifiers(identifiers, for: sourceIdentifier)
    }
    func clearWidgetAccountIdentifiers() {}
}

public final class MemoryPreferencesStore: PreferencesStore, @unchecked Sendable {
    private let lock = NSLock()
    private var serverIdentifier: String?
    private var themeMode: CPAThemeMode
    private var displayMode: QuotaDisplayMode
    private var maskEmail: Bool
    private var sharesQuotaWithWidgets: Bool
    private var widgetSourceIdentifier: String?
    private var widgetAccountIdentifiers: [String: String] = [:]
    private var widgetAccountAliases: [String: Int] = [:]

    public init(
        serverIdentifier: String? = nil,
        themeMode: CPAThemeMode = .system,
        displayMode: QuotaDisplayMode = .remaining,
        maskEmail: Bool = true,
        sharesQuotaWithWidgets: Bool = false
    ) {
        self.serverIdentifier = serverIdentifier
        self.themeMode = themeMode
        self.displayMode = displayMode
        self.maskEmail = maskEmail
        self.sharesQuotaWithWidgets = sharesQuotaWithWidgets
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

    public func loadSharesQuotaWithWidgets() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sharesQuotaWithWidgets
    }

    public func saveSharesQuotaWithWidgets(_ enabled: Bool) {
        lock.lock()
        sharesQuotaWithWidgets = enabled
        lock.unlock()
    }

    public func loadWidgetAccountIdentifiers(for sourceIdentifier: String) -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return widgetSourceIdentifier == sourceIdentifier ? widgetAccountIdentifiers : [:]
    }

    public func saveWidgetAccountIdentifiers(_ identifiers: [String: String], for sourceIdentifier: String) {
        saveWidgetAccountIdentifiers(identifiers, aliases: [:], for: sourceIdentifier)
    }

    public func loadWidgetAccountAliases(for sourceIdentifier: String) -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return widgetSourceIdentifier == sourceIdentifier ? widgetAccountAliases : [:]
    }

    public func saveWidgetAccountIdentifiers(_ identifiers: [String: String], aliases: [String: Int], for sourceIdentifier: String) {
        lock.lock()
        widgetSourceIdentifier = sourceIdentifier
        widgetAccountIdentifiers = identifiers
        widgetAccountAliases = aliases
        lock.unlock()
    }

    public func clearWidgetAccountIdentifiers() {
        lock.lock()
        widgetSourceIdentifier = nil
        widgetAccountIdentifiers = [:]
        widgetAccountAliases = [:]
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
        static let sharesQuotaWithWidgets = "sharesQuotaWithWidgets"
        static let widgetIdentityRecord = "widgetIdentityRecordV1"
    }

    private struct WidgetIdentityRecord: Codable {
        let version: Int
        let sourceIdentifier: String
        let identifiers: [String: String]
        let aliases: [String: Int]

        init(version: Int, sourceIdentifier: String, identifiers: [String: String], aliases: [String: Int]) {
            self.version = version
            self.sourceIdentifier = sourceIdentifier
            self.identifiers = identifiers
            self.aliases = aliases
        }

        private enum CodingKeys: String, CodingKey { case version, sourceIdentifier, identifiers, aliases }
        private struct AliasKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            sourceIdentifier = try container.decode(String.self, forKey: .sourceIdentifier)
            identifiers = try container.decode([String: String].self, forKey: .identifiers)
            if let values = try? container.nestedContainer(keyedBy: AliasKey.self, forKey: .aliases) {
                var decoded: [String: Int] = [:]
                for key in values.allKeys {
                    if let value = try? values.decode(Int.self, forKey: key) { decoded[key.stringValue] = value }
                }
                aliases = decoded
            } else {
                aliases = [:]
            }
        }
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

    public func loadSharesQuotaWithWidgets() -> Bool {
        defaults.bool(forKey: keyPrefix + Keys.sharesQuotaWithWidgets)
    }

    public func saveSharesQuotaWithWidgets(_ enabled: Bool) {
        defaults.set(enabled, forKey: keyPrefix + Keys.sharesQuotaWithWidgets)
    }

    // Stored only in the containing app's preferences, never in the App Group.
    public func loadWidgetAccountIdentifiers(for sourceIdentifier: String) -> [String: String] {
        guard let data = defaults.data(forKey: keyPrefix + Keys.widgetIdentityRecord),
              let record = try? JSONDecoder().decode(WidgetIdentityRecord.self, from: data),
              record.version == 1, record.sourceIdentifier == sourceIdentifier else { return [:] }
        return record.identifiers
    }

    public func loadWidgetAccountAliases(for sourceIdentifier: String) -> [String: Int] {
        guard let data = defaults.data(forKey: keyPrefix + Keys.widgetIdentityRecord),
              let record = try? JSONDecoder().decode(WidgetIdentityRecord.self, from: data),
              record.version == 1, record.sourceIdentifier == sourceIdentifier else { return [:] }
        return record.aliases
    }

    public func saveWidgetAccountIdentifiers(_ identifiers: [String: String], for sourceIdentifier: String) {
        saveWidgetAccountIdentifiers(identifiers, aliases: [:], for: sourceIdentifier)
    }

    public func saveWidgetAccountIdentifiers(_ identifiers: [String: String], aliases: [String: Int], for sourceIdentifier: String) {
        // Publish source, IDs and aliases as one value.
        let record = WidgetIdentityRecord(version: 1, sourceIdentifier: sourceIdentifier, identifiers: identifiers, aliases: aliases)
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: keyPrefix + Keys.widgetIdentityRecord)
    }

    public func clearWidgetAccountIdentifiers() {
        defaults.removeObject(forKey: keyPrefix + Keys.widgetIdentityRecord)
    }
}
