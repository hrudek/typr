import XCTest
@testable import Typr

/// A model session that records every prompt the coordinator sends it.
@MainActor
private final class ContextSession: CleanupSession {
    var result = "Erstelle einen Pull-Request für den Feature-Flag."
    private(set) var prompts: [String] = []
    private(set) var prewarms = 0
    func prewarm() async { prewarms += 1 }
    func generate(_ prompt: String) async throws -> String {
        prompts.append(prompt)
        return result
    }
}

@MainActor
private struct ContextCleaner: TyprTranscriptCleaning {
    var unavailableReason: String?
    let session: ContextSession
    func makeSession() -> any CleanupSession { session }
}

@MainActor
private final class ContextAudio: AudioManaging {
    var isKeepaliveRunning = false
    var onSystemEvent: ((AudioSystemEvent) -> Void)?
    var onUnexpectedCaptureEnd: ((URL, Bool) -> Void)?
    func requestPermission() async -> Bool { true }
    func startKeepalive(allowBluetooth: Bool) throws { isKeepaliveRunning = true }
    func stopKeepalive() { isKeepaliveRunning = false }
    func deactivateSession() { isKeepaliveRunning = false }
    func beginCapture(at url: URL, maxDuration: TimeInterval, allowBluetooth: Bool) throws -> any ActiveAudioCapture {
        ContextCapture(url: url)
    }
}

@MainActor
private final class ContextCapture: ActiveAudioCapture {
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

private actor ContextASR: LocalTranscribing {
    nonisolated let displayName = "Test ASR"
    let languageName = "German"
    let output: String
    private(set) var vocabularies: [[String]] = []
    init(output: String = "Erstelle einen Pulrequest für das Feature Flag") { self.output = output }
    func prepare(progressHandler: @escaping @Sendable (ModelPreparationProgress) -> Void) async throws {}
    func transcribe(_ url: URL) async throws -> String { output }
    func transcribe(_ url: URL, vocabulary: [String]) async throws -> String {
        vocabularies.append(vocabulary)
        return output
    }
}

@MainActor
private final class RequestedDurations {
    var values: [Duration] = []
}

@MainActor
final class CleanupRewriteTests: XCTestCase {
    private func drain() async { for _ in 0..<30 { await Task.yield() } }

    private func ready(_ controller: DictationController) async throws {
        controller.prepareModel()
        try await waitForState("model ready") { controller.phase == .ready }
    }

    /// `prewarms`: the session's total once this capture records; a capture admitted to Typr cleanup
    /// starts its prewarm task in the same step that sets `.recording`.
    private func recording(_ controller: DictationController, session: ContextSession? = nil,
                           prewarms: Int = 0) async throws {
        try await waitForState("recording") {
            controller.phase == .recording && (session?.prewarms ?? 0) == prewarms
        }
    }

    private func finish(_ controller: DictationController) async throws {
        controller.finishRecording()
        try await waitForState("transcription and cleanup finished") { controller.isIdleForTest }
    }

    /// Lets the fired deadline sleeper (it ignores cancellation, like a late wake-up) run its no-op
    /// continuation.
    private func fireDeadline(_ clock: CleanupTestSleeper) async {
        clock.fire()
        await mainActorBarrier()
    }

    /// Teardown drain before defaults or the log archive are removed.
    private func dispose(_ controller: DictationController, clock: CleanupTestSleeper) async throws {
        controller.cancelCurrentJob()
        try await waitForState("controller idle") { controller.isIdleForTest }
        await fireDeadline(clock)
    }

    // MARK: - Hyphens

