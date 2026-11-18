import SwiftUI

extension DictationLogEntry {
    var vocabularyLabel: String {
        switch context.vocabularyEnabled {
        case true?: "Vocabulary: On (\(context.vocabularyCount) terms)"
        case false?: "Vocabulary: Off"
        case nil: "Vocabulary: Not recorded (\(context.vocabularyCount) active terms)"
        }
    }

    func spellingLines(_ pass: DictationLogSpellingPass?) -> [String] {
        guard let pass else { return ["Replacement details not recorded (older entry or pass not reached)."] }
        guard pass.totalChanges > 0 else { return ["No replacements."] }
        var lines = pass.changes.map { change in
            "\(String(reflecting: change.before.text)) → \(String(reflecting: change.after.text)) (\(change.source == "built-in" ? "built-in" : "term"): \(String(reflecting: change.term.text)))\(change.before.truncated || change.after.truncated || change.term.truncated ? " [truncated]" : "")"
        }
        if pass.totalChanges > pass.changes.count {
            lines.append("\(pass.totalChanges - pass.changes.count) more replacements not retained (limit: \(DictationLogSpellingPass.maximumReplacements) per pass).")
        }
        return lines
    }

    var improvementLines: [String] {
        var lines = [
            "App: \(context.appVersion) (\(context.appBuild)); iOS \(context.systemVersion)",
            "Status: \(status.label)",
            "Recognition: \(context.speechEngine); language: \(context.speechLanguage); dictation language: \(context.dictationLanguage ?? "not recorded")",
            "Cleanup context: \(context.cleanupContextSource.map { "\($0), \(context.cleanupContextCharacters ?? 0) characters" } ?? "none or not recorded")",
            "Style: \(context.style); selected cleanup: \(context.cleanupPath.rawValue)",
            vocabularyLabel
        ]
        if let failure = asrFailure { lines.append("ASR failure: \(failure.rawValue)") }
        if context.cleanupPath == .typr {
            lines.append("Typr: \(cleanupOutcome ?? "not recorded"); answer: \(answerLabel)")
            if context.cleanupEngine == CleanupEngine.anthropic.rawValue {
                lines.append("Cleanup model: Anthropic \(AnthropicCleanupRequest.model) (cloud)")
            } else {
                lines.append("Cleanup model: on-device Apple FoundationModels (exact model version unavailable)")
            }
        } else if context.cleanupPath == .upstream {
            lines.append("Upstream: \(upstreamOutcome ?? "not recorded")\(upstreamReason.map { "; \($0)" } ?? "")")
        }
        return lines
    }
}

struct DictationLogDetail: View {
    let store: DictationLogStore
    let entryID: UUID
    var focusesNote = false
    @Environment(\.dismiss) private var dismiss
    @State private var showsPipeline = false
    @State private var confirmingDelete = false

    private var entry: DictationLogEntry? { store.entry(entryID) }

    var body: some View {
        Group {
            if let entry {
                List {
                    DictationCopyableTextSection(
                        title: "Final text", field: entry.finalText,
                        footer: "\(entry.context.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(entry.sourceLabel)\(entry.status == .finished ? "" : " · \(entry.status.label)")")
                    DictationRatingSection(store: store, entry: entry)
                    DictationFeedbackEditor(store: store, entry: entry, focusesNoteOnAppear: focusesNote)
                    if let problem = store.storageProblem {
                        Section {
                            Text(problem).font(.footnote).foregroundStyle(.red)
                            Button("Retry storage") { store.retry() }
                        }
                    }
                    Section {
                        DisclosureGroup("Pipeline details", isExpanded: $showsPipeline) {
                            pipeline(entry)
                        }
                    }
                }
                .toolbar {
                    Button("Delete", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                }
                .confirmationDialog("Delete this dictation?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) {
                        store.delete(entryID)
                        dismiss()
                    }
                }
            } else {
                ContentUnavailableView("Dictation not available", systemImage: "text.badge.minus",
                    description: Text("It may still be loading or was deleted."))
            }
        }
        .navigationTitle("Dictation")
        .navigationBarTitleDisplayMode(.inline)
        .task { store.loadEntry(entryID, pin: true) }
        // Opened from the keyboard while the archive was still loading: try again once it is ready.
        .onChange(of: store.isLoading) { _, loading in if !loading { store.loadEntry(entryID, pin: true) } }
    }

    @ViewBuilder
    private func pipeline(_ entry: DictationLogEntry) -> some View {
        stage("Recognized", entry.recognized, previous: nil)
        stage("After vocabulary", entry.aiInput, previous: entry.recognized)
        stage("AI answer (\(entry.answerLabel))", entry.aiAnswer, previous: entry.aiInput ?? entry.recognized)
        stage("Cleanup output used", entry.cleanupOutput, previous: entry.aiAnswer ?? entry.aiInput ?? entry.recognized)
        stage("After style formatting", entry.formattedText, previous: entry.cleanupOutput)
        ForEach(entry.improvementLines, id: \.self) { Text($0).font(.footnote).textSelection(.enabled) }
        replacements("Vocabulary before cleanup", entry, entry.firstSpellingPass)
        replacements("Vocabulary after formatting", entry, entry.secondSpellingPass)
    }

    @ViewBuilder
    private func stage(_ title: String, _ field: DictationLogText?, previous: DictationLogText?) -> some View {
        if let field {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.footnote.weight(.medium)).foregroundStyle(TyprTheme.textMuted)
                if let previous, !field.truncated, !previous.truncated, field.text == previous.text {
                    Text("Unchanged").font(.subheadline).foregroundStyle(TyprTheme.textMuted)
                } else {
                    Text(field.text.isEmpty ? "(empty)" : field.text).font(.subheadline).textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private func replacements(_ title: String, _ entry: DictationLogEntry, _ pass: DictationLogSpellingPass?) -> some View {
        if let pass, pass.totalChanges > 0 {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.footnote.weight(.medium)).foregroundStyle(TyprTheme.textMuted)
                ForEach(Array(entry.spellingLines(pass).enumerated()), id: \.offset) { Text($0.element).font(.footnote).textSelection(.enabled) }
            }
        }
    }
}
