import Foundation
import UIKit

typealias Language = SpatialWordDecoder.Language

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
    case editsNotReplayable = "edits not replayable", pickNotOffered = "pick not offered"
    case stateUncertain = "learning state uncertain"
}

/// A word's input up to its first boundary, rebuilt from the log: every tap in time order, erased
/// ones included, with the backspaces where the log puts them.
struct WordPlan {
    enum Step { case tap(TypingLogTap), delete(Int) }
    enum End { case none, separator(String), pick(to: String, chip: String) }
    var steps: [Step]
    /// The word's letters when its first boundary came.
    var literal: String
    var end: End

    /// Nil when the log does not tell the order of the word's edits up to its first boundary.
    init?(_ word: TypingLogWord) {
        let corrections = word.corrections
        let split = corrections.firstIndex { $0.kind != .backspace } ?? corrections.count
        let runs = corrections[..<split]
        let next = split < corrections.count ? corrections[split] : nil
        var target: String?
        switch (word.commit?.kind, next?.kind) {
        case (nil, nil):
            end = .none
        case (.literal?, nil), (.autocorrect?, nil):
            guard Replayer.separators.contains(word.end) else { return nil }
            end = .separator(word.end)
        case (.autocorrect?, .undo?):
            guard next?.from == word.commit?.text, let to = next?.to else { return nil }
            target = to
            end = .separator(" ")
        case (.literal?, .reopen?):
            target = word.commit?.text
            end = .separator(" ")
        case (.pick?, .pick?):
            guard let from = next?.from, let to = next?.to, let chip = next?.chip else { return nil }
            target = from
            end = .pick(to: to, chip: chip)
        default:
            return nil
        }
        let taps = (word.taps + corrections.flatMap { $0.erased ?? [] }).sorted { $0.t < $1.t }
        guard Set(taps.map(\.t)).count == taps.count else { return nil }
        var steps: [Step] = []
        var standing: [TypingLogTap] = []
        var run = runs.startIndex
        for tap in taps {
            if run == runs.endIndex, let target, standing.map(\.text).joined() == target { break }
            steps.append(.tap(tap))
            standing.append(tap)
            while run < runs.endIndex, let erased = runs[run].erased, erased.map(\.t).max() == tap.t {
                guard Array(standing.suffix(erased.count)) == erased else { return nil }
                standing.removeLast(erased.count)
                steps.append(.delete(erased.count))
                run += 1
            }
        }
        let literal = standing.map(\.text).joined()
        guard run == runs.endIndex, target.map({ $0 == literal }) ?? (standing == word.taps) else { return nil }
        self.literal = literal
        self.steps = steps
    }
}

/// What the word's own log proves about the learning when it was typed: an automatic correction
/// means its literal was neither kept, protected nor rejected for that replacement.
struct Adjustment: Equatable {
    var unkept: String?
    var unrejected: RejectedCorrection?
}

struct PreparedWord {
    let plan: WordPlan
    let adjustment: Adjustment
    /// In a bundled word list of the word's languages, imported or kept.
    let known: Bool
}

struct ReplayedWord {
    /// The word's letters at its first boundary.
    var literal: String
    /// What the keyboard committed at the first boundary, or `literal` when there was none.
    var committed: String
}

/// Feeds a word's logged input through the keyboard's own engine, one fresh engine per word.
@MainActor
final class Replayer {
    nonisolated static let separators: Set<String> = [" ", ".", ",", "?", "!", "\n"]

    private let words: WordData
    private let decoder: SpatialWordDecoder
    private let contextResources: KeyboardContextResources
    private let english: LexiconChecker
    private let german: GermanAutocorrect
    private let learning: PersonalTypingModel.State?
    private let protected: ProtectedPersonalLexicon

    init(words: WordData, export: TypingLogExport) throws {
        self.words = words
        var builder = ProtectedPersonalLexicon.Builder()
        export.protectedWords.forEach { builder.add($0) }
        protected = builder.build()
        decoder = SpatialWordDecoder(lexicons: words.lexicons)
        contextResources = KeyboardContextResources(model: words.context)
        english = LexiconChecker(words.lexicons[.english])
        german = GermanAutocorrect(checker: LexiconChecker(words.lexicons[.german]))
        if let learning = export.learning, learning.validated() == nil {
            throw ReplayError("The export's learning is invalid")
        }
        learning = export.learning
    }

    static func skipReason(_ word: TypingLogWord) -> SkipReason? {
        if word.swipe == true { return .swipe }
        if word.taps.isEmpty { return .noTaps }
        let taps = word.taps + word.corrections.flatMap { $0.erased ?? [] }
        if taps.count > TypingLogRecorder.maxTaps * 2 || word.corrections.count > TypingLogRecorder.maxCorrections {
            return .overBounds
        }
        if taps.contains(where: { $0.x == nil || $0.y == nil }) { return .tapWithoutPoint }
        guard let layout = word.layout?.keyboardLayout, layout.layer == .letters, layout.field == .text else {
            return .unknownLayout
        }
        return nil
    }

