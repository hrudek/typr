import Foundation
import XCTest
import ZIPFoundation
@testable import Typr

nonisolated enum OrukeetTestFiles {
    static func populateCompiled(_ store: OrukeetModelStore) throws {
        for component in TdtV3PreparationComponent.allCases {
            let folder = store.modelFolder.appending(component: component.compiledFolderName)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("model".utf8).write(to: folder.appending(component: "model.mil"))
        }
        try ParakeetV3TestFiles.vocabulary().write(to: store.vocabularyURL)
    }

    static func compile(_ package: URL) throws -> URL {
        let output = FileManager.default.temporaryDirectory
            .appending(component: "typr-orukeet-compiled-\(UUID().uuidString).mlmodelc")
        try FileManager.default.copyItem(at: package, to: output)
        return output
    }

    static func writeArchive(to url: URL, folder: String, files: [String: Data], extra: [String: Data] = [:]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let archive = try Archive(url: url, accessMode: .create)
        let all = files.map { ("\(folder)/\($0.key)", $0.value) } + extra.map { ($0.key, $0.value) }
        for (path, data) in all {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count),
                                 compressionMethod: .deflate) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
    }
}

private struct FakeOrukeetFailure: LocalizedError {
    var errorDescription: String? { "Compiler said no." }
}

private final class FakeOrukeetDownloader: ModelFileDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var holding = false

    var calls: [String] { lock.withLock { recorded } }
    func hold() { lock.withLock { holding = true } }
    func release() { lock.withLock { holding = false } }

    func download(_ file: PinnedModelFile, into root: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws {
        lock.withLock { recorded.append(file.path) }
        progress(0.5)
        while lock.withLock({ holding }) { try await Task.sleep(for: .milliseconds(10)) }
        try WhisperTestFiles.writeSparse(OrukeetModelStore(root: root).fileURL(for: file), bytes: file.bytes)
        progress(1)
    }
}

private final class FakeOrukeetUnpacker: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var failures: [any Error] = []

    var calls: Int { lock.withLock { count } }
    func fail(with error: any Error) { lock.withLock { failures.append(error) } }

    func unpack(_ store: OrukeetModelStore) throws {
        let failure: (any Error)? = lock.withLock {
            count += 1
            return failures.isEmpty ? nil : failures.removeFirst()
        }
        if let failure { throw failure }
        try OrukeetTestFiles.populateCompiled(store)
        try FileManager.default.removeItem(at: store.fileURL(for: OrukeetModelSpec.archive))
    }
}

