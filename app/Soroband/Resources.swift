import Foundation

/// A resource Soroband meters per app: the core's `resource_measures` words.
enum ResourceMeasure: String, Codable, CaseIterable, Identifiable {
    case cpu, memory, disk, energy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .disk: "Disk"
        case .energy: "Energy"
        }
    }
}

/// How each resource reads now, and which are metered: Settings › Resources, one setting per
/// resource for the popover's gauges, the menu bar readings and the past-minute chart.
struct ResourceSettings: Codable, Equatable {
    enum CPU: String, Codable, CaseIterable { case percent, cores }
    enum Memory: String, Codable, CaseIterable { case used, free, pressure }
    enum Disk: String, Codable, CaseIterable { case used, free }
    enum Unit: String, Codable, CaseIterable { case amount, percent }

    /// The resource meter's switch: off, it does not read and no resource view shows.
    var metered = true
    var measures = ResourceMeasure.allCases
    var cpu = CPU.percent
    var memory = Memory.used
    var memoryUnit = Unit.amount
    var disk = Disk.free
    var diskUnit = Unit.amount
    /// The disk reading's volume, by its mount point.
    var diskVolume = startupVolume
    /// Days the minute record is kept.
    var minutesDays = 7

    static let startupVolume = "/"

    static let meteredKey = "resources"
    static let measuresKey = "resource_measures"
    static let cpuKey = "resource_cpu"
    static let memoryKey = "resource_memory"
    static let memoryUnitKey = "resource_memory_unit"
    static let diskKey = "resource_disk"
    static let diskUnitKey = "resource_disk_unit"
    static let diskVolumeKey = "resource_disk_volume"
    static let minutesDaysKey = "resource_minutes_days"

    static let `default` = ResourceSettings()

    init() {}

    /// The settings as `setting` reads them; a value the app does not know keeps the default.
    init(setting: (String) -> String?) {
        metered = setting(Self.meteredKey) != "off"
        if let value = setting(Self.measuresKey) {
            measures =
                value == "none" ? [] : value.split(separator: ",").compactMap { ResourceMeasure(rawValue: String($0)) }
        }
        cpu = setting(Self.cpuKey).flatMap(CPU.init(rawValue:)) ?? cpu
        memory = setting(Self.memoryKey).flatMap(Memory.init(rawValue:)) ?? memory
        memoryUnit = setting(Self.memoryUnitKey).flatMap(Unit.init(rawValue:)) ?? memoryUnit
        disk = setting(Self.diskKey).flatMap(Disk.init(rawValue:)) ?? disk
        diskUnit = setting(Self.diskUnitKey).flatMap(Unit.init(rawValue:)) ?? diskUnit
        diskVolume = setting(Self.diskVolumeKey) ?? diskVolume
        minutesDays = setting(Self.minutesDaysKey).flatMap(Int.init) ?? minutesDays
    }

    /// The measures the views show: none while the meter is off.
    var shown: [ResourceMeasure] { metered ? measures : [] }

    func shows(_ measure: ResourceMeasure) -> Bool { shown.contains(measure) }

    /// `measures` as the core stores them.
    var measuresValue: String {
        measures.isEmpty
            ? "none" : ResourceMeasure.allCases.filter(measures.contains).map(\.rawValue).joined(separator: ",")
    }

    /// The setting `key` changed to `value`, as the menu bar process will save it.
    func setting(_ key: String, to value: String) -> ResourceSettings {
        ResourceSettings { $0 == key ? value : self.value(of: $0) }
    }

    /// The value of setting `key` as the core stores it; nil for a key that is not a resource's.
    func value(of key: String) -> String? {
        switch key {
        case Self.meteredKey: metered ? "on" : "off"
        case Self.measuresKey: measuresValue
        case Self.cpuKey: cpu.rawValue
        case Self.memoryKey: memory.rawValue
        case Self.memoryUnitKey: memoryUnit.rawValue
        case Self.diskKey: disk.rawValue
        case Self.diskUnitKey: diskUnit.rawValue
        case Self.diskVolumeKey: diskVolume
        case Self.minutesDaysKey: String(minutesDays)
        default: nil
        }
    }

    static let keys = [
        meteredKey, measuresKey, cpuKey, memoryKey, memoryUnitKey, diskKey, diskUnitKey, diskVolumeKey,
        minutesDaysKey,
    ]
}

/// The system gauges at the engine's last poll (`soroband_gauges`).
struct Gauges: Codable, Equatable {
    /// Whether the resource meter runs and has polled; nothing else is known while false.
    var on = false
    /// The share of CPU time busy between the last two polls, 0 to 1.
    var cpuBusy: Double?
    var memoryUsed: UInt64?
    /// The percent of memory the kernel counts as available; its complement is the pressure.
    var memoryLevel: Int?
    /// 1 normal, 2 warning, 4 critical.
    var pressure: Int?
    /// The disk reading's volume: its free and total bytes.
    var volumeFree: UInt64?
    var volumeSize: UInt64?
    /// The resource read falls back to the user's own processes.
    var fallback = false
    /// The installed memory the memory percents are of: this Mac's, or a fixture's in tests.
    var memoryTotal = Gauges.installedMemory

    static let none = Gauges()

    /// This Mac's installed memory and logical cores.
    static let installedMemory = ProcessInfo.processInfo.physicalMemory
    static let cores = ProcessInfo.processInfo.activeProcessorCount
}

