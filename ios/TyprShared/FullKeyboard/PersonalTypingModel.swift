import Foundation

/// Aggregates only: no raw taps, sentences or surrounding text are retained.
@MainActor
final class PersonalTypingModel {
    nonisolated struct TouchStats: Codable, Equatable, Sendable {
        var n = 0
        var meanX = 0.0
        var meanY = 0.0
        var varianceX = 0.0
        var varianceY = 0.0
        var covarianceXY = 0.0

        private enum CodingKeys: String, CodingKey { case n, meanX, meanY, varianceX, varianceY, covarianceXY }
        init(n: Int = 0, meanX: Double = 0, meanY: Double = 0,
             varianceX: Double = 0, varianceY: Double = 0, covarianceXY: Double = 0) {
            self.n = n; self.meanX = meanX; self.meanY = meanY
            self.varianceX = varianceX; self.varianceY = varianceY; self.covarianceXY = covarianceXY
        }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            n = try c.decode(Int.self, forKey: .n)
            meanX = try c.decode(Double.self, forKey: .meanX)
            meanY = try c.decode(Double.self, forKey: .meanY)
            varianceX = try c.decode(Double.self, forKey: .varianceX)
            varianceY = try c.decode(Double.self, forKey: .varianceY)
            // Schema 1 had diagonal statistics only; missing covariance means zero.
            covarianceXY = try c.decodeIfPresent(Double.self, forKey: .covarianceXY) ?? 0
        }

        // Pitch-normalized sufficient statistics adapted from AVGVSTVS96/iikb
        // Packages/KeyboardModules/Sources/KeyboardCore/Correction/TouchModel.swift (MIT).
        mutating func update(x: Double, y: Double) {
            guard x.isFinite, y.isFinite else { return }
            // The inclusive learn gate tolerates floating-point pitch rounding only.
            let x = max(-1, min(1, x)), y = max(-1, min(1, y))
            n = min(256, n + 1)
            let weight = max(1 / Double(n), 1 / 64.0)
            let dx = x - meanX, dy = y - meanY
            meanX = max(-1, min(1, meanX + weight * dx))
            meanY = max(-1, min(1, meanY + weight * dy))
            varianceX = max(0, min(1, (1 - weight) * (varianceX + weight * dx * dx)))
            varianceY = max(0, min(1, (1 - weight) * (varianceY + weight * dy * dy)))
            let limit = sqrt(varianceX * varianceY)
            covarianceXY = max(-limit, min(limit, (1 - weight) * (covarianceXY + weight * dx * dy)))
        }

        var moments: SpatialTouchCalibration.Moments {
            let n = Double(n)
            return .init(n: n, meanX: meanX, meanY: meanY,
                         scatterXX: n * varianceX, scatterXY: n * covarianceXY, scatterYY: n * varianceY)
        }

