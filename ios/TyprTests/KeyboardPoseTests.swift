import CoreGraphics
import UIKit
import XCTest
@testable import Typr

/// The keyboard for each iPhone Duo pose, picked from the display's size: outer display 466 × 678 pt, inner
/// display 669 × 951 pt. Keyboard widths include what iOS gives a third-party keyboard there (452 outer upright,
/// 528 outer sideways, 801 inner sideways; iikb docs/design.md) and the whole display, as the settings preview uses.
final class KeyboardPoseTests: XCTestCase {
    private let outerPortrait = CGSize(width: 466, height: 678)
    private let outerLandscape = CGSize(width: 678, height: 466)
    private let innerPortrait = CGSize(width: 669, height: 951)
    private let innerLandscape = CGSize(width: 951, height: 669)

    func testTheDisplaySizeAlonePicksThePose() {
        XCTAssertEqual(KeyboardOrientation(container: outerPortrait), .portrait)
        XCTAssertEqual(KeyboardOrientation(container: outerLandscape), .landscape)
        XCTAssertEqual(KeyboardOrientation(container: innerPortrait), .widePortrait)
        XCTAssertEqual(KeyboardOrientation(container: innerLandscape), .wideLandscape)
        for phone in [CGSize(width: 375, height: 667), CGSize(width: 393, height: 852), CGSize(width: 440, height: 956)] {
            XCTAssertEqual(KeyboardOrientation(container: phone), .portrait, "\(phone)")
            XCTAssertEqual(KeyboardOrientation(container: CGSize(width: phone.height, height: phone.width)), .landscape)
        }
    }

    func testTheOuterDisplayKeepsTodaysIPhoneKeyboard() {
        for width: CGFloat in [452, 466] {
            let layout = KeyboardLayout(width: width, orientation: KeyboardOrientation(container: outerPortrait))
            XCTAssertEqual(layout.metrics, KeyboardLayout(width: 440).metrics, "width \(width)")
            XCTAssertEqual(layout.totalHeight, KeyboardLayout.height(for: .portrait))
        }
        for width: CGFloat in [528, 678] {
            let layout = KeyboardLayout(width: width, orientation: KeyboardOrientation(container: outerLandscape))
            XCTAssertEqual(layout.metrics, KeyboardMetrics.landscape, "width \(width)")
            XCTAssertEqual(layout.totalHeight, KeyboardLayout.height(for: .landscape))
        }
    }

    func testInnerPortraitLeavesTheTextVisibleWithKeysInTheNorm() {
        let orientation = KeyboardOrientation(container: innerPortrait)
        for layout in variants(width: innerPortrait.width, orientation: orientation) {
            XCTAssertLessThanOrEqual(layout.totalHeight, 0.36 * innerPortrait.height, describe(layout))
            assertKeysInTheNorm(layout)
            XCTAssertNotNil(layout.balloon(for: layout.key(.character("g"))!), describe(layout))
        }
        XCTAssertGreaterThan(KeyboardLayout(width: 669, orientation: orientation).letterWidth, KeyboardLayout(width: 440).letterWidth)
    }

    func testInnerLandscapeFullLeavesTheTextVisibleWithKeysCentred() {
        let orientation = KeyboardOrientation(container: innerLandscape)
        for width: CGFloat in [801, innerLandscape.width] {
            for layout in variants(width: width, orientation: orientation) {
                XCTAssertLessThanOrEqual(layout.totalHeight, 0.45 * innerLandscape.height, describe(layout))
                assertKeysInTheNorm(layout)
                XCTAssertEqual(layout.letterWidth, KeyboardMetrics.maxWideLetterWidth, accuracy: 0.001, describe(layout))
                let q = layout.key(.character("q"))!
                let p = layout.key(.character("p"))!
                XCTAssertEqual(q.frame.minX, layout.width - p.frame.maxX, accuracy: 0.001, describe(layout))
                XCTAssertGreaterThan(q.frame.minX, KeyboardMetrics.wideLandscape.side, describe(layout))
                XCTAssertEqual(q.hitFrame.minX, 0, "the side padding still types q")
                XCTAssertEqual(layout.key(.returnKey)!.frame.maxX, p.frame.maxX, accuracy: 0.001, describe(layout))
            }
        }
    }

