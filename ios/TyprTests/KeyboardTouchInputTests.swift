import UIKit
import XCTest
@testable import Typr

@MainActor
final class KeyboardTouchInputTests: XCTestCase {
    private var target: FixtureTextTarget!
    private var engine: FullKeyboardEngine!

    override func setUp() async throws {
        target = FixtureTextTarget()
        target.autocapitalizationType = UITextAutocapitalizationType.none
        engine = makeEngine(target)
    }

    private func makeEngine(_ target: FixtureTextTarget) -> FullKeyboardEngine {
        let checker = TouchEvidenceChecker()
        // Isolate the evidence contract; spatial ranking is covered in SpatialWordDecoderTests.
        let ac = AutocorrectEngine(checker: checker, learning: KeyboardLearningSession(), spatialDecoder: nil)
        let engine = FullKeyboardEngine(target: target, autocorrect: ac)
        engine.width = 393
        engine.configureForField()
        return engine
    }

    private var evidence: KeyboardTouchWord? {
        engine.autocorrect.touchInput.evidence(beforeInput: target.documentContextBeforeInput)
    }

    private func point(_ kind: KeyKind) -> CGPoint {
        let frame = engine.layout.key(kind)!.frame
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    private func tap(_ kind: KeyKind) {
        let p = point(kind)
        engine.touchBegan(id: 1, at: p)
        engine.touchEnded(id: 1, at: p)
    }

    private func type(_ text: String) {
        for ch in text { tap(ch == " " ? .space : .character(String(ch))) }
    }

    func testOffCenterReleaseKeepsPointKeyAndLayoutWithoutChangingText() {
        let key = engine.layout.key(.character("a"))!
        let p = CGPoint(x: key.frame.midX + 4, y: key.frame.midY - 3)
        engine.touchBegan(id: 1, at: point(.character("a")))
        engine.touchEnded(id: 1, at: p)
        XCTAssertEqual(target.text, "a")
        XCTAssertEqual(evidence?.layout, engine.layout)
        XCTAssertEqual(evidence?.samples, [.init(text: "a", point: p, key: key)])
    }

    func testRolloverRecordsOnceInInsertionOrderNotReleaseOrder() {
        let t = point(.character("t"))
        let h = point(.character("h"))
        engine.touchBegan(id: 1, at: t)
        engine.touchBegan(id: 2, at: h)
        engine.touchEnded(id: 2, at: h)
        engine.touchEnded(id: 1, at: t)
        XCTAssertEqual(target.text, "th")
        XCTAssertEqual(evidence?.text, "th")
        XCTAssertEqual(evidence?.samples.map(\.point), [t, h])
    }

    func testDeleteAndRetypeKeepOnlySurvivingSamples() {
        type("cat")
        tap(.delete)
        XCTAssertEqual(evidence?.text, "ca")
        type("r")
        XCTAssertEqual(evidence?.text, "car")
        XCTAssertEqual(evidence?.samples.map(\.key.kind), [.character("c"), .character("a"), .character("r")])
        engine.repeatDelete(heldFor: FullKeyboardEngine.fastRepeatAfter)
        XCTAssertEqual(evidence?.text, "c")
        tap(.delete)
        XCTAssertNil(evidence)
        type("dog")
        XCTAssertEqual(evidence?.text, "dog")
        engine.deleteWordBackward()
        XCTAssertEqual(target.text, "")
        XCTAssertNil(evidence)
    }

    func testSpaceReturnAndSuggestionDiscardCompletedWord() {
        type("cat")
        tap(.space)
        XCTAssertNil(evidence)
        type("dog")
        XCTAssertEqual(evidence?.text, "dog")
        tap(.returnKey)
        XCTAssertNil(evidence)
        type("cat")
        engine.acceptOwnedFixtureSuggestion(.init(displayText: "car", replacement: "car", kind: .secondary))
        XCTAssertEqual(target.text, "cat dog\ncar ")
        XCTAssertNil(evidence)
    }

    func testAutocorrectUndoDoesNotResurrectOldSamples() {
        type("teh")
        XCTAssertEqual(evidence?.text, "teh")
        engine.typeSpaceFromTyprKey()
        XCTAssertEqual(target.text, "the ")
        XCTAssertNil(evidence)
        tap(.delete)
        XCTAssertEqual(target.text, "teh")
        XCTAssertNil(evidence)
        type("s")
        XCTAssertNil(evidence, "must not present a partially observed word as complete")
    }

    func testExternalEditsAndCursorChangesInvalidateIncludingHeldTaps() {
        type("cat")
        target.insertText("x")
        engine.textDidChange()
        type("s")
        XCTAssertNil(evidence)
        engine.configureForField()
        target.insertText(" ")
        engine.touchBegan(id: 1, at: point(.character("a")))
        engine.discardTouchEvidence()
        engine.touchEnded(id: 1, at: point(.character("a")))
        XCTAssertEqual(target.text, "catxs a")
        XCTAssertNil(evidence)
    }

    func testUnnotifiedContextMismatchDropsEvidence() {
        type("cat")
        target.deleteBackward()
        target.insertText("r")
        engine.refreshSuggestions()
        XCTAssertNil(evidence)
        type("s")
        XCTAssertNil(evidence)
    }

    func testLayoutChangesAndLateReleaseCannotMixGeometry() {
        type("cat")
        engine.width += 1
        XCTAssertNil(evidence)
        type("s")
        XCTAssertNil(evidence)
        tap(.space)
        engine.touchBegan(id: 1, at: point(.character("a")))
        engine.orientation = .landscape
        engine.touchEnded(id: 1, at: point(.character("a")))
        XCTAssertNil(evidence)
        tap(.space)
        type("dog")
        XCTAssertEqual(evidence?.layout.orientation, .landscape)
        engine.showsStrip = false
        XCTAssertNil(evidence)
    }

    func testAccentsSlidesAndCancellationFallBackWithoutChangingGestures() {
        type("c")
        engine.touchBegan(id: 1, at: point(.character("a")))
        XCTAssertTrue(engine.openAccentMenuIfEligible(forTouch: 1))
        engine.touchEnded(id: 1, at: point(.character("a")))
        XCTAssertNil(evidence, "accent-menu coordinates are not ordinary letter taps")
        tap(.space)
        engine.touchBegan(id: 1, at: point(.character("f")))
        engine.touchMoved(id: 1, to: point(.character("g")))
        engine.touchEnded(id: 1, at: point(.character("g")))
        XCTAssertTrue(target.text.hasSuffix(" g"))
        XCTAssertNil(evidence)
        tap(.space)
        type("cat")
        engine.touchBegan(id: 1, at: point(.character("s")))
        engine.touchCancelled(id: 1)
        XCTAssertNil(evidence)
        XCTAssertTrue(target.text.hasSuffix(" cat"))
    }

    func testTrackpadClearsEvidenceBeforeFirstCursorStep() {
        type("cat")
        let p = point(.space)
        engine.touchBegan(id: 1, at: p)
        engine.touchMoved(id: 1, to: CGPoint(x: p.x + 15, y: p.y))
        XCTAssertTrue(engine.isTrackpadActive)
        XCTAssertNil(evidence)
        engine.touchEnded(id: 1, at: p)
        XCTAssertEqual(target.text, "cat")
    }

    func testHiddenStripAndDisabledAutocorrectStillTrackButNonProseDoesNot() {
        engine.showsStrip = false
        engine.autocorrect.isEnabled = false
        type("cat")
        XCTAssertEqual(evidence?.text, "cat")
        XCTAssertTrue(engine.suggestions.isEmpty)
        target.keyboardType = .emailAddress
        engine.configureForField()
        type("dog")
        XCTAssertNil(evidence)
    }

    func testBoundedWordDoesNotRestartAfterOverflowOrAtPartialWord() {
        type(String(repeating: "a", count: KeyboardTouchInput.maxSamples))
        XCTAssertEqual(evidence?.samples.count, KeyboardTouchInput.maxSamples)
        type("aa")
        XCTAssertNil(evidence)
        tap(.space)
        type("cat")
        XCTAssertEqual(evidence?.text, "cat")
        engine.configureForField()
        type("s")
        XCTAssertNil(evidence)
    }

    func testPunctuationAndNumberLayerDoNotLabelLaterSuffixes() {
        type("cat")
        tap(.layerSwitch(.numbers))
        XCTAssertNil(evidence)
        tap(.character("'"))
        // Apostrophe already returns to letters; there is no ABC key to tap now.
        XCTAssertEqual(engine.layout.layer, .letters)
        type("s")
        XCTAssertNil(evidence)
        tap(.space)
        type("dog")
        XCTAssertEqual(evidence?.text, "dog")
        engine.cancelAllTouches()
        XCTAssertNil(evidence)
    }

    func testMissingContextAndNonfinitePointsDoNotProduceEvidence() {
        let input = KeyboardTouchInput()
        let key = engine.layout.key(.character("a"))!
        input.append(text: "a", point: point(.character("a")), key: key,
                     layout: engine.layout, before: nil, after: "a")
        XCTAssertNil(input.evidence(beforeInput: "a"))
        input.append(text: "a", point: CGPoint(x: CGFloat.nan, y: 1), key: key,
                     layout: engine.layout, before: "", after: "a")
        XCTAssertNil(input.evidence(beforeInput: "a"))
    }

    func testEvidenceDoesNotChangeExistingSuggestionsOrReplacements() async {
        for word in ["teh", "dont", "cat", "TyprKey", "API", "well", "fuer"] {
            let typedTarget = FixtureTextTarget()
            typedTarget.autocapitalizationType = UITextAutocapitalizationType.none
            let typed = makeEngine(typedTarget)
            var tick: TimeInterval = 100
            typed.clock = { tick }
            for ch in word {
                tick += 1
                if ch.isUppercase {
                    let shift = typed.layout.key(.shift)!.frame
                    let p = CGPoint(x: shift.midX, y: shift.midY)
                    typed.touchBegan(id: 2, at: p)
                    typed.touchEnded(id: 2, at: p)
                }
                let key = typed.layout.key(.character(String(ch).lowercased()))!
                let p = CGPoint(x: key.frame.midX + 3, y: key.frame.midY - 2)
                typed.touchBegan(id: 1, at: p)
                typed.touchEnded(id: 1, at: p)
            }
            XCTAssertEqual(typedTarget.text, word)
            let plainTarget = FixtureTextTarget(text: typedTarget.text)
            plainTarget.autocapitalizationType = UITextAutocapitalizationType.none
            let plain = makeEngine(plainTarget)
            XCTAssertNotNil(typed.autocorrect.touchInput.evidence(beforeInput: typedTarget.text))
            // Compare finished strips (ownership differs per engine; everything visible must not).
            await typed.waitForSuggestions()
            await plain.waitForSuggestions()
            XCTAssertEqual(typed.suggestions.map(\.replacement), plain.suggestions.map(\.replacement), word)
            XCTAssertEqual(typed.suggestions.map(\.kind), plain.suggestions.map(\.kind), word)
            XCTAssertEqual(typed.suggestions.map(\.isCompletion), plain.suggestions.map(\.isCompletion), word)
            typed.typeSpaceFromTyprKey()
            plain.typeSpaceFromTyprKey()
            XCTAssertEqual(typedTarget.text, plainTarget.text, word)
        }
    }
}

@MainActor
private final class TouchEvidenceChecker: TextChecking {
    func isWordValid(_ word: String) -> Bool { ["cat", "well"].contains(word.lowercased()) }
    func guesses(for word: String) -> [String] { word == "teh" ? ["the"] : [] }
    func completions(for prefix: String) -> [String] { [] }
}
