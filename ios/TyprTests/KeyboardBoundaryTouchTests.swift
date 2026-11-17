import Foundation
import XCTest
@testable import Typr

/// Constructed public strings/coordinates only, not collected typing or Apple dictionary proof.
@MainActor
final class KeyboardBoundaryTouchTests: XCTestCase {
    typealias Boundary = KeyboardBoundaryDecoder
    typealias Language = SpatialWordDecoder.Language
    @MainActor struct Fixture {
        func resources() throws -> [Language: SpatialWordLexicon] {
            try XCTUnwrap(BundledKeyboardData.lexicons)
        }
        func job(_ token: String, previous: String? = nil,
                 languages: Set<Language> = [.german, .english]) -> Boundary.Job {
            .init(token: token, previous: previous, languages: languages, personal: .empty, kept: [])
        }
        func engine(_ sources: [Language: SpatialWordLexicon],
                    languages: Set<Language> = [.german, .english], trusted: Set<String> = []) -> AutocorrectEngine {
            let checker = KeyboardBoundaryDecoderTests.Checker(sources[.english], trusted: trusted)
            let ac = AutocorrectEngine(checker: checker, spatialDecoder: SpatialWordDecoder(lexicons: sources),
                                      contextResources: KeyboardContextResources(model: nil))
            ac.englishEnabled = languages.contains(.english)
            if languages.contains(.german) {
                let germanChecker = KeyboardBoundaryDecoderTests.Checker(sources[.german], trusted: trusted)
                ac.german = GermanAutocorrect(checker: germanChecker)
            }
            return ac
        }
    }
    let helper = Fixture()
    let grid = KeyboardLayout(width: 393)

    func word(_ text: String, layout: KeyboardLayout? = nil) throws -> KeyboardTouchWord {
        let layout = layout ?? grid
        let samples: [KeyboardTouchWord.Sample] = try text.map { letter in
            let key = try XCTUnwrap(layout.key(.character(String(letter).lowercased())))
            return .init(text: String(letter), point: CGPoint(x: key.frame.midX, y: key.frame.midY), key: key)
        }
        return KeyboardTouchWord(layout: layout, samples: samples)
    }

    func splitTouch(_ text: String, index: Int, noise: Double = 0) throws -> KeyboardBoundaryTouch {
        var current = try word(text)
        let old = current.samples[index]
        let space = try XCTUnwrap(grid.key(.space))
        let x = min(space.frame.maxX - 1, max(space.frame.minX + 1, old.key.frame.midX))
        let point = CGPoint(x: x + noise * grid.letterWidth,
                            y: space.frame.minY - 1 + noise * grid.metrics.rowGap)
        current.samples[index] = .init(text: old.text, point: point, key: old.key)
        return KeyboardBoundaryTouch(current: current)
    }

    func joinTouch(_ text: String, aimed: String, noise: Double = 0) throws -> KeyboardBoundaryTouch {
        let parts = text.split(separator: " ").map(String.init)
        let key = try XCTUnwrap(grid.key(.character(aimed)))
        let space = try XCTUnwrap(grid.key(.space))
        let point = CGPoint(x: key.frame.midX + noise * grid.letterWidth,
                            y: space.frame.minY + 1 + abs(noise) * grid.metrics.rowGap)
        return KeyboardBoundaryTouch(current: try word(parts[1]), previous: try word(parts[0]),
                                     space: .init(text: " ", point: point, key: space))
    }

    func job(_ touch: KeyboardBoundaryTouch, languages: Set<Language> = [.german, .english]) -> Boundary.Job {
        var job = helper.job(touch.current.text, previous: touch.previous?.text, languages: languages)
        job.touch = touch
        return job
    }

    func install(_ touch: KeyboardBoundaryTouch, in ac: AutocorrectEngine) {
        ac.touchInput.clear()
        var before = ""
        func append(_ sample: KeyboardTouchWord.Sample) {
            let after = before + sample.text
            ac.touchInput.append(text: sample.text, point: sample.point, key: sample.key, layout: touch.current.layout,
                                 before: before, after: after)
            before = after
        }
        for sample in touch.previous?.samples ?? [] { append(sample) }
        if let space = touch.space { append(space) }
        for sample in touch.current.samples { append(sample) }
    }

