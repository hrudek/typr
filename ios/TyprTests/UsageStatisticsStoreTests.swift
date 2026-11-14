import Darwin
import XCTest
@testable import Typr

@MainActor
final class UsageStatisticsStoreTests: XCTestCase {
    private var root: URL!
    private var clock: Date!
    private var store: UsageStatisticsStore!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        clock = Date(timeIntervalSince1970: 1_800_000_000)
        store = UsageStatisticsStore(directory: root, now: { [unowned self] in self.clock },
                                     timeZone: { TimeZone(secondsFromGMT: 0)! })
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }
    private func batch(_ snapshot: UsageStatisticsSnapshot, writer: UsageWriter? = nil, count: UInt64 = 1) -> UsageBatch {
        var value = UsageTotals(); value.directGraphemes = count
        return .init(generation: snapshot.generation,
                     writer: writer ?? .init(id: UUID(), beganAt: clock, sequence: 1),
                     days: [.init(id: snapshot.dayID(clock), totals: value)], heat: [])
    }
    private var file: URL { root.appendingPathComponent("statistics-v1.json") }

    func testTwoWritersReadModifyWriteAndDuplicateAcknowledgements() throws {
        let initial = try store.snapshot()
        let other = UsageStatisticsStore(directory: root, now: { [unowned self] in self.clock })
        let first = batch(initial, count: 2)
        let second = batch(initial, count: 3)
        try store.apply(first); try other.apply(second)
        try other.apply(first) // Lost acknowledgement: same writer/sequence must be a no-op.
        XCTAssertEqual(try store.snapshot().totals(lastDays: 90, at: clock).directGraphemes, 5)
        let next = batch(initial, writer: .init(id: first.writer.id, beganAt: first.writer.beganAt, sequence: 2), count: 4)
        try other.apply(next); try store.apply(first)
        XCTAssertEqual(try store.snapshot().totals(lastDays: 90, at: clock).directGraphemes, 9)
    }
    func testCorruptionIsNotZeroHistoryAndExplicitResetRepairsIt() throws {
        _ = try store.snapshot()
        try Data("not JSON".utf8).write(to: file)
        XCTAssertThrowsError(try store.snapshot()) { XCTAssertEqual($0 as? UsageStatisticsStore.Failure, .corrupt) }
        let fresh = try store.reset()
        XCTAssertTrue(fresh.days.isEmpty)
        XCTAssertEqual(try store.snapshot().generation, fresh.generation)
    }
    func testOversizedDataRejectedAndResetCanRepairSize() throws {
        let initial = try store.snapshot()
        try Data(repeating: 0, count: UsageStatisticsStore.maximumBytes + 1).write(to: file)
        XCTAssertThrowsError(try store.snapshot()) { XCTAssertEqual($0 as? UsageStatisticsStore.Failure, .corrupt) }
        let fresh = try store.reset()
        XCTAssertNotEqual(fresh.generation, initial.generation)
        XCTAssertEqual(try store.snapshot().generation, fresh.generation)
        XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, UsageStatisticsStore.maximumBytes)
    }
    func testSymlinkRejectedAndResetReplacesLinkWithoutTouchingTarget() throws {
        _ = try store.snapshot()
        // Keep the target outside the store directory and use a future-schema payload:
        // reset must neither follow it to read a header nor overwrite it.
        let target = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: target) }
        let bytes = Data("{\"schemaVersion\":2}".utf8)
        try bytes.write(to: target)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertThrowsError(try store.snapshot()) { XCTAssertEqual($0 as? UsageStatisticsStore.Failure, .corrupt) }
        let fresh = try store.reset()
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        XCTAssertEqual(try store.snapshot().generation, fresh.generation)
        let info = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        XCTAssertEqual(info.isSymbolicLink, false)
        XCTAssertEqual(info.isRegularFile, true)
    }
    func testDanglingSymlinkRejectedAndResetDoesNotCreateTarget() throws {
        _ = try store.snapshot()
        let target = root.appendingPathComponent("missing-target")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertThrowsError(try store.snapshot()) { XCTAssertEqual($0 as? UsageStatisticsStore.Failure, .corrupt) }
        let fresh = try store.reset()
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try store.snapshot().generation, fresh.generation)
    }
    func testFutureSchemaCannotBeOverwrittenEvenByReset() throws {
        _ = try store.snapshot()
        let bytes = Data("{\"schemaVersion\":2}".utf8)
        try bytes.write(to: file)
        XCTAssertThrowsError(try store.snapshot()) { XCTAssertEqual($0 as? UsageStatisticsStore.Failure, .newerSchema) }
        XCTAssertThrowsError(try store.reset()) { XCTAssertEqual($0 as? UsageStatisticsStore.Failure, .newerSchema) }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    func testInvalidDecodedCountsAndDatesRejected() throws {
        let initial = try store.snapshot()
        let data = try JSONEncoder().encode(initial)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var invalid = UsageTotals(); invalid.directGraphemes = 1; invalid.timedGraphemes = 2
        let day = UsageDay(id: "2026-99-99", totals: invalid)
        json["days"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([day]))
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        XCTAssertThrowsError(try store.snapshot())
    }
    func testSequentialKeyboardSessionsKeepCollectingBeyondWriterCapacity() throws {
        let layout = KeyboardLayout(width: 393)
        for index in 0..<40 {
            let session = UsageStatisticsSession(store: store,
                now: { [unowned self] in self.clock }, automaticallyFlush: false)
            session.direct("a ")
            session.recordHeat(point: CGPoint(x: 20, y: 20), layout: layout)
            session.flush()
            XCTAssertNil(session.lastError, "Session \(index) must persist")
            session.flush() // A repeated flush must not double count.
            let snapshot = try store.snapshot()
            XCTAssertEqual(snapshot.totals(lastDays: 90, at: clock).directGraphemes, UInt64((index + 1) * 2))
            XCTAssertEqual(snapshot.totals(lastDays: 90, at: clock).completedWords, UInt64(index + 1))
            XCTAssertEqual(snapshot.heat.flatMap(\.cells).reduce(0, +), UInt64(index + 1))
            XCTAssertLessThanOrEqual(snapshot.writers.count, 16)
            clock += 1
        }
    }
    func testWriterCapacityEvictsOldestStartAndRetainsOtherRetryWatermarks() throws {
        let initial = try store.snapshot()
        let oldest = batch(initial)
        clock += 1
        let newer = (0..<15).map { _ in batch(initial) }
        // Insertion order deliberately differs from start order.
        try store.apply(newer[0]); try store.apply(oldest)
        for value in newer.dropFirst() { try store.apply(value) }
        let incoming = batch(initial)
        try store.apply(incoming)
        for value in newer { try store.apply(value) }
        try store.apply(incoming)
        let snapshot = try store.snapshot()
        XCTAssertEqual(snapshot.writers.count, 16)
        XCTAssertFalse(snapshot.writers.contains { $0.id == oldest.writer.id })
        XCTAssertEqual(snapshot.totals(lastDays: 90, at: clock).directGraphemes, 17)
    }
    func testCaptureCapacityRejectsRatherThanEvictsLiveReceipts() throws {
        var snapshot = try store.snapshot()
        snapshot.captures = (0..<2048).map { _ in .init(id: UUID(), beganAt: clock) }
        try JSONEncoder().encode(snapshot).write(to: file)
        let token = try store.beginCapture()
        XCTAssertThrowsError(try store.recordCapture(token, words: 2, seconds: 3)) {
            XCTAssertEqual($0 as? UsageStatisticsStore.Failure, .capacity)
        }
        XCTAssertEqual(try store.snapshot().captures.count, 2048)
    }
    func testExpiredReceiptsCannotBeReplayedAfterPruningAndClockRollbackRejects() throws {
        let initial = try store.snapshot()
        let old = batch(initial)
        let token = try store.beginCapture()
        try store.apply(old); try store.recordCapture(token, words: 1, seconds: 1)
        clock += 86401
        XCTAssertThrowsError(try store.apply(old)) { XCTAssertEqual($0 as? UsageStatisticsStore.Failure, .expired) }
        XCTAssertThrowsError(try store.recordCapture(token, words: 1, seconds: 1))
        XCTAssertEqual(try store.snapshot().writers.count, 0)
        clock = old.writer.beganAt.addingTimeInterval(-1)
        XCTAssertThrowsError(try store.apply(old))
    }
    func testRetentionHasNinetyCalendarDaysWithoutInventedHistory() throws {
        let initial = try store.snapshot()
        try store.apply(batch(initial))
        XCTAssertEqual(try store.snapshot().days.count, 1)
        clock = initial.calendar.date(byAdding: .day, value: 89, to: clock)!
        XCTAssertEqual(try store.snapshot().days.count, 1)
        clock = initial.calendar.date(byAdding: .day, value: 1, to: clock)!
        XCTAssertEqual(try store.snapshot().days.count, 0)
    }
    func testStatisticsResetDoesNotTouchLearningOrTechnicalCounters() throws {
        _ = try store.snapshot()
        for name in ["learning-v1.json", "diagnostics-v1.json"] {
            try Data(name.utf8).write(to: root.appendingPathComponent(name))
        }
        let old = try store.snapshot()
        _ = try store.reset()
        XCTAssertNotEqual(try store.snapshot().generation, old.generation)
        for name in ["learning-v1.json", "diagnostics-v1.json"] {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), Data(name.utf8))
        }
    }
    func testLockContentionDoesNotOverwriteAnything() throws {
        let initial = try store.snapshot()
        let before = try Data(contentsOf: file)
        let lock = try FileHandle(forWritingTo: root.appendingPathComponent("statistics.lock"))
        defer { try? lock.close() }
        XCTAssertEqual(flock(lock.fileDescriptor, LOCK_EX | LOCK_NB), 0)
        defer { _ = flock(lock.fileDescriptor, LOCK_UN) }
        XCTAssertThrowsError(try store.apply(batch(initial)))
        XCTAssertEqual(try Data(contentsOf: file), before)
    }
    func testFrozenRetryBatchKeepsNewEditsAfterWriteFailure() throws {
        var tick: TimeInterval = 1
        let session = UsageStatisticsSession(store: store, monotonic: { tick },
                                             now: { [unowned self] in self.clock }, automaticallyFlush: false)
        session.direct("a")
        // Hold the cross-process lock so the first flush freezes, but cannot commit.
        let lock = try FileHandle(forWritingTo: root.appendingPathComponent("statistics.lock"))
        XCTAssertEqual(flock(lock.fileDescriptor, LOCK_EX | LOCK_NB), 0)
        session.flush()
        XCTAssertNotNil(session.lastError)
        _ = flock(lock.fileDescriptor, LOCK_UN); try lock.close()
        tick += 1; session.direct("b")
        session.flush(); session.flush()
        XCTAssertNil(session.lastError)
        XCTAssertEqual(try store.snapshot().totals(lastDays: 90, at: clock).directGraphemes, 2)
    }
    func testCommittedBatchWithLostAcknowledgementRetriesExactContentsAndKeepsNewEdits() throws {
        var failOnce = true
        let failing = UsageStatisticsStore(directory: root, now: { [unowned self] in self.clock }, afterCommit: {
            if failOnce { failOnce = false; throw CocoaError(.fileWriteUnknown) }
        })
        var tick: TimeInterval = 100
        let session = UsageStatisticsSession(store: failing, monotonic: { tick },
                                             now: { [unowned self] in self.clock }, automaticallyFlush: false)
        session.direct("a"); session.flush()
        XCTAssertNotNil(session.lastError)
        XCTAssertEqual(try store.snapshot().totals(lastDays: 90, at: clock).directGraphemes, 1)
        tick += 1; session.direct("b"); session.flush()
        XCTAssertNil(session.lastError)
        XCTAssertEqual(try store.snapshot().totals(lastDays: 90, at: clock).directGraphemes, 2)
    }
    func testCapacityFailureAbandonsFrozenBatchButKeepsNewerEvents() throws {
        var failure: UsageStatisticsStore.Failure? = .unavailable
        let failing = UsageStatisticsStore(directory: root, now: { [unowned self] in self.clock }, afterCommit: {
            if let failure { throw failure }
        })
        let session = UsageStatisticsSession(store: failing,
            now: { [unowned self] in self.clock }, automaticallyFlush: false)
        session.direct("a"); session.flush()
        XCTAssertNotNil(session.lastError)
        session.direct("b")
        failure = .capacity
        session.flush() // The old frozen batch fails; b remains pending.
        XCTAssertEqual(session.lastError as? UsageStatisticsStore.Failure, .capacity)
        failure = nil
        session.direct("c"); session.flush()
        XCTAssertNil(session.lastError)
        XCTAssertEqual(try store.snapshot().totals(lastDays: 90, at: clock).directGraphemes, 3)
    }
    func testCaptureReceiptSurvivesLostAcknowledgement() throws {
        var failOnce = true
        let failing = UsageStatisticsStore(directory: root, now: { [unowned self] in self.clock }, afterCommit: {
            if failOnce { failOnce = false; throw CocoaError(.fileWriteUnknown) }
        })
        let recorder = UsageDictationRecorder(store: failing)
        recorder.success(recorder.beginCapture(), recognized: "one two", delivered: "One two.", seconds: 3)
        XCTAssertNotNil(recorder.lastError)
        recorder.flush()
        XCTAssertNil(recorder.lastError)
        let totals = try store.snapshot().totals(lastDays: 90, at: clock)
        XCTAssertEqual(totals.dictations, 1)
        XCTAssertEqual(totals.dictatedWords, 2)
        XCTAssertEqual(totals.recordingSeconds, 3)
    }
    func testNoAppGroupReportsUnavailableInsteadOfEmptyStatistics() {
        XCTAssertThrowsError(try UsageStatisticsStore(directory: nil).snapshot()) {
            XCTAssertEqual($0 as? UsageStatisticsStore.Failure, .unavailable)
        }
    }
}
