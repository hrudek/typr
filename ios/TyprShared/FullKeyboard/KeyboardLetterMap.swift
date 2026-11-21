import Foundation
import CoreGraphics

/// Physical holders, not popup positions. Translated from iikb Correction/LetterKeys.swift,
/// 09a2e9cdfbe851adff6c4646333c0a3f74ba8765 (MIT, © 2026 Bassim Shahidy).
/// The corpus alphabet stays Unicode; several letters share ONE key's touch density.
nonisolated enum KeyboardLetterMap {
    static func holder(of letter: Character) -> Character {
        switch letter {
        case "ä": "a"
        case "ö": "o"
        case "ü": "u"
        case "ß": "s"
        default: letter
        }
    }

    struct Emissions {
        let likelihoods: [[Double]]
        let best: [Double]
        let literal: Double
        /// Per tap: finite labels by descending density (ties by label), plus their bit mask.
        /// Empty on the legacy same-run baseline path, which never reads them.
        let rankedLabels: [[Int]]
        let finiteLabelMasks: [UInt32]
    }

    struct FrozenKey {
        let frame: CGRect
        let pitchX: Double, pitchY: Double
        let offsetX: Double, offsetY: Double
        let inverseXX: Double, inverseXY: Double, inverseYY: Double, normalizer: Double
        let degrees: Double

        init(frame: CGRect, gap: CGFloat, rowGap: CGFloat, key: SpatialTouchCalibration.Key) {
            self.frame = frame
            pitchX = Double(frame.width + gap); pitchY = Double(frame.height + rowGap)
            offsetX = key.offsetX; offsetY = key.offsetY
            let xx = key.sigmaX * key.sigmaX, yy = key.sigmaY * key.sigmaY, xy = key.covarianceXY
            let determinant = xx * yy - xy * xy
            inverseXX = yy / determinant; inverseXY = -xy / determinant; inverseYY = xx / determinant
            normalizer = -log(2 * Double.pi) - 0.5 * log(determinant)
            degrees = key.degrees
        }

        func score(_ point: CGPoint) -> Double {
            let dx = Double(point.x - frame.midX) / pitchX - offsetX
            let dy = Double(point.y - frame.midY) / pitchY - offsetY
            let distance = max(0, inverseXX * dx * dx + 2 * inverseXY * dx * dy + inverseYY * dy * dy)
            return normalizer - (degrees / 2 + 1) * log1p(distance / degrees)
        }
    }

    /// Same normalized density for correction and noisy-prefix retrieval, over every letter key. Calibration
    /// belongs to the physical key. This does not turn popup gestures into observed taps or labels.
    /// `prepared` selects the frozen per-key scorer; `false` keeps the original per-pair
    /// expression only for same-run legacy baselines.
    static func emissions(for word: KeyboardTouchWord, calibration: SpatialTouchCalibration?,
                          prepared: Bool = true) -> Emissions? {
        guard word.layout.layer == .letters, word.layout.field == .text,
              !word.samples.isEmpty, word.samples.count <= 32 else { return nil }
        let alphabet = SpatialWordLexicon.alphabet
        let holders = alphabet.map { holder(of: $0) }
        let frames = holders.map { holder in word.layout.keys.filter { $0.kind == .character(String(holder)) }.map(\.frame) }
        let keys = holders.map { calibration?.keys[$0] ?? SpatialTouchCalibration.prior }
        let gap = word.layout.metrics.gap, rowGap = word.layout.metrics.rowGap
        var frozen = [[FrozenKey]](repeating: [], count: alphabet.count)
        for index in alphabet.indices {
            for frame in frames[index] {
                let width = Double(frame.width + gap), height = Double(frame.height + rowGap)
                guard frame.width > 0, frame.height > 0, width.isFinite, height.isFinite,
                      width > 0, height > 0 else { return nil }
                if prepared { frozen[index].append(FrozenKey(frame: frame, gap: gap, rowGap: rowGap, key: keys[index])) }
            }
        }
        var likelihoods: [[Double]] = []
        var bestScores: [Double] = []
        var literalSpatial = 0.0
        for sample in word.samples {
            guard sample.text.count == 1, sample.text.lowercased().count == 1,
                  word.layout.keys.contains(sample.key),
                  (sample.attributedKey ?? sample.key).character?.lowercased() == sample.text.lowercased(),
                  sample.attributedKey.map(word.layout.keys.contains) ?? true,
                  sample.point.x.isFinite, sample.point.y.isFinite,
                  let letter = sample.text.lowercased().first,
                  let label = alphabet.firstIndex(of: letter),
                  word.layout.key(.character(String(letter))) != nil else { return nil }
            var scores = [Double](repeating: -.infinity, count: alphabet.count)
            for index in alphabet.indices {
                if prepared {
                    scores[index] = frozen[index].map { $0.score(sample.point) }.max() ?? -.infinity
                    continue
                }
                let key = keys[index]
                // The entire density is frozen before search, preserving max-path bounds.
                scores[index] = frames[index].map { frame in
                    key.logDensity(x: Double(sample.point.x - frame.midX) / Double(frame.width + gap),
                                   y: Double(sample.point.y - frame.midY) / Double(frame.height + rowGap))
                }.max() ?? -.infinity
            }
            guard scores[label].isFinite, let best = scores.max(), best.isFinite else { return nil }
            literalSpatial += scores[label]
            bestScores.append(best)
            likelihoods.append(scores)
        }
        let rankedLabels: [[Int]] = prepared ? likelihoods.map { scores in
            scores.indices.filter { scores[$0].isFinite }.sorted {
                scores[$0] == scores[$1] ? $0 < $1 : scores[$0] > scores[$1]
            }
        } : []
        let finiteLabelMasks = rankedLabels.map { labels in
            labels.reduce(UInt32(0)) { $0 | (UInt32(1) << $1) }
        }
        return Emissions(likelihoods: likelihoods, best: bestScores, literal: literalSpatial,
                         rankedLabels: rankedLabels, finiteLabelMasks: finiteLabelMasks)
    }
}
