import Foundation
import XCTest
@testable import Typr

/// Seeded synthetic grip-change ablation on public fixture words. NOT measured human typing,
/// a system dictionary or physical hit-test proof. Literals come from the static hit test of
/// the simulated touch, so a grip change produces realistic neighbour typos.
@MainActor
final class PersonalTypingAimEvaluationTests: XCTestCase {
    private let grid = KeyboardLayout(width: 393)
    private static let matureLabels = 3_000

    private struct SplitMix64 {
        var state: UInt64
        mutating func uniform() -> Double {
            state &+= 0x9e3779b97f4a7c15
            var value = state
            value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
            value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
            value ^= value >> 31
            return (Double(value >> 11) + 0.5) / 9_007_199_254_740_992
        }
        mutating func normal() -> Double { sqrt(-2 * log(uniform())) * cos(2 * Double.pi * uniform()) }
    }

    enum Grip: String { case twoThumbs, oneHandRight, tilt }

    // MARK: - Synthetic aim

    private var letterKeys: [KeyboardKey] {
        grid.keys.filter { $0.character?.count == 1 && $0.character?.first.map { ("a"..."z").contains($0) } == true }
    }
    private var pitch: (x: Double, y: Double) {
        let frame = grid.key(.character("a"))!.frame
        return (Double(frame.width + grid.metrics.gap), Double(frame.height + grid.metrics.rowGap))
    }
    private var plane: CGRect { letterKeys.map(\.frame).reduce(letterKeys[0].frame) { $0.union($1) } }

    /// The user's own fixed per-key bias (±.06 pitch), present in every grip.
    private func personalBias(_ letter: Character) -> (Double, Double) {
        var random = SplitMix64(state: 0x5059_5052_4249_4153 &+ UInt64(letter.asciiValue ?? 0) &* 7919)
        return ((random.uniform() - 0.5) * 0.12, (random.uniform() - 0.5) * 0.12)
    }

    /// Systematic offset and per-axis spread, both in key pitches.
    private func aim(_ letter: Character, _ grip: Grip) -> (x: Double, y: Double, sigma: Double) {
        let frame = grid.key(.character(String(letter)))!.frame
        let bias = personalBias(letter)
        switch grip {
        case .twoThumbs:
            return (bias.0, bias.1 + 0.06, 0.21)
        case .oneHandRight:
            // Right thumb pivoting below the bottom-right corner undershoots toward its base,
            // growing superlinearly with reach: ~.1 pitch near the base, ~.6 at the far side.
            let base = CGPoint(x: grid.width - 0.25 * pitch.x, y: plane.maxY + 2.2 * pitch.y)
            let far = letterKeys.map { hypot(Double($0.frame.midX - base.x), Double($0.frame.midY - base.y)) }.max()!
            let vx = Double(frame.midX - base.x), vy = Double(frame.midY - base.y)
            let reach = hypot(vx, vy) / far
            let magnitude = 0.6 * pitch.x * pow(reach, 1.5)
            return (bias.0 - vx / hypot(vx, vy) * magnitude / pitch.x,
                    bias.1 + 0.06 - vy / hypot(vx, vy) * magnitude / pitch.y,
                    0.21 + 0.07 * reach)
        case .tilt:
            // Device held tilted (e.g. lying down): a 4° rotation about the letter plane plus
            // taps landing .15 pitch low.
            let angle = 4.0 * Double.pi / 180
            let dx = Double(frame.midX - plane.midX), dy = Double(frame.midY - plane.midY)
            let rx = dx * cos(angle) - dy * sin(angle) - dx, ry = dx * sin(angle) + dy * cos(angle) - dy
            return (bias.0 + rx / pitch.x, bias.1 + 0.06 + 0.15 + ry / pitch.y, 0.22)
        }
    }

    private func tap(_ letter: Character, _ grip: Grip, _ random: inout SplitMix64) -> CGPoint {
        let frame = grid.key(.character(String(letter)))!.frame
        let a = aim(letter, grip)
        return CGPoint(x: frame.midX + CGFloat((a.x + a.sigma * random.normal()) * pitch.x),
                       y: frame.midY + CGFloat((a.y + a.sigma * random.normal()) * pitch.y))
    }

