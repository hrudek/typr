import Foundation
import CoreGraphics

/// Learning is isolated to one orientation, width bucket and accessory configuration.
nonisolated struct KeyboardLayoutSignature: Hashable, Codable, Sendable {
    let orientation: String
    let widthBucket: Int
    let showsStrip: Bool
    let showsGlobe: Bool

    init(_ layout: KeyboardLayout) {
        switch layout.orientation {
        case .portrait: orientation = "portrait"
        case .landscape: orientation = "landscape"
        }
        widthBucket = Int((layout.width / 8).rounded()) * 8
        showsStrip = layout.showsStrip
        showsGlobe = layout.showsGlobe
    }

    var id: String {
        "\(orientation)-\(widthBucket)-\(showsStrip ? "strip" : "no-strip")-\(showsGlobe ? "globe" : "no-globe")"
    }
}

// Normal-Inverse-Wishart touch posterior adapted from AVGVSTVS96/iikb
// Packages/KeyboardModules/Sources/KeyboardCore/Correction/TouchModel.swift
// at e05a0ab8a670478d97765d26ffb8493ed5b7ab66 (MIT).
nonisolated struct SpatialTouchCalibration: Equatable, Sendable {
    struct Key: Equatable, Sendable {
        let offsetX: Double
        let offsetY: Double
        let sigmaX: Double
        let sigmaY: Double
        var covarianceXY: Double = 0
        var degrees: Double = SpatialTouchCalibration.priorWeight - 1

        private var determinant: Double { sigmaX * sigmaX * sigmaY * sigmaY - covarianceXY * covarianceXY }

        func mahalanobis(x: Double, y: Double) -> Double {
            let dx = x - offsetX, dy = y - offsetY
            return max(0, (sigmaY * sigmaY * dx * dx - 2 * covarianceXY * dx * dy + sigmaX * sigmaX * dy * dy) / determinant)
        }

        func logDensity(x: Double, y: Double) -> Double {
            -log(2 * Double.pi) - 0.5 * log(determinant) - (degrees / 2 + 1) * log1p(mahalanobis(x: x, y: y) / degrees)
        }

        func logDensityY(_ y: Double) -> Double {
            let dy = y - offsetY, variance = sigmaY * sigmaY
            return lgamma((degrees + 1) / 2) - lgamma(degrees / 2) - 0.5 * log(degrees * Double.pi * variance)
                - (degrees + 1) / 2 * log1p(dy * dy / (degrees * variance))
        }
    }

    struct Moments: Equatable, Sendable {
        var n = 0.0
        var meanX = 0.0, meanY = 0.0
        var scatterXX = 0.0, scatterXY = 0.0, scatterYY = 0.0
    }

    struct Spread: Equatable, Sendable {
        let xx: Double, xy: Double, yy: Double

        static let prior = Spread(pooling: [])

        init(pooling keys: [Moments]) {
            let weight = SpatialTouchCalibration.priorWeight - 3
            let prior = weight * SpatialTouchCalibration.priorSpread * SpatialTouchCalibration.priorSpread
            var xx = prior, xy = 0.0, yy = prior, n = weight
            for key in keys {
                let shrink = SpatialTouchCalibration.centerPrior * key.n / (SpatialTouchCalibration.centerPrior + key.n)
                xx += key.scatterXX + shrink * key.meanX * key.meanX
                xy += key.scatterXY + shrink * key.meanX * key.meanY
                yy += key.scatterYY + shrink * key.meanY * key.meanY
                n += key.n
            }
            (self.xx, self.xy, self.yy) = (xx / n, xy / n, yy / n)
        }
    }

    static func posterior(_ taps: Moments, spread: Spread) -> Key {
        let n = taps.n
        let kappa = centerPrior + n
        let degrees = priorWeight + n - 1
        let weight = priorWeight - 3
        let shrink = centerPrior * n / kappa
        let scale = (kappa + 1) / (kappa * degrees)
        let xx = (weight * spread.xx + taps.scatterXX + shrink * taps.meanX * taps.meanX) * scale
        let xy = (weight * spread.xy + taps.scatterXY + shrink * taps.meanX * taps.meanY) * scale
        let yy = (weight * spread.yy + taps.scatterYY + shrink * taps.meanY * taps.meanY) * scale
        return Key(offsetX: n / kappa * taps.meanX, offsetY: n / kappa * taps.meanY,
                   sigmaX: sqrt(xx), sigmaY: sqrt(yy), covarianceXY: xy, degrees: degrees)
    }

    let keys: [Character: Key]
    let space: Key?
    static let centerPrior = 1.0
    static let priorWeight = 10.0
    static let priorSpread = 0.20
    static let prior = posterior(Moments(), spread: .prior)
    static let maxOffset = 0.5
    /// Standard deviation of a key's predictive covariance in every direction, in pitches. The floor
    /// (about half a millimetre on a phone) lies below measured human touch precision; it keeps
    /// near-collinear labels from collapsing a key onto a line.
    static let deviationRange: ClosedRange<Double> = 0.08...1.0
    static let degreesRange: ClosedRange<Double> = 3...1_000

    init(keys: [Character: Key], space: Key? = nil) {
        self.keys = keys.reduce(into: [:]) { result, entry in
            guard entry.key.isLetter, String(entry.key) == String(entry.key).lowercased(),
                  let key = Self.sanitized(entry.value) else { return }
            result[entry.key] = key
        }
        self.space = space.flatMap { Self.sanitized($0) }
    }

    static func scaleRange(degrees: Double) -> ClosedRange<Double> {
        let toScale = ((degrees - 2) / degrees).squareRoot()
        return deviationRange.lowerBound * toScale...deviationRange.upperBound * toScale
    }

    static func sanitized(_ key: Key) -> Key? {
        guard key.offsetX.isFinite, key.offsetY.isFinite, key.sigmaX.isFinite, key.sigmaY.isFinite,
              key.covarianceXY.isFinite, degreesRange.contains(key.degrees) else { return nil }
        let sigmaRange = scaleRange(degrees: key.degrees)
        let sx = max(sigmaRange.lowerBound, min(sigmaRange.upperBound, key.sigmaX))
        let sy = max(sigmaRange.lowerBound, min(sigmaRange.upperBound, key.sigmaY))
        let offsetX = max(-maxOffset, min(maxOffset, key.offsetX))
        let offsetY = max(-maxOffset, min(maxOffset, key.offsetY))
        let xy = max(-sx * sy, min(sx * sy, key.covarianceXY))
        guard xy != 0 else {
            return Key(offsetX: offsetX, offsetY: offsetY, sigmaX: sx, sigmaY: sy, degrees: key.degrees)
        }
        let floor = sigmaRange.lowerBound * sigmaRange.lowerBound
        let ceiling = sigmaRange.upperBound * sigmaRange.upperBound
        // 2×2 symmetric eigen-decomposition without trigonometry: mean ± radius.
        let half = (sx * sx - sy * sy) / 2, mean = (sx * sx + sy * sy) / 2, radius = hypot(half, xy)
        let large = max(floor, min(ceiling, mean + radius)), small = max(floor, min(ceiling, mean - radius))
        let center = (large + small) / 2, spread = (large - small) / 2
        return Key(offsetX: offsetX, offsetY: offsetY,
                   sigmaX: sqrt(center + spread * half / radius), sigmaY: sqrt(center - spread * half / radius),
                   covarianceXY: spread * xy / radius, degrees: key.degrees)
    }
}

