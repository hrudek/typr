import Foundation
import XCTest
@testable import Typr

@MainActor
final class TouchPosteriorTests: XCTestCase {
    private let layout = KeyboardLayout(width: 393)
    private let taps: [(Double, Double)] = [
        (0.12, 0.05), (0.20, -0.03), (0.08, 0.10), (0.15, 0.0), (0.22, 0.07),
        (0.05, -0.05), (0.18, 0.12), (0.10, 0.02), (0.25, 0.04), (0.14, -0.08),
    ]

    private func point(_ x: Double, _ y: Double, on letter: Character, in layout: KeyboardLayout) throws -> CGPoint {
        let key = try XCTUnwrap(layout.key(.character(String(letter))))
        return CGPoint(x: key.frame.midX + CGFloat(x) * (key.frame.width + layout.metrics.gap),
                       y: key.frame.midY + CGFloat(y) * (key.frame.height + layout.metrics.rowGap))
    }

    private func calibration(labels n: Int, on letter: Character = "f",
                             layout: KeyboardLayout? = nil) throws -> SpatialTouchCalibration? {
        let layout = layout ?? self.layout
        let model = PersonalTypingModel()
        model.learn(try taps.prefix(n).map { TouchLabel(point: try point($0.0, $0.1, on: letter, in: layout), letter: letter) },
                    layout: layout, source: .keep)
        return PersonalTypingModel(state: model.state).calibration(for: layout)
    }

    private func allTapsKey(labels n: Int) throws -> SpatialTouchCalibration.Key {
        let model = PersonalTypingModel()
        model.learn(try taps.prefix(n).map { TouchLabel(point: try point($0.0, $0.1, on: "f", in: layout), letter: "f") },
                    layout: layout, source: .keep)
        return model.state.layouts[KeyboardLayoutSignature(layout).id]?.allTapsKey("f") ?? SpatialTouchCalibration.prior
    }

    func testGoldenPosteriorsAfterZeroOneThreeAndTenLabels() throws {
        let golden: [(n: Int, offsetX: Double, offsetY: Double, sigmaX: Double, sigmaY: Double, xy: Double,
                      degrees: Double, densities: [Double])] = [
            (0, 0, 0, 0.24944382578492943, 0.24944382578492943, 0, 9,
             [0.9391660061798159, -0.20898547006179147, -5.2645034645146485, -6.984114838402797]),
            (1, 0.06, 0.025, 0.19691368667515222, 0.19261765884778062, 0.000843749999999999, 10,
             [1.3699658740868954, -0.10031348195159229, -7.3649856892432854, -9.018015311104188]),
            (3, 0.1, 0.03, 0.15524174696260024, 0.1488357595920192, -0.0007083333333333373, 12,
             [1.664732640620747, -0.05254880015888741, -10.076750752004395, -11.623312795250929]),
            (10, 0.13545454545454547, 0.021818181818181792, 0.10597057280558865, 0.09863796219461815,
             0.0008746923214696922, 19,
             [1.8536495745018708, -1.0055914422645649, -19.60695145086917, -21.396142835638734]),
        ]
        let probes: [(Double, Double)] = [(0, 0), (0.3, -0.2), (-0.9, 0.6), (0.95, -0.95)]
        for row in golden {
            let key = try allTapsKey(labels: row.n)
            XCTAssertEqual(key.offsetX, row.offsetX, accuracy: 1e-12, "n=\(row.n)")
            XCTAssertEqual(key.offsetY, row.offsetY, accuracy: 1e-12, "n=\(row.n)")
            XCTAssertEqual(key.sigmaX, row.sigmaX, accuracy: 1e-12, "n=\(row.n)")
            XCTAssertEqual(key.sigmaY, row.sigmaY, accuracy: 1e-12, "n=\(row.n)")
            XCTAssertEqual(key.covarianceXY, row.xy, accuracy: 1e-12, "n=\(row.n)")
            XCTAssertEqual(key.degrees, row.degrees, "n=\(row.n)")
            for (probe, expected) in zip(probes, row.densities) {
                XCTAssertEqual(key.logDensity(x: probe.0, y: probe.1), expected, accuracy: 1e-9, "n=\(row.n)")
            }
        }
    }

    func testUntrainedKeysUseThePriorPosterior() throws {
        let prior = SpatialTouchCalibration.prior
        XCTAssertEqual(prior.sigmaX * prior.sigmaX, 2.0 / 9 * 7 * 0.04, accuracy: 1e-15)
        XCTAssertEqual(prior.degrees, 9)
        let x = 0.3, y = -0.2
        let emissions = try XCTUnwrap(KeyboardLetterMap.emissions(for: word("f", at: (x, y)), calibration: nil))
        XCTAssertEqual(emissions.likelihoods[0][index("f")], prior.logDensity(x: x, y: y), accuracy: 1e-12)
    }

