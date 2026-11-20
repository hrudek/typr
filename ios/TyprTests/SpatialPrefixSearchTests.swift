import Foundation
import XCTest
@testable import Typr

@MainActor
final class SpatialPrefixSearchTests: XCTestCase {
    private let grid = KeyboardLayout(width: 393, orientation: .portrait, layer: .letters, field: .text,
                                      showsGlobe: false, showsStrip: true)

    private func evidence(_ typed: String, aimed: String? = nil, noise: Bool = false) -> KeyboardTouchWord {
        let samples = zip(typed, aimed ?? typed).enumerated().map { index, pair in
            let key = grid.key(.character(String(pair.0).lowercased()))!
            let frame = grid.key(.character(String(pair.1).lowercased()))!.frame
            return KeyboardTouchWord.Sample(text: String(pair.0),
                point: CGPoint(x: frame.midX + (noise ? CGFloat(index % 3 - 1) * 1.7 : 0),
                               y: frame.midY + (noise ? CGFloat(index % 2) * 2 - 1 : 0)), key: key)
        }
        return KeyboardTouchWord(layout: grid, samples: samples)
    }

    private func track(_ word: KeyboardTouchWord, engine: AutocorrectEngine) {
        var before = ""
        for sample in word.samples {
            let after = before + sample.text
            engine.touchInput.append(text: sample.text, point: sample.point, key: sample.key,
                                     layout: word.layout, before: before, after: after)
            before = after
        }
    }

    private func bundled() throws -> [SpatialWordDecoder.Language: SpatialWordLexicon] {
        try XCTUnwrap(BundledKeyboardData.lexicons)
    }

    func testExactFrequencyOrderNFCAndDeterminism() {
        let words = spatialLexicon([("häuser", 90), ("häuschen", 100), ("haus", 80), ("hause", 40), ("haupt", 30)])
        let expected = ["häuschen", "häuser"]
        for prefix in ["hä", "ha\u{308}", "HÄ"] {
            let result = SpatialPrefixSearch.search(prefix, lexicons: [.german: words], languages: [.german])
            XCTAssertEqual(Array(result.candidates.prefix(2).map(\.word)), expected)
            XCTAssertTrue(result.candidates.allSatisfy(\.isCompletion))
        }
        XCTAssertNotNil(words.logPrior(for: "häuser"))
        let equal = spatialLexicon([("hello", 10), ("help", 10), ("held", 10)])
        for _ in 0..<5 {
            XCTAssertEqual(SpatialPrefixSearch.search("he", lexicons: [.english: equal], languages: [.english])
                .candidates.map(\.word), ["held", "hello", "help"])
        }
    }

    func testEqualFrequencyBroadTrieAndLanguageNormalization() {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
        let entries = alphabet.flatMap { a in alphabet.map { b in ("aa" + String(a) + String(b), UInt32(1)) } }
        let source = spatialLexicon(entries)
        let result = SpatialPrefixSearch.search("aa", lexicons: [.english: source], languages: [.english])
        XCTAssertEqual(result.candidates.map(\.word), entries.prefix(8).map { $0.0 })
        XCTAssertLessThan(result.visits, 100)
        let en = spatialLexicon([("share", 10), ("shell", 90)])
        let de = spatialLexicon([("share", 100), ("sheriff", 900)])
        let mixed = SpatialPrefixSearch.search("sh", lexicons: [.english: en, .german: de], languages: [.german, .english])
        XCTAssertEqual(mixed.candidates.map(\.word), ["shell", "sheriff", "share"])
        XCTAssertEqual(mixed.candidates.filter { $0.word == "share" }.count, 1)
    }

    func testNoisyPrefixCompletionPickCountsWithoutTouchLabels() throws {
        let words = spatialLexicon([("keyboard", 100), ("hello", 100)])
        let ac = AutocorrectEngine(checker: SpatialChecker(valid: []), learning: KeyboardLearningSession(),
                                   spatialDecoder: SpatialWordDecoder(lexicons: [.english: words]))
        let taps = evidence("gell", aimed: "hell")
        track(taps, engine: ac)
        let suggestion = try XCTUnwrap(ac.suggestions(beforeInput: "gell", field: .text, autocorrectionType: nil)
            .first { $0.replacement == "hello" })
        ac.recordSuggestionFeedback(suggestion, literal: "gell", evidence: taps)
        XCTAssertTrue(suggestion.isCompletion)
        XCTAssertEqual(ac.learning.model.lexicon.counts["hello"], 1)
        XCTAssertEqual(ac.learning.diagnostics[.manualCompletionPick], 1)
        XCTAssertEqual(ac.learning.diagnostics.acceptedLabels, 0)
        XCTAssertTrue(ac.learning.model.state.layouts.isEmpty)
    }

