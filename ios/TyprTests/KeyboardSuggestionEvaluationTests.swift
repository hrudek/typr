import Foundation
import XCTest
@testable import Typr

/// Synthetic public fixtures + deterministic corpus-membership checker, NOT Apple's dictionaries,
/// measured typing accuracy, simulator or iPhone performance. Compares the old synchronous API
/// with real serial-worker search followed by the same main-actor spelling/policy step.
@MainActor
final class KeyboardSuggestionEvaluationTests: XCTestCase {
    private typealias Decoder = SpatialWordDecoder
    private final class CorpusChecker: TextChecking {
        let lexicons: [SpatialWordLexicon]
        let trusted: Set<String>
        var answer: String?
        var calls = 0
        init(_ lexicons: [SpatialWordLexicon], trusted: Set<String> = []) {
            self.lexicons = lexicons
            self.trusted = trusted
        }
        func isWordValid(_ word: String) -> Bool {
            calls += 1
            return trusted.contains(word.lowercased()) || lexicons.contains { $0.logPrior(for: word.lowercased()) != nil }
        }
        func guesses(for word: String) -> [String] { calls += 1; return answer.map { [$0] } ?? [] }
        func completions(for prefix: String) -> [String] { calls += 1; return [] }
    }
    private let grid = KeyboardLayout(width: 393)
    private let engineID = UUID()

    private func resources() throws -> [Decoder.Language: SpatialWordLexicon] {
        try XCTUnwrap(BundledKeyboardData.lexicons)
    }

    private func engine(_ sources: [Decoder.Language: SpatialWordLexicon], languages: Set<Decoder.Language>,
                        answer: String? = nil, trusted: Set<String> = []) -> AutocorrectEngine {
        let english = CorpusChecker(sources[.english].map { [$0] } ?? [], trusted: trusted)
        english.answer = answer
        let ac = AutocorrectEngine(checker: english, spatialDecoder: Decoder(lexicons: sources))
        ac.englishEnabled = languages.contains(.english)
        if languages.contains(.german) {
            let german = CorpusChecker(sources[.german].map { [$0] } ?? [], trusted: trusted)
            german.answer = answer
            ac.german = GermanAutocorrect(checker: german)
        }
        return ac
    }

    private func install(_ word: KeyboardTouchWord, in ac: AutocorrectEngine) {
        var before = ""
        for sample in word.samples {
            let after = before + sample.text
            ac.touchInput.append(text: sample.text, point: sample.point, key: sample.key,
                                 layout: word.layout, before: before, after: after)
            before = after
        }
    }

    private func ownership(_ word: KeyboardTouchWord, ac: AutocorrectEngine) -> KeyboardSuggestionOwnership {
        .init(engine: engineID, revision: 1, context: word.text, token: word.text, field: .text,
              permitsCorrection: true, configuration: ac.suggestionConfiguration,
              learning: ac.learning.generation, feedbackEpoch: ac.learning.feedbackEpoch,
              resources: ac.spatialDecoder?.resourceRevision ?? -1, layout: grid)
    }

    private func ranked(_ request: KeyboardSuggestionWorker.Request, worker: KeyboardSuggestionWorker) async throws
        -> KeyboardSuggestionWorker.Result {
        var completed: KeyboardSuggestionWorker.Result?
        worker.submit(prepare: { request }, finish: { completed = $0 })
        await worker.waitUntilIdle()
        return try XCTUnwrap(completed)
    }

