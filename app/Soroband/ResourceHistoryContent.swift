import Foundation

/// What History shows with a resource picked (`docs/mockups/resources.html`, 2A): the data page's
/// layout (tiles, the chart over the range, apps with their share, the heatmap) for one measure,
/// on every network, worked out from the core's answer so the view only lays it out.
struct ResourceHistoryContent: Equatable {
    struct Tile: Equatable {
        var title: String
        var value: String
        var detail: String?
    }

    struct Bar: Equatable, Identifiable {
        var start: Date
        var value: UInt64
        /// Memory only, on bars longer than an hour: the highest hourly average in the bar.
        var peak: UInt64?
        var id: Date { start }
    }

    struct AppRow: Equatable, Identifiable {
        var id: String
        var title: String
        var icon: PopoverContent.Icon
        var sum: ResourceSum
        var value: UInt64
        var share: Double
    }

    var measure: ResourceMeasure
    var title: String
    var subtitle: String
    var range: HistoryRange
    var step: HistoryStep
    var chartDomain: ClosedRange<Date>
    var tiles: [Tile]
    /// The measure against the previous period: +0.08 is 8% more.
    var change: Double?
    var chartTitle: String
    var bars: [Bar]
    var barAverage: UInt64?
    var apps: [AppRow]
    var appsScale: UInt64
    /// Week and longer ranges only.
    var heatmap: HistoryContent.Heatmap?
    /// Some hours of the range count only the user's own processes.
    var fallback: Bool

