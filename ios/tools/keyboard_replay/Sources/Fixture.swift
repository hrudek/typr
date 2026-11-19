import Foundation
import UIKit

/// Writes the synthetic export: invented text typed through the keyboard engine with the typing log
/// recorder attached, the way a user types (slips, backspace, undo, an edit after the space, a pick).
@MainActor
func makeFixture(words data: WordData, to url: URL) async throws {
    let protectedWords = ["Kalvenor"]
    var logged: [TypingLogWord] = []
    var clockDate = Date(timeIntervalSince1970: 1_790_000_000)
    let recorder = TypingLogRecorder(write: { logged.append($0) }, now: { clockDate })
    let learning = KeyboardLearningSession(store: nil, defaults: nil)
    let autocorrect = AutocorrectEngine(checker: LexiconChecker(data.lexicons[.english]), learning: learning,
                                        spatialDecoder: SpatialWordDecoder(lexicons: data.lexicons),
                                        contextResources: KeyboardContextResources(model: data.context))
    autocorrect.german = GermanAutocorrect(checker: LexiconChecker(data.lexicons[.german]))
    var builder = ProtectedPersonalLexicon.Builder()
    protectedWords.forEach { builder.add($0) }
    autocorrect.loadProtectedLexicon(builder.build())
    let target = ReplayTarget(text: "")
    let engine = FullKeyboardEngine(target: target, autocorrect: autocorrect, typingLog: recorder,
                                    swipeDecoder: { _ in [] })
    var now: TimeInterval = 500
    engine.clock = { now }
    engine.scheduleAfter = { _, _ in }
    engine.width = 393
    engine.configureForField()

    func teach(aim: Double) {
        let layout = engine.layout
        for round in 0..<40 {
            let jitter = Double(round % 3 - 1) * 0.04
            let labels = "abcdefghijklmnopqrstuvwxyz".map { letter -> TouchLabel in
                let key = layout.key(.character(String(letter)))!
                return TouchLabel(point: CGPoint(x: key.frame.midX + (aim + jitter) * key.frame.width,
                                                 y: key.frame.midY + (0.1 + jitter) * key.frame.height), letter: letter)
            }
            learning.learn(labels, layout: layout, source: .keep)
        }
    }
    learning.keep("Ive")
    learning.keep("Brisolde")

    var seed: UInt64 = 7
    func noise() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double(seed >> 11) / 9_007_199_254_740_992 - 0.5
    }
    var touch = 0
    func press(_ point: CGPoint) {
        touch += 1
        now += 0.16
        clockDate += 0.16
        engine.touchBegan(id: touch, at: point, time: now)
        engine.touchEnded(id: touch, at: point)
    }
    func press(_ kind: KeyKind) {
        let key = engine.layout.key(kind)!
        press(CGPoint(x: key.frame.midX, y: key.frame.midY))
    }
    /// Aims right of and below each key's center, like the learned touch model above.
    func type(_ text: String) {
        for character in text {
            let lower = String(character).lowercased()
            if (String(character) != lower) != engine.isUppercase { press(.shift) }
            let key = engine.layout.key(.character(lower))!
            press(CGPoint(x: key.frame.midX + (0.18 + noise() * 0.2) * key.frame.width,
                          y: key.frame.midY + (0.1 + noise() * 0.2) * key.frame.height))
        }
    }
    func slip(_ intended: Character, towards neighbor: Character, share: Double) {
        let a = engine.layout.key(.character(String(intended)))!.frame
        let b = engine.layout.key(.character(String(neighbor)))!.frame
        press(CGPoint(x: a.midX + (b.midX - a.midX) * share, y: a.midY + (b.midY - a.midY) * share))
    }
    func word(_ text: String) { type(text); press(.space) }
    func center(_ letters: String) {
        for letter in letters {
            let key = engine.layout.key(.character(String(letter)))!
            press(CGPoint(x: key.frame.midX, y: key.frame.midY))
        }
    }
    teach(aim: 0.18)

    ["Morgen", "fahre", "ich", "mit", "Kalvenor", "zum"].forEach(word)
    type("Wolkenradweg"); press(.returnKey)
    word("the")
    type("ho"); slip("u", towards: "y", share: 0.6); type("se")
    for _ in 0..<3 { press(.delete) }
    word("use")
    word("was")
    word("teh")
    press(.delete); press(.space)
    ["dont", "Ive", "and", "teh"].forEach(word)
    type("wot"); press(.delete); word("rld")
    ["quiet", "and", "i", "Brisolde", "fine"].forEach(word)
    for _ in 0..<5 { press(.delete) }
    ["great", "Sonnenblumenfeld"].forEach(word)

    autocorrect.german = nil
    engine.width = 390
    teach(aim: 0.3)
    let m = engine.layout.key(.character("m"))!
    center("arou")
    press(CGPoint(x: m.hitFrame.minX + 2, y: m.frame.midY))
    center("d")
    press(.delete)
    center("d")
    press(.space)
    center("arou")
    press(CGPoint(x: m.frame.midX - 0.2 * m.frame.width, y: m.frame.midY))
    center("d")
    await engine.waitForSuggestions()
    guard let around = engine.suggestions.first(where: { $0.replacement == "around" }) else {
        throw ReplayError("The strip offers no `around` for the fixture's edge miss")
    }
    engine.acceptSuggestion(around)
    word("most"); center("kf"); press(.space); press(.returnKey)
    word("even"); center("kf"); press(.space); press(.returnKey)
    center("jn"); press(.space); press(.returnKey)
    word("and"); center("iloveyou"); press(.space); press(.returnKey)
    type("today")
    engine.endTypingLogWord("dismiss")

    var swiped = TypingLogWord(at: clockDate, languages: ["de", "en"], swipe: true)
    swiped.commit = .init(kind: .swipe, text: "weather")
    swiped.meant = "weather"
    swiped.end = " "
    var accent = TypingLogWord(at: clockDate, languages: ["de", "en"])
    accent.taps = [TypingLogTap(t: 0, x: 120, y: 160, key: "c", text: "c"), TypingLogTap(t: 150, key: "a", text: "á")]
    accent.literal = "cá"
    accent.meant = "cá"
    accent.end = "field"
    let export = TypingLogExport(exportedAt: Date(timeIntervalSince1970: 1_790_000_600), appBuild: "fixture",
                                 learning: learning.model.state, protectedWords: protectedWords,
                                 words: logged + [swiped, accent])
    let encoder = TypingLogExport.encoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    try encoder.encode(export).write(to: url)
}
