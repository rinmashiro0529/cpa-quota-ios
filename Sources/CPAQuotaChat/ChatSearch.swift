// Request shapes adapted from robert-garay/openchat (MIT License).
// Copyright (c) 2026 Robert Garay <robert@genion.ai>
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ChatSearchError: Error, Equatable, Sendable {
    case emptyQuery
    case missingKey
    case httpError(statusCode: Int)
    case invalidResponse
}

public protocol ChatSearchClient: Sendable {
    func search(_ query: String, apiKey: String) async throws -> [ChatSearchSource]
}

/// Provider factory used by `ChatWorkspaceModel`.
public enum ChatSearch {
    public static func client(for provider: ChatSearchProvider) -> any ChatSearchClient {
        switch provider {
        case .tavily: TavilySearchClient()
        case .brave: BraveSearchClient()
        case .exa: ExaSearchClient()
        case .serper: SerperSearchClient()
        case .serpAPI: SerpAPISearchClient()
        }
    }
}

private let maximumResults = 5

private func makeSearchSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    return URLSession(configuration: configuration)
}

private func requireQuery(_ query: String) throws -> String {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw ChatSearchError.emptyQuery }
    return trimmed
}

private func requireKey(_ apiKey: String) throws -> String {
    let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw ChatSearchError.missingKey }
    return trimmed
}

private func fetch(_ session: URLSession, _ request: URLRequest) async throws -> Data {
    let data: Data
    let response: URLResponse
    do { (data, response) = try await session.data(for: request) }
    catch { throw error }
    guard let http = response as? HTTPURLResponse else { throw ChatSearchError.invalidResponse }
    guard (200..<300).contains(http.statusCode) else {
        throw ChatSearchError.httpError(statusCode: http.statusCode)
    }
    return data
}

public struct TavilySearchClient: ChatSearchClient {
    private let session: URLSession
    private let endpoint = URL(string: "https://api.tavily.com/search")!

    public init(session: URLSession? = nil) { self.session = session ?? makeSearchSession() }

    public func search(_ query: String, apiKey: String) async throws -> [ChatSearchSource] {
        let query = try requireQuery(query)
        let apiKey = try requireKey(apiKey)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(RequestBody(query: query))
        let data = try await fetch(session, request)
        guard let decoded = try? JSONDecoder().decode(APIResponse.self, from: data) else {
            throw ChatSearchError.invalidResponse
        }
        return (decoded.results ?? []).prefix(maximumResults).compactMap { item in
            guard let title = item.title, let raw = item.url, let url = URL(string: raw) else {
                return nil
            }
            return ChatSearchSource(title: title, url: url, snippet: item.content ?? "")
        }
    }

    private struct RequestBody: Encodable {
        var query: String
        var maxResults = maximumResults
        var includeAnswer = true
        var searchDepth = "basic"

        enum CodingKeys: String, CodingKey {
            case query
            case maxResults = "max_results"
            case includeAnswer = "include_answer"
            case searchDepth = "search_depth"
        }
    }

    private struct APIResponse: Decodable {
        var results: [APIResult]?
    }

    private struct APIResult: Decodable {
        var title: String?
        var url: String?
        var content: String?
    }
}

public struct BraveSearchClient: ChatSearchClient {
    private let session: URLSession
    private let endpoint = URL(string: "https://api.search.brave.com/res/v1/web/search")!

    public init(session: URLSession? = nil) { self.session = session ?? makeSearchSession() }

    public func search(_ query: String, apiKey: String) async throws -> [ChatSearchSource] {
        let query = try requireQuery(query)
        let apiKey = try requireKey(apiKey)
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: String(maximumResults)),
        ]
        guard let url = components.url else { throw ChatSearchError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        let data = try await fetch(session, request)
        guard let decoded = try? JSONDecoder().decode(APIResponse.self, from: data) else {
            throw ChatSearchError.invalidResponse
        }
        return (decoded.web?.results ?? []).prefix(maximumResults).compactMap { item in
            guard let title = item.title, let raw = item.url, let url = URL(string: raw) else {
                return nil
            }
            return ChatSearchSource(title: title, url: url, snippet: item.description ?? "")
        }
    }

    private struct APIResponse: Decodable {
        var web: Web?

        struct Web: Decodable {
            var results: [APIResult]?
        }

        struct APIResult: Decodable {
            var title: String?
            var url: String?
            var description: String?
        }
    }
}

