import CoreML
import Foundation

/// Everything that pins Typr's Whisper engine, in one place: the package, the exact model and
/// tokenizer revisions with every file's size, compute units and decoding limits. Changing the
/// model means changing this file (and the docs), never a runtime lookup.
nonisolated enum WhisperModelSpec {
    /// One file at an exact repository revision. `path` is relative to the repository root.
    struct PinnedFile: Equatable, Hashable, Sendable {
        let repo: String
        let revision: String
        let path: String
        let bytes: Int64
    }

    static let engine = SpeechEngineChoice.whisperLargeV3Turbo

    /// Swift package (app target only), pinned with `exactVersion` in ios/project.yml.
    static let packageURL = "https://github.com/argmaxinc/argmax-oss-swift.git"
    static let packageVersion = "1.1.1"
    static let packageProduct = "WhisperKit"

    static let modelRepo = "argmaxinc/whisperkit-coreml"
    static let modelRevision = "0f63a7800b00dd0226abd051b906c246e1907482"
    /// Whisper Large V3 Turbo (OpenAI's 2024-09-30 release), Argmax's 626 MB Core ML build.
    static let modelFolderName = "openai_whisper-large-v3-v20240930_626MB"

    static let tokenizerRepo = "openai/whisper-large-v3"
    static let tokenizerRevision = "06f233fe06e710322aca913c1bc4249a0d71fce1"

    /// The model folder at `modelRevision` (Hugging Face tree API): 17 files, 626,718,238 bytes.
    static let modelFiles: [PinnedFile] = [
        PinnedFile(repo: modelRepo, revision: modelRevision,
                   path: "openai_whisper-large-v3-v20240930_626MB/AudioEncoder.mlmodelc/analytics/coremldata.bin", bytes: 243),
        PinnedFile(repo: modelRepo, revision: modelRevision,
                   path: "openai_whisper-large-v3-v20240930_626MB/AudioEncoder.mlmodelc/coremldata.bin", bytes: 348),
        PinnedFile(repo: modelRepo, revision: modelRevision,
                   path: "openai_whisper-large-v3-v20240930_626MB/AudioEncoder.mlmodelc/metadata.json", bytes: 1_922),
        PinnedFile(repo: modelRepo, revision: modelRevision,
                   path: "openai_whisper-large-v3-v20240930_626MB/AudioEncoder.mlmodelc/model.mil", bytes: 934_263),
        PinnedFile(repo: modelRepo, revision: modelRevision,
                   path: "openai_whisper-large-v3-v20240930_626MB/AudioEncoder.mlmodelc/weights/weight.bin", bytes: 421_968_768),
        PinnedFile(repo: modelRepo, revision: modelRevision,
                   path: "openai_whisper-large-v3-v20240930_626MB/MelSpectrogram.mlmodelc/analytics/coremldata.bin", bytes: 243),
        PinnedFile(repo: modelRepo, revision: modelRevision,
                   path: "openai_whisper-large-v3-v20240930_626MB/MelSpectrogram.mlmodelc/coremldata.bin", bytes: 329),
        PinnedFile(repo: modelRepo, revision: modelRevision,
                   path: "openai_whisper-large-v3-v20240930_626MB/MelSpectrogram.mlmodelc/metadata.json", bytes: 1_850),
        PinnedFile(repo: modelRepo, revision: modelRevision,
                   path: "openai_whisper-large-v3-v20240930_626MB/MelSpectrogram.mlmodelc/model.mil", bytes: 10_143),
        PinnedFile(repo: modelRepo, revision: modelRevision,
                   path: "openai_whisper-large-v3-v20240930_626MB/MelSpectrogram.mlmodelc/weights/weight.bin", bytes: 373_376),
        PinnedFile(repo: modelRepo, revision: modelRevision,
                   path: "openai_whisper-large-v3-v20240930_626MB/TextDecoder.mlmodelc/analytics/coremldata.bin", bytes: 243),
        PinnedFile(repo: modelRepo, revision: modelRevision,
                   path: "openai_whisper-large-v3-v20240930_626MB/TextDecoder.mlmodelc/coremldata.bin", bytes: 633),
        PinnedFile(repo: modelRepo, revision: modelRevision,
                   path: "openai_whisper-large-v3-v20240930_626MB/TextDecoder.mlmodelc/metadata.json", bytes: 4_924),
        PinnedFile(repo: modelRepo, revision: modelRevision,
                   path: "openai_whisper-large-v3-v20240930_626MB/TextDecoder.mlmodelc/model.mil", bytes: 217_177),
        PinnedFile(repo: modelRepo, revision: modelRevision,
                   path: "openai_whisper-large-v3-v20240930_626MB/TextDecoder.mlmodelc/weights/weight.bin", bytes: 203_199_860),
        PinnedFile(repo: modelRepo, revision: modelRevision,
                   path: "openai_whisper-large-v3-v20240930_626MB/config.json", bytes: 1_149),
        PinnedFile(repo: modelRepo, revision: modelRevision,
                   path: "openai_whisper-large-v3-v20240930_626MB/generation_config.json", bytes: 2_767),
    ]

    /// The tokenizer files WhisperKit parses locally (`AutoTokenizerWrapper.from(modelFolder:)`).
    static let tokenizerFiles: [PinnedFile] = [
        PinnedFile(repo: tokenizerRepo, revision: tokenizerRevision, path: "config.json", bytes: 1_272),
        PinnedFile(repo: tokenizerRepo, revision: tokenizerRevision, path: "tokenizer.json", bytes: 2_480_617),
        PinnedFile(repo: tokenizerRepo, revision: tokenizerRevision, path: "tokenizer_config.json", bytes: 282_843),
    ]

    /// Download order: tokenizer first (small, parsed before the marker is written), then the model.
    static let allFiles: [PinnedFile] = tokenizerFiles + modelFiles

    static let modelBytes: Int64 = 626_718_238
    static let totalBytes: Int64 = modelBytes + 1_272 + 2_480_617 + 282_843

    /// Extra free space required beyond the download: Core ML's specialization cache from the
    /// first optimization, plus room for the system to keep working.
    static let storageHeadroomBytes: Int64 = 500_000_000

    /// Free space required before Core ML specializes ("optimizes") the model for this iPhone.
    /// Observed on an iPhone 16 (iOS 27.0.1): free space fell by about 3.9 GB during the first
    /// load and about 1.4 GB stayed as the system's specialization cache. With too little space
    /// specialization never finishes, iOS purges the partial cache and the app is terminated.
    static let optimizationStorageBytes: Int64 = 4_500_000_000

    /// Whisper V3's vocabulary size; any other logits size is a wrong or corrupt model.
    static let expectedLogitsSize = 51_866

    /// No GPU: background GPU use requires device support, a resource request and a separate
    /// entitlement. CPU/ANE do not request that resource. On iOS 27, background ANE additionally
    /// requires Background Inference (app entitlement + provisioning profile); a continued task
    /// alone does not grant it. Core ML still controls resource availability and may fail.
    /// WhisperKit forces .cpuOnly in the Simulator, which cannot validate ANE behavior.
    static let melComputeUnits: MLComputeUnits = .cpuOnly
    static let audioEncoderComputeUnits: MLComputeUnits = .cpuAndNeuralEngine
    static let textDecoderComputeUnits: MLComputeUnits = .cpuAndNeuralEngine

    /// Approximate download size for the UI (about 629 MB, including the tokenizer).
    static var downloadSizeLabel: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
}
