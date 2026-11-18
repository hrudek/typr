import XCTest
@testable import Typr

final class DictationHistoryTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int, month: Int = 11, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func row(_ date: Date) -> DictationLogMetadata {
        var entry = DictationLogEntry(context: .init())
        entry.context.createdAt = date
        return DictationLogMetadata(entry)
    }

    func testGroupsByCalendarDayNewestFirst() {
        let now = date(18, 9)
        let rows = [row(date(16, 8)), row(date(18, 7)), row(date(17, 23)), row(date(18, 8)), row(date(17, 1))]
        let days = DictationHistoryDay.group(rows, now: now, calendar: calendar)
        XCTAssertEqual(days.map(\.id), [date(18, 0), date(17, 0), date(16, 0)])
        XCTAssertEqual(days.map(\.title).prefix(2), ["Today", "Yesterday"])
        XCTAssertEqual(days[0].rows.map(\.date), [date(18, 8), date(18, 7)])
        XCTAssertEqual(days[1].rows.map(\.date), [date(17, 23), date(17, 1)])
        XCTAssertEqual(days.flatMap(\.rows).count, rows.count)
    }

    func testOlderDaysShowTheDateAndOtherYearsAddTheYear() {
        let now = date(18, 9)
        let thisYear = DictationHistoryDay.title(for: date(10, 0), now: now, calendar: calendar)
        let lastYear = DictationHistoryDay.title(for: date(10, 0, year: 2025), now: now, calendar: calendar)
        for title in [thisYear, lastYear] {
            XCTAssertFalse(["Today", "Yesterday"].contains(title))
            XCTAssertTrue(title.contains("November"), title)
        }
        XCTAssertFalse(thisYear.contains("2026"), thisYear)
        XCTAssertTrue(lastYear.contains("2025"), lastYear)
    }

    func testYesterdayCrossesMonthBoundary() {
        let now = date(1, 0, month: 12)
        XCTAssertEqual(DictationHistoryDay.title(for: date(30, 23), now: now, calendar: calendar), "Yesterday")
        XCTAssertEqual(DictationHistoryDay.title(for: date(1, 0, month: 12), now: now, calendar: calendar), "Today")
    }

    func testEmptyHistoryHasNoDays() {
        XCTAssertTrue(DictationHistoryDay.group([], now: date(18, 9), calendar: calendar).isEmpty)
    }
}
