import CoreGraphics
import UIKit
import XCTest
@testable import Typr

final class KeyboardLayoutTests: XCTestCase {
    private let portraitWidths: [CGFloat] = [320, 375, 393, 402, 430, 440]
    private let layers: [KeyboardLayer] = [.letters, .numbers, .symbols]
    private let fields: [KeyboardFieldKind] = [.text, .url, .email]

    private func everyPortraitLayout(showsStrip: Bool = true, numberRow: Bool = false) -> [KeyboardLayout] {
        var layouts: [KeyboardLayout] = []
        for width in portraitWidths {
            for layer in layers {
                for field in fields {
                    for globe in [false, true] {
                        for globeKey in GlobeKey.allCases {
                            layouts.append(KeyboardLayout(
                                width: width, layer: layer, field: field, showsGlobe: globe, globeKey: globeKey,
                                numberRow: numberRow, showsStrip: showsStrip
                            ))
                        }
                    }
                }
            }
        }
        return layouts
    }

    private func everyLayout() -> [KeyboardLayout] {
        [false, true].flatMap { numberRow in
            everyPortraitLayout(numberRow: numberRow) + everyPortraitLayout(showsStrip: false, numberRow: numberRow)
                + [true, false].flatMap { showsStrip in
                    (landscapeLayouts() + wideLayouts()).map {
                        KeyboardLayout(
                            width: $0.width, orientation: $0.orientation, layer: $0.layer, field: $0.field,
                            numberRow: numberRow, horizontalInset: $0.horizontalInset, showsStrip: showsStrip
                        )
                    }
                }
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
            // Split layouts have a space bar in each half; Typr sits beside the right one.
            guard let joined, let space = layout.keys.last(where: { $0.kind == .space }), let typr = layout.key(.typr) else {
                XCTFail("Adjacent space and Typr must share a background")
                continue
            }
            XCTAssertEqual(joined.frame, space.frame.union(typr.frame))
            XCTAssertEqual(joined.frame.height, space.frame.height)
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
        let scale: CGFloat = 3
        for isDark in [false, true] {
            let palette = FullKeyboardPalette(isDark: isDark, design: .mechanical)
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = true
            let image = UIGraphicsImageRenderer(bounds: joined.frame, format: format).image { renderer in
                palette.backdrop.setFill()
                renderer.fill(joined.frame)
                joined.draw(in: renderer.cgContext, palette: palette, spacePressed: false, typrPressed: false)
            }
            let cgImage = try XCTUnwrap(image.cgImage)
            let data = try XCTUnwrap(cgImage.dataProvider?.data as Data?)
            func brightness(dx: CGFloat) -> Int {
                let x = Int((centre + dx - joined.frame.minX) * scale), row = Int((y - joined.frame.minY) * scale)
                let offset = row * cgImage.bytesPerRow + x * cgImage.bitsPerPixel / 8
                return Int(data[offset]) + Int(data[offset + 1]) + Int(data[offset + 2])
            }
            let reach = MechanicalKeycap.seamGap / 2 - 0.4
            let quantisation = 3
            for sign: CGFloat in [-1, 1] {
                let samples = stride(from: CGFloat(0), through: reach, by: 1 / scale).map { brightness(dx: sign * $0) }
                XCTAssertLessThan(samples[0], samples[samples.count - 1])
                let steps = zip(samples, samples.dropFirst()).map { $1 - $0 }
                XCTAssertGreaterThanOrEqual(steps.min() ?? 0, -quantisation)
                XCTAssertLessThanOrEqual(steps.max() ?? 0, max((samples[samples.count - 1] - samples[0]) / 2, quantisation))
            }
        }
    }

    @MainActor
    func testPanelKeysShareLetterKeyFill() {
        for design in [KeyboardDesign.standard, .mechanical] {
            for isDark in [false, true] {
                let palette = FullKeyboardPalette(isDark: isDark, design: design)
                for button in [PanelKeyButton(), PanelKeyButton()] {
                    button.palette = palette
                    XCTAssertEqual(button.fill, palette.keyFill)
                }
            }
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
            let isSplit = layout.orientation == .splitLandscape
            var rowTop = area.minY
            // Split only: per row, the stretch between the halves that types nothing.
            var gaps: [(rows: Range<CGFloat>, xs: Range<CGFloat>)] = []
            for row in 0...layout.bottomRowIndex {
                let keys = layout.keys.filter { $0.row == row }.sorted { $0.frame.minX < $1.frame.minX }
                let targets = keys.map(\.hitFrame)
                XCTAssertEqual(targets.first?.minX, 0, describe(layout))
                XCTAssertEqual(targets.last?.maxX, layout.width, describe(layout))
                for target in targets {
                    XCTAssertEqual(target.minY, rowTop, accuracy: 0.0001, "\(describe(layout)) row \(row)")
                }
                var gapCount = 0
                for (a, b) in zip(keys, keys.dropFirst()) {
                    if isSplit, b.frame.minX - a.frame.maxX > layout.letterWidth {
                        gapCount += 1
                        XCTAssertLessThan(a.hitFrame.maxX, layout.width / 2, "\(describe(layout)) row \(row)")
                        XCTAssertGreaterThan(b.hitFrame.minX, layout.width / 2, "\(describe(layout)) row \(row)")
                        gaps.append((a.hitFrame.minY..<a.hitFrame.maxY, a.hitFrame.maxX..<b.hitFrame.minX))
                    } else {
                        XCTAssertEqual(a.hitFrame.maxX, b.hitFrame.minX, accuracy: 0.0001, "\(describe(layout)) row \(row)")
                    }
                }
                XCTAssertEqual(gapCount, isSplit ? 1 : 0, "\(describe(layout)) row \(row)")
                rowTop = targets[0].maxY
            }
            XCTAssertEqual(rowTop, area.maxY, accuracy: 0.0001, describe(layout))

            for _ in 0..<400 {
                let point = CGPoint(
                    x: CGFloat.random(in: 0..<layout.width, using: &generator),
                    y: CGFloat.random(in: area.minY..<area.maxY, using: &generator)
                )
                let hits = layout.keys.filter { $0.hitFrame.contains(point) }
                let inGap = gaps.contains { $0.rows.contains(point.y) && $0.xs.contains(point.x) }
                XCTAssertEqual(hits.count, inGap ? 0 : 1, "\(describe(layout)) at \(point): \(hits.map(\.label))")
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

    func testBalloonsStayInsideTheKeyboard() {
        for layout in everyPortraitLayout() + everyPortraitLayout(numberRow: true) {
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

    func testSplitLettersFollowTheKeychronRowStaggerWithSlashRightOfM() throws {
        for width: CGFloat in [801, 951] {
            for numberRow in [false, true] {
                let layout = KeyboardLayout(width: width, orientation: .splitLandscape, numberRow: numberRow)
                let name = describe(layout)
                let pitch = layout.letterWidth + layout.metrics.gap
                func frame(_ ch: String) throws -> CGRect { try XCTUnwrap(layout.key(.character(ch)), ch).frame }
                for (first, second, third) in [("q", "a", "z"), ("y", "h", "n")] {
                    XCTAssertEqual(try frame(second).minX - frame(first).minX, pitch / 4, accuracy: 0.001, name)
                    XCTAssertEqual(try frame(third).minX - frame(first).minX, 3 * pitch / 4, accuracy: 0.001, name)
                }

                let shift = try XCTUnwrap(layout.key(.shift)).frame
                let delete = try XCTUnwrap(layout.key(.delete)).frame
                let slash = try XCTUnwrap(layout.key(.character("/")))
                XCTAssertEqual(shift.width, layout.letterWidth * KeyboardLayout.modifierWidthRatio, accuracy: 0.001, name)
                XCTAssertEqual(delete.width, shift.width, accuracy: 0.001, name)
                XCTAssertEqual(try frame("z").minX - shift.maxX, layout.metrics.gap, accuracy: 0.001, name)
                XCTAssertEqual(slash.row, layout.key(.character("m"))?.row, name)
                XCTAssertEqual(slash.frame.width, layout.letterWidth, accuracy: 0.001, name)
                XCTAssertEqual(try slash.frame.minX - frame("m").maxX, layout.metrics.gap, accuracy: 0.001, name)
                XCTAssertEqual(delete.minX - slash.frame.maxX, layout.metrics.gap, accuracy: 0.001, name)
            }
        }
    }

    func testAlignedColumnsStackTheSplitLettersWithZBesideShift() throws {
        for width: CGFloat in [801, 951] {
            for numberRow in [false, true] {
                let layout = KeyboardLayout(width: width, orientation: .splitLandscape, numberRow: numberRow, splitColumns: true)
                let name = describe(layout)
                func frame(_ ch: String) throws -> CGRect { try XCTUnwrap(layout.key(.character(ch)), ch).frame }
                for column in ["qaz", "wsx", "edc", "rfv", "tgb", "yhn", "ujm", "ik/", "ol", "p"] {
                    let minXs = try column.map { try frame(String($0)).minX }
                    for minX in minXs { XCTAssertEqual(minX, minXs[0], accuracy: 0.001, "\(column) \(name)") }
                }

                let shift = try XCTUnwrap(layout.key(.shift)).frame
                let delete = try XCTUnwrap(layout.key(.delete)).frame
                XCTAssertEqual(shift.width, layout.letterWidth * KeyboardLayout.modifierWidthRatio, accuracy: 0.001, name)
                XCTAssertEqual(delete.width, shift.width, accuracy: 0.001, name)
                XCTAssertEqual(try frame("z").minX - shift.maxX, layout.metrics.gap, accuracy: 0.001, name)
                XCTAssertEqual(try frame("p").maxX, layout.width - layout.metrics.side, accuracy: 0.001, name)
                XCTAssertGreaterThanOrEqual(try delete.minX - frame("/").maxX, layout.metrics.gap, name)
                let keys = layout.keys.map(\.frame)
                for (index, a) in keys.enumerated() {
                    for b in keys[(index + 1)...] { XCTAssertFalse(a.insetBy(dx: 0.001, dy: 0.001).intersects(b), name) }
                }
            }
        }
    }

    func testAlignedColumnsChangeOnlyTheSplitLettersPage() {
        for (orientation, width) in [(KeyboardOrientation.portrait, 393), (.landscape, 932), (.widePortrait, 669),
                                     (.wideLandscape, 951), (.splitLandscape, 951)] as [(KeyboardOrientation, CGFloat)] {
            for layer in layers {
                for numberRow in [false, true] {
                    let staggered = KeyboardLayout(width: width, orientation: orientation, layer: layer, numberRow: numberRow)
                    let aligned = KeyboardLayout(width: width, orientation: orientation, layer: layer, numberRow: numberRow,
                                                 splitColumns: true)
                    let changes = orientation == .splitLandscape && layer == .letters
                    XCTAssertEqual(aligned.keys == staggered.keys, !changes, describe(aligned))
                    XCTAssertEqual(aligned.splitColumns, orientation == .splitLandscape, describe(aligned))
                }
            }
        }
    }

    func testMirroredHalvesMoveTheLeftHalfOutwardAndKeepTheRightHalf() throws {
        for width: CGFloat in [801, 951] {
            for columns in [false, true] {
                for numberRow in [false, true] {
                    for layer in layers {
                        let plain = KeyboardLayout(width: width, orientation: .splitLandscape, layer: layer,
                                                   numberRow: numberRow, splitColumns: columns, horizontalInset: 60)
                        let mirrored = KeyboardLayout(width: width, orientation: .splitLandscape, layer: layer,
                                                      numberRow: numberRow, splitColumns: columns, splitMirrored: true,
                                                      horizontalInset: 60)
                        let name = describe(mirrored)
                        let centre = width / 2
                        var moved = 0
                        for (a, b) in zip(plain.keys, mirrored.keys) {
                            XCTAssertEqual(a.kind, b.kind, name)
                            if a.frame.midX >= centre || b.row == mirrored.bottomRowIndex {
                                XCTAssertEqual(a.frame, b.frame, name)
                                XCTAssertEqual(a.hitFrame.maxX, b.hitFrame.maxX, name)
                            } else {
                                XCTAssertLessThanOrEqual(b.frame.minX, a.frame.minX, name)
                                XCTAssertGreaterThanOrEqual(b.frame.minX, 0, name)
                                XCTAssertEqual(a.frame.height, b.frame.height, name)
                                if a.frame != b.frame { moved += 1 }
                            }
                            XCTAssertEqual(a.frame.width, b.frame.width, accuracy: 0.001, name)
                        }
                        XCTAssertGreaterThan(moved, 0, name)
                        let keys = mirrored.keys.map(\.frame)
                        for (index, a) in keys.enumerated() {
                            for b in keys[(index + 1)...] { XCTAssertFalse(a.insetBy(dx: 0.001, dy: 0.001).intersects(b), name) }
                        }
                        if layer == .letters {
                            func innerGap(_ layout: KeyboardLayout) throws -> CGFloat {
                                try centre - XCTUnwrap(layout.key(.character("b"))).frame.maxX
                            }
                            XCTAssertGreaterThan(try innerGap(mirrored), try innerGap(plain) + 1, name)
                        }
                    }
                }
            }
        }
    }

    func testMirroredLeftHalfIgnoresTheSafeAreaInsetAndKeepsKeySizes() {
        for layer in layers {
            let plain = KeyboardLayout(width: 951, orientation: .splitLandscape, layer: layer, horizontalInset: 60)
            let mirrored = KeyboardLayout(width: 951, orientation: .splitLandscape, layer: layer,
                                          splitMirrored: true, horizontalInset: 60)
            let name = describe(mirrored)
            var leftMost = CGFloat.infinity
            var plainLeftMost = CGFloat.infinity
            for (a, b) in zip(plain.keys, mirrored.keys) {
                XCTAssertEqual(a.frame.size, b.frame.size, name)
                if a.frame.midX >= 951 / 2 || b.row == mirrored.bottomRowIndex {
                    XCTAssertEqual(a.frame, b.frame, name)
                } else {
                    leftMost = min(leftMost, b.frame.minX)
                    plainLeftMost = min(plainLeftMost, a.frame.minX)
                    XCTAssertGreaterThanOrEqual(b.frame.minX, mirrored.metrics.side - 0.001, name)
                }
            }
            XCTAssertLessThan(leftMost, plainLeftMost, name)
        }
    }

    func testMirroredHalvesChangeOnlySplitLandscape() {
        for (orientation, width) in [(KeyboardOrientation.portrait, 393), (.landscape, 932), (.widePortrait, 669),
                                     (.wideLandscape, 951)] as [(KeyboardOrientation, CGFloat)] {
            for layer in layers {
                let plain = KeyboardLayout(width: width, orientation: orientation, layer: layer)
                let mirrored = KeyboardLayout(width: width, orientation: orientation, layer: layer, splitMirrored: true)
                XCTAssertEqual(plain.keys, mirrored.keys, describe(mirrored))
                XCTAssertFalse(mirrored.splitMirrored)
            }
        }
        XCTAssertNotEqual(KeyboardLayout(width: 951, orientation: .splitLandscape).keys,
                          KeyboardLayout(width: 951, orientation: .splitLandscape, splitMirrored: true).keys)
    }

    func testOnlyTheSplitLettersPageGainsASlashKey() {
        func slashes(_ layout: KeyboardLayout) -> Int {
            layout.keys.filter { $0.character == "/" && $0.row != layout.bottomRowIndex }.count
        }
        XCTAssertEqual(slashes(KeyboardLayout(width: 951, orientation: .splitLandscape)), 1)
        XCTAssertEqual(slashes(KeyboardLayout(width: 951, orientation: .splitLandscape, field: .url)), 1)
        XCTAssertEqual(slashes(KeyboardLayout(width: 951, orientation: .wideLandscape)), 0)
        XCTAssertEqual(slashes(KeyboardLayout(width: 393)), 0)
        XCTAssertEqual(slashes(KeyboardLayout(width: 951, orientation: .splitLandscape, layer: .symbols)), 0)
    }

    func testLayoutsBesideTheSplitLettersKeepTheirFrames() {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { bytes in
                for byte in bytes { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
            }
        }
        var count = 0
        let widths: [(KeyboardOrientation, [CGFloat])] = [
            (.portrait, [320, 393, 440]), (.landscape, [852, 932]), (.widePortrait, [669]),
            (.wideLandscape, [801, 951]), (.splitLandscape, [801, 951]),
        ]
        for (orientation, orientationWidths) in widths {
            for width in orientationWidths {
                for layer in layers where orientation != .splitLandscape || layer != .letters {
                    for field in fields {
                        for numberRow in [false, true] {
                            for showsStrip in [false, true] {
                                for showsGlobe in [false, true] {
                                    for inset: CGFloat in [0, 30] {
                                        for periodKey in [false, true] {
                                            let layout = KeyboardLayout(
                                                width: width, orientation: orientation, layer: layer, field: field,
                                                showsGlobe: showsGlobe, bottomRow: BottomRow(periodKey: periodKey),
                                                numberRow: numberRow, horizontalInset: inset, showsStrip: showsStrip
                                            )
                                            for key in layout.keys {
                                                count += 1
                                                key.label.utf8.forEach(mix)
                                                for rect in [key.frame, key.hitFrame] {
                                                    for value in [rect.minX, rect.minY, rect.width, rect.height] {
                                                        mix(Int64((value * 1000).rounded()))
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(count, 93376)
        XCTAssertEqual(hash, 17_883_152_473_971_929_109)
    }

    func testLandscapeKeepsInsetsAndHeight() {
        let layout = KeyboardLayout(width: 932, orientation: .landscape, horizontalInset: 60)
        XCTAssertEqual(layout.totalHeight, 176)
        XCTAssertEqual(layout.key(.character("q"))!.frame.minX, 64, accuracy: 0.001)
        XCTAssertEqual(layout.key(.character("q"))!.hitFrame.minX, 0)
    }

    func testNumberRowPutsOneToZeroAboveTheLettersAndGrowsTheKeyboard() throws {
        for (orientation, width) in [(KeyboardOrientation.portrait, CGFloat(393)), (.landscape, 852)] {
            for showsStrip in [true, false] {
                let off = KeyboardLayout(width: width, orientation: orientation, showsStrip: showsStrip)
                let on = KeyboardLayout(width: width, orientation: orientation, numberRow: true, showsStrip: showsStrip)
                let context = "\(orientation) strip=\(showsStrip)"
                let grow = on.totalHeight - off.totalHeight
                XCTAssertEqual(grow, on.metrics.numberRowHeight + on.metrics.rowGap, context)
                XCTAssertGreaterThan(on.metrics.numberRowHeight, 0, context)
                XCTAssertLessThan(on.metrics.numberRowHeight, on.metrics.keyHeight, context)
                XCTAssertEqual(KeyboardLayout.height(for: orientation, showsStrip: showsStrip, numberRow: true), on.totalHeight, context)
                XCTAssertEqual(off.bottomRowIndex, 3, context)
                XCTAssertEqual(on.bottomRowIndex, 4, context)

                let digits = on.keys.filter { $0.row == 0 }
                XCTAssertEqual(digits.map(\.label), "1234567890".map(String.init), context)
                for (digit, letter) in zip(digits, "qwertyuiop") {
                    let below = try XCTUnwrap(on.key(.character(String(letter))))
                    XCTAssertEqual(digit.frame.minX, below.frame.minX, accuracy: 0.0001, context)
                    XCTAssertEqual(digit.frame.width, below.frame.width, accuracy: 0.0001, context)
                    XCTAssertLessThan(digit.frame.maxY, below.frame.minY, context)
                    XCTAssertEqual(on.hitTest(CGPoint(x: digit.frame.midX, y: digit.frame.midY)), digit, context)
                }
                XCTAssertEqual(on.keys.count, off.keys.count + 10, context)
                for key in off.keys {
                    let moved = try XCTUnwrap(on.keys.first { $0.kind == key.kind && $0.row == key.row + 1 }, "\(context) \(key.label)")
                    XCTAssertEqual(moved.frame, key.frame.offsetBy(dx: 0, dy: grow), "\(context) \(key.label)")
                }
            }
        }
    }

    func testWithTheNumberRowTheOtherPagesKeepTheHeightWithTallerKeys() throws {
        for orientation in [KeyboardOrientation.portrait, .landscape] {
            let width: CGFloat = orientation == .portrait ? 393 : 852
            let letters = KeyboardLayout(width: width, orientation: orientation, numberRow: true)
            for layer in [KeyboardLayer.numbers, .symbols] {
                let off = KeyboardLayout(width: width, orientation: orientation, layer: layer)
                let on = KeyboardLayout(width: width, orientation: orientation, layer: layer, numberRow: true)
                XCTAssertEqual(on.totalHeight, letters.totalHeight, "\(orientation) \(layer)")
                XCTAssertEqual(on.bottomRowIndex, 3)
                XCTAssertEqual(on.keys.count, off.keys.count)
                XCTAssertEqual(try XCTUnwrap(on.key(.space)).frame.maxY, try XCTUnwrap(letters.key(.space)).frame.maxY, accuracy: 0.0001)
                XCTAssertGreaterThan(try XCTUnwrap(on.key(.space)).frame.height, try XCTUnwrap(off.key(.space)).frame.height)
            }
        }
    }

    func testThePeriodKeyHoldsMorePunctuationBelowTheNumberRow() throws {
        let layout = KeyboardLayout(width: 393, bottomRow: BottomRow(periodKey: true), numberRow: true)
        XCTAssertTrue(layout.isPeriodKey(try XCTUnwrap(layout.key(.character(".")))))
    }

    // MARK: - Helpers

    private func landscapeLayouts() -> [KeyboardLayout] {
        [
            KeyboardLayout(width: 667, orientation: .landscape),
            KeyboardLayout(width: 852, orientation: .landscape, layer: .numbers),
            KeyboardLayout(width: 956, orientation: .landscape, field: .email, horizontalInset: 60),
        ]
    }

    /// The iPhone Duo's inner display: upright, and sideways in the 801 pt iOS gives a keyboard and across all 951 pt.
    private func wideLayouts() -> [KeyboardLayout] {
        [
            KeyboardLayout(width: 669, orientation: .widePortrait),
            KeyboardLayout(width: 669, orientation: .widePortrait, layer: .symbols, field: .url),
            KeyboardLayout(width: 801, orientation: .wideLandscape, layer: .numbers),
            KeyboardLayout(width: 951, orientation: .wideLandscape, field: .email),
            KeyboardLayout(width: 801, orientation: .splitLandscape),
            KeyboardLayout(width: 951, orientation: .splitLandscape, layer: .numbers, field: .url),
            KeyboardLayout(width: 951, orientation: .splitLandscape, layer: .symbols, field: .email),
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
        for base in everyPortraitLayout() + landscapeLayouts() + wideLayouts() {
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
                    let row = layout.keys.filter { $0.row == layout.bottomRowIndex }.sorted { $0.frame.minX < $1.frame.minX }
                    for (a, b) in zip(row, row.dropFirst()) {
                        XCTAssertLessThan(a.frame.maxX, b.frame.minX, name)
                        if layout.orientation == .splitLandscape, b.frame.minX - a.frame.maxX > layout.letterWidth { continue }
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
        layout.keys.filter { $0.row == layout.bottomRowIndex }.sorted { $0.frame.minX < $1.frame.minX }.map(\.kind)
    }

    private func describe(_ layout: KeyboardLayout) -> String {
        "\(layout.width)pt \(layout.orientation) \(layout.layer) \(layout.field) globe=\(layout.showsGlobe) \(layout.globeKey) \(layout.bottomRow) strip=\(layout.showsStrip) numbers=\(layout.numberRow)"
    }
}

@MainActor
final class FullKeyboardSettingsTests: XCTestCase {
    func testKeyboardSettingsDefaultRoundTripAndFallBack() throws {
        let suite = "FullKeyboardSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = FullKeyboardSettings(defaults: defaults)
        let fresh = { FullKeyboardSettings(defaults: defaults) }

        XCTAssertTrue(settings.autocorrect)
        XCTAssertTrue(settings.swipeTyping)
        XCTAssertFalse(settings.numberRow)
        XCTAssertFalse(settings.splitKeyboard)
        XCTAssertFalse(settings.splitColumns)
        XCTAssertFalse(settings.splitMirrored)
        XCTAssertEqual(settings.design, .standard)
        XCTAssertEqual(settings.bottomRow, BottomRow(order: [.space, .period, .typr], periodKey: false))

        settings.autocorrect = false
        settings.swipeTyping = false
        settings.numberRow = true
        settings.splitKeyboard = true
        settings.splitColumns = true
        settings.splitMirrored = true
        settings.design = .mechanical
        let arranged = BottomRow(order: [.typr, .space, .period], periodKey: true)
        settings.bottomRow = arranged
        XCTAssertFalse(fresh().autocorrect)
        XCTAssertFalse(fresh().swipeTyping)
        XCTAssertTrue(fresh().numberRow)
        XCTAssertTrue(fresh().splitKeyboard)
        XCTAssertTrue(fresh().splitColumns)
        XCTAssertTrue(fresh().splitMirrored)
        XCTAssertEqual(fresh().design, .mechanical)
        XCTAssertEqual(fresh().bottomRow, arranged)
        settings.numberRow = false
        settings.splitKeyboard = false
        settings.splitColumns = false
        settings.splitMirrored = false
        XCTAssertFalse(fresh().numberRow)
        XCTAssertFalse(fresh().splitKeyboard)
        XCTAssertFalse(fresh().splitColumns)
        XCTAssertFalse(fresh().splitMirrored)

        defaults.set("neon", forKey: "settings.keyboardDesign")
        defaults.set(["typr", "emoji"], forKey: "settings.keyboardBottomRowOrder")
        XCTAssertEqual(settings.design, .standard)
        XCTAssertEqual(settings.bottomRow.order, [.space, .period, .typr])
    }
}
