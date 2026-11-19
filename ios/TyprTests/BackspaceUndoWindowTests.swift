import UIKit
import XCTest
@testable import Typr

@MainActor
final class BackspaceUndoWindowTests: XCTestCase {
    private final class Checker: TextChecking {
        func isWordValid(_ word: String) -> Bool { ["the", "x"].contains(word) }
        func guesses(for word: String) -> [String] { word == "teh" ? ["the"] : [] }
        func completions(for prefix: String) -> [String] { [] }
    }

    private var defaults: UserDefaults!
    private var suite: String!
    private var target: FixtureTextTarget!
    private var engine: FullKeyboardEngine!
    private var written: [TypingLogWord] = []
    private var now: TimeInterval = 100
    private var scheduled: [(delay: TimeInterval, action: @MainActor () -> Void)] = []
    private var changes = 0

    override func setUp() async throws {
        suite = "BackspaceUndoWindowTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        target = FixtureTextTarget()
        target.autocapitalizationType = UITextAutocapitalizationType.none
        let autocorrect = AutocorrectEngine(checker: Checker(), learning: KeyboardLearningSession(defaults: defaults),
                                            spatialDecoder: nil)
        let log = TypingLogRecorder(write: { [unowned self] in self.written.append($0) }, now: { Date() })
        engine = FullKeyboardEngine(target: target, autocorrect: autocorrect, typingLog: log)
        engine.width = 393
        engine.clock = { [unowned self] in self.now }
        engine.scheduleAfter = { [unowned self] delay, action in self.scheduled.append((delay, action)) }
        engine.onChange = { [unowned self] in self.changes += 1 }
        engine.configureForField()
    }

    override func tearDown() async throws {
        engine = nil
        defaults.removePersistentDomain(forName: suite)
    }

    private func tap(_ kind: KeyKind) {
        let frame = engine.layout.key(kind)!.frame
        let point = CGPoint(x: frame.midX, y: frame.midY)
        engine.touchBegan(id: 1, at: point)
        engine.touchEnded(id: 1, at: point)
    }

    private func type(_ text: String) {
        for character in text {
            tap(character == " " ? .space : .character(String(character)))
            now += 0.1
        }
    }

    /// Types "teh " so the space corrects it at `now`, and returns that time.
    @discardableResult
    private func autocorrect() -> TimeInterval {
        type("teh")
        let correctedAt = now
        tap(.space)
        XCTAssertTrue(target.text.hasSuffix("the "))
        return correctedAt
    }

    func testDeleteUndoesJustBeforeTheWindowCloses() {
        let correctedAt = autocorrect()
        XCTAssertTrue(engine.deleteUndoes)
        now = correctedAt + KeyboardUndoWindow.duration - 0.01
        engine.deleteBackward()
        XCTAssertEqual(target.text, "teh")
        XCTAssertFalse(engine.deleteUndoes)
    }

    func testDeleteRemovesOneCharacterOnceTheWindowClosed() {
        let correctedAt = autocorrect()
        now = correctedAt + KeyboardUndoWindow.duration
        engine.deleteBackward()
        XCTAssertEqual(target.text, "the")
        XCTAssertFalse(engine.deleteUndoes)
        engine.deleteBackward()
        XCTAssertEqual(target.text, "th", "an expired undo is gone, not deferred")
        type("e x")
        XCTAssertFalse(written.flatMap(\.corrections).contains { $0.kind == .undo })
    }

    func testKeyRevertsToDeleteExactlyWhenTheWindowCloses() throws {
        let correctedAt = autocorrect()
        let expiry = try XCTUnwrap(scheduled.last)
        XCTAssertEqual(expiry.delay, KeyboardUndoWindow.duration, accuracy: 0.0001)
        XCTAssertEqual(scheduled.count, 1)

        now = correctedAt + KeyboardUndoWindow.duration
        changes = 0
        expiry.action()
        XCTAssertFalse(engine.deleteUndoes)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(scheduled.count, 1, "no further redraw is scheduled")
    }

    func testEarlyTimerKeepsUndoAndWaitsForTheRest() throws {
        let correctedAt = autocorrect()
        now = correctedAt + 2.5
        changes = 0
        try XCTUnwrap(scheduled.last).action()
        XCTAssertTrue(engine.deleteUndoes)
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(scheduled.count, 2)
        XCTAssertEqual(try XCTUnwrap(scheduled.last).delay, 0.5, accuracy: 0.0001)
    }

    func testStaleTimerFromAnEarlierCorrectionKeepsTheNewerUndo() throws {
        let firstAt = autocorrect()
        let first = try XCTUnwrap(scheduled.last)
        autocorrect()
        XCTAssertEqual(target.text, "the the ")
        now = firstAt + KeyboardUndoWindow.duration
        first.action()
        XCTAssertTrue(engine.deleteUndoes)
        engine.deleteBackward()
        XCTAssertEqual(target.text, "the teh")
    }

    func testUndoKeyEndsWhenUndoIsConsumed() {
        autocorrect()
        changes = 0
        engine.deleteBackward()
        XCTAssertFalse(engine.deleteUndoes)
        XCTAssertGreaterThan(changes, 0)
    }

    func testUndoKeyEndsWhenALetterFollows() {
        autocorrect()
        type("x")
        XCTAssertFalse(engine.deleteUndoes)
        engine.deleteBackward()
        XCTAssertEqual(target.text, "the ")
    }

    func testUndoKeyEndsWhenTheTextChangesElsewhere() {
        autocorrect()
        changes = 0
        engine.textDidChange()
        XCTAssertFalse(engine.deleteUndoes)
        XCTAssertGreaterThan(changes, 0)
    }

    func testUndoKeyEndsWhenTheFieldChanges() {
        autocorrect()
        engine.configureForField()
        XCTAssertFalse(engine.deleteUndoes)
    }

    func testKeptWordUndoExpiresToo() {
        type("teh")
        engine.acceptOwnedFixtureSuggestion(KeyboardSuggestion(displayText: "teh", replacement: "teh", kind: .keepLiteral))
        XCTAssertEqual(target.text, "teh ")
        XCTAssertTrue(engine.deleteUndoes)
        now += KeyboardUndoWindow.duration
        engine.refreshDeleteUndo()
        XCTAssertFalse(engine.deleteUndoes)
        engine.deleteBackward()
        XCTAssertEqual(target.text, "teh")
        type(" x")
        XCTAssertFalse(written.flatMap(\.corrections).contains { $0.kind == .undo })
    }
}