/// A trusted tap and lowercase letter supplied by the integration's aligner; never persisted.
nonisolated struct TouchLabel: Equatable, Sendable {
    let point: CGPoint
    let letter: Character
}

nonisolated enum TouchLabelSource: String, Codable, CaseIterable, Sendable {
    case literalValid, keep, undo, manualPick, retype, space, autocorrect
}

nonisolated enum TouchLabelRejection: String, Codable, CaseIterable, Sendable {
    case outlier, nonFinite, unknownKey, layoutMismatch, ambiguousAlignment, learningOff
}

/// A normalized typed → replacement pair rejected by explicit feedback.
nonisolated struct RejectedCorrection: Hashable, Codable, Sendable {
    let typed: String
    let replacement: String
    // Nil horizons preserve legacy explicit rejections indefinitely.
    var context: String? = nil
    var remaining: Int? = nil
    var globalRemaining: Int? = nil

    // Identity excludes decay/context: deletion and reversal still address the pair.
    // Counter changes invalidate the model's snapshot through its word-event generation.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.typed == rhs.typed && lhs.replacement == rhs.replacement
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(typed)
        hasher.combine(replacement)
    }

    /// Bounded local predecessor key; punctuation terminates rather than crossing sentences.
    static func context(before input: String?, token: String) -> String? {
        guard let input, input.hasSuffix(token) else { return nil }
        let prefix = input.dropLast(token.count).suffix(96)
        var words: [String] = []
        for part in prefix.split(separator: " ").reversed().prefix(2) {
            let word = PersonalLexiconSnapshot.normalize(String(part))
            guard PersonalTypingModel.State.validWord(word) else { break }
            words.insert(word, at: 0)
        }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    func blocks(in currentContext: String?) -> Bool {
        guard let remaining else { return true }
        return remaining > 0 && ((globalRemaining ?? 0) > 0 || (context != nil && context == currentContext))
    }

    init(typed: String, replacement: String) {
        self.typed = PersonalLexiconSnapshot.normalize(typed)
        self.replacement = PersonalLexiconSnapshot.normalize(replacement)
    }

    private enum CodingKeys: String, CodingKey { case typed, replacement, context, remaining, globalRemaining }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(typed: try container.decode(String.self, forKey: .typed),
                  replacement: try container.decode(String.self, forKey: .replacement))
        context = try container.decodeIfPresent(String.self, forKey: .context)
        remaining = try container.decodeIfPresent(Int.self, forKey: .remaining)
        globalRemaining = try container.decodeIfPresent(Int.self, forKey: .globalRemaining)
    }
}

