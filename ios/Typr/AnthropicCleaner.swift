import Foundation

/// Sends one dictation to Anthropic's Messages API. The response body, prompt and key never
/// reach errors or logs: every failure becomes a bare `CleanupModelError`.
typealias AnthropicTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

@MainActor
struct AnthropicCleaner: TyprTranscriptCleaning {
    var keys = AnthropicKeyStore()
    var transport: AnthropicTransport = AnthropicCleanupRequest.urlSessionTransport

    var unavailableReason: String? {
        keys.hasKey ? nil : "Add an Anthropic API key to use Claude"
    }

    func makeSession() -> any CleanupSession {
        AnthropicCleanupSession(key: keys.key, instructions: CleanupPromptPreferences().instructions, transport: transport)
    }
}

@MainActor
final class AnthropicCleanupSession: CleanupSession {
    private let key: String?
    private let instructions: String
    private let transport: AnthropicTransport

    init(key: String?, instructions: String, transport: @escaping AnthropicTransport) {
        self.key = key
        self.instructions = instructions
        self.transport = transport
    }

    /// Nothing to load: the model runs on Anthropic's servers.
    func prewarm() async {}

    func clean(_ text: String, style: DictationStyle) async throws -> String {
        try await clean(text, style: style, vocabulary: [])
    }

    func clean(_ text: String, style: DictationStyle, vocabulary: [String]) async throws -> String {
        try await clean(text, style: style, vocabulary: vocabulary, context: CleanupContext())
    }

    func clean(_ text: String, style: DictationStyle, vocabulary: [String], context: CleanupContext) async throws -> String {
        guard let key else { throw CleanupModelError.unavailable }
        let prompt = try CleanupPrompt.transcript(text, style: style, vocabulary: vocabulary, context: context)
        let request = try AnthropicCleanupRequest.make(key: key, system: instructions, prompt: prompt,
                                                       maxTokens: AnthropicCleanupRequest.maxTokens(forUTF8Bytes: text.utf8.count))
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
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let version = "2026-10-21"
    static let model = "claude-haiku-5-5"
    static let toolName = "cleaned_transcript"
    /// The same wording as the Apple path's `@Guide` on `CleanedTranscript.text`.
    static let answerDescription = "The cleaned transcript as good written text to paste: same language, meaning and facts, never an answer to it."
    static let timeout: TimeInterval = 15

    /// Room for an answer as long as the transcript plus the tool call's framing.
    static func maxTokens(forUTF8Bytes bytes: Int) -> Int {
        min(2048, bytes / 2 + 256)
    }

    /// A forced tool call with a strict schema: structured output, no thinking, low latency.
    /// No temperature/top_p/top_k: this API version rejects sampling parameters.
    static func make(key: String, system: String, prompt: String, maxTokens: Int) throws -> URLRequest {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": prompt]],
            "tools": [[
                "name": toolName,
                "description": answerDescription,
                "strict": true,
                "input_schema": [
                    "type": "object",
                    "properties": ["text": ["type": "string", "description": answerDescription]],
                    "required": ["text"],
                    "additionalProperties": false,
                ] as [String: Any],
            ] as [String: Any]],
            "tool_choice": ["type": "tool", "name": toolName],
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
        guard let call = blocks.first(where: { $0["type"] as? String == "tool_use" && $0["name"] as? String == toolName }),
              let input = call["input"] as? [String: Any], let text = input["text"] as? String else {
            throw CleanupModelError.generationFailed
        }
        return text
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