public struct ExaSearchClient: ChatSearchClient {
    private let session: URLSession
    private let endpoint = URL(string: "https://api.exa.ai/search")!

    public init(session: URLSession? = nil) { self.session = session ?? makeSearchSession() }

    public func search(_ query: String, apiKey: String) async throws -> [ChatSearchSource] {
        let query = try requireQuery(query)
        let apiKey = try requireKey(apiKey)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(
            RequestBody(query: query, numResults: maximumResults,
                        contents: .init(text: .init(maxCharacters: 1000))))
        let data = try await fetch(session, request)
        guard let decoded = try? JSONDecoder().decode(APIResponse.self, from: data) else {
            throw ChatSearchError.invalidResponse
        }
        return (decoded.results ?? []).prefix(maximumResults).compactMap { item in
            guard let title = item.title, let raw = item.url, let url = URL(string: raw) else {
                return nil
            }
            return ChatSearchSource(title: title, url: url, snippet: item.text ?? item.summary ?? "")
        }
    }

    private struct RequestBody: Encodable {
        var query: String
        var numResults: Int
        var contents: Contents

        struct Contents: Encodable {
            var text: TextOptions
        }

        struct TextOptions: Encodable {
            var maxCharacters: Int
        }
    }

    private struct APIResponse: Decodable {
        var results: [APIResult]?
    }

    private struct APIResult: Decodable {
        var title: String?
        var url: String?
        var text: String?
        var summary: String?
    }
}

public struct SerperSearchClient: ChatSearchClient {
    private let session: URLSession
    private let endpoint = URL(string: "https://google.serper.dev/search")!

    public init(session: URLSession? = nil) { self.session = session ?? makeSearchSession() }

    public func search(_ query: String, apiKey: String) async throws -> [ChatSearchSource] {
        let query = try requireQuery(query)
        let apiKey = try requireKey(apiKey)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-KEY")
        request.httpBody = try JSONEncoder().encode(RequestBody(q: query, num: maximumResults))
        let data = try await fetch(session, request)
        guard let decoded = try? JSONDecoder().decode(APIResponse.self, from: data) else {
            throw ChatSearchError.invalidResponse
        }
        return (decoded.organic ?? []).prefix(maximumResults).compactMap { item in
            guard let title = item.title, let raw = item.link, let url = URL(string: raw) else {
                return nil
            }
            return ChatSearchSource(title: title, url: url, snippet: item.snippet ?? "")
        }
    }

    private struct RequestBody: Encodable {
        var q: String
        var num: Int
    }

    private struct APIResponse: Decodable {
        var organic: [Organic]?

        struct Organic: Decodable {
            var title: String?
            var link: String?
            var snippet: String?
        }
    }
}

public struct SerpAPISearchClient: ChatSearchClient {
    private let session: URLSession
    private let endpoint = URL(string: "https://serpapi.com/search.json")!

    public init(session: URLSession? = nil) { self.session = session ?? makeSearchSession() }

    public func search(_ query: String, apiKey: String) async throws -> [ChatSearchSource] {
        let query = try requireQuery(query)
        let apiKey = try requireKey(apiKey)
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "engine", value: "google"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "num", value: String(maximumResults)),
        ]
        guard let url = components.url else { throw ChatSearchError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await fetch(session, request)
        guard let decoded = try? JSONDecoder().decode(APIResponse.self, from: data) else {
            throw ChatSearchError.invalidResponse
        }
        return (decoded.organicResults ?? []).prefix(maximumResults).compactMap { item in
            guard let title = item.title, let raw = item.link, let url = URL(string: raw) else {
                return nil
            }
            return ChatSearchSource(title: title, url: url, snippet: item.snippet ?? "")
        }
    }

    private struct APIResponse: Decodable {
        var organicResults: [Organic]?

        enum CodingKeys: String, CodingKey {
            case organicResults = "organic_results"
        }

        struct Organic: Decodable {
            var title: String?
            var link: String?
            var snippet: String?
        }
    }
}