@MainActor
final class OrukeetTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() async throws {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots = []
    }

    private func makeStore() -> OrukeetModelStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("typr-orukeet-tests-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        return OrukeetModelStore(root: root)
    }

    private func makeInstaller(_ store: OrukeetModelStore, downloader: FakeOrukeetDownloader,
                               unpacker: FakeOrukeetUnpacker, capacity: Int64? = .max) -> OrukeetModelInstaller {
        OrukeetModelInstaller(store: store, downloader: downloader, unpack: { try unpacker.unpack($0) },
                              availableCapacity: { capacity })
    }

    func testSpecPinsOneArchiveWithItsSizeChecksumAndUnpackPeak() {
        XCTAssertEqual(OrukeetModelSpec.modelRepo, "oruk/orukeet")
        XCTAssertEqual(OrukeetModelSpec.modelRevision.count, 40, "a commit, not a branch")
        XCTAssertEqual(OrukeetModelSpec.allFiles, [OrukeetModelSpec.archive])
        XCTAssertEqual(OrukeetModelSpec.totalBytes, 554_985_744)
        XCTAssertEqual(OrukeetModelSpec.archiveSHA256.count, 64)
        XCTAssertEqual(OrukeetModelSpec.totalBytes + OrukeetModelSpec.storageHeadroomBytes, 1_818_641_670,
                       "archive, unpacked packages and compiled models at once")
        let topLevel = Set(OrukeetModelSpec.unpackedFiles.compactMap { $0.path.split(separator: "/").first.map(String.init) })
        XCTAssertEqual(topLevel, Set(TdtV3PreparationComponent.allCases.map { "\($0.rawValue).mlpackage" } + [TdtV3Vocabulary.fileName]))
        XCTAssertEqual(OrukeetModelSpec.vocabularyEntry.bytes, ParakeetV3ModelSpec.vocabularyFile.bytes)
        XCTAssertFalse(OrukeetModelSpec.acceptsLanguageHint, "greedy-only joint network")
    }

    func testStoreIsSeparateFromOtherEnginesAndExcludedFromBackup() throws {
        let store = makeStore()
        XCTAssertEqual(OrukeetModelStore.defaultRoot().lastPathComponent, "Orukeet")
        XCTAssertNotEqual(OrukeetModelStore.defaultRoot(), ParakeetV3ModelStore.defaultRoot())
        XCTAssertNotEqual(OrukeetModelStore.markerFileName, ParakeetV3ModelStore.markerFileName)
        try store.prepareRoot()
        let values = try store.root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testInstalledNeedsTheMarkerTheCompiledModelsAndTheVocabulary() throws {
        let store = makeStore()
        XCTAssertFalse(store.isInstalled)
        try WhisperTestFiles.writeSparse(store.fileURL(for: OrukeetModelSpec.archive), bytes: OrukeetModelSpec.archive.bytes)
        try store.writeMarker()
        XCTAssertFalse(store.isInstalled, "the archive alone is not installed")

        try OrukeetTestFiles.populateCompiled(store)
        XCTAssertTrue(store.isInstalled)
        let encoder = store.modelFolder.appending(component: TdtV3PreparationComponent.encoder.compiledFolderName)
        try FileManager.default.removeItem(at: encoder)
        XCTAssertFalse(store.isInstalled, "a missing compiled model is never installed")
        try OrukeetTestFiles.populateCompiled(store)
        try WhisperTestFiles.writeSparse(store.vocabularyURL, bytes: OrukeetModelSpec.vocabularyEntry.bytes - 1)
        XCTAssertFalse(store.isInstalled, "a short vocabulary is never installed")

        try OrukeetTestFiles.populateCompiled(store)
        try Data(#"{"modelRepo":"oruk/orukeet","modelRevision":"main","archiveSHA256":"x"}"#.utf8).write(to: store.markerURL)
        XCTAssertFalse(store.isInstalled, "a marker for another revision is not this install")
    }

    func testArchiveUnpacksOnlyPinnedEntriesCompilesThemAndDeletesTheArchive() async throws {
        let store = makeStore()
        try OrukeetTestFiles.populateCompiled(store)
        try Data("old".utf8).write(to: store.modelFolder.appending(component: "stale.bin"))
        let url = store.fileURL(for: OrukeetModelSpec.archive)
        let folder = "bundle"
        var files: [String: Data] = [TdtV3Vocabulary.fileName: try ParakeetV3TestFiles.vocabulary()]
        for component in TdtV3PreparationComponent.allCases {
            files["\(component.rawValue).mlpackage/Manifest.json"] = Data(component.rawValue.utf8)
        }
        try OrukeetTestFiles.writeArchive(to: url, folder: folder, files: files,
                                          extra: ["../escaped.txt": Data("x".utf8), "\(folder)/README.md": Data("r".utf8)])
        let archive = OrukeetArchive(
            sha256: try OrukeetArchive.sha256(of: url), folder: folder,
            entries: files.map { OrukeetArchive.Entry(path: $0.key, bytes: Int64($0.value.count)) },
            compile: { try OrukeetTestFiles.compile($0) })

        try await archive.unpack(into: store)

        for component in TdtV3PreparationComponent.allCases {
            let manifest = store.modelFolder.appending(path: "\(component.compiledFolderName)/Manifest.json")
            XCTAssertEqual(try Data(contentsOf: manifest), Data(component.rawValue.utf8))
        }
        XCTAssertEqual(try TdtV3Vocabulary.load(from: store.vocabularyURL, for: .orukeet).count, TdtV3Vocabulary.size)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "the archive is not kept")
        let repo = store.repoFolder(OrukeetModelSpec.modelRepo)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: repo.path).sorted(), ["compiled", "coreml"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.modelFolder.path).sorted(),
                       (TdtV3PreparationComponent.allCases.map(\.compiledFolderName) + [TdtV3Vocabulary.fileName]).sorted())
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.deletingLastPathComponent().appending(component: "escaped.txt").path))
    }

    func testChecksumMismatchDeletesTheArchiveWithoutUnpacking() async throws {
        let store = makeStore()
        let url = store.fileURL(for: OrukeetModelSpec.archive)
        try OrukeetTestFiles.writeArchive(to: url, folder: "bundle", files: ["parakeet_vocab.json": Data("{}".utf8)])
        do {
            try await OrukeetArchive().unpack(into: store)
            XCTFail("an archive with another checksum is never unpacked")
        } catch {
            XCTAssertEqual(error as? OrukeetArchiveError, .damaged)
            XCTAssertEqual(ModelInstaller<OrukeetModelSpec>.message(for: error),
                           "The Orukeet download is damaged. Tap Retry to download it again.")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Retry downloads it again")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.modelFolder.path))
    }

    func testFailedCompilationKeepsTheArchiveAndLeavesNoPartialModels() async throws {
        let store = makeStore()
        let url = store.fileURL(for: OrukeetModelSpec.archive)
        let files = ["Preprocessor.mlpackage/Manifest.json": Data("p".utf8)]
        try OrukeetTestFiles.writeArchive(to: url, folder: "bundle", files: files)
        let archive = OrukeetArchive(sha256: try OrukeetArchive.sha256(of: url), folder: "bundle",
                                     entries: [OrukeetArchive.Entry(path: "Preprocessor.mlpackage/Manifest.json", bytes: 1)],
                                     compile: { _ in throw FakeOrukeetFailure() })
        do {
            try await archive.unpack(into: store)
            XCTFail("a failed compilation stops the install")
        } catch is FakeOrukeetFailure {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Retry unpacks without downloading")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.modelFolder.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.repoFolder(OrukeetModelSpec.modelRepo).appending(component: "unpacking").path))
    }

    func testDownloadReportsBytesUnpacksAndVerifiesBeforeInstalled() async throws {
        let store = makeStore()
        let downloader = FakeOrukeetDownloader()
        let unpacker = FakeOrukeetUnpacker()
        let installer = makeInstaller(store, downloader: downloader, unpacker: unpacker)
        XCTAssertEqual(installer.state, .notInstalled)
        XCTAssertTrue(downloader.calls.isEmpty, "creating the installer downloads nothing")

        downloader.hold()
        let task = installer.install()
        try await waitForState("Orukeet download running") {
            if case .downloading = installer.state { !downloader.calls.isEmpty } else { false }
        }
        guard case .downloading(let progress) = installer.state else { return XCTFail("\(installer.state)") }
        XCTAssertEqual(progress.totalBytes, OrukeetModelSpec.totalBytes)
        XCTAssertEqual(unpacker.calls, 0)
        XCTAssertFalse(store.hasMarker)
        downloader.release()
        await task.value

        XCTAssertEqual(installer.state, .installed)
        XCTAssertEqual(downloader.calls, [OrukeetModelSpec.archive.path])
        XCTAssertEqual(unpacker.calls, 1)
        XCTAssertTrue(store.isInstalled)
    }

    func testCancelledDownloadRetriesTheArchive() async throws {
        let store = makeStore()
        let downloader = FakeOrukeetDownloader()
        let unpacker = FakeOrukeetUnpacker()
        let installer = makeInstaller(store, downloader: downloader, unpacker: unpacker)
        downloader.hold()
        let first = installer.install()
        try await waitForState("Orukeet download held") { !downloader.calls.isEmpty }
        installer.cancel()
        XCTAssertEqual(installer.state, .cancelled)
        downloader.release()
        await first.value
        XCTAssertEqual(installer.state, .cancelled)
        XCTAssertEqual(unpacker.calls, 0)
        XCTAssertFalse(store.isInstalled)

        await installer.install().value
        XCTAssertEqual(installer.state, .installed)
    }

    func testFailedUnpackOffersRetryThatUnpacksTheKeptArchiveWithoutDownloading() async throws {
        let store = makeStore()
        let downloader = FakeOrukeetDownloader()
        let unpacker = FakeOrukeetUnpacker()
        unpacker.fail(with: FakeOrukeetFailure())
        let installer = makeInstaller(store, downloader: downloader, unpacker: unpacker)
        await installer.install().value
        XCTAssertEqual(installer.state, .failed("Download failed: Compiler said no. Tap Retry to start again."))
        XCTAssertFalse(store.hasMarker)

        await installer.install().value
        XCTAssertEqual(installer.state, .installed)
        XCTAssertEqual(downloader.calls, [OrukeetModelSpec.archive.path], "the verified archive was kept")
        XCTAssertEqual(unpacker.calls, 2)
    }

    func testInsufficientStorageCountsTheUnpackPeak() async throws {
        let store = makeStore()
        let downloader = FakeOrukeetDownloader()
        let unpacker = FakeOrukeetUnpacker()
        let installer = makeInstaller(store, downloader: downloader, unpacker: unpacker, capacity: 1_000_000)
        await installer.install().value
        let needed = OrukeetModelSpec.totalBytes + OrukeetModelSpec.storageHeadroomBytes
        XCTAssertEqual(installer.state, .failed(try XCTUnwrap(ModelInstallError.insufficientStorage(
            model: "Orukeet", needed: needed, available: 1_000_000).errorDescription)))
        XCTAssertTrue(downloader.calls.isEmpty)

        try WhisperTestFiles.writeSparse(store.fileURL(for: OrukeetModelSpec.archive), bytes: OrukeetModelSpec.archive.bytes)
        await installer.install().value
        XCTAssertEqual(installer.state, .failed(try XCTUnwrap(ModelInstallError.insufficientStorage(
            model: "Orukeet", needed: OrukeetModelSpec.storageHeadroomBytes, available: 1_000_000).errorDescription)),
                       "unpacking a kept archive needs its space too")
        XCTAssertEqual(unpacker.calls, 0)
    }

    func testPreparationRefusesAnUninstalledModel() async throws {
        let store = makeStore()
        try OrukeetTestFiles.populateCompiled(store)
        let transcriber = OrukeetTranscriber(store: store, language: .german, availableCapacity: { .max })
        do {
            try await transcriber.prepare { _ in }
            XCTFail("an unverified model is never prepared")
        } catch let error as OrukeetTranscriber.TranscriberError {
            XCTAssertEqual(error, .notInstalled)
            XCTAssertEqual(error.localizedDescription, "Orukeet is not downloaded. Download it under Speech engine.")
        }
    }

    func testDamagedVocabularyInvalidatesTheInstallAndAsksForDownload() async throws {
        let store = makeStore()
        try OrukeetTestFiles.populateCompiled(store)
        try store.writeMarker()
        try WhisperTestFiles.writeSparse(store.vocabularyURL, bytes: OrukeetModelSpec.vocabularyEntry.bytes)
        let transcriber = OrukeetTranscriber(store: store, language: .english, availableCapacity: { .max })
        do {
            try await transcriber.prepare { _ in }
            XCTFail("a damaged vocabulary must stop preparation")
        } catch let error as OrukeetTranscriber.TranscriberError {
            guard case .corruptModel = error else { return XCTFail("expected corruptModel, got \(error)") }
            XCTAssertTrue(error.localizedDescription.contains("Download Orukeet again"))
        }
        XCTAssertFalse(store.hasMarker)
    }

    func testUnloadableModelsFailAsPreparationWithOrukeetStages() async throws {
        let store = makeStore()
        try OrukeetTestFiles.populateCompiled(store)
        try store.writeMarker()
        let log = PreparationProgressLog()
        let transcriber = OrukeetTranscriber(store: store, language: .english,
                                             availableCapacity: { .max }, environment: "env")
        do {
            try await transcriber.prepare { log.append($0) }
            XCTFail("placeholder Core ML models cannot load")
        } catch let error as OrukeetTranscriber.TranscriberError {
            guard case .preparationFailed = error else { return XCTFail("expected preparationFailed, got \(error)") }
        }
        XCTAssertEqual(store.preparationRecord, ModelPreparationRecord(loadedEnvironment: nil, inProgress: false))
        XCTAssertTrue(log.values.contains { $0.detail.hasPrefix("Optimizing Orukeet audio features") })
        XCTAssertTrue(store.isInstalled, "a Core ML failure is not evidence of damaged downloads")
    }

    func testLanguageIsAlwaysDetectedByTheModel() {
        for language in DictationLanguage.allCases {
            XCTAssertEqual(OrukeetTranscriber.languageName(for: language), "Automatic (detected by Orukeet)")
            XCTAssertNil(OrukeetTranscriber.languageHint(for: language))
        }
    }

    func testFailuresAreClassifiedForTheDictationLog() {
        typealias E = OrukeetTranscriber.TranscriberError
        XCTAssertEqual(DictationLogASRFailure.classify(E.notInstalled), .modelNotReady)
        XCTAssertEqual(DictationLogASRFailure.classify(E.preparationFailed("x")), .modelNotReady)
        XCTAssertEqual(DictationLogASRFailure.classify(E.emptyTranscript), .noSpeech)
        XCTAssertEqual(DictationLogASRFailure.classify(E.corruptModel("x")), .other)
    }

    func testProductionProviderReportsOrukeetFromDiskOnly() async throws {
        let store = makeStore()
        let provider = ProductionSpeechEngineProvider(
            whisperStore: WhisperModelStore(root: store.root.appendingPathComponent("whisper")),
            parakeetV3Store: ParakeetV3ModelStore(root: store.root.appendingPathComponent("v3")),
            orukeetStore: store)
        XCTAssertFalse(provider.isInstalled(.orukeet))
        let missing = await provider.availability(of: .orukeet, language: .german)
        XCTAssertEqual(missing, .downloadRequired("Not downloaded (\(OrukeetModelSpec.downloadSizeLabel))."))
        do {
            _ = try await provider.transcriber(for: .orukeet, language: .german)
            XCTFail("an uninstalled Orukeet is never created")
        } catch {
            XCTAssertEqual(error as? SpeechEngineError, .notInstalled(.orukeet))
        }

        try OrukeetTestFiles.populateCompiled(store)
        XCTAssertFalse(provider.isInstalled(.orukeet))
        try store.writeMarker()
        XCTAssertTrue(provider.isInstalled(.orukeet))
        XCTAssertFalse(provider.isInstalled(.parakeetV3), "each engine has its own install")
        let created = try await provider.transcriber(for: .orukeet, language: .german)
        XCTAssertEqual(created.displayName, "Orukeet")
        let languageName = await created.languageName
        XCTAssertEqual(languageName, "Automatic (detected by Orukeet)")
    }
}
