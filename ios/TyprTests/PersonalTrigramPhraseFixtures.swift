import Foundation
import XCTest
@testable import Typr

/// Authored, disjoint-context phrases shared by the default trigram tests and the
/// research-only learning sweep. Every phrase in a language shares its middle word,
/// so only the earlier word separates the targets.
@MainActor
enum PersonalTrigramPhraseFixtures {
    static let phrases: [String: [[String]]] = [
        "de": [["unser", "projekt", "tastatur"], ["mein", "projekt", "garten"],
               ["dein", "projekt", "schule"], ["jedes", "projekt", "kaffee"]],
        "en": [["our", "project", "keyboard"], ["my", "project", "garden"],
               ["your", "project", "school"], ["every", "project", "coffee"]],
        "mixed": [["unser", "release", "keyboard"], ["my", "release", "garten"],
                  ["dein", "release", "school"], ["every", "release", "kaffee"]]
    ]
    static let trainingModes = ["settled", "completion", "prediction"]

    final class Checker: TextChecking {
        func isWordValid(_ word: String) -> Bool { true }
        func guesses(for word: String) -> [String] { [] }
        func completions(for prefix: String) -> [String] { [] }
    }

    private static func tap(_ text: String, engine: FullKeyboardEngine) {
        for ch in text {
            guard let key = engine.layout.key(ch == " " ? .space : .character(String(ch))) else {
                XCTFail("Missing key"); return
            }
            let p = CGPoint(x: key.frame.midX, y: key.frame.midY)
            engine.touchBegan(id: 1, at: p); engine.touchEnded(id: 1, at: p)
        }
    }

    /// One phrase through one trusted path: directly settled words, or key-centre taps
    /// with the third word accepted as a completion of its first three letters or as a
    /// prediction, settled by one following letter.
    static func train(_ phrase: [String], mode: String, session: KeyboardLearningSession,
                      file: StaticString = #filePath, line: UInt = #line) {
        session.breakWordSequence()
        if mode == "settled" {
            var before = ""
            for word in phrase {
                before += word + " "
                session.settleTrustedWord(word, beforeInput: before)
            }
            return
        }
        let target = FixtureTextTarget()
        target.autocapitalizationType = .some(.none)
        let ac = AutocorrectEngine(checker: Checker(), learning: session, spatialDecoder: nil,
                                   contextResources: .init(model: nil))
        let engine = FullKeyboardEngine(target: target, autocorrect: ac)
        engine.width = 393; engine.clock = { 100 }; engine.configureForField()
        let prefix = mode == "completion" ? String(phrase[2].prefix(3)) : ""
        tap(phrase[0] + " " + phrase[1] + " " + prefix, engine: engine)
        var chip = KeyboardSuggestion(displayText: phrase[2], replacement: phrase[2],
                                      kind: .primary(autoReplace: false), isCompletion: true)
        chip.ownership = engine.suggestionOwnership
        engine.acceptSuggestion(chip)
        tap("n", engine: engine)
        XCTAssertEqual(target.text, phrase.joined(separator: " ") + " n", file: file, line: line)
    }
}
