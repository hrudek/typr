import Foundation
import XCTest
@testable import Typr

final class KeyboardContextPosteriorTests: XCTestCase {
    func testSentencePosteriorSwitchesAndFiniteBounds() throws {
        let model = try XCTUnwrap(BundledKeyboardData.contextModel)
        var state = KeyboardContextModel.State()
        for _ in 0..<100 { state.consume("habe", model: model) }
        XCTAssertGreaterThan(state.weightDE, 0.9)
        state.consume("the", model: model)
        state.consume("with", model: model)
        XCTAssertLessThan(state.weightDE, 0.5, "Two contrary words override a saturated sentence")
        state.consume("für", model: model)
        XCTAssertGreaterThan(state.weightDE, 0.5, "Explicit German cue adapts immediately")
        for i in 0..<10_000 {
            state.consume(i % 2 == 0 ? "habe" : "with", model: model)
            XCTAssertLessThanOrEqual(state.observations.count, 8)
            XCTAssertTrue((-6...6).contains(state.value))
            XCTAssertEqual(state.weightDE + state.weightEN, 1, accuracy: 1e-12)
        }
        XCTAssertEqual(KeyboardContextModel.State(prior: .nan).value, 0)
        XCTAssertEqual(KeyboardContextModel.State(prior: 100).value, 1)
    }

    func testCuesAndSentenceReset() throws {
        let model = try XCTUnwrap(BundledKeyboardData.contextModel)
        var noun = KeyboardContextModel.State(), lower = KeyboardContextModel.State()
        noun.consume("das", model: model); lower.consume("das", model: model)
        noun.consume("Haus", model: model); lower.consume("haus", model: model)
        XCTAssertGreaterThan(noun.value, lower.value)
        var initial = KeyboardContextModel.State(), initialLower = KeyboardContextModel.State()
        initial.consume("Haus", model: model); initialLower.consume("haus", model: model)
        XCTAssertEqual(initial.value, initialLower.value, "Sentence-initial capital is not a German cue")
        var contraction = KeyboardContextModel.State()
        contraction.consume("don't", model: model)
        XCTAssertLessThan(contraction.weightDE, 0.5)
        var state = KeyboardContextModel.State(prior: 0.8)
        state.consume("habe", model: model)
        let before = state.value
        state.sentenceBoundary()
        XCTAssertEqual(state.value, 0.25 * before + 0.4, accuracy: 1e-12)
        XCTAssertTrue(state.observations.isEmpty)
        XCTAssertEqual(state.wordsInSentence, 0)
        XCTAssertEqual(model.context(before: "I don’t ", currentToken: nil).state.value,
                       model.context(before: "I don't ", currentToken: nil).state.value)
    }

    func testWindowEvictionRetokenizationAndCurrentWordExclusion() throws {
        let model = try XCTUnwrap(BundledKeyboardData.contextModel)
        var first = KeyboardContextModel.State(), second = KeyboardContextModel.State()
        first.consume("habe", model: model); second.consume("with", model: model)
        for _ in 0..<9 { first.consume("qzx", model: model); second.consume("qzx", model: model) }
        XCTAssertEqual(first.value, second.value, "Old evidence is evicted, not retained indefinitely")
        let full = model.context(before: "ich habe ein Haus ", currentToken: nil)
        let active = model.context(before: "ich habe ein Haus th", currentToken: "th")
        XCTAssertEqual(full.state.value, active.state.value)
        let bounded = model.context(before: String(repeating: "the ", count: 10_000) + "ich habe ", currentToken: nil)
        XCTAssertLessThanOrEqual(bounded.state.observations.count, 8)
    }

