import Foundation
import XCTest
@testable import Typr

@MainActor
final class KeyboardModelPredictionTests: XCTestCase {
    private final class Checker: TextChecking {
        func isWordValid(_ word: String) -> Bool { true }
        func guesses(for word: String) -> [String] { [] }
        func completions(for prefix: String) -> [String] { [] }
    }

    /// Answers per context, fails, or waits until released, ignoring cancellation like a slow model.
    private actor FakeModel: ModelPredictionProvider {
        enum Mode { case answer, fail, hold }
        private let answer: @Sendable (String) -> [String]
        private let mode: Mode
        private(set) var contexts: [String] = []
        private var held: [CheckedContinuation<Void, Never>] = []

        init(_ words: [String], mode: Mode = .answer) { self.init(mode: mode) { _ in words } }

        init(mode: Mode = .answer, answer: @escaping @Sendable (String) -> [String]) {
            self.answer = answer
            self.mode = mode
        }

        func predictions(for request: ModelPredictionRequest) async throws -> [String] {
            contexts.append(request.context)
            switch mode {
            case .answer: break
            case .fail: throw URLError(.badServerResponse)
            case .hold: await withCheckedContinuation { held.append($0) }
            }
            return answer(request.context)
        }

        func waitForRequests(_ count: Int) async {
            while contexts.count < count || held.count < count { await Task.yield() }
        }

        func release() {
            held.forEach { $0.resume() }
            held = []
        }
    }

    private let sentence = "I would like to "

    private func keyboard(_ provider: FakeModel?, timeout: Duration = .seconds(5),
                          configure: (FixtureTextTarget) -> Void = { _ in }) throws -> (FullKeyboardEngine, FixtureTextTarget) {
        let target = FixtureTextTarget()
        configure(target)
        let engine = FullKeyboardEngine(target: target, autocorrect: AutocorrectEngine(
            checker: Checker(), spatialDecoder: nil,
            contextResources: .init(model: try XCTUnwrap(BundledKeyboardData.contextModel))))
        engine.width = 393
        engine.modelPredictions = provider.map { ModelPredictionSession(provider: $0, timeout: timeout) }
        engine.configureForField()
        return (engine, target)
    }

    private func type(_ text: String, _ engine: FullKeyboardEngine, _ target: FixtureTextTarget) async {
        target.insertText(text)
        engine.textDidChange()
        await engine.waitForSuggestions()
    }

