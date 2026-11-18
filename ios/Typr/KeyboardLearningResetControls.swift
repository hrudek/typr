import SwiftUI

/// Available even with personal learning turned off.
struct KeyboardLearningResetControls: View {
    @State private var model = KeyboardLearningSettingsModel()
    @State private var confirmLearningReset = false
    @State private var confirmCountersReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSection(title: "Saved typing data") {
                VStack(alignment: .leading, spacing: 12) {
                    Button("Reset learning", role: .destructive) { confirmLearningReset = true }
                        .frame(minHeight: 44, alignment: .leading)
                    SettingsDivider()
                    Button("Reset technical counters", role: .destructive) { confirmCountersReset = true }
                        .frame(minHeight: 44, alignment: .leading)
                    if let problem = model.resetProblem {
                        Text(problem)
                            .font(.footnote)
                            .foregroundStyle(TyprTheme.danger)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            SettingsFooter("Learning stays on this iPhone. Resets cannot be undone.")
        }
        .confirmationDialog("Reset learning?", isPresented: $confirmLearningReset, titleVisibility: .visible) {
            Button("Reset learning", role: .destructive) { model.resetLearning() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes touch calibration, kept words, word counts, next-word contexts, rejected corrections and imported personal words. Turns off contacts and dictation imports without deleting their sources. Technical counters stay. The keyboard clears its matching learning before its next save and reloads imports on its next appearance.")
        }
        .confirmationDialog("Reset technical counters?", isPresented: $confirmCountersReset, titleVisibility: .visible) {
            Button("Reset technical counters", role: .destructive) { model.resetTechnicalCounters() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes autocorrect event counters and processing-time histograms. Learned words, touch calibration and personal imports stay.")
        }
    }
}