    func testSparseAndUnseenKeysTakeThePooledSpread() throws {
        let three = try XCTUnwrap(calibration(labels: 3))
        let unseen = try XCTUnwrap(three.keys["q"])
        let prior = SpatialTouchCalibration.prior
        XCTAssertNotEqual(unseen.sigmaX, prior.sigmaX, "taps on f teach q how steady the typist is")
        XCTAssertLessThan(unseen.sigmaX, prior.sigmaX)
        XCTAssertEqual(unseen.degrees, prior.degrees, "q has no taps of its own")
        XCTAssertLessThan(try XCTUnwrap(three.keys["f"]).sigmaX, unseen.sigmaX)
    }

    func testTheFirstLabelChangesInference() throws {
        let one = try XCTUnwrap(calibration(labels: 1))
        let typed = word("f", at: (0.3, 0.1))
        let cold = try XCTUnwrap(KeyboardLetterMap.emissions(for: typed, calibration: nil))
        let warm = try XCTUnwrap(KeyboardLetterMap.emissions(for: typed, calibration: one))
        XCTAssertNotEqual(cold.literal, warm.literal)
        let g = try XCTUnwrap(layout.key(.character("g")))
        let near = try point(0.3, 0.2, on: "g", in: layout)
        let coldBoundary = try XCTUnwrap(KeyboardBoundaryTouch.letterDensity(near, key: g, layout: layout, calibration: nil))
        let warmBoundary = try XCTUnwrap(KeyboardBoundaryTouch.letterDensity(near, key: g, layout: layout, calibration: one))
        XCTAssertNotEqual(coldBoundary, warmBoundary, "one label on f already changes an unseen key")
    }

    func testAssignmentWordAndBoundaryScoringShareTheDensity() throws {
        let f = try XCTUnwrap(layout.key(.character("f")))
        let g = try XCTUnwrap(layout.key(.character("g")))
        let leftward = SpatialTouchCalibration.Key(offsetX: -0.35, offsetY: 0, sigmaX: 0.15, sigmaY: 0.15, degrees: 12)
        let calibration = SpatialTouchCalibration(keys: ["f": SpatialTouchCalibration.prior, "g": leftward])
        let tap = try point(0.4, 0, on: "f", in: layout)
        let x = Double((tap.x - g.frame.midX) / (g.frame.width + layout.metrics.gap))
        let expected = leftward.logDensity(x: x, y: 0)
        XCTAssertEqual(try XCTUnwrap(KeyboardBoundaryTouch.letterDensity(tap, key: g, layout: layout,
                                                                         calibration: calibration)),
                       expected, accuracy: 1e-12)
        let emissions = try XCTUnwrap(KeyboardLetterMap.emissions(for: word("f", at: (0.4, 0)), calibration: calibration))
        XCTAssertEqual(emissions.likelihoods[0][index("g")], expected, accuracy: 1e-12)
        let uniform = [Double](repeating: 1.0 / 26, count: KeyboardKeyMap.keyLimit)
        let assignment = KeyboardKeyMap(layout: layout, prefix: "", calibration: calibration, priors: uniform)
        XCTAssertEqual(assignment.attributedKey(at: tap, geometric: f, layout: layout, prefix: ""), g,
                       "g's learned leftward aim outweighs f's untrained prior")
        let cold = KeyboardKeyMap(layout: layout, prefix: "", calibration: SpatialTouchCalibration(keys: ["f": SpatialTouchCalibration.prior, "g": SpatialTouchCalibration.prior]),
                                  priors: uniform)
        XCTAssertEqual(cold.attributedKey(at: tap, geometric: f, layout: layout, prefix: ""), f)
    }

    func testDensitiesDoNotDependOnKeyboardSize() throws {
        let wide = KeyboardLayout(width: 786)
        for n in [1, 3, 10] {
            let small = try XCTUnwrap(calibration(labels: n))
            let large = try XCTUnwrap(calibration(labels: n, layout: wide))
            for letter: Character in ["f", "q"] {
                let a = try XCTUnwrap(small.keys[letter]), b = try XCTUnwrap(large.keys[letter])
                XCTAssertEqual(a.offsetX, b.offsetX, accuracy: 1e-9)
                XCTAssertEqual(a.sigmaX, b.sigmaX, accuracy: 1e-9)
                XCTAssertEqual(a.sigmaY, b.sigmaY, accuracy: 1e-9)
                XCTAssertEqual(a.covarianceXY, b.covarianceXY, accuracy: 1e-9)
            }
        }
    }

