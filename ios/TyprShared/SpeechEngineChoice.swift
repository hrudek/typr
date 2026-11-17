import Foundation

/// The speech engines Typr can use. Stored raw values must never change: the user's explicit
/// choice is persisted in the App Group (`TyprSettings.preferredSpeechEngine`). No stored value
/// (nil) means the user never chose; Typr then keeps its original automatic behavior (Apple Speech
/// when available, else Parakeet V2).
nonisolated enum SpeechEngineChoice: String, CaseIterable, Codable, Sendable {
    case appleSpeech = "apple-speech"
    case parakeetV2 = "parakeet-v2"
    case whisperLargeV3Turbo = "whisper-large-v3-turbo"
    case parakeetV3 = "parakeet-v3"
    case orukeet = "orukeet"
    case cohereTranscribe = "cohere-transcribe"

    /// The name in the UI, the dictation log and `LocalTranscribing.displayName`.
    var displayName: String {
        switch self {
        case .appleSpeech: "Apple Speech"
        case .parakeetV2: "Parakeet V2"
        case .whisperLargeV3Turbo: "Whisper Large V3 Turbo"
        case .parakeetV3: "Parakeet V3"
        case .orukeet: "Orukeet"
        case .cohereTranscribe: "Cohere Transcribe"
        }
    }

    /// The name in settings values, messages and the system's background task title.
    var shortName: String {
        self == .whisperLargeV3Turbo ? "Whisper" : displayName
    }

    /// Reaches this iPhone only through its Download button in the app; never downloaded by
    /// choosing or preparing it.
    var requiresExplicitDownload: Bool {
        self == .whisperLargeV3Turbo || self == .parakeetV3 || self == .orukeet || self == .cohereTranscribe
    }

    /// Has model files on this iPhone that the user can delete; iOS manages Apple Speech's assets.
    var hasDeletableModel: Bool {
        self != .appleSpeech
    }

    /// The engine behind a transcriber's display name; nil for test or unknown engines.
    init?(displayName: String) {
        guard let match = Self.allCases.first(where: { $0.displayName == displayName }) else { return nil }
        self = match
    }

    /// One sentence for the settings section.
    var summary: String {
        switch self {
        case .appleSpeech:
            "Apple's on-device SpeechTranscriber. iOS manages its speech assets and may download them when first used."
        case .parakeetV2:
            "NVIDIA Parakeet TDT 0.6B V2 through FluidAudio, running on this iPhone. Downloaded from Hugging Face on first use."
        case .whisperLargeV3Turbo:
            "OpenAI Whisper Large V3 Turbo (Argmax WhisperKit, Core ML), running on this iPhone. About 627 MB, downloaded only when you tap Download."
        case .parakeetV3:
            "NVIDIA Parakeet TDT 0.6B V3 through FluidAudio (Core ML), running on this iPhone. About 483 MB, downloaded only when you tap Download."
        case .orukeet:
            "Oruk AI's Orukeet, trained further from NVIDIA Parakeet TDT 0.6B V3, through FluidAudio (Core ML), running on this iPhone. Experimental INT8 build. About 555 MB, downloaded only when you tap Download."
        case .cohereTranscribe:
            "Cohere Transcribe 03-2026 (2B parameters) through FluidAudio (Core ML, INT8), running on this iPhone. About 2.19 GB, downloaded only when you tap Download."
        }
    }

    /// The languages Typr uses the engine for, in the settings section.
    var languageSummary: String {
        switch self {
        case .appleSpeech: "German and English, as installed by iOS"
        case .parakeetV2: "English only"
        case .whisperLargeV3Turbo: "German and English, or automatic detection"
        case .parakeetV3: "25 European languages including German and English, detected automatically"
        case .orukeet: "25 European languages including German and English, always detected automatically"
        case .cohereTranscribe:
            "14 languages including German and English, no detection: automatic uses your first iPhone language it supports, else English"
        }
    }

    /// Whether German dictation is recognized. Parakeet V2 is English-only: Typr warns but
    /// never blocks German or changes the engine.
    var recognizesGerman: Bool {
        self != .parakeetV2
    }
}
