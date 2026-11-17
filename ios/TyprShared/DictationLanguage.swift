import Foundation

/// The language the owner dictates in. Automatic keeps the previous behavior: Apple Speech uses the
/// first supported preferred language and cleanup may skip a language the model does not support.
/// An explicit language fixes the speech locale and tells cleanup which language to write.
/// To add a language: a case, its raw value (BCP 47 language code), label, speech locale and
/// cleanup instruction. Stored raw values must never change.
nonisolated enum DictationLanguage: String, CaseIterable, Codable, Sendable {
    case automatic
    case german = "de"
    case english = "en"

    /// The picker label, matching the English settings UI.
    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .german: "German"
        case .english: "English"
        }
    }

    /// The Apple Speech locale requested for an explicit language; nil for automatic.
    var speechLocaleIdentifier: String? {
        switch self {
        case .automatic: nil
        case .german: "de-DE"
        case .english: "en-US"
        }
    }

    /// The Whisper decoding language: nil for automatic (Whisper detects it), else "de" or "en".
    var whisperLanguageCode: String? {
        switch self {
        case .automatic: nil
        case .german, .english: rawValue
        }
    }

    /// Locale identifiers Apple Speech may prepare, in order. Automatic: preferred languages, the
    /// current locale, then en-US. An explicit language never falls back to another language:
    /// its default locale, then preferred/current locales of the same language ("de-CH"); Apple
    /// Speech fails with a clear reason when none is supported.
    func speechLocaleCandidates(preferred: [String], current: String) -> [String] {
        guard let speechLocaleIdentifier else {
            return availabilityLocaleCandidates(preferred: preferred, current: current)
        }
        let sameLanguage = (preferred + [current]).filter { Self.languageCode(of: $0) == rawValue }
        var seen = Set<String>()
        return ([speechLocaleIdentifier] + sameLanguage).filter { seen.insert($0).inserted }
    }

    /// The pre-engine-choice order (explicit locale first, then the automatic order). Used only
    /// when no engine was chosen, to decide between Apple Speech and Parakeet V2 exactly as before;
    /// the locale Apple Speech prepares comes from the strict `speechLocaleCandidates`.
    func availabilityLocaleCandidates(preferred: [String], current: String) -> [String] {
        var identifiers: [String] = []
        if let speechLocaleIdentifier { identifiers.append(speechLocaleIdentifier) }
        identifiers += preferred
        identifiers.append(current)
        identifiers.append("en-US")
        var seen = Set<String>()
        return identifiers.filter { seen.insert($0).inserted }
    }

    private static func languageCode(of identifier: String) -> String {
        String(identifier.prefix { $0 != "-" && $0 != "_" }).lowercased()
    }
}