    /// Independently trusted labels for intended letters, from a word stream disjoint from the
    /// evaluated words. Offered labels are counted; the model's own outlier gate still applies.
    private struct LabelStream {
        let letters: [Character]
        var position = 0
        var random = SplitMix64(state: 0x4c41_4245_4c53_5452)
        init(words: [String]) { letters = words.joined().filter { ("a"..."z").contains($0) } }
        mutating func next() -> Character {
            defer { position += 1 }
            return letters[position % letters.count]
        }
    }

    @discardableResult
    private func train(_ model: PersonalTypingModel, _ stream: inout LabelStream, count: Int, grip: Grip) -> Int {
        var accepted = 0, offered = 0
        // Checkpoints count ACCEPTED trusted labels, not rejected outliers or physical taps.
        // Explicit cap keeps even a broken generator bounded and fails rather than hanging.
        while accepted < count, offered < 4 * count + 100 {
            let letter = stream.next()
            accepted += model.learn([TouchLabel(point: tap(letter, grip, &stream.random), letter: letter)],
                                    layout: grid, source: .manualPick).accepted
            offered += 1
        }
        XCTAssertEqual(accepted, count)
        return offered
    }

    private func decoder(usesLegacySearch: Bool = false) throws -> SpatialWordDecoder {
        SpatialWordDecoder(lexicons: try XCTUnwrap(BundledKeyboardData.lexicons), usesLegacySearch: usesLegacySearch)
    }

    private var trainingWords: [String] {
        (SpatialTypoEvaluationFixtures.rare + SpatialTypoEvaluationFixtures.absent).map { $0.lowercased() }
    }

#if TYPR_RESEARCH
    private func originParameterCalibration(_ state: PersonalTypingModel.State) -> SpatialTouchCalibration? {
        guard let layout = state.layouts[KeyboardLayoutSignature(grid).id] else { return nil }
        var keys: [Character: SpatialTouchCalibration.Key] = [:]
        let prior = 0.35 * 0.35
        for (letter, stats) in layout.keys where stats.n >= 20 {
            let shrink = Double(stats.n) / Double(stats.n + 20)
            func clampOffset(_ value: Double) -> Double { max(-0.25, min(0.25, shrink * value)) }
            func clampSigma(_ variance: Double) -> Double {
                max(0.22, min(0.50, sqrt(shrink * variance + (1 - shrink) * prior)))
            }
            keys[letter.first!] = .init(offsetX: clampOffset(stats.meanX), offsetY: clampOffset(stats.meanY),
                                        sigmaX: clampSigma(stats.varianceX), sigmaY: clampSigma(stats.varianceY))
        }
        return keys.isEmpty ? nil : SpatialTouchCalibration(keys: keys)
    }
    private let checkpoints = [0, 5, 10, 20, 30, 60, 120]

    /// Static attribution: the hit-tested letter, else the nearest letter centre.
    private func hit(_ point: CGPoint) -> KeyboardKey {
        if let key = grid.hitTest(point), key.character.map({ letterKeys.map(\.character).contains($0) }) == true {
            return key
        }
        return letterKeys.min {
            hypot(Double($0.frame.midX - point.x) / pitch.x, Double($0.frame.midY - point.y) / pitch.y)
                < hypot(Double($1.frame.midX - point.x) / pitch.x, Double($1.frame.midY - point.y) / pitch.y)
        }!
    }

    private func evidence(_ word: String, _ grip: Grip, seed: UInt64) -> KeyboardTouchWord {
        var random = SplitMix64(state: seed)
        return KeyboardTouchWord(layout: grid, samples: word.map { letter in
            let point = tap(letter, grip, &random)
            let key = hit(point)
            return KeyboardTouchWord.Sample(text: key.character!, point: point, key: key)
        })
    }

    // MARK: - Metrics

    private struct Metrics {
        var words = 0, typos = 0, recall1 = 0, recall3 = 0, fixedAuto = 0, wrongAuto = 0
        var unwanted = 0, unavailable = 0, incomplete = 0
        var milliseconds: [Double] = []
        var visits: [Double] = []
        var generated: [Int] = []
        /// Work on correctly hit-tested literals only: no candidate should need to beat them.
        var cleanVisits: [Double] = []

