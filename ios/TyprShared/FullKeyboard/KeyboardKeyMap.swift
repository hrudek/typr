import Foundation
import CoreGraphics

/// Invisible letter attribution, not a layout or word decoder.
/// KeyMap/posterior × prefix continuation idea translated from iikb Correction/KeyMap.swift
/// and Typing/TypingEngine+Words.swift at 09a2e9cdfbe851adff6c4646333c0a3f74ba8765; novelty
/// backoff from Correction/LanguageModel.swift `next(after:)` at e05a0ab8a670478d97765d26ffb8493ed5b7ab66
/// (MIT, © 2026 Bassim Shahidy). Typr owns the bounds and trust policy.
nonisolated struct KeyboardKeyMap: Sendable {
    static let keyLimit = 26
    /// Share of a novel spelling in the next-letter odds, as iikb's `LanguageModel.novelty`.
    static let novelty = 0.10

    struct Entry: Sendable {
        let key: KeyboardKey
        let density: SpatialTouchCalibration.Key
        let logPrior: Double
    }

    /// The sentence before the word: language weight and the previous word's corpus followers.
    struct Context: Sendable {
        struct Followers: Sendable {
            let lambda: Double
            let words: [(key: String, probability: Double)]
        }
        let weightDE: Double
        let followers: [SpatialWordDecoder.Language: Followers]
    }

    let layout: KeyboardLayout
    let prefix: String
    let entries: [Entry]
    var payloadBytes: Int { entries.count * MemoryLayout<Entry>.stride }

    /// Letters the calibration has not learned score with the prior touch model.
    init(layout: KeyboardLayout, prefix: String, calibration: SpatialTouchCalibration, priors: [Double]) {
        self.layout = layout
        self.prefix = prefix
        entries = layout.keys.compactMap { key in
            guard let text = key.character, let letter = text.first, text.count == 1,
                  let index = SpatialWordLexicon.alphabet.firstIndex(of: letter), index < Self.keyLimit,
                  priors.count == Self.keyLimit else { return nil }
            return Entry(key: key, density: calibration.keys[letter] ?? SpatialTouchCalibration.prior,
                         logPrior: log(priors[index] * 26))
        }.prefix(Self.keyLimit).map { $0 }
    }

    /// The map for the next tap after `prefix`, or nil for a prefix the priors cannot read.
    static func make(layout: KeyboardLayout, prefix: String, calibration: SpatialTouchCalibration,
                     languages: Set<SpatialWordDecoder.Language>,
                     lexicons: [SpatialWordDecoder.Language: SpatialWordLexicon],
                     personal: PersonalCompletionIndex?, context: Context? = nil) -> KeyboardKeyMap? {
        guard let priors = priors(prefix: prefix, languages: languages, lexicons: lexicons,
                                  personal: personal, context: context) else { return nil }
        return KeyboardKeyMap(layout: layout, prefix: prefix, calibration: calibration, priors: priors)
    }

    /// P(next letter | prefix, sentence), folded onto the 26 letter keys (accents share a/o/u/s).
    /// Per language, the previous word's corpus model P(w|h) = λ·P(w) + boost(w), with the word
    /// list's subtree mass standing in for P(w); languages mix by the sentence's weight. Personal
    /// words take 20% of the known mass. A novel spelling keeps `novelty × 26^-(n+1)`, so an
    /// absent prefix backs off to uniform odds.
    static func priors(prefix: String, languages: Set<SpatialWordDecoder.Language>,
                       lexicons: [SpatialWordDecoder.Language: SpatialWordLexicon],
                       personal: PersonalCompletionIndex?, context: Context? = nil) -> [Double]? {
        guard !languages.isEmpty, languages.allSatisfy({ lexicons[$0] != nil }),
              prefix.utf8.count <= 256, prefix.count <= 31 else { return nil }
        func slot(_ letter: Character) -> Int? {
            SpatialWordLexicon.alphabet.firstIndex(of: KeyboardLetterMap.holder(of: letter)).flatMap {
                $0 < keyLimit ? $0 : nil
            }
        }
        func share(_ mass: [Double], of total: [Double]) -> [Double] {
            var folded = [Double](repeating: 0, count: keyLimit)
            let sum = total.reduce(0, +)
            guard sum > 0 else { return folded }
            for (index, value) in mass.enumerated() {
                if let holder = slot(SpatialWordLexicon.alphabet[index]) { folded[holder] += value / sum }
            }
            return folded
        }
        var known = [Double](repeating: 0, count: keyLimit)
        // Fixed language order is important for deterministic floating point mixtures.
        for language in SpatialWordDecoder.Language.allCases where languages.contains(language) {
            let lexicon = lexicons[language]!
            let weight = languages.count == 1 ? 1
                : language == .german ? context?.weightDE ?? 0.5 : 1 - (context?.weightDE ?? 0.5)
            let followers = context?.followers[language]
            let mass = share(lexicon.nextLetterMass(after: prefix), of: lexicon.nextLetterMass(after: ""))
            for index in known.indices { known[index] += weight * (followers?.lambda ?? 1) * mass[index] }
            for follower in followers?.words ?? [] where follower.key.count > prefix.count
                && follower.key.hasPrefix(prefix) {
                let next = follower.key[follower.key.index(follower.key.startIndex, offsetBy: prefix.count)]
                if let index = slot(next) { known[index] += weight * follower.probability }
            }
        }
        if let personal {
            let mass = share(personal.nextLetterMass(after: prefix), of: personal.nextLetterMass(after: ""))
            if mass.contains(where: { $0 > 0 }) {
                for index in known.indices { known[index] = 0.8 * known[index] + 0.2 * mass[index] }
            }
        }
        let novel = novelty * pow(1.0 / 26, Double(prefix.count + 1))
        let odds = known.map { (1 - novelty) * $0 + novel }
        let sum = odds.reduce(0, +)
        return odds.map { $0 / sum }
    }

    /// iikb `KeyMap.key(atX:y:in:)`: the reachable letter key with the highest touch density plus
    /// log prior odds. Call at actual insertion; the caller also validates text/config/model epoch.
    /// Only letter keys compete; other keys keep the taps landing on them.
    func attributedKey(at point: CGPoint, geometric: KeyboardKey,
                       layout current: KeyboardLayout, prefix currentPrefix: String) -> KeyboardKey {
        guard current == layout, currentPrefix == prefix, layout.layer == .letters, layout.field == .text,
              point.x.isFinite, point.y.isFinite, layout.hitTest(point) == geometric,
              let hit = entries.first(where: { $0.key == geometric }) else { return geometric }
        let pitchX = Double(geometric.frame.width + layout.metrics.gap)
        let pitchY = Double(geometric.frame.height + layout.metrics.rowGap)
        guard pitchX > 0, pitchY > 0 else { return geometric }
        func score(_ entry: Entry) -> Double {
            entry.density.logDensity(x: Double(point.x - entry.key.frame.midX) / pitchX,
                                     y: Double(point.y - entry.key.frame.midY) / pitchY) + entry.logPrior
        }
        var best = hit.key
        var bestScore = score(hit)
        for entry in entries where entry.key != hit.key && layout.reaches(point, letter: entry.key.character!) {
            let posterior = score(entry)
            if posterior > bestScore { best = entry.key; bestScore = posterior }
        }
        return best
    }
}
