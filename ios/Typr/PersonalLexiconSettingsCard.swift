import SwiftUI

/// Source consent, not a switch for ordinary correction behavior.
struct PersonalLexiconSettingsCard: View {
    @State private var importer = PersonalLexiconImporter.shared
    @State private var contacts = PersonalLexiconImporter.shared.contactsEnabled
    @State private var vocabulary = PersonalLexiconImporter.shared.vocabularyEnabled
    @State private var requesting = false
    @State private var confirmDelete: Bool

    static let aboutImports = """
        Contacts: given names, family names, nicknames and companies. Typr asks for Contacts access; limited access imports only selected contacts.

        Dictation words: active custom vocabulary and words from recent finished dictations. Not rejected speech or model answers.

        Only words are shared with the keyboard on this iPhone, with Full Access. No phone numbers, addresses, sentences or audio are shared. Imported spellings stay literal and can appear as completions, independently of Learn from my typing.

        Delete imported words and Reset learning both delete this list and turn off both imports. Neither deletes contacts, custom vocabulary or the Dictation log.
        """
    static let deleteTitle = "Delete imported words?"
    static let deleteMessage = "Removes imported words and turns off both imports. Contacts, custom vocabulary and dictations stay."

    init(confirmDelete: Bool = false) {
        _confirmDelete = State(initialValue: confirmDelete)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSection(title: "Personal names and terms") {
                SettingsToggle(title: "Import contacts", detail: "Names, nicknames and companies.", isOn: $contacts)
                    .disabled(requesting)
                    .onChange(of: contacts) { _, enabled in
                        guard enabled != importer.contactsEnabled else { return }
                        requesting = true
                        Task {
                            await importer.setContacts(enabled)
                            contacts = importer.contactsEnabled
                            requesting = false
                        }
                    }
                SettingsDivider()
                SettingsToggle(title: "Import dictation words", detail: "Custom vocabulary and recent finished dictations.", isOn: $vocabulary)
                    .onChange(of: vocabulary) { _, enabled in importer.setVocabulary(enabled) }
                SettingsDivider()
                Button("Delete imported words", role: .destructive) { confirmDelete = true }
                    .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                    .padding(.horizontal, 16)
                SettingsDivider()
                SettingsDisclosure(title: "About imports", text: Self.aboutImports)
            }
            SettingsFooter("Words stay on this iPhone and reach the keyboard with Full Access. Imports are separate from typing learning.")
            if let problem = importer.problem {
                SettingsFooter(problem)
            }
        }
        .confirmationDialog(Self.deleteTitle, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete imported words", role: .destructive) {
                importer.clear()
                contacts = importer.contactsEnabled
                vocabulary = importer.vocabularyEnabled
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.deleteMessage)
        }
        .onAppear {
            contacts = importer.contactsEnabled
            vocabulary = importer.vocabularyEnabled
        }
    }
}
