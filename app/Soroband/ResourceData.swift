import Foundation

/// The span History and the popover ask the core about for one resource.
struct ResourceQuery: Equatable {
    var interval: DateInterval
    var previous: DateInterval?
    var step: HistoryStep
    var measure: ResourceMeasure

    /// The resource page of `range` around `anchor`: the same span, comparison and bars as the
    /// data page's, on every network.
    static func make(
        range: HistoryRange, anchor: Date, measure: ResourceMeasure, firstHour: Date?, now: Date, calendar: Calendar
    ) -> ResourceQuery {
        let data = HistoryQuery.make(
            range: range, anchor: anchor, network: nil, firstHour: firstHour, now: now, calendar: calendar)
        return ResourceQuery(interval: data.interval, previous: data.previous, step: data.step, measure: measure)
    }

    /// As the core's `soroband_resource_history_json` reads it.
    var json: String {
        func time(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970.rounded(.down)) }
        var fields = [
            "\"start\": \(time(interval.start))", "\"end\": \(time(interval.end))", "\"step\": \"\(step.rawValue)\"",
            "\"measure\": \"\(measure.rawValue)\"",
        ]
        if let previous {
            fields.append("\"previous_start\": \(time(previous.start))")
            fields.append("\"previous_end\": \(time(previous.end))")
        }
        return "{\(fields.joined(separator: ", "))}"
    }
}

/// Resources summed over a span: the Mac's, a bar's or an app's (`core/.../resource_history.rs`).
struct ResourceSum: Decodable, Equatable {
    /// CPU and billed CPU time in nanoseconds.
    var cpu: UInt64 = 0
    var billed: UInt64 = 0
    /// Disk bytes read and written.
    var read: UInt64 = 0
    var written: UInt64 = 0
    /// Nanojoules.
    var energy: UInt64 = 0
    /// The average and peak footprint, in bytes.
    var footprint: UInt64 = 0
    var peak: UInt64 = 0
    /// Some of it came from the fallback, which leaves out other users' and root processes.
    var fallback = false

    static let zero = ResourceSum()

    /// The number `measure` compares by, as the core's: CPU time, the average footprint, bytes
    /// read and written, or energy.
    func value(_ measure: ResourceMeasure) -> UInt64 {
        switch measure {
        case .cpu: cpu
        case .memory: footprint
        case .disk: read &+ written
        case .energy: energy
        }
    }
}

/// The core's answer to a `ResourceQuery`.
struct ResourceHistoryData: Decodable, Equatable {
    struct Bar: Decodable, Equatable {
        let firstHour: Int64
        let sum: ResourceSum

        enum CodingKeys: String, CodingKey { case firstHour = "first_hour" }

        init(firstHour: Int64, sum: ResourceSum) {
            self.firstHour = firstHour
            self.sum = sum
        }

        init(from decoder: Decoder) throws {
            firstHour = try decoder.container(keyedBy: CodingKeys.self).decode(Int64.self, forKey: .firstHour)
            sum = try ResourceSum(from: decoder)
        }
    }

    struct App: Decodable, Equatable {
        let id: String
        let name: String
        let sum: ResourceSum

        enum CodingKeys: String, CodingKey { case id, name }

        init(id: String, name: String, sum: ResourceSum) {
            self.id = id
            self.name = name
            self.sum = sum
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            sum = try ResourceSum(from: decoder)
        }
    }

    struct Day: Decodable, Equatable {
        let firstHour: Int64
        let value: UInt64

        enum CodingKeys: String, CodingKey {
            case value
            case firstHour = "first_hour"
        }
    }

    struct Cell: Decodable, Equatable {
        /// 0 is Sunday.
        let weekday: Int
        let hour: Int
        let value: UInt64
    }

    let firstHour: Int64?
    let total: ResourceSum
    /// The measure over the previous span.
    let previous: UInt64?
    let bars: [Bar]
    /// Largest by the measure first.
    let apps: [App]
    let busiestDay: Day?
    /// Local days in the span with resources stored.
    let days: Int
    let heatmap: [Cell]

    static let empty = ResourceHistoryData(
        firstHour: nil, total: .zero, previous: nil, bars: [], apps: [], busiestDay: nil, days: 0, heatmap: [])

    enum CodingKeys: String, CodingKey {
        case total, previous, bars, apps, days, heatmap
        case firstHour = "first_hour"
        case busiestDay = "busiest_day"
    }
}

extension ResourceSum {
    enum CodingKeys: String, CodingKey {
        case cpu, billed, read, written, energy, footprint, peak, fallback
    }
}

/// The minute record over a span (`soroband_resource_minutes_json`).
struct MinuteRecord: Decodable, Equatable {
    /// One minute's gauges.
    struct Minute: Decodable, Equatable {
        let start: Int64
        let cpuBusy: Double?
        let memoryUsed: UInt64?
        /// The percent of memory available.
        let memoryLevel: Int?
        /// 1 normal, 2 warning, 4 critical.
        let pressure: Int?
        let volumeFree: UInt64?
        let volumeSize: UInt64?
        let fallback: Bool

        init(
            start: Int64, cpuBusy: Double?, memoryUsed: UInt64?, memoryLevel: Int?, pressure: Int?,
            volumeFree: UInt64?, volumeSize: UInt64?, fallback: Bool = false
        ) {
            self.start = start
            self.cpuBusy = cpuBusy
            self.memoryUsed = memoryUsed
            self.memoryLevel = memoryLevel
            self.pressure = pressure
            self.volumeFree = volumeFree
            self.volumeSize = volumeSize
            self.fallback = fallback
        }

        /// The core writes each minute as an array, so a day of them stays small.
        init(from decoder: Decoder) throws {
            var fields = try decoder.unkeyedContainer()
            start = try fields.decode(Int64.self)
            cpuBusy = try fields.decodeIfPresent(Double.self)
            memoryUsed = try fields.decodeIfPresent(UInt64.self)
            memoryLevel = try fields.decodeIfPresent(Int.self)
            pressure = try fields.decodeIfPresent(Int.self)
            volumeFree = try fields.decodeIfPresent(UInt64.self)
            volumeSize = try fields.decodeIfPresent(UInt64.self)
            fallback = try fields.decode(Bool.self)
        }

        /// The gauges as the engine published them then, for `ResourceSettings.reading`.
        var gauges: Gauges {
            Gauges(
                on: true, cpuBusy: cpuBusy, memoryUsed: memoryUsed, memoryLevel: memoryLevel, pressure: pressure,
                volumeFree: volumeFree, volumeSize: volumeSize, fallback: fallback)
        }
    }

    /// The earliest minute the record keeps.
    let firstMinute: Int64?
    let minutes: [Minute]

    enum CodingKeys: String, CodingKey {
        case minutes
        case firstMinute = "first_minute"
    }

    static func query(from start: Date, to end: Date, volume: String) -> String {
        let volume = String(data: (try? JSONEncoder().encode(volume)) ?? Data("\"/\"".utf8), encoding: .utf8) ?? "\"/\""
        return
            "{\"start\": \(Int64(start.timeIntervalSince1970)), \"end\": \(Int64(end.timeIntervalSince1970)), \"volume\": \(volume)}"
    }
}

/// One minute's busiest apps (`soroband_resource_minute_apps_json`).
struct MinuteApps: Decodable, Equatable {
    struct App: Decodable, Equatable {
        let id: String
        let name: String
        /// CPU time in nanoseconds over the minute, footprint in bytes, or bytes written.
        let value: UInt64
    }

    var cpu: [App] = []
    var memory: [App] = []
    var written: [App] = []
}
