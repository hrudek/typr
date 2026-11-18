import CoreGraphics

/// Ephemeral evidence for one completely observed word. Coordinates use the captured layout's
/// keyboard-view space (including the strip). Not Codable: never persisted, logged or exported.
nonisolated struct KeyboardTouchWord: Equatable, Sendable {
    struct Sample: Equatable, Sendable {
        let text: String
        let point: CGPoint
        /// Original geometric hit; never silently relabeled by the attribution map.
        let key: KeyboardKey
        var attributedKey: KeyboardKey? = nil
    }

    let layout: KeyboardLayout
    var samples: [Sample]
    var learningIntact = true
    var retyped: [Int: TouchLabel] = [:]
    var text: String { samples.map(\.text).joined() }
}

/// Keeps only a bounded, contiguous word whose characters all came from unambiguous key taps.
/// Missing context, a partial word or an edit we cannot align means spelling-only fallback.
@MainActor
final class KeyboardTouchInput {
    static let maxSamples = 64
    private var word: KeyboardTouchWord?
    private var previous: KeyboardTouchWord?
    private var space: KeyboardTouchWord.Sample?
    // Survives loss of all samples, so delete-all/retype cannot regain learning trust.
    private var editedWord = false
    private var erased: [Int: KeyboardTouchWord.Sample] = [:]
    private var erasedLayout: KeyboardLayout?
    var isLearningIntact: Bool { !editedWord }
    // One RAM-only bit, independent of complete tap evidence (also covers partial words).
    // Backspacing is explicit disagreement: the rest of this word must stay geometric.
    private(set) var attributionSuppressed = false

    func clear() { word = nil; previous = nil; space = nil; editedWord = false; forgetErased() }

    private func forgetErased() { erased = [:]; erasedLayout = nil }

    /// iikb KeyGrid.reaches (73c2ed9016b802e5bf017a2d595d037d1e748ccf, MIT © 2026 Bassim Shahidy).
    static func reaches(_ point: CGPoint, letter: String, in layout: KeyboardLayout) -> Bool {
        guard let key = layout.key(.character(letter)) else { return false }
        let cell = key.frame.insetBy(dx: -layout.metrics.gap / 2, dy: -layout.metrics.rowGap / 2)
        let dx = max(cell.minX - point.x, 0, point.x - cell.maxX)
        let dy = max(cell.minY - point.y, 0, point.y - cell.maxY)
        return dx <= cell.width / 4 && dy <= cell.height / 4
    }

    func boundaryEvidence(beforeInput: String?) -> KeyboardBoundaryTouch? {
        guard let current = evidence(beforeInput: beforeInput) else { return nil }
        var touch = KeyboardBoundaryTouch(current: current, previous: previous, space: space)
        if !touch.isUsable || beforeInput?.hasSuffix(touch.original) != true {
            previous = nil; space = nil
            touch = KeyboardBoundaryTouch(current: current)
        }
        return touch.isUsable ? touch : nil
    }

    func clearAtBoundary() {
        clear()
        resetAttributionSuppression()
    }

    func resetAttributionSuppression() { attributionSuppressed = false }

    func evidence(beforeInput: String?) -> KeyboardTouchWord? {
        guard let word else {
            if let previous, beforeInput?.hasSuffix(previous.text + " ") != true {
                self.previous = nil; space = nil
            }
            return nil
        }
        guard AutocorrectEngine.currentToken(in: beforeInput) == word.text else {
            self.word = nil
            previous = nil; space = nil
            return nil
        }
        return word
    }

    func append(text: String, point: CGPoint, key: KeyboardKey, layout: KeyboardLayout,
                before: String?, after: String?, attributedKey: KeyboardKey? = nil) {
        if text == " " {
            let completed = evidence(beforeInput: before)
            clearAtBoundary() // A second space never carries a window forward.
            if let before, after == before + " ", let completed, completed.learningIntact,
               completed.layout == layout, completed.samples.count < KeyboardBoundaryTouch.maxSamples,
               key.kind == .space, point.x.isFinite, point.y.isFinite {
                previous = completed
                space = .init(text: " ", point: point, key: key)
            }
            return
        }
        if attributedKey != nil {
            // Disqualify even a partially observed word: a later keep must not count our guess.
            editedWord = true
            word?.learningIntact = false
            previous = nil; space = nil
        }
        guard before != nil, text.count == 1, text.first?.isLetter == true,
              point.x.isFinite, point.y.isFinite, layout.layer == .letters,
              layout.field == .text, (attributedKey ?? key).character?.lowercased() == text.lowercased(),
              AutocorrectEngine.currentToken(in: after) == (AutocorrectEngine.currentToken(in: before) ?? "") + text else {
            word = nil; previous = nil; space = nil; forgetErased()
            return
        }
        if let token = AutocorrectEngine.currentToken(in: before) {
            guard let current = evidence(beforeInput: before), current.text == token,
                  current.layout == layout, current.samples.count < Self.maxSamples else {
                word = nil; previous = nil; space = nil; forgetErased()
                return
            }
        } else {
            if let previous, before?.hasSuffix(previous.text + " ") != true || previous.layout != layout {
                self.previous = nil; space = nil
            }
            word = KeyboardTouchWord(layout: layout, samples: [], learningIntact: !editedWord)
        }
        let position = word?.samples.count ?? 0
        let letter = text.lowercased()
        if let tap = erased.removeValue(forKey: position), erasedLayout == layout,
           tap.text.lowercased() != letter, let character = letter.first,
           Self.reaches(tap.point, letter: letter, in: layout) {
            word?.retyped[position] = TouchLabel(point: tap.point, letter: character)
        }
        word?.samples.append(.init(text: text, point: point, key: key, attributedKey: attributedKey))
        if (previous?.samples.count ?? 0) + (word?.samples.count ?? 0) + 1 > KeyboardBoundaryTouch.maxSamples {
            previous = nil; space = nil
        }
    }

    func deletedBackward(before: String?, after: String?) {
        attributionSuppressed = true
        let evidence = evidence(beforeInput: before)
        editedWord = true
        previous = nil; space = nil
        guard var current = evidence else { forgetErased(); return }
        current.learningIntact = false
        let position = current.samples.count - 1
        erased[position] = current.samples.removeLast()
        erasedLayout = current.layout
        current.retyped[position] = nil
        let token = AutocorrectEngine.currentToken(in: after)
        guard !current.samples.isEmpty, token == current.text else {
            word = nil
            if !(current.samples.isEmpty && token == nil) { forgetErased() }
            return
        }
        word = current
    }
}
