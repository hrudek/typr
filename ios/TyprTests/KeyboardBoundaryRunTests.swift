import Foundation
import UIKit
import XCTest
@testable import Typr

/// Runs typed without (or with wrong) spaces, decided at the separator against the whole-word
/// reading. Constructed public phrases and synthetic key-centre taps, not collected typing.
extension KeyboardBoundaryDecoderTests {
    func runKeyboard(_ languages: Set<Language> = [.english], text: String = "") throws
        -> (FullKeyboardEngine, FixtureTextTarget) {
        let ac = engine(try resources(), languages: languages, model: try contextModel())
        let target = FixtureTextTarget(text: text)
        target.autocapitalizationType = UITextAutocapitalizationType.none
        let keyboard = FullKeyboardEngine(target: target, autocorrect: ac)
        keyboard.width = grid.width
        keyboard.configureForField()
        return (keyboard, target)
    }

    func press(_ keyboard: FullKeyboardEngine, at point: CGPoint) {
        keyboard.touchBegan(id: 1, at: point)
        keyboard.touchEnded(id: 1, at: point)
    }

    func centre(_ keyboard: FullKeyboardEngine, _ kind: KeyKind) throws -> CGPoint {
        let frame = try XCTUnwrap(keyboard.layout.key(kind)).frame
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    func typeRun(_ keyboard: FullKeyboardEngine, _ text: String) throws {
        for letter in text {
            press(keyboard, at: try centre(keyboard, letter == " " ? .space : .character(String(letter))))
        }
    }

    /// The letter's own key, at its edge towards `toward`: still that key, but likelier the other.
    func typeNear(_ keyboard: FullKeyboardEngine, _ letter: String, toward: String) throws {
        let key = try XCTUnwrap(keyboard.layout.key(.character(letter))).frame
        let other = try XCTUnwrap(keyboard.layout.key(.character(toward))).frame
        let x = other.midX < key.midX ? key.minX + 1 : key.maxX - 1
        press(keyboard, at: CGPoint(x: x, y: key.midY))
    }

    /// A bottom-row letter hit at its lower edge, just above the Space bar.
    func typeAboveSpace(_ keyboard: FullKeyboardEngine, _ letter: String) throws {
        let key = try XCTUnwrap(keyboard.layout.key(.character(letter))).frame
        press(keyboard, at: CGPoint(x: key.midX, y: key.maxY - 1))
    }

    /// Space hit at its top edge below `letter`, or at its centre.
    func typeSpace(_ keyboard: FullKeyboardEngine, below letter: String? = nil) throws {
        let space = try XCTUnwrap(keyboard.layout.key(.space)).frame
        guard let letter else { return press(keyboard, at: CGPoint(x: space.midX, y: space.midY)) }
        let key = try XCTUnwrap(keyboard.layout.key(.character(letter))).frame
        press(keyboard, at: CGPoint(x: key.midX, y: space.minY + 1))
    }

    func testRunWithoutSpacesSplitsAtTheSeparatorAndOneUndoRestoresIt() throws {
        let (keyboard, target) = try runKeyboard()
        let ac = keyboard.autocorrect
        let state = ac.learning.model.state
        let labels = ac.learning.diagnostics.acceptedLabels
        try typeRun(keyboard, "iloveyou")
        XCTAssertEqual(target.text, "iloveyou", "Nothing changes before the separator")
        try typeSpace(keyboard)
        XCTAssertEqual(target.text, "I love you ")
        try typeRun(keyboard, "so")
        XCTAssertEqual(ac.learning.model.state.counts, state.counts, "Inferred words are not counted")
        XCTAssertEqual(ac.learning.model.state.layouts, state.layouts)
        XCTAssertEqual(ac.learning.diagnostics.acceptedLabels, labels, "Inferred boundaries teach no taps")

        let (undone, undoneTarget) = try runKeyboard()
        try typeRun(undone, "iloveyou")
        try typeSpace(undone)
        XCTAssertEqual(undoneTarget.text, "I love you ")
        undone.deleteBackward()
        XCTAssertEqual(undoneTarget.text, "iloveyou", "One undo restores the run as typed")
        XCTAssertEqual(undone.autocorrect.boundaryRejectionCount, 1)
        try typeSpace(undone)
        XCTAssertEqual(undoneTarget.text, "iloveyou ", "An undone run is not split again")
    }

    func testThreeWordRunWithATypoInOnePart() throws {
        let (keyboard, target) = try runKeyboard()
        try typeRun(keyboard, "thisisg")
        try typeNear(keyboard, "i", toward: "o")
        try typeRun(keyboard, "od")
        XCTAssertEqual(target.text, "thisisgiod")
        try typeSpace(keyboard)
        XCTAssertEqual(target.text, "this is good ")
        keyboard.deleteBackward()
        XCTAssertEqual(target.text, "thisisgiod")
    }

    func testBottomRowLetterHitInsteadOfSpace() throws {
        let (keyboard, target) = try runKeyboard()
        try typeRun(keyboard, "love")
        try typeAboveSpace(keyboard, "b")
        try typeRun(keyboard, "you")
        XCTAssertEqual(target.text, "lovebyou")
        try typeSpace(keyboard)
        XCTAssertEqual(target.text, "love you ")
        keyboard.deleteBackward()
        XCTAssertEqual(target.text, "lovebyou")
    }

    func testSpaceHitInsteadOfALetterJoinsTheWord() throws {
        let (keyboard, target) = try runKeyboard()
        let ac = keyboard.autocorrect
        let state = ac.learning.model.state
        try typeRun(keyboard, "ne")
        try typeSpace(keyboard, below: "v")
        try typeRun(keyboard, "er")
        XCTAssertEqual(target.text, "ne er")
        try typeSpace(keyboard)
        XCTAssertEqual(target.text, "never ")
        keyboard.deleteBackward()
        XCTAssertEqual(target.text, "ne er", "One undo restores both words and their space")
        XCTAssertEqual(ac.learning.model.state.counts, state.counts)
        XCTAssertEqual(ac.learning.model.state.layouts, state.layouts, "The Space tap is not learned as a letter or Space")
    }

    func testValidSeparateWordsStayWithoutBetterTapEvidence() throws {
        let (keyboard, target) = try runKeyboard()
        try typeRun(keyboard, "a")
        try typeSpace(keyboard)
        try typeRun(keyboard, "out")
        try typeSpace(keyboard)
        XCTAssertEqual(target.text, "a out ", "A centred Space is a space between two valid words")
    }

    func testWholeWordBeatsAWeakSplit() throws {
        let (keyboard, target) = try runKeyboard()
        try typeRun(keyboard, "wonderfull")
        try typeSpace(keyboard)
        XCTAssertEqual(target.text, "wonderful ")
        let sources = try resources()
        // A split no likelier than the whole reading by the automatic odds stays a chip.
        let candidate = SpatialWordDecoder.Candidate(word: "great", language: .english, score: -20,
                                                    spatialScore: 0, edit: .none, alignment: [])
        let reading = SpatialWordDecoder.Result(candidates: [candidate], literalScore: -40, literalSpatialScore: 0,
                                               literalInLexicon: false, complete: true, visits: 1, generated: 1)
        var input = job("greatday", languages: [.english])
        input.touch = try multipartTouch("greatday", aimed: "greatday")
        let split = try XCTUnwrap(Boundary.retrieve(input, lexicons: sources, whole: .result(reading))
            .candidates.first { $0.replacement == "great day" })
        XCTAssertLessThan(split.score - split.baseline, Boundary.automaticLogOdds)
        XCTAssertFalse(split.automatic)
    }

    func testStaleWorkerResultOrMovedCaretAbstains() throws {
        let sources = try resources()
        let ac = engine(sources, languages: [.english], model: try contextModel())
        let touch = try multipartTouch("iloveyou", aimed: "iloveyou")
        installMultipart(touch, in: ac)
        // A worker result for other taps is not this run's: neither the strip nor Space uses it.
        var other = job("iloveyou", languages: [.english])
        other.touch = try multipartTouch("iloveyou", aimed: "ilivryou")
        let stale = Boundary.Retrieval(job: other, candidates: [.init(kind: .split, original: "iloveyou",
            replacement: "il ove you", score: 0, baseline: -100, automatic: true)], lexicalQueries: 0)
        let chips = ac.suggestions(beforeInput: "iloveyou", field: .text, autocorrectionType: .default,
                                   boundaryRetrieval: stale)
        XCTAssertFalse(chips.contains { $0.replacement == "il ove you" })
        XCTAssertEqual(ac.replacementOnSpace(beforeInput: "iloveyou", field: .text,
                                             autocorrectionType: .default)?.replacement, "I love you")
        installMultipart(touch, in: ac)
        XCTAssertNil(ac.replacementOnSpace(beforeInput: "iloveyou", field: .text, autocorrectionType: .no))
        ac.touchInput.clear()
        XCTAssertNil(ac.replacementOnSpace(beforeInput: "iloveyou", field: .text, autocorrectionType: .default),
                     "Without this run's taps nothing is applied")
        // The caret moved: the taps no longer belong to the run before it.
        let (keyboard, target) = try runKeyboard()
        try typeRun(keyboard, "iloveyou")
        keyboard.textDidChange()
        try typeSpace(keyboard)
        XCTAssertEqual(target.text, "iloveyou ")
    }

    func testRunSearchStaysWithinItsBudgets() throws {
        let sources = try resources(), model = try contextModel()
        for text in [String(repeating: "iloveyou", count: 4), String(repeating: "a", count: 32),
                     "thisisgoodandgreattodaytoo"] {
            var input = job(text)
            input.touch = try multipartTouch(text, aimed: text)
            input.context = .init(previous: "and", weightDE: 0.5)
            let result = Boundary.retrieve(input, lexicons: sources, model: model)
            XCTAssertLessThanOrEqual(result.multipartVisits, KeyboardMultipartSegmenter.maximumVisits)
            XCTAssertLessThanOrEqual(result.contextQueries, Boundary.maximumContextQueries)
            XCTAssertLessThanOrEqual(result.languageEvidenceQueries, Boundary.maximumLanguageEvidenceQueries)
            XCTAssertLessThanOrEqual(result.lexicalQueries, Boundary.maximumLexicalQueries)
            XCTAssertLessThanOrEqual(result.candidates.count, Boundary.resultLimit)
            XCTAssertTrue(result.candidates.allSatisfy { $0.replacement.split(separator: " ").count <= 4 })
        }
    }
}
