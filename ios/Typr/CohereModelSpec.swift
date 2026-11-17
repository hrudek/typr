import CoreML
import Foundation

/// Everything that pins Typr's Cohere Transcribe engine: Cohere Transcribe 03-2026 in FluidInference's
/// Core ML conversion, at an exact revision with every file's size. The files are the ones FluidAudio
/// 0.15.5's `CoherePipeline.loadModels` reads for its default INT8 encoder and `.v2` decoder
/// (`ModelNames.CohereTranscribe.requiredModels`), not the repository's other variants that
/// `ModelHub` would also fetch.
nonisolated enum CohereModelSpec: DownloadableModelSpec {
    struct Marker: Codable, Equatable, Sendable {
        var modelRepo = CohereModelSpec.modelRepo
        var modelRevision = CohereModelSpec.modelRevision
        var totalBytes = CohereModelSpec.totalBytes
    }

    static let engine = SpeechEngineChoice.cohereTranscribe
    static let storeFolderName = "CohereTranscribe"
    static let markerFileName = "typr-cohere-transcribe-installed.json"
    static let preparationFileName = "typr-cohere-transcribe-preparation.json"
    static var marker: Marker { Marker() }

    static let modelRepo = "FluidInference/cohere-transcribe-03-2026-coreml"
    static let modelRevision = "e1ce10d4cae2ca9a8b36cef5786fa3660f070050"

    /// The INT8 models' folder in the repository.
    static let modelFolderName = "q8"
    static let encoderFolder = "cohere_encoder.mlmodelc"
    static let decoderFolder = "cohere_decoder_cache_external_v2.mlmodelc"

    static let vocabularyFile = file("vocab.json", bytes: 338_520)

    static let modelFiles: [PinnedModelFile] = [
        file("q8/cohere_decoder_cache_external_v2.mlmodelc/analytics/coremldata.bin", bytes: 243),
        file("q8/cohere_decoder_cache_external_v2.mlmodelc/coremldata.bin", bytes: 1_562),
        file("q8/cohere_decoder_cache_external_v2.mlmodelc/metadata.json", bytes: 13_587),
        file("q8/cohere_decoder_cache_external_v2.mlmodelc/model.mil", bytes: 207_280),
        file("q8/cohere_decoder_cache_external_v2.mlmodelc/weights/weight.bin", bytes: 304_453_120),
        file("q8/cohere_encoder.mlmodelc/analytics/coremldata.bin", bytes: 243),
        file("q8/cohere_encoder.mlmodelc/coremldata.bin", bytes: 421),
        file("q8/cohere_encoder.mlmodelc/metadata.json", bytes: 2_587),
        file("q8/cohere_encoder.mlmodelc/model.mil", bytes: 2_444_649),
        file("q8/cohere_encoder.mlmodelc/weights/weight.bin", bytes: 1_881_964_672),
    ]

    static let allFiles: [PinnedModelFile] = [vocabularyFile] + modelFiles
    static var checkedFiles: [PinnedModelFile] { [vocabularyFile] }

    static let totalBytes: Int64 = 2_189_426_884

    static let storageHeadroomBytes: Int64 = 500_000_000

    /// Not measured for Cohere Transcribe. Whisper's first load needed about six times its
    /// 627 MB of weights (`WhisperModelSpec.optimizationStorageBytes`); this asks for about four
    /// times Cohere's, whose 1.9 GB encoder is INT8.
    static let optimizationStorageBytes: Int64 = 9_000_000_000

    /// `CohereAsrConfig.vocabSize`: token IDs `0..<vocabularySize`.
    static let vocabularySize = 16_384

    /// No GPU, for the same background reasons as `WhisperModelSpec`. FluidAudio defaults to `.all`.
    static let computeUnits: MLComputeUnits = .cpuAndNeuralEngine

    private static func file(_ path: String, bytes: Int64) -> PinnedModelFile {
        PinnedModelFile(repo: modelRepo, revision: modelRevision, path: path, bytes: bytes)
    }
}

/// The Cohere Transcribe model's store; see `ModelStore` for the layout and the meaning of "installed":
///
///     root/models/FluidInference/cohere-transcribe-03-2026-coreml/{vocab.json, q8/*.mlmodelc/…}
typealias CohereModelStore = ModelStore<CohereModelSpec>

extension ModelStore where Spec == CohereModelSpec {
    var vocabularyFolder: URL {
        repoFolder(CohereModelSpec.modelRepo)
    }

    var modelFolder: URL {
        vocabularyFolder.appendingPathComponent(CohereModelSpec.modelFolderName, isDirectory: true)
    }

    var vocabularyURL: URL {
        fileURL(for: CohereModelSpec.vocabularyFile)
    }
}

typealias CohereModelInstaller = ModelInstaller<CohereModelSpec>

extension ModelInstaller where Spec == CohereModelSpec {
    convenience init(
        store: CohereModelStore,
        downloader: any ModelFileDownloading,
        availableCapacity: (() -> Int64?)? = nil
    ) {
        self.init(store: store, downloader: downloader,
                  checkFiles: { try CohereVocabulary.check(store.vocabularyURL) },
                  availableCapacity: availableCapacity)
    }
}

nonisolated enum CohereVocabularyError: ModelFileCheckError, Equatable {
    case damaged

    var errorDescription: String? {
        "The Cohere Transcribe vocabulary on this iPhone is damaged. Download Cohere Transcribe again."
    }
}

/// Checks `vocab.json` locally: a JSON object from token ID to token, as `CoherePipeline` parses it,
/// with exactly the IDs `0..<vocabularySize`.
nonisolated enum CohereVocabulary {
    static func check(_ url: URL) throws {
        guard let data = try? Data(contentsOf: url),
              let tokens = try? JSONDecoder().decode([String: String].self, from: data),
              tokens.count == CohereModelSpec.vocabularySize,
              tokens.keys.allSatisfy({ Int($0).map { (0..<CohereModelSpec.vocabularySize).contains($0) } ?? false })
        else {
            throw CohereVocabularyError.damaged
        }
    }
}
