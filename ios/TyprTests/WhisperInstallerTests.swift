import CoreML
import Foundation
import XCTest
@testable import Typr

// Fake-backed tests for Whisper's explicit download: no network, no real model. Pinned files are
// written as sparse files of their exact pinned size (APFS: no real disk use), so the store's
// exact-size checks run unchanged against the production spec.

private struct FakeDownloadFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Records every download call; each path can write its exact size, a wrong size, fail, or hold
/// until released (cancellable: the hold sleeps, which throws `CancellationError` on cancel).
private final class FakeWhisperDownloader: ModelFileDownloading, @unchecked Sendable {
    enum Behavior {
        case write
        case writeBytes(Int64)
        case fail(any Error)
        case hold
    }

    private let lock = NSLock()
    private var recordedCalls: [String] = []
    private var behaviors: [String: Behavior] = [:]
    private var released: Set<String> = []
    private var active = 0
    private var recordedMaxConcurrent = 0
    private var recordedRoots: Set<URL> = []
    private var progressHandlers: [String: @Sendable (Double) -> Void] = [:]

    var calls: [String] { lock.withLock { recordedCalls } }
    var maxConcurrent: Int { lock.withLock { recordedMaxConcurrent } }
    var roots: Set<URL> { lock.withLock { recordedRoots } }

    func set(_ behavior: Behavior, for path: String) {
        lock.withLock {
            behaviors[path] = behavior
            released.remove(path)
        }
    }

    func release(_ path: String) {
        lock.withLock { _ = released.insert(path) }
    }

    func emit(_ fraction: Double, for path: String) {
        let callback = lock.withLock { progressHandlers[path] }
        callback?(fraction)
    }

    func download(
        _ file: PinnedModelFile,
        into root: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let behavior: Behavior = lock.withLock {
            recordedCalls.append(file.path)
            progressHandlers[file.path] = progress
            recordedRoots.insert(root.standardizedFileURL)
            active += 1
            recordedMaxConcurrent = max(recordedMaxConcurrent, active)
            return behaviors[file.path] ?? .write
        }
        defer { lock.withLock { active -= 1 } }
        let destination = WhisperModelStore(root: root).fileURL(for: file)
        // Hub may trust cached commit/ETag metadata without rechecking the destination bytes.
        // Refuse to overwrite: the installer must remove each wrong-sized destination first.
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw FakeDownloadFailure(message: "Hub refused to overwrite a cached destination: \(file.path)")
        }
        switch behavior {
        case .write:
            progress(0.5)
            try WhisperTestFiles.writeSparse(destination, bytes: file.bytes)
            progress(1)
        case .writeBytes(let bytes):
            try WhisperTestFiles.writeSparse(destination, bytes: bytes)
            progress(1)
        case .fail(let error):
            progress(0.25)
            throw error
        case .hold:
            try WhisperTestFiles.writeSparse(destination, bytes: file.bytes / 2)
            progress(0.5)
            while !lock.withLock({ released.contains(file.path) }) {
                try await Task.sleep(for: .milliseconds(10))
            }
            try WhisperTestFiles.writeSparse(destination, bytes: file.bytes)
            progress(1)
        }
    }
}

private final class FakeTokenizerChecker: WhisperTokenizerChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var folders: [URL] = []
    private var failure: (any Error)?
    private var failuresRemaining = 0

    var checkedFolders: [URL] { lock.withLock { folders } }

    func fail(with error: (any Error)?, times: Int = .max) {
        lock.withLock { failure = error; failuresRemaining = times }
    }

    func check(tokenizerFolder: URL) async throws {
        let error: (any Error)? = lock.withLock {
            folders.append(tokenizerFolder)
            guard failuresRemaining > 0 else { return nil }
            failuresRemaining -= 1
            return failure
        }
        if let error { throw error }
    }
}