        var isValid: Bool {
            (1...256).contains(n) && meanX.isFinite && meanY.isFinite
                && abs(meanX) <= 1 && abs(meanY) <= 1
                && varianceX.isFinite && varianceY.isFinite
                && (0...1).contains(varianceX) && (0...1).contains(varianceY)
                && covarianceXY.isFinite && abs(covarianceXY) <= sqrt(varianceX * varianceY) + 1e-12
        }
    }

    // Per-key aim memories adapted from AVGVSTVS96/iikb
    // Packages/KeyboardModules/Sources/KeyboardCore/Correction/TouchModel.swift (KeyTouches, Drift)
    // at e05a0ab8a670478d97765d26ffb8493ed5b7ab66 (MIT).
    /// Where a key's taps centre lately (about 30 taps) and now (about 3), and how well all its
    /// taps, lately and now predicted each of its taps so far.
    nonisolated struct KeyAim: Codable, Equatable, Sendable {
        nonisolated struct Drift: Codable, Equatable, Sendable {
            var count = 0.0
            var x = 0.0, y = 0.0

            mutating func add(x: Double, y: Double, memory: Double) {
                count = count * (1 - 1 / memory) + 1
                self.x += (x - self.x) / count
                self.y += (y - self.y) / count
            }

            func isValid(memory: Double) -> Bool {
                count.isFinite && (0...memory).contains(count) && x.isFinite && y.isFinite && abs(x) <= 1 && abs(y) <= 1
            }
        }

        static let lately = 30.0
        static let now = 3.0
        static let switching = 0.01

        var lately = Drift()
        var now = Drift()
        /// All taps, lately, now.
        var weights = [1.0 / 3, 1.0 / 3, 1.0 / 3]

        /// A key learned before it had aim memories starts both where all its taps centre.
        init(seed stats: TouchStats?) {
            guard let stats else { return }
            let n = Double(stats.n)
            lately = Drift(count: min(n, Self.lately), x: stats.meanX, y: stats.meanY)
            now = Drift(count: min(n, Self.now), x: stats.meanX, y: stats.meanY)
        }

        private func memories(_ all: SpatialTouchCalibration.Key, n: Int) -> [SpatialTouchCalibration.Key] {
            let kappa = SpatialTouchCalibration.centerPrior + Double(n)
            return [all] + [lately, now].map {
                SpatialTouchCalibration.aiming(all, kappa: kappa, count: $0.count, x: $0.x, y: $0.y)
            }
        }

        func key(_ all: SpatialTouchCalibration.Key, n: Int) -> SpatialTouchCalibration.Key {
            SpatialTouchCalibration.blending(memories(all, n: n), weights: weights)
        }

        /// Reweighs each memory by how well it predicted this tap, keeping a share for each so
        /// any can take over, then learns the tap.
        mutating func add(x: Double, y: Double, all: SpatialTouchCalibration.Key, n: Int) {
            let x = max(-1, min(1, x)), y = max(-1, min(1, y))
            let scores = memories(all, n: n).map { $0.logDensity(x: x, y: y) }
            let best = scores.max() ?? 0
            let odds = zip(weights, scores).map { $0.0 * exp($0.1 - best) }
            let total = odds.reduce(0, +)
            if total.isFinite, total > 0 { weights = odds.map { (1 - Self.switching) * $0 / total + Self.switching / 3 } }
            lately.add(x: x, y: y, memory: Self.lately)
            now.add(x: x, y: y, memory: Self.now)
        }

        var isValid: Bool {
            lately.isValid(memory: Self.lately) && now.isValid(memory: Self.now) && weights.count == 3
                && weights.allSatisfy { $0.isFinite && $0 >= Self.switching / 3 - 1e-9 }
                && abs(weights.reduce(0, +) - 1) < 1e-9
        }
    }

    nonisolated struct LayoutStats: Codable, Equatable, Sendable {
        var signature: KeyboardLayoutSignature
        var lastUpdated: Date
        var keys: [String: TouchStats] = [:]
        // Optional only for schema-1 decoding. New labels create this aggregate.
        var global: TouchStats?
        var space: TouchStats?
        // Optional for stores saved before aim memories; a missing key's aim is seeded from its stats.
        var aims: [String: KeyAim]?

        var pooled: SpatialTouchCalibration.Spread {
            .init(pooling: keys.keys.sorted().compactMap { keys[$0].flatMap { $0.isValid ? $0.moments : nil } })
        }

        func slowKey(_ stats: TouchStats?) -> SpatialTouchCalibration.Key {
            SpatialTouchCalibration.posterior(stats?.moments ?? .init(), spread: pooled)
        }

        var spaceKey: SpatialTouchCalibration.Key? {
            space.map { SpatialTouchCalibration.posterior($0.moments, spread: .init(pooling: [$0.moments])) }
        }

        func aim(_ letter: String) -> KeyAim { aims?[letter] ?? KeyAim(seed: keys[letter]) }

        /// The key over all its taps; a key without taps is centred where all keys' taps centre.
        func allTapsKey(_ letter: String) -> SpatialTouchCalibration.Key {
            let value = keys[letter]
            let key = slowKey(value)
            guard value == nil, let global, global.n > 0 else { return Self.bounded(key) }
            let center = SpatialTouchCalibration.posterior(global.moments, spread: .prior)
            return Self.bounded(.init(offsetX: center.offsetX, offsetY: center.offsetY, sigmaX: key.sigmaX,
                                      sigmaY: key.sigmaY, covarianceXY: key.covarianceXY, degrees: key.degrees))
        }

        /// The density inference uses: all taps, lately and now blended by their weights.
        func key(_ letter: String) -> SpatialTouchCalibration.Key {
            let all = allTapsKey(letter)
            guard let stats = keys[letter] else { return all }
            return Self.bounded(aim(letter).key(all, n: stats.n))
        }

        private static func bounded(_ key: SpatialTouchCalibration.Key) -> SpatialTouchCalibration.Key {
            SpatialTouchCalibration.sanitized(key) ?? SpatialTouchCalibration.prior
        }
    }

    nonisolated struct WordCount: Codable, Equatable, Sendable {
        var count: Int
        var lastUpdated: Date
    }

    nonisolated struct State: Codable, Equatable, Sendable {
        var schemaVersion = 5
        var layouts: [String: LayoutStats] = [:]
        var kept: [String: Date] = [:]
        var counts: [String: WordCount] = [:]
        var rejected: [RejectedCorrection] = []
        // Historical field name retained: schema 1/2 lack it, schema 3 holds bigrams,
        // schema 4 additionally allows two-word context keys. No observations invented.
        var bigrams: PersonalBigramModel? = .init()

        func validated() -> State? {
            guard (1...5).contains(schemaVersion), layouts.count <= 4,
                  (schemaVersion < 3 || bigrams != nil),
                  Set(kept.keys).union(counts.keys).count <= 2000, rejected.count <= 512,
                  Set(rejected).count == rejected.count else { return nil }
            for (id, layout) in layouts {
                let signature = layout.signature
                guard id == signature.id, signature.isValid,
                      layout.lastUpdated.timeIntervalSinceReferenceDate.isFinite,
                      !layout.keys.isEmpty || layout.space != nil, layout.keys.count <= 26,
                      layout.global == nil || layout.global?.isValid == true,
                      layout.space == nil || layout.space?.isValid == true,
                      (layout.aims ?? [:]).allSatisfy({ layout.keys[$0.key] != nil && $0.value.isValid })
                else { return nil }
                for (key, stats) in layout.keys {
                    guard key.count == 1, key.utf8.count == 1,
                          key.utf8.allSatisfy({ (97...122).contains($0) }), stats.isValid else { return nil }
                }
            }
            guard kept.allSatisfy({ Self.validWord($0.key) && $0.value.timeIntervalSinceReferenceDate.isFinite }),
                  counts.allSatisfy({ Self.validWord($0.key) && (1...10_000).contains($0.value.count)
                      && $0.value.lastUpdated.timeIntervalSinceReferenceDate.isFinite }),
                  rejected.allSatisfy({ pair in
                      guard Self.validRejectedWord(pair.typed), Self.validRejectedWord(pair.replacement) else { return false }
                      if let remaining = pair.remaining {
                          guard (1...256).contains(remaining), let global = pair.globalRemaining,
                                (0...64).contains(global), global <= remaining else { return false }
                      } else if pair.globalRemaining != nil || pair.context != nil { return false }
                      if let context = pair.context {
                          let words = context.split(separator: " ").map(String.init)
                          guard (1...2).contains(words.count), words.allSatisfy(Self.validWord),
                                words.joined(separator: " ") == context else { return false }
                      }
                      return true
                  }) else { return nil }
            var migrated = self
            migrated.schemaVersion = 5
            // Schema 1/2 start empty (no invented observations). An out-of-bounds pair section
            // drops only the pairs: keeps, counts, rejections and touch statistics survive.
            if migrated.bigrams?.isValid != true { migrated.bigrams = .init() }
            return migrated
        }

        /// Repair only invalid key aggregates, preserving unrelated words and layouts.
        /// Called before saving as a backstop against an invalid statistic poisoning a session.
        @discardableResult
        mutating func discardInvalidTouchStats() -> Bool {
            let original = layouts
            for (id, var layout) in layouts {
                layout.keys = layout.keys.filter { key, stats in
                    key.utf8.count == 1 && key.utf8.allSatisfy { (97...122).contains($0) } && stats.isValid
                }
                layout.aims = layout.aims?.filter { layout.keys[$0.key] != nil && $0.value.isValid }
                if layout.global?.isValid == false { layout.global = nil }
                if layout.space?.isValid == false { layout.space = nil }
                if layout.keys.isEmpty && layout.space == nil { layouts.removeValue(forKey: id) }
                else { layouts[id] = layout }
            }
            return layouts != original
        }

        static func validWord(_ word: String) -> Bool {
            (2...32).contains(word.count) && word.utf8.count <= 256
                && word.allSatisfy(\.isLetter) && word == PersonalLexiconSnapshot.normalize(word)
        }

        /// Rejected correction forms may contain straight or typographic apostrophes.
        /// Keeps/counts remain letter-only; multi-word text replacements stay session-only.
        static func validRejectedWord(_ word: String) -> Bool {
            (2...32).contains(word.count) && word.utf8.count <= 256
                && word.contains(where: \.isLetter)
                && word.allSatisfy { $0.isLetter || $0 == "'" || $0 == "’" }
                && word == PersonalLexiconSnapshot.normalize(word)
        }

        /// One shared word budget. Evict unkept counts first, then the oldest keep
        /// (including its count), so retained protection always has priority.
        mutating func enforceWordLimit() {
            while Set(kept.keys).union(counts.keys).count > 2000 {
                if let victim = counts.filter({ kept[$0.key] == nil }).min(by: {
                    if $0.value.count != $1.value.count { return $0.value.count < $1.value.count }
                    return $0.value.lastUpdated == $1.value.lastUpdated ? $0.key < $1.key
                        : $0.value.lastUpdated < $1.value.lastUpdated
                })?.key {
                    counts.removeValue(forKey: victim)
                    bigrams?.purge(victim)
                } else if let victim = kept.min(by: {
                    $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value
                })?.key {
                    kept.removeValue(forKey: victim)
                    counts.removeValue(forKey: victim)
                    bigrams?.purge(victim)
                }
            }
        }

        /// Used only to enforce the encoded byte ceiling. Touch statistics are never evicted here.
        mutating func dropOldestLexiconEntries(_ limit: Int) -> Bool {
            guard limit > 0 else { return false }
            // Frequency associations yield to explicit protections under the whole-file ceiling.
            if let count = bigrams?.pairCount, count > 0 {
                for _ in 0..<min(count, limit) { bigrams?.dropWeakest() }
                return true
            }
            enum Entry { case kept(String), counted(String) }
            var entries: [(Date, String, Entry)] = kept.map { ($0.value, "k:" + $0.key, .kept($0.key)) }
            entries += counts.map { ($0.value.lastUpdated, "c:" + $0.key, .counted($0.key)) }
            let oldest = entries.sorted {
                let aKept = $0.1.hasPrefix("k:"), bKept = $1.1.hasPrefix("k:")
                if aKept != bKept { return !aKept }
                return $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0
            }.prefix(limit)
            for entry in oldest {
                switch entry.2 {
                case .kept(let word): kept.removeValue(forKey: word)
                case .counted(let word): counts.removeValue(forKey: word)
                }
            }
            let pairsToDrop = min(rejected.count, limit - oldest.count)
            if pairsToDrop > 0 { rejected.removeFirst(pairsToDrop) }
            return !oldest.isEmpty || pairsToDrop > 0
        }
    }

    nonisolated struct LearnOutcome: Equatable, Sendable {
        var accepted = 0
        var rejected: [TouchLabelRejection: Int] = [:]
    }

    /// A key's posterior predictive: Student-t with `degrees` degrees of freedom whose
    /// standard deviations are `sigmaX`, `sigmaY` and covariance `covarianceXY` (pitches).
    nonisolated struct KeySummary: Equatable, Sendable {
        let letter: String
        let n: Int
        let offsetX: Double
        let offsetY: Double
        let sigmaX: Double
        let sigmaY: Double
        var covarianceXY: Double = 0
        let degrees: Double
    }

    nonisolated struct LayoutSummary: Equatable, Sendable {
        let signature: KeyboardLayoutSignature
        let lastUpdated: Date
        let keys: [KeySummary]
    }

    nonisolated struct Summary: Equatable, Sendable {
        let layouts: [LayoutSummary]
        let keptWords: Int
        let countedWords: Int
        let wordCountTotal: Int
        let rejectedCorrections: Int
        var storedPairs: Int = 0
        var pairByteBound: Int = 0
        var effectiveTouchCount: Int { layouts.flatMap(\.keys).reduce(0) { $0 + $1.n } }
    }

    private(set) var state: State
    var isLearningEnabled: Bool { didSet { cachedLexicon = nil } }

    private var cachedLexicon: PersonalLexiconSnapshot?
    private let now: () -> Date

    init(state: State = State(), isLearningEnabled: Bool = true, now: @escaping () -> Date = Date.init) {
        self.state = state.validated() ?? State()
        self.isLearningEnabled = isLearningEnabled
        self.now = now
    }

    @discardableResult
    func learn(_ labels: [TouchLabel], layout: KeyboardLayout, source: TouchLabelSource,
               accepted: ((TouchLabel) -> Void)? = nil) -> LearnOutcome {
        guard isLearningEnabled else {
            return LearnOutcome(rejected: labels.isEmpty ? [:] : [.learningOff: labels.count])
        }
        var outcome = LearnOutcome()
        // Validate before constructing a signature (rounding a non-finite width would trap).
        let usable = layout.layer == .letters && layout.field == .text
            && layout.width.isFinite && (8...4096).contains(layout.width)
        for label in labels {
            var rejection: TouchLabelRejection?
            if !usable { rejection = .layoutMismatch }
            else if !label.point.x.isFinite || !label.point.y.isFinite { rejection = .nonFinite }
            else if !label.letter.isLetter || String(label.letter) != String(label.letter).lowercased() {
                rejection = .unknownKey
            } else if let key = layout.key(.character(String(label.letter))) {
                let pitchX = key.frame.width + layout.metrics.gap
                let pitchY = key.frame.height + layout.metrics.rowGap
                let x = Double((label.point.x - key.frame.midX) / pitchX)
                let y = Double((label.point.y - key.frame.midY) / pitchY)
                if !x.isFinite || !y.isFinite || pitchX <= 0 || pitchY <= 0 { rejection = .nonFinite }
                // The inclusive one-pitch boundary needs only a rounding tolerance.
                else if hypot(x, y) > 1 + 1e-12 { rejection = .outlier }
                else {
                    let signature = KeyboardLayoutSignature(layout)
                    if state.layouts[signature.id] == nil, state.layouts.count >= 4,
                       let oldest = state.layouts.min(by: {
                           $0.value.lastUpdated == $1.value.lastUpdated ? $0.key < $1.key : $0.value.lastUpdated < $1.value.lastUpdated
                       })?.key { state.layouts.removeValue(forKey: oldest) }
                    var stats = state.layouts[signature.id] ?? LayoutStats(signature: signature, lastUpdated: now())
                    let letter = String(label.letter)
                    var aim = stats.aim(letter)
                    aim.add(x: x, y: y, all: stats.allTapsKey(letter), n: stats.keys[letter]?.n ?? 0)
                    var aims = stats.aims ?? [:]
                    aims[letter] = aim
                    stats.aims = aims
                    stats.keys[letter, default: TouchStats()].update(x: x, y: y)
                    stats.global = stats.global ?? TouchStats()
                    stats.global?.update(x: x, y: y)
                    stats.lastUpdated = now()
                    state.layouts[signature.id] = stats
                    outcome.accepted += 1
                    accepted?(label)
                }
            } else { rejection = .unknownKey }
            if let rejection { outcome.rejected[rejection, default: 0] += 1 }
        }
        return outcome
    }

    @discardableResult
    func learnSpace(_ point: CGPoint, layout: KeyboardLayout) -> LearnOutcome {
        guard isLearningEnabled else { return LearnOutcome(rejected: [.learningOff: 1]) }
        guard layout.layer == .letters, layout.field == .text,
              layout.width.isFinite, (8...4096).contains(layout.width),
              let space = layout.key(.space) else { return LearnOutcome(rejected: [.layoutMismatch: 1]) }
        let x = Double((point.x - space.frame.midX) / (space.frame.width / 2 + layout.metrics.gap))
        let y = Double((point.y - space.frame.midY) / (space.frame.height + layout.metrics.rowGap))
        guard x.isFinite, y.isFinite else { return LearnOutcome(rejected: [.nonFinite: 1]) }
        guard abs(x) <= 1, abs(y) <= 1 else { return LearnOutcome(rejected: [.outlier: 1]) }
        let signature = KeyboardLayoutSignature(layout)
        if state.layouts[signature.id] == nil, state.layouts.count >= 4,
           let oldest = state.layouts.min(by: {
               $0.value.lastUpdated == $1.value.lastUpdated ? $0.key < $1.key : $0.value.lastUpdated < $1.value.lastUpdated
           })?.key { state.layouts.removeValue(forKey: oldest) }
        var stats = state.layouts[signature.id] ?? LayoutStats(signature: signature, lastUpdated: now())
        stats.space = stats.space ?? TouchStats()
        stats.space?.update(x: x, y: y)
        stats.lastUpdated = now()
        state.layouts[signature.id] = stats
        return LearnOutcome(accepted: 1)
    }

    func calibration(for layout: KeyboardLayout) -> SpatialTouchCalibration? {
        guard isLearningEnabled, layout.layer == .letters, layout.field == .text,
              layout.width.isFinite, (8...4096).contains(layout.width),
              let stats = state.layouts[KeyboardLayoutSignature(layout).id] else { return nil }
        let pooledReady = (stats.global?.n ?? 0) > 0
        var keys: [Character: SpatialTouchCalibration.Key] = [:]
        for character in "abcdefghijklmnopqrstuvwxyz" {
            let letter = String(character)
            guard layout.key(.character(letter)) != nil,
                  pooledReady || (stats.keys[letter]?.n ?? 0) > 0 else { continue }
            keys[character] = stats.key(letter)
        }
        return keys.isEmpty ? nil : SpatialTouchCalibration(keys: keys, space: stats.spaceKey)
    }

    // Explicit keeps remain available while learning is off. Counting is a separate trusted event.
    @discardableResult
    func keep(_ word: String) -> Bool {
        let word = PersonalLexiconSnapshot.normalize(word)
        guard State.validWord(word) else { return false }
        state.kept[word] = now()
        state.enforceWordLimit()
        cachedLexicon = nil
        return true
    }

    @discardableResult
    func recordWord(_ word: String) -> Bool {
        let word = PersonalLexiconSnapshot.normalize(word)
        guard isLearningEnabled, State.validWord(word) else { return false }
        // Manual acceptances and independent literal settlements advance the same clock.
        // Merely continuing after automatic output does not count as acceptance.
        ageRejections()
        let count = min(10_000, (state.counts[word]?.count ?? 0) + 1)
        state.counts[word] = WordCount(count: count, lastUpdated: now())
        state.enforceWordLimit()
        cachedLexicon = nil
        return true
    }

    @discardableResult
    func rejectCorrection(typed: String, replacement: String, context: String? = nil) -> Bool {
        var pair = RejectedCorrection(typed: typed, replacement: replacement)
        if let context {
            let words = context.split(separator: " ").map(String.init)
            guard (1...2).contains(words.count), words.allSatisfy(State.validWord),
                  words.joined(separator: " ") == context else { return false }
        }
        pair.context = context
        pair.remaining = 256
        pair.globalRemaining = 64
        guard State.validRejectedWord(pair.typed), State.validRejectedWord(pair.replacement) else { return false }
        if let index = state.rejected.firstIndex(of: pair) {
            // Do not silently weaken a migrated permanent protection.
            if state.rejected[index].remaining != nil { state.rejected[index] = pair }
            cachedLexicon = nil
        } else {
            state.rejected.append(pair)
            if state.rejected.count > 512 { state.rejected.removeFirst() }
            cachedLexicon = nil
        }
        return true
    }

    /// Only independently typed, settled literals can confirm an undone spelling.
    @discardableResult
    func confirmLiteral(_ word: String) -> Bool {
        let word = PersonalLexiconSnapshot.normalize(word)
        guard isLearningEnabled, state.kept[word] == nil,
              state.rejected.contains(where: { $0.typed == word }) else { return false }
        return keep(word)
    }

    /// One bounded pass (≤512 records) per trusted word event; no dates or timers.
    private func ageRejections() {
        state.rejected = state.rejected.compactMap { saved in
            var pair = saved
            if let remaining = pair.remaining {
                guard remaining > 1 else { return nil }
                pair.remaining = remaining - 1
                pair.globalRemaining = max(0, (pair.globalRemaining ?? 0) - 1)
            }
            return pair
        }
    }

    func recordPair(_ word: String, after previous: String, earlier: String? = nil) {
        guard isLearningEnabled else { return }
        if let earlier { state.bigrams?.record(word, after: previous, earlier: earlier) }
        else { state.bigrams?.record(word, after: previous) }
    }

    /// Immediate keep revert only: the word's independently learned pairs stay.
    /// Explicit deletion in Manage learned words purges pairs in the store instead.
    func forgetKeep(_ word: String) {
        state.kept.removeValue(forKey: PersonalLexiconSnapshot.normalize(word))
        cachedLexicon = nil
    }

    func forgetRejection(_ pair: RejectedCorrection) {
        state.rejected.removeAll { $0 == pair }
        cachedLexicon = nil
    }

    /// Explicit count deletion also purges every pair naming the word.
    func forgetCount(_ word: String) {
        state.bigrams?.purge(word)
        state.counts.removeValue(forKey: PersonalLexiconSnapshot.normalize(word))
        cachedLexicon = nil
    }

    var lexicon: PersonalLexiconSnapshot {
        if let cachedLexicon { return cachedLexicon }
        let snapshot = PersonalLexiconSnapshot(kept: Set(state.kept.keys),
            counts: isLearningEnabled ? state.counts.mapValues(\.count) : [:], rejected: Set(state.rejected))
        cachedLexicon = snapshot
        return snapshot
    }

    var summary: Summary { Self.summarize(state) }

    static func summarize(_ state: State) -> Summary {
        let layouts = state.layouts.values.sorted { $0.signature.id < $1.signature.id }.map { layout in
            LayoutSummary(signature: layout.signature, lastUpdated: layout.lastUpdated,
                keys: layout.keys.sorted { $0.key < $1.key }.map { letter, stats in
                    let key = layout.key(letter)
                    let variance = key.degrees / (key.degrees - 2)
                    return KeySummary(letter: letter, n: stats.n, offsetX: key.offsetX, offsetY: key.offsetY,
                                      sigmaX: key.sigmaX * sqrt(variance), sigmaY: key.sigmaY * sqrt(variance),
                                      covarianceXY: key.covarianceXY * variance, degrees: key.degrees)
                })
        }
        return Summary(layouts: layouts, keptWords: state.kept.count, countedWords: state.counts.count,
            wordCountTotal: state.counts.values.reduce(0) { $0 + $1.count }, rejectedCorrections: state.rejected.count,
            storedPairs: state.bigrams?.pairCount ?? 0, pairByteBound: state.bigrams?.encodedByteBound ?? 0)
    }

    /// Mutates RAM too, so the same invalid aggregate is reported only once.
    func prepareForSave() -> Bool {
        guard state.validated() == nil else { return false }
        return state.discardInvalidTouchStats()
    }

    func reset() { state = State(); cachedLexicon = nil }
}
