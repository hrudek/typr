import Foundation

/// A trie over a–z spellings for the swipe network, which only knows a–z: "für" is found as "fur" and
/// "Straße" as "strasse". Each terminal keeps the real spellings with their ln P.
/// Built off the main actor from the bundled TSW1 lexicon plus Typr's curated short words.
nonisolated struct SwipeLexicon: Sendable {
    struct Word: Sendable {
        let text: String
        let logPrior: Float
    }

    private(set) var labels: [UInt8] = []
    private(set) var firstChild: [Int32] = []
    private(set) var childCount: [UInt8] = []
    /// Range into `words` for terminals; empty otherwise.
    private(set) var wordStart: [Int32] = []
    private(set) var wordEnd: [Int32] = []
    private(set) var words: [Word] = []

    var nodeCount: Int { labels.count }

    /// Unicode-scalar fold to the network's letters; nil for anything else.
    static func fold(_ word: String) -> [UInt8]? {
        var out: [UInt8] = []
        out.reserveCapacity(word.unicodeScalars.count + 1)
        for scalar in word.unicodeScalars {
            switch scalar {
            case "a"..."z": out.append(UInt8(scalar.value - 97))
            case "ä": out.append(0)
            case "ö": out.append(14)
            case "ü": out.append(20)
            case "ß": out += [18, 18]
            default: return nil
            }
        }
        return out.isEmpty ? nil : out
    }

    init(words input: [(String, Double)]) {
        var grouped: [[UInt8]: [Word]] = [:]
        for (text, prior) in input {
            guard let key = Self.fold(text), key.count <= SwipeEncoder.steps else { continue }
            grouped[key, default: []].append(Word(text: text, logPrior: Float(prior)))
        }
        let keys = grouped.keys.sorted { $0.lexicographicallyPrecedes($1) }
        // Breadth-first with contiguous children. A node is the sorted key range sharing its prefix.
        var queue: [(lo: Int, hi: Int, depth: Int)] = [(0, keys.count, 0)]
        labels = [255]
        var head = 0
        while head < queue.count {
            let (lo, hi, depth) = queue[head]
            var start = lo
            let words = start < hi && keys[start].count == depth ? grouped[keys[start]]!.sorted { $0.logPrior > $1.logPrior } : []
            if !words.isEmpty { start += 1 }
            wordStart.append(Int32(self.words.count))
            self.words += words
            wordEnd.append(Int32(self.words.count))
            firstChild.append(Int32(queue.count))
            var children = 0
            var at = start
            while at < hi {
                let letter = keys[at][depth]
                var end = at + 1
                while end < hi, keys[end][depth] == letter { end += 1 }
                queue.append((at, end, depth + 1))
                labels.append(letter)
                children += 1
                at = end
            }
            childCount.append(UInt8(children))
            head += 1
        }
    }

    /// TSW1 words with ln(count / total), then the curated short words at the flat prior the boundary
    /// decoder uses (TSW1 only holds 3+ letters). Typr's eval: flat short priors match corpus counts.
    init(lexicon: SpatialWordLexicon?, shortWords: [String], shortPrior: Double) {
        var input: [(String, Double)] = []
        if let lexicon {
            input.reserveCapacity(50_000 + shortWords.count)
            var stack: [(index: Int, word: String)] = [(0, "")]
            while let (index, word) = stack.popLast() {
                guard let node = lexicon.node(index) else { continue }
                if index != 0, node.count > 0 { input.append((word, log(node.count / lexicon.total))) }
                for child in node.children {
                    guard let item = lexicon.node(child) else { continue }
                    stack.append((child, word + String(SpatialWordLexicon.alphabet[item.label])))
                }
            }
        }
        for word in shortWords { input.append((word, shortPrior)) }
        self.init(words: input)
    }
}