    static func make(
        range: HistoryRange, query: ResourceQuery, data: ResourceHistoryData, now: Date, calendar: Calendar
    ) -> ResourceHistoryContent {
        let measure = query.measure
        var interval = query.interval
        if range == .all, let first = data.firstHour {
            interval = DateInterval(
                start: calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(first))),
                end: max(interval.end, interval.start))
        }
        let elapsedDays = max(
            1, HistoryContent.countSteps(.day, from: interval.start, to: min(interval.end, now), calendar: calendar))
        let total = data.total.value(measure)
        let change: Double? = data.previous.flatMap { previous in
            previous > 0 ? (Double(total) - Double(previous)) / Double(previous) : nil
        }
        let busiest = data.busiestDay.map {
            (
                start: calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval($0.firstHour) + 1800)),
                value: $0.value
            )
        }

        let bars = data.bars.map {
            Bar(
                start: HistoryContent.barStart(firstHour: $0.firstHour, step: query.step, calendar: calendar),
                value: $0.sum.value(measure),
                peak: measure == .memory && query.step != .hour ? $0.sum.peak : nil)
        }
        let elapsedBars = HistoryContent.countSteps(
            query.step.component, from: interval.start, to: min(interval.end, now), calendar: calendar)
        let barTotal = bars.reduce(0) { $0 + $1.value }
        // An average of averages says nothing for memory; the tiles carry its average.
        let barAverage =
            measure == .memory || barTotal == 0 ? nil : barTotal / UInt64(max(1, elapsedBars))

        let apps = data.apps.filter { $0.sum.value(measure) > 0 }
        let appsTotal = apps.reduce(0) { $0 + $1.sum.value(measure) }
        let rows = apps.map {
            AppRow(
                id: $0.id, title: $0.name, icon: PopoverContent.icon(forApp: $0.id), sum: $0.sum,
                value: $0.sum.value(measure),
                share: appsTotal == 0 ? 0 : Double($0.sum.value(measure)) / Double(appsTotal))
        }

        let component = query.step.component
        let domainStart = calendar.dateInterval(of: component, for: interval.start)?.start ?? interval.start
        let domainEnd =
            calendar.dateInterval(of: component, for: interval.end.addingTimeInterval(-1))?.end ?? interval.end
        return ResourceHistoryContent(
            measure: measure, title: measure.label,
            subtitle: "\(HistoryContent.subtitle(range: range, interval: interval, calendar: calendar)) · every app",
            range: range, step: query.step,
            chartDomain: domainStart...max(domainStart, domainEnd),
            tiles: tiles(
                measure: measure, data: data, elapsedDays: elapsedDays,
                // A day's busiest day is the day itself: its busiest hour says more.
                busiest: range == .day
                    ? bars.max { $0.value < $1.value }.map { (start: $0.start, value: $0.value) } : busiest,
                range: range, calendar: calendar,
                // The time the range has run: a day under way, or a day of 23 or 25 hours.
                elapsed: min(interval.end, now).timeIntervalSince(interval.start)),
            change: change,
            chartTitle: chartTitle(measure: measure, step: query.step),
            bars: bars, barAverage: barAverage,
            apps: rows, appsScale: max(rows.first?.value ?? 0, 1),
            heatmap: range == .day ? nil : heatmap(data.heatmap, calendar: calendar),
            fallback: data.total.fallback)
    }

    static func tiles(
        measure: ResourceMeasure, data: ResourceHistoryData, elapsedDays: Int, busiest: (start: Date, value: UInt64)?,
        range: HistoryRange, calendar: Calendar, elapsed: TimeInterval = 86_400
    ) -> [Tile] {
        let total = data.total
        let days = "over \(elapsedDays) day\(elapsedDays == 1 ? "" : "s")"
        let unit = range == .day ? "hour" : "day"
        let busiestTile = Tile(
            title: measure == .memory ? "Fullest \(unit)" : "Busiest \(unit)",
            value: busiest.map { Format.resource($0.value, measure: measure) } ?? "–",
            detail: busiest.map { $0.start.formatted(range == .day ? hourStyle(calendar) : dayStyle(calendar)) })
        let daily = Tile(
            title: "Daily average",
            value: Format.resource(total.value(measure) / UInt64(elapsedDays), measure: measure),
            detail: days)
        switch measure {
        case .cpu:
            return [
                Tile(title: "CPU time", value: Format.cpuTime(nanoseconds: total.cpu)),
                Tile(title: "Billed by daemons", value: Format.cpuTime(nanoseconds: total.billed)),
                range == .day ? Tile(title: "Average load", value: averageLoad(total.cpu, seconds: elapsed)) : daily,
                busiestTile,
            ]
        case .memory:
            return [
                Tile(title: "Average footprint", value: Format.bytes(total.footprint), detail: "every app, summed"),
                Tile(title: "Peak hour", value: Format.bytes(total.peak), detail: "highest hourly average"),
                busiestTile,
                Tile(title: "Days read", value: "\(data.days)"),
            ]
        case .disk:
            return [
                Tile(title: "Read and written", value: Format.bytes(total.read &+ total.written)),
                Tile(title: "Read", value: Format.bytes(total.read)),
                Tile(title: "Written", value: Format.bytes(total.written)),
                range == .day ? busiestTile : daily,
            ]
        case .energy:
            return [
                Tile(title: "Energy", value: Format.energy(nanojoules: total.energy)),
                range == .day ? busiestTile : daily,
                Tile(title: "CPU time", value: Format.cpuTime(nanoseconds: total.cpu)),
            ]
        }
    }

    /// "Monday, Nov 2" in the calendar's time zone and locale.
    static func dayStyle(_ calendar: Calendar) -> Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.weekday(.wide).day().month()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        if let locale = calendar.locale { style.locale = locale }
        return style
    }

    /// "3 PM" in the calendar's time zone and locale.
    static func hourStyle(_ calendar: Calendar) -> Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.hour()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        if let locale = calendar.locale { style.locale = locale }
        return style
    }

    /// CPU time over `seconds` as cores' worth busy on average: "0.4 cores".
    static func averageLoad(_ nanoseconds: UInt64, seconds: TimeInterval) -> String {
        let cores = Double(nanoseconds) / 1e9 / max(1, seconds)
        return "\(Format.cores(cores)) cores"
    }

    static func chartTitle(measure: ResourceMeasure, step: HistoryStep) -> String {
        let per =
            switch step {
            case .hour: "hour"
            case .day: "day"
            case .month: "month"
            }
        return switch measure {
        case .cpu: "CPU time by \(per)"
        case .memory: step == .hour ? "Average footprint by hour" : "Average footprint by \(per), with its peak hour"
        case .disk: "Read and written by \(per)"
        case .energy: "Energy by \(per)"
        }
    }

    static func heatmap(_ cells: [ResourceHistoryData.Cell], calendar: Calendar) -> HistoryContent.Heatmap {
        HistoryContent.heatmap(
            cells.map { HistoryData.Cell(weekday: $0.weekday, hour: $0.hour, bytes: $0.value) }, calendar: calendar)
    }
}
