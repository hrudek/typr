import UIKit
import XCTest
@testable import Typr

@MainActor
final class TypingLogTests: XCTestCase {
    private final class Checker: TextChecking {
        func isWordValid(_ word: String) -> Bool { ["the", "hello", "world", "cat", "cats"].contains(word) }
        func guesses(for word: String) -> [String] { word == "teh" ? ["the"] : [] }
        func completions(for prefix: String) -> [String] { [] }
    }

    private var defaults: UserDefaults!
    private var suite: String!
    private var directory: URL!
    private var target: FixtureTextTarget!
    private var engine: FullKeyboardEngine!
    private var written: [TypingLogWord] = []
    private var clock: TimeInterval = 100
    /// Whole seconds: the export's ISO 8601 dates keep no fractions.
    private let wall = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        suite = "TypingLogTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        written = []
        makeEngine()
    }

    override func tearDown() async throws {
        engine = nil
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeEngine(configure: (FixtureTextTarget) -> Void = { _ in }) {
        target = FixtureTextTarget()
        target.autocapitalizationType = UITextAutocapitalizationType.none
        configure(target)
        let learning = KeyboardLearningSession(defaults: defaults)
        let autocorrect = AutocorrectEngine(checker: Checker(), learning: learning, spatialDecoder: nil)
        let log = TypingLogRecorder(write: { [unowned self] in self.written.append($0) }, now: { [unowned self] in self.wall })
        engine = FullKeyboardEngine(target: target, autocorrect: autocorrect, typingLog: log)
        engine.width = 393
        engine.clock = { [unowned self] in self.clock }
        engine.configureForField()
    }

    private func tap(_ kind: KeyKind) {
        let frame = engine.layout.key(kind)!.frame
        let point = CGPoint(x: frame.midX, y: frame.midY)
        engine.touchBegan(id: 1, at: point)
        engine.touchEnded(id: 1, at: point)
        clock += 0.1
    }

    private func type(_ text: String) {
        for character in text { tap(character == " " ? .space : .character(String(character))) }
    }

    func testSettledWordRecordsTapsLayoutAndMeantWord() throws {
        type("hello w")
        XCTAssertEqual(written.count, 1)
        let word = try XCTUnwrap(written.first)
        XCTAssertEqual(word.meant, "hello")
        XCTAssertEqual(word.literal, "hello")
        XCTAssertEqual(word.end, " ")
        XCTAssertEqual(word.commit, .init(kind: .literal, text: "hello"))
        XCTAssertEqual(word.hitAreas, "standard")
        XCTAssertEqual(word.languages, ["en"])
        XCTAssertEqual(word.taps.map(\.key), ["h", "e", "l", "l", "o"])
        XCTAssertEqual(word.taps.map(\.t), [0, 100, 200, 300, 400])
        let h = engine.layout.key(.character("h"))!.frame
        XCTAssertEqual(word.taps[0].x ?? 0, Double(h.midX), accuracy: 0.01)
        XCTAssertEqual(word.taps[0].y ?? 0, Double(h.midY), accuracy: 0.01)
        XCTAssertEqual(word.layout?.keyboardLayout, engine.layout)
    }

    func testAutocorrectionThenUndoRecordsBothAndTheRestoredWord() throws {
        type("teh ")
        XCTAssertEqual(target.text, "the ")
        engine.deleteBackward()
        XCTAssertEqual(target.text, "teh")
        type(" x")
        let word = try XCTUnwrap(written.first)
        XCTAssertEqual(word.commit?.kind, .autocorrect)
        XCTAssertEqual(word.commit?.text, "the")
        XCTAssertEqual(word.corrections, [.init(kind: .undo, from: "the", to: "teh")])
        XCTAssertEqual(word.meant, "teh")
    }

    func testAcceptedAutocorrectionIsTheMeantWord() throws {
        type("teh x")
        let word = try XCTUnwrap(written.first)
        XCTAssertEqual(word.literal, "teh")
        XCTAssertEqual(word.meant, "the")
    }

    func testBackspaceRetypeKeepsErasedTaps() throws {
        type("hrl")
        engine.deleteBackward()
        engine.deleteBackward()
        type("ello x")
        let word = try XCTUnwrap(written.first)
        XCTAssertEqual(word.meant, "hello")
        XCTAssertEqual(word.literal, "hello")
        XCTAssertEqual(word.corrections.map(\.kind), [.backspace])
        XCTAssertEqual(word.corrections.first?.erased?.map(\.text), ["r", "l"])
    }

    func testManualPickIsACorrection() throws {
        type("wor")
        engine.acceptOwnedFixtureSuggestion(.init(displayText: "world", replacement: "world", kind: .primary(autoReplace: false)))
        type("x")
        let word = try XCTUnwrap(written.first)
        XCTAssertEqual(word.meant, "world")
        XCTAssertEqual(word.commit?.kind, .pick)
        XCTAssertEqual(word.corrections, [.init(kind: .pick, from: "wor", to: "world", chip: "primary")])
    }

    func testFieldChangeSettlesTheOpenWord() throws {
        type("cat")
        engine.configureForField()
        XCTAssertEqual(written.map(\.meant), ["cat"])
        XCTAssertEqual(written.first?.end, "field")
    }

    private func recorder() -> TypingLogRecorder {
        TypingLogRecorder(write: { [unowned self] in self.written.append($0) }, now: { [unowned self] in self.wall })
    }

    /// Feeds the recorder what the engine reports for each typed character.
    private func record(_ text: String, into log: TypingLogRecorder, field: inout String) {
        let layout = KeyboardLayout(width: 393)
        for character in text.map(String.init) {
            field += character
            if character == " " { log.boundary(" "); continue }
            let point = layout.key(.character(character)).map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }
            log.typed(character, point: point, key: point == nil ? nil : character, layout: layout,
                      time: clock, token: AutocorrectEngine.currentToken(in: field))
        }
    }

    func testApostropheWordsStayWhole() {
        written = []
        let log = recorder()
        var field = ""
        record("can't can’t 'hello' x", into: log, field: &field)
        XCTAssertEqual(written.map(\.meant), ["can't", "can’t", "hello"])
        XCTAssertEqual(written.map(\.literal), ["can't", "can’t", "hello'"])
    }

    func testEndlessEditsOfOneWordAreDropped() {
        written = []
        let log = recorder()
        var field = ""
        record("a", into: log, field: &field)
        for _ in 0...TypingLogRecorder.maxCorrections {
            record("b", into: log, field: &field)
            field.removeLast()
            log.deleted(token: AutocorrectEngine.currentToken(in: field))
        }
        log.end("field")
        XCTAssertEqual(written, [])
    }

    func testSecureURLEmailAndNoAutocorrectFieldsRecordNothing() {
        let fields: [(FixtureTextTarget) -> Void] = [
            { $0.isSecureTextEntry = true },
            { $0.keyboardType = .URL },
            { $0.keyboardType = .emailAddress },
            { $0.autocorrectionType = .no },
        ]
        for configure in fields {
            makeEngine(configure: configure)
            type("hello w")
            engine.configureForField()
        }
        XCTAssertEqual(written, [])
    }

    func testNothingIsRecordedWhileLearningIsOff() {
        TyprSettings(defaults: defaults).personalLearning = false
        makeEngine()
        type("hello world ")
        engine.configureForField()
        XCTAssertEqual(written, [])
    }

    private func word(_ meant: String) -> TypingLogWord {
        TypingLogWord(at: wall, end: " ", languages: ["en"],
                      hitAreas: "standard", literal: meant, meant: meant)
    }

    func testStoreKeepsOnlyTheMostRecentSegments() throws {
        let store = TypingLogStore(directory: directory, segmentWords: 3)
        for index in 1...8 { store.append(word("w\(index)")) }
        store.waitForWrites()
        XCTAssertEqual(try store.words().map(\.meant), ["w4", "w5", "w6", "w7", "w8"])
        XCTAssertEqual(try store.wordCount(), 5)
        let reopened = TypingLogStore(directory: directory, segmentWords: 3)
        reopened.append(word("w9"))
        reopened.append(word("w10"))
        reopened.waitForWrites()
        XCTAssertEqual(try reopened.words().map(\.meant), ["w7", "w8", "w9", "w10"])
    }

    func testTwoKeyboardProcessesShareTheRotation() throws {
        let first = TypingLogStore(directory: directory, segmentWords: 3)
        let second = TypingLogStore(directory: directory, segmentWords: 3)
        for index in 1...10 {
            let store = index.isMultiple(of: 2) ? second : first
            store.append(word("w\(index)"))
            store.waitForWrites()
        }
        XCTAssertEqual(try first.words().map(\.meant), ["w7", "w8", "w9", "w10"])
    }

    func testAppendAfterACutShortLineKeepsTheNewWord() throws {
        let store = TypingLogStore(directory: directory)
        store.append(word("hello"))
        store.waitForWrites()
        let file = directory.appendingPathComponent(TypingLogStore.currentName)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"at\":".utf8))
        try handle.close()
        store.append(word("world"))
        store.waitForWrites()
        XCTAssertEqual(try store.words().map(\.meant), ["hello", "world"])
    }

    func testRotationByAnotherProcessIsNotMistakenForTheSameFile() throws {
        let layout = TypingLogLayout(KeyboardLayout(width: 393))
        let candidates = (1...64).flatMap { length in [" ", "\n"].map { end in
            let text = String(repeating: "a", count: length)
            return TypingLogWord(at: wall, end: end, languages: ["en"], hitAreas: "standard", layout: layout,
                                 taps: (0..<length).map { TypingLogTap(t: $0 * 100, x: 100, y: 150, key: "a", text: "a") },
                                 literal: text, commit: .init(kind: .literal, text: text), meant: text)
        } }
        let sizes = try candidates.map { try TypingLogExport.encoder().encode($0).count + 1 }
        var match: (TypingLogWord, TypingLogWord, TypingLogWord)?
        for a in candidates.indices where match == nil {
            for b in candidates.indices where match == nil {
                if let c = sizes.firstIndex(of: sizes[a] + sizes[b]) { match = (candidates[a], candidates[b], candidates[c]) }
            }
        }
        let (small, other, big) = try XCTUnwrap(match)
        let first = TypingLogStore(directory: directory, segmentWords: 3)
        let second = TypingLogStore(directory: directory, segmentWords: 3)
        first.append(big)
        first.waitForWrites()
        for entry in [small, small, small, other] { second.append(entry) }
        second.waitForWrites()
        first.append(small)
        first.append(small)
        first.waitForWrites()
        XCTAssertEqual(try first.words(), [small, other, small, small])
    }

    func testOversizedRecordIsNotWritten() throws {
        let store = TypingLogStore(directory: directory)
        var huge = word("hello")
        huge.corrections = Array(repeating: .init(kind: .pick, from: String(repeating: "a", count: 1_000), to: "a"),
                                 count: 20)
        store.append(huge)
        store.append(word("world"))
        store.waitForWrites()
        XCTAssertEqual(try store.words().map(\.meant), ["world"])
    }

    func testDeleteRemovesTheLog() throws {
        let store = TypingLogStore(directory: directory)
        store.append(word("hello"))
        store.waitForWrites()
        try store.delete()
        XCTAssertEqual(try store.words(), [])
        store.append(word("again"))
        store.waitForWrites()
        XCTAssertEqual(try store.words().map(\.meant), ["again"])
    }

    func testExportIsVersionedAndCarriesOnlyTouchCalibration() throws {
        type("hello w")
        let store = TypingLogStore(directory: directory)
        written.forEach(store.append)
        let model = PersonalTypingModel(now: { [unowned self] in self.wall })
        model.keep("typr")
        let a = try XCTUnwrap(engine.layout.key(.character("a"))).frame
        model.learn([TouchLabel(point: CGPoint(x: a.midX, y: a.midY), letter: "a")], layout: engine.layout, source: .literalValid)
        XCTAssertFalse(model.state.layouts.isEmpty)

        let file = try store.export(touchModel: model.state, appBuild: "42", into: directory,
                                    now: wall)
        let data = try Data(contentsOf: file)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["format", "version", "exportedAt", "appBuild", "touchModel", "words"])
        XCTAssertEqual(object["format"] as? String, "typr-typing-log")
        XCTAssertEqual(object["version"] as? Int, 1)
        let export = try TypingLogExport.decoder().decode(TypingLogExport.self, from: data)
        XCTAssertEqual(export.words, written)
        XCTAssertEqual(export.touchModel?.layouts, model.state.layouts)
        XCTAssertEqual(export.touchModel?.kept, [:])
        XCTAssertNotNil(export.touchModel?.validated())
    }
}
