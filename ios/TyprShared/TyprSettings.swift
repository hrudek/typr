import Foundation

/// Typr switches, stored in the App Group so the keyboard reads them too.
/// Each switch documents its default. Dictation log deliberately retains saved history while off;
/// other switches keep upstream's behavior when off.
@MainActor
struct TyprSettings {
    private enum Key {
        static let aiCleanup = "typr.aiCleanup"
        static let dictationLog = "typr.dictationLog"
        static let autocorrectGerman = "typr.autocorrectGerman"
        static let autocorrectEnglish = "typr.autocorrectEnglish"
        static let hideSuggestionBar = "typr.hideSuggestionBar"
        static let personalLearning = "keyboard.personalLearning"
        static let dictationLanguage = "typr.dictationLanguage"
        static let preferredSpeechEngine = "typr.preferredSpeechEngine"
    }

    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = UserDefaults(suiteName: KeyboardBridge.appGroup)) {
        self.defaults = defaults
    }

    /// Dictation cleanup. Off by default and retains the plain transcription path.
    var aiCleanup: Bool {
        get { defaults?.object(forKey: Key.aiCleanup) as? Bool ?? false }
        nonmutating set { defaults?.set(newValue, forKey: Key.aiCleanup) }
    }

    /// Collection only. Off interrupts pending log entries but deliberately keeps saved history.
    var dictationLog: Bool {
        get { defaults?.object(forKey: Key.dictationLog) as? Bool ?? true }
        nonmutating set { defaults?.set(newValue, forKey: Key.dictationLog) }
    }

    /// Quick feedback for this keyboard instance's newly inserted dictation. Off keeps existing UI.
    var dictationFeedbackStrip: Bool {
        get { defaults?.object(forKey: DictationFeedbackBridge.stripKey) as? Bool ?? false }
        nonmutating set { defaults?.set(newValue, forKey: DictationFeedbackBridge.stripKey) }
    }

    /// Independently selected autocorrect languages. Both default on.
    /// Retired experiment switches do not override the language selection.
    var autocorrectGerman: Bool {
        get { defaults?.object(forKey: Key.autocorrectGerman) as? Bool ?? true }
        nonmutating set { defaults?.set(newValue, forKey: Key.autocorrectGerman) }
    }

    var autocorrectEnglish: Bool {
        get { defaults?.object(forKey: Key.autocorrectEnglish) as? Bool ?? true }
        nonmutating set { defaults?.set(newValue, forKey: Key.autocorrectEnglish) }
    }

    /// Learn local touch calibration and word counts. Explicit keep protection still works while off.
    var personalLearning: Bool {
        get { defaults?.object(forKey: Key.personalLearning) as? Bool ?? true }
        nonmutating set { defaults?.set(newValue, forKey: Key.personalLearning) }
    }

    /// The dictation language (a picker, not a switch). Automatic, the default, keeps the
    /// previous speech-locale and cleanup-language behavior.
    var dictationLanguage: DictationLanguage {
        get { defaults?.string(forKey: Key.dictationLanguage).flatMap(DictationLanguage.init(rawValue:)) ?? .automatic }
        nonmutating set { defaults?.set(newValue.rawValue, forKey: Key.dictationLanguage) }
    }

    /// The speech engine the user explicitly chose (a picker, not a switch). nil, the default and
    /// any unknown stored value, keeps the original automatic choice (Apple Speech when available,
    /// else Parakeet V2). An explicit choice is never replaced by another engine.
    var preferredSpeechEngine: SpeechEngineChoice? {
        get { defaults?.string(forKey: Key.preferredSpeechEngine).flatMap(SpeechEngineChoice.init(rawValue:)) }
        nonmutating set {
            if let newValue {
                defaults?.set(newValue.rawValue, forKey: Key.preferredSpeechEngine)
            } else {
                defaults?.removeObject(forKey: Key.preferredSpeechEngine)
            }
        }
    }

    /// The full keyboard without its suggestion bar: the keys move up and the keyboard gets
    /// shorter. Autocorrect on space still applies. Off by default; the bar is shown.
    var hideSuggestionBar: Bool {
        get { defaults?.object(forKey: Key.hideSuggestionBar) as? Bool ?? false }
        nonmutating set { defaults?.set(newValue, forKey: Key.hideSuggestionBar) }
    }
}
