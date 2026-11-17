import Foundation
import XCTest
@testable import Typr

/// Non-personal, fixed synthetic regression evaluation, NOT measured typing accuracy.
/// Timing is simulator timing when run by the iOS test target, never iPhone proof.
@MainActor
final class SpatialTypoEvaluationTests: XCTestCase {
    private typealias Decoder = SpatialWordDecoder
    private typealias ErrorClass = SpatialTypoEvaluationEvidence.ErrorClass
    private struct Metrics {
        var count = 0
        var recalled = 0
        var correctAuto = 0
        var wrongAuto = 0
        var incomplete = 0
        var unavailable = 0
        var milliseconds: [Double] = []
        var visits: [Double] = []
        var generated: [Double] = []

        private func work(_ values: [Double]) -> String {
            let sorted = values.sorted()
            let mean = values.reduce(0, +) / Double(max(1, values.count))
            let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
            return "\(String(format: "%.1f", mean))/\(Int(p95))/\(Int(values.max() ?? 0))"
        }

        var row: String {
            let sorted = milliseconds.sorted()
            let mean = milliseconds.reduce(0, +) / Double(max(1, count))
            let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
            return "n=\(count) r@3=\(recalled)/\(count) autoOK=\(correctAuto) wrongAuto=\(wrongAuto) incomplete=\(incomplete) unavailable=\(unavailable) meanMs=\(String(format: "%.2f", mean)) p95Ms=\(String(format: "%.2f", p95)) visits(mean/p95/max)=\(work(visits)) generated(mean/p95/max)=\(work(generated))"
        }
    }
    private let grid = KeyboardLayout(width: 393, orientation: .portrait, layer: .letters, field: .text,
                                      showsGlobe: false, showsStrip: true)

    private func evidence(_ word: String, error: ErrorClass? = nil, ordinal: Int,
                          seed: UInt64, sigma: Double) throws -> KeyboardTouchWord {
        try SpatialTypoEvaluationEvidence.evidence(word, grid: grid, error: error, ordinal: ordinal,
                                                   seed: seed, sigma: sigma)
    }

    private func observe(_ evidence: KeyboardTouchWord, intended: String, decoder: Decoder,
                         edits: Bool, metrics: inout Metrics) {
        let start = ProcessInfo.processInfo.systemUptime
        // Both languages in the same queue, also for the monolingual fixture groups.
        let result = decoder.decode(evidence, languages: [.german, .english], allowsEdits: edits)
        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1_000
        metrics.count += 1
        metrics.milliseconds.append(elapsed)
        guard let result else { metrics.unavailable += 1; return }
        metrics.visits.append(Double(result.visits))
        metrics.generated.append(Double(result.generated))
        if !result.complete { metrics.incomplete += 1 }
        // Display list: exact above-literal candidates, then best-effort edit suggestions.
        if result.suggestions.prefix(3).contains(where: { $0.word == intended.lowercased() }) { metrics.recalled += 1 }
        // Deterministic proxy only: corpus membership, NOT UITextChecker/system validity.
        if case .replace(let candidate) = result.automaticDecision(literalIsValid: result.literalInLexicon) {
            if candidate.word == intended.lowercased() { metrics.correctAuto += 1 } else { metrics.wrongAuto += 1 }
        }
    }

    /// TUNE half: even fixture indices. Structural calibration was selected on this half only.
    func testFixedGermanEnglishEvaluation() throws {
        try evaluate(seed: 0x545950525f503031, sigma: 0.18, half: 0)
    }

    /// HOLDOUT half: odd fixture indices with a different seed and sigma; never used for tuning.
    func testHeldOutNoiseEvaluation() throws {
        try evaluate(seed: 0x545950525f503032, sigma: 0.22, half: 1)
    }

