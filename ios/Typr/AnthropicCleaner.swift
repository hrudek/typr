import Foundation

/// Sends one dictation to Anthropic's Messages API. The response body, prompt and key never
/// reach errors or logs: every failure becomes a bare `CleanupModelError`.
typealias AnthropicTransport = AnthropicAPI.Transport

@MainActor
struct AnthropicCleaner: TyprTranscriptCleaning {
    var keys = AnthropicKeyStore()
    var transport: AnthropicTransport = AnthropicCleanupRequest.urlSessionTransport

    var unavailableReason: String? {
        keys.hasKey ? nil : "Add an Anthropic API key to use Claude"
    }

    func makeSession() -> any CleanupSession {
        AnthropicCleanupSession(key: keys.key, transport: transport)
    }
}

@MainActor
final class AnthropicCleanupSession: CleanupSession {
    private let key: String?
    private let transport: AnthropicTransport

    init(key: String?, transport: @escaping AnthropicTransport) {
        self.key = key
        self.transport = transport
    }

    /// Nothing to load: the model runs on Anthropic's servers.
    func prewarm() async {}

    func generate(_ prompt: String) async throws -> String {
        guard let key else { throw CleanupModelError.unavailable }
        let request = try AnthropicCleanupRequest.make(key: key, prompt: prompt,
                                                       maxTokens: AnthropicCleanupRequest.maxTokens(forUTF8Bytes: prompt.utf8.count))
        let data: Data
        let response: URLResponse
        do {
            try Task.checkCancellation()
            (data, response) = try await transport(request)
        } catch {
            // Offline, timed out or cancelled (the coordinator's deadline): no detail is kept.
            throw CleanupModelError.generationFailed
        }
        return try AnthropicCleanupRequest.parse(data: data, response: response)
    }
}

enum AnthropicCleanupRequest {
    static let endpoint = AnthropicAPI.endpoint
    static let version = AnthropicAPI.version
    static let model = AnthropicAPI.model
    static let timeout: TimeInterval = 15

    /// Room for an answer as long as the transcript: half the prompt's bytes plus slack, at most 2048.
    static func maxTokens(forUTF8Bytes bytes: Int) -> Int {
        min(2048, bytes / 2 + 256)
    }

    /// As Hex sends it: the one prompt as the only user message, answered in plain text.
    /// No temperature/top_p/top_k: this API version rejects sampling parameters.
    static func make(key: String, prompt: String, maxTokens: Int) throws -> URLRequest {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": prompt]],
        ]
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(version, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw CleanupModelError.generationFailed
        }
        return request
    }

    static func parse(data: Data, response: URLResponse) throws -> String {
        guard let http = response as? HTTPURLResponse else { throw CleanupModelError.generationFailed }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw CleanupModelError.unavailable // Invalid, revoked or unauthorized key.
        case 429, 529: throw CleanupModelError.rateLimited // Rate limited or overloaded.
        default: throw CleanupModelError.generationFailed
        }
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CleanupModelError.generationFailed
        }
        switch message["stop_reason"] as? String {
        case "refusal": throw CleanupModelError.refused
        case "max_tokens": throw CleanupModelError.generationFailed // A cut-off answer is never pasted.
        default: break
        }
        let blocks = message["content"] as? [[String: Any]] ?? []
        let texts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        guard !texts.isEmpty else { throw CleanupModelError.generationFailed }
        return texts.joined()
    }

    /// Ephemeral: no cache, cookies or credentials on disk. Task cancellation cancels the request.
    static let urlSessionTransport: AnthropicTransport = { request in
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
