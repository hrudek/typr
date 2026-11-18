import UIKit
import XCTest
@testable import Typr

@MainActor
final class KeyboardLearningIntegrationTests: XCTestCase {
    private final class Checker: TextChecking {
        var valid: Set<String>
        var answers: [String: [String]]
        init(valid: Set<String> = ["hello", "world", "the"], answers: [String: [String]] = [:]) {
            self.valid = valid
            self.answers = answers
        }
        func isWordValid(_ word: String) -> Bool { valid.contains(word) }
        func guesses(for word: String) -> [String] { answers[word] ?? [] }
        func completions(for prefix: String) -> [String] { [] }
    }

    private func keyboard(session: KeyboardLearningSession? = nil,
                          checker: Checker? = nil) -> (FullKeyboardEngine, FixtureTextTarget) {
        let target = FixtureTextTarget()
        target.autocapitalizationType = UITextAutocapitalizationType.none
        let ac = AutocorrectEngine(checker: checker ?? Checker(), learning: session, spatialDecoder: nil)
        let engine = FullKeyboardEngine(target: target, autocorrect: ac)
        engine.width = 393
        engine.clock = { 100 } // No accidental double-space conversion except when explicitly requested.
        engine.configureForField()
        return (engine, target)
    }

    private func tap(_ kind: KeyKind, _ engine: FullKeyboardEngine) {
        guard let key = engine.layout.key(kind) else { XCTFail("Missing synthetic key"); return }
        let point = CGPoint(x: key.frame.midX, y: key.frame.midY)
        engine.touchBegan(id: 1, at: point)
        engine.touchEnded(id: 1, at: point)
    }

    private func type(_ text: String, _ engine: FullKeyboardEngine) {
        for letter in text { tap(letter == " " ? .space : .character(String(letter)), engine) }
    }

    func testUndoContextSessionAndDecayWithoutSessionBlacklist() throws {
        let session = KeyboardLearningSession()
        let (engine, target) = keyboard(session: session)
        type("send to teh ", engine)
        XCTAssertEqual(target.text, "send to the ")
        tap(.delete, engine)
        XCTAssertEqual(target.text, "send to teh")
        XCTAssertEqual(session.model.state.rejected.first?.context, "send to")
        let ac = engine.autocorrect
        var immediate = 0
        for prefix in ["send to ", "reply to "] {
            if ac.replacementOnSpace(beforeInput: prefix + "teh", field: .text,
                                     autocorrectionType: .default) != nil { immediate += 1 }
        }
        XCTAssertEqual(immediate, 0)
        for _ in 0..<64 { session.recordWord("hello") }
        XCTAssertNil(ac.replacementOnSpace(beforeInput: "send to teh", field: .text, autocorrectionType: .default))
        XCTAssertNotNil(ac.replacementOnSpace(beforeInput: "reply to teh", field: .text, autocorrectionType: .default))
        for _ in 0..<192 { session.recordWord("hello") }
        XCTAssertNotNil(ac.replacementOnSpace(beforeInput: "send to teh", field: .text, autocorrectionType: .default))
        print("EVAL R2_3_session undo=1 immediate_same=0/1 immediate_different=0/1 event64_same=0/1 event64_different=1/1 event256_same=1/1 literal_confirmation=not_in_this_session")
    }

    func testFreshLiteralAfterUndoBecomesKeptButRestoredWordDoesNot() {
        let session = KeyboardLearningSession()
        let (engine, _) = keyboard(session: session)
        type("teh ", engine)
        tap(.delete, engine)
        type(" w", engine)
        XCTAssertFalse(session.protections.isKept("teh"), "Undo's restored taps are not a new literal")
        let (fresh, target) = keyboard(session: session)
        type("teh w", fresh)
        XCTAssertEqual(target.text, "teh w")
        XCTAssertTrue(session.protections.isKept("teh"))
        for _ in 0..<256 { session.recordWord("hello") }
        XCTAssertTrue(session.model.state.rejected.isEmpty)
        XCTAssertNil(fresh.autocorrect.replacementOnSpace(beforeInput: "teh", field: .text, autocorrectionType: .default))
        print("EVAL R2_3_literal undo_kept=0 restored_kept=0 fresh_settled_kept=1 post_decay_auto=0")
    }

    func testManualFeedbackRetainsFastAimButExternalContextResetsIt() throws {
        let session = KeyboardLearningSession()
        let (engine, _) = keyboard(session: session)
        let grid = engine.layout
        let key = try XCTUnwrap(grid.key(.character("e")))
        let label = TouchLabel(point: CGPoint(x: key.frame.midX + 0.2 * (key.frame.width + grid.metrics.gap),
                                              y: key.frame.midY), letter: "e")
        session.learn(Array(repeating: label, count: 40), layout: grid, source: .keep)
        type("hello", engine)
        engine.acceptSuggestion(.init(displayText: "hello", replacement: "hello", kind: .keepLiteral))
        let slow = PersonalTypingModel(state: session.model.state).calibration(for: grid)
        XCTAssertNotEqual(session.calibration(for: grid), slow, "manual feedback must not immediately erase its own fast updates")
        engine.textDidChange()
        XCTAssertEqual(session.calibration(for: grid), slow)
    }

    func testValidLiteralSettlesOnlyWhenIntactAndNextLetterStarts() {
        let (engine, target) = keyboard()
        type("hello ", engine)
        let session = engine.autocorrect.learning
        XCTAssertEqual(target.text, "hello ")
        XCTAssertEqual(session.diagnostics.acceptedLabels, 0)
        XCTAssertNil(session.model.lexicon.counts["hello"])
        type("w", engine)
        XCTAssertEqual(session.model.lexicon.counts["hello"], 1)
        XCTAssertEqual(session.diagnostics.acceptedBySource["literalValid"], 5)
        engine.refreshSuggestions()
        XCTAssertEqual(session.model.lexicon.counts["hello"], 1)
    }

