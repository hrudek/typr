import Foundation
import CoreGraphics

/// Mutable search memos have exactly one serial owner: the boundary facade OR the suggestion actor.
/// Resources and input snapshots are immutable Sendable values; no checker or learning owner enters here.
// Search/trail ideas previously translated from AVGVSTVS96/iikb Decoder.swift (MIT),
// 08df5aa1e698d8587b6dcaef53f5e555ba1fac2a; extracted from Typr unchanged for P1.
// P7 adds frozen full-covariance/aim densities (TouchModel.swift ideas at
// 09a2e9cdfbe851adff6c4646333c0a3f74ba8765, MIT © 2026 Bassim Shahidy) and
// Typr-specific admissible length/next-child bounds; both serial owners use this core.
nonisolated final class SpatialWordRanking {
    typealias Language = SpatialWordDecoder.Language
    typealias Edit = SpatialWordDecoder.Edit
    typealias Candidate = SpatialWordDecoder.Candidate
    typealias Result = SpatialWordDecoder.Result
    typealias Outcome = SpatialWordDecoder.Outcome
    /// Element payload ceiling, not Swift allocation size or process RSS. Dictionary/array
    /// headers, capacity rounding and allocator overhead must be measured on a real iPhone.
    static var maximumArenaPayloadBytes: Int {
        maxGenerated * (MemoryLayout<State>.stride + MemoryLayout<Trail>.stride
                        + MemoryLayout<Int>.stride + 2 * MemoryLayout<Int>.stride)
    }

    static let searchBudget = SpatialWordDecoder.searchBudget
    static let maxLetters = SpatialWordDecoder.maxLetters
    static let maxGenerated = SpatialWordDecoder.maxGenerated
    static let editSuggestionLimit = SpatialWordDecoder.editSuggestionLimit
    /// Full P(taps | word) × P(word), as iikb's decoder scores words.
    private static let priorWeight = 1.0
    private static let editPenalty = SpatialWordDecoder.editLogProbability
    private static let transliterationPenalty = log(0.5)
    private static let boundSlack = 1e-10
    private static let corpusMemoLimit = 4_096
    private let lexicons: [Language: SpatialWordLexicon]
    private var personalScan: PersonalLexiconSnapshot.ScanList?
    private var absentPersonalWords: [Set<Language>: [PersonalLexiconSnapshot.ScanList.Entry]] = [:]
    private var corpusAbsent: [Set<Language>: [String: Bool]] = [:]

    // Internal baseline seam for performance/oracle tests, not a product switch.
    // true retains the pre-aim per-pair density work and suffix-only search bound.
    private let usesLegacySearch: Bool

    init(lexicons: [Language: SpatialWordLexicon], usesLegacySearch: Bool = false) {
        self.lexicons = lexicons
        self.usesLegacySearch = usesLegacySearch
    }

    private func lexicon(_ language: Language) -> SpatialWordLexicon? { lexicons[language] }

    /// The filtered entries track snapshot identity (including changed bonuses). Corpus absence
    /// depends only on installed resources and the language set, so its bounded RAM memo survives
    /// count changes. At most three nonempty language sets; installing resources clears both caches.
    private func personalWords(_ personal: PersonalLexiconSnapshot, languages: Set<Language>,
                               sources: [(Language, SpatialWordLexicon)]) -> [PersonalLexiconSnapshot.ScanList.Entry] {
        if personalScan !== personal.scan {
            personalScan = personal.scan
            absentPersonalWords.removeAll()
        }
        if let cached = absentPersonalWords[languages] { return cached }
        var memo = corpusAbsent.removeValue(forKey: languages) ?? [:]
        let words = personal.scan.entries.filter { entry in
            if let absent = memo[entry.word] { return absent }
            let absent = sources.allSatisfy { $0.1.logPrior(for: entry.word) == nil }
            if memo.count >= Self.corpusMemoLimit { memo.removeAll(keepingCapacity: true) }
            memo[entry.word] = absent
            return absent
        }
        corpusAbsent[languages] = memo
        absentPersonalWords[languages] = words
        return words
    }

    private struct Trail {
        let parent: Int
        let label: Int
        let tap: Int?
    }
    private struct State {
        let source: Int
        let node: Int
        let tap: Int
        let depth: Int
        let trail: Int
        let spatial: Double
        let penalty: Double
        let edit: Edit
        let bound: Double
    }
    /// Heap entries and parent trails are integer indices; no per-state strings or arrays.
    private struct Frontier {
        var states: [State] = []
        var trails: [Trail] = []
        var heap: [Int] = []
        var best: [Int: Double] = [:]
        var capped = false

        private func key(_ state: State) -> Int {
            // At most two sources, 33 tap positions and two edit-used states.
            ((state.node * 33 + state.tap) * 2 + (state.edit == .none ? 0 : 1)) * 2 + state.source
        }
        func isDominated(_ state: State) -> Bool {
            state.spatial + state.penalty < (best[key(state)] ?? -.infinity)
        }

        func precedes(_ a: Int, _ b: Int) -> Bool {
            states[a].bound == states[b].bound ? a < b : states[a].bound > states[b].bound
        }
        mutating func push(_ state: State, letters: [(Int, Int?)], essential: Bool = true) {
            // A trie node fixes the spelling; future scores depend only on the tap
            // position and edit-used flag. Max-path scoring can discard worse or
            // equal readings, retaining the first deterministic alignment on ties.
            let key = key(state)
            let score = state.spatial + state.penalty
            guard score > (best[key] ?? -.infinity) else { return }
            // Cap both arenas. A transposition needs two spelling records. States below
            // the exact-search threshold only serve best-effort edit suggestions: they may
            // use at most half of each arena and their loss never voids `complete`.
            let limit = essential ? SpatialWordDecoder.maxGenerated : SpatialWordDecoder.maxGenerated / 2
            guard states.count < limit, trails.count + letters.count <= limit else {
                if essential { capped = true }
                return
            }
            best[key] = score
            var trail = state.trail
            for (label, tap) in letters {
                trails.append(Trail(parent: trail, label: label, tap: tap))
                trail = trails.count - 1
            }
            let index = states.count
            states.append(State(source: state.source, node: state.node, tap: state.tap, depth: state.depth,
                                trail: trail, spatial: state.spatial, penalty: state.penalty,
                                edit: state.edit, bound: state.bound))
            heap.append(index)
            var child = heap.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard precedes(heap[child], heap[parent]) else { break }
                heap.swapAt(child, parent)
                child = parent
            }
        }
        mutating func pop() -> State? {
            guard let first = heap.first, let last = heap.popLast() else { return nil }
            if !heap.isEmpty {
                heap[0] = last
                var parent = 0
                while parent * 2 + 1 < heap.count {
                    var child = parent * 2 + 1
                    if child + 1 < heap.count, precedes(heap[child + 1], heap[child]) { child += 1 }
                    guard precedes(heap[child], heap[parent]) else { break }
                    heap.swapAt(child, parent)
                    parent = child
                }
            }
            return states[first]
        }
        func spelling(_ trail: Int) -> (String, [Int?]) {
            var letters: [Character] = []
            var alignment: [Int?] = []
            var index = trail
            while index >= 0 {
                let entry = trails[index]
                letters.append(SpatialWordLexicon.alphabet[entry.label])
                alignment.append(entry.tap)
                index = entry.parent
            }
            return (String(letters.reversed()), Array(alignment.reversed()))
        }
    }

    func decode(_ word: KeyboardTouchWord, languages: Set<Language>,
                budget: Int = SpatialWordDecoder.searchBudget,
                calibration: SpatialTouchCalibration? = nil,
                personal: PersonalLexiconSnapshot = .empty, allowsEdits: Bool = true,
                context: KeyboardContextModel.WordContext? = nil, variants: [String] = []) -> Result? {
        if case .result(let result) = decodeDetailed(word, languages: languages, budget: budget,
                                                    calibration: calibration, personal: personal,
                                                    allowsEdits: allowsEdits, context: context,
                                                    variants: variants) { return result }
        return nil
    }

    /// Every reading is scored by one contract: touch log likelihood, edit penalties, lexical log
    /// prior, personal bonus and the sentence-context lift of `context`; the literal (also an OOV
    /// literal, at the floor prior) is scored the same way. `variants` are other spellings of the
    /// literal's own letters (apostrophes, umlaut digraphs) or its y/z swaps: same taps, one `log .5`
    /// per transliteration step or swap, priced by the word lists or else the context packs (a swap
    /// only by the German word list). An extra tap is, with even odds, a second touch on the next
    /// letter's key (the last letter's after the word) or a stray uniform over the keyboard (iikb's
    /// stray density), in key-pitch units.
    func decodeDetailed(_ word: KeyboardTouchWord, languages: Set<Language>,
                        budget: Int = SpatialWordDecoder.searchBudget,
                        calibration: SpatialTouchCalibration? = nil,
                        personal: PersonalLexiconSnapshot = .empty, allowsEdits: Bool = true,
                        context: KeyboardContextModel.WordContext? = nil, variants: [String] = []) -> Outcome {
        let literal = word.text.lowercased()
        let count = word.samples.count
        guard (SpatialWordDecoder.minLetters...Self.maxLetters).contains(count), literal.count == count,
              word.layout.layer == .letters, word.layout.field == .text, !languages.isEmpty else {
            return .unavailable(.evidence)
        }
        // Never partially decode a bilingual request with missing data.
        var sources: [(Language, SpatialWordLexicon)] = []
        for language in Language.allCases where languages.contains(language) {
            guard let source = lexicon(language) else { return .unavailable(.resource) }
            sources.append((language, source))
        }
        guard let emissions = KeyboardLetterMap.emissions(for: word, calibration: calibration,
                                                          prepared: !usesLegacySearch) else {
            return .unavailable(.evidence)
        }
        let likelihoods = emissions.likelihoods
        let bestScores = emissions.best
        let literalSpatial = emissions.literal
        let rankedLabels = emissions.rankedLabels
        let finiteLabelMasks = emissions.finiteLabelMasks
        let floorPrior = sources.map { log(1 / $0.1.total) }.max() ?? 0
        let literalInLexicon = sources.contains { $0.1.logPrior(for: literal) != nil }
        let literalPrior = sources.map { _, source in
            source.logPrior(for: literal) ?? log(1 / source.total)
        }.max() ?? 0
        func lift(_ word: String) -> Double { context?.logLift(word) ?? 0 }
        let maxLift = context?.maximumLift ?? 0
        let literalScore = literalSpatial + Self.priorWeight * literalPrior + personal.bonus(for: literal) + lift(literal)
        guard let stray = Self.strayLogDensity(word.layout) else { return .unavailable(.evidence) }
        var suffix = [Double](repeating: 0, count: count + 1)
        for index in (0..<count).reversed() { suffix[index] = suffix[index + 1] + max(bestScores[index], stray) }
        var found: [String: Candidate] = [:]
        var threshold = literalScore
        // Suggestion-only structural retrieval below an absent literal, down to one edit
        // penalty under it: "would beat the literal if the edit were free". Explored only
        // after the exact above-literal search is proven, from the same pop budget.
        let suggestsEdits = allowsEdits && !literalInLexicon
        var below: [String: Candidate] = [:]
        var belowThreshold = suggestsEdits ? literalScore + Self.editPenalty : Double.infinity
        func retainBelow(_ candidate: Candidate) {
            guard suggestsEdits, candidate.edit != .none, candidate.score >= belowThreshold,
                  found[candidate.word] == nil else { return }
            if let previous = below[candidate.word], !Self.precedes(candidate, previous) { return }
            below[candidate.word] = candidate
            if below.count > Self.editSuggestionLimit, let worst = below.values.sorted(by: Self.precedes).last {
                below.removeValue(forKey: worst.word)
            }
            if below.count == Self.editSuggestionLimit {
                belowThreshold = max(belowThreshold, (below.values.map(\.score).min() ?? belowThreshold) - Self.scoreQuantum)
            }
        }
        func retain(_ candidate: Candidate) {
            guard candidate.word != literal else { return }
            // A tie with the literal (within rounding) keeps the literal: with full prior weight a
            // stray tap's density can make a word score exactly as the literal does.
            guard candidate.score > literalScore + Self.scoreQuantum else { retainBelow(candidate); return }
            below.removeValue(forKey: candidate.word)
            if let previous = found[candidate.word], !Self.precedes(candidate, previous) { return }
            found[candidate.word] = candidate
            if found.count > 8, let worst = found.values.sorted(by: Self.precedes).last {
                found.removeValue(forKey: worst.word)
            }
            if found.count == 8 { threshold = (found.values.map(\.score).min() ?? literalScore) - Self.scoreQuantum }
        }
        // Personal scan is bounded independently of trie states; only normalized alphabet words
        // absent from ALL selected corpora participate. A one-edit fixed-word DP scores them.
        let personalComplete = personal.scan.complete
        for entry in personalWords(personal, languages: languages, sources: sources) {
            let labels = entry.labels
            guard abs(labels.count - count) <= (allowsEdits ? 1 : 0) else { continue }
            // First letter can use tap 0, tap 1 (extra/transposition), or be missing.
            if !allowsEdits && !likelihoods[0][labels[0]].isFinite { continue }
            if allowsEdits && !likelihoods[0][labels[0]].isFinite && !likelihoods[1][labels[0]].isFinite
                && (labels.count < 2 || !likelihoods[0][labels[1]].isFinite) { continue }
            guard let reading = Self.reading(labels: labels, likelihoods: likelihoods,
                                            stray: stray, allowsEdits: allowsEdits) else { continue }
            retain(Candidate(word: entry.word, language: nil,
                             score: reading.spatial + reading.penalty + Self.priorWeight * floorPrior + entry.bonus
                                + lift(entry.word),
                             spatialScore: reading.spatial, edit: reading.edit, alignment: reading.alignment))
        }
        for variant in variants {
            guard let spelling = Self.transliteration(of: variant), let swaps = Self.germanKeySwaps(spelling.letters, literal),
                  variant.lowercased() != literal else { continue }
            let key = variant.lowercased()
            let lexical = sources.filter { swaps == 0 || $0.0 == .german }
                .compactMap { language, source in source.logPrior(for: key).map { (language, $0) } }
                .max { $0.1 < $1.1 }
            if swaps > 0 && lexical == nil { continue }
            let prior = lexical?.1 ?? context?.logUnigram(variant) ?? floorPrior
            retain(Candidate(word: variant, language: lexical?.0,
                             score: literalSpatial + Double(spelling.steps + swaps) * Self.transliterationPenalty
                                + Self.priorWeight * prior + personal.bonus(for: key) + lift(variant),
                             spatialScore: literalSpatial, edit: .none, alignment: [],
                             isVariant: true))
        }
        var frontier = Frontier()
        // A subtree's best terminal prior and the snapshot's largest bonus tighten
        // the bound without changing the objective. Remaining tap densities include
        // stray taps and may be POSITIVE; future edit penalties are nonpositive.
        let maxBonus = personal.scan.maxBonus
        for source in sources.indices {
            let bound = suffix[0] + Self.priorWeight * sources[source].1.bestLogPrior(at: 0) + maxBonus + maxLift
                + Self.boundSlack
            frontier.push(State(source: source, node: 0, tap: 0, depth: 0, trail: -1,
                                spatial: 0, penalty: 0, edit: .none, bound: bound),
                          letters: [], essential: bound >= threshold)
        }
        var visits = 0
        var proven = false
        while let first = frontier.heap.first {
            // Bounds never increase along a path, so once the best frontier bound drops
            // below `threshold` the above-literal top eight are final (proof); the loop
            // only continues for best-effort below-literal edit suggestions.
            let top = frontier.states[first].bound
            if top < threshold { proven = true }
            if top < min(threshold, belowThreshold) { break }
            guard visits < max(0, min(budget, Self.searchBudget)), !frontier.capped else { break }
            guard let state = frontier.pop() else { break }
            visits += 1
            if frontier.isDominated(state) { continue }
            // After the proof only edit suggestions remain; an unedited path must still pay one penalty.
            if proven, state.edit == .none, state.bound + Self.editPenalty < belowThreshold { continue }
            let (language, source) = sources[state.source]
            guard let node = source.node(state.node) else { return .unavailable(.resource) }
            if state.tap == count, node.count > 0 {
                let (spelling, alignment) = frontier.spelling(state.trail)
                retain(Candidate(word: spelling, language: language,
                                 score: state.spatial + state.penalty + Self.priorWeight * log(node.count / source.total)
                                    + personal.bonus(for: spelling) + lift(spelling),
                                 spatialScore: state.spatial, edit: state.edit, alignment: alignment))
            }
            let canEdit = allowsEdits && state.edit == .none
            func enqueue(node: Int, tap: Int, letters: [(Int, Int?)], spatial: Double, edit: Edit) {
                let depth = state.depth + letters.count
                guard depth <= Self.maxLetters else { return }
                let penalty = edit == .none ? 0 : Self.editPenalty
                let bound: Double
                if usesLegacySearch {
                    // Original expression retained for same-run baseline timing/work.
                    bound = spatial + penalty + suffix[tap] + Self.priorWeight * source.bestLogPrior(at: node)
                        + maxBonus + maxLift + Self.boundSlack
                } else {
                    guard source.canFinish(at: node, remaining: count - tap,
                                           editAvailable: allowsEdits && edit == .none) else { return }
                    let fixed = spatial + penalty + Self.priorWeight * source.bestLogPrior(at: node)
                        + maxBonus + maxLift + Self.boundSlack
                    let loose = fixed + suffix[tap]
                    // Most proposals already fail the cheap bound; do not look ahead on them.
                    guard loose >= threshold || loose + (edit == .none ? Self.editPenalty : 0) >= belowThreshold else { return }
                    // Once the edit is spent (or disabled), the next tap MUST match a
                    // child. Unedited paths retain the old bound because they may skip
                    // or swap, and the below-literal proof assumes that suffix-only bound.
                    // Later terms remain optimistic maxima, including positive densities.
                    let remaining: Double
                    if (edit != .none || !allowsEdits), tap < count {
                        remaining = source.bestNextDensity(at: node, scores: likelihoods[tap],
                                                           rankedLabels: rankedLabels[tap], finiteMask: finiteLabelMasks[tap]) + suffix[tap + 1]
                    } else { remaining = suffix[tap] }
                    bound = fixed + remaining
                }
                let essential = bound >= threshold
                guard essential || bound + (edit == .none ? Self.editPenalty : 0) >= belowThreshold else { return }
                frontier.push(State(source: state.source, node: node, tap: tap, depth: depth,
                                    trail: state.trail, spatial: spatial, penalty: penalty,
                                    edit: edit, bound: bound), letters: letters, essential: essential)
            }
            if canEdit, state.tap == count - 1 {
                let near = state.depth > 0 ? likelihoods[state.tap][node.label] : -.infinity
                enqueue(node: state.node, tap: count, letters: [],
                        spatial: state.spatial + Self.extraTap(stray, near: near), edit: .extraTap(at: state.tap))
            }
            guard state.depth < Self.maxLetters else { continue }
            var labels: Set<Int> = []
            for child in node.children {
                guard let item = source.node(child), labels.insert(item.label).inserted else { return .unavailable(.resource) }
                if state.tap < count {
                    let spatial = likelihoods[state.tap][item.label]
                    if spatial.isFinite {
                        enqueue(node: child, tap: state.tap + 1, letters: [(item.label, state.tap)],
                                spatial: state.spatial + spatial, edit: state.edit)
                    }
                }
                if canEdit {
                    enqueue(node: child, tap: state.tap, letters: [(item.label, nil)],
                            spatial: state.spatial, edit: .missingLetter(at: state.depth))
                }
                if canEdit, state.tap + 1 < count {
                    enqueue(node: child, tap: state.tap + 2, letters: [(item.label, state.tap + 1)],
                            spatial: state.spatial + Self.extraTap(stray, near: likelihoods[state.tap][item.label])
                                + likelihoods[state.tap + 1][item.label],
                            edit: .extraTap(at: state.tap))
                }
                if canEdit, state.tap + 1 < count, state.depth + 2 <= Self.maxLetters,
                   likelihoods[state.tap + 1][item.label].isFinite,
                   usesLegacySearch || state.spatial + likelihoods[state.tap + 1][item.label] + bestScores[state.tap]
                    + suffix[state.tap + 2] + Self.editPenalty + Self.priorWeight * source.bestLogPrior(at: child)
                    + maxBonus + maxLift + Self.boundSlack >= min(threshold, belowThreshold) {
                    var grandLabels: Set<Int> = []
                    for grandchild in item.children {
                        guard let next = source.node(grandchild), grandLabels.insert(next.label).inserted else {
                            return .unavailable(.resource)
                        }
                        guard next.label != item.label, likelihoods[state.tap][next.label].isFinite else { continue }
                        enqueue(node: grandchild, tap: state.tap + 2,
                                letters: [(item.label, state.tap + 1), (next.label, state.tap)],
                                spatial: state.spatial + likelihoods[state.tap + 1][item.label] + likelihoods[state.tap][next.label],
                                edit: .transposition(at: state.depth))
                    }
                }
            }
        }
        // Exact top-eight DISTINCT spellings above literal under frozen max-path scoring
        // when complete: all eligible personal words scanned and frontier exhausted/bounded.
        // Any essential arena truncation conservatively makes the proof incomplete.
        return .result(Result(candidates: found.values.sorted(by: Self.precedes), literalScore: literalScore,
                              literalSpatialScore: literalSpatial, literalInLexicon: literalInLexicon,
                              complete: personalComplete && !frontier.capped && (proven || frontier.heap.isEmpty),
                              visits: visits, generated: frontier.states.count,
                              editSuggestions: below.values.filter { found[$0.word] == nil }.sorted(by: Self.precedes)))
    }

    static func strayLogDensity(_ layout: KeyboardLayout) -> Double? {
        guard let key = layout.key(.character("a"))?.frame else { return nil }
        let bounds = layout.keys.reduce(CGRect.null) { $0.union($1.frame) }
        let pitch = Double((key.width + layout.metrics.gap) * (key.height + layout.metrics.rowGap))
        let area = Double(bounds.width * bounds.height) / pitch
        return area.isFinite && area > 0 ? -log(area) : nil
    }

    /// Positions where `letters` has y and `literal` z or the reverse (a QWERTZ habit on QWERTY);
    /// `nil` when they differ otherwise.
    private static func germanKeySwaps(_ letters: String, _ literal: String) -> Int? {
        guard letters.count == literal.count else { return nil }
        var swaps = 0
        for (a, b) in zip(letters, literal) where a != b {
            guard Set([a, b]) == ["y", "z"] else { return nil }
            swaps += 1
        }
        return swaps
    }

    private static func extraTap(_ stray: Double, near: Double) -> Double {
        let top = max(stray, near)
        return top + log(0.5 * exp(stray - top) + 0.5 * exp(near - top))
    }

    static func transliteration(of spelling: String) -> (letters: String, steps: Int)? {
        var letters = "", steps = 0
        for character in spelling.lowercased() {
            switch character {
            case "'", "’": steps += 1
            case "ä": letters += "ae"; steps += 1
            case "ö": letters += "oe"; steps += 1
            case "ü": letters += "ue"; steps += 1
            case "ß": letters += "ss"; steps += 1
            case "a"..."z": letters.append(character)
            default: return nil
            }
        }
        return (letters, steps)
    }

    private struct Reading {
        let spatial: Double
        let penalty: Double
        let edit: Edit
        let alignment: [Int?]
    }

    /// Fixed-word one-edit alignment DP, expanded into its O(n) possible edit locations.
    /// Spatial substitutions remain allowed at every aligned position, as in the trie.
    private static func reading(labels: [Int], likelihoods: [[Double]], stray: Double,
                                allowsEdits: Bool) -> Reading? {
        let n = labels.count
        let m = likelihoods.count
        var best: Reading?
        func consider(_ alignment: [Int?], _ edit: Edit, extra: Int? = nil) {
            var spatial = extra.map { extraTap(stray, near: likelihoods[$0][labels[min($0, n - 1)]]) } ?? 0
            for index in labels.indices {
                if let tap = alignment[index] { spatial += likelihoods[tap][labels[index]] }
            }
            guard spatial.isFinite else { return }
            let penalty = edit == .none ? 0 : Self.editPenalty
            if let current = best, current.spatial + current.penalty >= spatial + penalty { return }
            best = Reading(spatial: spatial, penalty: penalty, edit: edit, alignment: alignment)
        }
        if n == m {
            consider((0..<n).map { Optional($0) }, .none)
            if allowsEdits {
                for index in 0..<(n - 1) where labels[index] != labels[index + 1] {
                    var alignment = (0..<n).map { Optional($0) }
                    alignment.swapAt(index, index + 1)
                    consider(alignment, .transposition(at: index))
                }
            }
        } else if allowsEdits, n == m + 1 {
            for missing in 0..<n {
                consider((0..<n).map { $0 == missing ? nil : ($0 < missing ? $0 : $0 - 1) }, .missingLetter(at: missing))
            }
        } else if allowsEdits, m == n + 1 {
            for extra in 0..<m {
                consider((0..<n).map { $0 < extra ? $0 : $0 + 1 }, .extraTap(at: extra), extra: extra)
            }
        }
        return best
    }

    /// Conservative text-only learning labels: at most one unit-cost spelling edit.
    /// Repeated-letter optimal alignments are merged, dropping only ambiguous positions;
    /// a transposed pair is always dropped. No spatial evidence is guessed here.
    static func align(word: String, taps: [Character]) -> [Int?]? {
        let letters = Array(word.lowercased())
        let typed = taps.map { Character(String($0).lowercased()) }
        let n = letters.count
        let m = typed.count
        guard n > 0, n <= maxLetters, m > 0, m <= maxLetters, abs(n - m) <= 1 else { return nil }
        var readings: [[Int?]] = []
        if n == m {
            let mismatches = (0..<n).filter { letters[$0] != typed[$0] }
            if mismatches.count <= 1 { return (0..<n).map { $0 } }
            if mismatches.count == 2, let first = mismatches.first, mismatches[1] == first + 1,
               letters[first] == typed[first + 1], letters[first + 1] == typed[first] {
                return (0..<n).map { $0 == first || $0 == first + 1 ? nil : $0 }
            }
            return nil
        }
        if n == m + 1 {
            for missing in 0..<n {
                let alignment: [Int?] = (0..<n).map { $0 == missing ? nil : ($0 < missing ? $0 : $0 - 1) }
                if letters.indices.allSatisfy({ i in alignment[i].map { letters[i] == typed[$0] } ?? true }) {
                    readings.append(alignment)
                }
            }
        } else {
            for extra in 0..<m {
                let alignment = (0..<n).map { Optional($0 < extra ? $0 : $0 + 1) }
                if letters.indices.allSatisfy({ i in alignment[i].map { letters[i] == typed[$0] } ?? false }) {
                    readings.append(alignment)
                }
            }
        }
        guard var result = readings.first else { return nil }
        for reading in readings.dropFirst() {
            for index in result.indices where result[index] != reading[index] { result[index] = nil }
        }
        return result
    }

    // Integer-sized score buckets give a transitive ordering (unlike pairwise epsilon
    // comparisons). Sub-nanolog rounding from key centres/libm/sum regrouping is a tie.
    private static let scoreQuantum = 1e-9
    private static func precedes(_ a: Candidate, _ b: Candidate) -> Bool {
        let aScore = (a.score / scoreQuantum).rounded()
        let bScore = (b.score / scoreQuantum).rounded()
        if aScore != bScore { return aScore > bScore }
        if a.word != b.word { return a.word < b.word }
        return (a.language?.rawValue ?? "") < (b.language?.rawValue ?? "")
    }
}
