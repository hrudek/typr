import XCTest
@testable import Typr

final class VocabularySpellingTests: XCTestCase {
    func testAppliesSpellingAcrossWords() {
        XCTAssertEqual(
            VocabularySpelling.apply(
                ["Claude", "OpenCode"],
                to: "i use claude in open code."
            ),
            "i use Claude in OpenCode."
        )
    }

    func testJoinsWordsAcrossASingleHyphen() {
        XCTAssertEqual(
            VocabularySpelling.apply(["OpenCode"], to: "Open-Code is great"),
            "OpenCode is great"
        )
    }

    func testDoesNotJoinAcrossOtherPunctuation() {
        XCTAssertEqual(
            VocabularySpelling.apply(["OpenCode"], to: "open, code"),
            "open, code"
        )
    }

    func testMatchesWholeWordsOnly() {
        XCTAssertEqual(
            VocabularySpelling.apply(["Hex"], to: "hexagon"),
            "hexagon"
        )
        XCTAssertEqual(
            VocabularySpelling.apply(["Hex"], to: "hex"),
            "Hex"
        )
    }

    func testKeepsAnEnglishPossessive() {
        XCTAssertEqual(
            VocabularySpelling.apply(["Claude"], to: "claude's idea"),
            "Claude's idea"
        )
        XCTAssertEqual(
            VocabularySpelling.apply(["Claude"], to: "claude’s idea"),
            "Claude’s idea"
        )
    }

    func testDoesNotMatchASimilarWord() {
        XCTAssertEqual(
            VocabularySpelling.apply(["Claude"], to: "a cloud"),
            "a cloud"
        )
    }

    func testEmptyAndTooShortTermsDoNothing() {
        let text = "i use claude in open code."
        XCTAssertEqual(VocabularySpelling.apply([], to: text), text)
        XCTAssertEqual(VocabularySpelling.apply(["a"], to: text), text)
    }

    func testMatchesAMultiWordTerm() {
        XCTAssertEqual(
            VocabularySpelling.apply(["iPhone 17"], to: "my iphone 17 broke"),
            "my iPhone 17 broke"
        )
    }

    func testMatchesSpacedTermsThatIncludeAOneLetterWord() {
        XCTAssertEqual(
            VocabularySpelling.apply(["iPhone 7"], to: "my iphone 7 broke"),
            "my iPhone 7 broke"
        )
        XCTAssertEqual(
            VocabularySpelling.apply(["Plan B"], to: "go with plan b"),
            "go with Plan B"
        )
        XCTAssertEqual(
            VocabularySpelling.apply(["Formula 1"], to: "the formula 1 race"),
            "the Formula 1 race"
        )
    }

    func testMatchesAHyphenatedTermAcrossAHyphenOrASpace() {
        XCTAssertEqual(
            VocabularySpelling.apply(["X-ray"], to: "an x-ray today"),
            "an X-ray today"
        )
        XCTAssertEqual(
            VocabularySpelling.apply(["X-ray"], to: "an x ray"),
            "an X-ray"
        )
    }

    func testPrefersTheLongestWindow() {
        XCTAssertEqual(
            VocabularySpelling.apply(["Open", "OpenCode"], to: "open code"),
            "OpenCode"
        )
    }

    func testDoesNotGlueOrdinaryWordsIntoAName() {
        XCTAssertEqual(
            VocabularySpelling.apply(["Ina"], to: "live in a house"),
            "live in a house"
        )
        XCTAssertEqual(
            VocabularySpelling.apply(["Isa"], to: "this is a test"),
            "this is a test"
        )
        XCTAssertEqual(
            VocabularySpelling.apply(["Arun"], to: "go for a run"),
            "go for a run"
        )
    }

    func testDoesNotMatchAcrossAnApostrophe() {
        XCTAssertEqual(
            VocabularySpelling.apply(["Shell"], to: "she'll come"),
            "she'll come"
        )
        XCTAssertEqual(
            VocabularySpelling.apply(["Well"], to: "we'll go"),
            "we'll go"
        )
    }

    func testDoesNotJoinWordsAcrossNewlines() {
        XCTAssertEqual(
            VocabularySpelling.apply(["OpenCode"], to: "open\n\ncode"),
            "open\n\ncode"
        )
    }

    func testKeepsQuotesOutsideTheMatchedRange() {
        XCTAssertEqual(
            VocabularySpelling.apply(["Claude"], to: "'claude'"),
            "'Claude'"
        )
        XCTAssertEqual(
            VocabularySpelling.apply(["Claude"], to: "‘claude’"),
            "‘Claude’"
        )
    }
    func testRulesMapASoundsLikeFormToTheTerm() {
        let rules = [
            VocabularySpelling.Rule(term: "herdr"),
            VocabularySpelling.Rule(match: "Herder", spelling: "herdr"),
            VocabularySpelling.Rule(match: "Hörder", spelling: "herdr"),
        ]
        var changes: [String] = []
        let fixed = VocabularySpelling.apply(rules: rules, to: "Öffne Herder, dann Hörder und Herders Tab") {
            before, after, term in changes.append("\(before)→\(after) (\(term))")
        }
        XCTAssertEqual(fixed, "Öffne herdr, dann herdr und Herders Tab")
        XCTAssertEqual(changes, ["Herder→herdr (herdr)", "Hörder→herdr (herdr)"])
    }

