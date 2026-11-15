import Foundation
import WhisperKit
import XCTest
@testable import Typr

// Whisper transcriber and tokenizer, without a model: decoding choices as plain values, the
// silence gate, offline-only preparation (no downloader exists on this path), and special-token
// resolution through a fake lookup with Whisper Large V3's real IDs. The Core ML load and real
// decoding need the 627 MB model and a device; they are not exercised here.

/// A tiny vocabulary with V3 IDs. Unknown strings return `unknownID` (byte-level BPE answers
/// `<|endoftext|>` for strings it does not know), which the tokenizer must reject.
private struct FakeTokenLookup: WhisperTokenLookup {
    static let v3: [String: Int] = [
        "<|endoftext|>": 50_257,
        "<|startoftranscript|>": 50_258,
        "<|en|>": 50_259,
        "<|de|>": 50_261,
        "<|fr|>": 50_265,
        "<|yue|>": 50_358,
        "<|translate|>": 50_359,
        "<|transcribe|>": 50_360,
        "<|startofprev|>": 50_362,
        "<|nospeech|>": 50_363,
        "<|notimestamps|>": 50_364,
        "<|0.00|>": 50_365,
        "\u{0120}": 220,
        "Hallo": 1_000,
        "\u{0120}Welt": 1_001,
    ]

    var vocabulary: [String: Int] = Self.v3
    var unknownID: Int?

    func encode(text: String) -> [Int] { vocabulary[text].map { [$0] } ?? [] }

    func decode(tokens: [Int]) -> String {
        tokens.compactMap(convertIdToToken).joined().replacingOccurrences(of: "\u{0120}", with: " ")
    }

    func convertTokenToId(_ token: String) -> Int? { vocabulary[token] ?? unknownID }

    func convertIdToToken(_ id: Int) -> String? { vocabulary.first { $0.value == id }?.key }

    func removing(_ token: String) -> FakeTokenLookup {
        var copy = self
        copy.vocabulary[token] = nil
        return copy
    }
}

@MainActor
final class WhisperTranscriberTests: XCTestCase {
    private var root: URL!
    private var store: WhisperModelStore!

    override func setUp() async throws {
        root = WhisperTestFiles.makeRoot()
        store = WhisperModelStore(root: root)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func assertThrows<T: Sendable>(
        _ expected: WhisperTranscriber.TranscriberError,
        file: StaticString = #filePath, line: UInt = #line,
        _ body: @MainActor () async throws -> T
    ) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as WhisperTranscriber.TranscriberError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    private func assertUnresolved(_ token: String, _ lookup: FakeTokenLookup,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try TyprWhisperTokenizer(lookup: lookup), file: file, line: line) { error in
            XCTAssertEqual(error as? WhisperTokenizerError, .unresolvedToken(token), file: file, line: line)
        }
    }

    // MARK: - Decoding plan (de / en / automatic)

    func testEveryLanguageTranscribesAndNeverTranslates() {
        for language in DictationLanguage.allCases {
            let plan = WhisperDecodingPlan(language: language)
            XCTAssertFalse(plan.translates, "\(language)")
            XCTAssertTrue(plan.usePrefillPrompt, "\(language)")
            XCTAssertTrue(plan.skipSpecialTokens, "\(language)")
            XCTAssertTrue(plan.withoutTimestamps, "\(language)")
            XCTAssertFalse(plan.wordTimestamps, "\(language)")
            XCTAssertTrue(plan.chunksByVoiceActivity, "\(language)")
            XCTAssertFalse(plan.usesPromptTokens, "vocabulary is never a Whisper prompt (\(language))")
        }
    }

    func testExplicitLanguagesAreForcedAndAutomaticDetects() {
        let german = WhisperDecodingPlan(language: .german)
        XCTAssertEqual(german.languageCode, "de")
        XCTAssertFalse(german.detectLanguage)

        let english = WhisperDecodingPlan(language: .english)
        XCTAssertEqual(english.languageCode, "en")
        XCTAssertFalse(english.detectLanguage)

        // WhisperKit's default detectLanguage (!usePrefillPrompt == false) would silently force English.
        let automatic = WhisperDecodingPlan(language: .automatic)
        XCTAssertNil(automatic.languageCode)
        XCTAssertTrue(automatic.detectLanguage)

        XCTAssertNil(DictationLanguage.automatic.whisperLanguageCode)
        XCTAssertEqual(DictationLanguage.german.whisperLanguageCode, "de")
        XCTAssertEqual(DictationLanguage.english.whisperLanguageCode, "en")
        XCTAssertNotEqual(german, english)
        XCTAssertEqual(german, WhisperDecodingPlan(language: .german))
    }

