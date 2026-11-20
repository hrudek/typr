import UIKit
import XCTest
@testable import Typr

/// Swipe typing: gesture detection, insertion, alternatives, cancellation and stale results run
/// against a scripted recognizer; the recognition tests run the bundled model and word lists on
/// synthetic key-center paths (no recorded or personal text).
@MainActor
final class SwipeTypingTests: XCTestCase {
    private var target: FixtureTextTarget!
    private var engine: FullKeyboardEngine!
    private var now: TimeInterval = 100
    private var suiteName: String!
    private var defaults: UserDefaults!
    /// The scripted recognizer's answers; a main-actor box so the `@Sendable` decoder need not capture the test.
    @MainActor private final class Script {
        var results: [SwipeSearch.Candidate] = []
        var requests = 0
    }
    private var script = Script()
    private var results: [SwipeSearch.Candidate] {
        get { script.results }
        set { script.results = newValue }
    }
    private var requests: Int { script.requests }

    private static var lexicons: [SpatialWordDecoder.Language: SpatialWordLexicon] {
        BundledKeyboardData.lexicons ?? [:]
    }

    override func setUp() async throws {
        suiteName = "SwipeTypingTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        reset()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func reset(text: String = "", keyboardType: UIKeyboardType = .default,
                       decoder: SwipeDecoding? = nil) {
        target = FixtureTextTarget(text: text)
        target.autocapitalizationType = UITextAutocapitalizationType.none
        target.keyboardType = keyboardType
        let ac = AutocorrectEngine(learning: KeyboardLearningSession(defaults: defaults),
                                   spatialDecoder: SpatialWordDecoder(lexicons: Self.lexicons))
        let script = script
        let scripted: SwipeDecoding = { _ in
            await MainActor.run {
                script.requests += 1
                return script.results
            }
        }
        engine = FullKeyboardEngine(target: target, autocorrect: ac, swipeDecoder: decoder ?? scripted)
        engine.width = 393
        engine.clock = { [unowned self] in self.now }
        engine.configureForField()
    }

    private func candidates(_ words: String...) -> [SwipeSearch.Candidate] {
        words.enumerated().map { .init(word: $0.element, score: -Double($0.offset), language: .english) }
    }

    private func center(_ letter: Character) -> CGPoint {
        let key = engine.layout.key(.character(String(letter)))!
        return CGPoint(x: key.frame.midX, y: key.frame.midY)
    }

