import XCTest
@testable import Typr

@MainActor
final class DictationLogCleanupTests: XCTestCase {
    /// The model task runs first and suspends on the session gate; the deadline task created in the
    /// same step then registers its sleep.
    private func modelSuspended(_ session: CleanupTestSession, _ sleeper: CleanupTestSleeper) async throws {
        try await waitForState("model and deadline suspended") { session.gate != nil && !sleeper.gates.isEmpty }
    }

    /// The model task records a late answer and releases the reservation in the job that returns
    /// from `clean`, so no model call in flight means the late answer is recorded.
    private func modelReturned(_ session: CleanupTestSession) async throws {
        try await waitForState("model call returned") { session.cleansInFlight == 0 }
    }

    /// Before `dispose` removes defaults and files: the fired deadline task returns in its next
    /// main-actor job, and no model task may still hold the reservation.
    private func drain(_ job: CleanupJob, _ sleeper: CleanupTestSleeper, _ coordinator: CleanupCoordinator,
                       _ session: CleanupTestSession) async throws {
        job.finish(); sleeper.fire(); await mainActorBarrier()
        try await waitForState("cleanup drained") { coordinator.reservedBy == nil && session.cleansInFlight == 0 }
    }

    func testAcceptedUnchangedRejectedAndEmptyAnswers() async throws {
        for mode in 0..<5 {
            let env = LogTestEnvironment(), session = CleanupTestSession()
            let background = CleanupTestBackground(), sleeper = CleanupTestSleeper()
            let coordinator = CleanupCoordinator()
            let observer = CleanupTestObserver()
            let start = ContinuousClock.now
            var time = start
            let deps = TranscriptCleanupDependencies(cleaner: CleanupTestCleaner(session: session),
                language: CleanupTestLanguage(), background: background, isEnabled: { true },
                sleep: sleeper.sleep, observer: observer, clock: { time })
            let raw = mode == 4 ? "bullet cat\nnew line dog" : "Die Katze sitzt auf der Mathe"
            session.result = ["Die Katze sitzt auf der Matte", raw, "Die Katze kostet 999", "  \t", "bullet cat new line dog"][mode]
            let recording = env.begin()
            let job = CleanupJob(session: session, background: background)
            job.begin()
            let work = Task { await coordinator.clean(raw, style: mode == 4 ? .notes : .polished,
                job: job, dependencies: deps, diagnostics: recording) }
            // No wait: the model answers at once and the entry is written before `clean` returns.
            let value = await work.value
            time = start.advanced(by: .milliseconds(50))
            let entry = try XCTUnwrap(env.store.entries.first)
            XCTAssertEqual(entry.aiAnswer?.text, session.result)
            XCTAssertEqual(entry.modelMilliseconds, 0)
            XCTAssertEqual(observer.events.count, 1)
            if mode < 2 {
                XCTAssertEqual(entry.answerUse, "accepted")
                XCTAssertEqual(entry.cleanupChanged, mode == 0)
                XCTAssertEqual(entry.cleanupOutcome, "completed")
                XCTAssertEqual(value, session.result)
            } else {
                XCTAssertEqual(value, raw)
                let reason: CleanupFailureReason = mode == 2 ? .guardRejected(.newValue)
                    : (mode == 3 ? .emptyOutput : .guardRejected(.notesLineAnchors))
                XCTAssertEqual(entry.answerUse, "rejected(\(reason.label)); not used")
                XCTAssertEqual(entry.cleanupOutcome, "failed(\(reason.label))")
            }
            try await drain(job, sleeper, coordinator, session)
            await env.dispose()
        }
    }

    func testDeadlineOrExpiryThenFinishedLateAnswerAndBusyBelongToOwnEntry() async throws {
        for expire in [false, true] {
            let env = LogTestEnvironment(), session = CleanupTestSession()
            session.suspend = true
            let background = CleanupTestBackground(), sleeper = CleanupTestSleeper(), observer = CleanupTestObserver()
            let coordinator = CleanupCoordinator(), a = env.begin()
            let start = ContinuousClock.now
            var time = start
            let deps = TranscriptCleanupDependencies(cleaner: CleanupTestCleaner(session: session),
                language: CleanupTestLanguage(), background: background, isEnabled: { true },
                sleep: sleeper.sleep, observer: observer, clock: { time })
            let job = CleanupJob(session: session, background: background)
            job.begin()
            let work = Task { await coordinator.clean("Die Katze sitzt auf der Mathe", style: .polished,
                job: job, dependencies: deps, diagnostics: a) }
            try await modelSuspended(session, sleeper)
            time = start.advanced(by: .seconds(4))
            if expire { background.expiration?() } else { sleeper.fire() }
            let output = await work.value
            XCTAssertEqual(output, "Die Katze sitzt auf der Mathe")
            a.finish(text: output, beforeSpelling: output)
            let finished = try XCTUnwrap(env.store.entries.first)
            let b = env.begin()
            let bOutput = await coordinator.clean("another plain transcript", style: .polished,
                job: nil, dependencies: deps, diagnostics: b)
            b.finish(text: bOutput, beforeSpelling: bOutput)
            let bBefore = env.store.entries.first
            time = start.advanced(by: .milliseconds(6_250))
            session.resume(); try await modelReturned(session)
            let late = try XCTUnwrap(env.store.entries.first { $0.id == a.entryID })
            XCTAssertEqual(late.status, .finished)
            XCTAssertEqual(late.aiAnswer?.text, session.result)
            XCTAssertEqual(late.answerUse, "late")
            XCTAssertEqual(late.modelMilliseconds, 6_250)
            XCTAssertEqual(late.cleanupMilliseconds, 4_000)
            XCTAssertEqual(late.finalText, finished.finalText)
            XCTAssertEqual(late.cleanupOutcome, finished.cleanupOutcome)
            XCTAssertEqual(late.answerLabel, expire
                ? "arrived after iOS ended the background time; not used"
                : "arrived after the cleanup deadline; not used")
            XCTAssertEqual(env.store.entries.first, bBefore)
            XCTAssertEqual(bBefore?.cleanupOutcome, "skipped(busy)")
            XCTAssertEqual(observer.events.count, 2) // Late text is not a second resolution.
            XCTAssertNil(coordinator.reservedBy)
            try await drain(job, sleeper, coordinator, session)
            await env.dispose()
        }
    }

