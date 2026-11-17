import Foundation
import XCTest
@testable import Typr

// Engine choice end to end through DictationController with fakes: the persisted preference, no
// silent fallback, Whisper never downloaded outside its Download button, the busy lock, per-capture
// engine/language snapshots, stale preparation results and the unchanged keyboard/vocabulary path.
// Real Apple Speech availability, real Whisper decoding and device behavior are not covered here.

// MARK: - Fakes

@MainActor
private final class EngineCapture: ActiveAudioCapture {
    let url: URL
    var isRecording = true
    var currentTime: TimeInterval

    init(url: URL, duration: TimeInterval) {
        self.url = url
        currentTime = duration
        FileManager.default.createFile(atPath: url.path, contents: Data("wav".utf8))
    }

    func normalizedPowerLevel() -> Float { 0.6 }
    func stop() { isRecording = false }
}

@MainActor
private final class EngineAudio: AudioManaging {
    var isKeepaliveRunning = false
    var onSystemEvent: ((AudioSystemEvent) -> Void)?
    var onUnexpectedCaptureEnd: ((URL, Bool) -> Void)?
    var holdPermission = false
    private var permissionWaiters: [CheckedContinuation<Bool, Never>] = []
    private(set) var captures: [EngineCapture] = []
    /// Permission requests suspended in the fake's continuation.
    var heldPermissionRequests: Int { permissionWaiters.count }

    func requestPermission() async -> Bool {
        guard holdPermission else { return true }
        return await withCheckedContinuation { permissionWaiters.append($0) }
    }

    func releasePermission() {
        holdPermission = false
        let waiters = permissionWaiters
        permissionWaiters = []
        waiters.forEach { $0.resume(returning: true) }
    }

    func startKeepalive(allowBluetooth: Bool) throws { isKeepaliveRunning = true }
    func stopKeepalive() { isKeepaliveRunning = false }
    func deactivateSession() { isKeepaliveRunning = false }

    func beginCapture(at url: URL, maxDuration: TimeInterval, allowBluetooth: Bool) throws -> any ActiveAudioCapture {
        try ensureKeepalive(allowBluetooth: allowBluetooth)
        let capture = EngineCapture(url: url, duration: 1.4)
        captures.append(capture)
        return capture
    }
}

