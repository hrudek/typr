import AVFAudio
import XCTest
@testable import Typr

@MainActor
private final class FakeAudioCapture: ActiveAudioCapture {
    let url: URL
    var isRecording = true
    var currentTime: TimeInterval
    var power: Float = 0.6

    init(url: URL, initialDuration: TimeInterval = 1.2) {
        self.url = url
        self.currentTime = initialDuration
        FileManager.default.createFile(atPath: url.path, contents: Data("wav".utf8))
    }

    func normalizedPowerLevel() -> Float {
        power
    }

    func stop() {
        isRecording = false
    }
}

@MainActor
private final class FakeAudioManager: AudioManaging {
    var isKeepaliveRunning = false
    var isOtherAudioPlaying = false
    var permissionGranted = true
    var keepaliveShouldThrow = false
    /// False models Typr in the background: iOS refuses to start microphone input there,
    /// though input that is already running keeps going.
    var canStartInput = true
    /// Activations iOS refuses before one succeeds, as right after another app's audio ends.
    var busyActivationsRemaining = 0
    var captureShouldThrow = false
    static let busyError = NSError(domain: NSOSStatusErrorDomain, code: 0x2170_6C61) // '!pla'
    var startKeepaliveCount = 0
    var nextCaptureDuration: TimeInterval = 1.4
    var nextCaptureIsRecording = true
    var deactivateCount = 0
    var createdCaptures: [FakeAudioCapture] = []

    var onSystemEvent: ((AudioSystemEvent) -> Void)?
    var onUnexpectedCaptureEnd: ((URL, Bool) -> Void)?

    func requestPermission() async -> Bool {
        permissionGranted
    }

    func startKeepalive(allowBluetooth: Bool) throws {
        startKeepaliveCount += 1
        if busyActivationsRemaining > 0 {
            busyActivationsRemaining -= 1
            isKeepaliveRunning = false
            throw Self.busyError
        }
        if keepaliveShouldThrow || !canStartInput {
            isKeepaliveRunning = false
            throw CocoaError(.coderInvalidValue)
        }
        isKeepaliveRunning = true
        // Activating input interrupts media, so subsequent queries no longer see it.
        isOtherAudioPlaying = false
    }

    func stopKeepalive() {
        isKeepaliveRunning = false
    }

    func deactivateSession() {
        isKeepaliveRunning = false
        deactivateCount += 1
    }

    func beginCapture(
        at url: URL,
        maxDuration: TimeInterval,
        allowBluetooth: Bool
    ) throws -> any ActiveAudioCapture {
        // Captures record from the keepalive input, starting it when it isn't running.
        try ensureKeepalive(allowBluetooth: allowBluetooth)
        if captureShouldThrow {
            throw CocoaError(.fileWriteUnknown)
        }
        let capture = FakeAudioCapture(url: url, initialDuration: nextCaptureDuration)
        capture.isRecording = nextCaptureIsRecording
        createdCaptures.append(capture)
        return capture
    }
}

private actor ControlledTranscriber: LocalTranscribing {
    nonisolated let displayName = "Controlled Speech"
    let languageName = "English"

    private var gate: CheckedContinuation<String, Error>?
    private var pendingResume: String?
    private var cannedOutput = "ship the build"
    private(set) var transcribedURLs: [URL] = []
    private(set) var vocabularyArguments: [[String]] = []
    private var suspendNext = false

    func armSuspension() {
        suspendNext = true
        pendingResume = nil
    }

    func setCannedOutput(_ text: String) {
        cannedOutput = text
    }

    func resumeSuspended(with text: String) {
        if let continuation = gate {
            gate = nil
            continuation.resume(returning: text)
        } else {
            pendingResume = text
        }
    }

    func prepare(progressHandler: @escaping @Sendable (ModelPreparationProgress) -> Void) async throws {
        progressHandler(ModelPreparationProgress(fractionCompleted: 1, detail: "Ready"))
    }

    func transcribe(_ audioURL: URL) async throws -> String {
        transcribedURLs.append(audioURL)
        if suspendNext {
            suspendNext = false
            if let early = pendingResume {
                pendingResume = nil
                return early
            }
            return try await withCheckedThrowingContinuation { continuation in
                gate = continuation
            }
        }
        return cannedOutput
    }

    func transcribe(_ audioURL: URL, vocabulary: [String]) async throws -> String {
        vocabularyArguments.append(vocabulary)
        return try await transcribe(audioURL)
    }
}

