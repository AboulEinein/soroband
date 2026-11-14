import Foundation
import Testing

@testable import Soroband

/// History's resource pages, from answers worked out by hand, in UTC so days are UTC days.
struct ResourceHistoryContentTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    let hour: Int64 = 3600
    let minute: UInt64 = 60_000_000_000
    /// 1 to 3 November 2026, UTC.
    let november1: Int64 = 1_793_491_200

    /// Three days: 60, 120 and 30 minutes of CPU; footprints averaging 8, 10 and 6 GB with
    /// peak hours of 9, 12 and 7 GB. Xcode has most of the CPU, Mail most of the memory.
    func data(_ measure: ResourceMeasure = .cpu) -> ResourceHistoryData {
        let gb: UInt64 = 1_000_000_000
        let days: [(cpu: UInt64, footprint: UInt64, peak: UInt64)] = [
            (60 * minute, 8 * gb, 9 * gb), (120 * minute, 10 * gb, 12 * gb), (30 * minute, 6 * gb, 7 * gb),
        ]
        return ResourceHistoryData(
            firstHour: november1,
            total: ResourceSum(
                cpu: 210 * minute, billed: 10 * minute, read: 3 * gb, written: 5 * gb, footprint: 8 * gb, peak: 12 * gb),
            previous: 300 * minute,
            bars: days.enumerated().map { index, day in
                .init(
                    firstHour: november1 + Int64(index) * 24 * hour,
                    sum: ResourceSum(cpu: day.cpu, footprint: day.footprint, peak: day.peak))
            },
            apps: [
                .init(
                    id: "/Applications/Xcode.app", name: "Xcode", sum: ResourceSum(cpu: 150 * minute, footprint: 2 * gb)
                ),
                .init(
                    id: "/Applications/Mail.app", name: "Mail", sum: ResourceSum(cpu: 60 * minute, footprint: 6 * gb)),
            ],
            // The core measures the busiest day by the page's measure: the 2nd either way.
            busiestDay: .init(firstHour: november1 + 24 * hour, value: measure == .memory ? 10 * gb : 120 * minute),
            days: 3,
            heatmap: [.init(weekday: 1, hour: 9, value: 120 * minute)])
    }

    func content(_ measure: ResourceMeasure, now: Date? = nil) -> ResourceHistoryContent {
        let start = Date(timeIntervalSince1970: TimeInterval(november1))
        let query = ResourceQuery(
            interval: DateInterval(start: start, duration: 30 * 86_400), previous: nil, step: .day, measure: measure)
        return ResourceHistoryContent.make(
            range: .month, query: query, data: data(measure),
            now: now ?? start.addingTimeInterval(3 * 86_400 - 1), calendar: calendar)
    }

    @Test func cpuTilesSumTheRangeAndCompareWithThePreviousOne() {
        let cpu = content(.cpu)
        #expect(cpu.tiles.map(\.value) == ["3 h 30 min", "10 min", "1 h 10 min", "2 h"])
        #expect(cpu.tiles[2].detail == "over 3 days")
        #expect(cpu.tiles[3].detail == "Monday, Nov 2")
        // 210 minutes against 300: 30% less.
        #expect(cpu.change == -0.3)
        #expect(cpu.title == "CPU")
        #expect(cpu.chartTitle == "CPU time by day")
    }

    @Test func barsCarryTheMeasureAndMemoryItsPeakHour() {
        let cpu = content(.cpu)
        #expect(cpu.bars.map(\.value) == [60 * minute, 120 * minute, 30 * minute])
        #expect(cpu.bars.allSatisfy { $0.peak == nil })
        // 210 minutes over the 3 days begun.
        #expect(cpu.barAverage == 70 * minute)
        let memory = content(.memory)
        #expect(memory.bars.map(\.value) == [8_000_000_000, 10_000_000_000, 6_000_000_000])
        #expect(memory.bars.map(\.peak) == [9_000_000_000, 12_000_000_000, 7_000_000_000])
        #expect(memory.barAverage == nil, "an average of averages says nothing")
        #expect(memory.tiles.map(\.value) == ["8 GB", "12 GB", "10 GB", "3"])
    }

    @Test func appsAreSharedByTheMeasure() {
        let cpu = content(.cpu)
        #expect(cpu.apps.map(\.title) == ["Xcode", "Mail"])
        // Typed, so Xcode 26's type checker settles it in time.
        let shares: [Double] = [150.0 / 210, 60.0 / 210]
        #expect(cpu.apps.map(\.share) == shares)
        #expect(cpu.appsScale == 150 * minute)
        let memory = content(.memory)
        #expect(memory.apps.map(\.value) == [2_000_000_000, 6_000_000_000], "in the core's order")
        #expect(memory.apps.map(\.share) == [0.25, 0.75])
    }

    /// CPU time adds up, so the heatmap tells how much of it nights carry; memory's cells are
    /// average footprints, which do not add up, so it tells only the fullest hour.
    @Test func onlyAMeasureThatAddsUpHasAShareOfTheNight() {
        let cells: [ResourceHistoryData.Cell] = [
            .init(weekday: 1, hour: 2, value: 1), .init(weekday: 1, hour: 14, value: 3),
        ]
        #expect(ResourceHistoryContent.heatmap(cells, measure: .cpu, calendar: calendar).nightShare == 0.25)
        let memory = ResourceHistoryContent.heatmap(cells, measure: .memory, calendar: calendar)
        #expect(memory.nightShare == nil)
        #expect(memory.peak?.hour == 14)
    }

    @Test func diskAndEnergyReadTheirOwnTotals() {
        #expect(content(.disk).tiles.map(\.value).prefix(3) == ["8 GB", "3 GB", "5 GB"])
        #expect(content(.energy).tiles.first?.title == "Energy")
        #expect(content(.cpu).heatmap?.peak?.hour == 9)
    }

    /// On a Day page the busiest day would be the day itself; its busiest hour says more.
    @Test func aDayPageNamesItsBusiestHour() {
        let start = Date(timeIntervalSince1970: TimeInterval(november1))
        let query = ResourceQuery(
            interval: DateInterval(start: start, duration: 86_400), previous: nil, step: .hour, measure: .cpu)
        let data = ResourceHistoryData(
            firstHour: november1, total: ResourceSum(cpu: 30 * minute),
            previous: nil,
            bars: [
                .init(firstHour: november1 + 9 * hour, sum: ResourceSum(cpu: 10 * minute)),
                .init(firstHour: november1 + 15 * hour, sum: ResourceSum(cpu: 20 * minute)),
            ],
            apps: [], busiestDay: .init(firstHour: november1, value: 30 * minute), days: 1, heatmap: [])
        let day = ResourceHistoryContent.make(
            range: .day, query: query, data: data, now: start.addingTimeInterval(86_400), calendar: calendar)
        #expect(day.tiles.last?.title == "Busiest hour")
        #expect(day.tiles.last?.value == "20 min")
        // Formatters put a narrow no-break space before PM.
        #expect(day.tiles.last?.detail?.replacingOccurrences(of: "\u{202F}", with: " ") == "3 PM")
        #expect(day.heatmap == nil)
        let busy = ResourceHistoryData(
            firstHour: november1, total: ResourceSum(cpu: 6 * 3600 * 1_000_000_000), previous: nil, bars: [],
            apps: [], busiestDay: nil, days: 1, heatmap: [])
        let halfDay = ResourceHistoryContent.make(
            range: .day, query: query, data: busy, now: start.addingTimeInterval(12 * 3600), calendar: calendar)
        // At noon the day has run 12 hours: 6 hours of CPU is half a core, not the quarter a whole
        // day would give.
        #expect(halfDay.tiles[2].value == "0.5 cores")
    }
}

