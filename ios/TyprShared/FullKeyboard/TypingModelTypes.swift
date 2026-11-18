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

/// Read-only offsets and spreads in key pitches (frame width + gap, height + rowGap).
// Layout-separated calibration adapted from AVGVSTVS96/iikb
// Packages/KeyboardModules/Sources/KeyboardCore/Correction/TouchModel.swift (MIT).
nonisolated struct SpatialTouchCalibration: Equatable, Sendable {
    struct Key: Equatable, Sendable {
        let offsetX: Double
        let offsetY: Double
        let sigmaX: Double
        let sigmaY: Double
        var covarianceXY: Double = 0

        private var determinant: Double { sigmaX * sigmaX * sigmaY * sigmaY - covarianceXY * covarianceXY }

        /// Squared Mahalanobis distance from the centre. Sanitized by the snapshot initializer.
        func mahalanobis(x: Double, y: Double) -> Double {
            let dx = x - offsetX, dy = y - offsetY
            return max(0, (sigmaY * sigmaY * dx * dx - 2 * covarianceXY * dx * dy + sigmaX * sigmaX * dy * dy) / determinant)
        }

        /// Normalized full-covariance Gaussian. Sanitized by the snapshot initializer.
        func logDensity(x: Double, y: Double) -> Double {
            if covarianceXY == 0 {
                // Exact origin/main diagonal expression; also avoids unnecessary covariance
                // arithmetic on the learning-off and slow-diagonal benchmark paths.
                let dx = x - offsetX, dy = y - offsetY
                return -0.5 * (dx * dx / (sigmaX * sigmaX) + dy * dy / (sigmaY * sigmaY))
                    - log(2 * Double.pi * sigmaX * sigmaY)
            }
            return -0.5 * mahalanobis(x: x, y: y) - log(2 * Double.pi) - 0.5 * log(determinant)
        }
    }

    let keys: [Character: Key]
    let space: Key?
    static let staticSigma = 0.35
    /// Physical tap spread (pitches) that the static density and the decoder's prior weight
    /// were tuned for: the fixed spatial evaluation's tune/holdout noise of .18/.22 pitch.
    /// Learned spreads are tempered by (staticSigma / referenceSpread)² so that a typical
    /// typist keeps the static density's calibration instead of overconfident evidence.
    static let referenceSpread = 0.20
    static let temperature = (staticSigma / referenceSpread) * (staticSigma / referenceSpread)
    /// One-hand thumb use moves far-side aim by up to about half a key; the one-pitch
    /// label gate and the 1.6-pitch decoder gate stay unchanged.
    static let maxOffset = 0.5
    static let sigmaRange: ClosedRange<Double> = 0.22...0.50

    init(keys: [Character: Key], space: Key? = nil) {
        self.keys = keys.reduce(into: [:]) { result, entry in
            guard entry.key.isLetter, String(entry.key) == String(entry.key).lowercased(),
                  let key = Self.sanitized(entry.value, sigmaRange: Self.sigmaRange) else { return }
            result[entry.key] = key
        }
        self.space = space.flatMap { Self.sanitized($0, sigmaRange: Self.sigmaRange) }
    }

    /// Finite, bounded centres; both covariance eigenvalues inside `sigmaRange`², hence a
    /// positive determinant floor. Correlated spreads clamp their EIGENVALUES, preserving the
    /// ellipse orientation; diagonal spreads clamp each axis exactly. `nil` for non-finite input.
    static func sanitized(_ key: Key, sigmaRange: ClosedRange<Double>) -> Key? {
        guard key.offsetX.isFinite, key.offsetY.isFinite,
              key.sigmaX.isFinite, key.sigmaY.isFinite, key.covarianceXY.isFinite else { return nil }
        let sx = max(sigmaRange.lowerBound, min(sigmaRange.upperBound, key.sigmaX))
        let sy = max(sigmaRange.lowerBound, min(sigmaRange.upperBound, key.sigmaY))
        let offsetX = max(-maxOffset, min(maxOffset, key.offsetX))
        let offsetY = max(-maxOffset, min(maxOffset, key.offsetY))
        let xy = max(-sx * sy, min(sx * sy, key.covarianceXY))
        guard xy != 0 else { return Key(offsetX: offsetX, offsetY: offsetY, sigmaX: sx, sigmaY: sy) }
        let floor = sigmaRange.lowerBound * sigmaRange.lowerBound
        let ceiling = sigmaRange.upperBound * sigmaRange.upperBound
        // 2×2 symmetric eigen-decomposition without trigonometry: mean ± radius.
        let half = (sx * sx - sy * sy) / 2, mean = (sx * sx + sy * sy) / 2, radius = hypot(half, xy)
        let large = max(floor, min(ceiling, mean + radius)), small = max(floor, min(ceiling, mean - radius))
        let center = (large + small) / 2, spread = (large - small) / 2
        return Key(offsetX: offsetX, offsetY: offsetY,
                   sigmaX: sqrt(center + spread * half / radius), sigmaY: sqrt(center - spread * half / radius),
                   covarianceXY: spread * xy / radius)
    }
}

/// A trusted tap and lowercase letter supplied by the integration's aligner; never persisted.
nonisolated struct TouchLabel: Equatable, Sendable {
    let point: CGPoint
    let letter: Character
}

nonisolated enum TouchLabelSource: String, Codable, CaseIterable, Sendable {
    case literalValid, keep, undo, manualPick, retype, space
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
