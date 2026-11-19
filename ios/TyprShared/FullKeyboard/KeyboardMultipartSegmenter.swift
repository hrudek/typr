import Foundation

/// Bounded translation of iikb Corrector.missedSpaces / Run.keep (MIT, © 2026
/// Bassim Shahidy, 09a2e9cdfbe851adff6c4646333c0a3f74ba8765; transitions after
/// e05a0ab8a670478d97765d26ffb8493ed5b7ab66).
nonisolated enum KeyboardMultipartSegmenter {
    static let maximumParts = 4
    static let beamWidth = 3
    static let maximumVisits = 131_072
    static let maximumVisitsPerStart = 8_192
    static let maximumPartLetters = 20
    static let maximumLetters = 32
    static let editPenalty = SpatialWordDecoder.editLogProbability

    struct Reading: Equatable, Sendable {
        let word: String
        let score: Double
        var edited = false
    }
    struct Run: Equatable, Sendable {
        let words: [String]
        let score: Double
        var consumesTap = false
        var spaceFits = false
        var edited = false
    }
    struct Result: Sendable {
        let runs: [Run]
        let visits: Int
        let cells: Int
        let cachedReadings: Int
        let exhausted: Bool
    }

    /// Conservative element/string payload, not allocator overhead or RSS. Shared
    /// validated trie data is borrowed. DFS depth ≤21, one ≤21-cell row per frame;
    /// endpoint caches ≤32×33×3, run beams ≤5×33×3 twice (missed Space, tap read as Space). No cross-call cache.
    static var maximumPayloadBytes: Int {
        let readings = maximumLetters * (maximumLetters + 1) * beamWidth
        let readingBytes = MemoryLayout<Reading>.stride + maximumPartLetters * 2
        let runs = 2 * (maximumParts + 1) * (maximumLetters + 1) * beamWidth
        let runBytes = MemoryLayout<Run>.stride + maximumParts * (MemoryLayout<String>.stride + 40)
        let frames = (maximumPartLetters + 2) * (64 + 21 * MemoryLayout<Int>.stride)
        // Include bucket-array elements, frozen 32×30 densities, input and
        // temporary alignment rows/strings with a conservative 32 KiB allowance.
        return readings * readingBytes + runs * runBytes + frames + 32_768
    }

    /// Runs of 2…`maximumParts` words. Without taps only exact spellings are read.
    static func retrieve(_ token: String, sources: [SpatialWordLexicon], shortWords: [(word: String, prior: Double)],
                         touch: KeyboardTouchWord?, calibration: SpatialTouchCalibration?,
                         personal: PersonalLexiconSnapshot = .empty) -> Result {
        let letters = Array(token)
        let touch = touch.flatMap {
            PersonalLexiconSnapshot.normalize($0.text) == token && $0.samples.count == letters.count ? $0 : nil
        }
        guard (2...maximumLetters).contains(letters.count), !sources.isEmpty else {
            return Result(runs: [], visits: 0, cells: 0, cachedReadings: 0, exhausted: false)
        }
        let count = letters.count
        var visits = 0, cells = 0, exhausted = false
        var gains: [[Double]] = []
        var asSpace: [Double?] = Array(repeating: nil, count: count)
        var asStray: [Double] = Array(repeating: -.infinity, count: count)
        if let touch {
            let stray = SpatialWordRanking.strayLogDensity(touch.layout).map { $0 + log(0.5) }
            let adjacent = KeyboardBoundaryTouch.adjacentLetters(in: touch.layout)
            for (index, sample) in touch.samples.enumerated() {
                let literal = KeyboardBoundaryTouch.letterDensity(sample.point, key: sample.key,
                                                                  layout: touch.layout, calibration: calibration)
                gains.append(SpatialWordLexicon.alphabet.map { letter in
                    guard let literal, let key = touch.layout.key(.character(String(letter))),
                          let score = KeyboardBoundaryTouch.letterDensity(sample.point, key: key,
                                                                          layout: touch.layout, calibration: calibration)
                    else { return -Double.infinity }
                    return score - literal
                })
                if let literal, let stray { asStray[index] = stray - literal }
                if let literal, adjacent.contains(sample.key),
                   let space = KeyboardBoundaryTouch.spaceDensity(sample.point, layout: touch.layout,
                                                                  calibration: calibration) {
                    asSpace[index] = space - literal
                }
            }
        }
        func support(_ word: String, start: Int, used: Int, edits: Int) -> Double? {
            if edits == 0 { return 0 }
            guard touch != nil else { return nil }
            let part = Array(letters[start..<(start + used)])
            guard let aligned = SpatialWordDecoder.align(word: word, taps: part) else { return nil }
            // A transposition has two real taps; keep their observed positions for
            // likelihood comparison, never use the alignment as a training label.
            let alignment: [Int?] = word.count == used ? (0..<used).map { Optional($0) } : aligned
            var gain = 0.0
            for offset in 0..<used where !alignment.contains(offset) { gain += asStray[start + offset] }
            for (index, letter) in word.enumerated() {
                guard let offset = alignment[index], part[offset] != letter else { continue }
                guard let label = SpatialWordLexicon.alphabet.firstIndex(of: letter) else { return nil }
                gain += gains[start + offset][label]
            }
            return gain.isFinite ? gain + Double(edits) * editPenalty : nil
        }
        // Flat, fixed-size start/end buckets; input length is capped before allocation.
        let width = count + 1
        var cache = Array(repeating: [Reading](), count: count * width)
        func keep(_ reading: Reading, start: Int, end: Int) {
            let index = start * width + end
            if let old = cache[index].firstIndex(where: { $0.word == reading.word }) {
                guard cache[index][old].score < reading.score else { return }
                cache[index].remove(at: old)
            }
            cache[index].append(reading)
            cache[index].sort { $0.score == $1.score ? $0.word < $1.word : $0.score > $1.score }
            if cache[index].count > beamWidth { cache[index].removeLast() }
        }
        for start in 0..<count {
            let length = min(maximumPartLetters, count - start)
            // Original Typr closed-class supplement (≤46 union entries, ≤2 letters).
            for (word, shortPrior) in shortWords.prefix(46) where word.count <= length {
                let used = word.count
                let part = letters[start..<(start + used)]
                let edits = zip(part, word).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
                guard edits <= 1, let gain = support(word, start: start, used: used, edits: edits) else { continue }
                let prior = max(shortPrior, sources.compactMap { $0.logPrior(for: word) }.max() ?? -.infinity)
                keep(Reading(word: word, score: prior + personal.bonus(for: word) + gain, edited: edits > 0),
                     start: start, end: start + used)
            }
            let initial: [Int] = Array(0...length)
            let before = visits
            for lexicon in sources {
                func walk(_ index: Int, prefix: String, row: [Int], previousRow: [Int]?,
                          previousLetter: Character?, depth: Int) {
                    guard visits < maximumVisits, visits - before < maximumVisitsPerStart else {
                        exhausted = true
                        return
                    }
                    visits += 1
                    guard let node = lexicon.node(index) else { return }
                    let letter = SpatialWordLexicon.alphabet[node.label]
                    var next = [Int](repeating: 0, count: length + 1)
                    next[0] = depth
                    var minimum = depth
                    for offset in 1...length {
                        let cost = letters[start + offset - 1] == letter ? 0 : 1
                        let replace = row[offset - 1] + cost
                        let insert = row[offset] + 1
                        let delete = next[offset - 1] + 1
                        next[offset] = min(replace, min(insert, delete))
                        if offset > 1, let previousRow, let previousLetter,
                           letter == letters[start + offset - 2],
                           previousLetter == letters[start + offset - 1] {
                            next[offset] = min(next[offset], previousRow[offset - 2] + 1)
                        }
                        minimum = min(minimum, next[offset])
                        cells += 1
                    }
                    guard minimum <= 1 else { return }
                    let word = prefix + String(letter)
                    if node.count > 0 {
                        let prior = log(node.count / lexicon.total) + personal.bonus(for: word)
                        for used in 1...length where next[used] <= 1 {
                            guard let gain = support(word, start: start, used: used, edits: next[used]) else { continue }
                            keep(Reading(word: word, score: prior + gain, edited: next[used] > 0),
                                 start: start, end: start + used)
                        }
                    }
                    guard depth < maximumPartLetters else { return }
                    for child in node.children {
                        walk(child, prefix: word, row: next, previousRow: row,
                             previousLetter: letter, depth: depth + 1)
                    }
                }
                if let root = lexicon.node(0) {
                    for child in root.children {
                        walk(child, prefix: "", row: initial, previousRow: nil, previousLetter: nil, depth: 1)
                    }
                }
            }
            if visits >= maximumVisits { break }
        }
        var unspaced = Array(repeating: [Run](), count: (maximumParts + 1) * width)
        var spaced = unspaced
        unspaced[0] = [Run(words: [], score: 0)]
        func retain(_ run: Run, in beam: inout [Run]) {
            if let old = beam.firstIndex(where: { $0.words == run.words }) {
                guard precedes(run, beam[old]) else { return }
                beam.remove(at: old)
            }
            beam.append(run)
            beam.sort(by: precedes)
            if beam.count > beamWidth { beam.removeLast() }
        }
        var finished: [Run] = []
        for parts in 0..<maximumParts {
            for start in 0..<count {
                let index = parts * width + start
                let runs = unspaced[index].map { ($0, parts == 0 ? 0 : KeyboardBoundaryDecoder.missingSpacePenalty) }
                    + spaced[index].map { ($0, 0.0) }
                guard !runs.isEmpty else { continue }
                for end in (start + 1)...min(count, start + maximumPartLetters) {
                    for reading in cache[start * width + end] {
                        for (run, boundary) in runs {
                            let extended = Run(words: run.words + [reading.word],
                                               score: run.score + boundary + reading.score,
                                               consumesTap: run.consumesTap, spaceFits: run.spaceFits,
                                               edited: run.edited || reading.edited)
                            if end == count {
                                if parts >= 1 { retain(extended, in: &finished) }
                                continue
                            }
                            retain(extended, in: &unspaced[(parts + 1) * width + end])
                            if end + 1 < count, let space = asSpace[end] {
                                retain(Run(words: extended.words, score: extended.score + space, consumesTap: true,
                                           spaceFits: space > 0 && (!run.consumesTap || run.spaceFits),
                                           edited: extended.edited),
                                       in: &spaced[(parts + 1) * width + end + 1])
                            }
                        }
                    }
                }
            }
        }
        let retained = cache.reduce(0) { $0 + $1.count }
        return Result(runs: finished, visits: visits, cells: cells, cachedReadings: retained, exhausted: exhausted)
    }

    private static func precedes(_ a: Run, _ b: Run) -> Bool {
        a.score == b.score ? a.words.joined(separator: " ") < b.words.joined(separator: " ") : a.score > b.score
    }
}
