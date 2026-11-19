import Foundation
import XCTest
@testable import Typr

@MainActor
final class PersonalTypingAimTests: XCTestCase {
    private let grid = KeyboardLayout(width: 393)

    private func label(_ letter: Character, _ x: Double, _ y: Double) -> TouchLabel {
        let key = grid.key(.character(String(letter)))!
        return TouchLabel(point: CGPoint(x: key.frame.midX + x * (key.frame.width + grid.metrics.gap),
                                         y: key.frame.midY + y * (key.frame.height + grid.metrics.rowGap)), letter: letter)
    }

    private func warm() -> PersonalTypingModel {
        let model = PersonalTypingModel()
        for i in 0..<160 {
            model.learn("abcdefghijklmnopqrstuvwxyz".map {
                label($0, Double(i % 5 - 2) * 0.035, Double(i % 3 - 1) * 0.05)
            }, layout: grid, source: .keep)
        }
        return model
    }

    func testCovarianceReferenceAndInvalidInput() {
        var stats = PersonalTypingModel.TouchStats()
        for (x, y) in [(0.2, 0.3), (-0.2, -0.1), (0.3, -0.2)] { stats.update(x: x, y: y) }
        XCTAssertEqual(stats.meanX, 0.1, accuracy: 1e-12)
        XCTAssertEqual(stats.meanY, 0, accuracy: 1e-12)
        XCTAssertEqual(stats.varianceX, 0.04666666666666667, accuracy: 1e-12)
        XCTAssertEqual(stats.varianceY, 0.04666666666666667, accuracy: 1e-12)
        XCTAssertEqual(stats.covarianceXY, 0.006666666666666667, accuracy: 1e-12)
        let before = stats
        stats.update(x: .nan, y: 0); stats.update(x: 0, y: .infinity)
        XCTAssertEqual(stats, before)
        stats.covarianceXY = 1
        XCTAssertFalse(stats.isValid)
    }

    func testFiniteEigenvalueFloorsAndDiagonalEquivalence() throws {
        for xy in [-1e100, -0.1, 0, 0.1, 1e100] {
            let key = try XCTUnwrap(SpatialTouchCalibration(keys: ["a": .init(
                offsetX: 10, offsetY: -10, sigmaX: 0.3, sigmaY: 0.4, covarianceXY: xy)]).keys["a"])
            let xx = key.sigmaX * key.sigmaX, yy = key.sigmaY * key.sigmaY
            let radius = hypot(xx - yy, 2 * key.covarianceXY)
            let floor = SpatialTouchCalibration.scaleRange(degrees: key.degrees).lowerBound
            XCTAssertGreaterThanOrEqual((xx + yy - radius) / 2, floor * floor - 1e-12)
            XCTAssertLessThanOrEqual((xx + yy + radius) / 2, 1 + 1e-12)
            XCTAssertGreaterThanOrEqual(xx * yy - key.covarianceXY * key.covarianceXY, pow(floor, 4) - 1e-12)
            XCTAssertTrue(key.logDensity(x: 1, y: -1).isFinite)
        }
        XCTAssertTrue(SpatialTouchCalibration(keys: ["a": .init(offsetX: 0, offsetY: 0,
            sigmaX: 0.3, sigmaY: 0.3, covarianceXY: .nan)]).keys.isEmpty)
        let diagonal = SpatialTouchCalibration.Key(offsetX: 0.1, offsetY: -0.1, sigmaX: 0.35, sigmaY: 0.35, degrees: 9)
        XCTAssertEqual(diagonal.logDensity(x: 0.3, y: 0.2),
                       -5.5 * log1p((0.2 * 0.2 + 0.3 * 0.3) / (0.35 * 0.35) / 9) - log(2 * Double.pi * 0.35 * 0.35),
                       accuracy: 1e-12)
        // Numerical integration checks normalized density, including a tilted cloud.
        let tilted = try XCTUnwrap(SpatialTouchCalibration(keys: ["a": .init(offsetX: 0, offsetY: 0,
            sigmaX: 0.15, sigmaY: 0.15, covarianceXY: 0.01)]).keys["a"])
        var mass = 0.0
        for i in -150...150 { for j in -150...150 {
            mass += exp(tilted.logDensity(x: Double(i) * 0.01, y: Double(j) * 0.01)) * 0.0001
        } }
        XCTAssertEqual(mass, 1, accuracy: 0.0001)
        XCTAssertGreaterThan(tilted.logDensity(x: 0.3, y: 0.3), tilted.logDensity(x: 0.3, y: -0.3))
    }

