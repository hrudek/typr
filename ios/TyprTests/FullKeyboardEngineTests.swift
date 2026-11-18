import UIKit
import XCTest
@testable import Typr

@MainActor
final class FullKeyboardEngineTests: XCTestCase {
    private var target: FixtureTextTarget!
    private var engine: FullKeyboardEngine!
    private var now: TimeInterval = 100
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "FullKeyboardEngineTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        target = FixtureTextTarget()
        target.autocapitalizationType = UITextAutocapitalizationType.none
        let ac = AutocorrectEngine(learning: KeyboardLearningSession(defaults: defaults), spatialDecoder: nil)
        engine = FullKeyboardEngine(target: target, autocorrect: ac)
        engine.width = 393
        engine.clock = { [unowned self] in self.now }
        engine.configureForField()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func point(_ kind: KeyKind) -> CGPoint {
        let key = engine.layout.key(kind)!
        return CGPoint(x: key.frame.midX, y: key.frame.midY)
    }

    private func down(_ id: Int, _ kind: KeyKind) { engine.touchBegan(id: id, at: point(kind)) }
    private func up(_ id: Int, _ kind: KeyKind) { engine.touchEnded(id: id, at: point(kind)) }

    private func tap(_ kind: KeyKind) {
        let at = point(kind)
        engine.touchBegan(id: 1, at: at)
        engine.touchEnded(id: 1, at: at)
    }

    private func type(_ text: String) {
        for ch in text {
            tap(ch == " " ? .space : .character(String(ch)))
            now += 0.5
        }
    }

    func testRolloverKeepsOrder() {
        down(1, .character("t"))
        down(2, .character("h"))
        up(1, .character("t"))
        up(2, .character("h"))
        XCTAssertEqual(target.text, "th")
    }

    func testRolloverWhenTheSecondKeyLiftsFirst() {
        down(1, .character("t"))
        down(2, .character("h"))
        up(2, .character("h"))
        up(1, .character("t"))
        XCTAssertEqual(target.text, "th")
    }

    func testSlidingToAnotherKeyTypesWhereTheFingerLifts() {
        down(1, .character("f"))
        engine.touchMoved(id: 1, to: point(.character("g")))
        XCTAssertEqual(engine.previewKey?.kind, .character("g"))
        up(1, .character("g"))
        XCTAssertEqual(target.text, "g")
    }

    func testShiftChordAndOneShot() {
        down(1, .shift)
        down(2, .character("a"))
        up(2, .character("a"))
        down(3, .character("b"))
        up(3, .character("b"))
        up(1, .shift)
        tap(.character("c"))
        XCTAssertEqual(target.text, "ABc")

        tap(.shift)
        tap(.character("d"))
        tap(.character("e"))
        XCTAssertEqual(target.text, "ABcDe")
    }

    func testDoubleTapShiftLocks() {
        tap(.shift)
        now += 0.1
        tap(.shift)
        type("hi")
        XCTAssertEqual(target.text, "HI")
        XCTAssertEqual(engine.shift.state, .locked)
    }

    func testHoldNumbersSlideToADigitAndLetGo() {
        down(1, .layerSwitch(.numbers))
        XCTAssertEqual(engine.layout.layer, .numbers)
        engine.touchMoved(id: 1, to: point(.character("7")))
        engine.touchEnded(id: 1, at: point(.character("7")))
        XCTAssertEqual(target.text, "7")
        XCTAssertEqual(engine.layout.layer, .letters)
    }

    func testHoldingNumbersSwitchesKeyboardsOnlyWhenTheGlobeDoesNot() {
        engine.showsGlobe = true
        for globeKey in GlobeKey.allCases {
            engine.globeKey = globeKey
            let layerKey = point(.layerSwitch(.numbers))
            engine.touchBegan(id: 1, at: layerKey)
            XCTAssertEqual(engine.takeNextKeyboardHold(forTouch: 1), globeKey != .switches, "\(globeKey)")
            engine.touchEnded(id: 1, at: layerKey)
            if globeKey == .switches { tap(.layerSwitch(.letters)) }
            XCTAssertEqual(engine.layout.layer, .letters, "\(globeKey)")
            XCTAssertTrue(engine.touches.isEmpty)
        }
        XCTAssertEqual(target.text, "")
    }

    func testHoldingNumbersThenSlidingAwayStillTypesThePunctuation() {
        engine.showsGlobe = true
        engine.globeKey = .hidden
        down(1, .layerSwitch(.numbers))
        engine.touchMoved(id: 1, to: point(.character(".")))
        XCTAssertFalse(engine.takeNextKeyboardHold(forTouch: 1))
        engine.touchEnded(id: 1, at: point(.character(".")))
        XCTAssertEqual(target.text, ".")
    }

