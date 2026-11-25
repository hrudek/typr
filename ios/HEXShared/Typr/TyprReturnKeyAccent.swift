import SwiftUI
import UIKit

/// The Mechanical design's Go, Search and Send return key: the keycap's own face with a light
/// tint of the theme's action colour, not the action colour's solid block. The Default design
/// keeps upstream's colours.
enum TyprReturnKeyAccent {
    /// How far the face moves from the keycap's grey toward the action colour.
    private static let strength: CGFloat = 0.25

    /// The glyph on an accented face: the plain label (`TyprMechanicalKeycap.keyLabel`) is
    /// under 4.5:1 there, so the return key's is a step stronger.
    private static func ink(isDark: Bool) -> UIColor {
        isDark ? UIColor(red: 0xD0 / 255.0, green: 0xD0 / 255.0, blue: 0xD0 / 255.0, alpha: 1)
            : UIColor(red: 0x3A / 255.0, green: 0x3D / 255.0, blue: 0x44 / 255.0, alpha: 1)
    }

    private static func face(isDark: Bool, action: UIColor, pressed: Bool) -> UIColor {
        let keycap = TyprMechanicalKeycap(isDark: isDark)
        return mix(pressed ? keycap.keyPressedFill : keycap.keyFill, action, strength)
    }

    private static func mix(_ base: UIColor, _ tint: UIColor, _ amount: CGFloat) -> UIColor {
        var b = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), a: CGFloat(0))
        var t = b
        base.getRed(&b.r, green: &b.g, blue: &b.b, alpha: &b.a)
        tint.getRed(&t.r, green: &t.g, blue: &t.b, alpha: &t.a)
        return UIColor(
            red: b.r + (t.r - b.r) * amount,
            green: b.g + (t.g - b.g) * amount,
            blue: b.b + (t.b - b.b) * amount,
            alpha: 1
        )
    }

    /// The return key's face when its action is on: upstream's `action` or `actionPressed`
    /// unless the design is Mechanical.
    static func fill(_ action: UIColor, _ actionPressed: UIColor, isDark: Bool, pressed: Bool) -> UIColor {
        guard TyprKeycaps.isMechanical else { return pressed ? actionPressed : action }
        return face(isDark: isDark, action: pressed ? actionPressed : action, pressed: pressed)
    }

    static func fills(_ action: Color, _ actionPressed: Color, isDark: Bool) -> (idle: Color, pressed: Color) {
        (
            Color(fill(UIColor(action), UIColor(actionPressed), isDark: isDark, pressed: false)),
            Color(fill(UIColor(action), UIColor(actionPressed), isDark: isDark, pressed: true))
        )
    }

    /// The glyph on that face: white unless the design is Mechanical.
    static func glyph(isDark: Bool) -> UIColor {
        TyprKeycaps.isMechanical ? ink(isDark: isDark) : .white
    }
}