/// Holds a synchronous actor-property read so the controller's `await languageName` really
/// suspends. Bounded to avoid wedging the test process if a regression exits a test early.
private final class EngineLanguageGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var released = false

    var hasStarted: Bool {
        condition.lock()
        defer { condition.unlock() }
        return started
    }

    func read(_ value: String) -> String {
        condition.lock()
        defer { condition.unlock() }
        started = true
        let deadline = Date().addingTimeInterval(5)
        while !released {
            if !condition.wait(until: deadline) { break }
        }
        return value
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

/// A speech engine stand-in, named like the real one so the controller maps it to its choice.
/// Holds use a detached sleep: like a real model, they do not stop early on cancellation.
private actor EngineASR: LocalTranscribing {
    nonisolated let engine: SpeechEngineChoice
    nonisolated let displayName: String
    nonisolated let languageGate: EngineLanguageGate?
    private let preparedLanguageName: String
    var languageName: String { languageGate?.read(preparedLanguageName) ?? preparedLanguageName }

    private(set) var prepareCount = 0
    private(set) var languages: [DictationLanguage] = []
    private(set) var vocabularies: [[String]] = []
    private var output: String
    private var failure: (any Error)?
    private var prepareFailure: (any Error)?
    private var holdsPrepare = false
    private var holdsTranscribe = false
    private var heldCalls: Set<Int> = []

    init(_ engine: SpeechEngineChoice, output: String = "ship the build", languageName: String = "English",
         languageGate: EngineLanguageGate? = nil) {
        self.engine = engine
        displayName = engine.displayName
        self.output = output
        self.preparedLanguageName = languageName
        self.languageGate = languageGate
    }

    func setOutput(_ text: String) { output = text }
    func setFailure(_ error: (any Error)?) { failure = error }
    func setPrepareFailure(_ error: (any Error)?) { prepareFailure = error }
    func holdPrepare() { holdsPrepare = true }
    func releasePrepare() { holdsPrepare = false }
    func holdTranscribe() { holdsTranscribe = true }
    func releaseTranscribe() { holdsTranscribe = false; heldCalls = [] }
    func holdCall(_ number: Int) { heldCalls.insert(number) }
    func releaseCall(_ number: Int) { heldCalls.remove(number) }

    private static func pause() async {
        await Task.detached { try? await Task.sleep(for: .milliseconds(10)) }.value
    }

    func prepare(progressHandler: @escaping @Sendable (ModelPreparationProgress) -> Void) async throws {
        prepareCount += 1
        while holdsPrepare { await Self.pause() }
        if let prepareFailure { throw prepareFailure }
        progressHandler(ModelPreparationProgress(fractionCompleted: 1, detail: "Ready"))
    }

    func transcribe(_ audioURL: URL) async throws -> String {
        try await transcribe(audioURL, vocabulary: [], language: .automatic)
    }

    func transcribe(_ audioURL: URL, vocabulary: [String]) async throws -> String {
        try await transcribe(audioURL, vocabulary: vocabulary, language: .automatic)
    }

    func transcribe(_ audioURL: URL, vocabulary: [String], language: DictationLanguage) async throws -> String {
        languages.append(language)
        vocabularies.append(vocabulary)
        let call = languages.count
        let capturedOutput = output
        let capturedFailure = failure
        while holdsTranscribe || heldCalls.contains(call) { await Self.pause() }
        if let capturedFailure { throw capturedFailure }
        return capturedOutput
    }
}

@MainActor
private final class FakeEngineProvider: SpeechEngineProviding {
    var installed: Set<SpeechEngineChoice> = [.parakeetV2, .whisperLargeV3Turbo]
    var installedCheck: ((SpeechEngineChoice) -> Bool)?
    var errors: [SpeechEngineChoice: SpeechEngineError] = [:]
    var automaticEngine = SpeechEngineChoice.appleSpeech
    var availabilities: [SpeechEngineChoice: SpeechEngineAvailability] = [:]
    /// Instances handed out next, per engine; otherwise a fresh default one.
    var queued: [SpeechEngineChoice: [EngineASR]] = [:]

    private(set) var events: [String] = []
    private(set) var automaticCalls: [DictationLanguage] = []
    private(set) var explicitCalls: [SpeechEngineChoice] = []
    private(set) var explicitLanguages: [DictationLanguage] = []
    private(set) var created: [EngineASR] = []

    func instances(of engine: SpeechEngineChoice) -> [EngineASR] { created.filter { $0.engine == engine } }

    private func make(_ engine: SpeechEngineChoice) -> EngineASR {
        let asr: EngineASR
        if var pending = queued[engine], !pending.isEmpty {
            asr = pending.removeFirst()
            queued[engine] = pending
        } else {
            asr = EngineASR(engine)
        }
        created.append(asr)
        return asr
    }

    func automaticTranscriber(language: DictationLanguage) async -> any LocalTranscribing {
        automaticCalls.append(language)
        events.append("automatic")
        return make(automaticEngine)
    }

    func transcriber(for engine: SpeechEngineChoice, language: DictationLanguage) async throws -> any LocalTranscribing {
        explicitCalls.append(engine)
        explicitLanguages.append(language)
        events.append("create:\(engine.rawValue)")
        if let error = errors[engine] { throw error }
        return make(engine)
    }

    func isInstalled(_ engine: SpeechEngineChoice) -> Bool {
        installedCheck?(engine) ?? installed.contains(engine)
    }

    func availability(of engine: SpeechEngineChoice, language: DictationLanguage) async -> SpeechEngineAvailability {
        availabilities[engine] ?? .installed
    }

    private(set) var deleted: [SpeechEngineChoice] = []
    var deleteFailure: (any Error)?

    func deleteModel(_ engine: SpeechEngineChoice) throws {
        if let deleteFailure { throw deleteFailure }
        deleted.append(engine)
        installed.remove(engine)
    }

    func note(_ event: String) { events.append(event) }
}

/// Records Whisper downloader calls; any call outside an explicit install fails the test.
private final class CountingDownloader: ModelFileDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var holding = false
    private var failure: (any Error)?
    var calls: [String] { lock.withLock { recorded } }
    func hold() { lock.withLock { holding = true } }
    func release() { lock.withLock { holding = false } }
    func fail(with error: (any Error)?) { lock.withLock { failure = error } }

    func download(_ file: PinnedModelFile, into root: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws {
        let failure: (any Error)? = lock.withLock {
            recorded.append(file.path)
            return self.failure
        }
        if let failure { throw failure }
        while lock.withLock({ holding }) { try await Task.sleep(for: .milliseconds(10)) }
        try WhisperTestFiles.writeSparse(WhisperModelStore(root: root).fileURL(for: file), bytes: file.bytes)
        progress(1)
    }
}

private struct PassingTokenizerChecker: WhisperTokenizerChecking {
    func check(tokenizerFolder: URL) async throws {}
}

@MainActor
private final class EngineClock {
    var now: TimeInterval = 50_000
}

private enum EngineTestFailure: Error {
    case timedOut
}

@MainActor
private final class EngineFixture {
    let suite = "typr.engine.tests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let settings: TyprSettings
    let bridge: KeyboardBridge
    let audio = EngineAudio()
    let provider: any SpeechEngineProviding
    let controller: DictationController
    private let clock = EngineClock()
    var now: TimeInterval {
        get { clock.now }
        set { clock.now = newValue }
    }

    var fake: FakeEngineProvider { provider as! FakeEngineProvider }

    init(preferred: SpeechEngineChoice? = nil,
         language: DictationLanguage = .automatic,
         autoPrepare: Bool = false,
         provider: (any SpeechEngineProviding)? = nil,
         transcriberFactory: (() async -> any LocalTranscribing)? = nil,
         vocabularyTerms: [String] = [],
         cleanup: ((UserDefaults) -> TranscriptCleanupDependencies)? = nil,
         dictationLog: DictationLogStore? = nil,
         defaults existing: UserDefaults? = nil,
         modelBackground: (any ModelPreparationScheduling)? = nil,
         deferPreparationUntilActive: Bool = false) {
        defaults = existing ?? UserDefaults(suiteName: suite)!
        settings = TyprSettings(defaults: defaults)
        if existing == nil {
            settings.preferredSpeechEngine = preferred
            settings.dictationLanguage = language
        }
        let vocabulary = CustomVocabularySettings(defaults: defaults)
        if !vocabularyTerms.isEmpty {
            vocabulary.isEnabled = true
            vocabulary.terms = vocabularyTerms
        }
        bridge = KeyboardBridge(defaults: defaults)
        self.provider = provider ?? FakeEngineProvider()
        let clock = self.clock
        controller = DictationController(
            audio: audio,
            keyboardBridge: bridge,
            transcriberFactory: transcriberFactory,
            now: { clock.now },
            autoPrepareOnInit: autoPrepare,
            customVocabularySettings: vocabulary,
            cleanup: cleanup?(defaults),
            dictationLog: dictationLog,
            languageSettings: settings,
            engineProvider: self.provider,
            modelBackground: modelBackground,
            deferPreparationUntilActive: deferPreparationUntilActive
        )
    }

    var storedPreferenceRaw: String? { defaults.string(forKey: "typr.preferredSpeechEngine") }

    func waitUntil(timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line,
                   _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("condition not met in time", file: file, line: line)
                throw EngineTestFailure.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func ready() async throws {
        controller.prepareModel()
        try await waitUntil { self.controller.phase == .ready && self.controller.canChangeEngine }
    }

    func waitForCalls(_ asr: EngineASR, count: Int) async throws {
        let deadline = Date().addingTimeInterval(3)
        while await asr.languages.count < count {
            guard Date() < deadline else {
                XCTFail("transcription did not start")
                throw EngineTestFailure.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @discardableResult
    func dictate(jobID: String? = nil) async throws -> String {
        controller.startRecording(keyboardJobID: jobID)
        try await waitUntil { self.controller.phase == .recording }
        controller.finishRecording()
        try await waitUntil { self.controller.phase != .transcribing && self.controller.canChangeEngine }
        return controller.transcript
    }

    func dispose() async {
        controller.cancelCurrentJob()
        controller.endWarmSession()
        audio.releasePermission()
        if let fake = provider as? FakeEngineProvider {
            // Unblock cancellation-ignoring fake work even when a test exits at a failed wait.
            for asr in fake.created + fake.queued.values.flatMap({ $0 }) {
                asr.languageGate?.release()
                await asr.releasePrepare()
                await asr.releaseTranscribe()
            }
        }
        // Drain before the defaults are removed: permission, transcription (including a cancelled
        // one's unwind) and preparation work have finished. A timeout fails the test.
        try? await waitForState("engine fixture idle before teardown") { self.controller.isIdleForTest }
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor
final class SpeechEngineSelectionTests: XCTestCase {
    private var fixtures: [EngineFixture] = []
    private var roots: [URL] = []
    private var logEnvironments: [LogTestEnvironment] = []

    override func tearDown() async throws {
        for fixture in fixtures { await fixture.dispose() }
        fixtures = []
        for environment in logEnvironments { await environment.dispose() }
        logEnvironments = []
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots = []
    }

    private func fixture(preferred: SpeechEngineChoice? = nil,
                         language: DictationLanguage = .automatic,
                         autoPrepare: Bool = false,
                         provider: (any SpeechEngineProviding)? = nil,
                         transcriberFactory: (() async -> any LocalTranscribing)? = nil,
                         vocabularyTerms: [String] = [],
                         cleanup: ((UserDefaults) -> TranscriptCleanupDependencies)? = nil,
                         dictationLog: DictationLogStore? = nil,
                         defaults: UserDefaults? = nil,
                         modelBackground: (any ModelPreparationScheduling)? = nil,
                         deferPreparationUntilActive: Bool = false) -> EngineFixture {
        let made = EngineFixture(preferred: preferred, language: language, autoPrepare: autoPrepare, provider: provider,
                                 transcriberFactory: transcriberFactory, vocabularyTerms: vocabularyTerms,
                                 cleanup: cleanup, dictationLog: dictationLog, defaults: defaults,
                                 modelBackground: modelBackground,
                                 deferPreparationUntilActive: deferPreparationUntilActive)
        fixtures.append(made)
        return made
    }

    private func whisperRoot() -> WhisperModelStore {
        let root = WhisperTestFiles.makeRoot()
        roots.append(root)
        return WhisperModelStore(root: root)
    }

    // MARK: - Pure settings row state (no view, preparation or download)

    private func row(_ engine: SpeechEngineChoice = .whisperLargeV3Turbo,
                     preferred: SpeechEngineChoice? = nil, current: SpeechEngineChoice? = nil,
                     availability: SpeechEngineAvailability? = .installed,
                     install: ModelInstallState = .installed, language: DictationLanguage = .english,
                     preparation: ModelPreparationProgress? = nil, failure: String? = nil,
                     canChange: Bool = true) -> SpeechEngineRowState {
        SpeechEngineRowState.make(engine: engine, preferred: preferred, current: current,
                                  availability: availability, install: install, language: language,
                                  preparation: preparation, failure: failure, canChangeEngine: canChange)
    }

    func testRowsDistinguishAutomaticCurrentAndChosenEngines() {
        let automatic = row(.appleSpeech, current: .appleSpeech)
        XCTAssertEqual(automatic.badge, "In use · automatic")
        XCTAssertEqual(automatic.status, "Ready on this iPhone")
        XCTAssertEqual(automatic.action, .use, "the automatic engine can be pinned explicitly")
        XCTAssertEqual(automatic.actionTitle, "Use")

        let current = row(preferred: .whisperLargeV3Turbo, current: .whisperLargeV3Turbo)
        XCTAssertEqual(current.badge, "In use")
        XCTAssertEqual(current.action, .none)

        let chosen = row(preferred: .whisperLargeV3Turbo)
        XCTAssertEqual(chosen.badge, "Chosen")
        XCTAssertEqual(chosen.action, .prepare)
        XCTAssertEqual(chosen.actionTitle, "Prepare")
        XCTAssertEqual(row().action, .use)
        XCTAssertEqual(row().actionTitle, "Use")
    }

    func testWhisperRowOffersOnlyDownloadUntilInstalledAndExplainsVocabulary() {
        let missing = row(availability: .downloadRequired("Not downloaded"), install: .notInstalled)
        XCTAssertEqual(missing.action, .download)
        XCTAssertEqual(missing.actionTitle, "Download (\(WhisperModelSpec.downloadSizeLabel))")
        XCTAssertNil(missing.progress)
        XCTAssertNotNil(missing.note)
        XCTAssertTrue(missing.note?.contains("not as Whisper hints") == true)
        XCTAssertTrue(missing.note?.contains("Opening Typr prepares the installed, chosen model") == true)
        XCTAssertTrue(missing.note?.contains("First optimization") == true)
        XCTAssertTrue(missing.note?.contains("several minutes") == true, "disclose optimization before choosing Use")
        XCTAssertTrue(missing.note?.contains("can pause or stop it; reopen Typr to retry") == true)
        XCTAssertNil(row(.appleSpeech).note)

        let ready = row(install: .installed)
        XCTAssertEqual(ready.action, .use, "Use is separate from Download")
        XCTAssertNil(ready.badge)
    }

    func testWhisperRowSeparatesDownloadVerificationAndDevicePreparation() {
        let downloading = row(install: .downloading(ModelDownloadProgress(completedBytes: 50, totalBytes: 100)))
        XCTAssertEqual(downloading.progress, 0.5)
        XCTAssertFalse(downloading.isIndeterminate)
        XCTAssertTrue(downloading.status.hasPrefix("Downloading "))
        XCTAssertTrue(downloading.status.contains("50%"))
        XCTAssertEqual(downloading.action, .cancelDownload)
        XCTAssertEqual(downloading.actionTitle, "Cancel")

        let checking = row(install: .verifying)
        XCTAssertEqual(checking.status, "Checking the downloaded files")
        XCTAssertNil(checking.progress)
        XCTAssertFalse(checking.isIndeterminate)
        XCTAssertEqual(checking.action, .none)

        let preparing = row(preferred: .whisperLargeV3Turbo,
                            preparation: ModelPreparationProgress(fractionCompleted: nil,
                                detail: "Optimizing Whisper text decoder · Step 2 of 3"))
        XCTAssertEqual(preparing.status, "Optimizing Whisper text decoder · Step 2 of 3")
        XCTAssertNil(preparing.progress)
        XCTAssertTrue(preparing.isIndeterminate)
        XCTAssertEqual(preparing.action, .none)
        XCTAssertEqual(preparing.badge, "Chosen")
    }

    func testWhisperRowOffersRetryAfterFailureOrCancelAndNeverPromisesResume() {
        for state in [ModelInstallState.cancelled, .failed("No internet connection. Connect and tap Retry.")] {
            let retry = row(install: state)
            XCTAssertEqual(retry.action, .retryDownload)
            XCTAssertEqual(retry.actionTitle, "Retry")
            XCTAssertNil(retry.progress)
            XCTAssertFalse(retry.status.localizedCaseInsensitiveContains("resume"))
        }
        XCTAssertTrue(row(install: .cancelled).status.contains("files already downloaded are kept"))
        let prepareFailed = row(preferred: .whisperLargeV3Turbo, failure: "Local model failed")
        XCTAssertEqual(prepareFailed.action, .prepare)
        XCTAssertEqual(prepareFailed.actionTitle, "Try again")
        XCTAssertEqual(prepareFailed.status, "Local model failed")
        XCTAssertFalse(prepareFailed.isIndeterminate)

        let missing = row(preferred: .whisperLargeV3Turbo, install: .notInstalled, failure: "Not downloaded")
        XCTAssertEqual(missing.action, .retryDownload, "a failed local preparation requires an explicit repair download")
    }

    func testBusyRowsDisableSwitchAndPrepareButAllowDownloadAndCancel() {
        XCTAssertFalse(row(canChange: false).actionEnabled)
        XCTAssertFalse(row(preferred: .whisperLargeV3Turbo, canChange: false).actionEnabled)
        XCTAssertFalse(row(.parakeetV2, availability: .downloadRequired("Not downloaded"), canChange: false).actionEnabled)

        let download = row(install: .notInstalled, canChange: false)
        XCTAssertEqual(download.action, .download)
        XCTAssertTrue(download.actionEnabled, "the current engine stays usable while Whisper downloads")
        XCTAssertTrue(row(install: .failed("offline"), canChange: false).actionEnabled)
        XCTAssertTrue(row(install: .downloading(ModelDownloadProgress(completedBytes: 1, totalBytes: 2)),
                          canChange: false).actionEnabled)
    }

    func testAppleRowsShowOSDeviceLanguageAndAssetAvailabilityWithoutStartingWork() async throws {
        let f = fixture(preferred: .parakeetV2)
        let statuses: [SpeechEngineAvailability] = [
            .requiresNewerOS("Requires iOS 26"), .unsupportedDevice("Unsupported device"),
            .languageUnsupported("German unsupported"), .downloadRequired("iOS downloads the speech model"), .installed
        ]
        for status in statuses {
            f.fake.availabilities[.appleSpeech] = status
            let result = await f.controller.engineAvailability(.appleSpeech)
            XCTAssertEqual(result, status)
            let shown = row(.appleSpeech, availability: result)
            XCTAssertEqual(shown.action, status.isSupported ? .use : .none)
            if !status.isSupported { XCTAssertEqual(shown.status, status.detail) }
            XCTAssertNil(shown.progress)
        }
        XCTAssertTrue(f.fake.explicitCalls.isEmpty)
        XCTAssertTrue(f.fake.automaticCalls.isEmpty)
        XCTAssertEqual(f.controller.phase, .modelRequired)
        XCTAssertEqual(f.storedPreferenceRaw, "parakeet-v2")
        XCTAssertEqual(row(.appleSpeech, availability: nil).status, "Checking this iPhone…")
    }

    func testParakeetRowWarnsButDoesNotBlockGermanOrAutomaticLanguage() {
        // Shared by the overview and engine picker: cover every language, including
        // Automatic, and the absence of an engine as well as both non-Parakeet engines.
        for language in DictationLanguage.allCases {
            XCTAssertEqual(SpeechEngineRowState.languageWarning(engine: .parakeetV2, language: language) != nil,
                           language != .english)
            let otherEngines: [SpeechEngineChoice?] = [nil, .appleSpeech, .whisperLargeV3Turbo]
            for engine in otherEngines {
                XCTAssertNil(SpeechEngineRowState.languageWarning(engine: engine, language: language))
            }
        }
        for language in [DictationLanguage.german, .automatic] {
            let shown = row(.parakeetV2, language: language)
            XCTAssertEqual(shown.action, .use)
            XCTAssertTrue(shown.actionEnabled)
            XCTAssertTrue(shown.engine.languageSummary.contains("English only"))
            XCTAssertTrue(shown.warning?.contains("Not suitable for German dictation") == true)
            XCTAssertTrue(shown.warning?.contains("Typr keeps your chosen engine") == true)
        }
        XCTAssertNil(row(.parakeetV2, language: .english).warning)
        XCTAssertNil(row(language: .german).warning)
        let downloadAndUse = row(.parakeetV2, availability: .downloadRequired("Not downloaded"))
        XCTAssertEqual(downloadAndUse.action, .use)
        XCTAssertEqual(downloadAndUse.actionTitle, "Download and use")
    }

    // MARK: - Choice values

    func testStoredRawValuesNamesAndGermanSupportAreStable() throws {
        XCTAssertEqual(SpeechEngineChoice.allCases.map(\.rawValue),
                       ["apple-speech", "parakeet-v2", "whisper-large-v3-turbo", "parakeet-v3", "orukeet",
                        "cohere-transcribe"])
        XCTAssertEqual(SpeechEngineChoice.allCases.map(\.displayName),
                       ["Apple Speech", "Parakeet V2", "Whisper Large V3 Turbo", "Parakeet V3", "Orukeet",
                        "Cohere Transcribe"])
        for choice in SpeechEngineChoice.allCases {
            XCTAssertEqual(SpeechEngineChoice(displayName: choice.displayName), choice)
            XCTAssertEqual(try JSONDecoder().decode(SpeechEngineChoice.self, from: JSONEncoder().encode(choice)), choice)
            XCTAssertFalse(choice.summary.isEmpty)
            XCTAssertFalse(choice.languageSummary.isEmpty)
        }
        XCTAssertNil(SpeechEngineChoice(displayName: "Controlled Speech"))
        XCTAssertNil(SpeechEngineChoice(displayName: "Local speech"))
        XCTAssertTrue(SpeechEngineChoice.appleSpeech.recognizesGerman)
        XCTAssertTrue(SpeechEngineChoice.whisperLargeV3Turbo.recognizesGerman)
        XCTAssertFalse(SpeechEngineChoice.parakeetV2.recognizesGerman)
        XCTAssertTrue(SpeechEngineChoice.whisperLargeV3Turbo.summary.contains("only when you tap Download"))
        XCTAssertTrue(SpeechEngineChoice.parakeetV3.recognizesGerman)
        XCTAssertTrue(SpeechEngineChoice.parakeetV3.summary.contains("only when you tap Download"))
        XCTAssertTrue(SpeechEngineChoice.parakeetV3.languageSummary.contains("German and English"))
        XCTAssertTrue(SpeechEngineChoice.orukeet.recognizesGerman)
        XCTAssertTrue(SpeechEngineChoice.orukeet.summary.contains("only when you tap Download"))
        XCTAssertTrue(SpeechEngineChoice.orukeet.languageSummary.contains("25 European languages"))
        XCTAssertTrue(SpeechEngineChoice.cohereTranscribe.recognizesGerman)
        XCTAssertTrue(SpeechEngineChoice.cohereTranscribe.summary.contains("only when you tap Download"))
        XCTAssertTrue(SpeechEngineChoice.cohereTranscribe.languageSummary.contains("German and English"))
        XCTAssertTrue(SpeechEngineChoice.cohereTranscribe.languageSummary.contains("no detection"))
        XCTAssertEqual(SpeechEngineChoice.allCases.filter(\.requiresExplicitDownload),
                       [.whisperLargeV3Turbo, .parakeetV3, .orukeet, .cohereTranscribe])
        XCTAssertTrue(SpeechEngineChoice.cohereTranscribe.hasDeletableModel)
    }

    // MARK: - Preference persistence (no migration)

    func testPreferenceDefaultsToNilAndUnknownValuesReadAsNil() {
        let suite = "typr.engine.pref.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = TyprSettings(defaults: defaults)
        XCTAssertNil(settings.preferredSpeechEngine)

        defaults.set("whisper-large-v3", forKey: "typr.preferredSpeechEngine")
        XCTAssertNil(settings.preferredSpeechEngine, "an unknown stored value is no choice, never Whisper")

        settings.preferredSpeechEngine = .whisperLargeV3Turbo
        XCTAssertEqual(defaults.string(forKey: "typr.preferredSpeechEngine"), "whisper-large-v3-turbo")
        settings.preferredSpeechEngine = nil
        XCTAssertNil(defaults.object(forKey: "typr.preferredSpeechEngine"), "nil removes the key")
        XCTAssertNil(TyprSettings(defaults: nil).preferredSpeechEngine)
    }

    func testNoChoiceStaysNilThroughLaunchPrepareAndDictationAndUsesTheAutomaticPath() async throws {
        let f = fixture(autoPrepare: true)
        // Launch without a choice either prepares (cached Parakeet), asks Apple Speech for a locale
        // in a task, or does nothing. Wait for that decision instead of a fixed delay.
        var appleSpeechAvailable = false
        if #available(iOS 26.0, *) { appleSpeechAvailable = AppleSpeechTranscriber.isAvailable }
        if ParakeetTranscriber.hasCachedModel || appleSpeechAvailable {
            try await waitForState("launch engine decision") {
                f.controller.phase != .preparingModel
                    && (f.controller.phase != .modelRequired || f.controller.engineName == "Parakeet V2")
            }
        }
        XCTAssertNil(f.controller.preferredEngine)
        if f.controller.phase != .ready { try await f.ready() }
        try await f.dictate()

        XCTAssertNil(f.controller.preferredEngine)
        XCTAssertNil(f.settings.preferredSpeechEngine)
        XCTAssertNil(f.storedPreferenceRaw, "nothing is written without an explicit choice")
        XCTAssertTrue(f.fake.explicitCalls.isEmpty, "no explicit engine is created for the automatic path")
        XCTAssertFalse(f.fake.automaticCalls.isEmpty)
        XCTAssertEqual(f.controller.currentEngine, .appleSpeech)

        // Relaunch on the same defaults: still no choice.
        let relaunched = fixture(defaults: f.defaults)
        XCTAssertNil(relaunched.controller.preferredEngine)
        XCTAssertNil(relaunched.storedPreferenceRaw)
    }

    func testPinningTheAutomaticReadyEnginePersistsWithoutReloading() async throws {
        let f = fixture()
        try await f.ready()
        let automatic = try XCTUnwrap(f.fake.created.first)
        XCTAssertNil(f.controller.preferredEngine)
        XCTAssertEqual(f.controller.selectEngine(.appleSpeech), .selected)
        XCTAssertEqual(f.controller.preferredEngine, .appleSpeech)
        XCTAssertEqual(f.controller.currentEngine, .appleSpeech)
        XCTAssertEqual(f.controller.phase, .ready)
        XCTAssertEqual(f.storedPreferenceRaw, "apple-speech")
        // Synchronous: a reload would already have left `.ready` above.
        XCTAssertTrue(f.fake.explicitCalls.isEmpty, "pinning does not create another engine")
        let preparations = await automatic.prepareCount
        XCTAssertEqual(preparations, 1)
    }

    func testAutomaticPathPassesTheDictationLanguage() async throws {
        let f = fixture(language: .german)
        try await f.ready()
        XCTAssertEqual(f.fake.automaticCalls, [.german])
    }

    func testLegacyFactoryIsUsedOnlyWithoutAChoice() async throws {
        var factoryCalls = 0
        let legacy = EngineASR(.parakeetV2)
        let automatic = fixture(transcriberFactory: { factoryCalls += 1; return legacy })
        try await automatic.ready()
        XCTAssertEqual(factoryCalls, 1)
        XCTAssertTrue(automatic.fake.automaticCalls.isEmpty)

        let explicit = fixture(preferred: .appleSpeech, transcriberFactory: { factoryCalls += 1; return legacy })
        try await explicit.ready()
        XCTAssertEqual(factoryCalls, 1, "an explicit choice never goes through the automatic factory")
        XCTAssertEqual(explicit.fake.explicitCalls, [.appleSpeech])
        XCTAssertEqual(explicit.controller.currentEngine, .appleSpeech)
    }

    func testProductionAutomaticChoiceIsNeverWhisperEvenWhenInstalled() async throws {
        let store = whisperRoot()
        try WhisperTestFiles.populate(store, marker: true)
        XCTAssertTrue(store.isInstalled)
        let provider = ProductionSpeechEngineProvider(whisperStore: store)
        for language in DictationLanguage.allCases {
            let automatic = await provider.automaticTranscriber(language: language)
            XCTAssertTrue(["Apple Speech", "Parakeet V2"].contains(automatic.displayName),
                          "\(language): \(automatic.displayName)")
        }
    }

    func testExplicitChoicePersistsAcrossRelaunch() async throws {
        let f = fixture()
        try await f.ready()
        XCTAssertEqual(f.controller.selectEngine(.parakeetV2), .selected)
        XCTAssertEqual(f.storedPreferenceRaw, "parakeet-v2")
        try await f.waitUntil { f.controller.phase == .ready }
        XCTAssertEqual(f.controller.currentEngine, .parakeetV2)

        let relaunched = fixture(defaults: f.defaults)
        XCTAssertEqual(relaunched.controller.preferredEngine, .parakeetV2)
        XCTAssertEqual(relaunched.controller.engineName, "Parakeet V2")
        XCTAssertEqual(relaunched.controller.selectEngine(.parakeetV2), .alreadySelected)
    }

    // MARK: - Explicit choice: no silent fallback

    func testUnavailableExplicitEngineFailsWithItsReasonAndNoOtherEngineIsCreated() async throws {
        let f = fixture(preferred: .parakeetV2, language: .german)
        try await f.ready()
        let previous = try XCTUnwrap(f.fake.instances(of: .parakeetV2).first)
        f.fake.errors[.appleSpeech] = .languageUnsupported(.appleSpeech, .german)

        XCTAssertEqual(f.controller.selectEngine(.appleSpeech), .selected)
        try await f.waitUntil { if case .failed = f.controller.phase { true } else { false } }
        XCTAssertEqual(f.controller.phase,
                       .failed("Apple Speech does not support German on this iPhone. Choose another language or engine."))
        XCTAssertEqual(f.controller.preferredEngine, .appleSpeech, "the choice is kept, not replaced")
        XCTAssertNil(f.controller.currentEngine)
        XCTAssertFalse(f.controller.isModelReady, "a failed switch never retains the old readiness")
        XCTAssertTrue(f.fake.automaticCalls.isEmpty)
        XCTAssertEqual(f.fake.explicitCalls, [.parakeetV2, .appleSpeech])
        XCTAssertFalse(f.bridge.isModelInstalled)

        // Retrying asks for the same engine again; it never substitutes another one.
        f.controller.performPrimaryAction()
        try await f.waitUntil {
            if case .failed = f.controller.phase { f.fake.explicitCalls.count == 3 } else { false }
        }
        XCTAssertEqual(f.fake.explicitCalls, [.parakeetV2, .appleSpeech, .appleSpeech])
        XCTAssertTrue(f.fake.automaticCalls.isEmpty)

        // Even a forced dictation is refused without a ready engine; the released engine is not used.
        // Synchronous: without a ready engine `startRecording` returns before any task.
        f.controller.startRecording()
        XCTAssertTrue(f.audio.captures.isEmpty)
        let previousCalls = await previous.languages
        XCTAssertTrue(previousCalls.isEmpty, "the previous engine never transcribes after a switch")
        XCTAssertEqual(f.controller.phase,
                       .failed(SpeechEngineError.languageUnsupported(.appleSpeech, .german).localizedDescription))
        XCTAssertEqual(f.controller.transcript, "")
    }

    func testKeyboardInstalledFlagFollowsTheSelectedEngineAtPreparationEntry() async throws {
        let f = fixture(preferred: .parakeetV2)
        try await f.ready()
        XCTAssertTrue(f.bridge.isModelInstalled)
        let apple = EngineASR(.appleSpeech)
        await apple.holdPrepare()
        f.fake.queued[.appleSpeech] = [apple]
        XCTAssertEqual(f.controller.selectEngine(.appleSpeech), .selected)
        XCTAssertEqual(f.controller.phase, .preparingModel)
        XCTAssertFalse(f.controller.isModelReady)
        XCTAssertFalse(f.bridge.isModelInstalled, "never keep the old Parakeet install flag while Apple is selected")
        await apple.releasePrepare()
        try await f.waitUntil { f.controller.phase == .ready }
        XCTAssertTrue(f.bridge.isModelInstalled)
    }

    func testExplicitEnginePreparationFailureIsReportedWithoutFallback() async throws {
        let failing = EngineASR(.parakeetV2)
        await failing.setPrepareFailure(CocoaError(.fileReadNoPermission))
        let f = fixture(preferred: .parakeetV2)
        f.fake.queued[.parakeetV2] = [failing]
        f.controller.prepareModel()
        try await f.waitUntil { if case .failed = f.controller.phase { true } else { false } }
        XCTAssertNil(f.controller.currentEngine)
        XCTAssertTrue(f.fake.automaticCalls.isEmpty)
        XCTAssertEqual(f.fake.explicitCalls, [.parakeetV2])
    }

    func testEngineErrorsNameTheChosenEngineAndOfferNoSubstitute() {
        XCTAssertEqual(SpeechEngineError.requiresNewerOS(.appleSpeech).localizedDescription,
                       "Apple Speech requires iOS 26 or later. Choose another engine under Speech engine.")
        XCTAssertEqual(SpeechEngineError.unsupportedDevice(.appleSpeech).localizedDescription,
                       "Apple Speech is not supported on this iPhone. Choose another engine under Speech engine.")
        XCTAssertEqual(SpeechEngineError.languageUnsupported(.appleSpeech, .automatic).localizedDescription,
                       "Apple Speech does not support your preferred languages on this iPhone.")
        XCTAssertEqual(SpeechEngineError.languageUnsupported(.appleSpeech, .english).localizedDescription,
                       "Apple Speech does not support English on this iPhone. Choose another language or engine.")
        if #available(iOS 26.0, *) {
            XCTAssertEqual(AppleSpeechTranscriber.TranscriberError.languageUnsupported("German").localizedDescription,
                           "Apple Speech does not support German on this iPhone. Choose another language or engine.")
        }
    }

    // MARK: - Apple Speech availability (pure parts) and the production provider

    func testExplicitLanguageNeverPreparesAnotherLanguage() {
        XCTAssertEqual(DictationLanguage.german.speechLocaleCandidates(preferred: ["de-AT", "en-US"], current: "de_CH"),
                       ["de-DE", "de-AT", "de_CH"])
        XCTAssertEqual(DictationLanguage.english.speechLocaleCandidates(preferred: ["en-GB", "de-DE"], current: "de_DE"),
                       ["en-US", "en-GB"])
        for candidate in DictationLanguage.german.speechLocaleCandidates(preferred: ["en-US", "fr-FR"], current: "en_US") {
            XCTAssertTrue(candidate.lowercased().hasPrefix("de"), candidate)
        }
        // Automatic and the no-choice availability order are unchanged.
        XCTAssertEqual(DictationLanguage.automatic.speechLocaleCandidates(preferred: ["fr-FR"], current: "de_DE"),
                       ["fr-FR", "de_DE", "en-US"])
        XCTAssertEqual(DictationLanguage.english.availabilityLocaleCandidates(preferred: ["de-DE"], current: "de_DE"),
                       ["en-US", "de-DE", "de_DE"])
        if #available(iOS 26.0, *) {
            XCTAssertEqual(AppleSpeechTranscriber.requestedLocale(for: .german).identifier, "de-DE")
            XCTAssertEqual(AppleSpeechTranscriber.requestedLocale(for: .english).identifier, "en-US")
        }
    }

    func testAvailabilityValuesSayWhetherTheEngineCanWork() {
        XCTAssertTrue(SpeechEngineAvailability.installed.isSupported)
        XCTAssertTrue(SpeechEngineAvailability.downloadRequired("x").isSupported)
        XCTAssertFalse(SpeechEngineAvailability.requiresNewerOS("x").isSupported)
        XCTAssertFalse(SpeechEngineAvailability.unsupportedDevice("x").isSupported)
        XCTAssertFalse(SpeechEngineAvailability.languageUnsupported("x").isSupported)
        XCTAssertEqual(SpeechEngineAvailability.installed.detail, "Installed on this iPhone")
        XCTAssertEqual(SpeechEngineAvailability.languageUnsupported("Not available for German on this iPhone").detail,
                       "Not available for German on this iPhone")
    }

    func testProductionProviderReportsWhisperFromDiskOnly() async throws {
        let store = whisperRoot()
        let provider = ProductionSpeechEngineProvider(whisperStore: store)
        XCTAssertFalse(provider.isInstalled(.whisperLargeV3Turbo))
        let missing = await provider.availability(of: .whisperLargeV3Turbo, language: .german)
        XCTAssertEqual(missing, .downloadRequired("Not downloaded (\(WhisperModelSpec.downloadSizeLabel))."))
        do {
            _ = try await provider.transcriber(for: .whisperLargeV3Turbo, language: .german)
            XCTFail("an uninstalled Whisper is never created")
        } catch {
            XCTAssertEqual(error as? SpeechEngineError, .notInstalled(.whisperLargeV3Turbo))
        }

        // Partial (no marker): still not installed, never selectable.
        try WhisperTestFiles.populate(store, marker: false)
        XCTAssertFalse(provider.isInstalled(.whisperLargeV3Turbo))

        try store.writeMarker()
        XCTAssertTrue(provider.isInstalled(.whisperLargeV3Turbo))
        let present = await provider.availability(of: .whisperLargeV3Turbo, language: .automatic)
        XCTAssertEqual(present, .installed)
        let whisper = try await provider.transcriber(for: .whisperLargeV3Turbo, language: .english)
        XCTAssertEqual(whisper.displayName, "Whisper Large V3 Turbo")
        let languageName = await whisper.languageName
        XCTAssertEqual(languageName, "English")

        let parakeet = await provider.availability(of: .parakeetV2, language: .german)
        XCTAssertEqual(parakeet == .installed, ParakeetTranscriber.hasCachedModel)
        XCTAssertEqual(provider.isInstalled(.parakeetV2), ParakeetTranscriber.hasCachedModel)
        XCTAssertFalse(provider.isInstalled(.appleSpeech), "Apple Speech assets are only known asynchronously")
    }

    func testProductionAppleSpeechIsExactlyAppleSpeechOrAnExplicitError() async throws {
        // OS, device, language and assets are whatever this simulator has; the contract is that
        // availability and creation agree and creation never returns another engine.
        let provider = ProductionSpeechEngineProvider(whisperStore: whisperRoot())
        for language in DictationLanguage.allCases {
            let availability = await provider.availability(of: .appleSpeech, language: language)
            if #unavailable(iOS 26.0) {
                XCTAssertEqual(availability, .requiresNewerOS("Requires iOS 26 or later"))
            }
            do {
                let created = try await provider.transcriber(for: .appleSpeech, language: language)
                XCTAssertEqual(created.displayName, "Apple Speech")
                XCTAssertTrue(availability.isSupported, "\(language): created although \(availability)")
            } catch let error as SpeechEngineError {
                switch availability {
                case .requiresNewerOS:
                    XCTAssertEqual(error, .requiresNewerOS(.appleSpeech))
                case .unsupportedDevice:
                    XCTAssertEqual(error, .unsupportedDevice(.appleSpeech))
                case .languageUnsupported:
                    XCTAssertEqual(error, .languageUnsupported(.appleSpeech, language))
                default:
                    XCTFail("\(language): availability \(availability) but creation threw \(error)")
                }
            }
        }
    }

    // MARK: - Whisper is downloaded only by its Download button

    private func whisperChosenNotInstalled(autoPrepare: Bool) -> (EngineFixture, CountingDownloader, WhisperModelStore) {
        let store = whisperRoot()
        let downloader = CountingDownloader()
        _ = WhisperModelInstaller(store: store, downloader: downloader, tokenizerChecker: PassingTokenizerChecker(),
                                  availableCapacity: { .max })
        let f = fixture(preferred: .whisperLargeV3Turbo, language: .german, autoPrepare: autoPrepare,
                        provider: ProductionSpeechEngineProvider(whisperStore: store))
        return (f, downloader, store)
    }

    func testLaunchWithWhisperChosenButNotInstalledDoesNotPrepareOrDownload() async throws {
        let (f, downloader, store) = whisperChosenNotInstalled(autoPrepare: true)
        // Synchronous: launch preparation skips an uninstalled Whisper without starting a task.
        XCTAssertEqual(f.controller.phase, .modelRequired)
        XCTAssertEqual(f.controller.engineName, "Whisper Large V3 Turbo")
        XCTAssertEqual(f.controller.preferredEngine, .whisperLargeV3Turbo)
        XCTAssertFalse(f.bridge.isModelInstalled)
        XCTAssertTrue(downloader.calls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.path))
    }

    func testPrepareKeyboardHandoffAndIntentFailWithNotDownloadedAndNeverDownload() async throws {
        let (f, downloader, store) = whisperChosenNotInstalled(autoPrepare: false)
        let notInstalled = SpeechEngineError.notInstalled(.whisperLargeV3Turbo).localizedDescription

        // Primary action (Prepare).
        f.controller.performPrimaryAction()
        try await f.waitUntil { f.controller.phase == .failed(notInstalled) }
        XCTAssertNil(f.controller.currentEngine)

        // Keyboard cold-start handoff.
        f.controller.handleKeyboardLaunch(.startRecording(jobID: "kb-1", requestedAt: f.now, style: .polished, host: nil))
        // The handoff starts another preparation; wait until it has failed again.
        try await f.waitUntil { f.controller.phase == .failed(notInstalled) }
        XCTAssertEqual(f.controller.phase, .failed(notInstalled))
        XCTAssertTrue(f.audio.captures.isEmpty, "no recording without a ready engine")
        XCTAssertEqual(f.bridge.snapshot().state, .failed)
        XCTAssertEqual(f.bridge.snapshot().message, notInstalled)

        // Action Button / Control Center intent.
        let result = await TyprSystemCommandBus.shared.dispatch(.toggleDictation)
        XCTAssertNil(result)
        XCTAssertEqual(f.controller.phase, .failed(notInstalled))
        await TyprSystemCommandBus.shared.dispatch(.warmSession)
        try await f.waitUntil { f.controller.phase == .failed(notInstalled) }

        // Language change. Synchronous: only Apple Speech reprepares for a language.
        f.controller.setDictationLanguage(.english)

        XCTAssertTrue(downloader.calls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.path), "nothing was written for Whisper")
        XCTAssertEqual(f.controller.preferredEngine, .whisperLargeV3Turbo)
        XCTAssertFalse(f.bridge.isModelInstalled)
    }

    func testSelectingAnUninstalledWhisperChangesNothingAndDownloadsNothing() async throws {
        let store = whisperRoot()
        let downloader = CountingDownloader()
        let installer = WhisperModelInstaller(store: store, downloader: downloader,
                                              tokenizerChecker: PassingTokenizerChecker(), availableCapacity: { .max })
        let fake = FakeEngineProvider()
        fake.installedCheck = { $0 == .whisperLargeV3Turbo ? installer.isInstalled : true }
        let f = fixture(preferred: .parakeetV2, provider: fake)
        try await f.ready()
        let callsBefore = fake.explicitCalls

        XCTAssertEqual(f.controller.selectEngine(.whisperLargeV3Turbo), .notInstalled)
        XCTAssertEqual(f.controller.preferredEngine, .parakeetV2)
        XCTAssertEqual(f.storedPreferenceRaw, "parakeet-v2")
        XCTAssertEqual(f.controller.currentEngine, .parakeetV2)
        XCTAssertEqual(f.controller.phase, .ready)
        XCTAssertEqual(fake.explicitCalls, callsBefore, "nothing is prepared")
        XCTAssertTrue(downloader.calls.isEmpty)
        XCTAssertEqual(installer.state, .notInstalled)

        // Partial files are still not selectable.
        try WhisperTestFiles.populate(store, marker: false)
        installer.refresh()
        XCTAssertEqual(f.controller.selectEngine(.whisperLargeV3Turbo), .notInstalled)
        XCTAssertTrue(downloader.calls.isEmpty)
    }

    func testCurrentEngineKeepsWorkingDuringAndAfterAFailedDownloadAndWhisperIsSelectableOnceInstalled() async throws {
        let store = whisperRoot()
        let downloader = CountingDownloader()
        let installer = WhisperModelInstaller(store: store, downloader: downloader,
                                              tokenizerChecker: PassingTokenizerChecker(), availableCapacity: { .max })
        let fake = FakeEngineProvider()
        fake.installedCheck = { $0 == .whisperLargeV3Turbo ? installer.isInstalled : true }
        let parakeet = EngineASR(.parakeetV2, output: "first while downloading")
        fake.queued[.parakeetV2] = [parakeet]
        let f = fixture(preferred: .parakeetV2, provider: fake)
        try await f.ready()

        // Download running: the current engine dictates normally and Whisper is not selectable.
        downloader.hold()
        let download = installer.install()
        try await f.waitUntil { !downloader.calls.isEmpty }
        XCTAssertTrue(installer.isBusy)
        let duringDownload = try await f.dictate()
        XCTAssertEqual(duringDownload, "First while downloading.")
        XCTAssertEqual(f.controller.selectEngine(.whisperLargeV3Turbo), .notInstalled)

        // The download fails: the active engine and the choice are untouched.
        downloader.fail(with: URLError(.networkConnectionLost))
        downloader.release()
        installer.cancel()
        await download.value
        await installer.install().value
        XCTAssertEqual(installer.state, .failed("No internet connection. Connect and tap Retry."))
        XCTAssertEqual(f.controller.preferredEngine, .parakeetV2)
        XCTAssertEqual(f.controller.currentEngine, .parakeetV2)
        await parakeet.setOutput("second after the failure")
        let afterFailure = try await f.dictate()
        XCTAssertEqual(afterFailure, "Second after the failure.")
        XCTAssertEqual(f.controller.selectEngine(.whisperLargeV3Turbo), .notInstalled)

        // Retry succeeds: only now can Whisper be selected, and selecting it downloads nothing more.
        downloader.fail(with: nil)
        await installer.install().value
        XCTAssertEqual(installer.state, .installed)
        let downloadsAfterInstall = downloader.calls.count
        XCTAssertEqual(f.controller.selectEngine(.whisperLargeV3Turbo), .selected)
        try await f.waitUntil { f.controller.phase == .ready }
        XCTAssertEqual(f.controller.currentEngine, .whisperLargeV3Turbo)
        XCTAssertEqual(downloader.calls.count, downloadsAfterInstall)
    }

    func testInstalledWhisperPreparesOfflineThroughTheProductionPath() async throws {
        // Exact sizes and marker, but no real model: preparation must fail locally (unreadable
        // tokenizer) without any download and without falling back to another engine.
        let store = whisperRoot()
        try WhisperTestFiles.populate(store, marker: true)
        let downloader = CountingDownloader()
        _ = WhisperModelInstaller(store: store, downloader: downloader, tokenizerChecker: PassingTokenizerChecker(),
                                  availableCapacity: { .max })
        let f = fixture(provider: ProductionSpeechEngineProvider(whisperStore: store))
        XCTAssertEqual(f.controller.selectEngine(.whisperLargeV3Turbo), .selected)
        XCTAssertEqual(f.storedPreferenceRaw, "whisper-large-v3-turbo")
        try await f.waitUntil(timeout: 10) { if case .failed = f.controller.phase { true } else { false } }
        guard case .failed(let message) = f.controller.phase else { return XCTFail() }
        XCTAssertTrue(message.contains("Download Whisper again"), message)
        XCTAssertNil(f.controller.currentEngine)
        XCTAssertEqual(f.controller.preferredEngine, .whisperLargeV3Turbo)
        XCTAssertTrue(downloader.calls.isEmpty)
        XCTAssertFalse(store.hasMarker, "local tokenizer corruption invalidates the install proof")
        XCTAssertFalse(f.bridge.isModelInstalled, "the selected engine is no longer verified on disk")
    }

    // MARK: - Switching

    func testSwitchUsesTheChosenEngineForTheNextDictation() async throws {
        let f = fixture(preferred: .parakeetV2)
        try await f.ready()
        let beforeSwitch = try await f.dictate()
        XCTAssertEqual(beforeSwitch, "Ship the build.")
        let parakeet = try XCTUnwrap(f.fake.instances(of: .parakeetV2).first)

        let whisper = EngineASR(.whisperLargeV3Turbo, output: "whisper wrote this")
        await whisper.holdPrepare()
        f.fake.queued[.whisperLargeV3Turbo] = [whisper]
        XCTAssertEqual(f.controller.selectEngine(.whisperLargeV3Turbo), .selected)
        XCTAssertEqual(f.controller.phase, .preparingModel)
        XCTAssertNil(f.controller.currentEngine, "no engine is current while switching")
        XCTAssertFalse(f.controller.isModelReady)
        XCTAssertEqual(f.controller.engineName, "Whisper Large V3 Turbo")
        XCTAssertEqual(f.controller.selectEngine(.whisperLargeV3Turbo), .alreadySelected)

        await whisper.releasePrepare()
        try await f.waitUntil { f.controller.phase == .ready }
        XCTAssertEqual(f.controller.currentEngine, .whisperLargeV3Turbo)
        XCTAssertTrue(f.bridge.isModelInstalled)

        let afterSwitch = try await f.dictate()
        XCTAssertEqual(afterSwitch, "Whisper wrote this.")
        let parakeetCalls = await parakeet.languages.count
        let whisperCalls = await whisper.languages.count
        XCTAssertEqual(parakeetCalls, 1)
        XCTAssertEqual(whisperCalls, 1)
    }

    func testANewChoiceWaitsForTheSupersededPreparationAndDropsItsResult() async throws {
        let f = fixture(preferred: .parakeetV2)
        try await f.ready()
        let slowApple = EngineASR(.appleSpeech)
        await slowApple.holdPrepare()
        f.fake.queued[.appleSpeech] = [slowApple]

        XCTAssertEqual(f.controller.selectEngine(.appleSpeech), .selected)
        try await f.waitUntil { f.fake.explicitCalls.last == .appleSpeech }
        XCTAssertEqual(f.controller.selectEngine(.whisperLargeV3Turbo), .selected, "choosing again while preparing is allowed")
        // The new preparation task's first main-actor step would create the model without the wait.
        await mainActorBarrier()
        XCTAssertFalse(f.fake.explicitCalls.contains(.whisperLargeV3Turbo),
                       "the next model is not created while the previous one is still loading")

        await slowApple.releasePrepare()
        try await f.waitUntil { f.controller.phase == .ready && f.controller.currentEngine != nil }
        XCTAssertEqual(f.controller.currentEngine, .whisperLargeV3Turbo, "the superseded result is dropped")
        XCTAssertEqual(f.controller.engineName, "Whisper Large V3 Turbo")
        XCTAssertEqual(Array(f.fake.events.suffix(2)), ["create:apple-speech", "create:whisper-large-v3-turbo"])
        // Synchronous: the superseded task finished before the Whisper one created its model.
        XCTAssertEqual(f.controller.currentEngine, .whisperLargeV3Turbo)

        _ = try await f.dictate()
        let appleCalls = await slowApple.languages.count
        XCTAssertEqual(appleCalls, 0)
    }

    func testSupersededPreparationCannotPublishReadyAfterAwaitingItsLanguageName() async throws {
        let f = fixture(preferred: .parakeetV2)
        try await f.ready()
        let gate = EngineLanguageGate()
        defer { gate.release() }
        let apple = EngineASR(.appleSpeech, languageGate: gate)
        f.fake.queued[.appleSpeech] = [apple]
        XCTAssertEqual(f.controller.selectEngine(.appleSpeech), .selected)
        try await f.waitUntil { gate.hasStarted }
        XCTAssertEqual(f.controller.selectEngine(.whisperLargeV3Turbo), .selected)
        XCTAssertNil(f.controller.currentEngine)
        XCTAssertFalse(f.controller.isModelReady)

        gate.release()
        try await f.waitUntil { f.controller.phase == .ready }
        XCTAssertEqual(f.controller.currentEngine, .whisperLargeV3Turbo)
        XCTAssertEqual(f.controller.preferredEngine, .whisperLargeV3Turbo)
        XCTAssertEqual(f.controller.engineName, "Whisper Large V3 Turbo")
        let staleCalls = await apple.languages
        XCTAssertTrue(staleCalls.isEmpty)
    }

    func testEngineCannotChangeFromPermissionRequestUntilTranscriptionEnds() async throws {
        let f = fixture(preferred: .parakeetV2)
        try await f.ready()
        let parakeet = try XCTUnwrap(f.fake.instances(of: .parakeetV2).first)
        let created = f.fake.explicitCalls
        XCTAssertTrue(f.controller.canChangeEngine)

        f.audio.holdPermission = true
        f.controller.startRecording()
        XCTAssertEqual(f.controller.phase, .requestingPermission)
        XCTAssertFalse(f.controller.canChangeEngine)
        XCTAssertEqual(f.controller.selectEngine(.whisperLargeV3Turbo), .busy)

        f.audio.releasePermission()
        try await f.waitUntil { f.controller.phase == .recording }
        XCTAssertFalse(f.controller.canChangeEngine)
        XCTAssertEqual(f.controller.selectEngine(.appleSpeech), .busy)

        await parakeet.holdTranscribe()
        f.controller.finishRecording()
        XCTAssertEqual(f.controller.phase, .transcribing)
        XCTAssertFalse(f.controller.canChangeEngine)
        XCTAssertEqual(f.controller.selectEngine(.whisperLargeV3Turbo), .busy)

        XCTAssertEqual(f.controller.preferredEngine, .parakeetV2)
        XCTAssertEqual(f.storedPreferenceRaw, "parakeet-v2", "a refused choice is not persisted")
        XCTAssertEqual(f.fake.explicitCalls, created)

        await parakeet.releaseTranscribe()
        try await f.waitUntil { f.controller.phase == .ready && f.controller.canChangeEngine }
        XCTAssertTrue(f.controller.canChangeEngine)
        XCTAssertEqual(f.controller.selectEngine(.whisperLargeV3Turbo), .selected)
    }

    func testEngineCannotChangeWhileAICleanupRuns() async throws {
        let session = CleanupTestSession()
        session.suspend = true
        let sleeper = CleanupTestSleeper()
        defer { session.resume(); sleeper.fire() }
        let f = fixture(preferred: .whisperLargeV3Turbo, language: .german, cleanup: { _ in
            TranscriptCleanupDependencies(cleaner: CleanupTestCleaner(session: session), background: CleanupTestBackground(), isEnabled: { true }, sleep: sleeper.sleep)
        })
        try await f.ready()
        let whisper = try XCTUnwrap(f.fake.instances(of: .whisperLargeV3Turbo).first)
        await whisper.setOutput("die katze sitzt auf der mathe")

        f.controller.startRecording(keyboardJobID: "cleanup-job")
        try await f.waitUntil { f.controller.phase == .recording }
        f.controller.finishRecording()
        try await f.waitUntil { session.cleanCount == 1 }
        XCTAssertEqual(f.controller.phase, .transcribing)
        XCTAssertFalse(f.controller.canChangeEngine)
        XCTAssertEqual(f.controller.selectEngine(.parakeetV2), .busy)

        session.resume()
        try await f.waitUntil { f.controller.phase == .ready && f.controller.canChangeEngine }
        XCTAssertTrue(f.controller.canChangeEngine)
        XCTAssertEqual(f.controller.transcript, "Die Katze sitzt auf der Matte.")
        XCTAssertEqual(f.bridge.snapshot().transcript, "Die Katze sitzt auf der Matte.")
        sleeper.fire()
    }

    func testPrepareModelIsANoOpDuringPermissionCaptureAndInference() async throws {
        let f = fixture(preferred: .whisperLargeV3Turbo)
        try await f.ready()
        let whisper = try XCTUnwrap(f.fake.instances(of: .whisperLargeV3Turbo).first)
        let originalCalls = f.fake.explicitCalls

        f.audio.holdPermission = true
        f.controller.startRecording()
        f.controller.prepareModel()
        XCTAssertEqual(f.controller.phase, .requestingPermission)
        f.audio.releasePermission()
        try await f.waitUntil { f.controller.phase == .recording }
        f.controller.prepareModel()
        XCTAssertEqual(f.controller.phase, .recording)

        await whisper.holdTranscribe()
        f.controller.finishRecording()
        try await f.waitForCalls(whisper, count: 1)
        f.controller.prepareModel()
        XCTAssertEqual(f.controller.phase, .transcribing)
        XCTAssertEqual(f.fake.explicitCalls, originalCalls)
        XCTAssertEqual(f.controller.currentEngine, .whisperLargeV3Turbo)
        XCTAssertTrue(f.controller.isModelReady)

        await whisper.releaseTranscribe()
        try await f.waitUntil { f.controller.phase == .ready && f.controller.canChangeEngine }
    }

    func testCancelledPermissionRequestAlsoFencesEngineChangesUntilItExits() async throws {
        let f = fixture(preferred: .parakeetV2)
        try await f.ready()
        f.audio.holdPermission = true
        f.controller.startRecording()
        // The request task must be suspended in the fake's continuation before it is cancelled.
        try await f.waitUntil { f.audio.heldPermissionRequests == 1 }
        f.controller.cancelCurrentJob()
        XCTAssertEqual(f.controller.phase, .ready)
        XCTAssertFalse(f.controller.canChangeEngine)
        XCTAssertEqual(f.controller.selectEngine(.whisperLargeV3Turbo), .busy)
        f.controller.prepareModel()
        XCTAssertEqual(f.fake.explicitCalls, [.parakeetV2])

        f.audio.releasePermission()
        try await f.waitUntil { f.controller.canChangeEngine }
        XCTAssertTrue(f.audio.captures.isEmpty, "the stale permission result never starts recording")
        XCTAssertEqual(f.controller.selectEngine(.whisperLargeV3Turbo), .selected)
    }

    func testCancelledInferenceFencesSwitchUntilItActuallyReturnsEvenAfterANewerCaptureFinishes() async throws {
        let f = fixture(preferred: .whisperLargeV3Turbo)
        try await f.ready()
        let whisper = try XCTUnwrap(f.fake.instances(of: .whisperLargeV3Turbo).first)
        await whisper.setOutput("stale old words")
        await whisper.holdCall(1)
        f.controller.startRecording(keyboardJobID: "old")
        try await f.waitUntil { f.controller.phase == .recording }
        let oldURL = try XCTUnwrap(f.audio.captures.last?.url)
        f.controller.finishRecording()
        try await f.waitForCalls(whisper, count: 1)
        f.controller.cancelCurrentJob()

        XCTAssertEqual(f.controller.phase, .ready, "Cancel may return to Ready before model work unwinds")
        XCTAssertFalse(f.controller.canChangeEngine)
        XCTAssertEqual(f.controller.selectEngine(.parakeetV2), .busy)
        f.controller.prepareModel()
        XCTAssertEqual(f.controller.phase, .ready, "preparation cannot allocate another model during the drain")
        XCTAssertEqual(f.fake.explicitCalls, [.whisperLargeV3Turbo])

        // Existing behavior: a newer capture may use the SAME engine while old work winds down.
        await whisper.setOutput("new words")
        f.controller.startRecording(keyboardJobID: "new")
        try await f.waitUntil { f.controller.phase == .recording }
        let newURL = try XCTUnwrap(f.audio.captures.last?.url)
        XCTAssertNotEqual(oldURL, newURL)
        f.controller.finishRecording()
        try await f.waitUntil { f.controller.phase == .ready }
        XCTAssertEqual(f.controller.transcript, "New words.")
        XCTAssertEqual(f.bridge.snapshot().transcript, "New words.")
        XCTAssertFalse(f.controller.canChangeEngine, "all superseded tasks are fenced, not just the newest one")
        XCTAssertEqual(f.controller.selectEngine(.parakeetV2), .busy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldURL.path))

        await whisper.releaseCall(1)
        try await f.waitUntil { f.controller.canChangeEngine }
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: newURL.path))
        XCTAssertEqual(f.controller.transcript, "New words.", "stale completion never clobbers the new result")
        XCTAssertEqual(f.controller.selectEngine(.parakeetV2), .selected)
    }

    func testChangingFailedAppleLanguageRetriesTheExplicitEngine() async throws {
        let f = fixture(preferred: .appleSpeech, language: .german)
        f.fake.errors[.appleSpeech] = .languageUnsupported(.appleSpeech, .german)
        f.controller.prepareModel()
        try await f.waitUntil { if case .failed = f.controller.phase { true } else { false } }
        XCTAssertFalse(f.controller.isModelReady)
        f.fake.errors[.appleSpeech] = nil

        f.controller.setDictationLanguage(.english)
        try await f.waitUntil { f.controller.phase == .ready }
        XCTAssertEqual(f.fake.explicitLanguages, [.german, .english])
        XCTAssertTrue(f.fake.automaticCalls.isEmpty)
        XCTAssertEqual(f.controller.preferredEngine, .appleSpeech)
        XCTAssertEqual(f.controller.currentEngine, .appleSpeech)
        XCTAssertTrue(f.controller.isModelReady)
        f.controller.setDictationLanguage(.english) // synchronous: the same language returns early
        XCTAssertEqual(f.fake.explicitLanguages, [.german, .english], "same language is not prepared again")
    }

    func testAppleLanguageChangeDuringPermissionUsesTheCaptureSnapshotThenRepreparesBeforeNextCapture() async throws {
        let f = fixture(preferred: .appleSpeech, language: .german)
        let german = EngineASR(.appleSpeech, languageName: "German")
        let english = EngineASR(.appleSpeech, languageName: "English")
        await english.holdPrepare()
        f.fake.queued[.appleSpeech] = [german, english]
        try await f.ready()
        f.audio.holdPermission = true
        f.controller.startRecording()
        XCTAssertEqual(f.controller.phase, .requestingPermission)
        f.controller.setDictationLanguage(.english)
        f.audio.releasePermission()
        try await f.waitUntil { f.controller.phase == .recording }
        XCTAssertEqual(f.fake.explicitLanguages, [.german], "no model work during the accepted capture")
        f.controller.finishRecording()
        try await f.waitUntil { f.fake.explicitLanguages == [.german, .english] }
        XCTAssertEqual(f.controller.phase, .preparingModel)
        XCTAssertFalse(f.controller.isModelReady)
        XCTAssertNil(f.controller.currentEngine)
        f.controller.startRecording() // synchronous: refused while the model is not ready
        XCTAssertEqual(f.audio.captures.count, 1, "the next capture cannot start with the previous Apple locale")

        await english.releasePrepare()
        try await f.waitUntil { f.controller.phase == .ready && f.controller.canChangeEngine }
        _ = try await f.dictate()
        let firstLanguages = await german.languages
        let nextLanguages = await english.languages
        XCTAssertEqual(firstLanguages, [.german], "snapshot is taken before microphone permission awaits")
        XCTAssertEqual(nextLanguages, [.english])
    }

    func testAppleLanguageChangedWhilePreparingNeverPublishesTheOldLocaleAsCurrent() async throws {
        let f = fixture(preferred: .appleSpeech, language: .german)
        let first = EngineASR(.appleSpeech, languageName: "German")
        let second = EngineASR(.appleSpeech, languageName: "English")
        await first.holdPrepare()
        await second.holdPrepare()
        f.fake.queued[.appleSpeech] = [first, second]
        f.controller.prepareModel()
        try await f.waitUntil { f.fake.explicitLanguages == [.german] }
        f.controller.setDictationLanguage(.english)
        await first.releasePrepare()
        try await f.waitUntil { f.fake.explicitLanguages == [.german, .english] }
        XCTAssertEqual(f.controller.phase, .preparingModel)
        XCTAssertNil(f.controller.currentEngine)
        XCTAssertFalse(f.controller.isModelReady)
        f.controller.startRecording()
        XCTAssertTrue(f.audio.captures.isEmpty)

        await second.releasePrepare()
        try await f.waitUntil { f.controller.phase == .ready }
        XCTAssertEqual(f.controller.transcriptionLanguage, "English")
        XCTAssertTrue(f.controller.isModelReady)
        _ = try await f.dictate()
        let staleCalls = await first.languages
        let currentCalls = await second.languages
        XCTAssertTrue(staleCalls.isEmpty)
        XCTAssertEqual(currentCalls, [.english])
    }

    // MARK: - Per-capture snapshots

    func testEachCaptureKeepsTheLanguageFromItsStart() async throws {
        let f = fixture(preferred: .whisperLargeV3Turbo, language: .german)
        try await f.ready()
        let whisper = try XCTUnwrap(f.fake.instances(of: .whisperLargeV3Turbo).first)
        XCTAssertEqual(f.fake.explicitLanguages, [.german])

        f.controller.startRecording()
        try await f.waitUntil { f.controller.phase == .recording }
        f.controller.setDictationLanguage(.english) // during the capture: applies to the next one
        f.controller.finishRecording()
        try await f.waitUntil { f.controller.phase == .ready }

        f.controller.setDictationLanguage(.automatic)
        _ = try await f.dictate()
        let languages = await whisper.languages
        XCTAssertEqual(languages, [.german, .automatic])
        XCTAssertEqual(f.settings.dictationLanguage, .automatic)
        XCTAssertEqual(f.controller.currentEngine, .whisperLargeV3Turbo, "Whisper is not re-prepared for a language change")
    }

    func testDictationLogRecordsTheCapturesEngineAndWhisperLanguage() async throws {
        let env = LogTestEnvironment()
        logEnvironments.append(env)
        try await LogTestEnvironment.waitUntilLoaded(env.store)
        let f = fixture(preferred: .whisperLargeV3Turbo, language: .german, dictationLog: env.store)
        try await f.ready()
        f.controller.startRecording(keyboardJobID: "log-1")
        try await f.waitUntil { f.controller.phase == .recording }
        f.controller.setDictationLanguage(.english)
        f.controller.finishRecording()
        try await f.waitUntil { f.controller.phase == .ready }
        f.controller.setDictationLanguage(.automatic)
        _ = try await f.dictate(jobID: "log-2")

        let contexts = env.store.entries.map(\.context)
        XCTAssertEqual(contexts.count, 2)
        XCTAssertEqual(Set(contexts.map(\.speechEngine)), ["Whisper Large V3 Turbo"])
        XCTAssertEqual(Set(contexts.map(\.speechLanguage)), ["German", "Automatic (detected by Whisper)"])
    }

    func testAStaleTranscriptionNeverOverwritesAfterCancel() async throws {
        let f = fixture(preferred: .whisperLargeV3Turbo)
        try await f.ready()
        let whisper = try XCTUnwrap(f.fake.instances(of: .whisperLargeV3Turbo).first)
        await whisper.setOutput("too late")
        await whisper.holdTranscribe()

        f.controller.startRecording(keyboardJobID: "stale")
        try await f.waitUntil { f.controller.phase == .recording }
        f.controller.finishRecording()
        // Ensure this is genuinely an in-flight result, not work cancelled before it started.
        try await f.waitForCalls(whisper, count: 1)
        f.controller.cancelCurrentJob()
        XCTAssertEqual(f.controller.phase, .ready)
        await whisper.releaseTranscribe()
        // The cancelled transcription task has returned from the model and unwound.
        try await f.waitUntil { f.controller.canChangeEngine }
        XCTAssertEqual(f.controller.transcript, "")
        XCTAssertNil(f.bridge.snapshot().transcript)
        XCTAssertEqual(f.controller.phase, .ready)
    }

    // MARK: - Whisper results through the unchanged pipeline

    func testWhisperSilenceFailsCleanlyAndTheKeyboardGetsTheReason() async throws {
        try await assertWhisperFailureRecovers(
            .silentAudio,
            message: "The recording is too quiet for Whisper. Try speaking closer to the microphone."
        )
    }

    func testWhisperEmptyDecodeIsNotReportedAsSilenceAndNextDictationWorks() async throws {
        try await assertWhisperFailureRecovers(
            .emptyTranscript,
            message: "Whisper returned no text. Please try dictating again."
        )
    }

    private func assertWhisperFailureRecovers(
        _ error: WhisperTranscriber.TranscriberError, message: String
    ) async throws {
        let f = fixture(preferred: .whisperLargeV3Turbo)
        try await f.ready()
        let whisper = try XCTUnwrap(f.fake.instances(of: .whisperLargeV3Turbo).first)
        await whisper.setFailure(error)

        f.controller.startRecording(keyboardJobID: "silent")
        try await f.waitUntil { f.controller.phase == .recording }
        f.controller.finishRecording()
        try await f.waitUntil { f.controller.phase != .transcribing && f.controller.canChangeEngine }
        XCTAssertEqual(f.controller.phase, .failed(message))
        XCTAssertEqual(f.controller.transcript, "")
        XCTAssertEqual(f.bridge.snapshot().state, .failed)
        XCTAssertEqual(f.bridge.snapshot().message, message)
        XCTAssertNil(f.bridge.snapshot().transcript)
        XCTAssertTrue(f.controller.canChangeEngine)
        XCTAssertEqual(f.controller.currentEngine, .whisperLargeV3Turbo, "a silent capture keeps the engine ready")

        // The next capture works with the same engine.
        await whisper.setFailure(nil)
        await whisper.setOutput("hello again")
        let afterSilence = try await f.dictate()
        XCTAssertEqual(afterSilence, "Hello again.")
    }

    func testWhisperTextGetsVocabularyFormattingAndKeyboardDelivery() async throws {
        let f = fixture(preferred: .whisperLargeV3Turbo, language: .german, vocabularyTerms: ["Rudek", "herdr"])
        try await f.ready()
        let whisper = try XCTUnwrap(f.fake.instances(of: .whisperLargeV3Turbo).first)
        await whisper.setOutput("frag rudek wegen herdr")

        f.controller.startRecording(keyboardJobID: "kb-whisper")
        try await f.waitUntil { f.controller.phase == .recording }
        XCTAssertEqual(f.bridge.snapshot().jobID, "kb-whisper")
        f.controller.finishRecording()
        try await f.waitUntil { f.controller.phase == .ready }

        XCTAssertEqual(f.controller.transcript, "Frag Rudek wegen herdr.")
        let snapshot = f.bridge.snapshot()
        XCTAssertEqual(snapshot.transcript, "Frag Rudek wegen herdr.")
        XCTAssertTrue(snapshot.hasDeliverableResult(at: f.now + 1))
        XCTAssertNotNil(snapshot.resultID)
        let vocabularies = await whisper.vocabularies
        XCTAssertTrue(vocabularies.first?.contains("Rudek") == true, "the hint list is still passed (and ignored by Whisper)")
        let languages = await whisper.languages
        XCTAssertEqual(languages, [.german])
    }
}

