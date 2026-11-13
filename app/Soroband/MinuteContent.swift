import Foundation

/// History's Day page with a resource picked (`docs/mockups/resources.html`, 3A): the day minute by
/// minute from the minute record, and the busiest apps of the minute picked.
struct MinuteContent: Equatable {
    struct Point: Equatable, Identifiable {
        var start: Date
        /// The CPU busy share, 0 to 1.
        var cpu: Double?
        /// The memory reading's share, 0 to 1: used, free or pressure, as set.
        var memory: Double?
        var id: Date { start }
    }

    struct List: Equatable, Identifiable {
        var measure: ResourceMeasure
        var title: String
        var rows: [(name: String, value: String)]
        var id: String { title }

        static func == (a: List, b: List) -> Bool {
            a.measure == b.measure && a.title == b.title && a.rows.map(\.name) == b.rows.map(\.name)
                && a.rows.map(\.value) == b.rows.map(\.value)
        }
    }

    var points: [Point]
    /// What each line reads: "CPU busy", "Memory used", "Memory pressure".
    var cpuLabel: String
    var memoryLabel: String
    /// The minute picked, as the lists show it.
    var selected: Date?
    /// "CPU 94% · Mem used 29.1 GB · pressure warning".
    var summary: String?
    var lists: [List]
    /// Days the record keeps, for the line on a day older than it.
    var keptDays: Int

    /// Whether the day has minutes to draw.
    var isEmpty: Bool { points.isEmpty }

    /// - `selected`: the minute picked; the latest of the day when nil.
    static func make(
        record: MinuteRecord, selected: Int64?, apps: MinuteApps?, settings: ResourceSettings, keptDays: Int,
        memoryTotal: UInt64 = Gauges.installedMemory, cores: Int = Gauges.cores
    ) -> MinuteContent {
        let points = record.minutes.map { minute in
            var gauges = minute.gauges
            gauges.memoryTotal = memoryTotal
            return Point(
                start: Date(timeIntervalSince1970: TimeInterval(minute.start)),
                cpu: minute.cpuBusy.map { min(1, max(0, $0)) },
                memory: memoryShare(gauges, settings: settings, memoryTotal: memoryTotal))
        }
        let minute = record.minutes.last { $0.start == selected } ?? (selected == nil ? record.minutes.last : nil)
        var summary: String?
        if let minute {
            var gauges = minute.gauges
            gauges.memoryTotal = memoryTotal
            var parts = [ResourceMeasure.cpu, .memory].compactMap {
                settings.reading($0, gauges: gauges, cores: cores)?.text
            }
            if let pressure = minute.pressure { parts.append("pressure \(pressureWord(pressure))") }
            summary = parts.joined(separator: " · ")
        }
        let core = 60_000_000_000.0
        let lists: [List] =
            apps.map { apps in
                [
                    List(
                        measure: .cpu, title: "CPU",
                        rows: apps.cpu.map { ($0.name, "\(Int((Double($0.value) / core * 100).rounded()))%") }),
                    List(
                        measure: .memory, title: "Memory", rows: apps.memory.map { ($0.name, Format.bytes($0.value)) }),
                    List(
                        measure: .disk, title: "Disk written",
                        rows: apps.written.map { ($0.name, Format.bytes($0.value)) }),
                ].filter { settings.shows($0.measure) }
            } ?? []
        return MinuteContent(
            points: points,
            cpuLabel: settings.cpu == .percent ? "CPU busy" : "CPU busy, in cores",
            memoryLabel: settings.reading(.memory, gauges: .none)?.title ?? "Memory",
            selected: minute.map { Date(timeIntervalSince1970: TimeInterval($0.start)) }, summary: summary,
            lists: lists, keptDays: keptDays)
    }

    /// The memory line's share as the Show setting reads memory.
    static func memoryShare(_ gauges: Gauges, settings: ResourceSettings, memoryTotal: UInt64) -> Double? {
        switch settings.memory {
        case .pressure: gauges.memoryLevel.map { Double(100 - min(100, max(0, $0))) / 100 }
        case .used, .free:
            gauges.memoryUsed.flatMap { used in
                guard memoryTotal > 0 else { return nil }
                let share = min(1, Double(used) / Double(memoryTotal))
                return settings.memory == .used ? share : 1 - share
            }
        }
    }

    static func pressureWord(_ level: Int) -> String {
        switch level {
        case ...1: "normal"
        case 2: "warning"
        default: "critical"
        }
    }

    /// The minute `offset` minutes from `selected` among the record's minutes; the first or last
    /// at either end.
    static func moved(_ record: MinuteRecord, from selected: Int64?, by offset: Int) -> Int64? {
        let starts = record.minutes.map(\.start)
        guard !starts.isEmpty else { return nil }
        let index = selected.flatMap { starts.firstIndex(of: $0) } ?? starts.count - 1
        return starts[min(max(0, index + offset), starts.count - 1)]
    }
}