    private func settle(_ engine: FullKeyboardEngine) async {
        await engine.waitForSuggestions()
        let limit = ContinuousClock.now.advanced(by: .seconds(10))
        while engine.modelPredictions?.isActive == true, ContinuousClock.now < limit {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func bar(_ engine: FullKeyboardEngine) -> [String] { engine.suggestions.map(\.replacement) }

    private func countedBar() async throws -> [String] {
        let (engine, target) = try keyboard(nil)
        await type(sentence, engine, target)
        let counted = bar(engine)
        XCTAssertEqual(counted.count, 3)
        return counted
    }

    func testCountPredictionsShowFirstThenModelWordsMergeForTheSameContext() async throws {
        let counted = try await countedBar()
        let model = FakeModel(["go", "visit", "see"], mode: .hold)
        let (engine, target) = try keyboard(model)
        await type(sentence, engine, target)
        XCTAssertEqual(bar(engine), counted, "Count predictions do not wait for the model")
        await model.waitForRequests(1)
        await model.release()
        await settle(engine)
        XCTAssertEqual(bar(engine), ["the", "go", "visit"], "Model and count words alternate, model first")
        XCTAssertEqual(engine.suggestions.filter(\.willAutoReplace).count, 0)
        XCTAssertTrue(engine.suggestions.allSatisfy { $0.ownership == engine.suggestionOwnership })

        engine.textDidChange()
        await settle(engine)
        XCTAssertEqual(bar(engine), ["the", "go", "visit"])
        let contexts = await model.contexts
        XCTAssertEqual(contexts, [sentence], "The same context is not requested twice")
    }

    func testPickedModelWordIsInsertedWithSentenceCase() async throws {
        let (engine, target) = try keyboard(FakeModel(["hello"]))
        await type("Done. ", engine, target)
        await settle(engine)
        let pick = try XCTUnwrap(engine.suggestions.first { $0.replacement == "Hello" })
        engine.acceptSuggestion(pick)
        XCTAssertEqual(target.text, "Done. Hello ")
    }

    func testStaleResultIsDroppedAndLatestContextWins() async throws {
        let model = FakeModel(mode: .hold) { $0.hasSuffix("go ") ? ["fresh"] : ["stale"] }
        let (engine, target) = try keyboard(model)
        await type(sentence, engine, target)
        await type("go ", engine, target)
        await model.waitForRequests(2)
        await model.release()
        await settle(engine)
        let contexts = await model.contexts
        XCTAssertEqual(contexts, [sentence, sentence + "go "])
        XCTAssertFalse(bar(engine).contains("stale"))
        XCTAssertTrue(bar(engine).contains("fresh"))
    }

    func testResultForAnOldCaretIsDropped() async throws {
        let model = FakeModel(mode: .hold) { $0 == "I would like to " ? ["late"] : ["fresh"] }
        let (engine, target) = try keyboard(model)
        await type(sentence, engine, target)
        await model.waitForRequests(1)
        target.adjustTextPosition(byCharacterOffset: -2)
        engine.textDidChange()
        await engine.waitForSuggestions()
        XCTAssertFalse(engine.modelPredictions?.isActive ?? true, "Caret inside a word cancels the request")
        await model.release()
        await settle(engine)
        let contexts = await model.contexts
        XCTAssertEqual(contexts, [sentence], "No request for a caret inside a word")
        XCTAssertFalse(bar(engine).contains("late"))
    }

    func testTimeoutFailureAndMalformedWordsKeepCountPredictions() async throws {
        let counted = try await countedBar()
        let slow = FakeModel(["late"], mode: .hold)
        let (timed, timedTarget) = try keyboard(slow, timeout: .milliseconds(50))
        await type(sentence, timed, timedTarget)
        await settle(timed)
        XCTAssertFalse(timed.modelPredictions?.isActive ?? true)
        await slow.waitForRequests(1)
        await slow.release()
        await Task.yield()
        XCTAssertEqual(bar(timed), counted)

        for provider in [FakeModel([], mode: .fail), FakeModel(["two words", "", "1234", "https://x.y"])] {
            let (engine, target) = try keyboard(provider)
            await type(sentence, engine, target)
            await settle(engine)
            XCTAssertEqual(bar(engine), counted)
        }
    }

    func testRestrictedFieldsSendNothing() async throws {
        let fields: [(FixtureTextTarget) -> Void] = [
            { $0.isSecureTextEntry = true }, { $0.keyboardType = .URL }, { $0.keyboardType = .emailAddress },
            { $0.keyboardType = .numberPad }, { $0.keyboardType = .numbersAndPunctuation },
            { $0.autocorrectionType = .no }, { $0.inlinePredictionType = .no },
        ]
        for configure in fields {
            let model = FakeModel(["go"])
            let (engine, target) = try keyboard(model, configure: configure)
            await type(sentence, engine, target)
            await settle(engine)
            let contexts = await model.contexts
            XCTAssertEqual(contexts, [])
        }
    }

    func testRequestIsTheBoundedCurrentParagraphBeforeTheCaret() throws {
        XCTAssertNil(ModelPredictionRequest(before: nil))
        XCTAssertNil(ModelPredictionRequest(before: "I would"), "Only after a separator")
        XCTAssertNil(ModelPredictionRequest(before: "Earlier text.\n "))
        XCTAssertEqual(ModelPredictionRequest(before: "Private.\nHello there ")?.context, "Hello there ")
        let long = String(repeating: "We walked along the river ", count: 12)
        let context = try XCTUnwrap(ModelPredictionRequest(before: "Private.\n" + long)?.context)
        XCTAssertLessThanOrEqual(context.count, ModelPredictionRequest.characterLimit)
        XCTAssertTrue(long.hasSuffix(context))
        XCTAssertTrue(context.first.map { !$0.isWhitespace } ?? false)
        XCTAssertEqual(context.split(separator: " ").first, "along", "Starts at a whole word")
    }

    func testCleanKeepsSingleWordsOnly() {
        XCTAssertEqual(ModelPredictionSession.clean([" go.", "Go", "two words", "", "it's", "e-mail", "42", "a", "b"]),
                       ["go", "it's", "e-mail"])
    }
}
