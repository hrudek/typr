import XCTest
@testable import Typr

@MainActor
final class CleanupTestSession: CleanupSession {
    var prepareCount = 0
    var cleanCount = 0
    var cancelled = false
    var result = "Die Katze sitzt auf der Matte"
    var shouldThrow = false
    var failure: (any Error)?
    var suspend = false
    var gate: CheckedContinuation<String, Never>?
    var suspendPrewarm = false
    var prewarmGate: CheckedContinuation<Void, Never>?
    /// Model calls that have not returned. The coordinator's model task continues in the same
    /// main-actor job after the return, so 0 also means that task has released its reservation.
    private(set) var cleansInFlight = 0
    func prewarm() async {
        prepareCount += 1
        if suspendPrewarm { await withCheckedContinuation { prewarmGate = $0 } }
        cancelled = Task.isCancelled
    }
    var acceptance: ((String, String) -> Bool)?
    func accepts(_ cleaned: String, for transcript: String) -> Bool { acceptance?(cleaned, transcript) ?? true }
    /// Every prompt this session was asked, in order.
    private(set) var prompts: [String] = []
    func generate(_ prompt: String) async throws -> String {
        prompts.append(prompt)
        cleanCount += 1
        cleansInFlight += 1
        defer { cleansInFlight -= 1 }
        if let failure { throw failure }
        if shouldThrow { throw CocoaError(.coderInvalidValue) }
        if suspend {
            let value = await withCheckedContinuation { gate = $0 }
            cancelled = Task.isCancelled
            return value
        }
        return result
    }
    func resume() { gate?.resume(returning: result); gate = nil }
}

@MainActor
struct CleanupTestCleaner: TyprTranscriptCleaning {
    var unavailableReason: String?
    let session: CleanupTestSession
    func makeSession() -> any CleanupSession { session }
}

@MainActor
final class CleanupTestBackground: BackgroundTaskStarting {
    var expiration: (@MainActor () -> Void)?
    var invalid = false
    var expireInBegin = false
    var begins = 0
    var ends: [Int] = []
    func begin(expiration: @escaping @MainActor () -> Void) -> Int? {
        begins += 1
        self.expiration = expiration
        if expireInBegin { expiration() }
        return invalid ? nil : begins
    }
    func end(_ token: Int) { ends.append(token) }
}

@MainActor
final class CleanupTestSleeper {
    var gates: [CheckedContinuation<Void, Error>] = []
    func sleep(_ duration: Duration) async throws {
        try await withCheckedThrowingContinuation { gates.append($0) }
    }
    func fire() { let pending = gates; gates = []; for gate in pending { gate.resume() } }
}

@MainActor
final class TyprCleanupTests: XCTestCase {
    private let raw = "Die Katze sitzt auf der Mathe"

    private func drain() async { for _ in 0..<30 { await Task.yield() } }

    func testCleanupSettingPersists() {
        let name = "cleanup.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = TyprSettings(defaults: defaults)
        settings.aiCleanup = true
        XCTAssertTrue(TyprSettings(defaults: defaults).aiCleanup)
        XCTAssertEqual(defaults.object(forKey: "typr.aiCleanup") as? Bool, true)
    }

    func testDeadlineRetainsReservationUntilIgnoringModelCompletes() async {
        let session = CleanupTestSession(); session.suspend = true
        let bg = CleanupTestBackground(), clock = CleanupTestSleeper()
        let deps = TranscriptCleanupDependencies(cleaner: CleanupTestCleaner(session: session), background: bg, isEnabled: { true }, sleep: clock.sleep)
        let coordinator = CleanupCoordinator()
        let a = CleanupJob(session: session, background: bg); a.begin()
        let task = Task { await coordinator.clean(raw, job: a, dependencies: deps) }
        await drain()
        clock.fire()
        let value = await task.value
        XCTAssertEqual(value, raw)
        XCTAssertEqual(coordinator.reservedBy, a.id)
        let b = CleanupJob(session: session, background: bg); b.begin()
        let skipped = await coordinator.clean(raw, job: b, dependencies: deps)
        XCTAssertEqual(skipped, raw)
        coordinator.cancel(b.id); coordinator.release(b.id)
        XCTAssertEqual(coordinator.reservedBy, a.id)
        session.resume(); await drain()
        XCTAssertTrue(session.cancelled)
        XCTAssertNil(coordinator.reservedBy)
        session.suspend = false
        let c = CleanupJob(session: session, background: bg); c.begin()
        let cleaned = await coordinator.clean(raw, job: c, dependencies: deps)
        XCTAssertEqual(cleaned, session.result)
        a.finish(); b.finish(); c.finish(); clock.fire(); await drain()
    }

    func testCancellationAndExpiryResolveExactlyOnce() async {
        for expire in [false, true] {
            let session = CleanupTestSession(); session.suspend = true
            let bg = CleanupTestBackground(), clock = CleanupTestSleeper()
            let deps = TranscriptCleanupDependencies(cleaner: CleanupTestCleaner(session: session), background: bg, isEnabled: { true }, sleep: clock.sleep)
            let job = CleanupJob(session: session, background: bg); job.begin()
            let coordinator = CleanupCoordinator()
            let task = Task { await coordinator.clean(raw, job: job, dependencies: deps) }
            await drain()
            if expire { bg.expiration?() } else { task.cancel() }
            let value = await task.value
            XCTAssertEqual(value, raw)
            session.resume(); await drain()
            XCTAssertTrue(session.cancelled)
            job.finish(); bg.expiration?(); job.finish()
            XCTAssertEqual(bg.ends, [1])
            clock.fire(); await drain()
        }
    }

