import Foundation

/// Hex's `numbers_only` (processor.rs): a transcript of digits or English number words, with
/// punctuation and joiners between them, has nothing to rewrite.
enum CleanupNumbers {
    private static let words: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty",
        "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand", "million", "billion"
    ]
    /// Words that join numbers but are not numbers themselves.
    private static let joiners: Set<String> = ["and", "point", "minus", "negative"]

    static func only(_ transcript: String) -> Bool {
        var anyNumber = false
        for token in transcript.split(whereSeparator: { $0.isWhitespace || $0 == "-" }) {
            let word = token.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            if word.isEmpty { continue }
            if word.unicodeScalars.allSatisfy({ (48...57).contains($0.value) || $0 == "." || $0 == "," })
                || words.contains(word.lowercased()) {
                anyNumber = true
            } else if !joiners.contains(word.lowercased()) {
                return false
            }
        }
        return anyNumber
    }
}
