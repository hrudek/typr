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

    static func populate(_ store: ParakeetV3ModelStore, marker: Bool) throws {
        for file in ParakeetV3ModelSpec.allFiles {
            try write(file, into: store.root)
        }
        if marker {
            try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
            try store.writeMarker()
        }
    }
}

private struct FakeParakeetV3Failure: Error {}

private final class FakeParakeetV3Downloader: ModelFileDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var calls: [String] { lock.withLock { recorded } }

    func download(_ file: PinnedModelFile, into root: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws {
        lock.withLock { recorded.append(file.path) }
        try ParakeetV3TestFiles.write(file, into: root)
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

    func testRetryReplacesOnlyADamagedVocabulary() async throws {
        let store = makeStore()
        let downloader = FakeParakeetV3Downloader()
        try ParakeetV3TestFiles.populate(store, marker: true)
        try WhisperTestFiles.writeSparse(store.vocabularyURL, bytes: ParakeetV3ModelSpec.vocabularyFile.bytes)
        let installer = ParakeetV3ModelInstaller(store: store, downloader: downloader, availableCapacity: { .max })
        await installer.install().value
        XCTAssertEqual(installer.state, .installed)
        XCTAssertEqual(downloader.calls, [ParakeetV3ModelSpec.vocabularyFile.path])
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
        XCTAssertEqual(DictationLogASRFailure.classify(E.corruptModel("x")), .other)
        XCTAssertEqual(DictationLogASRFailure.classify(OrukeetTranscriber.TranscriberError.notInstalled), .modelNotReady)
        XCTAssertEqual(DictationLogASRFailure.classify(OrukeetTranscriber.TranscriberError.emptyTranscript), .noSpeech)
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