    func testThePeriodKeyTypesAPeriodAndItsHoldOffersMorePunctuation() throws {
        engine.bottomRow = BottomRow(order: BottomKey.standard, periodKey: true)
        tap(.character("."))
        XCTAssertEqual(target.text, ".")

        down(1, .character("."))
        XCTAssertTrue(engine.openAccentMenuIfEligible(forTouch: 1))
        let menu = try XCTUnwrap(engine.activeAccentMenu)
        XCTAssertEqual(Set(menu.options), Set(AccentCatalog.periodKey))
        let cell = menu.cellFrames[try XCTUnwrap(menu.options.firstIndex(of: ","))]
        engine.touchMoved(id: 1, to: CGPoint(x: cell.midX, y: cell.midY))
        engine.touchEnded(id: 1, at: CGPoint(x: cell.midX, y: cell.midY))
        XCTAssertEqual(target.text, ".,")

        tap(.layerSwitch(.numbers))
        down(1, .character("."))
        XCTAssertTrue(engine.openAccentMenuIfEligible(forTouch: 1))
        XCTAssertEqual(Set(try XCTUnwrap(engine.activeAccentMenu).options), Set(AccentCatalog.options(for: ".", uppercase: false) ?? []))
        engine.cancelAllTouches()
    }

    func testGlobeSpacerDoesNothingWhenTapped() {
        engine.showsGlobe = true
        engine.globeKey = .spacer
        tap(.globeSpacer)
        XCTAssertEqual(target.text, "")
        XCTAssertEqual(engine.layout.layer, .letters)
    }

    func testNumbersStayUntilSpace() {
        tap(.layerSwitch(.numbers))
        XCTAssertEqual(engine.layout.layer, .numbers)
        tap(.character("4"))
        tap(.character("2"))
        XCTAssertEqual(engine.layout.layer, .numbers)
        tap(.space)
        XCTAssertEqual(engine.layout.layer, .letters)
        XCTAssertEqual(target.text, "42 ")
    }

    private func resetText(_ text: String = "", keyboardType: UIKeyboardType = .default) {
        target = FixtureTextTarget(text: text)
        target.autocapitalizationType = UITextAutocapitalizationType.none
        target.keyboardType = keyboardType
        let ac = AutocorrectEngine(learning: KeyboardLearningSession(defaults: defaults), spatialDecoder: nil)
        engine = FullKeyboardEngine(target: target, autocorrect: ac)
        engine.width = 393
        engine.clock = { [unowned self] in self.now }
        engine.configureForField()
    }

    private func punctuation(_ mark: String, sliding: Bool = false) {
        if sliding {
            down(1, .layerSwitch(.numbers))
            let at = point(.character(mark))
            engine.touchMoved(id: 1, to: at)
            engine.touchEnded(id: 1, at: at)
        } else {
            tap(.layerSwitch(.numbers))
            tap(.character(mark))
        }
    }

    func testPunctuationCorrectsTheCurrentWordOnTapAndNumberSlide() {
        for sliding in [false, true] {
            for mark in ["?", "!", ".", ","] {
                resetText()
                type("teh")
                punctuation(mark, sliding: sliding)
                XCTAssertEqual(target.text, "the" + mark)
                XCTAssertNil(engine.autocorrect.pendingFeedback, "punctuation must not teach automatic output")
                XCTAssertNil(engine.autocorrect.touchInput.evidence(beforeInput: target.documentContextBeforeInput))
            }
        }
    }

    func testPunctuationReplacesSpaceAfterAutomaticAndExplicitCorrection() {
        for explicit in [false, true] {
            for mark in ["?", "!", ".", ","] {
                resetText()
                type("teh")
                if explicit {
                    engine.acceptOwnedFixtureSuggestion(KeyboardSuggestion(displayText: "the", replacement: "the", kind: .secondary))
                } else {
                    tap(.space)
                }
                XCTAssertEqual(target.text, "the ")
                punctuation(mark)
                XCTAssertEqual(target.text, "the" + mark)
            }
        }
    }

    func testLongPressPlainPunctuationUsesTheSameBoundaryHandling() throws {
        for trailingSpace in [false, true] {
            for mark in ["?", "!", "."] {
                resetText()
                type("teh")
                if trailingSpace { tap(.space) }
                tap(.layerSwitch(.numbers))
                down(1, .character(mark))
                XCTAssertTrue(engine.openAccentMenuIfEligible(forTouch: 1))
                let menu = try XCTUnwrap(engine.activeAccentMenu)
                let index = try XCTUnwrap(menu.options.firstIndex(of: mark))
                let cell = menu.cellFrames[index]
                engine.touchEnded(id: 1, at: CGPoint(x: cell.midX, y: cell.midY))
                XCTAssertEqual(target.text, "the" + mark)
            }
        }
    }

