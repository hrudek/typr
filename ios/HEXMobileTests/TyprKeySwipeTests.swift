import CoreGraphics
import XCTest
@testable import HEX

final class TyprKeySwipeTests: XCTestCase {
    private func decide(_ dx: CGFloat, _ dy: CGFloat, state: HexKeyGesture.State = .pressing) -> TyprKeySwipe.Decision {
        var swipe = TyprKeySwipe()
        swipe.begin(at: CGPoint(x: 20, y: 20))
        return swipe.decide(at: CGPoint(x: 20 + dx, y: 20 + dy), state: state)
    }

    func testStraightDownClaims() {
        XCTAssertEqual(decide(0, 30), .claim)
        XCTAssertEqual(decide(0, TyprKeySwipe.minDistance), .claim)
    }

    func testSlightlyOffVerticalStillClaims() {
        XCTAssertEqual(decide(10, 30), .claim, "about 18 degrees")
        XCTAssertEqual(decide(-10, 30), .claim)
    }

    func testDownDiagonalOutsideTheWindowOpensTheMenu() {
        XCTAssertEqual(decide(30, 30), .upstream, "45 degrees")
        XCTAssertEqual(decide(-30, 30), .upstream)
        XCTAssertEqual(decide(20, 20 * 1.2), .upstream, "about 40 degrees")
    }

    func testLeftRightAndUpOpenTheMenu() {
        XCTAssertEqual(decide(-30, 0), .upstream)
        XCTAssertEqual(decide(30, 0), .upstream)
        XCTAssertEqual(decide(0, -30), .upstream)
        XCTAssertEqual(decide(5, -30), .upstream)
    }

    func testShortDownMovePastSlopWaitsWithoutOpeningTheMenu() {
        let short = HexKeyGesture.slop + 2
        XCTAssertLessThan(short, TyprKeySwipe.minDistance)
        XCTAssertEqual(decide(0, short), .wait)
    }

    func testMoveWithinSlopIsUpstreams() {
        XCTAssertEqual(decide(0, HexKeyGesture.slop - 1), .upstream)
        XCTAssertEqual(decide(0, 0), .upstream)
    }

    func testNothingIsClaimedOnceTheMenuOrHoldOwnsTheTouch() {
        XCTAssertEqual(decide(0, 40, state: .menu), .upstream, "dragging down onto menu rows still picks them")
        XCTAssertEqual(decide(0, 40, state: .fired), .upstream, "moves after a hold are ignored")
        XCTAssertEqual(decide(0, 40, state: .idle), .upstream)
    }
}

@MainActor
final class TyprKeyboardModeToggleTests: XCTestCase {
    func testFollowsTheSettingUntilSwiped() {
        let toggle = TyprKeyboardModeToggle()
        XCTAssertTrue(toggle.wantsFull(setting: true, hasFullAccess: true))
        XCTAssertFalse(toggle.wantsFull(setting: false, hasFullAccess: true))
        toggle.switchToMinimal()
        XCTAssertFalse(toggle.wantsFull(setting: true, hasFullAccess: true))
        toggle.switchToFull()
        XCTAssertTrue(toggle.wantsFull(setting: true, hasFullAccess: true))
    }

    func testWithoutFullAccessTheFullKeyboardStays() {
        let toggle = TyprKeyboardModeToggle()
        toggle.switchToMinimal()
        XCTAssertTrue(toggle.wantsFull(setting: true, hasFullAccess: false))
    }

    func testSettingOffStaysUpstreamWithNoExtraKey() {
        let toggle = TyprKeyboardModeToggle()
        XCTAssertFalse(toggle.forcesMinimal)
        XCTAssertFalse(toggle.wantsFull(setting: false, hasFullAccess: true))
    }

    func testResetOnAppearRestoresTheSetting() {
        let toggle = TyprKeyboardModeToggle()
        toggle.switchToMinimal()
        toggle.reset()
        XCTAssertFalse(toggle.forcesMinimal)
        XCTAssertTrue(toggle.wantsFull(setting: true, hasFullAccess: true))
    }

    func testChangeNotifiesOnceAndResetIsSilent() {
        let toggle = TyprKeyboardModeToggle()
        var changes = 0
        toggle.onChange = { changes += 1 }
        toggle.switchToMinimal()
        toggle.switchToMinimal()
        XCTAssertEqual(changes, 1)
        toggle.reset()
        XCTAssertEqual(changes, 1)
        toggle.switchToFull()
        XCTAssertEqual(changes, 1, "already full")
    }

    func testNeverWritesTheStoredSetting() {
        let before = FullKeyboardSettings().isEnabled
        let toggle = TyprKeyboardModeToggle()
        toggle.switchToMinimal()
        toggle.switchToFull()
        toggle.switchToMinimal()
        toggle.reset()
        XCTAssertEqual(FullKeyboardSettings().isEnabled, before)
    }
}