    func testWideLayoutsRoundTripThroughTheTypingLogAndLearning() {
        for layout in [
            KeyboardLayout(width: 669, orientation: .widePortrait),
            KeyboardLayout(width: 801, orientation: .wideLandscape, numberRow: true),
            KeyboardLayout(width: 801, orientation: .splitLandscape),
        ] {
            XCTAssertEqual(TypingLogLayout(layout).keyboardLayout, layout)
            XCTAssertEqual(KeyboardLayoutSignature(layout).orientation, layout.orientation.rawValue)
            XCTAssertNotEqual(KeyboardLayoutSignature(layout), KeyboardLayoutSignature(KeyboardLayout(width: layout.width)))
        }
    }

    func testTheSplitSettingOnlySplitsTheOpenDuoSideways() {
        XCTAssertEqual(KeyboardOrientation(container: innerLandscape, split: true), .splitLandscape)
        XCTAssertEqual(KeyboardOrientation(container: innerLandscape, split: false), .wideLandscape)
        for display in [outerPortrait, outerLandscape, innerPortrait, CGSize(width: 852, height: 393)] {
            XCTAssertEqual(KeyboardOrientation(container: display, split: true), KeyboardOrientation(container: display))
        }
        XCTAssertTrue(KeyboardOrientation.splitLandscape.isLandscape)
        XCTAssertFalse(KeyboardOrientation.splitLandscape.allowsSplit)
    }

    func testSplitHalvesSitAtTheEdgesWithTheFoldBetween() {
        let left = Set("qwertasdfgzxcvb".map(String.init))
        let right = Set("yuiophjklnm".map(String.init))
        let phoneLetter = KeyboardLayout(width: outerPortrait.width).letterWidth
        for width: CGFloat in [801, innerLandscape.width] {
            for layout in variants(width: width, orientation: .splitLandscape) {
                let name = describe(layout)
                let full = KeyboardLayout(width: width, orientation: .wideLandscape,
                                          numberRow: layout.numberRow, showsStrip: layout.showsStrip)
                XCTAssertLessThanOrEqual(layout.totalHeight, full.totalHeight, name)
                XCTAssertGreaterThanOrEqual(layout.letterWidth, phoneLetter, name)
                XCTAssertLessThanOrEqual(layout.letterWidth, KeyboardMetrics.maxWideLetterWidth, name)
                assertKeysInTheNorm(layout)

                XCTAssertEqual(layout.key(.shift)!.frame.minX, layout.metrics.side, accuracy: 0.001, name)
                XCTAssertEqual(layout.key(.delete)!.frame.maxX, width - layout.metrics.side, accuracy: 0.001, name)

                let leftKeys = layout.keys.filter { $0.frame.midX < width / 2 }
                let rightKeys = layout.keys.filter { $0.frame.midX > width / 2 }
                XCTAssertEqual(Set(leftKeys.compactMap(\.character)).intersection(left.union(right)), left, name)
                XCTAssertEqual(Set(rightKeys.compactMap(\.character)).intersection(left.union(right)), right, name)
                XCTAssertTrue(layout.keys.allSatisfy { $0.frame.maxX < width / 2 || $0.frame.minX > width / 2 },
                              "no key crosses the middle: \(name)")
                XCTAssertLessThanOrEqual(leftKeys.map(\.frame.maxX).max()!, 0.4 * width + 0.001, name)
                XCTAssertLessThanOrEqual(width - rightKeys.map(\.frame.minX).min()!, 0.4 * width + 0.001, name)

                XCTAssertEqual(leftKeys.filter { $0.kind == .space }.count, 1, name)
                XCTAssertEqual(rightKeys.filter { $0.kind == .space }.count, 1, name)
                for kind in [KeyKind.shift, .layerSwitch(.numbers), .globe] {
                    XCTAssertTrue(leftKeys.contains { $0.kind == kind }, "\(kind) on the left: \(name)")
                }
                for kind in [KeyKind.delete, .returnKey, .typr] {
                    XCTAssertTrue(rightKeys.contains { $0.kind == kind }, "\(kind) on the right: \(name)")
                }
                for key in layout.keys {
                    XCTAssertEqual(layout.hitTest(CGPoint(x: key.frame.midX, y: key.frame.midY)), key, name)
                }
                assertTheGapTypesNothingPastHalfAKey(layout)
            }
        }
    }