nonisolated enum WhisperTestFiles {
    /// A file of exactly `bytes` logical bytes; sparse on APFS, so 420 MB costs no real disk.
    static func writeSparse(_ url: URL, bytes: Int64) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(bytes))
    }

    /// Every pinned file at its exact size, optionally with the marker: a complete install.
    static func populate(_ store: WhisperModelStore, marker: Bool, except skipped: Set<String> = []) throws {
        for file in WhisperModelSpec.allFiles where !skipped.contains(file.path) {
            try writeSparse(store.fileURL(for: file), bytes: file.bytes)
        }
        if marker {
            try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
            try store.writeMarker()
        }
    }

    static func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("typr-whisper-tests-\(UUID().uuidString)", isDirectory: true)
    }
}

@MainActor
final class WhisperInstallerTests: XCTestCase {
    private var root: URL!
    private var store: WhisperModelStore!
    private var downloader: FakeWhisperDownloader!
    private var checker: FakeTokenizerChecker!
    private var installers: [WhisperModelInstaller] = []
    /// Install tasks (including joined and superseded ones) whose body has not returned yet.
    private var unfinishedInstallTasks = 0

    private static let weightPath = "openai_whisper-large-v3-v20240930_626MB/AudioEncoder.mlmodelc/weights/weight.bin"
    private static let melWeightPath = "openai_whisper-large-v3-v20240930_626MB/MelSpectrogram.mlmodelc/weights/weight.bin"

    override func setUp() async throws {
        root = WhisperTestFiles.makeRoot()
        store = WhisperModelStore(root: root)
        downloader = FakeWhisperDownloader()
        checker = FakeTokenizerChecker()
    }

    override func tearDown() async throws {
        for installer in installers { installer.cancel() }
        // `.cancelled` is shown before the cancelled run stops: drain until every install task has
        // returned, i.e. the cancellable fake download/checker waits have unwound, before the
        // files are removed. A timeout fails and keeps the files.
        try await waitForState("install tasks unwound") { self.unfinishedInstallTasks == 0 }
        installers = []
        try? FileManager.default.removeItem(at: root)
    }

    private func makeInstaller(capacity: Int64? = .max) -> WhisperModelInstaller {
        let installer = WhisperModelInstaller(store: store, downloader: downloader, tokenizerChecker: checker,
                                              availableCapacity: { capacity })
        installers.append(installer)
        return installer
    }

    /// Every install goes through here so teardown can wait for its unwind, not for its status.
    @discardableResult
    private func install(_ installer: WhisperModelInstaller) -> Task<Void, Never> {
        let task = installer.install()
        unfinishedInstallTasks += 1
        Task {
            await task.value
            self.unfinishedInstallTasks -= 1
        }
        return task
    }

    private var allPaths: [String] { WhisperModelSpec.allFiles.map(\.path) }

    private func bytes(before path: String) -> Int64 {
        let files = WhisperModelSpec.allFiles
        return files.prefix { $0.path != path }.reduce(0) { $0 + $1.bytes }
    }

    // MARK: - Spec

    private func assertPinned<Spec: DownloadableModelSpec>(_: Spec.Type, line: UInt = #line) {
        let files = Spec.allFiles
        XCTAssertEqual(files.reduce(0) { $0 + $1.bytes }, Spec.totalBytes, "\(Spec.engine)", line: line)
        XCTAssertEqual(Set(files.map { "\($0.repo)/\($0.path)" }).count, files.count, "\(Spec.engine)", line: line)
        XCTAssertEqual(Array(files.prefix(Spec.checkedFiles.count)), Spec.checkedFiles, "checked files come first", line: line)
        for file in files {
            XCTAssertTrue(file.revision.count == 40 && file.revision.allSatisfy(\.isHexDigit), "\(file.path) pins a commit", line: line)
            XCTAssertGreaterThan(file.bytes, 0, file.path, line: line)
        }
    }

