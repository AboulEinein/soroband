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

    func texts(
        _ readings: [MenuBarReading], scope: MenuBarScope = .network, status: EngineStatus? = nil
    ) -> [String] {
        MenuBarDisplay.make(
            layout: MenuBarLayout(scope: scope, readings: readings), status: status ?? self.status, kind: .wifi
        ).readings.map(\.text)
    }

    @Test func defaultShowsTodaysTotalOnTheCurrentNetworkAsCrossedItsInterfaces() {
        let display = MenuBarDisplay.make(layout: .default, status: status, kind: .wifi)
        #expect(display.symbol == "wifi")
        #expect(display.text == "1.1 GB")
        #expect(display.drawsTitle, "one reading is the item's title, as before readings could stack")
    }

    @Test func allNetworksSumsEveryNetwork() {
        // 2.87 GB rounded down to a tenth.
        #expect(texts([.total], scope: .all) == ["2.8 GB"])
        #expect(texts([.download, .upload], scope: .all) == ["↓ 2.3 GB", "↑ 500 MB"])
    }

    /// Readings keep the order they were chosen in; arrows say the direction where no caption does.
    @Test func eachReadingIsTodaysBytesOrTheLiveSpeedInOrder() {
        #expect(texts([.upload, .download]) == ["↑ 206 MB", "↓ 893 MB"])
        #expect(texts([.speedDown, .speedUp]) == ["↓ 137 KB/s", "↑ 42 KB/s"])
        #expect(texts([.total, .speedDown, .speedUp]) == ["1.1 GB", "↓ 137 KB/s", "↑ 42 KB/s"])
        let labeled = MenuBarDisplay.make(
            layout: MenuBarLayout(readings: [.download, .speedUp], style: .labeled), status: status, kind: .wifi)
        #expect(labeled.readings.map(\.caption) == ["DOWN", "↑ LIVE"])
        #expect(labeled.readings.map(\.value) == ["893 MB", "42 KB/s"], "the caption says the direction")
        #expect(texts([]).isEmpty, "icon only")
    }

    /// Stacked pairs readings in order, the first on top; a reading left without a partner is
    /// drawn alone at full size.
    @Test func stackedPairsTheReadingsInOrder() {
        let display = { (readings: [MenuBarReading], style: MenuBarStyle) in
            MenuBarDisplay.make(layout: MenuBarLayout(readings: readings, style: style), status: status, kind: .wifi)
        }
        let three = display([.total, .speedDown, .speedUp], .stacked)
        #expect(three.columns.map { $0.map(\.text) } == [["1.1 GB", "↓ 137 KB/s"], ["↑ 42 KB/s"]])
        #expect(!three.drawsTitle)
        #expect(display([.download, .upload], .labeled).columns.count == 2, "labeled: a column each")
        #expect(display([.download, .upload], .inline).drawsTitle)
        #expect(!display([.download], .labeled).drawsTitle, "a caption needs the image")
        #expect(!display([.speedDown], .inline).drawsTitle, "a speed keeps its width in the image")
    }

    /// A reading dropped on another takes its place; the others keep their order, so a stacked
    /// pair changes only where the user put something.
    @Test func aMovedReadingTakesTheDropTargetsPlace() {
        var layout = MenuBarLayout(readings: [.total, .speedDown, .speedUp])
        layout.move(.total, to: 2)
        #expect(layout.readings == [.speedDown, .speedUp, .total])
        layout.move(.total, to: 0)
        #expect(layout.readings == [.total, .speedDown, .speedUp])
        layout.move(.speedUp, to: 1)
        #expect(layout.readings == [.total, .speedUp, .speedDown])
        layout.move(.download, to: 0)
        layout.move(.total, to: 3)
        layout.move(.total, to: -1)
        #expect(layout.readings == [.total, .speedUp, .speedDown], "not shown, or out of range: unchanged")
    }

    @Test func readingsAreStoredAsTheCoreSettingsValue() {
        #expect(MenuBarLayout(readings: [.speedUp, .total]).readingsValue == "speed_up,total")
        #expect(MenuBarLayout(readings: []).readingsValue == "none")
        #expect(MenuBarLayout.readings(from: "speed_up,total") == [.speedUp, .total])
        #expect(MenuBarLayout.readings(from: "none") == [])
        #expect(MenuBarLayout.readings(from: "total,rainbow") == nil)
    }

    /// Only bytes the readings show move the throttle; any speed redraws at every poll.
    @Test func theThrottleFollowsTheBytesTheReadingsShow() {
        let total = { (readings: [MenuBarReading]) in
            MenuBarDisplay.total(layout: MenuBarLayout(readings: readings), status: status)
        }
        #expect(total([.upload]) == 206_400_000)
        #expect(total([.download, .upload]) == 1_100_000_000)
        #expect(total([.total, .speedDown]) == nil)
        #expect(total([]) == nil)
        let t = Date(timeIntervalSince1970: 1_793_098_800)
        let old = MenuBarDisplay.Drawn(
            display: display(["1.1 GB"]), layout: .default, network: 1, total: 1_100_000_000)
        let redesigned = MenuBarDisplay.Drawn(
            display: display(["↓ 893 MB", "↑ 206 MB"]), layout: MenuBarLayout(readings: [.download, .upload]),
            network: 1, total: 1_100_000_000)
        #expect(MenuBarDisplay.redrawDelay(from: old, to: redesigned, lastRedraw: t, now: t + 5) == 0, "new layout")
    }

    func display(_ texts: [String], symbol: String = "wifi") -> MenuBarDisplay {
        MenuBarDisplay(symbol: symbol, readings: texts.map { MenuBarDisplay.Reading(value: $0, text: $0) })
    }

    @Test func readingsStylesAndScopesAreTheCoreSettingsValues() {
        // `soroband config set menu_bar_readings <value>` must name readings the app knows.
        #expect(
            MenuBarReading.allCases.map(\.rawValue) == ["total", "download", "upload", "speed_down", "speed_up"])
        #expect(MenuBarStyle.allCases.map(\.rawValue) == ["stacked", "labeled", "inline"])
        #expect(MenuBarScope.allCases.map(\.rawValue) == ["network", "all"])
        #expect(MenuBarLayout.default == MenuBarLayout(scope: .network, readings: [.total], style: .stacked))
    }

    /// Each change of the text redraws the item on every display, which an idle Mac cannot
    /// afford every few seconds: idle traffic of a few KB/s must leave it alone.
    @Test func idleTrafficLeavesTheTextUnchangedUntilTheNextMegabyte() {
        let texts = [183_000_000, 183_400_000, 183_999_999, 184_000_000].map { (bytes: UInt64) in
            texts([.total], status: EngineStatus(todayNetworkInterfaces: ByteCounts(rx: bytes, tx: 0)))
        }
        #expect(texts == [["183 MB"], ["183 MB"], ["183 MB"], ["184 MB"]])
        #expect(Format.menuBarBytes(999_999) == "< 1 MB")
        #expect(Format.menuBarBytes(1_099_999_999) == "1.0 GB")
        #expect(Format.menuBarBytes(12_345_000_000) == "12.3 GB")
        // Speeds the same way: idle traffic stays "0 KB/s" instead of redrawing at every poll.
        #expect(Format.menuBarSpeed(0) == "0 KB/s")
        #expect(Format.menuBarSpeed(999) == "0 KB/s")
        #expect(Format.menuBarSpeed(137_900) == "137 KB/s")
        #expect(Format.menuBarSpeed(1_290_000) == "1.2 MB/s")
        #expect(Format.menuBarSpeed(48_700_000) == "48 MB/s")
    }

    @Test func aGrowingTotalRedrawsAtMostOnceAMinute() {
        let t = Date(timeIntervalSince1970: 1_793_098_800)
        typealias Drawn = MenuBarDisplay.Drawn
        let old = Drawn(display: display(["183 MB"]), layout: .default, network: 1, total: 183_000_000)
        let grown = Drawn(display: display(["184 MB"]), layout: .default, network: 1, total: 184_000_000)
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
        other.display = display(["950 MB"])
        other.total = 950_000_000
        #expect(delay(other, 5) == 0, "new network of the same kind")
        other = Drawn(display: display(["2 MB"]), layout: .default, network: 1, total: 2_000_000)
        #expect(delay(other, 5) == 0, "reset hour: the total went down")
        other = Drawn(
            display: display(["1.1 GB"]), layout: MenuBarLayout(scope: .all), network: 1, total: 1_100_000_000)
        #expect(delay(other, 5) == 0, "layout changed, though the total grew")
        other = Drawn(
            display: display(["↓ 2 KB/s", "↑ 1 KB/s"]), layout: MenuBarLayout(readings: [.speedDown, .speedUp]),
            network: 1, total: nil)
        #expect(delay(other, 5) == 0, "live speed")
        // The first count after launch, which had no text, shows at once.
        let launching = Drawn(display: display([]), layout: .default, network: 1, total: 0)
        #expect(MenuBarDisplay.redrawDelay(from: launching, to: grown, lastRedraw: t, now: t + 5) == 0)
        #expect(texts([.total], status: EngineStatus(state: .starting)).isEmpty)
    }

    @Test func noIdentifiedNetworkShowsThePlainNetworkIcon() {
        #expect(MenuBarDisplay.make(layout: .default, status: status, kind: nil).symbol == "network")
    }

    @Test func aStoppedEngineSaysSoInsteadOfAFrozenCount() {
        let failed = EngineStatus(state: .failed, todayNetworkInterfaces: ByteCounts(rx: 5_000_000, tx: 0))
        let display = MenuBarDisplay.make(
            layout: MenuBarLayout(readings: [.download, .upload]), status: failed, kind: .wifi)
        #expect(display.symbol == "exclamationmark.triangle")
        #expect(display.text == "Not counting")
        #expect(display.drawsTitle)
        #expect(texts([], status: failed).isEmpty, "icon only stays an icon")
    }

    @Test func bytesReadInDecimalUnits() {
        #expect(Format.bytes(0) == "0 bytes")
        #expect(Format.bytes(999) == "999 bytes")
        #expect(Format.bytes(420_300_000) == "420.3 MB")
        #expect(Format.speed(1_500_000) == "1.5 MB/s")
    }

    /// Readings the title cannot show are drawn into the item's one image, which must still
    /// follow the menu bar's color (a template) and fit its height.
    @MainActor @Test func drawnReadingsAreOneTemplateImageTheMenuBarsHeight() throws {
        let icon = try #require(display([]).image(debug: false))
        var widths: [MenuBarStyle: CGFloat] = [:]
        for style in MenuBarStyle.allCases {
            var drawn = display(["↓ 893 MB", "↑ 206 MB"])
            drawn.style = style
            let image = try #require(drawn.itemImage(debug: false))
            #expect(image.isTemplate)
            #expect(image.size.height == 22)
            #expect(image.size.width > icon.size.width)
            widths[style] = image.size.width
        }
        #expect(widths[.stacked]! < widths[.inline]!, "a stacked pair is narrower than one line")
        #expect(try #require(display(["1.1 GB"]).itemImage(debug: true)).isTemplate == false)
        // A speed keeps the width of its widest value, so the item does not resize at each poll.
        let speed = { (value: String) in
            MenuBarDisplay(
                symbol: "wifi",
                readings: [
                    MenuBarDisplay.Reading(value: "893 MB", text: "↓ 893 MB"),
                    MenuBarDisplay.Reading(
                        value: value, text: "↓ \(value)", widestValue: MenuBarDisplay.widestSpeed),
                ])
        }
        for style in MenuBarStyle.allCases {
            var idle = speed("0 KB/s")
            var busy = speed("137 KB/s")
            idle.style = style
            busy.style = style
            #expect(idle.readingsImage().size == busy.readingsImage().size, "\(style)")
        }
        // The menu bar gets a bitmap of it, still a template, the same size, at the display's scale.
        let drawn = try #require(display(["↓ 893 MB", "↑ 206 MB"]).itemImage(debug: false))
        let bitmap = MenuBarDisplay.rasterized(drawn, scale: 2)
        #expect(bitmap.isTemplate)
        #expect(bitmap.size == drawn.size)
        #expect(bitmap.representations.first?.pixelsHigh == 44)
    }

    /// A Debug build runs beside the installed app, so its item must not look like the installed
    /// one: an orange icon instead of the menu bar's template, and its own name for VoiceOver.
    @Test func aDebugBuildsItemStandsApartFromTheInstalledApps() throws {
        #expect(MenuBarDisplay.isDebugBuild, "tests run on the Debug build")
        let display = self.display(["1.1 GB"])
        let installed = try #require(display.image(debug: false))
        let debug = try #require(display.image(debug: true))
        #expect(installed.isTemplate)
        #expect(!debug.isTemplate)
        #expect(display.accessibilityLabel(debug: false) == "Soroband, 1.1 GB")
        #expect(display.accessibilityLabel(debug: true) == "Soroband Debug, 1.1 GB")
    }
}
