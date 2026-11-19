import Foundation
import XCTest
@testable import Typr

extension KeyboardBoundaryDecoderTests {
    // Typr-authored public phrase fixtures, not upstream test data or collected text.
    private static let dePhrases = [
        "ich habe", "das ist", "kannst du", "es ist", "in der", "in die", "am ende", "zu dir",
        "du bist", "ich bin", "wir sind", "er hat", "sie hat", "ist das", "hast du", "ich will",
        "und ich", "mit dem", "auf die", "auf dem", "im haus", "so ist", "es war", "zu mir"
    ]
    private static let enPhrases = [
        "great day", "this is", "in the", "I am", "a day", "you are", "we are", "it is",
        "is the", "of the", "to the", "at home", "my friend", "can you", "do you", "for the",
        "and the", "on the", "I have", "he is", "as if", "by the", "go to", "with you"
    ]
    private static let mixedPhrases = [
        "ich have", "das is", "great tag", "in die", "am ende", "my haus", "du are", "wir have",
        "you bist", "the haus", "und the", "mit you", "mein friend", "guten day", "ein day", "a haus"
    ]

    private static var validControls: [String] {
        let compounds = ["Haustür", "Kindergarten", "Bahnhof", "Fahrrad", "Haustürschlüssel", "Kindergartenplatz",
                         "Tastaturbelegung", "keyboard", "something", "somewhere", "doorframe", "rainjacket"]
        let identifiers = (0..<80).flatMap { ["greatday_\($0)", "ichhabe\($0)", "myValue\($0)"] }
        return SpatialTypoEvaluationFixtures.absent + SpatialTypoEvaluationFixtures.novel + compounds + identifiers
    }

    private func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
    private func fmt(_ value: Double) -> String { String(format: "%.4f", value) }
    private func p95(_ values: [Double]) -> Double { values.sorted()[Int(Double(values.count - 1) * 0.95)] }

    /// Evaluation premise for the merged fixture literals: a real dictionary does not list
    /// FrequencyWords merge noise such as "inthe"/"ofthe". "indie" is a genuine English word
    /// and stays valid. The pessimistic corpus proxy (every TSW1 entry valid) is reported too.
    static func mergedLiterals(_ phrases: [String]) -> Set<String> {
        Set(phrases.map { $0.replacingOccurrences(of: " ", with: "").lowercased() }).subtracting(["indie"])
    }

