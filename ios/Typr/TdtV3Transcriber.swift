@preconcurrency import CoreML
import FluidAudio
import Foundation
import OSLog

/// A model with NVIDIA Parakeet TDT 0.6B V3's architecture, installed as FluidAudio 0.15.5's four
/// compiled Core ML models (`TdtV3PreparationComponent`) beside the vocabulary (`TdtV3Vocabulary`).
protocol TdtV3ModelSpec: DownloadableModelSpec {
    /// The folder holding `<component>.mlmodelc` and the vocabulary.
    static func modelFolder(in store: ModelStore<Self>) -> URL
    /// FluidAudio's language filter reads the joint network's top-K outputs; greedy-only joints lack them.
    static var acceptsLanguageHint: Bool { get }
}

extension ModelStore where Spec: TdtV3ModelSpec {
    var modelFolder: URL {
        Spec.modelFolder(in: self)
    }

    var vocabularyURL: URL {
        modelFolder.appendingPathComponent(TdtV3Vocabulary.fileName)
    }
}

nonisolated struct TdtV3VocabularyError: ModelFileCheckError, Equatable {
    let engine: SpeechEngineChoice

    var errorDescription: String? {
        "The \(engine.displayName) vocabulary on this iPhone is damaged. Download \(engine.displayName) again."
    }
}

/// Reads `parakeet_vocab.json` locally: a JSON object from token ID to token, as FluidAudio 0.15.5's
/// `AsrModels` parses it for the 0.6B models, with exactly the IDs `0..<size`.
nonisolated enum TdtV3Vocabulary {
    static let fileName = "parakeet_vocab.json"
    /// The token count; the blank token is the next ID (FluidAudio `AsrModelVersion.v3.blankId`).
    static let size = 8_192

    static func load(from url: URL, for engine: SpeechEngineChoice) throws -> [Int: String] {
        guard let data = try? Data(contentsOf: url),
              let tokens = try? JSONDecoder().decode([String: String].self, from: data) else {
            throw TdtV3VocabularyError(engine: engine)
        }
        var vocabulary: [Int: String] = [:]
        for (key, token) in tokens {
            guard let id = Int(key) else { throw TdtV3VocabularyError(engine: engine) }
            vocabulary[id] = token
        }
        guard vocabulary.count == size, vocabulary.keys.allSatisfy({ (0..<size).contains($0) }) else {
            throw TdtV3VocabularyError(engine: engine)
        }
        return vocabulary
    }
}

nonisolated enum TdtV3PreparationComponent: String, CaseIterable, Sendable {
    case preprocessor = "Preprocessor"
    case decoder = "Decoder"
    case joint = "JointDecisionv3"
    case encoder = "Encoder"

    /// FluidAudio's defaults for these models: preprocessor on CPU, the rest on CPU and Neural
    /// Engine. No GPU, for the same background reasons as `WhisperModelSpec`.
    static let modelComputeUnits: MLComputeUnits = .cpuAndNeuralEngine

    var computeUnits: MLComputeUnits {
        self == .preprocessor ? .cpuOnly : Self.modelComputeUnits
    }

    var compiledFolderName: String {
        "\(rawValue).mlmodelc"
    }

    struct Loaded<Model> {
        let preprocessor: Model
        let decoder: Model
        let joint: Model
        let encoder: Model
    }

    static func prepare<Model>(
        engine: SpeechEngineChoice,
        optimizing: Bool,
        progressHandler: @Sendable (ModelPreparationProgress) -> Void,
        isolation: isolated (any Actor)? = #isolation,
        load: (TdtV3PreparationComponent) async throws -> Model
    ) async throws -> Loaded<Model> {
        let preprocessor = try await step(.preprocessor, engine: engine, optimizing: optimizing,
                                          progressHandler: progressHandler, load: load)
        let decoder = try await step(.decoder, engine: engine, optimizing: optimizing,
                                     progressHandler: progressHandler, load: load)
        let joint = try await step(.joint, engine: engine, optimizing: optimizing,
                                   progressHandler: progressHandler, load: load)
        let encoder = try await step(.encoder, engine: engine, optimizing: optimizing,
                                     progressHandler: progressHandler, load: load)
        try Task.checkCancellation()
        return Loaded(preprocessor: preprocessor, decoder: decoder, joint: joint, encoder: encoder)
    }

    private static func step<Model>(
        _ component: TdtV3PreparationComponent,
        engine: SpeechEngineChoice,
        optimizing: Bool,
        progressHandler: @Sendable (ModelPreparationProgress) -> Void,
        isolation: isolated (any Actor)? = #isolation,
        load: (TdtV3PreparationComponent) async throws -> Model
    ) async throws -> Model {
        try Task.checkCancellation()
        progressHandler(component.progress(engine: engine, optimizing: optimizing))
        return try await load(component)
    }

    func progress(engine: SpeechEngineChoice, optimizing: Bool) -> ModelPreparationProgress {
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
            detail: "\(verb) \(engine.displayName) \(name) · Step \(step) of 4",
            stageProgress: (Int64(step - 1), ModelPreparationProgress.milestoneCount))
    }
}

