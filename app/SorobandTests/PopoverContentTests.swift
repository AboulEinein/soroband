import Foundation
import Testing

@testable import Soroband

/// The popover's rows from a day worked out by hand: Home (Wi‑Fi, first seen) and iPhone
/// (hotspot), with Office known but unused today.
struct PopoverContentTests {
    let home = Network(id: 1, key: "wifi:Home", name: "Home", kind: .wifi)
    let registry = [
        RegisteredNetwork(id: 1, key: "wifi:Home", name: "Home", kind: .wifi, lastUsed: 1_793_098_800),
        RegisteredNetwork(id: 2, key: "wifi:iPhone", name: "iPhone", kind: .hotspot, lastUsed: 1_793_095_200),
        RegisteredNetwork(id: 3, key: "wifi:Office", name: "Office", kind: .wifi, lastUsed: 1_792_900_000),
    ]

    /// Home: Safari 400 + 20, Mail 30 + 0, curl 50 + 0 credited; 600 + 40 crossed. iPhone: Safari
    /// 100 + 10 credited; 130 + 10 crossed.
    let today = Today(
        networks: [
            .init(network: 1, apps: ByteCounts(rx: 480, tx: 20), interfaces: ByteCounts(rx: 600, tx: 40)),
            .init(network: 2, apps: ByteCounts(rx: 100, tx: 10), interfaces: ByteCounts(rx: 130, tx: 10)),
        ],
        apps: [
            .init(network: 1, id: "/Applications/Mail.app", name: "Mail", rx: 30, tx: 0),
            .init(network: 1, id: "/Applications/Safari.app", name: "Safari", rx: 400, tx: 20),
            .init(network: 1, id: "process:curl", name: "curl", rx: 50, tx: 0),
            .init(network: 2, id: "/Applications/Safari.app", name: "Safari", rx: 100, tx: 10),
        ])

    var status: EngineStatus {
        EngineStatus(
            networkID: 1,
            todayNetworkApps: ByteCounts(rx: 480, tx: 20),
            todayNetworkInterfaces: ByteCounts(rx: 600, tx: 40),
            todayApps: ByteCounts(rx: 580, tx: 30),
            todayInterfaces: ByteCounts(rx: 730, tx: 50),
            speed: ByteCounts(rx: 137_000, tx: 42_000))
    }

    func content(allNetworks: Bool = false, status: EngineStatus? = nil, current: Network?? = nil) -> PopoverContent {
        PopoverContent.make(
            status: status ?? self.status, today: today, registry: registry, current: current ?? home,
            connectedSince: Date(timeIntervalSince1970: 1_793_080_800), allNetworks: allNetworks)
    }

    @Test func headerShowsTodayOnThisNetworkAsCrossedItsInterfaces() {
        let header = content().header
        #expect(header.name == "Home")
        #expect(header.kind == .wifi)
        #expect(header.slot == 0)
        #expect(header.today == ByteCounts(rx: 600, tx: 40))
        #expect(header.speed == ByteCounts(rx: 137_000, tx: 42_000))
    }