    func testSeparatorsReturnAndPunctuationNeverSettleLiteral() {
        for ending in [KeyKind.space, .returnKey, .character(".")] {
            let (engine, _) = keyboard()
            type("hello ", engine)
            if ending == .character(".") { tap(.layerSwitch(.numbers), engine) }
            tap(ending, engine)
            if ending == .character(".") { tap(.layerSwitch(.letters), engine) }
            type("w", engine)
            let session = engine.autocorrect.learning
            XCTAssertTrue(session.model.lexicon.counts.isEmpty)
            XCTAssertEqual(session.diagnostics.acceptedLabels, 0)
            XCTAssertEqual(session.diagnostics[.boundaries], 1)
        }
        let (engine, target) = keyboard()
        type("hello ", engine)
        engine.clock = { 102 } // A second space outside double-space-period's time window.
        tap(.space, engine)
        type("w", engine)
        XCTAssertEqual(target.text, "hello  w")
        XCTAssertTrue(engine.autocorrect.learning.model.lexicon.counts.isEmpty)
        XCTAssertEqual(engine.autocorrect.learning.diagnostics.acceptedLabels, 0)
    }

    func testDeleteRetypeEvidenceCanDecodeButNeverTeachTheWord() {
        for choice in 0..<3 {
            let (engine, _) = keyboard()
            type("hella", engine)
            tap(.delete, engine)
            type("o", engine)
            XCTAssertNotNil(engine.autocorrect.touchInput.evidence(beforeInput: "hello"))
            if choice == 0 { type(" w", engine) }
            else {
                engine.acceptOwnedFixtureSuggestion(KeyboardSuggestion(displayText: choice == 1 ? "hello" : "help",
                    replacement: choice == 1 ? "hello" : "help", kind: choice == 1 ? .keepLiteral : .secondary))
            }
            let session = engine.autocorrect.learning
            XCTAssertTrue(session.model.lexicon.counts.isEmpty)
            XCTAssertEqual(session.diagnostics.acceptedLabels, 0)
            XCTAssertTrue(session.model.state.layouts.isEmpty)
        }
        let (engine, _) = keyboard()
        type("hello", engine)
        for _ in 0..<5 { tap(.delete, engine) }
        type("hello w", engine)
        XCTAssertTrue(engine.autocorrect.learning.model.lexicon.counts.isEmpty)
        XCTAssertEqual(engine.autocorrect.learning.diagnostics.acceptedLabels, 0)
    }

    private func missOThenRetype(_ engine: FullKeyboardEngine) throws {
        let p = try XCTUnwrap(engine.layout.key(.character("p")))
        let miss = CGPoint(x: p.frame.minX + 1, y: p.frame.midY)
        engine.touchBegan(id: 1, at: miss)
        engine.touchEnded(id: 1, at: miss)
        tap(.delete, engine)
        type("o", engine)
    }

    func testRetypedMissTeachesTheErasedTapOnceTheWordSettles() throws {
        let session = KeyboardLearningSession()
        let (engine, target) = keyboard(session: session)
        type("hell", engine)
        try missOThenRetype(engine)
        type(" ", engine)
        XCTAssertEqual(session.diagnostics.acceptedLabels, 0, "nothing is learned before the word settles")
        type("w", engine)
        XCTAssertEqual(target.text, "hello w")
        XCTAssertEqual(session.diagnostics.acceptedBySource["retype"], 1)
        XCTAssertEqual(session.diagnostics.acceptedLabels, 1, "the edited word itself still never teaches")
        XCTAssertTrue(session.model.lexicon.counts.isEmpty)
        let stats = try XCTUnwrap(session.model.state.layouts.values.first?.keys["o"])
        XCTAssertEqual(stats.n, 1)
        let o = try XCTUnwrap(engine.layout.key(.character("o")))
        let edge = Double(o.frame.width / 2 / (o.frame.width + engine.layout.metrics.gap))
        XCTAssertGreaterThan(stats.meanX, edge, "the label sits where the miss landed, past o's right edge")
    }

    func testRetypeDoesNotTeachFarTapsSameLettersUnsettledOrCorrectedWords() throws {
        var text = ""
        func retypeLabels(_ run: (FullKeyboardEngine) throws -> Void) rethrows -> Int? {
            let session = KeyboardLearningSession()
            let (engine, target) = keyboard(session: session)
            try run(engine)
            text = target.text
            return session.diagnostics.acceptedBySource["retype"]
        }
        XCTAssertNil(retypeLabels { engine in
            type("hellp", engine); tap(.delete, engine); type("o w", engine)
        }, "a tap in the middle of p is no miss of o")
        XCTAssertNil(try retypeLabels { engine in
            type("hell", engine); try missOThenRetype(engine)
            tap(.delete, engine); type("o w", engine)
        }, "deleting the retyped letter drops its label")
        XCTAssertNil(try retypeLabels { engine in
            type("hell", engine); try missOThenRetype(engine)
            tap(.returnKey, engine); type("w", engine)
        }, "a word that never settles teaches nothing")
        XCTAssertNil(try retypeLabels { engine in
            type("hell", engine); try missOThenRetype(engine)
            engine.textDidChange(); type(" w", engine)
        }, "a cursor or host change drops the evidence")
        XCTAssertNil(retypeLabels { engine in
            type("te", engine)
            let j = engine.layout.key(.character("j"))!
            let miss = CGPoint(x: j.frame.minX + 1, y: j.frame.midY)
            engine.touchBegan(id: 1, at: miss)
            engine.touchEnded(id: 1, at: miss)
            tap(.delete, engine)
            type("h w", engine)
        }, "an automatic replacement teaches nothing")
        XCTAssertEqual(text, "the w")
    }

