import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

nonisolated enum AnthropicAPI {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let version = "2026-10-21"
    static let model = "claude-haiku-5-5"

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
}

/// Next words from Claude for the bounded context. The key is read for every request and no
/// request is made without one. Key, context and response never reach errors or logs.
nonisolated struct AnthropicPredictionProvider: ModelPredictionProvider {
    enum Failure: Error { case noKey, failed }

    static let timeout: TimeInterval = 1.5
    static let maxTokens = 16
    static let system = """
        You predict the next word on a phone keyboard. The user message is text typed so far, ending \
        before the cursor. Reply with up to three likely next words in the text's language, most likely \
        first, one per line, nothing else. Use lowercase unless the word needs a capital at that point.
        """

    let key: @Sendable () -> String?
    var transport: AnthropicAPI.Transport = Self.urlSessionTransport

    func predictions(for request: ModelPredictionRequest) async throws -> [String] {
        guard let key = key()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw Failure.noKey
        }
        let (data, response) = try await transport(try Self.make(key: key, context: request.context))
        return try Self.parse(data: data, response: response)
    }

    static func make(key: String, context: String) throws -> URLRequest {
        let body: [String: Any] = [
            "model": AnthropicAPI.model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": context]],
        ]
        var request = URLRequest(url: AnthropicAPI.endpoint, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(AnthropicAPI.version, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { throw Failure.failed }
        request.httpBody = data
        return request
    }

    /// Words from a complete 200 answer; rate limits, errors and malformed bodies throw.
    static func parse(data: Data, response: URLResponse) throws -> [String] {
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else { throw Failure.failed }
        let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        let words = text.split(whereSeparator: { $0.isNewline || $0 == "," }).map(String.init)
        guard !words.isEmpty else { throw Failure.failed }
        return words
    }

    /// Ephemeral: no cache, cookies or credentials on disk. Task cancellation cancels the request.
    static let urlSessionTransport: AnthropicAPI.Transport = { request in
        try await session.data(for: request)
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return URLSession(configuration: configuration)
    }()
}
