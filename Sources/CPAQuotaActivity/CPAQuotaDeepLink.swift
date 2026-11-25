import Foundation

/// Links are navigation hints only. They never contain a bearer, account ID,
/// activity token, server address, or authorization to start a monitoring lease.
public enum CPAQuotaDeepLink: Equatable, Sendable {
    case quotas
    case monitoring(sourceID: String)

    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "cpaquota",
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil, components.path.isEmpty || components.path == "/" else { return nil }
        switch components.host?.lowercased() {
        case "quotas":
            guard components.queryItems?.isEmpty ?? true else { return nil }
            self = .quotas
        case "monitor":
            guard let query = components.queryItems, query.count == 1,
                  query[0].name == "source", let sourceID = query[0].value,
                  (try? CPAQuotaActivityAttributes(sourceID: sourceID)) != nil else { return nil }
            self = .monitoring(sourceID: sourceID)
        default:
            return nil
        }
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = "cpaquota"
        switch self {
        case .quotas:
            components.host = "quotas"
        case .monitoring(let sourceID):
            // Invalid programmer input is a harmless dashboard link; external
            // URLs are still strictly rejected by init(url:).
            guard (try? CPAQuotaActivityAttributes(sourceID: sourceID)) != nil else {
                return CPAQuotaDeepLink.quotas.url
            }
            components.host = "monitor"
            components.queryItems = [URLQueryItem(name: "source", value: sourceID)]
        }
        // The scheme/host are constants and the sole query value is encoded by
        // URLComponents. This construction cannot contain arbitrary URL syntax.
        return components.url!
    }
}
