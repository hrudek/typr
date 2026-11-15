import CoreML
import Foundation
import OSLog
import WhisperKit

/// Typr's Whisper decoding choices as plain values, so tests can check them without WhisperKit
/// types. `decodingOptions` maps them one to one.
nonisolated struct WhisperDecodingPlan: Equatable, Sendable {
    /// Always transcribe in the spoken language; never translate.
    let translates: Bool
    /// "de", "en", or nil for automatic detection.
    let languageCode: String?
    /// True only for automatic: WhisperKit's default (`!usePrefillPrompt`, false) would force English.
    let detectLanguage: Bool
    let usePrefillPrompt: Bool
    let skipSpecialTokens: Bool
    let withoutTimestamps: Bool
    let wordTimestamps: Bool
    /// Long captures are split at pauses (energy VAD) instead of hard 30-second windows.
    let chunksByVoiceActivity: Bool
    /// Typr never passes vocabulary as a Whisper prompt; vocabulary is post-processing only.
    let usesPromptTokens: Bool

    init(language: DictationLanguage) {
        translates = false
        languageCode = language.whisperLanguageCode
        detectLanguage = language.whisperLanguageCode == nil
        usePrefillPrompt = true
        skipSpecialTokens = true
        withoutTimestamps = true
        wordTimestamps = false
        chunksByVoiceActivity = true
        usesPromptTokens = false
    }

    var decodingOptions: DecodingOptions {
        DecodingOptions(
            verbose: false,
            task: translates ? .translate : .transcribe,
            language: languageCode,
            usePrefillPrompt: usePrefillPrompt,
            detectLanguage: detectLanguage,
            skipSpecialTokens: skipSpecialTokens,
            withoutTimestamps: withoutTimestamps,
            wordTimestamps: wordTimestamps,
            promptTokens: nil,
            chunkingStrategy: chunksByVoiceActivity ? .vad : ChunkingStrategy.none
        )
    }
}

/// The pinned model's real sequential specialization steps, not equally weighted percentages.
nonisolated enum WhisperPreparationComponent: String, CaseIterable, Sendable {
    case melSpectrogram = "MelSpectrogram"
    case textDecoder = "TextDecoder"
    case audioEncoder = "AudioEncoder"

    var computeUnits: MLComputeUnits {
        switch self {
        case .melSpectrogram: WhisperModelSpec.melComputeUnits
        case .textDecoder: WhisperModelSpec.textDecoderComputeUnits
        case .audioEncoder: WhisperModelSpec.audioEncoderComputeUnits
        }
    }

    /// Keep each prewarm awaited before announcing or allocating the next component.
    /// Preserve the caller's isolation; the closure lets tests verify ordering/failure without
    /// allocating real model weights.
    static func prepare(
        optimizing: Bool,
        progressHandler: @Sendable (ModelPreparationProgress) -> Void,
        isolation: isolated (any Actor)? = #isolation,
        load: (WhisperPreparationComponent) async throws -> Void
    ) async throws {
        for component in allCases {
            try Task.checkCancellation()
            progressHandler(component.progress(optimizing: optimizing))
            try await load(component)
        }
        try Task.checkCancellation()
    }

    // Three sequential specializations, the final load, and validation. These units are
    // milestones, not equal durations. Keep the app's Core ML fraction indeterminate.
    static let totalPreparationStages: Int64 = 5

    func progress(optimizing: Bool) -> ModelPreparationProgress {
        let step: Int
        let name: String
        switch self {
        case .melSpectrogram: (step, name) = (1, "audio features")
        case .textDecoder: (step, name) = (2, "text decoder")
        case .audioEncoder: (step, name) = (3, "audio encoder")
        }
        let verb = optimizing ? "Optimizing" : "Loading"
        return ModelPreparationProgress(fractionCompleted: nil,
            detail: "\(verb) Whisper \(name) · Step \(step) of 3",
            stageProgress: (Int64(step - 1), Self.totalPreparationStages))
    }
}

