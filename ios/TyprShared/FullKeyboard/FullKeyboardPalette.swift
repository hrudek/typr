import SwiftUI
import UIKit

/// The full keyboard's colours. Light is calibrated against Apple's iOS 26 Liquid
/// Glass system keyboard; dark matches the owner's 2026-11-11 reference keyboard
/// (opaque `#2D2D2D` keycaps on a `#171717` platter). Dark is chosen by the
/// field's `keyboardAppearance` first, then the host's interface style.
struct FullKeyboardPalette: Equatable {
    let isDark: Bool
    var design = KeyboardDesign.standard

    static func isDark(appearance: UIKeyboardAppearance?, traits: UITraitCollection) -> Bool {
        switch appearance {
        case .dark?:
            return true
        case .light?:
            return false
        default:
            return traits.userInterfaceStyle == .dark
        }
    }

    private static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// Stand-in for the system Liquid Glass platter, used only in standalone snapshot scenes.
    var backdrop: UIColor { isDark ? Self.rgb(0x171717) : Self.rgb(0xDFE1E6) }

    var textBase: UIColor { isDark ? .white : .black }
    var textMuted: UIColor { isDark ? UIColor(white: 1, alpha: 0.56) : Self.rgb(0x525763) }

    /// One keycap fill across letters and modifiers. Dark is opaque so the keys
    /// keep the reference colour regardless of the platter behind them.
    var keyFill: UIColor { isDark ? Self.rgb(0x2D2D2D) : .white }
    var keyPressedFill: UIColor { isDark ? Self.rgb(0x474747) : Self.rgb(0xD8DCE4) }
    /// Secondary fill for non-key chips and the recording panel's cancel pill.
    var functionFill: UIColor { isDark ? UIColor(white: 1, alpha: 0.07) : UIColor(white: 0, alpha: 0.065) }
    var keyShadow: UIColor { .clear }

    /// The joined space/Typr outline and seam (`#767676` in the dark reference).
    var joinedOutline: UIColor { isDark ? Self.rgb(0x767676) : UIColor(white: 0, alpha: 0.24) }

    /// Opaque so balloons and menus float cleanly over the strip and neighbouring keys.
    var popupFill: UIColor { isDark ? Self.rgb(0x3A3A3A) : .white }
    var popupBorder: UIColor { isDark ? UIColor(white: 1, alpha: 0.14) : UIColor(white: 0, alpha: 0.08) }
    var popupShadow: UIColor { UIColor(white: 0, alpha: isDark ? 0.5 : 0.18) }

    var chipFill: UIColor { isDark ? UIColor(white: 1, alpha: 0.09) : UIColor(white: 0, alpha: 0.065) }
    var wellFill: UIColor { isDark ? UIColor(white: 1, alpha: 0.045) : UIColor(white: 0, alpha: 0.045) }
    var separator: UIColor { isDark ? UIColor(white: 1, alpha: 0.12) : UIColor(white: 0, alpha: 0.10) }
    var selectFill: UIColor { isDark ? UIColor(white: 1, alpha: 0.15) : UIColor(white: 0, alpha: 0.075) }
    var selectText: UIColor { textBase }

    /// Apple system keyboard action blue (`#007AFF`).
    var actionFill: UIColor { Self.rgb(0x007AFF) }
    var actionPressedFill: UIColor { Self.rgb(0x0062CC) }
    var warmCore: UIColor { Self.rgb(0xFF9500) }
    var recordingDot: UIColor { Self.rgb(0xE54D42) }

    static let cornerRadius: CGFloat = 8.5
}

/// The outlined Typr wordmark on the Typr key, sized and placed like the
/// owner's 2026-11-11 reference: about 64 % of the key width, a little left of
/// centre and slightly low, leaving the top-right corner for the ↗ hint.
enum TyprMarkPath {
    /// The wordmark's own width-to-height ratio (`TyprWordmark` bounds).
    static let aspect: CGFloat = 1359.72 / 573

    /// The tight wordmark bounds inside the Typr keycap.
    static func frame(in cap: CGRect) -> CGRect {
        let width = min(cap.width * 0.64, cap.height * 0.66)
        let height = width / aspect
        let center = CGPoint(x: cap.minX + cap.width * 0.43, y: cap.minY + cap.height * 0.54)
        return CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }

    static func draw(in context: CGContext, rect: CGRect, color: UIColor, coreColor: UIColor?) {
        context.saveGState()
        context.setFillColor((coreColor ?? color).cgColor)
        context.addPath(TyprWordmark().path(in: rect).cgPath)
        context.fillPath()
        context.restoreGState()
    }

    /// The thin ↗ "opens Typr" hint in the keycap's top-right corner.
    static func arrowFrame(in cap: CGRect) -> CGRect {
        let size = min(5.8, cap.height * 0.14)
        return CGRect(x: cap.maxX - 6.4 - size, y: cap.minY + cap.height * 0.16, width: size, height: size)
    }

