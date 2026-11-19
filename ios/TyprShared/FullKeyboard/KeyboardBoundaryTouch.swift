import Foundation

/// One fully observed word, or two words separated by one real Space tap. RAM-only,
/// not Codable. Ownership/revert ideas translated from iikb TypingEngine+Words.swift
/// at 09a2e9cdfbe851adff6c4646333c0a3f74ba8765 (MIT, © 2026 Bassim Shahidy).
nonisolated struct KeyboardBoundaryTouch: Equatable, Sendable {
    let current: KeyboardTouchWord
    var previous: KeyboardTouchWord? = nil
    var space: KeyboardTouchWord.Sample? = nil

    static let maxSamples = 32
    /// Layout keys/strings plus sample payload, excluding allocator overhead and shared
    /// resource mappings. Layout is a value snapshot, not an unbounded geometry history.
    static let maximumPayloadBytes = 32_768

    var payloadBytes: Int {
        func wordBytes(_ word: KeyboardTouchWord) -> Int {
            let keyBytes = word.layout.keys.reduce(0) { sum, key in
                sum + MemoryLayout<KeyboardKey>.stride + key.label.utf8.count + (key.character?.utf8.count ?? 0)
            }
            let sampleBytes = word.samples.reduce(0) { sum, sample in
                sum + MemoryLayout<KeyboardTouchWord.Sample>.stride + sample.text.utf8.count
                    + sample.key.label.utf8.count + (sample.key.character?.utf8.count ?? 0)
            }
            return MemoryLayout<KeyboardTouchWord>.stride + keyBytes + sampleBytes
        }
        return MemoryLayout<Self>.stride + wordBytes(current) + (previous.map(wordBytes) ?? 0)
            + (space == nil ? 0 : MemoryLayout<KeyboardTouchWord.Sample>.stride + 8)
    }

    var original: String {
        previous.map { $0.text + " " + current.text } ?? current.text
    }

    var isUsable: Bool {
        let count = current.samples.count + (previous?.samples.count ?? 0) + (space == nil ? 0 : 1)
        func valid(_ word: KeyboardTouchWord) -> Bool {
            word.learningIntact && !word.samples.isEmpty && word.samples.allSatisfy { sample in
                sample.text.count == 1 && sample.text.first?.isLetter == true
                    && sample.point.x.isFinite && sample.point.y.isFinite
                    && sample.key == word.layout.key(sample.key.kind)
                    && sample.key.character?.lowercased() == sample.text.lowercased()
            }
        }
        guard (1...Self.maxSamples).contains(count), payloadBytes <= Self.maximumPayloadBytes,
              current.layout.layer == .letters, current.layout.field == .text, valid(current) else { return false }
        if let previous {
            guard previous.layout == current.layout, valid(previous),
                  let space, space.key == current.layout.key(.space), space.text == " ",
                  space.point.x.isFinite, space.point.y.isFinite else { return false }
        } else if space != nil { return false }
        return true
    }

    /// Only bottom-row letters whose horizontal span actually meets this layout's Space.
    /// Geometry is checked before density: a broad prior can never license a distant key.
    static func adjacentLetters(in layout: KeyboardLayout) -> [KeyboardKey] {
        guard let space = layout.key(.space) else { return [] }
        return ["c", "v", "b", "n", "m"].compactMap { letter in
            guard let key = layout.key(.character(letter)),
                  key.frame.maxX >= space.frame.minX, key.frame.minX <= space.frame.maxX,
                  abs(space.frame.minY - key.frame.maxY) <= layout.metrics.rowGap + 1 else { return nil }
            return key
        }
    }

    static func spaceDensity(_ point: CGPoint, layout: KeyboardLayout,
                             calibration: SpatialTouchCalibration? = nil) -> Double? {
        guard point.x.isFinite, point.y.isFinite, let space = layout.key(.space) else { return nil }
        let pitchX = layout.letterWidth + layout.metrics.gap
        let pitchY = space.frame.height + layout.metrics.rowGap
        guard pitchX > 0, pitchY > 0,
              point.x >= space.frame.minX - layout.metrics.gap,
              point.x <= space.frame.maxX + layout.metrics.gap else { return nil }
        let row = Double((point.y - space.frame.midY) / pitchY)
        guard abs(row) <= 1 else { return nil }
        let aim = calibration?.space ?? SpatialTouchCalibration.prior
        let width = Double((space.frame.width + 2 * layout.metrics.gap) / pitchX)
        return aim.logDensityY(row) - log(width)
    }

    static func letterDensity(_ point: CGPoint, key: KeyboardKey, layout: KeyboardLayout,
                              calibration: SpatialTouchCalibration?) -> Double? {
        guard point.x.isFinite, point.y.isFinite, let letter = key.character?.first else { return nil }
        let x = Double((point.x - key.frame.midX) / (key.frame.width + layout.metrics.gap))
        let y = Double((point.y - key.frame.midY) / (key.frame.height + layout.metrics.rowGap))
        guard x.isFinite, y.isFinite, abs(x) <= 1, abs(y) <= 1 else { return nil }
        return (calibration?.keys[letter] ?? SpatialTouchCalibration.prior).logDensity(x: x, y: y)
    }
}
