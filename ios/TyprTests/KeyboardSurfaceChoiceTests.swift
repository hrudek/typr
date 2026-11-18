import CoreGraphics
import XCTest
@testable import Typr

/// Typr: switching between the full keyboard and the compact dictation bar.
@MainActor
final class KeyboardSurfaceChoiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "KeyboardSurfaceChoiceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    // MARK: - Full keyboard

    func testBottomRowHasNoSeparateSwitchKey() {
        for globe in [false, true] {
            for field in [KeyboardFieldKind.text, .url, .email] {
                let layout = KeyboardLayout(width: 393, field: field, showsGlobe: globe)
                let bottom = layout.keys.filter { $0.row == 3 }.sorted { $0.frame.minX < $1.frame.minX }
                XCTAssertEqual(bottom.first?.kind, .layerSwitch(.numbers), "123 leads the row again")
                XCTAssertNotNil(layout.key(.typr))
            }
        }
    }

    func testFullKeyboardViewAllowsCompactBarOnTheTyprKey() {
        let view = FullKeyboardView(model: KeyboardViewModel(), target: FixtureTextTarget(),
            autocorrect: AutocorrectEngine(spatialDecoder: nil))
        XCTAssertFalse(view.allowsCompactBar, "off unless the controller turns it on")
        view.allowsCompactBar = true
        XCTAssertTrue(view.allowsCompactBar)
    }

    // MARK: - Settings and choice

    func testChoiceDefaultsToFullKeyboardAndPersists() {
        let choice = KeyboardSurfaceChoice(defaults: defaults)
        XCTAssertFalse(choice.showsCompactBar)
        choice.showsCompactBar = true
        XCTAssertTrue(KeyboardSurfaceChoice(defaults: defaults).showsCompactBar)
    }

    func testWhichKeyboardMounts() {
        typealias Choice = KeyboardSurfaceChoice
        // A persisted, retired switch value must no longer disable switching.
        defaults.set(false, forKey: "typr.keyboardSwitchKey")
        XCTAssertTrue(Choice.wantsFullKeyboard(isPhone: true, compactChosen: false))
        XCTAssertFalse(Choice.wantsFullKeyboard(isPhone: true, compactChosen: true))
        XCTAssertFalse(Choice.wantsFullKeyboard(isPhone: false, compactChosen: false), "iPad keeps the dictation bar")
        XCTAssertFalse(Choice.wantsFullKeyboard(isPhone: false, compactChosen: true))
    }
}
