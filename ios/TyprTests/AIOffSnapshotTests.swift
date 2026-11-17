import XCTest
@testable import Typr

@MainActor
private final class SnapshotAudio: AudioManaging {
    var isKeepaliveRunning = false
    var onSystemEvent: ((AudioSystemEvent) -> Void)?
    var onUnexpectedCaptureEnd: ((URL, Bool) -> Void)?
    func requestPermission() async -> Bool { true }
    func startKeepalive(allowBluetooth: Bool) throws { isKeepaliveRunning = true }
    func stopKeepalive() { isKeepaliveRunning = false }
    func deactivateSession() { isKeepaliveRunning = false }
    func beginCapture(at url: URL, maxDuration: TimeInterval, allowBluetooth: Bool) throws -> any ActiveAudioCapture {
        SnapshotCapture(url: url)
    }
}

@MainActor
private final class SnapshotCapture: ActiveAudioCapture {
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

private actor SnapshotASR: LocalTranscribing {
    nonisolated let displayName = "Test ASR"
    let languageName = "German"
    var output = ""
    func set(_ text: String) { output = text }
    func prepare(progressHandler: @escaping @Sendable (ModelPreparationProgress) -> Void) async throws {}
    func transcribe(_ url: URL) async throws -> String { output }
}

/// AI cleanup off must deliver byte for byte what Typr delivered before the Hex-style rewrite of
/// AI cleanup, in every style. The expected texts were recorded from the code before that change;
/// never update them to make a cleanup change pass.
@MainActor
final class AIOffSnapshotTests: XCTestCase {
    static let corpus: [String] = [
        "Die Katze sitzt auf der Mathe",
        "Ähm ich ich brauche mehr Daten um einen Schluss zu ziehen",
        "Erstelle einen Pulrequest für das Feature-Flag und pushe auf github",
        "bullet milk bullet eggs new line call mom new paragraph done",
        "Can we meet at 3 pm, no wait, 4 pm?",
        "one two three",
        "  Das Know-how aus Baden-Württemberg. Und dann OK.  ",
        "i think iphone and ios are great",
        "Hello world.",
        "So, uh, we need 1,000 users by Q3 — right",
        "Kannst du den Branch rebasen und dann pushen? Danke!",
        "Öffne das in einem neuen Herder Tab",
        "Line one\nLine two",
        "Was ist die Hauptstadt von Frankreich",
    ]

    /// Recorded from the pre-change code: "<style>|<corpus index>" -> delivered transcript.
    static let expected: [String: String] = [:]

    func testAIOffDeliversTheRecordedTextInEveryStyle() async throws {
        let suite = "ai-off.snapshot.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vocabulary = CustomVocabularySettings(defaults: defaults)
        vocabulary.isEnabled = true
        vocabulary.terms = ["herdr", "Baden-Württemberg"]
        vocabulary.setSoundsLike(["Herder"], for: "herdr")
        let session = CleanupTestSession(), clock = CleanupTestSleeper()
        let deps = TranscriptCleanupDependencies(cleaner: CleanupTestCleaner(session: session),
            language: CleanupTestLanguage(), background: CleanupTestBackground(), isEnabled: { false },
            sleep: clock.sleep)
        let asr = SnapshotASR()
        let controller = DictationController(audio: SnapshotAudio(), keyboardBridge: KeyboardBridge(defaults: defaults),
            transcriber: asr, transcriberFactory: { asr }, autoPrepareOnInit: false,
            customVocabularySettings: vocabulary, cleanup: deps, languageSettings: TyprSettings(defaults: defaults))
        controller.prepareModel()
        try await waitForState("model ready") { controller.phase == .ready }

        var actual: [String: String] = [:]
        for style in DictationStyle.allCases {
            for (index, raw) in Self.corpus.enumerated() {
                await asr.set(raw)
                controller.startRecording(styleOverride: style)
                try await waitForState("recording \(style) \(index)") { controller.phase == .recording }
                controller.finishRecording()
                try await waitForState("finished \(style) \(index)") { controller.isIdleForTest }
                actual["\(style.rawValue)|\(index)"] = controller.transcript
            }
        }
        XCTAssertEqual(session.cleanCount, 0)
        XCTAssertEqual(session.prepareCount, 0)
        for key in actual.keys.sorted() {
            XCTAssertEqual(actual[key], Self.expected[key], key)
        }
        if actual != Self.expected {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let json = String(decoding: try encoder.encode(actual), as: UTF8.self)
            XCTFail("AI-OFF-SNAPSHOT \(json)")
        }
        controller.cancelCurrentJob()
        try await waitForState("controller idle") { controller.isIdleForTest }
        clock.fire()
        await mainActorBarrier()
    }
}