/// A TDT V3 model on this iPhone through FluidAudio. Preparation is local only: it loads the
/// installed files with Core ML directly and never calls FluidAudio's `AsrModels.load` or
/// `ModelHub`, which download missing files and delete and download a cache that fails to load.
/// Only the engine's `ModelInstaller` downloads.
actor TdtV3Transcriber<Spec: TdtV3ModelSpec>: LocalTranscribing {
    enum TranscriberError: LocalizedError, Equatable {
        case notInstalled
        case notPrepared
        case emptyTranscript
        case corruptModel(String)
        case preparationFailed(String)
        /// Specialization is expected and the storage it needs is not free (bytes available).
        case insufficientStorage(Int64)

        var errorDescription: String? {
            let name = Spec.engine.displayName
            return switch self {
            case .notInstalled:
                "\(name) is not downloaded. Download it under Speech engine."
            case .notPrepared:
                "\(name) is not ready."
            case .emptyTranscript:
                "\(name) did not detect any speech."
            case .corruptModel(let detail):
                "The \(name) model on this iPhone could not be loaded: \(detail) Download \(name) again."
            case .preparationFailed(let detail):
                "\(name) could not be prepared: \(detail) Open Typr and try preparing it again. iOS controls background resources."
            case .insufficientStorage(let available):
                "\(name) must be optimized for this iPhone first, which needs about "
                    + ByteCountFormatter.string(fromByteCount: Spec.optimizationStorageBytes, countStyle: .file)
                    + " of free storage ("
                    + ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
                    + " is free). Free up storage, then prepare \(name) again."
            }
        }

        var asrFailure: DictationLogASRFailure {
            switch self {
            case .notInstalled, .notPrepared, .insufficientStorage, .preparationFailed: .modelNotReady
            case .emptyTranscript: .noSpeech
            case .corruptModel: .other
            }
        }
    }

    private nonisolated static var logger: Logger {
        Logger(subsystem: "dev.rudek.typr", category: "\(Spec.storeFolderName)Preparation")
    }
    nonisolated static var loadingDetail: String { "Loading \(Spec.engine.displayName)" }
    nonisolated static var optimizingDetail: String {
        "Optimizing \(Spec.engine.displayName) for this iPhone. This can take a few minutes."
    }

    nonisolated let displayName = Spec.engine.displayName

    private let store: ModelStore<Spec>
    private let preparedLanguage: DictationLanguage
    private let availableCapacity: @Sendable () -> Int64?
    private let environment: String
    private var manager: AsrManager?

    init(
        store: ModelStore<Spec> = .production,
        language: DictationLanguage,
        availableCapacity: (@Sendable () -> Int64?)? = nil,
        environment: String = ModelPreparationPlan.currentEnvironment(modelRevision: Spec.modelRevision)
    ) {
        self.store = store
        self.preparedLanguage = language
        self.availableCapacity = availableCapacity ?? { store.availableCapacity() }
        self.environment = environment
    }

    var languageName: String {
        Self.languageName(for: preparedLanguage)
    }

    /// The dictation log's language for a capture: what the model was asked to recognize.
    nonisolated static func languageName(for language: DictationLanguage) -> String {
        let automatic = "Automatic (detected by \(Spec.engine.displayName))"
        guard Spec.acceptsLanguageHint else { return automatic }
        return switch language {
        case .automatic: automatic
        case .german: "German"
        case .english: "English"
        }
    }

    /// FluidAudio's script filter for the chosen language; automatic, or a model without the
    /// filter's outputs, leaves detection to the model.
    nonisolated static func languageHint(for language: DictationLanguage) -> Language? {
        guard Spec.acceptsLanguageHint else { return nil }
        return switch language {
        case .automatic: nil
        case .german: .german
        case .english: .english
        }
    }

    func prepare(
        progressHandler: @escaping @Sendable (ModelPreparationProgress) -> Void
    ) async throws {
        guard manager == nil else { return }
        guard store.isInstalled else { throw TranscriberError.notInstalled }
        let record = store.preparationRecord
        let plan = ModelPreparationPlan.decide(record: record, environment: environment,
                                               availableBytes: availableCapacity(),
                                               requiredBytes: Spec.optimizationStorageBytes)
        if case .insufficientStorage(let available) = plan {
            throw TranscriberError.insufficientStorage(available)
        }

        progressHandler(ModelPreparationProgress(fractionCompleted: nil, detail: "Reading the \(displayName) vocabulary"))
        let vocabulary: [Int: String]
        do {
            vocabulary = try TdtV3Vocabulary.load(from: store.vocabularyURL, for: Spec.engine)
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
        progressHandler(ModelPreparationProgress(fractionCompleted: 1, detail: "\(displayName) ready"))
    }

    private nonisolated func loadManager(
        vocabulary: [Int: String],
        optimizing: Bool,
        progressHandler: @escaping @Sendable (ModelPreparationProgress) -> Void
    ) async throws -> AsrManager {
        do {
            let models = try await TdtV3PreparationComponent.prepare(
                engine: Spec.engine, optimizing: optimizing, progressHandler: progressHandler
            ) { component in
                try await MLModel.load(
                    contentsOf: store.modelFolder.appendingPathComponent(component.compiledFolderName),
                    configuration: MLModelConfigurationUtils.defaultConfiguration(computeUnits: component.computeUnits)
                )
            }
            progressHandler(ModelPreparationProgress(fractionCompleted: nil,
                detail: "Checking the \(displayName) model",
                stageProgress: (4, ModelPreparationProgress.milestoneCount)))
            let asrModels = AsrModels(
                encoder: models.encoder, preprocessor: models.preprocessor, decoder: models.decoder, joint: models.joint,
                configuration: MLModelConfigurationUtils.defaultConfiguration(computeUnits: TdtV3PreparationComponent.modelComputeUnits),
                vocabulary: vocabulary, version: .v3)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(asrModels)
            try Task.checkCancellation()
            return manager
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
