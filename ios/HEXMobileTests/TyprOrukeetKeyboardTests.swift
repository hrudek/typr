import Foundation
import XCTest
@testable import HEX

final class TyprOrukeetKeyboardTests: XCTestCase {
    private func resolve(
        orukeetEnabled: Bool = true,
        installed: Bool = true,
        keyboardModelEnabled: Bool = true,
        physicalMemory: UInt64 = 8 << 30,
        twoLanguageEnabled: Bool = false,
        language: String? = "de-DE",
        keyboardLimit: Int? = KeyboardParakeetBudget.requiredLimit
    ) -> String? {
        TyprOrukeetKeyboardPlan.resolve(
            orukeetEnabled: orukeetEnabled,
            installed: installed,
            keyboardModelEnabled: keyboardModelEnabled,
            physicalMemory: physicalMemory,
            twoLanguageEnabled: twoLanguageEnabled,
            language: language,
            keyboardLimit: keyboardLimit
        )
    }

    func testOnAndInstalledTakesUltrasLanguages() {
        XCTAssertEqual(resolve(), "de-DE")
        XCTAssertEqual(resolve(language: "en-US"), "en-US")
        XCTAssertEqual(resolve(keyboardLimit: nil), "de-DE", "a limit not measured yet, as Ultra")
    }

    func testOffLeavesUpstreamsPlan() {
        XCTAssertNil(resolve(orukeetEnabled: false))
    }

    func testFallsBackWhereUpstreamWouldNotRunUltra() {
        XCTAssertNil(resolve(installed: false), "not installed")
        XCTAssertNil(resolve(keyboardModelEnabled: false), "Speech model in keyboard off")
        XCTAssertNil(resolve(physicalMemory: 4 << 30), "4 GB iPhone")
        XCTAssertNil(resolve(twoLanguageEnabled: true), "two-language dictation")
        XCTAssertNil(resolve(language: "ja-JP"), "a language Ultra doesn't know")
        XCTAssertNil(resolve(language: nil))
        XCTAssertNil(resolve(keyboardLimit: KeyboardParakeetBudget.requiredLimit - 1), "keyboard limit too small")
    }

    func testCurrentReadsTheAppGroup() throws {
        let suite = "TyprOrukeetKeyboardTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        LanguageSettings(defaults: defaults).dictationLanguage = "fr-FR"
        func current(installed: Bool = true) -> String? {
            TyprOrukeetKeyboardPlan.current(
                defaults: defaults, preferred: ["en-US"], physicalMemory: 8 << 30, installed: installed
            )
        }

        XCTAssertEqual(current(), "fr-FR", "on by default")
        XCTAssertNil(current(installed: false))
        TyprSettings(defaults: defaults).orukeet = false
        XCTAssertNil(current())
        TyprSettings(defaults: defaults).orukeet = true
        KeyboardParakeetSettings(defaults: defaults).isEnabled = false
        XCTAssertNil(current())
        KeyboardParakeetSettings(defaults: defaults).isEnabled = true
        TwoLanguageDictationSettings(defaults: defaults).isEnabled = true
        XCTAssertNil(current())
    }

    func testModelIsInTheAppGroupsSpeechModels() {
        XCTAssertEqual(TyprOrukeetStore.compiledDirectory.deletingLastPathComponent().deletingLastPathComponent(), SpeechModelStore.root)
    }
}
