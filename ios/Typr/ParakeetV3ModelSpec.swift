import CoreML
import Foundation

/// Everything that pins Typr's Parakeet V3 engine: NVIDIA Parakeet TDT 0.6B V3 in FluidInference's
/// Core ML conversion, at an exact revision with every file's size. The files are the ones
/// FluidAudio 0.15.5 loads for `AsrModelVersion.v3` with its default `.int8` encoder precision
/// (`ModelNames.ASR.requiredModelsV3` plus `parakeet_vocab.json`).
nonisolated enum ParakeetV3ModelSpec: DownloadableModelSpec {
    struct Marker: Codable, Equatable, Sendable {
        var modelRepo = ParakeetV3ModelSpec.modelRepo
        var modelRevision = ParakeetV3ModelSpec.modelRevision
        var totalBytes = ParakeetV3ModelSpec.totalBytes
    }

    static let engine = SpeechEngineChoice.parakeetV3
    static let storeFolderName = "ParakeetV3"
    static let markerFileName = "typr-parakeet-v3-installed.json"
    static let preparationFileName = "typr-parakeet-v3-preparation.json"
    static var marker: Marker { Marker() }

    static let modelRepo = "FluidInference/parakeet-tdt-0.6b-v3-coreml"
    static let modelRevision = "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe"

    static let vocabularyFile = file("parakeet_vocab.json", bytes: 151_122)

    /// The four Core ML models at `modelRevision` (Hugging Face tree API).
    static let modelFiles: [PinnedModelFile] = [
        file("Preprocessor.mlmodelc/analytics/coremldata.bin", bytes: 243),
        file("Preprocessor.mlmodelc/coremldata.bin", bytes: 486),
        file("Preprocessor.mlmodelc/metadata.json", bytes: 2_841),
        file("Preprocessor.mlmodelc/model.mil", bytes: 28_181),
        file("Preprocessor.mlmodelc/weights/weight.bin", bytes: 491_072),
        file("Decoder.mlmodelc/analytics/coremldata.bin", bytes: 243),
        file("Decoder.mlmodelc/coremldata.bin", bytes: 554),
        file("Decoder.mlmodelc/metadata.json", bytes: 3_427),
        file("Decoder.mlmodelc/model.mil", bytes: 13_110),
        file("Decoder.mlmodelc/weights/weight.bin", bytes: 23_604_992),
        file("JointDecisionv3.mlmodelc/analytics/coremldata.bin", bytes: 243),
        file("JointDecisionv3.mlmodelc/coremldata.bin", bytes: 521),
        file("JointDecisionv3.mlmodelc/metadata.json", bytes: 3_453),
        file("JointDecisionv3.mlmodelc/model.mil", bytes: 11_775),
        file("JointDecisionv3.mlmodelc/weights/weight.bin", bytes: 12_642_764),
        file("Encoder.mlmodelc/analytics/coremldata.bin", bytes: 243),
        file("Encoder.mlmodelc/coremldata.bin", bytes: 485),
        file("Encoder.mlmodelc/metadata.json", bytes: 2_921),
        file("Encoder.mlmodelc/model.mil", bytes: 959_769),
        file("Encoder.mlmodelc/weights/weight.bin", bytes: 445_187_200),
    ]

    /// Download order: the vocabulary first (small, parsed before the marker is written), then the models.
    static let allFiles: [PinnedModelFile] = [vocabularyFile] + modelFiles
    static var checkedFiles: [PinnedModelFile] { [vocabularyFile] }

    static let totalBytes: Int64 = 483_105_645

    static let storageHeadroomBytes: Int64 = 500_000_000

    /// Not measured for Parakeet V3: Whisper's measured requirement (a larger model) is used.
    static let optimizationStorageBytes: Int64 = WhisperModelSpec.optimizationStorageBytes

    /// The vocabulary's token count; the blank token is the next ID (FluidAudio `AsrModelVersion.v3.blankId`).
    static let vocabularySize = 8_192

    /// FluidAudio's defaults for these models: preprocessor on CPU, the rest on CPU and Neural
    /// Engine. No GPU, for the same background reasons as `WhisperModelSpec`.
    static let preprocessorComputeUnits: MLComputeUnits = .cpuOnly
    static let modelComputeUnits: MLComputeUnits = .cpuAndNeuralEngine

    private static func file(_ path: String, bytes: Int64) -> PinnedModelFile {
        PinnedModelFile(repo: modelRepo, revision: modelRevision, path: path, bytes: bytes)
    }
}

/// The Parakeet V3 model's store; see `ModelStore` for the layout and the meaning of "installed":
///
///     root/models/FluidInference/parakeet-tdt-0.6b-v3-coreml/{parakeet_vocab.json, *.mlmodelc/…}
typealias ParakeetV3ModelStore = ModelStore<ParakeetV3ModelSpec>

extension ModelStore where Spec == ParakeetV3ModelSpec {
    var modelFolder: URL {
        repoFolder(ParakeetV3ModelSpec.modelRepo)
    }

    var vocabularyURL: URL {
        fileURL(for: ParakeetV3ModelSpec.vocabularyFile)
    }
}

typealias ParakeetV3ModelInstaller = ModelInstaller<ParakeetV3ModelSpec>

extension ModelInstaller where Spec == ParakeetV3ModelSpec {
    convenience init(
        store: ParakeetV3ModelStore,
        downloader: any ModelFileDownloading,
        availableCapacity: (() -> Int64?)? = nil
    ) {
        self.init(store: store, downloader: downloader,
                  checkFiles: { _ = try ParakeetV3Vocabulary.load(from: store.vocabularyURL) },
                  availableCapacity: availableCapacity)
    }
}

nonisolated enum ParakeetV3VocabularyError: ModelFileCheckError, Equatable {
    case damaged

    var errorDescription: String? {
        "The Parakeet V3 vocabulary on this iPhone is damaged. Download Parakeet V3 again."
    }
}

/// Reads `parakeet_vocab.json` locally: a JSON object from token ID to token, as FluidAudio 0.15.5's
/// `AsrModels` parses it for the 0.6B models, with exactly the IDs `0..<vocabularySize`.
nonisolated enum ParakeetV3Vocabulary {
    static func load(from url: URL) throws -> [Int: String] {
        guard let data = try? Data(contentsOf: url),
              let tokens = try? JSONDecoder().decode([String: String].self, from: data) else {
            throw ParakeetV3VocabularyError.damaged
        }
        var vocabulary: [Int: String] = [:]
        for (key, token) in tokens {
            guard let id = Int(key) else { throw ParakeetV3VocabularyError.damaged }
            vocabulary[id] = token
        }
        guard vocabulary.count == ParakeetV3ModelSpec.vocabularySize,
              vocabulary.keys.allSatisfy({ (0..<ParakeetV3ModelSpec.vocabularySize).contains($0) }) else {
            throw ParakeetV3VocabularyError.damaged
        }
        return vocabulary
    }
}