    func testEvaluationNoisyOmittedSpacesAgainstNoBoundaryBaseline() async throws {
        let sources = try resources()
        let modes: [(String, Set<Language>, [String])] = [
            ("DE", [.german], Self.dePhrases), ("EN", [.english], Self.enPhrases),
            ("mixed", [.german, .english], Self.mixedPhrases)
        ]
        let model = try contextModel()
        for (name, languages, phrases) in modes {
            let merged = Self.mergedLiterals(phrases)
            // [context, lexical-only] × [merge-noise premise, corpus-as-dictionary proxy].
            let engines = [
                engine(sources, languages: languages, rejected: merged, model: model),
                engine(sources, languages: languages, model: model),
                engine(sources, languages: languages, rejected: merged),
                engine(sources, languages: languages)
            ]
            let ac = engines[0]
            let worker = KeyboardSuggestionWorker()
            var n = 0, recall1 = 0, recall3 = 0, lexicalRecall3 = 0, baseline3 = 0
            var strip1 = [0, 0, 0, 0], strip3 = [0, 0, 0, 0]
            var autoSplits = 0, autoCorrect = 0, autoWrong = 0, wholeCorpus = 0, weakened = 0
            var maxQueries = 0, maxContextQueries = 0
            var times: [Double] = []
            for (ordinal, phrase) in phrases.enumerated() where EvaluationSample.includes(ordinal, every: 4) {
                let typed = phrase.replacingOccurrences(of: " ", with: "").lowercased()
                let expected = phrase.lowercased()
                for seed: UInt64 in [0x50355f54554e45, 0x50355f484f4c44] {
                    let evidence = try SpatialTypoEvaluationEvidence.evidence(
                        typed, grid: grid, ordinal: ordinal, seed: seed, sigma: 0.18)
                    n += 1
                    for (index, current) in engines.enumerated() {
                        current.discardEvidence()
                        var before = ""
                        for sample in evidence.samples {
                            let after = before + sample.text
                            current.touchInput.append(text: sample.text, point: sample.point, key: sample.key,
                                                      layout: grid, before: before, after: after)
                            before = after
                        }
                        let ownership = KeyboardSuggestionOwnership(
                            engine: UUID(), revision: 1, context: typed, token: typed, field: .text,
                            permitsCorrection: true, configuration: current.suggestionConfiguration,
                            learning: current.learning.generation, feedbackEpoch: current.learning.feedbackEpoch,
                            resources: current.spatialDecoder?.resourceRevision ?? -1, layout: grid)
                        let request = current.suggestionRequest(ownership: ownership, evidence: evidence)
                        let job = try XCTUnwrap(request.boundary)
                        var completed: KeyboardSuggestionWorker.Result?
                        worker.submit(prepare: { request }, finish: { completed = $0 })
                        await worker.waitUntilIdle()
                        let result = try XCTUnwrap(completed)
                        let retrieval = try XCTUnwrap(result.boundary)
                        let words = retrieval.candidates.map { $0.replacement.lowercased() }
                        if index == 0 {
                            let start = ContinuousClock.now
                            let direct = Boundary.retrieve(job, lexicons: sources, whole: result.outcome,
                                                           model: request.boundaryModel)
                            times.append(ms(start.duration(to: .now)))
                            XCTAssertEqual(direct.candidates, retrieval.candidates, "Worker and synchronous retrieval")
                            maxQueries = max(maxQueries, retrieval.lexicalQueries)
                            maxContextQueries = max(maxContextQueries, retrieval.contextQueries)
                            if words.first == expected { recall1 += 1 }
                            if words.prefix(3).contains(expected) { recall3 += 1 }
                            if retrieval.candidates.contains(where: { $0.weakWhole }) { weakened += 1 }
                            if languages.contains(where: { sources[$0]?.logPrior(for: typed) != nil }) { wholeCorpus += 1 }
                            let empty = Boundary.Retrieval(job: job, candidates: [], lexicalQueries: 0)
                            let baseline = current.suggestions(beforeInput: typed, field: .text,
                                                               autocorrectionType: .default, boundaryRetrieval: empty)
                            if baseline.map({ $0.replacement.lowercased() }).prefix(3).contains(expected) { baseline3 += 1 }
                        }
                        if index == 2, words.prefix(3).contains(expected) { lexicalRecall3 += 1 }
                        let strip = current.finishSuggestions(result)
                        let alternatives = strip.filter { $0.kind != .keepLiteral }.map { $0.replacement.lowercased() }
                        if alternatives.first == expected { strip1[index] += 1 }
                        if alternatives.prefix(3).contains(expected) { strip3[index] += 1 }
                        autoSplits += strip.filter { $0.boundary != nil && $0.willAutoReplace }.count
                        let automatic = current.replacementOnSpace(beforeInput: typed, field: .text,
                                                                   autocorrectionType: .default)
                        if let replacement = automatic?.replacement, replacement.contains(" ") {
                            if replacement.lowercased() == expected { autoCorrect += 1 } else { autoWrong += 1 }
                        }
                    }
                }
            }
            XCTAssertGreaterThanOrEqual(Double(recall3) / Double(n), 0.70, name)
            XCTAssertGreaterThan(strip3[0], baseline3)
            // Context must not trade away recall for any selection, under either proxy.
            XCTAssertGreaterThanOrEqual(recall3, lexicalRecall3, name)
            XCTAssertGreaterThanOrEqual(strip3[0], strip3[2], name)
            XCTAssertGreaterThanOrEqual(strip3[1], strip3[3], name)
            if name == "EN", EvaluationSample.isFull {
                XCTAssertGreaterThan(strip3[0], strip3[2], "Merge-noise weakening helps English")
            }
            XCTAssertEqual(autoWrong, 0, name)
            XCTAssertLessThanOrEqual(autoSplits, autoCorrect, name)
            XCTAssertLessThanOrEqual(maxQueries, Boundary.maximumLexicalQueries)
            XCTAssertLessThanOrEqual(maxContextQueries, Boundary.maximumContextQueries)
            print("EVAL P5_omitted language=\(name) n=\(n) recall1=\(recall1) recall3=\(recall3) lexical_recall3=\(lexicalRecall3) strip1=\(strip1[0]) strip3=\(strip3[0]) lexical_strip3=\(strip3[2]) corpus_proxy_strip3=\(strip3[1]) corpus_proxy_lexical_strip3=\(strip3[3]) baseline_strip3=\(baseline3) corpus_whole=\(wholeCorpus) weakened_whole=\(weakened) auto_correct=\(autoCorrect) auto_wrong=\(autoWrong) auto_chips=\(autoSplits) queries_max=\(maxQueries) context_queries_max=\(maxContextQueries) mean_ms=\(fmt(times.reduce(0,+)/Double(n))) p95_ms=\(fmt(p95(times))) max_ms=\(fmt(times.max() ?? 0)) validity=merge_noise_premise NOT-iPhone")
        }
    }

