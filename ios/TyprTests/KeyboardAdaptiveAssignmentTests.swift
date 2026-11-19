import Foundation
import UIKit
import XCTest
@testable import Typr

@MainActor
final class KeyboardAdaptiveAssignmentTests: XCTestCase {
    private typealias Language = SpatialWordDecoder.Language

    private final class Checker: TextChecking {
        func isWordValid(_ word: String) -> Bool { false }
        func guesses(for word: String) -> [String] { [] }
        func completions(for prefix: String) -> [String] { [] }
    }

    private func keyboard(_ text: String = "", autocapitalization: UITextAutocapitalizationType = .none,
                          context: Bool = false) throws -> (FullKeyboardEngine, FixtureTextTarget) {
        let target = FixtureTextTarget(text: text)
        target.autocapitalizationType = autocapitalization
        let ac = AutocorrectEngine(checker: Checker(), learning: KeyboardLearningSession(),
                                   spatialDecoder: SpatialWordDecoder(lexicons: try XCTUnwrap(BundledKeyboardData.lexicons)),
                                   contextResources: .init(model: context ? BundledKeyboardData.contextModel : nil))
        let engine = FullKeyboardEngine(target: target, autocorrect: ac)
        engine.width = 393
        engine.configureForField()
        engine.refreshSuggestions()
        return (engine, target)
    }

    private func key(_ letter: Character, _ engine: FullKeyboardEngine) -> KeyboardKey {
        engine.layout.key(.character(String(letter)))!
    }
    private func center(_ key: KeyboardKey) -> CGPoint { CGPoint(x: key.frame.midX, y: key.frame.midY) }
    private func tap(_ point: CGPoint, _ engine: FullKeyboardEngine) {
        engine.touchBegan(id: 1, at: point)
        engine.touchEnded(id: 1, at: point)
    }
    private func type(_ text: String, _ engine: FullKeyboardEngine) {
        for letter in text { tap(center(key(letter, engine)), engine) }
    }
    private func insideMTowardN(_ engine: FullKeyboardEngine) -> CGPoint {
        let m = key("m", engine)
        return CGPoint(x: m.hitFrame.minX + 2, y: m.frame.midY)
    }
    private func topEdgeOfGUnderT(_ engine: FullKeyboardEngine) -> CGPoint {
        let g = key("g", engine), t = key("t", engine)
        return CGPoint(x: (g.frame.midX + t.frame.midX) / 2, y: g.hitFrame.minY + 1)
    }
    private func label(_ letter: Character, _ engine: FullKeyboardEngine) {
        engine.autocorrect.learning.learn([TouchLabel(point: center(key(letter, engine)), letter: letter)],
                                          layout: engine.layout, source: .keep)
    }

    func testEdgeMissTypesTheLikeliestKeyWithoutLabelsWithOneLabelAndWithLearningOff() throws {
        for setup in ["cold", "one label", "learning off"] {
            let (engine, target) = try keyboard()
            switch setup {
            case "one label": label("f", engine)
            case "learning off": engine.autocorrect.learning.model.isLearningEnabled = false
            default: XCTAssertNil(engine.autocorrect.learning.calibration(for: engine.layout))
            }
            engine.refreshSuggestions()
            type("arou", engine)
            XCTAssertEqual(engine.layout.hitTest(insideMTowardN(engine))?.character, "m")
            tap(insideMTowardN(engine), engine)
            type("d", engine)
            XCTAssertEqual(target.text, "around", setup)
        }
    }

    func testStaleMapTypesTheKeyTheTapHit() throws {
        let (engine, target) = try keyboard()
        type("arou", engine)
        label("f", engine) // New learning generation, no refresh before the tap.
        tap(insideMTowardN(engine), engine)
        XCTAssertEqual(target.text, "aroum")
        let map = try XCTUnwrap(engine.autocorrect.keyMap(layout: engine.layout, context: "arou", permitsCorrection: true))
        let m = key("m", engine)
        XCTAssertEqual(map.attributedKey(at: insideMTowardN(engine), geometric: m, layout: engine.layout, prefix: "arouz"), m)
        XCTAssertEqual(map.attributedKey(at: insideMTowardN(engine), geometric: m, layout: KeyboardLayout(width: 440),
                                         prefix: "arou"), m)
    }

    func testUnknownPrefixBacksOffToUniformOdds() throws {
        let sources = try XCTUnwrap(BundledKeyboardData.lexicons)
        let priors = try XCTUnwrap(KeyboardKeyMap.priors(prefix: "zqxw", languages: [.english, .german],
                                                         lexicons: sources, personal: nil))
        for p in priors { XCTAssertEqual(p, 1.0 / 26, accuracy: 1e-12) }
        let (engine, target) = try keyboard()
        type("zqxw", engine)
        XCTAssertNotNil(engine.autocorrect.keyMap(layout: engine.layout, context: target.text, permitsCorrection: true))
        tap(insideMTowardN(engine), engine)
        XCTAssertEqual(target.text, "zqxwm", "without word odds the nearer key wins")
    }