/// Whisper Large V3 Turbo on this iPhone through WhisperKit. Preparation is local only: it never
/// downloads (no `WhisperKit.download`, `download: false`, a Typr tokenizer set before loading so
/// WhisperKit's Hub tokenizer fallback is unreachable). Only `WhisperModelInstaller` downloads.
/// The loader exclusively owns the non-Sendable `WhisperKit` until it transfers the completed
/// instance into this actor. It is released by ARC (never `unloadModels()` while a transcription
/// may hold it), and Typr never holds two instances.
actor WhisperTranscriber: LocalTranscribing {
    enum TranscriberError: LocalizedError, Equatable {
        case notInstalled
        case notPrepared
        case silentAudio
        case emptyTranscript
        case corruptModel(String)
        case preparationFailed(String)
        /// Specialization is expected and the storage it needs is not free (bytes available).
        case insufficientStorage(Int64)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                "Whisper Large V3 Turbo is not downloaded. Download it under Speech engine."
            case .notPrepared:
                "Whisper Large V3 Turbo is not ready."
            case .silentAudio:
                "The recording is too quiet for Whisper. Try speaking closer to the microphone."
            case .emptyTranscript:
                "Whisper returned no text. Please try dictating again."
            case .corruptModel(let detail):
                "The Whisper model on this iPhone could not be loaded: \(detail) Download Whisper again."
            case .preparationFailed(let detail):
                "Whisper could not be prepared: \(detail) Open Typr and try preparing it again. iOS controls background resources."
            case .insufficientStorage(let available):
                "Whisper must be optimized for this iPhone first, which needs about "
                    + ByteCountFormatter.string(fromByteCount: WhisperModelSpec.optimizationStorageBytes, countStyle: .file)
                    + " of free storage ("
                    + ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
                    + " is free). Free up storage, then prepare Whisper again."
            }
        }
    }

    private nonisolated static let logger = Logger(subsystem: "dev.rudek.typr", category: "WhisperPreparation")
    nonisolated static let loadingDetail = "Loading Whisper"
    nonisolated static let optimizingDetail = "Optimizing Whisper for this iPhone. This can take a few minutes."

    nonisolated let displayName = SpeechEngineChoice.whisperLargeV3Turbo.displayName

    private let store: WhisperModelStore
    private let preparedLanguage: DictationLanguage
    private let availableCapacity: @Sendable () -> Int64?
    private let environment: String
    private var kit: WhisperKit?

    init(
        store: WhisperModelStore = .production,
        language: DictationLanguage,
        availableCapacity: (@Sendable () -> Int64?)? = nil,
        environment: String = WhisperPreparationPlan.currentEnvironment()
    ) {
        self.store = store
        self.preparedLanguage = language
        self.availableCapacity = availableCapacity ?? { store.availableCapacity() }
        self.environment = environment
    }

    var languageName: String {
        Self.languageName(for: preparedLanguage)
    }

    /// The dictation log's language for a capture: what Whisper was asked to recognize.
    nonisolated static func languageName(for language: DictationLanguage) -> String {
        switch language {
        case .automatic: "Automatic (detected by Whisper)"
        case .german: "German"
        case .english: "English"
        }
    }

    nonisolated static var computeOptions: ModelComputeOptions {
        ModelComputeOptions(
            melCompute: WhisperModelSpec.melComputeUnits,
            audioEncoderCompute: WhisperModelSpec.audioEncoderComputeUnits,
            textDecoderCompute: WhisperModelSpec.textDecoderComputeUnits
        )
    }

    /// The loaded decoder must have V3's vocabulary; anything else is a wrong or damaged model.
    nonisolated static func validateLogitsSize(_ size: Int?) throws {
        guard size == WhisperModelSpec.expectedLogitsSize else {
            throw TranscriberError.corruptModel("unexpected vocabulary size \(size.map(String.init) ?? "unknown").")
        }
    }

    /// An amplitude gate, not a speech detector: it must not discard ordinary quiet speech.
    /// WhisperKit's default EnergyVAD threshold (0.02 RMS, about -34 dBFS) is intended for
    /// chunk boundaries and rejected valid low-level microphone recordings before inference.
    /// Use 0.005 RMS (about -46 dBFS) here, keeping a floor against silence/faint room hum.
    /// WhisperKit 1.1.1's decoder no-speech probability is not implemented, so removing the
    /// gate altogether would allow Whisper to hallucinate text for silence.
    nonisolated static func containsSpeech(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        return EnergyVAD(energyThreshold: 0.005).voiceActivity(in: samples).contains(true)
    }

    /// Chunk texts joined with single spaces, trimmed.
    nonisolated static func joinedText(_ texts: [String]) -> String {
        texts.joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    func prepare(
        progressHandler: @escaping @Sendable (ModelPreparationProgress) -> Void
    ) async throws {
        guard kit == nil else { return }
        // Exact files and marker, or stop: preparation never downloads.
        guard store.isInstalled else { throw TranscriberError.notInstalled }
        // Before any model work (including the tokenizer): stop if specialization is expected
        // and the storage it needs is not free.
        let record = store.preparationRecord
        let plan = WhisperPreparationPlan.decide(record: record, environment: environment,
                                                 availableBytes: availableCapacity())
        if case .insufficientStorage(let available) = plan {
            throw TranscriberError.insufficientStorage(available)
        }

        progressHandler(ModelPreparationProgress(fractionCompleted: nil, detail: "Reading the Whisper tokenizer"))
        let tokenizer: TyprWhisperTokenizer
        do {
            tokenizer = try await TyprWhisperTokenizer.load(from: store.tokenizerFolder)
        } catch {
            store.removeMarker()
            throw TranscriberError.corruptModel(error.localizedDescription)
        }
        try Task.checkCancellation()

        progressHandler(ModelPreparationProgress(
            fractionCompleted: nil,
            detail: plan == .optimize ? Self.optimizingDetail : Self.loadingDetail
        ))
        // Marked before Core ML starts: if iOS terminates Typr while specializing, the next
        // preparation expects specialization again and checks storage first.
        store.writePreparationRecord(WhisperPreparationRecord(loadedEnvironment: record.loadedEnvironment,
                                                              inProgress: true))
        let kit: WhisperKit
        do {
            kit = try await loadKit(tokenizer: tokenizer, optimizing: plan == .optimize,
                                    progressHandler: progressHandler)
        } catch {
            store.writePreparationRecord(WhisperPreparationRecord(loadedEnvironment: record.loadedEnvironment,
                                                                  inProgress: false))
            throw error
        }
        store.writePreparationRecord(WhisperPreparationRecord(loadedEnvironment: environment, inProgress: false))
        // Skipped with the loader above; without it language prefill and detection are wrong.
        kit.textDecoder.isModelMultilingual = true
        try Task.checkCancellation()
        self.kit = kit
        progressHandler(ModelPreparationProgress(fractionCompleted: 1, detail: "Whisper ready"))
    }

    /// Local only. Prewarming specializes the three models one at a time and releases each
    /// before the real load, so specialization never holds all model weights at once (WhisperKit's
    /// documented peak-memory trade-off; a cached load costs about twice as long, under a second).
    // Task-local construction keeps the non-Sendable kit disconnected from actor state while
    // the sequential loader closure uses it. Only the fully loaded instance is transferred in.
    private nonisolated func loadKit(
        tokenizer: TyprWhisperTokenizer,
        optimizing: Bool,
        progressHandler: @escaping @Sendable (ModelPreparationProgress) -> Void
    ) async throws -> sending WhisperKit {
        let config = WhisperKitConfig(
            modelFolder: store.modelFolder.path,
            tokenizerFolder: store.tokenizerFolder,
            computeOptions: Self.computeOptions,
            verbose: false,
            logLevel: .none,
            prewarm: false,
            load: false,
            download: false
        )
        let kit = try await WhisperKit(config)
        // Set before loading: loadModels() then skips its tokenizer loader (and its Hub fallback).
        kit.tokenizer = tokenizer
        do {
            // WhisperKit's whole-model prewarm has no per-component callback. Use its public
            // model-loading API with the same compute units and prewarm semantics: each load
            // releases its weights before the next, preserving the storage/memory guard.
            try await WhisperPreparationComponent.prepare(
                optimizing: optimizing, progressHandler: progressHandler
            ) { component in
                let model: (any WhisperMLModel)?
                switch component {
                case .melSpectrogram: model = kit.featureExtractor as? any WhisperMLModel
                case .textDecoder: model = kit.textDecoder as? any WhisperMLModel
                case .audioEncoder: model = kit.audioEncoder as? any WhisperMLModel
                }
                guard let model else {
                    throw TranscriberError.corruptModel("Missing \(component.rawValue) loader.")
                }
                try await model.loadModel(
                    at: store.modelFolder.appendingPathComponent("\(component.rawValue).mlmodelc"),
                    computeUnits: component.computeUnits,
                    prewarmMode: true
                )
            }
            try Task.checkCancellation()
            progressHandler(ModelPreparationProgress(fractionCompleted: nil,
                detail: "Loading the prepared Whisper models",
                stageProgress: (3, WhisperPreparationComponent.totalPreparationStages)))
            try await kit.loadModels()
            try Task.checkCancellation()
            progressHandler(ModelPreparationProgress(fractionCompleted: nil,
                detail: "Checking the Whisper model",
                stageProgress: (4, WhisperPreparationComponent.totalPreparationStages)))
            try Self.validateLogitsSize(kit.textDecoder.logitsSize)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TranscriberError {
            throw error
        } catch {
            // Resource denial (including background Core ML restrictions) is not evidence of
            // corrupt downloaded files. Do not tell the person to download the model again.
            // Technical metadata only: descriptions can contain private paths or payloads.
            let failure = error as NSError
            Self.logger.error("Core ML preparation failed: domain=\(failure.domain, privacy: .public) code=\(failure.code)")
            if let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError {
                Self.logger.error("Core ML underlying failure: domain=\(underlying.domain, privacy: .public) code=\(underlying.code)")
            }
            throw TranscriberError.preparationFailed(error.localizedDescription)
        }
        return kit
    }

    func transcribe(_ audioURL: URL) async throws -> String {
        try await transcribe(audioURL, vocabulary: [], language: preparedLanguage)
    }

    func transcribe(_ audioURL: URL, vocabulary: [String]) async throws -> String {
        try await transcribe(audioURL, vocabulary: vocabulary, language: preparedLanguage)
    }

    /// `vocabulary` is deliberately unused: Whisper gets no prompt; Typr's spelling passes and
    /// cleanup apply the vocabulary afterwards.
    func transcribe(_ audioURL: URL, vocabulary: [String], language: DictationLanguage) async throws -> String {
        // A local strong reference keeps this capture's model alive even if the actor's is dropped.
        guard let kit else { throw TranscriberError.notPrepared }
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioURL.path)
        guard Self.containsSpeech(samples) else { throw TranscriberError.silentAudio }
        let results = try await kit.transcribe(
            audioArray: samples,
            decodeOptions: WhisperDecodingPlan(language: language).decodingOptions
        )
        try Task.checkCancellation()
        let text = Self.joinedText(results.map(\.text))
        guard !text.isEmpty else { throw TranscriberError.emptyTranscript }
        return text
    }
}
