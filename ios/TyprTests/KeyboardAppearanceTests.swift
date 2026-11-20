import SwiftUI
import UIKit
import XCTest
@testable import Typr

@MainActor
final class KeyboardAppearanceTests: XCTestCase {
    private var base: KeyboardAppearancePreview.Settings {
        KeyboardAppearancePreview.Settings(
            design: .standard, showsSuggestionBar: true, globeKey: .switches,
            bottomRow: BottomRow(), numberRow: false, isDark: false, container: CGSize(width: 393, height: 852)
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
        XCTAssertEqual(views.filter { $0 is UISwitch }.count, 4)
    }

    func testPreviewIsDockedFullWidthAtTheBottomAndScrollEndsAboveIt() async throws {
        try await assertDocked(in: CGRect(x: 0, y: 0, width: 393, height: 852), compact: false)
    }

    func testScaledCompactPreviewStaysOnScreenFlushWithTheBottom() async throws {
        try await assertDocked(in: CGRect(x: 0, y: 0, width: 852, height: 300), compact: true)
    }

    func testPreviewKeysCentreOnTheWindowWithUnevenSideInsets() async throws {
        let insets = UIEdgeInsets(top: 0, left: 80, bottom: 0, right: 30)
        try await assertDocked(in: CGRect(x: 0, y: 0, width: 852, height: 393), compact: true, sideInsets: insets)
        try await assertDocked(in: CGRect(x: 0, y: 0, width: 951, height: 669), compact: false, sideInsets: insets)
        try await assertDocked(in: CGRect(x: 0, y: 0, width: 466, height: 678), compact: false, sideInsets: insets)
    }

    private func assertDocked(in bounds: CGRect, compact: Bool, sideInsets: UIEdgeInsets = .zero) async throws {
        let host = UIHostingController(rootView: NavigationStack { KeyboardAppearancePage() })
        host.additionalSafeAreaInsets = sideInsets
        if compact { host.traitOverrides.verticalSizeClass = .compact }
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
        XCTAssertLessThanOrEqual(frame.maxX, window.bounds.width + 1)
        let expectedWidth = KeyboardAppearancePage.keyboardWidth(display: window.bounds.size)
        XCTAssertEqual(frame.midX, window.bounds.midX, accuracy: 0.5)
        if !compact {
            XCTAssertEqual(frame.width, expectedWidth, accuracy: 0.5)
        }
        XCTAssertEqual(frame.maxY, window.bounds.height - window.safeAreaInsets.bottom, accuracy: 1)
        let scroll = try XCTUnwrap(views.compactMap { $0 as? UIScrollView }.filter { !$0.isDescendant(of: keyboard) }.max { $0.bounds.height < $1.bounds.height })
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

        settings.numberRow = true
        KeyboardAppearancePreview.apply(settings, to: view)
        try await waitForState("the preview shows the number row") { view.engine.numberRow }
        XCTAssertEqual(view.preferredHeight, KeyboardLayout.height(for: .portrait, showsStrip: false, numberRow: true))
        XCTAssertNotNil(view.engine.layout.key(.character("1")))
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

    /// iPhone Duo outer 466 × 678 pt and inner 669 × 951 pt, each both ways; split only open and sideways.
    func testPreviewPicksThePoseOfTheWholeWindow() {
        let poses: [(CGSize, KeyboardOrientation, Bool)] = [
            (CGSize(width: 393, height: 852), .portrait, false),
            (CGSize(width: 466, height: 678), .portrait, false),
            (CGSize(width: 678, height: 466), .landscape, false),
            (CGSize(width: 669, height: 951), .widePortrait, false),
            (CGSize(width: 951, height: 669), .wideLandscape, true),
        ]
        for (window, orientation, allowsSplit) in poses {
            var settings = base
            settings.container = window
            XCTAssertEqual(settings.orientation, orientation, "\(window)")
            XCTAssertEqual(settings.orientation.allowsSplit, allowsSplit, "\(window)")
        }
    }

    func testPreviewIsAsWideAsTheKeyboardIOSGivesThePose() {
        XCTAssertEqual(KeyboardAppearancePage.keyboardWidth(display: CGSize(width: 393, height: 852)), 393)
        XCTAssertEqual(KeyboardAppearancePage.keyboardWidth(display: CGSize(width: 669, height: 951)), 669)
        for display in [CGSize(width: 466, height: 678), CGSize(width: 678, height: 466), CGSize(width: 951, height: 669)] {
            XCTAssertLessThan(KeyboardAppearancePage.keyboardWidth(display: display), display.width, "\(display)")
        }
    }

    func testPreviewSplitsOnlyOnTheOpenDuoSideways() {
        let displays = [CGSize(width: 393, height: 852), CGSize(width: 466, height: 678), CGSize(width: 678, height: 466),
                        CGSize(width: 669, height: 951), CGSize(width: 951, height: 669)]
        for display in displays {
            var settings = base
            settings.container = display
            let full = settings.orientation
            settings.splitKeyboard = true
            XCTAssertEqual(settings.orientation, full.allowsSplit ? .splitLandscape : full, "\(display)")
            let view = KeyboardAppearancePreview.makeKeyboard(settings)
            view.frame = CGRect(x: 0, y: 0, width: KeyboardAppearancePage.keyboardWidth(display: display),
                                height: view.preferredHeight)
            view.layoutIfNeeded()
            XCTAssertEqual(view.engine.layout.orientation, settings.orientation, "\(display)")
        }
    }

    func testPreviewStaysBelowAFoldAcrossThePage() {
        let page = CGSize(width: 669, height: 830)
        let height = KeyboardLayout.height(for: .widePortrait, numberRow: true)
        XCTAssertEqual(KeyboardAppearancePage.previewScale(keyboardHeight: height, page: page, foldBottom: nil), 1)
        XCTAssertEqual(KeyboardAppearancePage.previewScale(keyboardHeight: height, page: page, foldBottom: 400), 1,
                       "a fold above the keyboard changes nothing")
        let foldBottom: CGFloat = 600
        let scale = KeyboardAppearancePage.previewScale(keyboardHeight: height, page: page, foldBottom: foldBottom)
        XCTAssertLessThan(scale, 1)
        XCTAssertEqual(height * scale, page.height - foldBottom, accuracy: 0.001)
    }

    func testPreviewFollowsTheWindowWhenItRotatesFoldsAndUnfolds() async throws {
        let host = UIHostingController(rootView: NavigationStack { KeyboardAppearancePage() })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 951, height: 669))
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        let poses: [(CGSize, KeyboardOrientation)] = [
            (CGSize(width: 951, height: 669), .wideLandscape),
            (CGSize(width: 669, height: 951), .widePortrait),
            (CGSize(width: 466, height: 678), .portrait),
            (CGSize(width: 678, height: 466), .landscape),
        ]
        for (size, orientation) in poses {
            window.frame = CGRect(origin: .zero, size: size)
            try await waitForState("the preview shows the \(orientation) keyboard") {
                host.view.layoutIfNeeded()
                let keyboard = Self.subviews(of: host.view).compactMap { $0 as? FullKeyboardView }.first
                return keyboard?.engine.layout.orientation == orientation
            }
            let keyboard = try XCTUnwrap(Self.subviews(of: host.view).compactMap { $0 as? FullKeyboardView }.first)
            XCTAssertEqual(keyboard.bounds.width, KeyboardAppearancePage.keyboardWidth(display: size), accuracy: 0.5, "\(size)")
            if orientation == .wideLandscape {
                XCTAssertEqual(keyboard.engine.layout.letterWidth, KeyboardMetrics.maxWideLetterWidth, accuracy: 0.001)
            }
        }
    }

    private static func subviews(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap(subviews(of:))
    }
}
