import Foundation
import XCTest
@testable import Typr

nonisolated enum CohereTestFiles {
    // JSON allows trailing whitespace, so padding keeps the vocabulary parseable at its pinned size.
    static func vocabulary(count: Int = CohereModelSpec.vocabularySize) throws -> Data {
        let tokens = Dictionary(uniqueKeysWithValues: (0..<count).map { (String($0), "t\($0)") })
        var data = try JSONEncoder().encode(tokens)
        let pinned = Int(CohereModelSpec.vocabularyFile.bytes)
        guard data.count <= pinned else { throw CocoaError(.fileWriteOutOfSpace) }
        data.append(Data(repeating: UInt8(ascii: " "), count: pinned - data.count))
        return data
    }

    static func write(_ file: PinnedModelFile, into root: URL) throws {
        let url = CohereModelStore(root: root).fileURL(for: file)
        if file == CohereModelSpec.vocabularyFile {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try vocabulary().write(to: url)
        } else {
            try WhisperTestFiles.writeSparse(url, bytes: file.bytes)
        }
    }

    static func populate(_ store: CohereModelStore, marker: Bool) throws {
        for file in CohereModelSpec.allFiles {
            try write(file, into: store.root)
        }
        if marker {
            try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
            try store.writeMarker()
        }
    }
}

