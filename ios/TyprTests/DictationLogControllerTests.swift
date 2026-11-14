import XCTest
@testable import Typr

@MainActor
private final class LogAudio: AudioManaging {
    var isKeepaliveRunning = false
    var onSystemEvent: ((AudioSystemEvent) -> Void)?
    var onUnexpectedCaptureEnd: ((URL, Bool) -> Void)?
    var duration: TimeInterval = 1.5
    func requestPermission() async -> Bool { true }
    func startKeepalive(allowBluetooth: Bool) throws { isKeepaliveRunning = true }
    func stopKeepalive() { isKeepaliveRunning = false }
    func deactivateSession() { isKeepaliveRunning = false }
    func beginCapture(at url: URL, maxDuration: TimeInterval, allowBluetooth: Bool) throws -> any ActiveAudioCapture {
        LogCapture(url: url, duration: duration)
    }
}

@MainActor
private final class LogCapture: ActiveAudioCapture {
    let url: URL
    var isRecording = true
    let currentTime: TimeInterval
    init(url: URL, duration: TimeInterval) {
        self.url = url
        currentTime = duration
        _ = FileManager.default.createFile(atPath: url.path, contents: Data())
    }
    func normalizedPowerLevel() -> Float { 0.5 }
    func averagePowerDB() -> Float { -24 }
    func stop() { isRecording = false }
}

private actor LogControlledTranscriber: LocalTranscribing {
    nonisolated let displayName = "Controlled Speech"
    let languageName = "German"
    var gate: CheckedContinuation<String, Error>?
    var suspendNext = false
    var shouldFail = false
    var output = "Die Katze sitzt auf der Mathe"
    func arm() { suspendNext = true }
    func fail() { shouldFail = true }
    func setOutput(_ text: String) { output = text }
    func resume() { gate?.resume(returning: output); gate = nil }
    func isWaiting() -> Bool { gate != nil }
    func prepare(progressHandler: @escaping @Sendable (ModelPreparationProgress) -> Void) async throws {}
    func transcribe(_ url: URL) async throws -> String {
        if shouldFail { throw ParakeetTranscriber.TranscriberError.notPrepared }
        if suspendNext {
            suspendNext = false
            return try await withCheckedThrowingContinuation { gate = $0 }
        }
        return output
    }
}

private struct LogSecretFailure: Error, LocalizedError {
    let payload = "SECRET-ERROR-PAYLOAD"
    var errorDescription: String? { payload }
}

@MainActor
private final class LogControllerFixture {
    let env = LogTestEnvironment()
    let audio = LogAudio()
    let asr = LogControlledTranscriber()
    let model = CleanupTestSession()
    let background = CleanupTestBackground()
    let sleeper = CleanupTestSleeper()
    let controller: DictationController
    let bridge: KeyboardBridge

    init(injectLog: Bool = true, statistics: UsageDictationRecorder? = nil) {
        bridge = KeyboardBridge(defaults: env.defaults)
        let deps = TranscriptCleanupDependencies(cleaner: CleanupTestCleaner(session: model), language: CleanupTestLanguage(),
            background: background, isEnabled: { true }, sleep: sleeper.sleep)
        let activeASR = asr
        controller = DictationController(audio: audio, keyboardBridge: bridge, transcriber: activeASR,
            transcriberFactory: { activeASR }, autoPrepareOnInit: false,
            customVocabularySettings: CustomVocabularySettings(defaults: env.defaults),
            cleanup: deps, dictationLog: injectLog ? env.store : nil, statistics: statistics)
    }