        mutating func add(_ other: Metrics) {
            words += other.words; typos += other.typos; recall1 += other.recall1; recall3 += other.recall3
            fixedAuto += other.fixedAuto; wrongAuto += other.wrongAuto; unwanted += other.unwanted
            unavailable += other.unavailable; incomplete += other.incomplete
            milliseconds += other.milliseconds; visits += other.visits; generated += other.generated
            cleanVisits += other.cleanVisits
        }
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * p)) - 1))]
    }

    private func observe(_ input: KeyboardTouchWord, intended: String, calibration: SpatialTouchCalibration?,
                         decoder: SpatialWordDecoder, into metrics: inout Metrics) {
        let start = ProcessInfo.processInfo.systemUptime
        let decoded = decoder.decode(input, languages: [.german, .english], calibration: calibration)
        metrics.milliseconds.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        metrics.words += 1
        let typo = input.text != intended
        if typo { metrics.typos += 1 }
        guard let result = decoded else { metrics.unavailable += 1; return }
        metrics.visits.append(Double(result.visits))
        metrics.generated.append(result.generated)
        if !typo { metrics.cleanVisits.append(Double(result.visits)) }
        if !result.complete { metrics.incomplete += 1 }
        let replaced: String?
        if case .replace(let candidate) = result.automaticDecision(literalIsValid: result.literalInLexicon) {
            replaced = candidate.word
        } else { replaced = nil }
        if typo {
            if result.suggestions.first?.word == intended { metrics.recall1 += 1 }
            if result.suggestions.prefix(3).contains(where: { $0.word == intended }) { metrics.recall3 += 1 }
            if let replaced { if replaced == intended { metrics.fixedAuto += 1 } else { metrics.wrongAuto += 1 } }
        } else if replaced != nil {
            // The hit-tested literal IS the intended (corpus-valid) word: any change is unwanted.
            metrics.unwanted += 1
        }
    }

    private var groups: [(String, [String])] {
        let usable: ([String]) -> [String] = { $0.map { $0.lowercased() }.filter { $0.count >= 3 && $0.allSatisfy { ("a"..."z").contains($0) } } }
        let de = usable(SpatialTypoEvaluationFixtures.german), en = usable(SpatialTypoEvaluationFixtures.english)
        // Code-switched sequence: alternate DE/EN words, drawn with independent seeds.
        let mixed = zip(de.enumerated().filter { $0.offset % 2 == 1 }.map(\.element),
                        en.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)).flatMap { [$0, $1] }
        return [("DE", de), ("EN", en), ("mixed", mixed)]
    }

    private func matureModel() -> (PersonalTypingModel, LabelStream) {
        let model = PersonalTypingModel()
        var stream = LabelStream(words: trainingWords)
        train(model, &stream, count: Self.matureLabels, grip: .twoThumbs)
        return (model, stream)
    }

    private func runScenario(_ away: Grip) throws -> [(phase: String, rows: [(labels: Int, variants: [Metrics])])] {
        let decoder = try decoder()
        let originDecoder = try self.decoder(usesLegacySearch: true)
        var measuredWork = [Metrics(), Metrics(), Metrics()]
        let groups = self.groups
        XCTAssertTrue(groups.allSatisfy { $0.1.count >= 100 }, "at least 100 words per group")
        var (model, stream) = matureModel()
        var output: [(phase: String, rows: [(labels: Int, variants: [Metrics])])] = []
        for (phase, grip) in [("away", away), ("back", Grip.twoThumbs)] {
            var trained = 0, offered = 0
            var rows: [(labels: Int, variants: [Metrics])] = []
            var curves: [String: [String]] = [:]
            var staticMetrics: [String: Metrics] = [:]
            for labels in checkpoints {
                offered += train(model, &stream, count: labels - trained, grip: grip)
                trained = labels
                let calibrations = [nil, originParameterCalibration(model.state), model.calibration(for: grid)]
                let slowOnly = phase == "away" && [0, 10, 20, 30].contains(labels)
                    ? PersonalTypingModel(state: model.state).calibration(for: grid) : nil
                print("EVAL P7_labels scenario=\(away.rawValue) phase=\(phase) accepted=\(labels) offered=\(offered)")
                var total = [Metrics(), Metrics(), Metrics()]
                for (groupIndex, (group, words)) in groups.enumerated() {
                    var metrics = [Metrics(), Metrics(), Metrics()]
                    var slowMetrics = Metrics()
                    for (ordinal, word) in words.enumerated() {
                        // Identical evidence at every checkpoint of a phase and for every variant.
                        let seed = 0x4752_4950 &+ UInt64(groupIndex) &* 1_000_003 &+ UInt64(ordinal) &* 7_919
                            &+ (grip == .twoThumbs ? 0 : 0x9999)
                        let input = evidence(word, grip, seed: seed)
                        if let slowOnly {
                            observe(input, intended: word, calibration: slowOnly, decoder: decoder, into: &slowMetrics)
                        }
                        for variant in 0..<3 {
                            // Static is checkpoint-independent: decode it once per phase.
                            if variant == 0, staticMetrics[group] != nil { continue }
                            observe(input, intended: word, calibration: calibrations[variant],
                                    decoder: variant == 2 ? decoder : originDecoder, into: &metrics[variant])
                        }
                    }
                    for variant in 0..<3 { measuredWork[variant].add(metrics[variant]) }
                    if let cached = staticMetrics[group] { metrics[0] = cached } else { staticMetrics[group] = metrics[0] }
                    for variant in 0..<3 { total[variant].add(metrics[variant]) }
                    let m = metrics
                    // Stratified safety/reversal: German may not hide behind English gains.
                    // Two words/group is a declared fixture tolerance, NOT a statistical CI.
                    let context = "\(away) \(phase) \(group) labels=\(labels)"
                    XCTAssertGreaterThanOrEqual(m[2].recall1, m[1].recall1 - 2, context)
                    XCTAssertGreaterThanOrEqual(m[2].recall3, m[1].recall3 - 2, context)
                    XCTAssertLessThanOrEqual(m[2].wrongAuto, m[1].wrongAuto + 1, context)
                    XCTAssertEqual(m[2].unwanted, 0, context)
                    if slowOnly != nil {
                        if away == .oneHandRight, (10...30).contains(labels) {
                            XCTAssertGreaterThanOrEqual(Double(m[2].recall1 - slowMetrics.recall1), 0.08 * Double(m[2].typos),
                                                        "fast drift must help independently of covariance tempering: \(context)")
                        }
                        print("EVAL P7_fastAblation scenario=\(away.rawValue) group=\(group) labels=\(labels) typos=\(m[2].typos) slowNewRecall1=\(slowMetrics.recall1) newRecall1=\(m[2].recall1) slowNewRecall3=\(slowMetrics.recall3) newRecall3=\(m[2].recall3) wrongTypoAuto=\(slowMetrics.wrongAuto)/\(m[2].wrongAuto)")
                    }
                    curves[group, default: []].append("\(labels):\(m[0].recall1)/\(m[1].recall1)/\(m[2].recall1):\(m[0].recall3)/\(m[1].recall3)/\(m[2].recall3):\(m[0].wrongAuto)/\(m[1].wrongAuto)/\(m[2].wrongAuto):\(m[0].unwanted)/\(m[1].unwanted)/\(m[2].unwanted)")
                    if labels == checkpoints[0] {
                        XCTAssertEqual(m[0].typos, m[2].typos)
                    }
                }
                rows.append((labels, total))
            }
            for (group, words) in groups {
                let typos = staticMetrics[group]!.typos
                print("EVAL P7_grip scenario=\(away.rawValue) phase=\(phase) group=\(group) words=\(words.count) typos=\(typos) curve=labels:recall1 prior/originParameters/new:recall3 p/o/n:wrongTypoAuto p/o/n:unwantedValidAuto p/o/n \(curves[group]!.joined(separator: ","))")
            }
            let summary = rows.map { row in
                let v = row.variants
                return "\(row.labels):\(v[0].recall1)/\(v[1].recall1)/\(v[2].recall1):\(v[0].recall3)/\(v[1].recall3)/\(v[2].recall3):\(v[0].wrongAuto)/\(v[1].wrongAuto)/\(v[2].wrongAuto):\(v[0].unwanted)/\(v[1].unwanted)/\(v[2].unwanted)"
            }
            let first = rows[0].variants[0]
            print("EVAL P7_gripTotal scenario=\(away.rawValue) phase=\(phase) words=\(first.words) typos=\(first.typos) curve=labels:recall1 prior/originParameters/new:recall3 p/o/n:wrongTypoAuto p/o/n:unwantedValidAuto p/o/n \(summary.joined(separator: ","))")
            var phaseWork = [Metrics(), Metrics(), Metrics()]
            for row in rows { for v in 0..<3 { phaseWork[v].add(row.variants[v]) } }
            print("EVAL P7_phaseVisits scenario=\(away.rawValue) phase=\(phase) " + phaseWork.enumerated().map { v, m in
                String(format: "%@=%.1f/%.0f/%.0f", ["prior", "originParameters", "new"][v], m.visits.reduce(0, +) / Double(max(1, m.visits.count)),
                       Self.percentile(m.visits, 0.95), m.visits.max() ?? 0)
            }.joined(separator: " ") + " (mean/p95/max)")
            output.append((phase, rows))
        }
        // Decode work on identical inputs, all checkpoints and phases of this scenario.
        let work = measuredWork // Static is really decoded only once per phase, not at every checkpoint.
        func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(max(1, values.count)) }
        for (v, name) in ["prior", "originParameters", "new"].enumerated() {
            let ms = work[v].milliseconds, visits = work[v].visits, clean = work[v].cleanVisits
            print(String(format: "EVAL P7_decodeWork scenario=%@ variant=%@ calls=%d meanMs=%.3f p95Ms=%.3f maxMs=%.3f visitsMean=%.1f visitsP95=%.0f visitsMax=%.0f cleanLiteralVisitsMean=%.1f cleanLiteralVisitsP95=%.0f incomplete=%d unavailable=%d platform=local_debug_not_iPhone",
                         away.rawValue, name, ms.count, mean(ms), Self.percentile(ms, 0.95),
                         ms.max() ?? 0, mean(visits), Self.percentile(visits, 0.95),
                         visits.max() ?? 0, mean(clean), Self.percentile(clean, 0.95), work[v].incomplete, work[v].unavailable))
            // Wall time is diagnostic only: shared runners can pause either comparison variant.
            XCTAssertLessThanOrEqual(work[v].generated.max() ?? 0, SpatialWordDecoder.maxGenerated)
            XCTAssertEqual(work[v].incomplete, 0, "every decode is a complete, proven search")
            XCTAssertLessThanOrEqual(visits.max() ?? 0, Double(SpatialWordDecoder.searchBudget))
        }
        XCTAssertLessThanOrEqual(mean(work[2].cleanVisits), 1.25 * mean(work[0].cleanVisits))
        // Valid-literal safety: the adaptive model never adds an unwanted change of a valid literal.
        for phase in output { for row in phase.rows {
            XCTAssertLessThanOrEqual(row.variants[2].unwanted, row.variants[0].unwanted, "\(away) \(phase.phase) \(row.labels)")
        } }
        return output
    }

    func testSteadyStateControlsAndDecodeWork() throws {
        let decoder = try decoder()
        let originDecoder = try self.decoder(usesLegacySearch: true)
        let (model, _) = matureModel()
        let calibrations = [nil, originParameterCalibration(model.state), model.calibration(for: grid), model.calibration(for: grid)]
        let names = ["prior", "originParametersStudentT", "new", "newDensityLegacySearch"]
        let inLexicon = (SpatialTypoEvaluationFixtures.german + SpatialTypoEvaluationFixtures.english
            + SpatialTypoEvaluationFixtures.germanNouns + SpatialTypoEvaluationFixtures.short
            + SpatialTypoEvaluationFixtures.rare).map { $0.lowercased() }
        let outside = (SpatialTypoEvaluationFixtures.novel + SpatialTypoEvaluationFixtures.absent).map { $0.lowercased() }
        for (set, words) in [("inLexicon", inLexicon), ("outside", outside)] {
            let usable = words.filter { $0.count >= 3 && $0.allSatisfy { ("a"..."z").contains($0) } }
            XCTAssertGreaterThanOrEqual(usable.count, 300)
            for edits in [false, true] {
                var rows: [String] = []
                var unwanted = [0, 0, 0, 0]
                var meanTimes: [Double] = [], meanVisits: [Double] = []
                for (v, calibration) in calibrations.enumerated() {
                    var ms: [Double] = [], visits: [Double] = [], generated: [Int] = [], incomplete = 0
                    for (ordinal, word) in usable.enumerated() {
                        // Literal = intended letters, aim and noise from the two-thumb grip.
                        var random = SplitMix64(state: 0x434f_4e54 &+ UInt64(ordinal) &* 7_919)
                        let input = KeyboardTouchWord(layout: grid, samples: word.map { letter in
                            let key = grid.key(.character(String(letter)))!
                            return .init(text: String(letter), point: tap(letter, .twoThumbs, &random), key: key)
                        })
                        let start = ProcessInfo.processInfo.systemUptime
                        let result = (v == 2 ? decoder : originDecoder).decode(input, languages: [.german, .english], calibration: calibration, allowsEdits: edits)
                        ms.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                        guard let result else { continue }
                        visits.append(Double(result.visits))
                        generated.append(result.generated)
                        if !result.complete { incomplete += 1 }
                        if case .replace = result.automaticDecision(literalIsValid: result.literalInLexicon) { unwanted[v] += 1 }
                    }
                    meanTimes.append(ms.reduce(0, +) / Double(ms.count))
                    meanVisits.append(visits.reduce(0, +) / Double(max(1, visits.count)))
                    XCTAssertEqual(incomplete, 0)
                    XCTAssertEqual(visits.count, usable.count, "Every control must produce a search result")
                    XCTAssertLessThanOrEqual(visits.max() ?? 0, Double(SpatialWordDecoder.searchBudget))
                    XCTAssertLessThanOrEqual(generated.max() ?? 0, SpatialWordDecoder.maxGenerated)
                    rows.append(String(format: "%@:unwanted=%d,incomplete=%d,meanMs=%.3f,p95Ms=%.3f,visits=%.1f/%.0f/%.0f",
                                       names[v], unwanted[v], incomplete, ms.reduce(0, +) / Double(ms.count),
                                       Self.percentile(ms, 0.95), visits.reduce(0, +) / Double(max(1, visits.count)),
                                       Self.percentile(visits, 0.95), visits.max() ?? 0))
                }
                print("EVAL P7_controls set=\(set) variant=\(edits ? "B" : "A") n=\(usable.count) \(rows.joined(separator: " ")) visits=mean/p95/max platform=local_debug_not_iPhone")
                XCTAssertEqual(unwanted[2], 0, "no unwanted automatic change of a correctly typed control")
                XCTAssertEqual(unwanted[3], 0, "bound changes work, not automatic policy")
                XCTAssertLessThanOrEqual(meanVisits[2], 1.10 * meanVisits[1] + (edits ? 0 : 8))
                print(String(format: "EVAL P7_originComparison set=%@ variant=%@ newOverPriorVisits=%.3f newOverPriorMeanMs=%.3f newOverOriginParametersVisits=%.3f newOverOriginParametersMeanMs=%.3f pruningVisitsRatio=%.3f",
                             set, edits ? "B" : "A", meanVisits[2] / meanVisits[0], meanTimes[2] / meanTimes[0],
                             meanVisits[2] / meanVisits[1], meanTimes[2] / meanTimes[1], meanVisits[2] / meanVisits[3]))
            }
        }
    }

    func testOneHandGripShiftAndReturn() throws {
        let result = try runScenario(.oneHandRight)
        assertCurves(result, scenario: "oneHandRight", gain: 0.25)
    }

    func testTiltGripShiftAndReturn() throws {
        let result = try runScenario(.tilt)
        assertCurves(result, scenario: "tilt", gain: 0.05)
    }

    /// Bounds, in typo-word counts pooled over the three >=100-word groups (same evidence for
    /// every variant and checkpoint of a phase; the noise bound covers one-label seed effects):
    /// - away, 10-30 trusted labels: new beats old by >= `gain` of the typos;
    /// - every checkpoint of both phases: new >= old - 2 and new >= static - 2 (recall@1 and @3);
    /// - wrong typo autos: new <= old + 1; unwanted changes of correct valid literals: 0.
    private func assertCurves(_ result: [(phase: String, rows: [(labels: Int, variants: [Metrics])])],
                              scenario: String, gain: Double) {
        for phase in result {
            for row in phase.rows {
                let v = row.variants
                print("EVAL P7_gripDelta scenario=\(scenario) phase=\(phase.phase) labels=\(row.labels) typos=\(v[0].typos) newMinusOldRecall1=\(v[2].recall1 - v[1].recall1) newMinusOldRecall3=\(v[2].recall3 - v[1].recall3) newMinusStaticRecall1=\(v[2].recall1 - v[0].recall1) wrongTypoAuto=\(v[0].wrongAuto)/\(v[1].wrongAuto)/\(v[2].wrongAuto) unwantedValidAuto=\(v[0].unwanted)/\(v[1].unwanted)/\(v[2].unwanted)")
                let label = "\(scenario) \(phase.phase) \(row.labels)"
                XCTAssertGreaterThanOrEqual(v[2].recall1, v[1].recall1 - 2, label)
                XCTAssertGreaterThanOrEqual(v[2].recall3, v[1].recall3 - 2, label)
                XCTAssertGreaterThanOrEqual(v[2].recall1, v[0].recall1 - 2, label)
                XCTAssertLessThanOrEqual(v[2].wrongAuto, v[1].wrongAuto + 1, label)
                XCTAssertEqual(v[2].unwanted, 0, label)
                if phase.phase == "away", (10...30).contains(row.labels) {
                    XCTAssertGreaterThanOrEqual(Double(v[2].recall1 - v[1].recall1), gain * Double(v[0].typos), label)
                }
            }
        }
    }