    func testPooledReferenceTiltedCloudAndScarceLabels() throws {
        let model = PersonalTypingModel()
        let signature = KeyboardLayoutSignature(grid)
        var layout = PersonalTypingModel.LayoutStats(signature: signature, lastUpdated: Date())
        layout.keys["a"] = .init(n: 20, varianceX: 0.08, varianceY: 0.06, covarianceXY: 0.03)
        XCTAssertEqual(layout.pooled.xx, (7 * 0.04 + 20 * 0.08) / 27, accuracy: 1e-12)
        XCTAssertEqual(layout.pooled.xy, 20 * 0.03 / 27, accuracy: 1e-12)
        XCTAssertEqual(layout.slowKey(layout.keys["a"]).covarianceXY,
                       (7 * layout.pooled.xy + 20 * 0.03) * 22 / (21 * 29), accuracy: 1e-12)
        XCTAssertEqual(layout.slowKey(layout.keys["a"]).degrees, 29)
        for i in 0..<120 {
            let x = Double(i % 7 - 3) * 0.15
            model.learn([label("a", x, x * 0.8)], layout: grid, source: .keep)
        }
        let keys = try XCTUnwrap(model.calibration(for: grid)?.keys)
        XCTAssertGreaterThan(try XCTUnwrap(keys["a"]).covarianceXY, 0.02)
        XCTAssertGreaterThan(try XCTUnwrap(keys["z"]).covarianceXY, 0.02, "pooled covariance reaches an unseen key")
        let sparse = PersonalTypingModel()
        XCTAssertNil(sparse.calibration(for: grid))
        sparse.learn([label("t", 0.2, 0.1)], layout: grid, source: .keep)
        XCTAssertGreaterThan(try XCTUnwrap(sparse.calibration(for: grid)?.keys["z"]).offsetX, 0.05)
    }

    private func key(_ model: PersonalTypingModel, _ letter: Character,
                     on layout: KeyboardLayout? = nil) throws -> SpatialTouchCalibration.Key {
        try XCTUnwrap(model.calibration(for: layout ?? grid)?.keys[letter])
    }

    func testDisplacedTapsMoveOnlyThatKeyAndStableTapsRecover() throws {
        let model = warm()
        let before = try XCTUnwrap(model.calibration(for: grid))
        let allTaps = PersonalTypingModel(state: model.state)
        for _ in 0..<3 { model.learn([label("e", 0.3, 0.15)], layout: grid, source: .keep) }
        let shifted = try key(model, "e")
        var slowOnly = try XCTUnwrap(model.state.layouts[KeyboardLayoutSignature(grid).id])
        slowOnly.aims = nil
        let slowShift = slowOnly.allTapsKey("e").offsetX - (before.keys["e"]?.offsetX ?? 0)
        XCTAssertGreaterThan(shifted.offsetX - before.keys["e"]!.offsetX, 0.08, "three displaced taps move the key")
        XCTAssertGreaterThan(shifted.offsetX - before.keys["e"]!.offsetX, 3 * slowShift, "the fast memory carries it")
        XCTAssertGreaterThan(shifted.offsetY - before.keys["e"]!.offsetY, 0.04)
        let aim = try XCTUnwrap(model.state.layouts[KeyboardLayoutSignature(grid).id]?.aims?["e"])
        XCTAssertGreaterThan(aim.weights[2], aim.weights[0], "now predicted the repeated miss best")
        for letter in "abcdfghijklmnopqrstuvwxyz" {
            let other = try key(model, letter), old = try XCTUnwrap(before.keys[letter])
            XCTAssertEqual(other.offsetX, old.offsetX, accuracy: 1e-12, "\(letter) does not inherit e's centre")
            XCTAssertEqual(other.offsetY, old.offsetY, accuracy: 1e-12)
        }
        XCTAssertEqual(try key(allTaps, "e"), before.keys["e"])
        for _ in 0..<4 { model.learn([label("e", 0, 0)], layout: grid, source: .keep) }
        let returned = try key(model, "e")
        XCTAssertLessThan(abs(returned.offsetX - before.keys["e"]!.offsetX), 0.035, "stable taps move it back")
        XCTAssertLessThan(abs(returned.offsetY - before.keys["e"]!.offsetY), 0.02)
    }