    func testSpaceCompoundsTurnsHyphensBetweenWordsIntoSpaces() {
        let cases: [(String, String)] = [
            ("Das Feedback-Menü hat Know-how", "Das Feedback Menü hat Know how"),
            ("Ein Pull-Request, ein Follow-up und ein To-do.", "Ein Pull Request, ein Follow up und ein To do."),
            ("PR-Feedback für das AI-Modell", "PR Feedback für das AI Modell"),
            ("Open-Source-Build und Speech-to-Text-App", "Open Source Build und Speech to Text App"),
            ("testflight-e-mails", "testflight e-mails"),
            ("Das iPhone-17 und Covid-19", "Das iPhone 17 und Covid 19"),
            ("Baden-Württemberg", "Baden Württemberg"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(CleanupHyphens.spaceCompounds(input), expected, input)
        }
        for kept in ["Schreib eine E-Mail", "Ein T-Shirt, x-mal", "Seiten 5-10 am 2026-11-10",
                     "siehe https://example.org/pull-request", "an pull-request@example.org", "die Datei pull-request.md",
                     "Ein- und Ausgang", "Milch - Brot", "- Erster Punkt\n- Zweiter Punkt"] {
            XCTAssertEqual(CleanupHyphens.spaceCompounds(kept), kept, kept)
        }
    }

    /// The radical pass runs on the speech engine's text in every style: with AI cleanup off, in
    /// Verbatim and when cleanup falls back. An accepted answer is used as written (Hex runs no
    /// pass over it), and the model gets the spaced text.
    func testSpaceCompoundsRunsBeforeCleanupInEveryStyle() async throws {
        let raw = "Das Feedback-Menü hat Know-how für PR-Feedback, 5-10 testflight-e-mails und das Open-Source-Build"
        let spaced = "Das Feedback Menü hat Know how für PR Feedback, 5-10 testflight e-mails und das Open Source Build"
        let answer = "Das Feedback-Menü hat Know-how für PR-Feedback, 5-10 TestFlight E-Mails und den Open-Source-Build."
        let cases: [(DictationStyle, Bool, Bool, String)] = [
            (.polished, false, false, spaced + "."),
            (.casual, false, false, spaced),
            (.veryCasual, false, false, spaced.lowercased()),
            (.notes, false, false, spaced),
            (.verbatim, false, false, spaced),
            (.verbatim, true, false, spaced),
            (.polished, true, true, spaced + "."),
            (.polished, true, false, answer),
        ]
        for (style, enabled, unavailable, expected) in cases {
            let suite = "cleanup.hyphens.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let session = ContextSession(), bg = CleanupTestBackground(), clock = CleanupTestSleeper()
            session.result = answer
            let deps = TranscriptCleanupDependencies(
                cleaner: ContextCleaner(unavailableReason: unavailable ? "unavailable" : nil, session: session),
                background: bg, isEnabled: { enabled }, sleep: clock.sleep)
            let asr = ContextASR(output: raw)
            let controller = DictationController(audio: ContextAudio(), keyboardBridge: KeyboardBridge(defaults: defaults),
                transcriber: asr, transcriberFactory: { asr }, autoPrepareOnInit: false,
                customVocabularySettings: CustomVocabularySettings(defaults: defaults), cleanup: deps,
                languageSettings: TyprSettings(defaults: defaults))
            let modelRan = enabled && !unavailable && style != .verbatim
            try await ready(controller)
            controller.startRecording(styleOverride: style)
            try await recording(controller, session: session, prewarms: modelRan ? 1 : 0)
            try await finish(controller)
            XCTAssertEqual(session.prompts.count, modelRan ? 1 : 0, "\(style)")
            if modelRan { XCTAssertTrue(session.prompts[0].contains("<transcript>\n\(spaced)\n</transcript>")) }
            XCTAssertEqual(controller.transcript, expected, "\(style), enabled: \(enabled)")
            try await dispose(controller, clock: clock)
        }
    }

    /// A user's Custom vocabulary term keeps its hyphen; everything else gets spaces.
    func testCustomVocabularyTermKeepsItsHyphen() async throws {
        let suite = "cleanup.hyphens.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vocabulary = CustomVocabularySettings(defaults: defaults)
        vocabulary.isEnabled = true
        vocabulary.terms = ["Baden-Württemberg"]
        let asr = ContextASR(output: "Das Know-how aus Baden-Württemberg")
        let controller = DictationController(audio: ContextAudio(), keyboardBridge: KeyboardBridge(defaults: defaults),
            transcriber: asr, transcriberFactory: { asr }, autoPrepareOnInit: false,
            customVocabularySettings: vocabulary, languageSettings: TyprSettings(defaults: defaults))
        try await ready(controller)
        controller.startRecording(styleOverride: .verbatim)
        try await recording(controller)
        try await finish(controller)
        XCTAssertEqual(controller.transcript, "Das Know how aus Baden-Württemberg")
    }

    // MARK: - Language

    func testLanguagePickerValuesAndSpeechLocales() {
        XCTAssertEqual(DictationLanguage.allCases, [.automatic, .german, .english])
        XCTAssertEqual(DictationLanguage.allCases.map(\.rawValue), ["automatic", "de", "en"])
        XCTAssertEqual(DictationLanguage.allCases.map(\.label), ["Automatic", "German", "English"])
        XCTAssertEqual(DictationLanguage.automatic.speechLocaleCandidates(preferred: ["de-DE", "en-GB"], current: "de_DE"),
                       ["de-DE", "en-GB", "de_DE", "en-US"])
        // An explicit language never falls back to another language for the prepared locale.
        XCTAssertEqual(DictationLanguage.german.speechLocaleCandidates(preferred: ["en-US", "de-CH"], current: "en_US"),
                       ["de-DE", "de-CH"])
        XCTAssertEqual(DictationLanguage.english.speechLocaleCandidates(preferred: ["de-DE"], current: "de_DE"), ["en-US"])
        // The automatic engine choice (no explicit engine) keeps the previous availability order.
        XCTAssertEqual(DictationLanguage.german.availabilityLocaleCandidates(preferred: ["en-US", "de-DE"], current: "en_US"),
                       ["de-DE", "en-US", "en_US"])
    }

    func testLanguageSettingDefaultsToAutomaticInIsolatedDefaults() {
        let name = "cleanup.language.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = TyprSettings(defaults: defaults)
        XCTAssertEqual(settings.dictationLanguage, .automatic)
        settings.dictationLanguage = .german
        XCTAssertEqual(TyprSettings(defaults: defaults).dictationLanguage, .german)
        defaults.set("klingon", forKey: "typr.dictationLanguage")
        XCTAssertEqual(settings.dictationLanguage, .automatic)
    }

    func testDeadlineGrowsWithTheDictation() {
        XCTAssertEqual(CleanupCoordinator.deadline(forUTF8Bytes: 0), .seconds(4))
        XCTAssertEqual(CleanupCoordinator.deadline(forUTF8Bytes: 400), .seconds(4))
        XCTAssertEqual(CleanupCoordinator.deadline(forUTF8Bytes: 550), .seconds(5))
        XCTAssertEqual(CleanupCoordinator.deadline(forUTF8Bytes: 1000), .seconds(8))
        XCTAssertEqual(CleanupCoordinator.deadline(forUTF8Bytes: 1600), CleanupCoordinator.maximumDeadline)
        XCTAssertEqual(CleanupCoordinator.deadline(forUTF8Bytes: 100_000), .seconds(12))
    }

    func testLongDictationWaitsForItsLongerDeadline() async {
        let session = CleanupTestSession(), bg = CleanupTestBackground(), observer = CleanupTestObserver()
        let requested = RequestedDurations(), sleeper = CleanupTestSleeper()
        let deps = TranscriptCleanupDependencies(cleaner: CleanupTestCleaner(session: session), background: bg, isEnabled: { true }, sleep: { duration in
                requested.values.append(duration)
                try await sleeper.sleep(duration)
            }, observer: observer)
        let raw = String(repeating: "Wort ", count: 200) // 1,000 bytes
        session.result = raw
        session.suspend = true
        let job = CleanupJob(session: session, background: bg); job.begin()
        let coordinator = CleanupCoordinator()
        let task = Task { await coordinator.clean(raw, job: job, dependencies: deps) }
        await drain()
        XCTAssertEqual(requested.values, [.seconds(8)])
        sleeper.fire()
        let value = await task.value
        XCTAssertEqual(value, raw)
        XCTAssertEqual(observer.events.map(\.outcome), [.failed(.deadline)])
        session.resume(); await drain()
        job.finish()
    }

    // MARK: - Context

    /// Hex's caret caps: the end of the text before, the start of the text after, and no caret
    /// text at all for a selection over its cap. Only a start command carries any of it.
    func testKeyboardStartCommandCarriesCappedCaretTextAndHostOnlyForStart() throws {
        let name = "cleanup.command.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let bridge = KeyboardBridge(defaults: defaults)
        bridge.send(.start, jobID: "job", context: String(repeating: "a", count: 1500) + "END",
                    selected: "Friday", after: "START" + String(repeating: "b", count: 1500), host: "com.apple.MobileSMS")
        let command = try XCTUnwrap(bridge.latestCommand())
        XCTAssertEqual(command.context?.count, KeyboardCommand.maximumBeforeCharacters)
        XCTAssertTrue(command.context?.hasSuffix("END") == true)
        XCTAssertEqual(command.selected, "Friday")
        XCTAssertEqual(command.after?.count, KeyboardCommand.maximumAfterCharacters)
        XCTAssertTrue(command.after?.hasPrefix("START") == true)
        XCTAssertEqual(command.host, "com.apple.MobileSMS")
        bridge.send(.start, jobID: "job", context: "before", selected: String(repeating: "s", count: 2001), after: "after")
        XCTAssertNil(bridge.latestCommand()?.context)
        XCTAssertNil(bridge.latestCommand()?.selected)
        XCTAssertNil(bridge.latestCommand()?.after)
        bridge.send(.stop, jobID: "job", context: "secret", selected: "secret", after: "secret", host: "com.example")
        XCTAssertNil(bridge.latestCommand()?.context)
        XCTAssertNil(bridge.latestCommand()?.selected)
        XCTAssertNil(bridge.latestCommand()?.after)
        XCTAssertNil(bridge.latestCommand()?.host)
        bridge.send(.start, jobID: "job", context: "", selected: "", after: "", host: "")
        XCTAssertNil(bridge.latestCommand()?.context)
        XCTAssertNil(bridge.latestCommand()?.host)
        // A command from an older keyboard without the fields still decodes.
        let old = #"{"id":"c","kind":"start","jobID":"j","style":"polished","sentAt":1}"#
        let decoded = try JSONDecoder().decode(KeyboardCommand.self, from: Data(old.utf8))
        XCTAssertNil(decoded.context)
        XCTAssertNil(decoded.host)
        XCTAssertEqual(decoded.kind, .start)
    }

    func testLogRecordsLanguageAndContextLengthButNeverTheContextText() throws {
        let context = DictationLogContext.capture(keyboardJob: true, copyToPasteboard: false, style: .polished,
            engine: "Apple Speech", language: "German (Germany)", duration: 2, loudestAverage: nil, cleanupPath: .typr,
            vocabularyCount: 0, cleanupContext: CleanupContext(language: .german, application: "com.apple.MobileSMS",
                                                               before: "geheimer ", selected: "Kon", after: "text"))
        XCTAssertEqual(context.dictationLanguage, "de")
        XCTAssertEqual(context.cleanupContextSource, "keyboard")
        XCTAssertEqual(context.cleanupContextCharacters, 16)
        let json = String(decoding: try JSONEncoder().encode(context), as: UTF8.self)
        XCTAssertFalse(json.contains("geheimer"))
        XCTAssertFalse(json.contains("MobileSMS"))
        let none = DictationLogContext.capture(keyboardJob: false, copyToPasteboard: false, style: .polished,
            engine: "Apple Speech", language: "German", duration: 2, loudestAverage: nil, cleanupPath: .typr,
            vocabularyCount: 0, cleanupContext: CleanupContext())
        XCTAssertEqual(none.dictationLanguage, "automatic")
        XCTAssertNil(none.cleanupContextSource)
        XCTAssertNil(none.cleanupContextCharacters)
    }

    /// The keyboard's caret text, host app, glossary fixes and Custom vocabulary reach the one prompt;
    /// the next in-app dictation has no context (Hex keeps no dictation history), and the log never
    /// holds the context text.
    func testKeyboardContextAndVocabularyReachThePromptAndNeverTheLog() async throws {
        for customEnabled in [false, true] {
            let env = LogTestEnvironment()
            try await LogTestEnvironment.waitUntilLoaded(env.store)
            env.settings.dictationLanguage = .german
            let vocabulary = CustomVocabularySettings(defaults: env.defaults)
            vocabulary.isEnabled = customEnabled
            vocabulary.terms = ["herdr"]
            vocabulary.setSoundsLike(["Hörder"], for: "herdr")
            let raw = "Erstelle einen Pulrequest für Hörder"
            let prepared = customEnabled ? "Erstelle einen Pull Request für herdr" : "Erstelle einen Pull Request für Hörder"
            let terms = customEnabled ? ["herdr", "Pull Request"] : ["Pull Request"]
            let session = ContextSession(), bg = CleanupTestBackground(), clock = CleanupTestSleeper()
            session.result = prepared + "."
            let deps = TranscriptCleanupDependencies(cleaner: ContextCleaner(session: session),
                background: bg, isEnabled: { true }, sleep: clock.sleep)
            let asr = ContextASR(output: raw), bridge = KeyboardBridge(defaults: env.defaults)
            let controller = DictationController(audio: ContextAudio(), keyboardBridge: bridge,
                transcriber: asr, transcriberFactory: { asr }, autoPrepareOnInit: false,
                customVocabularySettings: vocabulary, cleanup: deps, dictationLog: env.store,
                languageSettings: env.settings)
            try await ready(controller)
            bridge.send(.start, jobID: "integration", style: .polished, context: "Unser geheimer ",
                        selected: "Projekt", after: "kontext", host: "com.apple.MobileSMS")
            controller.processPendingKeyboardCommandForTesting()
            try await recording(controller, session: session, prewarms: 1)
            try await finish(controller)

            let context = CleanupContext(language: .german, application: "com.apple.MobileSMS",
                                         before: "Unser geheimer ", selected: "Projekt", after: "kontext")
            XCTAssertEqual(session.prompts, [CleanupPrompt.make(prepared, vocabulary: terms, context: context)])
            XCTAssertEqual(controller.transcript, prepared + ".")
            let entry = try XCTUnwrap(env.store.entries.first)
            XCTAssertEqual(entry.recognized?.text, raw)
            XCTAssertEqual(entry.aiInput?.text, prepared)
            XCTAssertEqual(entry.context.dictationLanguage, "de")
            XCTAssertEqual(entry.context.cleanupContextSource, "keyboard")
            XCTAssertEqual(entry.context.cleanupContextCharacters, "Unser geheimer Projektkontext".count)
            let encoded = String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
            XCTAssertFalse(encoded.contains("geheimer"))
            await fireDeadline(clock)

            controller.startRecording(styleOverride: .polished)
            try await recording(controller, session: session, prewarms: 2)
            try await finish(controller)
            XCTAssertEqual(session.prompts.count, 2)
            XCTAssertEqual(session.prompts.last, CleanupPrompt.make(prepared, vocabulary: terms))
            try await dispose(controller, clock: clock)
            await env.dispose()
        }
    }
}
