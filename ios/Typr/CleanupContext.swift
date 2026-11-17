import Foundation

/// What a dictation's cleanup knows besides its transcript, like Hex's context snapshot: the host
/// app and the text around the insertion point (Hex's `CaretText`, capped by `KeyboardCommand`),
/// plus the chosen dictation language for the log. The text is data only, kept in memory and never
/// written to the dictation log.
struct CleanupContext: Equatable, Sendable {
    var language: DictationLanguage = .automatic
    /// The host app's bundle ID, when the keyboard could name it.
    var application: String?
    var before = ""
    var selected = ""
    var after = ""

    /// Characters of caret text, for the log (never the text itself).
    var characters: Int { before.count + selected.count + after.count }
}