    func testCorrelatedDensityMatchesItsRotatedDiagonalForm() {
        let angle = Double.pi / 6, c = cos(angle), s = sin(angle)
        let xx = 0.05 * c * c + 0.01 * s * s, yy = 0.05 * s * s + 0.01 * c * c, xy = (0.05 - 0.01) * c * s
        let tilted = SpatialTouchCalibration.Key(offsetX: 0.1, offsetY: -0.1, sigmaX: sqrt(xx), sigmaY: sqrt(yy),
                                                 covarianceXY: xy, degrees: 12)
        let diagonal = SpatialTouchCalibration.Key(offsetX: 0, offsetY: 0, sigmaX: sqrt(0.05), sigmaY: sqrt(0.01),
                                                   degrees: 12)
        for (x, y) in [(0.0, 0.0), (0.4, 0.1), (-0.3, 0.5), (1.2, -0.8)] {
            let dx = x - 0.1, dy = y + 0.1
            XCTAssertEqual(tilted.logDensity(x: x, y: y),
                           diagonal.logDensity(x: c * dx + s * dy, y: -s * dx + c * dy), accuracy: 1e-12)
        }
    }

    func testOutliersKeepHeavierTailsThanAGaussianOfTheSameScale() {
        let key = SpatialTouchCalibration.prior
        let gaussian = { (x: Double) in -0.5 * x * x / (key.sigmaX * key.sigmaX) - log(2 * Double.pi * key.sigmaX * key.sigmaX) }
        XCTAssertEqual(key.logDensity(x: 0, y: 0), gaussian(0), accuracy: 1e-12)
        XCTAssertGreaterThan(key.logDensity(x: 1.2, y: 0), gaussian(1.2) + 3)
    }

    func testMalformedInputStaysFiniteOrIsRejected() throws {
        let calibration = SpatialTouchCalibration(keys: [
            "a": .init(offsetX: 0, offsetY: 0, sigmaX: 0.2, sigmaY: 0.2, degrees: .nan),
            "b": .init(offsetX: 0, offsetY: 0, sigmaX: 0.2, sigmaY: 0.2, degrees: 0.5),
            "d": .init(offsetX: 0, offsetY: 0, sigmaX: 0.2, sigmaY: 0.2, degrees: 1e308),
            "e": .init(offsetX: 0, offsetY: 0, sigmaX: 0.2, sigmaY: 0.2, degrees: 1_000),
            "c": .init(offsetX: 0, offsetY: 0, sigmaX: 1e-9, sigmaY: 1e9, covarianceXY: 5),
        ])
        XCTAssertNil(calibration.keys["a"])
        XCTAssertNil(calibration.keys["b"])
        XCTAssertNil(calibration.keys["d"])
        let e = try XCTUnwrap(calibration.keys["e"])
        XCTAssertTrue(e.logDensityY(0).isFinite)
        XCTAssertTrue(e.logDensity(x: 0, y: 0).isFinite)
        let c = try XCTUnwrap(calibration.keys["c"])
        XCTAssertTrue(c.logDensity(x: 1e6, y: -1e6).isFinite)
        XCTAssertTrue(c.logDensityY(1e6).isFinite)
        let model = PersonalTypingModel()
        let outcome = model.learn([TouchLabel(point: CGPoint(x: CGFloat.nan, y: 100), letter: "f")],
                                  layout: layout, source: .keep)
        XCTAssertEqual(outcome.rejected, [.nonFinite: 1])
        XCTAssertNil(model.calibration(for: layout))
    }

    func testSpaceUsesTheVerticalMarginalOfItsPosterior() throws {
        let space = try XCTUnwrap(layout.key(.space))
        let pitchX = layout.letterWidth + layout.metrics.gap
        let pitchY = space.frame.height + layout.metrics.rowGap
        let width = Double((space.frame.width + 2 * layout.metrics.gap) / pitchX)
        let tap = CGPoint(x: space.frame.midX, y: space.frame.midY + 0.3 * pitchY)
        let prior = SpatialTouchCalibration.prior
        let row = Double((tap.y - space.frame.midY) / pitchY)
        XCTAssertEqual(try XCTUnwrap(KeyboardBoundaryTouch.spaceDensity(tap, layout: layout)),
                       prior.logDensityY(row) - log(width), accuracy: 1e-12)
        var mass = 0.0
        for i in -4000...4000 { mass += exp(prior.logDensityY(Double(i) * 0.001)) * 0.001 }
        XCTAssertEqual(mass, 1, accuracy: 1e-4)
    }

    private func index(_ letter: Character) -> Int {
        SpatialWordLexicon.alphabet.firstIndex(of: letter)!
    }

    private func word(_ letter: Character, at offset: (Double, Double)) -> KeyboardTouchWord {
        let key = layout.key(.character(String(letter)))!
        let point = CGPoint(x: key.frame.midX + CGFloat(offset.0) * (key.frame.width + layout.metrics.gap),
                            y: key.frame.midY + CGFloat(offset.1) * (key.frame.height + layout.metrics.rowGap))
        return KeyboardTouchWord(layout: layout, samples: [.init(text: String(letter), point: point, key: key)])
    }
}