    func testSpatialHypothesesRequireRealOwnedGeometryAndProtectWholeReadings() throws {
        let sources = try helper.resources()
        let touch = try splitTouch("greatvday", index: 5)
        let recovered = Boundary.retrieve(job(touch), lexicons: sources)
        XCTAssertTrue(recovered.candidates.contains { $0.replacement == "great day" && $0.spatial })
        XCTAssertFalse(Boundary.retrieve(helper.job("greatvday"), lexicons: sources).candidates.contains {
            $0.replacement == "great day"
        })
        var withPrevious = touch
        withPrevious.previous = try word("have")
        let bar = try XCTUnwrap(grid.key(.space))
        withPrevious.space = .init(text: " ", point: CGPoint(x: bar.frame.midX, y: bar.frame.midY), key: bar)
        let currentOnly = Boundary.retrieve(job(withPrevious), lexicons: sources).candidates
        XCTAssertTrue(currentOnly.contains { $0.replacement == "great day" && $0.original == "greatvday" },
                      "A retained previous word cannot hide a current-token split or expand its owned suffix")
        let joined = try joinTouch("a out", aimed: "b")
        XCTAssertTrue(Boundary.retrieve(job(joined, languages: [.english]), lexicons: sources).candidates.contains {
            $0.replacement == "about" && $0.spatial
        })
        XCTAssertFalse(Boundary.retrieve(helper.job("out", previous: "a"), lexicons: sources).candidates.contains {
            $0.replacement == "about"
        })
        // An unknown whole is not sufficient: the competing word reading can beat the split.
        let candidate = SpatialWordDecoder.Candidate(word: "great", language: .english, score: 100,
                                                    spatialScore: 100, edit: .none, alignment: [])
        let reading = SpatialWordDecoder.Result(candidates: [candidate], literalScore: -20, literalSpatialScore: 0,
                                               literalInLexicon: false, complete: false, visits: 1, generated: 1)
        XCTAssertFalse(Boundary.retrieve(job(touch), lexicons: sources, whole: .result(reading)).candidates.contains {
            $0.replacement == "great day"
        })
        var kept = job(touch)
        kept = .init(token: kept.token, previous: nil, languages: kept.languages, personal: .empty,
                     kept: [kept.token], touch: touch)
        XCTAssertTrue(Boundary.retrieve(kept, lexicons: sources).candidates.isEmpty)
    }

    func testDensityAdjacencyAndWideLetterCalibrationCannotReachDistantKeys() throws {
        let adjacent = KeyboardBoundaryTouch.adjacentLetters(in: grid)
        XCTAssertFalse(adjacent.isEmpty)
        XCTAssertTrue(adjacent.allSatisfy { ["c", "v", "b", "n", "m"].contains($0.character!) })
        let space = try XCTUnwrap(grid.key(.space))
        let left = CGPoint(x: space.frame.minX + 2, y: space.frame.midY)
        let right = CGPoint(x: space.frame.maxX - 2, y: space.frame.midY)
        XCTAssertEqual(KeyboardBoundaryTouch.spaceDensity(left, layout: grid),
                       KeyboardBoundaryTouch.spaceDensity(right, layout: grid))
        XCTAssertNil(KeyboardBoundaryTouch.spaceDensity(CGPoint(x: 0, y: 0), layout: grid))
        let sources = try helper.resources()
        for letter in ["q", "e", "x"] {
            var current = try word("great" + letter + "day")
            let old = current.samples[5]
            current.samples[5] = .init(text: letter, point: CGPoint(x: space.frame.midX, y: space.frame.minY), key: old.key)
            var request = job(KeyboardBoundaryTouch(current: current))
            request.calibration = SpatialTouchCalibration(keys: [Character(letter): .init(offsetX: 0.5, offsetY: 0.5,
                                                                                          sigmaX: 0.5, sigmaY: 0.5)])
            XCTAssertFalse(Boundary.retrieve(request, lexicons: sources).candidates.contains { $0.spatial })
        }
        var centered = try word("greatvday")
        XCTAssertFalse(Boundary.retrieve(job(KeyboardBoundaryTouch(current: centered)), lexicons: sources)
            .candidates.contains { $0.replacement == "great day" })
        centered.learningIntact = false
        XCTAssertFalse(KeyboardBoundaryTouch(current: centered).isUsable)
    }