    func testEvaluationValidCompoundsNamesIdentifiersAndCodeSwitchesHaveZeroFalseAutos() throws {
        let sources = try resources()
        let controls = Self.validControls
        XCTAssertGreaterThanOrEqual(Set(controls).count, 300)
        let model = try contextModel()
        let ac = engine(sources, trusted: Set(controls.map { $0.lowercased() }), model: model)
        var unwanted = 0, boundaryAuto = 0, splitChips = 0
        for (index, token) in controls.enumerated() where EvaluationSample.includes(index, every: 5) {
            let context = (index % 2 == 0 ? "the " : "die ") + token
            let suggestions = strip(ac, context)
            splitChips += suggestions.filter { $0.boundary?.kind == .split }.count
            boundaryAuto += suggestions.filter { $0.boundary != nil && $0.willAutoReplace }.count
            if ac.replacementOnSpace(beforeInput: context, field: .text, autocorrectionType: .default) != nil { unwanted += 1 }
        }
        XCTAssertEqual(unwanted, 0)
        XCTAssertEqual(boundaryAuto, 0)
        XCTAssertEqual(splitChips, 0, "The checker accepts these synthetic valid literals")
        // OOV productive compounds cannot be reliably distinguished from omitted spaces.
        // Report those tempting suggestions separately, never pretend they are automatic precision.
        let unknown = engine(sources, model: model), lexical = engine(sources)
        var oovSplitSuggestions = 0, lexicalOOVSplitSuggestions = 0
        var oovTokens: [String] = []
        for (index, token) in SpatialTypoEvaluationFixtures.absent.enumerated()
            where EvaluationSample.includes(index, every: 5) {
            let chips = strip(unknown, token).filter { $0.boundary?.kind == .split }
            oovSplitSuggestions += chips.count
            if !chips.isEmpty { oovTokens.append(token) }
            lexicalOOVSplitSuggestions += strip(lexical, token).filter { $0.boundary?.kind == .split }.count
        }
        XCTAssertLessThanOrEqual(oovSplitSuggestions, lexicalOOVSplitSuggestions, "Context adds no OOV chips")
        var oovAutos = 0
        for (index, token) in SpatialTypoEvaluationFixtures.absent.enumerated()
            where EvaluationSample.includes(index, every: 5) && Boundary.isEligible(token) {
            let lower = token.lowercased()
            installMultipart(try multipartTouch(lower, aimed: lower), in: unknown)
            if unknown.replacementOnSpace(beforeInput: "the " + lower, field: .text,
                                          autocorrectionType: .default)?.replacement.contains(" ") == true { oovAutos += 1 }
        }
        XCTAssertEqual(oovAutos, 0)
        print("EVAL P5_controls unique=\(Set(controls).count) unwanted=\(unwanted) boundary_auto=\(boundaryAuto) valid_split_chips=\(splitChips) oov_split_chips=\(oovSplitSuggestions) oov_autos=\(oovAutos) lexical_oov_split_chips=\(lexicalOOVSplitSuggestions) oov_split_tokens=\(oovTokens.joined(separator: ",")) false_auto_bound=0 validity=synthetic_valid_checker NOT-iPhone")
    }

