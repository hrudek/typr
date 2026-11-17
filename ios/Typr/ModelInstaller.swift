import Foundation
import Observation
import WhisperKit

/// Downloads one pinned file into the Hub cache layout under `root`
/// (`ModelStore.fileURL(for:)`). Reports that file's own progress, 0...1.
/// Production: `HubModelFileDownloader` (WhisperKit's `HubApiWrapper.snapshot`, exact revision).
protocol ModelFileDownloading: Sendable {
    func download(
        _ file: PinnedModelFile,
        into root: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws
}

/// A local check of downloaded files that found them damaged; its text is shown as is.
protocol ModelFileCheckError: LocalizedError {}

/// Byte-weighted download progress over every pinned file (WhisperKit's own progress weighs each
/// file equally, which is wrong for one 422 MB file among small ones).
nonisolated struct ModelDownloadProgress: Equatable, Sendable {
    let completedBytes: Int64
    let totalBytes: Int64

    var fraction: Double {
        totalBytes > 0 ? min(1, max(0, Double(completedBytes) / Double(totalBytes))) : 0
    }

    /// (finished bytes + current file fraction × current file size) / total.
    static func weighted(
        finishedBytes: Int64,
        currentFileBytes: Int64,
        currentFileFraction: Double,
        totalBytes: Int64
    ) -> ModelDownloadProgress {
        let clamped = min(1, max(0, currentFileFraction.isFinite ? currentFileFraction : 0))
        let partial = Int64((Double(currentFileBytes) * clamped).rounded(.down))
        return ModelDownloadProgress(completedBytes: min(totalBytes, finishedBytes + partial), totalBytes: totalBytes)
    }
}

nonisolated enum ModelInstallState: Equatable, Sendable {
    /// No complete, verified model on this iPhone (never selectable).
    case notInstalled
    case downloading(ModelDownloadProgress)
    /// Checking every file's exact size and parsing the checked files locally.
    case verifying
    /// Marker written after verification: selectable.
    case installed
    /// The user cancelled; files already downloaded stay for Retry (no resume guarantee).
    case cancelled
    case failed(String)
}

nonisolated enum ModelInstallError: LocalizedError, Equatable {
    case insufficientStorage(model: String, needed: Int64, available: Int64)
    case sizeMismatch(model: String, path: String, expected: Int64, actual: Int64?)

    var errorDescription: String? {
        switch self {
        case .insufficientStorage(let model, let needed, let available):
            let format = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
            return "Not enough free storage: \(model) needs \(format(needed)), \(format(available)) is free."
        case .sizeMismatch(let model, let path, let expected, let actual):
            let found = actual.map { "\($0) bytes" } ?? "no file"
            return "A \(model) model file is incomplete (\((path as NSString).lastPathComponent): expected \(expected) bytes, found \(found))."
        }
    }
}

/// What the Speech engine section needs from any downloadable engine's installer.
@MainActor
protocol ModelInstalling: AnyObject {
    var state: ModelInstallState { get }
    func refresh()
    @discardableResult func install() -> Task<Void, Never>
    func cancel()
}

/// The only way a downloadable model reaches this iPhone: an explicit Download tap. Never called
/// from launch, preparation, keyboard handoff, intents or engine selection. One download at a time:
/// a second `install()` joins the running one; Retry after Cancel waits for the cancelled one to
/// stop. The current speech engine is untouched while downloading.
@MainActor
@Observable
final class ModelInstaller<Spec: DownloadableModelSpec>: ModelInstalling {
    let store: ModelStore<Spec>
    private let downloader: any ModelFileDownloading
    /// Parses `Spec.checkedFiles` locally; throws when they are damaged.
    private let checkFiles: @Sendable () async throws -> Void
    private let availableCapacity: () -> Int64?

    private(set) var state: ModelInstallState = .notInstalled
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0

    init(
        store: ModelStore<Spec>,
        downloader: any ModelFileDownloading,
        checkFiles: @escaping @Sendable () async throws -> Void,
        availableCapacity: (() -> Int64?)? = nil
    ) {
        self.store = store
        self.downloader = downloader
        self.checkFiles = checkFiles
        self.availableCapacity = availableCapacity ?? { store.availableCapacity() }
        refresh()
    }

    /// Marker plus exact sizes, read from disk now.
    var isInstalled: Bool { store.isInstalled }

    /// Downloading or verifying.
    var isBusy: Bool {
        switch state {
        case .downloading, .verifying: true
        default: false
        }
    }

    /// Re-reads the disk (launch, foreground). Never changes a running download's state.
    func refresh() {
        guard !isBusy else { return }
        if store.isInstalled {
            state = .installed
        } else if state == .installed {
            state = .notInstalled
        }
    }

    /// Starts the download, or returns the running one. Already installed: no network at all.
    @discardableResult
    func install() -> Task<Void, Never> {
        if isBusy, let task { return task }
        generation &+= 1
        let current = generation
        let previous = task
        previous?.cancel()
        // Check local files before showing download bytes: a corrupt checked file may need repair,
        // so counting its same-sized files now would start at 100% then move backwards.
        state = .verifying
        let task = Task { [weak self] in
            // A cancelled download must stop writing before a retry touches the same files.
            await previous?.value
            guard let self else { return }
            await self.run(generation: current)
        }
        self.task = task
        return task
    }

    /// Stops the download. Downloaded files stay; the model is not selectable until a Retry completes.
    func cancel() {
        guard isBusy else { return }
        generation &+= 1
        task?.cancel()
        state = .cancelled
    }