/// CTC prefix beam search over a `SwipeLexicon`, scored as `CTC / L^γ + λ ln P(word) + β L` (L: folded letters).
/// Adapted from iikb SwipeSearch.swift (MIT, revision f42bad59ce3c0f6f35c7ec0cf727d0b67c146608).
nonisolated enum SwipeSearch {
    struct Candidate: Sendable, Equatable {
        let word: String
        let score: Double
        let language: SpatialWordDecoder.Language?
    }

    /// iikb's encoder-only constants; Typr's German held-out tuning did not beat them.
    static let gamma = 0.608, lambda = 0.392, beta = 0.658, pruneGamma = 0.282, pruneBeta = 1.038
    static let beam = 100
    static let cutoff: Float = -14

    private struct Hypothesis {
        var node: Int32
        var last: Int8
        var depth: Int16
        var blank: Float
        var letter: Float
        var total: Float { SwipeSearch.add(blank, letter) }
    }

    /// ln(e^a + e^b).
    static func add(_ a: Float, _ b: Float) -> Float {
        let (high, low) = a > b ? (a, b) : (b, a)
        guard low > -.infinity else { return high }
        return high + log1p(exp(low - high))
    }

    static func candidates(_ emissions: SwipeEncoder.Emissions, in lexicon: SwipeLexicon,
                           language: SpatialWordDecoder.Language?, limit: Int) -> [Candidate] {
        guard lexicon.nodeCount > 1 else { return [] }
        let steps = SwipeEncoder.steps, blank = SwipeEncoder.letters
        let gammas = (0...steps + 1).map { Float(pow(Double(max($0, 1)), -pruneGamma)) }
        func pruneScore(_ h: Hypothesis) -> Float { h.total * gammas[Int(h.depth)] + Float(pruneBeta) * Float(h.depth) }

        var beamItems = [Hypothesis(node: 0, last: -1, depth: 0, blank: 0, letter: -.infinity)]
        let size = 8192
        var keys = [Int32](repeating: -1, count: size)
        var slots = [Int32](repeating: 0, count: size)
        var used: [Int] = []
        var next: [Hypothesis] = []
        var row = [Float](repeating: 0, count: SwipeEncoder.classes)
        for step in 0..<steps {
            for k in 0..<SwipeEncoder.classes { row[k] = emissions[step, k] }
            next.removeAll(keepingCapacity: true)
            used.removeAll(keepingCapacity: true)
            func slot(_ node: Int32, _ last: Int8, _ depth: Int16) -> Int {
                var at = Int(node) &* 40503 & (size - 1)
                while keys[at] != -1 && keys[at] != node { at = (at + 1) & (size - 1) }
                if keys[at] == -1 {
                    keys[at] = node
                    used.append(at)
                    slots[at] = Int32(next.count)
                    next.append(Hypothesis(node: node, last: last, depth: depth, blank: -.infinity, letter: -.infinity))
                }
                return Int(slots[at])
            }
            for h in beamItems {
                let total = h.total
                let stay = slot(h.node, h.last, h.depth)
                next[stay].blank = add(next[stay].blank, total + row[blank])
                if h.last >= 0 { next[stay].letter = add(next[stay].letter, h.letter + row[Int(h.last)]) }
                guard Int(h.depth) < steps else { continue }
                let first = Int(lexicon.firstChild[Int(h.node)])
                for child in first..<(first + Int(lexicon.childCount[Int(h.node)])) {
                    let index = Int(lexicon.labels[child])
                    guard row[index] > cutoff else { continue }
                    // A repeated letter needs a blank in between (CTC).
                    let source = h.last == Int8(index) ? h.blank : total
                    guard source > -.infinity else { continue }
                    let target = slot(Int32(child), Int8(index), h.depth + 1)
                    next[target].letter = add(next[target].letter, source + row[index])
                }
            }
            for at in used { keys[at] = -1 }
            if next.count > beam {
                let scores = next.map(pruneScore)
                beamItems = next.indices.sorted { scores[$0] > scores[$1] }.prefix(beam).map { next[$0] }
            } else {
                beamItems = next
            }
        }

        var found: [Candidate] = []
        for h in beamItems where h.depth > 0 {
            let node = Int(h.node)
            let range = Int(lexicon.wordStart[node])..<Int(lexicon.wordEnd[node])
            guard !range.isEmpty else { continue }
            let length = Double(h.depth)
            let fit = Double(h.total) / pow(length, gamma) + beta * length
            for word in lexicon.words[range] {
                found.append(Candidate(word: word.text, score: fit + lambda * Double(word.logPrior), language: language))
            }
        }
        return Array(found.sorted { $0.score > $1.score }.prefix(limit))
    }
}

/// One released swipe, in keyboard points, with the word lists to search.
nonisolated struct SwipeRequest: Sendable {
    let path: [SwipePoint]
    let layout: SwipeLayout
    let languages: Set<SpatialWordDecoder.Language>
    let lexicons: [SpatialWordDecoder.Language: SpatialWordLexicon]
    let resources: Int
}

/// The engine's seam to recognition; tests substitute a deterministic one.
typealias SwipeDecoding = @Sendable (SwipeRequest) async -> [SwipeSearch.Candidate]

/// Owns the swipe model and folded lexicons; all work runs here, off the main actor and touch handling.
/// Nothing about a swipe is kept after `decode` returns.
actor SwipeRecognizer {
    /// One per process: the mapped weights and folded tries are shared by every keyboard instance.
    static let shared = SwipeRecognizer()

    func decode(_ request: SwipeRequest) -> [SwipeSearch.Candidate] {
        decode(request.path, layout: request.layout, languages: request.languages,
               lexicons: request.lexicons, resources: request.resources)
    }

    private let loadEncoder: @Sendable () -> SwipeEncoder?
    private var encoder: SwipeEncoder??
    private var lexicons: [SpatialWordDecoder.Language: SwipeLexicon] = [:]
    private var resources = -1

    init(loadEncoder: @escaping @Sendable () -> SwipeEncoder? = { SwipeEncoder.bundled() }) {
        self.loadEncoder = loadEncoder
    }

    /// Up to `limit` distinct words, best first, merged across `languages` by score.
    func decode(_ path: [SwipePoint], layout: SwipeLayout, languages: Set<SpatialWordDecoder.Language>,
                lexicons source: [SpatialWordDecoder.Language: SpatialWordLexicon], resources revision: Int,
                limit: Int = 4) -> [SwipeSearch.Candidate] {
        if encoder == nil { encoder = .some(loadEncoder()) }
        guard let encoder = encoder ?? nil, let emissions = encoder.emissions(of: path, on: layout) else { return [] }
        if revision != resources {
            lexicons = [:]
            resources = revision
        }
        var merged: [SwipeSearch.Candidate] = []
        for language in languages.sorted(by: { $0.rawValue < $1.rawValue }) {
            if lexicons[language] == nil {
                lexicons[language] = SwipeLexicon(
                    lexicon: source[language],
                    shortWords: KeyboardBoundaryDecoder.shortWords(languages: [language]),
                    shortPrior: KeyboardBoundaryDecoder.shortPrior)
            }
            merged += SwipeSearch.candidates(emissions, in: lexicons[language]!, language: language, limit: limit * 2)
        }
        var seen: Set<String> = []
        return merged.sorted { $0.score > $1.score }.filter { seen.insert($0.word).inserted }.prefix(limit).map { $0 }
    }

    /// Memory warning: the folded tries are rebuilt on the next swipe; the mapped weights stay.
    func releaseLexicons() {
        lexicons = [:]
        resources = -1
    }
}