    func testPunctuationSpacingStillWorksWithAutocorrectDisabled() {
        for disabledSetting in [false, true] {
            resetText("word ")
            if disabledSetting { engine.autocorrect.isEnabled = false } else { target.autocorrectionType = .no }
            punctuation("?")
            XCTAssertEqual(target.text, "word?", "spacing cleanup is independent of word replacement")
        }
    }

    func testPunctuationDoesNotReconsiderExplicitKeep() {
        type("teh")
        engine.acceptOwnedFixtureSuggestion(KeyboardSuggestion(displayText: "teh", replacement: "teh", kind: .keepLiteral))
        punctuation("?")
        XCTAssertEqual(target.text, "teh?")
    }

    func testDoubleSpaceAfterAutomaticAndExplicitCorrection() {
        for explicit in [false, true] {
            for typrKey in [false, true] {
                resetText()
                type("teh")
                if explicit {
                    engine.acceptOwnedFixtureSuggestion(KeyboardSuggestion(displayText: "the", replacement: "the", kind: .secondary))
                } else {
                    tap(.space)
                }
                now += 0.2
                if typrKey { engine.typeSpaceFromTyprKey() } else { tap(.space) }
                XCTAssertEqual(target.text, "the. ")
                now += 0.1
                tap(.space)
                XCTAssertEqual(target.text, "the.  ")
            }
        }
    }

    func testSlowSpaceAfterSuggestionDoesNotInsertPeriod() {
        type("teh")
        engine.acceptOwnedFixtureSuggestion(KeyboardSuggestion(displayText: "the", replacement: "the", kind: .secondary))
        now += 0.5
        tap(.space)
        XCTAssertEqual(target.text, "the  ")
    }

    func testPunctuationPreservesWhitespaceAndNonProseFields() {
        for text in ["word  ", "word\n", "word\t", " "] {
            resetText(text)
            punctuation("?")
            XCTAssertEqual(target.text, text + "?")
        }
        for field in [UIKeyboardType.emailAddress, .URL] {
            resetText("teh ", keyboardType: field)
            punctuation(".")
            XCTAssertEqual(target.text, "teh .")
            resetText("teh", keyboardType: field)
            punctuation(".")
            XCTAssertEqual(target.text, "teh.")
        }
    }

    func testPunctuationRespectsDisabledAutocorrect() {
        for disabledSetting in [false, true] {
            resetText()
            if disabledSetting { engine.autocorrect.isEnabled = false } else { target.autocorrectionType = .no }
            type("teh")
            punctuation("!")
            XCTAssertEqual(target.text, "teh!")
        }
    }

    func testDeleteUndoesPunctuationCorrectionWithoutLearningPunctuationAsAWord() {
        type("teh")
        punctuation("?")
        engine.deleteBackward()
        XCTAssertEqual(target.text, "teh")
        XCTAssertTrue(engine.autocorrect.learning.model.lexicon.isRejected(typed: "teh", replacement: "the"))
        XCTAssertFalse(engine.autocorrect.learning.model.lexicon.isRejected(typed: "teh", replacement: "the?"))
        XCTAssertNil(engine.autocorrect.pendingFeedback)
    }

    func testExternalCursorChangeInvalidatesSuggestionDoubleSpace() {
        type("teh")
        engine.acceptOwnedFixtureSuggestion(KeyboardSuggestion(displayText: "the", replacement: "the", kind: .secondary))
        engine.textDidChange()
        now += 0.1
        tap(.space)
        XCTAssertEqual(target.text, "the  ")
    }

    func testDoubleSpaceTypesAPeriod() {
        type("ok")
        tap(.space)
        now += 0.2
        tap(.space)
        XCTAssertEqual(target.text, "ok. ")
        now += 0.2
        tap(.space)
        XCTAssertEqual(target.text, "ok.  ", "a third space is just a space")
    }

    // Typr: a tap on the Typr key types a space like the space bar.
    func testTyprKeySpaceActsLikeTheSpaceBar() {
        type("ok")
        engine.typeSpaceFromTyprKey()
        XCTAssertEqual(target.text, "ok ")
        now += 0.2
        engine.typeSpaceFromTyprKey()
        XCTAssertEqual(target.text, "ok. ", "double space still types a period")
        tap(.layerSwitch(.numbers))
        tap(.character("4"))
        engine.typeSpaceFromTyprKey()
        XCTAssertEqual(engine.layout.layer, .letters, "back to letters after a space")
        XCTAssertEqual(target.text, "ok. 4 ")
    }

    func testSlowDoubleSpaceStaysTwoSpaces() {
        type("ok")
        tap(.space)
        now += 0.5
        tap(.space)
        XCTAssertEqual(target.text, "ok  ")
    }

    func testSentenceAutoCapitalization() {
        target.autocapitalizationType = .sentences
        engine.configureForField()
        XCTAssertEqual(engine.shift.state, .on)
        type("hi")
        tap(.space)
        now += 0.2
        tap(.space)
        type("there")
        XCTAssertEqual(target.text, "Hi. There")
    }