    private func run(generation current: UInt64) async {
        do {
            guard generation == current else { return }
            try store.prepareRoot()
            // Never leave an old marker advertising a valid install during verification/repair.
            // A same-sized damaged checked file cannot be caught by byte counts or Hub metadata.
            store.removeMarker()
            if store.invalidFiles(Spec.checkedFiles).isEmpty {
                do {
                    try await checkFiles()
                } catch {
                    try Task.checkCancellation()
                    guard generation == current else { return }
                    // This is an explicit Download/Retry action: repair only the checked files,
                    // keeping the large, complete model. No preparation path downloads anything.
                    for file in Spec.checkedFiles {
                        try FileManager.default.removeItem(at: store.fileURL(for: file))
                    }
                }
            }
            try Task.checkCancellation()
            guard generation == current else { return }
            let missing = store.invalidFiles()
            let needed = missing.reduce(Int64(0)) { $0 + $1.bytes } + Spec.storageHeadroomBytes
            if !missing.isEmpty, let available = availableCapacity(), available < needed {
                throw ModelInstallError.insufficientStorage(model: Spec.engine.shortName, needed: needed, available: available)
            }

            let total = Spec.totalBytes
            var finished = Spec.allFiles.filter { !missing.contains($0) }.reduce(Int64(0)) { $0 + $1.bytes }
            state = .downloading(ModelDownloadProgress(completedBytes: finished, totalBytes: total))
            for file in missing {
                try Task.checkCancellation()
                let base = finished
                // Hub trusts its matching commit/ETag metadata without checking file size.
                // Remove an invalid destination first so Retry cannot keep reusing it forever.
                let destination = store.fileURL(for: file)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try await downloader.download(file, into: store.root) { [weak self] fraction in
                    let progress = ModelDownloadProgress.weighted(
                        finishedBytes: base, currentFileBytes: file.bytes,
                        currentFileFraction: fraction, totalBytes: total)
                    Task { @MainActor [weak self] in
                        // Hops can arrive out of order; progress never moves backwards.
                        guard let self, self.generation == current,
                              case .downloading(let shown) = self.state,
                              progress.completedBytes > shown.completedBytes else { return }
                        self.state = .downloading(progress)
                    }
                }
                try Task.checkCancellation()
                let size = store.size(of: file)
                guard size == file.bytes else {
                    throw ModelInstallError.sizeMismatch(model: Spec.engine.shortName, path: file.path,
                                                         expected: file.bytes, actual: size)
                }
                finished += file.bytes
                guard generation == current else { return }
                state = .downloading(ModelDownloadProgress(completedBytes: finished, totalBytes: total))
            }

            guard generation == current else { return }
            state = .verifying
            if let invalid = store.invalidFiles().first {
                throw ModelInstallError.sizeMismatch(model: Spec.engine.shortName, path: invalid.path,
                                                     expected: invalid.bytes, actual: store.size(of: invalid))
            }
            try await checkFiles()
            try Task.checkCancellation()
            guard generation == current else { return }
            try store.writeMarker()
            state = .installed
        } catch {
            guard generation == current else { return }
            store.removeMarker()
            if error is CancellationError || Task.isCancelled {
                state = .cancelled
            } else {
                state = .failed(Self.message(for: error))
            }
        }
    }

    /// Offline is the common failure; WhisperKit's Hub reports it as "Repository not available locally".
    nonisolated static func message(for error: any Error) -> String {
        let offlineCodes: Set<URLError.Code> = [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
                                                .cannotFindHost, .cannotConnectToHost, .timedOut]
        if let urlError = error as? URLError, offlineCodes.contains(urlError.code) {
            return "No internet connection. Connect and tap Retry."
        }
        let text = error.localizedDescription
        if error is ModelInstallError || error is any ModelFileCheckError {
            return text
        }
        if text.localizedCaseInsensitiveContains("not available locally") || text.localizedCaseInsensitiveContains("offline") {
            return "No internet connection. Connect and tap Retry."
        }
        return "Download failed: \(text) Tap Retry to start again."
    }
}

/// Production downloader: one exact file at the pinned revision through WhisperKit's Hub client,
/// into Typr's Application Support root. Cancelling the task throws `CancellationError`.
struct HubModelFileDownloader: ModelFileDownloading {
    func download(
        _ file: PinnedModelFile,
        into root: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let hub = HubApiWrapper(downloadBase: root)
        _ = try await hub.snapshot(
            from: HubApiWrapper.Repo(id: file.repo),
            revision: file.revision,
            matching: [file.path]
        ) { value in
            progress(value.fractionCompleted)
        }
    }
}

/// The installers of every engine that downloads only through its Download button.
@MainActor
enum DownloadableModels {
    static let whisper = WhisperModelInstaller(
        store: .production,
        downloader: HubModelFileDownloader(),
        tokenizerChecker: WhisperKitTokenizerChecker()
    )
    static let parakeetV3 = ParakeetV3ModelInstaller(store: .production, downloader: HubModelFileDownloader())

    static func installer(for engine: SpeechEngineChoice) -> (any ModelInstalling)? {
        switch engine {
        case .whisperLargeV3Turbo: whisper
        case .parakeetV3: parakeetV3
        case .appleSpeech, .parakeetV2: nil
        }
    }

    /// The Download button's size, nil for engines without one.
    nonisolated static func downloadSizeLabel(for engine: SpeechEngineChoice) -> String? {
        switch engine {
        case .whisperLargeV3Turbo: WhisperModelSpec.downloadSizeLabel
        case .parakeetV3: ParakeetV3ModelSpec.downloadSizeLabel
        case .appleSpeech, .parakeetV2: nil
        }
    }
}
