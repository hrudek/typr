import FluidAudio
import Foundation

struct ModelPreparationProgress: Sendable {
    /// Nil when the underlying operation cannot report measured progress.
    let fractionCompleted: Double?
    let detail: String
    /// Discrete completed work, not a measured fraction of elapsed time or Core ML work.
    var stageProgress: (completed: Int64, total: Int64)? = nil

    /// `stageProgress.total` of every downloaded engine's preparation: the background runtime
    /// counts these milestones.
    static let milestoneCount: Int64 = 5
}

protocol LocalTranscribing: Actor {
    nonisolated var displayName: String { get }
    var languageName: String { get }

    func prepare(
        progressHandler: @escaping @Sendable (ModelPreparationProgress) -> Void
    ) async throws

    func transcribe(_ audioURL: URL) async throws -> String
    func transcribe(_ audioURL: URL, vocabulary: [String]) async throws -> String
    /// The controller's call: `language` is the dictation language frozen at capture start.
    /// Engines prepared for one language (Apple Speech's locale, English-only Parakeet) ignore it.
    func transcribe(_ audioURL: URL, vocabulary: [String], language: DictationLanguage) async throws -> String
}

extension LocalTranscribing {
    /// Engines without a recognition hint ignore the list and transcribe exactly as before.
    nonisolated func transcribe(_ audioURL: URL, vocabulary: [String]) async throws -> String {
        try await transcribe(audioURL)
    }

    nonisolated func transcribe(_ audioURL: URL, vocabulary: [String], language: DictationLanguage) async throws -> String {
        try await transcribe(audioURL, vocabulary: vocabulary)
    }
}

/// The controller's transcriber before any engine is ready and while switching engines, so the
/// previous engine's model is released before the next one loads.
actor UnpreparedTranscriber: LocalTranscribing {
    nonisolated let displayName: String
    let languageName = ""

    init(displayName: String = "Local speech") {
        self.displayName = displayName
    }

    func prepare(progressHandler: @escaping @Sendable (ModelPreparationProgress) -> Void) async throws {
        throw SpeechEngineError.notReady
    }

    func transcribe(_ audioURL: URL) async throws -> String {
        throw SpeechEngineError.notReady
    }
}

actor ParakeetTranscriber: LocalTranscribing {
    enum TranscriberError: LocalizedError {
        case notPrepared
        case emptyTranscript

        var errorDescription: String? {
            switch self {
            case .notPrepared:
                "Parakeet V2 is not ready."
            case .emptyTranscript:
                "Parakeet did not detect any speech."
            }
        }
    }

    private var manager: AsrManager?

    nonisolated let displayName = "Parakeet V2"
    let languageName = "English"

    nonisolated static var hasCachedModel: Bool {
        AsrModels.modelsExist(
            at: AsrModels.defaultCacheDirectory(for: .v2),
            version: .v2
        )
    }

    func prepare(
        progressHandler: @escaping @Sendable (ModelPreparationProgress) -> Void
    ) async throws {
        guard manager == nil else { return }

        let models = try await AsrModels.downloadAndLoad(
            version: .v2,
            progressHandler: { progress in
                progressHandler(
                    ModelPreparationProgress(
                        fractionCompleted: progress.fractionCompleted,
                        detail: Self.detail(for: progress.phase)
                    )
                )
            }
        )
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
    }

    private static func detail(for phase: DownloadPhase) -> String {
        switch phase {
        case .listing:
            "Checking model files"
        case .downloading(let completedFiles, let totalFiles):
            "Downloading file \(min(completedFiles + 1, totalFiles)) of \(totalFiles)"
        case .compiling(let modelName):
            "Compiling \(modelName)"
        }
    }

    func transcribe(_ audioURL: URL) async throws -> String {
        guard let manager else {
            throw TranscriberError.notPrepared
        }

        let decoderLayers = await manager.decoderLayerCount
        var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await manager.transcribe(
            audioURL,
            decoderState: &decoderState
        )
        let text = result.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw TranscriberError.emptyTranscript
        }
        return text
    }
}