    func testEvaluationExactJoinsAndPlausiblePairAbstention() throws {
        let sources = try resources()
        let ac = engine(sources)
        let fixtures = [("Tasta tur", "tastatur"), ("Tast atur", "tastatur"), ("Tastat ur", "tastatur"),
                        ("keyb oard", "keyboard"), ("keybo ard", "keyboard"), ("keyboa rd", "keyboard")]
        var recall1 = 0, recall3 = 0, strip3 = 0, auto = 0
        var times: [Double] = []
        for (text, expected) in fixtures {
            let parts = text.split(separator: " ").map(String.init)
            let start = ContinuousClock.now
            let result = Boundary.retrieve(job(parts[1], previous: parts[0]), lexicons: sources)
            times.append(ms(start.duration(to: .now)))
            if result.candidates.first?.replacement == expected { recall1 += 1 }
            if result.candidates.prefix(3).contains(where: { $0.replacement == expected }) { recall3 += 1 }
            let chips = strip(ac, text)
            if chips.contains(where: { $0.replacement.lowercased() == expected }) { strip3 += 1 }
            auto += chips.filter { $0.boundary?.kind == .join && $0.willAutoReplace }.count
        }
        let pairs = ["some thing", "in side", "a bout", "an other", "key board", "the best", "ich habe",
                     "das ist", "in the", "am ende", "my haus", "und the"]
        let wrong = pairs.filter { text in strip(ac, text).contains { $0.boundary?.kind == .join } }.count
        XCTAssertGreaterThanOrEqual(recall3, 4)
        XCTAssertGreaterThanOrEqual(strip3, 4)
        XCTAssertEqual(auto, 0)
        XCTAssertEqual(wrong, 0)
        print("EVAL P5_join n=\(fixtures.count) recall1=\(recall1) recall3=\(recall3) strip3=\(strip3) auto=\(auto) plausible_pairs=\(pairs.count) unwanted_join_chips=\(wrong) mean_ms=\(fmt(times.reduce(0,+)/Double(times.count))) max_ms=\(fmt(times.max() ?? 0)) policy=exact_suggestion_only NOT-iPhone")
    }

#if TYPR_RESEARCH
    /// Rejected policy experiment, NOT production authority. A threshold grid over
    /// retained-bigram evidence, whole margin, runner margin and corpus-noise origin is
    /// evaluated on invalid lowercase literals only. Useful variants also split OOV
    /// product tokens; zero-false variants recover <10%, so no automatic gate is installed.
    func testEvaluationStrictAutomaticSplitGateIsUnsafeForOOVProducts() throws {
        for imported in [false, true] { try evaluateAutomaticGate(imported: imported) }
    }

