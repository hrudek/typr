import SwiftUI
import UIKit

/// Keyboard preferences, grouped by purpose rather than feature maturity.
struct KeyboardSettingsCard: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var fullKeyboard = FullKeyboardSettings().isEnabled
    @State private var autocorrect = FullKeyboardSettings().autocorrect
    @State private var swipeTyping = FullKeyboardSettings().swipeTyping
    @State private var personalLearning = TyprSettings().personalLearning
    @State private var autocorrectGerman = TyprSettings().autocorrectGerman
    @State private var autocorrectEnglish = TyprSettings().autocorrectEnglish
    @State private var hideSuggestionBar = TyprSettings().hideSuggestionBar

    static let swipeNotice = "Swipe typing powered by FUTO Swipe."

    var body: some View {
        VStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                SettingsSection(title: "Keyboard layout") {
                    SettingsToggle(title: "Full keyboard", detail: "Type with Typr. Hold the Typr key to dictate.", isOn: $fullKeyboard)
                        .onChange(of: fullKeyboard) { _, enabled in
                            FullKeyboardSettings().isEnabled = enabled
                        }
                    SettingsDivider()
                    SettingsToggle(title: "Hide suggestion bar", detail: "More room for your text. Autocorrect still works on space.", isOn: $hideSuggestionBar)
                        .onChange(of: hideSuggestionBar) { _, enabled in
                            TyprSettings().hideSuggestionBar = enabled
                        }
                }
                if !fullKeyboard {
                    Text("Turn on Full keyboard to configure autocorrect and its languages.")
                        .font(.footnote).foregroundStyle(TyprTheme.textMuted)
                        .padding(.horizontal, 16)
                }
                // Required end-user notice of the FUTO Model Weights License (SwipeModel/LICENSE-FUTO-SWIPE.txt).
                Text(Self.swipeNotice)
                    .font(.footnote).foregroundStyle(TyprTheme.textMuted)
                    .padding(.horizontal, 16)
            }
            if fullKeyboard {
                SettingsSection(title: "Typing assistance") {
                    SettingsToggle(title: "Autocorrect", detail: "Correct contractions, shortcuts and small typos on space.", isOn: $autocorrect)
                        .onChange(of: autocorrect) { _, enabled in
                            FullKeyboardSettings().autocorrect = enabled
                        }
                    if autocorrect {
                        SettingsDivider()
                        NavigationLink(value: SettingsDestination.autocorrectLanguages) {
                            SettingsLink(title: "Autocorrect languages", detail: "Choose one or more languages",
                                         value: AutocorrectLanguageSettingsCard.summary(
                                            german: autocorrectGerman, english: autocorrectEnglish))
                        }
                        .buttonStyle(.plain)
                    }
                    SettingsDivider()
                    SettingsToggle(title: "Swipe typing", detail: "Slide across the letters to type a word.", isOn: $swipeTyping)
                        .onChange(of: swipeTyping) { _, enabled in
                            FullKeyboardSettings().swipeTyping = enabled
                        }
                    SettingsDivider()
                    SettingsToggle(title: "Learn from my typing", detail: "Adapts to your taps, chosen words, recent German/English usage and what follows one or two words. Undo remembers rejected corrections and their preceding words.", isOn: $personalLearning)
                        .onChange(of: personalLearning) { _, enabled in
                            TyprSettings().personalLearning = enabled
                        }
                    SettingsDivider()
                    NavigationLink(value: SettingsDestination.keyboardLearnedWords) {
                        SettingsLink(title: "Manage learned words", detail: "Find and delete saved words and corrections")
                    }
                    .buttonStyle(.plain)
                }
            }
            KeyboardLearningResetControls()
            PersonalLexiconSettingsCard()
            VStack(alignment: .leading, spacing: 8) {
                SettingsSection(title: "iPhone setup") {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } label: {
                        SettingsLink(title: "iOS keyboard settings", detail: "Enable Typr and Full Access", external: true)
                    }
                    .buttonStyle(.plain)
                }
                Text("Add Typr and allow Full Access in iOS Settings.")
                    .font(.footnote).foregroundStyle(TyprTheme.textMuted)
                    .padding(.horizontal, 16)
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
    }

    private func refresh() {
        fullKeyboard = FullKeyboardSettings().isEnabled
        autocorrect = FullKeyboardSettings().autocorrect
        swipeTyping = FullKeyboardSettings().swipeTyping
        personalLearning = TyprSettings().personalLearning
        autocorrectGerman = TyprSettings().autocorrectGerman
        autocorrectEnglish = TyprSettings().autocorrectEnglish
        hideSuggestionBar = TyprSettings().hideSuggestionBar
    }
}

/// Uses the same checkmark rows as dictation language, but each choice is independent.
struct AutocorrectLanguageSettingsCard: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var german = TyprSettings().autocorrectGerman
    @State private var english = TyprSettings().autocorrectEnglish

    /// ISO 639-1 language codes, uppercased for display and sorted by code.
    static func summary(german: Bool, english: Bool) -> String {
        let codes = [(german, "DE"), (english, "EN")].compactMap { $0.0 ? $0.1 : nil }
        return codes.isEmpty ? "None" : codes.joined(separator: ", ")
    }

    var body: some View {
        SettingsSection {
            SettingsChoiceRow(title: "Deutsch", isSelected: german) {
                german.toggle()
                TyprSettings().autocorrectGerman = german
            }
            SettingsDivider()
            SettingsChoiceRow(title: "English", isSelected: english) {
                english.toggle()
                TyprSettings().autocorrectEnglish = english
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
    }

    private func refresh() {
        german = TyprSettings().autocorrectGerman
        english = TyprSettings().autocorrectEnglish
    }
}

struct VocabularySettingsCard: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var enabled = CustomVocabularySettings().isEnabled

    var body: some View {
        SettingsSection(title: "Vocabulary") {
            SettingsToggle(title: "Custom vocabulary", detail: "Preferred spellings for names and terms, with optional sounds-like forms.", isOn: $enabled)
                .onChange(of: enabled) { _, value in CustomVocabularySettings().isEnabled = value }
            if enabled {
                SettingsDivider()
                CustomVocabularyEditor().padding(16)
            }
        }
        .onAppear { enabled = CustomVocabularySettings().isEnabled }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { enabled = CustomVocabularySettings().isEnabled }
        }
    }
}
