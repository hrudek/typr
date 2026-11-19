import Foundation

/// Corpus-only discounted backoff, inspired by iikb LanguageModel/Corrector at
/// 09a2e9cdfbe851adff6c4646333c0a3f74ba8765 (MIT, © 2026 Bassim Shahidy).
/// TBG1, sentence posterior and all policy/bounds are Typr's. No sentence archive.
nonisolated struct KeyboardContextModel: Sendable {
    static let bos = "<s>"
    static let suppressed: Set<String> = ["tom", "mary", "maria", "john"]
    static let maxPackBytes = 1_048_576
    static let maxWords = 8_001
    static let candidateLimit = 32
    static let contextLimit = 256
    static let contextByteLimit = 2_048

    nonisolated struct Pack: Sendable {
        let data: Data
        let language: String
        let wordCount: Int
        let total: Double
        let edgeOffset: Int
        let stringOffset: Int
        let edgeCount: Int
        /// Only persistent derived index: two bytes per lexical word.
        let base: [UInt16]
        var residentPayloadBytes: Int { data.count + base.count * 2 }

        /// Check the bundled file before mapping (or Foundation's safe-copy fallback),
        /// then validate the actual bytes again. A corrupt oversized resource must not
        /// allocate its declared size on the extension's preparation path.
        init?(contentsOf url: URL) {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, let size = values.fileSize,
                  (64...KeyboardContextModel.maxPackBytes).contains(size),
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            self.init(data: data)
        }

        init?(data input: Data) {
            // Rebase sliced Data before any indexed access.
            let data = input.startIndex == 0 ? input : Data(input)
            guard data.count >= 64, data.count <= KeyboardContextModel.maxPackBytes else { return nil }
            func u(_ p: Int, _ n: Int = 4) -> UInt64 {
                (0..<n).reduce(0) { $0 | UInt64(data[p + $1]) << ($1 * 8) }
            }
            let v = Int(u(12)), e = Int(u(16)), eo = Int(u(24)), so = Int(u(28))
            let total = u(36, 8), k = Int(u(52, 2)), minimum = u(54, 2)
            guard Array(data.prefix(4)) == Array("TBG1".utf8), u(4, 2) == 1, u(6, 2) == 64,
                  let lang = String(data: data[8..<10], encoding: .utf8), ["de", "en"].contains(lang),
                  u(10, 2) == 0, u(60) == 0, (2...KeyboardContextModel.maxWords).contains(v),
                  (1...16).contains(k), minimum > 0, e <= v * k,
                  u(20) == 64, eo == 64 + v * 20, so == eo + e * 8,
                  so < data.count, Int(u(32)) == data.count,
                  total > 0, total <= 1_000_000_000_000, u(44) == 0x3f000000,
                  u(48) == UInt64(v - 1), Self.crc32(data.dropFirst(64)) == UInt32(u(56)) else { return nil }
            func string(_ offset: Int) -> String? {
                let start = so + offset
                guard start >= so, start < data.count,
                      let end = data[start..<min(data.count, start + 129)].firstIndex(of: 0), end > start,
                      let s = String(data: data[start..<end], encoding: .utf8) else { return nil }
                return s
            }
            var previous: String?
            var sum: UInt64 = 0
            var firstExpected = 0
            for i in 0..<v {
                let p = 64 + i * 20
                guard let key = string(Int(u(p))), let display = string(Int(u(p + 4))),
                      i == 0 ? (key == KeyboardContextModel.bos && display == key && u(p + 8) == 0)
                        : (Self.validWord(key, apostrophes: lang == "en") && Self.validWord(display, apostrophes: lang == "en")
                           && KeyboardContextModel.key(key) == key && KeyboardContextModel.key(display) == key
                           && u(p + 8) > 0),
                      i < 2 || previous!.utf8.lexicographicallyPrecedes(key.utf8) else { return nil }
                previous = key
                sum += u(p + 8)
                let first = Int(u(p + 12))
                let end = i + 1 < v ? Int(u(p + 32)) : e
                guard first == firstExpected, first <= end, end <= e, end - first <= k else { return nil }
                firstExpected = end
                var rowSum: UInt64 = 0
                var lastCount: UInt64 = .max
                var lastID = -1
                var seen: Set<Int> = []
                for j in first..<end {
                    let q = eo + j * 8, id = Int(u(q, 2)), count = u(q + 4)
                    guard id > 0, id < v, u(q + 2, 2) == 0, count >= minimum,
                          seen.insert(id).inserted, count < lastCount || (count == lastCount && id > lastID) else { return nil }
                    rowSum += count
                    lastCount = count; lastID = id
                }
                guard rowSum <= u(p + 16) else { return nil }
            }
            guard sum == total else { return nil }
            self.data = data; language = lang; wordCount = v; self.total = Double(total)
            edgeOffset = eo; stringOffset = so; edgeCount = e
            base = (1..<v).map { UInt16($0) }.sorted {
                let a = u(64 + Int($0) * 20 + 8), b = u(64 + Int($1) * 20 + 8)
                return a == b ? $0 < $1 : a > b
            }
        }

        fileprivate static func validWord(_ s: String, apostrophes: Bool) -> Bool {
            guard s.count <= 32, s.utf8.count <= 128, s.first?.isLetter == true,
                  s.last?.isLetter == true,
                  !s.unicodeScalars.contains(where: {
                      $0.properties.generalCategory == .control || $0.properties.generalCategory == .format
                  }) else { return false }
            let characters = Array(s)
            for (i, ch) in characters.enumerated() where !ch.isLetter {
                guard apostrophes, ch == "'", i > 0, i + 1 < characters.count,
                      characters[i - 1].isLetter, characters[i + 1].isLetter else { return false }
            }
            return true
        }

        private static func crc32(_ data: Data.SubSequence) -> UInt32 {
            var crc: UInt32 = 0xffffffff
            for byte in data {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb88320) }
            }
            return crc ^ 0xffffffff
        }

        private func u(_ p: Int, _ n: Int = 4) -> Int {
            (0..<n).reduce(0) { $0 | Int(data[p + $1]) << ($1 * 8) }
        }
        func word(_ id: Int, display: Bool = false) -> String {
            let start = stringOffset + u(64 + id * 20 + (display ? 4 : 0))
            let end = data[start..<min(data.count, start + 129)].firstIndex(of: 0)!
            return String(data: data[start..<end], encoding: .utf8)!
        }
        func id(_ key: String) -> Int? {
            if key == KeyboardContextModel.bos { return 0 }
            var lo = 1, hi = wordCount
            while lo < hi {
                let mid = (lo + hi) / 2, w = word(mid)
                if w.utf8.lexicographicallyPrecedes(key.utf8) { lo = mid + 1 } else { hi = mid }
            }
            return lo < wordCount && word(lo) == key ? lo : nil
        }
        func count(_ key: String) -> Double { id(key).map { Double(u(64 + $0 * 20 + 8)) } ?? 0 }
        func p0(_ id: Int) -> Double { (Double(u(64 + id * 20 + 8)) + 0.5) / (total + 0.5 * Double(wordCount - 1)) }
        struct Distribution {
            var lambda = 1.0
            var boosts: [(id: Int, probability: Double)] = []
        }
        func distribution(_ context: String?) -> Distribution {
            guard let context, let id = id(context) else { return Distribution() }
            let p = 64 + id * 20, total = u(p + 16)
            guard total > 0 else { return Distribution() }
            let first = u(p + 12), end = id + 1 < wordCount ? u(p + 32) : edgeCount
            var result = Distribution()
            for j in first..<end {
                let q = edgeOffset + j * 8
                result.boosts.append((u(q, 2), (Double(u(q + 4)) - 0.5) / Double(total)))
            }
            result.lambda = 1 - result.boosts.reduce(0) { $0 + $1.probability }
            return result
        }
        func probability(_ key: String, distribution d: Distribution) -> Double {
            guard let id = id(key), id > 0 else { return 0 }
            return d.lambda * p0(id) + (d.boosts.first { $0.id == id }?.probability ?? 0)
        }
        func probability(_ key: String, after context: String?) -> Double {
            probability(key, distribution: distribution(context))
        }
    }

    let de: Pack?
    let en: Pack?
    let unionSize: Int
    var residentPayloadBytes: Int { (de?.residentPayloadBytes ?? 0) + (en?.residentPayloadBytes ?? 0) }

    init?(de: Pack?, en: Pack?) {
        guard de != nil || en != nil, de == nil || de?.language == "de", en == nil || en?.language == "en",
              (de?.data.count ?? 0) + (en?.data.count ?? 0) <= Self.maxPackBytes else { return nil }
        self.de = de; self.en = en
        var a = 1, b = 1, count = 0
        while a < (de?.wordCount ?? 1) || b < (en?.wordCount ?? 1) {
            let x = a < (de?.wordCount ?? 1) ? de!.word(a) : nil
            let y = b < (en?.wordCount ?? 1) ? en!.word(b) : nil
            if let x, let y {
                if x == y { a += 1; b += 1 }
                else if x.utf8.lexicographicallyPrecedes(y.utf8) { a += 1 } else { b += 1 }
            } else if x != nil { a += 1 } else { b += 1 }
            count += 1
        }
        unionSize = count
    }

    static func key(_ word: String) -> String { word.lowercased().precomposedStringWithCanonicalMapping }

    /// Every selected language needs its pack; Typr never silently substitutes the other one.
    func supports(german: Bool, english: Bool) -> Bool {
        (german || english) && (!german || de != nil) && (!english || en != nil)
    }

    /// Strip slots for ranked predictions: second, best (centre), third.
    static func stripOrder<T>(_ ranked: [T]) -> [T] {
        ranked.count >= 2 ? [ranked[1], ranked[0]] + ranked.dropFirst(2) : ranked
    }
    func logRatio(_ word: String) -> Double {
        let key = Self.key(word), d = de?.count(key) ?? 0, e = en?.count(key) ?? 0
        guard key != Self.bos, d > 0 || e > 0, let de, let en else { return 0 }
        let qd = (d + 0.5) / (de.total + 0.5 * Double(unionSize + 1))
        let qe = (e + 0.5) / (en.total + 0.5 * Double(unionSize + 1))
        return log(qd / qe)
    }
    func evidence(_ word: String) -> Double { min(3, max(-3, logRatio(word))) }
    /// Sentence-level log odds, reconstructed from the bounded settled-word suffix. The
    /// eight most recent words have exponentially discounted evidence; repeated contrary
    /// observations or explicit orthography discount old evidence before saturation.
    struct State: Sendable {
        static let window = 8
        private(set) var value: Double
        private(set) var observations: [Double] = []
        private(set) var wordsInSentence = 0
        private var prior: Double
        private var boundaryPrior: Double
        init(prior: Double = 0) {
            let bounded = prior.isFinite ? min(1, max(-1, prior)) : 0
            self.prior = bounded; boundaryPrior = bounded; value = bounded
        }
        var weightDE: Double { 0.05 + 0.90 / (1 + exp(-value)) }
        var weightEN: Double { 1 - weightDE }
        mutating func consume(_ word: String, model: KeyboardContextModel) {
            let key = KeyboardContextModel.key(word)
            var cue = model.evidence(key)
            if key.contains(where: { "äöüß".contains($0) }) { cue += 2 }
            if key.contains("'") && (model.en?.count(key) ?? 0) > 0 { cue -= 2 }
            // A known German noun, not any capitalized name or sentence-initial word.
            var nounCue = 0.0
            if wordsInSentence > 0, word.first?.isUppercase == true,
               let pack = model.de, let id = pack.id(key),
               pack.word(id, display: true).first?.isUppercase == true,
               model.logRatio(key) > log(4) { nounCue = 0.6 }
            cue = min(3, max(-3, cue)) + nounCue
            // One loan word is not a switch. Two consecutive contrary observations
            // switch quickly; explicit umlauts/contractions can switch immediately.
            let explicitCue = key.contains(where: { "äöüß'".contains($0) })
            let repeatedCue = (observations.last ?? 0) * cue > 0
            if abs(cue) >= 1, cue * value < 0, explicitCue || repeatedCue {
                observations.removeAll(keepingCapacity: true)
                boundaryPrior *= 0.2
            }
            if observations.count == Self.window { observations.removeFirst() }
            observations.append(cue)
            value = boundaryPrior
            for observation in observations { value = 0.75 * value + observation }
            value = min(6, max(-6, value))
            wordsInSentence = min(Self.window, wordsInSentence + 1)
        }
        mutating func sentenceBoundary() {
            boundaryPrior = 0.25 * value + 0.5 * prior
            value = boundaryPrior
            observations.removeAll(keepingCapacity: true)
            wordsInSentence = 0
        }
    }

    /// Reuses deletable trusted word counts/dates, not a second language-history store.
    /// No host identifier is available. Most recent 32 retained word types, count capped
    /// at four per type, yield only a weak prior (at most ±1 log odds). Ties are lexical.
    func personalLanguagePrior(_ counts: [String: PersonalTypingModel.WordCount]) -> Double {
        guard counts.count <= 2_000 else { return 0 }
        let recent = counts.sorted {
            if $0.value.lastUpdated != $1.value.lastUpdated { return $0.value.lastUpdated > $1.value.lastUpdated }
            return $0.key < $1.key
        }.prefix(32)
        var sum = 0.0, mass = 4.0
        for (word, count) in recent {
            let weight = Double(min(4, max(0, count.count)))
            sum += weight * evidence(word); mass += weight
        }
        return min(1, max(-1, sum / mass))
    }

    struct Suggestion: Equatable, Sendable {
        let key: String
        let display: String
        let probability: Double
    }

    /// Exact mixture top-three: personal followers (≤8), all boosted corpus followers, then
    /// descending unigram scans. Personal evidence `P_personal(w|h)` (see `PersonalBigramModel`)
    /// wraps the corpus mixture; every non-follower keeps `backoff × P_corpus`, so the corpus
    /// stopping bound scaled by that weight stays exact. Strict bound preserves ties. At most
    /// 16,000 lexical keys, 32 boosts and 8 personal seeds visited; the seen set is
    /// request-local, never a history/cache. Learning off passes an empty personal model,
    /// which reproduces the corpus-only ranking exactly.
    func suggestions(after context: String?, weightDE: Double, german: Bool = true, english: Bool = true,
                     suppress: Set<String> = Self.suppressed,
                     personal: PersonalBigramModel = .init(), earlier: String? = nil) -> [Suggestion] {
        guard supports(german: german, english: english) else { return [] }
        let d = german ? de : nil, e = english ? en : nil
        let a = german ? (english ? min(1, max(0, weightDE.isFinite ? weightDE : 0.5)) : 1) : 0
        let dd = d?.distribution(context) ?? Pack.Distribution(), ed = e?.distribution(context) ?? Pack.Distribution()
        let selected = personal.select(after: context, earlier: earlier).context
        let row = personal.followers(after: selected)
        let backoff = personal.backoffWeight(after: selected)
        var seen: Set<String> = [], best: [Suggestion] = []
        func visit(_ key: String) {
            // Stock-name suppression and selected packs govern corpus words. A personal-only
            // follower (OOV, other language's word or a suppressed name) needs repeated trust.
            let corpusWord = !suppress.contains(key) && (d?.id(key) != nil || e?.id(key) != nil)
            guard corpusWord || (row[key] ?? 0) >= PersonalBigramModel.novelFollowerMinimum,
                  seen.insert(key).inserted else { return }
            let dp = a * (d?.probability(key, distribution: dd) ?? 0)
            let ep = (1 - a) * (e?.probability(key, distribution: ed) ?? 0)
            let pack = dp >= ep && d?.id(key) != nil ? d : e
            let display = pack.flatMap { p in p.id(key).map { p.word($0, display: true) } } ?? key
            best.append(Suggestion(key: key, display: display,
                                   probability: personal.probability(key, after: selected, corpus: dp + ep)))
            best.sort { $0.probability == $1.probability ? $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) : $0.probability > $1.probability }
            if best.count > 3 { best.removeLast() }
        }
        for key in row.keys.sorted() { visit(key) }
        for boost in dd.boosts { visit(d!.word(boost.id)) }
        for boost in ed.boosts { visit(e!.word(boost.id)) }
        var pos = 0
        while pos < max(d?.base.count ?? 0, e?.base.count ?? 0) {
            if let d, pos < d.base.count { visit(d.word(Int(d.base[pos]))) }
            if let e, pos < e.base.count { visit(e.word(Int(e.base[pos]))) }
            pos += 1
            let db = d.flatMap { pos < $0.base.count ? $0.p0(Int($0.base[pos])) : nil } ?? 0
            let eb = e.flatMap { pos < $0.base.count ? $0.p0(Int($0.base[pos])) : nil } ?? 0
            if best.count == 3, best[2].probability > backoff * (a * dd.lambda * db + (1 - a) * ed.lambda * eb) { break }
        }
        return best
    }

    func probability(_ word: String, after context: String?, weightDE: Double, german: Bool, english: Bool) -> Double {
        guard (!german || de != nil), (!english || en != nil) else { return 0 }
        let a = german ? (english ? weightDE : 1) : 0
        let key = Self.key(word)
        return a * (german ? de?.probability(key, after: context) ?? 0 : 0)
            + (1 - a) * (english ? en?.probability(key, after: context) ?? 0 : 0)
    }

    struct Context: Sendable {
        var state = State()
        var previous: String?
        var earlier: String?
        var canPredict = false
    }

    /// Recompute from a short RAM-only suffix every request: edits cannot double-consume
    /// evidence and field changes cannot retain a posterior. Discard a clipped first word.
    /// Unknown/numeric/identifier barriers are NOT BOS; sentence punctuation is BOS.
    func context(before input: String?, currentToken: String?, prior: Double = 0) -> Context {
        guard let input else { return Context() }
        let bytes = input.utf8.suffix(Self.contextByteLimit + 1)
        let tail = String(decoding: bytes.suffix(Self.contextByteLimit), as: UTF8.self).suffix(Self.contextLimit + 1)
        // A caller (including the suggestion worker) may already have clipped to
        // exactly these caps. Conservatively discard its potentially partial first word.
        let clipped = bytes.count >= Self.contextByteLimit || tail.count >= Self.contextLimit
        var suffix = String(tail.suffix(Self.contextLimit))
        if clipped { suffix = String(suffix.drop(while: { !$0.isWhitespace && !".!?…".contains($0) })) }
        if let token = currentToken, suffix.hasSuffix(token) { suffix.removeLast(token.count) }
        var result = Context(state: State(prior: prior)), token = ""
        var atSentenceBoundary = false
        func flush() {
            guard !token.isEmpty else { return }
            if Pack.validWord(token, apostrophes: true) {
                let key = Self.key(token)
                result.state.consume(token, model: self)
                result.earlier = result.previous == Self.bos ? nil : result.previous
                result.previous = key
                result.canPredict = true; atSentenceBoundary = false
            } else { result.previous = nil; result.earlier = nil; result.canPredict = false }
            token = ""
        }
        func sentenceBoundary() {
            if !atSentenceBoundary { result.state.sentenceBoundary() }
            result.previous = Self.bos; result.earlier = nil
            result.canPredict = true; atSentenceBoundary = true
        }
        let text = suffix.replacingOccurrences(of: "’", with: "'")
        for (index, line) in text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }).enumerated() {
            // A line break starts a new sentence (no cross-line pair); a leading break invents nothing.
            if index > 0, result.previous != nil || result.canPredict || result.state.value != 0 { sentenceBoundary() }
            for segment in line.split(whereSeparator: { $0.isWhitespace }) {
                // Non-prose spans are barriers, including their punctuation (not a fake BOS
                // inside a URL/email/identifier/number). Ordinary comma/quotes separate words.
                let invalidScalar = segment.unicodeScalars.contains {
                    $0.properties.generalCategory == .format
                        || ($0.properties.generalCategory == .control
                            && !CharacterSet.whitespacesAndNewlines.contains($0))
                }
                if invalidScalar || segment.contains(where: { $0.isNumber || "@/:_#-\\\\".contains($0) }) {
                    result.previous = nil; result.earlier = nil; result.canPredict = false
                    continue
                }
                for ch in segment {
                    if ch.isLetter || ch == "'" { token.append(ch) } else {
                        flush()
                        if ".!?…".contains(ch) { sentenceBoundary() }
                    }
                }
                flush()
            }
        }
        // At an empty/unknown document start do not pretend a sentence boundary was seen.
        return result
    }

    /// Weight of the context gain, equal to the spatial decoder's unigram prior weight, so the
    /// term is on the decoder's own language-model scale (noisy channel: spatial + LM).
    static let gainWeight = 0.35
    /// Gain cap: log(20). At most +1.05 nats; context never penalizes a candidate.
    static let gainLimit = log(20.0)
    /// Unscored alternatives (system guesses/completions, contact terms) keep rank spacing.
    static let rankWeight = 0.2

    /// Bounded, non-negative context evidence: clip(log(P(w|h) / P_mix(w)), 0, log 20)
    /// with the same language weights for both terms, where P(w|h) is the corpus mixture
    /// wrapped by personal follower backoff (empty while learning is off). Only retained
    /// corpus or personal followers of h can gain. Words without corpus probability (names,
    /// compounds, OOV) gain only as a personal follower seen at least twice (denominator
    /// floor 1e-12, still capped); otherwise they and plain non-followers get 0.
    func contextGain(_ word: String, context: Context, german: Bool, english: Bool,
                     personal: PersonalBigramModel = .init()) -> Double {
        guard context.canPredict, let previous = context.previous else { return 0 }
        let weight: Double = context.state.weightDE
        let base: Double = probability(word, after: nil, weightDE: weight, german: german, english: english)
        let selected = personal.select(after: previous, earlier: context.earlier).context
        let count: Int = personal.followers(after: selected)[Self.key(word)] ?? 0
        guard base > 0 || count >= PersonalBigramModel.novelFollowerMinimum else { return 0 }
        let corpus: Double = probability(word, after: previous, weightDE: weight, german: german, english: english)
        let p: Double = personal.probability(word, after: selected, corpus: corpus)
        let ratio: Double = max(p, 1e-12) / max(base, 1e-12)
        return min(Self.gainLimit, max(0, log(ratio)))
    }

    /// The sentence-context term of the automatic correction score: `log(P(w|h) / P(w))` under the
    /// language mixture wrapped by personal follower backoff, the same lift as
    /// `KeyboardBoundaryDecoder` (bounded by its `maximumLogLift`). Added to a word's lexical log
    /// prior, it turns `P(w)` into `P(w|h)`. Without a previous word, or for a word absent from the
    /// packs, the lift is 0. `logUnigram` prices spellings the spatial word lists cannot hold.
    struct WordContext: Sendable, Equatable {
        let previous: String?
        let earlier: String?
        let weightDE: Double
        let german: Bool
        let english: Bool
        let personal: PersonalBigramModel
        /// Upper bound of `logLift` over every word, for admissible search bounds.
        private(set) var maximumLift: Double
        private let model: KeyboardContextModel
        private let selected: String?
        private let deFollowers: Pack.Distribution
        private let enFollowers: Pack.Distribution

        init(model: KeyboardContextModel, context: Context, german: Bool, english: Bool,
             personal: PersonalBigramModel) {
            self.model = model
            previous = context.canPredict ? context.previous : nil
            earlier = context.earlier
            weightDE = context.state.weightDE
            self.german = german
            self.english = english
            self.personal = personal
            selected = personal.select(after: previous, earlier: earlier).context
            deFollowers = german ? model.de?.distribution(previous) ?? .init() : .init()
            enFollowers = english ? model.en?.distribution(previous) ?? .init() : .init()
            maximumLift = 0
            var followers = Array(personal.followers(after: selected).keys)
            if let de = model.de { followers += deFollowers.boosts.map { de.word($0.id) } }
            if let en = model.en { followers += enFollowers.boosts.map { en.word($0.id) } }
            maximumLift = followers.map(logLift).reduce(0, max)
        }

        private var mix: Double { german ? (english ? weightDE : 1) : 0 }

        private func probability(_ key: String, conditional: Bool) -> Double {
            let de = german ? model.de?.probability(key, distribution: conditional ? deFollowers : .init()) ?? 0 : 0
            let en = english ? model.en?.probability(key, distribution: conditional ? enFollowers : .init()) ?? 0 : 0
            return mix * de + (1 - mix) * en
        }

        func logLift(_ word: String) -> Double {
            guard previous != nil else { return 0 }
            let key = KeyboardContextModel.key(word)
            let unconditional = probability(key, conditional: false)
            let conditional = personal.probability(key, after: selected, corpus: probability(key, conditional: true))
            guard unconditional > 0, conditional > 0 else { return 0 }
            let limit = KeyboardBoundaryDecoder.maximumLogLift
            return min(limit, max(-limit, log(conditional / unconditional)))
        }

        func logUnigram(_ word: String) -> Double? {
            let p = probability(KeyboardContextModel.key(word), conditional: false)
            return p > 0 ? log(p) : nil
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.previous == rhs.previous && lhs.earlier == rhs.earlier && lhs.weightDE == rhs.weightDE
                && lhs.german == rhs.german && lhs.english == rhs.english && lhs.personal == rhs.personal
        }
    }

    /// Reorders an existing ordered display pool (at most 32 entries), only WITHIN each evidence
    /// kind and in the slots that kind already occupies: spatial candidates by
    /// `spatialScore + 0.35*gain`, unscored alternatives by `-0.2*rank + 0.35*gain`. A context
    /// can never lift an unscored guess above a spatial reading or vice versa. Literal,
    /// automatic and explicit-revert slots are pinned by the caller. Ties keep original order.
    func rerank(_ candidates: [String], spatialScores: [String: Double] = [:], context: Context,
                german: Bool, english: Bool, personal: PersonalBigramModel = .init()) -> [String] {
        var pool = Array(candidates.prefix(Self.candidateLimit))
        guard context.canPredict, context.previous != nil else { return pool }
        let gains: [Double] = pool.map { word in
            Self.gainWeight * contextGain(word, context: context, german: german, english: english, personal: personal)
        }
        guard gains.contains(where: { $0 > 0 }) else { return pool }
        for scored in [true, false] {
            let slots = pool.indices.filter { (spatialScores[pool[$0]] != nil) == scored }
            var keyed: [RerankEntry] = []
            keyed.reserveCapacity(slots.count)
            for (rank, slot) in slots.enumerated() {
                let base: Double
                if scored, let score = spatialScores[pool[slot]] {
                    base = score
                } else {
                    base = -Self.rankWeight * Double(rank)
                }
                let key: Double = base + gains[slot]
                keyed.append(RerankEntry(slot: slot, key: key))
            }
            let ordered: [RerankEntry] = keyed.sorted { (lhs: RerankEntry, rhs: RerankEntry) -> Bool in
                if lhs.key == rhs.key { return lhs.slot < rhs.slot }
                return lhs.key > rhs.key
            }
            let words: [String] = ordered.map { pool[$0.slot] }
            for (slot, word) in zip(slots, words) { pool[slot] = word }
        }
        return pool
    }

    private struct RerankEntry {
        let slot: Int
        let key: Double
    }
}

/// Shared immutable maps are prepared off the key path; unavailable selected data
/// abstains rather than silently falling back to the other language.
@MainActor
final class KeyboardContextResources {
    static let bundled = KeyboardContextResources(bundle: .main)
    private(set) var model: KeyboardContextModel?
    private let bundle: Bundle?
    private var task: Task<Void, Never>?
    private var ready: (@MainActor () -> Void)?
    init(model: KeyboardContextModel?) { self.model = model; bundle = nil }
    init(bundle: Bundle) { self.bundle = bundle }
    func prepare(onReady: @escaping @MainActor () -> Void) {
        guard model == nil, let bundle else { return }
        ready = onReady
        guard task == nil else { return }
        let urls = ["de", "en"].map { bundle.url(forResource: "keyboard-\($0)", withExtension: "tbg", subdirectory: "WordData") }
        task = Task { [weak self] in
            let model = await Task.detached(priority: .utility) {
                let packs = urls.map { url in
                    url.flatMap { KeyboardContextModel.Pack(contentsOf: $0) }
                }
                return KeyboardContextModel(de: packs[0], en: packs[1])
            }.value
            guard let self else { return }
            self.model = model
            let callback = self.ready; self.ready = nil
            callback?()
        }
    }
}
