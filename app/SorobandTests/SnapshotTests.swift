import ServiceManagement
import SwiftUI
import Testing

@testable import Soroband

/// Views rendered with fixed data. Each baseline in `tests/snapshots/` was checked by eye against
/// `docs/mockups/`.
@MainActor
@Suite(.serialized)
struct SnapshotTests {
    init() {
        AppIcons.load = Self.fixedIcon
        AppIcons.clear()
    }

    /// An app's icon drawn here, a rounded square in a color picked by its path, so a macOS update
    /// that redraws the Mac's own icons leaves the baselines as they are.
    static func fixedIcon(forPath path: String) -> NSImage {
        let colors: [(CGFloat, CGFloat, CGFloat)] = [
            (0.20, 0.52, 0.96), (0.96, 0.27, 0.36), (0.30, 0.80, 0.42), (0.98, 0.62, 0.16), (0.62, 0.40, 0.92),
        ]
        let (red, green, blue) = colors[path.utf8.reduce(0) { $0 + Int($1) } % colors.count]
        return NSImage(size: NSSize(width: 24, height: 24), flipped: false) { rect in
            NSColor(srgbRed: red, green: green, blue: blue, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5).fill()
            NSColor(white: 1, alpha: 0.85).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 8, dy: 8)).fill()
            return true
        }
    }

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

    /// The item in each style: one reading, a pair, three, four, and the icon alone; then the
    /// Soroband glyph with one reading, a pair and alone.
    @Test func menuBarPreviews() throws {
        let readings: [[MenuBarReading]] = [
            [.total], [.download, .upload], [.total, .speedDown, .speedUp],
            [.download, .upload, .speedDown, .speedUp], [],
        ]
        let layouts =
            MenuBarStyle.allCases.flatMap { style in
                readings.map { MenuBarLayout(readings: $0, style: style) }
            } + [[.total], [.download, .upload], []].map { MenuBarLayout(readings: $0, icon: .soroband) }
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

    /// The Appearance page on its defaults (System and System), in dark and in light: each card
    /// sketches a window in its appearance, and every accent has its label.
    @Test(arguments: [ColorScheme.dark, .light])
    func settingsAppearance(scheme: ColorScheme) throws {
        let view = AppearanceSettings(theme: Theme(), finderCanChange: true, set: { _, _ in })
            .background(Color(nsColor: .windowBackgroundColor))
        try Snapshot.verify(
            view, named: "settings-appearance-\(scheme == .dark ? "dark" : "light")",
            size: CGSize(width: 560, height: 420), scheme: scheme)
    }

    /// Plum picked on the Dark card, from a tint as the windows' root gives it (`themed`): the
    /// selected card, its radio and the sketches take plum's dark step, and macOS's accent stays
    /// on the System swatch only.
    @Test func settingsAppearanceTinted() throws {
        let theme = Theme(appearance: .dark, accent: .plum)
        let view = AppearanceSettings(theme: theme, finderCanChange: true, set: { _, _ in })
            .tint(theme.accent.color)
            .background(Color(nsColor: .windowBackgroundColor))
        try Snapshot.verify(view, named: "settings-appearance-plum", size: CGSize(width: 560, height: 420))
    }

    /// The whole page with the App Icon section, Hairline Teal picked on a copy this account
    /// cannot change: all 13 icons drawn small and sharp with their labels, the pick ringed, and
    /// the note that Finder keeps the default.
    @Test func settingsAppearanceAppIcon() throws {
        let view = AppearanceSettings(
            theme: Theme(), appIcon: .hairlineTeal, finderCanChange: false, set: { _, _ in }
        )
        .background(Color(nsColor: .windowBackgroundColor))
        try Snapshot.verify(
            view, named: "settings-appearance-app-icon", size: CGSize(width: 560, height: 770), scheme: .dark)
    }

    /// The day ruler with the day starting at 4 AM, tinted amber, the accent nearest to orange, in
    /// dark and in light: the hours before it, and their legend dot, stay gray, apart from today's.
    @Test func dayRulerWithAnAccent() throws {
        let ruler = { (scheme: ColorScheme) in
            DayRuler(resetHour: 4)
                .padding(12)
                .frame(width: 520)
                .background(scheme == .dark ? Color(white: 0.16) : .white)
                .environment(\.colorScheme, scheme)
        }
        let view = VStack(spacing: 0) {
            ruler(.dark)
            ruler(.light)
        }
        .tint(Accent.amber.color)
        try Snapshot.verify(view, named: "settings-day-ruler-amber")
    }

    /// The color picker of a network with a picked color (magenta, ringed) and of one without
    /// (Automatic checked, naming its place's color), in dark and in light mode.
    @Test func networkColorPicker() throws {
        let pickers = { (scheme: ColorScheme) in
            HStack(alignment: .top, spacing: 16) {
                NetworkColorPicker(slot: 4, automaticSlot: 0, isPicked: true) { _ in }
                NetworkColorPicker(slot: 1, automaticSlot: 1, isPicked: false) { _ in }
            }
            .padding(8)
            .background(scheme == .dark ? Color(white: 0.16) : .white)
            .environment(\.colorScheme, scheme)
        }
        let view = VStack(spacing: 0) {
            pickers(.dark)
            pickers(.light)
        }
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

    /// Every app icon in the snapshots comes through `AppIcons.load`, so none is the Mac's own.
    /// The popover mockup's resources (`docs/mockups/resources.html`, 1A).
    static let gauges = Gauges(
        on: true, cpuBusy: 0.23, memoryUsed: 23_000_000_000, memoryLevel: 60, pressure: 1,
        volumeFree: 212_000_000_000, volumeSize: 994_000_000_000)

    /// Today's apps as the mockup lists them, by CPU time; 46 apps in all.
    static let resourceApps: [ResourceHistoryData.App] = {
        let minute: UInt64 = 60_000_000_000
        let named: [(String, String, UInt64)] = [
            ("/Applications/Xcode.app", "Xcode", 72), ("/Applications/Safari.app", "Safari", 38),
            ("macos", "macOS & Services", 31), ("/Applications/zoom.us.app", "Zoom", 24),
            ("/Applications/Claude.app", "Claude", 9),
        ]
        let others = (1...41).map { ("process:/usr/bin/tool\($0)", "tool\($0)", UInt64(1)) }
        return (named + others).map { id, name, minutes in
            ResourceHistoryData.App(
                id: id, name: name,
                sum: ResourceSum(
                    cpu: minutes * minute, billed: minutes * minute / 20, read: minutes * 50_000_000,
                    written: minutes * 30_000_000, energy: minutes * 900_000_000_000, footprint: minutes * 40_000_000,
                    peak: minutes * 50_000_000))
        }
    }()

    @Test func popoverResources() throws {
        let content = PopoverContent.make(
            status: Self.status, today: Self.today, registry: Self.registry, current: Self.home,
            connectedSince: Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 18)),
            allNetworks: false, locationAllowed: true, summary: Self.summary, now: Self.now)
        let today = ResourceHistoryData(
            firstHour: 0, total: .zero, previous: nil, bars: [], apps: Self.resourceApps, busiestDay: nil, days: 1,
            heatmap: [])
        let resources = PopoverResources.make(settings: .default, gauges: Self.gauges, measure: .cpu, today: today)
        let view = PopoverView(
            content: content, tab: .constant(.resources), allNetworks: .constant(false), resources: resources,
            animatesOpen: false
        )
        .background(Color(nsColor: .windowBackgroundColor))
        try Snapshot.verify(view, named: "popover-resources")
    }

    @Test func settingsResources() throws {
        let view = ResourceSettingsView(
            settings: .default, gauges: Self.gauges, set: { _, _ in }, volumes: [("/", "Macintosh HD")]
        )
        .background(Color(nsColor: .windowBackgroundColor))
        try Snapshot.verify(view, named: "settings-resources", size: CGSize(width: 560, height: 1100))
    }

    /// October's CPU, a day per bar, from the data page's October shape.
    func resourceHistory(_ measure: ResourceMeasure) -> some View {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 28))!
        let anchor = calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 9))!
        let query = ResourceQuery.make(
            range: .month, anchor: anchor, measure: measure, firstHour: nil, now: now, calendar: calendar)
        let minute: UInt64 = 60_000_000_000
        let days = (0..<27).map { day -> ResourceHistoryData.Bar in
            let start = calendar.date(byAdding: .day, value: day, to: query.interval.start)!
            let cpu = UInt64(60 + (day * 37) % 130) * minute
            return .init(
                firstHour: Int64(start.timeIntervalSince1970),
                sum: ResourceSum(
                    cpu: cpu, footprint: 14_000_000_000 + UInt64(day % 5) * 1_000_000_000,
                    peak: 19_000_000_000 + UInt64(day % 3) * 1_500_000_000))
        }
        let data = ResourceHistoryData(
            firstHour: days.first?.firstHour,
            total: ResourceSum(
                cpu: days.reduce(0) { $0 + $1.sum.cpu }, billed: 185 * minute, read: 80_000_000_000,
                written: 212_000_000_000, energy: 11_000_000_000_000_000, footprint: 16_000_000_000,
                peak: 22_000_000_000),
            // The core answers the comparison and the busiest day by the page's measure.
            previous: measure == .memory ? 15_000_000_000 : 2_700 * minute, bars: days, apps: Self.resourceApps,
            busiestDay: .init(
                firstHour: days[12].firstHour,
                value: measure == .memory ? days[12].sum.footprint : days[12].sum.cpu),
            days: 27,
            heatmap: (0..<7).flatMap { weekday in
                (0..<24).map { hour in
                    ResourceHistoryData.Cell(
                        weekday: weekday, hour: hour, value: UInt64((9...18).contains(hour) ? 20 + weekday : 3) * minute
                    )
                }
            })
        let content = ResourceHistoryContent.make(range: .month, query: query, data: data, now: now, calendar: calendar)
        return ResourceHistoryDetail(
            content: content, minutes: nil, minutesKept: 7, settings: .default, expandedApp: .constant(nil),
            showsAllApps: .constant(false), expandedMeasures: nil
        )
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @Test func historyCPUMonth() throws {
        try Snapshot.verify(resourceHistory(.cpu), named: "history-cpu-month", size: CGSize(width: 780, height: 1180))
    }

    @Test func historyMemoryMonth() throws {
        try Snapshot.verify(
            resourceHistory(.memory), named: "history-memory-month", size: CGSize(width: 780, height: 1180))
    }

    /// A Day page minute by minute, at 15:04 (`docs/mockups/resources.html`, 3A): a CPU spike from
    /// 15:00 to 15:15 under memory pressure.
    @Test func historyCPUDayByTheMinute() throws {
        let calendar = Calendar.current
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 12))!
        let start = Int64(day.timeIntervalSince1970)
        let minutes = (0..<1440).map { m -> MinuteRecord.Minute in
            let spike = (900..<915).contains(m)
            return .init(
                start: start + Int64(m) * 60, cpuBusy: spike ? 0.94 : 0.08 + Double(m % 37) / 200,
                memoryUsed: UInt64(20 + (m / 180)) * 1_073_741_824, memoryLevel: spike ? 30 : 55,
                pressure: spike ? 2 : 1, volumeFree: 212_000_000_000, volumeSize: 994_000_000_000)
        }
        let named = { (rows: [(String, UInt64)], unit: UInt64) in
            rows.map { MinuteApps.App(id: $0.0, name: $0.0, value: $0.1 * unit) }
        }
        let apps = MinuteApps(
            cpu: named(
                [("Xcode", 612), ("swift-frontend", 180), ("Safari", 31), ("WindowServer", 18), ("Zoom", 12)],
                600_000_000),
            memory: named(
                [("Xcode", 9_200), ("Safari", 3_400), ("macOS & Services", 2_900), ("Docker", 2_100), ("Zoom", 820)],
                1_000_000),
            written: named(
                [("Xcode", 1_400), ("macOS & Services", 220), ("Spotlight", 90), ("Safari", 12), ("Claude", 3)],
                1_000_000))
        let content = MinuteContent.make(
            record: MinuteRecord(firstMinute: start, minutes: minutes), selected: start + 904 * 60, apps: apps,
            settings: .default, keptDays: 7, memoryTotal: 34_359_738_368, cores: 12)
        // Each hour's CPU time from its minutes' busy shares on 12 cores.
        let hours = (0..<24).map { hour -> ResourceHistoryData.Bar in
            let busy = minutes[(hour * 60)..<(hour * 60 + 60)].reduce(0.0) { $0 + ($1.cpuBusy ?? 0) }
            return .init(
                firstHour: start + Int64(hour) * 3600, sum: ResourceSum(cpu: UInt64(busy * 60 * 12 * 1e9)))
        }
        let total = hours.reduce(0) { $0 + $1.sum.cpu }
        let query = ResourceQuery(
            interval: DateInterval(start: day, duration: 86_400), previous: nil, step: .hour, measure: .cpu)
        let page = ResourceHistoryContent.make(
            range: .day, query: query,
            data: ResourceHistoryData(
                firstHour: start, total: ResourceSum(cpu: total, billed: total / 20), previous: total * 9 / 10,
                bars: hours, apps: Self.resourceApps, busiestDay: .init(firstHour: start, value: total), days: 1,
                heatmap: []),
            now: day.addingTimeInterval(86_400), calendar: calendar)
        let view = ResourceHistoryDetail(
            content: page, minutes: content, minutesKept: 7, settings: .default, expandedApp: .constant(nil),
            showsAllApps: .constant(false), expandedMeasures: nil
        )
        .background(Color(nsColor: .windowBackgroundColor))
        try Snapshot.verify(view, named: "history-cpu-day-minutes", size: CGSize(width: 780, height: 1180))
    }

    @Test func appIconsComeFromTheFixedLoader() throws {
        var asked: Set<String> = []
        AppIcons.load = {
            asked.insert($0)
            return Self.fixedIcon(forPath: $0)
        }
        _ = try #require(Snapshot.render(popover(.apps), size: nil))
        let popoverApps = Set(Self.today.apps.map(\.id).filter { $0.hasPrefix("/") })
        #expect(popoverApps.isSubset(of: asked), "popover: \(popoverApps.subtracting(asked).sorted())")
        // The popover's icons are cached; History must ask for its own.
        AppIcons.clear()
        asked = []
        _ = try #require(Snapshot.render(history(.month), size: CGSize(width: 780, height: 1180)))
        let historyApps = Set(Self.october.apps.map(\.id).filter { $0.hasPrefix("/") })
        #expect(historyApps.isSubset(of: asked), "History: \(historyApps.subtracting(asked).sorted())")
    }

    /// A snapshot must not depend on the display it runs on, or a baseline recorded on one display
    /// fails on another.
    @Test func renderingIgnoresTheDisplayColorSpace() throws {
        let spaces: [NSColorSpace] = [.sRGB, .displayP3, .adobeRGB1998]
        let images = try spaces.map { try #require(Snapshot.render(popover(.apps), size: nil, windowColorSpace: $0)) }
        for (space, image) in zip(spaces, images) {
            #expect(image.colorSpace == Snapshot.colorSpace.cgColorSpace, "rendered in \(space.localizedName ?? "?")")
            #expect(
                Snapshot.changedPixels(image, images[0], tolerance: 0) == 0,
                "rendered in \(space.localizedName ?? "?")")
        }
    }

    /// An image without a bitmap of its own is drawn in the snapshots' color space, not the main
    /// screen's: the fixed app icons and the menu bar glyph are such images.
    @Test func imagesAreDrawnInTheSnapshotColorSpace() throws {
        final class Spaces: @unchecked Sendable { var drawnIn: [CGColorSpace?] = [] }
        let spaces = Spaces()
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            spaces.drawnIn.append(NSGraphicsContext.current?.cgContext.colorSpace)
            NSColor(white: 1, alpha: 0.85).setFill()
            rect.fill()
            return true
        }
        _ = try #require(Snapshot.render(Image(nsImage: image), size: nil))
        #expect(!spaces.drawnIn.isEmpty, "the image was never drawn")
        for space in spaces.drawnIn {
            #expect(space == Snapshot.colorSpace.cgColorSpace, "drawn in \(space?.name as String? ?? "?")")
        }
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
