import Foundation

/// Export selection is independent of the disclosure state in the UI.
enum DictationLogExport: String, CaseIterable, Identifiable {
    case improvement, complete
    var id: Self { self }
    var label: String {
        switch self {
        case .improvement: "Recognition & cleanup improvement"
        case .complete: "Complete diagnostic log"
        }
    }

    static let limitations = "Human reference is optional and unverified. Accepted means the guard allowed an answer, not that it is correct. No audio is retained: ASR accuracy cannot be established from text alone. Vocabulary hints are best effort, not attributable word corrections. Final text is provided output, not proof of insertion. Missing stages in older entries must not be inferred."

    func text(for entries: [DictationLogEntry]) -> String {
        let header = self == .improvement
            ? "Typr recognition & cleanup improvement log · export v2\n" + Self.limitations
            : "Typr complete diagnostic log · export v2\n" + Self.limitations
        return ([header] + entries.map { self == .improvement ? $0.improvementText : $0.plainText })
            .joined(separator: "\n\n────────\n\n")
    }
}

extension DictationLogEntry {
    var improvementLines: [String] {
        var lines = [
            "ID: \(id.uuidString)",
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
            lines.append("Prompt: \(promptRevision); guard: \(guardRevision)")
            if context.cleanupEngine == CleanupEngine.anthropic.rawValue {
                lines.append("Cleanup model: Anthropic \(AnthropicCleanupRequest.model) (cloud)")
            } else {
                lines.append("Cleanup model: on-device Apple FoundationModels (exact model version unavailable)")
            }
        } else if context.cleanupPath == .upstream {
            lines.append("Upstream: \(upstreamOutcome ?? "not recorded")\(upstreamReason.map { "; \($0)" } ?? "")")
        }
        if let terms = vocabularyTermsLine {
            lines.append(terms)
        } else if let terms = context.vocabularySnapshot {
            lines.append("Active vocabulary: \(terms.text.isEmpty ? "(none)" : terms.text)\(terms.truncated ? " [TRUNCATED]" : "")")
        } else if context.vocabularyCount > 0 {
            lines.append("Active vocabulary spellings: not recorded")
        }
        return lines
    }

    /// Every saved vocabulary term, quoted so multi-word terms stay unambiguous.
    var vocabularyTermsLine: String? {
        guard let terms = context.vocabularyTerms else { return nil }
        let applied = switch context.vocabularyEnabled {
        case true?: "applied"
        case false?: "saved, not applied"
        case nil: "application not recorded"
        }
        let list = terms.isEmpty ? "(none)" : terms.map { String(reflecting: $0) }.joined(separator: ", ")
        return "Vocabulary terms (\(terms.count); \(applied)): \(list)"
    }

    /// Only a complete exact match may be abbreviated; matching truncated prefixes prove nothing.
    var improvementText: String {
        var sections = [improvementLines.joined(separator: "\n")]
        var previous: [(String, DictationLogText)] = []
        for (title, field) in [
            ("Recognized", recognized), ("Cleanup input (after vocabulary)", aiInput ?? recognized),
            ("Model answer — \(answerLabel)", aiAnswer), ("Cleanup output actually used", cleanupOutput),
            ("After style formatting", formattedText), ("Final text provided", finalText)
        ] {
            guard let field else {
                sections.append("\(title): not recorded")
                continue
            }
            if !field.truncated, let same = previous.first(where: { !$0.1.truncated && $0.1.text == field.text }) {
                sections.append("\(title): unchanged from [\(same.0)]")
            } else {
                sections.append(Self.exportField(title, field))
                previous.append((title, field))
            }
        }
        for (title, pass) in [("Vocabulary before cleanup", firstSpellingPass), ("Vocabulary after formatting", secondSpellingPass)] {
            if pass?.totalChanges != 0 {
                sections.append(title + ":\n" + spellingLines(pass).joined(separator: "\n"))
            }
        }
        sections.append(expectedText.map { Self.exportField("Desired final text (human reference)", $0) }
            ?? "Desired final text: not supplied (not a labelled training example)")
        if let feedbackNote { sections.append(Self.exportField("Human feedback", feedbackNote)) }
        return sections.joined(separator: "\n\n")
    }

    static func exportField(_ title: String, _ field: DictationLogText) -> String {
        let warning = field.truncated ? " [TRUNCATED; original \(field.originalUTF8Bytes) UTF-8 bytes]" : ""
        return "\(title)\(warning):\n\(field.text.isEmpty ? "(empty)" : field.text)"
    }
}