    func testSelectionUnavailableResourcesAndBounds() throws {
        let words = try bundled()
        XCTAssertTrue(SpatialPrefixSearch.search("ke", lexicons: [.english: words[.english]!],
                                                languages: [.english, .german]).candidates.isEmpty)
        for prefix in ["", "a", "a_b", "éé", String(repeating: "a", count: 32)] {
            XCTAssertEqual(SpatialPrefixSearch.search(prefix, lexicons: words, languages: [.english]).generated, 0)
        }
        for budget in [0, 1, 10, 512, 100_000] {
            let result = SpatialPrefixSearch.search("be", lexicons: words, languages: [.german, .english], budget: budget)
            XCTAssertLessThanOrEqual(result.visits, min(budget, SpatialPrefixSearch.maxVisits))
            XCTAssertLessThanOrEqual(result.generated, SpatialPrefixSearch.maxGenerated)
            if budget < 10 { XCTAssertTrue(result.truncated) }
        }
        XCTAssertTrue(SpatialPrefixSearch.search("keyb", lexicons: words, languages: [.german]).candidates
            .allSatisfy { $0.language == .german })
    }

    func testPhysicalHolderDensitiesAndNoPopupEvidence() throws {
        let tap = evidence("aous")
        let emissions = try XCTUnwrap(KeyboardLetterMap.emissions(for: tap, calibration: nil))
        for (index, pair) in zip([0, 1, 2, 3], [(Character("a"), Character("ä")), ("o", "ö"), ("u", "ü"), ("s", "ß")]) {
            let a = SpatialWordLexicon.alphabet.firstIndex(of: pair.0)!
            let b = SpatialWordLexicon.alphabet.firstIndex(of: pair.1)!
            XCTAssertEqual(emissions.likelihoods[index][a], emissions.likelihoods[index][b])
        }
        var popup = evidence("uber")
        let sample = popup.samples[0]
        popup.samples[0] = .init(text: "ü", point: sample.point, key: sample.key)
        XCTAssertNil(KeyboardLetterMap.emissions(for: popup, calibration: nil), "Popup is not an ordinary ü key")
        let calibration = SpatialTouchCalibration(keys: ["u": .init(offsetX: 0.2, offsetY: -0.1, sigmaX: 0.3, sigmaY: 0.4)])
        let calibrated = try XCTUnwrap(KeyboardLetterMap.emissions(for: evidence("uber"), calibration: calibration))
        XCTAssertEqual(calibrated.likelihoods[0][20], calibrated.likelihoods[0][28])
    }

    func testHolderCandidatesAndValidHomographsStayManual() throws {
        let words = spatialLexicon([("schon", 10), ("schön", 100), ("über", 100), ("für", 100), ("straße", 100)])
        let decoder = SpatialWordDecoder(lexicons: [.german: words, .english: words])
        for (typed, intended) in [("uber", "über"), ("fur", "für"), ("strase", "straße"), ("Strasse", "Straße")] {
            let ac = AutocorrectEngine(checker: SpatialChecker(valid: []), learning: KeyboardLearningSession(), spatialDecoder: decoder)
            ac.german = GermanAutocorrect(checker: SpatialChecker(valid: [intended], guesses: [intended]))
            track(evidence(typed), engine: ac)
            XCTAssertTrue(ac.suggestions(beforeInput: typed, field: .text, autocorrectionType: nil)
                .contains { $0.replacement == intended }, typed)
        }
        let valid: Set<String> = ["schon", "schön", "uber", "über", "fur", "für", "Strasse", "Straße"]
        let ac = AutocorrectEngine(checker: SpatialChecker(valid: valid), learning: KeyboardLearningSession(), spatialDecoder: decoder)
        ac.german = GermanAutocorrect(checker: SpatialChecker(valid: valid, guesses: ["schön", "über", "für", "Straße"]))
        for token in valid.sorted() {
            if token.allSatisfy({ $0.isASCII }) { track(evidence(token), engine: ac) }
            XCTAssertNil(ac.replacementOnSpace(beforeInput: token, field: .text, autocorrectionType: nil), token)
            ac.touchInput.clear()
        }
        track(evidence("schon"), engine: ac)
        XCTAssertTrue(ac.suggestions(beforeInput: "schon", field: .text, autocorrectionType: nil)
            .contains { $0.replacement == "schön" && !$0.isCompletion && !$0.willAutoReplace })
        XCTAssertEqual(ac.replacementOnSpace(beforeInput: "fuer", field: .text, autocorrectionType: nil)?.replacement, "für")
    }

