import Foundation
import XCTest
@testable import Typr

final class AutocorrectOrthographyTests: XCTestCase {
    @MainActor
    private final class Checker: TextChecking {
        let words: Set<String>
        var validityCalls = 0
        var apostropheCalls = 0
        var alternatives: [String: [String]] = [:]
        init(_ words: Set<String> = []) { self.words = words }
        func isWordValid(_ word: String) -> Bool {
            validityCalls += 1
            if word.contains("'") { apostropheCalls += 1 }
            return words.contains(word)
        }
        func guesses(for word: String) -> [String] { alternatives[word] ?? [] }
        func completions(for prefix: String) -> [String] { [] }
    }

    @MainActor
    private func engine() throws -> AutocorrectEngine {
        let model = try XCTUnwrap(BundledKeyboardData.contextModel)
        let english: Set<String> = ["were", "well", "ill", "wont", "shell", "hell", "its", "cant", "house", "gift"]
        let german: Set<String> = ["für", "über", "möchte", "heiß", "Haus", "Buch", "Arbeit", "Essen", "essen", "Laut", "laut", "Masse", "Maße", "Steuer", "Mauer", "Israel", "Michael", "Strasse", "strasse", "weiss", "im", "die", "am", "war", "will", "also", "Gift", "Chef", "schon"]
        let result = AutocorrectEngine(checker: Checker(english), spatialDecoder: nil,
                                      contextResources: .init(model: model))
        result.german = GermanAutocorrect(checker: Checker(german))
        return result
    }

    @MainActor
    func testOrthographyEvaluation() throws {
        let engine = try engine()
        let groups: [(String, [(String, String)])] = [
            ("noun", [("ich habe das haus", "Haus"), ("ich lese ein buch", "Buch"), ("ich bin bei der arbeit", "Arbeit"), ("wir gehen zum essen", "Essen")]),
            ("digraph", [("das ist fuer", "für"), ("ich bin ueber", "über"), ("ich moechte", "möchte"), ("das ist heiss", "heiß")]),
            ("contraction", [("I dont", "don't"), ("I cant", "can't"), ("youre", "you're"), ("im", "I'm"), ("wont", "won't"), ("ill", "I'll"), ("were", "we're"), ("shell", "she'll")])
        ]
        for (rule, cases) in groups {
            var automatic = 0, suggested = 0
            for (input, target) in cases {
                if engine.replacementOnSpace(beforeInput: input, field: .text, autocorrectionType: .default)?.replacement == target { automatic += 1 }
                let chips = engine.suggestions(beforeInput: input, field: .text, autocorrectionType: .default)
                if chips.contains(where: { $0.replacement == target && $0.kind != .keepLiteral }) { suggested += 1 }
            }
            XCTAssertEqual(automatic, rule == "digraph" ? 4 : (rule == "contraction" ? 2 : 0))
            XCTAssertEqual(suggested, rule == "contraction" ? 7 : 4)
        }
        let controls: [String] = ["were", "well", "ill", "wont", "shell", "hell", "its", "cant", "ich will essen", "das ist laut", "wir sind am essen", "ich sehe die masse", "die Masse", "die Maße", "die Steuer", "die Mauer", "Israel", "Michael", "die Strasse", "ich weiss", "im", "die", "war", "will", "also", "Gift", "Chef", "schon", "this is the house", "please send the gift", "ich sende the house", "TyprKey", "API", "@dont", "file/dont", "foo_dont"]
        let falseAutos = controls.filter { engine.replacementOnSpace(beforeInput: $0, field: .text, autocorrectionType: .default) != nil }.count
        XCTAssertEqual(falseAutos, 0)
        let english = AutocorrectEngine(checker: Checker(["shan't", "who'd"]), spatialDecoder: nil,
                                       contextResources: .init(model: BundledKeyboardData.contextModel))
        let missing = [("shant", "shan't"), ("whod", "who'd")]
        var hits = 0
        for (input, target) in missing {
            if english.suggestions(beforeInput: input, field: .text, autocorrectionType: .default).contains(where: { $0.replacement == target }) { hits += 1 }
        }
        XCTAssertEqual(hits, 2)
    }

    @MainActor
    func testAmbiguousWordsNeverUseSpellingFallbackAuthority() {
        let checker = Checker()
        checker.alternatives = AutocorrectEngine.suggestOnlyContractions.mapValues { [$0] }
        let engine = AutocorrectEngine(checker: checker, spatialDecoder: nil,
                                      contextResources: .init(model: nil))
        for (literal, target) in AutocorrectEngine.suggestOnlyContractions {
            XCTAssertNil(engine.replacementOnSpace(beforeInput: literal, field: .text, autocorrectionType: .default))
            let chips = engine.suggestions(beforeInput: literal, field: .text, autocorrectionType: .default)
            XCTAssertTrue(chips.contains { $0.replacement == target })
            XCTAssertFalse(chips.contains { $0.kind == .primary(autoReplace: true) })
        }
    }