    func testPrequentialWeightsAgainstIndependentReference() {
        let all = SpatialTouchCalibration.Key(offsetX: 0.05, offsetY: 0, sigmaX: 0.2, sigmaY: 0.2, degrees: 29)
        var aim = PersonalTypingModel.KeyAim(seed: .init(n: 20, meanX: 0.05))
        XCTAssertEqual(aim.lately, .init(count: 20, x: 0.05, y: 0))
        XCTAssertEqual(aim.now, .init(count: 3, x: 0.05, y: 0))
        var reference = [1.0 / 3, 1.0 / 3, 1.0 / 3]
        var lately = (count: 20.0, x: 0.05), now = (count: 3.0, x: 0.05)
        func density(_ meanX: Double, _ scale: Double, _ x: Double) -> Double {
            -log(2 * Double.pi * scale) - 15.5 * log1p((x - meanX) * (x - meanX) / scale / 29)
        }
        for x in [0.4, 0.4, 0.4, 0.0, -0.1] {
            // all: κ = 21; a drift with c taps: κ = 1 + c, mean (0.05 + c·x̄)/(1 + c).
            let scores = [density(0.05, 0.04, x),
                          density((0.05 + lately.count * lately.x) / (1 + lately.count),
                                  0.04 * (2 + lately.count) / (1 + lately.count) * 21 / 22, x),
                          density((0.05 + now.count * now.x) / (1 + now.count),
                                  0.04 * (2 + now.count) / (1 + now.count) * 21 / 22, x)]
            let odds = (0..<3).map { reference[$0] * exp(scores[$0]) }
            reference = odds.map { 0.99 * $0 / odds.reduce(0, +) + 0.01 / 3 }
            lately.count = lately.count * (1 - 1 / 30.0) + 1; lately.x += (x - lately.x) / lately.count
            now.count = now.count * (1 - 1 / 3.0) + 1; now.x += (x - now.x) / now.count
            aim.add(x: x, y: 0, all: all, n: 20)
            for i in 0..<3 { XCTAssertEqual(aim.weights[i], reference[i], accuracy: 1e-12) }
            XCTAssertEqual(aim.lately.x, lately.x, accuracy: 1e-12)
            XCTAssertEqual(aim.now.x, now.x, accuracy: 1e-12)
            XCTAssertEqual(aim.weights.reduce(0, +), 1, accuracy: 1e-12)
            XCTAssertTrue(aim.weights.allSatisfy { $0 >= 0.01 / 3 })
        }
        let blended = aim.key(all, n: 20)
        let means = [0.05, (0.05 + lately.count * lately.x) / (1 + lately.count), (0.05 + now.count * now.x) / (1 + now.count)]
        let mean = (0..<3).reduce(0) { $0 + reference[$1] * means[$1] }
        XCTAssertEqual(blended.offsetX, mean, accuracy: 1e-12)
        let scales = [0.04, 0.04 * (2 + lately.count) / (1 + lately.count) * 21 / 22,
                      0.04 * (2 + now.count) / (1 + now.count) * 21 / 22]
        let between = (0..<3).reduce(0) { $0 + reference[$1] * (scales[$1] + 27.0 / 29 * pow(means[$1] - mean, 2)) }
        XCTAssertEqual(blended.sigmaX * blended.sigmaX, between, accuracy: 1e-12, "between-memory uncertainty widens the key")
    }

    func testReloadGivesTheSameNextScoreAndLayoutsStayIsolated() throws {
        let model = warm()
        let other = KeyboardLayout(width: 430)
        let otherE = try XCTUnwrap(other.key(.character("e"))).frame
        model.learn([.init(point: CGPoint(x: otherE.midX, y: otherE.midY), letter: "e")], layout: other, source: .keep)
        let otherBefore = model.calibration(for: other)
        for _ in 0..<3 { model.learn([label("e", 0.3, 0.15)], layout: grid, source: .keep) }
        XCTAssertEqual(model.calibration(for: other), otherBefore, "another layout keeps its own memories")
        let reloaded = PersonalTypingModel(state: try JSONDecoder().decode(
            PersonalTypingModel.State.self, from: JSONEncoder().encode(model.state)))
        XCTAssertEqual(reloaded.state, model.state)
        XCTAssertEqual(reloaded.calibration(for: grid), model.calibration(for: grid))
        for next in [label("e", 0.25, 0.1), label("r", -0.1, 0)] {
            model.learn([next], layout: grid, source: .keep); reloaded.learn([next], layout: grid, source: .keep)
        }
        let a = try key(model, "e"), b = try key(reloaded, "e")
        XCTAssertEqual(a.logDensity(x: 0.2, y: 0.1), b.logDensity(x: 0.2, y: 0.1), accuracy: 1e-12)
        XCTAssertEqual(reloaded.calibration(for: grid), model.calibration(for: grid))
        XCTAssertEqual(model.calibration(for: other), otherBefore)
    }