    func testCompletionsCanonicalNounsNoisyPrefixAndNoAutomaticSuffix() throws {
        let words = spatialLexicon([("keyboard", 100), ("häuser", 100), ("hello", 100)])
        let decoder = SpatialWordDecoder(lexicons: [.english: words, .german: words])
        let ac = AutocorrectEngine(checker: SpatialChecker(valid: ["keyboard", "hello"]),
                                   learning: KeyboardLearningSession(), spatialDecoder: decoder)
        ac.german = GermanAutocorrect(checker: SpatialChecker(valid: ["Häuser"]))
        for (typed, aimed, intended) in [("keyb", "keyb", "keyboard"), ("gell", "hell", "hello"), ("hau", "hau", "Häuser")] {
            ac.touchInput.clear()
            track(evidence(typed, aimed: aimed), engine: ac)
            let chip = try XCTUnwrap(ac.suggestions(beforeInput: typed, field: .text, autocorrectionType: nil)
                .first { $0.replacement == intended }, typed)
            XCTAssertTrue(chip.isCompletion)
            XCTAssertFalse(chip.willAutoReplace)
            XCTAssertNil(ac.replacementOnSpace(beforeInput: typed, field: .text, autocorrectionType: nil))
        }
        // Even a high-prior one-letter prefix extension from the old edit/spelling path is manual.
        ac.touchInput.clear()
        track(evidence("keyboar"), engine: ac)
        XCTAssertNil(ac.replacementOnSpace(beforeInput: "keyboar", field: .text, autocorrectionType: nil))
    }

    func testPrefixExtendingTextReplacementIsHighlightedAndAppliedAtSpace() async throws {
        for (german, english) in [(true, false), (false, true), (true, true), (false, false)] {
            let ac = AutocorrectEngine(checker: SpatialChecker(valid: []), learning: KeyboardLearningSession(), spatialDecoder: nil)
            ac.englishEnabled = english
            ac.german = german ? GermanAutocorrect(checker: SpatialChecker(valid: [])) : nil
            ac.loadLexiconEntries([("sig", "signature")])
            let target = FixtureTextTarget()
            target.autocapitalizationType = .some(.none)
            let engine = FullKeyboardEngine(target: target, autocorrect: ac)
            engine.configureForField()
            target.insertText("sig")
            engine.textDidChange()
            await engine.waitForSuggestions()
            let primary = try XCTUnwrap(engine.suggestions.first { $0.replacement == "signature" })
            XCTAssertEqual(primary.kind, .primary(autoReplace: true), "Explicit rules are not inferred suffixes")
            XCTAssertTrue(primary.willAutoReplace)
            engine.typeSpaceFromTyprKey()
            XCTAssertEqual(target.text, "signature ")
            XCTAssertEqual(ac.pendingFeedback?.kind, .autoRule)
            engine.deleteBackward()
            XCTAssertEqual(target.text, "sig", "Text-replacement undo remains linked")
            await engine.waitForSuggestions()
            XCTAssertFalse(engine.suggestions.contains(where: \.willAutoReplace), "Undo protection also clears the highlight")
            engine.cancelSuggestions()
        }
    }

