import SwiftUI
import UIKit

struct KeyboardSettingsCard: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    private let defaults: UserDefaults?
    @State private var autocorrect: Bool
    @State private var swipeTyping: Bool
    @State private var hitAreas: KeyboardHitAreas
    @State private var autocorrectGerman: Bool
    @State private var autocorrectEnglish: Bool

    static let swipeNotice = "Swipe typing powered by FUTO Swipe."

    init(defaults: UserDefaults? = UserDefaults(suiteName: KeyboardBridge.appGroup)) {
        self.defaults = defaults
        let keyboard = FullKeyboardSettings(defaults: defaults)
        let typr = TyprSettings(defaults: defaults)
        _autocorrect = State(initialValue: keyboard.autocorrect)
        _swipeTyping = State(initialValue: keyboard.swipeTyping)
        _hitAreas = State(initialValue: keyboard.hitAreas)
        _autocorrectGerman = State(initialValue: typr.autocorrectGerman)
        _autocorrectEnglish = State(initialValue: typr.autocorrectEnglish)
    }

    private var keyboardSettings: FullKeyboardSettings { FullKeyboardSettings(defaults: defaults) }
    private var typrSettings: TyprSettings { TyprSettings(defaults: defaults) }

    var body: some View {
        VStack(spacing: 24) {
            SettingsSection {
                NavigationLink(value: SettingsDestination.keyboardAppearance) {
                    SettingsLink(title: "Appearance", detail: "Design, suggestion bar, globe key and bottom row")
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsSection(title: "Typing assistance") {
                    SettingsToggle(title: "Autocorrect", detail: "Correct contractions, shortcuts and small typos on space.", isOn: $autocorrect)
                        .onChange(of: autocorrect) { _, enabled in keyboardSettings.autocorrect = enabled }
                    SettingsDivider()
                    NavigationLink(value: SettingsDestination.autocorrectLanguages) {
                        SettingsLink(title: "Autocorrect languages", detail: "Choose the languages autocorrect uses",
                                     value: AutocorrectLanguageSettingsCard.summary(
                                        german: autocorrectGerman, english: autocorrectEnglish))
                    }
                    .buttonStyle(.plain)
                    .enabled(autocorrect)
                    SettingsDivider()
                    SettingsToggle(title: "Swipe typing", detail: "Slide across the letters to type a word.", isOn: $swipeTyping)
                        .onChange(of: swipeTyping) { _, enabled in keyboardSettings.swipeTyping = enabled }
                }
                // Required end-user notice of the FUTO Model Weights License (SwipeModel/LICENSE-FUTO-SWIPE.txt).
                SettingsFooter(Self.swipeNotice)
            }

            SettingsSection(title: "Hit areas") {
                ForEach(Array(KeyboardHitAreas.allCases.enumerated()), id: \.element) { index, choice in
                    if index > 0 { SettingsDivider() }
                    SettingsChoiceRow(title: choice.title, detail: choice.detail, isSelected: hitAreas == choice) {
                        hitAreas = choice
                        keyboardSettings.hitAreas = choice
                    }
                }
            }
            .enabled(autocorrect)

            SettingsSection {
                NavigationLink(value: SettingsDestination.keyboardWordsPrivacy) {
                    SettingsLink(title: "Words and privacy", detail: "Learning, personal words and saved data")
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsSection(title: "iPhone setup") {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } label: {
                        SettingsLink(title: "iOS keyboard settings", detail: "Enable Typr and Full Access", external: true)
                    }
                    .buttonStyle(.plain)
                }
                SettingsFooter("Add Typr and allow Full Access in iOS Settings.")
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
    }

    private func refresh() {
        autocorrect = keyboardSettings.autocorrect
        swipeTyping = keyboardSettings.swipeTyping
        hitAreas = keyboardSettings.hitAreas
        autocorrectGerman = typrSettings.autocorrectGerman
        autocorrectEnglish = typrSettings.autocorrectEnglish
    }
}

private extension View {
    func enabled(_ isEnabled: Bool) -> some View {
        disabled(!isEnabled).opacity(isEnabled ? 1 : 0.4)
    }
}

extension GlobeKey {
    var title: String {
        switch self {
        case .switches: "Switches keyboards"
        case .spacer: "Spacer"
        case .hidden: "Hidden"
        }
    }
}

extension KeyboardHitAreas {
    var title: String {
        switch self {
        case .standard: "Standard"
        case .adaptive: "Adaptive"
        }
    }

    var detail: String {
        switch self {
        case .standard: "Only taps in the narrow gap between keys use your learned aim."
        case .adaptive: "When a word ends, a tap near a key edge can count as the neighboring key if that makes a known word. A made-up word one key away from a known word can change too; Delete right after undoes it."
        }
    }
}

extension KeyboardDesign {
    var title: String {
        switch self {
        case .standard: "Default"
        case .mechanical: "Mechanical"
        }
    }
}

extension BottomKey {
    var title: String {
        switch self {
        case .space: "Space bar"
        case .period: "Period key"
        case .typr: "Typr key"
        }
    }
}

struct AutocorrectLanguageSettingsCard: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var german = TyprSettings().autocorrectGerman
    @State private var english = TyprSettings().autocorrectEnglish

    /// ISO 639-1 language codes, uppercased for display and sorted by code.
    static func summary(german: Bool, english: Bool) -> String {
        let codes = [(german, "DE"), (english, "EN")].compactMap { $0.0 ? $0.1 : nil }
        return codes.isEmpty ? "None" : codes.joined(separator: ", ")
    }

    static let footer = "For autocorrect only. Your dictation language stays as it is."
    static let noneSelected = "No autocorrect languages selected."

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
            if !german && !english { SettingsFooter(Self.noneSelected) }
            SettingsFooter(Self.footer)
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
