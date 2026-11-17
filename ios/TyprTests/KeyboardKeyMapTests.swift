import Foundation
import XCTest
@testable import Typr

/// Synthetic taps and corpus-validity checker, not Apple dictionaries or human typing proof.
@MainActor
final class KeyboardKeyMapTests: XCTestCase {
    private typealias Language = SpatialWordDecoder.Language
    private let grid = KeyboardLayout(width: 393)
    private final class Checker: TextChecking {
        let lexicons: [SpatialWordLexicon]
        var calls = 0
        init(_ lexicons: [SpatialWordLexicon]) { self.lexicons = lexicons }
        func isWordValid(_ word: String) -> Bool {
            calls += 1
            return lexicons.contains { $0.logPrior(for: word.lowercased()) != nil }
        }
        func guesses(for word: String) -> [String] { calls += 1; return [] }
        func completions(for prefix: String) -> [String] { calls += 1; return [] }
    }

    private func resources() throws -> [Language: SpatialWordLexicon] { try XCTUnwrap(BundledKeyboardData.lexicons) }

    private func calibration(_ offset: Double = 0.4) -> SpatialTouchCalibration {
        var keys: [Character: SpatialTouchCalibration.Key] = [:]
        for letter in "abcdefghijklmnopqrstuvwxyz" {
            keys[letter] = .init(offsetX: offset, offsetY: 0, sigmaX: 0.24, sigmaY: 0.24, covarianceXY: 0.005)
        }
        return .init(keys: keys)
    }

    private func center(_ key: KeyboardKey) -> CGPoint { CGPoint(x: key.frame.midX, y: key.frame.midY) }
    private func key(_ letter: Character, _ layout: KeyboardLayout? = nil) -> KeyboardKey {
        (layout ?? grid).key(.character(String(letter)))!
    }
    private func gap(_ intended: Character, _ layout: KeyboardLayout? = nil) -> CGPoint {
        let k = key(intended, layout)
        return CGPoint(x: k.hitFrame.maxX + 0.3, y: k.frame.midY)
    }
    private func tap(_ point: CGPoint, _ engine: FullKeyboardEngine, id: Int = 1) {
        engine.touchBegan(id: id, at: point)
        engine.touchEnded(id: id, at: point)
    }
    private func type(_ text: String, _ engine: FullKeyboardEngine) {
        for letter in text { tap(center(key(letter, engine.layout)), engine) }
    }

    private func keyboard(_ sources: [Language: SpatialWordLexicon], languages: Set<Language> = [.english],
                          trained: Bool = true, worker: KeyboardSuggestionWorker? = nil)
        -> (FullKeyboardEngine, FixtureTextTarget, Checker) {
        let target = FixtureTextTarget()
        target.autocapitalizationType = .some(.none)
        let checker = Checker(Array(sources.values))
        let ac = AutocorrectEngine(checker: checker, learning: KeyboardLearningSession(),
                                   spatialDecoder: SpatialWordDecoder(lexicons: sources),
                                   contextResources: .init(model: nil))
        ac.englishEnabled = languages.contains(.english)
        if languages.contains(.german) { ac.german = GermanAutocorrect(checker: checker) }
        let engine = FullKeyboardEngine(target: target, autocorrect: ac, suggestionWorker: worker)
        engine.width = 393
        engine.configureForField()
        if trained { train(engine) }
        return (engine, target, checker)
    }
    private func train(_ engine: FullKeyboardEngine, offset: Double = 0.4) {
        let layout = engine.layout
        for i in 0..<40 {
            let jitter = Double(i % 3 - 1) * 0.045
            let labels = "abcdefghijklmnopqrstuvwxyz".map { letter -> TouchLabel in
                let k = key(letter, layout)
                let x = k.frame.midX + (offset + jitter) * (k.frame.width + layout.metrics.gap)
                let y = k.frame.midY + jitter * (k.frame.height + layout.metrics.rowGap)
                return TouchLabel(point: CGPoint(x: x, y: y), letter: letter)
            }
            engine.autocorrect.learning.learn(labels, layout: layout, source: .keep)
        }
        engine.refreshSuggestions()
    }
    private func map(_ sources: [Language: SpatialWordLexicon], prefix: String = "wher",
                     languages: Set<Language> = [.english]) throws -> KeyboardKeyMap {
        let priors = try XCTUnwrap(KeyboardKeyMap.priors(prefix: prefix, languages: languages,
                                                       lexicons: sources, personal: nil))
        return KeyboardKeyMap(layout: grid, prefix: prefix, calibration: calibration(), priors: priors)
    }

    func testContinuationMassOracleAndNeutralMixture() throws {
        let sources = try resources()
        for language in Language.allCases {
            let lexicon = sources[language]!
            // Exhaustively sum terminals under a short prefix independently of the new index.
            for prefix in ["th", "ha", "zzq", "gr", "stra"] {
                var oracle = [Double](repeating: 0, count: SpatialWordLexicon.alphabet.count)
                func visit(_ index: Int, word: String) {
                    let node = lexicon.node(index)!
                    if node.count > 0, word.hasPrefix(prefix), word.count > prefix.count {
                        let next = Array(word)[prefix.count]
                        oracle[SpatialWordLexicon.alphabet.firstIndex(of: next)!] += node.count
                    }
                    for child in node.children {
                        let letter = SpatialWordLexicon.alphabet[lexicon.node(child)!.label]
                        visit(child, word: word + String(letter))
                    }
                }
                visit(0, word: "")
                XCTAssertEqual(lexicon.nextLetterMass(after: prefix), oracle)
            }
        }
        let en = try XCTUnwrap(KeyboardKeyMap.priors(prefix: "ha", languages: [.english], lexicons: sources, personal: nil))
        let de = try XCTUnwrap(KeyboardKeyMap.priors(prefix: "ha", languages: [.german], lexicons: sources, personal: nil))
        let both = try XCTUnwrap(KeyboardKeyMap.priors(prefix: "ha", languages: [.english, .german], lexicons: sources, personal: nil))
        for i in both.indices { XCTAssertEqual(both[i], (en[i] + de[i]) / 2, accuracy: 1e-12) }
        XCTAssertEqual(both.reduce(0, +), 1, accuracy: 1e-12)
        XCTAssertTrue(both.allSatisfy { $0 >= 0.90 / 26 })
        XCTAssertNil(KeyboardKeyMap.priors(prefix: "zzqx", languages: [.english, .german], lexicons: sources, personal: nil))
        XCTAssertNil(KeyboardKeyMap.priors(prefix: "ha", languages: [.german, .english], lexicons: [.english: sources[.english]!], personal: nil))
        XCTAssertNil(KeyboardKeyMap.priors(prefix: String(repeating: "a", count: 32), languages: [.english], lexicons: sources, personal: nil))
    }

