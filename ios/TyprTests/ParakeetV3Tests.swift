import Foundation
import XCTest
@testable import Typr

nonisolated enum ParakeetV3TestFiles {
    // JSON allows trailing whitespace, so padding keeps the vocabulary parseable at its pinned size.
    static func vocabulary(count: Int = TdtV3Vocabulary.size) throws -> Data {
        let tokens = Dictionary(uniqueKeysWithValues: (0..<count).map { (String($0), "t\($0)") })
        var data = try JSONEncoder().encode(tokens)
        let pinned = Int(ParakeetV3ModelSpec.vocabularyFile.bytes)
        guard data.count <= pinned else { throw CocoaError(.fileWriteOutOfSpace) }
        data.append(Data(repeating: UInt8(ascii: " "), count: pinned - data.count))
        return data
    }

    static func write(_ file: PinnedModelFile, into root: URL) throws {
        let url = ParakeetV3ModelStore(root: root).fileURL(for: file)
        if file == ParakeetV3ModelSpec.vocabularyFile {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try vocabulary().write(to: url)
        } else {
            try WhisperTestFiles.writeSparse(url, bytes: file.bytes)
        }
    }

    static func populate(_ store: ParakeetV3ModelStore, marker: Bool, except skipped: Set<String> = []) throws {
        for file in ParakeetV3ModelSpec.allFiles where !skipped.contains(file.path) {
            try write(file, into: store.root)
        }
        if marker {
            try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
            try store.writeMarker()
        }
    }
}

private struct FakeParakeetV3Failure: LocalizedError {
    var errorDescription: String? { "Server said no." }
}

private final class FakeParakeetV3Downloader: ModelFileDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var failure: (any Error)?
    private var holding = false

    var calls: [String] { lock.withLock { recorded } }
    func fail(with error: (any Error)?) { lock.withLock { failure = error } }
    func hold() { lock.withLock { holding = true } }
    func release() { lock.withLock { holding = false } }

    func download(_ file: PinnedModelFile, into root: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws {
        let failure: (any Error)? = lock.withLock {
            recorded.append(file.path)
            return self.failure
        }
        if let failure { throw failure }
        progress(0.5)
        while lock.withLock({ holding }) { try await Task.sleep(for: .milliseconds(10)) }
        try ParakeetV3TestFiles.write(file, into: root)
        progress(1)
    }
}

final class PreparationProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ModelPreparationProgress] = []
    var values: [ModelPreparationProgress] { lock.withLock { recorded } }
    func append(_ progress: ModelPreparationProgress) { lock.withLock { recorded.append(progress) } }
}

