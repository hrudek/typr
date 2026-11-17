import XCTest
import UIKit
@testable import Typr

/// A model session that records the vocabulary the coordinator hands it.
@MainActor
private final class VocabularySession: CleanupSession {
    var result = "Grüße an Rudek und Mayer"
    private(set) var prompts: [String] = []
    /// Prewarm has returned; the coordinator releases its reservation in the same main-actor job.
    private(set) var prewarms = 0
    func prewarm() async { prewarms += 1 }
    func generate(_ prompt: String) async throws -> String {
        prompts.append(prompt)
        return result
    }
}

@MainActor
private struct VocabularyCleaner: TyprTranscriptCleaning {
    var unavailableReason: String?
    let session: VocabularySession
    func makeSession() -> any CleanupSession { session }
}

@MainActor
private final class VocabularyAudio: AudioManaging {
    var isKeepaliveRunning = false
    var onSystemEvent: ((AudioSystemEvent) -> Void)?
    var onUnexpectedCaptureEnd: ((URL, Bool) -> Void)?
    func requestPermission() async -> Bool { true }
    func startKeepalive(allowBluetooth: Bool) throws { isKeepaliveRunning = true }
    func stopKeepalive() { isKeepaliveRunning = false }
    func deactivateSession() { isKeepaliveRunning = false }
    func beginCapture(at url: URL, maxDuration: TimeInterval, allowBluetooth: Bool) throws -> any ActiveAudioCapture {
        VocabularyCapture(url: url)
    }
}

@MainActor
private final class VocabularyCapture: ActiveAudioCapture {
    let url: URL
    var isRecording = true
    var currentTime: TimeInterval { 1.5 }
    init(url: URL) {
        self.url = url
        _ = FileManager.default.createFile(atPath: url.path, contents: Data())
    }
    func normalizedPowerLevel() -> Float { 0.5 }
    func stop() { isRecording = false }
}

private actor VocabularyASR: LocalTranscribing {
    nonisolated let displayName = "Test ASR"
    let languageName = "German"
    let output: String
    init(output: String = "Grüße an Rudeck und Meier") { self.output = output }
    func prepare(progressHandler: @escaping @Sendable (ModelPreparationProgress) -> Void) async throws {}
    func transcribe(_ url: URL) async throws -> String { output }
}

@MainActor
final class TyprCleanupVocabularyTests: XCTestCase {
    func testCoordinatorHandsTheVocabularyToTheModel() async {
        let session = VocabularySession()
        let bg = CleanupTestBackground(), clock = CleanupTestSleeper()
        let deps = TranscriptCleanupDependencies(cleaner: VocabularyCleaner(session: session), background: bg, isEnabled: { true }, sleep: clock.sleep)
        let job = CleanupJob(session: session, background: bg)
        job.begin()
        let value = await CleanupCoordinator().clean("Grüße an Rudeck und Meier", job: job,
            dependencies: deps, vocabulary: ["Rudek", "Mayer"])
        XCTAssertEqual(value, "Grüße an Rudek und Mayer")
        XCTAssertEqual(session.prompts, [CleanupPrompt.make("Grüße an Rudeck und Meier", vocabulary: ["Rudek", "Mayer"])])
        job.finish()
        clock.fire()
    }

    /// Only Typr cleanup may run, even when an old install still has the removed setting on.
    func testTyprCleanupOrPlainTranscriptIgnoresRemovedExperiment() async throws {
        for typrOn in [true, false] {
            let suite = "cleanup.vocabulary.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(true, forKey: "experiments.appleIntelligenceCleanup")
            let vocabulary = CustomVocabularySettings(defaults: defaults)
            vocabulary.isEnabled = true
            vocabulary.terms = ["Rudek", "Mayer"]

            let session = VocabularySession()
            let bg = CleanupTestBackground(), clock = CleanupTestSleeper()
            let deps = TranscriptCleanupDependencies(cleaner: VocabularyCleaner(session: session), background: bg, isEnabled: { typrOn }, sleep: clock.sleep)
            let asr = VocabularyASR()
            let controller = DictationController(audio: VocabularyAudio(), keyboardBridge: KeyboardBridge(defaults: defaults),
                transcriber: asr, transcriberFactory: { asr }, autoPrepareOnInit: false, customVocabularySettings: vocabulary, cleanup: deps)
            controller.prepareModel()
            try await waitForState("model ready") { controller.phase == .ready }
            controller.startRecording(keyboardJobID: "job", styleOverride: .polished, copyToPasteboard: false)
            try await waitForState("recording") { controller.phase == .recording }
            if typrOn {
                // Cleanup is admitted only after the capture's prewarm released its reservation.
                try await waitForState("cleanup prewarm returned") { session.prewarms == 1 }
            }
            controller.finishRecording()
            try await waitForState("transcript delivered and transcription unwound") {
                controller.phase == .ready && controller.isIdleForTest
            }

            if typrOn {
                XCTAssertEqual(session.prompts.count, 1)
                XCTAssertTrue(session.prompts.first?.contains(
                    "Vocabulary (spell these exactly when the speaker means them): Rudek; Mayer\n\n") == true)
                XCTAssertEqual(controller.transcript, "Grüße an Rudek und Mayer.")
            } else {
                XCTAssertEqual(session.prompts, [])
                XCTAssertEqual(controller.transcript, "Grüße an Rudeck und Meier.")
            }
            controller.cancelCurrentJob(); clock.fire()
            try await waitForState("dictation work drained before defaults teardown") { controller.isIdleForTest }
        }
    }
}
