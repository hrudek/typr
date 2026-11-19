import SwiftUI
import UIKit
import XCTest
@testable import Typr

final class SettingsPresentationTests: XCTestCase {
    func testEverySettingsPageHasAnExplicitSnapshotRoute() {
        for destination in SettingsDestination.allCases {
            XCTAssertFalse(destination.title.isEmpty)
            XCTAssertEqual(
                SettingsDestination.snapshotDestination(arguments: ["Typr", "--snap-state", "settings-\(destination.rawValue)"]),
                destination
            )
        }
        for scene in [SettingsDestination.historySampleScene, SettingsDestination.historyDetailScene] {
            XCTAssertEqual(SettingsDestination.snapshotDestination(arguments: ["Typr", "--snap-state", scene]), .history)
        }
        // The prompt editor is gone (Hex has none); its old route opens nothing.
        XCTAssertNil(SettingsDestination.snapshotDestination(arguments:
            ["Typr", "--snap-state", "settings-cleanup-prompt"]))
        XCTAssertEqual(Set(SettingsDestination.allCases.map(\.title)),
                       ["Keyboard", "Appearance", "Statistics", "Autocorrect languages", "Words and privacy",
                        "Manage learned words", "AI & vocabulary", "History & feedback", "Speech engine", "Style", "Language"])
    }

    @MainActor
    func testLearnedWordsFixtureContainsOnlySyntheticEntries() {
        let state = KeyboardLearnedWordsView.fixtureState()
        XCTAssertNotNil(state.validated())
        XCTAssertEqual(Set(state.kept.keys), ["swift", "typr"])
        XCTAssertEqual(state.rejected, [.init(typed: "teh", replacement: "the")])
        XCTAssertEqual(state.counts["hello"]?.count, 12)
        // Synthetic aggregate pair only; the page lists its words, never the association.
        XCTAssertEqual(state.bigrams?.followers(after: "hello"), ["world": 3])
        XCTAssertEqual(SettingsDestination.snapshotDestination(arguments:
            ["Typr", "--snap-state", "settings-keyboard-learned-words"]), .keyboardLearnedWords)
    }

    @MainActor
    func testLearnedWordsSearchFiltersEveryCategoryAndBothSidesOfCorrections() {
        var state = KeyboardLearnedWordsView.fixtureState()
        state.kept["zebra"] = KeyboardLearnedWordsView.fixtureDate
        state.counts["zebra"] = .init(count: 1, lastUpdated: KeyboardLearnedWordsView.fixtureDate)
        state.rejected.append(.init(typed: "adn", replacement: "and"))
        typealias Results = KeyboardLearnedWordsView.SearchResults
        let correction = RejectedCorrection(typed: "teh", replacement: "the")
        let visible = Results(state: state, query: "t")
        XCTAssertEqual(visible.kept, ["swift", "typr"])
        XCTAssertEqual(visible.pairs, [correction])
        XCTAssertTrue(visible.counts.isEmpty)

        state.kept["München"] = KeyboardLearnedWordsView.fixtureDate
        state.kept["hello"] = KeyboardLearnedWordsView.fixtureDate
        state.counts["other"] = .init(count: 3, lastUpdated: KeyboardLearnedWordsView.fixtureDate)
        let all = Results(state: state, query: "  \n ")
        XCTAssertEqual(all.kept, state.kept.keys.sorted())
        // Pairs are listed sorted by typed word, then replacement, not in storage order.
        XCTAssertEqual(all.pairs, [RejectedCorrection(typed: "adn", replacement: "and"), correction])
        XCTAssertEqual(all.counts, ["hello", "other", "zebra"])
        XCTAssertEqual(all.pairWords, ["hello", "world"])

        let partial = Results(state: state, query: "  ELL  ")
        XCTAssertEqual(partial.kept, ["hello"])
        XCTAssertEqual(partial.counts, ["hello"])
        XCTAssertTrue(partial.pairs.isEmpty)
        XCTAssertEqual(partial.pairWords, ["hello"])
        XCTAssertEqual(Results(state: state, query: "WORL").pairWords, ["world"])
        XCTAssertEqual(Results(state: state, query: "munchen").kept, ["München"])
        XCTAssertEqual(Results(state: state, query: "TEH").pairs, [correction])
        XCTAssertEqual(Results(state: state, query: "THE").pairs, [correction])
        XCTAssertEqual(Results(state: state, query: "zeb").kept, ["zebra"])
        XCTAssertEqual(Results(state: state, query: "zeb").counts, ["zebra"])

        let none = Results(state: state, query: "not-saved")
        XCTAssertTrue(none.kept.isEmpty)
        XCTAssertTrue(none.pairs.isEmpty)
        XCTAssertTrue(none.counts.isEmpty)
        XCTAssertTrue(none.pairWords.isEmpty)
        XCTAssertEqual(state.counts["hello"]?.count, 12)
        XCTAssertEqual(state.kept.count, 5)
    }

