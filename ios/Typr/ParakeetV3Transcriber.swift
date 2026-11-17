@preconcurrency import CoreML
import FluidAudio
import Foundation
import OSLog

/// The pinned model's sequential Core ML loads, largest last, not equally weighted percentages.
nonisolated enum ParakeetV3PreparationComponent: String, CaseIterable, Sendable {
    case preprocessor = "Preprocessor"
    case decoder = "Decoder"
    case joint = "JointDecisionv3"
    case encoder = "Encoder"

    var computeUnits: MLComputeUnits {
        self == .preprocessor ? ParakeetV3ModelSpec.preprocessorComputeUnits : ParakeetV3ModelSpec.modelComputeUnits
    }

    /// Keep each load awaited before announcing or allocating the next component. The closure
    /// lets tests verify ordering/failure without allocating real model weights.
    static func prepare(
        optimizing: Bool,
        progressHandler: @Sendable (ModelPreparationProgress) -> Void,
        isolation: isolated (any Actor)? = #isolation,
        load: (ParakeetV3PreparationComponent) async throws -> Void
    ) async throws {
        for component in allCases {
            try Task.checkCancellation()
            progressHandler(component.progress(optimizing: optimizing))
            try await load(component)
        }
        try Task.checkCancellation()
    }

    // Four sequential loads and the final check: `ModelPreparationProgress.milestoneCount`.
    func progress(optimizing: Bool) -> ModelPreparationProgress {
        let step: Int
        let name: String
        switch self {
        case .preprocessor: (step, name) = (1, "audio features")
        case .decoder: (step, name) = (2, "decoder")
        case .joint: (step, name) = (3, "joint network")
        case .encoder: (step, name) = (4, "audio encoder")
        }
        let verb = optimizing ? "Optimizing" : "Loading"
        return ModelPreparationProgress(fractionCompleted: nil,
            detail: "\(verb) Parakeet V3 \(name) · Step \(step) of 4",
            stageProgress: (Int64(step - 1), ModelPreparationProgress.milestoneCount))
    }
}

