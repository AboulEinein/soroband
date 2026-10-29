import Foundation
import Testing

@testable import Soroband

/// The popover's hourly bars and History card, from stored usage worked out by hand.
struct PopoverSummaryTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// 2026-10-27 00:00 UTC, and 21:30 that day.
    static let todayStart = Date(timeIntervalSince1970: 1_793_059_200)
    static let now = todayStart.addingTimeInterval(21.5 * 3600)

    func bar(hoursIn: Double, _ bytes: UInt64, from start: Date = todayStart) -> HistoryData.Bar {
        HistoryData.Bar(
            firstHour: Int64(start.timeIntervalSince1970 + hoursIn * 3600), network: 1, rx: bytes, tx: 0)
    }

    func data(_ bars: [HistoryData.Bar]) -> HistoryData {
        HistoryData(
            firstHour: nil, interfaces: .zero, previous: nil, bars: bars, networks: [], apps: [], busiestDay: nil,
            heatmap: [])
    }

    /// 100 bytes at 9:00 and 50 at 20:00 are stored; the live total says 400 moved today, so the
    /// hour in progress (21:00) holds the 250 not stored yet, and later hours have not happened.
    @Test func theHourInProgressTakesWhatTheLiveTotalCountsBeyondTheStoredHours() {
        let summary = PopoverSummary.make(
            hours: data([bar(hoursIn: 9, 100), bar(hoursIn: 20, 50)]), days: data([]), todayStart: Self.todayStart,
            now: Self.now, calendar: Self.calendar)
        let hours = summary.hours(today: 400, now: Self.now)
        #expect(hours.count == 24)
        #expect(hours[9] == 100)
        #expect(hours[20] == 50)
        #expect(hours[21] == 250)
        #expect(hours[22] == nil && hours[23] == nil)
        // Stored ahead of a live total that has not caught up: never below what is stored.
        #expect(summary.hours(today: 120, now: Self.now)[21] == 0)
    }

    /// The week is the last 7 calendar days, today last; the month starts on the 1st, so 25 Oct
    /// counts in both and 30 Sep in neither.
    @Test func historyEntryHoldsTheLastSevenDaysAndTheMonth() {
        let day = { (offset: Int) in Self.calendar.date(byAdding: .day, value: offset, to: Self.todayStart)! }
        let days = data([
            bar(hoursIn: 10, 7, from: day(-27)),  // 30 Sep
            bar(hoursIn: 10, 5, from: day(-6)),  // 21 Oct
            bar(hoursIn: 10, 2, from: day(-2)),  // 25 Oct
            bar(hoursIn: 10, 3, from: day(0)),  // 27 Oct
            bar(hoursIn: 10, 1, from: day(-20)),  // 7 Oct
        ])
        let summary = PopoverSummary.make(
            hours: data([]), days: days, todayStart: Self.todayStart, now: Self.now, calendar: Self.calendar)
        #expect(summary.week == [5, 0, 0, 0, 2, 0, 3])
        #expect(summary.month == 11)
    }

    /// The days query must reach back to the 1st late in a month, and six days back early in one.
    @Test func theDaysQueryCoversTheMonthAndTheWeek() {
        let queries = PopoverSummary.queries(
            network: 1, historyNetwork: nil, todayStart: Self.todayStart, now: Self.now, calendar: Self.calendar)
        #expect(queries.hours.network == 1 && queries.hours.step == .hour)
        #expect(queries.hours.interval.duration == 24 * 3600)
        #expect(queries.days.network == nil && queries.days.step == .day)
        // History opens on one network: the card's days follow it.
        let one = PopoverSummary.queries(
            network: 1, historyNetwork: 1, todayStart: Self.todayStart, now: Self.now, calendar: Self.calendar)
        #expect(one.days.network == 1)
        #expect(queries.days.interval.start == Self.calendar.date(from: DateComponents(year: 2026, month: 10, day: 1)))
        let third = Self.calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 12))!
        let early = PopoverSummary.queries(
            network: 1, historyNetwork: nil, todayStart: third, now: third, calendar: Self.calendar)
        #expect(early.days.interval.start == Self.calendar.date(from: DateComponents(year: 2026, month: 10, day: 28)))
    }

    /// New York falls back on 1 Nov 2026: that day has 25 hours, and the hour in progress in the
    /// 25th must still be its own bar, not past the end of the day.
    @Test func theDayClocksGoBackHasTwentyFiveHours() {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let midnight = newYork.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let lastHour = midnight.addingTimeInterval(24.5 * 3600)
        let queries = PopoverSummary.queries(
            network: 1, historyNetwork: nil, todayStart: midnight, now: lastHour, calendar: newYork)
        #expect(queries.hours.interval.duration == 25 * 3600)
        let summary = PopoverSummary.make(
            hours: data([bar(hoursIn: 3, 10, from: midnight)]), days: data([]), todayStart: midnight, now: lastHour,
            calendar: newYork)
        let hours = summary.hours(today: 40, now: lastHour)
        #expect(hours.count == 25)
        #expect(hours[24] == 30)
        // It springs forward on 8 Mar 2026: 23 hours, so 23 bars and the last labelled 11 PM.
        let march = newYork.date(from: DateComponents(year: 2026, month: 3, day: 8))!
        #expect(PopoverSummary.dayHours(todayStart: march, calendar: newYork) == 23)
    }
}