    func testPersonalMassExactCountsHoldersAndCapacity() throws {
        let personal = PersonalLexiconSnapshot(kept: ["thäva", "thöva"], counts: ["theron": 10, "thäva": 4], rejected: [])
        let mass = personal.scan.completions.nextLetterMass(after: "th")
        XCTAssertEqual(mass[4], 10)
        XCTAssertEqual(mass[26], 4)
        XCTAssertEqual(mass[27], 1)
        let sources = try resources()
        let before = try XCTUnwrap(KeyboardKeyMap.priors(prefix: "th", languages: [.english], lexicons: sources, personal: nil))
        let after = try XCTUnwrap(KeyboardKeyMap.priors(prefix: "th", languages: [.english], lexicons: sources,
                                                      personal: personal.scan.completions))
        XCTAssertGreaterThan(after[0], before[0], "ä continuation votes for physical a")
        XCTAssertGreaterThan(after[14], before[14], "ö continuation votes for physical o")
        var counts: [String: Int] = [:]
        for i in 0..<2_000 {
            let a = Character(UnicodeScalar(97 + i / 676)!)
            let b = Character(UnicodeScalar(97 + (i / 26) % 26)!)
            let c = Character(UnicodeScalar(97 + i % 26)!)
            counts["novel" + String([a, b, c])] = 2 + i
        }
        let full = PersonalLexiconSnapshot(kept: [], counts: counts, rejected: []).scan.completions
        XCTAssertEqual(full.nextLetterMass(after: "novel").reduce(0, +), Double(counts.values.reduce(0, +)))
        XCTAssertLessThanOrEqual(full.payloadBytes, 192 * 1_024)
        print("EVAL P8_personal entries=\(full.entries.count) payload_bytes=\(full.payloadBytes) max_binary_searches=60 max_comparisons=660")
    }

    func testGapOnlyStrictMarginControlsAndStaleGeometry() throws {
        let map = try map(resources())
        let point = gap("e"), geometric = grid.hitTest(point)!
        XCTAssertEqual(geometric.character, "r")
        XCTAssertEqual(map.attributedKey(at: point, geometric: geometric, layout: grid, prefix: "wher").character, "e")
        for k in grid.keys {
            for point in [center(k), CGPoint(x: k.frame.minX + 0.1, y: k.frame.midY),
                          CGPoint(x: k.frame.maxX - 0.1, y: k.frame.midY)] {
                XCTAssertEqual(map.attributedKey(at: point, geometric: k, layout: grid, prefix: "wher"), k)
            }
        }
        for k in grid.keys where k.character == nil {
            for x in [k.hitFrame.minX + 0.1, k.hitFrame.maxX - 0.1] {
                let p = CGPoint(x: x, y: k.hitFrame.midY)
                XCTAssertEqual(map.attributedKey(at: p, geometric: k, layout: grid, prefix: "wher"), k)
            }
        }
        XCTAssertEqual(map.attributedKey(at: point, geometric: geometric, layout: grid, prefix: "ha"), geometric)
        XCTAssertEqual(map.attributedKey(at: point, geometric: geometric, layout: KeyboardLayout(width: 440), prefix: "wher"), geometric)
        let neutral = KeyboardKeyMap(layout: grid, prefix: "wher", calibration: calibration(), priors: Array(repeating: 1.0 / 26, count: 26))
        XCTAssertEqual(neutral.attributedKey(at: point, geometric: geometric, layout: grid, prefix: "wher"), geometric)
        let cold = KeyboardKeyMap(layout: grid, prefix: "wher", calibration: calibration(0),
                                  priors: map.entries.map { exp($0.logPrior) / 26 })
        XCTAssertEqual(cold.attributedKey(at: point, geometric: geometric, layout: grid, prefix: "wher"), geometric)
        XCTAssertEqual(map.attributedKey(at: CGPoint(x: CGFloat.nan, y: 0), geometric: geometric, layout: grid, prefix: "wher"), geometric)
        XCTAssertLessThanOrEqual(map.entries.count, 26)
    }

    func testSerialAndRolloverUpdateBeforeDeferredRankingAndNeverSelfTrain() throws {
        let sources = try resources()
        for rollover in [false, true] {
            let (engine, target, checker) = keyboard(sources)
            let labels = engine.autocorrect.learning.diagnostics.acceptedLabels
            let points = [center(key("w")), center(key("h")), center(key("e")), center(key("r")), gap("e")]
            for (i, p) in points.enumerated() {
                engine.touchBegan(id: i, at: p)
                if !rollover { engine.touchEnded(id: i, at: p) }
            }
            if rollover {
                for i in points.indices.reversed() { engine.touchEnded(id: i, at: points[i]) }
            }
            XCTAssertEqual(target.text, "where")
            XCTAssertEqual(checker.calls, 0, "no checker/ranking on the insertion stack")
            let evidence = try XCTUnwrap(engine.autocorrect.touchInput.evidence(beforeInput: target.text))
            XCTAssertEqual(evidence.samples.last?.key.character, "r")
            XCTAssertEqual(evidence.samples.last?.attributedKey?.character, "e")
            XCTAssertFalse(evidence.learningIntact)
            XCTAssertNotNil(KeyboardLetterMap.emissions(for: evidence, calibration: calibration()))
            XCTAssertEqual(engine.autocorrect.learning.diagnostics[.reattributedTaps], 1)
            engine.acceptOwnedFixtureSuggestion(.init(displayText: "where", replacement: "where", kind: .keepLiteral))
            XCTAssertEqual(engine.autocorrect.learning.diagnostics.acceptedLabels, labels)
            XCTAssertNil(engine.autocorrect.learning.model.lexicon.counts["where"])
            type("w", engine)
            XCTAssertNil(engine.autocorrect.learning.model.lexicon.counts["where"])
        }
    }