    /// Learning at export time is used as it is, except where the word's own log proves otherwise.
    /// A word the export-time learning protects in a way the log cannot date is not replayed.
    func prepare(_ word: TypingLogWord) -> Result<PreparedWord, SkipReason> {
        if let reason = Self.skipReason(word) { return .failure(reason) }
        guard let plan = WordPlan(word) else { return .failure(.editsNotReplayable) }
        var adjustment = Adjustment()
        if let commit = word.commit, commit.kind == .autocorrect {
            adjustment.unkept = PersonalLexiconSnapshot.normalize(plan.literal)
            adjustment.unrejected = RejectedCorrection(typed: plan.literal, replacement: commit.text)
        }
        let state = learning.map { adjusted($0, adjustment) }
        for text in Set([plan.literal, word.meant]) {
            let normalized = PersonalLexiconSnapshot.normalize(text)
            let protects = state?.kept[normalized] != nil
                || state?.rejected.contains { $0.typed == normalized } == true
                || protected(unless: adjustment.unkept).contains(text)
            if protects { return .failure(.stateUncertain) }
        }
        let languages = Set(word.languages.compactMap(Language.init(rawValue:)))
        return .success(PreparedWord(plan: plan, adjustment: adjustment,
                                     known: words.isKnown(word.meant, in: languages)))
    }

    private func adjusted(_ learning: PersonalTypingModel.State, _ adjustment: Adjustment) -> PersonalTypingModel.State {
        var state = learning
        if let unkept = adjustment.unkept { state.kept[unkept] = nil }
        if let unrejected = adjustment.unrejected { state.rejected.removeAll { $0 == unrejected } }
        return state
    }

    private func protected(unless unkept: String?) -> ProtectedPersonalLexicon {
        guard let unkept, protected.contains(unkept) else { return protected }
        var builder = ProtectedPersonalLexicon.Builder()
        protected.words.filter { $0 != ProtectedPersonalLexicon.key(unkept) }.forEach { builder.add($0) }
        return builder.build()
    }

    private func session(_ adjustment: Adjustment) -> KeyboardLearningSession {
        guard let learning else { return KeyboardLearningSession(store: nil, defaults: nil) }
        return KeyboardLearningSession(state: adjusted(learning, adjustment))
    }

    /// `context`: the text before the word in its field, as far as the log tells.
    func replay(_ word: TypingLogWord, _ prepared: PreparedWord, context: String) async throws -> Result<ReplayedWord, SkipReason> {
        guard let logged = word.layout, let layout = logged.keyboardLayout else { return .failure(.unknownLayout) }
        let languages = Set(word.languages.compactMap(Language.init(rawValue:)))
        let autocorrect = AutocorrectEngine(checker: english, learning: session(prepared.adjustment),
                                            spatialDecoder: decoder, contextResources: contextResources)
        autocorrect.loadProtectedLexicon(protected(unless: prepared.adjustment.unkept))
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
        engine.splitColumns = layout.splitColumns
        engine.splitMirrored = layout.splitMirrored
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
        func typed() -> String { String(target.text.dropFirst(context.count)) }
        let start = now
        for step in prepared.plan.steps {
            switch step {
            case .tap(let tap):
                guard let x = tap.x, let y = tap.y else { return .failure(.tapWithoutPoint) }
                let time = start + Double(tap.t) / 1000
                if tap.text.first?.isLetter == true, (tap.text != tap.text.lowercased()) != engine.isUppercase {
                    now = max(now + 0.001, time - 0.05)
                    press(.shift)
                }
                now = max(now + 0.001, time)
                press(CGPoint(x: x, y: y))
            case .delete(let count):
                for _ in 0..<count {
                    now += 0.001
                    press(.delete)
                }
            }
        }
        let literal = typed()
        now += 0.2
        switch prepared.plan.end {
        case .none:
            return .success(ReplayedWord(literal: literal, committed: literal))
        case .separator(let separator):
            await engine.waitForSuggestions()
            press(separator == "\n" ? .returnKey : .space)
        case .pick(let to, let chip):
            // The first acceptance may only sync the session's learning and republish the strip.
            for _ in 0..<2 where typed() == literal {
                await engine.waitForSuggestions()
                guard let suggestion = engine.suggestions.first(where: {
                    $0.replacement == to && Self.chipName($0.kind) == chip
                }) else { return .failure(.pickNotOffered) }
                engine.acceptSuggestion(suggestion)
            }
            guard typed() != literal else { return .failure(.pickNotOffered) }
        }
        var committed = typed()
        if committed.last?.isWhitespace == true { committed.removeLast() }
        return .success(ReplayedWord(literal: literal, committed: committed))
    }

    private static func chipName(_ kind: KeyboardSuggestion.Kind) -> String {
        switch kind {
        case .keepLiteral: "keep"
        case .primary: "primary"
        case .secondary: "secondary"
        }
    }
}

struct ReplayError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
