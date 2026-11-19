import Foundation
import CoreGraphics

/// Static, bundled word counts. The TSW1 format is Typr's own, not iikb's ASCII HXL1 format.
/// See WordData/README.md and THIRD_PARTY_NOTICES.md for the separately licensed word data.
nonisolated struct SpatialWordLexicon: Sendable {
    static let alphabet = Array("abcdefghijklmnopqrstuvwxyzäöüß")
    static let maxBytes = 5_000_000
    let data: Data
    let nodeCount: Int
    let total: Double
    private var subtreeCounts: [UInt32] = []
    /// Exact terminal mass for bounded next-letter lookup; built off the insertion path.
    private var continuationMass: [UInt64] = []
    /// Min/max letters to a terminal, packed in two saturated UInt8 lanes.
    private var suffixLengths: [UInt16] = []
    /// Immediate child alphabet, derived once with the validated subtree index.
    private var childLabels: [UInt32] = []

    init?(data: Data) {
        guard data.count >= 36, data.count <= Self.maxBytes,
              Array(data.prefix(4)) == Array("TSW1".utf8) else { return nil }
        self.data = data
        let nodes = Int(Self.uint32(data, 4))
        let words = Int(Self.uint32(data, 8))
        let total = Double(Self.uint32(data, 16)) + Double(Self.uint32(data, 20)) * 4_294_967_296
        guard nodes > 0, nodes <= 400_000, data.count == 24 + nodes * 12,
              words > 0, words <= 50_000, total >= Double(words), total <= 1_000_000_000_000,
              Self.uint32(data, 12) == 0 else { return nil }
        self.nodeCount = nodes
        self.total = total
        guard node(0)?.label == 255 else { return nil }
        // TSW1 stores terminal counts, not subtree masses. Derive a max-count index
        // once, in reverse (edges are forward-only). Also establish the unique
        // spelling per node required by max-path state dominance below.
        subtreeCounts = [UInt32](repeating: 0, count: nodes)
        continuationMass = [UInt64](repeating: 0, count: nodes)
        suffixLengths = [UInt16](repeating: 255, count: nodes)
        childLabels = [UInt32](repeating: 0, count: nodes)
        var parents = [Bool](repeating: false, count: nodes)
        for index in (0..<nodes).reversed() {
            guard let record = node(index) else { return nil }
            var maximum = UInt32(record.count)
            var mass = UInt64(record.count)
            var minimumLength = record.count > 0 ? 0 : 255, maximumLength = 0
            var labels: UInt32 = 0
            for child in record.children {
                // Forward children were already validated in this reverse pass.
                let label = Int(data[data.startIndex + 24 + child * 12])
                let bit = UInt32(1) << label
                guard !parents[child], labels & bit == 0 else { return nil }
                labels |= bit
                parents[child] = true
                maximum = max(maximum, subtreeCounts[child])
                mass += continuationMass[child]
                if subtreeCounts[child] > 0 {
                    minimumLength = min(minimumLength, min(255, Int(suffixLengths[child] & 255) + 1))
                    maximumLength = max(maximumLength, min(255, Int(suffixLengths[child] >> 8) + 1))
                }
            }
            continuationMass[index] = mass
            subtreeCounts[index] = maximum
            childLabels[index] = labels
            suffixLengths[index] = UInt16(minimumLength | (maximumLength << 8))
        }
        guard parents.dropFirst().allSatisfy({ $0 }) else { return nil }
    }

    /// Upper bound on the terminal prior of any descendant (including this node).
    func bestLogPrior(at index: Int) -> Double {
        log(Double(subtreeCounts[index]) / total)
    }

    /// A length-incompatible subtree cannot finish, regardless of touch likelihood.
    /// Saturation at 255 is conservative for the decoder's <=32 remaining taps.
    func canFinish(at index: Int, remaining: Int, editAvailable: Bool) -> Bool {
        let span = suffixLengths[index], allowance = editAvailable ? 1 : 0
        return Int(span & 255) <= remaining + allowance && Int(span >> 8) >= remaining - allowance
    }

    /// Best possible NEXT aligned density. With an edit already spent, the next
    /// tap must name an immediate child. Works on frozen full-covariance scores,
    /// not an axis-aligned geometric approximation. No allocation or trie reads.
    func bestNextDensity(at index: Int, scores: [Double], rankedLabels: [Int], finiteMask: UInt32) -> Double {
        let mask = childLabels[index] & finiteMask
        guard mask != 0 else { return -.infinity }
        // Tap scores have few finite neighbours. Their order is frozen once per tap;
        // usually the first or second one is a child, instead of scanning up to 30 edges.
        for label in rankedLabels where mask & (UInt32(1) << label) != 0 { return scores[label] }
        return -.infinity
    }

    struct Node {
        let label: Int
        let children: Range<Int>
        let count: Double
    }

    /// Bounds-check every visited record, including forward-only edges. No unsafe pointer loads.
    func node(_ index: Int) -> Node? {
        guard index >= 0, index < nodeCount else { return nil }
        let offset = 24 + index * 12
        let label = Int(data[data.startIndex + offset])
        let children = Int(data[data.startIndex + offset + 1])
        let first = Int(Self.uint32(data, offset + 4))
        let count = Double(Self.uint32(data, offset + 8))
        guard (index == 0 ? label == 255 : label < Self.alphabet.count),
              children <= Self.alphabet.count, count <= total,
              data[data.startIndex + offset + 2] == 0, data[data.startIndex + offset + 3] == 0,
              children == 0 ? first == 0 : (first > index && first + children <= nodeCount) else { return nil }
        return Node(label: label, children: first..<(first + children), count: count)
    }

    func logPrior(for word: String) -> Double? {
        var index = 0
        for letter in word {
            guard let label = Self.alphabet.firstIndex(of: letter), let parent = node(index) else { return nil }
            var next: Int?
            for child in parent.children {
                guard let item = node(child) else { return nil }
                if item.label == label { next = child; break }
            }
            guard let next else { return nil }
            index = next
        }
        guard let count = node(index)?.count, count > 0 else { return nil }
        return log(count / total)
    }

    var continuationPayloadBytes: Int { continuationMass.count * MemoryLayout<UInt64>.stride }

    /// At most 32 × 30 edge inspections plus 30 children, never a subtree scan.
    /// Mass includes terminals of every descendant, not the decoder's maximum count.
    func nextLetterMass(after prefix: String) -> [Double] {
        var result = [Double](repeating: 0, count: Self.alphabet.count)
        guard prefix.utf8.count <= 256, prefix.count <= 31 else { return result }
        var index = 0
        for letter in prefix {
            guard let label = Self.alphabet.firstIndex(of: letter), let parent = node(index),
                  let next = parent.children.first(where: { node($0)?.label == label }) else { return result }
            index = next
        }
        guard let parent = node(index) else { return result }
        for child in parent.children {
            if let item = node(child) { result[item.label] = Double(continuationMass[child]) }
        }
        return result
    }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[data.startIndex + offset + $1]) << ($1 * 8) }
    }
}

