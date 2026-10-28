import Foundation

/// What the History window can show: one calendar period, or everything recorded.
enum HistoryRange: String, CaseIterable, Identifiable {
    case day, week, month, year, all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        case .year: "Year"
        case .all: "All Time"
        }
    }

    /// The calendar period one step of the range covers; nil for All Time.
    var period: Calendar.Component? {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        case .all: nil
        }
    }
}

/// What one bar of the usage chart covers. The raw values are the core's.
enum HistoryStep: String {
    case hour, day, month

    var component: Calendar.Component {
        switch self {
        case .hour: .hour
        case .day: .day
        case .month: .month
        }
    }
}

/// The span the History window asks the core about.
struct HistoryQuery: Equatable {
    var interval: DateInterval
    /// The same elapsed time one period earlier, for the change in the Total tile.
    var previous: DateInterval?
    /// One network, or every network when nil.
    var network: Int64?
    var step: HistoryStep

    /// All Time shows days until history is longer than this, then months.
    static let allTimeDays = 92

    /// The query for `range` around `anchor`.
    /// - `firstHour`: the earliest recorded hour, known from an earlier answer; All Time starts
    ///   there, or at the Unix epoch with month bars when nothing is known yet: a long history then
    ///   needs one read, and a short one, quick to read, a second for its day bars.
    static func make(
        range: HistoryRange, anchor: Date, network: Int64?, firstHour: Date?, now: Date, calendar: Calendar
    ) -> HistoryQuery {
        guard let period = range.period, let interval = calendar.dateInterval(of: period, for: anchor) else {
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            guard let firstHour else {
                return HistoryQuery(
                    interval: DateInterval(start: Date(timeIntervalSince1970: 0), end: end), previous: nil,
                    network: network, step: .month)
            }
            let start = calendar.startOfDay(for: min(firstHour, now))
            let days = calendar.dateComponents([.day], from: start, to: end).day ?? 0
            return HistoryQuery(
                interval: DateInterval(start: start, end: end), previous: nil, network: network,
                step: days > allTimeDays ? .month : .day)
        }
        let elapsed = min(interval.end, now).timeIntervalSince(interval.start)
        // Ends at the shown period's start at the latest: a finished 31-day month after a 30-day
        // one would otherwise count its own first day.
        let previous = calendar.date(byAdding: period, value: -1, to: interval.start).map {
            DateInterval(start: $0, end: min($0.addingTimeInterval(max(0, elapsed)), interval.start))
        }
        let step: HistoryStep = switch range {
        case .day: .hour
        case .year: .month
        case .week, .month, .all: .day
        }
        return HistoryQuery(interval: interval, previous: previous, network: network, step: step)
    }

    /// As the core's `soroband_history_json` reads it.
    var json: String {
        func time(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970.rounded(.down)) }
        var fields = [
            "\"start\": \(time(interval.start))", "\"end\": \(time(interval.end))", "\"step\": \"\(step.rawValue)\"",
        ]
        if let previous {
            fields.append("\"previous_start\": \(time(previous.start))")
            fields.append("\"previous_end\": \(time(previous.end))")
        }
        if let network { fields.append("\"network\": \(network)") }
        return "{\(fields.joined(separator: ", "))}"
    }
}

/// The core's answer to a `HistoryQuery`: totals aggregated in SQL (`core/.../history.rs`).
struct HistoryData: Decodable, Equatable {
    struct Bar: Decodable, Equatable {
        /// The first stored hour in the bar.
        let firstHour: Int64
        let network: Int64
        let rx: UInt64
        let tx: UInt64
    }

    struct NetworkShare: Decodable, Equatable {
        let network: Int64
        let interfaces: ByteCounts
        let apps: ByteCounts
    }

    struct AppShare: Decodable, Equatable {
        let network: Int64
        let id: String
        let name: String
        let rx: UInt64
        let tx: UInt64
    }