    func testAcceleratingDeleteRampAndWordDelete() {
        type("hello world")
        down(1, .delete)
        XCTAssertEqual(target.text, "hello worl")
        // Initial repeat deletes 1 char.
        engine.repeatDelete(heldFor: FullKeyboardEngine.repeatDelay)
        XCTAssertEqual(target.text, "hello wor")
        // Accelerated repeat deletes 2 chars per tick.
        engine.repeatDelete(heldFor: FullKeyboardEngine.fastRepeatAfter)
        XCTAssertEqual(target.text, "hello w")
        // After 1.4 s, removes whole words backward.
        engine.repeatDelete(heldFor: FullKeyboardEngine.wordDeleteAfter)
        XCTAssertEqual(target.text, "hello ")
        engine.repeatDelete(heldFor: FullKeyboardEngine.wordDeleteAfter)
        XCTAssertEqual(target.text, "")
        up(1, .delete)
    }

    func testLongPressAccentPickerSelectsAndUppercaseWorks() {
        tap(.shift)
        down(1, .character("e"))
        XCTAssertTrue(engine.openAccentMenuIfEligible(forTouch: 1))
        let menu = try! XCTUnwrap(engine.activeAccentMenu)
        XCTAssertNil(engine.previewKey, "single-key balloon hides while accent picker is open")
        XCTAssertEqual(menu.options.first, "E")
        // Slide to index 2 ("É").
        let cell = menu.cellFrames[2]
        engine.touchMoved(id: 1, to: CGPoint(x: cell.midX, y: cell.midY))
        engine.touchEnded(id: 1, at: CGPoint(x: cell.midX, y: cell.midY))
        XCTAssertNil(engine.activeAccentMenu)
        XCTAssertEqual(target.text, "É")
        XCTAssertEqual(engine.shift.state, .off)
    }

    func testSpacebarTrackpadMovesCaretWithoutInsertingSpace() {
        type("helo")
        let spaceStart = point(.space)
        engine.touchBegan(id: 1, at: spaceStart)
        // Enter trackpad mode (-12 pt) then drag left by 16 pt (-2 chars: before "lo").
        let enterPoint = CGPoint(x: spaceStart.x - 12, y: spaceStart.y)
        engine.touchMoved(id: 1, to: enterPoint)
        XCTAssertTrue(engine.isTrackpadActive)
        engine.touchMoved(id: 1, to: CGPoint(x: enterPoint.x - 16, y: spaceStart.y))
        engine.touchEnded(id: 1, at: CGPoint(x: enterPoint.x - 16, y: spaceStart.y))
        XCTAssertFalse(engine.isTrackpadActive)
        XCTAssertEqual(target.cursorIndex, 2)
        tap(.character("l"))
        XCTAssertEqual(target.text, "hello")
    }

    func testEnablesReturnKeyAutomaticallyBlocksEmptyField() {
        target.enablesReturnKeyAutomatically = true
        tap(.returnKey)
        XCTAssertEqual(target.text, "")
        type("ok")
        tap(.returnKey)
        XCTAssertEqual(target.text, "ok\n")
    }

    func testRecordingPanelAllocatesLazilyAndTearsDownOnIdle() {
        let model = KeyboardViewModel()
        let view = FullKeyboardView(model: model, target: target)
        view.frame = CGRect(x: 0, y: 0, width: 393, height: 254)
        view.layoutIfNeeded()
        XCTAssertFalse(view.hasAllocatedRecordingPanel, "no Metal scope allocated while typing")

        let t: TimeInterval = 1_000
        model.applyBridgeState(
            hasFullAccess: true,
            snapshot: KeyboardSnapshot(state: .recording, heartbeat: t, expiresAt: t + 60, recordingStartedAt: t - 1, jobID: "j1"),
            isModelInstalled: true,
            style: .polished,
            now: t,
            clearPending: false,
            animated: false
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(view.hasAllocatedRecordingPanel)

        model.applyBridgeState(
            hasFullAccess: true,
            snapshot: KeyboardSnapshot(state: .ready, heartbeat: t + 1, expiresAt: t + 60),
            isModelInstalled: true,
            style: .polished,
            now: t + 1,
            clearPending: true,
            animated: false
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(view.hasAllocatedRecordingPanel, "Metal scope torn down once recording ends")
    }

    func testEmailFieldShowsAtAndDot() {
        target.keyboardType = .emailAddress
        engine.configureForField()
        tap(.character("@"))
        tap(.character("."))
        XCTAssertEqual(target.text, "@.")
    }

    func testNumberPadOpensOnNumbers() {
        target.keyboardType = .numberPad
        engine.configureForField()
        XCTAssertEqual(engine.layout.layer, .numbers)
    }
}