    @MainActor
    func testRecentUsagePriorRoundTripDeletionAndReset() throws {
        let model = try XCTUnwrap(BundledKeyboardData.contextModel)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "R2-4.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let store = KeyboardLearningStore(directory: directory, defaults: defaults)
        let session = KeyboardLearningSession(store: store, defaults: defaults)
        for _ in 0..<4 { session.recordWord("habe") }
        let prior = model.personalLanguagePrior(session.model.state.counts)
        XCTAssertGreaterThan(prior, 0)
        session.flush()
        let loaded = KeyboardLearningStore(directory: directory, defaults: defaults)
        XCTAssertEqual(model.personalLanguagePrior(try XCTUnwrap(loaded.load().0).counts), prior)
        XCTAssertTrue(loaded.deleteLearnedEntry(.count("habe")))
        session.refresh()
        XCTAssertEqual(model.personalLanguagePrior(session.model.state.counts), 0)
        session.recordWord("with")
        XCTAssertLessThan(model.personalLanguagePrior(session.model.state.counts), 0)
        XCTAssertTrue(loaded.requestLearningReset())
        session.refresh()
        XCTAssertEqual(model.personalLanguagePrior(session.model.state.counts), 0)
    }

    func testUsageRecencyCountCapAndDeterministicTies() throws {
        let model = try XCTUnwrap(BundledKeyboardData.contextModel)
        let date = Date(timeIntervalSince1970: 100)
        let low: [String: PersonalTypingModel.WordCount] = ["habe": .init(count: 4, lastUpdated: date)]
        let high: [String: PersonalTypingModel.WordCount] = ["habe": .init(count: 10_000, lastUpdated: date)]
        XCTAssertEqual(model.personalLanguagePrior(low), model.personalLanguagePrior(high))
        var counts = high
        // Thirty-two more recent unknown types evict the old German type from this prior.
        for i in 0..<32 {
            let word = "qzx" + String(UnicodeScalar(97 + i / 26)!) + String(UnicodeScalar(97 + i % 26)!)
            counts[word] = .init(count: 1, lastUpdated: date.addingTimeInterval(1))
        }
        XCTAssertEqual(model.personalLanguagePrior(counts), 0)
        let reverse = Dictionary(uniqueKeysWithValues: counts.sorted { $0.key > $1.key })
        XCTAssertEqual(model.personalLanguagePrior(counts), model.personalLanguagePrior(reverse))
    }

    @MainActor
    func testEnginePriorCacheLearningOffAndFullAccessGating() throws {
        let model = try XCTUnwrap(BundledKeyboardData.contextModel)
        let suite = "R2-4.gating.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let store = KeyboardLearningStore(directory: directory, defaults: defaults)
        let session = KeyboardLearningSession(store: store, defaults: defaults, allowsPersistence: { false })
        let engine = AutocorrectEngine(checker: Checker(), learning: session, spatialDecoder: nil,
                                      contextResources: .init(model: model))
        engine.german = GermanAutocorrect(checker: Checker())
        let input = "also "
        func expected(_ prior: Double) -> [String] {
            let c = model.context(before: input, currentToken: nil, prior: prior)
            return KeyboardContextModel.stripOrder(model.suggestions(after: c.previous, weightDE: c.state.weightDE)).map(\.key)
        }
        func actual() -> [String] {
            engine.suggestions(beforeInput: input, field: .text, autocorrectionType: .default).map { $0.replacement.lowercased() }
        }
        for word in ["habe", "with", "habe"] {
            session.recordWord(word)
            XCTAssertEqual(actual(), expected(model.personalLanguagePrior(session.model.state.counts)))
        }
        session.flush()
        XCTAssertFalse(session.isPersistent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("learning-v1.json").path))
        defaults.set(false, forKey: "keyboard.personalLearning"); session.refresh()
        XCTAssertEqual(actual(), expected(0))
        XCTAssertFalse(session.model.state.counts.isEmpty)
        engine.german = nil; engine.englishEnabled = false
        XCTAssertTrue(actual().isEmpty)
    }

    @MainActor
    private final class Checker: TextChecking {
        func isWordValid(_ word: String) -> Bool { false }
        func guesses(for word: String) -> [String] { [] }
        func completions(for prefix: String) -> [String] { [] }
    }
}