    func testWindowInvalidationAndCombinedCap() throws {
        let ac = helper.engine(try helper.resources())
        let touch = try joinTouch("a out", aimed: "b")
        install(touch, in: ac)
        XCTAssertEqual(ac.touchInput.boundaryEvidence(beforeInput: "a out"), touch)
        XCTAssertNil(ac.touchInput.boundaryEvidence(beforeInput: "other text"))
        install(touch, in: ac)
        ac.touchInput.deletedBackward(before: "a out", after: "a ou")
        XCTAssertNil(ac.touchInput.boundaryEvidence(beforeInput: "a ou"))
        for reset in 0..<3 {
            install(touch, in: ac)
            if reset == 0 { ac.discardEvidence() }
            if reset == 1 { ac.touchInput.clear() }
            if reset == 2 { _ = ac.touchInput.evidence(beforeInput: nil) }
            XCTAssertNil(ac.touchInput.boundaryEvidence(beforeInput: "a out"))
        }
        let long = KeyboardBoundaryTouch(current: try word(String(repeating: "a", count: 16)),
            previous: try word(String(repeating: "b", count: 16)), space: touch.space)
        XCTAssertFalse(long.isUsable, "32 combined taps includes the observed Space")
        let valid = KeyboardBoundaryTouch(current: try word(String(repeating: "a", count: 15)),
            previous: try word(String(repeating: "b", count: 16)), space: touch.space)
        XCTAssertTrue(valid.isUsable)
    }

    func tap(_ character: String, keyboard: FullKeyboardEngine, id: Int = 1, point: CGPoint? = nil) throws {
        let kind: KeyKind = character == " " ? .space : .character(character)
        let key = try XCTUnwrap(keyboard.layout.key(kind))
        let location = point ?? CGPoint(x: key.frame.midX, y: key.frame.midY)
        keyboard.touchBegan(id: id, at: location)
        keyboard.touchEnded(id: id, at: location)
    }

    func testRealSpaceRolloverTyprDoubleSpaceAndSelectionMove() async throws {
        let ac = helper.engine(try helper.resources(), languages: [.english])
        let target = FixtureTextTarget(text: "")
        target.autocapitalizationType = .some(.none)
        let keyboard = FullKeyboardEngine(target: target, autocorrect: ac)
        keyboard.configureForField()
        try tap("a", keyboard: keyboard)
        let space = try XCTUnwrap(keyboard.layout.key(.space))
        let b = try XCTUnwrap(keyboard.layout.key(.character("b")))
        try tap(" ", keyboard: keyboard, point: CGPoint(x: b.frame.midX, y: space.frame.minY + 1))
        for letter in ["o", "u", "t"] { try tap(letter, keyboard: keyboard) }
        await keyboard.waitForSuggestions()
        XCTAssertEqual(target.text, "a out")
        XCTAssertNil(ac.learning.model.state.counts["a"], "Ambiguous boundary must not prematurely count the first fragment")
        XCTAssertTrue(ac.learning.model.state.layouts.isEmpty)
        XCTAssertNotNil(ac.touchInput.boundaryEvidence(beforeInput: target.text)?.space)
        XCTAssertTrue(keyboard.suggestions.contains { $0.boundary?.replacement == "about" })
        keyboard.textDidChange()
        XCTAssertNil(ac.touchInput.boundaryEvidence(beforeInput: target.text))

        let other = FixtureTextTarget(text: "")
        other.autocapitalizationType = .some(.none)
        let k = FullKeyboardEngine(target: other, autocorrect: ac)
        k.configureForField()
        try tap("a", keyboard: k)
        k.typeSpaceFromTyprKey()
        for letter in ["o", "u", "t"] { try tap(letter, keyboard: k) }
        XCTAssertNil(ac.touchInput.boundaryEvidence(beforeInput: other.text)?.space)
        k.typeSpaceFromTyprKey()
        k.typeSpaceFromTyprKey()
        XCTAssertTrue(other.text.hasSuffix(". "))
        XCTAssertNil(ac.touchInput.boundaryEvidence(beforeInput: other.text))

        // Held letters commit in down order, with the last known point, exactly once.
        let rollover = FixtureTextTarget(text: "")
        rollover.autocapitalizationType = .some(.none)
        let r = FullKeyboardEngine(target: rollover, autocorrect: ac)
        r.configureForField()
        let a = try XCTUnwrap(r.layout.key(.character("a")))
        let p = CGPoint(x: a.frame.midX, y: a.frame.midY)
        r.touchBegan(id: 10, at: p)
        let sp = CGPoint(x: space.frame.midX, y: space.frame.midY)
        r.touchBegan(id: 11, at: sp)
        let bk = try XCTUnwrap(r.layout.key(.character("b")))
        let bp = CGPoint(x: bk.frame.midX, y: bk.frame.midY)
        r.touchBegan(id: 12, at: bp) // Commits the held real Space before b.
        r.touchEnded(id: 12, at: bp)
        r.touchEnded(id: 11, at: sp) // Must not insert a second Space.
        r.touchEnded(id: 10, at: p)
        XCTAssertEqual(rollover.text, "a b")
        XCTAssertEqual(ac.touchInput.boundaryEvidence(beforeInput: rollover.text)?.previous?.samples.count, 1)
        XCTAssertEqual(ac.touchInput.boundaryEvidence(beforeInput: rollover.text)?.space?.point, sp)
    }