/// Immutable canonical word collections; the learning model supplies normalized keys.
// Keeps and personal counts adapted from AVGVSTVS96/iikb
// Packages/KeyboardModules/Sources/KeyboardCore/Correction/TypingMemory.swift (MIT).
nonisolated struct PersonalLexiconSnapshot: Equatable, Sendable {
    let kept: Set<String>
    let counts: [String: Int]
    let rejected: Set<RejectedCorrection>
    /// Shared identity lets the decoder reuse filtered entries without comparing 2,000 words.
    let scan: ScanList

    nonisolated final class ScanList: Sendable {
        nonisolated struct Entry: Sendable {
            let word: String
            let labels: [Int]
            let bonus: Double
        }
        let entries: [Entry]
        let complete: Bool
        let maxBonus: Double
        /// Display-only prefix retrieval over the same prepared words (kept or counted twice).
        let completions: PersonalCompletionIndex

        init(kept: Set<String>, counts: [String: Int]) {
            func bonus(_ count: Int) -> Double {
                guard count >= 1 else { return 0 }
                return min(PersonalLexiconSnapshot.maxBonus, 0.25 * log2(1 + Double(count)))
            }
            // Check each counted key once; kept-only words are checked below. Noncanonical
            // count keys cannot supply a bonus, even in externally constructed snapshots.
            let normalizedCounts = counts.filter { $0.key == PersonalLexiconSnapshot.normalize($0.key) }
            let words = kept.union(counts.keys.filter { (counts[$0] ?? 0) >= 2 }).sorted()
            complete = words.count <= 2_000
            maxBonus = normalizedCounts.values.map(bonus).max() ?? 0
            entries = words.prefix(2_000).compactMap { word in
                let normalized = counts[word] == nil
                    ? word == PersonalLexiconSnapshot.normalize(word) : normalizedCounts[word] != nil
                guard normalized else { return nil }
                let letters = Array(word)
                guard (2...32).contains(letters.count) else { return nil }
                let labels = letters.compactMap { SpatialWordLexicon.alphabet.firstIndex(of: $0) }
                guard labels.count == letters.count else { return nil }
                return Entry(word: word, labels: labels, bonus: bonus(counts[word] ?? 0))
            }
            completions = PersonalCompletionIndex(sortedWords: entries.map(\.word), kept: kept,
                                                  counts: normalizedCounts)
        }
    }

    init(kept: Set<String>, counts: [String: Int], rejected: Set<RejectedCorrection>) {
        self.kept = kept
        self.counts = counts
        self.rejected = rejected
        scan = ScanList(kept: kept, counts: counts)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kept == rhs.kept && lhs.counts == rhs.counts && lhs.rejected == rhs.rejected
    }

    static let empty = PersonalLexiconSnapshot(kept: [], counts: [:], rejected: [])
    static let maxBonus = 1.0

    static func normalize(_ word: String) -> String {
        word.lowercased().precomposedStringWithCanonicalMapping
    }

    func isKept(_ word: String) -> Bool {
        kept.contains(Self.normalize(word))
    }

    func isRejected(typed: String, replacement: String, context: String? = nil) -> Bool {
        let pair = RejectedCorrection(typed: typed, replacement: replacement)
        return rejected.first(where: { $0 == pair })?.blocks(in: context) == true
    }

    func bonus(for word: String) -> Double {
        guard let count = counts[Self.normalize(word)], count >= 1 else { return 0 }
        return min(Self.maxBonus, 0.25 * log2(1 + Double(count)))
    }
}