@MainActor
final class CohereTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() async throws {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots = []
    }

    private func makeStore() -> CohereModelStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("typr-cohere-tests-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        return CohereModelStore(root: root)
    }

    func testVocabularyMustBeTheFullTokenTable() throws {
        let store = makeStore()
        let url = store.vocabularyURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try CohereTestFiles.vocabulary().write(to: url)
        XCTAssertNoThrow(try CohereVocabulary.check(url))

        try CohereTestFiles.vocabulary(count: 16_000).write(to: url)
        XCTAssertThrowsError(try CohereVocabulary.check(url)) {
            XCTAssertEqual($0 as? CohereVocabularyError, .damaged)
        }
        try WhisperTestFiles.writeSparse(url, bytes: CohereModelSpec.vocabularyFile.bytes)
        XCTAssertThrowsError(try CohereVocabulary.check(url), "zero bytes of the right size are damaged")
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try CohereVocabulary.check(url))
    }

    func testPreparationRefusesAnUninstalledModel() async throws {
        let store = makeStore()
        try CohereTestFiles.populate(store, marker: false)
        let transcriber = CohereTranscriber(store: store, language: .german, availableCapacity: { .max })
        do {
            try await transcriber.prepare { _ in }
            XCTFail("an unverified model is never prepared")
        } catch let error as CohereTranscriber.TranscriberError {
            XCTAssertEqual(error, .notInstalled)
        }
    }

    func testPreparationStopsBeforeModelWorkWithoutOptimizationStorage() async throws {
        let store = makeStore()
        try CohereTestFiles.populate(store, marker: true)
        let log = PreparationProgressLog()
        let free = WhisperModelSpec.optimizationStorageBytes
        let transcriber = CohereTranscriber(store: store, language: .german,
                                            availableCapacity: { free }, environment: "env")
        do {
            try await transcriber.prepare { log.append($0) }
            XCTFail("specialization without enough storage must not start")
        } catch let error as CohereTranscriber.TranscriberError {
            XCTAssertEqual(error, .insufficientStorage(free))
        }
        XCTAssertTrue(log.values.isEmpty)
        XCTAssertTrue(store.isInstalled, "a storage stop never invalidates the install")
        XCTAssertEqual(store.preparationRecord, ModelPreparationRecord())
    }

    func testDamagedVocabularyInvalidatesTheInstallAndAsksForDownload() async throws {
        let store = makeStore()
        try CohereTestFiles.populate(store, marker: true)
        try WhisperTestFiles.writeSparse(store.vocabularyURL, bytes: CohereModelSpec.vocabularyFile.bytes)
        let transcriber = CohereTranscriber(store: store, language: .english, availableCapacity: { .max })
        do {
            try await transcriber.prepare { _ in }
            XCTFail("a damaged vocabulary must stop preparation")
        } catch let error as CohereTranscriber.TranscriberError {
            guard case .corruptModel = error else { return XCTFail("expected corruptModel, got \(error)") }
            XCTAssertTrue(error.localizedDescription.contains("Download Cohere Transcribe again"))
        }
        XCTAssertFalse(store.hasMarker)
    }

    func testSparseModelsFailAsPreparationWithoutDownloadAdviceAndClearTheInProgressMark() async throws {
        let store = makeStore()
        try CohereTestFiles.populate(store, marker: true)
        let log = PreparationProgressLog()
        let transcriber = CohereTranscriber(store: store, language: .english,
                                            availableCapacity: { .max }, environment: "env")
        do {
            try await transcriber.prepare { log.append($0) }
            XCTFail("zero-filled Core ML models cannot load")
        } catch let error as CohereTranscriber.TranscriberError {
            guard case .preparationFailed = error else { return XCTFail("expected preparationFailed, got \(error)") }
        }
        XCTAssertEqual(store.preparationRecord, ModelPreparationRecord(loadedEnvironment: nil, inProgress: false))
        XCTAssertTrue(log.values.contains { $0.detail == CohereTranscriber.optimizingDetail })
        XCTAssertTrue(store.isInstalled, "a Core ML failure is not evidence of damaged downloads")
    }

    func testDictationLanguageSelectsCohereLanguageAndAutomaticFollowsIPhoneLanguages() {
        XCTAssertEqual(CohereTranscriber.cohereLanguage(for: .german, preferredLanguages: ["fr-FR"]), .german)
        XCTAssertEqual(CohereTranscriber.cohereLanguage(for: .english, preferredLanguages: ["de-DE"]), .english)
        XCTAssertEqual(CohereTranscriber.cohereLanguage(for: .automatic, preferredLanguages: ["de-AT", "en-US"]), .german)
        XCTAssertEqual(CohereTranscriber.cohereLanguage(for: .automatic, preferredLanguages: ["sv-SE", "fr-CH"]), .french,
                       "the first supported iPhone language")
        XCTAssertEqual(CohereTranscriber.cohereLanguage(for: .automatic, preferredLanguages: ["zh-Hans-CN"]), .chinese)
        XCTAssertEqual(CohereTranscriber.cohereLanguage(for: .automatic, preferredLanguages: ["sv-SE"]), .english)
        XCTAssertEqual(CohereTranscriber.cohereLanguage(for: .automatic, preferredLanguages: []), .english)

        XCTAssertEqual(CohereTranscriber.languageName(for: .german), "German")
        XCTAssertEqual(CohereTranscriber.languageName(for: .english), "English")
        XCTAssertEqual(CohereTranscriber.languageName(for: .automatic, preferredLanguages: ["de-DE"]),
                       "Automatic (German, from iPhone languages)")
    }

    func testPreparationStagesDriveTheContinuedTask() {
        typealias B = ModelBackgroundPreparation
        XCTAssertEqual(B.taskTitle(for: .cohereTranscribe), "Preparing Cohere Transcribe")
        XCTAssertEqual(B.taskSubtitle(for: CohereTranscriber.loadingProgress(optimizing: true)), "Optimizing for this iPhone")
        XCTAssertEqual(B.taskSubtitle(for: CohereTranscriber.loadingProgress(optimizing: false)), "Loading model")
        XCTAssertEqual(B.taskSubtitle(for: CohereTranscriber.checkingProgress), "Checking model")
        let progress = Progress(totalUnitCount: -1)
        for update in [CohereTranscriber.loadingProgress(optimizing: true), CohereTranscriber.checkingProgress] {
            XCTAssertEqual(update.stageProgress?.total, ModelPreparationProgress.milestoneCount)
            B.updateTaskProgress(progress, from: update)
            XCTAssertEqual(progress.completedUnitCount, (update.stageProgress?.completed ?? -1) * B.unitsPerStage)
        }
    }

    func testFailuresAreClassifiedForTheDictationLog() {
        typealias E = CohereTranscriber.TranscriberError
        XCTAssertEqual(DictationLogASRFailure.classify(E.notInstalled), .modelNotReady)
        XCTAssertEqual(DictationLogASRFailure.classify(E.preparationFailed("x")), .modelNotReady)
        XCTAssertEqual(DictationLogASRFailure.classify(E.emptyTranscript), .noSpeech)
        XCTAssertTrue(DictationController.transcriptionFailureKeepsModel(E.emptyTranscript))
        XCTAssertFalse(DictationController.transcriptionFailureKeepsModel(E.corruptModel("x")))
    }

    func testProductionProviderReportsCohereFromDiskOnly() async throws {
        let store = makeStore()
        let whisper = WhisperModelStore(root: makeStore().root)
        let parakeetV3 = ParakeetV3ModelStore(root: makeStore().root)
        try ParakeetV3TestFiles.populate(parakeetV3, marker: true)
        let provider = ProductionSpeechEngineProvider(whisperStore: whisper, parakeetV3Store: parakeetV3,
                                                      cohereStore: store)
        XCTAssertFalse(provider.isInstalled(.cohereTranscribe))
        let missing = await provider.availability(of: .cohereTranscribe, language: .german)
        XCTAssertEqual(missing, .downloadRequired("Not downloaded (\(CohereModelSpec.downloadSizeLabel))."))
        do {
            _ = try await provider.transcriber(for: .cohereTranscribe, language: .german)
            XCTFail("an uninstalled Cohere Transcribe is never created")
        } catch {
            XCTAssertEqual(error as? SpeechEngineError, .notInstalled(.cohereTranscribe))
        }

        try CohereTestFiles.populate(store, marker: false)
        XCTAssertFalse(provider.isInstalled(.cohereTranscribe))
        try store.writeMarker()
        XCTAssertTrue(provider.isInstalled(.cohereTranscribe))
        XCTAssertFalse(provider.isInstalled(.whisperLargeV3Turbo), "each engine has its own install")
        let present = await provider.availability(of: .cohereTranscribe, language: .automatic)
        XCTAssertEqual(present, .installed)
        let created = try await provider.transcriber(for: .cohereTranscribe, language: .german)
        XCTAssertEqual(created.displayName, "Cohere Transcribe")
        let languageName = await created.languageName
        XCTAssertEqual(languageName, "German")

        try provider.deleteModel(.cohereTranscribe)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.path))
        XCTAssertFalse(provider.isInstalled(.cohereTranscribe))
        XCTAssertTrue(parakeetV3.isInstalled, "another engine's model is untouched")
    }
}
