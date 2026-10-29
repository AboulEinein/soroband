import Foundation

/// What the popover reads from the database when it opens: today on the current network hour by
/// hour, for the hero card's bars, and the History card's totals. Stored usage trails the engine
/// by up to a minute (it writes once a minute), so the hour in progress is taken from the live
/// total instead (`hours(today:now:)`).
struct PopoverSummary: Equatable {
    /// The start of today (the reset hour) and the bytes stored for each of its hours on the
    /// current network: 24, or 23 and 25 on the days clocks change.
    var todayStart: Date
    var storedHours: [UInt64]
    /// Bytes on the History card's network (every network when it opens on all of them) for each
    /// of the last 7 calendar days, oldest first, today last.
    var week: [UInt64]
    /// The same since the start of this calendar month.
    var month: UInt64

    /// The hours from `todayStart` to the next day's reset hour.
    static func dayHours(todayStart: Date, calendar: Calendar) -> Int {
        let end = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart.addingTimeInterval(86_400)
        return Int((end.timeIntervalSince(todayStart) / 3600).rounded())
    }

    /// The two queries the summary is read from: today's hours on `network`, and the days of
    /// `historyNetwork` (every network when nil) from the earlier of the month's start and six days
    /// ago.
    static func queries(network: Int64, historyNetwork: Int64?, todayStart: Date, now: Date, calendar: Calendar)
        -> (hours: HistoryQuery, days: HistoryQuery)
    {
        let today = calendar.startOfDay(for: now)
        let weekStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? today
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        let hours = TimeInterval(dayHours(todayStart: todayStart, calendar: calendar) * 3600)
        return (
            HistoryQuery(
                interval: DateInterval(start: todayStart, duration: hours), previous: nil, network: network,
                step: .hour),
            HistoryQuery(
                interval: DateInterval(start: min(weekStart, monthStart), end: tomorrow), previous: nil,
                network: historyNetwork, step: .day)
        )
    }

    /// Reads the summary; nil when the database cannot be read. Runs off the main thread: on a
    /// long history the two reads take tens of milliseconds.
    static func load(
        network: Int64, historyNetwork: Int64?, todayStart: Date, now: Date = .now, calendar: Calendar = .current
    ) -> PopoverSummary? {
        let queries = queries(
            network: network, historyNetwork: historyNetwork, todayStart: todayStart, now: now, calendar: calendar)
        guard let hours = Core.history(queries.hours), let days = Core.history(queries.days) else { return nil }
        return make(hours: hours, days: days, todayStart: todayStart, now: now, calendar: calendar)
    }

    static func make(hours: HistoryData, days: HistoryData, todayStart: Date, now: Date, calendar: Calendar)
        -> PopoverSummary
    {
        var stored = Array(repeating: UInt64(0), count: dayHours(todayStart: todayStart, calendar: calendar))
        for bar in hours.bars {
            let index = Int((TimeInterval(bar.firstHour) - todayStart.timeIntervalSince1970) / 3600)
            if stored.indices.contains(index) { stored[index] += bar.rx + bar.tx }
        }
        var byDay: [Date: UInt64] = [:]
        for bar in days.bars {
            byDay[HistoryContent.barStart(firstHour: bar.firstHour, step: .day, calendar: calendar), default: 0] +=
                bar.rx + bar.tx
        }
        let today = calendar.startOfDay(for: now)
        let week = (0..<7).reversed().map { back in
            calendar.date(byAdding: .day, value: -back, to: today).flatMap { byDay[$0] } ?? 0
        }
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? today
        let month = byDay.filter { $0.key >= monthStart }.values.reduce(0, +)
        return PopoverSummary(todayStart: todayStart, storedHours: stored, week: week, month: month)
    }

    /// Today's hours on the current network, nil for hours still to come. The hour in progress
    /// holds what `today` (the live total) counts beyond the earlier stored hours, so it does not
    /// lag the hero number; an earlier hour's last unwritten minute shows in it until the summary
    /// is read again, at the next hour or the next open.
    func hours(today: UInt64, now: Date) -> [UInt64?] {
        let current = Int(now.timeIntervalSince(todayStart) / 3600)
        return storedHours.indices.map { hour in
            if hour > current { return nil }
            if hour < current { return storedHours[hour] }
            let before = storedHours[..<hour].reduce(0, +)
            return max(storedHours[hour], today > before ? today - before : 0)
        }
    }
}
