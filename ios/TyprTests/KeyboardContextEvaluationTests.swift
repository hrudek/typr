import Foundation
import XCTest
@testable import Typr

final class KeyboardContextEvaluationTests: XCTestCase {
    nonisolated private static var timingPlatform: String {
        #if os(Linux)
        "Linux_XCTest"
        #else
        "Apple_XCTest"
        #endif
    }

    func testSyntheticNextWordsMixtureLatencyAndPayload() throws {
        let model = try XCTUnwrap(BundledKeyboardData.contextModel)
        // Independently authored synthetic sequences, not private text or a claim of
        // corpus-disjoint natural messaging. Predictions are measured before the target.
        let sets = [
            ("de", ["ich bin heute zu hause", "das ist ein guter tag", "wir haben keine zeit", "ich habe ein buch"]),
            ("en", ["i am going to the house", "this is a good day", "we have no time", "i have a book"]),
            ("mixed", ["ich habe ein meeting morgen", "i have a hund today", "das ist good", "this is gut"])
        ]
        var times: [Double] = []
        for (name, sentences) in sets {
            var hit1 = 0, hit3 = 0, baseline = 0, wrong = 0, naiveWrong = 0, pairs = 0
            var rr = 0.0
            for sentence in sentences {
                let words = sentence.split(separator: " ").map(String.init)
                var state = KeyboardContextModel.State()
                for i in 0..<(words.count - 1) {
                    state.consume(words[i], model: model)
                    let start = ContinuousClock.now
                    let got = model.suggestions(after: words[i], weightDE: state.weightDE,
                                                german: name != "en", english: name != "de")
                    let elapsed = start.duration(to: .now).components
                    times.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
                    let keys = got.map(\.key), target = words[i + 1]
                    if let rank = keys.firstIndex(of: target) { hit3 += 1; rr += 1 / Double(rank + 1); if rank == 0 { hit1 += 1 } }
                    let uni = model.suggestions(after: nil, weightDE: state.weightDE, german: name != "en", english: name != "de")
                    if uni.contains(where: { $0.key == target }) { baseline += 1 }
                    // D3b's fixed >=4:1 smoothed unigram language proxy, all slots denominator.
                    // Synthetic mixed targets use their own unambiguous corpus label.
                    let ratio = model.logRatio(target)
                    let gold = name == "de" ? 1 : name == "en" ? -1 : ratio >= log(4) ? 1 : ratio <= -log(4) ? -1 : 0
                    func isWrong(_ key: String) -> Bool {
                        let r = model.logRatio(key)
                        return gold == 1 ? r <= -log(4) : gold == -1 ? r >= log(4) : false
                    }
                    wrong += keys.filter(isWrong).count
                    naiveWrong += model.suggestions(after: words[i], weightDE: 0.5,
                                                    german: name != "en", english: name != "de").filter { isWrong($0.key) }.count
                    XCTAssertLessThanOrEqual(got.count, 3)
                    XCTAssertTrue(Set(keys).isDisjoint(with: KeyboardContextModel.suppressed))
                    pairs += 1
                }
            }
            print(String(format: "EVAL context_next_%@ pairs=%d recall1=%.4f recall3=%.4f mrr3=%.4f unigram_recall3=%.4f wrong_rate=%.4f naive_wrong_rate=%.4f", name, pairs, Double(hit1)/Double(pairs), Double(hit3)/Double(pairs), rr/Double(pairs), Double(baseline)/Double(pairs), Double(wrong)/Double(pairs*3), Double(naiveWrong)/Double(pairs*3)))
            if name != "mixed" { XCTAssertGreaterThanOrEqual(hit3, baseline) }
            if name == "mixed" { XCTAssertLessThanOrEqual(wrong, naiveWrong) }
        }
        times.sort()
        XCTAssertEqual(times.count, 41) // Deterministic fixture work, never a wall-clock gate.
        XCTAssertEqual(model.residentPayloadBytes, 802_630)
        XCTAssertLessThan(model.residentPayloadBytes, 1_048_576)
        print(String(format: "EVAL context_cost calls=%d mean_ms=%.4f p95_ms=%.4f max_ms=%.4f mapped_bytes=%d index_bytes=32000 resident_payload_bytes=%d max_seen_keys=16000 context_utf8_cap=2048", times.count, times.reduce(0,+)/Double(times.count), times[Int(Double(times.count-1)*0.95)], times.last!, model.residentPayloadBytes-32000, model.residentPayloadBytes))
    }

