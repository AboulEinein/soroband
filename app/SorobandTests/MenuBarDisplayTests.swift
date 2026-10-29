import Foundation
import Testing

@testable import Soroband

/// The menu bar item in each display mode, from a status worked out by hand.
struct MenuBarDisplayTests {
    /// Today: 1.1 GB crossed this network's interfaces, 2.87 GB all networks; apps were
    /// credited with less, which the menu bar must not show.
    let status = EngineStatus(
        networkID: 1,
        todayNetworkApps: ByteCounts(rx: 800_000_000, tx: 200_000_000),
        todayNetworkInterfaces: ByteCounts(rx: 893_600_000, tx: 206_400_000),
        todayApps: ByteCounts(rx: 2_000_000_000, tx: 500_000_000),
        todayInterfaces: ByteCounts(rx: 2_370_000_000, tx: 500_000_000),
        speed: ByteCounts(rx: 137_000, tx: 42_000))

    @Test func defaultShowsTodayOnTheCurrentNetworkAsCrossedItsInterfaces() {
        let display = MenuBarDisplay.make(mode: .todayNetwork, status: status, kind: .wifi)
        #expect(display == MenuBarDisplay(symbol: "wifi", text: "1.1 GB"))
    }

    @Test func todayAllSumsEveryNetwork() {
        let display = MenuBarDisplay.make(mode: .todayAll, status: status, kind: .hotspot)
        // 2.87 GB rounded down to a tenth.
        #expect(display == MenuBarDisplay(symbol: "personalhotspot", text: "2.8 GB"))
    }

    /// Today's 893.6 MB down and 206.4 MB up on this network, 2.37 GB and 500 MB on all of them.
    @Test func countShowsDownloadUploadOrBothOfTodayAsCrossedTheInterfaces() {
        let text = { (mode: MenuBarMode, count: MenuBarCount) in
            MenuBarDisplay.make(mode: mode, count: count, status: status, kind: .wifi).text
        }
        #expect(text(.todayNetwork, .total) == "1.1 GB")
        #expect(text(.todayNetwork, .download) == "↓ 893 MB")
        #expect(text(.todayNetwork, .upload) == "↑ 206 MB")
        #expect(text(.todayNetwork, .both) == "↓ 893 MB ↑ 206 MB")
        #expect(text(.todayAll, .download) == "↓ 2.3 GB")
        #expect(text(.todayAll, .upload) == "↑ 500 MB")
        // Live speed and the icon have no day's count to choose from.
        #expect(text(.speed, .upload) == "↓ 137 KB/s ↑ 42 KB/s")
        #expect(text(.icon, .both) == nil)
    }

    /// Showing upload only, a download that does not move the upload must not redraw the item.
    @Test func theThrottleFollowsTheBytesTheCountShows() {
        #expect(MenuBarDisplay.total(mode: .todayNetwork, count: .download, status: status) == 893_600_000)
        #expect(MenuBarDisplay.total(mode: .todayNetwork, count: .upload, status: status) == 206_400_000)
        #expect(MenuBarDisplay.total(mode: .todayAll, count: .both, status: status) == 2_870_000_000)
        let t = Date(timeIntervalSince1970: 1_793_098_800)
        let old = MenuBarDisplay.Drawn(
            display: MenuBarDisplay(symbol: "wifi", text: "1.1 GB"), mode: .todayNetwork, count: .total, network: 1,
            total: 1_100_000_000)
        let switched = MenuBarDisplay.Drawn(
            display: MenuBarDisplay(symbol: "wifi", text: "↓ 893 MB"), mode: .todayNetwork, count: .download,
            network: 1, total: 893_600_000)
        #expect(MenuBarDisplay.redrawDelay(from: old, to: switched, lastRedraw: t, now: t + 5) == 0, "count changed")
    }

    @Test func countsAreTheCoreSettingsValues() {
        // `soroband config set menu_bar_count <value>` must name a count the app knows.
        #expect(MenuBarCount.allCases.map(\.rawValue) == ["total", "download", "upload", "both"])
    }

    @Test func speedShowsDownloadAndUploadPerSecond() {
        let display = MenuBarDisplay.make(mode: .speed, status: status, kind: .ethernet)
        #expect(display == MenuBarDisplay(symbol: "cable.connector.horizontal", text: "↓ 137 KB/s ↑ 42 KB/s"))
    }

    /// Each change of the text redraws the item on every display, which an idle Mac cannot
    /// afford every few seconds: idle traffic of a few KB/s must leave it alone.
    @Test func idleTrafficLeavesTheTextUnchangedUntilTheNextMegabyte() {
        let texts = [183_000_000, 183_400_000, 183_999_999, 184_000_000].map { (bytes: UInt64) in
            MenuBarDisplay.make(
                mode: .todayNetwork, status: EngineStatus(todayNetworkInterfaces: ByteCounts(rx: bytes, tx: 0)),
                kind: .wifi
            ).text
        }
        #expect(texts == ["183 MB", "183 MB", "183 MB", "184 MB"])
        #expect(Format.menuBarBytes(999_999) == "< 1 MB")
        #expect(Format.menuBarBytes(1_099_999_999) == "1.0 GB")
        #expect(Format.menuBarBytes(12_345_000_000) == "12.3 GB")
    }