@MainActor
private final class FakeWhisperBackground: ModelPreparationScheduling {
    var expirations: [@MainActor () -> Void] = []
    var engines: [SpeechEngineChoice] = []
    var finishes: [Bool] = []
    var updates: [ModelPreparationProgress] = []
    var maintenance: [Bool] = []
    var activations = 0
    func begin(_ engine: SpeechEngineChoice, expiration: @escaping @MainActor () -> Void) {
        engines.append(engine)
        expirations.append(expiration)
    }
    func update(_ progress: ModelPreparationProgress) { updates.append(progress) }
    func sceneDidBecomeActive() { activations += 1 }
    func finish(success: Bool) { finishes.append(success) }
    func scheduleMaintenance(needed: Bool) { maintenance.append(needed) }
}

// These simulator tests drive the real controller with a cancellable runtime stand-in. They
// do not claim the simulator grants background execution, exercises ANE, or honors scheduling.
extension SpeechEngineSelectionTests {
    func testInstalledWhisperWaitsForForegroundThenPreparesOnlyOnce() async throws {
        let background = FakeWhisperBackground()
        let f = fixture(preferred: .whisperLargeV3Turbo, autoPrepare: true,
                        modelBackground: background, deferPreparationUntilActive: true)
        XCTAssertEqual(f.controller.phase, .modelRequired)
        XCTAssertTrue(f.fake.created.isEmpty, "background-only launch must wait for the registered handler")
        f.controller.noteSceneDidBecomeActive()
        f.controller.noteSceneDidBecomeActive()
        f.controller.prepareInstalledModelIfNeeded() // maintenance joins, it never creates another model
        try await f.waitUntil { f.controller.phase == .ready }
        f.controller.noteSceneDidBecomeActive()
        XCTAssertEqual(f.fake.explicitCalls, [.whisperLargeV3Turbo])
        XCTAssertEqual(background.expirations.count, 1)
        XCTAssertEqual(background.finishes.last, true)
        XCTAssertEqual(f.controller.preferredEngine, .whisperLargeV3Turbo)
        XCTAssertFalse(f.audio.isKeepaliveRunning)
        XCTAssertTrue(f.audio.captures.isEmpty)
    }