    func testCC0HeldoutNextWordEvaluation() throws {
        let model = try XCTUnwrap(BundledKeyboardData.contextModel)
        let url = try XCTUnwrap(Bundle.main.url(forResource: "context-heldout-cc0", withExtension: "json", subdirectory: "WordData"))
        struct Fixture: Decodable { let sentences: [String: [[String]]] }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        for language in ["de", "en"] {
            var n = 0, h1 = 0, h3 = 0, uni = 0, wrong = 0
            var rr = 0.0
            for words in try XCTUnwrap(fixture.sentences[language]) {
                var state = KeyboardContextModel.State()
                for i in 0..<(words.count - 1) {
                    let h = KeyboardContextModel.key(words[i]), w = KeyboardContextModel.key(words[i+1])
                    state.consume(h, model: model)
                    let got = model.suggestions(after: h, weightDE: state.weightDE,
                                                german: language == "de", english: language == "en")
                    if let rank = got.firstIndex(where: { $0.key == w }) {
                        h3 += 1; rr += 1 / Double(rank + 1); if rank == 0 { h1 += 1 }
                    }
                    if model.suggestions(after: nil, weightDE: state.weightDE, german: language == "de", english: language == "en").contains(where: { $0.key == w }) { uni += 1 }
                    wrong += got.filter { language == "de" ? model.logRatio($0.key) <= -log(4) : model.logRatio($0.key) >= log(4) }.count
                    n += 1
                }
            }
            print(String(format: "EVAL context_heldout_%@ sentences=64 pairs=%d recall1=%.4f recall3=%.4f mrr3=%.4f unigram_recall3=%.4f wrong_rate=%.4f source=CC0_CV_global_test_partition", language, n, Double(h1)/Double(n), Double(h3)/Double(n), rr/Double(n), Double(uni)/Double(n), Double(wrong)/Double(n*3)))
            XCTAssertGreaterThan(h3, uni)
            XCTAssertLessThan(Double(wrong)/Double(n*3), 0.2)
        }
    }