    func testEndpointAbstentionAndRetainedWindowDiscontinuities() throws {
        let sources = try helper.resources()
        for (text, index) in [("vgreatday", 0), ("greatdayv", 8)] {
            let touch = try splitTouch(text, index: index)
            XCTAssertFalse(Boundary.retrieve(job(touch), lexicons: sources).candidates.contains { $0.spatial },
                           "Endpoint letters are not two nonempty words")
        }
        let touch = try joinTouch("a out", aimed: "b")
        for action in 0..<5 {
            let ac = helper.engine(sources, languages: [.english])
            let target = FixtureTextTarget(text: touch.original)
            let keyboard = FullKeyboardEngine(target: target, autocorrect: ac)
            keyboard.width = grid.width
            keyboard.configureForField()
            install(touch, in: ac)
            XCTAssertNotNil(ac.touchInput.boundaryEvidence(beforeInput: target.text)?.space)
            let t = try XCTUnwrap(keyboard.layout.key(.character("t")))
            let point = CGPoint(x: t.frame.midX, y: t.frame.midY)
            keyboard.touchBegan(id: 99, at: point)
            switch action {
            case 0: keyboard.textDidChange() // Host selection/text callback.
            case 1: keyboard.discardTouchEvidence() // Memory warning/lifecycle adapter.
            case 2: keyboard.configureForField()
            case 3: keyboard.width += 8
            default: keyboard.cancelAllTouches()
            }
            keyboard.touchEnded(id: 99, at: point)
            XCTAssertNil(ac.touchInput.boundaryEvidence(beforeInput: target.text))
        }
        // No initial/final fragment is fabricated from a leading/trailing Space. In
        // particular a second Space keeps double-space-period, not inferred final b/m/n.
        let ac = helper.engine(sources, languages: [.english])
        install(touch, in: ac)
        XCTAssertNil(ac.touchInput.boundaryEvidence(beforeInput: "a "))
        XCTAssertNil(ac.touchInput.boundaryEvidence(beforeInput: " out")?.space)
    }

