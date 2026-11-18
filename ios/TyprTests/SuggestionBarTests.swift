import UIKit
import XCTest
@testable import Typr

/// Typr: *Hide suggestion bar* on the full keyboard.
@MainActor
final class SuggestionBarTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "SuggestionBarTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testAllKeyboardDefaultsOnEmptyDefaults() {
        let settings = TyprSettings(defaults: defaults)
        let keyboard = FullKeyboardSettings(defaults: defaults)
        XCTAssertTrue(keyboard.isEnabled)
        XCTAssertTrue(keyboard.autocorrect)
        XCTAssertTrue(keyboard.swipeTyping)
        XCTAssertFalse(settings.hideSuggestionBar)
        XCTAssertTrue(settings.personalLearning)
        XCTAssertTrue(settings.autocorrectGerman)
        XCTAssertTrue(settings.autocorrectEnglish)
        XCTAssertTrue(settings.dictationFeedbackStrip)
    }

    func testSettingDefaultsOffAndPersists() {
        let settings = TyprSettings(defaults: defaults)
        XCTAssertFalse(settings.hideSuggestionBar)
        settings.hideSuggestionBar = true
        XCTAssertTrue(TyprSettings(defaults: defaults).hideSuggestionBar)
    }

    private func keyboard(showsBar: Bool, text: String = "") -> (FullKeyboardView, FixtureTextTarget) {
        let target = FixtureTextTarget(text: text)
        let view = FullKeyboardView(model: KeyboardViewModel(), target: target,
            autocorrect: AutocorrectEngine(spatialDecoder: nil))
        view.suggestionBarOverride = showsBar
        view.orientationOverride = .portrait
        view.engine.autocorrect.isEnabled = true
        view.frame = CGRect(x: 0, y: 0, width: 393, height: view.preferredHeight)
        view.layoutIfNeeded()
        return (view, target)
    }

    private func press(_ kinds: [KeyKind], on view: FullKeyboardView) {
        for (index, kind) in kinds.enumerated() {
            guard let key = view.engine.layout.key(kind) else { return XCTFail("no key \(kind)") }
            let point = CGPoint(x: key.frame.midX, y: key.frame.midY)
            view.engine.touchBegan(id: 500 + index, at: point)
            view.engine.touchEnded(id: 500 + index, at: point)
        }
    }

    func testHiddenBarMakesTheKeyboardShorterAndComputesNoSuggestions() {
        let (view, _) = keyboard(showsBar: false)
        XCTAssertEqual(view.preferredHeight, 224)
        XCTAssertFalse(view.engine.showsStrip)
        press([.character("t"), .character("e"), .character("h")], on: view)
        XCTAssertTrue(view.engine.suggestions.isEmpty)
        XCTAssertEqual(view.engine.layout.key(.character("q"))?.frame.minY, 6)
    }

    func testBarOnKeepsTheEarlierKeyboard() {
        let (view, _) = keyboard(showsBar: true)
        XCTAssertEqual(view.preferredHeight, 253)
        press([.character("t"), .character("e"), .character("h")], on: view)
        XCTAssertFalse(view.engine.suggestions.isEmpty)
        XCTAssertEqual(view.engine.layout.key(.character("q"))?.frame.minY, 35)
    }

    func testAutocorrectOnSpaceStillAppliesWithoutTheBar() {
        let (view, target) = keyboard(showsBar: false)
        press([.character("t"), .character("e"), .character("h"), .space], on: view)
        XCTAssertTrue(target.text.hasSuffix("he "), target.text)
        XCTAssertFalse(target.text.lowercased().contains("teh"), target.text)
    }

    func testHeldStripChipAndAccessibilityUseTheirOwnActivationChoice() throws {
        let strip = KeyboardStripView()
        let old = KeyboardSuggestion(displayText: "hello", replacement: "hello", kind: .secondary)
        let new = KeyboardSuggestion(displayText: "world", replacement: "world", kind: .secondary)
        var selected: KeyboardSuggestion?
        var activationCount = 0
        strip.onSelectSuggestion = { selected = $0; activationCount += 1 }
        strip.update(suggestions: [old], statusText: nil)
        let button = try XCTUnwrap(strip.subviews.compactMap { $0 as? UIControl }.first { $0.tag == 0 })
        button.sendActions(for: .touchDown)
        strip.update(suggestions: [new], statusText: nil)
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(selected, old, "A delayed ranking must not change a held choice")
        button.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(activationCount, 1, "A control event must not also select the newer chip")
        XCTAssertTrue(button.accessibilityActivate())
        XCTAssertEqual(selected, new, "VoiceOver activates the current choice without touch-down")
        XCTAssertEqual(activationCount, 2)
        selected = nil
        button.sendActions(for: .touchDown)
        button.sendActions(for: .touchCancel)
        button.sendActions(for: .touchUpInside)
        XCTAssertNil(selected)
        XCTAssertEqual(activationCount, 2)
    }

    func testSwitchingTheBarRebuildsTheKeys() {
        let (view, _) = keyboard(showsBar: true)
        view.suggestionBarOverride = false
        XCTAssertEqual(view.preferredHeight, 224)
        XCTAssertEqual(view.engine.layout.key(.character("q"))?.frame.minY, 6)
        view.suggestionBarOverride = true
        XCTAssertEqual(view.preferredHeight, 253)
    }
}