    func settle() async throws {
        // Same bounded settling pattern as the existing controller tests; model/ASR waits
        // themselves are continuation-driven, not simulated four-second wall-clock waits.
        for _ in 0..<8 { try await Task.sleep(for: .milliseconds(25)) }
    }
    func waitUntil(_ description: String, file: StaticString = #filePath, line: UInt = #line,
                   _ condition: () -> Bool) async throws {
        // These are state/serialization tests, not latency tests. A cold CI simulator can
        // spend several seconds in framework initialization before the injected model runs.
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        // Stop the test on timeout rather than cancelling an unfinished job with the next one.
        _ = try XCTUnwrap(condition() ? true : nil, description, file: file, line: line)
    }
    func waitUntilFinished(file: StaticString = #filePath, line: UInt = #line) async throws {
        // Keyboard completion also waits for cold archive readiness.
        try await waitUntil("Expected the newest dictation to finish", file: file, line: line) {
            env.store.entries.first?.status == .finished
        }
    }
    func waitUntilASRIsSuspended(file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var waiting = await asr.isWaiting()
        while !waiting, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            waiting = await asr.isWaiting()
        }
        _ = try XCTUnwrap(waiting ? true : nil, "Expected suspended ASR", file: file, line: line)
    }
    func start() async throws {
        try await waitUntil("Expected the isolated log archive to finish loading") { !env.store.isLoading }
        controller.prepareModel()
        try await waitUntil("Expected the injected transcriber to be ready") { controller.phase == .ready }
        controller.startRecording(keyboardJobID: "a")
        try await waitUntil("Expected recording to start") { controller.phase == .recording }
    }
    func dispose() async throws {
        controller.cancelCurrentJob()
        await asr.resume()
        model.resume()
        sleeper.fire()
        try await settle()
        await env.dispose()
    }
}

@MainActor
final class DictationLogControllerTests: XCTestCase {
    func testCleanupProducesOneFinishedEntryWithTextsOutcomesAndTimings() async throws {
        let f = LogControllerFixture()
        try await f.start()
        // Recording state precedes the first meter tick; this test also asserts its -24 dB sample.
        try await f.waitUntil("Expected the injected audio meter sample") { f.controller.loudnessDB == -24 }
        f.controller.finishRecording(); try await f.waitUntilFinished()
        let entry = try XCTUnwrap(f.env.store.entries.first)
        XCTAssertEqual(f.env.store.entries.count, 1)
        XCTAssertEqual(entry.status, .finished)
        XCTAssertEqual(entry.recognized?.text, "Die Katze sitzt auf der Mathe")
        XCTAssertNil(entry.aiInput)
        XCTAssertEqual(entry.aiAnswer?.text, "Die Katze sitzt auf der Matte")
        XCTAssertEqual(entry.finalText?.text, "Die Katze sitzt auf der Matte.")
        XCTAssertEqual(f.bridge.snapshot().transcript, entry.finalText?.text)
        XCTAssertEqual(entry.cleanupOutcome, "completed")
        XCTAssertEqual(entry.cleanupChanged, true)
        XCTAssertEqual(entry.context.cleanupPath, .typr)
        XCTAssertEqual(entry.context.speechEngine, "Controlled Speech")
        XCTAssertEqual(entry.context.speechLanguage, "German")
        XCTAssertEqual(entry.context.loudestAverageDBFS, -24)
        XCTAssertEqual(entry.context.recordingDuration, 1.5)
        XCTAssertTrue(entry.context.keyboardJob)
        XCTAssertFalse(entry.context.copyToPasteboard)
        XCTAssertTrue(entry.outputLabel.contains("provided to keyboard"))
        XCTAssertNotNil(entry.asrMilliseconds)
        XCTAssertNotNil(entry.modelMilliseconds)
        XCTAssertNotNil(entry.cleanupMilliseconds)
        XCTAssertNotNil(entry.stopToFinalMilliseconds)
        XCTAssertEqual(entry.promptRevision, "2026-11-09a")
        XCTAssertEqual(entry.guardRevision, "2026-11-09a")
        try await f.dispose()
    }

