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

    let malformed = SpatialTouchCalibration(keys: [
        "a": .init(offsetX: 0, offsetY: 0, sigmaX: 0.2, sigmaY: 0.2, degrees: .nan),
        "b": .init(offsetX: 0, offsetY: 0, sigmaX: 1e-9, sigmaY: 1e9, covarianceXY: 5),
    ])
    let b = malformed.keys["b"]
    let report: [String: Any] = [
        "taps": taps.map { [$0.0, $0.1] }, "probes": probes.map { [$0.0, $0.1] },
        "cases": [0, 1, 3, 10].map { layoutCase(width: 393, labels: $0) },
        "scaled": [0, 1, 3, 10].map { layoutCase(width: 786, labels: $0) },
        "malformed": ["droppedNaNDegrees": malformed.keys["a"] == nil,
                      "clamped": b.map(describe) as Any,
                      "farDensity": b?.logDensity(x: 1e6, y: -1e6) as Any],
    ]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    return String(decoding: data, as: UTF8.self) + "\n"
}