    func testWhisperKitOptionsMatchThePlanForEveryLanguage() {
        for language in DictationLanguage.allCases {
            let options = WhisperDecodingPlan(language: language).decodingOptions
            switch options.task {
            case .transcribe: break
            case .translate: XCTFail("Whisper must never translate (\(language))")
            }
            XCTAssertEqual(options.language, language.whisperLanguageCode)
            XCTAssertEqual(options.detectLanguage, language == .automatic)
            XCTAssertTrue(options.usePrefillPrompt)
            XCTAssertTrue(options.skipSpecialTokens)
            XCTAssertTrue(options.withoutTimestamps)
            XCTAssertFalse(options.wordTimestamps)
            XCTAssertFalse(options.verbose)
            XCTAssertNil(options.promptTokens, "vocabulary must remain post-processing only")
            XCTAssertNil(options.prefixTokens)
            XCTAssertEqual(options.chunkingStrategy?.rawValue, "vad")
        }
    }

    // MARK: - Names

    func testDisplayAndLanguageNames() async {
        XCTAssertEqual(SpeechEngineChoice.whisperLargeV3Turbo.displayName, "Whisper Large V3 Turbo")
        let transcriber = WhisperTranscriber(store: store, language: .german)
        XCTAssertEqual(transcriber.displayName, SpeechEngineChoice.whisperLargeV3Turbo.displayName)
        XCTAssertEqual(SpeechEngineChoice(displayName: transcriber.displayName), .whisperLargeV3Turbo)
        let languageName = await transcriber.languageName
        XCTAssertEqual(languageName, "German")
        XCTAssertEqual(WhisperTranscriber.languageName(for: .english), "English")
        XCTAssertEqual(WhisperTranscriber.languageName(for: .automatic), "Automatic (detected by Whisper)")
    }

    // MARK: - Model checks

    func testOnlyTheV3VocabularySizeIsAccepted() {
        XCTAssertNoThrow(try WhisperTranscriber.validateLogitsSize(51_866))
        for size in [51_865, 51_864, 0, nil] as [Int?] {
            XCTAssertThrowsError(try WhisperTranscriber.validateLogitsSize(size), "\(String(describing: size))") { error in
                guard let typed = error as? WhisperTranscriber.TranscriberError, case .corruptModel = typed else {
                    return XCTFail("expected corruptModel, got \(error)")
                }
            }
        }
    }

    // MARK: - Silence and empty results

    func testSilenceAndRoomNoiseAreNotSpeech() {
        XCTAssertFalse(WhisperTranscriber.containsSpeech([]))
        XCTAssertFalse(WhisperTranscriber.containsSpeech([Float](repeating: 0, count: 16_000 * 3)))
        // Faint hum, RMS ~0.004: well under the energy gate.
        let hum = (0..<16_000).map { Float(0.005 * sin(Double($0) * 2 * .pi * 50 / 16_000)) }
        XCTAssertFalse(WhisperTranscriber.containsSpeech(hum))
    }

    func testAudibleSignalPassesTheGate() {
        // One second of silence, then 0.3 s at speech level (RMS ~0.21).
        let tone = (0..<4_800).map { Float(0.3 * sin(Double($0) * 2 * .pi * 220 / 16_000)) }
        XCTAssertTrue(WhisperTranscriber.containsSpeech([Float](repeating: 0, count: 16_000) + tone))
    }