    func testBackgroundOnlyLaunchDefersOtherEnginePreparationToo() async throws {
        let f = fixture(preferred: .appleSpeech, autoPrepare: true, deferPreparationUntilActive: true)
        await Task.yield()
        XCTAssertTrue(f.fake.created.isEmpty, "a stale maintenance wake must not prepare another engine")
        f.controller.noteSceneDidBecomeActive()
        try await f.waitUntil { f.controller.phase == .ready }
        XCTAssertEqual(f.fake.explicitCalls, [.appleSpeech])
    }

    func testOpeningDoesNotDownloadMissingWhisperOrChangeOtherEngine() async throws {
        let choices: [SpeechEngineChoice?] = [nil, .appleSpeech, .parakeetV2, .whisperLargeV3Turbo]
        for preferred in choices {
            let background = FakeWhisperBackground()
            let provider = FakeEngineProvider()
            provider.installed = []
            let f = fixture(preferred: preferred, provider: provider, modelBackground: background)
            f.controller.noteSceneDidBecomeActive()
            f.controller.prepareInstalledModelIfNeeded()
            await Task.yield()
            XCTAssertTrue(provider.explicitCalls.isEmpty)
            XCTAssertTrue(provider.automaticCalls.isEmpty)
            XCTAssertTrue(background.expirations.isEmpty)
            XCTAssertEqual(background.maintenance.last, false)
            XCTAssertEqual(f.controller.preferredEngine, preferred)
            XCTAssertFalse(f.audio.isKeepaliveRunning)
        }
    }

