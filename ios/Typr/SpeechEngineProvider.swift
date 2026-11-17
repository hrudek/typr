import Foundation
import Speech

/// One engine's status in the settings section, read without starting model work.
nonisolated enum SpeechEngineAvailability: Equatable, Sendable {
    /// Ready to prepare without any download.
    case installed
    /// Usable after a download: Parakeet V2 on first preparation, Apple Speech assets by iOS,
    /// Whisper and Parakeet V3 only through their Download buttons. The text says which.
    case downloadRequired(String)
    case requiresNewerOS(String)
    case unsupportedDevice(String)
    case languageUnsupported(String)

    /// Whether choosing the engine can work at all on this iPhone and language.
    var isSupported: Bool {
        switch self {
        case .installed, .downloadRequired: true
        case .requiresNewerOS, .unsupportedDevice, .languageUnsupported: false
        }
    }

    var detail: String {
        switch self {
        case .installed: "Installed on this iPhone"
        case .downloadRequired(let text), .requiresNewerOS(let text),
             .unsupportedDevice(let text), .languageUnsupported(let text): text
        }
    }
}

/// Why an explicitly chosen engine cannot be used. Shown as the failure; Typr never switches to
/// another engine instead.
nonisolated enum SpeechEngineError: LocalizedError, Equatable {
    case notReady
    case requiresNewerOS(SpeechEngineChoice)
    case unsupportedDevice(SpeechEngineChoice)
    case languageUnsupported(SpeechEngineChoice, DictationLanguage)
    case notInstalled(SpeechEngineChoice)

    var errorDescription: String? {
        switch self {
        case .notReady:
            "No speech engine is ready yet."
        case .requiresNewerOS(let engine):
            "\(engine.displayName) requires iOS 26 or later. Choose another engine under Speech engine."
        case .unsupportedDevice(let engine):
            "\(engine.displayName) is not supported on this iPhone. Choose another engine under Speech engine."
        case .languageUnsupported(let engine, let language):
            language == .automatic
                ? "\(engine.displayName) does not support your preferred languages on this iPhone."
                : "\(engine.displayName) does not support \(language.label) on this iPhone. Choose another language or engine."
        case .notInstalled(let engine):
            "\(engine.displayName) is not downloaded. Download it under Speech engine."
        }
    }
}

/// Creates transcribers for the controller. Two paths, kept apart on purpose:
/// no engine chosen (nil) keeps the original automatic choice; an explicit engine returns exactly
/// that engine or throws `SpeechEngineError`, never a substitute.
@MainActor
protocol SpeechEngineProviding: AnyObject {
    /// The original behavior: Apple Speech when it is available (any availability candidate),
    /// else Parakeet V2. Apple Speech then prepares the strict locale for `language`.
    func automaticTranscriber(language: DictationLanguage) async -> any LocalTranscribing
    /// Exactly `engine`. Downloaded engines require a verified install; nothing here downloads them.
    func transcriber(for engine: SpeechEngineChoice, language: DictationLanguage) async throws -> any LocalTranscribing
    /// Installed without network, synchronously (the keyboard's `model.installed` flag, launch).
    /// Apple Speech reports false: its assets are known only asynchronously.
    func isInstalled(_ engine: SpeechEngineChoice) -> Bool
    /// OS, device, language and asset status for the settings section. Never starts model work.
    func availability(of engine: SpeechEngineChoice, language: DictationLanguage) async -> SpeechEngineAvailability
}

@MainActor
final class ProductionSpeechEngineProvider: SpeechEngineProviding {
    private let whisperStore: WhisperModelStore
    private let parakeetV3Store: ParakeetV3ModelStore

    init(whisperStore: WhisperModelStore = .production, parakeetV3Store: ParakeetV3ModelStore = .production) {
        self.whisperStore = whisperStore
        self.parakeetV3Store = parakeetV3Store
    }

    func automaticTranscriber(language: DictationLanguage) async -> any LocalTranscribing {
        if #available(iOS 26.0, *),
           AppleSpeechTranscriber.isAvailable,
           await AppleSpeechTranscriber.preferredLocale(language: language, strict: false) != nil {
            let strict = await AppleSpeechTranscriber.preferredLocale(language: language)
            return AppleSpeechTranscriber(locale: strict ?? AppleSpeechTranscriber.requestedLocale(for: language),
                                          language: language)
        }
        return ParakeetTranscriber()
    }

    func transcriber(for engine: SpeechEngineChoice, language: DictationLanguage) async throws -> any LocalTranscribing {
        switch engine {
        case .appleSpeech:
            guard #available(iOS 26.0, *) else { throw SpeechEngineError.requiresNewerOS(engine) }
            guard AppleSpeechTranscriber.isAvailable else { throw SpeechEngineError.unsupportedDevice(engine) }
            guard let locale = await AppleSpeechTranscriber.preferredLocale(language: language) else {
                throw SpeechEngineError.languageUnsupported(engine, language)
            }
            guard await AssetInventory.status(forModules: [SpeechTranscriber(locale: locale, preset: .transcription)]) != .unsupported else {
                throw SpeechEngineError.languageUnsupported(engine, language)
            }
            return AppleSpeechTranscriber(locale: locale, language: language)
        case .parakeetV2:
            return ParakeetTranscriber()
        case .whisperLargeV3Turbo:
            guard whisperStore.isInstalled else { throw SpeechEngineError.notInstalled(engine) }
            return WhisperTranscriber(store: whisperStore, language: language)
        case .parakeetV3:
            guard parakeetV3Store.isInstalled else { throw SpeechEngineError.notInstalled(engine) }
            return ParakeetV3Transcriber(store: parakeetV3Store, language: language)
        }
    }

    func isInstalled(_ engine: SpeechEngineChoice) -> Bool {
        switch engine {
        case .appleSpeech: false
        case .parakeetV2: ParakeetTranscriber.hasCachedModel
        case .whisperLargeV3Turbo: whisperStore.isInstalled
        case .parakeetV3: parakeetV3Store.isInstalled
        }
    }

    func availability(of engine: SpeechEngineChoice, language: DictationLanguage) async -> SpeechEngineAvailability {
        switch engine {
        case .appleSpeech:
            guard #available(iOS 26.0, *) else { return .requiresNewerOS("Requires iOS 26 or later") }
            return await AppleSpeechTranscriber.availability(language: language)
        case .parakeetV2:
            return ParakeetTranscriber.hasCachedModel
                ? .installed
                : .downloadRequired("Not downloaded. Typr downloads it from Hugging Face when you choose it.")
        case .whisperLargeV3Turbo:
            return whisperStore.isInstalled
                ? .installed
                : .downloadRequired("Not downloaded (\(WhisperModelSpec.downloadSizeLabel)).")
        case .parakeetV3:
            return parakeetV3Store.isInstalled
                ? .installed
                : .downloadRequired("Not downloaded (\(ParakeetV3ModelSpec.downloadSizeLabel)).")
        }
    }
}
