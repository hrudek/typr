import CoreGraphics
import UIKit
import XCTest
@testable import Typr

final class KeyboardLayoutTests: XCTestCase {
    private let portraitWidths: [CGFloat] = [320, 375, 393, 402, 430, 440]
    private let layers: [KeyboardLayer] = [.letters, .numbers, .symbols]
    private let fields: [KeyboardFieldKind] = [.text, .url, .email]

    private func everyPortraitLayout(showsStrip: Bool = true) -> [KeyboardLayout] {
        var layouts: [KeyboardLayout] = []
        for width in portraitWidths {
            for layer in layers {
                for field in fields {
                    for globe in [false, true] {
                        for globeKey in GlobeKey.allCases {
                            layouts.append(KeyboardLayout(
                                width: width, layer: layer, field: field, showsGlobe: globe, globeKey: globeKey,
                                showsStrip: showsStrip
                            ))
                        }
                    }
                }
            }
        }
        return layouts
    }

    /// Every layout, with and without the suggestion bar.
    private func everyLayout() -> [KeyboardLayout] {
        everyPortraitLayout() + everyPortraitLayout(showsStrip: false) + landscapeLayouts()
            + landscapeLayouts().map {
                KeyboardLayout(
                    width: $0.width, orientation: .landscape, layer: $0.layer, field: $0.field,
                    horizontalInset: $0.horizontalInset, showsStrip: false
                )
            }
    }

    func testJoinedSpaceKeycapOnlyConnectsAdjacentKeysWithoutChangingTargets() {
        for layout in everyLayout() {
            let originalKeys = layout.keys
            let joined = JoinedSpaceKeycap(layout: layout)
            guard layout.field == .text else {
                XCTAssertNil(joined, "Do not cover URL/email punctuation")
                continue
            }
            guard let joined, let space = layout.key(.space), let typr = layout.key(.typr) else {
                XCTFail("Adjacent space and Typr must share a background")
                continue
            }
            XCTAssertEqual(joined.frame, space.frame.union(typr.frame))
            XCTAssertEqual(joined.frame.height, layout.metrics.keyHeight)
            XCTAssertEqual(joined.radius, layout.metrics.cornerRadius)
            // The visual seam must not replace the original straight touch boundary.
            let boundary = space.hitFrame.maxX
            XCTAssertEqual(layout.hitTest(CGPoint(x: boundary - 0.01, y: space.frame.midY))?.kind, .space)
            XCTAssertEqual(layout.hitTest(CGPoint(x: boundary + 0.01, y: space.frame.midY))?.kind, .typr)
            XCTAssertEqual(layout.keys, originalKeys)
        }
    }

    @MainActor
    func testJoinedTyprRegionFollowsReferenceSeamAndFitsWordmark() {
        for layout in everyLayout() where layout.field == .text {
            let cap = layout.key(.typr)!.frame
            let space = layout.key(.space)!.frame
            let radius = layout.metrics.cornerRadius
            let region = JoinedSpaceKeycap.typrRegion(cap: cap, radius: radius)
            // The seam leaves the top edge just inside the Typr key and slopes
            // into the space bar, landing on the bottom edge 0.545 key heights left.
            let seam = JoinedSpaceKeycap.seam(cap: cap, radius: radius)
            XCTAssertEqual(seam.bounds.maxX, cap.minX + 0.05 * cap.height, accuracy: 0.001)
            XCTAssertEqual(seam.bounds.minX, cap.minX - 0.545 * cap.height, accuracy: 0.001)
            XCTAssertGreaterThan(seam.bounds.minX, space.minX + radius, "The seam stays inside the space bar")
            XCTAssertEqual(region.bounds.minX, cap.minX - 0.545 * cap.height, accuracy: 0.001)
            XCTAssertEqual(region.bounds.maxX, cap.maxX, accuracy: 0.001)
            XCTAssertEqual(region.bounds.minY, cap.minY, accuracy: 0.001)
            XCTAssertEqual(region.bounds.maxY, cap.maxY, accuracy: 0.001)
            XCTAssertFalse(region.contains(CGPoint(x: cap.minX - 0.3 * cap.height, y: cap.minY + 2)))
            XCTAssertTrue(region.contains(CGPoint(x: cap.minX - 0.3 * cap.height, y: cap.maxY - 2)))
            // The full wordmark and the ↗ hint sit inside the Typr segment.
            let mark = TyprMarkPath.frame(in: cap)
            let arrow = TyprMarkPath.arrowFrame(in: cap)
            XCTAssertEqual(mark.width / mark.height, TyprMarkPath.aspect, accuracy: 0.001)
            XCTAssertFalse(mark.intersects(arrow))
            for box in [mark, arrow] {
                for x in [box.minX, box.midX, box.maxX] {
                    for y in [box.minY, box.midY, box.maxY] {
                        XCTAssertTrue(region.contains(CGPoint(x: x, y: y)))
                        XCTAssertTrue(cap.contains(CGPoint(x: x, y: y)))
                    }
                }
            }
        }
    }

