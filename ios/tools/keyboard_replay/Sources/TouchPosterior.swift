import Foundation
import CoreGraphics

@MainActor
func touchPosteriorReport() throws -> String {
    let taps: [(Double, Double)] = [
        (0.12, 0.05), (0.20, -0.03), (0.08, 0.10), (0.15, 0.0), (0.22, 0.07),
        (0.05, -0.05), (0.18, 0.12), (0.10, 0.02), (0.25, 0.04), (0.14, -0.08),
    ]
    let probes: [(Double, Double)] = [(0, 0), (0.3, -0.2), (-0.9, 0.6), (0.95, -0.95)]

    func point(_ offset: (Double, Double), on key: KeyboardKey, in layout: KeyboardLayout) -> CGPoint {
        CGPoint(x: key.frame.midX + CGFloat(offset.0) * (key.frame.width + layout.metrics.gap),
                y: key.frame.midY + CGFloat(offset.1) * (key.frame.height + layout.metrics.rowGap))
    }
    func describe(_ key: SpatialTouchCalibration.Key) -> [String: Double] {
        ["offsetX": key.offsetX, "offsetY": key.offsetY, "sigmaX": key.sigmaX, "sigmaY": key.sigmaY,
         "covarianceXY": key.covarianceXY, "degrees": key.degrees]
    }
    func layoutCase(width: CGFloat, labels n: Int) -> [String: Any] {
        let layout = KeyboardLayout(width: width)
        let f = layout.key(.character("f"))!, q = layout.key(.character("q"))!
        let model = PersonalTypingModel()
        let labels = taps.prefix(n).map { TouchLabel(point: point($0, on: f, in: layout), letter: "f") }
        model.learn(labels, layout: layout, source: .keep)
        let calibration = PersonalTypingModel(state: model.state).calibration(for: layout)
        func densities(_ key: KeyboardKey) -> [Double?] {
            probes.map { KeyboardBoundaryTouch.letterDensity(point($0, on: key, in: layout), key: key, layout: layout,
                                                             calibration: calibration) }
        }
        return ["n": n,
                "f": describe(calibration?.keys["f"] ?? SpatialTouchCalibration.prior),
                "q": describe(calibration?.keys["q"] ?? SpatialTouchCalibration.prior),
                "fDensity": densities(f) as [Any], "qDensity": densities(q) as [Any]]
    }

    func grip() throws -> [String: Any] {
        let layout = KeyboardLayout(width: 393), other = KeyboardLayout(width: 430)
        func label(_ letter: Character, _ x: Double, _ y: Double, on layout: KeyboardLayout = layout) -> TouchLabel {
            TouchLabel(point: point((x, y), on: layout.key(.character(String(letter)))!, in: layout), letter: letter)
        }
        let letters = "abcdefghijklmnopqrstuvwxyz"
        let model = PersonalTypingModel()
        for i in 0..<40 {
            model.learn(letters.map { label($0, Double(i % 5 - 2) * 0.035, Double(i % 3 - 1) * 0.05) },
                        layout: layout, source: .keep)
        }
        model.learn([label("e", 0, 0, on: other)], layout: other, source: .keep)
        func offsets() -> [String: [Double]] {
            let keys = model.calibration(for: layout)!.keys
            return Dictionary(uniqueKeysWithValues: letters.map { (String($0), [keys[$0]!.offsetX, keys[$0]!.offsetY]) })
        }
        let otherBefore = model.calibration(for: other)
        let before = offsets()
        for _ in 0..<3 { model.learn([label("e", 0.3, 0.15)], layout: layout, source: .keep) }
        let displaced = offsets()
        let aim = model.state.layouts[KeyboardLayoutSignature(layout).id]!.aims!["e"]!
        let reloaded = PersonalTypingModel(state: try JSONDecoder().decode(
            PersonalTypingModel.State.self, from: JSONEncoder().encode(model.state)))
        let next = label("e", 0.25, 0.1)
        model.learn([next], layout: layout, source: .keep)
        reloaded.learn([next], layout: layout, source: .keep)
        let scores = [model, reloaded].map { $0.calibration(for: layout)!.keys["e"]!.logDensity(x: 0.2, y: 0.1) }
        for _ in 0..<4 { model.learn([label("e", 0, 0)], layout: layout, source: .keep) }
        return ["before": before, "displaced": displaced, "recovered": offsets(), "weights": aim.weights,
                "nextScore": scores, "otherLayoutUnchanged": model.calibration(for: other) == otherBefore]
    }

    let malformed = SpatialTouchCalibration(keys: [
        "a": .init(offsetX: 0, offsetY: 0, sigmaX: 0.2, sigmaY: 0.2, degrees: .nan),
        "b": .init(offsetX: 0, offsetY: 0, sigmaX: 1e-9, sigmaY: 1e9, covarianceXY: 5),
    ])
    let b = malformed.keys["b"]
    let report: [String: Any] = [
        "taps": taps.map { [$0.0, $0.1] }, "probes": probes.map { [$0.0, $0.1] },
        "cases": [0, 1, 3, 10].map { layoutCase(width: 393, labels: $0) },
        "scaled": [0, 1, 3, 10].map { layoutCase(width: 786, labels: $0) },
        "grip": try grip(),
        "malformed": ["droppedNaNDegrees": malformed.keys["a"] == nil,
                      "clamped": b.map(describe) as Any,
                      "farDensity": b?.logDensity(x: 1e6, y: -1e6) as Any],
    ]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    return String(decoding: data, as: UTF8.self) + "\n"
}
