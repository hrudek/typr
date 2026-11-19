import SwiftUI

struct KeyboardWordsPrivacyCard: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var personalLearning = TyprSettings().personalLearning

    static let whatTyprLearns = "Typr adapts to your taps, chosen words, recent German/English usage and what follows one or two words. Undo remembers rejected corrections and their preceding words. Imported names and terms work independently of this switch."

    var body: some View {
        VStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                SettingsSection(title: "Learning") {
                    SettingsToggle(title: "Learn from my typing", detail: "Adapt to your taps and word choices.", isOn: $personalLearning)
                        .onChange(of: personalLearning) { _, enabled in TyprSettings().personalLearning = enabled }
                    SettingsDivider()
                    NavigationLink(value: SettingsDestination.keyboardLearnedWords) {
                        SettingsLink(title: "Manage learned words", detail: "Find and delete saved words and corrections")
                    }
                    .buttonStyle(.plain)
                    SettingsDivider()
                    SettingsDisclosure(title: "What Typr learns", text: Self.whatTyprLearns)
                }
                SettingsFooter("Turning this off keeps saved learning.")
            }
            PersonalLexiconSettingsCard()
            KeyboardLearningResetControls()
            TypingLogControls()
        }
        .onAppear { personalLearning = TyprSettings().personalLearning }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { personalLearning = TyprSettings().personalLearning }
        }
    }
}