    struct Day: Decodable, Equatable {
        let firstHour: Int64
        let bytes: UInt64
    }

    struct Cell: Decodable, Equatable {
        /// 0 is Sunday.
        let weekday: Int
        let hour: Int
        let bytes: UInt64
    }

    let firstHour: Int64?
    /// What crossed the interfaces over the range: its total.
    let interfaces: ByteCounts
    let previous: UInt64?
    let bars: [Bar]
    let networks: [NetworkShare]
    /// Largest app first, each app's networks together.
    let apps: [AppShare]
    let busiestDay: Day?
    let heatmap: [Cell]

    static let empty = HistoryData(
        firstHour: nil, interfaces: .zero, previous: nil, bars: [], networks: [], apps: [], busiestDay: nil,
        heatmap: [])

    enum CodingKeys: String, CodingKey {
        case interfaces, previous, bars, networks, apps, heatmap
        case firstHour = "first_hour"
        case busiestDay = "busiest_day"
    }
}

extension HistoryData.Bar {
    enum CodingKeys: String, CodingKey {
        case network, rx, tx
        case firstHour = "first_hour"
    }
}

extension HistoryData.Day {
    enum CodingKeys: String, CodingKey {
        case bytes
        case firstHour = "first_hour"
    }
}

/// What the History window shows, worked out from the core's answer, so the view only lays it out.
struct HistoryContent: Equatable {
    struct NetworkStyle: Equatable, Identifiable {
        /// 0 for usage booked to no network.
        var id: Int64
        var name: String
        var kind: NetworkKind?
        /// Color slot; nil is the neutral color of no network.
        var slot: Int?
        /// The chart's key and legend text: the name, with " (2)", " (3)" when an earlier network
        /// (or no network) already has that label, since the chart colors by it and names can repeat.
        var label: String

        init(id: Int64, name: String, kind: NetworkKind?, slot: Int?, label: String? = nil) {
            self.id = id
            self.name = name
            self.kind = kind
            self.slot = slot
            self.label = label ?? name
        }
    }

    /// One network's segment of one chart bar.
    struct BarSegment: Equatable, Identifiable {
        var start: Date
        var network: NetworkStyle
        var bytes: UInt64
        /// The segment's place in its stack, in bytes from the axis.
        var low: UInt64
        var high: UInt64

        var id: String { "\(start.timeIntervalSince1970)-\(network.id)" }

        /// Where the segment is drawn: `gap` bytes left free between it and the segment below,
        /// half off each. A segment smaller than its share of the gap is drawn with no height.
        func drawn(gap: UInt64) -> (low: UInt64, high: UInt64) {
            let low = self.low == 0 ? 0 : self.low + gap / 2
            let high = high >= low + gap / 2 ? high - gap / 2 : low
            return (low, max(low, high))
        }
    }

    struct Tooltip: Equatable {
        var start: Date
        var rows: [(network: NetworkStyle, bytes: UInt64)]
        var total: UInt64

        static func == (a: Tooltip, b: Tooltip) -> Bool {
            a.start == b.start && a.total == b.total
                && a.rows.map(\.network) == b.rows.map(\.network) && a.rows.map(\.bytes) == b.rows.map(\.bytes)
        }
    }

    struct NetworkSplit: Equatable, Identifiable {
        var network: NetworkStyle
        var bytes: ByteCounts
        var id: Int64 { network.id }
    }

    struct AppRow: Equatable, Identifiable {
        var id: String
        var title: String
        var icon: PopoverContent.Icon
        var bytes: ByteCounts
        /// Of the range's total.
        var share: Double
        var segments: [PopoverContent.Segment]
        /// Where its bytes went, in network order; shown when the row is expanded.
        var networks: [NetworkSplit]
    }

    struct ShareRow: Equatable, Identifiable {
        var network: NetworkStyle
        var bytes: UInt64
        var share: Double
        var id: Int64 { network.id }
    }

