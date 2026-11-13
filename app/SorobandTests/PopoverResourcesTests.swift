import Foundation
import Testing

@testable import Soroband

/// The popover's Resources tab from today's numbers worked out by hand.
struct PopoverResourcesTests {
    let gauges = Gauges(
        on: true, cpuBusy: 0.23, memoryUsed: 23_000_000_000, memoryLevel: 60, pressure: 1,
        volumeFree: 212_000_000_000, volumeSize: 994_000_000_000)

    /// Seven apps: CPU from 70 minutes (Xcode) down, Mail with no CPU but the most memory.
    func today() -> ResourceHistoryData {
        let minute: UInt64 = 60_000_000_000
        let apps = [
            ("Xcode", 72 * minute), ("Safari", 38 * minute), ("Zoom", 24 * minute), ("Claude", 9 * minute),
            ("Music", 3 * minute), ("Notes", minute),
        ].map { name, cpu in
            ResourceHistoryData.App(
                id: "/Applications/\(name).app", name: name, sum: ResourceSum(cpu: cpu, footprint: 100))
        }
        let mail = ResourceHistoryData.App(
            id: "/Applications/Mail.app", name: "Mail", sum: ResourceSum(footprint: 9_000_000_000))
        return ResourceHistoryData(
            firstHour: 0, total: .zero, previous: nil, bars: [], apps: apps + [mail], busiestDay: nil, days: 1,
            heatmap: [])
    }

    @Test func listsTodaysTopFiveByTheMeasureAndCountsTheRest() {
        let tab = PopoverResources.make(settings: .default, gauges: gauges, measure: .cpu, today: today())
        #expect(tab.rows.map(\.title) == ["Xcode", "Safari", "Zoom", "Claude", "Music"])
        #expect(tab.rows.map(\.text) == ["1 h 12 min", "38 min", "24 min", "9 min", "3 min"])
        // Notes is the sixth with CPU; Mail used none, so it is not one more.
        #expect(tab.hiddenApps == 1)
        #expect(tab.scale == 72 * 60_000_000_000)
        #expect(tab.gauges.map(\.reading.value) == ["23%", "21.4 GB", "212 GB"])
        #expect(tab.gauges.map(\.measure) == [.cpu, .memory, .disk], "energy has no gauge")
        #expect(tab.loaded && !tab.fallback)
    }

    @Test func aMeasureNotShownGivesWayToTheFirstShown() {
        var settings = ResourceSettings()
        settings.measures = [.memory, .energy]
        let tab = PopoverResources.make(settings: settings, gauges: gauges, measure: .cpu, today: today())
        #expect(tab.measure == .memory)
        #expect(tab.rows.first?.title == "Mail")
        #expect(tab.measures == [.memory, .energy])
        #expect(tab.gauges.map(\.measure) == [.memory])
    }

    @Test func theFallbackShowsWhenTheReadFallsBackNowOrDidToday() {
        var fallback = gauges
        fallback.fallback = true
        #expect(PopoverResources.make(settings: .default, gauges: fallback, measure: .cpu, today: nil).fallback)
        let earlier = ResourceHistoryData(
            firstHour: 0, total: ResourceSum(fallback: true), previous: nil, bars: [], apps: [], busiestDay: nil,
            days: 1, heatmap: [])
        #expect(PopoverResources.make(settings: .default, gauges: gauges, measure: .cpu, today: earlier).fallback)
        #expect(!PopoverResources.make(settings: .default, gauges: gauges, measure: .cpu, today: nil).loaded)
    }

    @Test func totalsReadAsTimeBytesAndWattHours() {
        #expect(Format.cpuTime(nanoseconds: 999_999_999) == "< 1 s")
        #expect(Format.cpuTime(nanoseconds: 45_500_000_000) == "45 s")
        #expect(Format.cpuTime(nanoseconds: 3_600_000_000_000) == "1 h")
        #expect(Format.cpuTime(nanoseconds: 4_320_000_000_000) == "1 h 12 min")
        // 18 Wh is 64.8 kJ.
        #expect(Format.energy(nanojoules: 64_800_000_000_000) == "18 Wh")
        #expect(Format.energy(nanojoules: 1_440_000_000_000) == "0.4 Wh")
        #expect(Format.energy(nanojoules: 100_000_000_000) == "< 0.1 Wh")
        #expect(Format.energy(nanojoules: 11_160_000_000_000_000) == "3.1 kWh")
        #expect(Format.resource(1_500_000, measure: .disk) == "1.5 MB")
    }
}
