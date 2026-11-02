import Foundation

public struct CPAServer: Equatable, Hashable, Sendable, Codable {
    public let baseURL: URL
    public var identifier: String { baseURL.absoluteString }

    public init(baseURL: String) throws {
        let text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains("\\"), let url = URL(string: text) else {
            throw CPAError(.invalidServer)
        }
        try self.init(baseURL: url)
    }

    public init(baseURL: URL) throws {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              !baseURL.absoluteString.contains("\\"),
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            throw CPAError(.invalidServer)
        }
        components.scheme = "https"
        components.host = host.lowercased()
        if components.port == 443 { components.port = nil }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        for suffix in ["/v0/management", "/management.html"] where path.hasSuffix(suffix) {
            path.removeLast(suffix.count)
            break
        }
        while path.hasSuffix("/") { path.removeLast() }
        guard !path.split(separator: "/").contains(where: {
            let decoded = String($0).removingPercentEncoding ?? String($0)
            return decoded == "." || decoded == ".." || decoded.contains("/") || decoded.contains("\\")
        }) else {
            throw CPAError(.invalidServer)
        }
        components.percentEncodedPath = path
        guard let normalized = components.url else { throw CPAError(.invalidServer) }
        self.baseURL = normalized
    }

    private enum CodingKeys: String, CodingKey { case baseURL }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(baseURL: values.decode(URL.self, forKey: .baseURL))
    }

    func endpoint(_ path: String) -> URL {
        baseURL.appendingPathComponent("v0").appendingPathComponent("management")
            .appendingPathComponent(path)
    }
}

public struct ManagementKey: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let value: String

    public init(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 4096,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CPAError(.invalidManagementKey)
        }
        self.value = trimmed
    }

    public var description: String { "<redacted management key>" }
    public var debugDescription: String { description }
}
