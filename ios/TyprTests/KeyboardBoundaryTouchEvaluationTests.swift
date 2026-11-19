import Foundation
import XCTest
@testable import Typr

extension KeyboardBoundaryTouchTests {
    struct Case {
        let observed: String
        let expected: String
        let index: Int?
        let aimed: String
    }

    func testNoisyBoundaryEvaluationByLanguageAndCase() throws {
        let sources = try helper.resources()
        let splitEN = [Case(observed: "greatvday", expected: "great day", index: 5, aimed: "v"),
                       Case(observed: "goodnmorning", expected: "good morning", index: 4, aimed: "n")]
        let splitDE = [Case(observed: "ichvhabe", expected: "ich habe", index: 3, aimed: "v"),
                       Case(observed: "gutenvmorgen", expected: "guten morgen", index: 5, aimed: "v"),
                       Case(observed: "ichnhabe", expected: "ich habe", index: 3, aimed: "n"),
                       Case(observed: "gutenmmorgen", expected: "guten morgen", index: 5, aimed: "m")]
        let splitMixed = [Case(observed: "bittevwait", expected: "bitte wait", index: 5, aimed: "v"),
                          Case(observed: "greatntag", expected: "great tag", index: 5, aimed: "n")]
        let joinEN = [Case(observed: "a out", expected: "about", index: nil, aimed: "b"),
                      Case(observed: "ne er", expected: "never", index: nil, aimed: "v")]
        let joinDE = [Case(observed: "le en", expected: "leben", index: nil, aimed: "b"),
                      Case(observed: "ha en", expected: "haben", index: nil, aimed: "b")]
        let extraEN = [Case(observed: "keyb oard", expected: "keyboard", index: nil, aimed: "b")]
        let extraDE = [Case(observed: "Tasta tur", expected: "tastatur", index: nil, aimed: "b")]
        let groups: [(String, Set<Language>, [(String, [Case])])] = [
            ("EN", [.english], [("letter_space", splitEN), ("space_letter", joinEN), ("extra_space", extraEN)]),
            ("DE", [.german], [("letter_space", splitDE), ("space_letter", joinDE), ("extra_space", extraDE)]),
            ("mixed", [.german, .english], [("letter_space", splitMixed), ("space_letter", joinEN + joinDE),
                                            ("extra_space", extraEN + extraDE)])
        ]
        let noise: [Double] = [-0.08, 0, 0.08]
        for (language, languages, kinds) in groups {
            let ac = helper.engine(sources, languages: languages)
            for (kind, cases) in kinds {
                var count = 0, recall1 = 0, recall3 = 0, chipRecall = 0, baseline3 = 0, automatic = 0, wrongAutomatic = 0
                var maximumQueries = 0, maximumBytes = 0
                var times: [Double] = []
                for fixture in cases {
                    for jitter in noise {
                        let touch: KeyboardBoundaryTouch
                        if let index = fixture.index {
                            touch = try splitTouch(fixture.observed, index: index, noise: jitter)
                        } else {
                            touch = try joinTouch(fixture.observed, aimed: fixture.aimed, noise: jitter)
                        }
                        let request = job(touch, languages: languages)
                        let start = ProcessInfo.processInfo.systemUptime
                        let result = Boundary.retrieve(request, lexicons: sources)
                        times.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
                        let replacements = result.candidates.map(\.replacement)
                        if replacements.first == fixture.expected { recall1 += 1 }
                        if replacements.contains(fixture.expected) { recall3 += 1 }
                        var baseline = request
                        baseline.touch = nil; baseline.calibration = nil
                        if Boundary.retrieve(baseline, lexicons: sources).candidates.contains(where: {
                            $0.replacement == fixture.expected
                        }) { baseline3 += 1 }
                        install(touch, in: ac)
                        let suggestions = ac.suggestions(beforeInput: fixture.observed, field: .text,
                                                         autocorrectionType: .default)
                        if suggestions.contains(where: { $0.replacement.lowercased() == fixture.expected }) { chipRecall += 1 }
                        let autos = suggestions.filter { $0.boundary != nil && $0.willAutoReplace }
                        automatic += autos.count
                        wrongAutomatic += autos.filter { $0.replacement.lowercased() != fixture.expected }.count
                        maximumQueries = max(maximumQueries, result.lexicalQueries)
                        maximumBytes = max(maximumBytes, touch.payloadBytes)
                        XCTAssertEqual(result.candidates, Boundary.retrieve(request, lexicons: sources).candidates)
                        XCTAssertLessThanOrEqual(result.lexicalQueries, Boundary.maximumLexicalQueries)
                        XCTAssertLessThanOrEqual(result.candidates.count, Boundary.resultLimit)
                        XCTAssertLessThanOrEqual(touch.payloadBytes, KeyboardBoundaryTouch.maximumPayloadBytes)
                        count += 1
                    }
                }
                times.sort()
                let p50 = times[times.count / 2], p95 = times[min(times.count - 1, times.count * 95 / 100)]
                let ratio1 = Double(recall1) / Double(count), ratio3 = Double(recall3) / Double(count)
                print("EVAL P6_quality language=\(language) kind=\(kind) n=\(count) recall1=\(ratio1) recall3=\(ratio3) chip_recall3=\(Double(chipRecall) / Double(count)) baseline_recall3=\(Double(baseline3) / Double(count)) boundary_autos=\(automatic) wrong_autos=\(wrongAutomatic) p50_ms=\(p50) p95_ms=\(p95) max_ms=\(times.last!) lexical_queries_max=\(maximumQueries) touch_bytes_max=\(maximumBytes)")
                XCTAssertGreaterThanOrEqual(recall3, baseline3)
                let minimum = kind == "letter_space" ? count / 2 : count
                XCTAssertGreaterThanOrEqual(recall1, minimum, "\(language)/\(kind) rank-one regression")
                XCTAssertGreaterThanOrEqual(recall3, minimum, "\(language)/\(kind) retrieval regression")
                XCTAssertGreaterThanOrEqual(chipRecall, minimum, "\(language)/\(kind) chip regression")
                XCTAssertEqual(wrongAutomatic, 0)
            }
        }
    }