/// One gauge as a view shows it: what it reads, its value, and the used share its bar fills.
struct GaugeReading: Equatable {
    /// "CPU now", "Memory used", "Disk free": for the popover's gauges.
    var title: String
    /// "CPU", "MEM USED", "DISK FREE": the menu bar's labeled style.
    var caption: String
    /// "CPU", "Mem used", "Disk free": before the value where no caption is drawn.
    var label: String
    /// "23%", "21.4 GB", "2.3"; "–" while unknown.
    var value: String
    /// The used share, 0 to 1, so a bar reads the same way whichever number sits above it; nil
    /// while unknown.
    var usedShare: Double?

    /// The value with its caption, as it reads without one drawn above it: "CPU 23%".
    var text: String { "\(label) \(value)" }

    static let unknown = "–"
}

extension ResourceSettings {
    /// What the gauge for `measure` (CPU, memory or disk; nil for energy, which has no gauge)
    /// reads with `gauges`.
    func reading(
        _ measure: ResourceMeasure, gauges: Gauges, cores: Int = Gauges.cores
    ) -> GaugeReading? {
        let known = gauges.on
        let memoryTotal = gauges.memoryTotal
        switch measure {
        case .cpu:
            let busy = known ? gauges.cpuBusy : nil
            return switch cpu {
            case .percent:
                GaugeReading(
                    title: "CPU now", caption: "CPU", label: "CPU",
                    value: busy.map(Format.percent) ?? GaugeReading.unknown,
                    usedShare: busy)
            case .cores:
                GaugeReading(
                    title: "CPU cores busy", caption: "CPU CORES", label: "CPU cores",
                    value: busy.map { Format.cores($0 * Double(cores)) } ?? GaugeReading.unknown, usedShare: busy)
            }
        case .memory:
            let used = known ? gauges.memoryUsed : nil
            let usedShare = used.flatMap { memoryTotal > 0 ? min(1, Double($0) / Double(memoryTotal)) : nil }
            switch memory {
            case .pressure:
                let pressure = (known ? gauges.memoryLevel : nil).map { Double(100 - min(100, max(0, $0))) / 100 }
                return GaugeReading(
                    title: "Memory pressure", caption: "PRESSURE", label: "Pressure",
                    value: pressure.map(Format.percent) ?? GaugeReading.unknown, usedShare: pressure)
            case .used, .free:
                let isUsed = memory == .used
                let amount = used.map { isUsed ? $0 : memoryTotal - min($0, memoryTotal) }
                let share = usedShare.map { isUsed ? $0 : 1 - $0 }
                let value =
                    memoryUnit == .percent ? share.map(Format.percent) : amount.map(Format.menuBarMemory)
                return GaugeReading(
                    title: isUsed ? "Memory used" : "Memory free", caption: isUsed ? "MEM USED" : "MEM FREE",
                    label: isUsed ? "Mem used" : "Mem free",
                    value: value ?? GaugeReading.unknown, usedShare: usedShare)
            }
        case .disk:
            let size = known ? gauges.volumeSize.flatMap { $0 > 0 ? $0 : nil } : nil
            let free = size.flatMap { _ in gauges.volumeFree }
            let usedShare = size.flatMap { size in free.map { 1 - Double(min($0, size)) / Double(size) } }
            let isUsed = disk == .used
            let amount = size.flatMap { size in free.map { isUsed ? size - min($0, size) : $0 } }
            let share = usedShare.map { isUsed ? $0 : 1 - $0 }
            let value = diskUnit == .percent ? share.map(Format.percent) : amount.map(Format.menuBarDisk)
            return GaugeReading(
                title: isUsed ? "Disk used" : "Disk free", caption: isUsed ? "DISK USED" : "DISK FREE",
                label: isUsed ? "Disk used" : "Disk free",
                value: value ?? GaugeReading.unknown, usedShare: usedShare)
        case .energy:
            return nil
        }
    }
}

extension Format {
    /// A share as a whole percent, rounded down so a gauge never reads full before it is: "23%".
    static func percent(_ share: Double) -> String {
        "\(Int((min(1, max(0, share)) * 100).rounded(.down)))%"
    }

    /// Cores' worth busy, in tenths, rounded down: "2.3".
    static func cores(_ cores: Double) -> String {
        let tenths = (max(0, cores) * 10).rounded(.down) / 10
        return tenths.formatted(.number.precision(.fractionLength(1)))
    }

    /// Memory for the menu bar and the gauges, in binary gigabytes as macOS reports installed
    /// memory (a 32 GB Mac has 32 GB): tenths, rounded down, so it redraws once a tenth.
    static func menuBarMemory(_ bytes: UInt64) -> String {
        let tenths = (Double(bytes) / 1_073_741_824 * 10).rounded(.down) / 10
        return "\(tenths.formatted(.number.precision(.fractionLength(1)))) GB"
    }

    /// Disk space for the menu bar and the gauges, in decimal units as Finder shows it: whole
    /// gigabytes, rounded down, or tenths of a terabyte from 1 TB.
    static func menuBarDisk(_ bytes: UInt64) -> String {
        if bytes >= 1_000_000_000_000 {
            let tenths = Double(bytes / 100_000_000_000) / 10
            return "\(tenths.formatted(.number.precision(.fractionLength(1)))) TB"
        }
        return "\(bytes / 1_000_000_000) GB"
    }
}