    @Test func aGrowingTotalRedrawsAtMostOnceAMinute() {
        let t = Date(timeIntervalSince1970: 1_793_098_800)
        typealias Drawn = MenuBarDisplay.Drawn
        let old = Drawn(
            display: MenuBarDisplay(symbol: "wifi", text: "183 MB"), mode: .todayNetwork, network: 1, total: 183_000_000
        )
        let grown = Drawn(
            display: MenuBarDisplay(symbol: "wifi", text: "184 MB"), mode: .todayNetwork, network: 1, total: 184_000_000
        )
        let delay = { (new: Drawn, secondsSince: TimeInterval) in
            MenuBarDisplay.redrawDelay(from: old, to: new, lastRedraw: t, now: t + secondsSince)
        }
        #expect(delay(grown, 5) == 55)
        #expect(delay(grown, 59) == 1)
        #expect(delay(grown, 61) == 0)
        // What the user changed or must see shows at once.
        var other = grown
        other.display.symbol = "personalhotspot"
        #expect(delay(other, 5) == 0, "new network of another kind")
        // Wi‑Fi to Wi‑Fi: same icon, and the new network's total may well be larger.
        other = grown
        other.network = 2
        other.display.text = "950 MB"
        other.total = 950_000_000
        #expect(delay(other, 5) == 0, "new network of the same kind")
        other = Drawn(
            display: MenuBarDisplay(symbol: "wifi", text: "2 MB"), mode: .todayNetwork, network: 1, total: 2_000_000)
        #expect(delay(other, 5) == 0, "reset hour: the total went down")
        other = Drawn(
            display: MenuBarDisplay(symbol: "wifi", text: "1.1 GB"), mode: .todayAll, network: 1, total: 1_100_000_000)
        #expect(delay(other, 5) == 0, "mode changed, though the total grew")
        other = Drawn(
            display: MenuBarDisplay(symbol: "wifi", text: "↓ 2 KB/s ↑ 1 KB/s"), mode: .speed, network: 1, total: nil)
        #expect(delay(other, 5) == 0, "live speed")
        // The first count after launch, which had no text, shows at once.
        let launching = Drawn(
            display: MenuBarDisplay(symbol: "wifi", text: nil), mode: .todayNetwork, network: 1, total: 0)
        #expect(MenuBarDisplay.redrawDelay(from: launching, to: grown, lastRedraw: t, now: t + 5) == 0)
        #expect(
            MenuBarDisplay.make(mode: .todayNetwork, status: EngineStatus(state: .starting), kind: .wifi)
                == MenuBarDisplay(symbol: "wifi", text: nil))
    }

    @Test func iconOnlyHasNoText() {
        #expect(
            MenuBarDisplay.make(mode: .icon, status: status, kind: .wifi) == MenuBarDisplay(symbol: "wifi", text: nil))
    }

    @Test func noIdentifiedNetworkShowsThePlainNetworkIcon() {
        #expect(MenuBarDisplay.make(mode: .todayNetwork, status: status, kind: nil).symbol == "network")
    }

    @Test func aStoppedEngineSaysSoInsteadOfAFrozenCount() {
        let failed = EngineStatus(state: .failed, todayNetworkInterfaces: ByteCounts(rx: 5_000_000, tx: 0))
        let display = MenuBarDisplay.make(mode: .todayNetwork, status: failed, kind: .wifi)
        #expect(display == MenuBarDisplay(symbol: "exclamationmark.triangle", text: "Not counting"))
    }

    @Test func modesAreTheCoreSettingsValues() {
        // `soroband config set menu_bar <value>` must name a mode the app knows.
        #expect(MenuBarMode.allCases.map(\.rawValue) == ["today_network", "today_all", "speed", "icon"])
    }

    @Test func bytesReadInDecimalUnits() {
        #expect(Format.bytes(0) == "0 bytes")
        #expect(Format.bytes(999) == "999 bytes")
        #expect(Format.bytes(420_300_000) == "420.3 MB")
        #expect(Format.speed(1_500_000) == "1.5 MB/s")
    }

    /// A Debug build runs beside the installed app, so its item must not look like the installed
    /// one: an orange icon instead of the menu bar's template, and its own name for VoiceOver.
    @Test func aDebugBuildsItemStandsApartFromTheInstalledApps() throws {
        #expect(MenuBarDisplay.isDebugBuild, "tests run on the Debug build")
        let display = MenuBarDisplay(symbol: "wifi", text: "1.1 GB")
        let installed = try #require(display.image(debug: false))
        let debug = try #require(display.image(debug: true))
        #expect(installed.isTemplate)
        #expect(!debug.isTemplate)
        #expect(display.accessibilityLabel(debug: false) == "Soroband, 1.1 GB")
        #expect(display.accessibilityLabel(debug: true) == "Soroband Debug, 1.1 GB")
    }
}
