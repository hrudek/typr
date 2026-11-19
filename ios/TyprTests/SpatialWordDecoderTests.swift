import UIKit
import XCTest
@testable import Typr

@MainActor
final class SpatialWordDecoderTests: XCTestCase {
    private func layout(width: CGFloat = 393, strip: Bool = true) -> KeyboardLayout {
        KeyboardLayout(width: width, orientation: .portrait, layer: .letters, field: .text,
                       showsGlobe: false, showsStrip: strip)
    }

    private func evidence(_ text: String, aimedAt: String, layout: KeyboardLayout? = nil) -> KeyboardTouchWord {
        let grid = layout ?? self.layout()
        let samples = zip(text, aimedAt).map { typed, aimed in
            let key = grid.key(.character(String(typed).lowercased()))!
            let destination = grid.key(.character(String(aimed).lowercased()))!.frame
            return KeyboardTouchWord.Sample(text: String(typed),
                                            point: CGPoint(x: destination.midX, y: destination.midY), key: key)
        }
        return KeyboardTouchWord(layout: grid, samples: samples)
    }

    // Small TSW1 fixture writer, independent of the production Python compiler.
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
        func append(_ value: UInt32, to data: inout Data) {
            for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        var index = 0
        while index < nodes.count {
            let (label, node) = nodes[index]
            let children = node.children.sorted { $0.key < $1.key }
            let first = children.isEmpty ? 0 : nodes.count
            records.append(contentsOf: [UInt8(label), UInt8(children.count), 0, 0])
            append(UInt32(first), to: &records)
            append(node.count, to: &records)
            nodes.append(contentsOf: children.map { ($0.key, $0.value) })
            index += 1
        }
        var bytes = Data("TSW1".utf8)
        append(UInt32(nodes.count), to: &bytes)
        append(UInt32(words.count), to: &bytes)
        append(0, to: &bytes)
        append(words.reduce(0) { $0 + $1.1 }, to: &bytes)
        append(0, to: &bytes)
        bytes.append(records)
        return SpatialWordLexicon(data: bytes)!
    }

    private func decoder() -> SpatialWordDecoder {
        SpatialWordDecoder(lexicons: [
            .english: lexicon([("hello", 100), ("jello", 100), ("world", 100), ("house", 100)]),
            .german: lexicon([("hallo", 100), ("hause", 100), ("straße", 100), ("grüße", 100)])
        ])
    }

    func testSameLiteralDifferentPointsProduceDifferentWords() {
        let decoder = self.decoder()
        XCTAssertEqual(decoder.decode(evidence("uello", aimedAt: "hello"), languages: [.english])?.automaticCandidate?.word, "hello")
        XCTAssertEqual(decoder.decode(evidence("uello", aimedAt: "jello"), languages: [.english])?.automaticCandidate?.word, "jello")
        XCTAssertNil(decoder.decode(evidence("uello", aimedAt: "uello"), languages: [.english])?.automaticCandidate)
    }

    func testLanguageSelectionAndMissingResourceFallback() {
        let word = evidence("hslko", aimedAt: "hallo")
        XCTAssertEqual(decoder().decode(word, languages: [.german])?.automaticCandidate?.word, "hallo")
        XCTAssertFalse(decoder().decode(word, languages: [.english])?.candidates.contains { $0.word == "hallo" } ?? false)
        XCTAssertNil(decoder().decode(word, languages: []))
        let onlyEnglish = SpatialWordDecoder(lexicons: [.english: lexicon([("hello", 100)])])
        XCTAssertNil(onlyEnglish.decode(word, languages: [.english, .german]))
    }

    func testUmlautsArePreservedNotASCIIExpanded() {
        let source = lexicon([("straße", 10), ("grüße", 20), ("für", 30)])
        XCTAssertNotNil(source.logPrior(for: "straße"))
        XCTAssertNotNil(source.logPrior(for: "grüße"))
        XCTAssertNil(source.logPrior(for: "strasse"))
        // ß shares s's physical holder density; no popup center is invented.
        XCTAssertTrue(decoder().decode(evidence("strase", aimedAt: "strase"), languages: [.german])?.suggestions.contains { $0.word == "straße" } ?? false)
    }

    func testDeterminismBudgetAndLengthBounds() {
        let decoder = self.decoder()
        let word = evidence("gello", aimedAt: "hello")
        let expected = decoder.decode(word, languages: [.german, .english])?.candidates.map(\.word)
        for _ in 0..<10 {
            XCTAssertEqual(decoder.decode(word, languages: [.english, .german])?.candidates.map(\.word), expected)
        }
        let truncated = decoder.decode(word, languages: [.english], budget: 1)
        XCTAssertEqual(truncated?.complete, false)
        XCTAssertNil(truncated?.automaticCandidate)
        XCTAssertEqual(truncated?.visits, 1)
        XCTAssertNil(decoder.decode(evidence("hi", aimedAt: "hi"), languages: [.english]))
        let long = String(repeating: "a", count: 33)
        XCTAssertNil(decoder.decode(evidence(long, aimedAt: long), languages: [.english]))
    }

    func testGeometryUsesCapturedWidthAndStripOffset() {
        for width in [CGFloat(320), 393, 440] {
            for strip in [false, true] {
                let word = evidence("gello", aimedAt: "hello", layout: layout(width: width, strip: strip))
                XCTAssertEqual(decoder().decode(word, languages: [.english])?.automaticCandidate?.word, "hello")
            }
        }
    }

    func testMalformedResourcesAndNonfiniteEvidenceFallBack() {
        XCTAssertNil(SpatialWordLexicon(data: Data()))
        var bytes = lexicon([("hello", 100)]).data
        bytes.removeLast()
        XCTAssertNil(SpatialWordLexicon(data: bytes))
        bytes = lexicon([("hello", 100)]).data
        bytes[28] = 255 // invalid first-child index in root
        XCTAssertNil(SpatialWordLexicon(data: bytes))
        var word = evidence("gello", aimedAt: "hello")
        let first = word.samples[0]
        word.samples[0] = .init(text: first.text, point: CGPoint(x: CGFloat.nan, y: 0), key: first.key)
        XCTAssertNil(decoder().decode(word, languages: [.english]))
    }

    private func engine(valid: Set<String> = ["hello", "jello"], germanGuesses: [String] = []) -> AutocorrectEngine {
        let checker = SpatialChecker(valid: valid)
        let engine = AutocorrectEngine(checker: checker, learning: KeyboardLearningSession(), spatialDecoder: decoder())
        if !germanGuesses.isEmpty {
            engine.german = GermanAutocorrect(checker: SpatialChecker(valid: Set(germanGuesses), guesses: germanGuesses))
        }
        return engine
    }

    private func track(_ word: KeyboardTouchWord, in engine: AutocorrectEngine) {
        var before = ""
        for sample in word.samples {
            let after = before + sample.text
            engine.touchInput.append(text: sample.text, point: sample.point, key: sample.key,
                                     layout: word.layout, before: before, after: after)
            before = after
        }
    }

    private func replacement(_ engine: AutocorrectEngine, _ token: String = "gello") -> String? {
        engine.replacementOnSpace(beforeInput: token, field: .text, autocorrectionType: .default)?.replacement
    }

    func testIntegrationSlotsSpaceAndNoEvidenceFallback() {
        let engine = self.engine()
        XCTAssertNil(replacement(engine))
        track(evidence("gello", aimedAt: "hello"), in: engine)
        let slots = engine.suggestions(beforeInput: "gello", field: .text, autocorrectionType: .default)
        XCTAssertEqual(slots.first?.replacement, "gello")
        XCTAssertEqual(slots.dropFirst().first?.replacement, "hello")
        XCTAssertTrue(slots.dropFirst().first?.willAutoReplace ?? false)
        XCTAssertEqual(replacement(engine), "hello")
        engine.touchInput.clear()
        XCTAssertNil(replacement(engine))
    }

    func testValidLiteralKeepAndLanguageOffBlockAutomaticReplacement() {
        let valid = engine(valid: ["gello", "hello", "jello"])
        track(evidence("gello", aimedAt: "hello"), in: valid)
        XCTAssertNil(replacement(valid))
        let kept = engine()
        track(evidence("gello", aimedAt: "hello"), in: kept)
        kept.suppressAndKeep("gello")
        XCTAssertNil(replacement(kept))
        let disabled = engine()
        track(evidence("gello", aimedAt: "hello"), in: disabled)
        disabled.englishEnabled = false
        XCTAssertNil(replacement(disabled))
        disabled.englishEnabled = true
        disabled.isEnabled = false
        XCTAssertNil(replacement(disabled))
        disabled.isEnabled = true
        XCTAssertNil(disabled.replacementOnSpace(beforeInput: "gello", field: .email, autocorrectionType: .default))
        XCTAssertNil(disabled.replacementOnSpace(beforeInput: "gello", field: .text, autocorrectionType: .no))
    }

    func testGermanRequiresCanonicalSpellingForAutomaticReplacement() {
        let engine = self.engine(germanGuesses: ["Hallo"])
        engine.englishEnabled = false
        track(evidence("hslko", aimedAt: "hallo"), in: engine)
        XCTAssertEqual(replacement(engine, "hslko"), "Hallo")
        engine.german = GermanAutocorrect(checker: SpatialChecker(valid: ["hallo"]))
        XCTAssertNil(replacement(engine, "hslko"), "lowercase frequency entry alone cannot establish noun casing")
    }

