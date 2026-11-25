import SwiftUI
import UIKit
import XCTest
@testable import HEX

@MainActor
final class TyprReturnKeyAccentTests: XCTestCase {
    override func tearDown() async throws {
        TyprKeycaps.designOverride = nil
    }

    private func rgb(_ color: UIColor) -> [CGFloat] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b]
    }

    private func distance(_ a: UIColor, _ b: UIColor) -> CGFloat {
        let (x, y) = (rgb(a), rgb(b))
        return sqrt((0..<3).reduce(0) { $0 + (x[$1] - y[$1]) * (x[$1] - y[$1]) })
    }

    private func luminance(_ color: UIColor) -> CGFloat {
        let c = rgb(color).map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
    }

    private func contrast(_ a: UIColor, _ b: UIColor) -> CGFloat {
        let (hi, lo) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (hi + 0.05) / (lo + 0.05)
    }

    func testDefaultDesignKeepsTheSolidActionColours() {
        TyprKeycaps.designOverride = false
        for isDark in [false, true] {
            for theme in KeyboardTheme.allCases {
                let palette = FullKeyboardPalette(isDark: isDark, theme: theme)
                let idle = TyprReturnKeyAccent.fill(palette.actionFill, palette.actionPressedFill, isDark: isDark, pressed: false)
                let pressed = TyprReturnKeyAccent.fill(palette.actionFill, palette.actionPressedFill, isDark: isDark, pressed: true)
                XCTAssertEqual(rgb(idle), rgb(palette.actionFill), "\(theme.rawValue) idle")
                XCTAssertEqual(rgb(pressed), rgb(palette.actionPressedFill), "\(theme.rawValue) pressed")
                XCTAssertEqual(rgb(TyprReturnKeyAccent.glyph(isDark: isDark)), [1, 1, 1], "white glyph")
            }
        }
    }

    func testMechanicalDesignTintsTheKeycapInsteadOfFillingWithTheActionColour() {
        TyprKeycaps.designOverride = true
        for isDark in [false, true] {
            let keycap = TyprMechanicalKeycap(isDark: isDark)
            for theme in KeyboardTheme.allCases {
                let palette = FullKeyboardPalette(isDark: isDark, theme: theme)
                let label = "\(theme.rawValue) \(isDark ? "dark" : "light")"
                for pressed in [false, true] {
                    let action = pressed ? palette.actionPressedFill : palette.actionFill
                    let plain = pressed ? keycap.keyPressedFill : keycap.keyFill
                    let face = TyprReturnKeyAccent.fill(palette.actionFill, palette.actionPressedFill, isDark: isDark, pressed: pressed)
                    let toKey = distance(face, plain)
                    // The weakest case is dark Forest pressed (0.059): its action green is itself dark.
                    XCTAssertGreaterThan(toKey, 0.05, "\(label) accent is visible (pressed \(pressed))")
                    XCTAssertLessThan(toKey, distance(face, action), "\(label) is nearer the key than the action colour (pressed \(pressed))")
                    let ratio = contrast(TyprReturnKeyAccent.glyph(isDark: isDark), face)
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(label) glyph \(ratio):1 (pressed \(pressed))")
                }
                let idle = TyprReturnKeyAccent.fill(palette.actionFill, palette.actionPressedFill, isDark: isDark, pressed: false)
                let held = TyprReturnKeyAccent.fill(palette.actionFill, palette.actionPressedFill, isDark: isDark, pressed: true)
                XCTAssertGreaterThan(distance(idle, held), 0.05, "\(label) pressed stays distinguishable")
            }
        }
    }

    func testTheSwiftUIReturnKeyFollowsTheSameRule() {
        let action = Color(red: 0, green: 0x7A / 255.0, blue: 1)
        let pressed = Color(red: 0, green: 0x62 / 255.0, blue: 0xCC / 255.0)
        TyprKeycaps.designOverride = false
        let upstream = rgb(UIColor(TyprReturnKeyAccent.fills(action, pressed, isDark: true).idle))
        for (got, want) in zip(upstream, rgb(UIColor(action))) {
            XCTAssertEqual(got, want, accuracy: 1e-4)
        }
        TyprKeycaps.designOverride = true
        let accented = UIColor(TyprReturnKeyAccent.fills(action, pressed, isDark: true).idle)
        XCTAssertLessThan(distance(accented, TyprMechanicalKeycap(isDark: true).keyFill), distance(accented, UIColor(action)))
    }
}
