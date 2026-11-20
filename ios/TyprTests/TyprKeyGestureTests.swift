import CoreGraphics
import XCTest
@testable import Typr

final class TyprKeyGestureTests: XCTestCase {
    func testTapTypesSpace() {
        var gesture = TyprKeyGesture()
        gesture.touchDown(at: .zero)
        XCTAssertEqual(gesture.touchMoved(to: CGPoint(x: 3, y: 2)), .ignored, "a jitter is still a tap")
        XCTAssertEqual(gesture.touchUp(), .tap)
        XCTAssertEqual(gesture.holdElapsed(), .ignored, "a timer left over from the tap")
        XCTAssertEqual(gesture.state, .idle)
    }

    func testStillHoldFiresOnceAndNoSpace() {
        var gesture = TyprKeyGesture()
        gesture.touchDown(at: .zero)
        XCTAssertEqual(gesture.holdElapsed(), .hold)
        XCTAssertEqual(gesture.holdElapsed(), .ignored)
        XCTAssertEqual(gesture.touchUp(), .ignored, "a hold never types a space")
    }

    func testSlideUpOpensMenu() {
        var gesture = TyprKeyGesture()
        gesture.touchDown(at: CGPoint(x: 20, y: 20))
        XCTAssertEqual(gesture.touchMoved(to: CGPoint(x: 20, y: -40), allowsCompactBar: true), .openMenu)
        XCTAssertEqual(gesture.holdElapsed(), .ignored, "the menu won, no dictation")
        XCTAssertEqual(gesture.touchMoved(to: CGPoint(x: 0, y: 40), allowsCompactBar: true), .dragMenu,
                       "once open, moving down drags in the menu")
        XCTAssertEqual(gesture.touchUp(), .releaseMenu)
        XCTAssertEqual(gesture.state, .idle)
    }

    func testSlideDownShowsCompactBar() {
        var gesture = TyprKeyGesture()
        gesture.touchDown(at: CGPoint(x: 20, y: 20))
        XCTAssertEqual(gesture.touchMoved(to: CGPoint(x: 20, y: 50), allowsCompactBar: true), .showCompactBar)
        XCTAssertEqual(gesture.holdElapsed(), .ignored, "no dictation")
        XCTAssertEqual(gesture.touchMoved(to: CGPoint(x: 24, y: 60), allowsCompactBar: true), .ignored)
        XCTAssertEqual(gesture.touchUp(), .ignored, "no space, no menu")
        XCTAssertEqual(gesture.state, .idle)
    }

    func testDownwardThresholdIs30Points() {
        for dx: CGFloat in [-18, 0, 18] {
            var gesture = TyprKeyGesture()
            gesture.touchDown(at: .zero)
            // A 3:4:5 diagonal also measures distance from touch-down.
            let dy: CGFloat = dx == 0 ? 30 : 24
            XCTAssertEqual(gesture.touchMoved(to: CGPoint(x: dx * 0.99, y: dy * 0.99),
                                              allowsCompactBar: true), .ignored)
            XCTAssertEqual(gesture.touchMoved(to: CGPoint(x: dx, y: dy),
                                              allowsCompactBar: true),
                           .showCompactBar)
        }
    }

    func testAllOtherDirectionsRequire60Points() {
        let directions: [CGPoint] = [
            CGPoint(x: 0, y: -60), CGPoint(x: -60, y: 0), CGPoint(x: 60, y: 0),
            CGPoint(x: -36, y: -48), CGPoint(x: 36, y: -48),
            CGPoint(x: -48, y: 36), CGPoint(x: 48, y: 36)
        ]
        for end in directions {
            var gesture = TyprKeyGesture()
            gesture.touchDown(at: .zero)
            XCTAssertEqual(gesture.touchMoved(to: CGPoint(x: end.x * 0.99, y: end.y * 0.99),
                                              allowsCompactBar: true), .ignored)
            XCTAssertEqual(gesture.touchMoved(to: end, allowsCompactBar: true), .openMenu)
            XCTAssertEqual(gesture.touchUp(), .releaseMenu)
        }
    }

    func testSubthresholdMovementStillTypesSpace() {
        for end in [CGPoint(x: 59, y: 0), CGPoint(x: 0, y: -59), CGPoint(x: 0, y: 29)] {
            var gesture = TyprKeyGesture()
            gesture.touchDown(at: .zero)
            XCTAssertEqual(gesture.touchMoved(to: end, allowsCompactBar: true), .ignored)
            XCTAssertEqual(gesture.touchUp(), .tap)
        }
    }

    func testDownwardMovementWithoutCompactBarRequires60Points() {
        var gesture = TyprKeyGesture()
        gesture.touchDown(at: .zero)
        XCTAssertEqual(gesture.touchMoved(to: CGPoint(x: 0, y: 30)), .ignored)
        XCTAssertEqual(gesture.touchMoved(to: CGPoint(x: 0, y: 59)), .ignored)
        XCTAssertEqual(gesture.touchMoved(to: CGPoint(x: 0, y: 60)), .openMenu)
    }

    func testSubthresholdMovementPreservesHold() {
        var gesture = TyprKeyGesture()
        gesture.touchDown(at: .zero)
        XCTAssertEqual(gesture.touchMoved(to: CGPoint(x: 0, y: -59),
                                          allowsCompactBar: true), .ignored)
        XCTAssertEqual(gesture.holdElapsed(), .hold)
        XCTAssertEqual(gesture.touchUp(), .ignored)
    }

    func testMoveAfterHoldDoesNothing() {
        var gesture = TyprKeyGesture()
        gesture.touchDown(at: .zero)
        XCTAssertEqual(gesture.holdElapsed(), .hold)
        XCTAssertEqual(gesture.touchMoved(to: CGPoint(x: 0, y: -80), allowsCompactBar: true), .ignored)
        XCTAssertEqual(gesture.touchMoved(to: CGPoint(x: 0, y: 80), allowsCompactBar: true), .ignored)
        XCTAssertEqual(gesture.touchUp(), .ignored)
    }

    func testCancelResets() {
        var gesture = TyprKeyGesture()
        gesture.touchDown(at: .zero)
        gesture.cancel()
        XCTAssertEqual(gesture.state, .idle)
        XCTAssertEqual(gesture.holdElapsed(), .ignored)
        XCTAssertEqual(gesture.touchMoved(to: CGPoint(x: 50, y: 0)), .ignored)
        XCTAssertEqual(gesture.touchUp(), .ignored, "a cancelled press types no space")
    }
}
