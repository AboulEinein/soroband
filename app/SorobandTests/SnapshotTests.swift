import ServiceManagement
import SwiftUI
import Testing

@testable import Soroband

/// Views rendered with fixed data. Each baseline in `tests/snapshots/` was checked by eye against
/// `docs/mockups/`.
@MainActor
@Suite(.serialized)
struct SnapshotTests {
    /// A day like the popover mockup's: Home-5G with seven apps and two more, iPhone used too,
    /// Office known but never used.
    static let registry = [
        RegisteredNetwork(id: 1, key: "wifi:Home-5G", name: "Home-5G", kind: .wifi, lastUsed: nil),
        RegisteredNetwork(id: 2, key: "wifi:iPhone", name: "iPhone", kind: .hotspot, lastUsed: nil),
        RegisteredNetwork(id: 3, key: "ethernet:office", name: "Office LAN", kind: .ethernet, lastUsed: nil),
    ]
    static let home = Network(id: 1, key: "wifi:Home-5G", name: "Home-5G", kind: .wifi)

    static let today: Today = {
        func app(_ network: Int64, _ id: String, _ name: String, _ megabytes: Double) -> Today.AppUsage {
            let bytes = UInt64(megabytes * 1_000_000)
            return .init(network: network, id: id, name: name, rx: bytes * 4 / 5, tx: bytes / 5)
        }
        return Today(
            networks: [
                .init(
                    network: 1, apps: ByteCounts(rx: 890_000_000, tx: 120_000_000),
                    interfaces: ByteCounts(rx: 893_600_000, tx: 203_800_000)),
                .init(
                    network: 2, apps: ByteCounts(rx: 300_000_000, tx: 60_000_000),
                    interfaces: ByteCounts(rx: 330_000_000, tx: 70_000_000)),
            ],
            apps: [
                app(1, "/Applications/Safari.app", "Safari", 420.3),
                app(1, "process:huddle", "huddle", 202.8),
                app(1, "/System/Applications/Music.app", "Music", 135.9),
                app(1, "/System/Applications/Messages.app", "Messages", 114),
                app(1, "macOS & Services", "macOS & Services", 62.8),
                app(1, "/System/Applications/Mail.app", "Mail", 39.4),
                app(1, "/usr/bin/curl", "curl", 20),
                app(1, "process:git", "git", 9),
                app(1, "process:ssh", "ssh", 5.8),
                app(2, "/Applications/Safari.app", "Safari", 250),
                app(2, "/System/Applications/Mail.app", "Mail", 110),
            ])
    }()