    func testLearningOffAndResetLeaveNoMemories() throws {
        let model = warm()
        for _ in 0..<3 { model.learn([label("e", 0.3, 0.15)], layout: grid, source: .keep) }
        let state = model.state, calibration = model.calibration(for: grid)
        model.isLearningEnabled = false
        XCTAssertEqual(model.learn([label("e", -0.3, 0)], layout: grid, source: .keep).rejected, [.learningOff: 1])
        XCTAssertNil(model.calibration(for: grid))
        XCTAssertEqual(model.state, state, "learning off learns nothing")
        model.isLearningEnabled = true
        XCTAssertEqual(model.calibration(for: grid), calibration)
        model.reset()
        XCTAssertEqual(model.state, PersonalTypingModel.State())
        XCTAssertNil(model.calibration(for: grid))
    }

    func testMigrationRepairAndAggregatePrivacy() throws {
        let model = warm()
        model.keep("hallo"); model.recordWord("hello"); model.rejectCorrection(typed: "hallo", replacement: "hello")
        let data = try JSONEncoder().encode(model.state)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schemaVersion"] = 1
        var layouts = try XCTUnwrap(object["layouts"] as? [String: [String: Any]])
        for id in layouts.keys {
            var layout = layouts[id]!
            layout.removeValue(forKey: "global")
            layout.removeValue(forKey: "aims")
            var keys = layout["keys"] as! [String: [String: Any]]
            for key in keys.keys { keys[key]!.removeValue(forKey: "covarianceXY") }
            layout["keys"] = keys; layouts[id] = layout
        }
        object["layouts"] = layouts
        let legacy = try JSONDecoder().decode(PersonalTypingModel.State.self, from: JSONSerialization.data(withJSONObject: object))
        let migrated = try XCTUnwrap(legacy.validated())
        XCTAssertEqual(migrated.schemaVersion, 5)
        XCTAssertEqual(migrated.kept, model.state.kept)
        XCTAssertEqual(migrated.counts, model.state.counts)
        XCTAssertEqual(migrated.rejected, model.state.rejected)
        XCTAssertTrue(migrated.layouts.values.allSatisfy { $0.global == nil && $0.aims == nil && $0.keys.values.allSatisfy { $0.covarianceXY == 0 } })
        let seeded = try XCTUnwrap(migrated.layouts.values.first)
        XCTAssertEqual(seeded.aim("e"), .init(seed: seeded.keys["e"]), "missing memories start where all taps centre")
        XCTAssertNotNil(PersonalTypingModel(state: migrated).calibration(for: grid))
        var broken = model.state
        let id = KeyboardLayoutSignature(grid).id
        broken.layouts[id]?.keys["a"]?.covarianceXY = 1
        broken.layouts[id]?.global?.meanX = .nan
        broken.layouts[id]?.aims?["e"]?.weights = [.nan, 0.5, 0.5]
        broken.layouts[id]?.aims?["t"]?.now.x = .infinity
        broken.layouts[id]?.aims?["o"]?.weights = [0.9, 0.9, 0.9]
        XCTAssertNil(broken.validated())
        XCTAssertTrue(broken.discardInvalidTouchStats())
        XCTAssertNotNil(broken.validated())
        let repaired = try XCTUnwrap(broken.layouts[id])
        XCTAssertNil(repaired.aims?["e"]); XCTAssertNil(repaired.aims?["t"]); XCTAssertNil(repaired.aims?["o"])
        XCTAssertNotNil(repaired.keys["e"], "a repaired key keeps its statistics and reseeds its memories")
        XCTAssertNotNil(repaired.aims?["n"])
        XCTAssertTrue(PersonalTypingModel(state: broken).calibration(for: grid)?.keys["e"]?.offsetX.isFinite == true)
        var orphan = model.state
        orphan.layouts[id]?.keys.removeValue(forKey: "q")
        XCTAssertNil(orphan.validated(), "memories without the key's statistics are invalid")
        XCTAssertEqual(broken.kept, model.state.kept)
        var future = migrated; future.schemaVersion = 99
        XCTAssertNil(future.validated())
        let encoded = String(decoding: data, as: UTF8.self)
        for forbidden in ["recent", "point", "taps"] { XCTAssertFalse(encoded.contains("\"" + forbidden + "\"")) }
        let object2 = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let stored = try XCTUnwrap((object2["layouts"] as? [String: [String: Any]])?.values.first?["aims"] as? [String: [String: Any]])
        XCTAssertEqual(stored.count, 26)
        for aim in stored.values {
            XCTAssertEqual(Set(aim.keys), ["lately", "now", "weights"], "fixed-size aggregates, no ordered taps")
            XCTAssertEqual((aim["weights"] as? [Double])?.count, 3)
            XCTAssertEqual(Set(((aim["now"] as? [String: Any]) ?? [:]).keys), ["count", "x", "y"])
        }
    }