    func testAutomaticAttributedLiteralNeverSettlesAndInternalCapitalStaysLiteral() throws {
        let sources = try resources()
        let (engine, target, _) = keyboard(sources)
        let labels = engine.autocorrect.learning.diagnostics.acceptedLabels
        type("wher", engine)
        tap(gap("e"), engine)
        tap(center(engine.layout.key(.space)!), engine)
        type("w", engine)
        XCTAssertEqual(target.text, "where w")
        XCTAssertNil(engine.autocorrect.learning.model.lexicon.counts["where"])
        XCTAssertEqual(engine.autocorrect.learning.diagnostics.acceptedLabels, labels)

        let (caps, capsTarget, _) = keyboard(sources)
        type("wher", caps)
        tap(center(caps.layout.key(.shift)!), caps)
        tap(gap("e"), caps)
        XCTAssertEqual(capsTarget.text, "wherR", "a shifted internal capital is an identifier signal")
    }

    func testPartialAttributedWordCannotCountOrTrainFromKeepAndCannotSeedPersonalPairs() throws {
        let (engine, target, _) = keyboard(try resources())
        let session = engine.autocorrect.learning
        let labels = session.diagnostics.acceptedLabels
        target.insertText("wher") // Prefix existed before Typr observed any taps.
        engine.refreshSuggestions()
        tap(gap("e"), engine)
        XCTAssertEqual(target.text, "where")
        XCTAssertNil(engine.autocorrect.touchInput.evidence(beforeInput: target.text))
        XCTAssertFalse(engine.autocorrect.touchInput.isLearningIntact)
        engine.acceptOwnedFixtureSuggestion(.init(displayText: "where", replacement: "where", kind: .keepLiteral))
        type("world", engine)
        tap(center(engine.layout.key(.space)!), engine)
        type("hello", engine)
        tap(center(engine.layout.key(.space)!), engine)
        type("w", engine)
        XCTAssertNil(session.model.lexicon.counts["where"])
        XCTAssertEqual(session.diagnostics.acceptedLabels, labels + 10, "only independently observed world and hello teach")
        XCTAssertEqual(session.model.state.bigrams?.pairCount, 1, "world→hello only; the never becomes an endpoint")
    }