    static func drawArrow(in context: CGContext, rect: CGRect, color: UIColor) {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.move(to: CGPoint(x: rect.maxX - rect.width * 0.62, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.62))
        path.lineWidth = 1.2
        path.lineCapStyle = .square
        path.lineJoinStyle = .miter
        context.saveGState()
        color.setStroke()
        path.stroke()
        context.restoreGState()
    }
}

/// Drawing-only geometry. Never used for hit testing or gesture thresholds.
struct JoinedSpaceKeycap {
    let space: CGRect
    let typr: CGRect
    let radius: CGFloat

    /// Outline and seam width: 2 px at 3x, as in the reference.
    static let lineWidth: CGFloat = 2.0 / 3.0

    init?(layout: KeyboardLayout) {
        guard let space = layout.key(.space), let typr = layout.key(.typr),
              abs(typr.frame.minX - space.frame.maxX - layout.metrics.gap) < 0.01 else { return nil }
        self.space = space.frame
        self.typr = typr.frame
        radius = layout.metrics.cornerRadius
    }

    var frame: CGRect { space.union(typr) }

    /// The reference's sloping S-shaped seam, as fractions of the key height
    /// from the Typr keycap's left edge: it leaves the top edge just inside the
    /// Typr key, rounds into a straight slant and rounds out into the bottom
    /// edge well inside the space bar. Entirely decorative: the touch boundary
    /// stays the straight edge between the original key frames.
    static func seamPoints(cap: CGRect) -> (top: CGPoint, slantTop: CGPoint, slantBottom: CGPoint, bottom: CGPoint) {
        let h = cap.height
        return (
            CGPoint(x: cap.minX + 0.05 * h, y: cap.minY),
            CGPoint(x: cap.minX - 0.165 * h, y: cap.minY + 0.15 * h),
            CGPoint(x: cap.minX - 0.32 * h, y: cap.minY + 0.83 * h),
            CGPoint(x: cap.minX - 0.545 * h, y: cap.maxY)
        )
    }

    static func seam(cap: CGRect, radius: CGFloat) -> UIBezierPath {
        let p = seamPoints(cap: cap)
        let dx = p.slantBottom.x - p.slantTop.x
        let dy = p.slantBottom.y - p.slantTop.y
        // Where the straight slant, extended, meets the top and bottom edges.
        let topCorner = CGPoint(x: p.slantTop.x - dx * (p.slantTop.y - cap.minY) / dy, y: cap.minY)
        let bottomCorner = CGPoint(x: p.slantBottom.x + dx * (cap.maxY - p.slantBottom.y) / dy, y: cap.maxY)
        func toward(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat = 0.6) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        let path = UIBezierPath()
        path.move(to: p.top)
        path.addCurve(to: p.slantTop, controlPoint1: toward(p.top, topCorner, 0.72), controlPoint2: toward(p.slantTop, topCorner, 0.72))
        path.addLine(to: p.slantBottom)
        path.addCurve(to: p.bottom, controlPoint1: toward(p.slantBottom, bottomCorner), controlPoint2: toward(p.bottom, bottomCorner))
        return path
    }

    static func typrRegion(cap: CGRect, radius: CGFloat) -> UIBezierPath {
        let path = seam(cap: cap, radius: radius)
        path.addLine(to: CGPoint(x: cap.maxX - radius, y: cap.maxY))
        path.addQuadCurve(to: CGPoint(x: cap.maxX, y: cap.maxY - radius),
                          controlPoint: CGPoint(x: cap.maxX, y: cap.maxY))
        path.addLine(to: CGPoint(x: cap.maxX, y: cap.minY + radius))
        path.addQuadCurve(to: CGPoint(x: cap.maxX - radius, y: cap.minY),
                          controlPoint: CGPoint(x: cap.maxX, y: cap.minY))
        path.close()
        return path
    }

    func draw(in context: CGContext, palette: FullKeyboardPalette, spacePressed: Bool, typrPressed: Bool) {
        if palette.design == .mechanical {
            drawMechanical(in: context, palette: palette, spacePressed: spacePressed, typrPressed: typrPressed)
            return
        }
        let line = Self.lineWidth
        let outline = UIBezierPath(roundedRect: frame.insetBy(dx: line / 2, dy: line / 2), cornerRadius: radius)
        context.saveGState()
        UIBezierPath(roundedRect: frame, cornerRadius: radius).addClip()
        context.setFillColor((spacePressed ? palette.keyPressedFill : palette.keyFill).cgColor)
        context.fill(frame)
        if spacePressed || typrPressed {
            // Keep the two pressed fills separate without stacking translucent
            // colours over the shared background.
            context.saveGState()
            Self.typrRegion(cap: typr, radius: radius).addClip()
            context.clear(frame)
            context.setFillColor((typrPressed ? palette.keyPressedFill : palette.keyFill).cgColor)
            context.fill(frame)
            context.restoreGState()
        }
        context.restoreGState()
        palette.joinedOutline.setStroke()
        outline.lineWidth = line
        outline.stroke()
        let seam = Self.seam(cap: typr.insetBy(dx: 0, dy: line / 2), radius: radius)
        seam.lineWidth = line
        seam.stroke()
    }
}