    private func evaluate(seed: UInt64, sigma: Double, half: Int) throws {
        let sources = try XCTUnwrap(BundledKeyboardData.lexicons)
        let decoder = Decoder(lexicons: sources)
        let germanWords: [String] = SpatialTypoEvaluationFixtures.german
        let englishWords: [String] = SpatialTypoEvaluationFixtures.english
        let groups: [(Decoder.Language, [String])] = [(Decoder.Language.german, germanWords),
                                                      (Decoder.Language.english, englishWords)]
        let seedHex: String = String(seed, radix: 16)
        let typoSplit: String = half == 0 ? "tune (even" : "holdout (odd"
        var lines: [String] = ["TYPR-EVAL seed=0x\(seedHex) sigma=\(sigma) pitch; portrait=393; personal=off; typos=\(typoSplit) fixture indices); controls=all",
                     "TYPR-EVAL A=static same-length; B=edits; both languages interleaved; validity=corpus membership (not system checker)",
                     "TYPR-EVAL times=simulator timing, not iPhone; controls wrongAuto=unwanted auto replacements"]
        var controls: [String] = []
        var ordinal = 0
        for (language, fixed) in groups {
            let source = try XCTUnwrap(sources[language])
            let words = fixed.filter { source.logPrior(for: $0) != nil }
            let skips = fixed.count - words.count
            lines.append("TYPR-EVAL \(language.rawValue) fixed=\(fixed.count) absentSkips=\(skips)")
            XCTAssertGreaterThanOrEqual(words.count, 120, "fixed common-word coverage")
            controls.append(contentsOf: words)
            var structuralRecalled = 0, structuralCount = 0
            for error in ErrorClass.allCases {
                var a = Metrics(), b = Metrics()
                for (position, word) in words.enumerated() {
                    // Ordinals run over the full list, so each half keeps its words' samples.
                    defer { ordinal += 1 }
                    guard position % 2 == half else { continue }
                    let samples = try evidence(word, error: error, ordinal: ordinal, seed: seed, sigma: sigma)
                    observe(samples, intended: word, decoder: decoder, edits: false, metrics: &a)
                    observe(samples, intended: word, decoder: decoder, edits: true, metrics: &b)
                }
                lines.append("TYPR-EVAL \(language.rawValue) \(error.rawValue) A \(a.row)")
                lines.append("TYPR-EVAL \(language.rawValue) \(error.rawValue) B \(b.row)")
                XCTAssertEqual(a.wrongAuto, 0, "same-length wrong auto: \(language.rawValue) \(error.rawValue)")
                XCTAssertEqual(b.wrongAuto, 0, "edit-aware wrong auto: \(language.rawValue) \(error.rawValue)")
                if [.missing, .extra, .transposition].contains(error) {
                    structuralRecalled += b.recalled
                    structuralCount += b.count
                    // Linux display-only retrieval: 53-100% per class/half; floor keeps a wide margin.
                    XCTAssertGreaterThanOrEqual(Double(b.recalled) / Double(max(1, b.count)), 0.40,
                                                "structural recall@3 floor: \(language.rawValue) \(error.rawValue)")
                } else {
                    XCTAssertGreaterThanOrEqual(Double(b.recalled) / Double(max(1, b.count)), 0.95,
                                                "neighbour recall@3 floor: \(language.rawValue) \(error.rawValue)")
                }
            }
            // Centred structural typos rarely beat the literal under log(.01) and the 0.35
            // prior weight, so recall comes from the best-effort below-literal edit
            // suggestions (absent literals only). Measured Linux pooled recall: 82-90%
            // per language and half with display-only retrieval, versus 2-5% above-literal only.
            // This is a regression floor, not an accuracy claim; structural auto stays ~0 by design.
            XCTAssertGreaterThanOrEqual(Double(structuralRecalled) / Double(max(1, structuralCount)), 0.70,
                                        "pooled structural recall@3 floor: \(language.rawValue)")
        }
        controls += SpatialTypoEvaluationFixtures.germanNouns.map { $0.lowercased() }
        controls += SpatialTypoEvaluationFixtures.short
        controls += SpatialTypoEvaluationFixtures.novel
        // Appended after the original controls, so their ordinals and samples are unchanged.
        controls += SpatialTypoEvaluationFixtures.absent
        controls += SpatialTypoEvaluationFixtures.rare
        let outside = (SpatialTypoEvaluationFixtures.novel + SpatialTypoEvaluationFixtures.absent).filter { word in
            sources.values.allSatisfy { $0.logPrior(for: word.lowercased()) == nil }
        }
        let rare = SpatialTypoEvaluationFixtures.rare.filter { word in
            sources.values.contains { $0.logPrior(for: word) != nil }
        }
        XCTAssertGreaterThanOrEqual(outside.count, 200, "at least 200 genuinely out-of-lexicon controls")
        XCTAssertGreaterThanOrEqual(rare.count, 100, "at least 100 rare in-lexicon controls")
        lines.append("TYPR-EVAL controls=\(controls.count) outside=\(outside.count) rarePresent=\(rare.count); nouns typed lowercase; mixed EN/DE; short words; names/technical/product/abbreviation/compound/unusual-spelling strings")
        XCTAssertGreaterThanOrEqual(controls.count, 600)
        for edits in [false, true] {
            var known = Metrics(), unknown = Metrics()
            for (index, word) in controls.enumerated() {
                let sample = try evidence(word, ordinal: 50_000 + index, seed: seed, sigma: sigma)
                let inLexicon = sources.values.contains { $0.logPrior(for: word.lowercased()) != nil }
                if inLexicon { observe(sample, intended: word, decoder: decoder, edits: edits, metrics: &known) }
                else { observe(sample, intended: word, decoder: decoder, edits: edits, metrics: &unknown) }
            }
            let variant = edits ? "B" : "A"
            lines.append("TYPR-EVAL controls inLexicon \(variant) \(known.row)")
            lines.append("TYPR-EVAL controls outside \(variant) \(unknown.row)")
            XCTAssertEqual(known.wrongAuto, 0, "no unwanted auto replacements on in-lexicon controls")
            XCTAssertEqual(unknown.wrongAuto, 0, "no unwanted auto replacements on out-of-lexicon controls")
            let failed = known.incomplete + unknown.incomplete + known.unavailable + unknown.unavailable
            XCTAssertLessThanOrEqual(Double(failed) / Double(controls.count), 0.05, "control evidence/search availability")
        }
        // Keep real noisy-touch decoder prefix sentinels from four fixed control words, with both
        // edit modes and both seeds/sigmas. Lexical SpatialPrefixSearch is a different path.
        // These replace the diagnostic-only all-prefix sweep, not a prefix-quality gate.
        for (index, word) in controls.enumerated().filter({ $0.element.count >= 6 }).prefix(4) {
            let full = try evidence(word, ordinal: 90_000 + index, seed: seed, sigma: sigma)
            for length in [3, word.count - 1] {
                let prefix = KeyboardTouchWord(layout: grid, samples: Array(full.samples.prefix(length)))
                for edits in [false, true] {
                    let result = try XCTUnwrap(decoder.decode(prefix, languages: [.german, .english],
                                                             allowsEdits: edits),
                                              "\(word), prefix length \(length), edits=\(edits)")
                    XCTAssertEqual(prefix.text, String(word.prefix(length)))
                    XCTAssertGreaterThan(result.visits, 0)
                    XCTAssertLessThanOrEqual(result.visits, Decoder.searchBudget)
                    XCTAssertLessThanOrEqual(result.generated, Decoder.maxGenerated)
                }
            }
        }
        let table = lines.joined(separator: "\n")
        print(table)
        let attachment = XCTAttachment(string: table)
        attachment.name = "Typr fixed DE-EN spatial evaluation"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