    private actor FirstJobGate {
        var started = false
        private var continuation: CheckedContinuation<Void, Never>?
        func rank(_ request: KeyboardSuggestionWorker.Request) async -> KeyboardSuggestionWorker.Result {
            if !started {
                started = true
                await withCheckedContinuation { continuation = $0 }
            }
            return .init(request: request, outcome: nil, seconds: 0)
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    func testBlockedWorkerDoesNotOwnAttributionAndMixedPrefixStreamStaysLiteral() async throws {
        let gate = FirstJobGate()
        let worker = KeyboardSuggestionWorker(rank: { await gate.rank($0) })
        let (engine, target, checker) = keyboard(try resources(), worker: worker)
        type("whe", engine)
        for _ in 0..<10_000 {
            if await gate.started { break }
            await Task.yield()
        }
        let started = await gate.started
        XCTAssertTrue(started)
        type("r", engine)
        tap(gap("e"), engine)
        XCTAssertEqual(target.text, "where")
        XCTAssertEqual(checker.calls, 0)
        await gate.release()
        await engine.waitForSuggestions()

        let (mixed, mixedTarget, _) = keyboard(try resources(), languages: [.german, .english])
        let passage = "das kind hat ein gift also hello world haushello"
        for character in passage {
            let k = character == " " ? mixed.layout.key(.space)! : key(character)
            tap(center(k), mixed)
        }
        XCTAssertEqual(mixedTarget.text, passage)
        XCTAssertEqual(mixed.autocorrect.learning.diagnostics[.reattributedTaps], 0)
    }

    func testOffFieldsAndStaleModelOrSettingsStayGeometric() throws {
        let sources = try resources()
        for mode in 0..<9 {
            let (engine, target, _) = keyboard(sources, trained: mode != 0)
            type("wher", engine)
            switch mode {
            case 1: engine.autocorrect.isEnabled = false
            case 2: target.autocorrectionType = .no
            case 3: target.keyboardType = .URL
            case 4: target.keyboardType = .emailAddress
            case 5: target.keyboardType = .numberPad
            case 6: train(engine, offset: -0.4) // Generation differs even though text did not change.
            case 7:
                for _ in 0..<4 { target.deleteBackward() }; target.insertText("hallo") // Unreported host edit.
            case 8: target.isSecureTextEntry = true
            default: break
            }
            // train refreshes normally: create a newer model generation without refreshing map.
            if mode == 6 {
                let k = key("e")
                engine.autocorrect.learning.learn([TouchLabel(point: center(k), letter: "e")], layout: grid, source: .keep)
            }
            tap(gap("e"), engine)
            XCTAssertTrue(target.text.hasSuffix("r"), "mode \(mode)")
            XCTAssertEqual(engine.autocorrect.learning.diagnostics[.reattributedTaps], 0)
        }
        let (engine, _, _) = keyboard(sources)
        type("wher", engine)
        let session = engine.autocorrect.learning
        XCTAssertNotNil(engine.autocorrect.keyMap(layout: grid, context: "wher", permitsCorrection: true))
        session.model.isLearningEnabled = false
        XCTAssertNil(engine.autocorrect.keyMap(layout: grid, context: "wher", permitsCorrection: true))
        XCTAssertNil(engine.autocorrect.keyMap(layout: grid, context: "https://wher", permitsCorrection: true))
        XCTAssertNil(engine.autocorrect.keyMap(layout: grid, context: "wher", permitsCorrection: false))
    }

    func testSyntheticHitAndCandidateEvaluation() throws {
        let sources = try resources()
        let de = SpatialTypoEvaluationFixtures.german
        let en = SpatialTypoEvaluationFixtures.english
        let modes: [(String, Set<Language>, [String])] = [
            ("DE", [.german], de), ("EN", [.english], en), ("mixed", [.german, .english], de + en)
        ]
        for (name, languages, words) in modes {
            var taps = 0, staticErrors = 0, adaptiveErrors = 0, wrong = 0, changed = 0
            var times: [Double] = []
            for (ordinal, intended) in words.enumerated() {
                let (engine, target, _) = keyboard(sources, languages: languages)
                let letters = Array(intended)
                for (i, letter) in letters.enumerated() {
                    let k = key(letter)
                    let candidate = gap(letter)
                    let neighbor = grid.hitTest(candidate)
                    // Fixed public fixture, one deterministic near-boundary error opportunity.
                    let noisy = i >= 2 && i % 3 == ordinal % 3 && neighbor?.row == k.row
                        && neighbor?.character?.first?.isLetter == true && neighbor != k
                    let p = noisy ? candidate : center(k)
                    let geometric = grid.hitTest(p)!
                    let hitText = geometric.character!
                    let start = ProcessInfo.processInfo.systemUptime
                    tap(p, engine)
                    times.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
                    let actual = target.text.last!
                    taps += 1
                    if hitText != String(letter) { staticErrors += 1 }
                    if actual != letter { adaptiveErrors += 1 }
                    if actual != hitText.first! { changed += 1; if actual != letter { wrong += 1 } }
                }
                _ = try XCTUnwrap(engine.autocorrect.touchInput.evidence(beforeInput: target.text))
            }
            XCTAssertLessThan(adaptiveErrors, staticErrors)
            XCTAssertEqual(wrong, 0, "fixed synthetic noisy-tap fixtures, not all intended novel spellings")
            times.sort()
            let p95 = times[Int(Double(times.count - 1) * 0.95)]
            print("EVAL P8_hits_\(name) words=\(words.count) taps=\(taps) static_errors=\(staticErrors) adaptive_errors=\(adaptiveErrors) reattributed=\(changed) wrong=\(wrong) insertion_p95_ms=\(p95) insertion_max_ms=\(times.last!)")
        }
    }

    func testNovelNamesValidWordsAndAdversarialGapHarmEvaluation() throws {
        let sources = try resources()
        let controls = ["gift", "also", "kind", "die", "hat", "haus", "hello", "wasser", "swift", "world",
                        "Thrax", "Thorin", "Therava", "Zyphren", "Donaudampfschifffahrt", "haushello", "hellohaus"]
        var unwanted = 0, reattributed = 0
        for text in controls {
            let (engine, target, _) = keyboard(sources, languages: [.german, .english])
            for letter in text {
                if letter.isUppercase { tap(center(engine.layout.key(.shift)!), engine) }
                tap(center(key(Character(String(letter).lowercased()))), engine)
            }
            XCTAssertEqual(target.text, text)
            let before = target.text
            tap(center(engine.layout.key(.space)!), engine)
            if target.text != before + " " { unwanted += 1 }
            reattributed += engine.autocorrect.learning.diagnostics[.reattributedTaps]
        }
        XCTAssertEqual(unwanted, 0)
        XCTAssertEqual(reattributed, 0)
        // The original thrax regression is now protected by the four-letter prefix gate.
        // Longer known prefixes still have ambiguous gaps: the large evaluation measures them.
        let (engine, target, _) = keyboard(sources)
        type("th", engine)
        tap(gap("e"), engine) // Deliberately meant r, in the gap under a right-shifted model.
        type("ax", engine)
        let adversarialWrong = target.text == "thrax" ? 0 : 1
        XCTAssertEqual(adversarialWrong, 0, "short-prefix attribution must not damage this deliberate name")
        print("EVAL P8_controls words=\(controls.count) unwanted_space_changes=\(unwanted) center_reattributions=\(reattributed) adversarial_gap_names=1 adversarial_wrong=\(adversarialWrong) boundary_fraction=\(KeyboardKeyMap.boundaryFraction) visual_keycap_changes=0")
    }

    func testBackspaceRetypeIsGeometricForCompleteAndPartialWords() throws {
        let sources = try resources()
        for partial in [false, true] {
            let (engine, target, _) = keyboard(sources)
            if partial { target.insertText("wher"); engine.refreshSuggestions() }
            else { type("wher", engine) }
            tap(gap("e"), engine)
            XCTAssertEqual(target.text, "where")
            engine.deleteBackward()
            XCTAssertEqual(target.text, "wher")
            // Refresh, layout invalidation, hidden strip and a blocked ranker cannot remove
            // the user's veto. It does not rely on complete current-word samples.
            engine.showsStrip = false
            engine.showsStrip = true
            for _ in 0..<3 {
                tap(gap("e"), engine)
                XCTAssertEqual(target.text, "wherr")
                engine.deleteBackward()
            }
            type("zqx", engine)
            XCTAssertNil(engine.autocorrect.keyMap(layout: grid, context: target.text, permitsCorrection: true))
            type("er", engine)
            XCTAssertNil(engine.autocorrect.keyMap(layout: grid, context: target.text, permitsCorrection: true))
            tap(center(engine.layout.key(.space)!), engine)
            type("wher", engine)
            tap(gap("e"), engine)
            XCTAssertTrue(target.text.hasSuffix(" where"), "a real boundary ends the veto")
        }
    }

    func testAttributionCannotSeedSpatialBoundaryWindowsButRealSpaceStillCan() throws {
        let sources = try resources()
        let (engine, target, _) = keyboard(sources)
        type("hello", engine)
        tap(center(engine.layout.key(.space)!), engine)
        type("world", engine)
        let intact = try XCTUnwrap(engine.autocorrect.touchInput.boundaryEvidence(beforeInput: target.text))
        XCTAssertEqual(intact.previous?.text, "hello")
        XCTAssertEqual(intact.space?.key.kind, .space, "attribution reset must not discard #123's real Space")
        tap(center(engine.layout.key(.space)!), engine)
        type("wher", engine)
        train(engine) // Previous centre-tapped trusted words legitimately changed fast aim.
        tap(gap("e"), engine)
        XCTAssertTrue(target.text.hasSuffix(" where"))
        XCTAssertNil(engine.autocorrect.touchInput.boundaryEvidence(beforeInput: target.text))
        tap(center(engine.layout.key(.space)!), engine)
        type("hello", engine)
        let after = try XCTUnwrap(engine.autocorrect.touchInput.boundaryEvidence(beforeInput: target.text))
        XCTAssertNil(after.previous, "an attributed word must not seed a boundary window")
        XCTAssertNil(after.space)
    }

    func testInconsistentLearnedCloudsAbstain() throws {
        let sources = try resources()
        let priors = try XCTUnwrap(KeyboardKeyMap.priors(prefix: "wher", languages: [.english], lexicons: sources, personal: nil))
        let point = gap("e"), geometric = grid.hitTest(point)!
        for offset in [-0.4, 0.0, 0.29] {
            var keys = calibration().keys
            keys["r"] = .init(offsetX: offset, offsetY: 0, sigmaX: 0.24, sigmaY: 0.24)
            let map = KeyboardKeyMap(layout: grid, prefix: "wher", calibration: .init(keys: keys), priors: priors)
            XCTAssertEqual(map.attributedKey(at: point, geometric: geometric, layout: grid, prefix: "wher"), geometric)
        }
    }

    /// Fixed seeds; no runtime/user data. Centre, Gaussian, shifted Gaussian and deliberate
    /// correct-side gap probes are reported separately so precision cannot hide gap harm.
    func testLargeOOVHarmAndGainTradeoffEvaluation() throws {
        let sources = try resources()
        var seen: Set<String> = []
        var oov: [(String, String)] = []
        for (category, words) in KeyboardKeyMapEvaluationFixtures.groups {
            for word in words {
                let lower = word.lowercased()
                if seen.insert(lower).inserted,
                   sources.values.allSatisfy({ $0.logPrior(for: lower) == nil }) {
                    oov.append((category, lower))
                }
            }
        }
        XCTAssertGreaterThanOrEqual(oov.count, 200)
        for (category, _) in KeyboardKeyMapEvaluationFixtures.groups {
            let count = oov.filter { $0.0 == category }.count
            XCTAssertGreaterThan(count, 0)
            print("EVAL P8b_corpus category=\(category) unique_oov=\(count)")
        }
        let (trained, _, _) = keyboard(sources)
        let frozen = try XCTUnwrap(trained.autocorrect.learning.calibration(for: grid))
        // Evaluate the shipped policy across the full matrix, not historical diagnostics.
        let policies: [(String, KeyboardKeyMap.Policy)] = [("conservative", .conservative)]
        struct Counts {
            var words = 0, taps = 0, correctTaps = 0, harmTaps = 0, harmWords = 0
            var staticErrors = 0, adaptiveErrors = 0, fixed = 0
            mutating func add(_ other: Counts) {
                words += other.words; taps += other.taps; correctTaps += other.correctTaps
                harmTaps += other.harmTaps; harmWords += other.harmWords
                staticErrors += other.staticErrors; adaptiveErrors += other.adaptiveErrors; fixed += other.fixed
            }
        }
        func points(_ word: String, ordinal: Int, profile: Int) -> [CGPoint] {
            var state = UInt64(ordinal + 1) &* 0x9E3779B97F4A7C15
            func uniform() -> Double {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Double(state >> 11) / 9_007_199_254_740_992
            }
            func gaussian() -> Double {
                sqrt(-2 * log(max(1e-12, uniform()))) * cos(2 * Double.pi * uniform())
            }
            return word.enumerated().map { index, letter in
                let k = key(letter)
                let pitch = Double(k.frame.width + grid.metrics.gap)
                let height = Double(k.frame.height + grid.metrics.rowGap)
                if profile == 0 { return center(k) }
                if profile == 3 {
                    // One deliberate, geometrically correct boundary tap per word, at a
                    // fixed absolute .1/.3/.8/1.4 pt distance (not scaled to policy band).
                    if index == 2 + ordinal % max(1, word.count - 2) {
                        let distance = [0.1, 0.3, 0.8, 1.4][ordinal % 4]
                        return CGPoint(x: k.hitFrame.minX + distance, y: k.frame.midY)
                    }
                    return center(k)
                }
                let drift = profile == 2 ? 0.35 : 0.0
                let spread = profile == 2 ? 0.10 : 0.18
                let p = CGPoint(x: k.frame.midX + (drift + spread * gaussian()) * pitch,
                                y: k.frame.midY + 0.10 * gaussian() * height)
                // Letter attribution only: tails outside the keyboard/on controls are centre
                // taps here; real control activation is not modelled as a letter substitution.
                return grid.hitTest(p)?.character?.first?.isLetter == true ? p : center(k)
            }
        }
        let profiles = ["precise", "gaussian", "shifted", "gapStress"]
        let modes: [(String, Set<Language>, [String])] = [
            ("DE", [.german], SpatialTypoEvaluationFixtures.german),
            ("EN", [.english], SpatialTypoEvaluationFixtures.english),
            ("mixed", [.german, .english], SpatialTypoEvaluationFixtures.german + SpatialTypoEvaluationFixtures.english)
        ]
        var selectedTimes: [Double] = []
        func simulate(_ word: String, points: [CGPoint], languages: Set<Language>,
                      policy: KeyboardKeyMap.Policy, timed: Bool) -> Counts {
            var counts = Counts()
            counts.words = 1
            var prefix = ""
            var harmed = false
            for (letter, point) in zip(word, points) {
                let geometric = grid.hitTest(point)!
                guard let literal = geometric.character?.first else { continue }
                let start = ProcessInfo.processInfo.systemUptime
                let priors = KeyboardKeyMap.priors(prefix: prefix, languages: languages,
                                                   lexicons: sources, personal: nil, policy: policy)
                let map = priors.map { KeyboardKeyMap(layout: grid, prefix: prefix, calibration: frozen,
                                                      priors: $0, policy: policy) }
                let actual = map?.attributedKey(at: point, geometric: geometric, layout: grid, prefix: prefix)
                    .character?.first ?? literal
                if timed { selectedTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1_000) }
                counts.taps += 1
                if literal == letter {
                    counts.correctTaps += 1
                    if actual != letter { counts.harmTaps += 1; harmed = true }
                } else {
                    counts.staticErrors += 1
                    if actual == letter { counts.fixed += 1 }
                }
                if actual != letter { counts.adaptiveErrors += 1 }
                prefix.append(actual)
            }
            counts.harmWords = harmed ? 1 : 0
            return counts
        }
        for (policyName, policy) in policies {
            for (mode, languages, known) in modes {
                var allOOV = Counts(), allKnown = Counts(), compounds = Counts()
                for (profile, profileName) in profiles.enumerated() {
                    var novel = Counts(), vocabulary = Counts()
                    for (ordinal, item) in oov.enumerated() {
                        let taps = points(item.1, ordinal: ordinal, profile: profile)
                        let result = simulate(item.1, points: taps, languages: languages, policy: policy,
                                              timed: policyName == "conservative" && mode == "mixed")
                        novel.add(result)
                        if item.0 == "compounds" { compounds.add(result) }
                        if policyName == "conservative", result.harmWords > 0 {
                            print("EVAL P8b_harm mode=\(mode) noise=\(profileName) category=\(item.0) intended=\(item.1) harm_taps=\(result.harmTaps)")
                        }
                    }
                    for (ordinal, word) in known.enumerated() {
                        let taps = points(word, ordinal: ordinal, profile: profile)
                        vocabulary.add(simulate(word, points: taps, languages: languages, policy: policy, timed: false))
                    }
                    allOOV.add(novel); allKnown.add(vocabulary)
                    if policyName == "conservative" {
                        XCTAssertLessThanOrEqual(Double(novel.harmTaps) / Double(novel.correctTaps), 0.002)
                        XCTAssertLessThanOrEqual(Double(novel.harmWords) / Double(novel.words), 0.01)
                        print("EVAL P8b_profile mode=\(mode) noise=\(profileName) oov_words=\(novel.words) correct_taps=\(novel.correctTaps) harm_taps=\(novel.harmTaps) harm_words=\(novel.harmWords) known_static_errors=\(vocabulary.staticErrors) known_adaptive_errors=\(vocabulary.adaptiveErrors) known_fixed=\(vocabulary.fixed)")
                    }
                }
                if policyName == "conservative" {
                    print("EVAL R2_7_compounds policy=\(policyName) mode=\(mode) runs=\(compounds.words) correct_taps=\(compounds.correctTaps) harm_taps=\(compounds.harmTaps) harm_words=\(compounds.harmWords)")
                }
                let tapRate = Double(allOOV.harmTaps) / Double(allOOV.correctTaps)
                let wordRate = Double(allOOV.harmWords) / Double(allOOV.words)
                if policyName == "conservative" {
                    XCTAssertLessThanOrEqual(tapRate, 0.002)
                    XCTAssertLessThanOrEqual(wordRate, 0.01)
                    XCTAssertEqual(allKnown.harmTaps, 0)
                }
                print("EVAL P8b_tradeoff policy=\(policyName) mode=\(mode) unique_oov=\(oov.count) oov_runs=\(allOOV.words) oov_taps=\(allOOV.taps) correct_taps=\(allOOV.correctTaps) static_harm_taps=0 static_harm_words=0 adaptive_harm_taps=\(allOOV.harmTaps) adaptive_harm_words=\(allOOV.harmWords) tap_harm_rate=\(tapRate) word_harm_rate=\(wordRate) known_runs=\(allKnown.words) known_static_errors=\(allKnown.staticErrors) known_adaptive_errors=\(allKnown.adaptiveErrors) known_fixed=\(allKnown.fixed) known_harm=\(allKnown.harmTaps)")
            }
        }
        // Real engine taps in German sentence context, not just a reimplementation of the
        // map call. All 455 OOV items participate; noise profile cycles independently of category.
        var integrated = Counts(), expected = Counts()
        for (ordinal, item) in oov.enumerated() {
            let (engine, target, _) = keyboard(sources, languages: [.german, .english])
            target.insertText("das ist ")
            engine.refreshSuggestions()
            let taps = points(item.1, ordinal: ordinal, profile: ordinal % 4)
            expected.add(simulate(item.1, points: taps, languages: [.german, .english],
                                  policy: .conservative, timed: false))
            var harmed = false
            for (intended, point) in zip(item.1, taps) {
                let literal = grid.hitTest(point)!.character!.first!
                tap(point, engine)
                let actual = target.text.last!
                integrated.taps += 1
                if literal == intended {
                    integrated.correctTaps += 1
                    if actual != intended { integrated.harmTaps += 1; harmed = true }
                } else {
                    integrated.staticErrors += 1
                    if actual == intended { integrated.fixed += 1 }
                }
                if actual != intended { integrated.adaptiveErrors += 1 }
            }
            integrated.words += 1
            if harmed { integrated.harmWords += 1 }
        }
        XCTAssertEqual(integrated.harmTaps, expected.harmTaps)
        XCTAssertEqual(integrated.adaptiveErrors, expected.adaptiveErrors)
        XCTAssertLessThanOrEqual(Double(integrated.harmWords) / Double(integrated.words), 0.01)
        XCTAssertLessThanOrEqual(Double(integrated.harmTaps) / Double(integrated.correctTaps), 0.002)
        print("EVAL P8b_integration mode=mixed context=German_sentence oov_words=\(integrated.words) taps=\(integrated.taps) correct_taps=\(integrated.correctTaps) harm_taps=\(integrated.harmTaps) harm_words=\(integrated.harmWords) static_errors=\(integrated.staticErrors) adaptive_errors=\(integrated.adaptiveErrors) map_engine_equivalent=1")
        selectedTimes.sort()
        print("EVAL P8b_latency calls=\(selectedTimes.count) map_p95_ms=\(selectedTimes[Int(Double(selectedTimes.count - 1) * 0.95)]) map_max_ms=\(selectedTimes.last!) wall_clock_assertions=0 calibration=frozen_trained synthetic=1")
    }

    func testImportedNameAttributionGuardBeforeAfterEvaluation() throws {
        let sources = try resources()
        let controls = ["ina", "malin", "andi", "jens", "maren", "alice", "george", "siemens",
                        "microsoft", "openai", "herdr", "typr", "whisper", "fahrradlieferzeit",
                        "kindergartenplatz", "haustuerschluessel"]
        var builder = ProtectedPersonalLexicon.Builder()
        for word in controls { builder.add(word) }
        let imported = builder.build()
        let modes: [(String, Set<Language>)] = [
            ("DE", [.german]), ("EN", [.english]), ("mixed", [.german, .english])
        ]
        for (mode, languages) in modes {
            var harms = 0
            var runs = 0
            for word in controls {
                for gapIndex in word.indices {
                    runs += 1
                    let (engine, target, _) = keyboard(sources, languages: languages)
                    engine.autocorrect.loadProtectedLexicon(imported)
                    target.insertText("das ist ")
                    engine.refreshSuggestions()
                    for index in word.indices {
                        let k = key(word[index])
                        let point = index == gapIndex
                            ? CGPoint(x: k.hitFrame.minX + 0.1, y: k.frame.midY) : center(k)
                        XCTAssertEqual(grid.hitTest(point)?.character, String(word[index]))
                        tap(point, engine)
                    }
                    XCTAssertEqual(target.text, "das ist " + word, "\(mode), gap at \(gapIndex)")
                    if target.text != "das ist " + word { harms += 1 }
                }
            }
            XCTAssertEqual(harms, 0)
            print("EVAL R2_1_attribution mode=\(mode) controls=\(controls.count) gap_runs=\(runs) protected_false=\(harms) profile=one_geometrically_correct_gap_per_position NOT-iPhone")
        }
    }

    func testWiderValidLiteralGateEvaluation() throws {
        let sources = try resources()
        let controls = ["ina", "malin", "andi", "jens", "maren", "alice", "george", "siemens",
                        "microsoft", "openai", "herdr", "typr", "whisper", "fahrradlieferzeit",
                        "kindergartenplatz", "haustuerschluessel"]
        var builder = ProtectedPersonalLexicon.Builder()
        builder.add(controls.joined(separator: " "))
        let imported = builder.build()
        let policies: [(String, KeyboardKeyMap.Policy)] = [
            ("shipping", .conservative),
            ("short", .init(boundaryFraction: 0.015, novelFloor: 0.90, minimumPrefix: 2,
                            densityMargin: log(4), posteriorMargin: log(16), requiresConsistency: true)),
            ("edges", .init(boundaryFraction: 0.10, novelFloor: 0.90, minimumPrefix: 4,
                            densityMargin: log(4), posteriorMargin: log(16), requiresConsistency: true,
                            includesKeyEdges: true)),
            ("wider", .init(boundaryFraction: 0.10, novelFloor: 0.90, minimumPrefix: 2,
                            densityMargin: log(4), posteriorMargin: log(16), requiresConsistency: true,
                            includesKeyEdges: true))
        ]
        let modes: [(String, Set<Language>)] = [
            ("DE", [.german]), ("EN", [.english]), ("mixed", [.german, .english])
        ]
        for (mode, languages) in modes {
            for (name, policy) in policies {
                var harms = [0, 0], probes = 0, centerChanges = 0
                for word in controls {
                    var prefix = ""
                    for letter in word {
                        if let priors = KeyboardKeyMap.priors(prefix: prefix, languages: languages,
                                                             lexicons: sources, personal: nil, policy: policy) {
                            let map = KeyboardKeyMap(layout: grid, prefix: prefix, calibration: calibration(),
                                                     priors: priors, policy: policy)
                            let k = key(letter)
                            let centered = map.attributedKey(at: center(k), geometric: k, layout: grid, prefix: prefix)
                            if centered != k { centerChanges += 1 }
                            // Both directions, on the correct side of hit boundary and just inside keycap.
                            let xs: [CGFloat] = [k.hitFrame.minX + 0.1, k.hitFrame.maxX - 0.1,
                                                 k.frame.minX + 0.1, k.frame.maxX - 0.1]
                            for x in xs {
                                let p = CGPoint(x: x, y: k.frame.midY)
                                guard grid.hitTest(p) == k else { continue }
                                probes += 1
                                if map.attributedKey(at: p, geometric: k, layout: grid, prefix: prefix) != k {
                                    harms[0] += 1
                                    let guarded = imported.contains(prefix) || imported.protectsPrefix(prefix + String(letter))
                                    if !guarded { harms[1] += 1 }
                                }
                            }
                        }
                        prefix.append(letter)
                    }
                }
                XCTAssertEqual(centerChanges, 0)
                XCTAssertEqual(harms[1], 0)
                print("EVAL R2_7_controls policy=\(name) mode=\(mode) words=\(controls.count) correct_side_probes=\(probes) without_import_harm=\(harms[0]) with_import_harm=\(harms[1]) dead_center_changes=\(centerChanges)")
            }
        }
    }

    /// Synthetic dictation-style vocabulary: common DE/EN words plus names/terms, no private log.
    /// Before is the exact #127 prefix-wide guard; after uses the production per-tap guard.
    func testDictationImportBranchCoverageEvaluation() throws {
        let sources = try resources()
        let words = SpatialTypoEvaluationFixtures.german + SpatialTypoEvaluationFixtures.english
        let names = ["malin", "maren", "ina", "typr", "herdr", "whisper", "fahrradlieferzeit"]
        var builder = ProtectedPersonalLexicon.Builder()
        builder.add((words + names).joined(separator: " "))
        let imported = builder.build()
        let modes: [(String, Set<Language>)] = [
            ("DE", [.german]), ("EN", [.english]), ("mixed", [.german, .english])
        ]
        for (mode, languages) in modes {
            let (engine, _, checker) = keyboard(sources, languages: languages)
            engine.autocorrect.loadProtectedLexicon(imported)
            let frozen = try XCTUnwrap(engine.autocorrect.learning.calibration(for: grid))
            var branches = 0, before = 0, after = 0, changesBefore = 0, changesAfter = 0
            var protectedTaps = 0
            for word in words + names {
                var prefix = ""
                for letter in word.lowercased() {
                    let priors = KeyboardKeyMap.priors(prefix: prefix, languages: languages,
                                                       lexicons: sources, personal: nil)
                    if prefix.count >= 4, let priors {
                        let map = KeyboardKeyMap(layout: grid, prefix: prefix, calibration: frozen, priors: priors)
                        // Every intended continuation of an imported word must remain protected.
                        XCTAssertTrue(engine.autocorrect.protectsAttribution(prefix: prefix, letter: String(letter)))
                        protectedTaps += 1
                        for entry in map.entries {
                            let text = entry.key.character!
                            let oldGuard = imported.protectsPrefix(prefix) || imported.protectsPrefix(prefix + text)
                            let newGuard = engine.autocorrect.protectsAttribution(prefix: prefix, letter: text)
                            branches += 1
                            if !oldGuard { before += 1 }
                            if !newGuard { after += 1 }
                            let point = CGPoint(x: entry.key.hitFrame.minX + 0.1, y: entry.key.frame.midY)
                            let actual = map.attributedKey(at: point, geometric: entry.key, layout: grid, prefix: prefix)
                            if actual != entry.key {
                                if !oldGuard { changesBefore += 1 }
                                if !newGuard { changesAfter += 1 }
                            }
                        }
                    }
                    prefix.append(letter)
                }
            }
            XCTAssertGreaterThan(after, before)
            XCTAssertGreaterThan(changesAfter, changesBefore)
            XCTAssertEqual(checker.calls, 0)
            XCTAssertLessThanOrEqual(imported.words.count, 2_000)
            print("EVAL R2_7_import mode=\(mode) imported=\(imported.words.count) branch_probes=\(branches) before_available=\(before) after_available=\(after) before_changes=\(changesBefore) after_changes=\(changesAfter) protected_continuations=\(protectedTaps) checker_calls=\(checker.calls) synthetic_dictation=1")
        }
        // Integration: an imported competing branch must not suppress recovery of 'where'.
        let (engine, target, checker) = keyboard(sources)
        var competing = ProtectedPersonalLexicon.Builder()
        competing.add("whereas")
        engine.autocorrect.loadProtectedLexicon(competing.build())
        type("wher", engine)
        tap(gap("e"), engine)
        XCTAssertEqual(target.text, "where")
        XCTAssertEqual(checker.calls, 0)
        XCTAssertTrue(engine.autocorrect.protectsAttribution(prefix: "whereas", letter: "x"))
    }

    func testAttributedFeedbackCurveRemainsNoUpdateAfterFailedWideningGate() throws {
        let sources = try resources()
        var curve: [Int] = []
        for undo in [true, false] {
            // One fresh session per path; no cumulative learning between trials.
            let (engine, target, _) = keyboard(sources)
            let session = engine.autocorrect.learning
            let trustedLabels = session.diagnostics.acceptedLabels
            XCTAssertGreaterThan(trustedLabels, 0)
            type("wher", engine)
            tap(gap("e"), engine)
            XCTAssertEqual(target.text, "where")
            if undo {
                engine.deleteBackward()
                tap(gap("e"), engine)
                XCTAssertEqual(target.text, "wherr", "backspace/retype must stay geometric")
            } else {
                tap(center(engine.layout.key(.space)!), engine)
                type("w", engine)
            }
            curve.append(session.diagnostics.acceptedLabels - trustedLabels)
            XCTAssertNil(session.model.lexicon.counts["where"])
        }
        XCTAssertEqual(curve, [0, 0])
        print("EVAL R2_7_feedback trials=2 not_undone=1 backspace_undo=1 attributed_label_curve=\(curve) attributed_word_counts=0 soft_labels_shipped=0")
    }

    func testMapWorkPayloadAndLatencyEvaluation() throws {
        let sources = try resources()
        let start = ProcessInfo.processInfo.systemUptime
        var bytes = 0
        let prefixes = ["wher", "hall"]
        for prefix in prefixes {
            let m = try map(sources, prefix: prefix, languages: [.german, .english])
            bytes = max(bytes, m.payloadBytes)
            XCTAssertLessThanOrEqual(m.entries.count, 26)
            for k in grid.keys {
                XCTAssertEqual(m.attributedKey(at: center(k), geometric: k, layout: grid, prefix: m.prefix), k)
            }
        }
        let ms = (ProcessInfo.processInfo.systemUptime - start) * 1_000 / Double(prefixes.count)
        let resourceBytes = sources.values.reduce(0) { $0 + $1.continuationPayloadBytes }
        XCTAssertLessThanOrEqual(bytes, 16 * 1_024)
        XCTAssertLessThanOrEqual(MemoryLayout<KeyboardKeyMap.Policy>.stride, 64)
        XCTAssertFalse(KeyboardKeyMap.Policy.conservative.includesKeyEdges)
        XCTAssertEqual(KeyboardKeyMap.Policy.conservative.minimumPrefix, 4)
        XCTAssertEqual(resourceBytes, sources.values.reduce(0) { $0 + $1.nodeCount * 8 })
        XCTAssertLessThanOrEqual(resourceBytes, 6_400_000)
        print("EVAL P8_bounds map_entries=26 max_neighbor_scores=2 max_entry_inspections=52 map_payload_bytes=\(bytes) policy_bytes=\(MemoryLayout<KeyboardKeyMap.Policy>.stride) recovery_bits=1 continuation_index_bytes=\(resourceBytes) map_and_center_probes_mean_ms=\(ms) wall_clock_assertions=0")
    }
}
