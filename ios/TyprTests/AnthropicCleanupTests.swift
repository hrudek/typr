import XCTest
@testable import Typr

@MainActor
final class MemorySecret: SecretStoring {
    var value: String?
    init(_ value: String? = nil) { self.value = value }
    func read() -> String? { value }
    func write(_ value: String) -> Bool { self.value = value; return true }
    func delete() { value = nil }
}

/// Records what the cleanup sent and answers with a canned response. Sendable: the transport
/// runs off the main actor.
final class AnthropicTransportProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var _started = false
    private var _cancelled = false
    var status = 200
    var body = Data()
    var failure: (any Error)?
    var plainResponse = false
    var waitForCancellation = false

    var requests: [URLRequest] { lock.withLock { _requests } }
    var started: Bool { lock.withLock { _started } }
    var cancelled: Bool { lock.withLock { _cancelled } }

    var transport: AnthropicTransport {
        { [self] request in
            lock.withLock { _requests.append(request); _started = true }
            if waitForCancellation {
                do { try await Task.sleep(for: .seconds(30)) } catch {
                    lock.withLock { _cancelled = true }
                    throw URLError(.cancelled)
                }
            }
            if let failure { throw failure }
            let response: URLResponse = plainResponse
                ? URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
                : HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (body, response)
        }
    }

    static func message(text: String = "Hello there, world.", stopReason: String = "end_turn") -> Data {
        let json: [String: Any] = [
            "type": "message", "role": "assistant", "stop_reason": stopReason,
            "content": [["type": "text", "text": text]],
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }
}