    /// Key-center polyline through `word`, sampled every 8 ms like coalesced 120 Hz touches.
    private func path(_ word: String) -> [(point: CGPoint, time: TimeInterval)] {
        let centers = word.map(center)
        var samples: [(point: CGPoint, time: TimeInterval)] = [(centers[0], now)]
        for (from, to) in zip(centers, centers.dropFirst()) {
            let steps = max(2, Int(hypot(to.x - from.x, to.y - from.y) / 6))
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                now += 0.008
                samples.append((CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t), now))
            }
        }
        return samples
    }

    /// Moves along `word` without lifting; returns the last point.
    @discardableResult
    private func slide(_ id: Int, _ word: String) -> CGPoint {
        let samples = path(word)
        engine.touchBegan(id: id, at: samples[0].point, time: samples[0].time)
        for chunk in stride(from: 1, to: samples.count, by: 2) {
            let batch = Array(samples[chunk..<min(chunk + 2, samples.count)])
            engine.touchMoved(id: id, to: batch.last!.point, samples: batch)
        }
        return samples.last!.point
    }

    private func swipe(_ word: String, id: Int = 1) async {
        let end = slide(id, word)
        engine.touchEnded(id: id, at: end)
        await engine.waitForSwipe()
        now += 0.3
    }

    private func tap(_ kind: KeyKind) {
        let key = engine.layout.key(kind)!
        let at = CGPoint(x: key.frame.midX, y: key.frame.midY)
        engine.touchBegan(id: 9, at: at)
        engine.touchEnded(id: 9, at: at)
        now += 0.3
    }

    // MARK: - Gesture

    func testSwipeInsertsTheBestWordWithoutTypingLetters() async {
        results = candidates("hello", "help")
        _ = slide(1, "helo")
        XCTAssertTrue(engine.touches[1]?.isSwipe == true)
        XCTAssertNil(engine.previewKey, "a swipe shows no key balloon")
        XCTAssertFalse(engine.pressedKinds.contains(.character("h")))
        XCTAssertGreaterThan(engine.swipeTrail.count, 2)
        XCTAssertEqual(target.text, "")
        engine.touchEnded(id: 1, at: center("o"))
        XCTAssertTrue(engine.swipeTrail.isEmpty)
        await engine.waitForSwipe()
        XCTAssertEqual(target.text, "hello")
        XCTAssertEqual(requests, 1)
    }

    func testSlippedTapStillTypesOneLetter() async {
        results = candidates("hello")
        let start = center("g")
        // Within 0.8 key widths: an imprecise tap, not a swipe.
        let end = CGPoint(x: start.x + engine.layout.letterWidth * 0.5, y: start.y)
        engine.touchBegan(id: 1, at: start, time: now)
        engine.touchMoved(id: 1, to: end, samples: [(end, now + 0.05)])
        XCTAssertFalse(engine.touches[1]?.isSwipe == true)
        engine.touchEnded(id: 1, at: end)
        await engine.waitForSwipe()
        XCTAssertEqual(target.text.count, 1)
        XCTAssertEqual(requests, 0)
    }

    func testConsecutiveSwipesAreSpacedAndPunctuationFollowsDirectly() async {
        results = candidates("hello")
        await swipe("helo")
        results = candidates("world")
        await swipe("world")
        XCTAssertEqual(target.text, "hello world")
        tap(.layerSwitch(.numbers))
        tap(.character("."))
        XCTAssertEqual(target.text, "hello world.")
        tap(.layerSwitch(.letters))
        results = candidates("again")
        await swipe("again")
        XCTAssertEqual(target.text, "hello world. again")
    }

    func testShiftCapitalizesAndCapsLockUppercases() async {
        tap(.shift)
        results = candidates("hello")
        await swipe("helo")
        XCTAssertEqual(target.text, "Hello")
        XCTAssertFalse(engine.isUppercase, "one-shot shift is spent by the swiped word")
        // Double tap within the lock window.
        let shiftKey = engine.layout.key(.shift)!
        let shiftAt = CGPoint(x: shiftKey.frame.midX, y: shiftKey.frame.midY)
        for _ in 0..<2 {
            engine.touchBegan(id: 8, at: shiftAt)
            engine.touchEnded(id: 8, at: shiftAt)
            now += 0.1
        }
        XCTAssertEqual(engine.shift.state, .locked)
        results = candidates("world")
        await swipe("world")
        XCTAssertEqual(target.text, "Hello WORLD")
    }

    // MARK: - Alternatives, Delete, Space

    func testStripOffersAlternativesThatReplaceTheWordWithoutLearning() async throws {
        results = candidates("hello", "help", "hell")
        await swipe("helo")
        XCTAssertEqual(engine.suggestions.map(\.replacement), ["help", "hello", "hell"])
        XCTAssertTrue(engine.suggestions.allSatisfy(\.isSwipe))
        XCTAssertFalse(engine.suggestions.contains { $0.willAutoReplace })
        engine.acceptSuggestion(try XCTUnwrap(engine.suggestions.first))
        XCTAssertEqual(target.text, "help")
        XCTAssertEqual(engine.suggestions.map(\.replacement), ["hello", "help", "hell"])
        engine.acceptSuggestion(try XCTUnwrap(engine.suggestions.last))
        XCTAssertEqual(target.text, "hell")
        tap(.space)
        XCTAssertEqual(target.text, "hell ")
        let learning = engine.autocorrect.learning
        XCTAssertTrue(learning.model.lexicon.counts.isEmpty, "swiped words are not confirmed words")
        XCTAssertEqual(learning.diagnostics.acceptedLabels, 0)
        XCTAssertTrue(learning.model.state.layouts.isEmpty, "no tap calibration from swipes")
    }

    func testDeleteRemovesTheWholeSwipedWordOnce() async {
        results = candidates("hello")
        await swipe("helo")
        results = candidates("world")
        await swipe("world")
        engine.deleteBackward()
        XCTAssertEqual(target.text, "hello ")
        engine.deleteBackward()
        XCTAssertEqual(target.text, "hello")
    }

    func testSpaceAfterASwipedWordNeverAutocorrectsIt() async {
        // Valid-looking but rare words must stay as swiped.
        results = candidates("thw")
        await swipe("thw")
        tap(.space)
        XCTAssertEqual(target.text, "thw ")
        XCTAssertTrue(engine.suggestions.allSatisfy { !$0.isSwipe })
    }

    // MARK: - Cancel and stale results

    func testCancelledOrInterruptedSwipesInsertNothing() async {
        results = candidates("hello")
        _ = slide(1, "helo")
        engine.touchCancelled(id: 1)
        XCTAssertTrue(engine.swipeTrail.isEmpty)
        await engine.waitForSwipe()
        XCTAssertEqual(target.text, "")

        _ = slide(2, "helo")
        engine.cancelAllTouches()
        await engine.waitForSwipe()
        XCTAssertEqual(target.text, "")

        // A second finger ends the swipe without a word and types normally.
        let end = slide(3, "helo")
        tap(.character("x"))
        engine.touchEnded(id: 3, at: end)
        await engine.waitForSwipe()
        XCTAssertEqual(target.text, "x")
        XCTAssertEqual(requests, 0)
    }

    func testStaleResultsAreDropped() async {
        let gate = SwipeGate()
        reset(decoder: { _ in await gate.wait() })
        // A tap while decoding: the late word would land after the tap's letter.
        let end = slide(1, "helo")
        engine.touchEnded(id: 1, at: end)
        await gate.started()
        tap(.character("x"))
        await gate.release(candidates("hello"))
        await engine.waitForSwipe()
        XCTAssertEqual(target.text, "x")

        // A host text change while decoding.
        let end2 = slide(2, "helo")
        engine.touchEnded(id: 2, at: end2)
        await gate.started()
        target.insertText("!")
        engine.textDidChange()
        await gate.release(candidates("hello"))
        await engine.waitForSwipe()
        XCTAssertEqual(target.text, "x!")
    }

    func testSwipeStaysOffOutsideProseFields() async {
        for type in [UIKeyboardType.URL, .emailAddress] {
            reset(keyboardType: type)
            results = candidates("hello")
            let end = slide(1, "helo")
            XCTAssertFalse(engine.touches[1]?.isSwipe == true)
            engine.touchEnded(id: 1, at: end)
            await engine.waitForSwipe()
            XCTAssertEqual(target.text, "o", "\(type): sliding types where the finger lifts")
        }
        reset()
        target.autocorrectionType = .no
        results = candidates("hello")
        let end = slide(1, "helo")
        engine.touchEnded(id: 1, at: end)
        await engine.waitForSwipe()
        XCTAssertEqual(target.text, "o")
    }

    func testSwipeTypingSwitchOffKeepsSlideToKey() async {
        engine.swipeTypingEnabled = false
        results = candidates("hello")
        let end = slide(1, "helo")
        XCTAssertFalse(engine.touches[1]?.isSwipe == true)
        engine.touchEnded(id: 1, at: end)
        await engine.waitForSwipe()
        XCTAssertEqual(target.text, "o")
        XCTAssertEqual(requests, 0)

        engine.swipeTypingEnabled = true
        await swipe("helo")
        XCTAssertEqual(target.text, "o hello")
    }

    func testHeldLetterStillOpensAccentsAndSwipeDoesNot() {
        engine.autocorrect.german = GermanAutocorrect(checker: nil)
        let start = center("a")
        engine.touchBegan(id: 1, at: start, time: now)
        XCTAssertTrue(engine.openAccentMenuIfEligible(forTouch: 1))
        engine.touchCancelled(id: 1)
        _ = slide(2, "asdf")
        XCTAssertFalse(engine.openAccentMenuIfEligible(forTouch: 2))
        engine.touchCancelled(id: 2)
    }

    // MARK: - Spelling

    func testGermanNounsTakeDictionaryCasing() {
        let ac = AutocorrectEngine(learning: KeyboardLearningSession(defaults: defaults), spatialDecoder: nil)
        ac.german = GermanAutocorrect(checker: SwipeChecker(valid: ["Haus", "laufen", "Laufen"]))
        XCTAssertEqual(ac.swipeSpelling("haus", language: .german), "Haus")
        XCTAssertEqual(ac.swipeSpelling("laufen", language: .german), "laufen")
        XCTAssertEqual(ac.swipeSpelling("house", language: .english), "house")
        XCTAssertEqual(FullKeyboardEngine.swipeCased("straße", shift: .locked), "STRASSE")
        XCTAssertEqual(FullKeyboardEngine.swipeCased("über", shift: .on), "Über")
        XCTAssertFalse(FullKeyboardEngine.swipeNeedsSpace(before: "("))
        XCTAssertFalse(FullKeyboardEngine.swipeNeedsSpace(before: "a "))
        XCTAssertTrue(FullKeyboardEngine.swipeNeedsSpace(before: "Hi,"))
    }

    // MARK: - Recognition (bundled model and word lists)

    func testBundledModelRecognizesGermanAndEnglishOnQwerty() async throws {
        let layout = try XCTUnwrap(SwipeLayout(layout: engine.layout))
        let recognizer = SwipeRecognizer()
        let words = ["hello", "keyboard", "danke", "zusammen"]
        var top1 = 0
        for word in words {
            let path = self.path(word).map { SwipePoint(x: $0.point.x, y: $0.point.y, time: $0.time) }
            let found = await recognizer.decode(path, layout: layout, languages: [.german, .english],
                                                lexicons: Self.lexicons, resources: 0)
            let ranked = found.prefix(3).map { SwipeLexicon.fold($0.word) }
            XCTAssertTrue(ranked.contains(SwipeLexicon.fold(word)), "\(word): \(found.prefix(3).map(\.word))")
            if found.first.map({ SwipeLexicon.fold($0.word) }) == SwipeLexicon.fold(word) { top1 += 1 }
        }
        XCTAssertGreaterThanOrEqual(top1, words.count - 1)
    }

    func testBundledEncoderLoadsAndRejectsCorruptData() throws {
        XCTAssertNotNil(SwipeEncoder.bundled())
        let url = try XCTUnwrap(Bundle.main.url(forResource: "swipe-encoder", withExtension: "tse",
                                                subdirectory: "SwipeModel"))
        let data = try Data(contentsOf: url)
        XCTAssertNil(SwipeEncoder(data: data.prefix(data.count / 2)))
        XCTAssertNil(SwipeEncoder(data: Data("TSE0".utf8) + data.dropFirst(4)))
        XCTAssertNotNil(Bundle.main.url(forResource: "LICENSE-FUTO-SWIPE", withExtension: "txt",
                                        subdirectory: "SwipeModel"))
    }
}

/// Holds one decode until the test releases it.
private actor SwipeGate {
    private var waiting: CheckedContinuation<[SwipeSearch.Candidate], Never>?
    private var onStart: CheckedContinuation<Void, Never>?

    func wait() async -> [SwipeSearch.Candidate] {
        await withCheckedContinuation { continuation in
            waiting = continuation
            onStart?.resume()
            onStart = nil
        }
    }

    func started() async {
        if waiting != nil { return }
        await withCheckedContinuation { onStart = $0 }
    }

    func release(_ result: [SwipeSearch.Candidate]) {
        waiting?.resume(returning: result)
        waiting = nil
    }
}

@MainActor
private final class SwipeChecker: TextChecking {
    let valid: Set<String>
    init(valid: Set<String>) { self.valid = valid }
    func isWordValid(_ word: String) -> Bool { valid.contains(word) }
    func guesses(for word: String) -> [String] { [] }
    func completions(for prefix: String) -> [String] { [] }
}