    func testEverySpecPinsCommitsAndItsFilesAddUpToTheTotal() {
        assertPinned(WhisperModelSpec.self)
        assertPinned(ParakeetV3ModelSpec.self)
        assertPinned(OrukeetModelSpec.self)
        assertPinned(CohereModelSpec.self)
        XCTAssertTrue(WhisperModelSpec.modelFiles.allSatisfy { $0.path.hasPrefix(WhisperModelSpec.modelFolderName + "/") })
        let components = TdtV3PreparationComponent.allCases.map(\.rawValue)
        XCTAssertEqual(Set(ParakeetV3ModelSpec.modelFiles.compactMap { $0.path.split(separator: "/").first.map(String.init) }),
                       Set(components.map { "\($0).mlmodelc" }))
        XCTAssertEqual(Set(OrukeetModelSpec.unpackedFiles.compactMap { $0.path.split(separator: "/").first.map(String.init) }),
                       Set(components.map { "\($0).mlpackage" } + [TdtV3Vocabulary.fileName]))
        XCTAssertEqual(OrukeetModelSpec.archiveSHA256.count, 64)
        XCTAssertEqual(Set(CohereModelSpec.modelFiles.map { $0.path.split(separator: "/").prefix(2).joined(separator: "/") }),
                       ["q8/\(CohereModelSpec.encoderFolder)", "q8/\(CohereModelSpec.decoderFolder)"])
    }

    func testComputeUnitsNeverUseTheGPU() {
        // Keyboard dictations finish in the background, where iOS denies GPU work.
        let units = [WhisperModelSpec.melComputeUnits, WhisperModelSpec.audioEncoderComputeUnits,
                     WhisperModelSpec.textDecoderComputeUnits, CohereModelSpec.computeUnits]
            + TdtV3PreparationComponent.allCases.map(\.computeUnits)
        for unit in units {
            XCTAssertFalse([MLComputeUnits.cpuAndGPU, .all].contains(unit), "\(unit.rawValue)")
        }
    }

    // MARK: - Byte-weighted progress

    func testProgressIsWeightedByBytesNotFiles() {
        let half = ModelDownloadProgress.weighted(finishedBytes: 100, currentFileBytes: 800,
                                                    currentFileFraction: 0.5, totalBytes: 1_000)
        XCTAssertEqual(half, ModelDownloadProgress(completedBytes: 500, totalBytes: 1_000))
        XCTAssertEqual(half.fraction, 0.5, accuracy: 1e-9)

        // Clamped: NaN, negative and >1 fractions; never above the total.
        XCTAssertEqual(ModelDownloadProgress.weighted(finishedBytes: 100, currentFileBytes: 800,
                                                        currentFileFraction: .nan, totalBytes: 1_000).completedBytes, 100)
        XCTAssertEqual(ModelDownloadProgress.weighted(finishedBytes: 100, currentFileBytes: 800,
                                                        currentFileFraction: -3, totalBytes: 1_000).completedBytes, 100)
        XCTAssertEqual(ModelDownloadProgress.weighted(finishedBytes: 900, currentFileBytes: 800,
                                                        currentFileFraction: 4, totalBytes: 1_000).completedBytes, 1_000)
        XCTAssertEqual(ModelDownloadProgress(completedBytes: 5, totalBytes: 0).fraction, 0)
        XCTAssertEqual(ModelDownloadProgress(completedBytes: 2_000, totalBytes: 1_000).fraction, 1)
    }

    func testFailureMessagesSayRetryNeverResume() {
        let offline = "No internet connection. Connect and tap Retry."
        for code in [URLError.Code.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost] {
            XCTAssertEqual(WhisperModelInstaller.message(for: URLError(code)), offline, "\(code)")
        }
        // WhisperKit's Hub reports a missing connection as a repository not available locally.
        XCTAssertEqual(WhisperModelInstaller.message(for: FakeDownloadFailure(message: "Repository not available locally")), offline)
        XCTAssertEqual(WhisperModelInstaller.message(for: FakeDownloadFailure(message: "HTTP 500")),
                       "Download failed: HTTP 500 Tap Retry to start again.")
        let storage = ModelInstallError.insufficientStorage(model: "Whisper", needed: 2_000_000_000, available: 1_000)
        XCTAssertEqual(WhisperModelInstaller.message(for: storage), storage.errorDescription)
        for message in [offline, WhisperModelInstaller.message(for: FakeDownloadFailure(message: "x"))] {
            XCTAssertFalse(message.localizedCaseInsensitiveContains("resume"), message)
        }
    }

