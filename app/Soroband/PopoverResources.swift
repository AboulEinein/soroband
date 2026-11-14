import Foundation

/// The popover's Resources tab (`docs/mockups/resources.html`, 1A): the Mac's gauges now, then
/// today's apps by one measure, worked out from the core's answers so the view only lays it out.
struct PopoverResources: Equatable {
    struct Gauge: Equatable, Identifiable {
        var measure: ResourceMeasure
        var reading: GaugeReading
        var id: ResourceMeasure { measure }
    }

    struct Row: Equatable, Identifiable {
        var id: String
        var title: String
        var icon: PopoverContent.Icon
        /// The measure's number, which the bar is scaled by.
        var value: UInt64
        /// The value as it reads: "1 h 12 min", "3.1 GB", "18 Wh".
        var text: String
    }

    /// The gauges of the shown resources: CPU, memory and disk, in that order.
    var gauges: [Gauge]
    /// The shown measures, for the picker.
    var measures: [ResourceMeasure]
    /// The measure the apps are listed by.
    var measure: ResourceMeasure
    var rows: [Row]
    /// Apps today beyond the rows, which History lists.
    var hiddenApps: Int
    /// The resource read falls back to the user's own processes, now or in some of today's hours.
    var fallback: Bool
    /// Today's apps have been read.
    var loaded: Bool

    /// Apps listed before "+ N more in History".
    static let visibleApps = 5

    /// - `today`: today's resources per app, by `measure`; nil before they are read.
    static func make(
        settings: ResourceSettings, gauges: Gauges, measure: ResourceMeasure, today: ResourceHistoryData?
    ) -> PopoverResources {
        let shown = settings.shown
        let measure = shown.contains(measure) ? measure : shown.first ?? measure
        // Sorted here too: the answer on screen may still be the last measure's while the next is read.
        let apps = (today?.apps ?? []).filter { $0.sum.value(measure) > 0 }.sorted {
            ($0.sum.value(measure), $1.name) > ($1.sum.value(measure), $0.name)
        }
        return PopoverResources(
            gauges: shown.compactMap { measure in
                settings.reading(measure, gauges: gauges).map { Gauge(measure: measure, reading: $0) }
            },
            measures: shown, measure: measure,
            rows: apps.prefix(visibleApps).map {
                Row(
                    id: $0.id, title: $0.name, icon: PopoverContent.icon(forApp: $0.id),
                    value: $0.sum.value(measure), text: Format.resource($0.sum.value(measure), measure: measure))
            },
            hiddenApps: max(0, apps.count - visibleApps),
            fallback: gauges.fallback || today?.total.fallback == true, loaded: today != nil)
    }

    /// The value that fills a bar: the first row's.
    var scale: UInt64 { max(rows.first?.value ?? 0, 1) }
}

extension Format {
    /// A resource total as it reads in a list: CPU time, a footprint, disk bytes or energy.
    static func resource(_ value: UInt64, measure: ResourceMeasure) -> String {
        switch measure {
        case .cpu: cpuTime(nanoseconds: value)
        case .memory, .disk: bytes(value)
        case .energy: energy(nanojoules: value)
        }
    }

    /// CPU time: "1 h 12 min", "38 min", "45 s", "< 1 s"; whole units, rounded down.
    static func cpuTime(nanoseconds: UInt64) -> String {
        let seconds = nanoseconds / 1_000_000_000
        if seconds == 0 { return "< 1 s" }
        if seconds < 60 { return "\(seconds) s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }

    /// Energy in watt-hours: "18 Wh", "0.4 Wh", "3.1 kWh"; "< 0.1 Wh" below a tenth.
    static func energy(nanojoules: UInt64) -> String {
        let wattHours = Double(nanojoules) / 3.6e12
        if wattHours < 0.1 { return "< 0.1 Wh" }
        if wattHours < 10 {
            return "\(((wattHours * 10).rounded(.down) / 10).formatted(.number.precision(.fractionLength(1)))) Wh"
        }
        if wattHours < 1000 { return "\(Int(wattHours)) Wh" }
        let kilo = (wattHours / 100).rounded(.down) / 10
        return "\(kilo.formatted(.number.precision(.fractionLength(1)))) kWh"
    }
}