    func testRetypeAfterDeletingTheWholeWordStillLabelsTheFirstTap() throws {
        let session = KeyboardLearningSession()
        let (engine, target) = keyboard(session: session)
        let g = try XCTUnwrap(engine.layout.key(.character("g")))
        let miss = CGPoint(x: g.frame.maxX - 1, y: g.frame.midY)
        engine.touchBegan(id: 1, at: miss)
        engine.touchEnded(id: 1, at: miss)
        tap(.delete, engine)
        type("hello w", engine)
        XCTAssertEqual(target.text, "hello w")
        XCTAssertEqual(session.diagnostics.acceptedBySource["retype"], 1)
    }

    func testSpaceTapTeachesOnceTheNextWordEndsSeparately() throws {
        let session = KeyboardLearningSession()
        let (engine, target) = keyboard(session: session)
        let space = try XCTUnwrap(engine.layout.key(.space))
        let low = CGPoint(x: space.frame.midX, y: space.frame.maxY - 2)
        type("hello", engine)
        engine.touchBegan(id: 1, at: low)
        engine.touchEnded(id: 1, at: low)
        type("world", engine)
        XCTAssertNil(session.diagnostics.acceptedBySource["space"])
        type(" n", engine)
        XCTAssertEqual(target.text, "hello world n")
        XCTAssertEqual(session.diagnostics.acceptedBySource["space"], 1, "the Space after world waits for its next word")
        XCTAssertGreaterThan(try XCTUnwrap(session.model.state.layouts.values.first?.space).meanY, 0)
    }

    func testJoinedOrInterruptedSpaceNeverTeaches() throws {
        func spaceLabels(_ run: (FullKeyboardEngine) -> Void) -> Int? {
            let session = KeyboardLearningSession()
            let (engine, _) = keyboard(session: session)
            run(engine)
            return session.diagnostics.acceptedBySource["space"]
        }
        XCTAssertNil(spaceLabels { engine in
            type("hello ", engine); engine.textDidChange(); type("world n", engine)
        }, "a cursor or host change drops the Space")
        XCTAssertNil(spaceLabels { engine in
            type("hello world", engine)
            tap(.layerSwitch(.numbers), engine); tap(.character("."), engine); tap(.layerSwitch(.letters), engine)
            type(" n", engine)
        }, "the next word must end with a Space of its own")
        XCTAssertNil(spaceLabels { engine in
            type("a o", engine)
            tap(.delete, engine); tap(.delete, engine)
            type("bout", engine)
            engine.typeSpaceFromTyprKey()
            type("a", engine)
            engine.typeSpaceFromTyprKey()
            type("word ", engine)
        }, "a deleted Space never teaches, even when the text later reads like it again")
        let ends: [(String, Int?)] = [("about ", nil), ("a out ", 1)]
        for (end, expected) in ends {
            XCTAssertEqual(spaceLabels { engine in
                let ac = engine.autocorrect
                let point = CGPoint(x: engine.layout.key(.space)!.frame.midX, y: engine.layout.key(.space)!.frame.midY)
                ac.spaceTyped(at: point, layout: engine.layout, afterInput: "a ")
                ac.settleFeedback(beforeInput: "a ", insertedLetter: "o", afterInput: "a o")
                ac.spaceTyped(at: point, layout: engine.layout, afterInput: end)
            }, expected, end)
        }
    }

    func testAutomaticOutputNeverTeachesWithoutFeedback() {
        for (typed, checker, counter) in [
            ("teh", Checker(), KeyboardDiagnostics.Counter.autoRule),
            ("helo", Checker(answers: ["helo": ["hello"]]), .autoSpellingFallback)
        ] {
            let (engine, _) = keyboard(checker: checker)
            type(typed + " w", engine)
            let session = engine.autocorrect.learning
            XCTAssertEqual(session.diagnostics[counter], 1)
            XCTAssertEqual(session.diagnostics.acceptedLabels, 0)
            XCTAssertTrue(session.model.lexicon.counts.isEmpty)
        }
    }

    func testUndoLearnsIdentityAndRejectsPairWithoutKeepOrWordCount() {
        let (engine, target) = keyboard()
        type("teh ", engine)
        tap(.delete, engine)
        let session = engine.autocorrect.learning
        XCTAssertEqual(target.text, "teh")
        XCTAssertEqual(session.diagnostics.acceptedBySource["undo"], 3)
        XCTAssertFalse(session.model.lexicon.isKept("teh"))
        XCTAssertTrue(session.model.lexicon.isRejected(typed: "teh", replacement: "the"))
        XCTAssertTrue(session.model.lexicon.counts.isEmpty)
        XCTAssertEqual(session.diagnostics[.undoRule], 1)
        tap(.space, engine)
        type("teh ", engine)
        XCTAssertEqual(target.text, "teh teh ")
        XCTAssertEqual(session.diagnostics[.autoRule], 1)
    }