extension JoinedSpaceKeycap {
    fileprivate func drawMechanical(in context: CGContext, palette: FullKeyboardPalette, spacePressed: Bool, typrPressed: Bool) {
        let mechanical = MechanicalKeycap(isDark: palette.isDark)
        let spaceFace = spacePressed ? palette.keyPressedFill : palette.keyFill
        let typrFace = typrPressed ? palette.keyPressedFill : palette.keyFill
        mechanical.drawCap(in: context, rect: frame, radius: radius)
        let face = mechanical.faceRect(frame)
        let faceRadius = mechanical.faceRadius(radius)
        context.saveGState()
        UIBezierPath(roundedRect: face, cornerRadius: faceRadius).addClip()
        mechanical.fillFace(in: context, rect: face, color: spaceFace)
        Self.typrRegion(cap: typr, radius: radius).addClip()
        mechanical.fillFace(in: context, rect: face, color: typrFace)
        context.restoreGState()
        context.saveGState()
        UIBezierPath(roundedRect: frame, cornerRadius: radius).addClip()
        let seam = Self.seam(cap: typr, radius: radius)
        seam.lineWidth = MechanicalKeycap.seamWidth
        mechanical.rim.setStroke()
        seam.stroke()
        context.restoreGState()
    }
}

struct MechanicalKeycap {
    let isDark: Bool

    static let seamWidth: CGFloat = 3.5

    var rim: UIColor { isDark ? UIColor(white: 0.07, alpha: 1) : UIColor(white: 0.74, alpha: 1) }

    func faceRect(_ cap: CGRect) -> CGRect {
        CGRect(x: cap.minX + 3, y: cap.minY + 2.5, width: cap.width - 6, height: cap.height - 7)
    }

    func faceRadius(_ radius: CGFloat) -> CGFloat { max(2, radius - 2.5) }

    func inkFrame(_ cap: CGRect) -> CGRect { cap.offsetBy(dx: 0, dy: -1) }

    func drawCap(in context: CGContext, rect: CGRect, radius: CGFloat) {
        let path = UIBezierPath(roundedRect: rect, cornerRadius: radius).cgPath
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 1), blur: 2.5, color: UIColor(white: 0, alpha: isDark ? 0.55 : 0.22).cgColor)
        context.addPath(path)
        context.setFillColor(rim.cgColor)
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(path)
        context.clip()
        let top = UIColor(white: isDark ? 0.17 : 0.88, alpha: 1)
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [top.cgColor, rim.cgColor] as CFArray,
            locations: [0, 0.45]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.midX, y: rect.minY),
                end: CGPoint(x: rect.midX, y: rect.maxY),
                options: []
            )
        }
        context.restoreGState()
    }

    func fillFace(in context: CGContext, rect: CGRect, color: UIColor) {
        context.setFillColor(color.cgColor)
        context.fill(rect)
        context.saveGState()
        context.clip(to: rect)
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [UIColor(white: 1, alpha: isDark ? 0.07 : 0.5).cgColor, UIColor(white: 1, alpha: 0).cgColor] as CFArray,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.midX, y: rect.minY),
                end: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.5),
                options: []
            )
        }
        context.restoreGState()
    }

    func draw(in context: CGContext, rect: CGRect, face color: UIColor, radius: CGFloat) {
        drawCap(in: context, rect: rect, radius: radius)
        let face = faceRect(rect)
        context.saveGState()
        UIBezierPath(roundedRect: face, cornerRadius: faceRadius(radius)).addClip()
        fillFace(in: context, rect: face, color: color)
        context.restoreGState()
    }
}

extension CGContext {
    func fillKeycap(_ rect: CGRect, palette: FullKeyboardPalette, fill: UIColor, radius: CGFloat = FullKeyboardPalette.cornerRadius) {
        switch palette.design {
        case .standard:
            fillKeycap(rect, fill: fill, radius: radius)
        case .mechanical:
            MechanicalKeycap(isDark: palette.isDark).draw(in: self, rect: rect, face: fill, radius: radius)
        }
    }

    /// Draws a continuous-corner iOS 26 Liquid Glass keycap with no legacy under-shadow.
    func fillKeycap(_ rect: CGRect, fill: UIColor, shadow: UIColor = .clear, radius: CGFloat = FullKeyboardPalette.cornerRadius) {
        let path = UIBezierPath(roundedRect: rect, cornerRadius: radius).cgPath
        saveGState()
        if shadow != .clear {
            setShadow(offset: CGSize(width: 0, height: 1), blur: 0.5, color: shadow.cgColor)
        }
        addPath(path)
        setFillColor(fill.cgColor)
        fillPath()
        restoreGState()
    }
}