@MainActor
final class ParakeetV3Tests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() async throws {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots = []
    }

    private func makeStore() -> ParakeetV3ModelStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("typr-parakeet-v3-tests-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        return ParakeetV3ModelStore(root: root)
    }

    private func makeInstaller(_ store: ParakeetV3ModelStore, downloader: FakeParakeetV3Downloader,
                               capacity: Int64? = .max) -> ParakeetV3ModelInstaller {
        ParakeetV3ModelInstaller(store: store, downloader: downloader, availableCapacity: { capacity })
    }

    func testSpecPinsOneRevisionOfFluidAudiosV3FilesWithExactSizes() {
        XCTAssertEqual(ParakeetV3ModelSpec.modelRepo, "FluidInference/parakeet-tdt-0.6b-v3-coreml")
        XCTAssertEqual(ParakeetV3ModelSpec.modelRevision.count, 40, "a commit, not a branch")
        XCTAssertTrue(ParakeetV3ModelSpec.allFiles.allSatisfy {
            $0.repo == ParakeetV3ModelSpec.modelRepo && $0.revision == ParakeetV3ModelSpec.modelRevision
        })
        XCTAssertEqual(ParakeetV3ModelSpec.allFiles.reduce(0) { $0 + $1.bytes }, ParakeetV3ModelSpec.totalBytes)
        XCTAssertEqual(Set(ParakeetV3ModelSpec.allFiles.map(\.path)).count, ParakeetV3ModelSpec.allFiles.count)
        XCTAssertEqual(ParakeetV3ModelSpec.allFiles.first, ParakeetV3ModelSpec.vocabularyFile, "vocabulary first")
        XCTAssertEqual(ParakeetV3ModelSpec.checkedFiles, [ParakeetV3ModelSpec.vocabularyFile])
        let folders = Set(ParakeetV3ModelSpec.modelFiles.compactMap { $0.path.split(separator: "/").first.map(String.init) })
        XCTAssertEqual(folders, Set(TdtV3PreparationComponent.allCases.map { "\($0.rawValue).mlmodelc" }))
        XCTAssertEqual(TdtV3PreparationComponent.preprocessor.computeUnits, .cpuOnly)
        XCTAssertEqual(TdtV3PreparationComponent.modelComputeUnits, .cpuAndNeuralEngine, "no GPU: background preparation")
    }

    func testStoreIsSeparateFromWhisperAndExcludedFromBackup() throws {
        let store = makeStore()
        XCTAssertEqual(ParakeetV3ModelStore.defaultRoot().lastPathComponent, "ParakeetV3")
        XCTAssertNotEqual(ParakeetV3ModelStore.defaultRoot(), WhisperModelStore.defaultRoot())
        XCTAssertNotEqual(ParakeetV3ModelStore.markerFileName, WhisperModelStore.markerFileName)
        XCTAssertNotEqual(ParakeetV3ModelStore.preparationFileName, ParakeetV3ModelStore.markerFileName)
        try store.prepareRoot()
        let values = try store.root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testInstalledNeedsTheMarkerAndEveryFileAtItsExactSize() throws {
        let store = makeStore()
        XCTAssertFalse(store.isInstalled)
        try ParakeetV3TestFiles.populate(store, marker: false)
        XCTAssertTrue(store.filesComplete)
        XCTAssertFalse(store.isInstalled, "files without the marker are a partial download")
        try store.writeMarker()
        XCTAssertTrue(store.isInstalled)

        let encoder = try XCTUnwrap(ParakeetV3ModelSpec.modelFiles.last)
        try WhisperTestFiles.writeSparse(store.fileURL(for: encoder), bytes: encoder.bytes - 1)
        XCTAssertFalse(store.isInstalled, "a short file is never installed")
        try ParakeetV3TestFiles.write(encoder, into: store.root)
        XCTAssertTrue(store.isInstalled)

        try Data(#"{"modelRepo":"FluidInference/parakeet-tdt-0.6b-v3-coreml","modelRevision":"main","totalBytes":1}"#.utf8)
            .write(to: store.markerURL)
        XCTAssertFalse(store.isInstalled, "a marker for another revision is not this install")
    }

    func testVocabularyMustBeTheFullTokenTable() throws {
        let store = makeStore()
        let url = store.vocabularyURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ParakeetV3TestFiles.vocabulary().write(to: url)
        let vocabulary = try TdtV3Vocabulary.load(from: url, for: .parakeetV3)
        XCTAssertEqual(vocabulary.count, TdtV3Vocabulary.size)
        XCTAssertEqual(vocabulary[8_191], "t8191")

        try ParakeetV3TestFiles.vocabulary(count: 8_000).write(to: url)
        XCTAssertThrowsError(try TdtV3Vocabulary.load(from: url, for: .parakeetV3)) {
            XCTAssertEqual($0 as? TdtV3VocabularyError, TdtV3VocabularyError(engine: .parakeetV3))
        }
        try WhisperTestFiles.writeSparse(url, bytes: ParakeetV3ModelSpec.vocabularyFile.bytes)
        XCTAssertThrowsError(try TdtV3Vocabulary.load(from: url, for: .parakeetV3), "zero bytes of the right size are damaged")
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try TdtV3Vocabulary.load(from: url, for: .parakeetV3))
    }

    func testDownloadFetchesEveryFileInOrderReportsBytesAndVerifiesBeforeInstalled() async throws {
        let store = makeStore()
        let downloader = FakeParakeetV3Downloader()
        let installer = makeInstaller(store, downloader: downloader)
        XCTAssertEqual(installer.state, .notInstalled)
        XCTAssertTrue(downloader.calls.isEmpty, "creating the installer downloads nothing")

        downloader.hold()
        let task = installer.install()
        try await waitForState("Parakeet V3 download running") {
            if case .downloading = installer.state { !downloader.calls.isEmpty } else { false }
        }
        guard case .downloading(let progress) = installer.state else { return XCTFail("\(installer.state)") }
        XCTAssertEqual(progress.totalBytes, ParakeetV3ModelSpec.totalBytes)
        XCTAssertFalse(store.hasMarker)
        downloader.release()
        await task.value

        XCTAssertEqual(installer.state, .installed)
        XCTAssertEqual(downloader.calls, ParakeetV3ModelSpec.allFiles.map(\.path))
        XCTAssertTrue(store.isInstalled)
        XCTAssertTrue(installer.isInstalled)

        await installer.install().value
        XCTAssertEqual(downloader.calls.count, ParakeetV3ModelSpec.allFiles.count, "installed: no network at all")
    }

    func testCancelKeepsDownloadedFilesAndRetryFetchesOnlyTheRest() async throws {
        let store = makeStore()
        let downloader = FakeParakeetV3Downloader()
        let installer = makeInstaller(store, downloader: downloader)
        let keptCount = 3
        try ParakeetV3TestFiles.populate(store, marker: false,
                                         except: Set(ParakeetV3ModelSpec.allFiles.dropFirst(keptCount).map(\.path)))
        downloader.hold()
        let first = installer.install()
        try await waitForState("Parakeet V3 download held") { !downloader.calls.isEmpty }
        installer.cancel()
        XCTAssertEqual(installer.state, .cancelled)
        downloader.release()
        await first.value
        XCTAssertEqual(installer.state, .cancelled)
        XCTAssertFalse(store.isInstalled)
        for file in ParakeetV3ModelSpec.allFiles.prefix(keptCount) {
            XCTAssertEqual(store.size(of: file), file.bytes, "\(file.path) is kept for Retry")
        }

        await installer.install().value
        XCTAssertEqual(installer.state, .installed)
        let fetched = Set(downloader.calls)
        XCTAssertTrue(fetched.isDisjoint(with: ParakeetV3ModelSpec.allFiles.prefix(keptCount).map(\.path)))
    }

    func testOfflineFailureOffersRetryAndDamagedVocabularyIsReplaced() async throws {
        let store = makeStore()
        let downloader = FakeParakeetV3Downloader()
        let installer = makeInstaller(store, downloader: downloader)
        downloader.fail(with: URLError(.notConnectedToInternet))
        await installer.install().value
        XCTAssertEqual(installer.state, .failed("No internet connection. Connect and tap Retry."))
        XCTAssertFalse(store.hasMarker)

        downloader.fail(with: FakeParakeetV3Failure())
        await installer.install().value
        XCTAssertEqual(installer.state, .failed("Download failed: Server said no. Tap Retry to start again."))

        try ParakeetV3TestFiles.populate(store, marker: true)
        try WhisperTestFiles.writeSparse(store.vocabularyURL, bytes: ParakeetV3ModelSpec.vocabularyFile.bytes)
        downloader.fail(with: nil)
        let before = downloader.calls.count
        await installer.install().value
        XCTAssertEqual(installer.state, .installed)
        XCTAssertEqual(Array(downloader.calls.dropFirst(before)), [ParakeetV3ModelSpec.vocabularyFile.path])
    }

    func testInsufficientStorageStopsBeforeDownloading() async throws {
        let store = makeStore()
        let downloader = FakeParakeetV3Downloader()
        let installer = makeInstaller(store, downloader: downloader, capacity: 1_000_000)
        await installer.install().value
        let needed = ParakeetV3ModelSpec.totalBytes + ParakeetV3ModelSpec.storageHeadroomBytes
        XCTAssertEqual(installer.state, .failed(try XCTUnwrap(ModelInstallError.insufficientStorage(
            model: "Parakeet V3", needed: needed, available: 1_000_000).errorDescription)))
        XCTAssertTrue(downloader.calls.isEmpty)
    }

    func testPreparationRefusesAnUninstalledModel() async throws {
        let store = makeStore()
        try ParakeetV3TestFiles.populate(store, marker: false)
        let transcriber = ParakeetV3Transcriber(store: store, language: .german, availableCapacity: { .max })
        do {
            try await transcriber.prepare { _ in }
            XCTFail("an unverified model is never prepared")
        } catch let error as ParakeetV3Transcriber.TranscriberError {
            XCTAssertEqual(error, .notInstalled)
        }
    }

    func testPreparationStopsBeforeModelWorkWithoutOptimizationStorage() async throws {
        let store = makeStore()
        try ParakeetV3TestFiles.populate(store, marker: true)
        let log = PreparationProgressLog()
        let free: Int64 = 300_000_000
        let transcriber = ParakeetV3Transcriber(store: store, language: .german,
                                                availableCapacity: { free }, environment: "env")
        do {
            try await transcriber.prepare { log.append($0) }
            XCTFail("specialization without enough storage must not start")
        } catch let error as ParakeetV3Transcriber.TranscriberError {
            XCTAssertEqual(error, .insufficientStorage(free))
        }
        XCTAssertTrue(log.values.isEmpty)
        XCTAssertTrue(store.isInstalled, "a storage stop never invalidates the install")
        XCTAssertEqual(store.preparationRecord, ModelPreparationRecord())
    }

    func testDamagedVocabularyInvalidatesTheInstallAndAsksForDownload() async throws {
        let store = makeStore()
        try ParakeetV3TestFiles.populate(store, marker: true)
        try WhisperTestFiles.writeSparse(store.vocabularyURL, bytes: ParakeetV3ModelSpec.vocabularyFile.bytes)
        let transcriber = ParakeetV3Transcriber(store: store, language: .english, availableCapacity: { .max })
        do {
            try await transcriber.prepare { _ in }
            XCTFail("a damaged vocabulary must stop preparation")
        } catch let error as ParakeetV3Transcriber.TranscriberError {
            guard case .corruptModel = error else { return XCTFail("expected corruptModel, got \(error)") }
            XCTAssertTrue(error.localizedDescription.contains("Download Parakeet V3 again"))
        }
        XCTAssertFalse(store.hasMarker)
    }

    func testSparseModelsFailAsPreparationWithoutDownloadAdviceAndClearTheInProgressMark() async throws {
        let store = makeStore()
        try ParakeetV3TestFiles.populate(store, marker: true)
        let log = PreparationProgressLog()
        let transcriber = ParakeetV3Transcriber(store: store, language: .english,
                                                availableCapacity: { .max }, environment: "env")
        do {
            try await transcriber.prepare { log.append($0) }
            XCTFail("zero-filled Core ML models cannot load")
        } catch let error as ParakeetV3Transcriber.TranscriberError {
            guard case .preparationFailed = error else { return XCTFail("expected preparationFailed, got \(error)") }
        }
        XCTAssertEqual(store.preparationRecord, ModelPreparationRecord(loadedEnvironment: nil, inProgress: false))
        XCTAssertTrue(log.values.contains { $0.detail.hasPrefix("Optimizing Parakeet V3 audio features") })
        XCTAssertTrue(store.isInstalled, "a Core ML failure is not evidence of damaged downloads")
    }

    func testComponentsLoadInOrderWithMilestonesAndStopAtTheFirstFailure() async throws {
        let log = PreparationProgressLog()
        var loaded: [TdtV3PreparationComponent] = []
        _ = try await TdtV3PreparationComponent.prepare(engine: .parakeetV3, optimizing: true, progressHandler: { log.append($0) }) {
            loaded.append($0)
        }
        XCTAssertEqual(loaded, [.preprocessor, .decoder, .joint, .encoder])
        XCTAssertEqual(log.values.map { $0.stageProgress?.completed }, [0, 1, 2, 3])
        XCTAssertTrue(log.values.allSatisfy { $0.stageProgress?.total == ModelPreparationProgress.milestoneCount })
        XCTAssertTrue(log.values.allSatisfy { $0.fractionCompleted == nil })
        XCTAssertEqual(TdtV3PreparationComponent.encoder.progress(engine: .parakeetV3, optimizing: false).detail,
                       "Loading Parakeet V3 audio encoder · Step 4 of 4")

        loaded = []
        do {
            _ = try await TdtV3PreparationComponent.prepare(engine: .parakeetV3, optimizing: false, progressHandler: { _ in }) {
                loaded.append($0)
                if $0 == .decoder { throw FakeParakeetV3Failure() }
            }
            XCTFail("a failed load stops preparation")
        } catch is FakeParakeetV3Failure {}
        XCTAssertEqual(loaded, [.preprocessor, .decoder])
    }

    func testLanguageNamesAndHintsFollowTheDictationLanguage() {
        XCTAssertEqual(ParakeetV3Transcriber.languageName(for: .automatic), "Automatic (detected by Parakeet V3)")
        XCTAssertEqual(ParakeetV3Transcriber.languageName(for: .german), "German")
        XCTAssertEqual(ParakeetV3Transcriber.languageName(for: .english), "English")
        XCTAssertNil(ParakeetV3Transcriber.languageHint(for: .automatic))
        XCTAssertEqual(ParakeetV3Transcriber.languageHint(for: .german)?.rawValue, "de")
        XCTAssertEqual(ParakeetV3Transcriber.languageHint(for: .english)?.rawValue, "en")
    }

    func testFailuresAreClassifiedForTheDictationLog() {
        typealias E = ParakeetV3Transcriber.TranscriberError
        XCTAssertEqual(DictationLogASRFailure.classify(E.notInstalled), .modelNotReady)
        XCTAssertEqual(DictationLogASRFailure.classify(E.preparationFailed("x")), .modelNotReady)
        XCTAssertEqual(DictationLogASRFailure.classify(E.emptyTranscript), .noSpeech)
        XCTAssertTrue(DictationController.transcriptionFailureKeepsModel(E.emptyTranscript))
        XCTAssertFalse(DictationController.transcriptionFailureKeepsModel(E.corruptModel("x")))
    }

    func testProductionProviderReportsParakeetV3FromDiskOnly() async throws {
        let store = makeStore()
        let whisper = WhisperModelStore(root: store.root.appendingPathComponent("whisper"))
        let provider = ProductionSpeechEngineProvider(whisperStore: whisper, parakeetV3Store: store)
        XCTAssertFalse(provider.isInstalled(.parakeetV3))
        let missing = await provider.availability(of: .parakeetV3, language: .german)
        XCTAssertEqual(missing, .downloadRequired("Not downloaded (\(ParakeetV3ModelSpec.downloadSizeLabel))."))
        do {
            _ = try await provider.transcriber(for: .parakeetV3, language: .german)
            XCTFail("an uninstalled Parakeet V3 is never created")
        } catch {
            XCTAssertEqual(error as? SpeechEngineError, .notInstalled(.parakeetV3))
        }

        try ParakeetV3TestFiles.populate(store, marker: false)
        XCTAssertFalse(provider.isInstalled(.parakeetV3))
        try store.writeMarker()
        XCTAssertTrue(provider.isInstalled(.parakeetV3))
        XCTAssertFalse(provider.isInstalled(.whisperLargeV3Turbo), "each engine has its own install")
        let present = await provider.availability(of: .parakeetV3, language: .automatic)
        XCTAssertEqual(present, .installed)
        let created = try await provider.transcriber(for: .parakeetV3, language: .german)
        XCTAssertEqual(created.displayName, "Parakeet V3")
        let languageName = await created.languageName
        XCTAssertEqual(languageName, "German")
    }
}