    func testContractionUndoPersistsRejectedPairAcrossReloadWithoutKeep() throws {
        let name = "KeyboardLearning-contraction-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = KeyboardLearningSession(store: KeyboardLearningStore(directory: directory, defaults: defaults),
                                              defaults: defaults)
        let (engine, target) = keyboard(session: session)
        type("dont ", engine)
        XCTAssertEqual(target.text, "don't ")
        tap(.delete, engine)
        XCTAssertEqual(target.text, "dont")
        XCTAssertTrue(session.protections.isRejected(typed: "dont", replacement: "don't"))
        XCTAssertFalse(session.protections.isKept("dont"))
        XCTAssertEqual(session.diagnostics[.correctionsRejected], 1)
        session.flush()
        let reloaded = KeyboardLearningSession(store: KeyboardLearningStore(directory: directory, defaults: defaults),
                                               defaults: defaults)
        XCTAssertTrue(reloaded.protections.isRejected(typed: "dont", replacement: "don't"))
        let (next, nextTarget) = keyboard(session: reloaded)
        type("dont ", next)
        XCTAssertEqual(nextTarget.text, "dont ")
        XCTAssertEqual(reloaded.diagnostics[.refusedProtected], 1)
        XCTAssertEqual(reloaded.diagnostics[.autoRule], 1, "Reload must not repeat the correction")
    }

    func testPhraseTextReplacementUndoSuppressesOnlyForCurrentSession() throws {
        let name = "KeyboardLearning-phrase-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = KeyboardLearningSession(store: KeyboardLearningStore(directory: directory, defaults: defaults),
                                              defaults: defaults)
        let (engine, target) = keyboard(session: session)
        engine.autocorrect.loadLexiconEntries([(userInput: "omw", documentText: "On my way!")])
        type("omw ", engine)
        XCTAssertEqual(target.text, "On my way! ")
        tap(.delete, engine)
        XCTAssertEqual(target.text, "omw")
        XCTAssertFalse(session.protections.isKept("omw"))
        XCTAssertFalse(session.protections.isRejected(typed: "omw", replacement: "On my way!"))
        tap(.space, engine)
        XCTAssertEqual(target.text, "omw ", "Undo still suppresses for this session")
        session.flush()
        let reloaded = KeyboardLearningSession(store: KeyboardLearningStore(directory: directory, defaults: defaults),
                                               defaults: defaults)
        let (next, nextTarget) = keyboard(session: reloaded)
        next.autocorrect.loadLexiconEntries([(userInput: "omw", documentText: "On my way!")])
        type("omw ", next)
        XCTAssertEqual(nextTarget.text, "On my way! ")
    }

    func testSpellingUndoHasSeparateCounter() {
        let (engine, _) = keyboard(checker: Checker(answers: ["helo": ["hello"]]))
        type("helo ", engine)
        tap(.delete, engine)
        XCTAssertEqual(engine.autocorrect.learning.diagnostics[.undoSpelling], 1)
        XCTAssertEqual(engine.autocorrect.learning.diagnostics.acceptedBySource["undo"], 4)
    }

    func testImmediateBackspaceRevertsNewKeepButNotExistingProtection() {
        for alreadyKept in [false, true] {
            let (engine, target) = keyboard()
            if alreadyKept { engine.autocorrect.learning.keep("helo") }
            type("helo", engine)
            engine.acceptOwnedFixtureSuggestion(.init(displayText: "helo", replacement: "helo", kind: .keepLiteral))
            XCTAssertTrue(engine.autocorrect.learning.protections.isKept("helo"))
            tap(.delete, engine)
            XCTAssertEqual(target.text, "helo")
            XCTAssertEqual(engine.autocorrect.learning.protections.isKept("helo"), alreadyKept)
            XCTAssertFalse(engine.autocorrect.learning.protections.isRejected(typed: "helo", replacement: "helo"))
        }
    }

    func testPickingReplacementImmediatelyRevertsNewRejection() async {
        let (engine, target) = keyboard()
        type("teh ", engine)
        tap(.delete, engine)
        XCTAssertTrue(engine.autocorrect.learning.protections.isRejected(typed: "teh", replacement: "the"))
        await engine.waitForSuggestions()
        let replacement = engine.suggestions.first { $0.replacement == "the" }
        XCTAssertNotNil(replacement, "The replacement must remain explicitly available after undo")
        if let replacement { engine.acceptSuggestion(replacement) }
        XCTAssertEqual(target.text, "the ")
        XCTAssertFalse(engine.autocorrect.learning.protections.isRejected(typed: "teh", replacement: "the"))
        type("teh ", engine)
        XCTAssertEqual(target.text, "the the ", "Session suppression must be reverted too")
    }

    func testRejectionRevertDoesNotCrossNewTypingOrEraseOlderPair() {
        let (engine, _) = keyboard()
        type("teh ", engine)
        tap(.delete, engine)
        type("x", engine)
        engine.acceptOwnedFixtureSuggestion(.init(displayText: "the", replacement: "the", kind: .secondary))
        XCTAssertTrue(engine.autocorrect.learning.protections.isRejected(typed: "teh", replacement: "the"))

        let ac = AutocorrectEngine(checker: Checker(), spatialDecoder: nil)
        ac.learning.rejectCorrection(typed: "teh", replacement: "the")
        ac.recordUndo(.init(original: "teh", insertedText: "the "))
        ac.recordSuggestionFeedback(.init(displayText: "the", replacement: "the", kind: .secondary),
                                    literal: "teh", evidence: nil)
        XCTAssertTrue(ac.learning.protections.isRejected(typed: "teh", replacement: "the"))
    }

    func testKeepChipCapturesEvidenceBeforeInvalidation() {
        let (engine, target) = keyboard()
        type("helo", engine)
        guard let literal = engine.suggestions.first else { return XCTFail("No literal chip") }
        engine.acceptSuggestion(literal)
        let session = engine.autocorrect.learning
        XCTAssertEqual(target.text, "helo ")
        XCTAssertEqual(session.diagnostics.acceptedBySource["keep"], 4)
        XCTAssertTrue(session.model.lexicon.isKept("helo"))
        XCTAssertEqual(session.model.lexicon.counts["helo"], 1)
        XCTAssertEqual(session.diagnostics[.keepChip], 1)
        XCTAssertNil(engine.autocorrect.touchInput.evidence(beforeInput: target.text))
    }

    func testManualAlternativeUsesOnlyUniqueAlignmentAndCompletionUsesNoTaps() {
        let (engine, _) = keyboard()
        type("helo", engine)
        engine.acceptOwnedFixtureSuggestion(KeyboardSuggestion(displayText: "hello", replacement: "hello", kind: .secondary))
        let session = engine.autocorrect.learning
        // Repeated l's are ambiguous; h, e and o remain uniquely aligned.
        XCTAssertEqual(session.diagnostics.acceptedBySource["manualPick"], 3)
        XCTAssertEqual(session.model.lexicon.counts["hello"], 1)
        XCTAssertEqual(session.diagnostics[.manualAlternativePick], 1)
        type("wor", engine)
        engine.acceptOwnedFixtureSuggestion(KeyboardSuggestion(displayText: "world", replacement: "world", kind: .secondary,
                                                   isCompletion: true))
        XCTAssertEqual(session.diagnostics.acceptedBySource["manualPick"], 3)
        XCTAssertEqual(session.model.lexicon.counts["world"], 1)
        XCTAssertEqual(session.diagnostics[.manualCompletionPick], 1)
    }

    func testManualAlignmentDropsDistantSubstitutionAndCountsRejection() {
        let (engine, _) = keyboard()
        type("pello", engine)
        engine.acceptOwnedFixtureSuggestion(KeyboardSuggestion(displayText: "hello", replacement: "hello", kind: .secondary))
        let session = engine.autocorrect.learning
        XCTAssertEqual(session.diagnostics.acceptedBySource["manualPick"], 4)
        XCTAssertEqual(session.diagnostics.rejectedByReason["outlier"], 1)
        XCTAssertEqual(session.model.lexicon.counts["hello"], 1)
    }

    func testRejectedDeterministicPairIsNotRetriedWithoutKeep() {
        let (engine, _) = keyboard()
        engine.autocorrect.learning.rejectCorrection(typed: "teh", replacement: "the")
        XCTAssertFalse(engine.autocorrect.learning.model.lexicon.isKept("teh"))
        XCTAssertNil(engine.autocorrect.replacementOnSpace(beforeInput: "teh", field: .text,
                                                          autocorrectionType: .default))
        XCTAssertEqual(engine.autocorrect.learning.diagnostics[.refusedProtected], 1)
    }

    func testSwitchChangeDiscardsAnUnsettledLiteral() throws {
        let name = "KeyboardLearning-toggle-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let session = KeyboardLearningSession(defaults: defaults)
        let (engine, _) = keyboard(session: session)
        type("hello ", engine)
        defaults.set(false, forKey: "keyboard.personalLearning")
        engine.autocorrect.syncLearning()
        defaults.set(true, forKey: "keyboard.personalLearning")
        engine.autocorrect.syncLearning()
        type("w", engine)
        XCTAssertEqual(session.diagnostics.acceptedLabels, 0)
        XCTAssertTrue(session.model.lexicon.counts.isEmpty)
    }

    func testDeletedBackExternalSelectionFieldDismissalAndLayoutDiscardPending() {
        for invalidate in 0..<7 {
            let (engine, target) = keyboard()
            type("hello ", engine)
            switch invalidate {
            case 0: tap(.delete, engine) // Delete the separator, then retype it: no delayed trust.
                tap(.space, engine)
            case 1: target.insertText("x "); engine.textDidChange()
            case 2: target.adjustTextPosition(byCharacterOffset: -1); engine.discardTouchEvidence()
            case 3: engine.configureForField()
            case 4: engine.cancelAllTouches()
            case 5: engine.width = 440
            default: target.insertText("x ") // Even a host that omits its callback fails the suffix check.
            }
            type("w", engine)
            XCTAssertEqual(engine.autocorrect.learning.diagnostics.acceptedLabels, 0, "case \(invalidate)")
            XCTAssertTrue(engine.autocorrect.learning.model.lexicon.counts.isEmpty, "case \(invalidate)")
        }
    }

    func testAccentSlideAndMissingEvidenceNeverSupplyLabels() {
        for gesture in 0..<2 {
            let (engine, _) = keyboard()
            guard let a = engine.layout.key(.character("a")),
                  let s = engine.layout.key(.character("s")) else { return XCTFail("Missing keys") }
            let start = CGPoint(x: a.frame.midX, y: a.frame.midY)
            engine.touchBegan(id: 1, at: start)
            if gesture == 0 {
                XCTAssertTrue(engine.openAccentMenuIfEligible(forTouch: 1))
                engine.touchEnded(id: 1, at: start)
            } else {
                let end = CGPoint(x: s.frame.midX, y: s.frame.midY)
                engine.touchMoved(id: 1, to: end)
                engine.touchEnded(id: 1, at: end)
            }
            type("he", engine)
            engine.acceptOwnedFixtureSuggestion(KeyboardSuggestion(displayText: "hello", replacement: "hello", kind: .secondary))
            XCTAssertEqual(engine.autocorrect.learning.diagnostics.acceptedLabels, 0)
        }
    }

    func testLearningOffStillProtectsExplicitKeepsAndCountsDiagnostics() {
        let name = "KeyboardLearning-off-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else { return XCTFail("No defaults") }
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "keyboard.personalLearning")
        let session = KeyboardLearningSession(defaults: defaults)
        let (engine, _) = keyboard(session: session)
        type("hello world", engine)
        XCTAssertEqual(session.diagnostics.acceptedLabels, 0)
        XCTAssertTrue(session.model.lexicon.counts.isEmpty)
        engine.acceptOwnedFixtureSuggestion(KeyboardSuggestion(displayText: "world", replacement: "world", kind: .keepLiteral))
        XCTAssertTrue(session.model.lexicon.isKept("world"))
        type("teh", engine)
        engine.acceptOwnedFixtureSuggestion(KeyboardSuggestion(displayText: "teh", replacement: "teh", kind: .keepLiteral))
        XCTAssertTrue(session.model.lexicon.isKept("teh"))
        XCTAssertEqual(session.diagnostics[.keepChip], 2)
        XCTAssertEqual(session.diagnostics[.wordsKept], 2)
        XCTAssertEqual(session.diagnostics[.boundaries], 1)
        XCTAssertEqual(session.diagnostics.acceptedLabels, 0)
        XCTAssertNil(engine.autocorrect.replacementOnSpace(beforeInput: "teh", field: .text,
                                                          autocorrectionType: .default))
    }

    func testLearningOffSingleLetterKeepCountsChipButDoesNotStoreWord() throws {
        let name = "KeyboardLearning-off-single-letter-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "keyboard.personalLearning")
        let session = KeyboardLearningSession(defaults: defaults)
        let (engine, target) = keyboard(session: session)
        type("w", engine)
        engine.acceptOwnedFixtureSuggestion(KeyboardSuggestion(displayText: "w", replacement: "w", kind: .keepLiteral))
        XCTAssertEqual(target.text, "w ")
        XCTAssertEqual(session.diagnostics[.keepChip], 1)
        XCTAssertEqual(session.diagnostics[.wordsKept], 0)
        XCTAssertFalse(session.model.lexicon.isKept("w"))
        XCTAssertTrue(session.model.lexicon.counts.isEmpty)
        XCTAssertEqual(session.diagnostics.acceptedLabels, 0)
    }

    func testLearningOffUndoStillRejectsWithoutPermanentKeep() throws {
        let name = "KeyboardLearning-off-undo-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "keyboard.personalLearning")
        let session = KeyboardLearningSession(defaults: defaults)
        let (engine, _) = keyboard(session: session)
        type("teh ", engine)
        tap(.delete, engine)
        XCTAssertTrue(session.protections.isRejected(typed: "teh", replacement: "the"))
        XCTAssertFalse(session.protections.isKept("teh"))
        XCTAssertEqual(session.diagnostics[.correctionsRejected], 1)
        XCTAssertEqual(session.diagnostics.acceptedLabels, 0)
        XCTAssertTrue(session.model.lexicon.counts.isEmpty)
        engine.acceptOwnedFixtureSuggestion(KeyboardSuggestion(displayText: "teh", replacement: "teh", kind: .keepLiteral))
        XCTAssertTrue(session.protections.isKept("teh"), "Keep chip remains permanent while learning is off")
        XCTAssertEqual(session.diagnostics.acceptedLabels, 0)
        XCTAssertTrue(session.model.lexicon.counts.isEmpty)
    }

    func testAutomaticUndoMethodMappingAndManualUndosDoNotCountAsAutomatic() {
        let ac = AutocorrectEngine(checker: Checker(), spatialDecoder: nil)
        ac.recordUndo(.init(original: "teh", insertedText: "the ", kind: .autoSpatial))
        ac.recordUndo(.init(original: "helo", insertedText: "hello ", kind: .autoSpelling))
        ac.recordUndo(.init(original: "dont", insertedText: "don't ", kind: .autoRule))
        XCTAssertEqual(ac.learning.diagnostics[.undoSpatial], 1)
        XCTAssertEqual(ac.learning.diagnostics[.undoSpelling], 1)
        XCTAssertEqual(ac.learning.diagnostics[.undoRule], 1)
        let before = ac.learning.diagnostics
        for wasNew in [false, true] {
            ac.recordUndo(.init(original: "helo", insertedText: "helo ", keptWordWasNew: wasNew))
        }
        let boundary = KeyboardBoundaryDecoder.Candidate(kind: .split, original: "helloworld",
            replacement: "hello world", score: 1, baseline: 0)
        ac.recordUndo(.init(original: "helloworld", insertedText: "hello world ", boundary: boundary))
        for counter in [KeyboardDiagnostics.Counter.undoSpatial, .undoSpelling, .undoRule] {
            XCTAssertEqual(ac.learning.diagnostics[counter], before[counter])
        }
        XCTAssertEqual(ac.learning.diagnostics.acceptedLabels, before.acceptedLabels)
    }

    func testSpellingCompletionRefusesBelowMarginWithoutTapEvidence() {
        // `hell` is a contraction homograph and is refused before spelling search.
        // Use an unprotected prefix so this exercises automatic's suffix refusal.
        let ac = AutocorrectEngine(checker: Checker(answers: ["worl": ["world"]]), spatialDecoder: nil)
        XCTAssertNil(ac.replacementOnSpace(beforeInput: "worl", field: .text, autocorrectionType: .default))
        XCTAssertEqual(ac.learning.diagnostics[.boundaries], 1)
        XCTAssertEqual(ac.learning.diagnostics[.evidenceMissing], 1)
        XCTAssertEqual(ac.learning.diagnostics[.refusedBelowMargin], 1)
        XCTAssertEqual(ac.learning.diagnostics[.unchanged], 1)
        XCTAssertEqual(ac.learning.diagnostics[.autoSpellingFallback], 0)
    }

    func testContractionHomographRefusesBeforeSpellingCompletion() {
        let ac = AutocorrectEngine(checker: Checker(answers: ["hell": ["hello"]]), spatialDecoder: nil)
        XCTAssertNil(ac.replacementOnSpace(beforeInput: "hell", field: .text, autocorrectionType: .default))
        XCTAssertEqual(ac.learning.diagnostics[.refusedLiteralValid], 1)
        XCTAssertEqual(ac.learning.diagnostics[.refusedBelowMargin], 0)
        XCTAssertEqual(ac.learning.diagnostics[.unchanged], 1)
        XCTAssertEqual(ac.learning.diagnostics[.autoSpellingFallback], 0)
    }

    func testEvidenceLengthGatePrecedesTrackerPresence() {
        for word in ["hi", String(repeating: "a", count: 33)] {
            let (engine, _) = keyboard()
            type(word, engine)
            XCTAssertNotNil(engine.autocorrect.touchInput.evidence(beforeInput: word))
            tap(.space, engine)
            let diagnostics = engine.autocorrect.learning.diagnostics
            XCTAssertEqual(diagnostics[.evidenceLengthOutOfRange], 1)
            XCTAssertEqual(diagnostics[.evidenceComplete], 0)
            XCTAssertEqual(diagnostics[.evidenceMissing], 0)
        }
    }

    func testMissingResourceFallsBackAndBoundaryCountersAreNotSuggestionCounters() {
        let (engine, target) = keyboard(checker: Checker(answers: ["helo": ["hello"]]))
        type("helo", engine)
        for _ in 0..<10 { engine.refreshSuggestions() }
        let session = engine.autocorrect.learning
        XCTAssertEqual(session.diagnostics[.boundaries], 0)
        XCTAssertEqual(session.diagnostics.boundaryMs.reduce(0, +), 0)
        tap(.space, engine)
        XCTAssertEqual(target.text, "hello ")
        XCTAssertEqual(session.diagnostics[.boundaries], 1)
        XCTAssertEqual(session.diagnostics[.evidenceComplete], 1)
        XCTAssertEqual(session.diagnostics[.autoSpellingFallback], 1)
        XCTAssertEqual(session.diagnostics[.refusedMissingResource], 1)
        XCTAssertEqual(session.diagnostics.boundaryMs.reduce(0, +), 1)
        XCTAssertEqual(session.diagnostics[.suggestionDecodes], 0, "No decoder was installed")
    }

    func testMissingEvidenceReasonsAndPlainBoundaryDecisionAreCountedOnce() {
        let (engine, _) = keyboard()
        for token in ["hello", "hi", "für"] {
            XCTAssertNil(engine.autocorrect.replacementOnSpace(beforeInput: token, field: .text,
                                                              autocorrectionType: .default))
        }
        let diagnostics = engine.autocorrect.learning.diagnostics
        XCTAssertEqual(diagnostics[.boundaries], 3)
        XCTAssertEqual(diagnostics[.evidenceMissing], 1)
        XCTAssertEqual(diagnostics[.evidenceComplete] + diagnostics[.evidenceMissing]
            + diagnostics[.evidenceLengthOutOfRange] + diagnostics[.evidenceUnsupported], diagnostics[.boundaries])
        XCTAssertEqual(diagnostics[.evidenceLengthOutOfRange], 1)
        XCTAssertEqual(diagnostics[.evidenceUnsupported], 1)
        XCTAssertEqual(diagnostics[.unchanged], 3)
        XCTAssertEqual(diagnostics.boundaryMs.reduce(0, +), 3)
    }

    func testSessionRemovesLegacyKeyAndPersistsOnlyAggregatesOnFlush() throws {
        let name = "KeyboardLearning-session-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        defaults.set(Data("obsolete".utf8), forKey: "keyboard.learnedWords")
        let store = KeyboardLearningStore(directory: directory, defaults: defaults)
        let session = KeyboardLearningSession(store: store, defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "keyboard.learnedWords"))
        let (engine, _) = keyboard(session: session)
        type("hello", engine)
        engine.acceptSuggestion(try XCTUnwrap(engine.suggestions.first))
        XCTAssertNil(KeyboardLearningStore.readSnapshot(directory: directory, defaults: defaults).learningFile.bytes,
                     "No immediate save before the debounce")
        session.flush()
        let loaded = KeyboardLearningSession(store: KeyboardLearningStore(directory: directory, defaults: defaults),
                                             defaults: defaults)
        XCTAssertTrue(loaded.model.lexicon.isKept("hello"))
        XCTAssertEqual(loaded.model.lexicon.counts["hello"], 1)
        XCTAssertEqual(loaded.diagnostics.acceptedLabels, 5)
        XCTAssertEqual(loaded.diagnostics[.keepChip], 1)
    }

    func testSettingsReadSessionSavesAndIndependentResetsReachLiveKeyboard() throws {
        let name = "KeyboardLearning-dashboard-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = KeyboardLearningSession(store: KeyboardLearningStore(directory: directory, defaults: defaults),
                                              defaults: defaults)
        let (engine, _) = keyboard(session: session)
        type("hello", engine)
        engine.acceptSuggestion(try XCTUnwrap(engine.suggestions.first))
        session.recordRejection(.outlier, count: 2)
        session.flush()

        let dashboard = KeyboardLearningSettingsModel(directory: directory, defaults: defaults)
        XCTAssertEqual(dashboard.snapshot.model.keptWords, 1)
        XCTAssertEqual(dashboard.snapshot.diagnostics.acceptedBySource["keep"], 5)
        XCTAssertEqual(dashboard.snapshot.diagnostics.rejectedByReason["outlier"], 2)
        XCTAssertEqual(dashboard.snapshot.diagnostics[.keepChip], 1)
        XCTAssertEqual(dashboard.snapshot.diagnostics[.wordsCounted], 1)
        XCTAssertNotNil(dashboard.snapshot.learningFile.bytes)
        XCTAssertNotNil(dashboard.snapshot.diagnosticsFile.bytes)

        dashboard.resetTechnicalCounters()
        XCTAssertNil(dashboard.resetProblem)
        engine.autocorrect.syncLearning()
        XCTAssertEqual(session.diagnostics[.keepChip], 0)
        XCTAssertEqual(session.diagnostics.acceptedLabels, 0)
        XCTAssertEqual(session.diagnostics.rejectedLabels, 0)
        XCTAssertTrue(session.model.lexicon.isKept("hello"))
        XCTAssertEqual(session.model.summary.effectiveTouchCount, 5)
        XCTAssertEqual(session.model.lexicon.counts["hello"], 1)
        session.flush()
        dashboard.refresh()
        XCTAssertEqual(dashboard.snapshot.diagnostics[.keepChip], 0)
        XCTAssertEqual(dashboard.snapshot.model.keptWords, 1)

        type("world", engine)
        engine.acceptSuggestion(try XCTUnwrap(engine.suggestions.first))
        session.recordRejection(.ambiguousAlignment, count: 3)
        type("hello ", engine)
        XCTAssertNotNil(engine.autocorrect.pendingFeedback)
        dashboard.resetLearning()
        XCTAssertNil(dashboard.resetProblem)
        engine.autocorrect.syncLearning()
        XCTAssertNil(engine.autocorrect.pendingFeedback)
        XCTAssertTrue(session.model.lexicon.kept.isEmpty)
        XCTAssertEqual(session.diagnostics[.boundaries], 1)
        XCTAssertEqual(session.diagnostics.acceptedBySource["keep"], 5)
        XCTAssertEqual(session.diagnostics.rejectedByReason["ambiguousAlignment"], 3)
        session.flush()
        dashboard.refresh()
        XCTAssertEqual(dashboard.snapshot.model.keptWords, 0)
        XCTAssertEqual(dashboard.snapshot.diagnostics[.boundaries], 1)
        XCTAssertEqual(dashboard.snapshot.diagnostics.acceptedBySource["keep"], 5)
        XCTAssertEqual(dashboard.snapshot.diagnostics.rejectedByReason["ambiguousAlignment"], 3)
    }

    func testPermissionRevocationCancelsPersistenceButKeepsRAMProtection() throws {
        let name = "KeyboardLearning-permission-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var fullAccess = true
        let session = KeyboardLearningSession(store: KeyboardLearningStore(directory: directory, defaults: defaults),
            defaults: defaults, allowsPersistence: { fullAccess })
        session.keep("hello")
        fullAccess = false
        session.flush()
        XCTAssertFalse(session.isPersistent)
        XCTAssertTrue(session.model.lexicon.isKept("hello"))
        XCTAssertNil(KeyboardLearningStore.readSnapshot(directory: directory, defaults: defaults).learningFile.bytes)
        defaults.set(1, forKey: KeyboardLearningStore.learningResetKey)
        session.refresh()
        XCTAssertFalse(session.model.lexicon.isKept("hello"), "RAM sessions also honor resets")
    }

    func testDiagnosticsResetDiscardsPendingFeedbackButPreservesLearning() throws {
        let name = "KeyboardLearning-statistics-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let session = KeyboardLearningSession(defaults: defaults)
        let store = KeyboardLearningStore(directory: nil, defaults: defaults)
        let (engine, _) = keyboard(session: session)
        session.keep("world")
        type("hello ", engine)
        XCTAssertNotNil(engine.autocorrect.pendingFeedback)
        XCTAssertTrue(store.requestDiagnosticsReset())
        engine.autocorrect.syncLearning()
        XCTAssertNil(engine.autocorrect.pendingFeedback)
        XCTAssertTrue(session.model.lexicon.isKept("world"))
        type("w", engine)
        XCTAssertEqual(session.diagnostics.acceptedLabels, 0)
        XCTAssertEqual(session.diagnostics[.boundaries], 0)
    }

    func testResetEpochIsCheckedBeforeSaveAndRefreshDiscardsPending() throws {
        let name = "KeyboardLearning-reset-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = KeyboardLearningStore(directory: nil, defaults: defaults)
        let session = KeyboardLearningSession(store: store, defaults: defaults)
        let (engine, _) = keyboard(session: session)
        type("hello ", engine)
        session.keep("world")
        XCTAssertTrue(store.requestLearningReset())
        session.flush()
        type("w", engine)
        XCTAssertFalse(session.model.lexicon.isKept("world"))
        XCTAssertTrue(session.model.lexicon.counts.isEmpty)
        XCTAssertEqual(session.diagnostics.acceptedLabels, 0)
        XCTAssertEqual(session.diagnostics[.boundaries], 1, "Learning reset does not reset diagnostics")
        XCTAssertTrue(store.requestDiagnosticsReset())
        session.refresh()
        XCTAssertEqual(session.diagnostics[.boundaries], 0)
    }
}
