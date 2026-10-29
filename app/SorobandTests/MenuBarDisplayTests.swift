import Foundation
import Testing

@testable import Soroband

/// The menu bar item for each layout, from a status worked out by hand.
struct MenuBarDisplayTests {
    /// Today: 1.1 GB crossed this network's interfaces (893.6 MB down, 206.4 MB up), 2.87 GB all
    /// networks (2.37 GB down, 500 MB up); apps were credited with less, which the menu bar must
    /// not show. Live: 137 KB/s down, 42 KB/s up.
    let status = EngineStatus(
        networkID: 1,
        todayNetworkApps: ByteCounts(rx: 800_000_000, tx: 200_000_000),
        todayNetworkInterfaces: ByteCounts(rx: 893_600_000, tx: 206_400_000),
        todayApps: ByteCounts(rx: 2_000_000_000, tx: 500_000_000),
        todayInterfaces: ByteCounts(rx: 2_370_000_000, tx: 500_000_000),
        speed: ByteCounts(rx: 137_000, tx: 42_000))

    func lines(
        _ top: MenuBarLine, _ bottom: MenuBarLine = .none, scope: MenuBarScope = .network,
        status: EngineStatus? = nil
    ) -> [String] {
        MenuBarDisplay.make(
            layout: MenuBarLayout(scope: scope, top: top, bottom: bottom), status: status ?? self.status, kind: .wifi
        ).lines
    }

    @Test func defaultShowsTodaysTotalOnTheCurrentNetworkAsCrossedItsInterfaces() {
        let display = MenuBarDisplay.make(layout: .default, status: status, kind: .wifi)
        #expect(display == MenuBarDisplay(symbol: "wifi", lines: ["1.1 GB"]))
    }

    @Test func allNetworksSumsEveryNetwork() {
        // 2.87 GB rounded down to a tenth.
        #expect(lines(.total, scope: .all) == ["2.8 GB"])
        #expect(lines(.download, .upload, scope: .all) == ["↓ 2.3 GB", "↑ 500 MB"])
    }

    /// Each line shows one reading; two lines stack, top first.
    @Test func eachLineShowsTodaysBytesOrTheLiveSpeed() {
        #expect(lines(.download) == ["↓ 893 MB"])
        #expect(lines(.upload) == ["↑ 206 MB"])
        #expect(lines(.download, .upload) == ["↓ 893 MB", "↑ 206 MB"])
        #expect(lines(.speedDown, .speedUp) == ["↓ 137 KB/s", "↑ 42 KB/s"])
        // Both speeds alone stack; beside a usage line they share one.
        #expect(lines(.speed) == ["↓ 137 KB/s", "↑ 42 KB/s"])
        #expect(lines(.none, .speed) == ["↓ 137 KB/s", "↑ 42 KB/s"])
        // Usage and speed together: today's total over the live speed.
        #expect(lines(.total, .speed) == ["1.1 GB", "↓ 137 KB/s ↑ 42 KB/s"])
        // An empty top line leaves the bottom one alone on the first line.
        #expect(lines(.none, .upload) == ["↑ 206 MB"])
        #expect(lines(.none, .none).isEmpty, "icon only")
    }

    /// Only bytes the lines show move the throttle; any speed redraws at every poll.
    @Test func theThrottleFollowsTheBytesTheLinesShow() {
        let total = { (top: MenuBarLine, bottom: MenuBarLine) in
            MenuBarDisplay.total(layout: MenuBarLayout(top: top, bottom: bottom), status: status)
        }
        #expect(total(.upload, .none) == 206_400_000)
        #expect(total(.download, .upload) == 1_100_000_000)
        #expect(total(.total, .speed) == nil)
        #expect(total(.none, .none) == nil)
        let t = Date(timeIntervalSince1970: 1_793_098_800)
        let old = MenuBarDisplay.Drawn(
            display: MenuBarDisplay(symbol: "wifi", lines: ["1.1 GB"]), layout: .default, network: 1,
            total: 1_100_000_000)
        let redesigned = MenuBarDisplay.Drawn(
            display: MenuBarDisplay(symbol: "wifi", lines: ["↓ 893 MB", "↑ 206 MB"]),
            layout: MenuBarLayout(top: .download, bottom: .upload), network: 1, total: 1_100_000_000)
        #expect(MenuBarDisplay.redrawDelay(from: old, to: redesigned, lastRedraw: t, now: t + 5) == 0, "new layout")
    }

