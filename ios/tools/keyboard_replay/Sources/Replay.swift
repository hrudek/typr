import Foundation

typealias Language = SpatialWordDecoder.Language

/// The hit-area setting a replay runs with; `rawValue` matches `TypingLogWord.hitAreas`.
enum HitAreas: String, CaseIterable {
    case standard
}

struct WordData {
    let lexicons: [Language: SpatialWordLexicon]
    let context: KeyboardContextModel?

    init(directory: URL) throws {
        var lexicons: [Language: SpatialWordLexicon] = [:]
        for language in Language.allCases {
            let url = directory.appendingPathComponent("keyboard-\(language.rawValue).words")
            guard let lexicon = SpatialWordLexicon(data: try Data(contentsOf: url)) else {
                throw ReplayError("Invalid word list \(url.path)")
            }
            lexicons[language] = lexicon
        }
        self.lexicons = lexicons
        let packs = ["de", "en"].map {
            KeyboardContextModel.Pack(contentsOf: directory.appendingPathComponent("keyboard-\($0).tbg"))
        }
        context = KeyboardContextModel(de: packs[0], en: packs[1])
    }

    func isKnown(_ word: String, in languages: Set<Language>) -> Bool {
        let letters = word.lowercased().filter { $0 != "'" && $0 != "’" }
        return languages.contains { lexicons[$0]?.logPrior(for: letters) != nil }
    }
}

/// System spelling stand-in: a word is valid when the bundled list has it, with no guesses.
@MainActor
final class LexiconChecker: TextChecking {
    private let lexicon: SpatialWordLexicon?

    init(_ lexicon: SpatialWordLexicon?) { self.lexicon = lexicon }

    func isWordValid(_ word: String) -> Bool { lexicon?.logPrior(for: word.lowercased()) != nil }
    func guesses(for word: String) -> [String] { [] }
    func completions(for prefix: String) -> [String] { [] }
}

@MainActor
final class ReplayTarget: KeyboardTextTarget {
    var text: String

    init(text: String) { self.text = text }

    var documentContextBeforeInput: String? { text }
    var hasText: Bool { !text.isEmpty }
    var autocapitalizationType: UITextAutocapitalizationType? { .sentences }
    var keyboardType: UIKeyboardType? { .default }
    var returnKeyType: UIReturnKeyType? { .default }
    var keyboardAppearance: UIKeyboardAppearance? { .default }
    func insertText(_ text: String) { self.text += text }
    func deleteBackward() { if !text.isEmpty { text.removeLast() } }
}

enum SkipReason: String, Error {
    case swipe, noTaps = "no taps", tapWithoutPoint = "tap without point", overBounds = "over bounds"
    case unknownLayout = "unknown layout", layoutDrift = "layout drift"
}

struct ReplayedWord {
    /// What the replayed taps inserted.
    var literal: String
    /// The word after the logged separator, or `literal` when the word ended without one.
    var committed: String
}

/// Feeds logged taps through the keyboard's own engine, one fresh engine per word.
@MainActor
final class Replayer {
    static let separators: Set<String> = [" ", ".", ",", "?", "!", "\n"]

    private let words: WordData
    private let decoder: SpatialWordDecoder
    private let contextResources: KeyboardContextResources
    private let english: LexiconChecker
    private let german: GermanAutocorrect
    private let learningStore: URL?

    /// `learningStore`: a private directory that receives the export's touch model.
    init(words: WordData, touchModel: PersonalTypingModel.State?, learningStore: URL) throws {
        self.words = words
        decoder = SpatialWordDecoder(lexicons: words.lexicons)
        contextResources = KeyboardContextResources(model: words.context)
        english = LexiconChecker(words.lexicons[.english])
        german = GermanAutocorrect(checker: LexiconChecker(words.lexicons[.german]))
        if let touchModel {
            var diagnostics = KeyboardDiagnostics()
            guard KeyboardLearningStore(directory: learningStore, defaults: nil)
                .save(model: touchModel, diagnostics: &diagnostics) else {
                throw ReplayError("The export's touch model is invalid")
            }
            self.learningStore = learningStore
        } else {
            self.learningStore = nil
        }
    }