    func testFrozenFixturesMatchSynchronousSuggestionsAndBoundaryDecisions() async throws {
        let sources = try resources()
        // One worker per resource facade; resources are immutable and identical throughout this test.
        let worker = KeyboardSuggestionWorker()
        var importBuilder = ProtectedPersonalLexicon.Builder()
        importBuilder.add("Ina Malin Andi Jens Maren Siemens herdr Typr Mälin Jürgen Zoë O'Neil Alice Microsoft OpenAI Whisper")
        let imported = importBuilder.build()
        let germanWords: [String] = SpatialTypoEvaluationFixtures.german
        let englishWords: [String] = SpatialTypoEvaluationFixtures.english
        let mixedWords: [String] = germanWords + englishWords
        let germanOnly: Set<Decoder.Language> = [.german]
        let englishOnly: Set<Decoder.Language> = [.english]
        let bothLanguages: Set<Decoder.Language> = [.german, .english]
        let modes: [(String, Set<Decoder.Language>, [String])] = [
            ("DE", germanOnly, germanWords),
            ("EN", englishOnly, englishWords),
            ("mixed", bothLanguages, mixedWords)
        ]
        for (name, languages, words) in modes {
            var n = 0, recall1 = 0, recall3 = 0, automatic = 0, wrong = 0, baselineWrong = 0
            var importedRecall1 = 0, importedRecall3 = 0, importedAutomatic = 0, importedWrong = 0
            var workerMs = [Double]()
            for (ordinal, intended) in words.enumerated() where EvaluationSample.includes(ordinal, every: 79) {
                let half = ordinal % 2
                for error in SpatialTypoEvaluationEvidence.ErrorClass.allCases {
                    let word = try SpatialTypoEvaluationEvidence.evidence(intended, grid: grid, error: error,
                        ordinal: ordinal, seed: half == 0 ? 0x545950525f503031 : 0x545950525f503032,
                        sigma: half == 0 ? 0.18 : 0.22)
                    let synchronous = engine(sources, languages: languages, answer: intended)
                    let asynchronous = engine(sources, languages: languages, answer: intended)
                    install(word, in: synchronous)
                    install(word, in: asynchronous)
                    let expected = synchronous.suggestions(beforeInput: word.text, field: .text, autocorrectionType: .default)
                    let request = asynchronous.suggestionRequest(ownership: ownership(word, ac: asynchronous), evidence: word)
                    let result = try await ranked(request, worker: worker)
                    if let evidence = request.evidence {
                        let expectedOutcome = synchronous.spatialDecoder?.decodeDetailed(evidence,
                            languages: request.languages, calibration: request.calibration, personal: request.personal,
                            context: request.context, variants: request.variants)
                        XCTAssertEqual(result.outcome, expectedOutcome, "Every score, alignment, cap and candidate must match")
                        if case .result(let decoded)? = result.outcome {
                            XCTAssertLessThanOrEqual(decoded.visits, Decoder.searchBudget)
                            XCTAssertLessThanOrEqual(decoded.generated, Decoder.maxGenerated)
                        }
                    }
                    let actual = asynchronous.finishSuggestions(result)
                    XCTAssertTrue(asynchronous.learning.model.state.layouts.isEmpty, "Ranking never trains touches")
                    XCTAssertTrue(asynchronous.learning.model.lexicon.counts.isEmpty, "Ranking never trains word counts")
                    XCTAssertEqual(actual, expected, "\(name) \(intended) \(error)")
                    let boundaryA = synchronous.replacementOnSpace(beforeInput: word.text, field: .text, autocorrectionType: .default)
                    let boundaryB = asynchronous.replacementOnSpace(beforeInput: word.text, field: .text, autocorrectionType: .default)
                    XCTAssertEqual(boundaryA?.replacement, boundaryB?.replacement)
                    XCTAssertEqual(synchronous.pendingFeedback?.kind, asynchronous.pendingFeedback?.kind)
                    // Equality of final strips is stronger than recall parity; report nonliteral recall
                    // (two available alternative slots) rather than counting the always-present keep chip.
                    let alternatives = actual.filter { $0.kind != .keepLiteral }.map { $0.replacement.lowercased() }
                    // Same public fixtures and evidence, now with the name-control import loaded.
                    let withImports = engine(sources, languages: languages, answer: intended)
                    withImports.loadProtectedLexicon(imported)
                    install(word, in: withImports)
                    let importedStrip = withImports.suggestions(beforeInput: word.text, field: .text,
                                                                 autocorrectionType: .default)
                    let importedAlternatives = importedStrip.filter { $0.kind != .keepLiteral }
                        .map { $0.replacement.lowercased() }
                    if importedAlternatives.first == intended { importedRecall1 += 1 }
                    if importedAlternatives.prefix(3).contains(intended) { importedRecall3 += 1 }
                    let importedBoundary = withImports.replacementOnSpace(beforeInput: word.text, field: .text,
                                                                          autocorrectionType: .default)
                    if let importedBoundary {
                        importedAutomatic += 1
                        if importedBoundary.replacement.lowercased() != intended { importedWrong += 1 }
                    }
                    if alternatives.first == intended { recall1 += 1 }
                    if alternatives.prefix(3).contains(intended) { recall3 += 1 }
                    if let boundaryA, boundaryA.replacement.lowercased() != intended { baselineWrong += 1 }
                    if let boundaryB {
                        automatic += 1
                        if boundaryB.replacement.lowercased() != intended {
                            wrong += 1
                            print("EVAL P1_existingPolicyError mode=\(name) intended=\(intended) typed=\(word.text) actual=\(boundaryB.replacement) error=\(error)")
                        }
                    }
                    n += 1
                    workerMs.append(result.seconds * 1_000)
                }
            }
            XCTAssertEqual(importedRecall1, recall1, "Name-control imports must preserve public correction recall@1")
            XCTAssertEqual(importedRecall3, recall3, "Name-control imports must preserve public correction recall@3")
            XCTAssertEqual(importedWrong, wrong)
            XCTAssertEqual(importedAutomatic, automatic)
            print("EVAL R2_1_public_quality mode=\(name) n=\(n) before_recall1=\(recall1) after_recall1=\(importedRecall1) before_recall3=\(recall3) after_recall3=\(importedRecall3) before_auto=\(automatic) after_auto=\(importedAutomatic) before_wrong=\(wrong) after_wrong=\(importedWrong) imported_entries=\(imported.words.count) validity=synthetic-corpus NOT-iPhone")
            XCTAssertEqual(wrong, baselineWrong, "Scheduling must not change automatic quality")
            XCTAssertLessThanOrEqual(wrong, 1, "Frozen synthetic fixture bound per language mode; not a valid-word allowance")
            let recallFloor = EvaluationSample.isFull ? 0.90 : 0.70
            XCTAssertGreaterThanOrEqual(Double(recall1) / Double(n), recallFloor)
            XCTAssertGreaterThanOrEqual(Double(recall3) / Double(n), recallFloor)
            print("EVAL P1_equivalence mode=\(name) n=\(n) identical=\(n) recall@1=\(recall1)/\(n) recall@3=\(recall3)/\(n) auto=\(automatic) wrongAuto=\(wrong) baselineWrongAuto=\(baselineWrong) wrongBound=1 workerMeanMs=\(format(mean(workerMs))) workerMaxMs=\(format(workerMs.max() ?? 0)) validity=synthetic-corpus NOT-iPhone")
        }
    }