@MainActor
final class AnthropicCleanupTests: XCTestCase {
    private func session(_ probe: AnthropicTransportProbe, key: String? = "sk-ant-test") -> AnthropicCleanupSession {
        AnthropicCleanupSession(key: key, transport: probe.transport)
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    /// As Hex: the whole prompt is the one user message; no system prompt, tool or sampling.
    func testRequestSendsThePromptAsTheOnlyUserMessage() async throws {
        let probe = AnthropicTransportProbe()
        probe.body = AnthropicTransportProbe.message()
        let prompt = CleanupPrompt.make("hello there world", vocabulary: ["Typr"], context: CleanupContext(application: "com.apple.MobileSMS"))
        _ = try await session(probe).generate(prompt)

        let request = try XCTUnwrap(probe.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        XCTAssertEqual(request.value(forHTTPHeaderField: "content-type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 15)

        let json = try body(request)
        XCTAssertEqual(json["model"] as? String, "claude-haiku-5-5")
        XCTAssertEqual(json["max_tokens"] as? Int, AnthropicCleanupRequest.maxTokens(forUTF8Bytes: prompt.utf8.count))
        for absent in ["system", "tools", "tool_choice", "temperature", "top_p", "top_k", "thinking"] {
            XCTAssertNil(json[absent], absent)
        }
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[0]["content"] as? String, prompt)
    }

    func testMaxTokensGrowsWithThePromptAndIsCapped() {
        XCTAssertEqual(AnthropicCleanupRequest.maxTokens(forUTF8Bytes: 0), 256)
        XCTAssertEqual(AnthropicCleanupRequest.maxTokens(forUTF8Bytes: 1000), 756)
        XCTAssertEqual(AnthropicCleanupRequest.maxTokens(forUTF8Bytes: 10_000), 2048)
    }

    func testTextAnswerIsReturned() async throws {
        let probe = AnthropicTransportProbe()
        probe.body = AnthropicTransportProbe.message(text: "Hello there, world.")
        let answer = try await session(probe).generate("prompt")
        XCTAssertEqual(answer, "Hello there, world.")
    }

    func testFailuresMapToBareCleanupErrors() async {
        let ok = AnthropicTransportProbe.message()
        let toolOnly = try! JSONSerialization.data(withJSONObject: [
            "stop_reason": "tool_use", "content": [["type": "tool_use", "name": "x", "input": ["text": "Hi"]]],
        ] as [String: Any])
        let cases: [(String, (AnthropicTransportProbe) -> Void, CleanupModelError)] = [
            ("401", { $0.status = 401; $0.body = Data(#"{"type":"error"}"#.utf8) }, .unavailable),
            ("403", { $0.status = 403 }, .unavailable),
            ("429", { $0.status = 429 }, .rateLimited),
            ("529", { $0.status = 529 }, .rateLimited),
            ("400", { $0.status = 400 }, .generationFailed),
            ("500", { $0.status = 500; $0.body = ok }, .generationFailed),
            ("refusal", { $0.body = AnthropicTransportProbe.message(stopReason: "refusal") }, .refused),
            ("max_tokens", { $0.body = AnthropicTransportProbe.message(stopReason: "max_tokens") }, .generationFailed),
            ("no text block", { $0.body = toolOnly }, .generationFailed),
            ("not JSON", { $0.body = Data("<html>".utf8) }, .generationFailed),
            ("missing text", { $0.body = Data(#"{"content":[{"type":"text"}]}"#.utf8) }, .generationFailed),
            ("offline", { $0.failure = URLError(.notConnectedToInternet) }, .generationFailed),
            ("timeout", { $0.failure = URLError(.timedOut) }, .generationFailed),
            ("not HTTP", { $0.plainResponse = true; $0.body = ok }, .generationFailed),
        ]
        for (name, configure, expected) in cases {
            let probe = AnthropicTransportProbe()
            probe.body = ok
            configure(probe)
            do {
                _ = try await session(probe).generate("hello there world")
                XCTFail("\(name) returned an answer")
            } catch {
                XCTAssertEqual(error as? CleanupModelError, expected, name)
            }
        }
    }

    func testCancellationCancelsTheRequest() async throws {
        let probe = AnthropicTransportProbe()
        probe.waitForCancellation = true
        let session = session(probe)
        let task = Task { try await session.generate("hello there world") }
        try await waitForState("request sent") { probe.started }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled request returned an answer")
        } catch {
            XCTAssertEqual(error as? CleanupModelError, .generationFailed)
        }
        XCTAssertTrue(probe.cancelled)
    }

    func testAlreadyCancelledTaskSendsNothing() async {
        let probe = AnthropicTransportProbe()
        let session = session(probe)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await session.generate("hello there world")
        }
        do { _ = try await task.value; XCTFail("Cancelled cleanup returned") } catch {
            XCTAssertEqual(error as? CleanupModelError, .generationFailed)
        }
        XCTAssertTrue(probe.requests.isEmpty)
    }

    func testMissingKeyIsUnavailableAndSendsNothing() async {
        let probe = AnthropicTransportProbe()
        let secret = MemorySecret()
        let cleaner = AnthropicCleaner(keys: AnthropicKeyStore(storage: secret), transport: probe.transport)
        XCTAssertEqual(cleaner.unavailableReason, "Add an Anthropic API key to use Claude")
        do {
            _ = try await cleaner.makeSession().generate("hello there world")
            XCTFail("Cleanup without a key returned")
        } catch {
            XCTAssertEqual(error as? CleanupModelError, .unavailable)
        }
        XCTAssertTrue(probe.requests.isEmpty)
        secret.value = "sk-ant-test"
        XCTAssertNil(cleaner.unavailableReason)
    }

    func testPrewarmSendsNothing() async {
        let probe = AnthropicTransportProbe()
        await session(probe).prewarm()
        XCTAssertTrue(probe.requests.isEmpty)
    }

}

@MainActor
final class CleanupEngineSelectionTests: XCTestCase {
    private func withDefaults(_ test: (UserDefaults) throws -> Void) rethrows {
        let suite = "CleanupEngineSelectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try test(defaults)
    }

    func testEnginePreferencePersistsAndDefaultsToAppleIntelligence() {
        withDefaults { defaults in
            XCTAssertEqual(CleanupEnginePreferences(defaults: defaults).engine, .appleIntelligence)
            CleanupEnginePreferences(defaults: defaults).engine = .anthropic
            XCTAssertEqual(CleanupEnginePreferences(defaults: defaults).engine, .anthropic)
            XCTAssertEqual(defaults.string(forKey: "typr.cleanupEngine"), "anthropic")
            CleanupEnginePreferences(defaults: defaults).engine = .appleIntelligence
            XCTAssertEqual(CleanupEnginePreferences(defaults: defaults).engine, .appleIntelligence)
            XCTAssertNil(defaults.object(forKey: "typr.cleanupEngine"))
            defaults.set("gpt", forKey: "typr.cleanupEngine")
            XCTAssertEqual(CleanupEnginePreferences(defaults: defaults).engine, .appleIntelligence)
        }
    }

    func testSelectedCleanerFollowsThePreferenceOnEveryCall() {
        withDefaults { defaults in
            let preferences = CleanupEnginePreferences(defaults: defaults)
            let appleSession = CleanupTestSession()
            let claudeSession = CleanupTestSession()
            let cleaner = SelectedTranscriptCleaner(
                engine: { preferences.engine },
                apple: CleanupTestCleaner(unavailableReason: "Turn on Apple Intelligence in Settings to use this", session: appleSession),
                anthropic: CleanupTestCleaner(unavailableReason: nil, session: claudeSession))

            XCTAssertEqual(cleaner.unavailableReason, "Turn on Apple Intelligence in Settings to use this")
            XCTAssertTrue(cleaner.makeSession() === appleSession)

            preferences.engine = .anthropic
            XCTAssertNil(cleaner.unavailableReason)
            XCTAssertTrue(cleaner.makeSession() === claudeSession)
        }
    }

    func testClaudeWithoutKeyReportsTheKeyReason() {
        let cleaner = SelectedTranscriptCleaner(
            engine: { .anthropic }, apple: UnsupportedAppleCleaner(),
            anthropic: AnthropicCleaner(keys: AnthropicKeyStore(storage: MemorySecret())))
        XCTAssertEqual(cleaner.unavailableReason, "Add an Anthropic API key to use Claude")
    }

    func testAppleBeforeIOS26IsUnavailable() async {
        let cleaner = UnsupportedAppleCleaner()
        XCTAssertEqual(cleaner.unavailableReason, "Requires iOS 26 or later")
        do {
            _ = try await cleaner.makeSession().generate("one two three")
            XCTFail("Unsupported Apple cleanup returned")
        } catch {
            XCTAssertEqual(error as? CleanupModelError, .unavailable)
        }
    }

    func testKeyStoreTrimsSavesAndRemoves() {
        let secret = MemorySecret()
        let keys = AnthropicKeyStore(storage: secret)
        XCTAssertFalse(keys.hasKey)
        XCTAssertNil(keys.key)
        XCTAssertTrue(keys.save("  sk-ant-test\n"))
        XCTAssertEqual(secret.value, "sk-ant-test")
        XCTAssertEqual(keys.key, "sk-ant-test")
        XCTAssertTrue(keys.hasKey)
        keys.remove()
        XCTAssertNil(secret.value)
        XCTAssertFalse(keys.hasKey)
    }

    func testEmptyKeyIsNeverSavedAndKeepsTheSavedKey() {
        let secret = MemorySecret("sk-ant-test")
        let keys = AnthropicKeyStore(storage: secret)
        for empty in ["", "  \n\t "] {
            XCTAssertFalse(AnthropicKeyStore.canSave(empty))
            XCTAssertFalse(keys.save(empty))
            XCTAssertEqual(secret.value, "sk-ant-test")
        }
        secret.value = " \n"
        XCTAssertFalse(keys.hasKey)
    }

    func testImprovementExportNamesTheCleanupModel() {
        var context = DictationLogContext()
        context.cleanupPath = .typr
        XCTAssertTrue(DictationLogEntry(context: context).improvementLines
            .contains("Cleanup model: on-device Apple FoundationModels (exact model version unavailable)"))
        context.cleanupEngine = CleanupEngine.anthropic.rawValue
        let lines = DictationLogEntry(context: context).improvementLines
        XCTAssertTrue(lines.contains("Cleanup model: Anthropic claude-haiku-5-5 (cloud)"))
        XCTAssertFalse(lines.contains { $0.contains("sk-ant") })
    }
}
