import Foundation

/// Where Orukeet lives in the App Group, for Hex (`TyprOrukeetModel`) and the keyboard.
nonisolated enum TyprOrukeetStore {
    static let revision = "419d7f79e290127e202a0f610509868d314743eb"

    static var directory: URL {
        SpeechModelStore.root.appendingPathComponent("typr-orukeet-\(revision.prefix(7))", isDirectory: true)
    }

    /// Compiled with Parakeet Ultra's file names, so the keyboard loads it as it loads Ultra.
    static var compiledDirectory: URL { directory.appendingPathComponent("compiled", isDirectory: true) }

    static func isInstalled(in directory: URL = directory) -> Bool {
        SpeechModelStore.isComplete(directory.appendingPathComponent("compiled", isDirectory: true))
    }
}

/// Settings › Typr › Orukeet in the keyboard: where upstream's Speech model in keyboard would
/// run Parakeet Ultra (`KeyboardParakeetPlan`: switch on, iPhone and keyboard memory, no
/// two-language dictation, one of Ultra's 25 languages), the keyboard loads Orukeet instead
/// once Hex has installed it. Orukeet's INT8 encoder has the size of Ultra's (594 MB), so
/// Ultra's keyboard budget (`KeyboardParakeetBudget`) holds for it. Anywhere else, or with
/// the setting off, the keyboard follows `KeyboardParakeetPlan` unchanged.
nonisolated enum TyprOrukeetKeyboardPlan {
    /// The language the keyboard dictates in with Orukeet, or nil for upstream's plan.
    static func resolve(
        orukeetEnabled: Bool,
        installed: Bool,
        keyboardModelEnabled: Bool,
        physicalMemory: UInt64,
        twoLanguageEnabled: Bool,
        language: String?,
        keyboardLimit: Int?
    ) -> String? {
        guard orukeetEnabled, installed, keyboardModelEnabled,
              KeyboardParakeetSettings.fits(physicalMemory: physicalMemory),
              MultilingualParakeetSettings.fits(physicalMemory: physicalMemory),
              !twoLanguageEnabled,
              keyboardLimit.map({ $0 >= KeyboardParakeetBudget.requiredLimit }) ?? true,
              let language, MultilingualParakeetSettings.supports(language) else { return nil }
        return language
    }

    static func current(
        defaults: UserDefaults? = UserDefaults(suiteName: KeyboardBridge.appGroup),
        preferred: [String] = Locale.preferredLanguages,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
        installed: Bool = TyprOrukeetStore.isInstalled()
    ) -> String? {
        let languages = LanguageSettings(defaults: defaults)
        let keyboard = KeyboardParakeetSettings(defaults: defaults)
        return resolve(
            orukeetEnabled: TyprSettings(defaults: defaults).orukeet,
            installed: installed,
            keyboardModelEnabled: keyboard.isEnabled,
            physicalMemory: physicalMemory,
            twoLanguageEnabled: TwoLanguageDictationSettings(defaults: defaults).isEnabled,
            language: languages.dictationLanguage
                ?? languages.keyboardDictationLanguage(preferred: preferred)
                ?? preferred.first,
            keyboardLimit: keyboard.keyboardLimit
        )
    }
}
