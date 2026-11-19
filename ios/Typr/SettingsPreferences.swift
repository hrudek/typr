import SwiftUI

struct SettingsPreferences: View {
    var body: some View {
        SettingsSection(title: "Preferences") {
            NavigationLink(value: SettingsDestination.keyboard) {
                SettingsLink(title: "Keyboard", detail: "Layout, suggestions and autocorrect", icon: "keyboard")
            }
            SettingsDivider(leading: 52)
            NavigationLink(value: SettingsDestination.textProcessing) {
                SettingsLink(title: "AI & vocabulary", detail: "AI cleanup and preferred spellings", icon: "wand.and.stars")
            }
            SettingsDivider(leading: 52)
            NavigationLink(value: SettingsDestination.history) {
                SettingsLink(title: "History & feedback", detail: "Review, rate and export dictations", icon: "clock.arrow.circlepath")
            }
        }
        .buttonStyle(.plain)
    }
}

/// Refreshes cleanup availability while this page is visible.
@MainActor
struct TextProcessingSettingsCard: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var aiCleanup = TyprSettings().aiCleanup
    @State private var cleanupReason = TranscriptCleanupProduction.unavailableReason
    @State private var engine = CleanupEnginePreferences().engine
    @State private var hasAPIKey = AnthropicKeyStore().hasKey
    @State private var keyDraft = ""

    var body: some View {
        VStack(spacing: 24) {
            SettingsSection(title: "AI cleanup") {
                SettingsToggle(title: "Clean up dictations", detail: toggleDetail, isOn: $aiCleanup)
                    .onChange(of: aiCleanup) { _, enabled in TyprSettings().aiCleanup = enabled }
                SettingsDivider()
                Picker("Cleanup engine", selection: $engine) {
                    ForEach(CleanupEngine.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .accessibilityIdentifier("cleanup-engine")
                .onChange(of: engine) { _, selected in
                    CleanupEnginePreferences().engine = selected
                    refresh()
                }
                if engine == .anthropic {
                    SettingsDivider()
                    anthropicKey
                }
                if let reason = cleanupReason {
                    Text(reason).font(.subheadline).foregroundStyle(TyprTheme.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.bottom, 14)
                }
            }
            VocabularySettingsCard()
        }
        .onAppear(perform: refresh)
        .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
    }

    private func refresh() {
        TranscriptCleanupProduction.invalidateAvailability()
        aiCleanup = TyprSettings().aiCleanup
        cleanupReason = TranscriptCleanupProduction.unavailableReason
        engine = CleanupEnginePreferences().engine
        hasAPIKey = AnthropicKeyStore().hasKey
    }

    private var toggleDetail: String {
        switch engine {
        case .appleIntelligence: "Clearer text with on-device Apple Intelligence. Skipped in Verbatim; plain transcript if unavailable."
        case .anthropic: "Clearer text with Claude by Anthropic. Skipped in Verbatim; plain transcript if unavailable."
        }
    }

    /// The saved key is never shown again, only whether one exists.
    private var anthropicKey: some View {
        VStack(alignment: .leading, spacing: 10) {
            if hasAPIKey {
                HStack {
                    Label("Key saved", systemImage: "checkmark.circle")
                        .font(.body).foregroundStyle(TyprTheme.textBase)
                    Spacer(minLength: 12)
                    Button("Remove key", role: .destructive) {
                        AnthropicKeyStore().remove()
                        refresh()
                    }
                    .accessibilityIdentifier("remove-anthropic-key")
                }
            } else {
                SecureField("Anthropic API key", text: $keyDraft)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("anthropic-key-field")
                Button("Save key") {
                    guard AnthropicKeyStore().save(keyDraft) else { return }
                    keyDraft = ""
                    refresh()
                }
                .disabled(!AnthropicKeyStore.canSave(keyDraft))
                .accessibilityIdentifier("save-anthropic-key")
            }
            Text("Dictations, the app you dictate in, the text around the cursor and your vocabulary are sent to Anthropic. Requires internet; plain transcript if unavailable. With Full Access on, text you type with the Typr keyboard (up to 200 characters before the cursor) is also sent to Anthropic for next-word predictions.")
                .font(.footnote).foregroundStyle(TyprTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}