    struct Heatmap: Equatable {
        /// 7 rows in the calendar's week order, each with 24 hours of bytes.
        var rows: [(weekday: String, hours: [UInt64])]
        var peak: (weekday: String, hour: Int, bytes: UInt64)?

        static func == (a: Heatmap, b: Heatmap) -> Bool {
            a.rows.map(\.weekday) == b.rows.map(\.weekday) && a.rows.map(\.hours) == b.rows.map(\.hours)
                && a.peak?.weekday == b.peak?.weekday && a.peak?.hour == b.peak?.hour
                && a.peak?.bytes == b.peak?.bytes
        }
    }

    var title: String
    var subtitle: String
    var range: HistoryRange
    var step: HistoryStep
    var interval: DateInterval
    /// The chart's time axis: the range widened to whole bars, so the first and last bars fit.
    var chartDomain: ClosedRange<Date>

    var total: ByteCounts
    /// The change of the total against the same elapsed time one period earlier; nil when that
    /// period has nothing to compare with.
    var change: Double?
    var elapsedDays: Int
    var dailyAverage: UInt64
    var busiestDay: (start: Date, bytes: UInt64)?

    /// Every network with bytes in the range, in color order: the chart's legend.
    var legend: [NetworkStyle]
    var bars: [BarSegment]
    var tooltips: [Date: Tooltip]
    /// The total over the bars elapsed so far, divided by their number; nil without bytes.
    var barAverage: UInt64?
    var peakBar: UInt64

    var apps: [AppRow]
    /// The raw gap between the interfaces and the apps' sum, as in the popover.
    var overhead: AppRow
    var appsScale: UInt64
    var shares: [ShareRow]
    /// Week and longer ranges only.
    var heatmap: Heatmap?

    static func == (a: HistoryContent, b: HistoryContent) -> Bool {
        a.title == b.title && a.subtitle == b.subtitle && a.range == b.range && a.step == b.step
            && a.interval == b.interval && a.chartDomain == b.chartDomain && a.total == b.total && a.change == b.change
            && a.elapsedDays == b.elapsedDays && a.dailyAverage == b.dailyAverage
            && a.busiestDay?.start == b.busiestDay?.start && a.busiestDay?.bytes == b.busiestDay?.bytes
            && a.legend == b.legend && a.bars == b.bars && a.tooltips == b.tooltips
            && a.barAverage == b.barAverage && a.peakBar == b.peakBar && a.apps == b.apps
            && a.overhead == b.overhead && a.appsScale == b.appsScale && a.shares == b.shares
            && a.heatmap == b.heatmap
    }

    static let allNetworksTitle = "All Networks"