    private func evaluateAutomaticGate(imported: Bool) throws {
        let sources = try resources(), model = try contextModel()
        // Same names/products that invalidated round one; imports are optional, never
        // a premise that every valid OOV literal has been imported.
        var builder = ProtectedPersonalLexicon.Builder()
        builder.add("andi asa bea ina isa malin ami ora todo AtHome GoTo Itis WithYou GitHub YouTube iPhone ThinkPad OpenAI OneDrive WhatsApp FaceTime PowerPoint TypeScript WordPress getValue setValue isEmpty")
        let protected = builder.build()
        struct Gate {
            let name: String
            let whole: Double
            let runner: Double
            let noiseOnly: Bool
        }
        let gates = [
            Gate(name: "w100_r10", whole: log(100), runner: log(10), noiseOnly: false),
            Gate(name: "w1e3_r100", whole: log(1_000), runner: log(100), noiseOnly: false),
            Gate(name: "w1e4_r1e3", whole: log(10_000), runner: log(1_000), noiseOnly: false),
            Gate(name: "noise_w100_r10", whole: log(100), runner: log(10), noiseOnly: true)
        ]
        func proposed(_ ac: AutocorrectEngine, _ token: String) -> [String?] {
            guard token == token.lowercased(), !ac.checker.isWordValid(token),
                  ac.german?.isValid(token) != true else { return gates.map { _ in nil } }
            let candidates = strip(ac, token).compactMap(\.boundary).filter { $0.kind == .split }
            return gates.map { gate in
                guard let first = candidates.first, first.strongPair, !gate.noiseOnly || first.weakWhole,
                      first.score - first.baseline >= gate.whole,
                      candidates.count < 2 || first.score - candidates[1].score >= gate.runner else { return nil }
                return first.replacement
            }
        }
        let modes: [(Set<Language>, [String])] = [
            ([.german], Self.dePhrases), ([.english], Self.enPhrases),
            ([.german, .english], Self.mixedPhrases)
        ]
        var correct = Array(repeating: 0, count: gates.count), wrong = correct
        let phraseCount = modes.reduce(0) { $0 + $1.1.count }
        for (languages, phrases) in modes {
            // Same merge-noise dictionary premise as the recall evaluation.
            let ac = engine(sources, languages: languages, rejected: Self.mergedLiterals(phrases), model: model)
            if imported { ac.loadProtectedLexicon(protected) }
            for phrase in phrases {
                let token = phrase.replacingOccurrences(of: " ", with: "").lowercased()
                for (index, replacement) in proposed(ac, token).enumerated() {
                    guard let replacement else { continue }
                    if replacement == phrase.lowercased() { correct[index] += 1 } else { wrong[index] += 1 }
                }
            }
        }
        // Public product/name-like spellings and code identifiers, also tested as
        // unknown lowercase forms. AtHome is an intentional product token, not "at home".
        let products = ["AtHome", "athome", "GoTo", "goto", "Itis", "itis", "WithYou", "withyou",
                        "GitHub", "github", "YouTube", "youtube", "iPhone", "iphone", "ThinkPad", "thinkpad",
                        "OpenAI", "openai", "OneDrive", "onedrive", "WhatsApp", "whatsapp", "FaceTime", "facetime",
                        "PowerPoint", "powerpoint", "TypeScript", "typescript", "WordPress", "wordpress",
                        "getValue", "getvalue", "setValue", "setvalue", "isEmpty", "isempty"]
        // Lowercase names/terms that ARE FrequencyWords entries with a strong-pair split (found by
        // scanning both TSW1 packs) and that a real dictionary may not list, exactly like merge
        // noise: casual "hey ina", "andi", "malin", a "todo" note. The checker rejects them here.
        let corpusNames = ["andi", "asa", "bea", "ina", "isa", "malin", "ami", "ora", "todo"]
        var validFalse = correct.map { _ in 0 }, oovFalse = validFalse, productFalse = validFalse
        var nameFalse = validFalse
        var falseProducts = gates.map { _ in [String]() }
        var actualFalse = 0
        for (languages, _) in modes {
            let ac = engine(sources, languages: languages, model: model)
            let unlisted = engine(sources, languages: languages, rejected: Set(corpusNames), model: model)
            if imported { ac.loadProtectedLexicon(protected); unlisted.loadProtectedLexicon(protected) }
            for name in corpusNames {
                for (index, value) in proposed(unlisted, name).enumerated() where value != nil {
                    nameFalse[index] += 1; falseProducts[index].append(name)
                }
                if unlisted.replacementOnSpace(beforeInput: "hey " + name, field: .text,
                                               autocorrectionType: .default)?.replacement.contains(" ") == true {
                    actualFalse += 1
                }
            }
            let trusted = engine(sources, languages: languages,
                                 trusted: Set((Self.validControls + products).map { $0.lowercased() }), model: model)
            if imported { trusted.loadProtectedLexicon(protected) }
            for token in Self.validControls + products {
                for (index, value) in proposed(trusted, token).enumerated() where value != nil { validFalse[index] += 1 }
            }
            for token in SpatialTypoEvaluationFixtures.absent {
                for (index, value) in proposed(ac, token).enumerated() where value != nil { oovFalse[index] += 1 }
            }
            for product in products {
                for (index, value) in proposed(ac, product).enumerated() where value != nil {
                    productFalse[index] += 1; falseProducts[index].append(product)
                }
            }
            for token in Self.validControls + SpatialTypoEvaluationFixtures.absent + products {
                let context = "the " + token
                if ac.replacementOnSpace(beforeInput: context, field: .text, autocorrectionType: .default)?.replacement.contains(" ") == true {
                    actualFalse += 1
                }
            }
        }
        XCTAssertGreaterThan(correct[0], 0, "Meaningful proposed recall alone is insufficient")
        for index in gates.indices {
            let falseAutos = wrong[index] + validFalse[index] + oovFalse[index] + productFalse[index] + nameFalse[index]
            // The installed policy depends on this: no evaluated variant has both zero false
            // automatic splits and meaningful (≥10%) omitted-space recall.
            if !imported {
                XCTAssertTrue(falseAutos > 0 || Double(correct[index]) < 0.10 * Double(phraseCount), gates[index].name)
            }
            let precision = correct[index] + falseAutos == 0 ? "NA"
                : fmt(Double(correct[index]) / Double(correct[index] + falseAutos))
            print("EVAL P5b_auto_gate_trial personal_lexicon=\(imported) gate=\(gates[index].name) proposed_n=\(phraseCount) proposed_correct=\(correct[index]) proposed_wrong=\(wrong[index]) proposed_recall=\(fmt(Double(correct[index])/Double(phraseCount))) proposed_precision=\(precision) valid_false=\(validFalse[index]) oov_false=\(oovFalse[index]) product_oov_false=\(productFalse[index]) corpus_name_false=\(nameFalse[index]) false_tokens=\(falseProducts[index].isEmpty ? "none" : falseProducts[index].joined(separator: ",")) NOT-iPhone")
        }
        XCTAssertEqual(actualFalse, 0)
        print("EVAL P5b_auto_gate personal_lexicon=\(imported) modes=3 variants=\(gates.count) valid_controls=\(3 * (Self.validControls.count + products.count)) oov_controls=\(3 * SpatialTypoEvaluationFixtures.absent.count) product_controls=\(3 * products.count) corpus_name_controls=\(3 * corpusNames.count) actual_false=\(actualFalse) actual_recall=0 actual_precision=NA_suggestion_only decision=rejected NOT-iPhone")
    }
#endif