    func testAmbiguityAndAcronymsNeverBecomeNewAutomaticFixes() {
        let decoder = self.decoder()
        var word = evidence("uello", aimedAt: "hello")
        let h = word.layout.key(.character("h"))!.frame
        let j = word.layout.key(.character("j"))!.frame
        let sample = word.samples[0]
        word.samples[0] = .init(text: sample.text, point: CGPoint(x: (h.midX + j.midX) / 2, y: h.midY), key: sample.key)
        let result = decoder.decode(word, languages: [.english])
        XCTAssertEqual(result?.candidates.prefix(2).map(\.word), ["hello", "jello"])
        XCTAssertNil(result?.automaticCandidate)
        let engine = self.engine()
        track(word, in: engine)
        XCTAssertNil(replacement(engine, "uello"))
        engine.touchInput.clear()
        track(evidence("GELLO", aimedAt: "hello"), in: engine)
        XCTAssertNil(replacement(engine, "GELLO"))
    }

    func testSpaceUndoAndManualSuggestionKeepExistingLifecycle() async throws {
        let ac = engine()
        let target = FixtureTextTarget(text: "gello")
        target.autocapitalizationType = UITextAutocapitalizationType.none
        let keyboard = FullKeyboardEngine(target: target, autocorrect: ac)
        keyboard.width = 393
        keyboard.configureForField()
        track(evidence("gello", aimedAt: "hello", layout: keyboard.layout), in: ac)
        keyboard.typeSpaceFromTyprKey()
        XCTAssertEqual(target.text, "hello ")
        XCTAssertNil(ac.touchInput.evidence(beforeInput: target.text))
        let delete = try XCTUnwrap(keyboard.layout.key(.delete)).frame
        let point = CGPoint(x: delete.midX, y: delete.midY)
        keyboard.touchBegan(id: 1, at: point)
        keyboard.touchEnded(id: 1, at: point)
        XCTAssertEqual(target.text, "gello")
        XCTAssertEqual(ac.learning.diagnostics[.undoSpatial], 1)
        XCTAssertFalse(ac.learning.model.lexicon.isKept("gello"), "Undo does not permanently keep the literal")
        XCTAssertTrue(ac.learning.model.lexicon.isRejected(typed: "gello", replacement: "hello"))
        // Adjacent g/h centres are exactly one pitch apart, accepted at the inclusive
        // boundary on both platforms (not an outlier, despite floating-point rounding).
        XCTAssertEqual(ac.learning.diagnostics.acceptedBySource["undo"], 5)
        XCTAssertNil(ac.learning.diagnostics.rejectedByReason["outlier"])
        XCTAssertNil(replacement(ac), "undo suppresses a repeated automatic replacement")

        let manual = engine()
        let manualTarget = FixtureTextTarget(text: "gello")
        let manualKeyboard = FullKeyboardEngine(target: manualTarget, autocorrect: manual)
        manualKeyboard.width = 393
        manualKeyboard.configureForField()
        track(evidence("gello", aimedAt: "hello", layout: manualKeyboard.layout), in: manual)
        manualKeyboard.refreshSuggestions()
        await manualKeyboard.waitForSuggestions()
        let suggestion = try XCTUnwrap(manualKeyboard.suggestions.first { $0.replacement == "hello" })
        manualKeyboard.acceptSuggestion(suggestion)
        XCTAssertEqual(manualTarget.text, "hello ")
        XCTAssertEqual(manual.learning.diagnostics[.manualAlternativePick], 1)
        XCTAssertEqual(manual.learning.model.lexicon.counts["hello"], 1)
        XCTAssertEqual(manual.learning.diagnostics.acceptedBySource["manualPick"], 5)
        XCTAssertNil(manual.touchInput.evidence(beforeInput: manualTarget.text))
    }

    func testPriorPromotedGeometricallyWorseNeighbourDoesNotVetoSpellingFallback() throws {
        let source = SpatialWordDecoder(lexicons: [.english: lexicon([("help", 10_000_000), ("hello", 1)])])
        let word = evidence("helo", aimedAt: "helo")
        let result = try XCTUnwrap(source.decode(word, languages: [.english]))
        XCTAssertEqual(result.candidates.first?.word, "help")
        XCTAssertFalse(result.geometryPrefersAlternative)
        XCTAssertNil(result.automaticCandidate)
        let ac = AutocorrectEngine(checker: SpatialChecker(valid: ["hello", "help"], guesses: ["hello"]),
                                   spatialDecoder: source)
        track(word, in: ac)
        XCTAssertEqual(replacement(ac, "helo"), "hello")
        XCTAssertEqual(ac.learning.diagnostics[.autoSpellingFallback], 1)
    }

    func testEditAutomaticCandidatePrecedesDifferentSpellingGuess() throws {
        let source = SpatialWordDecoder(lexicons: [.english: lexicon([("hello", 4_000_000_000), ("world", 1)])])
        for typed in ["helo", "helllo", "hlelo"] {
            var word = evidence(typed, aimedAt: typed)
            if typed == "helllo" {
                // A stray tap away from the key centre; no real/user samples.
                let sample = word.samples[2]
                let frame = sample.key.frame
                let pitchX = frame.width + word.layout.metrics.gap
                let pitchY = frame.height + word.layout.metrics.rowGap
                word.samples[2] = .init(text: sample.text,
                    point: CGPoint(x: frame.midX + pitchX * 0.45, y: frame.midY + pitchY * 0.45), key: sample.key)
            }
            let result = try XCTUnwrap(source.decode(word, languages: [.english]))
            XCTAssertEqual(result.automaticCandidate?.word, "hello", typed)
            let ac = AutocorrectEngine(checker: SpatialChecker(valid: ["hello", "help"], guesses: ["help"]),
                                       spatialDecoder: source)
            track(word, in: ac)
            XCTAssertEqual(replacement(ac, typed), "hello", typed)
            XCTAssertEqual(ac.learning.diagnostics[.autoSpatialEdit], 1, typed)
            ac.settleFeedback(beforeInput: "hello ", insertedLetter: "w", afterInput: "hello w")
            XCTAssertTrue(ac.learning.model.lexicon.counts.isEmpty)
            XCTAssertEqual(ac.learning.diagnostics.acceptedLabels, 0)
        }
    }

    func testSuggestionDecodeCacheAndBoundaryLatencyAreIndependent() {
        let ac = engine()
        for text in ["g", "ge"] {
            ac.touchInput.clear()
            track(evidence(text, aimedAt: text), in: ac)
            _ = ac.suggestions(beforeInput: text, field: .text, autocorrectionType: .default)
        }
        XCTAssertEqual(ac.learning.diagnostics[.suggestionDecodes], 0, "Evidence refusals are not searches")
        XCTAssertEqual(ac.learning.diagnostics.suggestionMs.reduce(0, +), 0)
        ac.touchInput.clear()
        track(evidence("gello", aimedAt: "hello"), in: ac)
        for _ in 0..<5 {
            _ = ac.suggestions(beforeInput: "gello", field: .text, autocorrectionType: .default)
        }
        XCTAssertEqual(ac.learning.diagnostics[.suggestionDecodes], 1)
        XCTAssertEqual(ac.learning.diagnostics.suggestionMs.reduce(0, +), 1)
        XCTAssertEqual(ac.learning.diagnostics[.boundaries], 0)
        XCTAssertEqual(replacement(ac), "hello")
        XCTAssertEqual(ac.learning.diagnostics[.suggestionDecodes], 1, "Boundary must reuse the decode")
        XCTAssertEqual(ac.learning.diagnostics.boundaryMs.reduce(0, +), 1)
        ac.touchInput.clear()
        _ = ac.suggestions(beforeInput: "other", field: .text, autocorrectionType: .default)
        track(evidence("gello", aimedAt: "hello"), in: ac)
        _ = ac.suggestions(beforeInput: "gello", field: .text, autocorrectionType: .default)
        XCTAssertEqual(ac.learning.diagnostics[.suggestionDecodes], 2)
    }

    private func editSuggestionEngine(valid: Set<String> = ["hello"]) -> AutocorrectEngine {
        // The large German corpus keeps the English absent-word floor as the literal's prior.
        let source = SpatialWordDecoder(lexicons: [.english: lexicon([("hello", 10_000), ("world", 1)]),
                                                   .german: lexicon([("morgen", 1_000_000)])])
        return AutocorrectEngine(checker: SpatialChecker(valid: valid), spatialDecoder: source)
    }

