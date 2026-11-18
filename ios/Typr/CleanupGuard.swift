import Foundation

nonisolated enum CleanupGuard {
    static let revision = "hex-ios-536cffef"

    static func wordCount(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: .byWords) { word, _, _, _ in
            if word != nil { count += 1 }
        }
        return count
    }

    private static let negations: Set<String> = [
        "not", "no", "never", "none", "nothing", "nobody", "nowhere", "neither", "nor",
        "cannot", "can't", "cant", "don't", "dont", "doesn't", "doesnt", "didn't", "didnt",
        "won't", "wont", "wouldn't", "wouldnt", "shouldn't", "shouldnt", "couldn't", "couldnt",
        "isn't", "isnt", "aren't", "arent", "wasn't", "wasnt", "weren't", "werent",
        "hasn't", "hasnt", "haven't", "havent", "hadn't", "hadnt", "mustn't", "mustnt",
        "needn't", "neednt", "ain't", "aint",
    ]

    static func isAcceptable(original: String, cleaned: String) -> Bool {
        let originalText = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedText = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !originalText.isEmpty, !cleanedText.isEmpty else { return false }

        guard cleanedText.count <= originalText.count * 3 / 2 + 16 else { return false }
        guard digits(in: originalText) == digits(in: cleanedText) else { return false }

        let originalWords = words(in: originalText)
        let cleanedWords = words(in: cleanedText)
        guard !originalWords.isEmpty, !cleanedWords.isEmpty else { return false }
        guard cleanedWords.count <= originalWords.count * 2 + 4 else { return false }

        guard negationCounts(in: originalText) == negationCounts(in: cleanedText) else {
            return false
        }

        let shared = sharedWordCount(originalWords, cleanedWords)
        guard Double(shared) / Double(cleanedWords.count) >= 0.5 else { return false }
        if !(originalWords.count <= 6 && cleanedWords.count <= 3) {
            guard Double(shared) / Double(originalWords.count) >= 0.5 else { return false }
        }
        return true
    }

    private static func digits(in text: String) -> [Character] {
        Array(text.filter(\.isNumber))
    }

    private static func words(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if character == "'" || character == "’" {
                if !current.isEmpty {
                    current.append("'")
                }
            } else if !current.isEmpty {
                result.append(trimTrailingApostrophes(current))
                current = ""
            }
        }
        if !current.isEmpty {
            result.append(trimTrailingApostrophes(current))
        }
        return result
    }

    private static func trimTrailingApostrophes(_ word: String) -> String {
        var trimmed = word
        while trimmed.hasSuffix("'") {
            trimmed.removeLast()
        }
        return trimmed
    }

    private static func negationCounts(in text: String) -> [String: Int] {
        let allWords = words(in: text)
        var counts: [String: Int] = [:]
        var index = 0
        while index < allWords.count {
            if allWords[index] == "no", index + 1 < allWords.count, allWords[index + 1] == "wait" {
                index += 2
                continue
            }
            if negations.contains(allWords[index]) {
                counts[allWords[index], default: 0] += 1
            }
            index += 1
        }
        return counts
    }

    private static func sharedWordCount(_ original: [String], _ cleaned: [String]) -> Int {
        var remaining: [String: Int] = [:]
        for word in original {
            remaining[word, default: 0] += 1
        }
        var shared = 0
        for word in cleaned {
            if let count = remaining[word], count > 0 {
                remaining[word] = count - 1
                shared += 1
            }
        }
        return shared
    }
}
