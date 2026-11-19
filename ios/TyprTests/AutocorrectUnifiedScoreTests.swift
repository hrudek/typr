import UIKit
import XCTest
@testable import Typr

@MainActor
final class AutocorrectUnifiedScoreTests: XCTestCase {
    private final class Checker: TextChecking {
        func isWordValid(_ word: String) -> Bool { ["in", "is", "us", "if", "of"].contains(word.lowercased()) }
        func guesses(for word: String) -> [String] { [] }
        func completions(for prefix: String) -> [String] { [] }
    }

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var now: TimeInterval = 200

    override func setUp() async throws {
        suiteName = "AutocorrectUnifiedScoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func keyboard(after context: String) throws -> (FullKeyboardEngine, FixtureTextTarget) {
        let lexicons = try XCTUnwrap(BundledKeyboardData.lexicons)
        let autocorrect = AutocorrectEngine(checker: Checker(), learning: KeyboardLearningSession(defaults: defaults),
                                            spatialDecoder: SpatialWordDecoder(lexicons: lexicons),
                                            contextResources: .init(model: try XCTUnwrap(BundledKeyboardData.contextModel)))
        let target = FixtureTextTarget(text: context)
        target.autocapitalizationType = UITextAutocapitalizationType.none
        let engine = FullKeyboardEngine(target: target, autocorrect: autocorrect)
        engine.width = 393
        engine.clock = { [unowned self] in self.now }
        engine.configureForField()
        return (engine, target)
    }

    private func tap(_ kind: KeyKind, _ engine: FullKeyboardEngine) {
        let key = engine.layout.key(kind)!
        let center = CGPoint(x: key.frame.midX, y: key.frame.midY)
        engine.touchBegan(id: 1, at: center)
        engine.touchEnded(id: 1, at: center)
        now += 0.45
    }

    private func commit(_ letters: String, after context: String) throws -> String {
        let (engine, target) = try keyboard(after: context)
        for letter in letters { tap(.character(String(letter)), engine) }
        tap(.space, engine)
        return target.text
    }

    func testTwoLetterWordWithDisagreeingTapsIsCorrected() throws {
        XCTAssertEqual(try commit("jn", after: "I "), "I in ")
        XCTAssertEqual(try commit("js", after: "It "), "It is ")
    }

    func testValidLiteralWhoseTapsFitItBestIsKept() throws {
        XCTAssertEqual(try commit("is", after: "Tell "), "Tell is ")
        XCTAssertEqual(try commit("us", after: "It "), "It us ")
    }

    func testSameTapsInADifferentSentenceChangeTheCorrection() throws {
        XCTAssertEqual(try commit("kf", after: "even "), "even if ")
        XCTAssertEqual(try commit("kf", after: "most "), "most of ")
    }

    func testOwnerProtectionsOutrankTheScore() throws {
        let (kept, keptTarget) = try keyboard(after: "even ")
        kept.autocorrect.learning.keep("kf")
        for letter in "kf" { tap(.character(String(letter)), kept) }
        tap(.space, kept)
        XCTAssertEqual(keptTarget.text, "even kf ")

        let (contact, contactTarget) = try keyboard(after: "even ")
        contact.autocorrect.loadLexiconEntries([("Kf", "Kf")])
        for letter in "kf" { tap(.character(String(letter)), contact) }
        tap(.space, contact)
        XCTAssertEqual(contactTarget.text, "even kf ")

        let (undo, undoTarget) = try keyboard(after: "even ")
        for letter in "kf" { tap(.character(String(letter)), undo) }
        tap(.space, undo)
        XCTAssertEqual(undoTarget.text, "even if ")
        tap(.delete, undo)
        XCTAssertEqual(undoTarget.text, "even kf")
        tap(.space, undo)
        XCTAssertEqual(undoTarget.text, "even kf ", "an undone correction is not repeated")
    }
}