    func testMemoryByteBounds() throws {
        let model = warm()
        var maximumLayouts = model.state
        let template = try XCTUnwrap(model.state.layouts.values.first)
        for width: CGFloat in [410, 430, 450] {
            var layout = template
            layout.signature = KeyboardLayoutSignature(KeyboardLayout(width: width))
            maximumLayouts.layouts[layout.signature.id] = layout
        }
        XCTAssertNotNil(maximumLayouts.validated())
        let touchBytes = try JSONEncoder().encode(maximumLayouts).count
        let slowPayload = 4 * 27 * MemoryLayout<PersonalTypingModel.TouchStats>.stride
        let aimPayload = 4 * 26 * (MemoryLayout<PersonalTypingModel.KeyAim>.stride + 3 * MemoryLayout<Double>.stride)
        XCTAssertEqual(template.aims?.count, 26)
        XCTAssertLessThan(touchBytes, 64 * 1024)
        XCTAssertLessThan(slowPayload + aimPayload, 32 * 1024)
        XCTAssertEqual(model.state.layouts.count, 1)
        print("EVAL P7_memory slowPayloadMaxBytes=\(slowPayload) aimPayloadMaxBytes=\(aimPayload) fourLayoutEncodedBytes=\(touchBytes) storeLimitBytes=\(KeyboardLearningStore.maximumLearningBytes) heapOverheadExcluded=true")
        var fileBytes = 0, nodes = 0
        for lexicon in try XCTUnwrap(BundledKeyboardData.lexicons).values {
            fileBytes += lexicon.data.count; nodes += lexicon.nodeCount
        }
        let indexBytes = nodes * MemoryLayout<UInt32>.stride
        let lengthBytes = nodes * MemoryLayout<UInt16>.stride
        XCTAssertLessThan(fileBytes + 2 * indexBytes + lengthBytes, 8 * 1024 * 1024, "shipping data plus subtree priors, child masks and length spans, not RSS")
        print("EVAL P7_lexiconMemory mappedFileBytes=\(fileBytes) priorIndexBytes=\(indexBytes) continuationMaskBytes=\(indexBytes) lengthSpanBytes=\(lengthBytes) totalFileAndIndexBytes=\(fileBytes + 2 * indexBytes + lengthBytes) transientAndHeapOverheadExcluded=true")
        // Exercise a real read and trusted update, without benchmark repetition.
        XCTAssertNotNil(model.calibration(for: grid))
        let outcome = model.learn([label("e", 0.15, 0.1)], layout: grid, source: .keep)
        XCTAssertEqual(outcome.accepted, 1)
        XCTAssertNotNil(model.calibration(for: grid))
        XCTAssertNotNil(model.state.validated())
        maximumLayouts.layouts[KeyboardLayoutSignature(grid).id] = model.state.layouts[KeyboardLayoutSignature(grid).id]
        XCTAssertNotNil(maximumLayouts.validated())
        XCTAssertLessThan(try JSONEncoder().encode(maximumLayouts).count, 64 * 1024,
                          "The four-layout byte bound must still hold after learning")
    }
}
