import Foundation
import Testing

@testable import Soroband

/// How each resource reads now (Settings › Resources' Show group), from gauges worked out by hand.
struct ResourcesTests {
    /// 32 GiB installed, 12 cores.
    let memoryTotal: UInt64 = 34_359_738_368
    let cores = 12
    /// 23% busy; 24 GiB used; 40% available, so 60% pressure; 300 GB free of 1 TB.
    let gauges = Gauges(
        on: true, cpuBusy: 0.2399, memoryUsed: 25_769_803_776, memoryLevel: 40, pressure: 2,
        volumeFree: 300_000_000_000, volumeSize: 1_000_000_000_000)

    func reading(_ measure: ResourceMeasure, _ change: (inout ResourceSettings) -> Void = { _ in }) -> GaugeReading? {
        var settings = ResourceSettings()
        change(&settings)
        return settings.reading(measure, gauges: gauges, memoryTotal: memoryTotal, cores: cores)
    }

    @Test func cpuReadsAsAPercentOrAsCoresBusy() {
        #expect(reading(.cpu)?.value == "23%", "rounded down, never full before it is")
        #expect(reading(.cpu)?.caption == "CPU")
        // 0.2399 × 12 = 2.88 cores, in tenths rounded down.
        #expect(reading(.cpu) { $0.cpu = .cores }?.value == "2.8")
        #expect(reading(.cpu) { $0.cpu = .cores }?.caption == "CPU CORES")
        #expect(reading(.cpu)?.usedShare == 0.2399)
    }

    @Test func memoryReadsUsedFreeOrPressureAndItsBarAlwaysShowsTheUsedShare() {
        #expect(reading(.memory)?.value == "24.0 GB", "binary gigabytes, as macOS counts installed memory")
        #expect(reading(.memory) { $0.memory = .free }?.value == "8.0 GB")
        #expect(reading(.memory) { $0.memoryUnit = .percent }?.value == "75%")
        #expect(
            reading(.memory) {
                $0.memory = .free
                $0.memoryUnit = .percent
            }?.value == "25%")
        #expect(reading(.memory) { $0.memory = .free }?.usedShare == 0.75, "the bar shows used, whatever the number")
        // Pressure is the complement of the memory available, a percent whatever the unit.
        let pressure = reading(.memory) {
            $0.memory = .pressure
            $0.memoryUnit = .amount
        }
        #expect(pressure?.value == "60%")
        #expect(pressure?.caption == "PRESSURE")
        #expect(pressure?.usedShare == 0.6)
    }

    @Test func diskReadsFreeOrUsedOnItsVolume() {
        #expect(reading(.disk)?.value == "300 GB", "decimal, as Finder shows it")
        #expect(reading(.disk) { $0.disk = .used }?.value == "700 GB")
        #expect(reading(.disk) { $0.diskUnit = .percent }?.value == "30%")
        #expect(
            reading(.disk) {
                $0.disk = .used
                $0.diskUnit = .percent
            }?.caption == "DISK USED")
        #expect(reading(.disk)?.usedShare == 0.7)
        #expect(reading(.energy) == nil, "energy has no gauge")
    }

    @Test func unknownGaugesReadAsADashNotAsZero() {
        let none = ResourceSettings().reading(.cpu, gauges: .none)
        #expect(none?.value == "–")
        #expect(none?.usedShare == nil)
        var off = gauges
        off.on = false
        #expect(ResourceSettings().reading(.disk, gauges: off)?.value == "–", "the meter is off")
    }

    @Test func amountsRoundDownSoTheyRedrawOnlyWhenTheShownDigitChanges() {
        #expect(Format.menuBarMemory(22_977_772_339) == "21.3 GB", "21.399 GiB")
        #expect(Format.menuBarMemory(22_978_846_000) == "21.4 GB")
        #expect(Format.menuBarDisk(999_999_999_999) == "999 GB")
        #expect(Format.menuBarDisk(1_250_000_000_000) == "1.2 TB")
        #expect(Format.percent(0.999) == "99%")
        #expect(Format.percent(1.2) == "100%")
    }

    /// The settings as the core stores them: a stored value the app does not know keeps the default.
    @Test func settingsReadTheCoresValues() {
        let stored = [
            "resources": "on", "resource_measures": "cpu,disk", "resource_cpu": "cores",
            "resource_memory": "pressure", "resource_memory_unit": "percent", "resource_disk": "used",
            "resource_disk_unit": "nonsense", "resource_disk_volume": "/Volumes/Backup",
        ]
        let settings = ResourceSettings { stored[$0] }
        #expect(settings.measures == [.cpu, .disk])
        #expect(settings.cpu == .cores)
        #expect(settings.memory == .pressure)
        #expect(settings.disk == .used)
        #expect(settings.diskUnit == .amount)
        #expect(settings.diskVolume == "/Volumes/Backup")
        #expect(settings.shows(.cpu) && !settings.shows(.memory))
        #expect(ResourceSettings { $0 == "resources" ? "off" : nil }.shown.isEmpty)
        #expect(ResourceSettings { $0 == "resource_measures" ? "none" : nil }.measures.isEmpty)
        // Each key round-trips through the value the menu bar process will save.
        for key in ResourceSettings.keys {
            #expect(settings.setting(key, to: settings.value(of: key)!) == settings, "\(key)")
        }
        #expect(settings.setting("resource_cpu", to: "percent").cpu == .percent)
        #expect(ResourceSettings().measuresValue == "cpu,memory,disk,energy")
    }
}
