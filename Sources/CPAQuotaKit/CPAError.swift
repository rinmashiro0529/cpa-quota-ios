import Foundation

public struct CPAError: Error, Codable, Equatable, Sendable, LocalizedError {
    public enum Kind: String, Codable, Sendable {
        case invalidServer
        case invalidManagementKey
        case managementUnauthorized
        case managementForbidden
        case endpointUnavailable
        case requestRejected
        case accountNotFound
        case accountDisabled
        case unsupportedProvider
        case upstreamUnauthorized
        case upstreamFailure
        case rateLimited
        case network
        case timeout
        case cancelled
        case invalidResponse
        case responseTooLarge
        case redirectRefused
        case secureStorageUnavailable
        case secureStorageFailure
    }

    public enum Layer: String, Codable, Sendable {
        case management
        case upstream
    }

    public let kind: Kind
    public let layer: Layer?
    public let statusCode: Int?
    public let retryAfter: Date?

    public init(_ kind: Kind, layer: Layer? = nil, statusCode: Int? = nil, retryAfter: Date? = nil) {
        self.kind = kind
        self.layer = layer
        self.statusCode = statusCode
        self.retryAfter = retryAfter
    }

    public var errorDescription: String? {
        switch kind {
        case .invalidServer: "Enter an HTTPS CPA server address without credentials, a query, or a fragment."
        case .invalidManagementKey: "Enter a nonempty management key without control characters."
        case .managementUnauthorized: "The CPA management key is missing or invalid."
        case .managementForbidden: "CPA management access is forbidden or temporarily blocked."
        case .endpointUnavailable: "This CPA endpoint is not available."
        case .requestRejected: "CPA rejected the quota request."
        case .accountNotFound: "Reload the account list before querying this account."
        case .accountDisabled: "This account is disabled."
        case .unsupportedProvider: "No supported quota reader is available for this account."
        case .upstreamUnauthorized: "The upstream account needs authorization or lacks permission."
        case .upstreamFailure: "The upstream quota request failed."
        case .rateLimited: "Quota requests are temporarily rate limited."
        case .network: "The CPA server could not be reached securely."
        case .timeout: "The quota request timed out."
        case .cancelled: "The quota request was cancelled."
        case .invalidResponse: "The server returned an invalid or unsupported quota response."
        case .responseTooLarge: "The server response exceeded the size limit."
        case .redirectRefused: "The server attempted to redirect a management request."
        case .secureStorageUnavailable: "Secure credential storage is unavailable on this platform."
        case .secureStorageFailure: "Secure credential storage could not complete the operation."
        }
    }

    static func normalize(_ error: any Error) -> CPAError {
        if let error = error as? CPAError { return error }
        if error is CancellationError { return CPAError(.cancelled) }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: return CPAError(.cancelled)
            case .timedOut: return CPAError(.timeout)
            default: return CPAError(.network)
            }
        }
        return CPAError(.invalidResponse)
    }
}

extension CPAError {
    var isManagementBlocking: Bool {
        kind == .managementUnauthorized || kind == .managementForbidden ||
            (kind == .rateLimited && layer == .management)
    }
}