    @Test func appsTabListsThisNetworksAppsLargestFirst() {
        let content = content()
        #expect(content.appsTitle == "Today on Home")
        #expect(content.apps.map(\.title) == ["Safari", "curl", "Mail"])
        // Safari's iPhone bytes are not on Home.
        #expect(content.apps[0].bytes == ByteCounts(rx: 400, tx: 20))
        #expect(content.apps[0].segments == [.init(slot: 0, bytes: 420)])
        #expect(
            content.apps.map(\.icon) == [.file("/Applications/Safari.app"), .tool, .file("/Applications/Mail.app")])
    }

    @Test func overheadIsTheRawGapBetweenTheInterfacesAndTheApps() {
        // Home: 640 crossed, 500 credited.
        let overhead = content().overhead
        #expect(overhead.title == "Other / overhead")
        #expect(overhead.bytes == ByteCounts(rx: 120, tx: 20))
        // All networks: 780 crossed, 610 credited.
        #expect(content(allNetworks: true).overhead.bytes == ByteCounts(rx: 150, tx: 20))
    }

    @Test func overheadNeverGoesNegative() {
        // Apps credited with more than crossed (the self-check flags it): no gap to show.
        let over = EngineStatus(
            networkID: 1, todayNetworkApps: ByteCounts(rx: 700, tx: 50),
            todayNetworkInterfaces: ByteCounts(rx: 600, tx: 40), check: .overcount)
        let content = content(status: over)
        #expect(content.overhead.bytes == .zero)
        #expect(content.notice == .overcount)
    }

    @Test func overheadTotalIsTheDifferenceOfTheTotalsWhicheverDirectionIsShort() {
        // An upload: 100 + 500 crossed, apps credited 150 + 0. Received is 50 over, so the gap
        // is 600 - 150 = 450, all of it sent.
        #expect(ByteCounts(rx: 100, tx: 500).gap(minus: ByteCounts(rx: 150, tx: 0)) == ByteCounts(rx: 0, tx: 450))
        #expect(ByteCounts(rx: 500, tx: 100).gap(minus: ByteCounts(rx: 0, tx: 150)) == ByteCounts(rx: 450, tx: 0))
        #expect(ByteCounts(rx: 100, tx: 10).gap(minus: ByteCounts(rx: 200, tx: 20)) == .zero)
    }

    @Test func allNetworksSplitsEachAppsBarByNetworkColor() {
        let content = content(allNetworks: true)
        #expect(content.appsTitle == "Today, all networks")
        let safari = content.apps[0]
        #expect(safari.title == "Safari")
        #expect(safari.bytes == ByteCounts(rx: 500, tx: 30))
        // Home's color first (slot 0), then iPhone's (slot 1), in registry order.
        #expect(safari.segments == [.init(slot: 0, bytes: 420), .init(slot: 1, bytes: 110)])
    }

    @Test func barsScaleToTheLargestRowIncludingOverhead() {
        #expect(content().appsScale == 420)
        // An idle day where the gap is larger than any app: 2,000 crossed, 500 credited.
        let idle = EngineStatus(
            networkID: 1, todayNetworkApps: ByteCounts(rx: 480, tx: 20),
            todayNetworkInterfaces: ByteCounts(rx: 2_000, tx: 0))
        #expect(content(status: idle).appsScale == 1_500)
        // The 20 bytes sent beyond the interfaces' count come off the received gap.
        #expect(content(status: idle).overhead.bytes == ByteCounts(rx: 1_500, tx: 0))
    }

    @Test func onlySevenAppsAreListedAndTheRestCounted() {
        let many = Today(
            networks: today.networks,
            apps: (1...10).map { .init(network: 1, id: "process:tool\($0)", name: "tool\($0)", rx: UInt64($0), tx: 0) })
        let content = PopoverContent.make(
            status: status, today: many, registry: registry, current: home, connectedSince: nil, allNetworks: false)
        #expect(content.apps.map(\.title) == ["tool10", "tool9", "tool8", "tool7", "tool6", "tool5", "tool4"])
        #expect(content.hiddenApps == 3)
    }

    @Test func networksTabListsEveryNetworkWithWhenUnusedOnesWereLastUsed() {
        let networks = content().networks
        #expect(networks.map(\.title) == ["Home", "iPhone", "Office"])
        #expect(networks.map(\.bytes) == [ByteCounts(rx: 600, tx: 40), ByteCounts(rx: 130, tx: 10), .zero])
        #expect(networks[0].subtitle == .connected)
        // Used today: no subtitle needed.
        #expect(networks[1].subtitle == nil)
        #expect(networks[2].subtitle == .lastUsed(Date(timeIntervalSince1970: 1_792_900_000)))
        #expect(
            networks.map(\.icon) == [
                .network(.wifi, slot: 0), .network(.hotspot, slot: 1), .network(.wifi, slot: 2),
            ])
        #expect(content().networksScale == 640)
    }

    /// A color picked in Settings replaces the one of the network's place, in every view that
    /// colors networks; the others keep theirs.
    @Test func aPickedColorReplacesTheColorOfTheNetworksPlace() throws {
        var registry = registry
        registry[0].color = 3
        let networks = PopoverContent.make(
            status: status, today: today, registry: registry, current: home, connectedSince: nil, allNetworks: false
        ).networks
        #expect(
            networks.map(\.icon) == [.network(.wifi, slot: 3), .network(.hotspot, slot: 1), .network(.wifi, slot: 2)])
        let decoded = try JSONDecoder().decode(
            [RegisteredNetwork].self,
            from: Data(#"[{"id":1,"key":"wifi:Home","name":"Home","kind":"wifi","last_used":null,"color":4}]"#.utf8))
        #expect(decoded[0].color == 4)
        #expect(NetworkColor.slot(for: decoded[0], index: 0) == 4)
        #expect(NetworkColor.slot(for: RegisteredNetwork.unpicked(decoded[0]), index: 0) == 0)
    }

    @Test func aNetworkNeverUsedSaysSo() {
        var registry = registry
        registry.append(RegisteredNetwork(id: 4, key: "wifi:Cafe", name: "Cafe", kind: .wifi, lastUsed: nil))
        let content = PopoverContent.make(
            status: status, today: today, registry: registry, current: home, connectedSince: nil, allNetworks: false)
        #expect(content.networks.last?.subtitle == .neverUsed)
    }

    @Test func noIdentifiedNetworkShowsUnknownAndListsItsBytes() {
        let waiting = Today(
            networks: today.networks + [.init(network: 0, apps: .zero, interfaces: ByteCounts(rx: 5, tx: 0))],
            apps: today.apps)
        let status = EngineStatus(networkID: 0, todayNetworkInterfaces: ByteCounts(rx: 5, tx: 0))
        let content = PopoverContent.make(
            status: status, today: waiting, registry: registry, current: nil,
            connectedSince: Date(timeIntervalSince1970: 1), allNetworks: false)
        #expect(content.header.name == "Unknown network")
        #expect(content.header.kind == nil)
        #expect(content.header.connectedSince == nil)
        #expect(content.apps.isEmpty, "no app is booked to no network")
        let unknown = content.networks.first { $0.title == "Unknown network" }
        #expect(unknown?.subtitle == .connected)
        #expect(unknown?.bytes == ByteCounts(rx: 5, tx: 0))
        // Home, used today, is no longer the connected one.
        #expect(content.networks.first { $0.title == "Home" }?.subtitle == nil)
    }

    @Test func engineProblemsShowANotice() {
        #expect(content().notice == nil)
        #expect(content(status: EngineStatus(state: .interfaceOnly)).notice == .perAppOff)
        #expect(content(status: EngineStatus(state: .failed)).notice == .failed)
        #expect(content(status: EngineStatus(check: .degraded)).notice == .degraded)
        // On interface totals the check has nothing to judge; that notice wins.
        #expect(content(status: EngineStatus(state: .interfaceOnly, check: .degraded)).notice == .perAppOff)
    }

    @Test func appIconsFollowTheCoresAppIdentities() {
        #expect(PopoverContent.icon(forApp: "/Applications/Safari.app") == .file("/Applications/Safari.app"))
        #expect(PopoverContent.icon(forApp: "/usr/bin/curl") == .file("/usr/bin/curl"))
        #expect(PopoverContent.icon(forApp: "macOS & Services") == .services)
        #expect(PopoverContent.icon(forApp: "process:curl") == .tool)
    }

    /// Wi‑Fi known by its router is named "Wi-Fi" until Location access is allowed; the popover
    /// offers it only then, not on a named Wi‑Fi nor on a wired network known by its router.
    @Test func asksForLocationOnlyOnWifiKnownByItsRouter() {
        let byRouter = Network(id: 1, key: "wifi-router:2:0:0:1:2:3", name: "Wi-Fi", kind: .wifi)
        let dock = Network(id: 1, key: "ethernet:0:11:22:33:44:55", name: "Ethernet", kind: .ethernet)
        let asks = { (current: Network?, allowed: Bool) in
            PopoverContent.make(
                status: status, today: today, registry: registry, current: current, connectedSince: nil,
                allNetworks: false, locationAllowed: allowed
            ).asksForLocation
        }
        #expect(asks(byRouter, false))
        #expect(!asks(byRouter, true))
        #expect(!asks(home, false))
        #expect(!asks(dock, false))
        #expect(!asks(nil, false))
    }
}
