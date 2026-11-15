import Foundation

/// Exact two-part run segmentation and whole-vs-split comparison translated from iikb's
/// Correction/Corrector.swift and Typing/TypingEngine+Words.swift at
/// 09a2e9cdfbe851adff6c4646333c0a3f74ba8765 (MIT, © 2026 Bassim Shahidy).
/// One spatial boundary reinterpretation is allowed. A separate bounded lexical
/// multi-part fallback has no automatic authority or fabricated tap evidence.
nonisolated enum KeyboardBoundaryDecoder {
    typealias Language = SpatialWordDecoder.Language
    static let maxLetters = 32
    static let maxPartLetters = 20
    static let resultLimit = 3
    // Exact baseline ≤74; at most 60 spatial part lookups plus eight whole
    // competitors and five Space-as-letter joins. If both paths run, the prior
    // word + Space leaves at most 30 current letters (saving eight part lookups).
    // Each query uses at most two tries; 144 includes rejected endpoints.
    static let maximumLexicalQueries = 144
    static let maximumTrieEdgeChecks = maximumLexicalQueries * maxLetters * 30 * 2
    // Conditional and unconditional mixture lookups: whole literal, eight whole
    // competitors and both parts at every split. Each lookup uses ≤2 packs,
    // ≤14 binary-search steps per key and ≤16 retained row edges.
    static let maximumContextQueries = 2 + 2 * 8 + 4 * (maxLetters - 1)
    static let maximumLanguageEvidenceQueries = 2 * (maxLetters - 1)
    /// Bound on |ln lift| so one sparse corpus row cannot dominate the lexical scale.
    static let maximumLogLift = log(1_000.0)
    static let missingSpacePenalty = log(0.01)
    static let joinMargin = log(100.0)

    struct Context: Equatable, Sendable {
        let previous: String?
        let weightDE: Double

        init(previous: String?, weightDE: Double) {
            self.previous = previous.flatMap {
                $0.utf8.count <= 128 && $0.count <= 32 ? KeyboardContextModel.key($0) : nil
            }
            self.weightDE = min(1, max(0, weightDE.isFinite ? weightDE : 0.5))
        }
    }

    static var maximumContextPayloadBytes: Int { MemoryLayout<Context>.stride + 128 }

    struct Job: Equatable, Sendable {
        let token: String
        let previous: String?
        let languages: Set<Language>
        let personal: PersonalLexiconSnapshot
        /// Explicit keeps protect whole literals even with personal ranking off.
        let kept: Set<String>
        /// Bounded corpus-only state recomputed from the field suffix. Nil preserves unigram policy.
        var context: Context? = nil
        var touch: KeyboardBoundaryTouch? = nil
        var calibration: SpatialTouchCalibration? = nil
    }

    struct Candidate: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case split, join }
        let kind: Kind
        /// Exact suffix owned by the chip. A join includes the preceding token and one space.
        let original: String
        let replacement: String
        let score: Double
        let baseline: Double
        /// Retained high-probability bigram evidence, never automatic authority.
        var strongPair = false
        /// The whole's FrequencyWords prior was treated as merge noise inside this ranking.
        /// MainActor dictionary validity still vetoes the chip; this never relaxes it.
        var weakWhole = false
        /// Consumes one observed tap as Space or a letter, rather than inventing a tap.
        var spatial = false
        /// Independent likelihood protection for dictionary-valid parts on MainActor,
        /// including valid names/words absent from the ranking lexicons.
        var betterThanSeparateTap = false
    }

    struct Retrieval: Sendable {
        let job: Job
        let candidates: [Candidate]
        let lexicalQueries: Int
        var contextQueries = 0
        var languageEvidenceQueries = 0
        var multipartVisits = 0
        var multipartCells = 0
        var multipartCachedReadings = 0
        var multipartExhausted = false
        /// Synchronous legacy fallback must not suppress a later worker search.
        var includesMultipart = true
    }

    /// Hand-curated closed-class words (Typr original work, not third-party data).
    /// Only words filtered out by the bundled ≥3-letter resource policy. Equal
    /// .01 pseudo-probability, not fabricated corpus counts; longer function words use TSW1.
    private static let germanShort: Set<String> = [
        "ab", "am", "an", "da", "du", "er", "es", "im", "in", "ja", "je", "ob", "so", "um", "wo", "zu"
    ]
    private static let englishShort: Set<String> = [
        "a", "i", "am", "an", "as", "at", "be", "by", "do", "he", "if", "in", "is", "it", "me", "my",
        "no", "of", "oh", "on", "or", "so", "to", "up", "us", "we"
    ]
    static let shortPrior = log(0.01)

    static func shortWords(languages: Set<Language>) -> [String] {
        var words: Set<String> = []
        if languages.contains(.german) { words.formUnion(germanShort) }
        if languages.contains(.english) { words.formUnion(englishShort) }
        return words.sorted()
    }

    static var shortWordPayloadBytes: Int {
        (germanShort.count + englishShort.count) * MemoryLayout<String>.stride
            + germanShort.reduce(0) { $0 + $1.utf8.count } + englishShort.reduce(0) { $0 + $1.utf8.count }
    }

    static var maximumCandidatePayloadBytes: Int {
        // Original join suffix keeps RAW Unicode: two ≤64-byte inputs plus a space.
        // Replacement is NFC (≤36 two-byte letters plus three spaces). Do not assume the raw
        // original was NFC. Excludes allocator/container overhead, not RSS.
        (resultLimit + 1) * (MemoryLayout<Candidate>.stride + 129 + 75)
    }

    static func isEligible(_ token: String) -> Bool {
        guard token.utf8.count <= 64, (1...maxLetters).contains(token.count) else { return false }
        let lower = PersonalLexiconSnapshot.normalize(token)
        guard lower.allSatisfy({ SpatialWordLexicon.alphabet.contains($0) }) else { return false }
        // Internal capitals, acronyms and non-letter identifiers have no boundary interpretation.
        return token == token.lowercased() || (token.first?.isUppercase == true
            && String(token.dropFirst()) == token.dropFirst().lowercased())
    }

    static func retrieve(_ job: Job, lexicons: [Language: SpatialWordLexicon],
                         whole: SpatialWordDecoder.Outcome? = nil,
                         model: KeyboardContextModel? = nil, includeMultipart: Bool = true) -> Retrieval {
        var queries = 0, contextQueries = 0, languageEvidenceQueries = 0
        var found: [Candidate] = []
        var multipart: KeyboardMultipartSegmenter.Result?
        var needsMultipart = false
        func result() -> Retrieval {
            Retrieval(job: job, candidates: found, lexicalQueries: queries, contextQueries: contextQueries,
                      languageEvidenceQueries: languageEvidenceQueries,
                      multipartVisits: multipart?.visits ?? 0, multipartCells: multipart?.cells ?? 0,
                      multipartCachedReadings: multipart?.cachedReadings ?? 0,
                      multipartExhausted: multipart?.exhausted ?? false,
                      includesMultipart: includeMultipart || !needsMultipart || !found.isEmpty)
        }
        func retain(_ candidate: Candidate) {
            found.append(candidate)
            found.sort {
                let a = ($0.score * 1e9).rounded(), b = ($1.score * 1e9).rounded()
                return a == b ? $0.replacement < $1.replacement : a > b
            }
            if found.count > resultLimit { found.removeLast() }
        }
        guard !job.languages.isEmpty, job.languages.allSatisfy({ lexicons[$0] != nil }),
              isEligible(job.token), job.personal.scan.complete else { return result() }
        let sources = Language.allCases.filter { job.languages.contains($0) }
        let floor = sources.compactMap { lexicons[$0].map { log(1 / $0.total) } }.max() ?? 0
        func prior(_ word: String) -> Double? {
            queries += 1
            precondition(queries <= maximumLexicalQueries)
            var best: Double?
            for language in sources {
                var value = lexicons[language]?.logPrior(for: word)
                let short = language == .german ? germanShort : englishShort
                if short.contains(word) { value = max(value ?? -.infinity, shortPrior) }
                if let value { best = max(best ?? -.infinity, value) }
            }
            if job.personal.isKept(word) || (job.personal.counts[word] ?? 0) >= 2 {
                best = max(best ?? -.infinity, log(0.0001))
            }
            return best.map { $0 + job.personal.bonus(for: word) }
        }
        let contextModel = model.flatMap {
            job.context != nil && $0.supports(german: job.languages.contains(.german),
                                              english: job.languages.contains(.english)) ? $0 : nil
        }
        func probability(_ word: String, after previous: String?) -> Double {
            guard let contextModel else { return 0 }
            contextQueries += 1
            precondition(contextQueries <= maximumContextQueries)
            return contextModel.probability(word, after: previous, weightDE: job.context?.weightDE ?? 0.5,
                                            german: job.languages.contains(.german),
                                            english: job.languages.contains(.english))
        }
        // P(w|c)/P(w): the context model's conditional evidence as a ratio. Both corpora
        // estimate unigram frequency on different scales (subtitles vs. sentences), so the
        // lexical TSW1 prior keeps the scale and context only multiplies it. Absent words
        // and missing context back off to lift 1. P(left|c)·P(right|left) =
        // P(left)·P(right)·lift(left|c)·lift(right|left) when both unigram sources agree.
        func logLift(_ conditional: Double, _ unconditional: Double) -> Double {
            guard conditional > 0, unconditional > 0 else { return 0 }
            return min(maximumLogLift, max(-maximumLogLift, log(conditional / unconditional)))
        }
        func contextLift(_ word: String) -> Double {
            guard let previous = job.context?.previous else { return 0 }
            return logLift(probability(word, after: previous), probability(word, after: nil))
        }
        let token = PersonalLexiconSnapshot.normalize(job.token)
        let wholePrior = prior(token)
        let protected = job.kept.contains(token) || (job.personal.counts[token] ?? 0) > 0
        needsMultipart = !protected && wholePrior == nil && token.count >= 6 && job.touch?.isUsable == true
        if !protected, token.count >= 3 {
            // Corpus membership is not spelling validity (the packs contain e.g. "inthe").
            // A known whole must lose on score too; MainActor separately vetoes every literal
            // the enabled dictionaries accept.
            let previous = job.context?.previous
            let wholeContext = probability(token, after: previous)
            let wholeUnigram = previous == nil ? wholeContext : probability(token, after: nil)
            let literalBaseline = (wholePrior ?? floor) + logLift(wholeContext, wholeUnigram)
            var competitorBaseline = -Double.infinity
            if case .result(let reading) = whole {
                // Convert the existing .35-weighted whole-word score to full lexical log
                // probability; the unchanged letters' spatial density cancels for exact splits.
                for candidate in reading.candidates.prefix(8) where !candidate.isCompletion {
                    queries += 1
                    let p = sources.compactMap { lexicons[$0]?.logPrior(for: candidate.word) }.max() ?? floor
                    // The literal itself is compared separately, including corpus merge noise.
                    // candidate.score already includes its personal bonus; add it only once.
                    if candidate.word != token {
                        competitorBaseline = max(competitorBaseline, candidate.score - reading.literalSpatialScore
                                                 + 0.65 * p + contextLift(candidate.word))
                    }
                }
            }
            let letters = Array(token)
            for point in 1..<letters.count {
                guard point <= maxPartLetters, letters.count - point <= maxPartLetters else { continue }
                let left = String(letters[..<point]), right = String(letters[point...])
                guard let a = prior(left), let b = prior(right) else { continue }
                var leftLift = 0.0, rightLift = 0.0, strongPair = false
                if contextModel != nil {
                    let leftUnigram = probability(left, after: nil)
                    if let previous { leftLift = logLift(probability(left, after: previous), leftUnigram) }
                    let pair = probability(right, after: left), rightUnigram = probability(right, after: nil)
                    rightLift = logLift(pair, rightUnigram)
                    // Corpus pairs do not cover code switches. Opposite-language evidence on
                    // the parts must not let sparse monolingual rows penalize "mit you".
                    let crossLanguage = job.languages.count == 2 && contextModel.map {
                        languageEvidenceQueries += 2
                        precondition(languageEvidenceQueries <= maximumLanguageEvidenceQueries)
                        return $0.evidence(left) * $0.evidence(right) < 0
                    } == true
                    if crossLanguage { leftLift = max(0, leftLift); rightLift = max(0, rightLift) }
                    // Merge noise needs an actual retained edge (not just frequent words) and a
                    // whole absent from the independent sentence corpus. Keeps, counts and the
                    // MainActor dictionary/contact/identifier protections still win.
                    strongPair = wholeContext == 0 && wholeUnigram == 0 && pair >= 0.05
                        && rightUnigram > 0 && pair / rightUnigram >= 2 && leftUnigram >= 0.001
                }
                let baseline = max(competitorBaseline, strongPair ? floor : literalBaseline)
                let score = a + b + leftLift + rightLift + missingSpacePenalty
                guard score > baseline else { continue }
                retain(Candidate(kind: .split, original: job.token,
                                 replacement: left + " " + right, score: score, baseline: baseline,
                                 strongPair: strongPair,
                                 weakWhole: strongPair && wholePrior != nil && literalBaseline > competitorBaseline))
            }
        }
        // Spatial cases share the exact lookup budget and the top-three retention. Only
        // one boundary tap changes; all other letters are literal, so their densities cancel.
        if let touch = job.touch, touch.isUsable, touch.current.text == job.token {
            let layout = touch.current.layout
            let adjacent = KeyboardBoundaryTouch.adjacentLetters(in: layout)
            if !protected, token.count >= 3 {
                var baseline = wholePrior ?? floor
                if case .result(let reading) = whole {
                    for candidate in reading.candidates.prefix(8) where !candidate.isCompletion {
                        // Same full-prior scale as the exact split comparison above.
                        queries += 1
                        precondition(queries <= maximumLexicalQueries)
                        let p = sources.compactMap { lexicons[$0]?.logPrior(for: candidate.word) }.max() ?? floor
                        baseline = max(baseline, candidate.score - reading.literalSpatialScore + 0.65 * p)
                    }
                }
                let letters = Array(token)
                for index in 1..<(letters.count - 1) {
                    guard index <= maxPartLetters, letters.count - index - 1 <= maxPartLetters,
                          let key = adjacent.first(where: { $0.character == String(letters[index]) }) else { continue }
                    let sample = touch.current.samples[index]
                    guard sample.key == key,
                          let spaceScore = KeyboardBoundaryTouch.spaceDensity(sample.point, layout: layout),
                          let letterScore = KeyboardBoundaryTouch.letterDensity(sample.point, key: key, layout: layout,
                                                                              calibration: job.calibration) else { continue }
                    let left = String(letters[..<index]), right = String(letters[(index + 1)...])
                    guard let a = prior(left), let b = prior(right) else { continue }
                    let score = a + b + spaceScore - letterScore
                    if score > baseline {
                        retain(Candidate(kind: .split, original: job.token, replacement: left + " " + right,
                                         score: score, baseline: baseline, spatial: true))
                    }
                }
            }
            // A current-token split and a previous+current join are ALTERNATIVES, not
            // two edits in a three-word run. A retained prior word must not hide a
            // letter-as-Space error in the current word.
            if let previous = touch.previous, previous.text == job.previous,
               isEligible(previous.text), let space = touch.space,
               previous.text.count + token.count + 1 <= maxLetters {
                let first = PersonalLexiconSnapshot.normalize(previous.text)
                let protection = job.kept.contains(first) || job.kept.contains(token)
                    || (job.personal.counts[first] ?? 0) > 0 || (job.personal.counts[token] ?? 0) > 0
                if !protection, let asSpace = KeyboardBoundaryTouch.spaceDensity(space.point, layout: layout) {
                    let a = prior(first), b = wholePrior
                    // Two known words require better tap likelihood too (iikb's separate
                    // reading protection). Frequency alone can never reinterpret their Space.
                    let baseline = (a ?? floor) + (b ?? floor)
                    for key in adjacent {
                        guard let letter = key.character,
                              let density = KeyboardBoundaryTouch.letterDensity(space.point, key: key, layout: layout,
                                                                              calibration: job.calibration),
                              (a == nil || b == nil || density > asSpace),
                              let joined = prior(first + letter + token) else { continue }
                        let score = joined + density - asSpace
                        if score > baseline + joinMargin {
                            retain(Candidate(kind: .join, original: touch.original,
                                             replacement: first + letter + token,
                                             score: score, baseline: baseline, spatial: true,
                                             betterThanSeparateTap: density > asSpace))
                        }
                    }
                }
            }
        }
        // Exact removal of one gratuitous space. Without contextual evidence TWO known parts
        // always win protection, irrespective of the joined word's frequency ("some thing").
        if let previous = job.previous, isEligible(previous), previous.count + token.count <= maxLetters {
            let first = PersonalLexiconSnapshot.normalize(previous)
            let personalProtection = job.kept.contains(first) || job.kept.contains(token)
                || (job.personal.counts[first] ?? 0) > 0 || (job.personal.counts[token] ?? 0) > 0
            if !personalProtection {
                let firstPrior = prior(first)
                let secondPrior = wholePrior
                if firstPrior == nil || secondPrior == nil, let joined = prior(first + token) {
                    let apart = (firstPrior ?? floor) + (secondPrior ?? floor)
                    var strayLift = 0.0
                    if let touch = job.touch, touch.isUsable, touch.previous?.text == previous,
                       touch.current.text == job.token, let space = touch.space,
                       let asSpace = KeyboardBoundaryTouch.spaceDensity(space.point, layout: touch.current.layout) {
                        // A deleted gratuitous tap still pays its best gated density and the
                        // edit penalty. Compare against the same tap interpreted as Space.
                        var stray = asSpace
                        for key in KeyboardBoundaryTouch.adjacentLetters(in: touch.current.layout) {
                            if let density = KeyboardBoundaryTouch.letterDensity(space.point, key: key,
                                layout: touch.current.layout, calibration: job.calibration) {
                                stray = max(stray, density)
                            }
                        }
                        strayLift = stray - asSpace
                    }
                    let score = joined + missingSpacePenalty + strayLift
                    if score - apart >= joinMargin {
                        retain(Candidate(kind: .join, original: previous + " " + job.token,
                                               replacement: first + token, score: score, baseline: apart))
                    }
                }
            }
        }
        // Preserve the established exact/spatial ranking. Only unknown wholes with
        // no retained boundary alternative enter the more permissive lexical beam.
        // MainActor still applies dictionary/contact/personal/rejection protection.
        if includeMultipart, found.isEmpty, !protected, wholePrior == nil, token.count >= 6,
           let touch = job.touch, touch.isUsable, touch.current.text == job.token {
            let packs: [SpatialWordLexicon] = sources.compactMap { lexicons[$0] }
            let short = shortWords(languages: job.languages)
            let segmented = KeyboardMultipartSegmenter.retrieve(token, sources: packs, shortWords: short,
                                                                 touch: touch.current, calibration: job.calibration)
            multipart = segmented
            var baseline = KeyboardMultipartSegmenter.noveltyBaseline
            if case .result(let reading) = whole {
                for candidate in reading.candidates.prefix(8) where !candidate.isCompletion {
                    baseline = max(baseline, candidate.score - reading.literalSpatialScore)
                }
            }
            for run in segmented.runs where run.score > baseline {
                retain(Candidate(kind: .split, original: job.token,
                                 replacement: run.words.joined(separator: " "),
                                 score: run.score, baseline: baseline))
            }
        }
        return result()
    }
}