    func testFirstLetterAcrossRowsAtFieldStartAfterSpaceAndAfterPunctuation() throws {
        for start in ["", "ok ", "ok,", "ok!", "(ok)"] {
            let (engine, target) = try keyboard(start)
            let point = topEdgeOfGUnderT(engine)
            XCTAssertEqual(engine.layout.hitTest(point)?.character, "g")
            XCTAssertTrue(engine.layout.reaches(point, letter: "t"))
            tap(point, engine)
            XCTAssertEqual(target.text, start + "t", start)
        }
    }

    func testLetterAfterAPeriodAtSignOrSlashInsideATokenTypesTheKeyItHits() throws {
        let cases: [(String, Character)] = [("wikipedia.", "o"), ("bit.", "l"), ("www.", "g"), ("gmx.", "n"),
                                            ("example.", "c"), ("github.", "c"), ("heise.", "d"), ("e.", "g"),
                                            ("i.", "e"), ("a.b@c.", "d"), ("a.", "b"), ("name@", "g"), ("x.com/", "a")]
        for trained in [false, true] {
            for (context, letter) in cases {
                let (engine, target) = try keyboard(context)
                if trained {
                    for _ in 0..<5 { "abcdefghijklmnopqrstuvwxyz".forEach { label($0, engine) } }
                    engine.refreshSuggestions()
                }
                XCTAssertNil(engine.autocorrect.keyMap(layout: engine.layout, context: context, permitsCorrection: true),
                             context)
                let area = key(letter, engine).hitFrame
                for i in 0..<15 {
                    for j in 0..<9 {
                        let point = CGPoint(x: area.minX + (CGFloat(i) + 0.5) * area.width / 15,
                                            y: area.minY + (CGFloat(j) + 0.5) * area.height / 9)
                        tap(point, engine)
                        XCTAssertEqual(target.text.last, letter, "\(context)\(letter) trained=\(trained)")
                        engine.deleteBackward()
                    }
                }
                XCTAssertEqual(target.text, context)
            }
        }
    }

    func testSentenceStartCapitalIsReadToo() throws {
        for start in ["", "Ok. "] {
            let (engine, target) = try keyboard(start, autocapitalization: .sentences, context: true)
            XCTAssertTrue(engine.isUppercase)
            tap(topEdgeOfGUnderT(engine), engine)
            XCTAssertEqual(target.text, start + "T", start)
        }
        let (engine, target) = try keyboard("wher")
        tap(center(engine.layout.key(.shift)!), engine)
        let e = key("e", engine)
        tap(CGPoint(x: e.hitFrame.maxX + 1, y: e.frame.midY), engine)
        XCTAssertEqual(target.text, "wherR", "a shifted capital inside a word stays literal")
    }

    func testSentenceContextChangesTheLetterOdds() throws {
        let sources = try XCTUnwrap(BundledKeyboardData.lexicons)
        let model = try XCTUnwrap(BundledKeyboardData.contextModel)
        let plain = try XCTUnwrap(KeyboardKeyMap.priors(prefix: "", languages: [.english], lexicons: sources, personal: nil))
        let context = model.keyMapContext(model.context(before: "one of ", currentToken: ""), german: false, english: true)
        let afterOf = try XCTUnwrap(KeyboardKeyMap.priors(prefix: "", languages: [.english], lexicons: sources,
                                                          personal: nil, context: context))
        let t = SpatialWordLexicon.alphabet.firstIndex(of: "t")!
        XCTAssertGreaterThan(afterOf[t], plain[t], "`the` follows `of`")
        XCTAssertEqual(afterOf.reduce(0, +), 1, accuracy: 1e-12)
    }

    func testOnlyReachableLettersCompeteAndOtherKeysKeepTheirTaps() throws {
        let (engine, target) = try keyboard("wher")
        let layout = engine.layout
        let sources = try XCTUnwrap(BundledKeyboardData.lexicons)
        let map = try XCTUnwrap(KeyboardKeyMap.make(layout: layout, prefix: "q", calibration: .init(keys: [:]),
                                                    languages: [.english], lexicons: sources, personal: nil))
        let a = key("a", engine)
        let top = CGPoint(x: a.frame.midX, y: a.hitFrame.minY + 1)
        XCTAssertFalse(layout.reaches(top, letter: "u"))
        XCTAssertNotEqual(map.attributedKey(at: top, geometric: a, layout: layout, prefix: "q").character, "u",
                          "u follows q, but the tap cannot reach it")
        for k in layout.keys where k.character.map({ $0.count != 1 || !$0.first!.isLetter }) ?? true {
            for point in [CGPoint(x: k.hitFrame.minX + 0.1, y: k.hitFrame.minY + 0.1),
                          CGPoint(x: k.hitFrame.maxX - 0.1, y: k.hitFrame.minY + 0.1)] where layout.hitTest(point) == k {
                XCTAssertEqual(map.attributedKey(at: point, geometric: k, layout: layout, prefix: "q"), k)
            }
        }
        let space = try XCTUnwrap(layout.key(.space))
        tap(CGPoint(x: space.frame.midX, y: space.hitFrame.minY + 1), engine)
        XCTAssertEqual(target.text, "wher ")
    }
}
