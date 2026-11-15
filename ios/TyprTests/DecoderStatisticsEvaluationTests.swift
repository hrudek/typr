import Foundation
import XCTest
@testable import Typr

/// Opt-in target only: bash ios/tools/run-research-tests.sh <simulator destination>.
/// R2-8 trial only: fixed retrieval, no automatic authority, no product switch.
/// Student-t predictive density and reading summation translated from iikb
/// Correction/{TouchModel,Decoder}.swift, 09a2e9cd (MIT © 2026 Bassim Shahidy).
/// Unlike upstream, calibration is frozen: a hypothetical reading never trains aim.
@MainActor
final class DecoderStatisticsEvaluationTests: XCTestCase {
    private typealias Decoder = SpatialWordDecoder
    private let grid = KeyboardLayout(width: 393, orientation: .portrait, layer: .letters,
                                      field: .text, showsGlobe: false, showsStrip: true)
    private let penalty = log(0.01)

    private func sources() throws -> [Decoder.Language: SpatialWordLexicon] {
        var result: [Decoder.Language: SpatialWordLexicon] = [:]
        for language in Decoder.Language.allCases {
            let url = try XCTUnwrap(Bundle.main.url(forResource: "keyboard-\(language.rawValue)",
                                                    withExtension: "words", subdirectory: "WordData"))
            result[language] = try XCTUnwrap(SpatialWordLexicon(data: Data(contentsOf: url)))
        }
        return result
    }

    private func logAdd(_ a: Double, _ b: Double) -> Double {
        if a == -.infinity { return b }
        if b == -.infinity { return a }
        let high = max(a, b)
        return high + log1p(exp(min(a, b) - high))
    }

    // In two dimensions the gamma ratio cancels to 1/(2π sqrt(det(scale))).
    // ν=4, scale=covariance: retains centre density, deliberately heavier tails.
    private func density(_ key: SpatialTouchCalibration.Key, x: Double, y: Double,
                         student: Bool) -> Double {
        if !student { return key.logDensity(x: x, y: y) }
        let determinant = key.sigmaX * key.sigmaX * key.sigmaY * key.sigmaY
            - key.covarianceXY * key.covarianceXY
        return -log(2 * Double.pi) - 0.5 * log(determinant)
            - 3 * log1p(key.mahalanobis(x: x, y: y) / 4)
    }

    private func emissions(_ word: KeyboardTouchWord, calibration: SpatialTouchCalibration?,
                           student: Bool) throws -> ([[Double]], [Double]) {
        var matrix: [[Double]] = []
        var best: [Double] = []
        for sample in word.samples {
            var row = [Double](repeating: -.infinity, count: SpatialWordLexicon.alphabet.count)
            for (index, letter) in SpatialWordLexicon.alphabet.enumerated() {
                let holder = KeyboardLetterMap.holder(of: letter)
                let frame = try XCTUnwrap(grid.key(.character(String(holder)))).frame
                let key = calibration?.keys[holder] ?? SpatialTouchCalibration.Key(
                    offsetX: 0, offsetY: 0, sigmaX: 0.35, sigmaY: 0.35)
                let x = Double(sample.point.x - frame.midX) / Double(frame.width + grid.metrics.gap)
                let y = Double(sample.point.y - frame.midY) / Double(frame.height + grid.metrics.rowGap)
                let dx = x - key.offsetX, dy = y - key.offsetY
                if dx * dx + dy * dy <= 1.6 * 1.6 {
                    row[index] = density(key, x: x, y: y, student: student)
                }
            }
            let high = try XCTUnwrap(row.max())
            best.append(high)
            for index in row.indices where row[index] < high - 6 { row[index] = -.infinity }
            matrix.append(row)
        }
        return (matrix, best)
    }

    /// Enumerate at most n+1 readings, stream their scores (no path arrays).
    /// Same-length: normal substitutions + each distinct adjacent swap; n+1 letters:
    /// each missing-letter position; n-1 letters: each stray-tap position.
    private func likelihood(_ spelling: String, matrix: [[Double]], best: [Double],
                            marginal: Bool) -> (score: Double, readings: Int) {
        let labels = spelling.map { SpatialWordLexicon.alphabet.firstIndex(of: $0)! }
        let n = matrix.count, m = labels.count
        var total = -Double.infinity
        var readings = 0
        func retain(_ score: Double) {
            readings += 1
            total = marginal ? logAdd(total, score) : max(total, score)
        }
        if n == m {
            var normal = 0.0
            for i in 0..<n { normal += matrix[i][labels[i]] }
            retain(normal)
            for at in 0..<(n - 1) where labels[at] != labels[at + 1] {
                var score = penalty
                for i in 0..<n {
                    let j = i == at ? at + 1 : (i == at + 1 ? at : i)
                    score += matrix[i][labels[j]]
                }
                retain(score)
            }
        } else if m == n + 1 {
            for missing in 0..<m {
                var score = penalty
                for i in 0..<n { score += matrix[i][labels[i < missing ? i : i + 1]] }
                retain(score)
            }
        } else if n == m + 1 {
            for stray in 0..<n {
                var score = penalty + best[stray]
                for i in 0..<m { score += matrix[i < stray ? i : i + 1][labels[i]] }
                retain(score)
            }
        }
        return (total, readings)
    }

