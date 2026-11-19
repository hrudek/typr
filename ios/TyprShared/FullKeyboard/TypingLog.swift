import CoreGraphics
import Foundation

/// One settled word of the on-device typing log (JSON Lines on disk, `words` in the export).
///
/// Export file (`TypingLogExport`), format `typr-typing-log`, version 1:
/// `{ "format", "version", "exportedAt" (ISO 8601), "appBuild",
///    "touchModel": PersonalTypingModel.State with only `layouts` (touch calibration),
///    "words": [TypingLogWord], oldest first }`
///
/// Word fields:
/// - `at`: when its first tap (or swipe) happened.
/// - `end`: the separator that ended it (" ", ".", ",", "?", "!", "\n" or another character), or
///   `field`, `external` (host text or cursor change), `cursor` (space-bar trackpad), `dismiss`,
///   `swipe` or `prediction` when the user moved on otherwise.
/// - `languages`: enabled word languages ("de", "en"); `hitAreas`: the hit-area setting.
/// - `layout`: the `KeyboardLayout` its tap points belong to.
/// - `taps`: the taps standing in the word, in order; `literal`: their inserted text.
/// - `commit`: what the keyboard did at the word's first boundary.
/// - `corrections`: in order; `meant`: the word as it stood when the user moved on.
/// - `swipe`: true for a swiped word, which keeps no taps or layout.
///
/// Optional fields are absent when empty: `touchModel` without saved learning, `layout` without a
/// tap point, `commit` for a word that never reached a boundary, `x`/`y` of an ambiguous tap.
nonisolated struct TypingLogWord: Codable, Equatable, Sendable {
    var at: Date
    var end = ""
    var languages: [String]
    var hitAreas: String
    var layout: TypingLogLayout?
    var taps: [TypingLogTap] = []
    var literal = ""
    var commit: Commit?
    var corrections: [Correction] = []
    var meant = ""
    var swipe: Bool?

    nonisolated struct Commit: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case literal, autocorrect, pick, boundaryPick, swipe }
        enum CorrectionKind: String, Codable, Sendable { case spatial, spelling, rule }
        var kind: Kind
        var text: String
        /// Only for `autocorrect`: which decision replaced the literal.
        var correction: CorrectionKind?
    }

    /// `backspace` (with the `erased` taps, oldest first), `undo` of the automatic change
    /// (`from` → `to`), a strip `pick` (`chip`: keep, primary, secondary or swipe) or `reopen`
    /// (the separator was deleted and the word edited again).
    nonisolated struct Correction: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case backspace, undo, pick, reopen }
        var kind: Kind
        var erased: [TypingLogTap]?
        var from: String?
        var to: String?
        var chip: String?
    }
}

/// `t`: milliseconds since the word's first tap. `x`/`y`: keyboard-view points of `layout`,
/// suggestion strip included; absent for slid, rolled-across-layout, accent or hold-123 input.
/// `key`: the geometric key under the point; `text`: what went into the field.
nonisolated struct TypingLogTap: Codable, Equatable, Sendable {
    var t: Int
    var x: Double?
    var y: Double?
    var key: String?
    var text: String
}

