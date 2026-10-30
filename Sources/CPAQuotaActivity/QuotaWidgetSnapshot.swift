import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

public enum QuotaWidgetSnapshotError: Error, Equatable, Sendable {
    case invalidEntry
    case invalidSnapshot
    case sharedContainerUnavailable
}

/// A deliberately small, credential-free projection, not a copy of CPAAccount.
/// The app owns the private mapping from this opaque UUID to its account/window.
public struct QuotaWidgetEntry: Codable, Hashable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable { case ready, stale, unavailable, failed }
    public let id: String
    public let label: String
    public let provider: String
    public let windowLabel: String
    public let remainingFraction: Double?
    public let value: Double?
    public let unit: String?
    public let observedAt: Date?
    public let validUntil: Date?
    public let status: Status

    public init(
        id: String, label: String, provider: String, windowLabel: String,
        remainingFraction: Double? = nil, value: Double? = nil, unit: String? = nil,
        observedAt: Date? = nil, validUntil: Date? = nil, status: Status
    ) throws {
        guard let opaqueID = UUID(uuidString: id),
              Self.safeDisplay(label), Self.safeDisplay(provider), Self.safeDisplay(windowLabel),
              unit.map(Self.safeDisplay) ?? true,
              remainingFraction.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
              value.map(\.isFinite) ?? true,
              observedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
              validUntil.map({ $0.timeIntervalSince1970.isFinite }) ?? true else {
            throw QuotaWidgetSnapshotError.invalidEntry
        }
        self.id = opaqueID.uuidString
        self.label = label
        self.provider = provider
        self.windowLabel = windowLabel
        self.remainingFraction = remainingFraction
        self.value = value
        self.unit = unit
        self.observedAt = observedAt
        self.validUntil = validUntil
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, provider, windowLabel, remainingFraction, value, unit, observedAt, validUntil, status
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(String.self, forKey: .id),
            label: values.decode(String.self, forKey: .label),
            provider: values.decode(String.self, forKey: .provider),
            windowLabel: values.decode(String.self, forKey: .windowLabel),
            remainingFraction: values.decodeIfPresent(Double.self, forKey: .remainingFraction),
            value: values.decodeIfPresent(Double.self, forKey: .value),
            unit: values.decodeIfPresent(String.self, forKey: .unit),
            observedAt: values.decodeIfPresent(Date.self, forKey: .observedAt),
            validUntil: values.decodeIfPresent(Date.self, forKey: .validUntil),
            status: values.decode(Status.self, forKey: .status)
        )
    }

    /// Match the app's 300-second observation-age policy unless the publisher
    /// supplies a stricter validity boundary. A UI refresh never resets this age.
    public func status(at date: Date) -> Status {
        guard status == .ready else { return status }
        guard let observedAt else { return .unavailable }
        let age = date.timeIntervalSince(observedAt)
        let deadline = min(validUntil ?? observedAt.addingTimeInterval(300), observedAt.addingTimeInterval(300))
        guard age.isFinite, age >= -60, date < deadline else { return .stale }
        return .ready
    }

    public var staleDate: Date? {
        guard let observedAt else { return nil }
        return min(validUntil ?? observedAt.addingTimeInterval(300), observedAt.addingTimeInterval(300))
    }

    public var formattedValue: String {
        if let remainingFraction { return String(format: "%.0f%%", remainingFraction * 100) }
        if let value {
            if abs(value) >= 1_000_000 || (value != 0 && abs(value) < 0.005) {
                return value.formatted(.number.notation(.scientific).precision(.significantDigits(1...6)))
                    + (unit.map { " " + $0 } ?? "")
            }
            return value.formatted(.number.precision(.fractionLength(0...2))) + (unit.map { " " + $0 } ?? "")
        }
        return "未知"
    }

    private static func safeDisplay(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= 128
            && !text.contains("@") && !lowered.contains("://") && !lowered.contains("www.")
            && !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

public struct QuotaWidgetSnapshot: Codable, Hashable, Sendable {
    public static let maximumEntries = 64
    public static let maximumEncodedBytes = 65_536
    public let version: Int
    public let generatedAt: Date
    public let entries: [QuotaWidgetEntry]

    public init(generatedAt: Date, entries: [QuotaWidgetEntry]) throws {
        guard generatedAt.timeIntervalSince1970.isFinite,
              entries.count <= Self.maximumEntries, Set(entries.map(\.id)).count == entries.count else {
            throw QuotaWidgetSnapshotError.invalidSnapshot
        }
        version = 1
        self.generatedAt = generatedAt
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey { case version, generatedAt, entries }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .version) == 1 else {
            throw QuotaWidgetSnapshotError.invalidSnapshot
        }
        try self.init(generatedAt: values.decode(Date.self, forKey: .generatedAt),
                      entries: values.decode([QuotaWidgetEntry].self, forKey: .entries))
    }
}

/// No network or Keychain access. Missing entitlements fail closed instead of
/// falling back to a non-shared preferences domain or persisting credentials.
public struct SharedQuotaWidgetSnapshotStore: Sendable {
    public static let appGroupIdentifier = "group.icu.nahida.cpaquota"
    public static let widgetKind = "CPAQuotaWidget"
    private static let filename = "quota-widget-snapshot-v1.json"
    private let directoryURL: URL?
    private let reloadsWidgets: Bool

    public init(appGroupIdentifier: String = SharedQuotaWidgetSnapshotStore.appGroupIdentifier) {
        reloadsWidgets = true
        #if os(iOS) || os(macOS)
        directoryURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
        #else
        directoryURL = nil
        #endif
    }

    /// Isolated file-system injection for contract tests; production uses the
    /// security application group initializer above.
    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
        reloadsWidgets = false
    }

    public func read() -> QuotaWidgetSnapshot? {
        guard let url = fileURL,
              let metadata = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              metadata.isRegularFile == true,
              let count = metadata.fileSize, count <= QuotaWidgetSnapshot.maximumEncodedBytes,
              let data = try? Data(contentsOf: url), data.count <= QuotaWidgetSnapshot.maximumEncodedBytes else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(QuotaWidgetSnapshot.self, from: data)
    }

    public func write(_ snapshot: QuotaWidgetSnapshot) throws {
        guard let directoryURL, let url = fileURL else { throw QuotaWidgetSnapshotError.sharedContainerUnavailable }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(snapshot)
        guard data.count <= QuotaWidgetSnapshot.maximumEncodedBytes else { throw QuotaWidgetSnapshotError.invalidSnapshot }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        reloadWidgets()
    }

    public func clear() throws {
        guard let url = fileURL else { throw QuotaWidgetSnapshotError.sharedContainerUnavailable }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        reloadWidgets()
    }

    private var fileURL: URL? { directoryURL?.appendingPathComponent(Self.filename, isDirectory: false) }

    private func reloadWidgets() {
        guard reloadsWidgets else { return }
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
        #endif
    }
}