@MainActor
final class DictationControllerTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "typr.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testStaleTranscriptionAfterSessionEndCannotClobberNewerCaptureOrDeleteItsFile() async throws {
        let now = 1_000.0
        let audio = FakeAudioManager()
        let transcriber = ControlledTranscriber()
        let bridge = KeyboardBridge(defaults: defaults)

        let controller = DictationController(
            audio: audio,
            keyboardBridge: bridge,
            transcriber: transcriber,
            transcriberFactory: { transcriber },
            now: { now },
            autoPrepareOnInit: false
        )
        controller.prepareModel()
        try await settle()
        XCTAssertEqual(controller.phase, .ready)

        // Start Job A and suspend its transcription in-flight.
        await transcriber.armSuspension()
        controller.toggleWarmSession()
        try await settle()
        XCTAssertTrue(controller.keyboardSessionEnabled)

        bridge.send(.start, jobID: "job-a", style: .polished, sentAt: now)
        controller.processPendingKeyboardCommandForTesting()
        try await settle()
        XCTAssertEqual(controller.phase, .recording)
        let firstCaptureURL = try XCTUnwrap(audio.createdCaptures.first?.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstCaptureURL.path))

        controller.finishRecording()
        XCTAssertEqual(controller.phase, .transcribing)
        try await settle()

        // Expire / end the warm session while Job A is still transcribing, then start a new capture Job B!
        controller.endWarmSession()
        XCTAssertFalse(controller.keyboardSessionEnabled)

        controller.startRecording(keyboardJobID: "job-b")
        try await settle()
        XCTAssertEqual(controller.phase, .recording)
        let secondCaptureURL = try XCTUnwrap(audio.createdCaptures.last?.url)
        XCTAssertNotEqual(firstCaptureURL, secondCaptureURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondCaptureURL.path))

        // Complete stale Job A: it must clean up ONLY firstCaptureURL and leave Job B recording untouched!
        await transcriber.resumeSuspended(with: "stale transcript")
        try await settle()

        XCTAssertFalse(FileManager.default.fileExists(atPath: firstCaptureURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondCaptureURL.path))
        XCTAssertEqual(controller.phase, .recording)
        XCTAssertEqual(controller.transcript, "")

        controller.cancelCurrentJob()
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondCaptureURL.path))
    }

    func testAcceptedJobDeliversTranscriptEvenWhenWarmSessionCloses() async throws {
        let now = 2_000.0
        let audio = FakeAudioManager()
        let transcriber = ControlledTranscriber()
        await transcriber.armSuspension()
        let bridge = KeyboardBridge(defaults: defaults)

        let controller = DictationController(
            audio: audio,
            keyboardBridge: bridge,
            transcriber: transcriber,
            transcriberFactory: { transcriber },
            now: { now },
            autoPrepareOnInit: false,
            hostReturner: HostReturner(openByBundleID: { _ in false }, openURL: { _ in false })
        )
        controller.prepareModel()
        try await settle()

        controller.setWarmDuration(.off)
        // Very casual preserves this regression's lowercase output after the Casual style split.
        controller.handleKeyboardLaunch(
            .startRecording(jobID: "one-shot-job", requestedAt: now, style: .veryCasual, host: nil)
        )
        try await settle()
        XCTAssertEqual(controller.phase, .recording)

        // Finishing capture in one-shot mode immediately releases the mic while transcription completes.
        controller.finishRecording()
        XCTAssertEqual(controller.phase, .transcribing)
        XCTAssertFalse(controller.keyboardSessionEnabled)
        XCTAssertGreaterThan(audio.deactivateCount, 0)
        try await settle()

        await transcriber.resumeSuspended(with: "Um, Ship It Tonight.")
        try await settle()

        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(controller.transcript, "ship it tonight")
        let snap = bridge.snapshot()
        XCTAssertTrue(snap.hasDeliverableResult(at: now + 1))
        XCTAssertEqual(snap.transcript, "ship it tonight")
    }

    func testTenSecondHandoffWindowAndAutoReturnBehavior() async throws {
        var now = 5_000.0
        let audio = FakeAudioManager()
        let transcriber = ControlledTranscriber()
        let bridge = KeyboardBridge(defaults: defaults)
        var openedBundleIDs: [String] = []
        var openedURLs: [URL] = []

        let controller = DictationController(
            audio: audio,
            keyboardBridge: bridge,
            transcriber: transcriber,
            transcriberFactory: { transcriber },
            now: { now },
            autoPrepareOnInit: false,
            hostReturner: HostReturner(
                openByBundleID: { id in
                    openedBundleIDs.append(id)
                    return id == "com.openai.chat"
                },
                openURL: { url in
                    openedURLs.append(url)
                    return url.scheme == "ichat"
                }
            )
        )
        controller.prepareModel()
        try await settle()

        // 1. Expired (>10s) handoff warms session without surprise-recording or returning.
        controller.handleKeyboardLaunch(
            .startRecording(jobID: "expired-job", requestedAt: now - 11.5, style: .polished, host: "com.openai.chat")
        )
        try await settle()
        XCTAssertTrue(controller.keyboardSessionEnabled)
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertNotNil(controller.handoffNotice)
        XCTAssertTrue(openedBundleIDs.isEmpty)
        XCTAssertTrue(openedURLs.isEmpty)

        // 2. Fresh handoff starts recording and returns to the host by bundle ID first.
        now += 1
        controller.handleKeyboardLaunch(
            .startRecording(jobID: "fresh-job", requestedAt: now - 0.4, style: .polished, host: "com.openai.chat")
        )
        try await settle()
        XCTAssertEqual(controller.phase, .recording)
        XCTAssertEqual(openedBundleIDs, ["com.openai.chat"])
        XCTAssertTrue(openedURLs.isEmpty)
        XCTAssertEqual(controller.autoReturnState, .attempting)
        controller.noteSceneDidEnterBackground()
        XCTAssertEqual(controller.autoReturnState, .succeeded)

        // 3. When opening by bundle ID fails, the host's own resuming URL is used.
        controller.cancelCurrentJob()
        now += 1
        controller.handleKeyboardLaunch(
            .startRecording(jobID: "scheme-job", requestedAt: now - 0.2, style: .polished, host: "com.apple.MobileSMS")
        )
        try await settle()
        XCTAssertEqual(openedBundleIDs.last, "com.apple.MobileSMS")
        XCTAssertEqual(openedURLs.map(\.absoluteString), ["ichat://"])
        XCTAssertEqual(controller.autoReturnState, .attempting)

        // 4. An app with neither way back falls back to the swipe cue.
        controller.cancelCurrentJob()
        now += 1
        controller.handleKeyboardLaunch(
            .startRecording(jobID: "unknown-job", requestedAt: now - 0.2, style: .polished, host: "com.example.noscheme")
        )
        try await settle()
        XCTAssertEqual(openedBundleIDs.last, "com.example.noscheme")
        XCTAssertEqual(openedURLs.count, 1)
        XCTAssertEqual(controller.autoReturnState, .swipeFallback)

        // 5. A host the keyboard could not name gets the swipe cue without opening anything.
        controller.cancelCurrentJob()
        now += 1
        let opensBefore = openedBundleIDs.count
        controller.handleKeyboardLaunch(
            .startRecording(jobID: "nameless-job", requestedAt: now - 0.2, style: .polished, host: nil)
        )
        try await settle()
        XCTAssertEqual(openedBundleIDs.count, opensBefore)
        XCTAssertEqual(controller.autoReturnState, .swipeFallback)

        // 6. A field inside Typr itself needs no return.
        controller.cancelCurrentJob()
        now += 1
        controller.handleKeyboardLaunch(
            .startRecording(jobID: "self-job", requestedAt: now - 0.2, style: .polished, host: HostReturnCatalog.typrBundleID)
        )
        try await settle()
        XCTAssertEqual(openedBundleIDs.count, opensBefore)
        XCTAssertEqual(controller.autoReturnState, .idle)
        controller.cancelCurrentJob()
    }

    func testAudioInterruptionsAndRouteChangesNeverLeaveStuckListeningState() async throws {
        let now = 8_000.0
        let audio = FakeAudioManager()
        let transcriber = ControlledTranscriber()
        await transcriber.setCannedOutput("saved before call")
        let bridge = KeyboardBridge(defaults: defaults)

        let controller = DictationController(
            audio: audio,
            keyboardBridge: bridge,
            transcriber: transcriber,
            transcriberFactory: { transcriber },
            now: { now },
            autoPrepareOnInit: false
        )
        controller.prepareModel()
        try await settle()
        controller.toggleWarmSession()
        try await settle()

        // Long capture (>= 0.3s) interrupted by phone call saves and transcribes spoken words!
        audio.nextCaptureDuration = 2.1
        controller.startRecording(keyboardJobID: "call-job")
        try await settle()
        XCTAssertEqual(controller.phase, .recording)

        controller.handleAudioSystemEvent(.interruptionBegan)
        try await settle()
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(controller.transcript, "Saved before call.")
        XCTAssertNotEqual(bridge.snapshot().state, .recording)

        // Short capture (< 0.3s) interrupted cancels cleanly out of recording.
        audio.nextCaptureDuration = 0.1
        controller.startRecording(keyboardJobID: "short-call-job")
        try await settle()
        controller.handleAudioSystemEvent(.interruptionBegan)
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertNotEqual(bridge.snapshot().state, .recording)
    }

    func testWarmSessionStaysHotForTheNextKeyboardDictationWhileInBackground() async throws {
        let now = 9_000.0
        let audio = FakeAudioManager()
        let transcriber = ControlledTranscriber()
        let bridge = KeyboardBridge(defaults: defaults)

        let controller = DictationController(
            audio: audio,
            keyboardBridge: bridge,
            transcriber: transcriber,
            transcriberFactory: { transcriber },
            now: { now },
            autoPrepareOnInit: false
        )
        controller.prepareModel()
        try await settle()
        controller.selectWarmDuration(.fifteenMinutes)
        try await settle()
        XCTAssertTrue(controller.keyboardSessionEnabled)
        let startsWhileForeground = audio.startKeepaliveCount

        // The person returns to the host app: from now on iOS won't start input again.
        audio.canStartInput = false

        for job in ["first", "second", "third"] {
            bridge.send(.start, jobID: job, style: .polished, sentAt: now)
            controller.processPendingKeyboardCommandForTesting()
            try await settle()
            XCTAssertEqual(controller.phase, .recording, "\(job) dictation should record from the keyboard")

            controller.finishRecording()
            try await settle()
            XCTAssertEqual(controller.phase, .ready)
            XCTAssertTrue(controller.keyboardSessionEnabled, "\(job) dictation must not end the warm session")
            XCTAssertTrue(audio.isKeepaliveRunning)
            XCTAssertEqual(bridge.snapshot().state, .ready)
        }

        XCTAssertEqual(audio.startKeepaliveCount, startsWhileForeground, "no input restart in the background")
        XCTAssertEqual(audio.deactivateCount, 0)
    }

    func testMediaPreventsWarmOnlyActivationButAllowsColdKeyboardDictation() async throws {
        let now = 9_100.0
        let audio = FakeAudioManager()
        audio.isOtherAudioPlaying = true
        let transcriber = ControlledTranscriber()
        let bridge = KeyboardBridge(defaults: defaults)
        let controller = DictationController(
            audio: audio, keyboardBridge: bridge, transcriber: transcriber,
            transcriberFactory: { transcriber }, now: { now }, autoPrepareOnInit: false
        )
        controller.prepareModel()
        try await settle()
        controller.selectWarmDuration(.fifteenMinutes)
        try await settle()
        XCTAssertFalse(controller.keyboardSessionEnabled)
        XCTAssertFalse(audio.isKeepaliveRunning)
        XCTAssertEqual(audio.startKeepaliveCount, 0)
        XCTAssertTrue(audio.isOtherAudioPlaying, "warming must not interrupt media")
        XCTAssertEqual(bridge.snapshot().state, .offline)

        await transcriber.armSuspension()
        controller.handleKeyboardLaunch(
            .startRecording(jobID: "media", requestedAt: now, style: .polished, host: nil)
        )
        try await settle()
        XCTAssertEqual(controller.phase, .recording)
        XCTAssertFalse(audio.isOtherAudioPlaying, "the activation now interrupted playback")
        XCTAssertTrue(audio.isKeepaliveRunning)
        let releasesBeforeFinish = audio.deactivateCount
        controller.finishRecording()
        XCTAssertEqual(controller.phase, .transcribing)
        XCTAssertEqual(audio.deactivateCount, releasesBeforeFinish + 1)
        XCTAssertFalse(controller.keyboardSessionEnabled)
        XCTAssertFalse(audio.isKeepaliveRunning)
        try await settle()
        XCTAssertEqual(audio.startKeepaliveCount, 1, "warm loop must not restart input during ASR")
        await transcriber.resumeSuspended(with: "ship the build")
        try await settle()
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertTrue(bridge.snapshot().hasDeliverableResult(at: now + 1))
        XCTAssertFalse(audio.isKeepaliveRunning)

        // Nothing is playing on the next activation: ordinary warm behavior returns.
        controller.selectWarmDuration(.fifteenMinutes)
        try await settle()
        XCTAssertTrue(controller.keyboardSessionEnabled)
        XCTAssertTrue(audio.isKeepaliveRunning)
        controller.endWarmSession()
    }

    func testMediaCaptureReleasesOnCancelShortCaptureFailureAndUnexpectedEnd() async throws {
        for outcome in ["cancel", "short", "failure", "unexpected-success", "unexpected-failure"] {
            let audio = FakeAudioManager()
            audio.isOtherAudioPlaying = true
            audio.nextCaptureDuration = outcome == "short" ? 0.1 : 1.4
            audio.captureShouldThrow = outcome == "failure"
            let transcriber = ControlledTranscriber()
            let controller = DictationController(
                audio: audio, keyboardBridge: KeyboardBridge(defaults: defaults), transcriber: transcriber,
                transcriberFactory: { transcriber }, autoPrepareOnInit: false
            )
            controller.prepareModel()
            try await settle()
            controller.setWarmDuration(.fifteenMinutes)
            controller.startRecording()
            try await settle()
            if outcome != "failure" {
                XCTAssertEqual(controller.phase, .recording, outcome)
                if outcome == "cancel" {
                    controller.cancelCurrentJob()
                } else if outcome.hasPrefix("unexpected") {
                    let capture = try XCTUnwrap(audio.createdCaptures.last)
                    capture.isRecording = false
                    audio.onUnexpectedCaptureEnd?(capture.url, outcome == "unexpected-success")
                } else {
                    controller.finishRecording()
                }
            }
            try await settle()
            XCTAssertFalse(audio.isKeepaliveRunning, outcome)
            XCTAssertFalse(controller.keyboardSessionEnabled, outcome)
            XCTAssertGreaterThan(audio.deactivateCount, 0, outcome)
            XCTAssertEqual(audio.startKeepaliveCount, 1, outcome)
        }
    }

    func testMediaStartingDuringWarmSessionLeavesInputColdAfterInterruption() async throws {
        let audio = FakeAudioManager()
        let transcriber = ControlledTranscriber()
        let controller = DictationController(
            audio: audio, keyboardBridge: KeyboardBridge(defaults: defaults), transcriber: transcriber,
            transcriberFactory: { transcriber }, autoPrepareOnInit: false
        )
        controller.prepareModel()
        try await settle()
        controller.selectWarmDuration(.fifteenMinutes)
        try await settle()
        XCTAssertTrue(audio.isKeepaliveRunning)
        audio.isOtherAudioPlaying = true
        controller.handleAudioSystemEvent(.interruptionBegan)
        XCTAssertFalse(audio.isKeepaliveRunning)
        XCTAssertFalse(controller.keyboardSessionEnabled)
        controller.handleAudioSystemEvent(.interruptionEnded(shouldResume: true))
        try await settle()
        XCTAssertEqual(audio.startKeepaliveCount, 1, "do not interrupt media to restore idle input")
        XCTAssertTrue(audio.isOtherAudioPlaying)
    }

    func testRecordedWAVFixtureIsValidSilentTestInput() throws {
        let bundle = Bundle(for: Self.self)
        let wavURL = try XCTUnwrap(
            bundle.url(forResource: "term-hex-1", withExtension: "wav"),
            "Expected recorded WAV fixture in test bundle"
        )
        let audioFile = try AVAudioFile(forReading: wavURL)
        XCTAssertEqual(audioFile.fileFormat.sampleRate, 16_000, accuracy: 1)
        XCTAssertGreaterThan(audioFile.length, 4_000)
    }

    func testSelectWarmDurationWarmsAndEndsWithoutSeparateButton() async throws {
        let now = 12_000.0
        let audio = FakeAudioManager()
        let transcriber = ControlledTranscriber()
        let bridge = KeyboardBridge(defaults: defaults)

        let controller = DictationController(
            audio: audio,
            keyboardBridge: bridge,
            transcriber: transcriber,
            transcriberFactory: { transcriber },
            now: { now },
            autoPrepareOnInit: false
        )
        controller.prepareModel()
        try await settle()

        controller.setWarmDuration(.off)
        XCTAssertFalse(controller.keyboardSessionEnabled)

        controller.selectWarmDuration(.fifteenMinutes)
        try await settle()
        XCTAssertTrue(controller.keyboardSessionEnabled)
        XCTAssertTrue(audio.isKeepaliveRunning)
        XCTAssertEqual(controller.warmDuration, .fifteenMinutes)

        controller.selectWarmDuration(.off)
        XCTAssertFalse(controller.keyboardSessionEnabled)
        XCTAssertFalse(audio.isKeepaliveRunning)
    }

    func testMeterRecoversAfterCaptureStartsTemporarilyNotRecording() async throws {
        try await checkMeterRecovery(initiallyRecording: false)
    }

    func testMeterRecoversAfterRecordingTemporarilyStops() async throws {
        try await checkMeterRecovery(initiallyRecording: true)
    }

    private func checkMeterRecovery(initiallyRecording: Bool) async throws {
        var now = 20_000.0
        let audio = FakeAudioManager()
        audio.nextCaptureIsRecording = initiallyRecording
        let transcriber = ControlledTranscriber()
        let bridge = KeyboardBridge(defaults: defaults)
        let controller = DictationController(
            audio: audio,
            keyboardBridge: bridge,
            transcriber: transcriber,
            transcriberFactory: { transcriber },
            now: { now },
            autoPrepareOnInit: false
        )
        controller.prepareModel()
        try await settle()
        controller.startRecording(keyboardJobID: "meter-recovery")
        try await settle()
        let capture = try XCTUnwrap(audio.createdCaptures.last)
        defer { controller.cancelCurrentJob() }

        // No completion/interruption callback: the same capture becomes available again.
        capture.isRecording = false
        try await settle()
        capture.power = 0.9
        capture.currentTime = 2.4
        capture.isRecording = true
        now += 1
        try await settle()

        let db = capture.averagePowerDB()
        XCTAssertEqual(controller.phase, .recording)
        XCTAssertEqual(controller.loudnessDB, db, accuracy: 0.001)
        XCTAssertEqual(controller.audioLevel, (db + 48) / 48, accuracy: 0.001)
        XCTAssertEqual(controller.recordingDuration, 2.4)
        XCTAssertEqual(bridge.snapshot().state, .recording)
        XCTAssertEqual(bridge.snapshot().effectiveLoudnessDB, db, accuracy: 0.001)
        XCTAssertEqual(bridge.snapshot().heartbeat, now)

        // A level-only change must still get through the keyboard publication throttle.
        capture.power = 0.2
        now += 1
        try await settle()
        XCTAssertEqual(controller.loudnessDB, capture.averagePowerDB(), accuracy: 0.001)
        XCTAssertEqual(bridge.snapshot().effectiveLoudnessDB, capture.averagePowerDB(), accuracy: 0.001)

        controller.finishRecording()
        try await settle()
        XCTAssertEqual(controller.transcript, "Ship the build.")
        XCTAssertEqual(controller.audioLevel, 0)
        XCTAssertEqual(bridge.snapshot().audioLevel, 0)
    }

    func testCustomVocabularyAppliesOnlyWhenCaptured() async throws {
        let now = 50_000.0
        let audio = FakeAudioManager()
        let transcriber = ControlledTranscriber()
        await transcriber.setCannedOutput("i use open code")
        let bridge = KeyboardBridge(defaults: defaults)
        let settings = CustomVocabularySettings(defaults: defaults)
        settings.terms = ["OpenCode"]
        let controller = DictationController(
            audio: audio,
            keyboardBridge: bridge,
            transcriber: transcriber,
            transcriberFactory: { transcriber },
            now: { now },
            autoPrepareOnInit: false,
            customVocabularySettings: settings
        )
        controller.prepareModel()
        try await settle()

        // Off: the transcript is formatted exactly as before.
        settings.isEnabled = false
        controller.startRecording(keyboardJobID: "vocabulary-off", styleOverride: .verbatim)
        try await settle()
        settings.isEnabled = true // A mid-capture toggle must not affect this session.
        controller.finishRecording()
        try await settle()
        XCTAssertEqual(controller.transcript, "i use open code")

        // On: the setting is captured at start, before formatting.
        controller.clearTranscript()
        settings.isEnabled = true
        controller.startRecording(keyboardJobID: "vocabulary-on", styleOverride: .verbatim)
        try await settle()
        settings.isEnabled = false
        controller.finishRecording()
        try await settle()
        XCTAssertEqual(controller.transcript, "i use OpenCode")

    }

    func testCustomVocabularyReachesTheTranscriberOnlyWhileEnabledBeforeGlossaryHints() async throws {
        let now = 60_000.0
        let audio = FakeAudioManager()
        let transcriber = ControlledTranscriber()
        await transcriber.setCannedOutput("i use open code")
        let bridge = KeyboardBridge(defaults: defaults)
        let settings = CustomVocabularySettings(defaults: defaults)
        settings.terms = ["OpenCode"]
        let controller = DictationController(
            audio: audio,
            keyboardBridge: bridge,
            transcriber: transcriber,
            transcriberFactory: { transcriber },
            now: { now },
            autoPrepareOnInit: false,
            customVocabularySettings: settings
        )
        controller.prepareModel()
        try await settle()

        settings.isEnabled = false
        controller.startRecording(keyboardJobID: "vocabulary-hint-off")
        try await settle()
        controller.finishRecording()
        try await settle()
        // The built-in tech glossary always gives Apple Speech its hints; user terms come first.
        var arguments = await transcriber.vocabularyArguments
        XCTAssertEqual(arguments, [TechGlossary.listedTerms])

        settings.isEnabled = true
        controller.startRecording(keyboardJobID: "vocabulary-hint-on")
        try await settle()
        controller.finishRecording()
        try await settle()
        arguments = await transcriber.vocabularyArguments
        XCTAssertEqual(arguments, [TechGlossary.listedTerms, ["OpenCode"] + TechGlossary.listedTerms])
    }

    func testCustomVocabularySurvivesCasualFormatting() async throws {
        let now = 70_000.0
        let audio = FakeAudioManager()
        let transcriber = ControlledTranscriber()
        await transcriber.setCannedOutput("iphone 17 broke")
        let bridge = KeyboardBridge(defaults: defaults)
        let settings = CustomVocabularySettings(defaults: defaults)
        settings.terms = ["iPhone 17"]
        settings.isEnabled = true
        let controller = DictationController(
            audio: audio,
            keyboardBridge: bridge,
            transcriber: transcriber,
            transcriberFactory: { transcriber },
            now: { now },
            autoPrepareOnInit: false,
            customVocabularySettings: settings
        )
        controller.prepareModel()
        try await settle()

        // Very casual lowercases the whole sentence, so the second spelling pass has to
        // restore the listed term.
        controller.startRecording(keyboardJobID: "vocabulary-casual", styleOverride: .veryCasual)
        try await settle()
        controller.finishRecording()
        try await settle()
        XCTAssertEqual(controller.transcript, "iPhone 17 broke")
    }

    func testCustomVocabularySurvivesPolishedFormatting() async throws {
        let now = 80_000.0
        let audio = FakeAudioManager()
        let transcriber = ControlledTranscriber()
        await transcriber.setCannedOutput("iphone 17 broke")
        let bridge = KeyboardBridge(defaults: defaults)
        let settings = CustomVocabularySettings(defaults: defaults)
        settings.terms = ["iPhone 17"]
        settings.isEnabled = true
        let controller = DictationController(
            audio: audio,
            keyboardBridge: bridge,
            transcriber: transcriber,
            transcriberFactory: { transcriber },
            now: { now },
            autoPrepareOnInit: false,
            customVocabularySettings: settings
        )
        controller.prepareModel()
        try await settle()

        // Polished capitalizes the sentence start ("IPhone"), so the second pass
        // has to restore the listed term.
        controller.startRecording(keyboardJobID: "vocabulary-polished", styleOverride: .polished)
        try await settle()
        controller.finishRecording()
        try await settle()
        XCTAssertEqual(controller.transcript, "iPhone 17 broke.")
    }

    // MARK: - Start without waiting after failures (2026-11-12 device logs)

    private func makeRecoveryController(
        audio: FakeAudioManager,
        bridge: KeyboardBridge,
        now: TimeInterval,
        retryDelays: [Duration],
        onPrepare: @escaping () -> Void = {}
    ) -> DictationController {
        let transcriber = ControlledTranscriber()
        return DictationController(
            audio: audio,
            keyboardBridge: bridge,
            transcriber: transcriber,
            transcriberFactory: {
                onPrepare()
                return transcriber
            },
            now: { now },
            autoPrepareOnInit: false,
            hostReturner: HostReturner(openByBundleID: { _ in false }, openURL: { _ in false }),
            audioActivationRetryDelays: retryDelays
        )
    }

    func testActivationRetriesWhileAnotherAppStillHoldsAudio() async throws {
        let audio = FakeAudioManager()
        let bridge = KeyboardBridge(defaults: defaults)
        let controller = makeRecoveryController(audio: audio, bridge: bridge, now: 20_000,
                                                retryDelays: [.milliseconds(1), .milliseconds(1)])
        controller.prepareModel()
        try await settle()

        audio.busyActivationsRemaining = 2
        controller.startRecording(keyboardJobID: "after-voice-message")
        try await settle()
        XCTAssertEqual(controller.phase, .recording, "a brief refusal must not fail the dictation")
        XCTAssertEqual(audio.startKeepaliveCount, 3)
        controller.cancelCurrentJob()
    }

    func testRefusalBeyondRetriesExplainsThatAudioIsBusy() async throws {
        let audio = FakeAudioManager()
        let bridge = KeyboardBridge(defaults: defaults)
        let controller = makeRecoveryController(audio: audio, bridge: bridge, now: 21_000,
                                                retryDelays: [.milliseconds(1)])
        controller.prepareModel()
        try await settle()

        audio.busyActivationsRemaining = 5
        controller.startRecording(keyboardJobID: "busy")
        try await settle()
        XCTAssertEqual(controller.phase, .failed(DictationController.audioBusyMessage))
        XCTAssertEqual(audio.startKeepaliveCount, 2)
    }

    func testKeyboardHandoffAfterFailureReusesPreparedModel() async throws {
        let now = 22_000.0
        let audio = FakeAudioManager()
        let bridge = KeyboardBridge(defaults: defaults)
        var prepares = 0
        let controller = makeRecoveryController(audio: audio, bridge: bridge, now: now,
                                                retryDelays: [], onPrepare: { prepares += 1 })
        controller.prepareModel()
        try await settle()
        XCTAssertEqual(prepares, 1)

        audio.captureShouldThrow = true
        controller.startRecording(keyboardJobID: "fails")
        try await settle()
        guard case .failed = controller.phase else { return XCTFail("expected failure, got \(controller.phase)") }

        audio.captureShouldThrow = false
        controller.handleKeyboardLaunch(
            .startRecording(jobID: "next", requestedAt: now, style: .polished, host: nil)
        )
        try await settle()
        XCTAssertEqual(controller.phase, .recording)
        XCTAssertEqual(prepares, 1, "a microphone failure must not reload the speech model")
        controller.cancelCurrentJob()
    }

    func testWarmKeyboardStartWorksAgainAfterFailedCapture() async throws {
        let now = 23_000.0
        let audio = FakeAudioManager()
        let bridge = KeyboardBridge(defaults: defaults)
        let controller = makeRecoveryController(audio: audio, bridge: bridge, now: now, retryDelays: [])
        controller.prepareModel()
        try await settle()
        controller.selectWarmDuration(.fifteenMinutes)
        try await settle()
        XCTAssertTrue(audio.isKeepaliveRunning)

        audio.captureShouldThrow = true
        bridge.send(.start, jobID: "fails", style: .polished, sentAt: now)
        controller.processPendingKeyboardCommandForTesting()
        try await settle()
        guard case .failed = controller.phase else { return XCTFail("expected failure, got \(controller.phase)") }
        XCTAssertTrue(audio.isKeepaliveRunning)

        audio.captureShouldThrow = false
        bridge.send(.start, jobID: "retry", style: .polished, sentAt: now)
        controller.processPendingKeyboardCommandForTesting()
        try await settle()
        XCTAssertEqual(controller.phase, .recording, "the warm keyboard start must not be ignored after a failure")
        controller.cancelCurrentJob()
    }

    func testInterruptionResumeRetriesBeforeEndingWarmSession() async throws {
        let audio = FakeAudioManager()
        let bridge = KeyboardBridge(defaults: defaults)
        let controller = makeRecoveryController(audio: audio, bridge: bridge, now: 24_000,
                                                retryDelays: [.milliseconds(1), .milliseconds(1)])
        controller.prepareModel()
        try await settle()
        controller.selectWarmDuration(.fifteenMinutes)
        try await settle()

        controller.handleAudioSystemEvent(.interruptionBegan)
        XCTAssertFalse(audio.isKeepaliveRunning)
        audio.busyActivationsRemaining = 2
        controller.handleAudioSystemEvent(.interruptionEnded(shouldResume: true))
        try await settle()
        XCTAssertTrue(controller.keyboardSessionEnabled)
        XCTAssertTrue(audio.isKeepaliveRunning)

        controller.handleAudioSystemEvent(.interruptionBegan)
        audio.busyActivationsRemaining = 10
        controller.handleAudioSystemEvent(.interruptionEnded(shouldResume: true))
        try await settle()
        XCTAssertFalse(controller.keyboardSessionEnabled, "a lasting refusal still ends the warm session")
    }

    func testKeyboardStartDuringInterruptionResumeKeepsItsCapture() async throws {
        let now = 25_000.0
        let audio = FakeAudioManager()
        let bridge = KeyboardBridge(defaults: defaults)
        let controller = makeRecoveryController(audio: audio, bridge: bridge, now: now,
                                                retryDelays: [.milliseconds(50), .milliseconds(50)])
        controller.prepareModel()
        try await settle()
        controller.selectWarmDuration(.fifteenMinutes)
        try await settle()

        controller.handleAudioSystemEvent(.interruptionBegan)
        audio.busyActivationsRemaining = 2
        controller.handleAudioSystemEvent(.interruptionEnded(shouldResume: true))
        // Dictate right away, while the resume would still be retrying.
        bridge.send(.start, jobID: "right-after-voice-message", style: .polished, sentAt: now)
        controller.processPendingKeyboardCommandForTesting()
        try await settle()
        XCTAssertEqual(controller.phase, .recording)
        let capture = try XCTUnwrap(audio.createdCaptures.last)
        let startsAfterCapture = audio.startKeepaliveCount

        try await settle()
        try await settle()
        XCTAssertEqual(controller.phase, .recording, "the capture must keep recording")
        XCTAssertTrue(capture.isRecording)
        XCTAssertEqual(audio.startKeepaliveCount, startsAfterCapture, "no input restart under the capture")
        XCTAssertTrue(controller.keyboardSessionEnabled)
        controller.cancelCurrentJob()
    }

    func testFailedStartDuringCallKeepsWarmSessionUntilTheCallEnds() async throws {
        let audio = FakeAudioManager()
        let bridge = KeyboardBridge(defaults: defaults)
        let controller = makeRecoveryController(audio: audio, bridge: bridge, now: 26_000, retryDelays: [])
        controller.prepareModel()
        try await settle()
        controller.selectWarmDuration(.fifteenMinutes)
        try await settle()

        // A phone call holds audio: every activation fails until it ends.
        controller.handleAudioSystemEvent(.interruptionBegan)
        audio.keepaliveShouldThrow = true
        controller.startRecording(keyboardJobID: "during-call")
        try await settle()
        guard case .failed = controller.phase else { return XCTFail("expected failure, got \(controller.phase)") }
        XCTAssertTrue(controller.keyboardSessionEnabled, "a failed start during the call must not end the session")

        audio.keepaliveShouldThrow = false
        controller.handleAudioSystemEvent(.interruptionEnded(shouldResume: true))
        try await settle()
        XCTAssertTrue(controller.keyboardSessionEnabled)
        XCTAssertTrue(audio.isKeepaliveRunning, "the end of the call still resumes the warm input")
    }

    func testSuccessfulStartDuringInterruptionEndsTheSuspension() async throws {
        let audio = FakeAudioManager()
        let bridge = KeyboardBridge(defaults: defaults)
        let controller = makeRecoveryController(audio: audio, bridge: bridge, now: 27_000, retryDelays: [])
        controller.prepareModel()
        try await settle()
        controller.selectWarmDuration(.fifteenMinutes)
        try await settle()

        controller.handleAudioSystemEvent(.interruptionBegan)
        XCTAssertFalse(audio.isKeepaliveRunning)
        controller.startRecording(keyboardJobID: "during-voice-playback")
        try await settle()
        XCTAssertEqual(controller.phase, .recording)
        controller.finishRecording()
        try await settle()
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertTrue(audio.isKeepaliveRunning)
        let startsAfterDictation = audio.startKeepaliveCount

        // A late end of the interruption must not restart the running input or end the session.
        controller.handleAudioSystemEvent(.interruptionEnded(shouldResume: true))
        try await settle()
        XCTAssertEqual(audio.startKeepaliveCount, startsAfterDictation)
        XCTAssertTrue(controller.keyboardSessionEnabled)
        XCTAssertTrue(audio.isKeepaliveRunning)

        // The input is no longer treated as suspended: the session loop restarts a dead input.
        audio.stopKeepalive()
        try await settle()
        XCTAssertTrue(audio.isKeepaliveRunning, "the session loop must not skip a dead input after the suspension")
    }

    func testOnlyEngineFailuresRequireReloadingTheModel() {
        XCTAssertTrue(DictationController.transcriptionFailureKeepsModel(WhisperTranscriber.TranscriberError.silentAudio))
        XCTAssertTrue(DictationController.transcriptionFailureKeepsModel(WhisperTranscriber.TranscriberError.emptyTranscript))
        XCTAssertTrue(DictationController.transcriptionFailureKeepsModel(CancellationError()))
        XCTAssertFalse(DictationController.transcriptionFailureKeepsModel(
            WhisperTranscriber.TranscriberError.corruptModel("ANE")))
        XCTAssertFalse(DictationController.transcriptionFailureKeepsModel(WhisperTranscriber.TranscriberError.notPrepared))
    }

    private func settle() async throws {
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}