/// The `KeyboardLayout` initializer's arguments, plus its metrics to detect geometry drift on replay.
nonisolated struct TypingLogLayout: Codable, Equatable, Sendable {
    var width: Double
    var orientation: String
    var layer: String
    var field: String
    var showsGlobe: Bool
    var globeKey: String
    var bottomRow: [String]
    var periodKey: Bool
    var numberRow: Bool
    var horizontalInset: Double
    var showsStrip: Bool
    var metrics: Metrics

    nonisolated struct Metrics: Codable, Equatable, Sendable {
        var side, gap, rowGap, keyHeight, numberRowHeight: Double
        var stripTop, stripHeight, stripBottom, keysTop, keysBottom: Double
    }

    init(_ layout: KeyboardLayout) {
        width = layout.width
        orientation = layout.orientation == .portrait ? "portrait" : "landscape"
        layer = switch layout.layer { case .letters: "letters"; case .numbers: "numbers"; case .symbols: "symbols" }
        field = switch layout.field { case .text: "text"; case .url: "url"; case .email: "email" }
        showsGlobe = layout.showsGlobe
        globeKey = layout.globeKey.rawValue
        bottomRow = layout.bottomRow.order.map(\.rawValue)
        periodKey = layout.bottomRow.periodKey
        numberRow = layout.numberRow
        horizontalInset = layout.horizontalInset
        showsStrip = layout.showsStrip
        let m = layout.metrics
        metrics = Metrics(side: m.side, gap: m.gap, rowGap: m.rowGap, keyHeight: m.keyHeight,
                          numberRowHeight: m.numberRowHeight, stripTop: m.stripTop, stripHeight: m.stripHeight,
                          stripBottom: m.stripBottom, keysTop: m.keysTop, keysBottom: m.keysBottom)
    }

    /// The layout these taps were made on; nil for values this build does not know.
    var keyboardLayout: KeyboardLayout? {
        let orientation: KeyboardOrientation? = switch orientation {
        case "portrait": .portrait
        case "landscape": .landscape
        default: nil
        }
        let layer: KeyboardLayer? = switch layer {
        case "letters": .letters
        case "numbers": .numbers
        case "symbols": .symbols
        default: nil
        }
        let field: KeyboardFieldKind? = switch field {
        case "text": .text
        case "url": .url
        case "email": .email
        default: nil
        }
        let order = bottomRow.compactMap(BottomKey.init(rawValue:))
        guard let orientation, let layer, let field, let globeKey = GlobeKey(rawValue: globeKey),
              order.count == bottomRow.count else { return nil }
        return KeyboardLayout(width: width, orientation: orientation, layer: layer, field: field,
                              showsGlobe: showsGlobe, globeKey: globeKey,
                              bottomRow: BottomRow(order: order, periodKey: periodKey),
                              numberRow: numberRow, horizontalInset: horizontalInset, showsStrip: showsStrip)
    }
}