    func testValidNamesCompoundsAndCodeSwitchControlsStayUnchanged() async throws {
        let sources = try resources()
        let worker = KeyboardSuggestionWorker()
        let controls = SpatialTypoEvaluationFixtures.german + SpatialTypoEvaluationFixtures.english
            + SpatialTypoEvaluationFixtures.germanNouns + SpatialTypoEvaluationFixtures.novel
            + SpatialTypoEvaluationFixtures.absent
        let trusted = Set(controls.map { $0.lowercased() })
        var unwanted = 0
        for (ordinal, intended) in controls.enumerated() where EvaluationSample.includes(ordinal, every: 7) {
            let word = try SpatialTypoEvaluationEvidence.evidence(intended, grid: grid,
                ordinal: ordinal, seed: 0x545950525f503032, sigma: 0.22)
            let ac = engine(sources, languages: [.german, .english], trusted: trusted)
            install(word, in: ac)
            let request = ac.suggestionRequest(ownership: ownership(word, ac: ac), evidence: word)
            let result = try await ranked(request, worker: worker)
            _ = ac.finishSuggestions(result)
            // Alternating DE/EN preceding context is intentionally irrelevant to today's policy.
            let context = (ordinal % 2 == 0 ? "hello Haus " : "guten morning ") + word.text
            if ac.replacementOnSpace(beforeInput: context, field: .text, autocorrectionType: .default) != nil {
                unwanted += 1
            }
        }
        XCTAssertEqual(unwanted, 0)
        print("EVAL P1_controls unwanted=\(unwanted) bound=0 valid-names-compounds-codeSwitch=synthetic-checker NOT-iPhone")
    }

