import Foundation

public struct AccountIdentity: Sendable, Equatable {
    public let label: String

    public init(account: CPAAccount, ordinal: Int) {
        self.label = "Account \(max(1, ordinal))"
    }
}