    @MainActor
    func testValidWordsDoNotOfferProductivePossessives() {
        for (literal, possessive) in [("dogs", "dog's"), ("houses", "house's"), ("users", "user's"), ("Dogs", "Dog's")] {
            // Title case is intentionally absent: lowercased validity must also veto search.
            let checker = Checker([literal.lowercased(), possessive.lowercased()])
            let engine = AutocorrectEngine(checker: checker, spatialDecoder: nil,
                                          contextResources: .init(model: nil))
            let chips = engine.suggestions(beforeInput: literal, field: .text, autocorrectionType: .default)
            let hits = chips.filter { $0.replacement == possessive }.count
            XCTAssertEqual(hits, 0)
            XCTAssertEqual(checker.apostropheCalls, 0, "Valid literals must not enumerate apostrophe spellings")
        }
    }

    @MainActor
    func testDeterministicWorkAndMemoryBounds() {
        let checker = Checker()
        let engine = AutocorrectEngine(checker: checker, spatialDecoder: nil,
                                      contextResources: .init(model: nil))
        let input = String(repeating: "x", count: 32)
        let first = engine.suggestions(beforeInput: input, field: .text, autocorrectionType: .default)
        let calls = checker.validityCalls
        XCTAssertLessThanOrEqual(calls, 64, "31 insertion boundaries plus the existing fixed checker probes")
        let second = engine.suggestions(beforeInput: input, field: .text, autocorrectionType: .default)
        XCTAssertEqual(first.map(\.replacement), second.map(\.replacement))
        XCTAssertLessThanOrEqual(first.count, 3)
    }

    @MainActor
    func testNounGateAndEnabledLanguages() throws {
        let engine = try engine()
        func offered(_ input: String, _ target: String) -> Bool {
            engine.suggestions(beforeInput: input, field: .text, autocorrectionType: .default)
                .contains { $0.replacement == target && $0.kind != .keepLiteral }
        }
        XCTAssertTrue(offered("ich habe das haus", "Haus"))
        XCTAssertTrue(engine.suggestions(beforeInput: "ich habe das haus", field: .text, autocorrectionType: .no).isEmpty)
        let validHomographs = ["wir sehen die essen", "wir hören die laut", "wir hören sie laut"]
        var proposedFalse = 0
        for input in validHomographs {
            let target = input.hasSuffix("essen") ? "Essen" : "Laut"
            if offered(input, target) { proposedFalse += 1 }
            XCTAssertNil(engine.replacementOnSpace(beforeInput: input, field: .text, autocorrectionType: .default))
        }
        XCTAssertGreaterThan(proposedFalse, 0, "A local cue is not enough to enable automatic noun casing")
        XCTAssertFalse(offered("this is the house", "House"))
        XCTAssertFalse(offered("please read das haus", "Haus"), "English posterior must veto the German cue")
        engine.englishEnabled = false
        XCTAssertTrue(offered("ich habe das haus", "Haus"))
        XCTAssertFalse(offered("were", "we're"))
        engine.englishEnabled = true; engine.german = nil
        XCTAssertFalse(offered("ich habe das haus", "Haus"))
        XCTAssertTrue(offered("im", "I'm"))
        engine.englishEnabled = false
        XCTAssertFalse(offered("dont", "don't"))
        engine.englishEnabled = true; engine.isEnabled = false
        XCTAssertFalse(offered("were", "we're"))
    }

    @MainActor
    func testProtectedTermsRejectionsAndManualApostropheEnumeration() throws {
        let engine = try engine()
        let suite = "R2-5.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = KeyboardLearningSession(store: KeyboardLearningStore(directory: nil, defaults: defaults),
                                              defaults: defaults, allowsPersistence: { false })
        let english = Checker(["shan't", "who'd", "were", "wont", "cant"])
        let model = try XCTUnwrap(BundledKeyboardData.contextModel)
        let apostrophe = AutocorrectEngine(checker: english, learning: session, spatialDecoder: nil,
                                           contextResources: .init(model: model))
        func manual(_ engine: AutocorrectEngine, _ input: String, _ target: String) -> Bool {
            let chips = engine.suggestions(beforeInput: input, field: .text, autocorrectionType: .default)
            XCTAssertNil(engine.replacementOnSpace(beforeInput: input, field: .text, autocorrectionType: .default))
            XCTAssertFalse(chips.contains { $0.kind == .primary(autoReplace: true) })
            return chips.contains { $0.replacement == target && $0.kind != .keepLiteral }
        }
        XCTAssertTrue(manual(apostrophe, "shant", "shan't"))
        XCTAssertTrue(manual(apostrophe, "whod", "who'd"))
        session.rejectCorrection(typed: "shant", replacement: "shan't")
        XCTAssertFalse(manual(apostrophe, "shant", "shan't"))
        session.keep("whod")
        XCTAssertFalse(manual(apostrophe, "whod", "who'd"))
        var builder = ProtectedPersonalLexicon.Builder()
        builder.add("Haus Wont Cant")
        let lexicon = builder.build()
        engine.loadProtectedLexicon(lexicon); apostrophe.loadProtectedLexicon(lexicon)
        XCTAssertFalse(manual(engine, "ich habe das haus", "Haus"))
        XCTAssertFalse(manual(apostrophe, "wont", "won't"))
        XCTAssertFalse(manual(apostrophe, "cant", "can't"))
        session.rejectCorrection(typed: "haus", replacement: "Haus")
        apostrophe.german = GermanAutocorrect(checker: Checker(["Haus"]))
        XCTAssertFalse(manual(apostrophe, "ich habe das haus", "Haus"))
        XCTAssertFalse(session.isPersistent)
    }
}