    func testTheSplitGapTypesNothingPastHalfAKeyOnEveryLayer() {
        for width: CGFloat in [801, innerLandscape.width] {
            for layer in [KeyboardLayer.numbers, .symbols] {
                for field in [KeyboardFieldKind.text, .url, .email] {
                    for showsStrip in [true, false] {
                        assertTheGapTypesNothingPastHalfAKey(KeyboardLayout(
                            width: width, orientation: .splitLandscape, layer: layer, field: field,
                            showsGlobe: true, showsStrip: showsStrip
                        ))
                    }
                }
            }
        }
    }

    func testTheJoinedSpaceAndTyprKeycapTakesOnlyTheRightSpaceBarWhenSplit() throws {
        for width: CGFloat in [801, innerLandscape.width] {
            let layout = KeyboardLayout(width: width, orientation: .splitLandscape)
            let spaces = layout.keys.filter { $0.kind == .space }.sorted { $0.frame.minX < $1.frame.minX }
            XCTAssertEqual(spaces.count, 2)
            let joined = try XCTUnwrap(JoinedSpaceKeycap(layout: layout))
            XCTAssertEqual(joined.space, spaces[1].frame, "width \(width)")
            XCTAssertNotEqual(joined.space, spaces[0].frame, "the left space bar keeps its own keycap")
        }
    }

    func testTheOuterDisplayKeepsTodaysIPhoneGlyphs() {
        XCTAssertEqual(KeyboardOrientation(container: outerPortrait).glyphs, KeyGlyphSizes(
            letter: 22.5, capital: 21, widePunctuation: 21, letterLift: 1,
            symbol: 18, returnSymbol: 17.5, label: 15.5, balloonLetter: 33
        ))
        XCTAssertEqual(KeyboardOrientation(container: outerLandscape).glyphs, KeyGlyphSizes(
            letter: 19, capital: 18, widePunctuation: 19, letterLift: 0.5,
            symbol: 16, returnSymbol: 15.5, label: 14.5, balloonLetter: 33
        ))
    }

    func testInnerDisplayGlyphsGrowWithTheKeysAsApplesDo() {
        let phone = KeyboardOrientation.portrait.glyphs
        let inner: [(KeyboardOrientation, ClosedRange<CGFloat>)] = [
            (KeyboardOrientation(container: innerPortrait), 27...28),
            (KeyboardOrientation(container: innerLandscape), 27.5...28.5),
            (KeyboardOrientation(container: innerLandscape, split: true), 27.5...28.5),
        ]
        for (orientation, apple) in inner {
            let glyphs = orientation.glyphs
            XCTAssertTrue(apple.contains(glyphs.letter), "\(orientation) letters \(glyphs.letter)")
            for (size, phoneSize) in [
                (glyphs.capital, phone.capital), (glyphs.widePunctuation, phone.widePunctuation),
                (glyphs.symbol, phone.symbol), (glyphs.returnSymbol, phone.returnSymbol), (glyphs.label, phone.label),
            ] {
                XCTAssertGreaterThan(size, phoneSize, "\(orientation)")
                XCTAssertEqual(size / phoneSize, glyphs.letter / phone.letter, accuracy: 0.05, "\(orientation)")
            }
        }
        XCTAssertEqual(KeyboardOrientation.splitLandscape.glyphs, KeyboardOrientation.wideLandscape.glyphs)
    }

