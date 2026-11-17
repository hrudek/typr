@preconcurrency import CoreML
import FluidAudio
import Foundation
import OSLog

/// Cohere Transcribe 03-2026 on this iPhone through FluidAudio's `CoherePipeline`. Preparation is
/// local only: it loads the pinned files with `CoherePipeline.loadModels` and never calls
/// `ModelHub`, which downloads more than Typr pins and follows the repository's main branch. Only
/// `CohereModelInstaller` downloads.
///
/// Cohere has no language detection: every transcription is conditioned on one language.
actor CohereTranscriber: LocalTranscribing {
    enum TranscriberError: LocalizedError, Equatable {
        case notInstalled
        case notPrepared
        case emptyTranscript
        case corruptModel(String)
        case preparationFailed(String)
        /// Specialization is expected and the storage it needs is not free (bytes available).
        case insufficientStorage(Int64)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                "Cohere Transcribe is not downloaded. Download it under Speech engine."
            case .notPrepared:
                "Cohere Transcribe is not ready."
            case .emptyTranscript:
                "Cohere Transcribe did not detect any speech."
            case .corruptModel(let detail):
                "The Cohere Transcribe model on this iPhone could not be loaded: \(detail) Download Cohere Transcribe again."
            case .preparationFailed(let detail):
                "Cohere Transcribe could not be prepared: \(detail) Open Typr and try preparing it again. iOS controls background resources."
            case .insufficientStorage(let available):
                "Cohere Transcribe must be optimized for this iPhone first, which needs about "
                    + ByteCountFormatter.string(fromByteCount: CohereModelSpec.optimizationStorageBytes, countStyle: .file)
                    + " of free storage ("
                    + ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
                    + " is free). Free up storage, then prepare Cohere Transcribe again."
            }
        }
    }

    private nonisolated static let logger = Logger(subsystem: "dev.rudek.typr", category: "CoherePreparation")
    nonisolated static let loadingDetail = "Loading Cohere Transcribe"
    nonisolated static let optimizingDetail = "Optimizing Cohere Transcribe for this iPhone. This can take several minutes."

    nonisolated let displayName = SpeechEngineChoice.cohereTranscribe.displayName

    private let store: CohereModelStore
    private let preparedLanguage: DictationLanguage
    private let availableCapacity: @Sendable () -> Int64?
    private let environment: String
    private let pipeline = CoherePipeline()
    private var models: CoherePipeline.LoadedModels?

    init(
        store: CohereModelStore = .production,
        language: DictationLanguage,
        availableCapacity: (@Sendable () -> Int64?)? = nil,
        environment: String = ModelPreparationPlan.currentEnvironment(modelRevision: CohereModelSpec.modelRevision)
    ) {
        self.store = store
        self.preparedLanguage = language
        self.availableCapacity = availableCapacity ?? { store.availableCapacity() }
        self.environment = environment
    }

    var languageName: String {
        Self.languageName(for: preparedLanguage)
    }

    /// The dictation log's language for a capture: the language Cohere Transcribe was given.
    nonisolated static func languageName(
        for language: DictationLanguage,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        switch language {
        case .automatic:
            "Automatic (\(cohereLanguage(for: language, preferredLanguages: preferredLanguages).englishName), from iPhone languages)"
        case .german: "German"
        case .english: "English"
        }
    }

    /// German and English pass through. Automatic uses the first iPhone language Cohere supports,
    /// else English.
    nonisolated static func cohereLanguage(
        for language: DictationLanguage,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> CohereAsrConfig.Language {
        switch language {
        case .german: return .german
        case .english: return .english
        case .automatic:
            for identifier in preferredLanguages {
                if let code = Locale.Language(identifier: identifier).languageCode?.identifier,
                   let supported = CohereAsrConfig.Language(rawValue: code) {
                    return supported
                }
            }
            return .english
        }
    }

    func prepare(
        progressHandler: @escaping @Sendable (ModelPreparationProgress) -> Void
    ) async throws {
        guard models == nil else { return }
        guard store.isInstalled else { throw TranscriberError.notInstalled }
        let record = store.preparationRecord
        let plan = ModelPreparationPlan.decide(record: record, environment: environment,
                                               availableBytes: availableCapacity(),
                                               requiredBytes: CohereModelSpec.optimizationStorageBytes)
        if case .insufficientStorage(let available) = plan {
            throw TranscriberError.insufficientStorage(available)
        }

        progressHandler(ModelPreparationProgress(fractionCompleted: nil, detail: "Reading the Cohere Transcribe vocabulary"))
        do {
            try CohereVocabulary.check(store.vocabularyURL)
        } catch {
            store.removeMarker()
            throw TranscriberError.corruptModel(error.localizedDescription)
        }
        try Task.checkCancellation()

        // Marked before Core ML starts: if iOS terminates Typr while specializing, the next
        // preparation expects specialization again and checks storage first.
        store.writePreparationRecord(ModelPreparationRecord(loadedEnvironment: record.loadedEnvironment,
                                                            inProgress: true))
        let models: CoherePipeline.LoadedModels
        do {
            models = try await loadModels(optimizing: plan == .optimize, progressHandler: progressHandler)
        } catch {
            store.writePreparationRecord(ModelPreparationRecord(loadedEnvironment: record.loadedEnvironment,
                                                                inProgress: false))
            throw error
        }
        store.writePreparationRecord(ModelPreparationRecord(loadedEnvironment: environment, inProgress: false))
        try Task.checkCancellation()
        self.models = models
        progressHandler(ModelPreparationProgress(fractionCompleted: 1, detail: "Cohere Transcribe ready"))
    }

    /// `CoherePipeline.loadModels` loads encoder and decoder in one call (its result has no public
    /// initializer), so the continued task sees one model-loading stage and the final check.
    nonisolated static func loadingProgress(optimizing: Bool) -> ModelPreparationProgress {
        ModelPreparationProgress(fractionCompleted: nil,
                                 detail: optimizing ? optimizingDetail : loadingDetail,
                                 stageProgress: (0, ModelPreparationProgress.milestoneCount))
    }

    nonisolated static let checkingProgress = ModelPreparationProgress(
        fractionCompleted: nil, detail: "Checking the Cohere Transcribe model",
        stageProgress: (4, ModelPreparationProgress.milestoneCount))

    private nonisolated func loadModels(
        optimizing: Bool,
        progressHandler: @escaping @Sendable (ModelPreparationProgress) -> Void
    ) async throws -> CoherePipeline.LoadedModels {
        do {
            progressHandler(Self.loadingProgress(optimizing: optimizing))
            let models = try await CoherePipeline.loadModels(
                encoderDir: store.modelFolder, decoderDir: store.modelFolder, vocabDir: store.vocabularyFolder,
                decoderVariant: .v2, computeUnits: CohereModelSpec.computeUnits)
            progressHandler(Self.checkingProgress)
            try Task.checkCancellation()
            return models
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Resource denial (including background Core ML restrictions) is not evidence of
            // corrupt downloaded files. Do not tell the person to download the model again.
            // Technical metadata only: descriptions can contain private paths or payloads.
            let failure = error as NSError
            Self.logger.error("Core ML preparation failed: domain=\(failure.domain, privacy: .public) code=\(failure.code)")
            throw TranscriberError.preparationFailed(error.localizedDescription)
        }
    }

    func transcribe(_ audioURL: URL) async throws -> String {
        try await transcribe(audioURL, vocabulary: [], language: preparedLanguage)
    }

    func transcribe(_ audioURL: URL, vocabulary: [String]) async throws -> String {
        try await transcribe(audioURL, vocabulary: vocabulary, language: preparedLanguage)
    }

    func transcribe(_ audioURL: URL, vocabulary: [String], language: DictationLanguage) async throws -> String {
        guard let models else { throw TranscriberError.notPrepared }
        let samples = try AudioConverter().resampleAudioFile(audioURL)
        let result: CoherePipeline.TranscriptionResult
        do {
            result = try await pipeline.transcribeLong(audio: samples, models: models,
                                                       language: Self.cohereLanguage(for: language))
        } catch CohereAsrError.invalidInput {
            // FluidAudio's only invalid input: audio too short for one mel frame.
            throw TranscriberError.emptyTranscript
        }
        try Task.checkCancellation()
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriberError.emptyTranscript }
        return text
    }
}