    func testQuietRecordedSpeechIsNotRejectedBeforeWhisperRuns() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "term-hex-1", withExtension: "wav"))
        let original = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
        XCTAssertFalse(original.isEmpty)
        // Real speech at reduced gain, not a loud synthetic tone. Its loudest frame is
        // 0.006–0.012 RMS: both versions were incorrectly rejected by the old 0.02 gate.
        for gain in [Float(0.025), Float(0.05)] {
            let quietSpeech = original.map { $0 * gain }
            XCTAssertFalse(EnergyVAD().voiceActivity(in: quietSpeech).contains(true),
                           "fixture must reproduce the old false rejection at gain \(gain)")
            XCTAssertTrue(WhisperTranscriber.containsSpeech(quietSpeech), "gain \(gain)")
        }
    }

    func testQuietSpeechAfterSilenceAndInPartialFramePasses() {
        let tone = (0..<800).map { Float(0.012 * sin(Double($0) * 2 * .pi * 220 / 16_000)) }
        XCTAssertTrue(WhisperTranscriber.containsSpeech(tone), "50 ms partial frame")
        XCTAssertTrue(WhisperTranscriber.containsSpeech([Float](repeating: 0, count: 16_000) + tone))
    }

    func testJoinedTextCollapsesWhitespaceAndEmptyChunksAreEmpty() {
        XCTAssertEqual(WhisperTranscriber.joinedText([" Hallo ", " Welt. "]), "Hallo Welt.")
        XCTAssertEqual(WhisperTranscriber.joinedText(["Erstens,\n", "\tzweitens."]), "Erstens, zweitens.")
        XCTAssertEqual(WhisperTranscriber.joinedText([]), "")
        XCTAssertEqual(WhisperTranscriber.joinedText(["", " ", "\n"]), "")
    }

    // MARK: - Offline preparation

    func testPrepareWithoutAnInstalledModelFailsWithoutAnyWork() async {
        let transcriber = WhisperTranscriber(store: store, language: .automatic)
        let reported = ProgressLog()
        await assertThrows(.notInstalled) {
            try await transcriber.prepare { reported.append($0.detail) }
        }
        XCTAssertTrue(reported.values.isEmpty, "nothing is read, loaded or downloaded")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "preparation never creates the model folder")
    }

    func testPrepareRejectsPartialAndUnmarkedInstalls() async throws {
        // Every file, no marker (an interrupted download).
        try WhisperTestFiles.populate(store, marker: false)
        await assertThrows(.notInstalled) {
            try await WhisperTranscriber(store: self.store, language: .german).prepare { _ in }
        }
        // Marker, one file short.
        let file = WhisperModelSpec.modelFiles[14]
        try WhisperTestFiles.writeSparse(store.fileURL(for: file), bytes: file.bytes - 1)
        try store.writeMarker()
        await assertThrows(.notInstalled) {
            try await WhisperTranscriber(store: self.store, language: .german).prepare { _ in }
        }
    }

    func testInstalledButUnreadableTokenizerIsALocalCorruptModelError() async throws {
        // Exact sizes and marker, but the sparse tokenizer files are zeros: parsing fails locally.
        try WhisperTestFiles.populate(store, marker: true)
        XCTAssertTrue(store.isInstalled)
        // Unknown free space: the storage guard never blocks, whatever the test host has free.
        let transcriber = WhisperTranscriber(store: store, language: .english, availableCapacity: { nil })
        do {
            try await transcriber.prepare { _ in }
            XCTFail("a zero-filled tokenizer must not load")
        } catch let error as WhisperTranscriber.TranscriberError {
            guard case .corruptModel = error else { return XCTFail("expected corruptModel, got \(error)") }
            XCTAssertTrue(error.localizedDescription.contains("Download Whisper again"), error.localizedDescription)
        }
        XCTAssertFalse(store.hasMarker, "a bad tokenizer invalidates the historical install proof")
        XCTAssertFalse(store.isInstalled)
    }

    func testTranscribingBeforePrepareIsNotPrepared() async {
        let transcriber = WhisperTranscriber(store: store, language: .german)
        let missing = root.appendingPathComponent("never-recorded.wav")
        await assertThrows(.notPrepared) { try await transcriber.transcribe(missing) }
        await assertThrows(.notPrepared) { try await transcriber.transcribe(missing, vocabulary: ["herdr"]) }
        await assertThrows(.notPrepared) {
            try await transcriber.transcribe(missing, vocabulary: [], language: .automatic)
        }
    }

    // MARK: - Errors and log classification

    func testErrorsNeverPromiseAnAutomaticDownload() {
        let notInstalled = WhisperTranscriber.TranscriberError.notInstalled.localizedDescription
        XCTAssertTrue(notInstalled.contains("Download it under Speech engine"), notInstalled)
        XCTAssertEqual(SpeechEngineError.notInstalled(.whisperLargeV3Turbo).localizedDescription,
                       "Whisper Large V3 Turbo is not downloaded. Download it under Speech engine.")
        XCTAssertEqual(WhisperTranscriber.TranscriberError.silentAudio.localizedDescription,
                       "The recording is too quiet for Whisper. Try speaking closer to the microphone.")
        XCTAssertEqual(WhisperTranscriber.TranscriberError.emptyTranscript.localizedDescription,
                       "Whisper returned no text. Please try dictating again.")
    }

    func testWhisperAndEngineErrorsClassifyForTheDictationLog() {
        XCTAssertEqual(DictationLogASRFailure.classify(WhisperTranscriber.TranscriberError.notInstalled), .modelNotReady)
        XCTAssertEqual(DictationLogASRFailure.classify(WhisperTranscriber.TranscriberError.notPrepared), .modelNotReady)
        XCTAssertEqual(DictationLogASRFailure.classify(WhisperTranscriber.TranscriberError.silentAudio), .noSpeech)
        XCTAssertEqual(DictationLogASRFailure.classify(WhisperTranscriber.TranscriberError.emptyTranscript), .other)
        XCTAssertEqual(DictationLogASRFailure.classify(WhisperTranscriber.TranscriberError.corruptModel("x")), .other)
        XCTAssertEqual(DictationLogASRFailure.classify(WhisperTranscriber.TranscriberError.preparationFailed("x")),
                       .modelNotReady)
        XCTAssertEqual(DictationLogASRFailure.classify(WhisperTranscriber.TranscriberError.insufficientStorage(1)),
                       .modelNotReady)
        XCTAssertEqual(DictationLogASRFailure.classify(SpeechEngineError.notReady), .modelNotReady)
        XCTAssertEqual(DictationLogASRFailure.classify(SpeechEngineError.notInstalled(.whisperLargeV3Turbo)), .modelNotReady)
        XCTAssertEqual(DictationLogASRFailure.classify(SpeechEngineError.requiresNewerOS(.appleSpeech)), .other)
        XCTAssertEqual(DictationLogASRFailure.classify(SpeechEngineError.unsupportedDevice(.appleSpeech)), .other)
        XCTAssertEqual(DictationLogASRFailure.classify(SpeechEngineError.languageUnsupported(.appleSpeech, .german)), .other)
        XCTAssertEqual(DictationLogASRFailure.classify(CancellationError()), .cancelled)
    }

    // MARK: - Tokenizer

    func testV3SpecialTokensResolveToTheirExactIDs() throws {
        let tokenizer = try TyprWhisperTokenizer(lookup: FakeTokenLookup())
        let special = tokenizer.specialTokens
        XCTAssertEqual(special.endToken, 50_257)
        XCTAssertEqual(special.specialTokenBegin, 50_257)
        XCTAssertEqual(special.startOfTranscriptToken, 50_258)
        XCTAssertEqual(special.englishToken, 50_259)
        XCTAssertEqual(special.translateToken, 50_359)
        XCTAssertEqual(special.transcribeToken, 50_360)
        XCTAssertEqual(special.startOfPreviousToken, 50_362)
        XCTAssertEqual(special.noSpeechToken, 50_363)
        XCTAssertEqual(special.noTimestampsToken, 50_364)
        XCTAssertEqual(special.timeTokenBegin, 50_365)
        XCTAssertEqual(special.whitespaceToken, 220, "byte-level space, not a literal \" \" lookup")
        XCTAssertEqual(tokenizer.allLanguageTokens, [50_259, 50_261, 50_265, 50_358])
        XCTAssertTrue(tokenizer.allLanguageTokens.contains(50_261), "German")
    }

    func testTokenizerForwardsToTheLookup() throws {
        let tokenizer = try TyprWhisperTokenizer(lookup: FakeTokenLookup())
        XCTAssertEqual(tokenizer.convertTokenToId("<|de|>"), 50_261)
        XCTAssertEqual(tokenizer.convertIdToToken(50_360), "<|transcribe|>")
        XCTAssertEqual(tokenizer.encode(text: "Hallo"), [1_000])
        XCTAssertEqual(tokenizer.decode(tokens: [1_000, 1_001]), "Hallo Welt")
    }

    func testEveryMissingSpecialTokenIsALocalError() {
        for token in ["<|endoftext|>", "<|startoftranscript|>", "<|en|>", "<|translate|>", "<|transcribe|>",
                      "<|startofprev|>", "<|nospeech|>", "<|notimestamps|>", "<|0.00|>", "<|de|>"] {
            assertUnresolved(token, FakeTokenLookup().removing(token))
        }
        assertUnresolved("space", FakeTokenLookup().removing("\u{0120}"))
    }

    func testUnknownStringsMappedToEndOfTextAreRejected() {
        // Byte-level BPE answers <|endoftext|> for unknown strings; upstream would take that ID.
        var lookup = FakeTokenLookup().removing("<|nospeech|>")
        lookup.unknownID = 50_257
        assertUnresolved("<|nospeech|>", lookup)

        var noGerman = FakeTokenLookup().removing("<|de|>")
        noGerman.unknownID = 50_257
        assertUnresolved("<|de|>", noGerman)
    }

    func testGermanBelowTheSpecialRangeIsNotALanguageToken() {
        var lookup = FakeTokenLookup()
        lookup.vocabulary["<|de|>"] = 100
        assertUnresolved("<|de|>", lookup)
    }

    func testWordSplittingDropsSpecialTokensAndNeverCrashes() throws {
        let tokenizer = try TyprWhisperTokenizer(lookup: FakeTokenLookup())
        let empty = tokenizer.splitToWordTokens(tokenIds: [])
        XCTAssertEqual(empty.words, [])
        XCTAssertEqual(empty.wordTokens, [])

        let split = tokenizer.splitToWordTokens(tokenIds: [50_258, 50_261, 50_360, 1_000, 1_001, 50_257, 99_999])
        XCTAssertEqual(split.wordTokens, [[1_000], [1_001]])
        XCTAssertEqual(split.words, ["Hallo", " Welt"])

        // Out-of-vocabulary IDs: any result, but no crash and matching lengths.
        let odd = tokenizer.splitToWordTokens(tokenIds: [-1, 7, Int.max])
        XCTAssertEqual(odd.words.count, odd.wordTokens.count)
        XCTAssertFalse(odd.wordTokens.flatMap { $0 }.contains(Int.max))
    }

    // MARK: - Optimization storage guard

    private static let env = "Version 27.0.1 (Build 24A446) | 1.0 (42) | rev"
    private static let enough = WhisperModelSpec.optimizationStorageBytes
    private static let tooLittle: Int64 = 300_000_000

    func testFirstPreparationOptimizesOnlyWithEnoughStorage() {
        let fresh = WhisperPreparationRecord()
        XCTAssertEqual(WhisperPreparationPlan.decide(record: fresh, environment: Self.env, availableBytes: Self.enough),
                       .optimize)
        XCTAssertEqual(WhisperPreparationPlan.decide(record: fresh, environment: Self.env, availableBytes: Self.tooLittle),
                       .insufficientStorage(available: Self.tooLittle))
        // Unknown free space never blocks; Core ML reports its own failure.
        XCTAssertEqual(WhisperPreparationPlan.decide(record: fresh, environment: Self.env, availableBytes: nil),
                       .optimize)
    }

    func testCompletedLoadInTheSameEnvironmentLoadsEvenWithLittleStorage() {
        let loaded = WhisperPreparationRecord(loadedEnvironment: Self.env, inProgress: false)
        XCTAssertEqual(WhisperPreparationPlan.decide(record: loaded, environment: Self.env, availableBytes: Self.tooLittle),
                       .load)
    }

    func testOSOrTyprUpdateExpectsOptimizationAgain() {
        let loaded = WhisperPreparationRecord(loadedEnvironment: Self.env, inProgress: false)
        let updated = "Version 27.1 (Build 24B5) | 1.0 (43) | rev"
        XCTAssertEqual(WhisperPreparationPlan.decide(record: loaded, environment: updated, availableBytes: Self.enough),
                       .optimize)
        XCTAssertEqual(WhisperPreparationPlan.decide(record: loaded, environment: updated, availableBytes: Self.tooLittle),
                       .insufficientStorage(available: Self.tooLittle))
    }

    func testUnfinishedPreviousPreparationChecksStorageAgain() {
        // iOS terminated Typr while Core ML specialized: the cache cannot be trusted.
        let interrupted = WhisperPreparationRecord(loadedEnvironment: Self.env, inProgress: true)
        XCTAssertEqual(WhisperPreparationPlan.decide(record: interrupted, environment: Self.env, availableBytes: Self.tooLittle),
                       .insufficientStorage(available: Self.tooLittle))
        XCTAssertEqual(WhisperPreparationPlan.decide(record: interrupted, environment: Self.env, availableBytes: Self.enough),
                       .optimize)
    }

    func testPreparationRecordRoundTripsAndToleratesMissingOrDamagedFiles() throws {
        XCTAssertEqual(store.preparationRecord, WhisperPreparationRecord())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let record = WhisperPreparationRecord(loadedEnvironment: Self.env, inProgress: true)
        store.writePreparationRecord(record)
        XCTAssertEqual(store.preparationRecord, record)
        try Data("not json".utf8).write(to: store.preparationURL)
        XCTAssertEqual(store.preparationRecord, WhisperPreparationRecord())
        // The record is not part of the install: it never changes "installed".
        XCTAssertNotEqual(WhisperModelStore.preparationFileName, WhisperModelStore.markerFileName)
    }

    func testPrepareStopsBeforeAnyModelWorkWhenOptimizationLacksStorage() async throws {
        try WhisperTestFiles.populate(store, marker: true)
        let progress = ProgressLog()
        let free = Self.tooLittle
        let transcriber = WhisperTranscriber(store: store, language: .german,
                                             availableCapacity: { free }, environment: Self.env)
        do {
            try await transcriber.prepare { progress.append($0.detail) }
            XCTFail("specialization without enough storage must not start")
        } catch let error as WhisperTranscriber.TranscriberError {
            XCTAssertEqual(error, .insufficientStorage(Self.tooLittle))
        }
        XCTAssertTrue(progress.values.isEmpty, "no tokenizer read or model load started: \(progress.values)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.preparationURL.path))
        XCTAssertTrue(store.isInstalled, "a storage stop never invalidates the install")

        // An interrupted earlier preparation in the same environment is stopped the same way.
        store.writePreparationRecord(WhisperPreparationRecord(loadedEnvironment: Self.env, inProgress: true))
        do {
            try await transcriber.prepare { progress.append($0.detail) }
            XCTFail("an interrupted specialization must check storage again")
        } catch let error as WhisperTranscriber.TranscriberError {
            XCTAssertEqual(error, .insufficientStorage(Self.tooLittle))
        }
        XCTAssertEqual(store.preparationRecord, WhisperPreparationRecord(loadedEnvironment: Self.env, inProgress: true))
    }

    func testPrepareWithAnExpectedCachePassesTheGuardDespiteLittleStorage() async throws {
        try WhisperTestFiles.populate(store, marker: true)
        let loaded = WhisperPreparationRecord(loadedEnvironment: Self.env, inProgress: false)
        store.writePreparationRecord(loaded)
        let free = Self.tooLittle
        let transcriber = WhisperTranscriber(store: store, language: .german,
                                             availableCapacity: { free }, environment: Self.env)
        do {
            try await transcriber.prepare { _ in }
            XCTFail("the zero-filled tokenizer must still stop preparation")
        } catch let error as WhisperTranscriber.TranscriberError {
            // Past the guard: the (sparse) tokenizer is what fails, not storage.
            guard case .corruptModel = error else { return XCTFail("expected corruptModel, got \(error)") }
        }
        XCTAssertEqual(store.preparationRecord, loaded, "no model load started, so the record is unchanged")
    }

    func testCurrentEnvironmentNamesOSTyprAndModelRevision() {
        let environment = WhisperPreparationPlan.currentEnvironment()
        XCTAssertTrue(environment.contains(ProcessInfo.processInfo.operatingSystemVersionString))
        XCTAssertTrue(environment.hasSuffix(WhisperModelSpec.modelRevision))
    }

    func testInsufficientStorageMessageNamesNeededAndFreeSpace() {
        let message = WhisperTranscriber.TranscriberError.insufficientStorage(Self.tooLittle).errorDescription ?? ""
        let needed = ByteCountFormatter.string(fromByteCount: WhisperModelSpec.optimizationStorageBytes, countStyle: .file)
        let free = ByteCountFormatter.string(fromByteCount: Self.tooLittle, countStyle: .file)
        XCTAssertTrue(message.hasPrefix("Whisper must be optimized for this iPhone first"))
        XCTAssertTrue(message.contains(needed))
        XCTAssertTrue(message.contains("\(free) is free"))
        XCTAssertTrue(message.hasSuffix("Free up storage, then prepare Whisper again."))
    }

    func testPreparationStepsReportRealComponentsWithoutPercentages() {
        let components = WhisperPreparationComponent.allCases
        XCTAssertEqual(components, [.melSpectrogram, .textDecoder, .audioEncoder])
        for (index, component) in components.enumerated() {
            let optimizing = component.progress(optimizing: true)
            let loading = component.progress(optimizing: false)
            XCTAssertNil(optimizing.fractionCompleted)
            XCTAssertNil(loading.fractionCompleted)
            XCTAssertTrue(optimizing.detail.hasPrefix("Optimizing Whisper "))
            XCTAssertTrue(loading.detail.hasPrefix("Loading Whisper "))
            XCTAssertTrue(optimizing.detail.hasSuffix("Step \(index + 1) of 3"))
            XCTAssertFalse(optimizing.detail.contains("%"))
        }
        XCTAssertEqual(components.map(\.computeUnits),
                       [WhisperModelSpec.melComputeUnits, WhisperModelSpec.textDecoderComputeUnits,
                        WhisperModelSpec.audioEncoderComputeUnits])
    }

    func testPreparationAwaitsEachComponentBeforeAnnouncingTheNext() async throws {
        let events = ProgressLog()
        try await WhisperPreparationComponent.prepare(optimizing: true, progressHandler: {
            XCTAssertNil($0.fractionCompleted)
            events.append($0.detail)
        }) { component in
            // The next phase must not have been announced while this component loads.
            XCTAssertEqual(events.values.last, component.progress(optimizing: true).detail)
            await Task.yield()
            events.append("Finished \(component.rawValue)")
        }
        XCTAssertEqual(events.values, [
            "Optimizing Whisper audio features · Step 1 of 3", "Finished MelSpectrogram",
            "Optimizing Whisper text decoder · Step 2 of 3", "Finished TextDecoder",
            "Optimizing Whisper audio encoder · Step 3 of 3", "Finished AudioEncoder"
        ])
    }

    func testPreparationFailureDoesNotAnnounceOrLoadLaterSteps() async {
        enum Failure: Error { case load }
        let progress = ProgressLog()
        var loaded: [WhisperPreparationComponent] = []
        do {
            try await WhisperPreparationComponent.prepare(optimizing: false, progressHandler: {
                progress.append($0.detail)
            }) { component in
                loaded.append(component)
                if component == .textDecoder { throw Failure.load }
            }
            XCTFail("Expected the model failure")
        } catch {
            XCTAssertTrue(error is Failure)
        }
        XCTAssertEqual(loaded, [.melSpectrogram, .textDecoder])
        XCTAssertEqual(progress.values.count, 2)
    }

    func testCancelledPreparationDoesNotStartAnotherComponent() async {
        let progress = ProgressLog()
        let task = Task {
            try await WhisperPreparationComponent.prepare(optimizing: true, progressHandler: {
                progress.append($0.detail)
            }) { _ in
                // The nonescaping loader is awaited in the same task as the sequence.
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(progress.values, ["Optimizing Whisper audio features · Step 1 of 3"])
    }

    func testPreparationTextsDistinguishLoadingFromOptimizing() {
        XCTAssertEqual(WhisperTranscriber.loadingDetail, "Loading Whisper")
        XCTAssertTrue(WhisperTranscriber.optimizingDetail.hasPrefix("Optimizing Whisper for this iPhone"))
    }

    func testLocalTokenizerAndInstallerCheckerRejectMissingFiles() async throws {
        // Both entry points read this local folder; no tokenizer.json is present.
        let empty = root.appendingPathComponent("empty-tokenizer", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        do {
            _ = try await TyprWhisperTokenizer.load(from: empty)
            XCTFail("an empty folder has no tokenizer")
        } catch {}
        do {
            try await WhisperKitTokenizerChecker().check(tokenizerFolder: empty)
            XCTFail("the installer's checker must reject an empty folder")
        } catch {}
        let remaining = try FileManager.default.contentsOfDirectory(atPath: empty.path)
        XCTAssertTrue(remaining.isEmpty, "local validation must not create downloaded tokenizer files")
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var values: [String] { lock.withLock { recorded } }
    func append(_ value: String) { lock.withLock { recorded.append(value) } }
}