    @MainActor
    func testTyprKeyAndWordmarkMatch393PointReference() {
        // The original 393 pt keycap is unchanged; the wordmark and arrow follow
        // the owner's 2026-11-11 reference keyboard.
        let layout = KeyboardLayout(width: 393, showsStrip: true)
        let cap = layout.key(.typr)!.frame
        XCTAssertEqual(cap.minX, 252.576, accuracy: 0.001)
        XCTAssertEqual(cap.minY, 203, accuracy: 0.001)
        XCTAssertEqual(cap.width, 43.684, accuracy: 0.001)
        XCTAssertEqual(cap.height, 45, accuracy: 0.001)
        let mark = TyprMarkPath.frame(in: cap)
        XCTAssertEqual(mark.width, 27.958, accuracy: 0.001)
        XCTAssertEqual(mark.height, 11.782, accuracy: 0.001)
        XCTAssertEqual(mark.midX, cap.minX + 18.784, accuracy: 0.001)
        XCTAssertEqual(mark.midY, cap.minY + 24.3, accuracy: 0.001)
        let arrow = TyprMarkPath.arrowFrame(in: cap)
        XCTAssertEqual(arrow.maxX, cap.maxX - 6.4, accuracy: 0.001)
        XCTAssertEqual(arrow.minY, cap.minY + 7.2, accuracy: 0.001)
        XCTAssertEqual(arrow.width, 5.8, accuracy: 0.001)
    }

    @MainActor
    func testMechanicalDesignChangesKeycapAndJoinedSpacePixelsOnly() throws {
        let layout = try XCTUnwrap(everyLayout().first { $0.field == .text && JoinedSpaceKeycap(layout: $0) != nil })
        let joined = try XCTUnwrap(JoinedSpaceKeycap(layout: layout))
        let key = CGRect(origin: .zero, size: CGSize(width: 40, height: 44))
        let size = joined.frame.size

        func pixels(isDark: Bool, design: KeyboardDesign, joinedKey: Bool) -> Data {
            let palette = FullKeyboardPalette(isDark: isDark, design: design)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
                let context = renderer.cgContext
                context.translateBy(x: -joined.frame.minX, y: -joined.frame.minY)
                if joinedKey {
                    joined.draw(in: context, palette: palette, spacePressed: false, typrPressed: false)
                } else {
                    context.translateBy(x: joined.frame.minX, y: joined.frame.minY)
                    context.fillKeycap(key, palette: palette, fill: palette.keyFill)
                }
            }
            return image.pngData() ?? Data()
        }