    // MARK: - Store

    func testEveryEngineHasItsOwnStoreInApplicationSupportExcludedFromBackup() throws {
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let documents = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KeyboardBridge.appGroup)
        let roots = [WhisperModelStore.defaultRoot(), ParakeetV3ModelStore.defaultRoot(),
                     OrukeetModelStore.defaultRoot(), CohereModelStore.defaultRoot()].map(\.standardizedFileURL.path)
        XCTAssertEqual(Set(roots).count, roots.count, "each engine has its own folder")
        for path in roots {
            XCTAssertTrue(path.hasPrefix(support.standardizedFileURL.path), path)
            XCTAssertFalse(path.hasPrefix(documents.standardizedFileURL.path), path)
            if let group { XCTAssertFalse(path.hasPrefix(group.standardizedFileURL.path), "the keyboard never needs the model") }
        }
        let files = [(WhisperModelStore.markerFileName, WhisperModelStore.preparationFileName),
                     (ParakeetV3ModelStore.markerFileName, ParakeetV3ModelStore.preparationFileName),
                     (OrukeetModelStore.markerFileName, OrukeetModelStore.preparationFileName),
                     (CohereModelStore.markerFileName, CohereModelStore.preparationFileName)]
        for (marker, preparation) in files { XCTAssertNotEqual(marker, preparation) }