    @MainActor
    func testAutocorrectLanguageSummaryCoversAllSelectionsInStoredOrder() {
        typealias Card = AutocorrectLanguageSettingsCard
        for order: [SpatialWordDecoder.Language] in [[.german, .english], [.english, .german]] {
            XCTAssertEqual(Card.summary(order: order, german: true, english: false), "DE")
            XCTAssertEqual(Card.summary(order: order, german: false, english: true), "EN")
            XCTAssertEqual(Card.summary(order: order, german: false, english: false), "None")
        }
        XCTAssertEqual(Card.summary(order: [.german, .english], german: true, english: true), "DE, EN")
        XCTAssertEqual(Card.summary(order: [.english, .german], german: true, english: true), "EN, DE")
    }

    @MainActor
    func testDroppingAutocorrectLanguageTakesTheTargetPlace() {
        typealias Card = AutocorrectLanguageSettingsCard
        XCTAssertEqual(Card.moving(.english, onto: .german, in: [.german, .english]), [.english, .german])
        XCTAssertEqual(Card.moving(.german, onto: .english, in: [.german, .english]), [.english, .german])
        XCTAssertEqual(Card.moving(.german, onto: .german, in: [.german, .english]), [.german, .english])
    }

    @MainActor
    func testMovedAutocorrectLanguageOrderIsStoredAndSummarized() throws {
        let suite = "SettingsPresentationTests.languageOrder"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = TyprSettings(defaults: defaults)
        settings.autocorrectLanguageOrder = AutocorrectLanguageSettingsCard.moving(
            .english, onto: .german, in: settings.autocorrectLanguageOrder)
        let stored = TyprSettings(defaults: defaults)
        XCTAssertEqual(stored.autocorrectLanguageOrder, [.english, .german])
        XCTAssertEqual(AutocorrectLanguageSettingsCard.summary(order: stored.autocorrectLanguageOrder,
                                                               german: stored.autocorrectGerman,
                                                               english: stored.autocorrectEnglish), "EN, DE")
    }

    func testRemovedDiagnosticsRoutesDoNotNavigateOrUseLearnedWordsFixtures() {
        for page in ["", "-word-checks", "-speed", "-learning"] {
            for state in ["", "-empty", "-populated", "-learning-off", "-unreadable"] {
                let scene = "settings-keyboard-diagnostics" + page + state
                let arguments = ["Typr", "--snap-state", scene]
                XCTAssertNil(SettingsDestination.snapshotDestination(arguments: arguments), scene)
                XCTAssertFalse(ContentView.learnedWordsUsesFixture(arguments: arguments), scene)
            }
        }
        XCTAssertFalse(SettingsDestination.allCases.contains { $0.rawValue.contains("diagnostics") })
        XCTAssertEqual(SettingsDestination.snapshotDestination(arguments:
            ["Typr", "--snap-state", "settings-statistics"]), .statistics)
        XCTAssertTrue(ContentView.learnedWordsUsesFixture(
            arguments: ["Typr", "--snap-state", "settings-keyboard-learned-words"]))
        for arguments in [[], ["Typr"], ["--snap-state"], ["settings-keyboard-learned-words"],
                          ["--other", "settings-keyboard-learned-words"], ["--snap-state", "settings-keyboard"]] {
            XCTAssertFalse(ContentView.learnedWordsUsesFixture(arguments: arguments))
        }
    }

    func testTypingAssistanceSnapshotOpensKeyboardSettings() {
        XCTAssertEqual(SettingsDestination.snapshotDestination(arguments: ["Typr", "--snap-state", "settings-keyboard-typing"]), .keyboard)
    }