    func testSettingsAreFrozenAtStartEvenWhenToggledDuringRecording() async throws {
        let f = LogControllerFixture()
        let vocabulary = CustomVocabularySettings(defaults: f.env.defaults)
        vocabulary.isEnabled = true
        vocabulary.terms = ["iPhone"]
        f.env.defaults.set(true, forKey: "experiments.appleIntelligenceCleanup")
        await f.asr.setOutput("iphone works")
        f.model.result = "iPhone works"
        try await f.start()
        vocabulary.isEnabled = false
        vocabulary.terms = []
        f.env.defaults.set(false, forKey: "experiments.appleIntelligenceCleanup")
        f.controller.finishRecording(); try await f.waitUntilFinished()
        let entry = try XCTUnwrap(f.env.store.entries.first)
        XCTAssertEqual(entry.context.vocabularyEnabled, true)
        XCTAssertEqual(entry.context.upstreamCleanupEnabled, false)
        XCTAssertEqual(entry.context.typrCleanupEnabled, true)
        XCTAssertEqual(entry.context.cleanupPath, .typr)
        XCTAssertEqual(entry.firstSpellingPass?.changes.first?.before.text, "iphone")
        XCTAssertEqual(entry.firstSpellingPass?.changes.first?.after.text, "iPhone")
        XCTAssertNil(entry.context.vocabularyTerms)
        XCTAssertNil(entry.context.vocabularySnapshot)
        XCTAssertEqual(entry.cleanupOutput?.text, "iPhone works")
        XCTAssertEqual(entry.formattedText?.text, TranscriptFormatter.format("iPhone works", style: .polished))
        try await f.dispose()
    }