        try store.prepareRoot()
        let values = try root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testStoreUsesTheHubCacheLayoutUnderItsRoot() {
        let modelFile = WhisperModelSpec.modelFiles[0]
        XCTAssertEqual(store.fileURL(for: modelFile).standardizedFileURL.path,
                       root.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(modelFile.path)").standardizedFileURL.path)
        XCTAssertEqual(store.tokenizerFolder.standardizedFileURL.path,
                       root.appendingPathComponent("models/openai/whisper-large-v3").standardizedFileURL.path)
        XCTAssertEqual(store.modelFolder.standardizedFileURL.path,
                       root.appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_626MB")
                           .standardizedFileURL.path)
        XCTAssertEqual(store.markerURL.lastPathComponent, WhisperModelStore.markerFileName)
        XCTAssertEqual(store.markerURL.deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL)
    }

    // MARK: - Installed detection (restart)

    func testCreatingTheInstallerNeverDownloads() async throws {
        let installer = makeInstaller()
        installer.refresh()
        // Synchronous: only install() starts work, and it marks the installer busy before returning.
        XCTAssertEqual(installer.state, .notInstalled)
        XCTAssertFalse(installer.isInstalled)
        XCTAssertFalse(installer.isBusy)
        XCTAssertTrue(downloader.calls.isEmpty)
        XCTAssertTrue(checker.checkedFolders.isEmpty)
    }

    func testMarkerAndExactFilesAreDetectedAsInstalledAfterRestart() async throws {
        try WhisperTestFiles.populate(store, marker: true)
        let installer = makeInstaller()
        XCTAssertEqual(installer.state, .installed)
        XCTAssertTrue(installer.isInstalled)
        XCTAssertFalse(installer.isBusy)
        XCTAssertTrue(downloader.calls.isEmpty, "a restart with an installed model reaches no network")
    }

    func testPartialOrUnmarkedFilesAreNeverInstalled() throws {
        // Every file but no marker: an interrupted install (the marker is written last).
        try WhisperTestFiles.populate(store, marker: false)
        XCTAssertFalse(store.isInstalled)
        XCTAssertEqual(makeInstaller().state, .notInstalled)

        // Marker but one file missing.
        try FileManager.default.removeItem(at: store.fileURL(for: WhisperModelSpec.modelFiles[4]))
        try store.writeMarker()
        XCTAssertTrue(store.hasMarker)
        XCTAssertFalse(store.filesComplete)
        XCTAssertFalse(store.isInstalled)
        XCTAssertEqual(makeInstaller().state, .notInstalled)

        // Marker and every file, but one has the wrong size (truncated write).
        let file = WhisperModelSpec.modelFiles[4]
        try WhisperTestFiles.writeSparse(store.fileURL(for: file), bytes: file.bytes - 1)
        XCTAssertEqual(store.invalidFiles().map(\.path), [file.path])
        XCTAssertFalse(store.isInstalled)
        XCTAssertEqual(makeInstaller().state, .notInstalled)
    }

    func testMarkerForAnotherRevisionIsNotInstalled() throws {
        try WhisperTestFiles.populate(store, marker: false)
        var stale = WhisperModelStore.Marker()
        stale.modelRevision = String(repeating: "0", count: 40)
        try JSONEncoder().encode(stale).write(to: store.markerURL)
        XCTAssertFalse(store.hasMarker)
        XCTAssertFalse(store.isInstalled)

        try Data("not json".utf8).write(to: store.markerURL)
        XCTAssertFalse(store.isInstalled)
    }

    func testRefreshNoticesAModelRemovedFromDisk() throws {
        try WhisperTestFiles.populate(store, marker: true)
        let installer = makeInstaller()
        XCTAssertEqual(installer.state, .installed)
        try FileManager.default.removeItem(at: store.fileURL(for: WhisperModelSpec.tokenizerFiles[1]))
        installer.refresh()
        XCTAssertEqual(installer.state, .notInstalled)
        XCTAssertFalse(installer.isInstalled)
    }

    // MARK: - Download

    func testExplicitInstallDownloadsEveryFileOnceInOrderThenVerifiesAndMarks() async throws {
        let installer = makeInstaller()
        await install(installer).value

        XCTAssertEqual(installer.state, .installed)
        XCTAssertTrue(installer.isInstalled)
        XCTAssertTrue(store.hasMarker)
        XCTAssertEqual(downloader.calls, allPaths)
        XCTAssertEqual(downloader.maxConcurrent, 1, "one file at a time")
        XCTAssertEqual(downloader.roots, Set([root.standardizedFileURL]))
        XCTAssertEqual(checker.checkedFolders.map(\.standardizedFileURL), [store.tokenizerFolder.standardizedFileURL],
                       "the tokenizer is parsed locally before the marker")
    }

    func testDownloadProgressIsByteWeightedAndSeparateFromVerifying() async throws {
        downloader.set(.hold, for: Self.weightPath)
        let installer = makeInstaller()
        let task = install(installer)
        XCTAssertTrue(installer.isBusy)
        XCTAssertEqual(installer.state, .verifying, "preflight runs before byte-weighted download progress begins")

        let weight = try XCTUnwrap(WhisperModelSpec.allFiles.first { $0.path == Self.weightPath })
        let expected = bytes(before: Self.weightPath) + weight.bytes / 2
        let half = ModelDownloadProgress(completedBytes: expected, totalBytes: WhisperModelSpec.totalBytes)
        try await waitForState("half the held file shown") { installer.state == .downloading(half) }
        XCTAssertFalse(store.hasMarker)
        XCTAssertFalse(installer.isInstalled)

        downloader.release(Self.weightPath)
        await task.value
        XCTAssertEqual(installer.state, .installed)
        XCTAssertFalse(installer.isBusy)
    }

    func testProgressNeverRegressesAndCancelledCallbacksCannotReviveAnInstall() async throws {
        downloader.set(.hold, for: Self.weightPath)
        let installer = makeInstaller()
        let task = install(installer)
        try await waitForState("weight download held") { self.downloader.calls.last == Self.weightPath }
        let file = try XCTUnwrap(WhisperModelSpec.allFiles.first { $0.path == Self.weightPath })
        let advanced = ModelDownloadProgress.weighted(finishedBytes: bytes(before: file.path),
            currentFileBytes: file.bytes, currentFileFraction: 0.8, totalBytes: WhisperModelSpec.totalBytes)
        downloader.emit(0.8, for: file.path)
        try await waitForState("advanced progress shown") { installer.state == .downloading(advanced) }
        downloader.emit(0.1, for: file.path)
        await mainActorBarrier() // The late progress hop has run (and was ignored).
        XCTAssertEqual(installer.state, .downloading(advanced), "late progress never moves the display backwards")

        installer.cancel()
        downloader.emit(1, for: file.path)
        await task.value
        await mainActorBarrier() // The cancelled run's last progress hop has run.
        XCTAssertEqual(installer.state, .cancelled)
        XCTAssertFalse(installer.isInstalled)
    }

    func testVerifyingIsItsOwnStateBeforeInstalled() async throws {
        // A tokenizer check that holds shows .verifying (busy, not installed, no marker yet).
        let slowChecker = HoldingTokenizerChecker()
        let installer = WhisperModelInstaller(store: store, downloader: downloader, tokenizerChecker: slowChecker,
                                              availableCapacity: { .max })
        installers.append(installer)
        let task = install(installer)
        try await waitForState("tokenizer check held") { slowChecker.hasEntered && installer.state == .verifying }
        XCTAssertTrue(installer.isBusy)
        XCTAssertFalse(store.hasMarker)
        XCTAssertFalse(installer.isInstalled)
        slowChecker.release()
        await task.value
        XCTAssertEqual(installer.state, .installed)
    }

    func testSecondInstallWhileBusyJoinsTheRunningDownload() async throws {
        downloader.set(.hold, for: Self.weightPath)
        let installer = makeInstaller()
        let first = install(installer)
        let second = install(installer)
        XCTAssertEqual(first, second)
        try await waitForState("download held mid-file") { self.downloader.calls.last == Self.weightPath }
        let third = install(installer)
        XCTAssertEqual(first, third)

        downloader.release(Self.weightPath)
        await first.value
        XCTAssertEqual(installer.state, .installed)
        XCTAssertEqual(downloader.calls, allPaths, "each file downloaded exactly once")
        XCTAssertEqual(downloader.maxConcurrent, 1)
    }

    func testInstallWhenAlreadyInstalledMakesNoDownloaderCalls() async throws {
        try WhisperTestFiles.populate(store, marker: true)
        let installer = makeInstaller()
        await install(installer).value
        XCTAssertEqual(installer.state, .installed)
        XCTAssertTrue(downloader.calls.isEmpty)
    }

    func testCancelKeepsDownloadedFilesNotSelectableAndRetryFinishesOnlyTheRest() async throws {
        downloader.set(.hold, for: Self.weightPath)
        let installer = makeInstaller()
        let task = install(installer)
        try await waitForState("weight download held") { self.downloader.calls.last == Self.weightPath }

        installer.cancel()
        XCTAssertEqual(installer.state, .cancelled)
        XCTAssertFalse(installer.isBusy)
        await task.value
        await mainActorBarrier() // Progress hops queued before the unwind have run.
        XCTAssertEqual(installer.state, .cancelled, "a late progress callback never revives a cancelled download")
        XCTAssertFalse(store.hasMarker)
        XCTAssertFalse(installer.isInstalled)
        // Files finished before the cancel stay on disk for Retry.
        for file in WhisperModelSpec.tokenizerFiles {
            XCTAssertEqual(store.size(of: file), file.bytes)
        }

        downloader.set(.write, for: Self.weightPath)
        await install(installer).value
        XCTAssertEqual(installer.state, .installed)
        let afterCancel = Array(downloader.calls.drop { $0 != Self.weightPath }.dropFirst())
        XCTAssertEqual(afterCancel.first, Self.weightPath, "Retry restarts the interrupted file")
        XCTAssertEqual(downloader.calls.filter { $0 == "tokenizer.json" }.count, 1, "complete files are not downloaded again")
    }

    func testRetryImmediatelyAfterCancelWaitsForTheCancelledDownloadToStop() async throws {
        downloader.set(.hold, for: Self.weightPath)
        let installer = makeInstaller()
        _ = install(installer)
        try await waitForState("weight download held") { self.downloader.calls.last == Self.weightPath }
        installer.cancel()
        downloader.set(.write, for: Self.weightPath)
        await install(installer).value
        XCTAssertEqual(installer.state, .installed)
        XCTAssertEqual(downloader.maxConcurrent, 1, "the retry never writes beside the cancelled download")
    }

    func testCancelWhenIdleDoesNothing() {
        let installer = makeInstaller()
        installer.cancel()
        XCTAssertEqual(installer.state, .notInstalled)
    }

    func testDownloadFailureIsReportedKeepsFilesAndRetrySucceeds() async throws {
        downloader.set(.fail(FakeDownloadFailure(message: "Server said no.")), for: Self.melWeightPath)
        let installer = makeInstaller()
        await install(installer).value
        XCTAssertEqual(installer.state, .failed("Download failed: Server said no. Tap Retry to start again."))
        XCTAssertFalse(installer.isBusy)
        XCTAssertFalse(store.hasMarker)
        XCTAssertFalse(installer.isInstalled)
        XCTAssertNil(downloader.calls.firstIndex(of: WhisperModelSpec.modelFiles.last!.path), "stops at the failure")

        downloader.set(.write, for: Self.melWeightPath)
        await install(installer).value
        XCTAssertEqual(installer.state, .installed)
        XCTAssertEqual(downloader.calls.filter { $0 == Self.melWeightPath }.count, 2)
        XCTAssertEqual(downloader.calls.filter { $0 == Self.weightPath }.count, 1, "files before the failure are kept")
    }

    func testWrongFileSizeFailsAndIsNeverMarked() async throws {
        let file = try XCTUnwrap(WhisperModelSpec.allFiles.first { $0.path == Self.melWeightPath })
        downloader.set(.writeBytes(file.bytes - 7), for: file.path)
        let installer = makeInstaller()
        await install(installer).value
        let expected = ModelInstallError.sizeMismatch(model: "Whisper", path: file.path, expected: file.bytes, actual: file.bytes - 7)
        XCTAssertEqual(installer.state, .failed(try XCTUnwrap(expected.errorDescription)))
        XCTAssertFalse(store.hasMarker)
        XCTAssertFalse(installer.isInstalled)
    }

    func testCorruptTokenizerFailsAndIsNeverMarked() async throws {
        checker.fail(with: WhisperTokenizerError.unresolvedToken("<|de|>"))
        let installer = makeInstaller()
        await install(installer).value
        XCTAssertEqual(installer.state,
                       .failed("The Whisper tokenizer on this iPhone is damaged (missing <|de|>). Download Whisper again."))
        XCTAssertFalse(store.hasMarker)
        XCTAssertFalse(installer.isInstalled)
        XCTAssertEqual(downloader.calls, allPaths, "files are complete; only verification failed")
    }

    func testInsufficientStorageFailsBeforeAnyDownload() async throws {
        let installer = makeInstaller(capacity: 1_000_000)
        await install(installer).value
        guard case .failed(let message) = installer.state else { return XCTFail("expected failure, got \(installer.state)") }
        let needed = WhisperModelSpec.totalBytes + WhisperModelSpec.storageHeadroomBytes
        XCTAssertEqual(message, ModelInstallError.insufficientStorage(model: "Whisper", needed: needed, available: 1_000_000).errorDescription)
        XCTAssertTrue(downloader.calls.isEmpty)
    }

    func testStorageCheckUsesMissingBytesAndAllowsTheExactHeadroomBoundary() async throws {
        try WhisperTestFiles.populate(store, marker: false, except: [Self.melWeightPath])
        let missing = try XCTUnwrap(WhisperModelSpec.allFiles.first { $0.path == Self.melWeightPath })
        let installer = makeInstaller(capacity: missing.bytes + WhisperModelSpec.storageHeadroomBytes)
        await install(installer).value
        XCTAssertEqual(installer.state, .installed)
        XCTAssertEqual(downloader.calls, [missing.path], "complete files do not consume the required download space twice")
    }

    func testWrongSizedCachedHubDestinationIsRemovedBeforeDownloaderRuns() async throws {
        try WhisperTestFiles.populate(store, marker: true)
        let file = try XCTUnwrap(WhisperModelSpec.allFiles.first { $0.path == Self.weightPath })
        try WhisperTestFiles.writeSparse(store.fileURL(for: file), bytes: file.bytes - 1)
        XCTAssertFalse(store.isInstalled)

        let installer = makeInstaller()
        await install(installer).value
        XCTAssertEqual(installer.state, .installed, "the fake Hub refuses to overwrite an existing destination")
        XCTAssertEqual(downloader.calls, [file.path], "only the invalid cached file is downloaded again")
        XCTAssertEqual(store.size(of: file), file.bytes)
        XCTAssertTrue(store.hasMarker)
    }

    func testExplicitRetryRepairsSameSizedInvalidTokenizerWithoutRedownloadingModel() async throws {
        try WhisperTestFiles.populate(store, marker: true)
        // Byte checks alone see these zero-filled files as complete. Preflight parsing rejects
        // them once; the fake accepts the replacement tokenizer at final verification.
        checker.fail(with: WhisperTokenizerError.unresolvedToken("<|de|>"), times: 1)
        let installer = makeInstaller()
        XCTAssertEqual(installer.state, .installed, "restart detection initially checks marker and sizes")
        await install(installer).value

        XCTAssertEqual(installer.state, .installed)
        XCTAssertEqual(downloader.calls, WhisperModelSpec.tokenizerFiles.map(\.path))
        XCTAssertEqual(checker.checkedFolders.count, 2, "preflight failure followed by a final local validation")
        XCTAssertTrue(store.isInstalled)
        XCTAssertTrue(downloader.calls.allSatisfy { !$0.hasPrefix(WhisperModelSpec.modelFolderName) },
                      "the 627 MB model is retained during tokenizer repair")
    }

    func testCompleteInstallMarkerIsHiddenDuringReverificationAndRemovedOnFailure() async throws {
        try WhisperTestFiles.populate(store, marker: true)
        let held = HoldingTokenizerChecker()
        let installer = WhisperModelInstaller(store: store, downloader: downloader, tokenizerChecker: held,
                                              availableCapacity: { .max })
        installers.append(installer)
        let task = install(installer)
        try await waitForState("marker removed") { !self.store.hasMarker }
        XCTAssertFalse(installer.isInstalled, "a stale marker never advertises an install being repaired")
        installer.cancel()
        await task.value
        XCTAssertEqual(installer.state, .cancelled)
        XCTAssertFalse(store.hasMarker)
        XCTAssertTrue(downloader.calls.isEmpty)
    }

    func testStaleMarkerWithIncompleteFilesIsRemovedOnInstall() async throws {
        try WhisperTestFiles.populate(store, marker: true, except: [Self.weightPath])
        XCTAssertTrue(store.hasMarker)
        downloader.set(.fail(URLError(.notConnectedToInternet)), for: Self.weightPath)
        let installer = makeInstaller()
        XCTAssertEqual(installer.state, .notInstalled)
        await install(installer).value
        XCTAssertEqual(installer.state, .failed("No internet connection. Connect and tap Retry."))
        XCTAssertFalse(store.hasMarker, "an invalid marker never survives a failed retry")
        XCTAssertEqual(downloader.calls, [Self.weightPath], "only the missing file is downloaded")
    }
}

/// A tokenizer check that waits until released, so the `.verifying` state can be observed.
private final class HoldingTokenizerChecker: WhisperTokenizerChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var entered = false
    var hasEntered: Bool { lock.withLock { entered } }

    func release() { lock.withLock { released = true } }

    func check(tokenizerFolder: URL) async throws {
        lock.withLock { entered = true }
        while !lock.withLock({ released }) {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
