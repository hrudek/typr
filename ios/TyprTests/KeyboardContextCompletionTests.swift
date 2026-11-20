import Foundation
import XCTest
@testable import Typr

/// M3 integration: public corpus context on #115's completion union, through the real
/// deferred worker/finish. Synthetic spellings/checkers, not Apple's dictionary or typing quality.
@MainActor
final class KeyboardContextCompletionTests: XCTestCase {
    private final class Checker: TextChecking {
        let words: [String]
        init(_ words: [String] = []) { self.words = words }
        func isWordValid(_ word: String) -> Bool { false }
        func guesses(for word: String) -> [String] { [] }
        func completions(for prefix: String) -> [String] { words }
    }

    /// Tiny TSW1 fixture: root → h → a → four terminals, plus hab → e. No upstream data.
    private func trie(includingTarget: Bool) throws -> SpatialWordLexicon {
        var data = Data("TSW1".utf8)
        func u32(_ value: UInt32) {
            for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        // haa/hab/hac/had are short strict extensions; none has a retained ich follower boost.
        for value: UInt32 in [includingTarget ? 8 : 7, includingTarget ? 5 : 4, 0,
                              includingTarget ? 4_000 : 3_400, 0] { u32(value) }
        var nodes: [(UInt8, UInt8, UInt32, UInt32)] = [
            (255, 1, 1, 0), (7, 1, 2, 0), (0, 4, 3, 0),
            (0, 0, 0, 1_000), (1, includingTarget ? 1 : 0, includingTarget ? 7 : 0, 900),
            (2, 0, 0, 800), (3, 0, 0, 700)
        ]
        if includingTarget { nodes.append((4, 0, 0, 600)) }
        for (label, children, first, count) in nodes {
            data.append(contentsOf: [label, children, 0, 0]); u32(first); u32(count)
        }
        return try XCTUnwrap(SpatialWordLexicon(data: data))
    }

    private func make(source: String, model: KeyboardContextModel?, learningOn: Bool = true,
                      seeded: Bool = true) throws -> (AutocorrectEngine, UserDefaults) {
        let defaults = UserDefaults(suiteName: "typr.tests.context-completion.\(UUID().uuidString)")!
        defaults.set(learningOn, forKey: "keyboard.personalLearning")
        let session = KeyboardLearningSession(defaults: defaults)
        if seeded {
            let counts = source == "personal" ? ["haa": 6, "hab": 5, "habe": 2] : ["hax": 3]
            for (word, count) in counts.sorted(by: { $0.key < $1.key }) {
                for _ in 0..<count { session.model.recordWord(word) }
            }
        }
        // System habe starts behind two shorter completions. In the union scenario it
        // starts behind the full four-result trie and a personal addition as well.
        let system = source == "system" ? ["haa", "hab", "habe"] : source == "union" ? ["habe"] : []
        var lexicons: [SpatialWordDecoder.Language: SpatialWordLexicon] = [:]
        if source == "trie" || source == "union" {
            let fixture = try trie(includingTarget: source == "trie")
            // Both selected resources must exist; no English-only/German-only fallback.
            lexicons = [.german: fixture, .english: fixture]
        }
        let ac = AutocorrectEngine(checker: Checker(system), learning: session,
                                   spatialDecoder: lexicons.isEmpty ? nil : SpatialWordDecoder(lexicons: lexicons),
                                   contextResources: .init(model: model))
        ac.german = GermanAutocorrect(checker: Checker())
        return (ac, defaults)
    }

    private func ranked(_ ac: AutocorrectEngine, text: String = "ich ha") async -> [KeyboardSuggestion] {
        let engine = FullKeyboardEngine(target: FixtureTextTarget(text: text), autocorrect: ac)
        engine.width = 393
        engine.configureForField()
        await engine.waitForSuggestions()
        // Ownership differs by engine, so compare semantic chips with the synchronous API.
        return engine.suggestions.map { var chip = $0; chip.ownership = nil; return chip }
    }

    func testWorkerContextScoresSystemTrieAndPersonalCompletionUnion() async throws {
        let model = try XCTUnwrap(BundledKeyboardData.contextModel)
        var promoted = 0
        for source in ["system", "trie", "personal", "union"] {
            let (baseline, _) = try make(source: source, model: nil)
            let (context, _) = try make(source: source, model: model)
            let old = await ranked(baseline), chips = await ranked(context)
            XCTAssertEqual(chips, context.suggestions(beforeInput: "ich ha", field: .text, autocorrectionType: .default), source)
            let best = try XCTUnwrap(chips.dropFirst().first)
            XCTAssertEqual(best.replacement.lowercased(), "habe", source)
            XCTAssertTrue(best.isCompletion, source)
            XCTAssertFalse(best.willAutoReplace, source)
            XCTAssertEqual(best.isPersonal, source == "personal", source)
            if old[1].replacement != best.replacement { promoted += 1 }
            XCTAssertNil(context.replacementOnSpace(beforeInput: "ich ha", field: .text, autocorrectionType: .default))
            XCTAssertNil(baseline.replacementOnSpace(beforeInput: "ich ha", field: .text, autocorrectionType: .default))
            XCTAssertLessThanOrEqual(chips.count, 3)
            if source == "personal" {
                context.recordSuggestionFeedback(best, literal: "ha", evidence: nil)
                XCTAssertEqual(context.learning.model.lexicon.counts["habe"], 3)
                XCTAssertEqual(context.learning.diagnostics[.personalCompletionPick], 1)
                XCTAssertEqual(context.learning.diagnostics.acceptedLabels, 0)
            }
        }
        XCTAssertGreaterThanOrEqual(promoted, 3)
    }

    func testLearningOffRemovesPersonalInfluenceButKeepsCorpusContext() async throws {
        let model = try XCTUnwrap(BundledKeyboardData.contextModel)
        for source in ["system", "trie", "personal", "union"] {
            let (off, defaults) = try make(source: source, model: model, learningOn: true)
            defaults.set(false, forKey: "keyboard.personalLearning")
            off.learning.refresh()
            let (empty, _) = try make(source: source, model: model, learningOn: false, seeded: false)
            let chips = await ranked(off)
            let emptyChips = await ranked(empty)
            XCTAssertEqual(chips, emptyChips, source)
            XCTAssertFalse(chips.contains(where: \.isPersonal), source)
            XCTAssertFalse(off.learning.isLearningEnabled)
            XCTAssertFalse(off.learning.model.state.counts.isEmpty, "Off retains saved counts")
            if source != "personal" { XCTAssertEqual(chips[1].replacement.lowercased(), "habe", source) }
        }
    }

    func testContextPreservesContactPrecedenceInWorker() async throws {
        let model = try XCTUnwrap(BundledKeyboardData.contextModel)
        let (ac, _) = try make(source: "union", model: model)
        ac.loadLexiconEntries([(userInput: "Hanna", documentText: "Hanna")])
        let chips = await ranked(ac)
        XCTAssertEqual(chips[1].replacement, "Hanna")
        XCTAssertTrue(chips[1].isCompletion)
        XCTAssertFalse(chips[1].isPersonal)
        XCTAssertFalse(chips[1].willAutoReplace)
        XCTAssertNil(ac.replacementOnSpace(beforeInput: "ich ha", field: .text, autocorrectionType: .default))
    }

    func testContextLeavesTextReplacementAuthorityAndHighlightIntactInWorker() async throws {
        let model = try XCTUnwrap(BundledKeyboardData.contextModel)
        let (ac, _) = try make(source: "union", model: model)
        ac.loadLexiconEntries([(userInput: "ha", documentText: "hallo welt")])
        let chips = await ranked(ac)
        XCTAssertEqual(chips[1].replacement, "hallo welt")
        XCTAssertTrue(chips[1].willAutoReplace)
        XCTAssertEqual(ac.replacementOnSpace(beforeInput: "ich ha", field: .text,
                                            autocorrectionType: .default)?.replacement, "hallo welt")
    }
}
