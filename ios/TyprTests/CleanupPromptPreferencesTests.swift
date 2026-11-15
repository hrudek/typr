import XCTest
@testable import Typr

@MainActor
final class CleanupPromptPreferencesTests: XCTestCase {
    private func withPreferences(_ test: (CleanupPromptPreferences, UserDefaults) throws -> Void) rethrows {
        let suite = "CleanupPromptPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try test(CleanupPromptPreferences(defaults: defaults), defaults)
    }

    func testUnmodifiedPromptIsTheExactCurrentHardcodedDefault() {
        withPreferences { preferences, defaults in
            XCTAssertEqual(preferences.instructions, CleanupPrompt.instructions)
            XCTAssertFalse(preferences.isCustom)
            XCTAssertNil(defaults.object(forKey: "typr.cleanupPrompt"))
        }
    }

    func testSavedPromptPersistsExactlyAndIsUsedByNewReaders() {
        withPreferences { preferences, defaults in
            let custom = "Keep my wording.\n  Fix only punctuation.\n"
            XCTAssertTrue(preferences.save(custom))
            let reopened = CleanupPromptPreferences(defaults: defaults)
            XCTAssertEqual(reopened.instructions, custom)
            XCTAssertTrue(reopened.isCustom)
            // The built-in default itself is never mutated by editing.
            XCTAssertNotEqual(CleanupPrompt.instructions, custom)
        }
    }

    func testEmptyOrWhitespaceDraftDoesNotOverwriteSavedPrompt() {
        withPreferences { preferences, _ in
            XCTAssertTrue(preferences.save("Fix punctuation."))
            for empty in ["", " \n\t "] {
                XCTAssertFalse(CleanupPromptPreferences.canSave(empty))
                XCTAssertFalse(preferences.save(empty))
                XCTAssertEqual(preferences.instructions, "Fix punctuation.")
            }
        }
    }

    func testResetRemovesOverrideAndFollowsDefault() {
        withPreferences { preferences, defaults in
            preferences.save("Fix punctuation.")
            preferences.reset()
            XCTAssertFalse(preferences.isCustom)
            XCTAssertEqual(CleanupPromptPreferences(defaults: defaults).instructions, CleanupPrompt.instructions)
            XCTAssertNil(defaults.object(forKey: "typr.cleanupPrompt"))
        }
    }

    func testSavingDefaultAlsoRemovesOverride() {
        withPreferences { preferences, defaults in
            preferences.save("Fix punctuation.")
            XCTAssertTrue(preferences.save(CleanupPrompt.instructions))
            XCTAssertFalse(preferences.isCustom)
            XCTAssertNil(defaults.object(forKey: "typr.cleanupPrompt"))
        }
    }

    func testInvalidStoredValueFallsBackToDefault() {
        withPreferences { preferences, defaults in
            defaults.set(" \n ", forKey: "typr.cleanupPrompt")
            XCTAssertEqual(preferences.instructions, CleanupPrompt.instructions)
            XCTAssertFalse(preferences.isCustom)
        }
    }
}