    func testExpirationCannotPublishLateReadyAndRetryWaitsForOldModel() async throws {
        let background = FakeWhisperBackground()
        let old = EngineASR(.whisperLargeV3Turbo)
        await old.holdPrepare()
        let provider = FakeEngineProvider()
        provider.queued[.whisperLargeV3Turbo] = [old]
        let f = fixture(preferred: .whisperLargeV3Turbo, provider: provider, modelBackground: background)
        f.controller.noteSceneDidBecomeActive()
        try await f.waitUntil { provider.created.count == 1 }
        // Ensure the cancellation-ignoring fake has actually entered its model operation.
        for _ in 0..<100 {
            if await old.prepareCount == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let count = await old.prepareCount
        XCTAssertEqual(count, 1)
        let expire = try XCTUnwrap(background.expirations.first)
        expire()
        XCTAssertTrue(f.controller.phase.isFailure)
        XCTAssertFalse(f.controller.isModelReady)
        XCTAssertNil(f.controller.currentEngine)
        f.controller.noteSceneDidBecomeActive()
        // The retry's first main-actor step would create the model if it did not wait for the old one.
        await mainActorBarrier()
        XCTAssertEqual(provider.created.count, 1, "a retry must not overlap a non-interruptible Core ML call")
        await old.releasePrepare()
        try await f.waitUntil { f.controller.phase == .ready }
        XCTAssertEqual(provider.created.count, 2)
        expire() // late expiration from the previous lease must not invalidate the new engine
        XCTAssertEqual(f.controller.phase, .ready)
        XCTAssertEqual(background.finishes.filter { $0 }.count, 1)
        XCTAssertEqual(f.controller.currentEngine, .whisperLargeV3Turbo)
    }

    func testBackgroundingKeepsOnePreparationAndDoesNotStartAudio() async throws {
        let background = FakeWhisperBackground()
        let whisper = EngineASR(.whisperLargeV3Turbo)
        await whisper.holdPrepare()
        let provider = FakeEngineProvider()
        provider.queued[.whisperLargeV3Turbo] = [whisper]
        let f = fixture(preferred: .whisperLargeV3Turbo, provider: provider, modelBackground: background)
        f.controller.noteSceneDidBecomeActive()
        try await f.waitUntil { provider.created.count == 1 }
        f.controller.noteSceneDidEnterBackground()
        f.controller.prepareInstalledModelIfNeeded()
        XCTAssertEqual(background.expirations.count, 1)
        XCTAssertEqual(background.maintenance.last, true)
        XCTAssertFalse(f.audio.isKeepaliveRunning)
        await whisper.releasePrepare()
        try await f.waitUntil { f.controller.phase == .ready }
        XCTAssertEqual(background.finishes.last, true)
        XCTAssertEqual(provider.created.count, 1)
    }

    func testMaintenanceUsesChosenLanguageAndDoesNotLaunchHandoff() async throws {
        let background = FakeWhisperBackground()
        let f = fixture(preferred: .whisperLargeV3Turbo, language: .german, modelBackground: background)
        f.controller.prepareInstalledModelIfNeeded()
        try await f.waitUntil { f.controller.phase == .ready }
        XCTAssertEqual(f.fake.explicitLanguages, [.german])
        XCTAssertFalse(f.audio.isKeepaliveRunning)
        XCTAssertTrue(f.audio.captures.isEmpty)
        XCTAssertEqual(f.controller.preferredEngine, .whisperLargeV3Turbo)
    }

    func testPreparationResourceFailureCompletesUnsuccessfullyWithoutSwitchingEngine() async throws {
        let background = FakeWhisperBackground()
        let whisper = EngineASR(.whisperLargeV3Turbo)
        let error = WhisperTranscriber.TranscriberError.preparationFailed("Resources unavailable")
        await whisper.setPrepareFailure(error)
        let provider = FakeEngineProvider()
        provider.queued[.whisperLargeV3Turbo] = [whisper]
        let f = fixture(preferred: .whisperLargeV3Turbo, provider: provider, modelBackground: background)
        f.controller.prepareInstalledModelIfNeeded()
        try await f.waitUntil { f.controller.phase.isFailure }
        XCTAssertEqual(f.controller.phase, .failed(error.localizedDescription))
        XCTAssertEqual(background.finishes.last, false)
        XCTAssertFalse(f.controller.isModelReady)
        XCTAssertEqual(f.controller.preferredEngine, .whisperLargeV3Turbo)
        XCTAssertTrue(provider.automaticCalls.isEmpty)
        XCTAssertFalse(error.localizedDescription.contains("Download"))
        XCTAssertFalse(f.audio.isKeepaliveRunning)
    }

    func testResourceFailureCanRetryInForegroundWithoutRelaunchOrEngineChange() async throws {
        let background = FakeWhisperBackground()
        let failed = EngineASR(.whisperLargeV3Turbo)
        await failed.setPrepareFailure(WhisperTranscriber.TranscriberError.preparationFailed("Resources unavailable"))
        let provider = FakeEngineProvider()
        provider.queued[.whisperLargeV3Turbo] = [failed]
        let f = fixture(preferred: .whisperLargeV3Turbo, provider: provider, modelBackground: background)
        f.controller.prepareInstalledModelIfNeeded()
        try await f.waitUntil { f.controller.phase.isFailure }
        let staleExpiration = try XCTUnwrap(background.expirations.first)
        XCTAssertEqual(background.finishes.last, false)
        XCTAssertTrue(provider.isInstalled(.whisperLargeV3Turbo))
        f.controller.noteSceneDidBecomeActive()
        try await f.waitUntil { f.controller.phase == .ready }
        staleExpiration()
        XCTAssertEqual(f.controller.phase, .ready)
        XCTAssertEqual(f.controller.currentEngine, .whisperLargeV3Turbo)
        XCTAssertEqual(f.controller.preferredEngine, .whisperLargeV3Turbo)
        XCTAssertEqual(provider.explicitCalls, [.whisperLargeV3Turbo, .whisperLargeV3Turbo])
        XCTAssertTrue(provider.automaticCalls.isEmpty)
        XCTAssertEqual(background.finishes.filter { $0 }.count, 1)
        XCTAssertFalse(f.audio.isKeepaliveRunning)
        XCTAssertTrue(f.audio.captures.isEmpty)
    }

    /// Short system UI text that changes only with a real stage, never per heartbeat or callback.
    func testContinuedTaskSubtitleIsShortAndFollowsRealStages() {
        typealias B = ModelBackgroundPreparation
        XCTAssertEqual(B.taskTitle(for: .whisperLargeV3Turbo), "Preparing Whisper")
        XCTAssertEqual(B.taskSubtitle(for: nil), "Starting")
        XCTAssertEqual(B.taskSubtitle(for: ModelPreparationProgress(fractionCompleted: nil, detail: "Checking model files")), "Starting")
        for component in WhisperPreparationComponent.allCases {
            XCTAssertEqual(B.taskSubtitle(for: component.progress(optimizing: true)), "Optimizing for this iPhone")
            XCTAssertEqual(B.taskSubtitle(for: component.progress(optimizing: false)), "Loading model")
        }
        XCTAssertEqual(B.taskSubtitle(for: ModelPreparationProgress(
            fractionCompleted: nil, detail: "Loading the prepared Whisper models", stageProgress: (3, 5))), "Loading model")
        XCTAssertEqual(B.taskSubtitle(for: ModelPreparationProgress(
            fractionCompleted: nil, detail: "Checking the Whisper model", stageProgress: (4, 5))), "Checking model")
    }

    func testContinuedTaskCountsCompletedMilestonesRatherThanStayingIndeterminate() {
        let unit = ModelBackgroundPreparation.unitsPerStage
        let progress = Progress(totalUnitCount: -1)
        ModelBackgroundPreparation.updateTaskProgress(progress, from: nil)
        XCTAssertEqual(progress.totalUnitCount, 5 * unit)
        XCTAssertEqual(progress.completedUnitCount, 0)
        for component in WhisperPreparationComponent.allCases {
            let update = component.progress(optimizing: true)
            XCTAssertNil(update.fractionCompleted, "the app must not invent a measured percent")
            ModelBackgroundPreparation.updateTaskProgress(progress, from: update)
            XCTAssertEqual(progress.completedUnitCount, (update.stageProgress?.completed ?? -1) * unit)
        }
        for completed: Int64 in [3, 4] {
            ModelBackgroundPreparation.updateTaskProgress(progress, from: ModelPreparationProgress(
                fractionCompleted: nil, detail: "Next real stage", stageProgress: (completed, 5)))
            XCTAssertEqual(progress.completedUnitCount, completed * unit)
        }
        // Late/indeterminate updates cannot regress the system's progress. Only finish(success:)
        // is allowed to mark the task complete, never a queued readiness callback.
        ModelBackgroundPreparation.updateTaskProgress(progress, from: WhisperPreparationComponent.melSpectrogram.progress(optimizing: true))
        ModelBackgroundPreparation.updateTaskProgress(progress, from: ModelPreparationProgress(
            fractionCompleted: nil, detail: "No measured progress"))
        ModelBackgroundPreparation.updateTaskProgress(progress, from: ModelPreparationProgress(
            fractionCompleted: 1, detail: "Ready", stageProgress: (5, 5)))
        XCTAssertEqual(progress.completedUnitCount, 4 * unit)
        XCTAssertFalse(progress.isFinished)
        // Attaching a delayed continued task uses the latest completed milestone.
        let attached = Progress(totalUnitCount: 0)
        ModelBackgroundPreparation.updateTaskProgress(attached, from: ModelPreparationProgress(
            fractionCompleted: nil, detail: "Loading", stageProgress: (3, 5)))
        XCTAssertEqual(attached.completedUnitCount, 3 * unit)
    }

    /// Device logs showed the scheduler expiring a continued task ~46 s after its last progress
    /// change while one Core ML specialization was still running. Heartbeats keep progress moving
    /// inside the running stage without ever claiming the stage or the preparation is done.
    func testHeartbeatAdvancesWithinRunningStageWithoutReachingMilestoneOrCompletion() {
        let unit = ModelBackgroundPreparation.unitsPerStage
        let progress = Progress(totalUnitCount: -1)
        XCTAssertFalse(ModelBackgroundPreparation.advanceHeartbeat(progress),
                       "no heartbeat before the stage layout is known")
        ModelBackgroundPreparation.updateTaskProgress(progress, from: WhisperPreparationComponent.textDecoder.progress(optimizing: true))
        XCTAssertEqual(progress.completedUnitCount, unit)
        XCTAssertTrue(ModelBackgroundPreparation.advanceHeartbeat(progress))
        XCTAssertEqual(progress.completedUnitCount, unit + 1)
        for _ in 0..<(2 * unit) { ModelBackgroundPreparation.advanceHeartbeat(progress) }
        XCTAssertEqual(progress.completedUnitCount, 2 * unit - 1, "a heartbeat never reaches the next milestone")
        XCTAssertFalse(ModelBackgroundPreparation.advanceHeartbeat(progress))
        // The real milestone still jumps to its boundary, and heartbeats then fill the next stage.
        ModelBackgroundPreparation.updateTaskProgress(progress, from: WhisperPreparationComponent.audioEncoder.progress(optimizing: true))
        XCTAssertEqual(progress.completedUnitCount, 2 * unit)
        ModelBackgroundPreparation.updateTaskProgress(progress, from: ModelPreparationProgress(
            fractionCompleted: nil, detail: "Checking", stageProgress: (4, 5)))
        for _ in 0..<(2 * unit) { ModelBackgroundPreparation.advanceHeartbeat(progress) }
        XCTAssertEqual(progress.completedUnitCount, 5 * unit - 1)
        XCTAssertFalse(progress.isFinished, "only finish(success:) completes the system task")
        XCTAssertLessThan(ModelBackgroundPreparation.heartbeatInterval, .seconds(30))
    }

    func testBecomingActiveAsksForContinuedTaskWithoutRestartingPreparation() async throws {
        let background = FakeWhisperBackground()
        let whisper = EngineASR(.whisperLargeV3Turbo)
        await whisper.holdPrepare()
        let provider = FakeEngineProvider()
        provider.queued[.whisperLargeV3Turbo] = [whisper]
        let f = fixture(preferred: .whisperLargeV3Turbo, provider: provider, modelBackground: background)
        f.controller.noteSceneDidBecomeActive()
        try await f.waitUntil { provider.created.count == 1 }
        XCTAssertEqual(background.expirations.count, 1)
        // Returning while the same preparation runs re-requests runtime, not a second load.
        f.controller.noteSceneDidBecomeActive()
        XCTAssertEqual(background.activations, 2)
        XCTAssertEqual(background.expirations.count, 1)
        XCTAssertEqual(provider.created.count, 1)
        XCTAssertEqual(provider.explicitCalls, [.whisperLargeV3Turbo])
        XCTAssertFalse(f.audio.isKeepaliveRunning)
        await whisper.releasePrepare()
    }

    func testSwitchingAwayInvalidatesWhisperExpirationAndMaintenance() async throws {
        let background = FakeWhisperBackground()
        let whisper = EngineASR(.whisperLargeV3Turbo)
        await whisper.holdPrepare()
        let provider = FakeEngineProvider()
        provider.queued[.whisperLargeV3Turbo] = [whisper]
        let f = fixture(preferred: .whisperLargeV3Turbo, provider: provider, modelBackground: background)
        f.controller.noteSceneDidBecomeActive()
        try await f.waitUntil { provider.created.count == 1 }
        let expire = try XCTUnwrap(background.expirations.first)
        XCTAssertEqual(f.controller.selectEngine(.parakeetV2), .selected)
        expire()
        await whisper.releasePrepare()
        try await f.waitUntil { f.controller.phase == .ready }
        XCTAssertEqual(f.controller.currentEngine, .parakeetV2)
        XCTAssertEqual(f.controller.preferredEngine, .parakeetV2)
        XCTAssertEqual(background.maintenance.last, false)
        XCTAssertFalse(f.audio.isKeepaliveRunning)
    }
}

extension SpeechEngineSelectionTests {
    private func parakeetV3Root() -> ParakeetV3ModelStore {
        let root = WhisperTestFiles.makeRoot()
        roots.append(root)
        return ParakeetV3ModelStore(root: root)
    }