    func testInnerDisplayGlyphsFitTheirKeys() {
        let layouts = [
            KeyboardLayout(width: innerPortrait.width, orientation: .widePortrait),
            KeyboardLayout(width: 801, orientation: .wideLandscape),
            KeyboardLayout(width: 801, orientation: .splitLandscape),
        ]
        for layout in layouts {
            let glyphs = layout.orientation.glyphs
            let key = layout.key(.character("w"))!.frame
            let capital = ("W" as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: glyphs.capital)])
            XCTAssertLessThan(capital.width, key.width - 8, describe(layout))
            XCTAssertLessThan(capital.height, key.height, describe(layout))
            let balloon = ("W" as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: glyphs.balloonLetter, weight: .light)])
            XCTAssertLessThanOrEqual(balloon.height, KeyBalloon.bubbleHeight, describe(layout))
        }
    }

    /// The keyboard extension and the settings preview both hand `FullKeyboardView` a display size.
    @MainActor
    func testTheKeyboardViewTakesItsGeometryFromTheDisplaySize() {
        let poses: [(CGSize, KeyboardOrientation)] = [
            (outerPortrait, .portrait), (outerLandscape, .landscape),
            (innerPortrait, .widePortrait), (innerLandscape, .wideLandscape),
        ]
        for (display, orientation) in poses {
            let view = KeyboardAppearancePreview.makeKeyboard(KeyboardAppearancePreview.Settings(
                design: .standard, showsSuggestionBar: true, globeKey: .switches,
                bottomRow: BottomRow(), numberRow: false, isDark: false, container: display
            ))
            XCTAssertEqual(view.orientation, orientation, "\(display)")
            XCTAssertEqual(view.preferredHeight, KeyboardLayout.height(for: orientation), "\(display)")
            view.frame = CGRect(x: 0, y: 0, width: display.width, height: view.preferredHeight)
            view.layoutIfNeeded()
            XCTAssertEqual(view.engine.layout.orientation, orientation, "\(display)")
        }
    }

    private func assertTheGapTypesNothingPastHalfAKey(_ layout: KeyboardLayout, file: StaticString = #filePath, line: UInt = #line) {
        let name = describe(layout)
        let reach = layout.letterWidth / 2
        for row in 0...layout.bottomRowIndex {
            let keys = layout.keys.filter { $0.row == row }.sorted { $0.frame.minX < $1.frame.minX }
            let leftHalf = keys.filter { $0.frame.maxX < layout.width / 2 }
            let rightHalf = keys.filter { $0.frame.minX > layout.width / 2 }
            for half in [leftHalf, rightHalf] {
                for (a, b) in zip(half, half.dropFirst()) {
                    XCTAssertEqual(a.hitFrame.maxX, b.hitFrame.minX, accuracy: 0.0001, "row \(row) tiles: \(name)", file: file, line: line)
                }
            }
            let inner = (leftHalf.last!, rightHalf.first!)
            let y = inner.0.frame.midY
            XCTAssertEqual(layout.hitTest(CGPoint(x: inner.0.frame.maxX + reach - 0.5, y: y)), inner.0, name, file: file, line: line)
            XCTAssertEqual(layout.hitTest(CGPoint(x: inner.1.frame.minX - reach + 0.5, y: y)), inner.1, name, file: file, line: line)
            XCTAssertNil(layout.hitTest(CGPoint(x: inner.0.frame.maxX + reach + 0.5, y: y)), "row \(row): \(name)", file: file, line: line)
            XCTAssertNil(layout.hitTest(CGPoint(x: inner.1.frame.minX - reach - 0.5, y: y)), "row \(row): \(name)", file: file, line: line)
            XCTAssertNil(layout.hitTest(CGPoint(x: layout.width / 2, y: y)), "row \(row): \(name)", file: file, line: line)
        }
    }

    private func variants(width: CGFloat, orientation: KeyboardOrientation) -> [KeyboardLayout] {
        [true, false].flatMap { showsStrip in
            [false, true].map { numberRow in
                KeyboardLayout(width: width, orientation: orientation, showsGlobe: true, numberRow: numberRow, showsStrip: showsStrip)
            }
        }
    }

    /// Letters at least as easy to hit as on an iPhone, at most about an iPad's, and Apple's 44 pt tall targets.
    private func assertKeysInTheNorm(_ layout: KeyboardLayout, file: StaticString = #filePath, line: UInt = #line) {
        let g = layout.key(.character("g"))!
        XCTAssertGreaterThanOrEqual(g.hitFrame.width, 30, describe(layout), file: file, line: line)
        XCTAssertLessThanOrEqual(g.frame.width, 60, describe(layout), file: file, line: line)
        XCTAssertGreaterThanOrEqual(g.hitFrame.height, 44, describe(layout), file: file, line: line)
    }

    private func describe(_ layout: KeyboardLayout) -> String {
        "\(layout.width)pt \(layout.orientation) strip=\(layout.showsStrip) numbers=\(layout.numberRow)"
    }
}