    func testUnrelatedSavedVocabularyIsNotCollected() async throws {
        let f = LogControllerFixture()
        let vocabulary = CustomVocabularySettings(defaults: f.env.defaults)
        vocabulary.isEnabled = false
        vocabulary.terms = ["herdr", "pi Agent", "GitHub"]
        await f.asr.setOutput("Öffne eine herdr pane")
        f.model.result = "Öffne eine herdr pane"
        try await f.start()
        vocabulary.terms = []
        f.controller.finishRecording(); try await f.waitUntilFinished()
        let entry = try XCTUnwrap(f.env.store.entries.first)
        XCTAssertEqual(entry.context.vocabularyEnabled, false)
        XCTAssertEqual(entry.context.vocabularyCount, 0)
        XCTAssertNil(entry.context.vocabularyTerms)
        XCTAssertFalse(entry.plainText.contains(#""pi Agent""#))
        XCTAssertFalse(entry.plainText.contains("GitHub"))
        try await f.dispose()
    }

    func testBuiltInGlossaryReplacementsAreLoggedWithTheirSource() async throws {
        let f = LogControllerFixture()
        await f.asr.setOutput("Erstelle einen Pulrequest auf Gitub")
        f.model.result = "Erstelle einen Pull Request auf GitHub"
        try await f.start()
        f.controller.finishRecording()
        try await f.waitUntilFinished()
        let entry = try XCTUnwrap(f.env.store.entries.first)
        XCTAssertEqual(entry.recognized?.text, "Erstelle einen Pulrequest auf Gitub")
        XCTAssertEqual(entry.aiInput?.text, "Erstelle einen Pull Request auf GitHub")
        XCTAssertEqual(entry.firstSpellingPass?.totalChanges, 2)
        let change = try XCTUnwrap(entry.firstSpellingPass?.changes.first)
        XCTAssertEqual(change.before.text, "Pulrequest")
        XCTAssertEqual(change.after.text, "Pull Request")
        XCTAssertEqual(change.source, "built-in")
        XCTAssertEqual(entry.context.glossaryRevision, TechGlossary.revision)
        XCTAssertEqual(entry.spellingLines(entry.firstSpellingPass).first,
                       #""Pulrequest" → "Pull Request" (built-in: "Pull Request")"#)
        XCTAssertEqual(entry.finalText?.text, "Erstelle einen Pull Request auf GitHub.")
        try await f.dispose()
    }

    func testVeryCasualFormattingRestorationHasSeparateReplacementEvidence() async throws {
        let f = LogControllerFixture()
        let vocabulary = CustomVocabularySettings(defaults: f.env.defaults)
        vocabulary.isEnabled = true
        vocabulary.terms = ["iPhone"]
        f.controller.setStyle(.veryCasual)
        await f.asr.setOutput("my iphone works")
        f.model.result = "my iPhone works"
        try await f.start()
        f.controller.finishRecording(); try await f.waitUntilFinished()
        let entry = try XCTUnwrap(f.env.store.entries.first)
        XCTAssertEqual(entry.firstSpellingPass?.totalChanges, 1)
        XCTAssertEqual(entry.secondSpellingPass?.totalChanges, 1)
        XCTAssertEqual(entry.secondSpellingPass?.changes.first?.before.text, "iphone")
        XCTAssertEqual(entry.secondSpellingPass?.changes.first?.after.text, "iPhone")
        XCTAssertEqual(entry.finalText?.text, "my iPhone works")
        XCTAssertEqual(entry.cleanupOutput?.text, "my iPhone works")
        XCTAssertEqual(entry.formattedText?.text, "my iphone works")
        try await f.dispose()
    }

    func testVerbatimShowsNoAIWhileRetainingEnabledSwitchState() async throws {
        let f = LogControllerFixture()
        f.env.defaults.set(true, forKey: "experiments.appleIntelligenceCleanup")
        let vocabulary = CustomVocabularySettings(defaults: f.env.defaults)
        vocabulary.isEnabled = true // On but empty is not Off.
        f.controller.setStyle(.verbatim)
        try await f.start()
        f.controller.finishRecording(); try await f.waitUntilFinished()
        let entry = try XCTUnwrap(f.env.store.entries.first)
        XCTAssertEqual(entry.context.cleanupPath, .none)
        XCTAssertEqual(entry.context.typrCleanupEnabled, true)
        XCTAssertEqual(entry.context.upstreamCleanupEnabled, false)
        XCTAssertEqual(entry.vocabularyLabel, "Vocabulary: On (0 terms)")
        XCTAssertEqual(entry.firstSpellingPass?.totalChanges, 0)
        XCTAssertEqual(entry.secondSpellingPass?.totalChanges, 0)
        XCTAssertNil(entry.aiAnswer)
        try await f.dispose()
    }

    func testASRFailureIsCategorizedWithoutErrorDescription() async throws {
        let f = LogControllerFixture()
        await f.asr.fail()
        try await f.start()
        f.controller.finishRecording(); try await f.settle()
        XCTAssertEqual(f.env.store.entries.first?.status, .asrFailed)
        XCTAssertEqual(f.env.store.entries.first?.asrFailure, .modelNotReady)
        XCTAssertNil(f.env.store.entries.first?.finalText)
        XCTAssertNil(f.env.store.entries.first?.asrErrorType)
        XCTAssertEqual(DictationLogASRFailure.classify(ParakeetTranscriber.TranscriberError.emptyTranscript), .noSpeech)
        XCTAssertEqual(DictationLogASRFailure.classify(CancellationError()), .cancelled)
        XCTAssertEqual(DictationLogASRFailure.classify(CocoaError(.fileReadUnknown)), .other)
        try await f.dispose()
    }

    func testCancelAndReplacementTerminateBeforeUncooperativeASRReturns() async throws {
        for replace in [false, true] {
            let f = LogControllerFixture()
            await f.asr.arm()
            try await f.start()
            f.controller.finishRecording(); try await f.settle()
            let waiting = await f.asr.isWaiting()
            XCTAssertTrue(waiting)
            let id = try XCTUnwrap(f.env.store.entries.first?.id)
            if replace { f.controller.startRecording(keyboardJobID: "b") }
            else { f.controller.cancelCurrentJob() }
            // No settling or ASR resumption needed to see cancellation.
            XCTAssertEqual(f.env.store.entries.first?.status, .cancelled)
            XCTAssertNil(f.env.store.entries.first?.finalText)
            await f.asr.resume(); try await f.settle()
            let cancelled = try XCTUnwrap(f.env.store.entries.first { $0.id == id })
            XCTAssertEqual(cancelled.status, .cancelled)
            XCTAssertNil(cancelled.recognized)
            XCTAssertNil(cancelled.finalText)
            if replace {
                f.controller.finishRecording(); try await f.settle()
                XCTAssertEqual(f.env.store.entries.count, 2)
                XCTAssertEqual(f.env.store.entries.first?.status, .finished)
            }
            try await f.dispose()
        }
    }

    func testWarmSessionEndDuringAcceptedCleanupStillFinishes() async throws {
        let f = LogControllerFixture()
        f.model.suspend = true
        try await f.waitUntil("Expected the isolated log archive to finish loading") { !f.env.store.isLoading }
        f.controller.prepareModel()
        try await f.waitUntil("Expected the injected transcriber to be ready") { f.controller.phase == .ready }
        f.controller.selectWarmDuration(.fifteenMinutes)
        try await f.waitUntil("Expected the warm session to start") { f.controller.keyboardSessionEnabled }
        f.controller.startRecording(keyboardJobID: "warm")
        try await f.waitUntil("Expected recording to start") { f.controller.phase == .recording }
        f.controller.finishRecording()
        try await f.waitUntil("Expected accepted cleanup to suspend") { f.model.gate != nil }
        let accepted = try XCTUnwrap(f.env.store.entries.first)
        XCTAssertEqual(accepted.status, .transcribing)
        f.controller.endWarmSession()
        XCTAssertFalse(f.controller.keyboardSessionEnabled)
        XCTAssertNotNil(f.model.gate, "Ending the warm session must preserve accepted cleanup")
        XCTAssertEqual(f.env.store.entries.first?.status, .transcribing)
        f.model.resume()
        try await f.waitUntilFinished()
        XCTAssertEqual(f.env.store.entries.first?.id, accepted.id)
        XCTAssertEqual(f.env.store.entries.first?.aiAnswer?.text, f.model.result)
        XCTAssertEqual(f.env.store.entries.first?.answerUse, "accepted")
        XCTAssertEqual(f.env.store.entries.first?.finalText?.text, f.controller.transcript)
        try await f.dispose()
    }

    func testFinishedDeadlineAndExpiryEntriesGainOnlyTheirOwnLateAnswer() async throws {
        for expire in [false, true] {
            let f = LogControllerFixture()
            f.model.suspend = true
            try await f.start()
            f.controller.finishRecording()
            try await f.waitUntil("Expected suspended cleanup and its deadline/expiry hooks") {
                f.model.gate != nil && !f.sleeper.gates.isEmpty && f.background.expiration != nil
            }
            if expire { f.background.expiration?() } else { f.sleeper.fire() }
            // Fallback delivery can await cold archive readiness for longer than settle's 200 ms.
            // Do not start B until A has actually finished, or B cancels A instead.
            try await f.waitUntilFinished()
            let first = try XCTUnwrap(f.env.store.entries.first)
            XCTAssertEqual(first.status, .finished)
            XCTAssertEqual(first.finalText?.text, "Die Katze sitzt auf der Mathe.")
            XCTAssertEqual(first.cleanupOutcome, expire ? "failed(expired)" : "failed(deadline)")
            // A second dictation skips busy while A still owns the model reservation.
            f.controller.startRecording(keyboardJobID: "b"); try await f.settle()
            f.controller.finishRecording()
            try await f.waitUntilFinished()
            let b = try XCTUnwrap(f.env.store.entries.first)
            XCTAssertNotEqual(b.id, first.id)
            XCTAssertEqual(b.cleanupOutcome, "skipped(busy)")
            let delivered = f.bridge.snapshot().resultID
            f.model.resume()
            try await f.waitUntil("Expected A's late model answer to be recorded") {
                f.env.store.entries.first { $0.id == first.id }?.aiAnswer != nil
            }
            let late = try XCTUnwrap(f.env.store.entries.first { $0.id == first.id })
            XCTAssertEqual(late.status, .finished)
            XCTAssertEqual(late.finalText, first.finalText)
            XCTAssertEqual(late.cleanupOutcome, first.cleanupOutcome)
            XCTAssertEqual(late.aiAnswer?.text, f.model.result)
            XCTAssertEqual(late.answerUse, "late")
            XCTAssertNotNil(late.modelMilliseconds)
            XCTAssertEqual(f.env.store.entries.first, b)
            XCTAssertEqual(f.bridge.snapshot().resultID, delivered)
            try await f.dispose()
        }
    }

    func testClearOffAndOffOnDuringASROrRecordingNeverRevivePermission() async throws {
        for duringASR in [false, true] {
            for mode in 0..<3 {
                let f = LogControllerFixture()
                if duringASR { await f.asr.arm() }
                try await f.start()
                if duringASR {
                    f.controller.finishRecording()
                    try await f.waitUntilASRIsSuspended()
                }
                if mode == 0 { f.env.store.clear() }
                else {
                    f.env.store.setEnabled(false)
                    if mode == 2 { f.env.store.setEnabled(true) }
                }
                if duringASR { await f.asr.resume() } else { f.controller.finishRecording() }
                // Clearing/disabling the log removes the entry, not the asynchronous delivery.
                try await f.waitUntil("Expected transcript delivery despite revoked log permission") {
                    !f.controller.transcript.isEmpty
                }
                XCTAssertFalse(f.controller.transcript.isEmpty)
                await f.env.storage.flush()
                try await f.settle()
                if duringASR && mode != 0 {
                    XCTAssertEqual(f.env.store.entries.first?.status, .interrupted)
                    XCTAssertNil(f.env.store.entries.first?.finalText)
                } else { XCTAssertTrue(f.env.store.entries.isEmpty) }
                XCTAssertEqual(f.env.persistedEntryCount, duringASR && mode != 0 ? 1 : 0)
                try await f.dispose()
            }
        }
    }

    func testNoInjectedLogAndShortOrCancelledCaptureProduceNoEntries() async throws {
        let noLog = LogControllerFixture(injectLog: false)
        try await noLog.start()
        noLog.controller.finishRecording(); try await noLog.settle()
        XCTAssertFalse(noLog.controller.transcript.isEmpty)
        XCTAssertTrue(noLog.env.store.entries.isEmpty)
        await noLog.env.storage.flush()
        XCTAssertEqual(noLog.env.persistedEntryCount, 0)
        try await noLog.dispose()
        for short in [false, true] {
            let f = LogControllerFixture()
            if short { f.audio.duration = 0.1 }
            try await f.start()
            if short { f.controller.finishRecording() } else { f.controller.cancelCurrentJob() }
            try await f.settle()
            XCTAssertTrue(f.env.store.entries.isEmpty)
            try await f.dispose()
        }
    }

    func testUnwritableStorageDoesNotAffectDelivery() async throws {
        let f = LogControllerFixture()
        // Let startup finish before changing its storage. Removing the whole fixture
        // directory races the archive's asynchronous initialization on the simulator.
        try await LogTestEnvironment.waitUntilLoaded(f.env.store)
        let entries = f.env.storage.root.appendingPathComponent("entries", isDirectory: false)
        // A regular file where entries must be written fails even as an admin.
        try FileManager.default.removeItem(at: entries)
        try Data("not a directory".utf8).write(to: entries)
        try await f.start()
        f.controller.finishRecording(); try await f.settle()
        await f.env.storage.flush(); try await f.settle()
        XCTAssertEqual(f.controller.phase, .ready)
        XCTAssertEqual(f.controller.transcript, "Die Katze sitzt auf der Matte.")
        XCTAssertEqual(f.env.store.entries.first?.status, .finished)
        XCTAssertNotNil(f.env.store.storageProblem)
        try await f.dispose()
    }

    func testUsageCountsSuccessfulKeyboardDictationWithoutHistoryOrRepeatedStop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UsageStatisticsStore(directory: root)
        let f = LogControllerFixture(injectLog: false, statistics: UsageDictationRecorder(store: store))
        try await f.start()
        f.controller.finishRecording(); f.controller.finishRecording()
        try await f.waitUntil("Expected successful result without an archive") { f.controller.phase == .ready }
        let totals = try store.snapshot().totals(lastDays: 90, at: Date())
        XCTAssertEqual(totals.dictations, 1)
        XCTAssertEqual(totals.dictatedWords, 6) // Raw recognition, not cleanup's spelling/style output.
        XCTAssertEqual(totals.recordingSeconds, 1.5)
        XCTAssertTrue(f.env.store.entries.isEmpty)
        try await f.dispose()
    }

    func testUsageResetDuringRecordingOrSuspendedASRDoesNotReviveOldCapture() async throws {
        for duringASR in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let store = UsageStatisticsStore(directory: root)
            let f = LogControllerFixture(statistics: UsageDictationRecorder(store: store))
            try await f.start()
            if duringASR {
                await f.asr.arm(); f.controller.finishRecording()
                try await f.waitUntilASRIsSuspended()
            }
            _ = try store.reset()
            if duringASR { await f.asr.resume() } else { f.controller.finishRecording() }
            try await f.waitUntilFinished()
            XCTAssertTrue(try store.snapshot().days.isEmpty)
            try await f.dispose()
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testUsageDoesNotCountFailedOrCancelledDictation() async throws {
        for cancelled in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let store = UsageStatisticsStore(directory: root)
            let f = LogControllerFixture(statistics: UsageDictationRecorder(store: store))
            try await f.start()
            if cancelled { f.controller.cancelCurrentJob() }
            else {
                await f.asr.fail(); f.controller.finishRecording()
                try await f.waitUntil("Expected failed ASR") { if case .failed = f.controller.phase { true } else { false } }
            }
            XCTAssertTrue(try store.snapshot().days.isEmpty)
            try await f.dispose()
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testExplicitExportsIncludeEvidenceButNoInternalKeysOrErrorPayload() async throws {
        let env = LogTestEnvironment()
        let recording = env.begin()
        recording.recognized("spoken secret", spelled: "spoken Secret", asrMilliseconds: 12)
        recording.modelAnswer("unused answer", use: .rejected(.emptyOutput), modelMilliseconds: 20)
        recording.finish(text: "Spoken Secret.", beforeSpelling: "Spoken Secret.")
        let entry = try XCTUnwrap(env.store.entries.first)
        let export = entry.plainText
        for evidence in ["spoken secret", "spoken Secret", "unused answer", "Spoken Secret.",
                         "rejected(empty-output); not used", "12 ms", "20 ms", "does not prove insertion"] {
            XCTAssertTrue(export.contains(evidence), evidence)
        }
        XCTAssertFalse(export.contains("vocabularyTerms"))
        XCTAssertFalse(export.contains("errorDescription"))
        let failedRecording = env.begin()
        failedRecording.failASR(LogSecretFailure(), milliseconds: 4)
        let failed = try XCTUnwrap(env.store.entries.first)
        XCTAssertEqual(failed.asrFailure, .other)
        XCTAssertTrue(failed.asrErrorType?.hasSuffix("LogSecretFailure") == true)
        XCTAssertFalse(failed.plainText.contains("SECRET-ERROR-PAYLOAD"))
        await env.dispose()
    }

}