    func testValidPairControlsAndSuggestedOnlyAutomaticGate() throws {
        let sources = try helper.resources()
        let groups: [(String, Set<Language>, [String])] = [
            ("EN", [.english], ["a day", "a man", "some thing", "in side", "a bout", "in put", "we can", "Ann May",
                                 "home work", "code review", "out put", "a out"]),
            ("DE", [.german], ["am ende", "in der", "an dem", "das ist", "ich bin", "Anna Mai", "Haus Bau",
                                "Kinder Garten", "mit dir", "um das", "bei der", "im Haus"]),
            ("mixed", [.german, .english], ["bitte wait", "great Tag", "mit you", "mein code", "der build", "we gehen",
                                            "Anna day", "Haus work", "im office", "das meeting", "a Haus", "in Berlin"])
        ]
        for imported in [false, true] {
        for (language, languages, controls) in groups {
            let trusted = Set(controls.flatMap { $0.lowercased().split(separator: " ").map(String.init) })
            let ac = helper.engine(sources, languages: languages, trusted: trusted)
            if imported {
                var builder = ProtectedPersonalLexicon.Builder()
                builder.add("Ann May Anna Mai Berlin")
                ac.loadProtectedLexicon(builder.build())
            }
            var falseChips = 0, autos = 0, calls = 0
            for text in controls {
                // Normal Space centre plus top-edge adversarial points, with both words valid.
                // Only a tap that fits a letter better than Space may join two valid words.
                for topEdge in [false, true] {
                    var touch = try joinTouch(text, aimed: "b")
                    if !topEdge {
                        let space = try XCTUnwrap(grid.key(.space))
                        touch.space = .init(text: " ", point: CGPoint(x: space.frame.midX, y: space.frame.midY), key: space)
                    }
                    install(touch, in: ac)
                    let chips = ac.suggestions(beforeInput: text, field: .text, autocorrectionType: .default)
                    falseChips += chips.filter { $0.boundary != nil }.count
                    let applied = ac.replacementOnSpace(beforeInput: text, field: .text, autocorrectionType: .default)
                    if !topEdge {
                        autos += chips.filter { $0.boundary != nil && $0.willAutoReplace }.count
                        XCTAssertNil(applied, text)
                    } else if let applied {
                        XCTAssertEqual(applied.replacement, "about", text)
                    }
                    calls += 1
                }
            }
            // The deliberately ambiguous valid "a out" offers and, as iikb, applies "about" when
            // the tap lies on b's edge rather than the Space bar. State the bound.
            let chipBound = language == "EN" ? 1 : 0
            print("EVAL P6_controls personal_lexicon=\(imported) language=\(language) n=\(calls) false_boundary_chips=\(falseChips) false_boundary_chip_bound=\(chipBound) false_automatic_changes_space_centre=\(autos) automatic_policy=tap_evidence")
            XCTAssertLessThanOrEqual(falseChips, chipBound)
            XCTAssertEqual(autos, 0)
        }
        }
        print("EVAL P6_bounds combined_taps=\(KeyboardBoundaryTouch.maxSamples) touch_payload_cap=\(KeyboardBoundaryTouch.maximumPayloadBytes) candidates=\(Boundary.resultLimit) lexical_queries=\(Boundary.maximumLexicalQueries) trie_edge_checks=\(Boundary.maximumTrieEdgeChecks) candidate_payload=\(Boundary.maximumCandidatePayloadBytes) queued_jobs=1 running_jobs=1 inferred_boundary_training=0")
    }
}