    static func make(
        range: HistoryRange, query: HistoryQuery, data: HistoryData, registry: [RegisteredNetwork], now: Date,
        calendar: Calendar
    ) -> HistoryContent {
        let styles = networkStyles(registry: registry)
        func style(_ id: Int64) -> NetworkStyle {
            styles[id] ?? NetworkStyle(id: id, name: PopoverContent.unknownNetworkName, kind: nil, slot: nil)
        }
        // Colors in registry order, no network last.
        func order(_ id: Int64) -> Int {
            id == 0 ? .max : registry.firstIndex { $0.id == id } ?? .max - 1
        }

        // All Time starts at the first recorded hour.
        var interval = query.interval
        if range == .all, let first = data.firstHour {
            interval = DateInterval(
                start: calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(first))),
                end: max(interval.end, interval.start))
        }
        let elapsedEnd = min(interval.end, now)
        let elapsedDays = max(1, countSteps(.day, from: interval.start, to: elapsedEnd, calendar: calendar))
        let total = data.interfaces
        let change: Double? = data.previous.flatMap { previous in
            previous > 0 ? (Double(total.total) - Double(previous)) / Double(previous) : nil
        }

        // Bars: each network's segment placed in its hour, day or month, stacked in color order.
        var byStart: [Date: [Int64: UInt64]] = [:]
        for bar in data.bars {
            let start = barStart(firstHour: bar.firstHour, step: query.step, calendar: calendar)
            byStart[start, default: [:]][bar.network, default: 0] += bar.rx + bar.tx
        }
        var bars: [BarSegment] = []
        var tooltips: [Date: Tooltip] = [:]
        for (start, perNetwork) in byStart {
            var low: UInt64 = 0
            var rows: [(network: NetworkStyle, bytes: UInt64)] = []
            for (network, bytes) in perNetwork.sorted(by: { order($0.key) < order($1.key) }) where bytes > 0 {
                bars.append(BarSegment(start: start, network: style(network), bytes: bytes, low: low, high: low + bytes))
                rows.append((style(network), bytes))
                low += bytes
            }
            tooltips[start] = Tooltip(start: start, rows: rows, total: low)
        }
        bars.sort { $0.start != $1.start ? $0.start < $1.start : order($0.network.id) < order($1.network.id) }
        let elapsedBars = countSteps(query.step.component, from: interval.start, to: elapsedEnd, calendar: calendar)
        let barTotal = tooltips.values.reduce(0) { $0 + $1.total }

        let legend = Set(data.networks.map(\.network)).union(data.bars.map(\.network))
            .sorted { order($0) < order($1) }.map(style)

        // Apps, one row each, with a segment per network.
        var apps: [AppRow] = []
        var credited = ByteCounts.zero
        for share in data.apps {
            credited.rx += share.rx
            credited.tx += share.tx
            let bytes = ByteCounts(rx: share.rx, tx: share.tx)
            if apps.last?.id != share.id {
                apps.append(AppRow(
                    id: share.id, title: share.name, icon: PopoverContent.icon(forApp: share.id), bytes: .zero,
                    share: 0, segments: [], networks: []))
            }
            apps[apps.count - 1].bytes.rx += share.rx
            apps[apps.count - 1].bytes.tx += share.tx
            apps[apps.count - 1].networks.append(NetworkSplit(network: style(share.network), bytes: bytes))
        }
        for index in apps.indices {
            apps[index].networks.sort { order($0.network.id) < order($1.network.id) }
            apps[index].segments = apps[index].networks.map {
                PopoverContent.Segment(slot: $0.network.slot, bytes: $0.bytes.total)
            }
            apps[index].share = share(apps[index].bytes.total, of: total.total)
        }
        let gap = total.gap(minus: credited)
        let overhead = AppRow(
            id: "overhead", title: PopoverContent.overheadTitle, icon: .overhead, bytes: gap,
            share: share(gap.total, of: total.total), segments: [PopoverContent.Segment(slot: nil, bytes: gap.total)],
            networks: [])

        let shares = data.networks.filter { $0.interfaces.total > 0 }.map {
            ShareRow(network: style($0.network), bytes: $0.interfaces.total, share: share($0.interfaces.total, of: total.total))
        }

        let component = query.step.component
        let domainStart = calendar.dateInterval(of: component, for: interval.start)?.start ?? interval.start
        let lastMoment = interval.end.addingTimeInterval(-1)
        let domainEnd = calendar.dateInterval(of: component, for: lastMoment)?.end ?? interval.end
        let selected = query.network.map(style)
        return HistoryContent(
            title: selected?.name ?? allNetworksTitle,
            subtitle: subtitle(range: range, interval: interval, calendar: calendar),
            range: range,
            step: query.step,
            interval: interval,
            chartDomain: domainStart...max(domainStart, domainEnd),
            total: total,
            change: change,
            elapsedDays: elapsedDays,
            dailyAverage: total.total / UInt64(elapsedDays),
            busiestDay: data.busiestDay.map {
                (calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval($0.firstHour) + 1800)), $0.bytes)
            },
            legend: legend,
            bars: bars,
            tooltips: tooltips,
            barAverage: barTotal > 0 ? barTotal / UInt64(max(1, elapsedBars)) : nil,
            peakBar: tooltips.values.map(\.total).max() ?? 0,
            apps: apps,
            overhead: overhead,
            appsScale: max(apps.first?.bytes.total ?? 0, gap.total, 1),
            shares: shares,
            heatmap: range == .day ? nil : heatmap(data.heatmap, calendar: calendar))
    }

    /// Every network in the registry by id, with its color slot in registry order.
    static func networkStyles(registry: [RegisteredNetwork]) -> [Int64: NetworkStyle] {
        // No network's name is taken first, so a network named like it gets a suffix; a suffixed
        // label skips any label already used, including another network's real name.
        var used: Set<String> = [PopoverContent.unknownNetworkName]
        return Dictionary(uniqueKeysWithValues: registry.enumerated().map { index, network in
            var label = network.name
            var count = 1
            while used.contains(label) {
                count += 1
                label = "\(network.name) (\(count))"
            }
            used.insert(label)
            return (network.id, NetworkStyle(
                id: network.id, name: network.name, kind: network.kind, slot: NetworkColor.slot(forIndex: index),
                label: label))
        })
    }

    /// The start of the hour, day or month a bar covers, from its first stored hour. The core
    /// places an hour by its middle, which matters in a time zone with a half-hour offset.
    static func barStart(firstHour: Int64, step: HistoryStep, calendar: Calendar) -> Date {
        let middle = Date(timeIntervalSince1970: TimeInterval(firstHour) + 1800)
        return calendar.dateInterval(of: step.component, for: middle)?.start ?? middle
    }

    /// The number of hours, days or months from `start` that have begun before `end`.
    static func countSteps(_ component: Calendar.Component, from start: Date, to end: Date, calendar: Calendar) -> Int {
        guard end > start else { return 0 }
        let whole = calendar.dateComponents([component], from: start, to: end).value(for: component) ?? 0
        let reached = calendar.date(byAdding: component, value: whole, to: start) ?? end
        return whole + (reached < end ? 1 : 0)
    }

    static func subtitle(range: HistoryRange, interval: DateInterval, calendar: Calendar) -> String {
        var fields = Date.FormatStyle()
        fields.calendar = calendar
        fields.timeZone = calendar.timeZone
        if let locale = calendar.locale { fields.locale = locale }
        var date = Date.FormatStyle(date: .abbreviated, time: .omitted)
        date.calendar = fields.calendar
        date.timeZone = fields.timeZone
        date.locale = fields.locale
        switch range {
        case .day:
            return interval.start.formatted(fields.weekday(.wide).day().month(.wide).year())
        case .month:
            return interval.start.formatted(fields.month(.wide).year())
        case .year:
            return interval.start.formatted(fields.year())
        case .week, .all:
            let last = interval.end.addingTimeInterval(-1)
            return "\(interval.start.formatted(date)) – \(last.formatted(date))"
        }
    }

    private static func share(_ bytes: UInt64, of total: UInt64) -> Double {
        total == 0 ? 0 : Double(bytes) / Double(total)
    }

    private static func heatmap(_ cells: [HistoryData.Cell], calendar: Calendar) -> Heatmap {
        var hours = Array(repeating: Array(repeating: UInt64(0), count: 24), count: 7)
        for cell in cells where (0..<7).contains(cell.weekday) && (0..<24).contains(cell.hour) {
            hours[cell.weekday][cell.hour] += cell.bytes
        }
        let symbols = calendar.shortWeekdaySymbols
        // Weekday 0 is Sunday, as `firstWeekday` 1 is.
        let order = (0..<7).map { ($0 + calendar.firstWeekday - 1) % 7 }
        var peak: (weekday: String, hour: Int, bytes: UInt64)?
        for day in order {
            for hour in 0..<24 where hours[day][hour] > (peak?.bytes ?? 0) {
                peak = (symbols[day], hour, hours[day][hour])
            }
        }
        return Heatmap(rows: order.map { (symbols[$0], hours[$0]) }, peak: peak)
    }
}
