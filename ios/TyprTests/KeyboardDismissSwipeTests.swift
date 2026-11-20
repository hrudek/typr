import CoreGraphics
import XCTest
@testable import Typr

@MainActor
final class KeyboardDismissSwipeTests: XCTestCase {
    func testOnlyAClearDownwardSwipeDismisses() {
        XCTAssertTrue(KeyboardDismissSwipe.dismisses(translation: CGSize(width: 0, height: 40)))
        XCTAssertTrue(KeyboardDismissSwipe.dismisses(translation: CGSize(width: -30, height: 60)))
        XCTAssertFalse(KeyboardDismissSwipe.dismisses(translation: CGSize(width: 0, height: 39)), "too short")
        XCTAssertFalse(KeyboardDismissSwipe.dismisses(translation: CGSize(width: 0, height: -80)), "upward")
        XCTAssertFalse(KeyboardDismissSwipe.dismisses(translation: CGSize(width: 31, height: 60)), "too diagonal")
        XCTAssertFalse(KeyboardDismissSwipe.dismisses(translation: CGSize(width: 120, height: 0)), "sideways")
    }

    func testFullKeyboardStartsOnlyOffKeys() {
        let view = makeKeyboard(orientation: .portrait, width: 393)
        let layout = view.engine.layout
        let belowStrip = CGPoint(x: layout.width / 2, y: layout.stripFrame.maxY + layout.metrics.stripBottom / 2)
        XCTAssertTrue(view.startsDismissSwipe(at: belowStrip), "between the strip and the keys")

        for kind in [KeyKind.delete, .space, .shift, .returnKey, .typr] {
            guard let key = layout.key(kind) else { XCTFail("no \(kind) key"); continue }
            XCTAssertFalse(view.startsDismissSwipe(at: key.hitFrame.center), "\(kind)")
        }
        guard let letter = layout.keys.first(where: { $0.character != nil }) else { return XCTFail("no letter key") }
        XCTAssertFalse(view.startsDismissSwipe(at: letter.hitFrame.center))
        let gap = CGPoint(x: letter.frame.maxX + 1, y: letter.frame.midY)
        XCTAssertFalse(view.startsDismissSwipe(at: gap), "gaps between keys type the nearer key")
    }

    func testFullKeyboardSplitGapStartsDismissSwipe() {
        let view = makeKeyboard(orientation: .splitLandscape, width: 951)
        let layout = view.engine.layout
        let middle = CGPoint(x: layout.width / 2, y: layout.keysAreaFrame.minY + layout.keysAreaFrame.height / 3)
        XCTAssertNil(layout.hitTest(middle), "precondition: the split gap types nothing")
        XCTAssertTrue(view.startsDismissSwipe(at: middle))
    }

    func testFullKeyboardIgnoresTheSwipeWhileSwipeTypingIsOn() {
        let view = makeKeyboard(orientation: .portrait, width: 393)
        view.engine.swipeTypingEnabled = true
        let layout = view.engine.layout
        let belowStrip = CGPoint(x: layout.width / 2, y: layout.stripFrame.maxY + layout.metrics.stripBottom / 2)
        XCTAssertFalse(view.startsDismissSwipe(at: belowStrip))
    }

    private func makeKeyboard(orientation: KeyboardOrientation, width: CGFloat) -> FullKeyboardView {
        let view = FullKeyboardView(model: KeyboardViewModel(), target: FixtureTextTarget(),
            autocorrect: AutocorrectEngine(spatialDecoder: nil))
        view.suggestionBarOverride = true
        view.orientationOverride = orientation
        view.engine.swipeTypingEnabled = false
        view.frame = CGRect(x: 0, y: 0, width: width, height: view.preferredHeight)
        view.layoutIfNeeded()
        return view
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