    func testInvalidAndEarlyExpiredLeaseNeverStartModel() async {
        for mode in 0..<2 {
            let bg = CleanupTestBackground(); bg.invalid = mode == 0; bg.expireInBegin = mode == 1
            let session = CleanupTestSession()
            let deps = TranscriptCleanupDependencies(cleaner: CleanupTestCleaner(session: session), background: bg, isEnabled: { true })
            let job = CleanupJob(session: session, background: bg); job.begin()
            let coordinator = CleanupCoordinator()
            let value = await coordinator.clean(raw, job: job, dependencies: deps)
            XCTAssertEqual(value, raw)
            XCTAssertEqual(session.cleanCount, 0)
            job.finish(); job.finish()
            XCTAssertEqual(bg.ends, mode == 0 ? [] : [1])
        }
    }

    func testAdmissionAndPrewarmedThenBusySkip() async {
        let coordinator = CleanupCoordinator(), bg = CleanupTestBackground(), session = CleanupTestSession()
        let job = CleanupJob(session: session, background: bg)
        coordinator.prewarm(job)
        XCTAssertEqual(coordinator.reservedBy, job.id)
        XCTAssertFalse(coordinator.admit(UUID()))
        await drain()
        XCTAssertEqual(session.prepareCount, 1)
        let foreign = UUID()
        XCTAssertTrue(coordinator.admit(foreign))
        job.begin()
        let deps = TranscriptCleanupDependencies(cleaner: CleanupTestCleaner(session: session), background: bg, isEnabled: { true })
        let value = await coordinator.clean(raw, job: job, dependencies: deps)
        XCTAssertEqual(value, raw)
        XCTAssertEqual(session.cleanCount, 0)
        coordinator.release(job.id)
        XCTAssertEqual(coordinator.reservedBy, foreign)
        coordinator.release(foreign); job.finish()
    }

    func testLateDeadlineCannotResolveFollowingJobAndResultRaceIsSingleResolution() async {
        let session = CleanupTestSession(), bg = CleanupTestBackground(), clock = CleanupTestSleeper()
        let deps = TranscriptCleanupDependencies(cleaner: CleanupTestCleaner(session: session), background: bg, isEnabled: { true }, sleep: clock.sleep)
        let coordinator = CleanupCoordinator()
        let a = CleanupJob(session: session, background: bg); a.begin()
        session.suspend = true
        let firstTask = Task { await coordinator.clean(raw, job: a, dependencies: deps) }
        await drain()
        XCTAssertEqual(clock.gates.count, 1)
        session.resume()
        let first = await firstTask.value
        XCTAssertEqual(first, session.result)
        await drain()
        session.suspend = true
        let b = CleanupJob(session: session, background: bg); b.begin()
        let task = Task { await coordinator.clean(raw, job: b, dependencies: deps) }
        await drain()
        // Wake only A's cancelled sleeper; it must not cancel or resolve B.
        if !clock.gates.isEmpty { clock.gates.removeFirst().resume() }
        await drain()
        XCTAssertEqual(coordinator.reservedBy, b.id)
        XCTAssertNotNil(session.gate)
        // Result and deadline become runnable together. Either value is valid, never a double resume.
        session.resume(); clock.fire()
        let second = await task.value
        XCTAssertTrue(second == raw || second == session.result)
        await drain()
        XCTAssertNil(coordinator.reservedBy)
        a.finish(); b.finish()
        XCTAssertEqual(bg.ends, [1, 2])
    }

    func testPrewarmCancellationKeepsSlotUntilActualCompletion() async {
        let session = CleanupTestSession(), bg = CleanupTestBackground()
        session.suspendPrewarm = true
        let coordinator = CleanupCoordinator()
        let job = CleanupJob(session: session, background: bg)
        coordinator.prewarm(job)
        await drain()
        coordinator.cancel(job.id)
        XCTAssertEqual(coordinator.reservedBy, job.id)
        XCTAssertFalse(coordinator.admit(UUID()))
        session.prewarmGate?.resume(); session.prewarmGate = nil
        await drain()
        XCTAssertTrue(session.cancelled)
        XCTAssertNil(coordinator.reservedBy)
    }

    /// As in Hex, any length and language goes to the model: no word count, byte budget or
    /// language admission. Only numbers-only transcripts skip it.
    func testEveryTranscriptButNumbersOnlyReachesTheModel() async {
        for text in ["zwei Worte", "Bonjour", String(repeating: "lang ", count: 600)] {
            let session = CleanupTestSession(), bg = CleanupTestBackground(), clock = CleanupTestSleeper()
            let deps = TranscriptCleanupDependencies(cleaner: CleanupTestCleaner(session: session), background: bg,
                isEnabled: { true }, sleep: clock.sleep)
            let job = CleanupJob(session: session, background: bg); job.begin()
            let value = await CleanupCoordinator().clean(text, job: job, dependencies: deps)
            XCTAssertEqual(value, session.result)
            XCTAssertEqual(session.prompts, [CleanupPrompt.make(text)])
            job.finish(); clock.fire(); await drain()
        }
    }

    func testAlreadyCancelledBeforeRegistrationDoesNotStartModel() async {
        let session = CleanupTestSession(), bg = CleanupTestBackground()
        let deps = TranscriptCleanupDependencies(cleaner: CleanupTestCleaner(session: session), background: bg, isEnabled: { true })
        let job = CleanupJob(session: session, background: bg); job.begin()
        let coordinator = CleanupCoordinator()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await coordinator.clean(raw, job: job, dependencies: deps)
        }
        let value = await task.value
        XCTAssertEqual(value, raw)
        XCTAssertEqual(session.cleanCount, 0)
        XCTAssertNil(coordinator.reservedBy)
        job.finish()
    }
}
