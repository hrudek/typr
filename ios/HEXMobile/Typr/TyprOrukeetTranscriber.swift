import FluidAudio
import Foundation
import os

/// Settings › Typr › Orukeet: `TyprOrukeetModel` through FluidAudio's v3 decoder, loaded as
/// `ParakeetUltraTranscriber` loads Parakeet Ultra. Orukeet detects the language itself, so
/// `languageIdentifier` only names the dictation language for the steps after it.
actor TyprOrukeetTranscriber: LocalTranscribing {
    enum TranscriberError: HexDescribedError, Equatable {
        case notPrepared
        case emptyTranscript
        case notEnoughMemory
        case notInstalled
        case loadFailed

        var errorDescription: String? {
            switch self {
            case .notPrepared:
                String(localized: "Orukeet isn't ready.")
            case .emptyTranscript:
                String(localized: "No speech heard.")
            case .notEnoughMemory:
                String(localized: "Not enough memory for Orukeet.")
            case .notInstalled:
                String(localized: "Orukeet isn't downloaded yet.")
            case .loadFailed:
                String(localized: "Orukeet didn't load.")
            }
        }
    }

    static let loadGuardModel = "typrOrukeet"
    static let compileRecordKey = "typrOrukeet.compiledForSystem"

    nonisolated let engine: DictationEngine = .typrOrukeet
    let languageIdentifier: String
    private let directory: URL
    private var manager: AsrManager?

    init(language: String, directory: URL = TyprOrukeetModel.compiledDirectory) {
        languageIdentifier = language
        self.directory = directory
    }

    var languageName: String {
        SpeechLanguagePicker.displayName(for: languageIdentifier)
    }

    nonisolated static var isCompiled: Bool {
        ParakeetCompileRecord(key: compileRecordKey).isCurrent
    }

    func prepare(
        progressHandler: @escaping @Sendable (ModelPreparationProgress) -> Void
    ) async throws {
        guard manager == nil else { return }
        guard TyprOrukeetModel.isInstalled() else { throw TranscriberError.notInstalled }

        let compiled = ParakeetCompileRecord(key: Self.compileRecordKey)
        let progress = ParakeetProgressFeed(
            ParakeetPreparationProgress(downloads: false, compiledBefore: compiled.isCurrent),
            emit: progressHandler
        )
        let ticker = Task {
            while !Task.isCancelled {
                progress.tick()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { ticker.cancel() }

        _ = TyprOrukeetChoice.launchNoted
        let loads = ParakeetLoadGuard(model: Self.loadGuardModel)
        guard ParakeetUltraTranscriber.hasRoomToLoad(available: UInt64(max(0, os_proc_available_memory()))) else {
            loads.setAside()
            throw TranscriberError.notEnoughMemory
        }
        loads.begin()
        var loaded = false
        defer { loads.end(loaded: loaded) }
        progress.update { $0.startLoading(at: Date.now.timeIntervalSinceReferenceDate) }
        let manager = AsrManager(config: .default)
        do {
            let models = try ParakeetUltraModel.load(from: directory) {
                let now = Date.now.timeIntervalSinceReferenceDate
                progress.update { $0.finishModel(at: now) }
            }
            try await manager.loadModels(models)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            print("typr orukeet: load failed: \(error)")
            loads.setAside()
            throw TranscriberError.loadFailed
        }
        self.manager = manager
        loaded = true
        compiled.markCurrent()
        progress.update { $0.finish() }
    }

    func transcribe(_ audioURL: URL) async throws -> String {
        guard let manager else {
            throw TranscriberError.notPrepared
        }
        let decoderLayers = await manager.decoderLayerCount
        var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await manager.transcribe(audioURL, decoderState: &decoderState)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw TranscriberError.emptyTranscript
        }
        return text
    }
}

extension TyprOrukeetTranscriber.TranscriberError: NoSpeechError {
    var meansNoSpeech: Bool { self == .emptyTranscript }
}
