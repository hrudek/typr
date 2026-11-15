import XCTest
import SwiftUI
import UIKit
@testable import Typr

final class ActivityStatisticsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func snapshot(days: Int = 90, zone: String = "UTC") -> UsageStatisticsSnapshot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return UsageStatisticsSnapshot(now: calendar.date(byAdding: .day, value: -(days - 1), to: now)!, timeZone: calendar.timeZone)
    }
    private func date(_ offset: Int, in snapshot: UsageStatisticsSnapshot) -> Date {
        snapshot.calendar.date(byAdding: .day, value: offset, to: now)!
    }

    func testAllRangesIncludeTodayAndExcludeOlderAndFutureDays() {
        for range in StatisticsRange.allCases {
            var saved = snapshot()
            var totals = UsageTotals(); totals.completedWords = 11; totals.directGraphemes = 55
            for offset in [-range.rawValue, -range.rawValue + 1, 0, 1] {
                saved.add(totals, day: saved.dayID(date(offset, in: saved)))
            }
            let result = ActivityStatistics(snapshot: saved, range: range, now: now)
            XCTAssertEqual(result.days.count, range.rawValue)
            XCTAssertEqual(result.totals.completedWords, 22)
            XCTAssertEqual(result.today?.completedWords, 11)
            XCTAssertEqual(result.activeDays(.typing), 2)
        }
    }

    func testBeforeCollectionIsUnavailableAndMissingCollectedDaysAreZero() {
        let saved = snapshot(days: 3)
        let result = ActivityStatistics(snapshot: saved, range: .week, now: now)
        XCTAssertEqual(result.collectedDays, 3)
        XCTAssertTrue(result.days.prefix(4).allSatisfy { $0.totals == nil })
        XCTAssertTrue(result.days.suffix(3).allSatisfy { $0.totals == UsageTotals() })
        XCTAssertNil(result.averageWords(.typing))
        XCTAssertNil(result.totals.typingWPM)
        XCTAssertNil(result.totals.dictationWPM)
    }

    func testNoPopulationWhenClockPrecedesCollection() {
        let result = ActivityStatistics(snapshot: snapshot(days: 1), range: .week, now: now.addingTimeInterval(-86400))
        XCTAssertEqual(result.collectedDays, 0)
        XCTAssertNil(result.today)
        XCTAssertEqual(result.totals, UsageTotals())
    }

    func testSpeedsUseSummedMatchingPopulationsNotMeanOfDailyWPM() throws {
        var saved = snapshot()
        var first = UsageTotals()
        first.directGraphemes = 600; first.timedGraphemes = 600; first.typingSeconds = 60
        first.completedWords = 99; first.dictatedWords = 100; first.recordingSeconds = 60; first.dictations = 1
        var second = UsageTotals()
        second.directGraphemes = 600; second.timedGraphemes = 600; second.typingSeconds = 600
        second.completedWords = 1; second.dictatedWords = 100; second.recordingSeconds = 600; second.dictations = 1
        saved.add(first, day: saved.dayID(now))
        saved.add(second, day: saved.dayID(date(-1, in: saved)))
        let result = ActivityStatistics(snapshot: saved, range: .week, now: now)
        XCTAssertEqual(try XCTUnwrap(result.totals.typingWPM), 1200 * 12 / 660.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(result.totals.dictationWPM), 200 * 60 / 660.0, accuracy: 1e-9)
        XCTAssertNotEqual(result.totals.typingWPM, (first.typingWPM! + second.typingWPM!) / 2)
        XCTAssertEqual(result.totals.completedWords, 100)
        XCTAssertEqual(result.totals.dictatedWords, 200)
    }

    func testSubthresholdDaysCanReachThresholdTogetherWithoutDailySpeedPoints() {
        var saved = snapshot()
        var totals = UsageTotals()
        totals.directGraphemes = 100; totals.timedGraphemes = 90; totals.typingSeconds = 30
        totals.dictatedWords = 60; totals.recordingSeconds = 30; totals.dictations = 1
        for offset in [0, -1] { saved.add(totals, day: saved.dayID(date(offset, in: saved))) }
        let result = ActivityStatistics(snapshot: saved, range: .week, now: now)
        XCTAssertEqual(result.totals.typingWPM, 36)
        XCTAssertEqual(result.totals.dictationWPM, 120)
        XCTAssertTrue(result.days.compactMap(\.totals).allSatisfy { $0.typingWPM == nil && $0.dictationWPM == nil })
    }

    func testActiveDaysIncludeDeleteOnlyAndZeroWordSuccessfulDictation() {
        var saved = snapshot()
        var deletion = UsageTotals(); deletion.deletions = 1
        var suggestion = UsageTotals(); suggestion.suggestions = 1; suggestion.completedWords = 2
        var punctuation = UsageTotals(); punctuation.dictations = 1; punctuation.recordingSeconds = 60
        saved.add(deletion, day: saved.dayID(now))
        saved.add(suggestion, day: saved.dayID(date(-1, in: saved)))
        saved.add(punctuation, day: saved.dayID(date(-2, in: saved)))
        let result = ActivityStatistics(snapshot: saved, range: .week, now: now)
        XCTAssertEqual(result.activeDays(.typing), 2)
        XCTAssertEqual(result.averageWords(.typing), 1)
        XCTAssertEqual(result.activeDays(.dictation), 1)
        XCTAssertEqual(result.averageWords(.dictation), 0)
        XCTAssertEqual(result.totals.dictationWPM, 0) // measured zero, not missing time
    }

    func testPopulationSelectorsNeverUseWordCompletionsForTypingSpeed() {
        var totals = UsageTotals()
        totals.directGraphemes = 110; totals.timedGraphemes = 100; totals.completedWords = 999
        totals.typingSeconds = 60; totals.dictatedWords = 50; totals.recordingSeconds = 59
        XCTAssertEqual(ActivityKind.typing.words(totals), 999)
        XCTAssertEqual(ActivityKind.typing.speed(totals), 20)
        XCTAssertNil(ActivityKind.dictation.speed(totals))
        totals.recordingSeconds = 60
        XCTAssertEqual(ActivityKind.dictation.speed(totals), 50)
        XCTAssertEqual(ActivityKind.typing.seconds(totals), 60)
    }

    func testCalendarDaysAcrossDSTAndFixedCollectionZone() throws {
        var saved = snapshot(zone: "America/New_York")
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-10T01:00:00Z"))
        saved = UsageStatisticsSnapshot(now: date.addingTimeInterval(-10 * 86400), timeZone: saved.calendar.timeZone)
        let result = ActivityStatistics(snapshot: saved, range: .week, now: date)
        XCTAssertEqual(result.days.last?.id, "2026-03-09") // not UTC's March 10
        XCTAssertEqual(Set(result.days.map(\.id)).count, 7)
        let gaps = zip(result.days, result.days.dropFirst()).map { $1.date.timeIntervalSince($0.date) }
        XCTAssertTrue(gaps.contains(23 * 3600))
        XCTAssertEqual(result.calendar.timeZone.identifier, "America/New_York")
    }

    func testDurationAndNeutralFormatting() {
        XCTAssertEqual(ActivityStatistics.speedText(nil), "—")
        XCTAssertEqual(ActivityStatistics.speedText(0), "0")
        XCTAssertEqual(ActivityStatistics.duration(59.9), "59s")
        XCTAssertEqual(ActivityStatistics.duration(60), "1m 0s")
        XCTAssertEqual(ActivityStatistics.duration(3661), "1h 1m")
    }

    @MainActor
    func testFixturesContainRealisticDailyAggregatesAndNeutralSparseSpeeds() throws {
        for fixture in [StatisticsFixture.empty, .sparse, .populated] {
            let saved = try XCTUnwrap(fixture.snapshots().0)
            XCTAssertTrue(saved.isValid)
            let result = ActivityStatistics(snapshot: saved, range: .quarter, now: StatisticsFixture.referenceDate)
            if fixture == .populated {
                XCTAssertEqual(result.collectedDays, 90)
                XCTAssertGreaterThan(result.activeDays(.typing), 60)
                XCTAssertNotNil(result.totals.typingWPM)
                XCTAssertNotNil(result.totals.dictationWPM)
            } else {
                XCTAssertNil(result.totals.typingWPM)
                XCTAssertNil(result.totals.dictationWPM)
            }
        }
        XCTAssertNil(StatisticsFixture.unavailable.snapshots().0)
    }

    @MainActor
    func testResetClearsEveryActivityPeriodButPreservesSavedAim() throws {
        let model = StatisticsModel(directory: nil, defaults: nil, fixture: .populated)
        let learning = model.learning?.model
        model.reset(); model.refresh()
        let saved = try XCTUnwrap(model.usage)
        for range in StatisticsRange.allCases {
            let result = ActivityStatistics(snapshot: saved, range: range, now: model.presentationDate(at: Date()))
            XCTAssertEqual(result.totals, UsageTotals())
            XCTAssertNil(result.totals.typingWPM)
            XCTAssertEqual(result.activeDays(.dictation), 0)
        }
        XCTAssertEqual(model.learning?.model, learning)
    }

    @MainActor
    func testRefreshSeesExternalWritesAndStoreFailureRemovesOldHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = StatisticsModel(directory: directory, defaults: nil)
        let store = UsageStatisticsStore(directory: directory)
        try store.recordCapture(store.beginCapture(), words: 123, seconds: 60)
        model.refresh() // same path as activation / returning from keyboard
        let saved = try XCTUnwrap(model.usage)
        XCTAssertEqual(ActivityStatistics(snapshot: saved, range: .week, now: Date()).totals.dictatedWords, 123)
        try Data("corrupt".utf8).write(to: directory.appendingPathComponent("statistics-v1.json"))
        model.refresh()
        XCTAssertNil(model.usage)
        XCTAssertNotNil(model.problem)
        model.reset(); model.refresh()
        XCTAssertNotNil(model.usage)
        XCTAssertNil(model.problem)
    }

    @MainActor
    func testAllFourSectionsHostEmptySparsePopulatedAndUnavailable() {
        XCTAssertEqual(StatisticsSection.allCases.map(\.rawValue), ["Overview", "Typing", "Dictation", "Taps"])
        // Keep a default-initializer sentinel: the matrix below always supplies a section.
        let defaultHost = UIHostingController(rootView: StatisticsView(fixture: .populated)
            .environment(\.dynamicTypeSize, .accessibility3))
        let defaultSize = defaultHost.sizeThatFits(in: CGSize(width: 320, height: 4000))
        XCTAssertTrue(defaultSize.width.isFinite && defaultSize.height.isFinite)
        XCTAssertLessThanOrEqual(defaultSize.width, 320.5)
        for section in StatisticsSection.allCases {
            for fixture in [StatisticsFixture.empty, .sparse, .populated, .unavailable] {
                let host = UIHostingController(rootView: StatisticsView(fixture: fixture, section: section)
                    .environment(\.dynamicTypeSize, .accessibility3))
                let size = host.sizeThatFits(in: CGSize(width: 320, height: 4000))
                XCTAssertTrue(size.width.isFinite && size.height.isFinite)
                XCTAssertLessThanOrEqual(size.width, 320.5)
            }
        }
    }

    @MainActor
    func testEveryHistoryModeAndPeriodHostsAtSmallWidth() throws {
        let saved = try XCTUnwrap(StatisticsFixture.populated.snapshots().0)
        for section in [StatisticsSection.overview, .typing, .dictation] {
            for range in StatisticsRange.allCases {
                for metric in ActivityMetric.allCases {
                    let view = ActivityStatisticsView(snapshot: saved, section: section, now: StatisticsFixture.referenceDate,
                                                      range: .constant(range), metric: .constant(metric))
                    let host = UIHostingController(rootView: view)
                    let size = host.sizeThatFits(in: CGSize(width: 280, height: 10000))
                    XCTAssertTrue(size.width.isFinite && size.height.isFinite)
                    XCTAssertLessThanOrEqual(size.width, 280.5)
                }
            }
        }
    }
}
