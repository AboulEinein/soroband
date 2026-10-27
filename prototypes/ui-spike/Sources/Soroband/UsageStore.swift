import AppKit
import SwiftUI

/// Spike-only store: generates ~60 days of fake hourly history and ticks fake live traffic every second.
@MainActor @Observable
final class UsageStore {
    var networks: [Network]
    let apps: [AppInfo]
    private(set) var records: [UsageRecord] = []
    private var recordIndex: [String: Int] = [:]

    private(set) var currentNetworkID: String
    private(set) var connectedSince: Date
    private(set) var liveDown: Double = 0
    private(set) var liveUp: Double = 0

    var menuBarMode: MenuBarMode = .todayCurrentNetwork
    var resetHour = 0
    var launchAtLogin = true

    private let calendar = Calendar.current
    private var rng = SeededRNG(seed: 42)

    init() {
        networks = [
            Network(id: "home", name: "Home-5G", kind: .wifi, tint: .series1),
            Network(id: "office", name: "Office Wi‑Fi", kind: .wifi, tint: .series2),
            Network(id: "iphone", name: "iPhone Hotspot", kind: .hotspot, tint: .series3),
            Network(id: "dock", name: "Desk Dock", kind: .ethernet, tint: .series4),
            Network(id: "cafe", name: "Café Lounge", kind: .wifi, tint: .series5),
        ]
        apps = Self.mockApps.map { spec in
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: spec.id)
            return AppInfo(
                id: spec.id, name: spec.name, symbol: spec.symbol, tint: spec.tint,
                icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) })
        }
        currentNetworkID = "home"
        connectedSince = .now
        generateHistory()
        startTicking()
    }

    // MARK: Queries

    var currentNetwork: Network { network(currentNetworkID) }
    func network(_ id: String) -> Network { networks.first { $0.id == id }! }
    func app(_ id: String) -> AppInfo { apps.first { $0.id == id }! }

    /// The counter resets daily at `resetHour`; history is untouched.
    var todayInterval: DateInterval {
        var start = calendar.date(bySettingHour: resetHour, minute: 0, second: 0, of: .now)!
        if start > .now { start = calendar.date(byAdding: .day, value: -1, to: start)! }
        return DateInterval(start: start, duration: 86_400)
    }

    func records(in interval: DateInterval, network: String? = nil) -> [UsageRecord] {
        records.filter {
            $0.hour >= interval.start && $0.hour < interval.end
                && (network == nil || $0.networkID == network)
        }
    }

    func lastSeen(_ networkID: String) -> Date? {
        records.last { $0.networkID == networkID }?.hour
    }

    func lastSeenBefore(_ networkID: String, _ date: Date) -> Date? {
        records.last { $0.networkID == networkID && $0.hour < date }?.hour
    }

    var firstRecordDate: Date { records.first?.hour ?? .now }

    /// Bar segments per network in fixed network order, so a network keeps its color everywhere.
    func networkSegments(_ records: [UsageRecord]) -> [Segment] {
        let byNetwork = Dictionary(grouping: records, by: \.networkID).mapValues { $0.totals.total }
        return networks.compactMap { net in
            byNetwork[net.id].map { Segment(color: net.tint, bytes: $0) }
        }
    }

    var menuBarText: String {
        switch menuBarMode {
        case .todayCurrentNetwork: formatBytes(records(in: todayInterval, network: currentNetworkID).totals.total)
        case .todayAllNetworks: formatBytes(records(in: todayInterval).totals.total)
        case .liveSpeed: "↓\(formatRate(liveDown)) ↑\(formatRate(liveUp))"
        case .iconOnly: ""
        }
    }

    // MARK: Spike controls

    func simulateJoin(_ networkID: String) {
        currentNetworkID = networkID
        connectedSince = .now
    }

    // MARK: Mock data

    private static let mockApps: [(id: String, name: String, symbol: String, tint: Color, mbPerHour: Double, upShare: Double, chance: Double)] = [
        ("com.apple.Safari", "Safari", "safari", .blue, 70, 0.06, 0.9),
        ("org.example.huddle", "Huddle", "video", .cyan, 180, 0.45, 0.25),
        ("org.example.tempo", "Tempo", "music.note", .green, 45, 0.02, 0.5),
        ("org.example.relay", "Relay", "number", .purple, 18, 0.15, 0.95),
        ("org.example.quill", "Quill", "sparkle", .orange, 12, 0.3, 0.7),
        ("com.apple.dt.Xcode", "Xcode", "hammer", .blue, 60, 0.02, 0.15),
        ("com.apple.bird", "iCloud Drive", "icloud", .teal, 30, 0.5, 0.4),
        ("com.apple.mail", "Mail", "envelope", .blue, 6, 0.2, 0.9),
        ("system", "macOS & Services", "gearshape.2", .gray, 10, 0.1, 1.0),
    ]

    private func scheduledNetwork(dayIndex: Int, day: Date, hour: Int) -> String {
        let workday = !calendar.isDateInWeekend(day)
        if workday && (9..<18).contains(hour) {
            if dayIndex % 6 == 2 && (13..<16).contains(hour) { return "iphone" }
            return dayIndex % 4 == 1 ? "dock" : "office"
        }
        if !workday && dayIndex % 7 == 3 && (11..<14).contains(hour) { return "cafe" }
        return "home"
    }

    private func generateHistory() {
        let today = calendar.startOfDay(for: .now)
        let nowHour = calendar.dateInterval(of: .hour, for: .now)!.start
        for dayIndex in 0..<60 {
            let day = calendar.date(byAdding: .day, value: dayIndex - 59, to: today)!
            for hour in 0..<24 {
                let start = calendar.date(byAdding: .hour, value: hour, to: day)!
                if start > nowHour { break }
                let networkID = scheduledNetwork(dayIndex: dayIndex, day: day, hour: hour)
                currentNetworkID = networkID
                let activity = hour < 7 ? 0.06 : hour < 9 ? 0.5 : 1.0
                for spec in Self.mockApps where Double.random(in: 0...1, using: &rng) < spec.chance {
                    let bytes = spec.mbPerHour * activity * Double.random(in: 0.3...1.6, using: &rng) * 1_000_000
                    add(hour: start, networkID: networkID, appID: spec.id,
                        down: Int64(bytes * (1 - spec.upShare)), up: Int64(bytes * spec.upShare))
                }
            }
        }
        var since = nowHour
        while let previous = calendar.date(byAdding: .hour, value: -1, to: since),
              records.contains(where: { $0.hour == previous && $0.networkID == currentNetworkID }) {
            since = previous
        }
        connectedSince = since
    }

    private func add(hour: Date, networkID: String, appID: String, down: Int64, up: Int64) {
        let key = "\(hour.timeIntervalSince1970)|\(networkID)|\(appID)"
        if let i = recordIndex[key] {
            records[i].down += down
            records[i].up += up
        } else {
            recordIndex[key] = records.count
            records.append(UsageRecord(hour: hour, networkID: networkID, appID: appID, down: down, up: up))
        }
    }

    private func startTicking() {
        Task { [weak self] in
            while let self {
                try? await Task.sleep(for: .seconds(1))
                self.tick()
            }
        }
    }

    private func tick() {
        liveDown = Double.random(in: 20_000...450_000, using: &rng)
        liveUp = Double.random(in: 3_000...60_000, using: &rng)
        let hour = calendar.dateInterval(of: .hour, for: .now)!.start
        let active = apps.shuffled(using: &rng).prefix(3)
        for (i, app) in active.enumerated() {
            let share = [0.6, 0.3, 0.1][i]
            add(hour: hour, networkID: currentNetworkID, appID: app.id,
                down: Int64(liveDown * share), up: Int64(liveUp * share))
        }
    }
}

struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