/// Frozen geometry and weak word priors. Max-path scoring, not alignment marginalisation.
// Best-first trie/edit/trail ideas adapted from AVGVSTVS96/iikb
// Packages/KeyboardModules/Sources/KeyboardCore/Correction/Decoder.swift (MIT),
// revision 08df5aa1e698d8587b6dcaef53f5e555ba1fac2a. TSW1 and policy are Typr's.
@MainActor
final class SpatialWordDecoder {
    nonisolated enum Language: String, CaseIterable, Sendable { case german = "de", english = "en" }
    nonisolated enum Edit: Equatable, Sendable {
        case none, missingLetter(at: Int), extraTap(at: Int), transposition(at: Int)
    }
    nonisolated struct Candidate: Equatable, Sendable {
        let word: String
        let language: Language?
        let score: Double
        let spatialScore: Double
        let edit: Edit
        /// Candidate letter -> observed tap; missing letters have no tap.
        let alignment: [Int?]
        /// The literal's own letters with an apostrophe restored (`dont` -> `don't`).
        var addsApostrophe = false

        /// P(taps | word) of the reading: touch densities and its edit's probability.
        var tapLogLikelihood: Double {
            spatialScore + (edit == .none ? 0 : SpatialWordDecoder.editLogProbability)
        }

        /// Extending an exhausted tap prefix is a completion even when its prefix was noisy.
        var isCompletion: Bool {
            if case .missingLetter(let index) = edit { return index == alignment.count - 1 }
            return false
        }
    }
    nonisolated enum Refusal: String, CaseIterable, Sendable {
        case noCandidate, belowMargin, editNeedsInvalidLiteral
    }
    nonisolated enum AutoDecision: Sendable { case replace(Candidate), refuse(Refusal) }
    nonisolated enum Unavailable: Equatable, Sendable { case evidence, resource }
    nonisolated enum Outcome: Equatable, Sendable { case result(Result), unavailable(Unavailable) }
    nonisolated struct Result: Equatable, Sendable {
        let candidates: [Candidate]
        let literalScore: Double
        let literalSpatialScore: Double
        let literalInLexicon: Bool
        let complete: Bool
        let visits: Int
        let generated: Int
        /// Suggestion-only structural alternatives scored BELOW the literal (at most
        /// `editSuggestionLimit`, within one edit penalty of it), retrieved only when the
        /// literal is absent from every selected corpus. Best effort from the remaining
        /// budget: NOT covered by `complete`, never part of `candidates`, and never used
        /// by `automaticDecision`.
        var editSuggestions: [Candidate] = []

        /// Display order: exact above-literal candidates, then best-effort edit suggestions.
        var suggestions: [Candidate] { candidates + editSuggestions }

        /// With two languages on, a candidate outside the preferred language ranks this much lower
        /// against the other candidates (twice the ambiguity margin to win against a preferred one).
        /// Its own score, and so its margin over the literal, is unchanged.
        static let secondaryLanguagePenalty = 1.6

        /// `candidates` reordered by that penalty; `nil` keeps the decoder's order.
        func ranked(preferring isPreferred: ((Candidate) -> Bool)?) -> [Candidate] {
            guard let isPreferred else { return candidates }
            return candidates.sorted { rank($0, isPreferred) > rank($1, isPreferred) }
        }

        private func rank(_ candidate: Candidate, _ isPreferred: ((Candidate) -> Bool)?) -> Double {
            isPreferred?(candidate) == false ? candidate.score - Self.secondaryLanguagePenalty : candidate.score
        }

        /// Dictionary/casing, keeps, rejected pairs and field guards remain the caller's job.
        /// As in iikb's `Corrector.correction`: the likeliest whole word that beats the literal
        /// wins, without a fixed margin or an ambiguity gap, and the best word found so far counts
        /// when the search budget ran out. A valid literal yields only to a word its taps, edit
        /// included, fit better, or, as iikb's `Corrector.contraction`, to its apostrophe spelling at
        /// `apostropheLogOdds`.
        func automaticDecision(literalIsValid: Bool, preferring isPreferred: ((Candidate) -> Bool)? = nil) -> AutoDecision {
            let candidates = ranked(preferring: isPreferred)
            guard let best = candidates.first(where: { !$0.isCompletion }) else {
                return .refuse(candidates.isEmpty ? .noCandidate : .belowMargin)
            }
            guard best.score > literalScore else { return .refuse(.belowMargin) }
            if literalIsValid && best.tapLogLikelihood <= literalSpatialScore
                && !(best.addsApostrophe && best.score - literalScore >= Self.apostropheLogOdds) {
                return .refuse(.editNeedsInvalidLiteral)
            }
            return .replace(best)
        }

        static let apostropheLogOdds = log(10.0)
    }

