import SwiftUI
import UIKit

/// Typr's mechanical keycap: a dark base ring with a raised, lighter face and a thin top
/// highlight (from typr-deprecated's `MechanicalKeycap`).
struct TyprMechanicalKeycap {
    let isDark: Bool

    private static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    var keyFill: UIColor { isDark ? Self.rgb(0x262626) : Self.rgb(0xE9EAEE) }
    var keyPressedFill: UIColor { isDark ? Self.rgb(0x3A3A3A) : Self.rgb(0xD3D6DC) }
    var keyLabel: UIColor { isDark ? Self.rgb(0x929292) : Self.rgb(0x6A6D74) }

    static let highlightWidth: CGFloat = 0.5

    private var seamFill: UIColor { UIColor(white: isDark ? 0.05 : 0.7, alpha: 1) }

    private var baseStops: [(CGFloat, UIColor)] {
        let stops: [(CGFloat, CGFloat)] = isDark
            ? [(0, 0.18), (0.06, 0.165), (0.15, 0.085), (0.6, 0.08), (0.92, 0.06), (1, 0.035)]
            : [(0, 0.97), (0.06, 0.93), (0.15, 0.8), (0.6, 0.78), (0.92, 0.72), (1, 0.66)]
        return stops.map { ($0.0, UIColor(white: $0.1, alpha: 1)) }
    }

    private var faceStops: [(CGFloat, UIColor)] {
        let stops: [(CGFloat, CGFloat)] = isDark
            ? [(0, 0.12), (0.25, 0.055), (0.5, 0.02), (0.62, 0), (0.82, 0), (1, 0.08)]
            : [(0, 0.75), (0.3, 0.35), (0.6, 0), (0.85, 0), (1, 0.25)]
        return stops.map { ($0.0, UIColor(white: 1, alpha: $0.1)) }
    }

    private var highlight: UIColor { UIColor(white: 1, alpha: isDark ? 0.28 : 1) }
    private var shadow: UIColor { UIColor(white: 0, alpha: isDark ? 0.6 : 0.22) }

    /// The raised face inside a keycap; labels sit on it.
    func faceRect(_ cap: CGRect) -> CGRect {
        let side = cap.height * 0.062
        let top = cap.height * 0.062
        let bottom = cap.height * 0.105
        return CGRect(x: cap.minX + side, y: cap.minY + top, width: cap.width - 2 * side, height: cap.height - top - bottom)
    }

    func faceRadius(_ radius: CGFloat) -> CGFloat { max(2, radius - 2) }

    private func drawGradient(in context: CGContext, rect: CGRect, stops: [(CGFloat, UIColor)]) {
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: stops.map { $0.1.cgColor } as CFArray,
            locations: stops.map { $0.0 }
        ) else { return }
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.midX, y: rect.minY),
            end: CGPoint(x: rect.midX, y: rect.maxY),
            options: []
        )
    }

    private func drawBase(in context: CGContext, path: UIBezierPath, rect: CGRect) {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 4, color: shadow.cgColor)
        context.addPath(path.cgPath)
        context.setFillColor(seamFill.cgColor)
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(path.cgPath)
        context.clip()
        drawGradient(in: context, rect: rect, stops: baseStops)
        context.restoreGState()
    }

    private func drawFace(in context: CGContext, path: UIBezierPath, rect: CGRect, color: UIColor) {
        context.saveGState()
        context.addPath(path.cgPath)
        context.clip()
        context.setFillColor(highlight.cgColor)
        context.fill(rect)
        let lowered = UIBezierPath(cgPath: path.cgPath)
        lowered.apply(CGAffineTransform(translationX: 0, y: Self.highlightWidth))
        context.addPath(lowered.cgPath)
        context.clip()
        context.setFillColor(color.cgColor)
        context.fill(rect)
        drawGradient(in: context, rect: rect, stops: faceStops)
        context.restoreGState()
    }

    func draw(in context: CGContext, rect: CGRect, face color: UIColor, radius: CGFloat) {
        drawBase(in: context, path: UIBezierPath(roundedRect: rect, cornerRadius: radius), rect: rect)
        let face = faceRect(rect)
        drawFace(in: context, path: UIBezierPath(roundedRect: face, cornerRadius: faceRadius(radius)), rect: face, color: color)
    }
}

