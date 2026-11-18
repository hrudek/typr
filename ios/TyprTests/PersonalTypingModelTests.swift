import Foundation
import XCTest
@testable import Typr

@MainActor
final class PersonalTypingModelTests: XCTestCase {
    private let layout = KeyboardLayout(width: 393)

    private func label(_ x: Double = 0, _ y: Double = 0, letter: Character = "a",
                       layout: KeyboardLayout? = nil) throws -> TouchLabel {
        let layout = layout ?? self.layout
        let key = try XCTUnwrap(layout.key(.character(String(letter))))
        return TouchLabel(point: CGPoint(x: key.frame.midX + x * (key.frame.width + layout.metrics.gap),
                                         y: key.frame.midY + y * (key.frame.height + layout.metrics.rowGap)), letter: letter)
    }

    private func stats(_ model: PersonalTypingModel, layout: KeyboardLayout? = nil) throws -> PersonalTypingModel.TouchStats {
        try XCTUnwrap(model.state.layouts[KeyboardLayoutSignature(layout ?? self.layout).id]?.keys["a"])
    }

    private func word(_ index: Int) -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        return "word" + String(letters[(index / 676) % 26]) + String(letters[(index / 26) % 26]) + String(letters[index % 26])
    }

    func testWelfordPopulationVarianceAndExponentialWeight() throws {
        let model = PersonalTypingModel()
        model.learn([try label(0.2, 0.3), try label(-0.2, -0.1)], layout: layout, source: .literalValid)
        var value = try stats(model)
        XCTAssertEqual(value.n, 2)
        XCTAssertEqual(value.meanX, 0, accuracy: 1e-12)
        XCTAssertEqual(value.varianceX, 0.04, accuracy: 1e-12)
        XCTAssertEqual(value.meanY, 0.1, accuracy: 1e-12)
        XCTAssertEqual(value.varianceY, 0.04, accuracy: 1e-12)
        model.reset()
        model.learn(Array(repeating: try label(), count: 64), layout: layout, source: .keep)
        model.learn([try label(0.64)], layout: layout, source: .manualPick)
        value = try stats(model)
        XCTAssertEqual(value.n, 65)
        XCTAssertEqual(value.meanX, 0.01, accuracy: 1e-12)
        XCTAssertEqual(value.varianceX, 0.0063, accuracy: 1e-12)
        XCTAssertEqual(value.meanY, 0)
    }

    func testEffectiveCountCapDoesNotStopUpdates() throws {
        let model = PersonalTypingModel()
        model.learn(Array(repeating: try label(), count: 300), layout: layout, source: .undo)
        XCTAssertEqual(try stats(model).n, 256)
        model.learn([try label(0.64)], layout: layout, source: .undo)
        XCTAssertEqual(try stats(model).meanX, 0.01, accuracy: 1e-12)
        XCTAssertEqual(model.summary.effectiveTouchCount, 256)
    }

    func testThresholdShrinkageAndCalibrationClamps() throws {
        let model = PersonalTypingModel()
        model.learn(Array(repeating: try label(0.4), count: 19), layout: layout, source: .keep)
        XCTAssertNil(model.calibration(for: layout))
        model.learn([try label(0.4)], layout: layout, source: .keep)
        var key = try XCTUnwrap(model.calibration(for: layout)?.keys["a"])
        // Slow sufficient statistics retain the original shrinkage reference;
        // fast/pooled inference can already move further after sustained evidence.
        XCTAssertEqual(try stats(model).calibration.offsetX, 0.2, accuracy: 1e-12)
        XCTAssertEqual(key.offsetX, 0.2, accuracy: 1e-12, "no fast drift before 20 pooled labels")
        XCTAssertTrue(SpatialTouchCalibration.sigmaRange.contains(key.sigmaX))
        model.learn(Array(repeating: try label(0.9), count: 300), layout: layout, source: .keep)
        key = try XCTUnwrap(model.calibration(for: layout)?.keys["a"])
        XCTAssertEqual(key.offsetX, SpatialTouchCalibration.maxOffset)
        XCTAssertTrue(SpatialTouchCalibration.sigmaRange.contains(key.sigmaX))
        model.resetFastAim()
        XCTAssertEqual(model.calibration(for: layout)?.keys["a"]?.sigmaX, 0.22)
        model.reset()
        for _ in 0..<150 {
            model.learn([try label(-0.9), try label(0.9)], layout: layout, source: .keep)
        }
        XCTAssertEqual(model.calibration(for: layout)?.keys["a"]?.sigmaX, 0.50)
        XCTAssertTrue(try XCTUnwrap(model.summary.layouts.first?.keys.first).isCalibrated)
    }

    func testRejectsNonFiniteOutlierUnknownKeyAndUnsupportedLayout() throws {
        let model = PersonalTypingModel()
        let outcome = model.learn([
            try label(), try label(1.01), try label(0.8, 0.8),
            .init(point: CGPoint(x: Double.nan, y: 0), letter: "a"),
            .init(point: CGPoint(x: 0, y: Double.infinity), letter: "a"),
            .init(point: .zero, letter: "ä"), .init(point: .zero, letter: "A"),
        ], layout: layout, source: .literalValid)
        XCTAssertEqual(outcome.accepted, 1)
        XCTAssertEqual(outcome.rejected, [.outlier: 2, .nonFinite: 2, .unknownKey: 2])
        for invalid in [KeyboardLayout(width: 393, layer: .numbers), KeyboardLayout(width: 393, field: .email)] {
            XCTAssertEqual(model.learn([try label()], layout: invalid, source: .keep).rejected, [.layoutMismatch: 1])
            XCTAssertNil(model.calibration(for: invalid))
        }
    }

    func testOnePitchLearningBoundaryIsInclusiveAcrossWidths() throws {
        for width: CGFloat in [320, 375, 393, 402, 430, 440] {
            let grid = KeyboardLayout(width: width)
            let model = PersonalTypingModel()
            let accepted = model.learn([try label(1, letter: "g", layout: grid)], layout: grid, source: .undo)
            XCTAssertEqual(accepted.accepted, 1)
            XCTAssertTrue(accepted.rejected.isEmpty)
            XCTAssertNotNil(model.state.validated())
            let rejected = model.learn([try label(1.01, letter: "g", layout: grid)], layout: grid, source: .undo)
            XCTAssertEqual(rejected.rejected[.outlier], 1)
        }
    }

    func testAlternatingOnePitchSamplesKeepVarianceValid() throws {
        for width: CGFloat in [320, 375, 393, 402, 430, 440] {
            let grid = KeyboardLayout(width: width)
            let model = PersonalTypingModel()
            for index in 0..<300 {
                let outcome = model.learn([try label(index.isMultiple(of: 2) ? 1 : -1,
                                                     letter: "g", layout: grid)], layout: grid, source: .undo)
                XCTAssertEqual(outcome.accepted, 1)
                XCTAssertNotNil(model.state.validated())
            }
            let value = try XCTUnwrap(model.state.layouts[KeyboardLayoutSignature(grid).id]?.keys["g"])
            XCTAssertGreaterThan(value.varianceX, 0.99)
            XCTAssertLessThanOrEqual(value.varianceX, 1)
        }
    }

    func testLayoutsAreSeparatedAndEvictedByLastUpdate() throws {
        var tick = 0.0
        let model = PersonalTypingModel(now: { tick += 1; return Date(timeIntervalSince1970: tick) })
        let layouts = [393, 410, 430, 450, 470].map { KeyboardLayout(width: CGFloat($0)) }
        for layout in layouts.prefix(4) { model.learn([try label(layout: layout)], layout: layout, source: .keep) }
        model.learn([try label(0.3, layout: layouts[0])], layout: layouts[0], source: .keep)
        model.learn([try label(layout: layouts[4])], layout: layouts[4], source: .keep)
        XCTAssertEqual(model.state.layouts.count, 4)
        XCTAssertNotNil(model.state.layouts[KeyboardLayoutSignature(layouts[0]).id])
        XCTAssertNil(model.state.layouts[KeyboardLayoutSignature(layouts[1]).id])
        XCTAssertEqual(try stats(model, layout: layouts[0]).n, 2)
        XCTAssertEqual(try stats(model, layout: layouts[4]).meanX, 0, accuracy: 1e-12)
        XCTAssertNil(model.calibration(for: KeyboardLayout(width: 393, showsStrip: false)))
        XCTAssertNil(model.calibration(for: KeyboardLayout(width: 393, orientation: .landscape)))
    }

    func testLearningOffPreservesStateAndProtectionsButHidesPriors() throws {
        let model = PersonalTypingModel()
        model.recordWord("hello")
        model.keep("hello")
        model.rejectCorrection(typed: "hello", replacement: "help")
        model.learn(Array(repeating: try label(), count: 20), layout: layout, source: .keep)
        XCTAssertEqual(model.lexicon.counts["hello"], 1)
        model.isLearningEnabled = false
        let before = model.state
        XCTAssertEqual(model.learn([try label()], layout: layout, source: .keep).rejected, [.learningOff: 1])
        XCTAssertFalse(model.recordWord("other"))
        XCTAssertEqual(model.state, before)
        XCTAssertNil(model.calibration(for: layout))
        XCTAssertTrue(model.lexicon.counts.isEmpty)
        XCTAssertTrue(model.lexicon.isKept("HELLO"))
        XCTAssertTrue(model.lexicon.isRejected(typed: "HELLO", replacement: "HELP"))
        XCTAssertTrue(model.keep("other"))
        XCTAssertTrue(model.lexicon.isKept("other"))
        model.isLearningEnabled = true
        XCTAssertEqual(model.lexicon.counts["hello"], 1)
        XCTAssertNotNil(model.calibration(for: layout))
    }

    func testNormalizationAndInvalidWords() {
        let model = PersonalTypingModel()
        for word in ["STRAẞE", "ÜBER", "a\u{0308}rger"] {
            XCTAssertTrue(model.keep(word))
            XCTAssertTrue(model.recordWord(word))
        }
        XCTAssertEqual(model.lexicon.kept, ["straße", "über", "ärger"])
        XCTAssertEqual(model.lexicon.counts, ["straße": 1, "über": 1, "ärger": 1])
        XCTAssertFalse(model.lexicon.isKept("strasse"), "ß is not folded to ss")
        for word in ["a", "two words", "can't", "word1", String(repeating: "a", count: 33)] {
            XCTAssertFalse(model.keep(word)); XCTAssertFalse(model.recordWord(word))
            if word != "can't" { XCTAssertFalse(model.rejectCorrection(typed: word, replacement: "hello")) }
        }
        model.forgetCount("ÜBER")
        XCTAssertNil(model.lexicon.counts["über"])
        XCTAssertTrue(model.lexicon.isKept("über"))
    }

    func testWordAndKeepCapsUseCountThenRecencyAndKeepLRU() throws {
        var tick = 0.0
        let model = PersonalTypingModel(now: { tick += 1; return Date(timeIntervalSince1970: tick) })
        for index in 0..<2000 { model.keep(word(index)); model.recordWord(word(index)) }
        model.keep(word(0))
        model.recordWord(word(0))
        model.keep(word(2000)); model.recordWord(word(2000))
        XCTAssertEqual(model.state.kept.count, 2000)
        XCTAssertEqual(model.state.counts.count, 2000)
        XCTAssertNotNil(model.state.kept[word(0)])
        XCTAssertNil(model.state.kept[word(1)])
        XCTAssertEqual(model.state.counts[word(0)]?.count, 2)
        XCTAssertNil(model.state.counts[word(1)])
        // Preserve the real capacity/eviction sequence above; seed only the saturation tail.
        var boundary = model.state
        boundary.counts[word(0)]?.count = 9_999
        let validated = try XCTUnwrap(boundary.validated())
        XCTAssertEqual(validated.counts.count, 2_000)
        XCTAssertEqual(validated.kept.count, 2_000)
        let capped = PersonalTypingModel(state: validated, now: { tick += 1; return Date(timeIntervalSince1970: tick) })
        XCTAssertEqual(capped.state, validated)
        XCTAssertEqual(capped.lexicon.counts[word(0)], 9_999) // Prime the cached snapshot too.
        var previousUpdate = try XCTUnwrap(capped.state.counts[word(0)]).lastUpdated
        for _ in 0..<2 {
            XCTAssertTrue(capped.recordWord(word(0)))
            let value = try XCTUnwrap(capped.state.counts[word(0)])
            XCTAssertEqual(value.count, 10_000)
            XCTAssertGreaterThan(value.lastUpdated, previousUpdate, "Recency must advance even at saturation")
            XCTAssertEqual(value.lastUpdated, Date(timeIntervalSince1970: tick))
            XCTAssertEqual(capped.lexicon.counts[word(0)], 10_000)
            XCTAssertEqual(capped.state.counts.count, 2_000)
            XCTAssertEqual(capped.state.kept, validated.kept)
            XCTAssertNotNil(capped.state.validated())
            previousUpdate = value.lastUpdated
        }
    }

    func testDisjointKeepsAndCountsShareOneBudgetWithKeepPriority() {
        let model = PersonalTypingModel()
        for index in 0..<1000 { model.keep(word(index)) }
        for index in 1000..<2000 { model.recordWord(word(index)) }
        XCTAssertEqual(Set(model.state.kept.keys).union(model.state.counts.keys).count, 2000)
        model.keep(word(2000))
        XCTAssertEqual(model.state.kept.count, 1001)
        XCTAssertEqual(model.state.counts.count, 999)
        XCTAssertTrue((0..<1000).allSatisfy { model.lexicon.isKept(word($0)) })
        XCTAssertNotNil(model.state.validated())
        var invalid = model.state
        invalid.counts[word(2001)] = .init(count: 2, lastUpdated: Date())
        XCTAssertNil(invalid.validated(), "Individually legal populations must not exceed the union bound")
        for index in 2001..<3000 { model.keep(word(index)) }
        model.recordWord("hello")
        XCTAssertEqual(model.state.kept.count, 2000)
        XCTAssertNil(model.state.counts["hello"], "Counts cannot evict a keep")
        XCTAssertNotNil(model.state.validated())
    }

    func testRejectedFormsAllowApostrophesButNotPhrasesOrNonletters() throws {
        let model = PersonalTypingModel()
        for replacement in ["DON'T", "Don’t", "I'm"] {
            XCTAssertTrue(model.rejectCorrection(typed: "DONT", replacement: replacement))
            XCTAssertTrue(model.lexicon.isRejected(typed: "dont", replacement: replacement))
            XCTAssertFalse(model.keep(replacement)); XCTAssertFalse(model.recordWord(replacement))
        }
        for replacement in ["two words", "word1", "''", "a", String(repeating: "a", count: 33)] {
            XCTAssertFalse(model.rejectCorrection(typed: "dont", replacement: replacement))
        }
        XCTAssertNotNil(model.state.validated())
        let reloaded = try JSONDecoder().decode(PersonalTypingModel.State.self, from: JSONEncoder().encode(model.state))
        XCTAssertEqual(reloaded.validated(), model.state)
    }

    func testRejectedPairsFIFOAndDeduplication() {
        let model = PersonalTypingModel()
        for index in 0..<513 { model.rejectCorrection(typed: word(index), replacement: "hello") }
        XCTAssertEqual(model.state.rejected.count, 512)
        XCTAssertFalse(model.lexicon.isRejected(typed: word(0), replacement: "hello"))
        XCTAssertTrue(model.lexicon.isRejected(typed: word(1), replacement: "hello"))
        model.rejectCorrection(typed: word(1).uppercased(), replacement: "HELLO")
        XCTAssertEqual(model.state.rejected.count, 512)
        XCTAssertEqual(model.state.rejected.first?.typed, word(1))
    }

    func testStateValidationAndCodableRoundTrip() throws {
        let model = PersonalTypingModel()
        model.learn([try label()], layout: layout, source: .keep)
        model.keep("hello"); model.recordWord("hello")
        model.rejectCorrection(typed: "hello", replacement: "help")
        let original = model.state
        let decoded = try JSONDecoder().decode(PersonalTypingModel.State.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.validated(), original)
        let id = KeyboardLayoutSignature(layout).id
        var bad = original; bad.layouts[id]?.keys["a"]?.meanX = .nan
        XCTAssertNil(bad.validated())
        bad = original; bad.layouts[id]?.keys["a"]?.varianceY = -0.1
        XCTAssertNil(bad.validated())
        bad = original; bad.layouts[id]?.keys["a"]?.n = 257
        XCTAssertNil(bad.validated())
        bad = original; bad.counts["hello"]?.count = -1
        XCTAssertNil(bad.validated())
        bad = original; bad.schemaVersion = 99
        XCTAssertNil(bad.validated())
        bad = original; bad.kept["HELLO"] = Date()
        XCTAssertNil(bad.validated())
        bad = original; bad.layouts[id]?.keys["ä"] = .init(n: 1)
        XCTAssertNil(bad.validated())
        bad = original; bad.layouts["wrong-id"] = bad.layouts.removeValue(forKey: id)
        XCTAssertNil(bad.validated())
        bad = original
        for width in [410, 430, 450, 470] {
            let signature = KeyboardLayoutSignature(KeyboardLayout(width: CGFloat(width)))
            bad.layouts[signature.id] = .init(signature: signature, lastUpdated: Date(), keys: ["a": .init(n: 1)])
        }
        XCTAssertNil(bad.validated())
        bad = original
        for index in 0..<513 { bad.rejected.append(.init(typed: word(index), replacement: "hello")) }
        XCTAssertNil(bad.validated())
        bad = original
        for index in 0..<2001 { bad.counts[word(index)] = .init(count: 1, lastUpdated: Date()) }
        XCTAssertNil(bad.validated())
        bad = original
        for index in 0..<2001 { bad.kept[word(index)] = Date() }
        XCTAssertNil(bad.validated())
        XCTAssertEqual(PersonalTypingModel(state: bad).state, .init())
    }

    func testLearningCountersAndAlignmentRejectionsSaturate() throws {
        var diagnostics = KeyboardDiagnostics()
        diagnostics.recordLabels(.init(accepted: Int.max), source: .keep)
        diagnostics.recordLabels(.init(accepted: 1), source: .keep)
        XCTAssertEqual(diagnostics.acceptedBySource["keep"], Int(Int32.max))
        diagnostics.recordRejection(.ambiguousAlignment, count: Int.max)
        diagnostics.recordRejection(.ambiguousAlignment, count: 1)
        diagnostics.recordRejection(.layoutMismatch, count: -1)
        XCTAssertEqual(diagnostics.rejectedByReason["ambiguousAlignment"], Int(Int32.max))
        XCTAssertNil(diagnostics.rejectedByReason["layoutMismatch"])
    }

    func testLearnedSpaceAimShiftsTheSpaceDensityAndSurvivesValidation() throws {
        let model = PersonalTypingModel()
        let space = try XCTUnwrap(layout.key(.space))
        let pitchY = space.frame.height + layout.metrics.rowGap
        let low = CGPoint(x: space.frame.minX + 10, y: space.frame.midY + 0.25 * pitchY)
        let far = CGPoint(x: space.frame.midX, y: space.frame.midY - 2 * pitchY)
        XCTAssertEqual(model.learnSpace(far, layout: layout).rejected, [.outlier: 1])
        for _ in 0..<40 { model.learnSpace(low, layout: layout) }
        let spaceOnly = try XCTUnwrap(model.state.validated())
        XCTAssertEqual(spaceOnly.layouts.values.first?.keys.isEmpty, true)
        XCTAssertNil(model.calibration(for: layout), "Space aim applies once the letters are calibrated")
        model.learn(Array(repeating: try label(), count: 20), layout: layout, source: .keep)
        let calibration = try XCTUnwrap(model.calibration(for: layout))
        XCTAssertGreaterThan(try XCTUnwrap(calibration.space).offsetY, 0.1)
        let learned = try XCTUnwrap(KeyboardBoundaryTouch.spaceDensity(low, layout: layout, calibration: calibration))
        let fixed = try XCTUnwrap(KeyboardBoundaryTouch.spaceDensity(low, layout: layout))
        XCTAssertGreaterThan(learned, fixed)
        let data = try JSONEncoder().encode(model.state)
        let restored = PersonalTypingModel(state: try JSONDecoder().decode(PersonalTypingModel.State.self, from: data))
        XCTAssertEqual(restored.calibration(for: layout), calibration)
    }

    func testResetClearsAggregatesAndProtections() throws {
        let model = PersonalTypingModel()
        model.keep("hello"); model.recordWord("hello")
        model.rejectCorrection(typed: "hello", replacement: "help")
        model.learn([try label()], layout: layout, source: .keep)
        _ = model.lexicon
        model.reset()
        XCTAssertEqual(model.lexicon, .empty)
        XCTAssertEqual(model.state, .init())
    }
}