    func testParakeetV3RowOffersOnlyItsDownloadUntilInstalled() {
        let missing = row(.parakeetV3, availability: .downloadRequired("Not downloaded"), install: .notInstalled)
        XCTAssertEqual(missing.action, .download)
        XCTAssertEqual(missing.actionTitle, "Download (\(ParakeetV3ModelSpec.downloadSizeLabel))")
        XCTAssertNotEqual(ParakeetV3ModelSpec.downloadSizeLabel, WhisperModelSpec.downloadSizeLabel)
        XCTAssertTrue(missing.note?.contains("Opening Typr prepares the installed, chosen model") == true)
        XCTAssertFalse(missing.note?.contains("Whisper") == true)
        XCTAssertNil(row(.parakeetV3, language: .german).warning, "German is one of its languages")

        let downloading = row(.parakeetV3, install: .downloading(ModelDownloadProgress(completedBytes: 25, totalBytes: 100)))
        XCTAssertEqual(downloading.progress, 0.25)
        XCTAssertEqual(downloading.action, .cancelDownload)
        XCTAssertEqual(row(.parakeetV3, install: .verifying).status, "Checking the downloaded files")
        XCTAssertEqual(row(.parakeetV3, install: .cancelled).action, .retryDownload)
        XCTAssertEqual(row(.parakeetV3, install: .failed("offline")).actionTitle, "Retry")
        XCTAssertEqual(row(.parakeetV3, install: .installed).action, .use)
        XCTAssertEqual(row(.parakeetV3, preferred: .parakeetV3, failure: "Failed").action, .prepare)
        XCTAssertEqual(row(.parakeetV3, preferred: .parakeetV3, install: .notInstalled, failure: "Not downloaded").action,
                       .retryDownload)
    }