    static func skipReason(_ word: TypingLogWord) -> SkipReason? {
        if word.swipe == true { return .swipe }
        if word.taps.isEmpty { return .noTaps }
        if word.taps.count > TypingLogRecorder.maxTaps || word.corrections.count > TypingLogRecorder.maxCorrections {
            return .overBounds
        }
        if word.taps.contains(where: { $0.x == nil || $0.y == nil }) { return .tapWithoutPoint }
        guard let layout = word.layout?.keyboardLayout, layout.layer == .letters, layout.field == .text else {
            return .unknownLayout
        }
        return nil
    }

    /// Each session reads the same snapshot and never writes it back.
    private func learning() -> KeyboardLearningSession {
        guard let learningStore else { return KeyboardLearningSession(store: nil, defaults: nil) }
        var opening = true
        let session = KeyboardLearningSession(store: KeyboardLearningStore(directory: learningStore, defaults: nil),
                                              defaults: nil, allowsPersistence: { opening })
        opening = false
        return session
    }

    /// `context`: the text before the word in its field, as far as the log tells.
    func replay(_ word: TypingLogWord, context: String, hitAreas: HitAreas) -> Result<ReplayedWord, SkipReason> {
        if let reason = Self.skipReason(word) { return .failure(reason) }
        guard let logged = word.layout, let layout = logged.keyboardLayout else { return .failure(.unknownLayout) }
        let languages = Set(word.languages.compactMap(Language.init(rawValue:)))
        let autocorrect = AutocorrectEngine(checker: english, learning: learning(), spatialDecoder: decoder,
                                            contextResources: contextResources)
        autocorrect.englishEnabled = languages.contains(.english)
        autocorrect.german = languages.contains(.german) ? german : nil
        let target = ReplayTarget(text: context)
        let engine = FullKeyboardEngine(target: target, autocorrect: autocorrect, swipeDecoder: { _ in [] })
        var now: TimeInterval = 1_000
        engine.clock = { now }
        engine.scheduleAfter = { _, _ in }
        engine.width = layout.width
        engine.orientation = layout.orientation
        engine.showsGlobe = layout.showsGlobe
        engine.globeKey = layout.globeKey
        engine.bottomRow = layout.bottomRow
        engine.numberRow = layout.numberRow
        engine.horizontalInset = layout.horizontalInset
        engine.showsStrip = layout.showsStrip
        engine.configureForField()
        guard TypingLogLayout(engine.layout) == logged else { return .failure(.layoutDrift) }

        var touch = 0
        func press(_ point: CGPoint) {
            touch += 1
            engine.touchBegan(id: touch, at: point, time: now)
            engine.touchEnded(id: touch, at: point)
        }
        func press(_ kind: KeyKind) {
            guard let key = engine.layout.key(kind) else { return }
            press(CGPoint(x: key.frame.midX, y: key.frame.midY))
        }
        let start = now
        for tap in word.taps {
            guard let x = tap.x, let y = tap.y else { return .failure(.tapWithoutPoint) }
            let time = start + Double(tap.t) / 1000
            if tap.text.first?.isLetter == true, (tap.text != tap.text.lowercased()) != engine.isUppercase {
                now = max(now + 0.001, time - 0.05)
                press(.shift)
            }
            now = max(now + 0.001, time)
            press(CGPoint(x: x, y: y))
        }
        let literal = String(target.text.dropFirst(context.count))
        now += 0.2
        switch word.end {
        case " ", ".", ",", "?", "!": press(.space)
        case "\n": press(.returnKey)
        default: return .success(ReplayedWord(literal: literal, committed: literal))
        }
        var committed = String(target.text.dropFirst(context.count))
        if committed.last?.isWhitespace == true { committed.removeLast() }
        return .success(ReplayedWord(literal: literal, committed: committed))
    }
}

struct ReplayError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
