import SwiftUI
import UIKit
import XCTest
@testable import HEX

@MainActor
final class TyprMechanicalKeyboardTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "TyprMechanicalKeyboardTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        TyprKeycaps.designOverride = nil
        TyprKeycaps.end()
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testMechanicalDesignDefaultsOnAndPersists() {
        let settings = TyprSettings(defaults: defaults)
        XCTAssertTrue(settings.mechanicalKeyboard, "on while nothing is stored")
        XCTAssertNil(defaults.object(forKey: TyprSettings.mechanicalKeyboardKey))

        settings.mechanicalKeyboard = false
        XCTAssertFalse(TyprSettings(defaults: defaults).mechanicalKeyboard)
        XCTAssertEqual(defaults.object(forKey: TyprSettings.mechanicalKeyboardKey) as? Bool, false)

        settings.mechanicalKeyboard = true
        XCTAssertTrue(TyprSettings(defaults: defaults).mechanicalKeyboard)
        XCTAssertTrue(TyprSettings(defaults: nil).mechanicalKeyboard, "without the App Group")
    }

    func testOffLeavesUpstreamInkAndLabelsAlone() {
        TyprKeycaps.designOverride = false
        for isDark in [false, true] {
            let palette = FullKeyboardPalette(isDark: isDark)
            let upstreamInk = palette.textBase
            TyprKeycaps.begin(palette)
            XCTAssertNil(TyprKeycaps.ink)
            XCTAssertTrue(palette.textBase.isEqual(upstreamInk))
            let cap = CGRect(x: 4, y: 6, width: 33, height: 45)
            XCTAssertEqual(TyprKeycaps.inkFrame(cap), cap)
            TyprKeycaps.end()
        }
    }

    func testOnTakesTyprsColoursOnlyInsideTheScope() {
        TyprKeycaps.designOverride = true
        for isDark in [false, true] {
            let palette = FullKeyboardPalette(isDark: isDark)
            let upstreamInk = palette.textBase
            let keycap = TyprMechanicalKeycap(isDark: isDark)
            TyprKeycaps.begin(palette)
            XCTAssertTrue(palette.textBase.isEqual(keycap.keyLabel))
            let cap = CGRect(x: 4, y: 6, width: 33, height: 45)
            XCTAssertEqual(TyprKeycaps.inkFrame(cap), keycap.faceRect(cap))
            TyprKeycaps.end()
            XCTAssertTrue(palette.textBase.isEqual(upstreamInk), "outside the scope, upstream's ink")

            TyprKeycaps.begin(nil)
            XCTAssertNil(TyprKeycaps.ink, "a Hex key in the strip keeps upstream's look")
            TyprKeycaps.end()
        }
    }

    func testOffDrawsUpstreamKeycapPixelForPixel() {
        let palette = FullKeyboardPalette(isDark: true)
        let upstream = render { $0.fillKeycap(CGRect(x: 8, y: 8, width: 33, height: 45), fill: palette.keyFill, shadow: palette.keyShadow) }

        TyprKeycaps.designOverride = false
        let off = render { context in
            TyprKeycaps.begin(palette)
            context.fillKeycap(CGRect(x: 8, y: 8, width: 33, height: 45), fill: palette.keyFill, shadow: palette.keyShadow)
            TyprKeycaps.end()
        }
        XCTAssertEqual(off, upstream)

        TyprKeycaps.designOverride = true
        let on = render { context in
            TyprKeycaps.begin(palette)
            context.fillKeycap(CGRect(x: 8, y: 8, width: 33, height: 45), fill: palette.keyFill, shadow: palette.keyShadow)
            TyprKeycaps.end()
        }
        XCTAssertNotEqual(on, upstream)
    }

    func testTheKeyPlaneFollowsTheDesign() {
        let view = FullKeyboardView(model: KeyboardViewModel(), target: FixtureTextTarget())
        view.appearanceOverride = true
        view.frame = CGRect(x: 0, y: 0, width: 393, height: view.preferredHeight)
        view.layoutIfNeeded()
        let frames = view.engine.layout.keys.map(\.frame)

        TyprKeycaps.designOverride = false
        let off = render(view.plane)
        TyprKeycaps.designOverride = true
        let on = render(view.plane)
        XCTAssertNotEqual(on, off)
        XCTAssertEqual(view.engine.layout.keys.map(\.frame), frames, "same key geometry")
        TyprKeycaps.designOverride = false
        XCTAssertEqual(render(view.plane), off)
    }

    func testKeyTextTakesTheKeycapInkOnlyWhenOn() {
        for theme in KeyboardTheme.allCases {
            for isDark in [false, true] {
                let palette = FullKeyboardPalette(isDark: isDark, theme: theme)
                let upstream: UIColor = palette.keysAreDark ? .white : .black
                TyprKeycaps.designOverride = false
                TyprKeycaps.begin(palette)
                XCTAssertTrue(palette.keyText.isEqual(upstream), "\(theme)")
                TyprKeycaps.end()

                TyprKeycaps.designOverride = true
                TyprKeycaps.begin(palette)
                XCTAssertTrue(palette.keyText.isEqual(TyprMechanicalKeycap(isDark: isDark).keyLabel), "\(theme)")
                TyprKeycaps.end()
                XCTAssertTrue(palette.keyText.isEqual(upstream), "\(theme)")
            }
        }
    }

    func testPressedNumberPadKeysTakeThePressedKeycap() {
        TyprKeycaps.designOverride = true
        let rect = CGRect(x: 8, y: 8, width: 33, height: 45)
        for theme in [KeyboardTheme.automatic, .navy] {
            for isDark in [false, true] {
                let palette = FullKeyboardPalette(isDark: isDark, theme: theme)
                let keycap = TyprMechanicalKeycap(isDark: isDark)
                let pressed = render { keycap.draw(in: $0, rect: rect, face: keycap.keyPressedFill, radius: 8) }
                for fill in [palette.keyHeldFill, palette.systemHeldFill] {
                    let drawn = render { context in
                        TyprKeycaps.begin(palette)
                        context.fillKeycap(rect, fill: fill, radius: 8)
                        TyprKeycaps.end()
                    }
                    XCTAssertEqual(drawn, pressed, "\(theme), dark: \(isDark), \(fill)")
                }
            }
        }
    }

    func testNumberPadLabelsSitOnTheKeycapFace() throws {
        let target = FixtureTextTarget()
        target.keyboardType = .numberPad
        let view = FullKeyboardView(model: KeyboardViewModel(), target: target)
        view.appearanceOverride = true
        view.engine.configureForField()
        view.frame = CGRect(x: 0, y: 0, width: 393, height: view.preferredHeight)
        view.layoutIfNeeded()
        XCTAssertTrue(view.engine.layout.isNumberPad)
        let five = try XCTUnwrap(view.engine.layout.key(.character("5")))

        TyprKeycaps.designOverride = false
        let off = render(view.plane)
        let offInk = try inkBounds(view.plane, in: five.frame)
        TyprKeycaps.designOverride = true
        let onInk = try inkBounds(view.plane, in: five.frame)
        let face = TyprMechanicalKeycap(isDark: true).faceRect(five.frame)
        XCTAssertTrue(face.insetBy(dx: -1, dy: -1).contains(onInk), "\(onInk) on \(face)")
        XCTAssertLessThan(onInk.maxY, offInk.maxY - 1, "the letters rise onto the face")
        TyprKeycaps.designOverride = false
        XCTAssertEqual(render(view.plane), off)
    }

    private func inkBounds(_ view: UIView, in rect: CGRect) throws -> CGRect {
        let scale: CGFloat = 2
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.preferredRange = .standard
        let image = try XCTUnwrap(
            UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in view.draw(view.bounds) }.cgImage
        )
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn)
        var ink = CGRect.null
        for y in max(0, Int(rect.minY * scale))..<min(height, Int(rect.maxY * scale)) {
            for x in max(0, Int(rect.minX * scale))..<min(width, Int(rect.maxX * scale)) where bytes[(y * width + x) * 4] >= 128 {
                ink = ink.union(CGRect(x: CGFloat(x) / scale, y: CGFloat(y) / scale, width: 1 / scale, height: 1 / scale))
            }
        }
        XCTAssertFalse(ink.isNull, "no ink in \(rect)")
        return ink
    }

    private func render(_ draw: (CGContext) -> Void) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: CGSize(width: 60, height: 70), format: format)
            .image { draw($0.cgContext) }
            .pngData()
    }

    private func render(_ view: UIView) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(bounds: view.bounds, format: format)
            .image { _ in view.draw(view.bounds) }
            .pngData()
    }
}
