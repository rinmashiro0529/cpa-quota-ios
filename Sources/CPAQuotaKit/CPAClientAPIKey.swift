import Foundation

/// A CPA client API key used for inference endpoints (`/v1/chat/completions`,
/// `/v1/models`). Like `ManagementKey` it never renders its value.
public struct CPAClientAPIKey: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    let value: String

    public init?(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 4096,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        self.value = trimmed
    }

    /// The raw credential. Only for `Authorization` headers; never log or persist it elsewhere.
    public var exposedValue: String { value }

    /// A display suffix such as `••••wxyz`; too-short keys become just `••••`.
    public var hint: String {
        value.count > 8 ? "••••" + value.suffix(4) : "••••"
    }

    public var description: String { "<redacted client API key>" }
    public var debugDescription: String { description }
}
