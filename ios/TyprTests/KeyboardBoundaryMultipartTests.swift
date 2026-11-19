import Foundation
import XCTest
@testable import Typr

extension KeyboardBoundaryDecoderTests {
    func multipartTouch(_ noisy: String, aimed: String) throws -> KeyboardBoundaryTouch {
        let samples: [KeyboardTouchWord.Sample] = try zip(noisy, aimed).map { typed, intended in
            let key = try XCTUnwrap(grid.key(.character(String(typed))))
            let target = try XCTUnwrap(grid.key(.character(String(intended))))
            let point = CGPoint(x: 0.85 * target.frame.midX + 0.15 * key.frame.midX,
                                y: 0.85 * target.frame.midY + 0.15 * key.frame.midY)
            return .init(text: String(typed), point: point, key: key)
        }
        return KeyboardBoundaryTouch(current: KeyboardTouchWord(layout: grid, samples: samples))
    }

    func installMultipart(_ touch: KeyboardBoundaryTouch, in ac: AutocorrectEngine) {
        ac.touchInput.clear()
        var before = ""
        for sample in touch.current.samples {
            let after = before + sample.text
            ac.touchInput.append(text: sample.text, point: sample.point, key: sample.key,
                                 layout: grid, before: before, after: after)
            before = after
        }
    }

    /// Original synthetic fixtures: every part has one substituted letter; observed
    /// coordinates favor the intended key. Not human-touch accuracy evidence.
    /// Pin adjacent substitutions: sorting equidistant keys by floating-point distance
    /// can choose different neighbors on arm64 and x86_64 (notably y → t vs y → u).
    /// For "have a nice day", that changes decoder rank two to three, beyond the
    /// strip's two boundary slots. Both platforms use the injected corpus Checker,
    /// not UITextChecker; exact recall below applies to these fixed fixtures only.
    func testEvaluationMultipartOneErrorPerPart() throws {
        let sources = try resources()
        let modes: [(String, Set<Language>, [String])] = [
            ("DE", [.german], ["guten morgen heute", "wir haben zeit", "bitte komm morgen", "ich habe hunger", "das ist gut", "wir sind hier"]),
            ("EN", [.english], ["great day today", "please come home", "we have time", "this is good", "you are here", "have a nice day"]),
            ("mixed", [.german, .english], ["guten morning heute", "please komm morgen", "wir have zeit", "this ist gut", "you bist hier", "have einen nice tag"])
        ]
        let substitutions: [Character: Character] = [
            "a": "s", "d": "s", "e": "w", "g": "f", "h": "g", "m": "n",
            "n": "b", "r": "t", "s": "a", "t": "r", "u": "y", "y": "u"
        ]
        for (name, languages, fixtures) in modes {
            let phrases = fixtures.enumerated().filter { EvaluationSample.includes($0.offset, every: 2) }.map(\.element)
            let ac = engine(sources, languages: languages)
            var recall1 = 0, recall3 = 0, strip3 = 0, autos = 0, wrongAutos = 0
            var visits = 0, cells = 0, cached = 0, exhausted = 0
            var timings: [Double] = []
            for phrase in phrases {
                let parts = phrase.split(separator: " ")
                let noisy = try parts.map { part -> String in
                    var letters = Array(part)
                    let last = try XCTUnwrap(letters.last)
                    let neighbor = try XCTUnwrap(substitutions[last])
                    XCTAssertNotEqual(last, neighbor)
                    let key = try XCTUnwrap(grid.key(.character(String(last))))
                    let adjacent = try XCTUnwrap(grid.key(.character(String(neighbor))))
                    XCTAssertEqual(key.row, adjacent.row)
                    XCTAssertLessThanOrEqual(abs(key.frame.midX - adjacent.frame.midX),
                                             key.frame.width + grid.metrics.gap + 0.001)
                    letters[letters.count - 1] = neighbor
                    return String(letters)
                }.joined()
                let aimed = phrase.replacingOccurrences(of: " ", with: "")
                let touch = try multipartTouch(noisy, aimed: aimed)
                var input = job(noisy, languages: languages)
                input.touch = touch
                let start = ProcessInfo.processInfo.systemUptime
                let result = Boundary.retrieve(input, lexicons: sources)
                timings.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
                visits = max(visits, result.multipartVisits)
                cells = max(cells, result.multipartCells)
                cached = max(cached, result.multipartCachedReadings)
                if result.multipartExhausted { exhausted += 1 }
                XCTAssertEqual(result.candidates, Boundary.retrieve(input, lexicons: sources).candidates)
                XCTAssertLessThanOrEqual(result.multipartVisits, KeyboardMultipartSegmenter.maximumVisits)
                XCTAssertLessThanOrEqual(result.multipartCells, KeyboardMultipartSegmenter.maximumVisits * 20)
                installMultipart(touch, in: ac)
                let words = result.candidates.map(\.replacement)
                if words.first == phrase { recall1 += 1 }
                if words.prefix(3).contains(phrase) { recall3 += 1 }
                let chips = ac.suggestions(beforeInput: noisy, field: .text,
                                           autocorrectionType: .default, boundaryRetrieval: result)
                if chips.contains(where: { $0.replacement.lowercased() == phrase }) { strip3 += 1 }
                XCTAssertTrue(chips.contains { $0.replacement.lowercased() == phrase },
                              "\(name): \(phrase), noisy=\(noisy), candidates=\(words), chips=\(chips.map(\.replacement))")
                let highlighted = chips.first { $0.boundary != nil && $0.willAutoReplace }?.replacement
                let applied = ac.replacementOnSpace(beforeInput: noisy, field: .text, autocorrectionType: .default)
                XCTAssertEqual(applied.flatMap { $0.replacement.contains(" ") ? $0.replacement : nil }, highlighted, noisy)
                if let replacement = applied?.replacement, replacement.contains(" ") {
                    autos += 1
                    if replacement.lowercased() != phrase { wrongAutos += 1 }
                }
            }
            XCTAssertEqual(wrongAutos, 0)
            XCTAssertEqual(recall3, phrases.count)
            XCTAssertEqual(strip3, phrases.count)
            XCTAssertGreaterThanOrEqual(recall1, EvaluationSample.isFull && name == "EN" ? 5 : phrases.count)
            print("EVAL R2_6_multipart_work language=\(name) visits_max=\(visits) visit_cap=\(KeyboardMultipartSegmenter.maximumVisits) cells_max=\(cells) cached_readings_max=\(cached) exhausted_calls=\(exhausted) payload_cap=\(KeyboardMultipartSegmenter.maximumPayloadBytes) mean_ms=\(timings.reduce(0,+)/Double(timings.count)) max_ms=\(timings.max() ?? 0) memory=payload_NOT_RSS")
            print("EVAL R2_6_multipart language=\(name) n=\(phrases.count) recall1=\(recall1) recall3=\(recall3) strip3=\(strip3) autos=\(autos) wrong_autos=\(wrongAutos) errors=one_substitution_per_part NOT-iPhone")
        }
    }

