import UIKit

@MainActor
final class GermanAutocorrect {
    /// `nil` when the device has no German dictionary; only the built-in table works then.
    let checker: TextChecking?

    init(checker: TextChecking?) {
        self.checker = checker
    }

    static func system() -> GermanAutocorrect {
        let languages = UITextChecker.availableLanguages.filter { $0.hasPrefix("de") }
        let chosen = languages.first(where: { $0 == "de_DE" }) ?? languages.first
        guard let chosen else { return GermanAutocorrect(checker: nil) }
        return GermanAutocorrect(checker: SystemTextChecker(language: chosen))
    }

    func warmUp() {
        (checker as? SystemTextChecker)?.warmUp()
    }

    func isValid(_ word: String) -> Bool {
        guard let checker else { return false }
        return checker.isWordValid(word)
    }

    func guesses(for word: String) -> [String] {
        Array((checker?.guesses(for: word) ?? []).prefix(8))
    }

    /// English fixes that must not fire when German is on (`im` is a German word).
    func blocksEnglishFix(_ lower: String) -> Bool {
        if Self.blockedEnglishFixes.contains(lower) { return true }
        return lower.count >= 2 && isValid(lower)
    }

    // MARK: - Contextual noun suggestions

    /// A local cue is not a parser: nominalized verbs/adjectives remain ambiguous.
    /// Only the dictionary (never lowercase corpus frequency) establishes noun casing.
    func nounSuggestion(_ token: String, after previous: String?) -> String? {
        guard (3...32).contains(token.count), token == token.lowercased(),
              token.allSatisfy({ $0.isLetter }), let previous,
              Self.nounCues.contains(previous) else { return nil }
        let title = token.prefix(1).uppercased() + token.dropFirst()
        return isValid(title) ? title : nil
    }

    private static let nounCues: Set<String> = [
        "der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "eines",
        "am", "beim", "im", "ins", "zum", "zur", "vom", "mit", "ohne", "bei", "für", "von",
    ]

    // MARK: - Umlauts

    private static let digraphs: [(ascii: String, replacement: String)] = [
        ("ae", "ä"), ("oe", "ö"), ("ue", "ü"), ("ss", "ß"),
    ]

    /// Every combination of replacing each digraph occurrence (at most 4 occurrences), minus the identity.
    static func variants(of lower: String) -> [String] {
        spellings(of: lower) { chars, i in
            guard i + 1 < chars.count else { return nil }
            return digraphs.first { Array($0.ascii) == [chars[i], chars[i + 1]] }
        }
    }

    /// Every combination of swapping y and z (at most 4 occurrences), minus the identity: a German
    /// typing on QWERTY often hits the QWERTZ key (`okaz` for `okay`).
    static func keySwaps(of lower: String) -> [String] {
        spellings(of: lower) { chars, i in
            switch chars[i] {
            case "y": return ("y", "z")
            case "z": return ("z", "y")
            default: return nil
            }
        }
    }

    private static func spellings(of lower: String,
                                  replacement: ([Character], Int) -> (ascii: String, replacement: String)?) -> [String] {
        var parts: [[String]] = []
        let chars = Array(lower)
        var i = 0
        var occurrences = 0
        while i < chars.count {
            if let hit = replacement(chars, i) {
                occurrences += 1
                if occurrences > 4 { return [] }
                parts.append([hit.ascii, hit.replacement])
                i += hit.ascii.count
            } else {
                parts.append([String(chars[i])])
                i += 1
            }
        }
        var results = [""]
        for options in parts {
            results = results.flatMap { prefix in options.map { prefix + $0 } }
        }
        return results.filter { $0 != lower }
    }

    // MARK: - Typo cost

    private static let fold: [Character: Character] = ["ä": "a", "ö": "o", "ü": "u", "ß": "s"]

    /// Single-edit cost where an umlaut or ß in the target counts as a cheap 0.4 swap for its plain letter.
    func costAdjustedForUmlauts(from source: String, to target: String) -> Double? {
        let direct = AutocorrectEngine.singleEditKeyboardCost(from: source, to: target)
        let folded = String(target.map { Self.fold[$0] ?? $0 })
        guard folded != target else { return direct }
        // A missing umlaut ("fur" for "für") is cheaper than an ordinary
        // substitution, so it wins over the direct edit cost.
        let umlaut: Double?
        if folded == source {
            umlaut = 0.4
        } else if let base = AutocorrectEngine.singleEditKeyboardCost(from: source, to: folded) {
            umlaut = base + 0.4
        } else {
            umlaut = nil
        }
        switch (direct, umlaut) {
        case let (d?, u?): return min(d, u)
        case let (d?, nil): return d
        case let (nil, u?): return u
        case (nil, nil): return nil
        }
    }

    // MARK: - Built-in table

    /// Keys whose ASCII form is never a valid German or English word.
    static let blockedEnglishFixes: Set<String> = ["im"]
}