    func testMainActorKeystrokeLatencyBeforeAfterAndPayloadBounds() async throws {
        let sources = try resources()
        var before = [Double](), after = [Double](), ready = [Double]()
        var beforeCalls = 0, afterCallsOnInsertion = 0
        let rounds = EvaluationSample.isFull ? 20 : 2
        for baseline in [true, false] {
            for _ in 0..<rounds {
                let target = FixtureTextTarget()
                target.autocapitalizationType = .some(.none)
                let ac = engine(sources, languages: [.german, .english])
                let engine = FullKeyboardEngine(target: target, autocorrect: ac)
                engine.width = 393
                engine.configureForField()
                let checker = try XCTUnwrap(ac.checker as? CorpusChecker)
                for letter in "keyboard" {
                    let key = try XCTUnwrap(engine.layout.key(.character(String(letter))))
                    let point = CGPoint(x: key.frame.midX + 2, y: key.frame.midY - 1)
                    let calls = checker.calls
                    let start = ContinuousClock.now
                    engine.touchBegan(id: 1, at: point)
                    engine.touchEnded(id: 1, at: point)
                    if baseline {
                        // The pre-change didEdit performed this exact synchronous ranking API.
                        _ = ac.suggestions(beforeInput: target.text, field: .text, autocorrectionType: .default)
                    }
                    let ms = milliseconds(start.duration(to: .now))
                    if baseline { before.append(ms); beforeCalls += checker.calls - calls }
                    else { after.append(ms); afterCallsOnInsertion += checker.calls - calls }
                }
                let start = ContinuousClock.now
                await engine.waitForSuggestions()
                ready.append(milliseconds(start.duration(to: .now)))
                XCTAssertFalse(engine.suggestions.isEmpty)
            }
        }
        XCTAssertEqual(afterCallsOnInsertion, 0)
        XCTAssertGreaterThan(beforeCalls, 0)
        // Call counts and payloads gate regressions; wall time below is diagnostic only.
        XCTAssertEqual(before.count, rounds * 8)
        XCTAssertEqual(after.count, before.count)
        XCTAssertEqual(ready.count, rounds * 2)
        XCTAssertLessThan(SpatialWordRanking.maximumArenaPayloadBytes, 4 * 1_024 * 1_024)
        print("EVAL P1_keyLatency n=\(after.count) beforeMeanMs=\(format(mean(before))) beforeP95Ms=\(format(percentile(before, 0.95))) beforeP99Ms=\(format(percentile(before, 0.99))) beforeMaxMs=\(format(before.max() ?? 0)) afterMeanMs=\(format(mean(after))) afterP95Ms=\(format(percentile(after, 0.95))) afterP99Ms=\(format(percentile(after, 0.99))) afterMaxMs=\(format(after.max() ?? 0)) readyMeanMs=\(format(mean(ready))) checkerCallsBefore=\(beforeCalls) checkerCallsAfterInsertion=\(afterCallsOnInsertion) checkerScope=English-fixture synthetic-mainActor NOT-iPhone")
        print("EVAL P1_memory arenaElementPayloadBytes=\(SpatialWordRanking.maximumArenaPayloadBytes) requestValueBytes=\(MemoryLayout<KeyboardSuggestionWorker.Request>.stride) resultValueBytes=\(MemoryLayout<KeyboardSuggestionWorker.Result>.stride) maxRunning=1 maxQueued=1 maxPressedChips=3 maxContextUTF8=2048 maxTokenUTF8=256 maxTaps=64 maxPersonalWords=2000 resourcesSharedCOW=true excludes-allocator-overhead-and-RSS=true")
    }

    func testMaxCapacityPersonalSnapshotMatchesWorker() async throws {
        let sources = try resources()
        let words = (0..<2_000).map { index -> String in
            var n = index
            var suffix = ""
            repeat { suffix.append(Character(UnicodeScalar(97 + n % 26)!)); n /= 26 } while n > 0
            return "qz" + suffix
        }
        let personal = PersonalLexiconSnapshot(kept: [], counts: Dictionary(uniqueKeysWithValues: words.map { ($0, 2) }), rejected: [])
        XCTAssertEqual(personal.scan.entries.count, 2_000)
        let word = try SpatialTypoEvaluationEvidence.evidence("keyboard", grid: grid, error: .missing,
            ordinal: 3, seed: 0x545950525f503032, sigma: 0.22)
        let ac = engine(sources, languages: [.german, .english])
        let request = KeyboardSuggestionWorker.Request(ownership: ownership(word, ac: ac), evidence: word,
            languages: [.german, .english],
            calibration: SpatialTouchCalibration(keys: ["k": .init(offsetX: 0.12, offsetY: -0.08,
                                                                     sigmaX: 0.28, sigmaY: 0.42, covarianceXY: 0.035)]),
            personal: personal, lexicons: sources)
        let synchronous = ac.spatialDecoder?.decode(word, languages: request.languages,
                                                     calibration: request.calibration, personal: personal)
        let result = try await ranked(request, worker: KeyboardSuggestionWorker())
        guard case .result(let actual)? = result.outcome else { return XCTFail("Expected decode") }
        XCTAssertEqual(actual, synchronous, "Worker and boundary must preserve full covariance scores, alignments and search bounds")
        let stringBytes = words.reduce(0) { $0 + $1.utf8.count }
        print("EVAL P1_personal words=2000 wordUTF8Bytes=\(stringBytes) workerMs=\(format(result.seconds * 1000)) equivalent=true")
    }

    private func milliseconds(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15
    }
    private func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(max(1, values.count)) }
    private func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * p)) - 1))]
    }
    private func format(_ value: Double) -> String { String(format: "%.3f", value) }
}
