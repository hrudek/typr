import Foundation
import CoreGraphics

/// Presentation math only. No inferred labels, text, or reconstructed individual taps.
nonisolated struct TapStatistics {
    struct Key: Identifiable {
        let letter: String
        let samples: Int
        let center: CGPoint
        let xx: Double
        let xy: Double
        let yy: Double
        let drift: Double
        let onTarget: Double?
        let neighbors: [(letter: String, share: Double)]
        var id: String { letter }
    }
    let signature: KeyboardLayoutSignature
    let layout: KeyboardLayout
    let keys: [Key]
    let heat: UsageHeat?

    init(signature: KeyboardLayoutSignature, model: PersonalTypingModel.LayoutSummary?, heat: UsageHeat?) {
        self.signature = signature
        let board = Self.board(signature)
        layout = board
        self.heat = heat.flatMap { $0.isValid && $0.layout == signature ? $0 : nil }
        let summaries: [PersonalTypingModel.KeySummary] = model?.signature == signature ? model?.keys ?? [] : []
        keys = summaries.compactMap { Self.statistics(for: $0, on: board) }
    }

    private static func statistics(for summary: PersonalTypingModel.KeySummary, on board: KeyboardLayout) -> Key? {
        guard let key = board.key(.character(summary.letter)), summary.n > 0 else { return nil }
        let px = Double(key.frame.width + board.metrics.gap)
        let py = Double(key.frame.height + board.metrics.rowGap)
        let dx = summary.offsetX * px, dy = summary.offsetY * py
        let center = CGPoint(x: Double(key.frame.midX) + dx, y: Double(key.frame.midY) + dy)
        let xx = pow(summary.sigmaX * px, 2), yy = pow(summary.sigmaY * py, 2)
        let xy = summary.covarianceXY * px * py
        let shares = landing(center: center, xx: xx, xy: xy, yy: yy, layout: board)
        var neighbors: [(letter: String, share: Double)] = []
        let onTarget: Double?
        if summary.n >= 20 {
            onTarget = shares[summary.letter, default: 0]
            for (letter, share) in shares where letter != summary.letter {
                neighbors.append((letter: letter, share: share))
            }
            neighbors.sort { lhs, rhs in
                if lhs.share == rhs.share { return lhs.letter < rhs.letter }
                return lhs.share > rhs.share
            }
        } else {
            onTarget = nil
        }
        return Key(letter: summary.letter, samples: summary.n, center: center, xx: xx, xy: xy, yy: yy,
                   drift: hypot(dx, dy), onTarget: onTarget, neighbors: neighbors)
    }

    static func board(_ signature: KeyboardLayoutSignature) -> KeyboardLayout {
        KeyboardLayout(width: CGFloat(signature.widthBucket),
                       orientation: signature.orientation == "landscape" ? .landscape : .portrait,
                       showsGlobe: signature.showsGlobe, horizontalInset: 0, showsStrip: signature.showsStrip)
    }
    var effectiveSamples: Int { keys.reduce(0) { $0 + $1.samples } }
    var heatSamples: UInt64 { heat?.cells.reduce(0, +) ?? 0 }
    var onTarget: Double? { Self.weighted(keys) }
    var meanDrift: Double? {
        guard effectiveSamples > 0 else { return nil }
        return keys.reduce(0) { $0 + $1.drift * Double($1.samples) } / Double(effectiveSamples)
    }
    func half(left: Bool) -> Double? {
        Self.weighted(keys.filter { key in
            guard let frame = layout.key(.character(key.letter))?.frame else { return false }
            return (frame.midX < layout.width / 2) == left
        })
    }
    static func weighted(_ keys: [Key]) -> Double? {
        let eligible = keys.filter { $0.onTarget != nil }
        let n = eligible.reduce(0) { $0 + $1.samples }
        guard n > 0 else { return nil }
        return eligible.reduce(0) { $0 + ($1.onTarget ?? 0) * Double($1.samples) } / Double(n)
    }
    static func percent(_ value: Double?) -> String {
        value.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
    }
    var commonDeviations: [(from: String, to: String, share: Double)] {
        var deviations: [(from: String, to: String, share: Double)] = []
        for key in keys {
            guard let neighbor = key.neighbors.first, neighbor.share >= 0.01 else { continue }
            deviations.append((from: key.letter, to: neighbor.letter, share: neighbor.share))
        }
        deviations.sort { lhs, rhs in
            if lhs.share == rhs.share { return lhs.from < rhs.from }
            return lhs.share > rhs.share
        }
        return Array(deviations.prefix(3))
    }

    // Gaussian lattice integration adapted from iikb Aim.swift (MIT); see notices.
    // Unlike upstream, off-board mass stays in the denominator. Hit regions include
    // modifiers: hitting delete/space or leaving the board is NOT an on-target letter.
    static func landing(center: CGPoint, xx: Double, xy: Double, yy: Double,
                        layout: KeyboardLayout) -> [String: Double] {
        guard center.x.isFinite, center.y.isFinite, xx.isFinite, xy.isFinite, yy.isFinite,
              xx > 0, yy > 0, xx * yy > xy * xy else { return [:] }
        let l11 = sqrt(xx), l21 = xy / l11, l22 = sqrt(max(0, yy - l21 * l21))
        var shares: [String: Double] = [:]
        var total = 0.0
        for i in -24...24 {
            let a = 3.5 * Double(i) / 24
            for j in -24...24 {
                let b = 3.5 * Double(j) / 24
                let weight = exp(-(a * a + b * b) / 2)
                total += weight
                let point = CGPoint(x: Double(center.x) + l11 * a, y: Double(center.y) + l21 * a + l22 * b)
                if let letter = layout.hitTest(point)?.character { shares[letter, default: 0] += weight }
            }
        }
        return shares.mapValues { $0 / total }
    }
}

extension KeyboardLayoutSignature {
    var statisticsTitle: String {
        "\(orientation.capitalized) · \(widthBucket) pt · \(showsStrip ? "suggestions" : "no suggestions") · \(showsGlobe ? "globe" : "no globe")"
    }
}
