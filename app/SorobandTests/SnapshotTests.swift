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

    static let status = EngineStatus(
        networkID: 1,
        todayNetworkApps: ByteCounts(rx: 890_000_000, tx: 120_000_000),
        todayNetworkInterfaces: ByteCounts(rx: 893_600_000, tx: 203_800_000),
        todayApps: ByteCounts(rx: 1_190_000_000, tx: 180_000_000),
        todayInterfaces: ByteCounts(rx: 1_223_600_000, tx: 273_800_000),
        speed: ByteCounts(rx: 137_000, tx: 42_000))

    func popover(_ tab: PopoverView.Tab, allNetworks: Bool = false, status: EngineStatus = status) -> some View {
        let content = PopoverContent.make(
            status: status, today: Self.today, registry: Self.registry, current: Self.home,
            // 18:00 local time on 2026-10-27.
            connectedSince: Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 18)),
            allNetworks: allNetworks)
        return PopoverView(content: content, tab: .constant(tab), allNetworks: .constant(allNetworks))
            .background(Color(nsColor: .windowBackgroundColor))
    }

    @Test func popoverApps() throws {
        try Snapshot.verify(popover(.apps), named: "popover-apps")
    }

    @Test func popoverAppsOnAllNetworks() throws {
        try Snapshot.verify(popover(.apps, allNetworks: true), named: "popover-apps-all-networks")
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
        let view = GeneralSettings(usage: Usage(), launchAtLogin: launch)
            .background(Color(nsColor: .windowBackgroundColor))
        try Snapshot.verify(view, named: "settings-general", size: CGSize(width: 560, height: 300))
    }

    @Test func settingsNetworks() throws {
        let view = NetworkSettings(
            networks: Self.registry, location: .notDetermined, requestLocation: {}, save: { _, _, _ in }
        )
        .background(Color(nsColor: .windowBackgroundColor))
        try Snapshot.verify(view, named: "settings-networks", size: CGSize(width: 560, height: 340))
    }

    @Test func onboarding() throws {
        let view = OnboardingView(done: {}).background(Color(nsColor: .windowBackgroundColor))
        try Snapshot.verify(view, named: "onboarding")
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