    func testLaunchWithParakeetV3ChosenButNotInstalledDoesNotPrepareOrDownload() async throws {
        let store = parakeetV3Root()
        let provider = ProductionSpeechEngineProvider(whisperStore: whisperRoot(), parakeetV3Store: store)
        let background = FakeWhisperBackground()
        let f = fixture(preferred: .parakeetV3, language: .german, autoPrepare: true, provider: provider,
                        modelBackground: background)
        XCTAssertEqual(f.controller.phase, .modelRequired)
        XCTAssertEqual(f.controller.engineName, "Parakeet V3")
        XCTAssertFalse(f.bridge.isModelInstalled)
        f.controller.noteSceneDidBecomeActive()
        XCTAssertTrue(background.engines.isEmpty)
        XCTAssertEqual(background.maintenance.last, false)

        let notInstalled = SpeechEngineError.notInstalled(.parakeetV3).localizedDescription
        f.controller.performPrimaryAction()
        try await f.waitUntil { f.controller.phase == .failed(notInstalled) }
        XCTAssertNil(f.controller.currentEngine)
        XCTAssertEqual(f.controller.preferredEngine, .parakeetV3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.path), "nothing was written for Parakeet V3")
    }

    func testInstalledParakeetV3PreparesOnOpeningWithTheBackgroundRuntime() async throws {
        let background = FakeWhisperBackground()
        let provider = FakeEngineProvider()
        provider.installed = [.parakeetV3]
        let f = fixture(preferred: .parakeetV3, autoPrepare: true, provider: provider,
                        modelBackground: background, deferPreparationUntilActive: true)
        XCTAssertTrue(provider.created.isEmpty)
        f.controller.noteSceneDidBecomeActive()
        f.controller.prepareInstalledModelIfNeeded()
        try await f.waitUntil { f.controller.phase == .ready }
        XCTAssertEqual(provider.explicitCalls, [.parakeetV3])
        XCTAssertEqual(background.engines, [.parakeetV3])
        XCTAssertEqual(background.finishes.last, true)
        XCTAssertEqual(background.maintenance.last, true)
        XCTAssertFalse(f.audio.isKeepaliveRunning)
        XCTAssertEqual(ModelBackgroundPreparation.taskTitle(for: .parakeetV3), "Preparing Parakeet V3")
        XCTAssertEqual(ModelBackgroundPreparation.taskTitle(for: .orukeet), "Preparing Orukeet")
    }

    func testParakeetV3PreparationExpiryNamesTheEngineAndKeepsTheChoice() async throws {
        let background = FakeWhisperBackground()
        let held = EngineASR(.parakeetV3)
        await held.holdPrepare()
        let provider = FakeEngineProvider()
        provider.installed = [.parakeetV3]
        provider.queued[.parakeetV3] = [held]
        let f = fixture(preferred: .parakeetV3, provider: provider, modelBackground: background)
        f.controller.noteSceneDidBecomeActive()
        try await f.waitUntil { provider.created.count == 1 }
        try XCTUnwrap(background.expirations.first)()
        XCTAssertEqual(f.controller.phase, .failed(
            "Parakeet V3 preparation paused. Open Typr or tap Try again to continue. iOS controls background time."))
        XCTAssertEqual(f.controller.preferredEngine, .parakeetV3)
        XCTAssertTrue(provider.automaticCalls.isEmpty)
        await held.releasePrepare()
    }

    func testParakeetV3StagesDriveTheContinuedTaskLikeWhisper() {
        typealias B = ModelBackgroundPreparation
        let progress = Progress(totalUnitCount: -1)
        for component in TdtV3PreparationComponent.allCases {
            let update = component.progress(engine: .parakeetV3, optimizing: true)
            XCTAssertEqual(B.taskSubtitle(for: update), "Optimizing for this iPhone")
            XCTAssertEqual(B.taskSubtitle(for: component.progress(engine: .parakeetV3, optimizing: false)), "Loading model")
            B.updateTaskProgress(progress, from: update)
            XCTAssertEqual(progress.completedUnitCount, (update.stageProgress?.completed ?? -1) * B.unitsPerStage)
        }
        XCTAssertEqual(B.taskSubtitle(for: ModelPreparationProgress(
            fractionCompleted: nil, detail: "Checking the Parakeet V3 model", stageProgress: (4, 5))), "Checking model")
    }

    func testDictationLogRecordsParakeetV3AndTheCapturesLanguage() async throws {
        let env = LogTestEnvironment()
        logEnvironments.append(env)
        try await LogTestEnvironment.waitUntilLoaded(env.store)
        let provider = FakeEngineProvider()
        provider.installed = [.parakeetV3]
        let f = fixture(preferred: .parakeetV3, language: .german, provider: provider, dictationLog: env.store)
        try await f.ready()
        _ = try await f.dictate(jobID: "v3-1")
        f.controller.setDictationLanguage(.automatic)
        _ = try await f.dictate(jobID: "v3-2")

        let contexts = env.store.entries.map(\.context)
        XCTAssertEqual(contexts.count, 2)
        XCTAssertEqual(Set(contexts.map(\.speechEngine)), ["Parakeet V3"])
        XCTAssertEqual(Set(contexts.map(\.speechLanguage)), ["German", "Automatic (detected by Parakeet V3)"])
        let languages = await provider.instances(of: .parakeetV3).first?.languages
        XCTAssertEqual(languages, [.german, .automatic], "each capture passes its own language")
    }
}

extension SpeechEngineSelectionTests {
    func testRowsOfferDeleteOnlyForModelsOnThisIPhone() {
        XCTAssertTrue(row(.parakeetV3, install: .installed).offersDelete)
        XCTAssertTrue(row(.whisperLargeV3Turbo, install: .installed).offersDelete)
        XCTAssertFalse(row(.parakeetV3, availability: .downloadRequired("Not downloaded"), install: .notInstalled).offersDelete)
        XCTAssertFalse(row(.whisperLargeV3Turbo, install: .downloading(ModelDownloadProgress(completedBytes: 1, totalBytes: 2)))
            .offersDelete)
        XCTAssertFalse(row(.whisperLargeV3Turbo, install: .cancelled).offersDelete)
        XCTAssertTrue(row(.parakeetV2, availability: .installed).offersDelete)
        XCTAssertFalse(row(.parakeetV2, availability: .downloadRequired("Not downloaded")).offersDelete)
        XCTAssertFalse(row(.appleSpeech, availability: .installed).offersDelete, "iOS manages Apple Speech's assets")
        XCTAssertTrue(row(.parakeetV3, current: .parakeetV3, install: .installed).offersDelete)
        XCTAssertTrue(row(.parakeetV3, install: .installed).deleteEnabled)
        XCTAssertFalse(row(.parakeetV3, install: .installed, canChange: false).deleteEnabled)
        XCTAssertTrue(SpeechEngineCard.deletionMessage(for: .parakeetV2).contains("downloads it again the next time you use it"))
        XCTAssertTrue(SpeechEngineCard.deletionMessage(for: .parakeetV3).contains("Your engine choice stays"))
    }

    func testDeletingTheCurrentModelReleasesItEndsTheWarmSessionAndKeepsTheChoice() async throws {
        let provider = FakeEngineProvider()
        provider.installed = [.parakeetV3]
        let f = fixture(preferred: .parakeetV3, provider: provider)
        try await f.ready()
        f.controller.toggleWarmSession()
        try await f.waitUntil { f.controller.phase != .requestingPermission }
        XCTAssertTrue(f.controller.keyboardSessionEnabled)
        XCTAssertTrue(f.bridge.isModelInstalled)

        let result = await f.controller.deleteModel(.parakeetV3)
        XCTAssertEqual(result, .deleted)
        XCTAssertEqual(provider.deleted, [.parakeetV3])
        XCTAssertFalse(f.controller.keyboardSessionEnabled)
        XCTAssertFalse(f.audio.isKeepaliveRunning)
        XCTAssertNil(f.controller.currentEngine)
        XCTAssertFalse(f.controller.isModelReady)
        XCTAssertEqual(f.controller.phase, .modelRequired)
        XCTAssertEqual(f.controller.preferredEngine, .parakeetV3)
        XCTAssertEqual(f.storedPreferenceRaw, "parakeet-v3")
        XCTAssertFalse(f.bridge.isModelInstalled)
        XCTAssertTrue(provider.automaticCalls.isEmpty)
        XCTAssertEqual(provider.explicitCalls, [.parakeetV3], "nothing else is prepared")
    }

    func testDeletingAnotherEnginesModelKeepsTheReadyEngine() async throws {
        let f = fixture(preferred: .parakeetV2)
        try await f.ready()
        let result = await f.controller.deleteModel(.whisperLargeV3Turbo)
        XCTAssertEqual(result, .deleted)
        XCTAssertEqual(f.fake.deleted, [.whisperLargeV3Turbo])
        XCTAssertEqual(f.controller.currentEngine, .parakeetV2)
        XCTAssertEqual(f.controller.phase, .ready)
        XCTAssertTrue(f.bridge.isModelInstalled)
        let text = try await f.dictate()
        XCTAssertFalse(text.isEmpty)
    }