    func testOrdinaryLaunchesAndUnrelatedScenesDoNotNavigate() {
        for arguments in [[], ["Typr"], ["--snap-state"], ["--snap-state", "ready"],
                          ["--snap-state", "keyboard-warm"], ["--snap-state", "settings-unknown"],
                          ["settings-keyboard"], ["--other", "settings-keyboard"]] {
            XCTAssertNil(SettingsDestination.snapshotDestination(arguments: arguments))
        }
    }

    @MainActor
    func testSettingsRowsGrowForAccessibilityTextAtCompactWidth() {
        func size(_ type: DynamicTypeSize) -> CGSize {
            let view = SettingsToggle(
                title: "Keep dictation history",
                detail: "Saves text stages, vocabulary and feedback. No audio. Kept until you delete it.",
                isOn: .constant(true)
            )
            .dynamicTypeSize(type)
            let host = UIHostingController(rootView: view)
            return host.sizeThatFits(in: CGSize(width: 320, height: 10_000))
        }
        let regular = size(.large)
        let accessible = size(.accessibility3)
        XCTAssertGreaterThanOrEqual(regular.height, 64)
        XCTAssertGreaterThan(accessible.height, regular.height)
        XCTAssertLessThanOrEqual(accessible.width, 320.5)
        XCTAssertLessThan(accessible.height, 10_000)
    }

    @MainActor
    func testLearningResetControlsGrowAtCompactAccessibilitySizes() {
        func size(_ type: DynamicTypeSize) -> CGSize {
            let host = UIHostingController(rootView:
                KeyboardLearningResetControls().dynamicTypeSize(type)
            )
            return host.sizeThatFits(in: CGSize(width: 280, height: 10_000))
        }
        let regular = size(.large)
        let accessible = size(.accessibility3)
        XCTAssertGreaterThanOrEqual(regular.height, 88)
        XCTAssertGreaterThan(accessible.height, regular.height)
        XCTAssertLessThanOrEqual(accessible.width, 280.5)
        XCTAssertLessThan(accessible.height, 10_000)
    }

    @MainActor
    func testLearningResetControlsReportUnavailableStorage() {
        let model = KeyboardLearningSettingsModel(directory: nil, defaults: nil)
        model.resetTechnicalCounters()
        XCTAssertNotNil(model.resetProblem)
        model.resetLearning()
        XCTAssertNotNil(model.resetProblem)
    }

    @MainActor
    func testWarmDurationButtonsUseTwoRowsAtAccessibilitySizes() {
        func size(_ type: DynamicTypeSize) -> CGSize {
            let host = UIHostingController(rootView:
                SettingsWarmDurationControl(selected: .fifteenMinutes, onSelect: { _ in })
                    .dynamicTypeSize(type)
            )
            return host.sizeThatFits(in: CGSize(width: 280, height: 10_000))
        }
        let regular = size(.large)
        let accessible = size(.accessibility3)
        XCTAssertGreaterThanOrEqual(regular.height, 44)
        XCTAssertGreaterThan(accessible.height, regular.height)
        XCTAssertLessThanOrEqual(accessible.width, 280.5)
    }

    @MainActor
    func testMenuEntryPointsStaySingleLineAndCompactAtStandardTextSize() {
        for title in ["Keyboard", "AI & vocabulary", "History & feedback", "Speech engine", "iOS keyboard settings"] {
            let host = UIHostingController(rootView:
                SettingsLink(title: title, detail: "Explanations stay on the destination", icon: "keyboard")
                    .dynamicTypeSize(.large)
            )
            let size = host.sizeThatFits(in: CGSize(width: 353, height: 10_000))
            XCTAssertEqual(size.height, 50, accuracy: 0.5, title)
            XCTAssertLessThanOrEqual(size.width, 353.5, title)
        }
    }

    @MainActor
    func testWarmDurationRowIsInlineWhenItFitsAndStacksWithoutClipping() {
        func size(width: CGFloat, type: DynamicTypeSize = .large, selected: WarmSessionDuration = .fifteenMinutes) -> CGSize {
            let host = UIHostingController(rootView:
                SettingsWarmDurationRow(selected: selected, onSelect: { _ in })
                    .dynamicTypeSize(type)
            )
            return host.sizeThatFits(in: CGSize(width: width, height: 10_000))
        }
        XCTAssertEqual(size(width: 353).height, 50, accuracy: 0.5)
        XCTAssertGreaterThan(size(width: 280).height, 50)
        let accessible = size(width: 320, type: .accessibility3)
        XCTAssertGreaterThan(accessible.height, 50)
        XCTAssertLessThanOrEqual(accessible.width, 320.5)
    }