    private func rerank(_ result: Decoder.Result, word: KeyboardTouchWord,
                        calibration: SpatialTouchCalibration?, student: Bool,
                        marginal: Bool) throws -> ([String], Int) {
        let (matrix, best) = try emissions(word, calibration: calibration, student: student)
        var scored: [(String, Double)] = []
        var work = 0
        XCTAssertLessThanOrEqual(result.suggestions.count, 10)
        for candidate in result.suggestions {
            let reading = likelihood(candidate.word, matrix: matrix, best: best, marginal: marginal)
            // Preserve corpus/personal prior, remove exactly the old structural penalty.
            let oldPenalty = candidate.edit == .none ? 0 : penalty
            let prior = candidate.score - candidate.spatialScore - oldPenalty
            scored.append((candidate.word, reading.score + prior))
            work += reading.readings
        }
        scored.sort { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        return (scored.map { $0.0 }, work)
    }

    private func outlier(_ word: KeyboardTouchWord, ordinal: Int) throws -> KeyboardTouchWord {
        var samples = word.samples
        let index = ordinal % samples.count
        let old = samples[index]
        let pitch = old.key.frame.width + grid.metrics.gap
        let distance = CGFloat([1.0, 1.25, 1.5][ordinal % 3])
        // Keep the physical raw hit and inserted literal consistent with displaced geometry.
        // Move inward on edge keys, so every fixture still has a real letter hit.
        let sign: CGFloat = old.point.x < grid.width / 2 ? 1 : -1
        let point = CGPoint(x: old.point.x + sign * distance * pitch, y: old.point.y)
        let nearest = grid.keys.filter { $0.character != nil }.min {
            abs($0.frame.midX - point.x) + abs($0.frame.midY - point.y)
                < abs($1.frame.midX - point.x) + abs($1.frame.midY - point.y)
        }
        let key = try XCTUnwrap(nearest)
        samples[index] = .init(text: try XCTUnwrap(key.character), point: point, key: key)
        return KeyboardTouchWord(layout: grid, samples: samples)
    }

    func testBoundedStudentAndAlignmentTrial() throws {
        let lexicons = try sources()
        let decoder = Decoder(lexicons: lexicons)
        let de = Array(SpatialTypoEvaluationFixtures.german.prefix(64))
        let en = Array(SpatialTypoEvaluationFixtures.english.prefix(64))
        let groups: [(String, [String], Set<Decoder.Language>)] = [
            ("de", de, [.german]), ("en", en, [.english]), ("mixed", de + en, [.german, .english])]
        let learnedKey = SpatialTouchCalibration.Key(offsetX: 0.12, offsetY: -0.08,
                                                     sigmaX: 0.32, sigmaY: 0.40, covarianceXY: 0.025)
        let keys = Dictionary(uniqueKeysWithValues: Array("abcdefghijklmnopqrstuvwxyz").map { ($0, learnedKey) })
        let learned = SpatialTouchCalibration(keys: keys)
        let models: [(String, SpatialTouchCalibration?)] = [("cold", nil), ("aim", learned)]
        var recall1 = [Int](repeating: 0, count: 4)
        var recall3 = recall1
        var recall1Regressions = 0, recall3Regressions = 0
        for (model, calibration) in models {
            for (mode, words, languages) in groups {
                for sloppy in [false, true] {
                    var top1 = [Int](repeating: 0, count: 4)
                    var top3 = top1
                    var calls = 0, unavailable = 0, visits = 0, generated = 0, maxReadings = 0
                    var milliseconds = 0.0
                    for (ordinal, intended) in words.enumerated() {
                        let errors: [SpatialTypoEvaluationEvidence.ErrorClass?] = sloppy
                            ? [nil] : [.neighbour1, .neighbour2, .missing, .extra, .transposition]
                        for error in errors {
                            let original = try SpatialTypoEvaluationEvidence.evidence(
                                intended, grid: grid, error: error, ordinal: ordinal,
                                seed: 0x523238, sigma: sloppy ? 0 : 0.22)
                            let word = sloppy ? try outlier(original, ordinal: ordinal) : original
                            calls += 1
                            guard let result = decoder.decode(word, languages: languages, calibration: calibration) else {
                                unavailable += 1
                                continue
                            }
                            // Cold and memoized work must be deterministic.
                            XCTAssertEqual(result, decoder.decode(word, languages: languages, calibration: calibration))
                            visits += result.visits; generated += result.generated
                            let start = ProcessInfo.processInfo.systemUptime
                            var orders = [result.suggestions.map(\.word)]
                            for (student, marginal) in [(false, true), (true, false), (true, true)] {
                                let trial = try rerank(result, word: word, calibration: calibration,
                                                       student: student, marginal: marginal)
                                orders.append(trial.0)
                                maxReadings = max(maxReadings, trial.1)
                            }
                            milliseconds += (ProcessInfo.processInfo.systemUptime - start) * 1_000
                            for i in orders.indices {
                                if orders[i].first == intended { top1[i] += 1 }
                                if orders[i].prefix(3).contains(intended) { top3[i] += 1 }
                            }
                        }
                    }
                    XCTAssertLessThanOrEqual(maxReadings, 330)
                    for i in 0..<4 { recall1[i] += top1[i]; recall3[i] += top3[i] }
                    if top1[3] < top1[0] { recall1Regressions += 1 }
                    if top3[3] < top3[0] { recall3Regressions += 1 }
                    print("EVAL R2_8_quality model=\(model) mode=\(mode) profile=\(sloppy ? "outlier_1_to_1.5_pitch" : "noisy_five_edits") n=\(calls) unavailable=\(unavailable) before_r1=\(top1[0]) before_r3=\(top3[0]) gaussian_sum_r1=\(top1[1]) gaussian_sum_r3=\(top3[1]) student_max_r1=\(top1[2]) student_max_r3=\(top3[2]) trial_r1=\(top1[3]) trial_r3=\(top3[3]) before_visits=\(visits) trial_visits=\(visits) before_generated=\(generated) trial_generated=\(generated) extra_readings_max=\(maxReadings) three_trials_ms=\(milliseconds) scope=fixed_retrieval_not_iPhone")
                }
            }
        }
        print("EVAL R2_8_gate before_r1=\(recall1[0]) trial_r1=\(recall1[3]) before_r3=\(recall3[0]) trial_r3=\(recall3[3]) r1_regressing_groups=\(recall1Regressions) r3_regressing_groups=\(recall3Regressions) automatic_authority=unchanged decision=evaluation_only")
    }

    func testDensityAndReadingRegression() throws {
        let key = SpatialTouchCalibration.Key(offsetX: 0, offsetY: 0, sigmaX: 0.35, sigmaY: 0.35)
        XCTAssertEqual(density(key, x: 0, y: 0, student: true), key.logDensity(x: 0, y: 0), accuracy: 1e-12)
        XCTAssertGreaterThan(density(key, x: 1.5, y: 0, student: true), key.logDensity(x: 1.5, y: 0))
        XCTAssertEqual(logAdd(-1_000, -1_000), -1_000 + log(2), accuracy: 1e-12)
        let row = [Double](repeating: 0, count: SpatialWordLexicon.alphabet.count)
        let matrix = Array(repeating: row, count: 4)
        let summed = likelihood("hello", matrix: matrix, best: [0, 0, 0, 0], marginal: true)
        let maximum = likelihood("hello", matrix: matrix, best: [0, 0, 0, 0], marginal: false)
        XCTAssertEqual(summed.readings, 5)
        XCTAssertEqual(summed.score - maximum.score, log(5), accuracy: 1e-12)
        let longest = String(repeating: "l", count: 32)
        let longestMatrix = Array(repeating: row, count: 32)
        let longestBest = [Double](repeating: 0, count: 32)
        XCTAssertEqual(likelihood(longest + "l", matrix: longestMatrix, best: longestBest,
                                  marginal: true).readings, 33)
        XCTAssertEqual(likelihood(String(longest.dropLast()), matrix: longestMatrix, best: longestBest,
                                  marginal: true).readings, 32)
        // Repeated letters are separate readings; equal adjacent swaps are not new paths.
        XCTAssertEqual(likelihood("llll", matrix: matrix, best: [0, 0, 0, 0], marginal: true).readings, 1)
        print("EVAL R2_8_learning hypothetical_reading_updates=0 new_storage_bytes=0 calibration=frozen existing_trust_and_reset=unchanged")
        print("EVAL R2_8_bounds candidates=10 taps=32 readings_per_candidate_max=33 readings_per_call_max=330 emission_cells_max=960 path_score_additions_max=10560 numeric_payload_bytes_max=\((32 * 30 + 32 + 30 + 10) * MemoryLayout<Double>.stride + 33 * MemoryLayout<Int>.stride) production_arena_bytes=\(SpatialWordRanking.maximumArenaPayloadBytes) excludes_containers_and_RSS=true")
    }
}
