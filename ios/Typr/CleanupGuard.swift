import Foundation

/// Checks a model answer against the transcript before it is pasted. The on-device model applies
/// Hex's "Lists" rule to ordinary sentences and repeats words; the answer is then dropped and the
/// recognized text is used, as for an empty answer.
enum CleanupGuard {
    static let revision = "list-repeat-v1"

    static func rejection(answer: String, transcript: String) -> CleanupFailureReason? {
        if invents(list: answer, transcript: transcript) { return .unjustifiedList }
        if repeatsAWord(answer: answer, transcript: transcript) { return .repeatedWord }
        return nil
    }

    static func wordCount(_ text: String) -> Int {
        words(text).count
    }

    private static let listLine = try! Regex(#"^\s*\d+[.)]\s"#)
    private static let enumerationCue = try! Regex(
        #"\b(erstens|zweitens|drittens|firstly|secondly|thirdly|first|second|third|(punkt|point|nummer|number|schritt|step)\s+(eins|zwei|drei|one|two|three|\d+))\b|\d+[.)]\s"#)
        .ignoresCase()

    private static func invents(list answer: String, transcript: String) -> Bool {
        let items = answer.split(whereSeparator: \.isNewline).filter { $0.contains(listLine) }
        return items.count >= 2 && !transcript.contains(enumerationCue)
    }

    private static func repeatsAWord(answer: String, transcript: String) -> Bool {
        repeats(in: answer).subtracting(repeats(in: transcript)).isEmpty == false
    }

    private static func repeats(in text: String) -> Set<String> {
        let tokens = words(text).map { $0.lowercased() }
        return Set(zip(tokens, tokens.dropFirst()).filter { $0.0 == $0.1 }.map(\.0))
    }

    private static func words(_ text: String) -> [String] {
        var result: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .byWords) { word, _, _, _ in
            if let word { result.append(word) }
        }
        return result
    }
}
