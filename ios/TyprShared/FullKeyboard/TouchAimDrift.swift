import Foundation

/// RAM-only, aggregate-only shared aim drift for ONE active layout.
///
/// A grip or posture change moves every key's aim by an amount that varies smoothly with
/// position (a thumb undershoots far keys more than near ones; a tilt rotates the plane).
/// Rare keys get almost no labels in the first 10-30 taps, so the drift is one shared
/// affine field over normalized key positions, `drift(u, v) = W · [1, u, v]` in pitches,
/// measured as the residual from the slow (persisted) per-key model.
///
/// Three memories compete prequentially, as iikb's all/lately/now aim memories do
/// (TouchModel.swift KeyTouches/Drift, 09a2e9cdfbe851adff6c4646333c0a3f74ba8765,
/// MIT © 2026 Bassim Shahidy): `stable` (no drift: the slow model alone), `medium` and
/// `fast` exponentially forgetting ridge regressions. Each memory is scored on a label
/// BEFORE it learns from it; a fixed share lets any memory take over again, so returning
/// to the original grip recovers within a few labels. Typr's shared affine field replaces
/// iikb's per-key memories. No points are stored: 2 × 12 sufficient sums plus three weights
/// (SIMD padding and fixed decay lengths are included in the byte-bound tests).
nonisolated struct TouchAimDrift: Equatable, Sendable {
    nonisolated struct Memory: Equatable, Sendable {
        let length: Double
        /// Upper triangle of Σ φφᵀ (00, 01, 02, 11, 12, 22), then two unused lanes.
        private(set) var gram = SIMD8<Double>(repeating: 0)
        /// Σ φ·rx and Σ φ·ry.
        private(set) var crossX = SIMD3<Double>(repeating: 0)
        private(set) var crossY = SIMD3<Double>(repeating: 0)

        init(length: Double) { self.length = length }

        /// Ridge solution `(Σφφᵀ + Λ)⁻¹ Σφr`, shrinking toward NO drift. Λ is in label units.
        var coefficients: (x: SIMD3<Double>, y: SIMD3<Double>) {
            let l = TouchAimDrift.ridge
            // Cholesky of the 3×3 SPD matrix; Λ > 0 guarantees positive pivots.
            let a00 = gram[0] + l[0], a01 = gram[1], a02 = gram[2]
            let a11 = gram[3] + l[1], a12 = gram[4], a22 = gram[5] + l[2]
            let c00 = sqrt(a00), c10 = a01 / c00, c20 = a02 / c00
            let c11 = sqrt(max(1e-12, a11 - c10 * c10)), c21 = (a12 - c20 * c10) / c11
            let c22 = sqrt(max(1e-12, a22 - c20 * c20 - c21 * c21))
            func solve(_ b: SIMD3<Double>) -> SIMD3<Double> {
                let y0 = b[0] / c00, y1 = (b[1] - c10 * y0) / c11, y2 = (b[2] - c20 * y0 - c21 * y1) / c22
                let x2 = y2 / c22, x1 = (y1 - c21 * x2) / c11, x0 = (y0 - c10 * x1 - c20 * x2) / c00
                return SIMD3(x0, x1, x2)
            }
            return (solve(crossX), solve(crossY))
        }

        mutating func update(features φ: SIMD3<Double>, residualX: Double, residualY: Double) {
            let keep = 1 - 1 / length
            gram = keep * gram + SIMD8(φ[0] * φ[0], φ[0] * φ[1], φ[0] * φ[2], φ[1] * φ[1],
                                       φ[1] * φ[2], φ[2] * φ[2], 0, 0)
            crossX = keep * crossX + residualX * φ
            crossY = keep * crossY + residualY * φ
        }
    }

    /// Ridge pseudo-labels toward NO drift: intercept, then each position slope.
    static let ridge = SIMD3<Double>(1, 2, 2)
    /// Fixed share: every memory keeps at least share/3 weight and can take over again.
    static let share = 0.02
    static let mediumLength = 40.0
    static let fastLength = 8.0

    private(set) var medium = Memory(length: TouchAimDrift.mediumLength)
    private(set) var fast = Memory(length: TouchAimDrift.fastLength)
    /// stable, medium, fast.
    private(set) var weights = SIMD3<Double>(1 - 2 * share / 3, share / 3, share / 3)

    /// Normalized key-centre positions in the letter plane, each component in [-1, 1].
    static func features(for layout: KeyboardLayout) -> [Character: SIMD3<Double>] {
        let letters = layout.keys.filter { key in
            guard let text = key.character, text.count == 1, let c = text.first else { return false }
            return ("a"..."z").contains(c)
        }
        guard let first = letters.first else { return [:] }
        let plane = letters.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        guard plane.width > 0, plane.height > 0 else { return [:] }
        var result: [Character: SIMD3<Double>] = [:]
        for key in letters {
            guard let c = key.character?.first else { continue }
            let u = Double((key.frame.midX - plane.midX) / (plane.width / 2))
            let v = Double((key.frame.midY - plane.midY) / (plane.height / 2))
            guard u.isFinite, v.isFinite else { continue }
            result[c] = SIMD3(1, max(-1, min(1, u)), max(-1, min(1, v)))
        }
        return result
    }

    /// Drift predicted by stable, medium and fast at one key position.
    private func offsets(_ φ: SIMD3<Double>) -> [(x: Double, y: Double)] {
        let m = medium.coefficients, f = fast.coefficients
        return [(0, 0), ((m.x * φ).sum(), (m.y * φ).sum()), ((f.x * φ).sum(), (f.y * φ).sum())]
    }

    /// One trusted label at pitch position (x, y) for a key whose slow physical density is `slow`.
    mutating func update(x: Double, y: Double, slow: SpatialTouchCalibration.Key, features φ: SIMD3<Double>) {
        guard x.isFinite, y.isFinite, φ[0] == 1,
              φ[1].isFinite, φ[2].isFinite, abs(φ[1]) <= 1, abs(φ[2]) <= 1 else { return }
        // Score BEFORE learning, in log space, then mix in the fixed share. All memories share
        // the slow width, so they compete on their predicted centres only.
        let scores = offsets(φ).map { -0.5 * slow.mahalanobis(x: x - $0.x, y: y - $0.y) }
        let best = scores.max() ?? 0
        var odds = weights
        for i in 0..<3 { odds[i] *= exp(scores[i] - best) }
        let total = odds.sum()
        if total.isFinite, total > 0 {
            weights = (1 - Self.share) * odds / total + SIMD3<Double>(repeating: Self.share / 3)
        }
        medium.update(features: φ, residualX: x - slow.offsetX, residualY: y - slow.offsetY)
        fast.update(features: φ, residualX: x - slow.offsetX, residualY: y - slow.offsetY)
    }

    /// Moment-matched predictive density for one key: weighted centre, slow covariance plus
    /// the between-memory scatter, so disagreeing memories broaden rather than over-assert.
    func prediction(slow: SpatialTouchCalibration.Key, features φ: SIMD3<Double>) -> SpatialTouchCalibration.Key {
        let parts = offsets(φ)
        var x = 0.0, y = 0.0
        for i in 0..<3 { x += weights[i] * parts[i].x; y += weights[i] * parts[i].y }
        var xx = slow.sigmaX * slow.sigmaX, yy = slow.sigmaY * slow.sigmaY, xy = slow.covarianceXY
        for i in 0..<3 {
            let dx = parts[i].x - x, dy = parts[i].y - y
            xx += weights[i] * dx * dx; yy += weights[i] * dy * dy; xy += weights[i] * dx * dy
        }
        return .init(offsetX: slow.offsetX + x, offsetY: slow.offsetY + y,
                     sigmaX: sqrt(xx), sigmaY: sqrt(yy), covarianceXY: xy, degrees: slow.degrees)
    }
}
