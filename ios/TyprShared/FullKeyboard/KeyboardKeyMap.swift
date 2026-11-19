import Foundation
import CoreGraphics

/// Invisible letter attribution, not a layout or word decoder.
/// KeyMap/posterior × prefix continuation idea translated from iikb Correction/KeyMap.swift
/// and Typing/TypingEngine+Words.swift at 09a2e9cdfbe851adff6c4646333c0a3f74ba8765
/// (MIT, © 2026 Bassim Shahidy). Typr owns the bounds, abstention and trust policy.
nonisolated struct KeyboardKeyMap: Sendable {
    static let keyLimit = 26
    /// Standard is conservative; Adaptive reads every tap as iikb's `KeyMap` does. The Hit areas setting picks one.
    struct Policy: Sendable {
        let boundaryFraction: Double
        let novelFloor: Double
        let minimumPrefix: Int
        let densityMargin: Double
        let posteriorMargin: Double
        let requiresConsistency: Bool
        /// Evaluation-only alternative to the conservative gap band.
        var includesKeyEdges: Bool = false
        /// iikb's `KeyMap`: every letter key the tap reaches competes on learned density times
        /// next-letter odds, from a word's first letter, without margins or consistency checks.
        var readsEveryTap: Bool = false
        /// Bound on |ln| of a letter's prior odds against a uniform letter.
        var priorOddsLimit: Double = log(2)

        static let conservative = Policy(boundaryFraction: 0.015, novelFloor: 0.90,
                                         minimumPrefix: 4, densityMargin: log(4),
                                         posteriorMargin: log(16), requiresConsistency: true)
        static let adaptive = Policy(boundaryFraction: 0.015, novelFloor: 0.10,
                                     minimumPrefix: 0, densityMargin: 0,
                                     posteriorMargin: 0, requiresConsistency: false,
                                     readsEveryTap: true, priorOddsLimit: .infinity)
    }
    static let boundaryFraction = Policy.conservative.boundaryFraction
    struct Entry: Sendable {
        let key: KeyboardKey
        let density: SpatialTouchCalibration.Key
        let logPrior: Double
    }
    let layout: KeyboardLayout
    let prefix: String
    let entries: [Entry]
    let policy: Policy
    var payloadBytes: Int { entries.count * MemoryLayout<Entry>.stride }

    init(layout: KeyboardLayout, prefix: String, calibration: SpatialTouchCalibration,
         priors: [Double], policy: Policy = .conservative) {
        self.layout = layout
        self.prefix = prefix
        self.policy = policy
        entries = layout.keys.compactMap { key in
            guard let text = key.character, let letter = text.first, text.count == 1,
                  let index = SpatialWordLexicon.alphabet.firstIndex(of: letter), index < Self.keyLimit,
                  let density = calibration.keys[letter], priors.count == Self.keyLimit else { return nil }
            // Standard limits the prior odds between any two letters to four; Adaptive does not.
            // Priors are at least novelFloor / 26, so the logarithm stays finite.
            let gain = log(priors[index] * 26)
            let limit = policy.priorOddsLimit
            return Entry(key: key, density: density, logPrior: max(-limit, min(limit, gain)))
        }.prefix(Self.keyLimit).map { $0 }
    }

    /// The map for the next tap after `prefix`, or nil where the policy abstains for the whole tap.
    static func make(layout: KeyboardLayout, prefix: String, calibration: SpatialTouchCalibration,
                     languages: Set<SpatialWordDecoder.Language>,
                     lexicons: [SpatialWordDecoder.Language: SpatialWordLexicon],
                     personal: PersonalCompletionIndex?, policy: Policy) -> KeyboardKeyMap? {
        guard let priors = priors(prefix: prefix, languages: languages, lexicons: lexicons,
                                  personal: personal, policy: policy) else { return nil }
        return KeyboardKeyMap(layout: layout, prefix: prefix, calibration: calibration, priors: priors,
                              policy: policy)
    }

    /// Unknown source prefixes contribute uniform mass, never an English-only fallback.
    /// Equal enabled-language mixture, 90% uniform novel-word floor; personal mass can take
    /// at most 20% of the known component. Accents share physical a/o/u/s holders.
    static func priors(prefix: String, languages: Set<SpatialWordDecoder.Language>,
                       lexicons: [SpatialWordDecoder.Language: SpatialWordLexicon],
                       personal: PersonalCompletionIndex?, policy: Policy = .conservative) -> [Double]? {
        guard !languages.isEmpty, languages.allSatisfy({ lexicons[$0] != nil }),
              prefix.utf8.count <= 256, (min(2, policy.minimumPrefix)...31).contains(prefix.count) else { return nil }
        func distribution(_ masses: [Double]) -> [Double] {
            var folded = [Double](repeating: 0, count: keyLimit)
            for (index, mass) in masses.enumerated() {
                let letter = KeyboardLetterMap.holder(of: SpatialWordLexicon.alphabet[index])
                if let holder = SpatialWordLexicon.alphabet.firstIndex(of: letter), holder < keyLimit {
                    folded[holder] += mass
                }
            }
            let sum = folded.reduce(0, +)
            return sum > 0 ? folded.map { $0 / sum } : [Double](repeating: 1.0 / 26, count: keyLimit)
        }
        var mixed = [Double](repeating: 0, count: keyLimit)
        var hasContinuation = false
        // Fixed language order is important for deterministic floating point mixtures.
        for language in SpatialWordDecoder.Language.allCases where languages.contains(language) {
            let mass = lexicons[language]!.nextLetterMass(after: prefix)
            hasContinuation = hasContinuation || mass.contains(where: { $0 > 0 })
            let source = distribution(mass)
            for index in mixed.indices { mixed[index] += source[index] / Double(languages.count) }
        }
        if let personal {
            let mass = personal.nextLetterMass(after: prefix)
            if mass.reduce(0, +) > 0 {
                hasContinuation = true
                let source = distribution(mass)
                for index in mixed.indices { mixed[index] = 0.8 * mixed[index] + 0.2 * source[index] }
            }
        }
        // A trie cannot re-enter after an absent prefix by appending letters. Combined with
        // the per-word edit latch, this stops adaptation for the rest of an OOV/edited word.
        guard hasContinuation else { return nil }
        return mixed.map { policy.novelFloor / 26 + (1 - policy.novelFloor) * $0 }
    }

    /// The key typed at insertion, by either policy. Call at actual insertion, not touch-down;
    /// the caller also validates text/config/model epoch. Only the same-row immediate neighbour
    /// across the gap band can win; outer/function/space/punctuation cells cannot donate.
    func attributedKey(at point: CGPoint, geometric: KeyboardKey,
                       layout current: KeyboardLayout, prefix currentPrefix: String) -> KeyboardKey {
        guard let (hit, pitchX, score) = scoring(at: point, geometric: geometric, layout: current,
                                                 prefix: currentPrefix) else { return geometric }
        if policy.readsEveryTap { return likeliestKey(at: point, literal: hit, score: score) }
        return gapKey(at: point, literal: hit, pitchX: pitchX, score: score)
    }

    /// iikb `KeyMap.key(atX:y:in:)`: the reachable letter key with the highest learned density
    /// plus log prior odds. Only letter keys compete; other keys keep the taps landing on them.
    private func likeliestKey(at point: CGPoint, literal hit: Entry, score: (Entry) -> Double) -> KeyboardKey {
        var best = hit.key
        var bestScore = score(hit) + hit.logPrior
        for entry in entries where entry.key != hit.key && layout.reaches(point, letter: entry.key.character!) {
            let posterior = score(entry) + entry.logPrior
            if posterior > bestScore { best = entry.key; bestScore = posterior }
        }
        return best
    }

    private func scoring(at point: CGPoint, geometric: KeyboardKey, layout current: KeyboardLayout,
                         prefix currentPrefix: String) -> (Entry, Double, (Entry) -> Double)? {
        guard current == layout, currentPrefix == prefix, prefix.count >= policy.minimumPrefix,
              layout.layer == .letters,
              layout.field == .text, point.x.isFinite, point.y.isFinite,
              layout.hitTest(point) == geometric,
              let hit = entries.first(where: { $0.key == geometric }) else { return nil }
        let pitchX = Double(geometric.frame.width + layout.metrics.gap)
        let pitchY = Double(geometric.frame.height + layout.metrics.rowGap)
        guard pitchX > 0, pitchY > 0 else { return nil }
        let score = { (entry: Entry) -> Double in
            entry.density.logDensity(x: Double(point.x - entry.key.frame.midX) / pitchX,
                                     y: Double(point.y - entry.key.frame.midY) / pitchY)
        }
        return (hit, pitchX, score)
    }

    private func gapKey(at point: CGPoint, literal hit: Entry, pitchX: Double,
                        score: (Entry) -> Double) -> KeyboardKey {
        let geometric = hit.key
        guard policy.includesKeyEdges || !geometric.frame.contains(point),
              abs(point.x - geometric.frame.midX) > geometric.frame.width * 0.35,
              abs(point.y - geometric.frame.midY) <= geometric.frame.height * 0.30 else { return geometric }
        let literalDensity = score(hit)
        let literalScore = literalDensity + hit.logPrior
        var best = geometric
        var bestScore = literalScore + policy.posteriorMargin
        for entry in entries where entry.key.row == geometric.row && entry.key != geometric {
            let dx = entry.key.frame.midX - geometric.frame.midX
            guard abs(dx) <= CGFloat(pitchX) * 1.05 else { continue }
            let boundary = dx > 0 ? geometric.hitFrame.maxX : geometric.hitFrame.minX
            let band: CGFloat = policy.includesKeyEdges
                ? layout.metrics.gap / 2 + geometric.frame.width * policy.boundaryFraction
                : min(geometric.frame.width * policy.boundaryFraction, layout.metrics.gap / 2)
            guard abs(point.x - boundary) <= band,
                  entry.logPrior > hit.logPrior else { continue }
            if policy.requiresConsistency {
                // A single displaced/overconfident key is not evidence of shared aim. Both
                // neighboring learned clouds must agree on drift direction, centre and spread.
                let a = entry.density, b = hit.density
                let direction = dx > 0 ? -1.0 : 1.0
                guard a.offsetX * direction >= 0.25, b.offsetX * direction >= 0.25,
                      abs(a.offsetX - b.offsetX) <= 0.08,
                      abs(a.offsetY - b.offsetY) <= 0.08,
                      abs(a.sigmaX - b.sigmaX) <= 0.08,
                      abs(a.sigmaY - b.sigmaY) <= 0.08,
                      abs(a.covarianceXY - b.covarianceXY) <= 0.015 else { continue }
            }
            let density = score(entry)
            // Language cannot override a geometrically better reading. Require learned aim
            // evidence in addition to the posterior margin; cold/static maps stay literal.
            guard density > literalDensity + policy.densityMargin else { continue }
            let posterior = density + entry.logPrior
            if posterior > bestScore { best = entry.key; bestScore = posterior }
        }
        return best
    }
}

extension KeyboardKeyMap.Policy {
    init(_ hitAreas: KeyboardHitAreas) {
        self = hitAreas == .adaptive ? .adaptive : .conservative
    }
}