/// Which keycaps the full keyboard draws. The key plane and the Hex key open a scope while
/// they draw (`begin`/`end`); inside it, with Mechanical keyboard design on, the upstream
/// `fillKeycap` and `textBase` hand over to Typr's keycap and ink. Off, or outside a scope,
/// nothing changes.
enum TyprKeycaps {
    private struct Scope {
        let keycap: TyprMechanicalKeycap
        let keyFill: UIColor
        let heldFills: [UIColor]
    }

    nonisolated(unsafe) private static var scope: Scope?

    /// Tests pick the design; nil reads Settings › Typr.
    nonisolated(unsafe) static var designOverride: Bool?

    static var isMechanical: Bool { designOverride ?? TyprSettings.shared.mechanicalKeyboard }

    /// Starts drawing keycaps for `palette`; nil (a Hex key in the strip) draws upstream's.
    static func begin(_ palette: FullKeyboardPalette?) {
        guard let palette, isMechanical else {
            scope = nil
            return
        }
        scope = Scope(
            keycap: TyprMechanicalKeycap(isDark: palette.isDark),
            keyFill: palette.keyFill,
            heldFills: [palette.keyPressedFill, palette.keyHeldFill, palette.functionHeldFill, palette.spaceHeldFill]
        )
    }

    static func end() { scope = nil }

    /// The label colour inside a mechanical scope.
    static var ink: UIColor? { scope?.keycap.keyLabel }

    /// Where a key's label sits: on the raised face inside a mechanical scope.
    static func inkFrame(_ cap: CGRect) -> CGRect { scope?.keycap.faceRect(cap) ?? cap }

    /// Draws a mechanical keycap and says so, or leaves it to the caller.
    static func fillKeycap(_ context: CGContext, _ rect: CGRect, fill: UIColor, radius: CGFloat) -> Bool {
        guard let scope else { return false }
        scope.keycap.draw(in: context, rect: rect, face: face(for: fill, in: scope), radius: radius)
        return true
    }

    /// The resting fill becomes Typr's face, every held grey its pressed face; any other fill
    /// (the return key's blue) keeps its colour.
    private static func face(for fill: UIColor, in scope: Scope) -> UIColor {
        if fill.isEqual(scope.keyFill) { return scope.keycap.keyFill }
        if scope.heldFills.contains(where: { fill.isEqual($0) }) { return scope.keycap.keyPressedFill }
        return fill
    }
}

extension View {
    /// The dictation bar's keys with Mechanical keyboard design on: a mechanical keycap over
    /// the flat fill that follows. `face` overrides the face colour (the return key's blue).
    func typrMechanicalKeycap(isDark: Bool, pressed: Bool, face: Color? = nil) -> some View {
        modifier(TyprMechanicalKeycapBackground(isDark: isDark, pressed: pressed, face: face))
    }
}

private struct TyprMechanicalKeycapBackground: ViewModifier {
    let isDark: Bool
    let pressed: Bool
    let face: Color?

    /// Room around the keycap for its shadow.
    private static let bleed: CGFloat = 6

    @ViewBuilder
    func body(content: Content) -> some View {
        if TyprKeycaps.isMechanical {
            let keycap = TyprMechanicalKeycap(isDark: isDark)
            let color = face.map { UIColor($0) } ?? (pressed ? keycap.keyPressedFill : keycap.keyFill)
            content.background {
                Canvas { context, size in
                    context.withCGContext { cg in
                        let rect = CGRect(origin: .zero, size: size).insetBy(dx: Self.bleed, dy: Self.bleed)
                        keycap.draw(in: cg, rect: rect, face: color, radius: HexTheme.controlRadius)
                    }
                }
                .padding(-Self.bleed)
                .allowsHitTesting(false)
            }
        } else {
            content
        }
    }
}
