import CoreGraphics
import XCTest
@testable import Typr

@MainActor
final class UsageStatisticsTests: XCTestCase {
    private var directory: URL!
    private var wall: Date!
    private var tick: TimeInterval = 100
    private var store: UsageStatisticsStore!
    private var session: UsageStatisticsSession!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        wall = ISO8601DateFormatter().date(from: "2026-03-28T22:59:59Z")!
        store = UsageStatisticsStore(directory: directory, now: { [unowned self] in self.wall },
                                     timeZone: { TimeZone(identifier: "Europe/Berlin")! })
        session = UsageStatisticsSession(store: store, monotonic: { [unowned self] in self.tick },
                                         now: { [unowned self] in self.wall }, automaticallyFlush: false)
    }
    override func tearDown() async throws {
        session = nil; store = nil
        try? FileManager.default.removeItem(at: directory)
    }
    private func totals() throws -> UsageTotals {
        session.flush()
        return try store.snapshot().totals(lastDays: 90, at: wall)
    }

    func testTimingPopulationAndFourSecondBoundary() throws {
        session.direct("a") // First action has no attributable interval.
        tick += 4; session.direct("b")
        tick += 4.001; session.direct("c")
        tick += 1; session.deletion()
        tick += 1; session.direct("é")
        let value = try totals()
        XCTAssertEqual(value.directGraphemes, 4)
        XCTAssertEqual(value.timedGraphemes, 2)
        XCTAssertEqual(value.typingSeconds, 6, accuracy: 0.00001)
        XCTAssertEqual(value.deletions, 1)
        XCTAssertNil(value.typingWPM)
    }
    func testSessionSuggestionAndNonMonotonicClockBreakTimeChain() throws {
        session.direct("a")
        tick += 1; session.suggestion("hello", boundaryOriginal: nil)
        tick += 1; session.direct("b")
        session.endSession()
        tick += 1; session.direct("c")
        tick -= 10; session.direct("d")
        tick += 1; session.direct("e")
        let value = try totals()
        XCTAssertEqual(value.directGraphemes, 5)
        XCTAssertEqual(value.timedGraphemes, 1)
        XCTAssertEqual(value.typingSeconds, 1)
        XCTAssertEqual(value.suggestions, 1)
        XCTAssertEqual(value.completedWords, 1)
    }
    func testWordsCorrectionAndBoundarySuggestionsDoNotDoubleCount() throws {
        session.direct("teh")
        session.direct(" ", boundaryReplacement: "the")
        session.direct(" ") // Double-space period is still one direct space.
        session.direct("foo")
        session.direct(" ", boundaryReplacement: "for example") // A split correction.
        session.direct("ba")
        session.suggestion("example bar", boundaryOriginal: "example ba")
        let value = try totals()
        XCTAssertEqual(value.completedWords, 4) // the, for, example, bar
        XCTAssertEqual(value.directGraphemes, 11)
        XCTAssertEqual(value.suggestions, 1)
    }
    func testWordSegmentationAndUnfinishedWords() throws {
        XCTAssertEqual(UsageWordTracker.count("can't co-operate 123 élan …"), 4)
        XCTAssertEqual(UsageWordTracker.count("foo--bar - ' ."), 2)
        session.direct("unfinished")
        session.endSession()
        session.direct(" ")
        XCTAssertEqual(try totals().completedWords, 0)
        session.direct("cat")
        session.deletion(); session.deletion(); session.deletion()
        session.direct(" ")
        XCTAssertEqual(try totals().completedWords, 0)
    }
    func testMidnightIntervalBelongsToEndDayAndFixedTimeZoneSurvivesDST() throws {
        wall = ISO8601DateFormatter().date(from: "2026-03-28T22:59:59Z")!
        session.direct("a")
        wall += 2; tick += 2; session.direct("b")
        session.flush()
        let snapshot = try store.snapshot()
        XCTAssertEqual(snapshot.days.map(\.id), ["2026-03-28", "2026-03-29"])
        XCTAssertEqual(snapshot.days[0].totals.typingSeconds, 0)
        XCTAssertEqual(snapshot.days[1].totals.typingSeconds, 2)
        XCTAssertEqual(snapshot.days[1].totals.timedGraphemes, 1)
        XCTAssertEqual(snapshot.retainedDayIDs(at: wall).count, 90)
        let springDay = snapshot.calendar.startOfDay(for: wall)
        let nextDay = try XCTUnwrap(snapshot.calendar.date(byAdding: .day, value: 1, to: springDay))
        XCTAssertEqual(nextDay.timeIntervalSince(springDay), 23 * 3600)
        let elsewhere = UsageStatisticsStore(directory: directory, now: { [unowned self] in self.wall },
                                             timeZone: { TimeZone(identifier: "Pacific/Honolulu")! })
        XCTAssertEqual(try elsewhere.snapshot().timeZone, "Europe/Berlin")
    }
    func testResetRejectsUnflushedTypingAndRunningCapture() throws {
        session.direct("old")
        let capture = try store.beginCapture()
        let generation = try store.reset().generation
        session.flush()
        XCTAssertEqual(try store.snapshot().generation, generation)
        XCTAssertEqual(try store.snapshot().days.count, 0)
        XCTAssertThrowsError(try store.recordCapture(capture, words: 10, seconds: 20)) {
            XCTAssertEqual($0 as? UsageStatisticsStore.Failure, .staleGeneration)
        }
        session.direct("new ")
        XCTAssertEqual(try totals().completedWords, 1)
    }
    func testDictationSuccessIsTextFreeIdempotentAndIndependentOfHistory() throws {
        let recorder = UsageDictationRecorder(store: store)
        let token = recorder.beginCapture()
        recorder.success(token, recognized: "one two co-operate", delivered: "Different output", seconds: 20)
        recorder.success(token, recognized: "one two co-operate", delivered: "Different output", seconds: 20)
        recorder.success(recorder.beginCapture(), recognized: " ", delivered: "", seconds: 20)
        recorder.success(recorder.beginCapture(), recognized: "word", delivered: "  ", seconds: 20)
        recorder.success(recorder.beginCapture(), recognized: "word", delivered: "word", seconds: .nan)
        let value = try totals()
        XCTAssertEqual(value.dictations, 1)
        XCTAssertEqual(value.dictatedWords, 3)
        XCTAssertEqual(value.recordingSeconds, 20)
        let data = try Data(contentsOf: directory.appendingPathComponent("statistics-v1.json"))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("co-operate")); XCTAssertFalse(json.contains("Different output"))
    }
    func testHeatRejectsOffboardNonfiniteAndUnsupportedLayouts() throws {
        let layout = KeyboardLayout(width: 393)
        session.recordHeat(point: CGPoint(x: 50, y: 90), layout: layout)
        session.recordHeat(point: CGPoint(x: -1, y: 90), layout: layout)
        session.recordHeat(point: CGPoint(x: CGFloat.infinity, y: 90), layout: layout)
        session.recordHeat(point: CGPoint(x: 393, y: 90), layout: layout)
        session.recordHeat(point: CGPoint(x: 50, y: 90), layout: KeyboardLayout(width: 393, layer: .numbers))
        session.flush()
        let heat = try XCTUnwrap(store.snapshot().heat.first)
        XCTAssertEqual(heat.cells.count, 64 * 24)
        XCTAssertEqual(heat.cells.reduce(0, +), 1)
        XCTAssertEqual(heat.geometryVersion, 1)
    }
    func testHeatWithTheNumberRowLandsOnTheSameLetterCells() throws {
        let off = KeyboardLayout(width: 393)
        let on = KeyboardLayout(width: 393, numberRow: true)
        for layout in [off, on] {
            let q = try XCTUnwrap(layout.key(.character("q")))
            session.recordHeat(point: CGPoint(x: q.frame.midX, y: q.frame.midY), layout: layout)
        }
        let one = try XCTUnwrap(on.key(.character("1")))
        session.recordHeat(point: CGPoint(x: one.frame.midX, y: one.frame.midY), layout: on)
        session.flush()
        let heat = try XCTUnwrap(store.snapshot().heat.first)
        XCTAssertEqual(try store.snapshot().heat.count, 1)
        XCTAssertEqual(heat.cells.filter { $0 > 0 }, [2], "both q taps share one cell; the digit is off the board")
    }

    func testLayoutRetentionAndSessionRecentLabelsAreBounded() throws {
        for width in [320, 350, 375, 393, 430] {
            session.recordHeat(point: CGPoint(x: 50, y: 90), layout: KeyboardLayout(width: CGFloat(width)))
            session.flush()
        }
        XCTAssertEqual(try store.snapshot().heat.count, 4)
        let layout = KeyboardLayout(width: 393)
        for _ in 0..<150 { session.validatedLabel(.init(point: .zero, letter: "a"), layout: layout) }
        XCTAssertEqual(session.recentLabels.count, 128)
        session.validatedLabel(.init(point: .zero, letter: "a"), layout: KeyboardLayout(width: 320))
        XCTAssertEqual(session.recentLabels.count, 1)
        session.endSession()
        XCTAssertTrue(session.recentLabels.isEmpty)
    }
}

/// Pure totals checks need neither a statistics store nor a typing session.
@MainActor
final class UsageTotalsTests: XCTestCase {
    func testSaturationDoesNotOverflow() {
        var value = UsageTotals(); value.directGraphemes = UsageTotals.ceiling
        value.typingSeconds = Double(UsageTotals.ceiling)
        var delta = UsageTotals(); delta.directGraphemes = UsageTotals.ceiling; delta.typingSeconds = 2
        value.add(delta)
        XCTAssertEqual(value.directGraphemes, UsageTotals.ceiling)
        XCTAssertEqual(value.typingSeconds, Double(UsageTotals.ceiling))
        XCTAssertTrue(value.isValid)
    }
}
