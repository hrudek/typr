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
    var calls: [String] { lock.withLock { recorded } }

    func download(_ file: PinnedModelFile, into root: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws {
        lock.withLock { recorded.append(file.path) }
        try WhisperTestFiles.writeSparse(OrukeetModelStore(root: root).fileURL(for: file), bytes: file.bytes)
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

    func testLanguageIsAlwaysDetectedByTheModel() {
        for language in DictationLanguage.allCases {
            XCTAssertEqual(OrukeetTranscriber.languageName(for: language), "Automatic (detected by Orukeet)")
            XCTAssertNil(OrukeetTranscriber.languageHint(for: language))
        }
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
