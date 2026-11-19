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

    func testFixedShareRecoveryAndGlobalTransferReset() throws {
        let model = warm()
        let baseline = try XCTUnwrap(model.calibration(for: grid)?.keys["z"])
        // A shared translation observed on a few frequent keys only.
        for _ in 0..<6 { model.learn("entaoi".map { label($0, 0.24, 0.10) }, layout: grid, source: .keep) }
        let shifted = try XCTUnwrap(model.calibration(for: grid)?.keys["z"])
        // z (bottom left) lies outside the labelled keys' span: ridge-shrunk extrapolation.
        XCTAssertGreaterThan(shifted.offsetX, baseline.offsetX + 0.1, "an unlabelled key receives the shared shift")
        XCTAssertGreaterThan(shifted.offsetY, baseline.offsetY + 0.04)
        for _ in 0..<3 { model.learn("entaoi".map { label($0, 0, 0) }, layout: grid, source: .keep) }
        let returned = try XCTUnwrap(model.calibration(for: grid)?.keys["z"])
        XCTAssertLessThan(abs(returned.offsetX - baseline.offsetX), 0.06, "returning aim recovers within 18 labels")
        let frozen = model.calibration(for: grid)
        let restored = PersonalTypingModel(state: model.state)
        model.resetFastAim()
        XCTAssertEqual(model.calibration(for: grid), restored.calibration(for: grid))
        XCTAssertNotEqual(frozen, model.calibration(for: grid))
        // The returned snapshot is immutable even if labels arrive later.
        model.learn(Array(repeating: label("e", -0.24, 0), count: 30), layout: grid, source: .keep)
        XCTAssertEqual(frozen?.keys["z"], returned)
        let beforeOtherLayoutRead = model.calibration(for: grid)
        let other = KeyboardLayout(width: 430)
        _ = model.calibration(for: other)
        XCTAssertEqual(model.calibration(for: grid), beforeOtherLayoutRead, "Snapshot reads cannot silently reset aim")
        let e = try XCTUnwrap(other.key(.character("e"))).frame
        model.learn([.init(point: CGPoint(x: e.midX, y: e.midY), letter: "e")], layout: other, source: .keep)
        XCTAssertEqual(model.calibration(for: grid), PersonalTypingModel(state: model.state).calibration(for: grid))
    }

    func testPrequentialFixedShareWeightsAndLifecycleReset() {
        let slow = SpatialTouchCalibration.Key(offsetX: 0.05, offsetY: 0, sigmaX: 0.3, sigmaY: 0.3)
        let share = TouchAimDrift.share
        var drift = TouchAimDrift()
        XCTAssertEqual(drift.prediction(slow: slow, features: SIMD3(1, 0.5, -0.5)), slow, "no labels: exactly the slow model")
        drift.update(x: 0.65, y: 0.1, slow: slow, features: SIMD3(1, 0, 0))
        // All memories predicted identically before the first label: only the share moves weights.
        XCTAssertEqual(drift.weights[0], (1 - share) * (1 - 2 * share / 3) + share / 3, accuracy: 1e-12)
        // Ridge regression toward no drift: (1 + 1)⁻¹ · 0.6 for the intercept.
        XCTAssertEqual(drift.medium.coefficients.x[0], 0.6 / 2, accuracy: 1e-12)
        XCTAssertEqual(drift.fast.coefficients.y[0], 0.1 / 2, accuracy: 1e-12)
        XCTAssertEqual(drift.medium.coefficients.x[1], 0, accuracy: 1e-12)
        // A position-dependent shift (affine field) is learned and transfers to unseen positions.
        let field: (SIMD3<Double>) -> (Double, Double) = { (0.3 - 0.2 * $0[1], 0.1 + 0.1 * $0[2]) }
        var positions: [SIMD3<Double>] = []
        for u in stride(from: -1.0, through: 1.0, by: 0.5) { for v in [-1.0, 0, 1] { positions.append(SIMD3(1, u, v)) } }
        for i in 0..<60 {
            let φ = positions[i % positions.count], d = field(φ)
            drift.update(x: slow.offsetX + d.0, y: slow.offsetY + d.1, slow: slow, features: φ)
        }
        XCTAssertLessThan(drift.weights[0], 0.05, "the stable memory loses after a sustained shift")
        let far = drift.prediction(slow: slow, features: SIMD3(1, -1, 0.5))
        // Ridge shrinkage and the residual stable/fast weights keep the extrapolated corner
        // conservative (true drift .5): most of the shift, never an overshoot.
        XCTAssertGreaterThan(far.offsetX - slow.offsetX, 0.38)
        XCTAssertLessThan(far.offsetX - slow.offsetX, 0.5)
        XCTAssertEqual(far.offsetY, slow.offsetY + 0.15, accuracy: 0.03)
        XCTAssertEqual(drift.weights.sum(), 1, accuracy: 1e-12)
        // Returning to the original aim: within 8 labels the prediction is back near the slow model.
        var returned = drift
        for i in 0..<8 { returned.update(x: slow.offsetX, y: slow.offsetY, slow: slow, features: positions[i]) }
        XCTAssertLessThan(abs(returned.prediction(slow: slow, features: SIMD3(1, -1, 0.5)).offsetX - slow.offsetX), 0.1)
        XCTAssertGreaterThan(returned.weights[0] + returned.weights[2], 0.9, "stable and fast memories explain the return")
        XCTAssertTrue((0..<3).allSatisfy { returned.weights[$0] >= share / 3 })
        // Non-finite input never changes state.
        var copy = returned
        copy.update(x: .nan, y: 0, slow: slow, features: SIMD3(1, 0, 0))
        XCTAssertEqual(copy, returned)

        let session = KeyboardLearningSession()
        for _ in 0..<40 { session.learn([label("e", 0.2, 0.1)], layout: grid, source: .keep) }
        let before = session.model.state
        let generation = session.generation
        session.resetFastAim()
        XCTAssertGreaterThan(session.generation, generation)
        XCTAssertEqual(session.model.state, before)
        XCTAssertEqual(session.calibration(for: grid), PersonalTypingModel(state: before).calibration(for: grid))
    }

    func testAffineRidgeAgainstIndependentNormalEquationReference() {
        var memory = TouchAimDrift.Memory(length: 8)
        var gram = Array(repeating: Array(repeating: 0.0, count: 3), count: 3)
        var cross = [0.0, 0.0, 0.0]
        for i in 0..<80 {
            let f = [1.0, Double(i % 7 - 3) / 3, Double(i % 5 - 2) / 2]
            let residual = 0.3 - 0.2 * f[1] + 0.1 * f[2]
            for j in 0..<3 {
                cross[j] = 0.875 * cross[j] + f[j] * residual
                for k in 0..<3 { gram[j][k] = 0.875 * gram[j][k] + f[j] * f[k] }
            }
            memory.update(features: SIMD3(f[0], f[1], f[2]), residualX: residual, residualY: -residual)
        }
        XCTAssertLessThanOrEqual(memory.gram[0], 8)
        // Independent explicit 3×3 adjugate inverse, NOT production Cholesky.
        let a = gram[0][0] + 1, b = gram[0][1], c = gram[0][2]
        let d = gram[1][1] + 2, e = gram[1][2], f = gram[2][2] + 2
        let cofactors = [[d * f - e * e, c * e - b * f, b * e - c * d],
                         [c * e - b * f, a * f - c * c, b * c - a * e],
                         [b * e - c * d, b * c - a * e, a * d - b * b]]
        let determinant = a * cofactors[0][0] + b * cofactors[0][1] + c * cofactors[0][2]
        let solution = memory.coefficients
        for j in 0..<3 {
            let reference = (0..<3).reduce(0.0) { $0 + cofactors[j][$1] * cross[$1] } / determinant
            XCTAssertEqual(solution.x[j], reference, accuracy: 1e-12)
            XCTAssertEqual(solution.y[j], -reference, accuracy: 1e-12)
        }
        var drift = TouchAimDrift()
        let before = drift
        let slow = SpatialTouchCalibration.Key(offsetX: 0, offsetY: 0, sigmaX: 0.2, sigmaY: 0.2)
        for position in [SIMD3(1.0, Double.nan, 0), SIMD3(1.0, 0, Double.infinity), SIMD3(1.0, 1.1, 0)] {
            drift.update(x: 0.3, y: 0, slow: slow, features: position)
            XCTAssertEqual(drift, before)
        }
    }

    func testMigrationRepairAndFastPrivacy() throws {
        let model = warm()
        model.keep("hallo"); model.recordWord("hello"); model.rejectCorrection(typed: "hallo", replacement: "hello")
        let data = try JSONEncoder().encode(model.state)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schemaVersion"] = 1
        var layouts = try XCTUnwrap(object["layouts"] as? [String: [String: Any]])
        for id in layouts.keys {
            var layout = layouts[id]!
            layout.removeValue(forKey: "global")
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
        XCTAssertTrue(migrated.layouts.values.allSatisfy { $0.global == nil && $0.keys.values.allSatisfy { $0.covarianceXY == 0 } })
        var broken = model.state
        let id = KeyboardLayoutSignature(grid).id
        broken.layouts[id]?.keys["a"]?.covarianceXY = 1
        broken.layouts[id]?.global?.meanX = .nan
        XCTAssertNil(broken.validated())
        XCTAssertTrue(broken.discardInvalidTouchStats())
        XCTAssertNotNil(broken.validated())
        XCTAssertEqual(broken.kept, model.state.kept)
        var future = migrated; future.schemaVersion = 99
        XCTAssertNil(future.validated())
        let encoded = String(decoding: data, as: UTF8.self)
        for forbidden in ["fast", "medium", "weights", "recent", "point"] { XCTAssertFalse(encoded.contains("\"" + forbidden + "\"")) }
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
        let fastPayload = MemoryLayout<TouchAimDrift>.stride
        XCTAssertLessThan(touchBytes, 64 * 1024)
        XCTAssertLessThan(slowPayload + fastPayload, 16 * 1024)
        XCTAssertEqual(model.state.layouts.count, 1)
        print("EVAL P7_memory slowPayloadMaxBytes=\(slowPayload) fastPayloadMaxBytes=\(fastPayload) fourLayoutEncodedBytes=\(touchBytes) storeLimitBytes=\(KeyboardLearningStore.maximumLearningBytes) heapOverheadExcluded=true")
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