    static let bundled = SpatialWordDecoder(bundle: .main)
    nonisolated static let searchBudget = 6_000
    nonisolated static let maxGenerated = 12_000
    nonisolated static let editLogProbability = log(0.01)
    nonisolated static let minLetters = 2
    nonisolated static let maxLetters = 32
    nonisolated static let editSuggestionLimit = 2
    private var lexicons: [Language: SpatialWordLexicon]
    private let bundle: Bundle?
    private var loadTask: Task<Void, Never>?
    private var ranking: SpatialWordRanking
    private(set) var isResourceLoading = false

    init(lexicons: [Language: SpatialWordLexicon], usesLegacySearch: Bool = false) {
        self.lexicons = lexicons
        self.ranking = SpatialWordRanking(lexicons: lexicons, usesLegacySearch: usesLegacySearch)
        self.bundle = nil
    }

    init(bundle: Bundle) {
        self.bundle = bundle
        self.lexicons = [:]
        self.ranking = SpatialWordRanking(lexicons: [:])
        isResourceLoading = true
    }

    /// Start at keyboard appearance, never on the first typing/decode path. Mapping,
    /// validation and subtree-index construction all happen off the main actor.
    func prepareResources() {
        guard isResourceLoading, loadTask == nil, let bundle else { return }
        let urls = Language.allCases.compactMap { language -> (Language, URL)? in
            bundle.url(forResource: "keyboard-\(language.rawValue)", withExtension: "words",
                       subdirectory: "WordData").map { (language, $0) }
        }
        loadTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) {
                var lexicons: [Language: SpatialWordLexicon] = [:]
                for (language, url) in urls {
                    if let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                       let lexicon = SpatialWordLexicon(data: data) { lexicons[language] = lexicon }
                }
                return lexicons
            }.value
            guard let self else { return }
            self.lexicons = loaded
            self.ranking = SpatialWordRanking(lexicons: loaded)
            self.resourceRevision &+= 1
            self.isResourceLoading = false
            self.loadTask = nil
        }
    }

    /// Immutable resources are shared copy-on-write, never the mutable ranking memos.
    var resourceSnapshot: [Language: SpatialWordLexicon] { lexicons }
    private(set) var resourceRevision = 0

    /// Display-only wrapper for synchronous logic clients; production suggestions use the worker.
    func prefixSuggestions(_ prefix: String, languages: Set<Language>, evidence: KeyboardTouchWord?,
                           calibration: SpatialTouchCalibration?) -> SpatialPrefixSearch.Result {
        SpatialPrefixSearch.search(prefix, lexicons: lexicons, languages: languages,
                                   evidence: evidence, calibration: calibration)
    }

    func decode(_ word: KeyboardTouchWord, languages: Set<Language>,
                budget: Int = SpatialWordDecoder.searchBudget,
                calibration: SpatialTouchCalibration? = nil,
                personal: PersonalLexiconSnapshot = .empty, allowsEdits: Bool = true,
                context: KeyboardContextModel.WordContext? = nil, variants: [String] = []) -> Result? {
        ranking.decode(word, languages: languages, budget: budget, calibration: calibration,
                       personal: personal, allowsEdits: allowsEdits, context: context, variants: variants)
    }

    func decodeDetailed(_ word: KeyboardTouchWord, languages: Set<Language>,
                        budget: Int = SpatialWordDecoder.searchBudget,
                        calibration: SpatialTouchCalibration? = nil,
                        personal: PersonalLexiconSnapshot = .empty, allowsEdits: Bool = true,
                        context: KeyboardContextModel.WordContext? = nil, variants: [String] = []) -> Outcome {
        ranking.decodeDetailed(word, languages: languages, budget: budget, calibration: calibration,
                               personal: personal, allowsEdits: allowsEdits, context: context, variants: variants)
    }

    nonisolated static func align(word: String, taps: [Character]) -> [Int?]? {
        SpatialWordRanking.align(word: word, taps: taps)
    }
}
