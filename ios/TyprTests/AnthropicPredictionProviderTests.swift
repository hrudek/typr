import Foundation
import XCTest
@testable import Typr

@MainActor
final class AnthropicPredictionProviderTests: XCTestCase {
    private final class Checker: TextChecking {
        func isWordValid(_ word: String) -> Bool { true }
        func guesses(for word: String) -> [String] { [] }
        func completions(for prefix: String) -> [String] { [] }
    }

    private let key = "sk-ant-prediction-test"
    private let sentence = "I would like to "

    private func provider(_ probe: AnthropicTransportProbe, key: String?) -> AnthropicPredictionProvider {
        AnthropicPredictionProvider(key: { key }, transport: probe.transport)
    }

    private func keyboard(_ probe: AnthropicTransportProbe, key: String?, timeout: Duration = .seconds(5),
                          configure: (FixtureTextTarget) -> Void = { _ in }) throws -> (FullKeyboardEngine, FixtureTextTarget) {
        let target = FixtureTextTarget()
        configure(target)
        let engine = FullKeyboardEngine(target: target, autocorrect: AutocorrectEngine(
            checker: Checker(), spatialDecoder: nil,
            contextResources: .init(model: try XCTUnwrap(BundledKeyboardData.contextModel))))
        engine.width = 393
        engine.modelPredictions = ModelPredictionSession(provider: provider(probe, key: key), timeout: timeout)
        engine.configureForField()
        return (engine, target)
    }

    private func type(_ text: String, _ engine: FullKeyboardEngine, _ target: FixtureTextTarget) async {
        target.insertText(text)
        engine.textDidChange()
        await engine.waitForSuggestions()
        let limit = ContinuousClock.now.advanced(by: .seconds(10))
        while engine.modelPredictions?.isActive == true, ContinuousClock.now < limit {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func bar(_ engine: FullKeyboardEngine) -> [String] { engine.suggestions.map(\.replacement) }

    func testNoKeyMakesNoRequest() async throws {
        for missing in [nil, "", "  \n"] as [String?] {
            let probe = AnthropicTransportProbe()
            let (engine, target) = try keyboard(probe, key: missing)
            await type(sentence, engine, target)
            XCTAssertEqual(probe.requests.count, 0)
            XCTAssertEqual(bar(engine).count, 3, "Local predictions stay")
        }
    }

    func testSuccessMergesClaudeWordsAndSendsOnlyTheBoundedContext() async throws {
        let probe = AnthropicTransportProbe()
        probe.body = AnthropicTransportProbe.message(text: "go\nsee\nVisit")
        let (engine, target) = try keyboard(probe, key: key)
        target.insertText("Private earlier paragraph.\n")
        await type(sentence, engine, target)
        XCTAssertEqual(bar(engine), ["the", "go", "see"])
        let request = try XCTUnwrap(probe.requests.first)
        XCTAssertEqual(probe.requests.count, 1)
        XCTAssertEqual(request.url, AnthropicAPI.endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), key)
        XCTAssertEqual(request.timeoutInterval, AnthropicPredictionProvider.timeout)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, AnthropicAPI.model)
        XCTAssertEqual(body["max_tokens"] as? Int, AnthropicPredictionProvider.maxTokens)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["content"] as? String }, [sentence])
    }

    func testRateLimitTimeoutAndMalformedKeepLocalPredictions() async throws {
        let (local, localTarget) = try keyboard(AnthropicTransportProbe(), key: nil)
        await type(sentence, local, localTarget)
        let counted = bar(local)

        let limited = AnthropicTransportProbe()
        limited.status = 429
        let overloaded = AnthropicTransportProbe()
        overloaded.status = 529
        let malformed = AnthropicTransportProbe()
        malformed.body = Data("not json".utf8)
        let empty = AnthropicTransportProbe()
        empty.body = AnthropicTransportProbe.message(text: "")
        let slow = AnthropicTransportProbe()
        slow.waitForCancellation = true
        for probe in [limited, overloaded, malformed, empty, slow] {
            let (engine, target) = try keyboard(probe, key: key, timeout: .milliseconds(100))
            await type(sentence, engine, target)
            XCTAssertEqual(probe.requests.count, 1)
            XCTAssertEqual(bar(engine), counted)
        }
    }

    func testStaleResponseIsDropped() async throws {
        let probe = AnthropicTransportProbe()
        probe.waitForCancellation = true
        let (engine, target) = try keyboard(probe, key: key)
        target.insertText(sentence)
        engine.textDidChange()
        await engine.waitForSuggestions()
        XCTAssertTrue(engine.modelPredictions?.isActive ?? false)
        let started = ContinuousClock.now.advanced(by: .seconds(5))
        while probe.requests.isEmpty, ContinuousClock.now < started { try? await Task.sleep(for: .milliseconds(5)) }
        target.insertText("go ")
        engine.textDidChange()
        await engine.waitForSuggestions()
        let limit = ContinuousClock.now.advanced(by: .seconds(5))
        while probe.requests.count < 2 || !probe.cancelled, ContinuousClock.now < limit { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(probe.requests.count, 2, "The newer context replaces the active request")
        XCTAssertTrue(probe.cancelled, "The stale request is cancelled")
        engine.cancelSuggestions()
    }

    func testRestrictedFieldsSendNothing() async throws {
        let fields: [(FixtureTextTarget) -> Void] = [
            { $0.isSecureTextEntry = true }, { $0.keyboardType = .URL }, { $0.keyboardType = .emailAddress },
            { $0.keyboardType = .numberPad }, { $0.keyboardType = .numbersAndPunctuation },
            { $0.autocorrectionType = .no }, { $0.inlinePredictionType = .no },
        ]
        for configure in fields {
            let probe = AnthropicTransportProbe()
            let (engine, target) = try keyboard(probe, key: key, configure: configure)
            await type(sentence, engine, target)
            XCTAssertEqual(probe.requests.count, 0)
        }
    }

    func testParseErrorsCarryNoResponseText() {
        let response = HTTPURLResponse(url: AnthropicAPI.endpoint, statusCode: 429, httpVersion: nil, headerFields: nil)!
        XCTAssertThrowsError(try AnthropicPredictionProvider.parse(data: Data(key.utf8), response: response)) {
            XCTAssertFalse(String(describing: $0).contains(self.key))
        }
    }

    func testKeyboardCopyFollowsTheSavedKeyAndNeverReachesDefaults() {
        let saved = MemorySecret(), copy = MemorySecret()
        let keys = AnthropicKeyStore(storage: saved, keyboardCopy: copy)
        XCTAssertTrue(keys.save(" \(key)\n"))
        XCTAssertEqual(copy.value, key)
        copy.value = nil
        keys.syncKeyboardCopy()
        XCTAssertEqual(copy.value, key, "A key saved before the copy existed is copied at launch")
        keys.remove()
        XCTAssertNil(copy.value)
        copy.value = "orphan"
        keys.syncKeyboardCopy()
        XCTAssertNil(copy.value)

        for defaults in [UserDefaults.standard, UserDefaults(suiteName: KeyboardBridge.appGroup)].compactMap({ $0 }) {
            let stored = defaults.dictionaryRepresentation().values.map { String(describing: $0) }
            XCTAssertFalse(stored.contains { $0.contains(key) })
        }
    }
}