    func testEarlierRuleWinsForTheSameKey() {
        let rules = [
            VocabularySpelling.Rule(match: "Typer", spelling: "Typr"),
            VocabularySpelling.Rule(match: "typer", spelling: "Tipper"),
        ]
        XCTAssertEqual(VocabularySpelling.apply(rules: rules, to: "open typer"), "open Typr")
    }
}

final class CustomVocabularySettingsTests: XCTestCase {
    func testIsOffByDefaultAndPersistsTerms() {
        let suite = "CustomVocabularySettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = CustomVocabularySettings(defaults: defaults)
        XCTAssertFalse(settings.isEnabled)

        settings.terms = ["OpenCode"]
        XCTAssertEqual(settings.activeTerms, [])
        XCTAssertEqual(CustomVocabularySettings(defaults: defaults).terms, ["OpenCode"])

        settings.isEnabled = true
        XCTAssertTrue(CustomVocabularySettings(defaults: defaults).isEnabled)
        XCTAssertEqual(settings.activeTerms, ["OpenCode"])
    }

    func testSanitizesTerms() {
        let suite = "CustomVocabularySettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = CustomVocabularySettings(defaults: defaults)
        let tooLong = String(repeating: "x", count: CustomVocabularySettings.maxTermLength + 1)
        let longestAllowed = String(repeating: "y", count: CustomVocabularySettings.maxTermLength)
        var rawTerms = [
            "  Claude  ", "", "   ", "claude", "OpenCode", "open code",
            "C++", "C#", "a", tooLong, longestAllowed,
        ]
        rawTerms += (1...105).map { "Term \($0)" }

        settings.terms = rawTerms
        let saved = settings.terms

        XCTAssertEqual(saved.count, CustomVocabularySettings.maxTermCount)
        XCTAssertEqual(saved[0], "Claude")
        XCTAssertEqual(saved[1], "OpenCode")
        XCTAssertEqual(saved[2], longestAllowed)
        XCTAssertFalse(saved.contains(tooLong))
        XCTAssertFalse(saved.contains(""))
        XCTAssertFalse(saved.contains("C++"))
        XCTAssertFalse(saved.contains("C#"))
        XCTAssertFalse(saved.contains("a"))
        XCTAssertFalse(saved.contains("open code"))
        XCTAssertEqual(saved.last, "Term 97")
    }

    func testSoundsLikeIsStoredBesideTheUnchangedTermList() {
        let suite = "CustomVocabularySettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // An install from before sounds-like: just the term array.
        defaults.set(["herdr", "Rudek"], forKey: "customVocabulary.terms")
        let settings = CustomVocabularySettings(defaults: defaults)
        XCTAssertEqual(settings.terms, ["herdr", "Rudek"])
        XCTAssertEqual(settings.soundsLike, [:])

        settings.setSoundsLike([" Herder ", "Herda", "herder", "Rudek", "x", "Hörder"], for: "herdr")
        XCTAssertEqual(settings.soundsLike(for: "HERDR"), ["Herder", "Herda", "Hörder"])
        XCTAssertEqual(defaults.stringArray(forKey: "customVocabulary.terms"), ["herdr", "Rudek"])

        // Off: no rules. On: the term first, then its forms.
        XCTAssertEqual(settings.activeRules, [])
        settings.isEnabled = true
        XCTAssertEqual(settings.activeRules.map(\.match), ["herdr", "Rudek", "Herder", "Herda", "Hörder"])
        XCTAssertEqual(Set(settings.activeRules.map(\.spelling)), ["herdr", "Rudek"])

        // Forms of a removed term are dropped.
        settings.terms = ["Rudek"]
        XCTAssertEqual(settings.soundsLike, [:])
    }

    func testSoundsLikeFormsAreUniqueAndCapped() {
        let terms = ["herdr", "pane"]
        let raw = ["herdr": (1...12).map { "Form \($0)" }, "pane": ["Pain", "Form 1"], "gone": ["Weg"]]
        let clean = CustomVocabularySettings.sanitize(soundsLike: raw, terms: terms)
        XCTAssertEqual(clean["herdr"]?.count, CustomVocabularySettings.maxSoundsLikePerTerm)
        XCTAssertEqual(clean["pane"], ["Pain"])
        XCTAssertNil(clean["gone"])
        XCTAssertEqual(CustomVocabularySettings.parseSoundsLike("Herder, Herda;\n Hörder ,,"), ["Herder", "Herda", "Hörder"])
    }
}