#endif

    private func point(_ letter: Character, x: Double, y: Double) -> CGPoint {
        let frame = grid.key(.character(String(letter)))!.frame
        return CGPoint(x: frame.midX + x * pitch.x, y: frame.midY + y * pitch.y)
    }

    private final class Checker: TextChecking {
        let valid: Set<String>
        init(_ words: [String]) { valid = Set(words.map { $0.lowercased() }) }
        func isWordValid(_ word: String) -> Bool { valid.contains(word.lowercased()) }
        func guesses(for word: String) -> [String] { [] }
        func completions(for prefix: String) -> [String] { [] }
    }

    func testAdversarialLabelsDoNotOverrideValidLiteralsOrSelfTrain() throws {
        let decoder = try decoder()
        let words = ["hallo", "hello", "haus", "house", "welt", "world", "Anna", "Siempelkamper", "Haustuersteuerung", "GitHub", "Swift", "keyboard", "kind", "gift"]
        let session = KeyboardLearningSession()
        var stream = LabelStream(words: trainingWords)
        train(session.model, &stream, count: Self.matureLabels, grip: .twoThumbs)
        // Worst allowed independently supplied labels; silent automatic output still has
        // no API path to these updates. Influence stays bounded even under hostile labels.
        for _ in 0..<100 { session.learn(Array("abcdefghijklmnopqrstuvwxyz").map {
            TouchLabel(point: point($0, x: 0.7, y: 0.7), letter: $0)
        }, layout: grid, source: .manualPick) }
        let ac = AutocorrectEngine(checker: Checker(words), learning: session, spatialDecoder: decoder)
        ac.german = GermanAutocorrect(checker: Checker(words))
        let before = session.model.state
        var changes = 0
        for word in words {
            ac.touchInput.clear() // Keep hostile fast aim active while testing protection.
            var text = ""
            for letter in word {
                let key = grid.key(.character(String(letter).lowercased()))!
                let after = text + String(letter)
                ac.touchInput.append(text: String(letter), point: point(Character(String(letter).lowercased()), x: -0.2, y: 0.1), key: key,
                                     layout: grid, before: text, after: after)
                text = after
            }
            for _ in 0..<3 {
                _ = ac.suggestions(beforeInput: word, field: .text, autocorrectionType: .default)
                if ac.replacementOnSpace(beforeInput: word, field: .text, autocorrectionType: .default) != nil { changes += 1 }
            }
        }
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(session.model.state, before, "scoring and silent boundary decisions never train")
        let keys = try XCTUnwrap(session.calibration(for: grid)?.keys)
        XCTAssertTrue(keys.values.allSatisfy { abs($0.offsetX) <= SpatialTouchCalibration.maxOffset && abs($0.offsetY) <= SpatialTouchCalibration.maxOffset })
        print("EVAL P7_safety validControls=\(words.count) decisions=\(words.count * 3) unwantedAuto=\(changes) adversarialLabels=2600 selfTrainingUpdates=0")
    }
}
