import UIKit
import XCTest
@testable import Typr

@MainActor
final class UsageStatisticsEngineTests: XCTestCase {
    private final class Checker: TextChecking {
        func isWordValid(_ word: String) -> Bool { ["the", "hello", "world"].contains(word) }
        func guesses(for word: String) -> [String] { word == "teh" ? ["the"] : [] }
        func completions(for prefix: String) -> [String] { [] }
    }
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var target: FixtureTextTarget!
    private var engine: FullKeyboardEngine!
    private var store: UsageStatisticsStore!
    private var session: UsageStatisticsSession!
    private var clock: TimeInterval = 100
    private let wall = Date(timeIntervalSince1970: 1_800_000_000)
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "UsageStatisticsEngineTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        target = FixtureTextTarget(); target.autocapitalizationType = UITextAutocapitalizationType.none
        store = UsageStatisticsStore(directory: directory, now: { [unowned self] in self.wall })
        session = UsageStatisticsSession(store: store, monotonic: { [unowned self] in self.clock },
                                         now: { [unowned self] in self.wall }, automaticallyFlush: false)
        let learning = KeyboardLearningSession(defaults: defaults)
        let autocorrect = AutocorrectEngine(checker: Checker(), learning: learning, spatialDecoder: nil)
        engine = FullKeyboardEngine(target: target, autocorrect: autocorrect, statistics: session)
        engine.width = 393; engine.clock = { [unowned self] in self.clock }
        engine.configureForField()
    }
    override func tearDown() async throws {
        engine = nil; session = nil; store = nil
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    private func point(_ kind: KeyKind) -> CGPoint {
        let frame = engine.layout.key(kind)!.frame
        return CGPoint(x: frame.midX, y: frame.midY)
    }
    private func tap(_ kind: KeyKind) {
        let p = point(kind)
        engine.touchBegan(id: 1, at: p); engine.touchEnded(id: 1, at: p)
        clock += 0.1
    }
    private func type(_ string: String) {
        for ch in string { tap(ch == " " ? .space : .character(String(ch))) }
    }
    private func snapshot() throws -> UsageStatisticsSnapshot {
        session.flush(); return try store.snapshot()
    }
    private func totals() throws -> UsageTotals { try snapshot().totals(lastDays: 90, at: wall) }

    func testRolloverCountsEachCommitOnceAndExcludesHeldHeat() throws {
        let t = point(.character("t")), h = point(.character("h"))
        engine.touchBegan(id: 1, at: t)
        engine.touchBegan(id: 2, at: h) // t commits on DOWN, not release.
        clock += 0.1
        engine.touchEnded(id: 2, at: h)
        engine.touchEnded(id: 1, at: t)
        XCTAssertEqual(target.text, "th")
        XCTAssertEqual(try totals().directGraphemes, 2)
        XCTAssertEqual(try snapshot().heat.flatMap(\.cells).reduce(0, +), 1)
    }
    func testHold123SlideIsOneDirectCharacterWithoutLetterHeat() throws {
        engine.touchBegan(id: 1, at: point(.layerSwitch(.numbers)))
        let digit = point(.character("7"))
        engine.touchMoved(id: 1, to: digit); engine.touchEnded(id: 1, at: digit)
        XCTAssertEqual(target.text, "7")
        XCTAssertEqual(try totals().directGraphemes, 1)
        XCTAssertTrue(try snapshot().heat.isEmpty)
    }
    func testCorrectionDoubleSpaceUndoAndRepeatAreSemanticEvents() throws {
        type("teh ")
        XCTAssertEqual(target.text, "the ")
        engine.deleteBackward() // Restores teh, but is one deletion, not four deletes + insert.
        XCTAssertEqual(target.text, "teh")
        clock += 0.1; tap(.space)
        tap(.space)
        XCTAssertTrue(target.text.hasSuffix(". "))
        engine.repeatDelete(heldFor: 1) // Two proxy deletions, one repeat tick.
        clock += 0.1; engine.deleteWordBackward()
        let value = try totals()
        XCTAssertEqual(value.directGraphemes, 6)
        XCTAssertEqual(value.deletions, 3)
        XCTAssertEqual(value.completedWords, 1) // Undo never reopens a counted word.
    }
    func testRefusedSuggestionIsNothingAndAcceptedSuggestionBreaksTimeChain() throws {
        type("he")
        let suggestion = KeyboardSuggestion(displayText: "hello", replacement: "hello", kind: .secondary)
        engine.acceptSuggestion(suggestion) // No ownership: refused.
        XCTAssertEqual(try totals().suggestions, 0)
        engine.acceptOwnedFixtureSuggestion(suggestion)
        type("w")
        let value = try totals()
        XCTAssertEqual(target.text, "hello w")
        XCTAssertEqual(value.suggestions, 1)
        XCTAssertEqual(value.directGraphemes, 3)
        XCTAssertEqual(value.timedGraphemes, 1)
        XCTAssertEqual(value.completedWords, 1)
    }
    func testHostContextCursorAndFieldChangesDoNotImportForeignWords() throws {
        target.insertText("foreign")
        engine.textDidChange()
        tap(.space)
        XCTAssertEqual(try totals().completedWords, 0)
        type("h")
        while target.hasText { target.deleteBackward() }
        target.insertText("host changed") // Even without a callback, ownership mismatch breaks chain.
        tap(.space)
        XCTAssertEqual(try totals().completedWords, 0)
        type("abc")
        engine.configureForField()
        tap(.space)
        XCTAssertEqual(try totals().completedWords, 0)
    }
    func testSessionStartedInsideForeignOrPreResetWordDoesNotClaimItsCompletion() throws {
        target.insertText("hel")
        engine.textDidChange()
        type("lo ")
        XCTAssertEqual(try totals().completedWords, 0)
        type("hel")
        _ = try store.reset()
        session.refreshGeneration()
        type("lo ")
        XCTAssertEqual(try totals().completedWords, 0)
    }

    func testLearningOffStillRecordsTypingAndMeasuredHeat() throws {
        let settings = TyprSettings(defaults: defaults)
        settings.personalLearning = false
        engine.autocorrect.learning.refresh()
        engine.autocorrect.isEnabled = false
        type("hello ")
        let value = try totals()
        XCTAssertEqual(value.directGraphemes, 6)
        XCTAssertEqual(value.completedWords, 1)
        XCTAssertEqual(try snapshot().heat.flatMap(\.cells).reduce(0, +), 5)
    }
    func testAccentSelectionCountsOneGraphemeAndNoFabricatedHeat() throws {
        let key = point(.character("e"))
        engine.touchBegan(id: 1, at: key)
        clock += FullKeyboardEngine.accentHoldDelay + 0.01
        XCTAssertTrue(engine.openAccentMenuIfEligible(forTouch: 1))
        let menu = try XCTUnwrap(engine.activeAccentMenu)
        let cell = menu.cellFrames[1]
        engine.touchEnded(id: 1, at: CGPoint(x: cell.midX, y: cell.midY))
        XCTAssertEqual(try totals().directGraphemes, 1)
        XCTAssertTrue(try snapshot().heat.isEmpty)
    }

    func testLearningSwitchInvalidatesRecentAcceptedLabels() throws {
        let learning = engine.autocorrect.learning
        learning.onValidatedLabel = { [unowned self] label, layout in self.session.validatedLabel(label, layout: layout) }
        learning.onLabelsInvalidated = { [unowned self] in self.session.clearRecentLabels() }
        let key = try XCTUnwrap(engine.layout.key(.character("a")))
        let label = TouchLabel(point: .init(x: key.frame.midX, y: key.frame.midY), letter: "a")
        learning.learn([label], layout: engine.layout, source: .manualPick)
        XCTAssertEqual(session.recentLabels.count, 1)
        TyprSettings(defaults: defaults).personalLearning = false
        learning.refresh()
        XCTAssertTrue(session.recentLabels.isEmpty)
        learning.learn([label], layout: engine.layout, source: .manualPick)
        XCTAssertTrue(session.recentLabels.isEmpty)
    }

}

/// The model's accepted-label callback does not require a full engine or disk fixtures.
@MainActor
final class UsageStatisticsAcceptedLabelTests: XCTestCase {
    func testValidatedLabelHookSeesOnlyAcceptedFiniteInRangeLabels() throws {
        let model = PersonalTypingModel(isLearningEnabled: true)
        let layout = KeyboardLayout(width: 393)
        let key = try XCTUnwrap(layout.key(.character("a")))
        var accepted: [TouchLabel] = []
        let valid = TouchLabel(point: CGPoint(x: key.frame.midX, y: key.frame.midY), letter: "a")
        let labels = [valid, .init(point: .init(x: CGFloat.nan, y: 0), letter: "a"),
                      .init(point: .init(x: 10000, y: 10000), letter: "a"), .init(point: .zero, letter: "A")]
        let outcome = model.learn(labels, layout: layout, source: .manualPick, accepted: { accepted.append($0) })
        XCTAssertEqual(outcome.accepted, 1)
        XCTAssertEqual(accepted, [valid])
        model.isLearningEnabled = false
        _ = model.learn([valid], layout: layout, source: .manualPick, accepted: { accepted.append($0) })
        XCTAssertEqual(accepted.count, 1)
    }
}