        for isDark in [false, true] {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let legacy = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
                renderer.cgContext.fillKeycap(key, fill: FullKeyboardPalette(isDark: isDark).keyFill)
            }.pngData()
            XCTAssertEqual(pixels(isDark: isDark, design: .standard, joinedKey: false), legacy)
            XCTAssertNotEqual(
                pixels(isDark: isDark, design: .mechanical, joinedKey: false),
                pixels(isDark: isDark, design: .standard, joinedKey: false)
            )
            XCTAssertNotEqual(
                pixels(isDark: isDark, design: .mechanical, joinedKey: true),
                pixels(isDark: isDark, design: .standard, joinedKey: true)
            )
        }
    }

    @MainActor
    func testMechanicalMutesKeyLabelsAndDefaultKeepsTextBase() {
        func white(_ color: UIColor) -> CGFloat {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            return (r + g + b) / 3
        }
        for isDark in [false, true] {
            let standard = FullKeyboardPalette(isDark: isDark)
            XCTAssertEqual(standard.keyLabel, standard.textBase)
            XCTAssertEqual(standard.keyGlyph, standard.textBase)
            let mechanical = FullKeyboardPalette(isDark: isDark, design: .mechanical)
            for ink in [mechanical.keyLabel, mechanical.keyGlyph] {
                let contrast = abs(white(ink) - white(mechanical.keyFill))
                XCTAssertLessThan(contrast, abs(white(standard.textBase) - white(mechanical.keyFill)))
                XCTAssertGreaterThan(contrast, 0.3)
            }
        }
        XCTAssertEqual(FullKeyboardPalette(isDark: true).warmCore, FullKeyboardPalette(isDark: false).warmCore)
        XCTAssertNotEqual(FullKeyboardPalette(isDark: true, design: .mechanical).warmCore, FullKeyboardPalette(isDark: true).warmCore)
    }

    @MainActor
    func testMechanicalJoinedSeamSlantsAcrossTheTouchBoundary() throws {
        let layout = try XCTUnwrap(everyPortraitLayout().first { $0.field == .text && JoinedSpaceKeycap(layout: $0) != nil })
        let joined = try XCTUnwrap(JoinedSpaceKeycap(layout: layout))
        let face = MechanicalKeycap(isDark: true).faceRect(joined.frame)
        let boundary = (joined.space.maxX + joined.typr.minX) / 2
        XCTAssertGreaterThan(joined.mechanicalSeamX(atY: face.minY, face: face), boundary + 2)
        XCTAssertLessThan(joined.mechanicalSeamX(atY: face.maxY, face: face), boundary - 2)
        XCTAssertEqual(joined.mechanicalSeamX(atY: face.midY, face: face), boundary, accuracy: 0.001)

        for isDark in [false, true] {
            let palette = FullKeyboardPalette(isDark: isDark, design: .mechanical)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: joined.frame, format: format).image { renderer in
                joined.draw(in: renderer.cgContext, palette: palette, spacePressed: false, typrPressed: false)
            }
            let cgImage = try XCTUnwrap(image.cgImage)
            let data = try XCTUnwrap(cgImage.dataProvider?.data as Data?)
            func brightness(_ point: CGPoint) -> Int {
                let x = Int(point.x - joined.frame.minX), y = Int(point.y - joined.frame.minY)
                let offset = y * cgImage.bytesPerRow + x * cgImage.bitsPerPixel / 8
                return Int(data[offset]) + Int(data[offset + 1]) + Int(data[offset + 2])
            }
            func alpha(_ point: CGPoint) -> Int {
                let x = Int(point.x - joined.frame.minX), y = Int(point.y - joined.frame.minY)
                return Int(data[y * cgImage.bytesPerRow + x * cgImage.bitsPerPixel / 8 + 3])
            }
            for edge in [joined.frame.minY + 0.5, joined.frame.maxY - 0.5] {
                let corner = CGPoint(x: joined.mechanicalSeamX(atY: edge, face: face), y: edge)
                let body = CGPoint(x: joined.frame.minX + joined.radius * 2, y: edge)
                XCTAssertLessThan(alpha(corner), alpha(body))
            }
            for y in [face.minY + face.height * 0.25, face.midY, face.maxY - face.height * 0.25] {
                let seam = CGPoint(x: joined.mechanicalSeamX(atY: y, face: face), y: y)
                XCTAssertLessThan(brightness(seam), brightness(CGPoint(x: seam.x - 6, y: y)))
                XCTAssertLessThan(brightness(seam), brightness(CGPoint(x: seam.x + 6, y: y)))
            }
        }
    }

    @MainActor
    func testMechanicalJoinedSeamIsASoftShadowWithoutHardEdges() throws {
        let layout = try XCTUnwrap(everyPortraitLayout().first { $0.field == .text && JoinedSpaceKeycap(layout: $0) != nil })
        let joined = try XCTUnwrap(JoinedSpaceKeycap(layout: layout))
        let face = MechanicalKeycap(isDark: true).faceRect(joined.frame)
        let y = face.midY
        let centre = joined.mechanicalSeamX(atY: y, face: face)
        for isDark in [false, true] {
            let palette = FullKeyboardPalette(isDark: isDark, design: .mechanical)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: joined.frame, format: format).image { renderer in
                joined.draw(in: renderer.cgContext, palette: palette, spacePressed: false, typrPressed: false)
            }
            let cgImage = try XCTUnwrap(image.cgImage)
            let data = try XCTUnwrap(cgImage.dataProvider?.data as Data?)
            func brightness(dx: CGFloat, dy: CGFloat = 0) -> Int {
                let x = Int(centre + dx - joined.frame.minX), row = Int(y + dy - joined.frame.minY)
                let offset = row * cgImage.bytesPerRow + x * cgImage.bitsPerPixel / 8
                return Int(data[offset]) + Int(data[offset + 1]) + Int(data[offset + 2])
            }
            // The gap is darkest in the middle and fades toward its edges instead of a flat bar.
            let half = MechanicalKeycap.seamGap / 2
            XCTAssertLessThan(brightness(dx: 0), brightness(dx: half - 0.5))
        }
    }

    @MainActor
    func testDarkPaletteMatchesReferenceColors() {
        let dark = FullKeyboardPalette(isDark: true)
        func hex(_ color: UIColor) -> String {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            return String(format: "%02lX%02lX%02lX@%.2f", Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)), a)
        }
        XCTAssertEqual(hex(dark.keyFill), "2D2D2D@1.00")
        XCTAssertEqual(hex(dark.backdrop), "171717@1.00")
        XCTAssertEqual(hex(dark.joinedOutline), "767676@1.00")
        XCTAssertEqual(hex(dark.textBase), "FFFFFF@1.00")
    }

    @MainActor
    func testJoinedKeyHighlightIsDrawingOnlyAndResetsOnCancel() {
        let control = TyprKeyControl()
        control.joinsSpace = true
        var highlights: [Bool] = []
        var actions = 0
        control.onHighlightChanged = { highlights.append($0) }
        control.onTap = { actions += 1 }
        control.onHold = { actions += 1 }
        control.isHighlighted = true
        control.isHighlighted = true
        control.cancelTracking(with: nil)
        XCTAssertEqual(highlights, [true, false])
        XCTAssertEqual(actions, 0)
    }

    func testPortraitIs253PointsAndLandscapeIs176Points() {
        for width in portraitWidths {
            XCTAssertEqual(KeyboardLayout(width: width).totalHeight, 253, "width \(width)")
        }
        XCTAssertEqual(KeyboardLayout.height(for: .portrait), 253)
        XCTAssertEqual(KeyboardLayout.height(for: .landscape), 176)
    }

    /// Typr: without the suggestion bar the keys move up to a small top margin.
    func testWithoutTheBarTheKeyboardIsShorterAndKeysMoveUp() {
        for width in portraitWidths {
            let layout = KeyboardLayout(width: width, showsStrip: false)
            XCTAssertEqual(layout.totalHeight, 224, "width \(width)")
            XCTAssertEqual(layout.key(.character("q"))!.frame.minY, 6, accuracy: 0.001)
            XCTAssertEqual(layout.stripFrame.height, 0)
            XCTAssertEqual(layout.key(.character("q"))!.hitFrame.minY, 0, "the top margin still types")
        }
        XCTAssertEqual(KeyboardLayout.height(for: .portrait, showsStrip: false), 224)
        XCTAssertEqual(KeyboardLayout.height(for: .landscape, showsStrip: false), 141)
        // Same keys, same sizes.
        let with = KeyboardLayout(width: 393)
        let without = KeyboardLayout(width: 393, showsStrip: false)
        XCTAssertEqual(with.keys.map(\.frame.size), without.keys.map(\.frame.size))
        XCTAssertEqual(with.keys.map(\.frame.minX), without.keys.map(\.frame.minX))
    }

    func testTopRowBalloonsWidenTheKeyInPlaceWithoutTheBar() {
        for layout in everyPortraitLayout(showsStrip: false) {
            let bounds = CGRect(x: 0, y: 0, width: layout.width, height: layout.totalHeight)
            for key in layout.keys where key.character != nil {
                let balloon = layout.balloon(for: key)!
                XCTAssertTrue(bounds.insetBy(dx: -0.001, dy: -0.001).contains(balloon.bounds), describe(layout))
                XCTAssertEqual(balloon.isInline, key.row == 0, "\(describe(layout)) \(key.label)")
                if balloon.isInline {
                    XCTAssertEqual(balloon.bubble.maxY, key.frame.maxY, accuracy: 0.001)
                    XCTAssertLessThan(balloon.bubble.minY, key.frame.minY)
                }
            }
        }
        // With the bar every balloon floats above its key, as before.
        for layout in everyPortraitLayout() {
            for key in layout.keys where key.character != nil {
                XCTAssertFalse(layout.balloon(for: key)!.isInline, "\(describe(layout)) \(key.label)")
            }
        }
    }

    func testPortraitMetricsMatchAppleIOS26() {
        let proMax = KeyboardLayout(width: 440)
        XCTAssertEqual(proMax.letterWidth, (440 - 13 - 54) / 10, accuracy: 0.001)
        let q = proMax.key(.character("q"))!
        XCTAssertEqual(q.frame.minX, 6.5, accuracy: 0.001)
        XCTAssertEqual(q.frame.minY, 35, accuracy: 0.001)
        XCTAssertEqual(q.frame.height, 45)
        let shift = proMax.key(.shift)!
        XCTAssertEqual(shift.frame.width, proMax.letterWidth * 1.34, accuracy: 0.001)
    }

    func testHitTargetsTileTheKeyAreaWithNoDeadZonesOrOverlaps() {
        var generator = SystemRandomNumberGenerator()
        for layout in everyLayout() {
            let area = layout.keysAreaFrame
            var rowTop = area.minY
            for row in 0..<4 {
                let targets = layout.keys.filter { $0.row == row }.map(\.hitFrame).sorted { $0.minX < $1.minX }
                XCTAssertEqual(targets.first?.minX, 0, describe(layout))
                XCTAssertEqual(targets.last?.maxX, layout.width, describe(layout))
                for target in targets {
                    XCTAssertEqual(target.minY, rowTop, accuracy: 0.0001, "\(describe(layout)) row \(row)")
                }
                for (a, b) in zip(targets, targets.dropFirst()) {
                    XCTAssertEqual(a.maxX, b.minX, accuracy: 0.0001, "\(describe(layout)) row \(row)")
                }
                rowTop = targets[0].maxY
            }
            XCTAssertEqual(rowTop, area.maxY, accuracy: 0.0001, describe(layout))

            for _ in 0..<400 {
                let point = CGPoint(
                    x: CGFloat.random(in: 0..<layout.width, using: &generator),
                    y: CGFloat.random(in: area.minY..<area.maxY, using: &generator)
                )
                let hits = layout.keys.filter { $0.hitFrame.contains(point) }
                XCTAssertEqual(hits.count, 1, "\(describe(layout)) at \(point): \(hits.map(\.label))")
            }
            if layout.showsStrip {
                XCTAssertNil(layout.hitTest(CGPoint(x: 20, y: layout.stripFrame.midY)), "strip is not a key")
            } else {
                XCTAssertEqual(area.minY, 0, "without the bar the keys reach the top edge")
            }
        }
    }

    func testKeycapsSitInsideTheirTargetsAndNeverOverlap() {
        for layout in everyLayout() {
            let bounds = CGRect(x: 0, y: 0, width: layout.width, height: layout.totalHeight)
            for key in layout.keys {
                XCTAssertTrue(key.hitFrame.contains(key.frame), "\(describe(layout)) \(key.label)")
                XCTAssertTrue(bounds.contains(key.frame), "\(describe(layout)) \(key.label)")
                XCTAssertGreaterThan(key.frame.width, 20, "\(describe(layout)) \(key.label)")
            }
            for (i, a) in layout.keys.enumerated() {
                for b in layout.keys[(i + 1)...] {
                    XCTAssertFalse(a.frame.intersects(b.frame), "\(describe(layout)) \(a.label) × \(b.label)")
                }
            }
        }
    }

    func testBalloonsStayInsideThe253PointKeyboard() {
        for layout in everyPortraitLayout() {
            let bounds = CGRect(x: 0, y: 0, width: layout.width, height: layout.totalHeight)
            for key in layout.keys where key.character != nil {
                guard let balloon = layout.balloon(for: key) else {
                    return XCTFail("\(describe(layout)) \(key.label) has no balloon")
                }
                XCTAssertTrue(
                    bounds.insetBy(dx: -0.001, dy: -0.001).contains(balloon.bounds),
                    "\(describe(layout)) \(key.label): \(balloon.bubble)"
                )
                XCTAssertGreaterThanOrEqual(balloon.bubble.width, key.frame.width)
            }
        }
    }

    func testAccentMenusClampInwardAcrossEveryWidth() {
        for width in portraitWidths {
            let layout = KeyboardLayout(width: width)
            let bounds = CGRect(x: 0, y: 0, width: layout.width, height: layout.totalHeight)
            for ch in ["e", "a", "i", "o", "u", "n", "c", "s", "z"] {
                let key = layout.key(.character(ch))!
                let options = AccentCatalog.options(for: ch, uppercase: false)!
                let menu = AccentMenu.build(for: key.frame, rawOptions: options, in: layout.width)
                XCTAssertTrue(
                    bounds.insetBy(dx: -0.01, dy: -0.01).contains(menu.bubbleFrame),
                    "width \(width) key \(ch): \(menu.bubbleFrame)"
                )
                XCTAssertEqual(menu.selectedOption, ch)
            }
        }
    }

    func testEdgeBalloonsArePushedInward() {
        let layout = KeyboardLayout(width: 375)
        let q = layout.balloon(for: layout.key(.character("q"))!)!
        let p = layout.balloon(for: layout.key(.character("p"))!)!
        let g = layout.balloon(for: layout.key(.character("g"))!)!
        XCTAssertGreaterThan(q.offsetX, 0)
        XCTAssertLessThan(p.offsetX, 0)
        XCTAssertEqual(g.offsetX, 0, accuracy: 0.001)
        XCTAssertEqual(q.bubble.minY, 0, accuracy: 0.001)
    }

    func testNoBalloonsForModifiersOrInLandscape() {
        let portrait = KeyboardLayout(width: 393)
        XCTAssertNil(portrait.balloon(for: portrait.key(.space)!))
        XCTAssertNil(portrait.balloon(for: portrait.key(.shift)!))
        let landscape = KeyboardLayout(width: 852, orientation: .landscape)
        XCTAssertNil(landscape.balloon(for: landscape.key(.character("a"))!))
    }

    func testBottomRowMatchesIOS26EmailAndURLRightOfSpace() {
        XCTAssertEqual(bottomRow(KeyboardLayout(width: 393)), [.layerSwitch(.numbers), .space, .typr, .returnKey])
        XCTAssertEqual(
            bottomRow(KeyboardLayout(width: 375, showsGlobe: true)),
            [.layerSwitch(.numbers), .globe, .space, .typr, .returnKey]
        )
        XCTAssertEqual(
            bottomRow(KeyboardLayout(width: 393, layer: .numbers, field: .email)),
            [.layerSwitch(.letters), .space, .character("@"), .character("."), .typr, .returnKey]
        )
        XCTAssertEqual(
            bottomRow(KeyboardLayout(width: 393, field: .url)),
            [.layerSwitch(.numbers), .space, .character("."), .character("/"), .typr, .returnKey]
        )
    }

    func testRowThreeModifiersFollowTheLayer() {
        XCTAssertNotNil(KeyboardLayout(width: 393).key(.shift))
        XCTAssertEqual(KeyboardLayout(width: 393, layer: .numbers).key(.layerSwitch(.symbols))?.row, 2)
        XCTAssertEqual(KeyboardLayout(width: 393, layer: .symbols).key(.layerSwitch(.numbers))?.row, 2)
        let numbers = KeyboardLayout(width: 393, layer: .numbers)
        XCTAssertEqual(numbers.keys.filter { $0.row == 2 }.compactMap(\.character), [".", ",", "?", "!", "'"])
    }

    func testRowTwoIsCentred() {
        let layout = KeyboardLayout(width: 402)
        let a = layout.key(.character("a"))!.frame
        let l = layout.key(.character("l"))!.frame
        XCTAssertEqual(a.minX, layout.width - l.maxX, accuracy: 0.001)
        XCTAssertEqual(layout.key(.character("a"))!.hitFrame.minX, 0)
        XCTAssertEqual(layout.key(.character("l"))!.hitFrame.maxX, layout.width)
    }

    func testLandscapeKeepsInsetsAndHeight() {
        let layout = KeyboardLayout(width: 932, orientation: .landscape, horizontalInset: 60)
        XCTAssertEqual(layout.totalHeight, 176)
        XCTAssertEqual(layout.key(.character("q"))!.frame.minX, 64, accuracy: 0.001)
        XCTAssertEqual(layout.key(.character("q"))!.hitFrame.minX, 0)
    }

    // MARK: - Helpers

    private func landscapeLayouts() -> [KeyboardLayout] {
        [
            KeyboardLayout(width: 667, orientation: .landscape),
            KeyboardLayout(width: 852, orientation: .landscape, layer: .numbers),
            KeyboardLayout(width: 956, orientation: .landscape, field: .email, horizontalInset: 60),
        ]
    }

    func testGlobeKeyChoicesShapeTheBottomRowOnlyWhereIOSNeedsAGlobe() {
        for layer in [KeyboardLayer.letters, .numbers] {
            let layerKey = KeyKind.layerSwitch(layer == .letters ? .numbers : .letters)
            let switches = KeyboardLayout(width: 393, layer: layer, showsGlobe: true, globeKey: .switches)
            let spacer = KeyboardLayout(width: 393, layer: layer, showsGlobe: true, globeKey: .spacer)
            let hidden = KeyboardLayout(width: 393, layer: layer, showsGlobe: true, globeKey: .hidden)
            let none = KeyboardLayout(width: 393, layer: layer)

            XCTAssertEqual(bottomRow(switches), [layerKey, .globe, .space, .typr, .returnKey])
            XCTAssertEqual(bottomRow(spacer), [.globeSpacer, layerKey, .space, .typr, .returnKey])
            XCTAssertEqual(bottomRow(hidden), bottomRow(none))
            XCTAssertEqual(hidden.keys, none.keys)
            XCTAssertEqual(spacer.key(.globeSpacer)?.frame.width, switches.key(.globe)?.frame.width)
            XCTAssertEqual(spacer.key(.space)?.frame.width, switches.key(.space)?.frame.width)

            XCTAssertFalse(switches.layerKeyHoldSwitchesKeyboard)
            XCTAssertTrue(spacer.layerKeyHoldSwitchesKeyboard)
            XCTAssertTrue(hidden.layerKeyHoldSwitchesKeyboard)
        }
        for globeKey in GlobeKey.allCases {
            let layout = KeyboardLayout(width: 393, globeKey: globeKey)
            XCTAssertEqual(layout.keys, KeyboardLayout(width: 393).keys, "\(globeKey)")
            XCTAssertFalse(layout.layerKeyHoldSwitchesKeyboard)
        }
    }

    func testBottomRowFollowsTheOrderAndThePeriodToggle() {
        let dot = KeyKind.character(".")
        let on = BottomRow(order: [.typr, .space, .period], periodKey: true)
        let off = BottomRow(order: [.typr, .space, .period], periodKey: false)

        XCTAssertEqual(
            bottomRow(KeyboardLayout(width: 393, bottomRow: on)),
            [.layerSwitch(.numbers), .typr, .space, dot, .returnKey]
        )
        XCTAssertEqual(
            bottomRow(KeyboardLayout(width: 393, bottomRow: off)),
            [.layerSwitch(.numbers), .typr, .space, .returnKey]
        )
        XCTAssertEqual(
            bottomRow(KeyboardLayout(width: 393, layer: .numbers, bottomRow: on)),
            [.layerSwitch(.letters), .typr, .space, .returnKey]
        )
        XCTAssertEqual(
            bottomRow(KeyboardLayout(width: 393, field: .email, bottomRow: on)),
            [.layerSwitch(.numbers), .typr, .space, .character("@"), dot, .returnKey]
        )
        XCTAssertEqual(
            bottomRow(KeyboardLayout(width: 393, field: .url, bottomRow: on)),
            [.layerSwitch(.numbers), .typr, .space, dot, .character("/"), .returnKey]
        )
        XCTAssertEqual(
            bottomRow(KeyboardLayout(
                width: 393, showsGlobe: true, globeKey: .spacer,
                bottomRow: BottomRow(order: [.period, .space, .typr], periodKey: true)
            )),
            [.globeSpacer, .layerSwitch(.numbers), dot, .space, .typr, .returnKey]
        )
    }

    func testOnlyTheBottomRowPeriodKeyHoldsMorePunctuation() throws {
        let on = BottomRow(order: BottomKey.standard, periodKey: true)
        let letters = KeyboardLayout(width: 393, bottomRow: on)
        XCTAssertTrue(letters.isPeriodKey(try XCTUnwrap(letters.key(.character(".")))))
        for layout in [
            KeyboardLayout(width: 393, layer: .numbers, bottomRow: on),
            KeyboardLayout(width: 393, field: .email, bottomRow: on),
            KeyboardLayout(width: 393, field: .url, bottomRow: on),
        ] {
            XCTAssertFalse(layout.isPeriodKey(try XCTUnwrap(layout.key(.character(".")))), describe(layout))
        }
    }

    func testWithoutThePeriodKeyEveryOrderOfSpaceAndTyprBeforeItKeepsTodaysRow() {
        for order in [[BottomKey.space, .typr, .period], [.period, .space, .typr]] {
            XCTAssertEqual(
                KeyboardLayout(width: 393, bottomRow: BottomRow(order: order, periodKey: false)).keys,
                KeyboardLayout(width: 393).keys
            )
        }
    }

    func testEveryBottomRowKeepsTheLayerKeyFirstAndReturnLastWithoutOverlaps() {
        let orders: [[BottomKey]] = [
            [.space, .period, .typr], [.space, .typr, .period], [.period, .space, .typr],
            [.period, .typr, .space], [.typr, .space, .period], [.typr, .period, .space],
        ]
        for base in everyPortraitLayout() + landscapeLayouts() {
            for order in orders {
                for periodKey in [false, true] {
                    let layout = KeyboardLayout(
                        width: base.width, orientation: base.orientation, layer: base.layer, field: base.field,
                        showsGlobe: base.showsGlobe, globeKey: base.globeKey,
                        bottomRow: BottomRow(order: order, periodKey: periodKey),
                        horizontalInset: base.horizontalInset, showsStrip: base.showsStrip
                    )
                    let name = "\(describe(layout)) \(order) period=\(periodKey)"
                    let kinds = bottomRow(layout).filter { $0 != .globeSpacer }
                    XCTAssertEqual(kinds.first, .layerSwitch(layout.layer == .letters ? .numbers : .letters), name)
                    XCTAssertEqual(kinds.last, .returnKey, name)
                    let dots = kinds.filter { $0 == .character(".") }.count
                    XCTAssertEqual(dots, layout.field != .text || (periodKey && layout.layer == .letters) ? 1 : 0, name)
                    let row = layout.keys.filter { $0.row == 3 }.sorted { $0.frame.minX < $1.frame.minX }
                    for (a, b) in zip(row, row.dropFirst()) {
                        XCTAssertLessThan(a.frame.maxX, b.frame.minX, name)
                        XCTAssertEqual(a.hitFrame.maxX, b.hitFrame.minX, accuracy: 0.0001, name)
                    }
                    XCTAssertLessThanOrEqual(row.last?.frame.maxX ?? 0, layout.width - layout.horizontalInset, name)
                    XCTAssertGreaterThan(layout.key(.space)?.frame.width ?? 0, 2 * layout.letterWidth, name)
                }
            }
        }
    }

    func testBottomKeysArrangeEachKeyOnceWithMissingOnesInTheirStandardPlace() {
        XCTAssertEqual(BottomKey.arranged([]), BottomKey.standard)
        XCTAssertEqual(BottomKey.arranged([.typr, .typr]), [.space, .period, .typr])
        XCTAssertEqual(BottomKey.arranged([.typr, .space]), [.typr, .space, .period])
        XCTAssertEqual(BottomKey.arranged([.period, .typr, .space]), [.period, .typr, .space])
    }

    private func bottomRow(_ layout: KeyboardLayout) -> [KeyKind] {
        layout.keys.filter { $0.row == 3 }.sorted { $0.frame.minX < $1.frame.minX }.map(\.kind)
    }

    private func describe(_ layout: KeyboardLayout) -> String {
        "\(layout.width)pt \(layout.orientation) \(layout.layer) \(layout.field) globe=\(layout.showsGlobe) \(layout.globeKey) \(layout.bottomRow) strip=\(layout.showsStrip)"
    }
}