    func testEveryDictationStyleExplainsItsBehavior() {
        for style in DictationStyle.allCases {
            XCTAssertFalse(style.settingsDescription.isEmpty, style.rawValue)
        }
        XCTAssertTrue(DictationStyle.notes.settingsDescription.contains("new line"))
        XCTAssertTrue(DictationStyle.notes.settingsDescription.contains("new paragraph"))
        XCTAssertEqual(TranscriptFormatter.format("first new line second", style: .notes), "First\nSecond")
        XCTAssertEqual(TranscriptFormatter.format("first new paragraph second", style: .notes), "First\n\nSecond")
        XCTAssertEqual(TranscriptFormatter.format("bullet first bullet second", style: .notes), "- First\n- Second")
        XCTAssertTrue(DictationStyle.verbatim.settingsDescription.contains("Skips AI cleanup"))
        XCTAssertTrue(DictationStyle.verbatim.settingsDescription.contains("Vocabulary corrections"))
    }

    @MainActor
    func testDictationLinksShowSelectedValuesAtStandardAndAccessibilitySizes() {
        for (title, value) in [("Speech engine", "Apple Speech"), ("Speech engine", "Parakeet V2"),
                               ("Speech engine", "Whisper"), ("Style", "Polished"),
                               ("Language", "Automatic"), ("Language", "German")] {
            func size(_ type: DynamicTypeSize) -> CGSize {
                let host = UIHostingController(rootView:
                    SettingsLink(title: title, detail: "Open details", value: value).dynamicTypeSize(type)
                )
                return host.sizeThatFits(in: CGSize(width: 353, height: 10_000))
            }
            XCTAssertEqual(size(.large).height, 50, accuracy: 0.5, "\(title): \(value)")
            let accessible = size(.accessibility3)
            XCTAssertGreaterThan(accessible.height, 50, title)
            XCTAssertLessThanOrEqual(accessible.width, 353.5, title)
        }
    }

    @MainActor
    func testDictationChoiceDescriptionsWrapAtCompactWidthAndLargerText() {
        let choices = DictationStyle.allCases.map { ($0.label, $0.settingsDescription) }
        for (title, detail) in choices {
            func size(_ type: DynamicTypeSize, selected: Bool) -> CGSize {
                let host = UIHostingController(rootView:
                    SettingsChoiceRow(title: title, detail: detail, isSelected: selected, onSelect: {})
                        .dynamicTypeSize(type)
                )
                return host.sizeThatFits(in: CGSize(width: 280, height: 10_000))
            }
            let regular = size(.large, selected: true)
            let accessible = size(.accessibility3, selected: true)
            XCTAssertGreaterThanOrEqual(regular.height, 64, title)
            XCTAssertGreaterThan(accessible.height, regular.height, title)
            XCTAssertLessThanOrEqual(accessible.width, 280.5, title)
            XCTAssertLessThan(accessible.height, 10_000, title)
            XCTAssertEqual(size(.large, selected: false).height, regular.height, accuracy: 0.5, title)
        }
    }

    @MainActor
    func testLanguageChoicesUseSingleLineRowsWithoutDescriptions() {
        for language in DictationLanguage.allCases {
            for selected in [true, false] {
                let row = SettingsChoiceRow(title: language.label, isSelected: selected, onSelect: {})
                XCTAssertNil(row.detail)
                let host = UIHostingController(rootView: row.dynamicTypeSize(.large))
                let size = host.sizeThatFits(in: CGSize(width: 280, height: 10_000))
                XCTAssertEqual(size.height, 64, accuracy: 0.5, language.rawValue)
                XCTAssertLessThanOrEqual(size.width, 280.5, language.rawValue)
            }
        }
    }

    @MainActor
    func testNavigationRowsWrapRatherThanFixingTheirHeight() {
        let row = SettingsLink(title: "History & feedback", detail: "Review, rate and export dictations",
                               icon: "clock.arrow.circlepath", value: "100 entries")
            .dynamicTypeSize(.accessibility3)
        let host = UIHostingController(rootView: row)
        let size = host.sizeThatFits(in: CGSize(width: 320, height: 10_000))
        XCTAssertGreaterThan(size.height, 76)
        XCTAssertLessThanOrEqual(size.width, 320.5)
        XCTAssertLessThan(size.height, 10_000)
    }
}