    @Test func linesAndScopesAreTheCoreSettingsValues() {
        // `soroband config set menu_bar_top <value>` must name a line the app knows.
        #expect(
            MenuBarLine.allCases.map(\.rawValue) == [
                "total", "download", "upload", "speed", "speed_down", "speed_up", "none",
            ])
        #expect(MenuBarScope.allCases.map(\.rawValue) == ["network", "all"])
        #expect(MenuBarLayout.default == MenuBarLayout(scope: .network, top: .total, bottom: .none))
    }

    /// Each change of the text redraws the item on every display, which an idle Mac cannot
    /// afford every few seconds: idle traffic of a few KB/s must leave it alone.
    @Test func idleTrafficLeavesTheTextUnchangedUntilTheNextMegabyte() {
        let texts = [183_000_000, 183_400_000, 183_999_999, 184_000_000].map { (bytes: UInt64) in
            lines(.total, status: EngineStatus(todayNetworkInterfaces: ByteCounts(rx: bytes, tx: 0)))
        }
        #expect(texts == [["183 MB"], ["183 MB"], ["183 MB"], ["184 MB"]])
        #expect(Format.menuBarBytes(999_999) == "< 1 MB")
        #expect(Format.menuBarBytes(1_099_999_999) == "1.0 GB")
        #expect(Format.menuBarBytes(12_345_000_000) == "12.3 GB")
    }

    @Test func aGrowingTotalRedrawsAtMostOnceAMinute() {
        let t = Date(timeIntervalSince1970: 1_793_098_800)
        typealias Drawn = MenuBarDisplay.Drawn
        let old = Drawn(
            display: MenuBarDisplay(symbol: "wifi", lines: ["183 MB"]), layout: .default, network: 1,
            total: 183_000_000)
        let grown = Drawn(
            display: MenuBarDisplay(symbol: "wifi", lines: ["184 MB"]), layout: .default, network: 1,
            total: 184_000_000)
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
        other.display.lines = ["950 MB"]
        other.total = 950_000_000
        #expect(delay(other, 5) == 0, "new network of the same kind")
        other = Drawn(
            display: MenuBarDisplay(symbol: "wifi", lines: ["2 MB"]), layout: .default, network: 1, total: 2_000_000)
        #expect(delay(other, 5) == 0, "reset hour: the total went down")
        other = Drawn(
            display: MenuBarDisplay(symbol: "wifi", lines: ["1.1 GB"]), layout: MenuBarLayout(scope: .all),
            network: 1, total: 1_100_000_000)
        #expect(delay(other, 5) == 0, "layout changed, though the total grew")
        other = Drawn(
            display: MenuBarDisplay(symbol: "wifi", lines: ["↓ 2 KB/s ↑ 1 KB/s"]),
            layout: MenuBarLayout(top: .speed), network: 1, total: nil)
        #expect(delay(other, 5) == 0, "live speed")
        // The first count after launch, which had no text, shows at once.
        let launching = Drawn(
            display: MenuBarDisplay(symbol: "wifi", lines: []), layout: .default, network: 1, total: 0)
        #expect(MenuBarDisplay.redrawDelay(from: launching, to: grown, lastRedraw: t, now: t + 5) == 0)
        #expect(lines(.total, status: EngineStatus(state: .starting)).isEmpty)
    }

    @Test func noIdentifiedNetworkShowsThePlainNetworkIcon() {
        #expect(MenuBarDisplay.make(layout: .default, status: status, kind: nil).symbol == "network")
    }

    @Test func aStoppedEngineSaysSoInsteadOfAFrozenCount() {
        let failed = EngineStatus(state: .failed, todayNetworkInterfaces: ByteCounts(rx: 5_000_000, tx: 0))
        #expect(
            MenuBarDisplay.make(layout: MenuBarLayout(top: .download, bottom: .upload), status: failed, kind: .wifi)
                == MenuBarDisplay(symbol: "exclamationmark.triangle", lines: ["Not counting"]))
        #expect(lines(.none, status: failed).isEmpty, "icon only stays an icon")
    }

    @Test func bytesReadInDecimalUnits() {
        #expect(Format.bytes(0) == "0 bytes")
        #expect(Format.bytes(999) == "999 bytes")
        #expect(Format.bytes(420_300_000) == "420.3 MB")
        #expect(Format.speed(1_500_000) == "1.5 MB/s")
    }

    /// Two stacked lines are drawn into the item's one image, which must still follow the menu
    /// bar's color (a template) and fit its height.
    @MainActor @Test func stackedLinesAreOneTemplateImageTheMenuBarsHeight() throws {
        let display = MenuBarDisplay(symbol: "wifi", lines: ["↓ 893 MB", "↑ 206 MB"])
        let installed = try #require(display.stackedItemImage(debug: false))
        #expect(installed.isTemplate)
        #expect(installed.size.height == 22)
        let icon = try #require(display.image(debug: false))
        #expect(installed.size.width > icon.size.width)
        #expect(try #require(display.stackedItemImage(debug: true)).isTemplate == false)
    }

    /// A Debug build runs beside the installed app, so its item must not look like the installed
    /// one: an orange icon instead of the menu bar's template, and its own name for VoiceOver.
    @Test func aDebugBuildsItemStandsApartFromTheInstalledApps() throws {
        #expect(MenuBarDisplay.isDebugBuild, "tests run on the Debug build")
        let display = MenuBarDisplay(symbol: "wifi", lines: ["1.1 GB"])
        let installed = try #require(display.image(debug: false))
        let debug = try #require(display.image(debug: true))
        #expect(installed.isTemplate)
        #expect(!debug.isTemplate)
        #expect(display.accessibilityLabel(debug: false) == "Soroband, 1.1 GB")
        #expect(display.accessibilityLabel(debug: true) == "Soroband Debug, 1.1 GB")
    }
}
