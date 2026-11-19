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
                        let next = word + String(SpatialWordLexicon.alphabet[lexicon.node(child)!.label])
                        if next.hasPrefix(prefix) || prefix.hasPrefix(next) { visit(child, word: next) }
                    }
                }
                visit(0, word: "")
                XCTAssertEqual(lexicon.nextLetterMass(after: prefix), oracle)
            }
        }
        let both = try XCTUnwrap(KeyboardKeyMap.priors(prefix: "ha", languages: [.english, .german], lexicons: sources, personal: nil))
        XCTAssertEqual(both.reduce(0, +), 1, accuracy: 1e-12)
        XCTAssertTrue(both.allSatisfy { $0 > 0 })
        let novel = try XCTUnwrap(KeyboardKeyMap.priors(prefix: "zzqx", languages: [.english, .german], lexicons: sources, personal: nil))
        for p in novel { XCTAssertEqual(p, 1.0 / 26, accuracy: 1e-12, "an absent prefix backs off to uniform odds") }
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

    func testCentredTapsFunctionKeysAndStaleGeometryStayGeometric() throws {
        let map = try map(resources())
        let point = gap("e"), geometric = grid.hitTest(point)!
        XCTAssertEqual(geometric.character, "r")
        XCTAssertEqual(map.attributedKey(at: point, geometric: geometric, layout: grid, prefix: "wher").character, "e")
        for k in grid.keys {
            XCTAssertEqual(map.attributedKey(at: center(k), geometric: k, layout: grid, prefix: "wher"), k)
        }
        for k in grid.keys where k.character.map({ $0.count != 1 || !$0.first!.isLetter }) ?? true {
            for x in [k.hitFrame.minX + 0.1, k.hitFrame.maxX - 0.1] {
                let p = CGPoint(x: x, y: k.hitFrame.midY)
                XCTAssertEqual(map.attributedKey(at: p, geometric: k, layout: grid, prefix: "wher"), k)
            }
        }
        XCTAssertEqual(map.attributedKey(at: point, geometric: geometric, layout: grid, prefix: "ha"), geometric)
        XCTAssertEqual(map.attributedKey(at: point, geometric: geometric, layout: KeyboardLayout(width: 440), prefix: "wher"), geometric)
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
        XCTAssertEqual(session.diagnostics.acceptedLabels, labels + 11,
                       "only independently observed world and hello teach, plus the Space between them")
        XCTAssertEqual(session.diagnostics.acceptedBySource["space"], 1)
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
        for mode in 1..<9 {
            let (engine, target, _) = keyboard(sources)
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
        XCTAssertNotNil(engine.autocorrect.keyMap(layout: grid, context: "wher", permitsCorrection: true))
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
            for (ordinal, intended) in words.enumerated() where EvaluationSample.includes(ordinal, every: 25) {
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
            print("EVAL P8_hits_\(name) taps=\(taps) static_errors=\(staticErrors) adaptive_errors=\(adaptiveErrors) reattributed=\(changed) wrong=\(wrong) insertion_p95_ms=\(p95) insertion_max_ms=\(times.last!)")
        }
    }

    func testNovelNamesAndValidWordsTypedAtKeyCentresStay() throws {
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
        print("EVAL P8_controls words=\(controls.count) unwanted_space_changes=\(unwanted) center_reattributions=\(reattributed) visual_keycap_changes=0")
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
            tap(gap("e"), engine)
            XCTAssertTrue(target.text.hasSuffix("zqxr"), "the veto lasts to the end of the word")
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
        train(engine) // Previous centre-tapped trusted words legitimately changed the aim memories.
        tap(gap("e"), engine)
        XCTAssertTrue(target.text.hasSuffix(" where"))
        XCTAssertNil(engine.autocorrect.touchInput.boundaryEvidence(beforeInput: target.text))
        tap(center(engine.layout.key(.space)!), engine)
        type("hello", engine)
        let after = try XCTUnwrap(engine.autocorrect.touchInput.boundaryEvidence(beforeInput: target.text))
        XCTAssertNil(after.previous, "an attributed word must not seed a boundary window")
        XCTAssertNil(after.space)
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
        var probe = 0
        for (mode, languages) in modes {
            var harms = 0
            var runs = 0
            for word in controls {
                for gapIndex in word.indices {
                    probe += 1
                    guard EvaluationSample.includes(probe, every: 34) else { continue }
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
        XCTAssertEqual(resourceBytes, sources.values.reduce(0) { $0 + $1.nodeCount * 8 })
        XCTAssertLessThanOrEqual(resourceBytes, 6_400_000)
        print("EVAL P8_bounds map_entries=26 max_neighbor_scores=2 max_entry_inspections=52 map_payload_bytes=\(bytes) recovery_bits=1 continuation_index_bytes=\(resourceBytes) map_and_center_probes_mean_ms=\(ms) wall_clock_assertions=0")
    }

    private func trainedCalibration(_ sources: [Language: SpatialWordLexicon]) throws -> SpatialTouchCalibration {
        try XCTUnwrap(keyboard(sources).0.autocorrect.learning.calibration(for: grid))
    }

    private func leftEdge(_ letter: Character, depth: CGFloat = 2) -> CGPoint {
        CGPoint(x: key(letter).hitFrame.minX + depth, y: key(letter).frame.midY)
    }

    private func adaptiveMap(_ prefix: String, _ languages: Set<Language>, sources: [Language: SpatialWordLexicon],
                             calibration: SpatialTouchCalibration,
                             personal: PersonalCompletionIndex? = nil) -> KeyboardKeyMap? {
        KeyboardKeyMap.make(layout: grid, prefix: prefix, calibration: calibration, languages: languages,
                            lexicons: sources, personal: personal)
    }

    /// The word Adaptive types for these taps when it differs from the geometric literal and is known.
    private func knownReading(of taps: [CGPoint], _ languages: Set<Language>,
                              sources: [Language: SpatialWordLexicon],
                              calibration: SpatialTouchCalibration) -> String? {
        var typed = "", literal = ""
        for point in taps {
            let geometric = grid.hitTest(point)!
            literal += geometric.character!
            // Centred taps stay geometric (asserted in testAdaptiveMapsFromTheFirstLetterAndCentredTapsStay).
            guard point != center(geometric) else { typed += geometric.character!; continue }
            let map = adaptiveMap(typed, languages, sources: sources, calibration: calibration)
            typed += (map?.attributedKey(at: point, geometric: geometric, layout: grid, prefix: typed) ?? geometric).character!
        }
        guard typed != literal else { return nil }
        return languages.contains { sources[$0]?.logPrior(for: typed) != nil } ? typed : nil
    }

    func testAdaptiveReadsAnEdgeMissLiveAsTheLikeliestKey() throws {
        let sources = try resources()
        let frozen = try trainedCalibration(sources)
        let point = leftEdge("m"), geometric = key("m")
        let adaptive = try XCTUnwrap(adaptiveMap("arou", [.english], sources: sources, calibration: frozen))
        XCTAssertEqual(adaptive.attributedKey(at: point, geometric: geometric, layout: grid, prefix: "arou"), key("n"))
        XCTAssertEqual(adaptive.attributedKey(at: point, geometric: geometric, layout: grid, prefix: "arouz"), geometric,
                       "a map holds only for the prefix it was made for")
        var taps = "around".map { center(key($0)) }
        taps[4] = point
        XCTAssertEqual(knownReading(of: taps, [.english], sources: sources, calibration: frozen), "around")
    }

    func testAdaptiveMapsFromTheFirstLetterAndCentredTapsStay() throws {
        let sources = try resources()
        let frozen = try trainedCalibration(sources)
        for prefix in ["", "a", "arou", "wher"] {
            let map = try XCTUnwrap(adaptiveMap(prefix, [.english], sources: sources, calibration: frozen), prefix)
            for k in grid.keys where k.character.map({ $0.count == 1 && $0.first!.isLetter }) == true {
                XCTAssertEqual(map.attributedKey(at: center(k), geometric: k, layout: grid, prefix: prefix), k,
                               "\(prefix)+\(k.character!)")
            }
        }
        let personal = PersonalCompletionIndex(sortedWords: ["aroumar"], kept: ["aroumar"], counts: [:])
        XCTAssertNotNil(adaptiveMap("arou", [.english], sources: sources, calibration: frozen, personal: personal))
    }

    func testNearCollinearTrustedLabelsKeepCentredValidWords() throws {
        let sources = try resources()
        let history = "the quick brown fox jumps over the lazy dog and then runs around the house with a kind friend"
        do {
            let (engine, target, _) = keyboard(sources, trained: false)
            let layout = engine.layout
            var index = 0
            for _ in 0..<8 {
                for word in history.split(separator: " ") {
                    let labels = word.map { letter -> TouchLabel in
                        defer { index += 1 }
                        let k = key(letter, layout)
                        let jitter = Double(index % 3 - 1) * 0.06
                        let y = jitter + Double(index / 3 % 3 - 1) * 0.01
                        return TouchLabel(point: CGPoint(x: k.frame.midX + (0.25 + jitter) * (k.frame.width + layout.metrics.gap),
                                                         y: k.frame.midY + y * (k.frame.height + layout.metrics.rowGap)),
                                          letter: letter)
                    }
                    engine.autocorrect.learning.learn(labels, layout: layout, source: .literalValid)
                }
            }
            XCTAssertEqual(engine.autocorrect.learning.diagnostics.acceptedLabels, index)
            engine.refreshSuggestions()
            type("kind", engine)
            XCTAssertEqual(target.text, "kind")
            tap(center(layout.key(.space)!), engine)
            XCTAssertEqual(target.text, "kind ")
        }
    }

    func testAdaptiveTypesTheLikeliestKeyThroughTheEngine() throws {
        let sources = try resources()
        func settle(configure: (FullKeyboardEngine, FixtureTextTarget) -> Void = { _, _ in })
            -> (typed: String, settled: String) {
            let (engine, target, _) = keyboard(sources)
            configure(engine, target)
            engine.refreshSuggestions()
            let m = key("m", engine.layout)
            for (index, letter) in "around".enumerated() {
                tap(index == 4 ? CGPoint(x: m.hitFrame.minX + 2, y: m.frame.midY) : center(key(letter, engine.layout)), engine)
            }
            let typed = target.text
            tap(center(engine.layout.key(.space)!), engine)
            return (typed, target.text)
        }
        XCTAssertEqual(settle().typed, "around", "the tap is read as n when it lands")
        XCTAssertEqual(settle().settled, "around ")
        XCTAssertEqual(settle { engine, _ in engine.autocorrect.isEnabled = false }.settled, "aroumd ")
        XCTAssertEqual(settle { _, target in target.autocorrectionType = .no }.settled, "aroumd ")
    }

    /// Reading every tap trades unknown words for known ones (iikb's choice); this reports both.
    func testAdaptiveUnknownAndKnownWordEdgeEvaluation() throws {
        let sources = try resources()
        let frozen = try trainedCalibration(sources)
        var seen: Set<String> = []
        let oov = KeyboardKeyMapEvaluationFixtures.groups.flatMap(\.1).map { $0.lowercased() }.filter { word in
            seen.insert(word).inserted && sources.values.allSatisfy { $0.logPrior(for: word) == nil }
        } + ["gehring", "reolink", "fotheringham", "friemel", "everud", "everup", "friemelt"]
        let known = Array(Set((SpatialTypoEvaluationFixtures.german + SpatialTypoEvaluationFixtures.english)
            .map { $0.lowercased() })).sorted()
        let modes: [Set<Language>] = [[.german], [.english], [.german, .english]]
        let pitch = CGSize(width: key("q").frame.width + grid.metrics.gap, height: key("q").frame.height + grid.metrics.rowGap)
        let depths: [CGFloat] = EvaluationSample.isFull ? [0.1, 0.3, 0.8, 1.4, 2, 3, 4, 5] : [0.3, 2, 4]
        let area: [(x: CGFloat, y: CGFloat)] = stride(from: -1.0, through: 1.0, by: 0.1).flatMap { x in
            [-1.0, -0.6, -0.45, -0.3, 0, 0.3, 0.45, 0.6, 1.0].map { (CGFloat(x), CGFloat($0)) }
        }
        func taps(around k: KeyboardKey, dense: Bool) -> [CGPoint] {
            let edges = depths.flatMap { [CGPoint(x: k.hitFrame.minX + $0, y: k.frame.midY),
                                          CGPoint(x: k.hitFrame.maxX - $0, y: k.frame.midY)] }
            let grid2D = area.map { CGPoint(x: k.frame.midX + $0.x * pitch.width, y: k.frame.midY + $0.y * pitch.height) }
            return (dense ? edges + grid2D : edges).filter { grid.hitTest($0)?.character?.count == 1 }
        }
        var probes = 0, moved: [String] = [], gains = 0
        for languages in modes {
            for (ordinal, word) in oov.enumerated() {
                for (index, letter) in word.enumerated() {
                    for point in taps(around: key(letter), dense: EvaluationSample.includes(ordinal, every: 43)) {
                        var line = word.map { center(key($0)) }
                        line[index] = point
                        probes += 1
                        if let reading = knownReading(of: line, languages, sources: sources, calibration: frozen) {
                            moved.append("\(word)->\(reading)")
                        }
                    }
                }
            }
            for (ordinal, word) in known.enumerated() where EvaluationSample.includes(ordinal, every: 7) {
                for (index, letter) in word.enumerated() {
                    for point in taps(around: key(letter), dense: true) {
                        var line = word.map { center(key($0)) }
                        line[index] = point
                        if knownReading(of: line, languages, sources: sources, calibration: frozen) == word { gains += 1 }
                    }
                }
            }
        }
        XCTAssertGreaterThan(gains, moved.count)
        print("EVAL hit_areas_taps full=\(EvaluationSample.isFull) unknown_words=\(oov.count) probes=\(probes) known_readings_for_unknown=\(moved.count) known_word_readings=\(gains)")
    }

    /// Centred taps never move an unknown word; noisy taps may, as in iikb.
    func testAdaptiveNoiseEvaluation() throws {
        let sources = try resources()
        let frozen = try trainedCalibration(sources)
        var seen: Set<String> = []
        let oov = KeyboardKeyMapEvaluationFixtures.groups.flatMap(\.1).map { $0.lowercased() }.filter { word in
            seen.insert(word).inserted && sources.values.allSatisfy { $0.logPrior(for: word) == nil }
        }
        func points(_ word: String, ordinal: Int, profile: Int) -> [CGPoint] {
            var state = UInt64(ordinal + 1) &* 0x9E3779B97F4A7C15
            func uniform() -> Double {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Double(state >> 11) / 9_007_199_254_740_992
            }
            func gaussian() -> Double { sqrt(-2 * log(max(1e-12, uniform()))) * cos(2 * Double.pi * uniform()) }
            return word.enumerated().map { index, letter in
                let k = key(letter)
                if profile == 0 { return center(k) }
                if profile == 3 {
                    guard index == 2 + ordinal % max(1, word.count - 2) else { return center(k) }
                    return CGPoint(x: k.hitFrame.minX + [0.1, 0.3, 0.8, 1.4][ordinal % 4], y: k.frame.midY)
                }
                let drift = profile == 2 ? 0.35 : 0.0, spread = profile == 2 ? 0.10 : 0.18
                let p = CGPoint(x: k.frame.midX + (drift + spread * gaussian()) * (k.frame.width + grid.metrics.gap),
                                y: k.frame.midY + 0.10 * gaussian() * (k.frame.height + grid.metrics.rowGap))
                return grid.hitTest(p)?.character?.first?.isLetter == true ? p : center(k)
            }
        }
        let modes: [(Set<Language>, [String])] = [
            ([.german], SpatialTypoEvaluationFixtures.german),
            ([.english], SpatialTypoEvaluationFixtures.english),
            ([.german, .english], SpatialTypoEvaluationFixtures.german + SpatialTypoEvaluationFixtures.english)
        ]
        var moved: [String] = [], centred: [String] = [], gains = 0
        for (languages, vocabulary) in modes {
            for profile in 0..<4 {
                for (ordinal, word) in oov.enumerated() where EvaluationSample.includes(ordinal, every: 43) {
                    let taps = points(word, ordinal: ordinal, profile: profile)
                    if let reading = knownReading(of: taps, languages, sources: sources, calibration: frozen) {
                        moved.append("\(word)->\(reading)")
                        if profile == 0 { centred.append("\(word)->\(reading)") }
                    }
                }
                for (ordinal, word) in vocabulary.enumerated() where EvaluationSample.includes(ordinal, every: 43) {
                    let word = word.lowercased()
                    let reading = knownReading(of: points(word, ordinal: ordinal, profile: profile), languages,
                                               sources: sources, calibration: frozen)
                    if reading == word { gains += 1 }
                }
            }
        }
        XCTAssertEqual(centred, [])
        XCTAssertGreaterThan(gains, 0)
        print("EVAL hit_areas_noise full=\(EvaluationSample.isFull) known_readings_for_unknown=\(moved.count) known_word_readings=\(gains)")
    }
}
