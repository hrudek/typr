import UIKit
import XCTest
@testable import Typr

@MainActor
private final class FakeTextChecker: TextChecking {
    var valid: Set<String>
    var guessTable: [String: [String]]
    var completionTable: [String: [String]]

    init(valid: Set<String> = [], guesses: [String: [String]] = [:], completions: [String: [String]] = [:]) {
        self.valid = valid
        self.guessTable = guesses
        self.completionTable = completions
    }

    func isWordValid(_ word: String) -> Bool { valid.contains(word) }
    func guesses(for word: String) -> [String] { guessTable[word] ?? [] }
    func completions(for prefix: String) -> [String] { completionTable[prefix] ?? [] }
}

@MainActor
final class GermanAutocorrectTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var now: TimeInterval = 200

    override func setUp() async throws {
        suiteName = "GermanAutocorrectTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeEngine(
        english: Set<String> = ["does", "blue", "queue", "I'm", "the"],
        german: Set<String> = ["neue", "Feuer", "dass", "im", "für", "über", "straße"],
        germanGuesses: [String: [String]] = [:],
        germanOn: Bool = true
    ) -> AutocorrectEngine {
        let engine = AutocorrectEngine(
            checker: FakeTextChecker(valid: english, guesses: ["teh": ["the"]]),
            learning: KeyboardLearningSession(defaults: defaults), spatialDecoder: nil
        )
        if germanOn {
            engine.german = GermanAutocorrect(checker: FakeTextChecker(valid: german, guesses: germanGuesses))
        }
        return engine
    }

    private func fix(_ engine: AutocorrectEngine, _ word: String) -> String? {
        engine.replacementOnSpace(beforeInput: word, field: .text, autocorrectionType: .default)?.replacement
    }

    func testUmlautDigraphsAndCasing() {
        let engine = makeEngine()
        XCTAssertEqual(fix(engine, "fuer"), "für")
        XCTAssertEqual(fix(engine, "Fuer"), "Für")
        XCTAssertEqual(fix(engine, "FUER"), "FÜR")
        XCTAssertEqual(fix(engine, "ueber"), "über")
        XCTAssertEqual(fix(engine, "strasse"), "straße")
    }

    func testDictionaryPath() {
        let engine = makeEngine(german: ["Brücke"])
        XCTAssertEqual(fix(engine, "bruecke"), "Brücke")
    }

    func testValidWordsAreLeftAlone() {
        let engine = makeEngine()
        for word in ["neue", "Feuer", "dass", "does", "blue", "queue"] {
            XCTAssertNil(fix(engine, word), word)
        }
    }

    func testImStaysWithGermanButContractsWithout() {
        XCTAssertNil(fix(makeEngine(), "im"))
        XCTAssertEqual(fix(makeEngine(germanOn: false), "im"), "I'm")
    }

    func testSwitchOffDoesNotTouchUmlauts() {
        XCTAssertNil(fix(makeEngine(germanOn: false), "fuer"))
    }

    func testLearnedWordIsNotRewritten() {
        let engine = makeEngine()
        engine.learning.keep("fuer")
        XCTAssertNil(fix(engine, "fuer"))
    }

    func testUmlautAwareTypoCost() {
        let german = GermanAutocorrect(checker: FakeTextChecker())
        XCTAssertEqual(german.costAdjustedForUmlauts(from: "fur", to: "für"), 0.4)
        XCTAssertNotNil(german.costAdjustedForUmlauts(from: "brucke", to: "brücke"))
    }

    func testGermanTypoGuess() {
        let engine = makeEngine(german: ["Haus"], germanGuesses: ["hasu": ["Haus"]])
        XCTAssertEqual(fix(engine, "hasu"), "Haus")
    }

    func testEngineTypesUmlautAndBackspaceReverts() {
        let target = FixtureTextTarget()
        target.autocapitalizationType = UITextAutocapitalizationType.none
        let autocorrect = makeEngine()
        let engine = FullKeyboardEngine(target: target, autocorrect: autocorrect)
        engine.width = 393
        engine.clock = { [unowned self] in self.now }
        engine.configureForField()

        func tap(_ kind: KeyKind) {
            let key = engine.layout.key(kind)!
            let center = CGPoint(x: key.frame.midX, y: key.frame.midY)
            engine.touchBegan(id: 1, at: center)
            engine.touchEnded(id: 1, at: center)
            now += 0.45
        }
        for ch in "fuer" { tap(.character(String(ch))) }
        tap(.space)
        XCTAssertEqual(target.text, "für ")
        tap(.delete)
        XCTAssertEqual(target.text, "fuer")
    }

    func testLanguageSettingsDefaultOnAndPersistIndependently() {
        let settings = TyprSettings(defaults: defaults)
        defaults.set(false, forKey: "typr.germanAutocorrect")
        XCTAssertTrue(settings.autocorrectGerman, "Retired experiment does not disable German")
        XCTAssertTrue(settings.autocorrectEnglish)
        for german in [false, true] {
            for english in [false, true] {
                settings.autocorrectGerman = german
                settings.autocorrectEnglish = english
                let reloaded = TyprSettings(defaults: defaults)
                XCTAssertEqual(reloaded.autocorrectGerman, german)
                XCTAssertEqual(reloaded.autocorrectEnglish, english)
                let keyboard = FullKeyboardSettings(defaults: defaults)
                keyboard.autocorrect = false
                keyboard.autocorrect = true
                XCTAssertEqual(reloaded.autocorrectGerman, german)
                XCTAssertEqual(reloaded.autocorrectEnglish, english)
            }
        }
    }

    func testLanguageCombinationsAndMasterSwitch() {
        for german in [false, true] {
            for english in [false, true] {
                let engine = makeEngine(germanOn: german)
                engine.englishEnabled = english
                XCTAssertEqual(fix(engine, "fuer"), german ? "für" : nil)
                XCTAssertEqual(fix(engine, "teh"), english ? "the" : nil)
                XCTAssertEqual(fix(engine, "dont"), english ? "don't" : nil)
                engine.isEnabled = false
                XCTAssertNil(fix(engine, "fuer"))
                XCTAssertNil(fix(engine, "teh"))
            }
        }
    }

    func testGermanOnlyDoesNotUseEnglishDictionaryOrDeterministicFixes() {
        let engine = makeEngine(english: ["hasu"], germanGuesses: ["hasu": ["Haus"]])
        engine.englishEnabled = false
        XCTAssertEqual(fix(engine, "hasu"), "Haus")
        XCTAssertNil(fix(engine, "teh"))
        XCTAssertNil(fix(engine, "dont"))
        let suggestions = engine.suggestions(beforeInput: "hasu", field: .text, autocorrectionType: .default)
        XCTAssertTrue(suggestions.contains { $0.replacement == "Haus" })
        let contractions = engine.suggestions(beforeInput: "well", field: .text, autocorrectionType: .default)
        XCTAssertFalse(contractions.contains { $0.replacement == "we'll" })
    }

    func testEnglishDictionaryGuessesAndCompletionsRespectSelection() {
        let engine = AutocorrectEngine(
            checker: FakeTextChecker(guesses: ["helo": ["hello"]], completions: ["hel": ["hello"]]),
            learning: KeyboardLearningSession(defaults: defaults), spatialDecoder: nil
        )
        XCTAssertEqual(fix(engine, "helo"), "hello")
        XCTAssertTrue(engine.suggestions(beforeInput: "hel", field: .text, autocorrectionType: .default)
            .contains { $0.replacement == "hello" })
        engine.englishEnabled = false
        XCTAssertNil(fix(engine, "helo"))
        let suggestions = engine.suggestions(beforeInput: "helo", field: .text, autocorrectionType: .default)
        XCTAssertFalse(suggestions.contains { $0.replacement == "hello" })
        XCTAssertFalse(engine.suggestions(beforeInput: "hel", field: .text, autocorrectionType: .default)
            .contains { $0.replacement == "hello" })
    }

    func testLanguageOrderDefaultsToGermanFirstAndPersists() {
        let settings = TyprSettings(defaults: defaults)
        XCTAssertEqual(settings.autocorrectLanguageOrder, [.german, .english])
        settings.autocorrectLanguageOrder = [.english, .german]
        XCTAssertEqual(TyprSettings(defaults: defaults).autocorrectLanguageOrder, [.english, .german])
        let invalid: [Any] = [["en"], ["en", "en"], ["fr", "en"], ["en", "de", "fr"], ["en", "fr", "de"], "en"]
        for stored in invalid {
            defaults.set(stored, forKey: "typr.autocorrectLanguageOrder")
            XCTAssertEqual(settings.autocorrectLanguageOrder, [.german, .english], "\(stored)")
        }
    }

    private func makeBilingualEngine(englishGuesses: [String], germanGuesses: [String]) -> AutocorrectEngine {
        let engine = AutocorrectEngine(
            checker: FakeTextChecker(guesses: ["wirk": englishGuesses]),
            learning: KeyboardLearningSession(defaults: defaults), spatialDecoder: nil
        )
        engine.german = GermanAutocorrect(checker: FakeTextChecker(guesses: ["wirk": germanGuesses]))
        return engine
    }

    func testSpellingFallbackDoesNotDependOnWhichLanguageSuppliesFirst() {
        for preferred in SpatialWordDecoder.Language.allCases {
            let engine = makeBilingualEngine(englishGuesses: ["work"], germanGuesses: ["wird"])
            engine.preferredLanguage = preferred
            XCTAssertEqual(fix(engine, "wirk"), "work", "\(preferred)")
            let strip = engine.suggestions(beforeInput: "wirk", field: .text, autocorrectionType: .default)
            XCTAssertEqual(strip.map(\.replacement), ["wirk", "work", "wird"], "\(preferred)")
        }
    }

    func testSecondaryLanguageStillFixesItsOwnWords() {
        let english = makeBilingualEngine(englishGuesses: ["work"], germanGuesses: [])
        XCTAssertEqual(english.preferredLanguage, .german)
        XCTAssertEqual(fix(english, "wirk"), "work")
        let german = makeBilingualEngine(englishGuesses: [], germanGuesses: ["wird"])
        german.preferredLanguage = .english
        XCTAssertEqual(fix(german, "wirk"), "wird")
    }

    func testPreferenceDoesNotChangeASingleLanguage() {
        for preferred in SpatialWordDecoder.Language.allCases {
            let englishOnly = makeBilingualEngine(englishGuesses: ["work"], germanGuesses: ["wird"])
            englishOnly.german = nil
            englishOnly.preferredLanguage = preferred
            XCTAssertEqual(fix(englishOnly, "wirk"), "work")
            let germanOnly = makeBilingualEngine(englishGuesses: ["work"], germanGuesses: ["wird"])
            germanOnly.englishEnabled = false
            germanOnly.preferredLanguage = preferred
            XCTAssertEqual(fix(germanOnly, "wirk"), "wird")
        }
    }

    func testTextReplacementIsIndependentOfLanguageSelection() {
        let engine = makeEngine(germanOn: false)
        engine.englishEnabled = false
        engine.loadLexiconEntries([(userInput: "omw", documentText: "On my way!")])
        XCTAssertEqual(fix(engine, "omw"), "On my way!")
        engine.isEnabled = false
        XCTAssertNil(fix(engine, "omw"))
    }

    func testProductNameIsKeptInGermanAndEnglish() {
        for (german, english) in [(true, false), (false, true), (true, true)] {
            let engine = AutocorrectEngine(
                checker: FakeTextChecker(valid: ["type", "typo"],
                                         guesses: ["typr": ["type"], "Typr": ["Type"], "tpye": ["type"]]),
                learning: KeyboardLearningSession(defaults: defaults), spatialDecoder: nil
            )
            if german {
                engine.german = GermanAutocorrect(checker: FakeTextChecker(
                    valid: ["Typ"], guesses: ["typr": ["Typ"], "Typr": ["Typ"], "tyo": ["Typ"]]))
            }
            engine.englishEnabled = english
            let label = "de=\(german) en=\(english)"
            for typed in ["typr", "Typr", "TYPR"] {
                XCTAssertNil(fix(engine, typed), "\(typed) \(label)")
                let slots = engine.suggestions(beforeInput: typed, field: .text, autocorrectionType: .default)
                XCTAssertFalse(slots.contains { $0.willAutoReplace }, "\(typed) \(label)")
            }
            for valid in ["type", "typo", "Typ"] {
                XCTAssertNil(fix(engine, valid), "\(valid) \(label)")
            }
            if english { XCTAssertEqual(fix(engine, "tpye"), "type", label) }
            if german { XCTAssertEqual(fix(engine, "tyo"), "Typ", label) }
        }
    }

    func testTypedProductNamePlusSpaceStays() {
        let target = FixtureTextTarget()
        target.autocapitalizationType = UITextAutocapitalizationType.none
        let autocorrect = AutocorrectEngine(
            checker: FakeTextChecker(valid: ["type"], guesses: ["typr": ["type"], "Typr": ["Type"]]),
            learning: KeyboardLearningSession(defaults: defaults), spatialDecoder: nil
        )
        autocorrect.german = GermanAutocorrect(checker: FakeTextChecker(
            valid: ["Typ"], guesses: ["typr": ["Typ"], "Typr": ["Typ"]]))
        let engine = FullKeyboardEngine(target: target, autocorrect: autocorrect)
        engine.width = 393
        engine.clock = { [unowned self] in self.now }
        engine.configureForField()

        func tap(_ kind: KeyKind) {
            let key = engine.layout.key(kind)!
            let center = CGPoint(x: key.frame.midX, y: key.frame.midY)
            engine.touchBegan(id: 1, at: center)
            engine.touchEnded(id: 1, at: center)
            now += 0.45
        }
        for ch in "typr" { tap(.character(String(ch))) }
        tap(.space)
        tap(.shift)
        for ch in "typr" { tap(.character(String(ch))) }
        tap(.space)
        XCTAssertEqual(target.text, "typr Typr ")
    }

    func testRealDictionary() throws {
        guard UITextChecker.availableLanguages.contains(where: { $0.hasPrefix("de") }) else {
            throw XCTSkip("No German dictionary on this simulator")
        }
        let engine = AutocorrectEngine(learning: KeyboardLearningSession(defaults: defaults), spatialDecoder: nil)
        engine.german = GermanAutocorrect.system()
        XCTAssertEqual(fix(engine, "fuer"), "für")
        XCTAssertNil(fix(engine, "neue"))
    }
}