    func testSparseAndCalibratedLettersKeepSpacePriorStaticAndLearningOffWorks() throws {
        let sources = try helper.resources()
        let touch = try joinTouch("a out", aimed: "b")
        let point = try XCTUnwrap(touch.space?.point)
        let prior = KeyboardBoundaryTouch.spaceDensity(point, layout: grid)
        var request = job(touch, languages: [.english])
        let sparse = Boundary.retrieve(request, lexicons: sources)
        request.calibration = SpatialTouchCalibration(keys: ["b": .init(offsetX: 0, offsetY: 0.1,
                                                                        sigmaX: 0.28, sigmaY: 0.4)])
        let calibrated = Boundary.retrieve(request, lexicons: sources)
        XCTAssertTrue(sparse.candidates.contains { $0.replacement == "about" })
        XCTAssertTrue(calibrated.candidates.contains { $0.replacement == "about" })
        XCTAssertEqual(prior, KeyboardBoundaryTouch.spaceDensity(point, layout: grid))
        let ac = helper.engine(sources, languages: [.english])
        ac.learning.model.isLearningEnabled = false
        install(touch, in: ac)
        XCTAssertTrue(ac.suggestions(beforeInput: touch.original, field: .text, autocorrectionType: .default)
            .contains { $0.boundary?.replacement == "about" })
        print("EVAL P6_density sparse_recall=1 calibrated_letter_recall=1 space_training=none static_space_prior_unchanged=true learning_off_recall=1")
    }

    func testRetainedRealSpacePreservesSettledPersonalPairs() throws {
        let sources = try helper.resources()
        let fixtures: [(String, String, Set<Language>)] = [
            ("hello", "world", [.english]),
            ("guten", "morgen", [.german]),
            ("meine", "coffee", [.german, .english])
        ]
        for (first, second, languages) in fixtures {
            for realSpace in [true, false] {
                let ac = helper.engine(sources, languages: languages, trusted: [first, second])
                let target = FixtureTextTarget(text: "")
                target.autocapitalizationType = .some(.none)
                let keyboard = FullKeyboardEngine(target: target, autocorrect: ac)
                keyboard.width = grid.width
                keyboard.configureForField()
                for letter in first { try tap(String(letter), keyboard: keyboard) }
                if realSpace { try tap(" ", keyboard: keyboard) } else { keyboard.typeSpaceFromTyprKey() }
                for letter in second { try tap(String(letter), keyboard: keyboard) }
                XCTAssertEqual(ac.learning.previousTrustedWord, first)
                XCTAssertEqual(ac.learning.personalBigrams.pairCount, 0, "Follower must settle independently")
                let boundary = ac.touchInput.boundaryEvidence(beforeInput: target.text)
                XCTAssertEqual(boundary?.space != nil, realSpace, "Only real Space retains geometry")
                if realSpace { try tap(" ", keyboard: keyboard) } else { keyboard.typeSpaceFromTyprKey() }
                XCTAssertEqual(ac.learning.previousTrustedWord, first, "An ordinary boundary preserves adjacency")
                XCTAssertEqual(ac.learning.personalBigrams.pairCount, 0)
                try tap("n", keyboard: keyboard)
                XCTAssertEqual(ac.learning.personalBigrams.followers(after: first), [second: 1])
                XCTAssertEqual(ac.learning.previousTrustedWord, second)
            }
        }
        print("EVAL M6_settlement language_buckets=3 separator_modes=2 settled_pairs=6 premature_pairs=0 fabricated_spaces=0")
    }