    func testMultipartStructuralPartWithTwoSupportedPartsAndNoEvidenceAbstention() throws {
        let sources = try resources()
        let variants = [("gutemmorgemheut", "gutenmorgenheut"),
                        ("gutemmorgemheutex", "gutenmorgenheutex")]
        for (text, aimed) in variants {
            let touch = try multipartTouch(text, aimed: aimed)
            var input = job(text, languages: [.german])
            input.touch = touch
            let result = Boundary.retrieve(input, lexicons: sources)
            XCTAssertTrue(result.candidates.contains { $0.replacement == "guten morgen heute" }, text)
            input.touch = nil
            XCTAssertFalse(Boundary.retrieve(input, lexicons: sources).candidates.contains {
                $0.replacement == "guten morgen heute"
            })
        }
    }

    func testMultipartWorkerUndoProtectionsAndNoLearning() async throws {
        let sources = try resources()
        let touch = try multipartTouch("gutemmorgemheutr", aimed: "gutenmorgenheute")
        let ac = engine(sources, languages: [.german])
        let target = FixtureTextTarget(text: touch.original)
        let keyboard = FullKeyboardEngine(target: target, autocorrect: ac)
        keyboard.width = grid.width
        keyboard.configureForField()
        installMultipart(touch, in: ac)
        // A synchronous legacy result must not poison the worker's full cache.
        XCTAssertFalse(strip(ac, touch.original).contains { $0.boundary != nil })
        keyboard.refreshSuggestions()
        await keyboard.waitForSuggestions()
        let chip = try XCTUnwrap(keyboard.suggestions.first { $0.boundary?.replacement == "guten morgen heute" })
        let state = ac.learning.model.state
        let labels = ac.learning.diagnostics.acceptedLabels
        keyboard.acceptSuggestion(chip)
        XCTAssertEqual(target.text.lowercased(), "guten morgen heute ")
        keyboard.deleteBackward()
        XCTAssertEqual(target.text, touch.original)
        XCTAssertEqual(ac.learning.model.state.counts, state.counts)
        XCTAssertEqual(ac.learning.model.state.layouts, state.layouts)
        XCTAssertEqual(ac.learning.diagnostics.acceptedLabels, labels)
        XCTAssertEqual(ac.boundaryRejectionCount, 1)
        // Manual boundary undo retains its existing RAM-only veto, not inferred
        // phrase learning. R2-3's automatic undo/pair path is deliberately unchanged.
        var builder = ProtectedPersonalLexicon.Builder()
        builder.add(touch.original)
        ac.loadProtectedLexicon(builder.build())
        installMultipart(touch, in: ac)
        keyboard.refreshSuggestions()
        await keyboard.waitForSuggestions()
        XCTAssertFalse(keyboard.suggestions.contains { $0.boundary != nil })
        ac.loadProtectedLexicon(.empty)
        let trusted = engine(sources, trusted: [touch.original])
        installMultipart(touch, in: trusted)
        XCTAssertFalse(strip(trusted, touch.original).contains { $0.boundary != nil })
        print("EVAL R2_6_learning undo_steps=1 literal_restored=true inferred_labels=0 inferred_counts=0 persistent_phrase_pairs=0 ram_rejection_pairs=1 imported_and_dictionary_veto=true")
    }

