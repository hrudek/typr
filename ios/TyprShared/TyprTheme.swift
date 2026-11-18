import SwiftUI

enum TyprTheme {
    // OpenCode dark palette — single cool-neutral temperature, tints via opacity.
    static let bgDeep = Color(red: 0x0A / 255.0, green: 0x0B / 255.0, blue: 0x0D / 255.0)
    static let bgBase = Color(red: 0x11 / 255.0, green: 0x13 / 255.0, blue: 0x16 / 255.0)
    static let layer01 = Color(red: 0x17 / 255.0, green: 0x19 / 255.0, blue: 0x1D / 255.0)
    static let layer02 = Color(red: 0x20 / 255.0, green: 0x23 / 255.0, blue: 0x29 / 255.0)

    static let textBase = Color.white.opacity(0.94)
    static let textMuted = Color.white.opacity(0.56)
    static let textFaint = Color.white.opacity(0.36)

    static let borderWeak = Color.white.opacity(0.06)
    static let borderStrong = Color.white.opacity(0.11)

    static let bgContrast = Color.white.opacity(0.96)
    static let textContrast = Color(red: 0x0A / 255.0, green: 0x0B / 255.0, blue: 0x0D / 255.0)

    static let danger = Color(red: 0xE5 / 255.0, green: 0x4D / 255.0, blue: 0x42 / 255.0)
    static let dangerSurface = Color(red: 0xE5 / 255.0, green: 0x4D / 255.0, blue: 0x42 / 255.0).opacity(0.14)
    static let warmMic = Color(red: 0xFF / 255.0, green: 0x95 / 255.0, blue: 0x00 / 255.0)
    static let success = Color(red: 0x34 / 255.0, green: 0xC7 / 255.0, blue: 0x59 / 255.0)

    static let warmPearl = Color(red: 0.96, green: 0.94, blue: 0.89)
    static let agentBlue = Color(red: 0.78, green: 0.86, blue: 0.97)

    static let cardRadius: CGFloat = 18
    static let controlRadius: CGFloat = 8.5

    static func formatClock(_ seconds: TimeInterval) -> String {
        let clamped = max(0, Int(seconds))
        return String(format: "%d:%02d", clamped / 60, clamped % 60)
    }

    static func formatRemaining(_ seconds: TimeInterval) -> String {
        let clamped = max(0, Int(ceil(seconds)))
        if clamped >= 3600 {
            let mins = (clamped % 3600) / 60
            return mins == 0 ? "\(clamped / 3600)h" : "\(clamped / 3600)h \(mins)m"
        }
        if clamped >= 90 {
            return "\((clamped + 59) / 60)m"
        }
        return formatClock(TimeInterval(clamped))
    }
}

/// Critically damped `(duration, bounce: 0)` springs shared across Typr iPhone surfaces.
enum TyprMotion {
    static let stageDuration: Double = 0.28
    static let settleDuration: Double = 0.30
    static let trayDuration: Double = 0.25
    static let reducedDuration: Double = 0.18

    static let stage = Animation.spring(duration: stageDuration, bounce: 0.0)
    static let settle = Animation.spring(duration: settleDuration, bounce: 0.0)
    static let tray = Animation.spring(duration: trayDuration, bounce: 0.0)
    static let reducedFade = Animation.easeInOut(duration: reducedDuration)

    static func stageAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? reducedFade : stage
    }

    static func settleAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? reducedFade : settle
    }

    static func trayAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? reducedFade : tray
    }
}

/// Keeps a control permanently mounted and drives its visibility continuously via
/// opacity, subtle scale (`>= 0.90`), and soft blur (`<= 4 pt`), so interrupted
/// transitions retarget velocity smoothly and never flash in or out in one frame.
struct TyprControlReveal: ViewModifier {
    var shown: Bool
    var reduceMotion: Bool
    var scale: CGFloat = 0.92
    var blur: CGFloat = 2.5
    var anchor: UnitPoint = .center

    @ViewBuilder
    func body(content: Content) -> some View {
        let base = content
            .opacity(shown ? 1.0 : 0.0)
            .scaleEffect(shown || reduceMotion ? 1.0 : scale, anchor: anchor)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
        if blur > 0 {
            base.blur(radius: (shown || reduceMotion) ? 0.0 : blur)
        } else {
            base
        }
    }
}

/// Keeps a top-bar tray or status item permanently mounted in a `ZStack` and
/// reveals it smoothly without layout jumps.
struct TyprTrayReveal: ViewModifier {
    var shown: Bool
    var reduceMotion: Bool
    var offsetY: CGFloat = 3.5

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1.0 : 0.0)
            .offset(y: (shown || reduceMotion) ? 0.0 : offsetY)
            .blur(radius: (shown || reduceMotion) ? 0.0 : 2.5)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
    }
}

/// Soft recessed capsule well for `DotScopeView` that adapts naturally to both
/// dark and light host platters without opaque black holes or heavy box strokes.
struct TyprRecessedWell: View {
    var isDark: Bool

    var body: some View {
        Capsule()
            .fill(isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.055))
            .overlay(alignment: .top) {
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.black.opacity(isDark ? 0.30 : 0.09),
                                Color.clear,
                                Color.white.opacity(isDark ? 0.065 : 0.50),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.75
                    )
            }
    }
}

extension View {
    func typrControlReveal(
        _ shown: Bool,
        reduceMotion: Bool,
        scale: CGFloat = 0.92,
        blur: CGFloat = 2.5,
        anchor: UnitPoint = .center
    ) -> some View {
        modifier(
            TyprControlReveal(
                shown: shown,
                reduceMotion: reduceMotion,
                scale: scale,
                blur: blur,
                anchor: anchor
            )
        )
    }

    func typrTrayReveal(_ shown: Bool, reduceMotion: Bool, offsetY: CGFloat = 3.5) -> some View {
        modifier(TyprTrayReveal(shown: shown, reduceMotion: reduceMotion, offsetY: offsetY))
    }

    /// Soft horizontal fade mask on scroll strips so chips never crop hard at edges.
    func typrHorizontalEdgeFade(leading: CGFloat = 14, trailing: CGFloat = 18) -> some View {
        mask {
            GeometryReader { geo in
                let w = max(1, geo.size.width)
                let l = min(0.25, max(0, leading / w))
                let r = max(0.75, min(1, 1 - trailing / w))
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: l),
                        .init(color: .black, location: r),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
        }
    }
}

struct TyprStatusDot: View {
    var color: Color
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
    }
}

/// Shared brand mark for the app header, setup and dictation keyboard.
struct TyprMarkView: View {
    var size: CGFloat = 20
    var color: Color = TyprTheme.textBase
    var coreColor: Color? = nil

    var body: some View {
        TyprWordmark()
            .fill(coreColor ?? color)
            .frame(width: size * 2, height: size)
            .accessibilityHidden(true)
    }
}

/// Static brand mark for WidgetKit's archived Live Activity display lists.
struct TyprDotMatrixBadge: View {
    var columns: Int = 21
    var rows: Int = 7
    var pitch: CGFloat = 2.6
    var cooling: Bool = false
    /// Set when the badge is centered in its region (Dynamic Island minimal).
    var opticallyCentered: Bool = false

    var body: some View {
        TyprWordmark(opticallyCentered: opticallyCentered)
            .fill(cooling ? TyprTheme.agentBlue : TyprTheme.warmPearl)
            .frame(
                width: CGFloat(columns - 1) * pitch + 8,
                height: CGFloat(rows - 1) * pitch + 8
            )
            .accessibilityHidden(true)
    }
}