@MainActor
final class FullKeyboardSettingsTests: XCTestCase {
    func testFullKeyboardAndAutocorrectAreOnByDefault() throws {
        let suite = "FullKeyboardSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = FullKeyboardSettings(defaults: defaults)

        XCTAssertTrue(settings.isEnabled)
        XCTAssertTrue(settings.autocorrect)
        XCTAssertTrue(settings.swipeTyping)

        settings.isEnabled = false
        settings.applyLaunchArguments(["Typr"])
        XCTAssertFalse(settings.isEnabled)
        settings.applyLaunchArguments(["Typr", FullKeyboardSettings.launchArgument])
        XCTAssertTrue(settings.isEnabled)

        settings.autocorrect = false
        XCTAssertFalse(FullKeyboardSettings(defaults: defaults).autocorrect)
        settings.swipeTyping = false
        XCTAssertFalse(FullKeyboardSettings(defaults: defaults).swipeTyping)
    }

    func testKeyboardDesignDefaultsRoundTripsAndFallsBack() throws {
        let suite = "FullKeyboardSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = FullKeyboardSettings(defaults: defaults)

        XCTAssertEqual(settings.design, .standard)
        settings.design = .mechanical
        XCTAssertEqual(FullKeyboardSettings(defaults: defaults).design, .mechanical)
        defaults.set("neon", forKey: "settings.keyboardDesign")
        XCTAssertEqual(settings.design, .standard)
    }

    func testBottomRowDefaultsToSpaceThenTyprAndRoundTrips() throws {
        let suite = "FullKeyboardSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = FullKeyboardSettings(defaults: defaults)

        XCTAssertEqual(settings.bottomRow, BottomRow(order: [.space, .period, .typr], periodKey: false))
        let arranged = BottomRow(order: [.typr, .space, .period], periodKey: true)
        settings.bottomRow = arranged
        XCTAssertEqual(FullKeyboardSettings(defaults: defaults).bottomRow, arranged)
        defaults.set(["typr", "emoji"], forKey: "settings.keyboardBottomRowOrder")
        XCTAssertEqual(settings.bottomRow.order, [.space, .period, .typr])
    }

    func testNoAppGroupReadsAsOff() {
        XCTAssertFalse(FullKeyboardSettings(defaults: nil).isEnabled)
    }
}
