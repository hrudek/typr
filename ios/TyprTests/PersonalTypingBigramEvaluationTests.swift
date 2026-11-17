import Foundation
import XCTest
@testable import Typr

/// P4 evaluations. Personal phrases are Typr-authored synthetic pairs (never private text);
/// the no-harm check uses the bundled public CC0 held-out sentences. Training goes through
/// the real keyboard settlement path with synthetic key-centre taps. Validity is an injected
/// checker, not Apple's dictionary. Work counts are asserted; timings are EVAL output only.
@MainActor
final class PersonalTypingBigramEvaluationTests: XCTestCase {
    private final class Checker: TextChecking {
        var valid: Set<String>
        init(_ valid: Set<String>) { self.valid = valid }
        func isWordValid(_ word: String) -> Bool { valid.contains(word) || valid.contains(word.lowercased()) }
        func guesses(for word: String) -> [String] { [] }
        func completions(for prefix: String) -> [String] { [] }
    }

    /// Repeated personal phrases whose follower the public corpus rarely predicts.
    static let fixtures: [(name: String, pairs: [(String, String)])] = [
        ("de", [("meine", "tastatur"), ("heute", "mittag"), ("kurzes", "update"), ("unser", "standup"),
                ("bitte", "review"), ("neue", "version"), ("kleine", "korrektur"), ("lieber", "kollege"),
                ("guten", "appetit"), ("frohe", "weihnachten")]),
        ("en", [("daily", "standup"), ("project", "update"), ("morning", "coffee"), ("pull", "request"),
                ("code", "review"), ("release", "notes"), ("unit", "tests"), ("happy", "birthday"),
                ("thanks", "team"), ("see", "you")]),
        ("mixed", [("meine", "pipeline"), ("das", "deployment"), ("kurzes", "meeting"), ("the", "tastatur"),
                   ("my", "kollege"), ("neue", "feature"), ("daily", "besprechung"), ("unser", "backlog"),
                   ("final", "version"), ("bitte", "merge")])
    ]
    private static var allWords: Set<String> { Set(fixtures.flatMap { $0.pairs.flatMap { [$0.0, $0.1] } }) }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let c = start.duration(to: .now).components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }
    private static func summary(_ values: [Double]) -> String {
        let sorted = values.sorted()
        guard let last = sorted.last else { return "calls=0" }
        return String(format: "calls=%d meanMs=%.4f p95Ms=%.4f maxMs=%.4f", sorted.count,
                      sorted.reduce(0, +) / Double(sorted.count), sorted[Int(Double(sorted.count - 1) * 0.95)], last)
    }
    private static var timing: String {
        #if os(Linux)
        "Linux_XCTest_debug_not_iPhone"
        #else
        "Apple_XCTest_not_iPhone"
        #endif
    }

    /// Types one phrase with key-centre taps through `FullKeyboardEngine`, then one letter that
    /// settles the follower. Only the existing trusted-literal protocol can teach the pair.
    private func typePhrase(_ previous: String, _ follower: String, session: KeyboardLearningSession) {
        let target = FixtureTextTarget()
        target.autocapitalizationType = .some(.none)
        let ac = AutocorrectEngine(checker: Checker(Self.allWords), learning: session, spatialDecoder: nil,
                                   contextResources: .init(model: nil))
        let engine = FullKeyboardEngine(target: target, autocorrect: ac)
        engine.width = 393
        engine.clock = { 100 }
        engine.configureForField()
        for ch in previous + " " + follower + " n" {
            guard let key = engine.layout.key(ch == " " ? .space : .character(String(ch))) else {
                XCTFail("No key for \(ch)"); return
            }
            let p = CGPoint(x: key.frame.midX, y: key.frame.midY)
            engine.touchBegan(id: 1, at: p); engine.touchEnded(id: 1, at: p)
        }
    }

    private func rank(_ word: String, after previous: String, model: KeyboardContextModel, name: String,
                      personal: PersonalBigramModel) -> Int? {
        let context = model.context(before: previous + " ", currentToken: nil)
        return model.suggestions(after: context.previous, weightDE: context.state.weightDE,
                                 german: name != "en", english: name != "de", personal: personal)
            .firstIndex { $0.key == word }
    }

    /// Recall@1/@3 and MRR@3 of the personal follower after 0, 1, 2, 4 and 8 typed repetitions.
    func testPersonalNextWordRecallGrowsWithRepeatedTrustedSessions() throws {
        let model = try XCTUnwrap(BundledKeyboardData.contextModel)
        var times: [Double] = []
        for (name, fixtures) in Self.fixtures {
            let pairs = fixtures.enumerated().filter { EvaluationSample.includes($0.offset, every: 2) }.map(\.element)
            let session = KeyboardLearningSession()
            var typed = 0, previousRecall3 = -1
            var line = "EVAL P4_learning_\(name) pairs=\(pairs.count)"
            for repetitions in [0, 1, 2, 4, 8] {
                while typed < repetitions {
                    for (h, w) in pairs { typePhrase(h, w, session: session) }
                    typed += 1
                }
                var hit1 = 0, hit3 = 0, rr = 0.0
                for (h, w) in pairs {
                    XCTAssertEqual(session.personalBigrams.followers(after: h)[w] ?? 0, repetitions, "\(name) \(h) \(w)")
                    let start = ContinuousClock.now
                    let r = rank(w, after: h, model: model, name: name, personal: session.personalBigrams)
                    times.append(Self.milliseconds(since: start))
                    if let r { hit3 += 1; rr += 1 / Double(r + 1); if r == 0 { hit1 += 1 } }
                }
                line += String(format: " n%d_recall1=%d n%d_recall3=%d n%d_mrr3=%.3f", repetitions, hit1, repetitions, hit3, repetitions, rr / Double(pairs.count))
                XCTAssertGreaterThanOrEqual(hit3, previousRecall3, "\(name): more trusted repetitions never lower recall")
                previousRecall3 = hit3
                if repetitions >= 2 { XCTAssertEqual(hit3, pairs.count, "\(name) after \(repetitions)") }
                if repetitions >= 4 { XCTAssertEqual(hit1, pairs.count, "\(name) after \(repetitions)") }
            }
            XCTAssertEqual(session.personalBigrams.pairCount, pairs.count, "Exactly the typed adjacent pairs")
            print(line + " training=engine_key_centre_taps")
        }
        print("EVAL P4_prediction_cost \(Self.summary(times)) timing=\(Self.timing) personalSeedsMax=8")
    }

    /// Public CC0 held-out sentences: corpus-only versus a bilingual user's trained personal layer.
    /// Shared contexts (e.g. `das`, `the`) can be overridden by design; the bound states the cost.
    func testHeldoutCorpusPredictionsStayCloseWithPersonalPairs() throws {
        let model = try XCTUnwrap(BundledKeyboardData.contextModel)
        let url = try XCTUnwrap(Bundle.main.url(forResource: "context-heldout-cc0", withExtension: "json", subdirectory: "WordData"))
        struct Fixture: Decodable { let sentences: [String: [[String]]] }
        let sentences = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).sentences
        var personal = PersonalBigramModel()
        for _ in 0..<8 { for (_, pairs) in Self.fixtures { for (h, w) in pairs { personal.record(w, after: h) } } }
        XCTAssertEqual(personal.pairCount, 30)
        for language in ["de", "en"] {
            var n = 0, base3 = 0, mine3 = 0, base1 = 0, mine1 = 0, changed = 0, affected = 0
            for words in try XCTUnwrap(sentences[language]) {
                var state = KeyboardContextModel.State()
                for i in 0..<(words.count - 1) {
                    let h = KeyboardContextModel.key(words[i]), w = KeyboardContextModel.key(words[i + 1])
                    state.consume(h, model: model)
                    let corpus = model.suggestions(after: h, weightDE: state.weightDE, german: language == "de", english: language == "en")
                    let mine = model.suggestions(after: h, weightDE: state.weightDE, german: language == "de", english: language == "en",
                                                 personal: personal)
                    if corpus.contains(where: { $0.key == w }) { base3 += 1 }
                    if mine.contains(where: { $0.key == w }) { mine3 += 1 }
                    if corpus.first?.key == w { base1 += 1 }
                    if mine.first?.key == w { mine1 += 1 }
                    if corpus.map(\.key) != mine.map(\.key) { changed += 1 }
                    if !personal.followers(after: h).isEmpty { affected += 1 }
                    n += 1
                }
            }
            print(String(format: "EVAL P4_heldout_noharm_%@ pairs=%d personalContexts=%d listsChanged=%d corpus_recall1=%.4f personal_recall1=%.4f corpus_recall3=%.4f personal_recall3=%.4f source=CC0_heldout",
                         language, n, affected, changed, Double(base1) / Double(n), Double(mine1) / Double(n),
                         Double(base3) / Double(n), Double(mine3) / Double(n)))
            XCTAssertLessThanOrEqual(changed, affected, "Only contexts with personal rows can change")
            XCTAssertGreaterThanOrEqual(Double(mine3) / Double(n), Double(base3) / Double(n) - 0.03, language)
        }
    }

    /// Noisy current-word typing after a personal context: prefixes (completion ranking) and
    /// full words (spatial alternatives). Variants: corpus-only, personal pairs, learning off
    /// with retained pairs. Automatic decisions must be identical in all three.
    func testNoisyTouchRankingWithPersonalPairsAndNoAddedAutomaticChanges() throws {
        let model = try XCTUnwrap(BundledKeyboardData.contextModel)
        let lexicons = try XCTUnwrap(BundledKeyboardData.lexicons)
        let decoder = SpatialWordDecoder(lexicons: lexicons)
        let grid = KeyboardLayout(width: 393, orientation: .portrait, layer: .letters, field: .text, showsGlobe: false, showsStrip: true)
        let controls = ["Lena", "Donaudampfschiff", "WeChat", "camelCase", "meeting", "tasche", "mittwoch", "updated",
                        "reviewer", "standard", "tastaturen", "kollegen"]
        let checker = Checker(Self.allWords.union(controls))
        func engine(_ variant: Int, name: String, pairs: [(String, String)]) -> AutocorrectEngine {
            let defaults = UserDefaults(suiteName: "p4.eval.\(UUID().uuidString)")!
            let session = KeyboardLearningSession(defaults: defaults)
            if variant > 0 { for _ in 0..<6 { for (h, w) in pairs { session.model.recordPair(w, after: h) } } }
            if variant == 2 { defaults.set(false, forKey: "keyboard.personalLearning"); session.refresh() }
            let ac = AutocorrectEngine(checker: checker, learning: session, spatialDecoder: decoder, contextResources: .init(model: model))
            ac.englishEnabled = name != "de"
            if name != "en" { ac.german = GermanAutocorrect(checker: checker) }
            return ac
        }
        var times: [Double] = [], ordinal = 0
        for (name, pairs) in Self.fixtures {
            let engines = (0...2).map { engine($0, name: name, pairs: pairs) }
            var top1 = [0, 0, 0], top3 = [0, 0, 0], n = 0, changedAuto = 0, offDiffers = 0, wins = 0, losses = 0
            let sampled = pairs.enumerated().filter { EvaluationSample.includes($0.offset, every: 2) }.map(\.element)
            for (h, w) in sampled {
                // Prefix of ≥3 letters (clean and one neighbour slip) and the full word (one/two slips).
                let prefix = String(w.prefix(max(3, w.count / 2)))
                let cases: [(String, SpatialTypoEvaluationEvidence.ErrorClass?)] = [
                    (prefix, nil), (prefix, .neighbour1), (w, .neighbour1), (w, .neighbour2)]
                for (typedWord, error) in cases {
                    ordinal += 1
                    let evidence = try SpatialTypoEvaluationEvidence.evidence(typedWord, grid: grid, error: error, ordinal: ordinal,
                                                                            seed: 0x5034, sigma: 0.18)
                    var strips: [[String]] = [], autos: [String?] = []
                    for (variant, ac) in engines.enumerated() {
                        ac.discardEvidence()
                        var before = h + " "
                        for sample in evidence.samples {
                            let after = before + sample.text
                            ac.touchInput.append(text: sample.text, point: sample.point, key: sample.key, layout: grid, before: before, after: after)
                            before = after
                        }
                        let start = ContinuousClock.now
                        let chips = ac.suggestions(beforeInput: before, field: .text, autocorrectionType: .default)
                        if variant == 1 { times.append(Self.milliseconds(since: start)) }
                        let keys = chips.filter { $0.kind != .keepLiteral }.map { KeyboardContextModel.key($0.replacement) }
                        strips.append(keys)
                        if keys.first == w { top1[variant] += 1 }
                        if keys.prefix(3).contains(w) { top3[variant] += 1 }
                        autos.append(ac.replacementOnSpace(beforeInput: before, field: .text, autocorrectionType: .default)?.replacement)
                    }
                    n += 1
                    if Set(autos.map { $0 ?? "" }).count != 1 { changedAuto += 1 }
                    if strips[2] != strips[0] { offDiffers += 1 }
                    if (strips[0].first == w) != (strips[1].first == w) { if strips[1].first == w { wins += 1 } else { losses += 1 } }
                }
            }
            // Clean valid words, names, compounds and code-switches typed after a personal context
            // whose learned follower is a different word: never an automatic change.
            var unwanted = 0
            for (h, _) in sampled {
                for literal in controls {
                    for ac in engines {
                        ac.discardEvidence()
                        if ac.replacementOnSpace(beforeInput: h + " " + literal, field: .text, autocorrectionType: .default) != nil { unwanted += 1 }
                    }
                }
            }
            print("EVAL P4_noisy_\(name) cases=\(n) corpus_recall1=\(top1[0]) personal_recall1=\(top1[1]) off_recall1=\(top1[2]) corpus_recall3=\(top3[0]) personal_recall3=\(top3[1]) off_recall3=\(top3[2]) first_slot_wins=\(wins) first_slot_losses=\(losses) changed_auto=\(changedAuto) off_strips_differ=\(offDiffers) controls=\(controls.count * sampled.count * 3) unwanted_auto=\(unwanted) validity=injected_not_Apple")
            XCTAssertEqual(changedAuto, 0, name)
            XCTAssertEqual(offDiffers, 0, "\(name): learning off equals no personal data")
            XCTAssertEqual(unwanted, 0, name)
            XCTAssertGreaterThanOrEqual(top3[1], top3[0], name)
            XCTAssertGreaterThan(top1[1], top1[0], name)
            XCTAssertEqual(n, sampled.count * 4)
        }
        print("EVAL P4_noisy_cost \(Self.summary(times)) timing=\(Self.timing)")
    }

    /// Deterministic event-count ageing: unused pairs fade under unrelated traffic, a phrase
    /// still in use survives, and the caps hold throughout.
    func testAgeingForgetsUnusedPairsAndKeepsUsedOnes() throws {
        let model = try XCTUnwrap(BundledKeyboardData.contextModel)
        let pairs = try XCTUnwrap(Self.fixtures.first { $0.name == "de" }).pairs
        var personal = PersonalBigramModel()
        for _ in 0..<8 { for (h, w) in pairs { personal.record(w, after: h) } }
        var line = "EVAL P4_ageing pairs=\(pairs.count) startCount=8"
        var events = 0
        func noise(_ i: Int) -> (String, String) {
            func word(_ n: Int) -> String {
                var value = n, s = "q"
                repeat { s.append(Character(UnicodeScalar(97 + value % 26)!)); value /= 26 } while value > 0
                return s
            }
            return (word(10_000 + i % 997), word(i % 389))
        }
        var replay = PersonalBigramModel()
        for checkpoint in [256, 512, 1024, 2048] {
            while events < checkpoint {
                let (h, w) = noise(events)
                personal.record(w, after: h)
                // One phrase stays in use every 32 events.
                if events % 32 == 0 { personal.record("tastatur", after: "meine") }
                events += 1
                XCTAssertLessThanOrEqual(personal.pairCount, PersonalBigramModel.pairLimit)
                XCTAssertLessThanOrEqual(personal.encodedByteBound, PersonalBigramModel.maximumBytes)
            }
            let retained = pairs.filter { personal.followers(after: $0.0)[$0.1] != nil }.count
            let recall3 = pairs.filter { (h, w) in
                rank(w, after: h, model: model, name: "de", personal: personal).map { $0 < 3 } ?? false }.count
            line += " after\(checkpoint)_retained=\(retained) after\(checkpoint)_recall3=\(recall3)"
        }
        XCTAssertNotNil(personal.followers(after: "meine")["tastatur"], "A phrase in use survives ageing")
        XCTAssertEqual(pairs.filter { $0.0 != "meine" && personal.followers(after: $0.0)[$0.1] != nil }.count, 0,
                       "Unused pairs fade completely")
        // Replaying the identical event sequence reproduces the identical state.
        for _ in 0..<8 { for (h, w) in pairs { replay.record(w, after: h) } }
        for i in 0..<2048 {
            let (h, w) = noise(i)
            replay.record(w, after: h)
            if i % 32 == 0 { replay.record("tastatur", after: "meine") }
        }
        XCTAssertEqual(replay, personal)
        print(line + " events=\(events) finalPairs=\(personal.pairCount) deterministic=1")
    }
}
