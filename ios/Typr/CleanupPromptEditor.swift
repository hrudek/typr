import SwiftUI

@MainActor
struct CleanupPromptEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft = CleanupPromptPreferences().instructions
    @State private var savedCustomPrompt = CleanupPromptPreferences().isCustom
    @FocusState private var isEditing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("The instructions AI cleanup follows when cleaning up your dictations. Changes apply to the next cleanup request after saving.")
                .font(.subheadline).foregroundStyle(TyprTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)

            SettingsSection(title: "Prompt") {
                TextEditor(text: $draft)
                    .font(.body)
                    .foregroundStyle(TyprTheme.textBase)
                    .scrollContentBackground(.hidden)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($isEditing)
                    .frame(height: 360)
                    .padding(12)
                    .accessibilityLabel("Cleanup prompt")
                    .accessibilityIdentifier("cleanup-prompt-editor")
            }

            Text("Language, style, vocabulary and context are added automatically. Existing safety checks and formatting still apply. Long prompts can exceed Apple Intelligence’s context window; Typr then uses the plain transcript.")
                .font(.footnote).foregroundStyle(TyprTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)

            if !CleanupPromptPreferences.canSave(draft) {
                Text("Enter a prompt before saving.")
                    .font(.footnote).foregroundStyle(TyprTheme.warmMic)
                    .padding(.horizontal, 16)
            }

            Button {
                guard CleanupPromptPreferences().save(draft) else { return }
                isEditing = false
                dismiss()
            } label: {
                Text("Save prompt")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(TyprTheme.agentBlue)
            .disabled(!CleanupPromptPreferences.canSave(draft))
            .accessibilityIdentifier("save-cleanup-prompt")

            if savedCustomPrompt || draft != CleanupPrompt.instructions {
                Button("Reset to default", role: .destructive) {
                    CleanupPromptPreferences().reset()
                    draft = CleanupPrompt.instructions
                    savedCustomPrompt = false
                    isEditing = false
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("reset-cleanup-prompt")
            }
        }
    }
}