nonisolated struct TypingLogExport: Codable, Sendable {
    static let format = "typr-typing-log"
    static let version = 1
    var format = Self.format
    var version = Self.version
    var exportedAt: Date
    var appBuild: String
    var touchModel: PersonalTypingModel.State?
    var words: [TypingLogWord]

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Turns the engine's edits into settled words. A word stays undoable after its separator until
/// the user moves on (next word, another separator, field or cursor change, dismissal).
/// The engine calls it only where personal learning may record; `discard()` drops everything.
@MainActor
final class TypingLogRecorder {
    /// Words beyond these bounds are dropped, which keeps every record a few kilobytes.
    static let maxTaps = 64
    static let maxCorrections = 32

    var languages: [String] = []
    var hitAreas = "standard"
    private let write: (TypingLogWord) -> Void
    private let now: () -> Date
    private var open: Draft?
    private var settled: Draft?

    private struct Draft {
        var word: TypingLogWord
        var text: String
        var started: TimeInterval
        var backspacing = false
        var tapsMatchText: Bool { word.literal == text }
        var isBounded: Bool {
            word.taps.count <= TypingLogRecorder.maxTaps
                && word.corrections.count <= TypingLogRecorder.maxCorrections
                && word.corrections.reduce(0) { $0 + ($1.erased?.count ?? 0) } <= TypingLogRecorder.maxTaps
        }

        mutating func append(_ text: String, point: CGPoint?, key: String?, layout: KeyboardLayout, time: TimeInterval) {
            if point != nil, word.layout == nil { word.layout = TypingLogLayout(layout) }
            let onLayout = point != nil && word.layout == TypingLogLayout(layout)
            word.taps.append(TypingLogTap(t: Int(((time - started) * 1000).rounded()),
                                          x: onLayout ? point.map { (Double($0.x) * 100).rounded() / 100 } : nil,
                                          y: onLayout ? point.map { (Double($0.y) * 100).rounded() / 100 } : nil,
                                          key: key, text: text))
            word.literal += text
            self.text += text
        }

        mutating func commit(_ commit: TypingLogWord.Commit) {
            if word.commit == nil { word.commit = commit }
        }
    }

    init(write: @escaping (TypingLogWord) -> Void, now: @escaping () -> Date = Date.init) {
        self.write = write
        self.now = now
    }

    /// A character went in. `token`: the current word in the field afterwards.
    func typed(_ text: String, point: CGPoint?, key: String?, layout: KeyboardLayout,
               time: TimeInterval, token: String?) {
        if var draft = open, token == draft.text + text
            || (token == nil && Self.isApostrophe(text) && draft.text.last?.isLetter == true) {
            draft.append(text, point: point, key: key, layout: layout, time: time)
            draft.backspacing = false
            open = draft.isBounded ? draft : nil
            return
        }
        settle()
        finish(open, end: text)
        open = nil
        guard token == text else { return }
        var draft = Draft(word: TypingLogWord(at: now(), languages: languages, hitAreas: hitAreas), text: "", started: time)
        draft.append(text, point: point, key: key, layout: layout, time: time)
        open = draft
    }

    /// A separator went in after the word, possibly with an automatic replacement.
    func boundary(_ separator: String, replacement: String? = nil,
                  correction: TypingLogWord.Commit.CorrectionKind? = nil) {
        guard var draft = open, !draft.text.isEmpty else {
            settle()
            open = nil
            return
        }
        open = nil
        if let replacement {
            draft.commit(.init(kind: .autocorrect, text: replacement, correction: correction))
            draft.text = replacement
        } else {
            draft.commit(.init(kind: .literal, text: draft.text))
        }
        draft.word.end = separator
        settle()
        settled = draft
    }

    /// A strip choice replaced the word (`from`, a boundary chip's whole suffix) and added a space.
    func picked(from: String, to: String, chip: String, boundary: Bool) {
        settle()
        guard var draft = open else { return }
        open = nil
        draft.word.corrections.append(.init(kind: .pick, from: from, to: to, chip: chip))
        draft.commit(.init(kind: boundary ? .boundaryPick : .pick, text: to))
        draft.text = to
        draft.word.end = " "
        settled = draft.isBounded ? draft : nil
    }

    /// One character was deleted. `token`: the current word in the field afterwards.
    func deleted(token: String?) {
        if var draft = open {
            open = nil
            guard (token ?? "") == String(draft.text.dropLast()), !draft.text.isEmpty else { return }
            var erased: [TypingLogTap] = []
            if draft.tapsMatchText, let tap = draft.word.taps.popLast() {
                erased.append(tap)
                draft.word.literal = String(draft.word.literal.dropLast(tap.text.count))
            }
            if draft.backspacing, var last = draft.word.corrections.popLast() {
                last.erased = erased + (last.erased ?? [])
                draft.word.corrections.append(last)
            } else {
                draft.word.corrections.append(.init(kind: .backspace, erased: erased))
            }
            draft.backspacing = true
            draft.text = token ?? ""
            open = draft.isBounded ? draft : nil
            return
        }
        guard var draft = settled else { return }
        settled = nil
        guard let token, draft.text.hasSuffix(token) else { return }
        draft.word.corrections.append(.init(kind: .reopen))
        draft.word.end = ""
        draft.text = token
        open = draft.isBounded ? draft : nil
    }

    /// Backspace restored `original` in place of the word's automatic change.
    func undone(original: String, token: String?) {
        guard var draft = settled, let token, original.hasSuffix(token) else { discard(); return }
        settled = nil
        draft.word.corrections.append(.init(kind: .undo, from: draft.text, to: original))
        draft.word.end = ""
        draft.text = token
        open = draft.isBounded ? draft : nil
    }

    func swiped(_ word: String, time: TimeInterval) {
        settle()
        finish(open, end: "swipe")
        var draft = Draft(word: TypingLogWord(at: now(), languages: languages, hitAreas: hitAreas, swipe: true),
                          text: word, started: time)
        draft.commit(.init(kind: .swipe, text: word))
        open = draft
    }

    func swipeReplaced(with word: String) {
        guard var draft = open, draft.word.swipe == true else { return }
        draft.word.corrections.append(.init(kind: .pick, from: draft.text, to: word, chip: "swipe"))
        draft.text = word
        open = draft.isBounded ? draft : nil
    }

    /// The open word was removed as a whole (swipe delete).
    func dropOpenWord() { open = nil }

    /// The user moved on without a separator.
    func end(_ reason: String) {
        settle()
        finish(open, end: reason)
        open = nil
    }

    func discard() {
        open = nil
        settled = nil
    }

    private func settle() {
        finish(settled, end: nil)
        settled = nil
    }

    private func finish(_ draft: Draft?, end: String?) {
        guard var word = draft?.word, let text = draft?.text, !text.isEmpty else { return }
        if let end, word.end.isEmpty { word.end = end }
        word.meant = String(text.reversed().drop(while: { Self.isApostrophe(String($0)) }).reversed())
        write(word)
    }

    private static func isApostrophe(_ text: String) -> Bool { text == "'" || text == "’" }
}
