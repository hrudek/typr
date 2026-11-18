import SwiftUI
import UIKit
import XCTest
@testable import Typr

@MainActor
final class KeyboardAppearanceTests: XCTestCase {
    private var base: KeyboardAppearancePreview.Settings {
        KeyboardAppearancePreview.Settings(
            design: .standard, showsSuggestionBar: true, globeKey: .switches,
            bottomRow: BottomRow(), isDark: false, orientation: .portrait
        )
    }

    func testAppearanceScenesOpenTheAppearancePage() {
        for (scene, isDark) in [("settings-keyboard-appearance", nil),
                                ("settings-keyboard-appearance-light", false),
                                ("settings-keyboard-appearance-dark", true)] as [(String, Bool?)] {
            let arguments = ["Typr", "--snap-state", scene]
            XCTAssertEqual(SettingsDestination.snapshotDestination(arguments: arguments), .keyboardAppearance, scene)
            XCTAssertEqual(KeyboardAppearancePage.snapshotIsDark(arguments: arguments), isDark, scene)
        }
        XCTAssertEqual(SettingsDestination.keyboardAppearance.title, "Appearance")
    }

    func testHubLinkSummarizesDesignAndPeriodKey() {
        XCTAssertEqual(KeyboardAppearancePage.summary(design: .standard, periodKey: false), "Default · Period off")
        XCTAssertEqual(KeyboardAppearancePage.summary(design: .mechanical, periodKey: true), "Mechanical · Period on")
    }

    func testPageShowsPreviewAndEveryAppearanceControl() async throws {
        let host = UIHostingController(rootView: NavigationStack { KeyboardAppearancePage() })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 1_600))
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await waitForState("the page mounts its preview") {
            host.view.layoutIfNeeded()
            return Self.subviews(of: host.view).contains { $0 is FullKeyboardView }
        }
        let views = Self.subviews(of: host.view)
        let previews = views.compactMap { $0 as? FullKeyboardView }
        XCTAssertEqual(previews.count, 1)
        XCTAssertEqual(previews.first?.isUserInteractionEnabled, false)
        let design = views.compactMap { $0 as? UISegmentedControl }
        XCTAssertEqual(design.count, 1)
        XCTAssertEqual(design.first?.numberOfSegments, KeyboardDesign.allCases.count)
        XCTAssertEqual(views.filter { $0 is UISwitch }.count, 2)
    }

    func testPreviewIsDockedFullWidthAtTheBottomAndScrollEndsAboveIt() async throws {
        try await assertDocked(in: CGRect(x: 0, y: 0, width: 393, height: 852))
    }

    func testScaledCompactPreviewStaysOnScreenFlushWithTheBottom() async throws {
        try await assertDocked(in: CGRect(x: 0, y: 0, width: 852, height: 300))
    }

    private func assertDocked(in bounds: CGRect) async throws {
        let host = UIHostingController(rootView: NavigationStack { KeyboardAppearancePage() })
        let window = UIWindow(frame: bounds)
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await waitForState("the page mounts its preview") {
            host.view.layoutIfNeeded()
            return Self.subviews(of: host.view).contains { $0 is FullKeyboardView }
        }
        let views = Self.subviews(of: host.view)
        let keyboard = try XCTUnwrap(views.compactMap { $0 as? FullKeyboardView }.first)
        let frame = keyboard.convert(keyboard.bounds, to: window)
        XCTAssertGreaterThanOrEqual(frame.minY, -1)
        XCTAssertEqual(frame.minX, 0, accuracy: 0.5)
        XCTAssertEqual(frame.width, window.bounds.width, accuracy: 0.5)
        XCTAssertEqual(frame.maxY, window.bounds.height - window.safeAreaInsets.bottom, accuracy: 1)
        let scroll = try XCTUnwrap(views.compactMap { $0 as? UIScrollView }.first { $0.bounds.height > 300 })
        let visibleBottom = scroll.convert(scroll.bounds, to: window).maxY - scroll.adjustedContentInset.bottom
        XCTAssertLessThanOrEqual(visibleBottom, frame.minY + 1)
    }

    func testPreviewDrawsEveryAppearanceSetting() async throws {
        let view = KeyboardAppearancePreview.makeKeyboard(base)
        view.frame = CGRect(x: 0, y: 0, width: 393, height: view.preferredHeight)
        view.layoutIfNeeded()
        XCTAssertEqual(view.design, .standard)
        XCTAssertEqual(view.preferredHeight, KeyboardLayout.height(for: .portrait, showsStrip: true))
        XCTAssertNotNil(view.engine.layout.key(.globe))
        XCTAssertNil(view.engine.layout.key(.character(".")))

        var settings = base
        settings.design = .mechanical
        settings.showsSuggestionBar = false
        settings.globeKey = .spacer
        settings.bottomRow = BottomRow(order: [.typr, .period, .space], periodKey: true)
        KeyboardAppearancePreview.apply(settings, to: view)
        XCTAssertEqual(view.design, .mechanical)
        XCTAssertEqual(view.preferredHeight, KeyboardLayout.height(for: .portrait, showsStrip: false))
        let bottomRow = settings.bottomRow
        try await waitForState("the preview's keys follow the bottom row") {
            view.engine.bottomRow == bottomRow && view.engine.globeKey == .spacer
        }
        let layout = view.engine.layout
        XCTAssertNotNil(layout.key(.globeSpacer))
        XCTAssertNil(layout.key(.globe))
        let x = { (kind: KeyKind) in layout.key(kind)?.frame.minX ?? -1 }
        XCTAssertLessThan(x(.typr), x(.character(".")))
        XCTAssertLessThan(x(.character(".")), x(.space))

        settings.globeKey = .hidden
        KeyboardAppearancePreview.apply(settings, to: view)
        try await waitForState("the preview hides the globe") { view.engine.globeKey == .hidden }
        XCTAssertNil(view.engine.layout.key(.globe))
        XCTAssertNil(view.engine.layout.key(.globeSpacer))
    }

    func testPreviewNeitherSuggestsNorWritesSettings() {
        let defaults = UserDefaults(suiteName: KeyboardBridge.appGroup)
        let before = defaults.map { $0.dictionaryRepresentation() as NSDictionary }
        var settings = base
        let view = KeyboardAppearancePreview.makeKeyboard(settings)
        settings.design = .mechanical
        settings.bottomRow.periodKey = true
        KeyboardAppearancePreview.apply(settings, to: view)
        XCTAssertFalse(view.engine.suggestionsAreActive)
        XCTAssertFalse(view.isUserInteractionEnabled)
        XCTAssertEqual(defaults.map { $0.dictionaryRepresentation() as NSDictionary }, before)

        let normal = FullKeyboardView(model: KeyboardViewModel(), target: KeyboardPreviewTextTarget(),
                                      autocorrect: AutocorrectEngine(spatialDecoder: nil))
        XCTAssertTrue(normal.engine.suggestionsAreActive, "without a preview the keyboard suggests as before")
    }

    func testPreviewTargetIgnoresEdits() {
        let target = KeyboardPreviewTextTarget()
        target.insertText("typr")
        target.deleteBackward()
        target.adjustTextPosition(byCharacterOffset: -1)
        XCTAssertFalse(target.hasText)
        XCTAssertNil(target.documentContextBeforeInput)
        XCTAssertEqual(target.autocapitalizationType, .sentences)
        XCTAssertEqual(target.keyboardType, .default)
    }

    private static func subviews(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap(subviews(of:))
    }
}