/// NVIDIA Parakeet TDT 0.6B V3 on this iPhone through FluidAudio. Preparation is local only: it
/// loads the pinned files with Core ML directly and never calls FluidAudio's `AsrModels.load` or
/// `ModelHub`, which download missing files and delete and download a cache that fails to load.
/// Only `ParakeetV3ModelInstaller` downloads.
actor ParakeetV3Transcriber: LocalTranscribing {
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
                "Parakeet V3 is not downloaded. Download it under Speech engine."
            case .notPrepared:
                "Parakeet V3 is not ready."
            case .emptyTranscript:
                "Parakeet V3 did not detect any speech."
            case .corruptModel(let detail):
                "The Parakeet V3 model on this iPhone could not be loaded: \(detail) Download Parakeet V3 again."
            case .preparationFailed(let detail):
                "Parakeet V3 could not be prepared: \(detail) Open Typr and try preparing it again. iOS controls background resources."
            case .insufficientStorage(let available):
                "Parakeet V3 must be optimized for this iPhone first, which needs about "
                    + ByteCountFormatter.string(fromByteCount: ParakeetV3ModelSpec.optimizationStorageBytes, countStyle: .file)
                    + " of free storage ("
                    + ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
                    + " is free). Free up storage, then prepare Parakeet V3 again."
            }
        }
    }

    private nonisolated static let logger = Logger(subsystem: "dev.rudek.typr", category: "ParakeetV3Preparation")
    nonisolated static let loadingDetail = "Loading Parakeet V3"
    nonisolated static let optimizingDetail = "Optimizing Parakeet V3 for this iPhone. This can take a few minutes."

    nonisolated let displayName = SpeechEngineChoice.parakeetV3.displayName

    private let store: ParakeetV3ModelStore
    private let preparedLanguage: DictationLanguage
    private let availableCapacity: @Sendable () -> Int64?
    private let environment: String
    private var manager: AsrManager?

    init(
        store: ParakeetV3ModelStore = .production,
        language: DictationLanguage,
        availableCapacity: (@Sendable () -> Int64?)? = nil,
        environment: String = ModelPreparationPlan.currentEnvironment(modelRevision: ParakeetV3ModelSpec.modelRevision)
    ) {
        self.store = store
        self.preparedLanguage = language
        self.availableCapacity = availableCapacity ?? { store.availableCapacity() }
        self.environment = environment
    }

    var languageName: String {
        Self.languageName(for: preparedLanguage)
    }

    /// The dictation log's language for a capture: what Parakeet V3 was asked to recognize.
    nonisolated static func languageName(for language: DictationLanguage) -> String {
        switch language {
        case .automatic: "Automatic (detected by Parakeet V3)"
        case .german: "German"
        case .english: "English"
        }
    }

    /// FluidAudio's script filter for the chosen language; automatic leaves detection to the model.
    nonisolated static func languageHint(for language: DictationLanguage) -> Language? {
        switch language {
        case .automatic: nil
        case .german: .german
        case .english: .english
        }
    }

    func prepare(
        progressHandler: @escaping @Sendable (ModelPreparationProgress) -> Void
    ) async throws {
        guard manager == nil else { return }
        // Exact files and marker, or stop: preparation never downloads.
        guard store.isInstalled else { throw TranscriberError.notInstalled }
        let record = store.preparationRecord
        let plan = ModelPreparationPlan.decide(record: record, environment: environment,
                                               availableBytes: availableCapacity(),
                                               requiredBytes: ParakeetV3ModelSpec.optimizationStorageBytes)
        if case .insufficientStorage(let available) = plan {
            throw TranscriberError.insufficientStorage(available)
        }

        progressHandler(ModelPreparationProgress(fractionCompleted: nil, detail: "Reading the Parakeet V3 vocabulary"))
        let vocabulary: [Int: String]
        do {
            vocabulary = try ParakeetV3Vocabulary.load(from: store.vocabularyURL)
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
        store.writePreparationRecord(ModelPreparationRecord(loadedEnvironment: record.loadedEnvironment,
                                                            inProgress: true))
        let manager: AsrManager
        do {
            manager = try await loadManager(vocabulary: vocabulary, optimizing: plan == .optimize,
                                            progressHandler: progressHandler)
        } catch {
            store.writePreparationRecord(ModelPreparationRecord(loadedEnvironment: record.loadedEnvironment,
                                                                inProgress: false))
            throw error
        }
        store.writePreparationRecord(ModelPreparationRecord(loadedEnvironment: environment, inProgress: false))
        try Task.checkCancellation()
        self.manager = manager
        progressHandler(ModelPreparationProgress(fractionCompleted: 1, detail: "Parakeet V3 ready"))
    }

    private nonisolated func loadManager(
        vocabulary: [Int: String],
        optimizing: Bool,
        progressHandler: @escaping @Sendable (ModelPreparationProgress) -> Void
    ) async throws -> AsrManager {
        do {
            var models: [ParakeetV3PreparationComponent: MLModel] = [:]
            try await ParakeetV3PreparationComponent.prepare(
                optimizing: optimizing, progressHandler: progressHandler
            ) { component in
                models[component] = try await MLModel.load(
                    contentsOf: store.modelFolder.appendingPathComponent("\(component.rawValue).mlmodelc"),
                    configuration: MLModelConfigurationUtils.defaultConfiguration(computeUnits: component.computeUnits)
                )
            }
            progressHandler(ModelPreparationProgress(fractionCompleted: nil,
                detail: "Checking the Parakeet V3 model",
                stageProgress: (4, ModelPreparationProgress.milestoneCount)))
            guard let preprocessor = models[.preprocessor], let decoder = models[.decoder],
                  let joint = models[.joint], let encoder = models[.encoder] else {
                throw TranscriberError.corruptModel("A Core ML model is missing.")
            }
            let asrModels = AsrModels(
                encoder: encoder, preprocessor: preprocessor, decoder: decoder, joint: joint,
                configuration: MLModelConfigurationUtils.defaultConfiguration(computeUnits: ParakeetV3ModelSpec.modelComputeUnits),
                vocabulary: vocabulary, version: .v3)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(asrModels)
            try Task.checkCancellation()
            return manager
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
            throw TranscriberError.preparationFailed(error.localizedDescription)
        }
    }

    func transcribe(_ audioURL: URL) async throws -> String {
        try await transcribe(audioURL, vocabulary: [], language: preparedLanguage)
    }

    func transcribe(_ audioURL: URL, vocabulary: [String]) async throws -> String {
        try await transcribe(audioURL, vocabulary: vocabulary, language: preparedLanguage)
    }

    /// `vocabulary` is deliberately unused: Typr's spelling passes and cleanup apply it afterwards.
    func transcribe(_ audioURL: URL, vocabulary: [String], language: DictationLanguage) async throws -> String {
        guard let manager else { throw TranscriberError.notPrepared }
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(audioURL, decoderState: &decoderState,
                                                  language: Self.languageHint(for: language))
        try Task.checkCancellation()
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriberError.emptyTranscript }
        return text
    }
}