    /// 21:30 local time on 2026-10-27, and the day's hours before it on Home-5G: quiet at night,
    /// busy through the day; the hour in progress comes from the live total.
    static let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 21, minute: 30))!
    static let summary = PopoverSummary(
        todayStart: Calendar.current.startOfDay(for: now),
        storedHours: [4, 2, 1, 1, 0, 1, 3, 12, 40, 80, 100, 74, 52, 60, 96, 122, 84, 70, 52, 60, 34, 0, 0, 0]
            .map { UInt64($0) * 1_000_000 },
        week: [6.1, 8.4, 7.2, 9.8, 8.8, 10.4, 1.5].map { UInt64($0 * 1_000_000_000) },
        month: 62_300_000_000)

    static let status = EngineStatus(
        networkID: 1,
        todayNetworkApps: ByteCounts(rx: 890_000_000, tx: 120_000_000),
        todayNetworkInterfaces: ByteCounts(rx: 893_600_000, tx: 203_800_000),
        todayApps: ByteCounts(rx: 1_190_000_000, tx: 180_000_000),
        todayInterfaces: ByteCounts(rx: 1_223_600_000, tx: 273_800_000),
        speed: ByteCounts(rx: 137_000, tx: 42_000))

    func popover(
        _ tab: PopoverView.Tab, allNetworks: Bool = false, status: EngineStatus = status, current: Network = home,
        locationAllowed: Bool = true
    ) -> some View {
        let content = PopoverContent.make(
            status: status, today: Self.today, registry: Self.registry, current: current,
            // 18:00 local time on 2026-10-27.
            connectedSince: Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 18)),
            allNetworks: allNetworks, locationAllowed: locationAllowed, summary: Self.summary, now: Self.now)
        return PopoverView(
            content: content, tab: .constant(tab), allNetworks: .constant(allNetworks), animatesOpen: false
        )
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @Test func popoverApps() throws {
        try Snapshot.verify(popover(.apps), named: "popover-apps")
    }

    @Test func popoverAppsOnAllNetworks() throws {
        try Snapshot.verify(popover(.apps, allNetworks: true), named: "popover-apps-all-networks")
    }

    /// Home-5G before Location access: known by its router and named "Wi-Fi".
    @Test func popoverAsksForLocation() throws {
        let byRouter = Network(id: 1, key: "wifi-router:2:0:0:1:2:3", name: "Wi-Fi", kind: .wifi)
        try Snapshot.verify(
            popover(.apps, current: byRouter, locationAllowed: false), named: "popover-asks-for-location")
    }

    @Test func popoverNetworks() throws {
        try Snapshot.verify(popover(.networks), named: "popover-networks")
    }

    @Test func popoverNetworksScrollPastEight() throws {
        let many = (1...12).map {
            RegisteredNetwork(id: Int64($0), key: "wifi:n\($0)", name: "Network \($0)", kind: .wifi, lastUsed: nil)
        }
        let content = PopoverContent.make(
            status: Self.status, today: Self.today, registry: many, current: Self.home, connectedSince: nil,
            allNetworks: false)
        let view = PopoverView(content: content, tab: .constant(.networks), allNetworks: .constant(false))
            .background(Color(nsColor: .windowBackgroundColor))
        try Snapshot.verify(view, named: "popover-networks-scroll")
    }

    @Test func popoverDegraded() throws {
        let s = Self.status
        let degraded = EngineStatus(
            networkID: 1, todayNetworkApps: s.todayNetworkApps, todayNetworkInterfaces: s.todayNetworkInterfaces,
            todayApps: s.todayApps, todayInterfaces: s.todayInterfaces, speed: s.speed, check: .degraded)
        try Snapshot.verify(popover(.apps, status: degraded), named: "popover-degraded")
    }

    @Test func settingsGeneral() throws {
        let launch = LaunchAtLogin(service: .init(status: { .enabled }, register: {}, unregister: {}))
        let view = GeneralSettings(usage: Usage(), launchAtLogin: launch, locationStatus: .notDetermined)
            .background(Color(nsColor: .windowBackgroundColor))
        try Snapshot.verify(view, named: "settings-general", size: CGSize(width: 560, height: 700))
    }

    /// The Menu Bar page on its default layout, with the sample numbers before the first count.
    @Test func settingsMenuBar() throws {
        let view = MenuBarSettings(usage: Usage(), now: Self.now, kind: .wifi, networkName: "Home-5G")
            .background(Color(nsColor: .windowBackgroundColor))
        try Snapshot.verify(view, named: "settings-menu-bar", size: CGSize(width: 560, height: 900))
    }

    /// The item in each style: one reading, a pair, three, four, and the icon alone.
    @Test func menuBarPreviews() throws {
        let readings: [[MenuBarReading]] = [
            [.total], [.download, .upload], [.total, .speedDown, .speedUp],
            [.download, .upload, .speedDown, .speedUp], [],
        ]
        let layouts = MenuBarStyle.allCases.flatMap { style in
            readings.map { MenuBarLayout(readings: $0, style: style) }
        }
        let previews = VStack(spacing: 4) {
            ForEach(layouts.indices, id: \.self) { index in
                MenuBarPreview(
                    display: MenuBarDisplay.make(layout: layouts[index], status: MenuBarPreview.sample, kind: .wifi),
                    now: Self.now)
            }
        }
        .frame(width: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        try Snapshot.verify(previews, named: "settings-menu-bar-previews")
    }

    @Test func settingsNetworks() throws {
        let view = NetworkSettings(
            networks: Self.registry, current: 1, save: { _, _, _ in }, setColor: { _, _ in }, now: Self.now
        )
        .background(Color(nsColor: .windowBackgroundColor))
        try Snapshot.verify(view, named: "settings-networks", size: CGSize(width: 560, height: 400))
    }

    /// The color picker of a network with a picked color (magenta, ringed) and of one without
    /// (Automatic checked, naming its place's color).
    @Test func networkColorPicker() throws {
        let view = HStack(alignment: .top, spacing: 16) {
            NetworkColorPicker(slot: 4, automaticSlot: 0, isPicked: true) { _ in }
            NetworkColorPicker(slot: 1, automaticSlot: 1, isPicked: false) { _ in }
        }
        .padding(8)
        .background(Color(nsColor: .windowBackgroundColor))
        try Snapshot.verify(view, named: "settings-network-color-picker")
    }

    @Test func onboarding() throws {
        let view = OnboardingView(done: {}).background(Color(nsColor: .windowBackgroundColor))
        try Snapshot.verify(view, named: "onboarding")
    }

    /// October 2026 up to the 28th on four networks, shaped like `docs/mockups/history.png`.
    static let historyRegistry = [
        RegisteredNetwork(id: 1, key: "wifi:Home-5G", name: "Home-5G", kind: .wifi, lastUsed: nil),
        RegisteredNetwork(id: 2, key: "wifi:Office", name: "Office Wi-Fi", kind: .wifi, lastUsed: nil),
        RegisteredNetwork(id: 3, key: "wifi:iPhone", name: "iPhone Hotspot", kind: .hotspot, lastUsed: nil),
        RegisteredNetwork(id: 4, key: "ethernet:desk", name: "Desk Dock", kind: .ethernet, lastUsed: nil),
    ]

    static let october: HistoryData = {
        let calendar = Calendar.current
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1))!
        var bars: [HistoryData.Bar] = []
        var perNetwork: [Int64: UInt64] = [:]
        var busiest: HistoryData.Day?
        for day in 0..<27 {
            let date = calendar.date(byAdding: .day, value: day, to: start)!
            let firstHour = Int64(date.timeIntervalSince1970) + 9 * 3600
            // Home every day; the office on weekdays; the phone and the dock now and then.
            var today: [(Int64, UInt64)] = [(1, UInt64(900 + (day * 37) % 700) * 1_000_000)]
            if calendar.component(.weekday, from: date) % 7 > 1 {
                today.append((2, UInt64(800 + (day * 53) % 600) * 1_000_000))
            }
            if day % 6 == 2 { today.append((3, 400_000_000)) }
            if day % 5 == 0 { today.append((4, 700_000_000)) }
            for (network, bytes) in today {
                bars.append(.init(firstHour: firstHour, network: network, rx: bytes * 4 / 5, tx: bytes / 5))
                perNetwork[network, default: 0] += bytes
            }
            let total = today.reduce(0) { $0 + $1.1 }
            if total > busiest?.bytes ?? 0 { busiest = .init(firstHour: firstHour, bytes: total) }
        }
        let all = perNetwork.values.reduce(0, +)
        let apps: [(String, String, UInt64)] = [
            ("/Applications/Safari.app", "Safari", 34), ("process:huddle", "huddle", 22),
            ("/System/Applications/Music.app", "Music", 11), ("/System/Applications/Messages.app", "Messages", 9),
            ("/System/Applications/Mail.app", "Mail", 6), ("macOS & Services", "macOS & Services", 5),
            ("process:git", "git", 3),
        ]
        var shares: [HistoryData.AppShare] = []
        for (id, name, percent) in apps {
            for network in [Int64(1), 2, 3, 4] {
                let bytes = (perNetwork[network] ?? 0) * percent / 100
                shares.append(.init(network: network, id: id, name: name, rx: bytes * 4 / 5, tx: bytes / 5))
            }
        }
        var heatmap: [HistoryData.Cell] = []
        for weekday in 0..<7 {
            for hour in 0..<24 {
                // Quiet nights, then busier hours that vary by weekday.
                let megabytes: Int = hour < 7 ? 5 : 60 + (weekday * 7 + hour * 13) % 90
                heatmap.append(HistoryData.Cell(weekday: weekday, hour: hour, bytes: UInt64(megabytes) * 1_000_000))
            }
        }
        return HistoryData(
            firstHour: Int64(start.timeIntervalSince1970), interfaces: ByteCounts(rx: all * 4 / 5, tx: all / 5),
            previous: all * 97 / 100, bars: bars,
            networks: perNetwork.sorted { $0.value > $1.value }.map {
                .init(network: $0.key, interfaces: ByteCounts(rx: $0.value * 4 / 5, tx: $0.value / 5), apps: .zero)
            },
            apps: shares, busiestDay: busiest, heatmap: heatmap)
    }()

    func history(_ range: HistoryRange, network: Int64? = nil, expandedApp: String? = nil, hover: Date? = nil)
        -> some View
    {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 28))!
        let anchor = calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 9))!
        let query = HistoryQuery.make(
            range: range, anchor: anchor, network: network, firstHour: nil, now: now, calendar: calendar)
        let content = HistoryContent.make(
            range: range, query: query, data: Self.october, registry: Self.historyRegistry, now: now, calendar: calendar
        )
        return HistoryDetail(
            content: content, expandedApp: .constant(expandedApp), hoverDate: .constant(hover),
            showsAllApps: .constant(false)
        )
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @Test func historyMonth() throws {
        try Snapshot.verify(history(.month), named: "history-month", size: CGSize(width: 780, height: 1180))
    }

    @Test func historyMonthWithAnAppOpenAndADayHovered() throws {
        let hover = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 12))
        try Snapshot.verify(
            history(.month, expandedApp: "process:huddle", hover: hover), named: "history-month-expanded",
            size: CGSize(width: 780, height: 1180))
    }

    @Test func comparisonFindsAChangedPixel() throws {
        // Guards the comparison itself: without it, every snapshot test would pass.
        let one = try #require(ImageRenderer(content: Color.black.frame(width: 4, height: 4)).cgImage)
        let other = try #require(
            ImageRenderer(
                content: ZStack(alignment: .topLeading) {
                    Color.black
                    Color.white.frame(width: 1, height: 1)
                }.frame(width: 4, height: 4)
            ).cgImage)
        #expect(Snapshot.changedPixels(one, one) == 0)
        #expect(Snapshot.changedPixels(one, other) == 1)
    }
}