    private static func heldout() throws -> [String: [[String]]] {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "context-heldout-cc0", withExtension: "json", subdirectory: "WordData"))
        struct Fixture: Decodable { let sentences: [String: [[String]]] }
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).sentences
    }

    /// D3b.5-style alternating held-out sentences (DE→EN for even, EN→DE for odd indices),
    /// both languages selected. Compares the exact decaying posterior with naive 50/50 and
    /// a hard language switch on identical rankers; the target is never consumed early.
    func testHeldoutAlternatingMixedWrongLanguageRate() throws {
        let model = try XCTUnwrap(BundledKeyboardData.contextModel)
        let sentences = try Self.heldout()
        let de = try XCTUnwrap(sentences["de"]), en = try XCTUnwrap(sentences["en"])
        var pairs = 0, switchPairs = 0
        var hits = [0, 0, 0], wrong = [0, 0, 0], switchWrong = [0, 0, 0]
        for k in 0..<min(de.count, en.count) {
            let (first, second, gold) = k % 2 == 0 ? (de[k], en[k], -1) : (en[k], de[k], 1)
            var state = KeyboardContextModel.State()
            for word in first { state.consume(KeyboardContextModel.key(word), model: model) }
            state.sentenceBoundary()
            for i in 0..<(second.count - 1) {
                let h = KeyboardContextModel.key(second[i]), target = KeyboardContextModel.key(second[i + 1])
                state.consume(h, model: model)
                let hard = state.value > 0 ? 1.0 : state.value < 0 ? 0.0 : 0.5
                for (scheme, weight) in [state.weightDE, 0.5, hard].enumerated() {
                    let keys = model.suggestions(after: h, weightDE: weight).map(\.key)
                    if keys.contains(target) { hits[scheme] += 1 }
                    // Fixed smoothed 4:1 corpus-ratio label; shared words never count as wrong.
                    let bad = keys.filter { gold == 1 ? model.logRatio($0) <= -log(4) : model.logRatio($0) >= log(4) }.count
                    wrong[scheme] += bad
                    if i < 3 { switchWrong[scheme] += bad }
                }
                pairs += 1
                if i < 3 { switchPairs += 1 }
            }
        }
        func rate(_ value: Int, _ n: Int) -> Double { Double(value) / Double(max(1, n)) }
        print(String(format: "EVAL context_mixed_alternating pairs=%d posterior_recall3=%.4f naive_recall3=%.4f hard_recall3=%.4f posterior_wrong=%.4f naive_wrong=%.4f hard_wrong=%.4f first3_after_switch_posterior_wrong=%.4f first3_naive_wrong=%.4f source=CC0_CV_heldout",
                     pairs, rate(hits[0], pairs), rate(hits[1], pairs), rate(hits[2], pairs),
                     rate(wrong[0], pairs * 3), rate(wrong[1], pairs * 3), rate(wrong[2], pairs * 3),
                     rate(switchWrong[0], switchPairs * 3), rate(switchWrong[1], switchPairs * 3)))
        XCTAssertLessThan(wrong[0], wrong[1])
        XCTAssertGreaterThanOrEqual(hits[0], hits[1])
        XCTAssertLessThan(rate(wrong[0], pairs * 3), 0.10)
    }

    /// Integrated noisy-touch typos of every eligible held-out target word with its real left
    /// context. Same seeded taps, decoder and injected validity proxy for both variants; only
    /// the context resources differ. Automatic decisions must be identical.
    @MainActor
    func testHeldoutNoisyTouchSuggestionsAndAutomaticNonregression() throws {
        let model = try XCTUnwrap(BundledKeyboardData.contextModel)
        let sentences = try Self.heldout()
        let lexicons = try XCTUnwrap(BundledKeyboardData.lexicons)
        let decoder = SpatialWordDecoder(lexicons: lexicons)
        let grid = KeyboardLayout(width: 393, orientation: .portrait, layer: .letters, field: .text, showsGlobe: false, showsStrip: true)
        let de = try XCTUnwrap(sentences["de"]), en = try XCTUnwrap(sentences["en"])
        // Validity proxy: every held-out spelling is "valid" (not Apple's dictionary).
        let vocabulary = Set((de + en).flatMap { $0 }.flatMap { [$0, $0.lowercased()] })
        let pairCount: Int = min(de.count, en.count)
        let mixed: [([String], Int)] = (0..<pairCount).map { (k: Int) -> ([String], Int) in
            let first: [String] = k % 2 == 0 ? de[k] : en[k]
            let second: [String] = k % 2 == 0 ? en[k] : de[k]
            let words: [String] = first + ["."] + second
            let start: Int = first.count + 1
            return (words, start)
        }
        let groups: [(String, [([String], Int)])] = [("de", de.map { ($0, 1) }), ("en", en.map { ($0, 1) }), ("mixed", mixed)]
        var ordinal = 0
        var milliseconds = [[Double](), [Double]()]
        for (name, cases) in groups {
            var n = 0, controls = 0, top1 = [0, 0], top3 = [0, 0], wrongAuto = [0, 0], unwanted = [0, 0], changed = 0
            var hard = 0, hardTop1 = [0, 0], wins = 0, losses = 0, reordered = 0
            for (words, start) in cases {
                for i in max(1, start)..<words.count {
                    let target = words[i].lowercased()
                    guard target.count >= 3, target.count <= 12,
                          // Umlauts/ß come from the accent menu, not a tap; those words are excluded here.
                          target.allSatisfy({ "abcdefghijklmnopqrstuvwxyz".contains($0) }) else { continue }
                    let prefix = words[..<i].joined(separator: " ").replacingOccurrences(of: " .", with: ".") + " "
                    ordinal += 1
                    // One and two neighbour substitutions, plus the correctly typed control.
                    for error in [SpatialTypoEvaluationEvidence.ErrorClass.neighbour1, .neighbour2, nil] {
                        let word = try SpatialTypoEvaluationEvidence.evidence(target, grid: grid, error: error, ordinal: ordinal,
                                                                              seed: 0x5033, sigma: 0.18)
                        var autos: [String?] = [], firsts: [Bool] = [], strips: [[String]] = []
                        for variant in 0...1 {
                            let checker = Checker(valid: vocabulary, guesses: [])
                            let ac = AutocorrectEngine(checker: checker, learning: KeyboardLearningSession(), spatialDecoder: decoder,
                                                       contextResources: .init(model: variant == 1 ? model : nil))
                            ac.german = GermanAutocorrect(checker: checker)
                            var before = prefix
                            for sample in word.samples {
                                let after = before + sample.text
                                ac.touchInput.append(text: sample.text, point: sample.point, key: sample.key, layout: grid,
                                                     before: before, after: after)
                                before = after
                            }
                            if error != nil {
                                let clock = ContinuousClock.now
                                let strip = ac.suggestions(beforeInput: before, field: .text, autocorrectionType: .default)
                                let elapsed = clock.duration(to: .now).components
                                milliseconds[variant].append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
                                let keys = strip.map { KeyboardContextModel.key($0.replacement) }
                                strips.append(keys)
                                let first = keys.count > 1 && keys[1] == target
                                firsts.append(first)
                                if error == .neighbour2, first { hardTop1[variant] += 1 }
                                if first { top1[variant] += 1 }
                                if keys.contains(target) { top3[variant] += 1 }
                            }
                            let auto = ac.replacementOnSpace(beforeInput: before, field: .text, autocorrectionType: .default)?.replacement
                            autos.append(auto)
                            if let auto, KeyboardContextModel.key(auto) != target {
                                if error == nil { unwanted[variant] += 1 } else { wrongAuto[variant] += 1 }
                            }
                        }
                        if autos[0] != autos[1] { changed += 1 }
                        if error == nil { controls += 1 } else { n += 1 }
                        if error == .neighbour2 { hard += 1 }
                        if strips.count == 2, strips[0] != strips[1] { reordered += 1 }
                        if firsts.count == 2, firsts[0] != firsts[1] { if firsts[1] { wins += 1 } else { losses += 1 } }
                    }
                }
            }
            print("EVAL context_noisy_heldout_\(name) typos=\(n) baseline_recall1=\(top1[0]) context_recall1=\(top1[1]) baseline_recall3=\(top3[0]) context_recall3=\(top3[1]) two_neighbour=\(hard) two_neighbour_recall1=\(hardTop1[0])->\(hardTop1[1]) first_slot_wins=\(wins) first_slot_losses=\(losses) strips_changed=\(reordered) wrong_auto_baseline=\(wrongAuto[0]) wrong_auto_context=\(wrongAuto[1]) correct_controls=\(controls) unwanted_auto_baseline=\(unwanted[0]) unwanted_auto_context=\(unwanted[1]) changed_auto_decisions=\(changed) validity=injected_heldout_vocabulary")
            XCTAssertEqual(changed, 0, name)
            XCTAssertEqual(unwanted[1], unwanted[0], name)
            XCTAssertGreaterThanOrEqual(top3[1], top3[0], name)
            XCTAssertGreaterThanOrEqual(top1[1], top1[0], name)
        }
        func summary(_ values: [Double]) -> String {
            let sorted = values.sorted()
            return String(format: "mean_ms=%.3f p95_ms=%.3f max_ms=%.3f", sorted.reduce(0, +) / Double(sorted.count),
                          sorted[Int(Double(sorted.count - 1) * 0.95)], sorted.last!)
        }
        print("EVAL context_noisy_heldout_latency calls=\(milliseconds[1].count) baseline_\(summary(milliseconds[0])) context_\(summary(milliseconds[1])) timing=\(Self.timingPlatform)")
        XCTAssertEqual(milliseconds[1].count, 2_154) // Same bounded fixture calls in both variants.
        XCTAssertEqual(milliseconds[0].count, milliseconds[1].count)
    }

    @MainActor
    func testIntegratedNoisyTouchAndZeroAddedAutomaticChanges() throws {
        let model = try XCTUnwrap(BundledKeyboardData.contextModel)
        let lexicons = try XCTUnwrap(BundledKeyboardData.lexicons)
        let cases = [("de", "ich bin ", "heute"), ("de", "wir haben ", "arbeit"), ("de", "das ist ", "gut"),
                     ("en", "this is ", "good"), ("en", "i am ", "going"), ("en", "good ", "morning"),
                     ("mixed", "ich habe ein ", "meeting"), ("mixed", "i have a ", "hund"), ("mixed", "das ist ", "good")]
        let grid = KeyboardLayout(width: 393, orientation: .portrait, layer: .letters, field: .text, showsGlobe: false, showsStrip: true)
        for name in ["de", "en", "mixed"] {
            var counts = [[0, 0], [0, 0]], autos = [String?](), calls = 0
            for (_, context, intended) in cases.filter({ $0.0 == name }) {
                let letters = Array(intended)
                let first = grid.key(.character(String(letters[0])))!.frame
                let neighbor = grid.keys.filter { $0.character != nil && $0.kind != .character(String(letters[0])) }
                    .min { hypot($0.frame.midX-first.midX, $0.frame.midY-first.midY) < hypot($1.frame.midX-first.midX, $1.frame.midY-first.midY) }!
                let typo = neighbor.character! + String(intended.dropFirst())
                for variant in 0...1 {
                    let checker = Checker(valid: [intended], guesses: [intended])
                    let ac = AutocorrectEngine(checker: checker, spatialDecoder: SpatialWordDecoder(lexicons: lexicons),
                                               contextResources: KeyboardContextResources(model: variant == 1 ? model : nil))
                    ac.englishEnabled = name != "de"
                    if name != "en" { ac.german = GermanAutocorrect(checker: checker) }
                    var before = context
                    for (j, typed) in typo.enumerated() {
                        let frame = grid.key(.character(String(letters[j])))!.frame
                        let after = before + String(typed)
                        ac.touchInput.append(text: String(typed), point: CGPoint(x: frame.midX + 1.5, y: frame.midY - 1),
                                             key: grid.key(.character(String(typed)))!, layout: grid, before: before, after: after)
                        before = after
                    }
                    let suggestions = ac.suggestions(beforeInput: before, field: .text, autocorrectionType: .default)
                        .filter { $0.kind != .keepLiteral }.map { KeyboardContextModel.key($0.replacement) }
                    if suggestions.first == intended { counts[variant][0] += 1 }
                    if suggestions.prefix(3).contains(intended) { counts[variant][1] += 1 }
                    autos.append(ac.replacementOnSpace(beforeInput: before, field: .text, autocorrectionType: .default)?.replacement)
                }
                XCTAssertEqual(autos[autos.count-2], autos.last!)
                calls += 1
            }
            print("EVAL context_noisy_\(name) samples=\(calls) baseline_recall1=\(counts[0][0])/\(calls) context_recall1=\(counts[1][0])/\(calls) baseline_recall3=\(counts[0][1])/\(calls) context_recall3=\(counts[1][1])/\(calls) changed_auto_decisions=0")
            XCTAssertGreaterThanOrEqual(counts[1][1], counts[0][1])
        }
        let controls = ["im", "in", "am", "die", "war", "will", "also", "Gift", "Chef", "schon", "schön", "Straße", "Masse", "Maße", "Velqora", "OpenTelemetry", "WASM", "hausfenster", "meeting", "camelCase"]
        let checker = Checker(valid: Set(controls), guesses: [])
        let ac = AutocorrectEngine(checker: checker, spatialDecoder: SpatialWordDecoder(lexicons: lexicons), contextResources: .init(model: model))
        ac.german = GermanAutocorrect(checker: checker)
        for word in controls { XCTAssertNil(ac.replacementOnSpace(beforeInput: "ich habe \(word)", field: .text, autocorrectionType: .default)) }
        print("EVAL context_controls words=\(controls.count) unwanted_auto=0 added_auto=0 validity=injected_dictionary")
    }

    @MainActor
    func testEngineAfterSpaceAcceptAndSettings() async throws {
        let model = try XCTUnwrap(BundledKeyboardData.contextModel)
        let guessChecker = Checker(valid: [], guesses: ["hallo", "habe"])
        let ranked = AutocorrectEngine(checker: guessChecker, spatialDecoder: nil, contextResources: .init(model: model))
        ranked.englishEnabled = false; ranked.german = GermanAutocorrect(checker: guessChecker)
        let baseline = AutocorrectEngine(checker: guessChecker, spatialDecoder: nil, contextResources: .init(model: nil))
        baseline.englishEnabled = false; baseline.german = GermanAutocorrect(checker: guessChecker)
        XCTAssertEqual(baseline.suggestions(beforeInput: "ich ha", field: .text, autocorrectionType: .default)[1].replacement, "hallo")
        let promoted = ranked.suggestions(beforeInput: "ich ha", field: .text, autocorrectionType: .default)[1]
        XCTAssertEqual(promoted.replacement, "habe")
        XCTAssertTrue(promoted.isCompletion)
        XCTAssertFalse(promoted.willAutoReplace)
        XCTAssertNil(ranked.replacementOnSpace(beforeInput: "ich ha", field: .text, autocorrectionType: .default))
        let ac = AutocorrectEngine(checker: Checker(valid: [], guesses: []), spatialDecoder: nil, contextResources: .init(model: model))
        let target = FixtureTextTarget(text: "i am ")
        let engine = FullKeyboardEngine(target: target, autocorrect: ac)
        engine.width = 393
        engine.configureForField()
        // Predictions go through the deferred suggestion worker; the old chips never stay pickable.
        XCTAssertTrue(engine.suggestions.isEmpty)
        await engine.waitForSuggestions()
        XCTAssertEqual(engine.suggestions.count, 3)
        XCTAssertTrue(engine.suggestions.allSatisfy { !$0.willAutoReplace && $0.kind != .keepLiteral })
        let ranking = model.suggestions(after: "am", weightDE: model.context(before: "i am ", currentToken: nil).state.weightDE,
                                        german: false, english: true)
        XCTAssertEqual(engine.suggestions.map(\.replacement), KeyboardContextModel.stripOrder(ranking).map(\.display))
        XCTAssertEqual(engine.suggestions[1].kind, .primary(autoReplace: false))
        let best = engine.suggestions[1]
        engine.acceptSuggestion(best)
        XCTAssertEqual(target.text, "i am " + best.replacement + " ")
        XCTAssertTrue(ac.learning.model.lexicon.counts.isEmpty)
        XCTAssertEqual(ac.learning.diagnostics.acceptedLabels, 0)
        // Accepting a prediction chains into the next prediction for the new last word.
        await engine.waitForSuggestions()
        XCTAssertEqual(engine.suggestions.count, 3)
        XCTAssertNotEqual(engine.suggestions.map(\.replacement), KeyboardContextModel.stripOrder(ranking).map(\.display))
        // Typing a letter replaces predictions with the current word's chips.
        let key = try XCTUnwrap(engine.layout.key(.character("t"))).frame
        engine.touchBegan(id: 1, at: CGPoint(x: key.midX, y: key.midY))
        engine.touchEnded(id: 1, at: CGPoint(x: key.midX, y: key.midY))
        XCTAssertEqual(engine.suggestions.first?.kind, .keepLiteral)
        await engine.waitForSuggestions()
        XCTAssertEqual(engine.suggestions.first?.kind, .keepLiteral)
        // Space after the typed word predicts its followers again.
        let space = try XCTUnwrap(engine.layout.key(.space)).frame
        engine.touchBegan(id: 2, at: CGPoint(x: space.midX, y: space.midY))
        engine.touchEnded(id: 2, at: CGPoint(x: space.midX, y: space.midY))
        await engine.waitForSuggestions()
        XCTAssertTrue(target.text.hasSuffix(" "))
        XCTAssertEqual(engine.suggestions.count, 3)
        // A missing selected pack abstains in the engine instead of using the other language.
        let english = try XCTUnwrap(KeyboardContextModel(de: nil, en: model.en))
        let partial = AutocorrectEngine(checker: Checker(valid: [], guesses: []), spatialDecoder: nil,
                                        contextResources: .init(model: english))
        partial.german = GermanAutocorrect(checker: Checker(valid: [], guesses: []))
        let other = FullKeyboardEngine(target: FixtureTextTarget(text: "ich bin "), autocorrect: partial)
        other.width = 393
        other.configureForField()
        await other.waitForSuggestions()
        XCTAssertTrue(other.suggestions.isEmpty)
        partial.german = nil
        XCTAssertEqual(partial.suggestions(beforeInput: "ich bin ", field: .text, autocorrectionType: .default).count, 3)
        ac.isEnabled = false
        XCTAssertTrue(ac.suggestions(beforeInput: "i am ", field: .text, autocorrectionType: .default).isEmpty)
        ac.isEnabled = true; ac.englishEnabled = false
        XCTAssertTrue(ac.suggestions(beforeInput: "i am ", field: .text, autocorrectionType: .default).isEmpty)
        ac.englishEnabled = true
        for text: String? in [nil, "", "123 ", "https://example.com "] {
            XCTAssertTrue(ac.suggestions(beforeInput: text, field: .text, autocorrectionType: .default).isEmpty)
        }
        XCTAssertTrue(ac.suggestions(beforeInput: "i am ", field: .url, autocorrectionType: .default).isEmpty)
        XCTAssertTrue(ac.suggestions(beforeInput: "i am ", field: .text, autocorrectionType: .no).isEmpty)
    }

    @MainActor
    func testPredictionOwnershipRejectsChangedContextLanguageAndField() async throws {
        let model = try XCTUnwrap(BundledKeyboardData.contextModel)
        let ac = AutocorrectEngine(checker: Checker(valid: [], guesses: []), spatialDecoder: nil,
                                   contextResources: .init(model: model))
        let target = FixtureTextTarget(text: "i am ")
        let engine = FullKeyboardEngine(target: target, autocorrect: ac)
        engine.configureForField()
        await engine.waitForSuggestions()
        let old = try XCTUnwrap(engine.suggestions.first)
        // A host edit without textDidChange must not append a stale next word.
        target.insertText("going ")
        let edited = target.text
        engine.acceptSuggestion(old)
        XCTAssertEqual(target.text, edited)
        await engine.waitForSuggestions()
        let new = try XCTUnwrap(engine.suggestions.first)
        // Settings and field protection are rechecked even without a UI refresh.
        ac.englishEnabled = false
        engine.acceptSuggestion(new)
        XCTAssertEqual(target.text, edited)
        await engine.waitForSuggestions()
        XCTAssertTrue(engine.suggestions.isEmpty)
        ac.englishEnabled = true
        engine.refreshSuggestions()
        await engine.waitForSuggestions()
        let prose = try XCTUnwrap(engine.suggestions.first)
        target.keyboardType = .URL
        engine.acceptSuggestion(prose)
        XCTAssertEqual(target.text, edited)
        await engine.waitForSuggestions()
        XCTAssertTrue(engine.suggestions.isEmpty)
        XCTAssertTrue(ac.learning.model.lexicon.counts.isEmpty)
        XCTAssertEqual(ac.learning.diagnostics.acceptedLabels, 0)
    }

    @MainActor
    func testNoContextKeepsOriginalCheckerWork() throws {
        let model = try XCTUnwrap(BundledKeyboardData.contextModel)
        let checker = Checker(valid: [], guesses: ["glaube", "bin", "habe"])
        let ac = AutocorrectEngine(checker: checker, spatialDecoder: nil, contextResources: .init(model: model))
        for text in ["ha", "123 ha"] {
            _ = ac.suggestions(beforeInput: text, field: .text, autocorrectionType: .default)
        }
        XCTAssertEqual(checker.completionCalls, 0)
        _ = ac.suggestions(beforeInput: "ich ha", field: .text, autocorrectionType: .default)
        XCTAssertEqual(checker.completionCalls, 1)
        ac.isEnabled = false
        _ = ac.suggestions(beforeInput: "ich ha", field: .text, autocorrectionType: .default)
        XCTAssertEqual(checker.completionCalls, 1)
    }

    @MainActor
    func testDetachedResourcePreparationAndReadinessCallback() async throws {
        let resources = KeyboardContextResources(bundle: Bundle.main)
        XCTAssertNil(resources.model)
        let start = ContinuousClock.now
        await withCheckedContinuation { continuation in
            resources.prepare { continuation.resume() }
        }
        XCTAssertEqual(resources.model?.residentPayloadBytes, 802_630)
        let elapsed = start.duration(to: .now).components
        let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        print(String(format: "EVAL context_prepare elapsed_ms=%.3f payload_bytes=802630 mapping=if_safe timing=%@", milliseconds, Self.timingPlatform))
    }

    @MainActor private final class Checker: TextChecking {
        let valid: Set<String>
        let answers: [String]
        private(set) var completionCalls = 0
        init(valid: Set<String>, guesses: [String]) { self.valid = valid; answers = guesses }
        func isWordValid(_ word: String) -> Bool { valid.contains(word) }
        func guesses(for word: String) -> [String] { answers }
        func completions(for prefix: String) -> [String] { completionCalls += 1; return [] }
    }
}
