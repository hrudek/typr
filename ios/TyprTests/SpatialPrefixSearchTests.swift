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

    private func lexicon(_ words: [(String, UInt32)]) -> SpatialWordLexicon {
        final class Node {
            var children: [Int: Node] = [:]
            var count: UInt32 = 0
        }
        let root = Node()
        for (word, count) in words {
            var node = root
            for letter in word {
                let label = SpatialWordLexicon.alphabet.firstIndex(of: letter)!
                if node.children[label] == nil { node.children[label] = Node() }
                node = node.children[label]!
            }
            node.count += count
        }
        var nodes = [(255, root)]
        var records = Data()
        func append(_ n: UInt32, to data: inout Data) {
            for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: n >> shift)) }
        }
        var cursor = 0
        while cursor < nodes.count {
            let (label, node) = nodes[cursor]
            let children = node.children.sorted { $0.key < $1.key }
            records.append(contentsOf: [UInt8(label), UInt8(children.count), 0, 0])
            append(children.isEmpty ? 0 : UInt32(nodes.count), to: &records)
            append(node.count, to: &records)
            nodes.append(contentsOf: children.map { ($0.key, $0.value) })
            cursor += 1
        }
        var data = Data("TSW1".utf8)
        for value in [UInt32(nodes.count), UInt32(words.count), 0, words.reduce(0) { $0 + $1.1 }, 0] {
            append(value, to: &data)
        }
        data.append(records)
        return SpatialWordLexicon(data: data)!
    }

    private func bundled() throws -> [SpatialWordDecoder.Language: SpatialWordLexicon] {
        try XCTUnwrap(BundledKeyboardData.lexicons)
    }

    func testExactFrequencyOrderNFCAndDeterminism() {
        let words = lexicon([("häuser", 90), ("häuschen", 100), ("haus", 80), ("hause", 40), ("haupt", 30)])
        let expected = ["häuschen", "häuser"]
        for prefix in ["hä", "ha\u{308}", "HÄ"] {
            let result = SpatialPrefixSearch.search(prefix, lexicons: [.german: words], languages: [.german])
            XCTAssertEqual(Array(result.candidates.prefix(2).map(\.word)), expected)
            XCTAssertTrue(result.candidates.allSatisfy(\.isCompletion))
        }
        XCTAssertNotNil(words.logPrior(for: "häuser"))
        let equal = lexicon([("hello", 10), ("help", 10), ("held", 10)])
        for _ in 0..<5 {
            XCTAssertEqual(SpatialPrefixSearch.search("he", lexicons: [.english: equal], languages: [.english])
                .candidates.map(\.word), ["held", "hello", "help"])
        }
    }

    func testEqualFrequencyBroadTrieAndLanguageNormalization() {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
        let entries = alphabet.flatMap { a in alphabet.map { b in ("aa" + String(a) + String(b), UInt32(1)) } }
        let source = lexicon(entries)
        let result = SpatialPrefixSearch.search("aa", lexicons: [.english: source], languages: [.english])
        XCTAssertEqual(result.candidates.map(\.word), entries.prefix(8).map { $0.0 })
        XCTAssertLessThan(result.visits, 100)
        let en = lexicon([("share", 10), ("shell", 90)])
        let de = lexicon([("share", 100), ("sheriff", 900)])
        let mixed = SpatialPrefixSearch.search("sh", lexicons: [.english: en, .german: de], languages: [.german, .english])
        XCTAssertEqual(mixed.candidates.map(\.word), ["shell", "sheriff", "share"])
        XCTAssertEqual(mixed.candidates.filter { $0.word == "share" }.count, 1)
    }

    func testManualCompletionFeedbackCountsWithoutTouchLabels() throws {
        for (typed, intended, noisy) in [("keyb", "keyboard", false), ("gell", "hello", true)] {
            let words = lexicon([("keyboard", 100), ("hello", 100)])
            let ac = AutocorrectEngine(checker: PrefixChecker(), learning: KeyboardLearningSession(),
                                       spatialDecoder: SpatialWordDecoder(lexicons: [.english: words]))
            let taps = evidence(typed, aimed: noisy ? "hell" : typed)
            track(taps, engine: ac)
            let suggestion = try XCTUnwrap(ac.suggestions(beforeInput: typed, field: .text, autocorrectionType: nil)
                .first { $0.replacement == intended })
            ac.recordSuggestionFeedback(suggestion, literal: typed, evidence: taps)
            XCTAssertTrue(suggestion.isCompletion)
            XCTAssertEqual(ac.learning.model.lexicon.counts[intended], 1)
            XCTAssertEqual(ac.learning.diagnostics[.manualCompletionPick], 1)
            XCTAssertEqual(ac.learning.diagnostics.acceptedLabels, 0)
            XCTAssertTrue(ac.learning.model.state.layouts.isEmpty)
        }
        print("EVAL P2_learning completion_picks=2 counted_words=2 touch_labels=0")
    }

    func testKeyboardStripCompletionSelectionAndSpaceBoundary() async throws {
        for pick in [false, true] {
            let words = lexicon([("keyboard", 100)])
            let ac = AutocorrectEngine(checker: PrefixChecker(), learning: KeyboardLearningSession(),
                                       spatialDecoder: SpatialWordDecoder(lexicons: [.english: words]))
            let target = FixtureTextTarget(text: "keyb")
            target.autocapitalizationType = .some(.none)
            let keyboard = FullKeyboardEngine(target: target, autocorrect: ac)
            keyboard.width = 393
            keyboard.configureForField()
            track(evidence("keyb"), engine: ac)
            keyboard.refreshSuggestions()
            await keyboard.waitForSuggestions()
            let chip = try XCTUnwrap(keyboard.suggestions.first { $0.replacement == "keyboard" })
            XCTAssertTrue(chip.isCompletion)
            if pick {
                keyboard.acceptSuggestion(chip)
                XCTAssertEqual(target.text, "keyboard ")
                XCTAssertEqual(ac.learning.model.lexicon.counts["keyboard"], 1)
                XCTAssertEqual(ac.learning.diagnostics.acceptedLabels, 0)
            } else {
                keyboard.typeSpaceFromTyprKey()
                XCTAssertEqual(target.text, "keyb ")
                XCTAssertTrue(ac.learning.model.lexicon.counts.isEmpty)
            }
        }
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
        let words = lexicon([("schon", 10), ("schön", 100), ("über", 100), ("für", 100), ("straße", 100)])
        let decoder = SpatialWordDecoder(lexicons: [.german: words, .english: words])
        for (typed, intended) in [("uber", "über"), ("fur", "für"), ("strase", "straße"), ("Strasse", "Straße")] {
            let ac = AutocorrectEngine(checker: PrefixChecker(), learning: KeyboardLearningSession(), spatialDecoder: decoder)
            ac.german = GermanAutocorrect(checker: PrefixChecker(valid: [intended], guesses: [intended]))
            track(evidence(typed), engine: ac)
            XCTAssertTrue(ac.suggestions(beforeInput: typed, field: .text, autocorrectionType: nil)
                .contains { $0.replacement == intended }, typed)
        }
        let valid: Set<String> = ["schon", "schön", "uber", "über", "fur", "für", "Strasse", "Straße"]
        let ac = AutocorrectEngine(checker: PrefixChecker(valid: valid), learning: KeyboardLearningSession(), spatialDecoder: decoder)
        ac.german = GermanAutocorrect(checker: PrefixChecker(valid: valid, guesses: ["schön", "über", "für", "Straße"]))
        for token in valid.sorted() {
            if token.allSatisfy({ $0.isASCII }) { track(evidence(token), engine: ac) }
            XCTAssertNil(ac.replacementOnSpace(beforeInput: token, field: .text, autocorrectionType: nil), token)
            ac.touchInput.clear()
        }
        track(evidence("schon"), engine: ac)
        XCTAssertTrue(ac.suggestions(beforeInput: "schon", field: .text, autocorrectionType: nil)
            .contains { $0.replacement == "schön" && !$0.isCompletion && !$0.willAutoReplace })
        XCTAssertEqual(ac.replacementOnSpace(beforeInput: "fuer", field: .text, autocorrectionType: nil)?.replacement, "für")
        print("EVAL P2_holders controls=8 unwanted_auto=0")
    }

    func testCompletionsCanonicalNounsNoisyPrefixAndNoAutomaticSuffix() throws {
        let words = lexicon([("keyboard", 100), ("häuser", 100), ("hello", 100)])
        let decoder = SpatialWordDecoder(lexicons: [.english: words, .german: words])
        let ac = AutocorrectEngine(checker: PrefixChecker(valid: ["keyboard", "hello"]),
                                   learning: KeyboardLearningSession(), spatialDecoder: decoder)
        ac.german = GermanAutocorrect(checker: PrefixChecker(valid: ["Häuser"]))
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
            let ac = AutocorrectEngine(checker: PrefixChecker(), learning: KeyboardLearningSession(), spatialDecoder: nil)
            ac.englishEnabled = english
            ac.german = german ? GermanAutocorrect(checker: PrefixChecker()) : nil
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
        let ac = AutocorrectEngine(checker: PrefixChecker(valid: Set(controls)), learning: KeyboardLearningSession(), spatialDecoder: decoder)
        ac.german = GermanAutocorrect(checker: PrefixChecker(valid: Set(controls)))
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

@MainActor
private final class PrefixChecker: TextChecking {
    let valid: Set<String>
    let values: [String]
    init(valid: Set<String> = [], guesses: [String] = []) { self.valid = valid; values = guesses }
    func isWordValid(_ word: String) -> Bool { valid.contains(word) }
    func guesses(for word: String) -> [String] { values }
    func completions(for prefix: String) -> [String] { [] }
}