    func testEditSuggestionsFillTheStripButNeverReplaceAutomatically() throws {
        let ac = editSuggestionEngine()
        let word = evidence("helo", aimedAt: "helo")
        let result = try XCTUnwrap(ac.spatialDecoder?.decode(word, languages: [.english]))
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.editSuggestions.map(\.word), ["hello"])
        track(word, in: ac)
        let slots = ac.suggestions(beforeInput: "helo", field: .text, autocorrectionType: .default)
        XCTAssertEqual(slots.map(\.replacement), ["helo", "hello"])
        XCTAssertFalse(slots[1].willAutoReplace)
        XCTAssertFalse(slots[1].isCompletion)
        XCTAssertNil(replacement(ac, "helo"), "edit suggestions are never automatic")
        XCTAssertEqual(ac.learning.diagnostics[.refusedBelowMargin], 1)
    }

    func testEditSuggestionsAreSuppressedForTrustedLiterals() {
        func secondSlot(_ ac: AutocorrectEngine) -> String? {
            track(evidence("helo", aimedAt: "helo"), in: ac)
            return ac.suggestions(beforeInput: "helo", field: .text, autocorrectionType: .default)
                .dropFirst().first?.replacement
        }
        XCTAssertEqual(secondSlot(editSuggestionEngine()), "hello")
        XCTAssertEqual(secondSlot(editSuggestionEngine(valid: ["hello", "helo"])), "helo", "system-valid literal")
        let kept = editSuggestionEngine()
        kept.suppressAndKeep("helo")
        XCTAssertEqual(secondSlot(kept), "helo", "explicitly kept literal")
        let retainedKeep = editSuggestionEngine()
        retainedKeep.learning.keep("helo")
        XCTAssertEqual(secondSlot(retainedKeep), "helo", "personal lexicon protection without session suppression")
        let rejected = editSuggestionEngine()
        rejected.learning.rejectCorrection(typed: "helo", replacement: "hello")
        XCTAssertEqual(secondSlot(rejected), "helo", "rejected edit pair")
        let contact = editSuggestionEngine()
        contact.loadLexiconEntries([("Helo", "Helo")])
        XCTAssertEqual(secondSlot(contact), "helo", "Contacts/lexicon term")
        let bilingual = editSuggestionEngine()
        bilingual.german = GermanAutocorrect(checker: SpatialChecker(valid: []))
        XCTAssertEqual(secondSlot(bilingual), "hello", "both languages selected")
        let noun = editSuggestionEngine()
        noun.german = GermanAutocorrect(checker: SpatialChecker(valid: ["Helo"]))
        XCTAssertEqual(secondSlot(noun), "helo", "lowercase-typed German noun")
    }

    func testProtectedEditSuggestionsLeaveRoomForNormalCompletions() {
        let source = editSuggestionEngine().spatialDecoder
        let checker = SpatialChecker(valid: ["helo", "hello"], completions: ["helos"])
        let ac = AutocorrectEngine(checker: checker, spatialDecoder: source)
        track(evidence("helo", aimedAt: "helo"), in: ac)
        let slots = ac.suggestions(beforeInput: "helo", field: .text, autocorrectionType: .default)
        XCTAssertEqual(slots.map(\.replacement), ["helo", "helos"])
        XCTAssertTrue(slots[1].isCompletion)

        // A disabled dictionary must not protect the literal in the enabled language.
        let englishOff = editSuggestionEngine(valid: ["helo"])
        englishOff.englishEnabled = false
        englishOff.german = GermanAutocorrect(checker: SpatialChecker(valid: []))
        XCTAssertFalse(englishOff.literalIsValid("helo"))
    }

    func testAboveLiteralStructuralCandidatesAlsoRespectProtections() throws {
        let source = SpatialWordDecoder(lexicons: [.english: lexicon([("hello", 4_000_000_000), ("world", 1)])])
        let word = evidence("helo", aimedAt: "helo")
        let result = try XCTUnwrap(source.decode(word, languages: [.english]))
        XCTAssertEqual(result.candidates.first?.word, "hello")
        XCTAssertNotEqual(result.candidates.first?.edit, SpatialWordDecoder.Edit.none)
        let ac = AutocorrectEngine(checker: SpatialChecker(valid: ["helo", "hello"], completions: ["helos"]),
                                   spatialDecoder: source)
        track(word, in: ac)
        let slots = ac.suggestions(beforeInput: "helo", field: .text, autocorrectionType: .default)
        XCTAssertEqual(slots.map(\.replacement), ["helo", "helos"])
        XCTAssertTrue(slots[1].isCompletion)
        XCTAssertNil(replacement(ac, "helo"))
    }

    func testLowercaseGermanNounIsProtectedWithoutSpatialResources() {
        let ac = AutocorrectEngine(checker: SpatialChecker(valid: [], guesses: ["hello"]), spatialDecoder: nil)
        ac.german = GermanAutocorrect(checker: SpatialChecker(valid: ["Helo"], guesses: ["Hello"]))
        XCTAssertTrue(ac.literalIsValid("helo"))
        XCTAssertNil(replacement(ac, "helo"))
        XCTAssertEqual(ac.learning.diagnostics[.refusedLiteralValid], 1)
        XCTAssertEqual(ac.learning.diagnostics[.autoSpellingFallback], 0)
    }

    func testManualEditSuggestionPickLearnsOnlyAlignedLabels() async throws {
        let ac = editSuggestionEngine()
        let target = FixtureTextTarget(text: "helo")
        target.autocapitalizationType = UITextAutocapitalizationType.none
        let keyboard = FullKeyboardEngine(target: target, autocorrect: ac)
        keyboard.width = 393
        keyboard.configureForField()
        track(evidence("helo", aimedAt: "helo", layout: keyboard.layout), in: ac)
        keyboard.refreshSuggestions()
        await keyboard.waitForSuggestions()
        let suggestion = try XCTUnwrap(keyboard.suggestions.first { $0.replacement == "hello" })
        keyboard.acceptSuggestion(suggestion)
        XCTAssertEqual(target.text, "hello ")
        XCTAssertEqual(ac.learning.diagnostics[.manualAlternativePick], 1)
        XCTAssertEqual(ac.learning.diagnostics[.manualCompletionPick], 0)
        XCTAssertEqual(ac.learning.model.lexicon.counts["hello"], 1)
        // `align` drops the ambiguous repeated `l`; h, e and o stay uniquely aligned.
        XCTAssertEqual(ac.learning.diagnostics.acceptedBySource["manualPick"], 3)
        XCTAssertEqual(ac.learning.diagnostics.rejectedByReason["ambiguousAlignment"], 1)
        XCTAssertFalse(ac.learning.model.lexicon.isKept("helo"))
    }

    func testPickingTheRepeatedLiteralIsNotAnAlternativePick() async throws {
        let ac = editSuggestionEngine(valid: ["hello", "helo"])
        let target = FixtureTextTarget(text: "helo")
        target.autocapitalizationType = UITextAutocapitalizationType.none
        let keyboard = FullKeyboardEngine(target: target, autocorrect: ac)
        keyboard.width = 393
        keyboard.configureForField()
        track(evidence("helo", aimedAt: "helo", layout: keyboard.layout), in: ac)
        keyboard.refreshSuggestions()
        await keyboard.waitForSuggestions()
        // The finished ranking suppresses structural "hello" for valid "helo". A decode
        // counter proves we did not just inspect the identical-looking interim literal chips.
        XCTAssertEqual(ac.learning.diagnostics[.suggestionDecodes], 1)
        let finished = keyboard.suggestions
        keyboard.refreshSuggestions()
        XCTAssertEqual(keyboard.suggestions.map(\.replacement), finished.map(\.replacement), "No literal-only flicker")
        await keyboard.waitForSuggestions()
        XCTAssertEqual(ac.learning.diagnostics[.suggestionDecodes], 1, "An unchanged worker refresh reuses its decode")
        XCTAssertEqual(keyboard.suggestions.map(\.replacement), finished.map(\.replacement))
        XCTAssertEqual(keyboard.suggestions.map(\.kind), finished.map(\.kind))
        XCTAssertEqual(keyboard.suggestions.map(\.isCompletion), finished.map(\.isCompletion))
        let primary = try XCTUnwrap(keyboard.suggestions.dropFirst().first)
        XCTAssertEqual(primary.replacement, "helo")
        XCTAssertEqual(primary.kind, .primary(autoReplace: false))
        XCTAssertFalse(primary.isCompletion)
        keyboard.acceptSuggestion(primary)
        XCTAssertEqual(target.text, "helo ")
        XCTAssertEqual(ac.learning.diagnostics[.manualAlternativePick], 0)
        XCTAssertEqual(ac.learning.diagnostics.acceptedLabels, 0)
        XCTAssertTrue(ac.learning.model.lexicon.counts.isEmpty)
    }

    func testProtectionAppliesBeforeSpatialAndSpelling() {
        for token in ["gello", "GELLO", "gEllo", "Gello"] {
            let ac = engine()
            ac.loadLexiconEntries([(token, token)]) // Includes unknown proper-name/contact spellings.
            track(evidence(token, aimedAt: "hello"), in: ac)
            XCTAssertNil(replacement(ac, token))
            XCTAssertEqual(ac.learning.diagnostics[.refusedProtected], 1)
        }
        let ac = engine()
        ac.learning.rejectCorrection(typed: "gello", replacement: "hello")
        track(evidence("gello", aimedAt: "hello"), in: ac)
        XCTAssertNil(replacement(ac))
        XCTAssertEqual(ac.learning.diagnostics[.refusedProtected], 1)
        ac.loadLexiconEntries([("gello", "Explicit replacement")])
        XCTAssertEqual(replacement(ac), "Explicit replacement", "Explicit replacement outranks inferred protections")
    }

    func testDeterministicRuleAndCapsGuardsPrecedeSpatialDecoding() {
        let rule = engine(valid: ["the"])
        track(evidence("teh", aimedAt: "teh"), in: rule)
        XCTAssertEqual(replacement(rule, "teh"), "the")
        XCTAssertEqual(rule.learning.diagnostics[.autoRule], 1)
        XCTAssertEqual(rule.learning.diagnostics[.autoSpatialSameLength], 0)
        for token in ["GELLO", "gEllo"] { // Acronym and internal capital, no lexicon entry.
            let ac = engine()
            track(evidence(token, aimedAt: "hello"), in: ac)
            XCTAssertNil(replacement(ac, token), token)
            XCTAssertEqual(ac.learning.diagnostics[.refusedProtected], 1, token)
        }
    }

    func testMissingSelectedLanguageResourceFallsBackWithDiagnostic() {
        let source = SpatialWordDecoder(lexicons: [.english: lexicon([("hello", 100)])])
        let ac = AutocorrectEngine(checker: SpatialChecker(valid: ["hello"], guesses: ["hello"]), spatialDecoder: source)
        ac.german = GermanAutocorrect(checker: SpatialChecker(valid: []))
        track(evidence("gello", aimedAt: "hello"), in: ac)
        XCTAssertEqual(replacement(ac), "hello")
        XCTAssertEqual(ac.learning.diagnostics[.refusedMissingResource], 1)
        XCTAssertEqual(ac.learning.diagnostics[.autoSpellingFallback], 1)
    }

    func testIncompleteSearchCannotUseSpellingFallback() throws {
        let entries: [(String, UInt32)] = (0..<4_096).map { value in
            (String((0..<12).map { value & (1 << $0) == 0 ? Character("g") : Character("h") }), 1)
        }
        let source = SpatialWordDecoder(lexicons: [.english: lexicon(entries + [("world", 1_000_000_000)])])
        let token = String(repeating: "g", count: 12)
        var word = evidence(token, aimedAt: token)
        let g = try XCTUnwrap(word.layout.key(.character("g"))).frame
        let h = try XCTUnwrap(word.layout.key(.character("h"))).frame
        word.samples = word.samples.map {
            .init(text: $0.text, point: CGPoint(x: (g.midX + h.midX) / 2, y: g.midY), key: $0.key)
        }
        let guess = String(repeating: "g", count: 11) + "h"
        let ac = AutocorrectEngine(checker: SpatialChecker(valid: [guess], guesses: [guess]), spatialDecoder: source)
        XCTAssertFalse(try XCTUnwrap(source.decode(word, languages: [.english])).complete)
        track(word, in: ac)
        XCTAssertNil(replacement(ac, token))
        XCTAssertEqual(ac.learning.diagnostics[.refusedIncompleteSearch], 1)
        XCTAssertEqual(ac.learning.diagnostics[.autoSpellingFallback], 0)
    }

    func testCanonicalGermanGuessesAreCachedPerTokenForVisibleCandidates() {
        let checker = SpatialChecker(valid: ["Hallo"], guesses: ["Hallo"])
        let ac = engine()
        ac.englishEnabled = false
        ac.german = GermanAutocorrect(checker: checker)
        track(evidence("hslko", aimedAt: "hallo"), in: ac)
        for _ in 0..<5 {
            let slots = ac.suggestions(beforeInput: "hslko", field: .text, autocorrectionType: .default)
            XCTAssertEqual(slots.dropFirst().first?.replacement, "Hallo")
        }
        XCTAssertEqual(replacement(ac, "hslko"), "Hallo")
        XCTAssertEqual(checker.guessCalls, 1)
    }

    func testLearningOffDoesNotSupplyCalibrationOrWordPriors() throws {
        let name = "Spatial-learning-off-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let session = KeyboardLearningSession(defaults: defaults)
        let grid = layout()
        let frame = try XCTUnwrap(grid.key(.character("h"))).frame
        for _ in 0..<24 {
            session.learn([TouchLabel(point: CGPoint(x: frame.midX + 4, y: frame.midY), letter: "h")],
                          layout: grid, source: .keep)
        }
        session.recordWord("hello")
        XCTAssertNotNil(session.model.calibration(for: grid))
        defaults.set(false, forKey: "keyboard.personalLearning")
        let ac = AutocorrectEngine(checker: SpatialChecker(valid: ["hello"]), learning: session, spatialDecoder: decoder())
        ac.syncLearning()
        XCTAssertNil(session.model.calibration(for: grid))
        XCTAssertTrue(session.model.lexicon.counts.isEmpty)
        let state = session.model.state
        track(evidence("gello", aimedAt: "hello"), in: ac)
        XCTAssertEqual(replacement(ac), "hello")
        XCTAssertEqual(session.model.state, state)
    }

    private func bundledDecoder() throws -> SpatialWordDecoder {
        SpatialWordDecoder(lexicons: try XCTUnwrap(BundledKeyboardData.lexicons))
    }

    func testFixedPublicWordFixturesWithBundledData() throws {
        let decoder = try bundledDecoder()
        // Synthetic points are an algorithm regression set, not real-iPhone accuracy measurements.
        let cases: [(String, String, SpatialWordDecoder.Language)] = [
            ("gello", "hello", .english), ("eorld", "world", .english),
            ("jeyboars", "keyboard", .english), ("gouse", "house", .english),
            ("hslko", "hallo", .german), ("dsnkr", "danke", .german),
            ("norgem", "morgen", .german), ("hrutr", "heute", .german),
        ]
        for (typed, intended, language) in cases {
            let result = decoder.decode(evidence(typed, aimedAt: intended), languages: [language])
            XCTAssertTrue(result?.candidates.contains { $0.word == intended } ?? false, "candidate recall: \(typed) -> \(intended)")
            let control = decoder.decode(evidence(intended, aimedAt: intended), languages: [language])
            XCTAssertNotNil(control, "a control should complete within budget")
            XCTAssertEqual(control?.complete, true)
            XCTAssertNil(control?.automaticCandidate, "centered control: \(intended)")
        }
    }

    func testStructuralEditAlignmentsAndNoCompletions() throws {
        let decoder = SpatialWordDecoder(lexicons: [.english: lexicon([("hello", 1_000_000), ("help", 1)])])
        let missing = try XCTUnwrap(decoder.decode(evidence("helo", aimedAt: "helo"), languages: [.english]))
        let inserted = try XCTUnwrap(missing.candidates.first { $0.word == "hello" })
        if case .missingLetter = inserted.edit {} else { XCTFail("expected one missing letter") }
        XCTAssertEqual(inserted.alignment.count, 5)
        XCTAssertEqual(inserted.alignment.compactMap { $0 }, [0, 1, 2, 3])
        let extra = try XCTUnwrap(decoder.decode(evidence("heallo", aimedAt: "heallo"), languages: [.english]))
        XCTAssertEqual(extra.candidates.first?.edit, .extraTap(at: 2))
        XCTAssertEqual(extra.candidates.first?.alignment, [0, 1, 3, 4, 5])
        let transpose = try XCTUnwrap(decoder.decode(evidence("hlelo", aimedAt: "hlelo"), languages: [.english]))
        XCTAssertEqual(transpose.candidates.first?.edit, .transposition(at: 1))
        XCTAssertEqual(transpose.candidates.first?.alignment, [0, 2, 1, 3, 4])
        for text in ["helo", "heallo", "hlelo"] {
            let staticResult = decoder.decode(evidence(text, aimedAt: text), languages: [.english], allowsEdits: false)
            XCTAssertFalse(staticResult?.candidates.contains { $0.word == "hello" } ?? false)
        }
        let completion = SpatialWordDecoder(lexicons: [.english: lexicon([("helping", 100)])])
        XCTAssertTrue(completion.decode(evidence("help", aimedAt: "help"), languages: [.english])?.candidates.isEmpty ?? false)
    }

    func testStructuralCandidatesStillNeedToBeatTheLiteral() throws {
        // A centred missing-letter typo has no geometric gain over the literal.
        // Realistic prior ratios do not pay for log(.01); this is not search failure.
        let word = evidence("helo", aimedAt: "helo")
        let conservative = SpatialWordDecoder(lexicons: [.english: lexicon([("hello", 10_000), ("world", 1)])])
        let result = try XCTUnwrap(conservative.decode(word, languages: [.english]))
        XCTAssertTrue(result.complete)
        XCTAssertTrue(result.candidates.isEmpty)
        // Absent literal: the structural word is still offered, below the literal and
        // only as a suggestion. It never feeds the automatic or geometry decisions.
        XCTAssertEqual(result.editSuggestions.map(\.word), ["hello"])
        XCTAssertEqual(result.suggestions.map(\.word), ["hello"])
        XCTAssertLessThan(try XCTUnwrap(result.editSuggestions.first).score, result.literalScore)
        XCTAssertNil(result.automaticCandidate)
        XCTAssertFalse(result.geometryPrefersAlternative)
        let staticResult = try XCTUnwrap(conservative.decode(word, languages: [.english], allowsEdits: false))
        XCTAssertTrue(staticResult.editSuggestions.isEmpty)
        let valid = SpatialWordDecoder(lexicons: [.english: lexicon([("hello", 10_000), ("helo", 1)])])
        XCTAssertTrue(try XCTUnwrap(valid.decode(word, languages: [.english])).editSuggestions.isEmpty,
                      "a corpus-valid literal gets no below-literal edit suggestions")
        let several = SpatialWordDecoder(lexicons: [.english: lexicon([("hello", 10_000), ("helio", 5_000),
                                                                       ("helot", 2_000), ("world", 1)])])
        XCTAssertEqual(try XCTUnwrap(several.decode(word, languages: [.english])).editSuggestions.map(\.word),
                       ["hello", "helio"], "at most editSuggestionLimit, best first")
        // Window: more than one edit penalty below the literal (small German corpus sets the floor).
        let distant = SpatialWordDecoder(lexicons: [.english: lexicon([("hello", 1), ("world", 1_000_000)]),
                                                    .german: lexicon([("hallo", 10)])])
        XCTAssertTrue(try XCTUnwrap(distant.decode(word, languages: [.english, .german])).editSuggestions.isEmpty)
        let stronger = SpatialWordDecoder(lexicons: [.english: lexicon([("hello", 1_000_000), ("world", 1)])])
        let suggested = try XCTUnwrap(stronger.decode(word, languages: [.english]))
        XCTAssertTrue(suggested.complete)
        XCTAssertEqual(suggested.candidates.first?.word, "hello")
        XCTAssertNil(suggested.automaticCandidate, "beating literal is still not the 3-unit auto margin")
    }

    func testSubtreePriorIndexRequiresUniqueSpellingsPerNode() throws {
        let source = lexicon([("cat", 2), ("car", 30), ("dog", 7)])
        XCTAssertEqual(source.bestLogPrior(at: 0), log(30.0 / 39), accuracy: 1e-12)
        let root = try XCTUnwrap(source.node(0))
        let c = root.children.lowerBound, d = c + 1
        let cNode = try XCTUnwrap(source.node(c))
        XCTAssertEqual(source.bestLogPrior(at: c), log(30.0 / 39), accuracy: 1e-12)
        XCTAssertEqual(source.bestLogPrior(at: d), log(7.0 / 39), accuracy: 1e-12)
        // Sharing a child would make a node's spelling ambiguous and invalidate
        // dominance. Such forward-only DAGs must not be accepted as tries.
        var shared = source.data
        let offset = 24 + d * 12 + 4
        for shift in 0..<4 { shared[offset + shift] = UInt8(truncatingIfNeeded: cNode.children.lowerBound >> (shift * 8)) }
        XCTAssertNil(SpatialWordLexicon(data: shared))
        var duplicate = source.data
        duplicate[24 + d * 12] = UInt8(try XCTUnwrap(source.node(c)).label)
        XCTAssertNil(SpatialWordLexicon(data: duplicate))
    }

    func testPolicyRefusalsAndGeometryOnlyVeto() {
        typealias Decoder = SpatialWordDecoder
        func candidate(_ word: String, score: Double, spatial: Double, edit: Decoder.Edit = .none) -> Decoder.Candidate {
            .init(word: word, language: .english, score: score, spatialScore: spatial,
                  edit: edit, alignment: [0, 1, 2, 3])
        }
        func result(_ candidates: [Decoder.Candidate], complete: Bool = true) -> Decoder.Result {
            .init(candidates: candidates, literalScore: 0, literalSpatialScore: 0,
                  literalInLexicon: false, complete: complete, visits: 1, generated: 1)
        }
        func refusal(_ result: Decoder.Result, valid: Bool = false) -> Decoder.Refusal? {
            if case .refuse(let reason) = result.automaticDecision(literalIsValid: valid) { return reason }
            return nil
        }
        let strong = candidate("hello", score: 4, spatial: 3)
        XCTAssertEqual(refusal(result([strong], complete: false)), .incompleteSearch)
        XCTAssertEqual(refusal(result([])), .noCandidate)
        XCTAssertEqual(refusal(result([candidate("hello", score: 2.9, spatial: 3)])), .belowMargin)
        XCTAssertEqual(refusal(result([candidate("hello", score: 4, spatial: 1.9)])), .belowMargin)
        XCTAssertEqual(refusal(result([strong, candidate("jello", score: 2.5, spatial: 3)])), .ambiguous)
        XCTAssertNil(refusal(result([strong, candidate("jello", score: 2.4, spatial: 3)])))
        let suggestionOnly = Decoder.Result(candidates: [], literalScore: 0, literalSpatialScore: 0,
                                            literalInLexicon: false, complete: true, visits: 1, generated: 1,
                                            editSuggestions: [candidate("hello", score: -1, spatial: 0, edit: .missingLetter(at: 1))])
        XCTAssertEqual(refusal(suggestionOnly), .noCandidate)
        XCTAssertFalse(suggestionOnly.geometryPrefersAlternative)
        let edited = candidate("hello", score: 4, spatial: -1, edit: .transposition(at: 1))
        XCTAssertEqual(refusal(result([edited]), valid: true), .editNeedsInvalidLiteral)
        XCTAssertNil(refusal(result([edited])))
        XCTAssertFalse(result([candidate("hello", score: 4, spatial: -0.01)]).geometryPrefersAlternative)
        XCTAssertTrue(result([candidate("hello", score: 4, spatial: 0)]).geometryPrefersAlternative)
    }

    func testPreferredLanguageWinsCloseCandidatesOnly() {
        typealias Decoder = SpatialWordDecoder
        func candidate(_ word: String, _ language: Decoder.Language, score: Double) -> Decoder.Candidate {
            .init(word: word, language: language, score: score, spatialScore: 3, edit: .none, alignment: [0, 1, 2, 3])
        }
        func decision(_ candidates: [Decoder.Candidate], preferring language: Decoder.Language?) -> String? {
            let result = Decoder.Result(candidates: candidates, literalScore: 0, literalSpatialScore: 0,
                                        literalInLexicon: false, complete: true, visits: 1, generated: 1)
            let isPreferred = language.map { language in { (candidate: Decoder.Candidate) in candidate.language == language } }
            if case .replace(let best) = result.automaticDecision(literalIsValid: false, preferring: isPreferred) {
                return best.word
            }
            return nil
        }
        let close = [candidate("work", .english, score: 5), candidate("wird", .german, score: 4.5)]
        XCTAssertNil(decision(close, preferring: nil))
        XCTAssertEqual(decision(close, preferring: .english), "work")
        XCTAssertEqual(decision(Array(close.reversed()), preferring: .english), "work")
        let germanAhead = [candidate("wird", .german, score: 5), candidate("work", .english, score: 4.5)]
        XCTAssertNil(decision(germanAhead, preferring: nil))
        XCTAssertEqual(decision(germanAhead, preferring: .german), "wird")
        XCTAssertNil(decision(germanAhead, preferring: .english), "A small lead of the other language still refuses")
        let englishClear = [candidate("work", .english, score: 8), candidate("wird", .german, score: 4.5)]
        XCTAssertEqual(decision(englishClear, preferring: .german), "work")
        XCTAssertEqual(decision([candidate("work", .english, score: 3.5)], preferring: .german), "work")
        XCTAssertNil(decision([candidate("work", .english, score: 2.9)], preferring: .german),
                     "The literal margin is unchanged")
    }

    func testPersonalCandidatesPriorAndCalibrationNormalization() throws {
        let decoder = SpatialWordDecoder(lexicons: [.english: lexicon([("hello", 1_000_000), ("world", 1)])])
        let personal = PersonalLexiconSnapshot(kept: ["zello"], counts: ["zello": 4, "xello": 1], rejected: [])
        let word = evidence("xello", aimedAt: "zello")
        let result = try XCTUnwrap(decoder.decode(word, languages: [.english], personal: personal))
        let candidate = try XCTUnwrap(result.candidates.first { $0.word == "zello" })
        XCTAssertNil(candidate.language)
        XCTAssertEqual(candidate.edit, .none)
        XCTAssertEqual(candidate.alignment, [0, 1, 2, 3, 4])
        let without = decoder.decode(word, languages: [.english])
        XCTAssertFalse(without?.candidates.contains { $0.word == "zello" } ?? false)
        let centered = evidence("hello", aimedAt: "hello")
        let baseline = try XCTUnwrap(decoder.decode(centered, languages: [.english]))
        let narrow = SpatialTouchCalibration(keys: ["h": .init(offsetX: 0, offsetY: 0, sigmaX: 0.22, sigmaY: 0.22)])
        let broad = SpatialTouchCalibration(keys: ["h": .init(offsetX: 0, offsetY: 0, sigmaX: 0.5, sigmaY: 0.5)])
        let n = try XCTUnwrap(decoder.decode(centered, languages: [.english], calibration: narrow))
        let b = try XCTUnwrap(decoder.decode(centered, languages: [.english], calibration: broad))
        XCTAssertEqual(n.literalSpatialScore - b.literalSpatialScore, 2 * log(0.5 / 0.22), accuracy: 1e-10)
        let withBonus = try XCTUnwrap(decoder.decode(centered, languages: [.english], personal:
            .init(kept: [], counts: ["hello": 10_000], rejected: [])))
        XCTAssertEqual(withBonus.literalScore - baseline.literalScore, 1, accuracy: 1e-10)
        XCTAssertEqual(withBonus.literalSpatialScore, baseline.literalSpatialScore)
        var shifted = centered
        let first = shifted.samples[0]
        let pitch = first.key.frame.width + shifted.layout.metrics.gap
        shifted.samples[0] = .init(text: first.text, point: CGPoint(x: first.point.x + 0.25 * pitch, y: first.point.y), key: first.key)
        let offset = SpatialTouchCalibration(keys: ["h": .init(offsetX: 0.25, offsetY: 0, sigmaX: 0.35, sigmaY: 0.35)])
        let calibrated = try XCTUnwrap(decoder.decode(shifted, languages: [.english], calibration: offset))
        let staticResult = try XCTUnwrap(decoder.decode(shifted, languages: [.english]))
        XCTAssertEqual(calibrated.literalSpatialScore - staticResult.literalSpatialScore,
                       0.25 * 0.25 / (2 * 0.35 * 0.35), accuracy: 1e-10)
    }

    func testTwoThousandCountedDictionaryWordsHaveIdenticalColdAndCachedResults() throws {
        let sources = try XCTUnwrap(BundledKeyboardData.lexicons)
        let english = try XCTUnwrap(sources[.english])
        var words: [String] = []
        func collect(_ index: Int, _ prefix: String) throws {
            let node = try XCTUnwrap(english.node(index))
            if node.count > 0, PersonalTypingModel.State.validWord(prefix) { words.append(prefix) }
            for child in node.children where words.count < 2_000 {
                let next = try XCTUnwrap(english.node(child))
                try collect(child, prefix + String(SpatialWordLexicon.alphabet[next.label]))
            }
        }
        try collect(0, "")
        XCTAssertEqual(words.count, 2_000)
        let counts = Dictionary(uniqueKeysWithValues: words.map { ($0, 2) })
        let snapshot = PersonalLexiconSnapshot(kept: [], counts: counts, rejected: [])
        let decoder = SpatialWordDecoder(lexicons: sources)
        let changedWord = try XCTUnwrap(words.first { $0.count >= 3 && $0.allSatisfy { $0.isASCII } })
        var changedCounts = counts
        changedCounts[changedWord] = 3
        // Model the combined bound's eviction when adding a new counted word.
        changedCounts.removeValue(forKey: try XCTUnwrap(words.last))
        changedCounts["zello"] = 2
        let updated = PersonalLexiconSnapshot(kept: [], counts: changedCounts, rejected: [])
        XCTAssertTrue(updated.scan.complete)
        XCTAssertFalse(updated.scan === snapshot.scan)
        // Warm the original snapshot, change a count and add a word, then revisit the original.
        // The corpus memo survives, but entry bonuses and personal-only words must refresh.
        var coldResults: [String: SpatialWordDecoder.Result] = [:]
        for (current, currentCounts) in [(snapshot, counts), (updated, changedCounts), (snapshot, counts)] {
            for languages: Set<SpatialWordDecoder.Language> in [[.english], [.german], [.english, .german], [.english]] {
                for typed in ["wunderbar", "xello", changedWord] {
                    let word = evidence(typed, aimedAt: typed == "xello" ? "zello" : typed)
                    let key = "\(currentCounts == counts) \(languages.map(\.rawValue).sorted()) \(typed)"
                    if coldResults[key] == nil {
                        coldResults[key] = try XCTUnwrap(SpatialWordDecoder(lexicons: sources).decode(word,
                            languages: languages, personal: .init(kept: [], counts: currentCounts, rejected: [])))
                    }
                    let cold = try XCTUnwrap(coldResults[key])
                    for _ in 0..<2 {
                        let cached = try XCTUnwrap(decoder.decode(word, languages: languages, personal: current))
                        XCTAssertEqual(cached.literalScore, cold.literalScore)
                        XCTAssertEqual(cached.literalSpatialScore, cold.literalSpatialScore)
                        XCTAssertEqual(cached.literalInLexicon, cold.literalInLexicon)
                        XCTAssertEqual(cached.complete, cold.complete)
                        XCTAssertEqual(cached.visits, cold.visits)
                        XCTAssertEqual(cached.generated, cold.generated)
                        for (actual, expected) in [(cached.candidates, cold.candidates), (cached.suggestions, cold.suggestions)] {
                            XCTAssertEqual(actual.count, expected.count)
                            for (a, b) in zip(actual, expected) {
                                XCTAssertEqual(a.word, b.word); XCTAssertEqual(a.language, b.language)
                                XCTAssertEqual(a.score, b.score); XCTAssertEqual(a.spatialScore, b.spatialScore)
                                XCTAssertEqual(a.edit, b.edit); XCTAssertEqual(a.alignment, b.alignment)
                            }
                        }
                    }
                }
            }
        }
        XCTAssertTrue(decoder.decode(evidence("xello", aimedAt: "zello"), languages: [.english],
            personal: updated)?.candidates.contains { $0.word == "zello" && $0.language == nil } ?? false)
        let changed = PersonalLexiconSnapshot(kept: ["zello"], counts: [:], rejected: [])
        let word = evidence("xello", aimedAt: "zello")
        XCTAssertTrue(decoder.decode(word, languages: [.english], personal: changed)?.candidates.contains { $0.word == "zello" } ?? false)
        XCTAssertFalse(decoder.decode(word, languages: [.english], personal: snapshot)?.candidates.contains { $0.language == nil } ?? true)
    }

    func testLearningAlignmentDropsAmbiguousAndTransposedLabels() {
        XCTAssertEqual(SpatialWordDecoder.align(word: "hello", taps: Array("hello")), [0, 1, 2, 3, 4])
        XCTAssertEqual(SpatialWordDecoder.align(word: "hello", taps: Array("helo")), [0, 1, nil, nil, 3])
        XCTAssertEqual(SpatialWordDecoder.align(word: "hello", taps: Array("heallo")), [0, 1, 3, 4, 5])
        XCTAssertEqual(SpatialWordDecoder.align(word: "hello", taps: Array("helllo")), [0, 1, nil, nil, 5])
        XCTAssertEqual(SpatialWordDecoder.align(word: "hello", taps: Array("hlelo")), [0, nil, nil, 3, 4])
        XCTAssertEqual(SpatialWordDecoder.align(word: "hello", taps: Array("gello")), [0, 1, 2, 3, 4])
        XCTAssertNil(SpatialWordDecoder.align(word: "hello", taps: Array("xxllo")))
        XCTAssertNil(SpatialWordDecoder.align(word: "hello", taps: Array("heo")))
    }

    func testContinuationBoundsRetainOneEditAndSaturateDeepResources() throws {
        let source = lexicon([("hello", 100), ("help", 1)])
        XCTAssertTrue(source.canFinish(at: 0, remaining: 4, editAvailable: false))
        XCTAssertFalse(source.canFinish(at: 0, remaining: 3, editAvailable: false))
        XCTAssertTrue(source.canFinish(at: 0, remaining: 3, editAvailable: true), "one missing letter")
        XCTAssertTrue(source.canFinish(at: 0, remaining: 6, editAvailable: true), "one extra tap")
        XCTAssertFalse(source.canFinish(at: 0, remaining: 7, editAvailable: true))
        let alphabet = SpatialWordLexicon.alphabet
        let a = try XCTUnwrap(alphabet.firstIndex(of: "a")), h = try XCTUnwrap(alphabet.firstIndex(of: "h"))
        var scores = [Double](repeating: -.infinity, count: alphabet.count)
        scores[a] = 10; scores[h] = -2
        XCTAssertEqual(source.bestNextDensity(at: 0, scores: scores, rankedLabels: [a, h],
                                             finiteMask: (1 << a) | (1 << h)), -2, "the globally best key is not a child")
        XCTAssertEqual(source.bestNextDensity(at: 0, scores: scores, rankedLabels: [a], finiteMask: 1 << a), -.infinity)
        let deep = lexicon([(String(repeating: "z", count: 300), 1)])
        for remaining in 0...32 {
            XCTAssertFalse(deep.canFinish(at: 0, remaining: remaining, editAvailable: true),
                           "255 saturation must not wrap a long path into an eligible word")
        }
    }

    func testCompleteSearchMatchesExhaustiveFrozenScoreDP() throws {
        let english: [(String, UInt32)] = [("hello", 500_000), ("jello", 100_000), ("hell", 2_000), ("heallo", 1_000), ("help", 4_000)]
        let german: [(String, UInt32)] = [("hallo", 600_000), ("hello", 700_000), ("helgo", 10_000)]
        let sources = [(SpatialWordDecoder.Language.english, english), (.german, german)]
        let lexicons: [SpatialWordDecoder.Language: SpatialWordLexicon] = [.english: lexicon(english), .german: lexicon(german)]
        let decoder = SpatialWordDecoder(lexicons: lexicons)
        let originBound = SpatialWordDecoder(lexicons: lexicons, usesLegacySearch: true)
        let offsets: [Double] = [0.08, -0.5, 0.5]
        let calibrations: [SpatialTouchCalibration?] = [nil] + offsets.map { (offset: Double) -> SpatialTouchCalibration? in
            let keys: [(Character, SpatialTouchCalibration.Key)] = "abcdefghijklmnopqrstuvwxyz".enumerated().map { index, letter in
                let covariance: Double = index % 2 == 0 ? 0.035 : -0.035
                let key = SpatialTouchCalibration.Key(offsetX: offset, offsetY: -offset / 2, sigmaX: 0.30, sigmaY: 0.40,
                                                      covarianceXY: covariance)
                return (letter, key)
            }
            return SpatialTouchCalibration(keys: Dictionary(uniqueKeysWithValues: keys))
        }
        let pairs = [("gello", "hello"), ("helo", "helo"), ("heallo", "heallo"), ("hlelo", "hlelo")]
        let scenarios = calibrations.flatMap { c in pairs.map { ($0.0, $0.1, c) } }
        for (typed, aimed, calibration) in scenarios {
            let word = evidence(typed, aimedAt: aimed)
            let letters = Array("abcdefghijklmnopqrstuvwxyz")
            var scores: [[Character: Double]] = []
            for sample in word.samples {
                var row: [Character: Double] = [:]
                for letter in letters {
                    let frame = try XCTUnwrap(word.layout.key(.character(String(letter)))).frame
                    let key = calibration?.keys[letter] ?? .init(offsetX: 0, offsetY: 0, sigmaX: 0.35, sigmaY: 0.35)
                    let dx = Double(sample.point.x - frame.midX) / Double(frame.width + word.layout.metrics.gap) - key.offsetX
                    let dy = Double(sample.point.y - frame.midY) / Double(frame.height + word.layout.metrics.rowGap) - key.offsetY
                    if dx * dx + dy * dy <= 1.6 * 1.6 {
                        // Independent inverse/determinant reference, not logDensity().
                        let xx = key.sigmaX * key.sigmaX, yy = key.sigmaY * key.sigmaY, xy = key.covarianceXY
                        let det = xx * yy - xy * xy
                        row[letter] = -0.5 * (yy * dx * dx - 2 * xy * dx * dy + xx * dy * dy) / det
                            - log(2 * Double.pi * sqrt(det))
                    }
                }
                let best = try XCTUnwrap(row.values.max())
                scores.append(row.filter { $0.value >= best - 6 })
            }
            for edits in [false, true] {
                let result = try XCTUnwrap(decoder.decode(word, languages: [.english, .german], calibration: calibration, allowsEdits: edits))
                XCTAssertTrue(result.complete)
                let baseline = try XCTUnwrap(originBound.decode(word, languages: [.english, .german], calibration: calibration, allowsEdits: edits))
                XCTAssertTrue(baseline.complete)
                XCTAssertEqual(result.suggestions.map(\.word), baseline.suggestions.map(\.word))
                for (candidate, original) in zip(result.suggestions, baseline.suggestions) {
                    XCTAssertEqual(candidate.score, original.score, accuracy: 1e-10)
                }
                XCTAssertLessThanOrEqual(result.visits, baseline.visits)
                var expected: [String: Double] = [:]
                var structural: [String: Double] = [:]
                for (_, entries) in sources {
                    let total = Double(entries.reduce(UInt32(0)) { $0 + $1.1 })
                    for (spelling, count) in entries where spelling != typed {
                        let intended = Array(spelling)
                        let n = intended.count, m = scores.count
                        // Independent full matrix oracle, rather than the production trie/trails.
                        var dp = Array(repeating: Array(repeating: [-Double.infinity, -Double.infinity], count: m + 1), count: n + 1)
                        dp[0][0][0] = 0
                        for i in 0...n {
                            for j in 0...m {
                                for used in 0...1 where dp[i][j][used].isFinite {
                                    let value = dp[i][j][used]
                                    if i < n, j < m, let score = scores[j][intended[i]] {
                                        dp[i + 1][j + 1][used] = max(dp[i + 1][j + 1][used], value + score)
                                    }
                                    if edits && used == 0 {
                                        if i < n { dp[i + 1][j][1] = max(dp[i + 1][j][1], value + log(0.01)) }
                                        if j < m {
                                            let stray = scores[j].values.max() ?? -.infinity
                                            dp[i][j + 1][1] = max(dp[i][j + 1][1], value + stray + log(0.01))
                                        }
                                        if i + 1 < n, j + 1 < m, intended[i] != intended[i + 1],
                                           let a = scores[j + 1][intended[i]], let b = scores[j][intended[i + 1]] {
                                            dp[i + 2][j + 2][1] = max(dp[i + 2][j + 2][1], value + a + b + log(0.01))
                                        }
                                    }
                                }
                            }
                        }
                        let prior = 0.35 * log(Double(count) / total)
                        let score = max(dp[n][m][0], dp[n][m][1]) + prior
                        if score > result.literalScore { expected[spelling] = max(expected[spelling] ?? -.infinity, score) }
                        if dp[n][m][1].isFinite {
                            structural[spelling] = max(structural[spelling] ?? -.infinity, dp[n][m][1] + prior)
                        }
                    }
                }
                let ordered = expected.keys.sorted {
                    let a = ((expected[$0] ?? 0) / 1e-9).rounded(), b = ((expected[$1] ?? 0) / 1e-9).rounded()
                    return a == b ? $0 < $1 : a > b
                }
                XCTAssertEqual(result.candidates.map(\.word), Array(ordered.prefix(8)))
                for candidate in result.candidates {
                    XCTAssertEqual(candidate.score, try XCTUnwrap(expected[candidate.word]), accuracy: 1e-10)
                }
                // Below-literal edit suggestions: best structural reading within one edit penalty.
                let window = structural.filter { word, score in
                    expected[word] == nil && score <= result.literalScore && score >= result.literalScore + log(0.01)
                }
                let below = window.keys.sorted {
                    let a = ((window[$0] ?? 0) / 1e-9).rounded(), b = ((window[$1] ?? 0) / 1e-9).rounded()
                    return a == b ? $0 < $1 : a > b
                }
                let suggestsEdits = edits && !result.literalInLexicon
                XCTAssertEqual(result.editSuggestions.map(\.word),
                               suggestsEdits ? Array(below.prefix(SpatialWordDecoder.editSuggestionLimit)) : [])
                for candidate in result.editSuggestions {
                    XCTAssertNotEqual(candidate.edit, SpatialWordDecoder.Edit.none)
                    XCTAssertEqual(candidate.score, try XCTUnwrap(window[candidate.word]), accuracy: 1e-10)
                }
            }
        }
    }

    func testExactTopEightUsesDeterministicSpellingTies() throws {
        let entries: [(String, UInt32)] = (0..<16).map { value in
            (String((0..<4).map { value & (1 << $0) == 0 ? Character("g") : Character("h") }), 1)
        }
        let decoder = SpatialWordDecoder(lexicons: [.english: lexicon(entries)])
        for width: CGFloat in [320, 375, 393, 402, 430, 440] {
            for strip in [false, true] {
                var word = evidence("jjjj", aimedAt: "hhhh", layout: layout(width: width, strip: strip))
                let g = try XCTUnwrap(word.layout.key(.character("g"))).frame
                let h = try XCTUnwrap(word.layout.key(.character("h"))).frame
                word.samples = word.samples.map {
                    .init(text: $0.text, point: CGPoint(x: (g.midX + h.midX) / 2, y: g.midY), key: $0.key)
                }
                let result = try XCTUnwrap(decoder.decode(word, languages: [.english]))
                XCTAssertTrue(result.complete)
                XCTAssertEqual(result.candidates.map(\.word), Array(entries.map { $0.0 }.sorted().prefix(8)))
            }
        }
    }

    func testSettledSpatialSubstitutionTeachesOnlyWhenItSettles() {
        func corrected() -> AutocorrectEngine {
            let ac = engine()
            track(evidence("gello", aimedAt: "hello"), in: ac)
            XCTAssertEqual(replacement(ac), "hello")
            return ac
        }
        let settled = corrected()
        settled.settleFeedback(beforeInput: "hello ", insertedLetter: "w", afterInput: "hello w")
        XCTAssertEqual(settled.learning.diagnostics.acceptedBySource["autocorrect"], 5)
        XCTAssertTrue(settled.learning.model.lexicon.counts.isEmpty, "an automatic correction still counts no word")
        let undone = corrected()
        undone.recordUndo(.init(original: "gello", insertedText: "hello ", kind: .autoSpatial))
        undone.settleFeedback(beforeInput: "gello ", insertedLetter: "w", afterInput: "gello w")
        XCTAssertNil(undone.learning.diagnostics.acceptedBySource["autocorrect"])
        let unsettled = corrected()
        unsettled.settleFeedback(beforeInput: "hello ", insertedLetter: "1", afterInput: "hello 1")
        XCTAssertNil(unsettled.learning.diagnostics.acceptedBySource["autocorrect"])
    }

    func testSettledSpatialTranspositionNeverTeaches() {
        let source = SpatialWordDecoder(lexicons: [.english: lexicon([("hello", 4_000_000_000), ("world", 1)])])
        let ac = AutocorrectEngine(checker: SpatialChecker(valid: ["hello"]), learning: KeyboardLearningSession(),
                                   spatialDecoder: source)
        track(evidence("hlelo", aimedAt: "hlelo"), in: ac)
        XCTAssertEqual(replacement(ac, "hlelo"), "hello")
        XCTAssertEqual(ac.learning.diagnostics[.autoSpatialEdit], 1)
        ac.settleFeedback(beforeInput: "hello ", insertedLetter: "w", afterInput: "hello w")
        XCTAssertNil(ac.learning.diagnostics.acceptedBySource["autocorrect"])
    }

    func testEditedEvidenceStillDecodesButUndoDoesNotTeach() {
        let ac = engine()
        track(evidence("gella", aimedAt: "hella"), in: ac)
        ac.touchInput.deletedBackward(before: "gella", after: "gell")
        let word = evidence("gello", aimedAt: "hello")
        guard let last = word.samples.last else { return XCTFail("Missing synthetic tap") }
        ac.touchInput.append(text: "o", point: last.point, key: last.key, layout: word.layout,
                             before: "gell", after: "gello")
        XCTAssertEqual(ac.touchInput.evidence(beforeInput: "gello")?.learningIntact, false)
        XCTAssertEqual(replacement(ac), "hello", "Edited evidence still participates in decoding")
        ac.recordUndo(.init(original: "gello", insertedText: "hello ", kind: .autoSpatial))
        XCTAssertEqual(ac.learning.diagnostics.acceptedLabels, 0)
        XCTAssertTrue(ac.learning.model.lexicon.counts.isEmpty)
        XCTAssertFalse(ac.learning.protections.isKept("gello"))
        XCTAssertTrue(ac.learning.protections.isRejected(typed: "gello", replacement: "hello"))
    }

    func testDisjointPersonalWordsAtCapacityDoNotInvalidateCompleteSearch() throws {
        let model = PersonalTypingModel()
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
        for index in 0..<2000 {
            let word = "word" + String(alphabet[index / 676]) + String(alphabet[(index / 26) % 26])
                + String(alphabet[index % 26])
            if index < 1000 { model.keep(word) }
            else { model.recordWord(word); model.recordWord(word) }
        }
        XCTAssertEqual(model.state.kept.count, 1000)
        XCTAssertEqual(model.state.counts.count, 1000)
        XCTAssertNotNil(model.state.validated())
        let result = try XCTUnwrap(decoder().decode(evidence("gello", aimedAt: "hello"),
            languages: [.english], personal: model.lexicon))
        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.automaticCandidate?.word, "hello")
    }

    func testPrefixExtensionFromSpatialAndSpellingIsAlwaysCompletion() async throws {
        let source = SpatialWordDecoder(lexicons: [.english: lexicon([("keyboard", 100)])])
        for spatial in [true, false] {
            let ac = AutocorrectEngine(checker: SpatialChecker(valid: ["keyboard"],
                guesses: spatial ? [] : ["keyboard"]), spatialDecoder: spatial ? source : nil)
            let target = FixtureTextTarget(text: "keyboar")
            target.autocapitalizationType = UITextAutocapitalizationType.none
            let keyboard = FullKeyboardEngine(target: target, autocorrect: ac)
            keyboard.width = 393
            keyboard.configureForField()
            track(evidence("keyboar", aimedAt: "keyboar", layout: keyboard.layout), in: ac)
            keyboard.refreshSuggestions()
            await keyboard.waitForSuggestions()
            let suggestion = try XCTUnwrap(keyboard.suggestions.first { $0.replacement == "keyboard" })
            XCTAssertTrue(suggestion.isCompletion)
            keyboard.acceptSuggestion(suggestion)
            XCTAssertEqual(target.text, "keyboard ")
            XCTAssertEqual(ac.learning.diagnostics[.manualCompletionPick], 1)
            XCTAssertEqual(ac.learning.diagnostics[.manualAlternativePick], 0)
            XCTAssertEqual(ac.learning.diagnostics.acceptedLabels, 0)
            XCTAssertEqual(ac.learning.model.lexicon.counts["keyboard"], 1)
        }
    }

    func testNotYetLoadedResourcesNeverBlockSpellingFallback() {
        let source = SpatialWordDecoder(bundle: .main)
        XCTAssertTrue(source.isResourceLoading)
        let word = evidence("gello", aimedAt: "hello")
        guard case .unavailable(.resource) = source.decodeDetailed(word, languages: [.english]) else {
            return XCTFail("Decode must not synchronously load word data")
        }
        let ac = AutocorrectEngine(checker: SpatialChecker(valid: ["hello"], guesses: ["hello"]),
                                   spatialDecoder: source)
        track(word, in: ac)
        for _ in 0..<5 {
            _ = ac.suggestions(beforeInput: "gello", field: .text, autocorrectionType: .default)
        }
        XCTAssertEqual(ac.learning.diagnostics[.suggestionDecodes], 0)
        XCTAssertEqual(ac.learning.diagnostics.suggestionMs.reduce(0, +), 0)
        XCTAssertEqual(ac.learning.diagnostics[.boundaries], 0)
        XCTAssertEqual(replacement(ac), "hello")
        XCTAssertEqual(ac.learning.diagnostics[.resourceLoading], 1)
        XCTAssertEqual(ac.learning.diagnostics[.refusedMissingResource], 0)
        XCTAssertEqual(ac.learning.diagnostics[.autoSpellingFallback], 1)
        XCTAssertTrue(source.isResourceLoading)
        XCTAssertNotNil(decoder().decode(word, languages: [.english]), "Injected lexicons remain synchronous")
    }

    func testSettledLiteralChecksWordSuffixNotEntireHostContext() {
        let ac = AutocorrectEngine(checker: SpatialChecker(valid: ["hello"]), spatialDecoder: decoder())
        track(evidence("hello", aimedAt: "hello"), in: ac)
        XCTAssertNil(replacement(ac, "hello"))
        ac.settleFeedback(beforeInput: "public words hello ", insertedLetter: "w", afterInput: "hello w")
        XCTAssertEqual(ac.learning.diagnostics.acceptedLabels, 5)
        XCTAssertEqual(ac.learning.model.lexicon.counts["hello"], 1)
    }

    func testGeneratedArenaCapRefusesAutomaticReplacement() throws {
        // Four equidistant letters on a pitch-coordinate circle. Other keys are
        // closer, so the remaining-tap bound stays loose despite exact subtree priors.
        // Four-way branching exercises the arena independently of the pop budget.
        let letters = Array("ghtu")
        let entries: [(String, UInt32)] = (0..<16_384).map { value in
            var digits = value
            let spelling = (0..<7).map { _ -> Character in
                let letter = letters[digits % 4]
                digits /= 4
                return letter
            }
            return (String(spelling), 1)
        }
        let decoder = SpatialWordDecoder(lexicons: [.english: lexicon(entries + [("world", 1_000_000_000)])])
        var word = evidence(String(repeating: "g", count: 7), aimedAt: String(repeating: "g", count: 7))
        let g = try XCTUnwrap(word.layout.key(.character("g"))).frame
        let h = try XCTUnwrap(word.layout.key(.character("h"))).frame
        let y = try XCTUnwrap(word.layout.key(.character("y"))).frame
        let point = CGPoint(x: (g.midX + h.midX) / 2,
                            y: y.midY + 0.125 * (g.height + word.layout.metrics.rowGap))
        word.samples = word.samples.map { .init(text: $0.text, point: point, key: $0.key) }
        let result = try XCTUnwrap(decoder.decode(word, languages: [.english]))
        XCTAssertFalse(result.complete)
        XCTAssertLessThanOrEqual(result.generated, 12_000)
        XCTAssertLessThan(result.visits, 6_000, "an arena cap, not the pop budget, stops this fixture")
        XCTAssertNil(result.automaticCandidate)
    }

    func testDetailedUnavailableAndHardLimits() throws {
        let missing = SpatialWordDecoder(lexicons: [:])
        if case .unavailable(.resource) = missing.decodeDetailed(evidence("hello", aimedAt: "hello"), languages: [.english]) {} else {
            XCTFail("missing selected resource must be diagnosed")
        }
        if case .unavailable(.evidence) = missing.decodeDetailed(evidence("hi", aimedAt: "hi"), languages: [.english]) {} else {
            XCTFail("short evidence must be diagnosed")
        }
        let word = evidence("gello", aimedAt: "hello")
        let zero = try XCTUnwrap(decoder().decode(word, languages: [.english, .german], budget: 0))
        XCTAssertFalse(zero.complete)
        XCTAssertEqual(zero.visits, 0)
        XCTAssertEqual(zero.generated, 2, "both languages enter the same queue before any pops")
        let result = try XCTUnwrap(decoder().decode(word, languages: [.english, .german]))
        XCTAssertTrue(result.complete)
        XCTAssertLessThanOrEqual(result.visits, SpatialWordDecoder.searchBudget)
        XCTAssertLessThanOrEqual(result.generated, SpatialWordDecoder.maxGenerated)
    }

    func testBundledWordDataLoadsInAppAndHasExpectedUnicodeWords() throws {
        let lexicons = try XCTUnwrap(BundledKeyboardData.lexicons)
        XCTAssertNotNil(lexicons[.german]?.logPrior(for: "straße"))
        XCTAssertNotNil(lexicons[.english]?.logPrior(for: "keyboard"))
    }
}

private extension SpatialWordDecoder.Result {
    var automaticCandidate: SpatialWordDecoder.Candidate? {
        if case .replace(let candidate) = automaticDecision(literalIsValid: false) { return candidate }
        return nil
    }
}

@MainActor
private final class SpatialChecker: TextChecking {
    let valid: Set<String>
    let values: [String]
    let prefixes: [String]
    private(set) var guessCalls = 0
    init(valid: Set<String>, guesses: [String] = [], completions: [String] = []) {
        self.valid = valid
        values = guesses
        prefixes = completions
    }
    func isWordValid(_ word: String) -> Bool { valid.contains(word) }
    func guesses(for word: String) -> [String] { guessCalls += 1; return values }
    func completions(for prefix: String) -> [String] { prefixes }
}
