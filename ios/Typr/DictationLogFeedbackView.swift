import SwiftUI
import UIKit

/// Tapping the selected rating again removes it; categories, note and desired text stay.
struct DictationRatingSection: View {
    let store: DictationLogStore
    let entry: DictationLogEntry

    var body: some View {
        Section("Rating") {
            HStack(spacing: 12) {
                ratingButton("Good", value: "good", icon: "hand.thumbsup", tint: TyprTheme.success)
                ratingButton("Problem", value: "bad", icon: "hand.thumbsdown", tint: .orange)
            }
            .buttonStyle(.borderless)
            if entry.rating == "bad" {
                ForEach(DictationIssue.choices, id: \.0) { code, title in
                    let selected = entry.issues?.contains(code) == true
                    Button {
                        var issues = entry.issues ?? []
                        if selected { issues.removeAll { $0 == code } } else { issues.append(code) }
                        store.rate(entry.id, rating: "bad", issues: issues)
                    } label: {
                        Label(title, systemImage: selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(TyprTheme.textBase)
                    }
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    private func ratingButton(_ title: String, value: String, icon: String, tint: Color) -> some View {
        let selected = entry.rating == value
        return Button {
            store.rate(entry.id, rating: selected ? "unrated" : value)
        } label: {
            Label(title, systemImage: selected ? icon + ".fill" : icon)
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(selected ? Color.white : TyprTheme.textBase)
                .background(selected ? tint : TyprTheme.bgDeep, in: RoundedRectangle(cornerRadius: 10))
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One dictation text with an explicit Copy button. Copying happens only on tap.
struct DictationCopyableTextSection: View {
    let title: String
    let field: DictationLogText?
    var footer: String? = nil
    @State private var copied = false

    var body: some View {
        Section {
            if let field {
                Text(field.text.isEmpty ? "(empty)" : field.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if field.truncated {
                    Text("Shortened · original \(field.originalUTF8Bytes) UTF-8 bytes")
                        .font(.caption).foregroundStyle(TyprTheme.textMuted)
                }
            } else {
                Text("Not recorded").foregroundStyle(TyprTheme.textMuted)
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                if let field, !field.text.isEmpty {
                    Button {
                        UIPasteboard.general.string = field.text
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .textCase(nil)
                    .accessibilityLabel(copied ? "Copied \(title.lowercased())" : "Copy \(title.lowercased())")
                }
            }
        } footer: {
            if let footer { Text(footer) }
        }
    }
}

/// Note and desired text are both optional. An unchanged field is passed as nil so the store keeps it as saved.
struct DictationFeedbackEditor: View {
    let store: DictationLogStore
    let entry: DictationLogEntry
    var focusesNoteOnAppear = false
    @State private var note: String
    @State private var desired: String
    @State private var savedNote: String
    @State private var savedDesired: String
    @State private var didAutoFocus = false
    @FocusState private var noteFocused: Bool

    init(store: DictationLogStore, entry: DictationLogEntry, focusesNoteOnAppear: Bool = false) {
        self.store = store
        self.entry = entry
        self.focusesNoteOnAppear = focusesNoteOnAppear
        let note = entry.feedbackNote?.text ?? "", desired = entry.expectedText?.text ?? ""
        _note = State(initialValue: note); _savedNote = State(initialValue: note)
        _desired = State(initialValue: desired); _savedDesired = State(initialValue: desired)
    }

    private var dirty: Bool { note != savedNote || desired != savedDesired }
    private var withinLimit: Bool {
        note.utf8.count <= DictationLogText.maximumBytes && desired.utf8.count <= DictationLogText.maximumBytes
    }

    var body: some View {
        Section {
            TextField("What went wrong or could be better?", text: $note, axis: .vertical)
                .lineLimit(3...8)
                .focused($noteFocused)
                .accessibilityLabel("Note")
            TextField("Desired text (optional)", text: $desired, axis: .vertical)
                .lineLimit(2...8)
                .accessibilityLabel("Desired text")
            if dirty {
                Button("Save feedback") { save() }.disabled(!withinLimit)
            }
            if !withinLimit {
                Text("Too long: each field is limited to 4,000 UTF-8 bytes.")
                    .font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Feedback")
        } footer: {
            Text("Saved with this dictation on this iPhone and included in the JSON export.")
        }
        .onAppear {
            // One-shot: a List re-fires onAppear when the section scrolls back into view.
            guard focusesNoteOnAppear, !didAutoFocus else { return }
            didAutoFocus = true
            Task { try? await Task.sleep(for: .milliseconds(450)); noteFocused = true }
        }
        .onChange(of: entry.feedbackNote?.text) { _, value in
            if note == savedNote { note = value ?? "" }
            savedNote = value ?? ""
        }
        .onChange(of: entry.expectedText?.text) { _, value in
            if desired == savedDesired { desired = value ?? "" }
            savedDesired = value ?? ""
        }
        .onDisappear { if dirty && withinLimit { save() } }
    }

    private func save() {
        guard withinLimit else { return }
        store.saveFeedback(for: entry.id,
                           expectedText: desired == savedDesired ? nil : desired,
                           note: note == savedNote ? nil : note)
        savedNote = note; savedDesired = desired
        noteFocused = false
    }
}

struct DictationJSONShareSheet: UIViewControllerRepresentable {
    let url: URL
    let completion: @MainActor @Sendable () -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        let finished = completion
        controller.completionWithItemsHandler = { _, _, _, _ in
            Task { @MainActor in finished() }
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