    func testMultipartAdversarialBoundsAndLiteralTouchControls() throws {
        let sources = try resources()
        let controls = SpatialTypoEvaluationFixtures.absent.filter { Boundary.isEligible($0) }
        var falseChips = 0, falseAutos = 0, visits = 0, exhausted = 0
        let ac = engine(sources)
        for (index, text) in controls.enumerated() where EvaluationSample.includes(index, every: 10) {
            let lower = text.lowercased()
            let touch = try multipartTouch(lower, aimed: lower)
            installMultipart(touch, in: ac)
            var input = job(lower)
            input.touch = touch
            let result = Boundary.retrieve(input, lexicons: sources)
            let chips = ac.suggestions(beforeInput: lower, field: .text,
                                       autocorrectionType: .default, boundaryRetrieval: result)
            // Count only NEW 3+-part chips; existing exact two-part suggestions
            // (redis, esbuild, sunhat) have their independent P5 bound.
            falseChips += chips.filter { ($0.boundary?.replacement.split(separator: " ").count ?? 0) >= 3 }.count
            falseAutos += chips.filter { $0.boundary != nil && $0.willAutoReplace }.count
        }
        for length in [6, 16, 32] {
            let text = String(repeating: "a", count: length)
            let aimed = String(repeating: "s", count: length)
            let touch = try multipartTouch(text, aimed: aimed)
            var input = job(text)
            input.touch = touch
            let result = Boundary.retrieve(input, lexicons: sources)
            visits = max(visits, result.multipartVisits)
            if result.multipartExhausted { exhausted += 1 }
            XCTAssertLessThanOrEqual(result.multipartVisits, KeyboardMultipartSegmenter.maximumVisits)
            XCTAssertLessThanOrEqual(result.multipartCachedReadings, 32 * 33 * 3)
            XCTAssertEqual(result.candidates, Boundary.retrieve(input, lexicons: sources).candidates)
        }
        XCTAssertEqual(falseChips, 0)
        XCTAssertEqual(falseAutos, 0)
        XCTAssertLessThan(KeyboardMultipartSegmenter.maximumPayloadBytes, 512 * 1_024)
        print("EVAL R2_6_literal_controls false_multipart_chips=\(falseChips) false_autos=\(falseAutos) adversarial_visits_max=\(visits) exhausted_calls=\(exhausted) payload_cap=\(KeyboardMultipartSegmenter.maximumPayloadBytes)")
    }
}
