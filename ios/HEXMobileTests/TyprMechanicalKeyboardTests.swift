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