    func testSpatialRecoveryPickAndUndoNeverSupplyPersonalPairEndpoints() async throws {
        let sources = try helper.resources()
        let fixtures = [try splitTouch("greatvday", index: 5), try joinTouch("a out", aimed: "b")]
        for touch in fixtures {
            for undo in [false, true] {
                let ac = helper.engine(sources, languages: [.english], trusted: ["hello", "next"])
                let target = FixtureTextTarget(text: "")
                target.autocapitalizationType = .some(.none)
                let keyboard = FullKeyboardEngine(target: target, autocorrect: ac)
                keyboard.width = grid.width
                keyboard.configureForField()
                for letter in "hello " { try tap(String(letter), keyboard: keyboard) }
                var samples = touch.previous?.samples ?? []
                if let space = touch.space { samples.append(space) }
                samples.append(contentsOf: touch.current.samples)
                for sample in samples {
                    let center = CGPoint(x: sample.key.frame.midX, y: sample.key.frame.midY)
                    keyboard.touchBegan(id: 1, at: center)
                    keyboard.touchEnded(id: 1, at: sample.point)
                }
                XCTAssertEqual(target.text, "hello " + touch.original)
                let captured = try XCTUnwrap(ac.touchInput.boundaryEvidence(beforeInput: target.text))
                XCTAssertEqual(captured.current, touch.current)
                if touch.space != nil {
                    XCTAssertEqual(captured.previous, touch.previous)
                    XCTAssertEqual(captured.space, touch.space)
                    XCTAssertNil(ac.learning.previousTrustedWord, "Ambiguous Space breaks the earlier pair chain")
                    XCTAssertNil(ac.learning.model.state.counts["a"])
                } else {
                    XCTAssertEqual(ac.learning.previousTrustedWord, "hello")
                }
                await keyboard.waitForSuggestions()
                let chip = try XCTUnwrap(keyboard.suggestions.first { $0.boundary?.spatial == true })
                let state = ac.learning.model.state
                let labels = ac.learning.diagnostics.acceptedLabels
                keyboard.acceptSuggestion(chip)
                XCTAssertEqual(target.text, "hello " + chip.replacement + " ")
                XCTAssertNil(ac.learning.previousTrustedWord)
                XCTAssertEqual(ac.learning.personalBigrams, state.bigrams ?? .init())
                XCTAssertEqual(ac.learning.model.state.counts, state.counts)
                XCTAssertEqual(ac.learning.model.state.layouts, state.layouts)
                XCTAssertEqual(ac.learning.diagnostics.acceptedLabels, labels)
                if undo {
                    keyboard.deleteBackward()
                    XCTAssertEqual(target.text, "hello " + touch.original)
                    keyboard.typeSpaceFromTyprKey()
                }
                for letter in "next n" { try tap(String(letter), keyboard: keyboard) }
                XCTAssertEqual(ac.learning.personalBigrams, state.bigrams ?? .init())
                XCTAssertEqual(ac.learning.model.state.counts["about"], state.counts["about"])
                XCTAssertEqual(ac.learning.model.state.counts["great"], state.counts["great"])
                XCTAssertEqual(ac.learning.model.state.counts["day"], state.counts["day"])
                XCTAssertEqual(ac.learning.previousTrustedWord, "next", "A later independent word starts a fresh chain")
                // Only the independently typed `next` may supply new labels, never the recovered suffix.
                let nextLabels = ac.learning.diagnostics.acceptedLabels - labels
                XCTAssertEqual(nextLabels, 4)
            }
        }
        print("EVAL M6_recovery cases=4 inferred_pairs=0 inferred_word_counts=0 inferred_touch_labels=0 undo_steps=1")
    }

    func testWorkerPickOneStepUndoAndNoBoundaryTraining() async throws {
        let sources = try helper.resources()
        for touch in [try splitTouch("greatvday", index: 5), try joinTouch("a out", aimed: "b")] {
            let ac = helper.engine(sources, languages: [.english])
            let target = FixtureTextTarget(text: touch.original)
            let keyboard = FullKeyboardEngine(target: target, autocorrect: ac)
            keyboard.width = grid.width
            keyboard.configureForField()
            install(touch, in: ac)
            keyboard.refreshSuggestions()
            await keyboard.waitForSuggestions()
            let chip = try XCTUnwrap(keyboard.suggestions.first { $0.boundary?.spatial == true }, touch.original)
            let state = ac.learning.model.state
            let labels = ac.learning.diagnostics.acceptedLabels
            keyboard.acceptSuggestion(chip)
            XCTAssertEqual(target.text, chip.replacement + " ")
            XCTAssertEqual(ac.learning.model.state.counts, state.counts)
            XCTAssertEqual(ac.learning.model.state.layouts, state.layouts)
            keyboard.deleteBackward()
            XCTAssertEqual(target.text, touch.original)
            XCTAssertEqual(ac.learning.diagnostics.acceptedLabels, labels)
            XCTAssertTrue(ac.learning.model.state.rejected.isEmpty)
            XCTAssertNil(ac.touchInput.boundaryEvidence(beforeInput: target.text))
            keyboard.textDidChange()
            target.insertText("x")
            keyboard.acceptSuggestion(chip)
            XCTAssertEqual(target.text, touch.original + "x")
            print("EVAL P6_learning kind=\(chip.boundary!.kind) label_delta=0 count_delta=0 undo_steps=1 stale_edits=0")
        }
    }
}