    func testClearOffAndCancellationDuringCleanupNeverResurrectText() async throws {
        for mode in 0..<3 {
            let env = LogTestEnvironment(), session = CleanupTestSession()
            session.suspend = true
            let background = CleanupTestBackground(), sleeper = CleanupTestSleeper(), coordinator = CleanupCoordinator()
            let deps = TranscriptCleanupDependencies(cleaner: CleanupTestCleaner(session: session),
                language: CleanupTestLanguage(), background: background, isEnabled: { true }, sleep: sleeper.sleep)
            let job = CleanupJob(session: session, background: background), recording = env.begin()
            job.begin()
            let work = Task { await coordinator.clean("Die Katze sitzt auf der Mathe", style: .polished,
                job: job, dependencies: deps, diagnostics: recording) }
            try await modelSuspended(session, sleeper)
            if mode == 0 { env.store.clear() }
            else if mode == 1 { env.store.setEnabled(false); env.store.setEnabled(true) }
            else { recording.finishIfOpen(.cancelled) }
            coordinator.cancel(job.id)
            _ = await work.value
            session.resume(); try await modelReturned(session)
            if mode == 2 {
                XCTAssertEqual(env.store.entries.first?.status, .cancelled)
                XCTAssertNil(env.store.entries.first?.aiAnswer)
                XCTAssertNil(env.store.entries.first?.cleanupOutcome)
            } else if mode == 1 {
                XCTAssertEqual(env.store.entries.first?.status, .interrupted)
                XCTAssertNil(env.store.entries.first?.aiAnswer)
            } else {
                await env.storage.flush(); await mainActorBarrier() // Save completions hop to the main actor.
                XCTAssertTrue(env.store.entries.isEmpty)
            }
            try await drain(job, sleeper, coordinator, session)
            await env.storage.flush()
            XCTAssertEqual(env.persistedEntryCount, mode == 0 ? 0 : 1)
            await env.dispose()
        }
    }

    func testFailedModelRecordsDurationWithoutInventingAnAnswer() async throws {
        let env = LogTestEnvironment(), coordinator = CleanupCoordinator(), session = CleanupTestSession()
        let background = CleanupTestBackground(), sleeper = CleanupTestSleeper()
        session.failure = CleanupModelError.refused
        let deps = TranscriptCleanupDependencies(cleaner: CleanupTestCleaner(session: session),
            language: CleanupTestLanguage(), background: background, isEnabled: { true }, sleep: sleeper.sleep)
        let recording = env.begin(), job = CleanupJob(session: session, background: background)
        job.begin()
        let raw = "Die Katze sitzt auf der Mathe"
        let output = await coordinator.clean(raw, style: .polished, job: job, dependencies: deps, diagnostics: recording)
        XCTAssertEqual(output, raw)
        XCTAssertEqual(env.store.entries.first?.cleanupOutcome, "failed(refused)")
        XCTAssertNotNil(env.store.entries.first?.modelMilliseconds)
        XCTAssertNil(env.store.entries.first?.aiAnswer)
        try await drain(job, sleeper, coordinator, session)
        await env.dispose()
    }

    func testSkipDiagnosticsAndNoChangeToTextFreeAppGroupSummary() async throws {
        let env = LogTestEnvironment(), coordinator = CleanupCoordinator()
        let session = CleanupTestSession(), background = CleanupTestBackground()
        let diagnostics = CleanupDiagnostics(defaults: env.defaults)
        let deps = TranscriptCleanupDependencies(cleaner: CleanupTestCleaner(session: session),
            language: CleanupTestLanguage(), background: background, isEnabled: { true }, observer: diagnostics)
        let recording = env.begin()
        coordinator.recordSkip(.verbatim, dependencies: deps, diagnostics: recording)
        XCTAssertEqual(env.store.entries.first?.cleanupOutcome, "skipped(verbatim)")
        let summary = try XCTUnwrap(env.defaults.dictionary(forKey: CleanupDiagnostics.key))
        XCTAssertEqual(Set(summary.keys), Set(["summary", "at", "deadline"]))
        XCTAssertNil(env.defaults.object(forKey: "recognized"))
        XCTAssertNil(env.store.entries.first?.aiAnswer)
        await env.dispose()
    }
}