/// History's Day page minute by minute.
struct MinuteContentTests {
    let record = MinuteRecord(
        firstMinute: 60,
        minutes: [
            .init(
                start: 60, cpuBusy: 0.25, memoryUsed: 8_589_934_592, memoryLevel: 70, pressure: 1, volumeFree: nil,
                volumeSize: nil),
            .init(
                start: 120, cpuBusy: 0.94, memoryUsed: 25_769_803_776, memoryLevel: 20, pressure: 2, volumeFree: nil,
                volumeSize: nil),
        ])
    let apps = MinuteApps(
        cpu: [.init(id: "/Applications/Xcode.app", name: "Xcode", value: 367_200_000_000)],
        memory: [.init(id: "/Applications/Xcode.app", name: "Xcode", value: 9_200_000_000)],
        written: [])

    @Test func theLatestMinuteIsPickedAndReadAsTheSettingsSay() {
        let content = MinuteContent.make(
            record: record, selected: nil, apps: apps, settings: .default, keptDays: 7, memoryTotal: 34_359_738_368,
            cores: 12)
        #expect(content.selected == Date(timeIntervalSince1970: 120))
        #expect(content.summary == "CPU 94% · Mem used 24.0 GB · pressure warning")
        // 367.2 s of CPU in 60 s is 612% of one core.
        #expect(content.lists.map(\.title) == ["CPU", "Memory", "Disk written"])
        #expect(content.lists[0].rows.map(\.value) == ["612%"])
        #expect(content.lists[1].rows.map(\.value) == ["9.2 GB"])
        #expect(content.points.map(\.memory) == [0.25, 0.75])
    }

    @Test func theMemoryLineFollowsTheShowSetting() {
        var settings = ResourceSettings()
        settings.memory = .pressure
        let content = MinuteContent.make(
            record: record, selected: 60, apps: nil, settings: settings, keptDays: 7, memoryTotal: 34_359_738_368,
            cores: 12)
        #expect(content.points.map(\.memory) == [0.3, 0.8])
        #expect(content.memoryLabel == "Memory pressure")
        #expect(content.summary == "CPU 25% · Pressure 30% · pressure normal")
        settings.measures = [.cpu]
        // Memory turned off leaves the chart's memory line, its summary and its list.
        let cpuOnly = MinuteContent.make(
            record: record, selected: 60, apps: apps, settings: settings, keptDays: 7, memoryTotal: 34_359_738_368,
            cores: 12)
        #expect(cpuOnly.points.map(\.memory) == [nil, nil])
        #expect(cpuOnly.memoryLabel == nil)
        #expect(cpuOnly.summary == "CPU 25%")
        settings.cpu = .cores
        #expect(
            MinuteContent.make(record: record, selected: 60, apps: nil, settings: settings, keptDays: 7, cores: 12)
                .cpuLabel == "CPU busy, 100% = 12 cores")
        #expect(
            MinuteContent.make(record: record, selected: 60, apps: apps, settings: settings, keptDays: 7).lists.map(
                \.title) == ["CPU"])
    }

    @Test func arrowKeysMoveAMinuteAndStopAtTheDaysEnds() {
        #expect(MinuteContent.moved(record, from: nil, by: -1) == 60, "from the latest")
        #expect(MinuteContent.moved(record, from: 60, by: -1) == 60)
        #expect(MinuteContent.moved(record, from: 60, by: 1) == 120)
        #expect(MinuteContent.moved(MinuteRecord(firstMinute: nil, minutes: []), from: nil, by: 1) == nil)
    }
}