    func testCompletionEvaluationOnFrozenHoldoutPrefixes() throws {
        let words = try bundled()
        let decoder = SpatialWordDecoder(lexicons: words)
        for (name, languages, vocabulary) in [
            ("DE", Set([SpatialWordDecoder.Language.german]), SpatialTypoEvaluationFixtures.german),
            ("EN", Set([SpatialWordDecoder.Language.english]), SpatialTypoEvaluationFixtures.english),
            ("mixed", Set(SpatialWordDecoder.Language.allCases), SpatialTypoEvaluationFixtures.german + SpatialTypoEvaluationFixtures.english)
        ] {
            // Odd-index common words are frozen holdout, not used to tune search constants.
            let heldout = vocabulary.enumerated().filter { $0.offset % 2 == 1 && $0.element.count >= 5 }.map(\.element)
            for noisy in [false, true] {
                var recall1 = 0, recall3 = 0, baseline3 = 0, visits = 0, generated = 0
                var times: [Double] = []
                for (ordinal, word) in heldout.enumerated() {
                    let prefix = String(word.prefix(word.count - 2))
                    var typed = Array(prefix)
                    if noisy {
                        // Neighbor symbol, but observed point near the intended center, as in
                        // the existing typo evaluation. Stable public synthetic data, not runtime capture.
                        let target = grid.key(.character(String(typed[0])))!.frame
                        let neighbors = Array("abcdefghijklmnopqrstuvwxyz").filter { $0 != typed[0] }.sorted {
                            func distance(_ c: Character) -> CGFloat {
                                let frame = grid.key(.character(String(c)))!.frame
                                return hypot(frame.midX - target.midX, frame.midY - target.midY)
                            }
                            return distance($0) == distance($1) ? $0 < $1 : distance($0) < distance($1)
                        }
                        typed[0] = neighbors[ordinal % min(2, neighbors.count)]
                    }
                    let tap = evidence(String(typed), aimed: prefix, noise: true)
                    let start = DispatchTime.now().uptimeNanoseconds
                    let result = SpatialPrefixSearch.search(String(typed), lexicons: words, languages: languages, evidence: tap)
                    times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                    let candidates = result.candidates.filter(\.isCompletion).map(\.word)
                    recall1 += candidates.first == word ? 1 : 0
                    recall3 += candidates.prefix(3).contains(word) ? 1 : 0
                    baseline3 += decoder.decode(tap, languages: languages)?.suggestions.prefix(3).contains { $0.word == word } == true ? 1 : 0
                    visits = max(visits, result.visits)
                    generated = max(generated, result.generated)
                }
                let sorted = times.sorted()
                let mean = times.reduce(0, +) / Double(times.count)
                let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
                print("EVAL P2_completion language=\(name) noisy=\(noisy) n=\(heldout.count) recall1=\(recall1) recall3=\(recall3) baseline3=\(baseline3) mean_ms=\(mean) p95_ms=\(p95) max_ms=\(sorted.last!) visits=\(visits) generated=\(generated)")
                XCTAssertGreaterThanOrEqual(Double(recall3) / Double(heldout.count), 0.35)
                XCTAssertGreaterThan(recall3, baseline3)
                XCTAssertLessThanOrEqual(visits, SpatialPrefixSearch.maxVisits)
                XCTAssertLessThanOrEqual(generated, SpatialPrefixSearch.maxGenerated)
            }
        }
    }

    func testBroadPrefixesMemoryAndControlEvaluation() throws {
        let words = try bundled()
        let decoder = SpatialWordDecoder(lexicons: words)
        let controls = SpatialTypoEvaluationFixtures.germanNouns + SpatialTypoEvaluationFixtures.novel
            + SpatialTypoEvaluationFixtures.absent + ["schon", "schön", "uber", "über", "fur", "für", "Strasse", "Straße"]
        let ac = AutocorrectEngine(checker: SpatialChecker(valid: Set(controls)), learning: KeyboardLearningSession(), spatialDecoder: decoder)
        ac.german = GermanAutocorrect(checker: SpatialChecker(valid: Set(controls)))
        var unwanted = 0
        for token in controls {
            if ac.replacementOnSpace(beforeInput: token, field: .text, autocorrectionType: nil) != nil { unwanted += 1 }
        }
        XCTAssertEqual(unwanted, 0)
        var maxVisits = 0, maxGenerated = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for prefix in ["be", "ge", "in", "an", "re", "un", "st", "ha", "th", "co"] {
            let result = SpatialPrefixSearch.search(prefix, lexicons: words, languages: Set(words.keys))
            maxVisits = max(maxVisits, result.visits)
            maxGenerated = max(maxGenerated, result.generated)
            XCTAssertFalse(result.candidates.isEmpty)
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 / 10
        let resourceBytes = words.values.reduce(0) { $0 + $1.data.count + $1.nodeCount * 4 }
        XCTAssertLessThan(resourceBytes, 8 * 1_024 * 1_024)
        XCTAssertLessThan(SpatialPrefixSearch.arenaPayloadByteBound, 512 * 1_024)
        XCTAssertLessThanOrEqual(maxVisits, SpatialPrefixSearch.maxVisits)
        XCTAssertLessThanOrEqual(maxGenerated, SpatialPrefixSearch.maxGenerated)
        print("EVAL P2_bounds controls=\(controls.count) unwanted_auto=\(unwanted) broad_mean_ms=\(ms) visits=\(maxVisits) generated=\(maxGenerated) arena_payload_bound=\(SpatialPrefixSearch.arenaPayloadByteBound) resource_index_bytes=\(resourceBytes)")
    }
}
