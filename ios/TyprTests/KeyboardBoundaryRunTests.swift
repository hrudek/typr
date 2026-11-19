import Foundation
import UIKit
import XCTest
@testable import Typr

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

    func typeNear(_ keyboard: FullKeyboardEngine, _ letter: String, toward: String) throws {
        let key = try XCTUnwrap(keyboard.layout.key(.character(letter))).frame
        let other = try XCTUnwrap(keyboard.layout.key(.character(toward))).frame
        let x = other.midX < key.midX ? key.minX + 1 : key.maxX - 1
        press(keyboard, at: CGPoint(x: x, y: key.midY))
    }

    func typeAboveSpace(_ keyboard: FullKeyboardEngine, _ letter: String) throws {
        let key = try XCTUnwrap(keyboard.layout.key(.character(letter))).frame
        press(keyboard, at: CGPoint(x: key.midX, y: key.maxY - 1))
    }

    func typeSpace(_ keyboard: FullKeyboardEngine, below letter: String? = nil) throws {
        let space = try XCTUnwrap(keyboard.layout.key(.space)).frame
        guard let letter else { return press(keyboard, at: CGPoint(x: space.midX, y: space.midY)) }
        let key = try XCTUnwrap(keyboard.layout.key(.character(letter))).frame
        press(keyboard, at: CGPoint(x: key.midX, y: space.minY + 1))
    }

    func testRunWithoutSpacesSplitsAtTheSeparatorAndOneUndoRestoresIt() async throws {
        let (keyboard, target) = try runKeyboard()
        let ac = keyboard.autocorrect
        let state = ac.learning.model.state
        let labels = ac.learning.diagnostics.acceptedLabels
        try typeRun(keyboard, "iloveyou")
        XCTAssertEqual(target.text, "iloveyou", "Nothing changes before the separator")
        await keyboard.waitForSuggestions()
        XCTAssertTrue(keyboard.suggestions.contains { $0.replacement == "I love you" && $0.willAutoReplace })
        try typeSpace(keyboard)
        XCTAssertEqual(target.text, "I love you ")
        try typeRun(keyboard, "so")
        XCTAssertEqual(ac.learning.model.state.counts, state.counts, "Inferred words are not counted")
        XCTAssertEqual(ac.learning.model.state.layouts, state.layouts)
        XCTAssertEqual(ac.learning.diagnostics.acceptedLabels, labels, "Inferred boundaries teach no taps")

        let (undone, undoneTarget) = try runKeyboard()
        try typeRun(undone, "iloveyou")
        await undone.waitForSuggestions()
        try typeSpace(undone)
        XCTAssertEqual(undoneTarget.text, "I love you ")
        undone.deleteBackward()
        XCTAssertEqual(undoneTarget.text, "iloveyou", "One undo restores the run as typed")
        XCTAssertEqual(undone.autocorrect.boundaryRejectionCount, 1)
        try typeSpace(undone)
        XCTAssertEqual(undoneTarget.text, "iloveyou ", "An undone run is not split again")
    }

    func testThreeWordRunWithATypoInOnePart() async throws {
        let (keyboard, target) = try runKeyboard()
        try typeRun(keyboard, "thisisg")
        try typeNear(keyboard, "i", toward: "o")
        try typeRun(keyboard, "od")
        XCTAssertEqual(target.text, "thisisgiod")
        await keyboard.waitForSuggestions()
        try typeSpace(keyboard)
        XCTAssertEqual(target.text, "this is good ")
        keyboard.deleteBackward()
        XCTAssertEqual(target.text, "thisisgiod")
    }

    func testBottomRowLetterHitInsteadOfSpace() async throws {
        let (cold, coldTarget) = try runKeyboard()
        try typeRun(cold, "love")
        try typeAboveSpace(cold, "b")
        try typeRun(cold, "you")
        await cold.waitForSuggestions()
        XCTAssertTrue(cold.suggestions.contains { $0.replacement == "love you" && !$0.willAutoReplace },
                      "Without learned Space aim the tap fits b better: offered, not applied")
        try typeSpace(cold)
        XCTAssertEqual(coldTarget.text, "lovebyou ")

        let (keyboard, target) = try runKeyboard()
        let layout = keyboard.layout, learning = keyboard.autocorrect.learning
        let labels = try "abcdefghijklmnopqrstuvwxyz".map { letter in
            TouchLabel(point: try centre(keyboard, .character(String(letter))), letter: letter)
        }
        for _ in 0..<3 { learning.learn(labels, layout: layout, source: .literalValid) }
        let space = try XCTUnwrap(layout.key(.space)).frame
        for tap in 0..<10 {
            learning.learnSpace(CGPoint(x: space.minX + 4 + CGFloat(tap) * 15, y: space.minY + 2), layout: layout)
        }
        try typeRun(keyboard, "love")
        try typeAboveSpace(keyboard, "b")
        try typeRun(keyboard, "you")
        XCTAssertEqual(target.text, "lovebyou")
        await keyboard.waitForSuggestions()
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

    func testCapitalizedWordInsideASentenceIsNotJoined() throws {
        let ac = engine(try resources(), languages: [.english], model: try contextModel())
        let space = try XCTUnwrap(grid.key(.space)).frame
        let v = try XCTUnwrap(grid.key(.character("v"))).frame
        func sample(_ text: String) throws -> KeyboardTouchWord.Sample {
            let key = try XCTUnwrap(grid.key(.character(text.lowercased())))
            return .init(text: text, point: CGPoint(x: key.frame.midX, y: key.frame.midY), key: key)
        }
        func install(_ before: String) throws {
            ac.touchInput.clear()
            var text = before
            let samples = [try sample("N"), try sample("e"),
                           .init(text: " ", point: CGPoint(x: v.midX, y: space.minY + 1), key: try XCTUnwrap(grid.key(.space))),
                           try sample("e"), try sample("r")]
            for item in samples {
                ac.touchInput.append(text: item.text, point: item.point, key: item.key, layout: grid,
                                     before: text, after: text + item.text)
                text += item.text
            }
        }
        try install("")
        XCTAssertEqual(ac.replacementOnSpace(beforeInput: "Ne er", field: .text,
                                             autocorrectionType: .default)?.replacement, "Never")
        try install("so ")
        XCTAssertNil(ac.replacementOnSpace(beforeInput: "so Ne er", field: .text, autocorrectionType: .default),
                     "A capital inside a sentence is a name")
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
        var other = job("iloveyou", languages: [.english])
        other.touch = try multipartTouch("iloveyou", aimed: "ilivryou")
        let stale = Boundary.Retrieval(job: other, candidates: [.init(kind: .split, original: "iloveyou",
            replacement: "il ove you", score: 0, baseline: -100, automatic: true)], lexicalQueries: 0)
        let chips = ac.suggestions(beforeInput: "iloveyou", field: .text, autocorrectionType: .default,
                                   boundaryRetrieval: stale)
        XCTAssertFalse(chips.contains { $0.replacement == "il ove you" })
        let applied = ac.replacementOnSpace(beforeInput: "iloveyou", field: .text, autocorrectionType: .default)
        XCTAssertNotEqual(applied?.replacement, "il ove you")
        XCTAssertEqual(applied?.replacement, chips.first { $0.willAutoReplace }?.replacement)
        installMultipart(touch, in: ac)
        XCTAssertNil(ac.replacementOnSpace(beforeInput: "iloveyou", field: .text, autocorrectionType: .no))
        ac.touchInput.clear()
        XCTAssertNil(ac.replacementOnSpace(beforeInput: "iloveyou", field: .text, autocorrectionType: .default),
                     "Without this run's taps nothing is applied")
        let (keyboard, target) = try runKeyboard()
        try typeRun(keyboard, "iloveyou")
        keyboard.textDidChange()
        try typeSpace(keyboard)
        XCTAssertEqual(target.text, "iloveyou ")
    }

    func testHighlightMatchesSpaceBeforeTheWorkerAnswers() throws {
        for text in ["iloveyou", "thisisgood", "haveaniceday", "greatdaytoday"] {
            let ac = engine(try resources(), languages: [.english], model: try contextModel())
            installMultipart(try multipartTouch(text, aimed: text), in: ac)
            let chips = ac.suggestions(beforeInput: text, field: .text, autocorrectionType: .default)
            let space = ac.replacementOnSpace(beforeInput: text, field: .text, autocorrectionType: .default)
            XCTAssertEqual(chips.first { $0.willAutoReplace }?.replacement, space?.replacement, text)
        }
    }

    func testUnlistedGermanCompoundsStayAsTyped() async throws {
        let compounds = ["gutenachtlied", "gutenachtritual", "gutenachtgeschichte", "gutenachtkuss",
                         "gutenmorgenkaffee", "gutenmorgenlied", "nachhauseweg", "zuhausebleiben",
                         "kaffeetrinken", "fensterbankpflanze", "feierabendbier", "kindergeburtstagsfeier",
                         "sonntagsspaziergang", "heuteabend", "morgenroutine", "zusammenleben"]
        for (index, word) in compounds.enumerated() where EvaluationSample.includes(index, every: 2) {
            let (keyboard, target) = try runKeyboard([.german])
            try typeRun(keyboard, word)
            await keyboard.waitForSuggestions()
            try typeSpace(keyboard)
            XCTAssertEqual(target.text, word + " ", word)
        }
        let (keyboard, target) = try runKeyboard([.german, .english])
        try typeRun(keyboard, "gutenachtritual")
        await keyboard.waitForSuggestions()
        try typeSpace(keyboard)
        XCTAssertEqual(target.text, "gutenachtritual ")
    }

    func testCentredBottomRowLetterIsNotReadAsSpace() async throws {
        for languages: Set<Language> in [[.english], [.german, .english]] {
            for word in ["jazzband", "hairband", "schoolband", "punkband"] {
                let (keyboard, target) = try runKeyboard(languages)
                try typeRun(keyboard, word)
                await keyboard.waitForSuggestions()
                try typeSpace(keyboard)
                XCTAssertEqual(target.text, word + " ", "\(languages)")
            }
        }
        let ac = engine(try resources(), languages: [.english], model: try contextModel())
        installMultipart(try multipartTouch("jazzband", aimed: "jazzband"), in: ac)
        _ = ac.suggestions(beforeInput: "jazzband", field: .text, autocorrectionType: .default)
        XCTAssertNotEqual(ac.replacementOnSpace(beforeInput: "jazzband", field: .text,
                                                autocorrectionType: .default)?.replacement, "jazz and")
    }

    func testGermanSentencesKeepLoanwordCompounds() async throws {
        let cases: [(String, String)] = [
            ("ich höre am liebsten ", "punkrock"), ("wir hören heute abend ", "punkrock"), ("", "punkrock"),
            ("meine schwester spielt in einer ", "metalband"), ("das ist meine lieblings ", "metalband"),
            ("", "metalband"), ("mein bruder macht nächstes jahr den ", "ironman"), ("", "ironman"),
            ("die ", "brassband"), ("wir haben gestern eine ", "brassband"), ("", "brassband"),
            ("das ist eine tolle ", "rockband"), ("ich höre gern ", "rockmusik"), ("wir sehen uns beim ", "rockkonzert"),
            ("ich esse heute ", "fastfood"), ("ich gehe heute in den ", "nightclub")]
        for wait in [true, false] {
            for (context, word) in cases {
                let (keyboard, target) = try runKeyboard([.german, .english], text: context)
                try typeRun(keyboard, word)
                if wait { await keyboard.waitForSuggestions() }
                try typeSpace(keyboard)
                XCTAssertEqual(target.text, context + word + " ", "wait \(wait)")
            }
        }
        for word in ["Metalband", "Brassband", "Ironman"] {
            let (keyboard, target) = try runKeyboard([.german, .english], text: "Das ist toll. ")
            target.autocapitalizationType = UITextAutocapitalizationType.sentences
            keyboard.textDidChange()
            try typeRun(keyboard, word.lowercased())
            XCTAssertEqual(target.text, "Das ist toll. " + word)
            await keyboard.waitForSuggestions()
            try typeSpace(keyboard)
            XCTAssertEqual(target.text, "Das ist toll. " + word + " ")
        }
    }

    func testGermanCompoundWithATypoIsNotSplit() async throws {
        for languages: Set<Language> in [[.german], [.german, .english]] {
            for word in ["gutenachtlued", "gutenmorgenkaffre"] {
                let (keyboard, target) = try runKeyboard(languages)
                try typeRun(keyboard, word)
                await keyboard.waitForSuggestions()
                try typeSpace(keyboard)
                XCTAssertEqual(target.text.split(separator: " ").count, 1, "\(word) \(languages): \(target.text)")
            }
        }
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