    func testDeletingWaitsForThatEnginesPreparationAndNeverPublishesItReady() async throws {
        let held = EngineASR(.parakeetV2)
        await held.holdPrepare()
        let f = fixture(preferred: .parakeetV2)
        f.fake.queued[.parakeetV2] = [held]
        f.controller.prepareModel()
        for _ in 0..<100 {
            if await held.prepareCount == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let deletion = Task { await f.controller.deleteModel(.parakeetV2) }
        try await f.waitUntil { f.controller.isDeletingModel }
        XCTAssertFalse(f.controller.canChangeEngine)
        XCTAssertTrue(f.fake.deleted.isEmpty, "files stay until the running load returns")
        await held.releasePrepare()
        let result = await deletion.value
        XCTAssertEqual(result, .deleted)
        XCTAssertEqual(f.fake.deleted, [.parakeetV2])
        XCTAssertEqual(f.controller.phase, .modelRequired)
        XCTAssertNil(f.controller.currentEngine)
        XCTAssertEqual(f.controller.preferredEngine, .parakeetV2)
        XCTAssertTrue(f.controller.canChangeEngine)
    }

    func testDeleteIsRefusedDuringDictationAndForAppleSpeech() async throws {
        let f = fixture(preferred: .parakeetV3)
        f.fake.installed.insert(.parakeetV3)
        try await f.ready()
        f.controller.startRecording(keyboardJobID: "busy")
        try await f.waitUntil { f.controller.phase == .recording }
        let busy = await f.controller.deleteModel(.parakeetV3)
        XCTAssertEqual(busy, .busy)
        f.controller.finishRecording()
        try await f.waitUntil { f.controller.phase != .transcribing && f.controller.canChangeEngine }
        let apple = await f.controller.deleteModel(.appleSpeech)
        XCTAssertEqual(apple, .notDeletable)
        XCTAssertTrue(f.fake.deleted.isEmpty)
        XCTAssertEqual(f.controller.currentEngine, .parakeetV3)
    }

    func testFailedDeletionIsReportedAndKeepsTheChoice() async throws {
        struct Locked: LocalizedError { var errorDescription: String? { "File is locked." } }
        let f = fixture(preferred: .whisperLargeV3Turbo)
        try await f.ready()
        f.fake.deleteFailure = Locked()
        let result = await f.controller.deleteModel(.whisperLargeV3Turbo)
        XCTAssertEqual(result, .failed("File is locked."))
        XCTAssertEqual(f.controller.preferredEngine, .whisperLargeV3Turbo)
        XCTAssertFalse(f.controller.isDeletingModel)
    }

    func testProductionDeleteRemovesOnlyThatEnginesFilesAndTheChoiceThenFailsAsNotDownloaded() async throws {
        let v3 = ParakeetV3ModelStore(root: WhisperTestFiles.makeRoot())
        let whisper = whisperRoot()
        let v2Cache = WhisperTestFiles.makeRoot().appendingPathComponent("parakeet-tdt-0.6b-v2-coreml")
        roots += [v3.root, v2Cache.deletingLastPathComponent()]
        try ParakeetV3TestFiles.populate(v3, marker: true)
        let partial = v3.repoFolder(ParakeetV3ModelSpec.modelRepo).appendingPathComponent("Encoder.mlmodelc/weights/weight.bin.incomplete")
        try WhisperTestFiles.writeSparse(partial, bytes: 1_000)
        try WhisperTestFiles.populate(whisper, marker: true)
        try WhisperTestFiles.writeSparse(v2Cache.appendingPathComponent("Encoder.mlmodelc/weights/weight.bin.partial"), bytes: 10)
        let provider = ProductionSpeechEngineProvider(whisperStore: whisper, parakeetV3Store: v3, parakeetV2Cache: v2Cache)
        let installer = ParakeetV3ModelInstaller(store: v3, downloader: CountingDownloader(), availableCapacity: { .max })
        XCTAssertEqual(installer.state, .installed)

        let f = fixture(preferred: .parakeetV3, provider: provider)
        let result = await f.controller.deleteModel(.parakeetV3)
        XCTAssertEqual(result, .deleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: v3.root.path), "files and partial downloads are gone")
        XCTAssertFalse(provider.isInstalled(.parakeetV3))
        XCTAssertTrue(whisper.isInstalled, "another engine's model is untouched")
        installer.refresh()
        XCTAssertEqual(installer.state, .notInstalled, "the row returns to Download")
        XCTAssertFalse(f.bridge.isModelInstalled)

        let notInstalled = SpeechEngineError.notInstalled(.parakeetV3).localizedDescription
        f.controller.performPrimaryAction()
        try await f.waitUntil { f.controller.phase == .failed(notInstalled) }
        XCTAssertEqual(f.controller.preferredEngine, .parakeetV3)

        try provider.deleteModel(.parakeetV2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: v2Cache.path))
        try provider.deleteModel(.appleSpeech)
        XCTAssertTrue(whisper.isInstalled)
    }

    func testDeletingAfterAPausedPreparationWaitsForItsRunningLoad() async throws {
        let background = FakeWhisperBackground()
        let held = EngineASR(.parakeetV3)
        await held.holdPrepare()
        let provider = FakeEngineProvider()
        provider.installed = [.parakeetV3]
        provider.queued[.parakeetV3] = [held]
        let f = fixture(preferred: .parakeetV3, provider: provider, modelBackground: background)
        f.controller.noteSceneDidBecomeActive()
        for _ in 0..<100 {
            if await held.prepareCount == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try XCTUnwrap(background.expirations.first)()
        XCTAssertTrue(f.controller.phase.isFailure)
        let deletion = Task { await f.controller.deleteModel(.parakeetV3) }
        try await f.waitUntil { f.controller.isDeletingModel }
        await mainActorBarrier()
        XCTAssertTrue(provider.deleted.isEmpty, "the paused load still holds the files")
        await held.releasePrepare()
        let result = await deletion.value
        XCTAssertEqual(result, .deleted)
        XCTAssertEqual(provider.deleted, [.parakeetV3])
        XCTAssertEqual(f.controller.phase, .modelRequired)
        XCTAssertEqual(f.controller.preferredEngine, .parakeetV3)
    }

    func testDeletingParakeetV2LeavesAnAutomaticAppleSpeechPreparationRunning() async throws {
        let apple = EngineASR(.appleSpeech)
        await apple.holdPrepare()
        let provider = FakeEngineProvider()
        provider.queued[.appleSpeech] = [apple]
        let f = fixture(provider: provider)
        f.controller.prepareModel()
        try await f.waitUntil { f.controller.engineName == "Apple Speech" }
        let result = await f.controller.deleteModel(.parakeetV2)
        XCTAssertEqual(result, .deleted)
        XCTAssertEqual(f.controller.phase, .preparingModel)
        await apple.releasePrepare()
        try await f.waitUntil { f.controller.phase == .ready }
        XCTAssertEqual(f.controller.currentEngine, .appleSpeech)
        XCTAssertNil(f.controller.preferredEngine)
    }

    func testDeletingWaitsForASupersededLoadOfThatEngine() async throws {
        let held = EngineASR(.parakeetV3)
        await held.holdPrepare()
        let provider = FakeEngineProvider()
        provider.installed = [.parakeetV3, .whisperLargeV3Turbo]
        provider.queued[.parakeetV3] = [held]
        let f = fixture(preferred: .parakeetV3, provider: provider)
        f.controller.prepareModel()
        for _ in 0..<100 {
            if await held.prepareCount == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(f.controller.selectEngine(.whisperLargeV3Turbo), .selected)
        let deletion = Task { await f.controller.deleteModel(.parakeetV3) }
        try await f.waitUntil { f.controller.isDeletingModel }
        await mainActorBarrier()
        XCTAssertTrue(provider.deleted.isEmpty, "the superseded load still holds the files")
        await held.releasePrepare()
        let result = await deletion.value
        XCTAssertEqual(result, .deleted)
        XCTAssertEqual(provider.deleted, [.parakeetV3])
        try await f.waitUntil { f.controller.phase == .ready }
        XCTAssertEqual(f.controller.currentEngine, .whisperLargeV3Turbo)
        XCTAssertEqual(f.controller.preferredEngine, .whisperLargeV3Turbo)
    }

    func testKeyboardLaunchDuringDeletionIsAnsweredWhenItEnds() async throws {
        let held = EngineASR(.parakeetV3)
        await held.holdPrepare()
        let provider = FakeEngineProvider()
        provider.installed = [.parakeetV3]
        provider.queued[.parakeetV3] = [held]
        let f = fixture(preferred: .parakeetV3, provider: provider)
        f.controller.prepareModel()
        for _ in 0..<100 {
            if await held.prepareCount == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let deletion = Task { await f.controller.deleteModel(.parakeetV3) }
        try await f.waitUntil { f.controller.isDeletingModel }
        f.controller.handleKeyboardLaunch(.startRecording(jobID: "kb-delete", requestedAt: f.now, style: .polished, host: nil))
        XCTAssertEqual(provider.explicitCalls, [.parakeetV3], "no preparation starts during the deletion")
        provider.errors[.parakeetV3] = .notInstalled(.parakeetV3)
        await held.releasePrepare()
        _ = await deletion.value

        let notInstalled = SpeechEngineError.notInstalled(.parakeetV3).localizedDescription
        try await f.waitUntil { f.controller.phase == .failed(notInstalled) }
        XCTAssertEqual(provider.explicitCalls, [.parakeetV3, .parakeetV3])
        XCTAssertEqual(f.bridge.snapshot().state, .failed)
        XCTAssertEqual(f.bridge.snapshot().message, notInstalled)
        XCTAssertTrue(f.audio.captures.isEmpty)
        XCTAssertEqual(f.controller.preferredEngine, .parakeetV3)
    }
}

extension SpeechEngineSelectionTests {
    func testOrukeetRowOffersOnlyItsDownloadUntilInstalled() {
        let missing = row(.orukeet, availability: .downloadRequired("Not downloaded"), install: .notInstalled)
        XCTAssertEqual(missing.action, .download)
        XCTAssertEqual(missing.actionTitle, "Download (\(OrukeetModelSpec.downloadSizeLabel))")
        XCTAssertNotEqual(OrukeetModelSpec.downloadSizeLabel, ParakeetV3ModelSpec.downloadSizeLabel)
        XCTAssertTrue(missing.note?.contains("Opening Typr prepares the installed, chosen model") == true)
        XCTAssertNil(row(.orukeet, language: .german).warning, "German is one of its languages")

        let downloading = row(.orukeet, install: .downloading(ModelDownloadProgress(completedBytes: 25, totalBytes: 100)))
        XCTAssertEqual(downloading.progress, 0.25)
        XCTAssertEqual(downloading.action, .cancelDownload)
        XCTAssertEqual(row(.orukeet, install: .cancelled).action, .retryDownload)
        XCTAssertEqual(row(.orukeet, install: .failed("offline")).actionTitle, "Retry")
        XCTAssertEqual(row(.orukeet, install: .installed).action, .use)
        XCTAssertTrue(row(.orukeet, install: .installed).offersDelete)
        XCTAssertFalse(missing.offersDelete)
        XCTAssertFalse(downloading.offersDelete)
        XCTAssertEqual(row(.orukeet, preferred: .orukeet, install: .notInstalled, failure: "Not downloaded").action,
                       .retryDownload)
    }

    func testLaunchWithOrukeetChosenButNotInstalledDoesNotPrepareOrDownload() async throws {
        let root = WhisperTestFiles.makeRoot()
        roots.append(root)
        let store = OrukeetModelStore(root: root)
        let provider = ProductionSpeechEngineProvider(whisperStore: whisperRoot(), orukeetStore: store)
        let background = FakeWhisperBackground()
        let f = fixture(preferred: .orukeet, language: .german, autoPrepare: true, provider: provider,
                        modelBackground: background)
        XCTAssertEqual(f.controller.phase, .modelRequired)
        XCTAssertEqual(f.controller.engineName, "Orukeet")
        XCTAssertFalse(f.bridge.isModelInstalled)
        f.controller.noteSceneDidBecomeActive()
        XCTAssertTrue(background.engines.isEmpty)

        let notInstalled = SpeechEngineError.notInstalled(.orukeet).localizedDescription
        f.controller.performPrimaryAction()
        try await f.waitUntil { f.controller.phase == .failed(notInstalled) }
        XCTAssertNil(f.controller.currentEngine)
        XCTAssertEqual(f.controller.preferredEngine, .orukeet)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.path), "nothing was written for Orukeet")
    }

    func testDictationLogRecordsOrukeetWithItsAutomaticLanguage() async throws {
        let env = LogTestEnvironment()
        logEnvironments.append(env)
        try await LogTestEnvironment.waitUntilLoaded(env.store)
        let provider = FakeEngineProvider()
        provider.installed = [.orukeet]
        let f = fixture(preferred: .orukeet, language: .german, provider: provider, dictationLog: env.store)
        try await f.ready()
        _ = try await f.dictate(jobID: "orukeet-1")

        let context = try XCTUnwrap(env.store.entries.first?.context)
        XCTAssertEqual(context.speechEngine, "Orukeet")
        XCTAssertEqual(context.speechLanguage, "Automatic (detected by Orukeet)")
    }

    func testProductionDeleteRemovesOrukeetsModelArchiveAndStagingButKeepsTheChoice() async throws {
        let root = WhisperTestFiles.makeRoot()
        roots.append(root)
        let store = OrukeetModelStore(root: root)
        let v3 = ParakeetV3ModelStore(root: root.appendingPathComponent("v3"))
        try OrukeetTestFiles.populateCompiled(store)
        try store.writeMarker()
        try WhisperTestFiles.writeSparse(store.fileURL(for: OrukeetModelSpec.archive), bytes: 1_000)
        try WhisperTestFiles.writeSparse(
            store.repoFolder(OrukeetModelSpec.modelRepo).appending(path: "unpacking/packages/Encoder.mlpackage/Manifest.json"),
            bytes: 10)
        try ParakeetV3TestFiles.populate(v3, marker: true)
        let provider = ProductionSpeechEngineProvider(whisperStore: whisperRoot(), parakeetV3Store: v3, orukeetStore: store)
        let installer = OrukeetModelInstaller(store: store, downloader: CountingDownloader(), availableCapacity: { .max })
        XCTAssertEqual(installer.state, .installed)

        let f = fixture(preferred: .orukeet, provider: provider)
        let result = await f.controller.deleteModel(.orukeet)
        XCTAssertEqual(result, .deleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.modelFolder.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(for: OrukeetModelSpec.archive).path),
                       "a partial archive download is gone too")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.markerURL.path))
        XCTAssertFalse(provider.isInstalled(.orukeet))
        installer.refresh()
        XCTAssertEqual(installer.state, .notInstalled, "the row returns to Download")
        XCTAssertFalse(f.bridge.isModelInstalled)
        XCTAssertEqual(f.controller.preferredEngine, .orukeet)

        let notInstalled = SpeechEngineError.notInstalled(.orukeet).localizedDescription
        f.controller.performPrimaryAction()
        try await f.waitUntil { f.controller.phase == .failed(notInstalled) }
        XCTAssertEqual(f.controller.preferredEngine, .orukeet)
    }
}

extension SpeechEngineSelectionTests {
    func testCohereRowOffersOnlyItsDownloadUntilInstalledThenDelete() {
        let missing = row(.cohereTranscribe, availability: .downloadRequired("Not downloaded"), install: .notInstalled)
        XCTAssertEqual(missing.action, .download)
        XCTAssertEqual(missing.actionTitle, "Download (\(CohereModelSpec.downloadSizeLabel))")
        XCTAssertFalse(missing.offersDelete)
        XCTAssertTrue(missing.note?.contains("Opening Typr prepares the installed, chosen model") == true)
        XCTAssertNil(row(.cohereTranscribe, language: .german).warning, "German is one of its languages")

        let downloading = row(.cohereTranscribe, install: .downloading(ModelDownloadProgress(completedBytes: 25, totalBytes: 100)))
        XCTAssertEqual(downloading.progress, 0.25)
        XCTAssertEqual(downloading.action, .cancelDownload)
        XCTAssertEqual(row(.cohereTranscribe, install: .verifying).status, "Checking the downloaded files")
        XCTAssertEqual(row(.cohereTranscribe, install: .cancelled).action, .retryDownload)
        XCTAssertEqual(row(.cohereTranscribe, install: .failed("offline")).actionTitle, "Retry")
        XCTAssertEqual(row(.cohereTranscribe, install: .installed).action, .use)
        XCTAssertTrue(row(.cohereTranscribe, install: .installed).offersDelete)
        XCTAssertEqual(row(.cohereTranscribe, preferred: .cohereTranscribe, install: .notInstalled,
                           failure: "Not downloaded").action, .retryDownload)
        XCTAssertTrue(SpeechEngineCard.deletionMessage(for: .cohereTranscribe).contains("Your engine choice stays"))
    }

    func testLaunchWithCohereChosenButNotInstalledDoesNotPrepareOrDownload() async throws {
        let store = CohereModelStore(root: WhisperTestFiles.makeRoot())
        roots.append(store.root)
        let provider = ProductionSpeechEngineProvider(whisperStore: whisperRoot(), cohereStore: store)
        let background = FakeWhisperBackground()
        let f = fixture(preferred: .cohereTranscribe, language: .german, autoPrepare: true, provider: provider,
                        modelBackground: background)
        XCTAssertEqual(f.controller.phase, .modelRequired)
        XCTAssertEqual(f.controller.engineName, "Cohere Transcribe")
        XCTAssertFalse(f.bridge.isModelInstalled)
        f.controller.noteSceneDidBecomeActive()
        XCTAssertTrue(background.engines.isEmpty)

        let notInstalled = SpeechEngineError.notInstalled(.cohereTranscribe).localizedDescription
        f.controller.performPrimaryAction()
        try await f.waitUntil { f.controller.phase == .failed(notInstalled) }
        XCTAssertNil(f.controller.currentEngine)
        XCTAssertEqual(f.controller.preferredEngine, .cohereTranscribe)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.path), "nothing was written for Cohere")
    }

    func testDictationLogRecordsCohereAndTheLanguageItWasGiven() async throws {
        let env = LogTestEnvironment()
        logEnvironments.append(env)
        try await LogTestEnvironment.waitUntilLoaded(env.store)
        let provider = FakeEngineProvider()
        provider.installed = [.cohereTranscribe]
        let f = fixture(preferred: .cohereTranscribe, language: .german, provider: provider, dictationLog: env.store)
        try await f.ready()
        _ = try await f.dictate(jobID: "cohere-1")
        f.controller.setDictationLanguage(.automatic)
        _ = try await f.dictate(jobID: "cohere-2")

        let contexts = env.store.entries.map(\.context)
        XCTAssertEqual(contexts.count, 2)
        XCTAssertEqual(Set(contexts.map(\.speechEngine)), ["Cohere Transcribe"])
        XCTAssertEqual(Set(contexts.map(\.speechLanguage)), ["German", CohereTranscriber.languageName(for: .automatic)])
        let languages = await provider.instances(of: .cohereTranscribe).first?.languages
        XCTAssertEqual(languages, [.german, .automatic], "each capture passes its own language")
    }
}
