import CoreGraphics
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

                let q = layout.key(.character("q"))!
                let p = layout.key(.character("p"))!
                XCTAssertEqual(q.frame.minX, layout.metrics.side, accuracy: 0.001, name)
                XCTAssertEqual(p.frame.maxX, width - layout.metrics.side, accuracy: 0.001, name)

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
                XCTAssertNotNil(layout.hitTest(CGPoint(x: width / 2, y: q.frame.midY)), "the gap still types: \(name)")
            }
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