    func testEvaluationBoundsAtMaximumPersonalCapacityAndAdversarialLengths() throws {
        let sources = try resources()
        var counts: [String: Int] = [:]
        for index in 0..<2_000 {
            var value = index
            var suffix = ""
            for _ in 0..<3 { suffix.append(Character(UnicodeScalar(97 + value % 26)!)); value /= 26 }
            counts["velq" + suffix] = 2
        }
        let personal = PersonalLexiconSnapshot(kept: [], counts: counts, rejected: [])
        let model = try contextModel()
        var times: [Double] = []
        var maxQueries = 0, maxContextQueries = 0
        for length in 1...64 where EvaluationSample.includes(length - 1, every: 7) {
            for token in [String(repeating: "a", count: length), String(repeating: "i", count: length)] {
                let start = ContinuousClock.now
                var input = job(token, previous: "the", personal: personal)
                input.context = .init(previous: "the", weightDE: 0.5)
                let result = Boundary.retrieve(input, lexicons: sources, model: model)
                times.append(ms(start.duration(to: .now)))
                maxQueries = max(maxQueries, result.lexicalQueries)
                XCTAssertLessThanOrEqual(result.candidates.count, Boundary.resultLimit)
                XCTAssertLessThanOrEqual(result.lexicalQueries, Boundary.maximumLexicalQueries)
                maxContextQueries = max(maxContextQueries, result.contextQueries)
                XCTAssertLessThanOrEqual(result.contextQueries, Boundary.maximumContextQueries)
                XCTAssertLessThanOrEqual(result.languageEvidenceQueries, Boundary.maximumLanguageEvidenceQueries)
                XCTAssertEqual(result.candidates, Boundary.retrieve(result.job, lexicons: sources, model: model).candidates)
            }
        }
        let pairBytes = AutocorrectEngine.boundaryRejectionLimit * (MemoryLayout<RejectedCorrection>.stride + 130)
        XCTAssertLessThan(Boundary.shortWordPayloadBytes, 1_024)
        XCTAssertLessThan(Boundary.maximumCandidatePayloadBytes, 2_048)
        XCTAssertLessThan(pairBytes, 16_384)
        XCTAssertLessThan(Boundary.maximumContextPayloadBytes, 384)
        print("EVAL P5_bounds calls=\(times.count) personal_words=\(personal.scan.entries.count) queries_max=\(maxQueries) query_cap=\(Boundary.maximumLexicalQueries) context_queries_max=\(maxContextQueries) context_query_cap=\(Boundary.maximumContextQueries) context_payload_bytes=\(Boundary.maximumContextPayloadBytes) shared_context_pack_bytes=\(model.residentPayloadBytes) trie_edge_cap=\(Boundary.maximumTrieEdgeChecks) candidate_payload_bytes=\(Boundary.maximumCandidatePayloadBytes) short_word_payload_bytes=\(Boundary.shortWordPayloadBytes) letter_array_payload_bytes=\(Boundary.maxLetters * MemoryLayout<Character>.stride) session_pair_payload_bytes=\(pairBytes) mean_ms=\(fmt(times.reduce(0,+)/Double(times.count))) p95_ms=\(fmt(p95(times))) max_ms=\(fmt(times.max() ?? 0)) memory=element_payload_NOT_RSS NOT-iPhone")
    }
}
