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
    static let expected: [String: String] = [
        "casual|0": "die katze sitzt auf der mathe",
        "casual|1": "ich ich brauche mehr daten um einen schluss zu ziehen",
        "casual|2": "erstelle einen pull request für das feature flag und pushe auf github",
        "casual|3": "bullet milk bullet eggs new line call mom new paragraph done",
        "casual|4": "can we meet at 3 pm, no wait, 4 pm?",
        "casual|5": "one two three",
        "casual|6": "das know how aus Baden-Württemberg. und dann ok",
        "casual|7": "i think iphone and ios are great",
        "casual|8": "hello world",
        "casual|9": "so, we need 1,000 users by q3 — right",
        "casual|10": "kannst du den branch rebasen und dann pushen? danke!",
        "casual|11": "öffne das in einem neuen herdr tab",
        "casual|12": "line one\nline two",
        "casual|13": "was ist die hauptstadt von frankreich",
        "casualCapitalized|0": "Die Katze sitzt auf der Mathe",
        "casualCapitalized|1": "Ich ich brauche mehr Daten um einen Schluss zu ziehen",
        "casualCapitalized|2": "Erstelle einen Pull Request für das Feature Flag und pushe auf GitHub",
        "casualCapitalized|3": "Bullet milk bullet eggs new line call mom new paragraph done",
        "casualCapitalized|4": "Can we meet at 3 pm, no wait, 4 pm?",
        "casualCapitalized|5": "One two three",
        "casualCapitalized|6": "Das Know how aus Baden-Württemberg. Und dann OK",
        "casualCapitalized|7": "I think iphone and ios are great",
        "casualCapitalized|8": "Hello world",
        "casualCapitalized|9": "So, we need 1,000 users by Q3 — right",
        "casualCapitalized|10": "Kannst du den Branch rebasen und dann pushen? Danke!",
        "casualCapitalized|11": "Öffne das in einem neuen herdr Tab",
        "casualCapitalized|12": "Line one\nLine two",
        "casualCapitalized|13": "Was ist die Hauptstadt von Frankreich",
        "notes|0": "Die Katze sitzt auf der Mathe",
        "notes|1": "Ich ich brauche mehr Daten um einen Schluss zu ziehen",
        "notes|2": "Erstelle einen Pull Request für das Feature Flag und pushe auf GitHub",
        "notes|3": "- Milk\n- Eggs\nCall mom\n\nDone",
        "notes|4": "Can we meet at 3 pm, no wait, 4 pm?",
        "notes|5": "One two three",
        "notes|6": "Das Know how aus Baden-Württemberg. Und dann OK.",
        "notes|7": "I think iphone and ios are great",
        "notes|8": "Hello world.",
        "notes|9": "So, we need 1,000 users by Q3 — right",
        "notes|10": "Kannst du den Branch rebasen und dann pushen? Danke!",
        "notes|11": "Öffne das in einem neuen herdr Tab",
        "notes|12": "Line one\nLine two",
        "notes|13": "Was ist die Hauptstadt von Frankreich",
        "polished|0": "Die Katze sitzt auf der Mathe.",
        "polished|1": "Ich ich brauche mehr Daten um einen Schluss zu ziehen.",
        "polished|2": "Erstelle einen Pull Request für das Feature Flag und pushe auf GitHub.",
        "polished|3": "Bullet milk bullet eggs new line call mom new paragraph done.",
        "polished|4": "Can we meet at 3 pm, no wait, 4 pm?",
        "polished|5": "One two three.",
        "polished|6": "Das Know how aus Baden-Württemberg. Und dann OK.",
        "polished|7": "I think iphone and ios are great.",
        "polished|8": "Hello world.",
        "polished|9": "So, we need 1,000 users by Q3 — right.",
        "polished|10": "Kannst du den Branch rebasen und dann pushen? Danke!",
        "polished|11": "Öffne das in einem neuen herdr Tab.",
        "polished|12": "Line one\nLine two.",
        "polished|13": "Was ist die Hauptstadt von Frankreich.",
        "verbatim|0": "Die Katze sitzt auf der Mathe",
        "verbatim|1": "Ähm ich ich brauche mehr Daten um einen Schluss zu ziehen",
        "verbatim|2": "Erstelle einen Pull Request für das Feature Flag und pushe auf GitHub",
        "verbatim|3": "bullet milk bullet eggs new line call mom new paragraph done",
        "verbatim|4": "Can we meet at 3 pm, no wait, 4 pm?",
        "verbatim|5": "one two three",
        "verbatim|6": "Das Know how aus Baden-Württemberg. Und dann OK.",
        "verbatim|7": "i think iphone and ios are great",
        "verbatim|8": "Hello world.",
        "verbatim|9": "So, uh, we need 1,000 users by Q3 — right",
        "verbatim|10": "Kannst du den Branch rebasen und dann pushen? Danke!",
        "verbatim|11": "Öffne das in einem neuen herdr Tab",
        "verbatim|12": "Line one\nLine two",
        "verbatim|13": "Was ist die Hauptstadt von Frankreich",
    ]

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
            background: CleanupTestBackground(), isEnabled: { false },
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
