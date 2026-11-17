import Foundation

/// Word counting for the dictation log. Hex checks no model answer, so neither does Typr: the
/// revision only marks log entries written without the former answer guard.
enum CleanupGuard {
    static let revision = "none"

    static func wordCount(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: .byWords) { word, _, _, _ in
            if word != nil { count += 1 }
        }
        return count
    }
}
