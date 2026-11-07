import AppKit
import Foundation
import Testing

@testable import Soroband

/// The moment queue: one moment at a time, alerts first, a moment closing on time unless the
/// pointer is on it, and a transfer as one moment per app.
struct MomentQueueTests {
    let office = Network(id: 1, key: "wifi:Office", name: "Office", kind: .wifi)
    let music = MomentApp(id: "/System/Applications/Music.app", name: "Music")
    let xcode = MomentApp(id: "/Applications/Xcode.app", name: "Xcode")

    var joined: MomentContent { .joined(network: office, week: 0, today: 0, lastSeen: nil) }
    var hog: MomentContent { .hog(app: music, bytes: 0, minutes: 5, network: nil) }
    func transfer(_ bytes: UInt64, done: Bool = false) -> MomentContent {
        .transfer(app: xcode, via: nil, bytes: bytes, rate: 0, done: done)
    }

    @Test func aMomentClosesAfterItsDurationAndTheNextOpensAfterTheGap() {
        var queue = MomentQueue()
        queue.post(joined, now: 0)
        queue.post(.left(network: office, since: .now, bytes: 0, top: nil), now: 1)
        #expect(queue.current?.kind == .joined)
        // Joined lasts 5 s: still open at 4.9 s, closed at 5 s, and Left opens 0.45 s later.
        queue.advance(now: 4.9)
        #expect(queue.current?.kind == .joined)
        queue.advance(now: 5)
        #expect(queue.current == nil)
        queue.advance(now: 5.4)
        #expect(queue.current == nil, "the island closes between moments")
        queue.advance(now: 5.45)
        #expect(queue.current?.kind == .left)
    }

    @Test func alertsJumpAheadOfWaitingMomentsButNeverCloseTheOpenOne() {
        var queue = MomentQueue()
        queue.post(joined, now: 0)
        queue.post(.recap(bytes: 0, networks: 0, top: nil), now: 0)
        queue.post(transfer(60_000_000), now: 0)
        queue.post(hog, now: 0)
        #expect(queue.current?.kind == .joined)
        #expect(queue.waiting.map(\.kind) == [.hog, .transfer, .recap])
    }

    @Test func thePointerKeepsAMomentOpenUntilItLeaves() {
        var queue = MomentQueue()
        queue.post(hog, now: 0)
        queue.hover(true, now: 1)
        queue.advance(now: 60)
        #expect(queue.current?.kind == .hog, "open as long as the pointer is on it")
        queue.hover(false, now: 60)
        // The hog's 8 s start again when the pointer leaves.
        queue.advance(now: 67.9)
        #expect(queue.current?.kind == .hog)
        queue.advance(now: 68)
        #expect(queue.current == nil)
    }

    @Test func clickingTheIslandClosesItAndDropsTheMomentsWaitingBehindIt() {
        // Back-to-back moments keep the island open for half a minute with only 0.45 s gaps; one
        // click puts it away for all of them.
        var queue = MomentQueue()
        queue.post(hog, now: 0)
        queue.post(joined, now: 0)
        queue.post(transfer(60_000_000), now: 0)
        queue.hover(true, now: 1)
        queue.dismissAll(now: 2)
        #expect(queue.current == nil && queue.waiting.isEmpty)
        #expect(queue.nextChange == nil, "nothing opens after the gap")
        // The transfer's progress opens nothing new; a new alert still shows.
        queue.post(transfer(80_000_000), now: 3)
        #expect(queue.current == nil)
        queue.post(hog, now: 4)
        #expect(queue.current?.kind == .hog)
    }

    @Test func aTransferIsOneMomentWhoseProgressUpdatesItAndWhoseEndOpensItAgain() {
        var queue = MomentQueue()
        let started = queue.post(transfer(50_000_000), now: 0)
        #expect(started)
        let progress = queue.post(transfer(60_000_000), now: 1)
        #expect(!progress, "progress updates the open moment")
        #expect(queue.current?.content == transfer(60_000_000))
        queue.advance(now: 6)
        #expect(queue.current == nil)
        let later = queue.post(transfer(70_000_000), now: 7)
        #expect(!later, "no new moment for progress once shown")
        queue.advance(now: 8)
        #expect(queue.current == nil)
        let end = queue.post(transfer(80_000_000, done: true), now: 9)
        #expect(end)
        #expect(queue.current?.content == transfer(80_000_000, done: true))
    }

    @Test func aShownTransferWhoseEndNeverCameStartsAfreshAfterSilence() {
        var queue = MomentQueue()
        queue.post(transfer(50_000_000), now: 0)
        queue.advance(now: 6)
        // Progress every 5 s keeps it one transfer; then 30 s of silence (its app was ignored).
        let progress = queue.post(transfer(60_000_000), now: 10)
        #expect(!progress)
        let next = queue.post(transfer(70_000_000), now: 40)
        #expect(next, "silent for 30 s, so this is a new transfer")
    }

    @Test func aTransferHeldOpenByThePointerStaysOneMoment() {
        var queue = MomentQueue()
        queue.post(transfer(50_000_000), now: 0)
        queue.hover(true, now: 1)
        // Progress every 5 s while the pointer holds it open for a minute.
        for t in stride(from: 5.0, through: 60, by: 5) {
            queue.post(transfer(50_000_000 + UInt64(t) * 1_000_000), now: t)
        }
        queue.hover(false, now: 61)
        queue.advance(now: 67)
        #expect(queue.current == nil)
        let progress = queue.post(transfer(120_000_000), now: 68)
        #expect(!progress, "still the same running transfer")
    }

    @Test func aTransfersEndShowsAsANewOpenOrWaitingMoment() {
        let end = transfer(80_000_000, done: true)
        // New: the transfer showed and closed; its end opens again.
        var closed = MomentQueue()
        closed.post(transfer(50_000_000), now: 0)
        closed.advance(now: 6)
        let new = closed.post(end, now: 7)
        #expect(new && closed.holds(end))
        // Open: the end lands on the transfer showing.
        var open = MomentQueue()
        open.post(transfer(50_000_000), now: 0)
        let onOpen = open.post(end, now: 1)
        #expect(!onOpen && open.holds(end))
        // Waiting: the end lands on the transfer waiting behind a hog.
        var waiting = MomentQueue()
        waiting.post(hog, now: 0)
        waiting.post(transfer(50_000_000), now: 0)
        let onWaiting = waiting.post(end, now: 1)
        #expect(!onWaiting && waiting.holds(end))
        // Never seen: nothing holds it.
        var unseen = MomentQueue()
        let dropped = unseen.post(end, now: 0)
        #expect(!dropped && !unseen.holds(end))
    }

    @Test func aTransferNobodySawStartShowsNoEnd() {
        var queue = MomentQueue()
        let end = queue.post(transfer(80_000_000, done: true), now: 0)
        #expect(!end)
        #expect(queue.current == nil)
    }

    @Test func aTransferTurnedOffBeforeItsEndStartsAfreshNextTime() {
        var queue = MomentQueue()
        queue.post(transfer(50_000_000), now: 0)
        queue.remove(.transfer, now: 1)
        queue.advance(now: 2)
        let next = queue.post(transfer(60_000_000), now: 3)
        #expect(next, "its end never came, so the next transfer is a new moment")
    }

    @Test func ignoringAnAppDropsItsWaitingMoments() {
        // A hog and a transfer of Xcode in one poll: the hog opens, the transfer waits.
        var queue = MomentQueue()
        queue.post(.hog(app: xcode, bytes: 0, minutes: 5, network: nil), now: 0)
        queue.post(transfer(100_000_000), now: 0)
        queue.post(joined, now: 0)
        queue.remove(app: xcode.id)
        queue.dismiss(now: 1)
        queue.advance(now: 1.45)
        #expect(queue.current?.kind == .joined, "the ignored app's transfer does not open")
        #expect(queue.waiting.isEmpty)
    }

    @Test func turningAMomentOffDropsItOpenOrWaiting() {
        var queue = MomentQueue()
        queue.post(hog, now: 0)
        queue.post(joined, now: 0)
        queue.remove(.hog, now: 1)
        #expect(queue.current == nil)
        queue.advance(now: 1.45)
        #expect(queue.current?.kind == .joined)
        queue.remove(.joined, now: 2)
        #expect(queue.current == nil && queue.waiting.isEmpty)
    }

    @Test func theQueueKeepsAtMostEightWaitingDroppingTheLeastImportant() {
        var queue = MomentQueue()
        queue.post(joined, now: 0)
        for _ in 0..<8 { queue.post(.recap(bytes: 0, networks: 0, top: nil), now: 0) }
        queue.post(hog, now: 0)
        #expect(queue.waiting.count == 8)
        #expect(queue.waiting.first?.kind == .hog)
    }

    @Test func nextChangeIsTheOpenMomentsCloseOrTheNextOpening() {
        var queue = MomentQueue()
        #expect(queue.nextChange == nil, "nothing to do")
        queue.post(joined, now: 10)
        #expect(queue.nextChange == 15)
        queue.post(hog, now: 11)
        queue.advance(now: 15)
        #expect(queue.nextChange == 15.45)
    }
}

/// The island's outline: what the pointer is on, and the two styles.
@MainActor
struct IslandOutlineTests {
    /// A MacBook's notch: 185 pt wide, a 32 pt menu bar; the panel is 560 × 232 pt.
    let geometry = IslandGeometry(notchWidth: 185, menuBarHeight: 32)
    let panel = CGRect(x: 0, y: 0, width: 560, height: 232)

    /// A point `x` from the panel's centre and `y` below the top of the screen.
    func point(_ x: CGFloat, below y: CGFloat) -> CGPoint { CGPoint(x: panel.midX + x, y: panel.maxY - y) }

    func contains(_ metrics: IslandMetrics, _ p: CGPoint) -> Bool {
        islandPath(metrics, band: geometry.menuBarHeight, in: panel).contains(p)
    }

    @Test func peekIgnoresPointerBesideTheNotch() {
        let rest = IslandMetrics.rest(geometry)
        #expect(contains(rest, point(0, below: 16)), "the notch's middle")
        #expect(contains(rest, point(85, below: 16)), "inside its right edge (92.5 pt)")
        #expect(!contains(rest, point(100, below: 16)), "beside it, in the menu bar")
        #expect(!contains(rest, point(0, below: 40)), "below it")
    }

    @Test func seamlessCoversTheMenuBarBesideTheNotchWhileKeepMenuBarClearDoesNot() {
        // A joined moment is 450 pt wide; 150 pt from the centre is beside the notch.
        let beside = point(150, below: 16)
        #expect(contains(.open(.joined, geometry, style: .seamless), beside))
        #expect(!contains(.open(.joined, geometry, style: .clear), beside))
        // Below the menu bar both reach as wide.
        #expect(contains(.open(.joined, geometry, style: .clear), point(150, below: 60)))
    }

    @Test func keepMenuBarClearStaysBelowTheMenuBarOnADisplayWithoutANotch() {
        let flat = IslandGeometry(notchWidth: 0, menuBarHeight: 24)
        let path = { (m: IslandMetrics) in islandPath(m, band: 24, in: panel) }
        let joined = IslandMetrics.open(.joined, flat, style: .clear)
        #expect(!path(joined).contains(point(0, below: 12)), "nothing over the menu bar")
        #expect(path(joined).contains(point(0, below: 40)), "the moment below it")
        #expect(!path(IslandMetrics.glance(flat, style: .clear)).contains(point(0, below: 12)))
        #expect(path(.open(.joined, flat, style: .seamless)).contains(point(0, below: 12)), "seamless covers it")
    }

    @Test func keepMenuBarClearNeverCrossesTheMenuBarWhileItGrowsOrShrinks() {
        // Every frame between rest and a joined moment, as the springs pass through them.
        let flat = IslandGeometry(notchWidth: 0, menuBarHeight: 24)
        let rest = IslandMetrics.rest(flat, style: .clear)
        let open = IslandMetrics.open(.joined, flat, style: .clear)
        #expect(rest.top == open.top, "the top does not jump")
        for step in 0...20 {
            let f = CGFloat(step) / 20
            let frame = IslandMetrics(
                width: rest.width + (open.width - rest.width) * f,
                height: rest.height + (open.height - rest.height) * f,
                radius: 26, bandWidth: rest.bandWidth + (open.bandWidth - rest.bandWidth) * f, top: open.top)
            let path = islandPath(frame, band: 24, in: panel)
            #expect(!path.contains(point(0, below: 6)) && !path.contains(point(0, below: 20)), "frame \(step)")
        }
    }

    @Test func aDisplayWithoutANotchShowsNothingAtRest() {
        let flat = IslandGeometry(notchWidth: 0, menuBarHeight: 24)
        #expect(islandPath(.rest(flat), band: 24, in: panel).isEmpty)
    }

    @Test func theSpringSettlesOnItsTarget() {
        var spring = Spring(value: 185)
        spring.target = 450
        for _ in 0..<120 { spring.advance(1.0 / 60) }
        #expect(spring.value == 450 && !spring.isMoving, "settled within 2 s")
        var overshoot = Spring(value: 185)
        overshoot.target = 450
        var peak: CGFloat = 0
        for _ in 0..<60 {
            overshoot.advance(1.0 / 60)
            peak = max(peak, overshoot.value)
        }
        // Damping 0.8 overshoots by about 1.5%, as SwiftUI's spring does: a bounce, not a wobble.
        #expect(peak > 450 && peak < 460)
    }
}

/// The engine names an app by its outermost bundle; the frontmost app's bundle may be nested.
struct AppIDTests {
    @Test func aNestedAppIsTheAppThatHoldsIt() {
        #expect(
            IslandController.appID(bundle: "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app")
                == "/Applications/Xcode.app")
        #expect(IslandController.appID(bundle: "/Applications/Safari.app") == "/Applications/Safari.app")
        #expect(IslandController.appID(bundle: "/usr/local/bin/tool") == "/usr/local/bin/tool")
    }
}

/// Full screen: an app in front with a window exactly over a display the island is on.
struct IslandFullScreenTests {
    /// The main display 1512 × 982 pt; a second one above it, 1920 × 1080 pt, whose bottom
    /// edge is the main display's top.
    let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let above = CGRect(x: -200, y: 982, width: 1920, height: 1080)

    func window(pid: pid_t, layer: Int = 0, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat)
        -> [String: Any]
    {
        [
            kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer,
            kCGWindowBounds as String: CGRect(x: x, y: y, width: width, height: height).dictionaryRepresentation,
        ]
    }

    func covers(_ windows: [[String: Any]], displays: [CGRect]) -> Bool {
        IslandController.coversADisplay(windows: windows, owner: 42, displays: displays, mainDisplayHeight: 982)
    }

    @Test func aWindowOverTheWholeDisplayIsFullScreen() {
        #expect(covers([window(pid: 42, 0, 0, 1512, 982)], displays: [main]))
        // The display above starts 1080 pt above the main display's top (y = -1080 from it).
        #expect(covers([window(pid: 42, -200, -1080, 1920, 1080)], displays: [main, above]))
    }

    @Test func aZoomedWindowAnotherAppsWindowOrAPanelIsNot() {
        #expect(!covers([window(pid: 42, 0, 33, 1512, 949)], displays: [main]), "zoomed, below the menu bar")
        #expect(!covers([window(pid: 7, 0, 0, 1512, 982)], displays: [main]), "another app in front")
        #expect(!covers([window(pid: 42, layer: 25, 0, 0, 1512, 982)], displays: [main]), "not a document window")
        #expect(!covers([window(pid: 42, -200, -1080, 1920, 1080)], displays: [main]), "a display without the island")
    }
}

/// The island's settings as the core stores them, and the moments as the core reports them.
struct IslandSettingsTests {
    @Test func settingsReadEveryKeyAndKeepDefaultsForMissingOnes() {
        let values = [
            "island": "on", "island_style": "clear", "island_moments": "hog,transfer", "island_hog_mb": "20",
            "island_full_screen": "hide", "island_ignored_apps": "/Applications/Music.app,macOS & Services",
        ]
        let settings = IslandSettings(value: { values[$0] })
        #expect(settings.enabled && settings.style == .clear)
        #expect(settings.moments == [.hog, .transfer])
        #expect(settings.hogMB == 20 && settings.hogMinutes == 5, "a missing key keeps its default")
        #expect(settings.fullScreen == .hide)
        #expect(settings.ignoredApps == ["/Applications/Music.app", "macOS & Services"])
        #expect(settings.momentsValue == "hog,transfer")
    }

    @Test func everySettingWritesTheValueItReads() {
        // Settings sends `value(for:)`'s text to the core; reading it back must give the same
        // settings, or a change in the pane would turn into another one.
        var settings = IslandSettings()
        settings.enabled = true
        settings.style = .clear
        settings.moments = [.peek, .recap]
        settings.hogMB = 250
        settings.offersPause = false
        settings.fullScreen = .all
        settings.displays = .all
        settings.ignoredApps = ["/usr/bin/curl"]
        let keys = [
            "island", "island_style", "island_moments", "island_hog_mb", "island_hog_minutes", "island_background_mb",
            "island_transfer_mb", "island_pause", "island_full_screen", "island_displays", "island_notifications",
            "island_ignored_apps",
        ]
        #expect(keys.allSatisfy { settings.value(for: $0) != nil })
        #expect(IslandSettings(value: settings.value(for:)) == settings)
        #expect(settings.setting("island_moments", to: "none").moments.isEmpty)
        #expect(IslandSettingsView.moments([.hog], .peek, true) == "peek,hog", "in the schema's order")
    }

    @Test func anAppWhoseIdHoldsACommaIsNotOfferedIgnore() {
        // Its id would be stored as two names, neither of them the app.
        #expect(!IslandSettings.canIgnore("/Applications/Foo, Bar.app"))
        #expect(IslandSettings.canIgnore("/Applications/Safari.app"))
    }

    @Test func ignoringTheHundredAndFirstAppDropsTheOldest() {
        var settings = IslandSettings()
        settings.ignoredApps = (1...100).map { "/tools/t\($0)" }
        let ignored = settings.ignoring("/Applications/Music.app")
        #expect(ignored.count == 100)
        #expect(ignored.first == "/tools/t2" && ignored.last == "/Applications/Music.app")
        #expect(settings.ignoring("/tools/t5") == settings.ignoredApps, "already ignored")
    }

    @Test func alertsBecomeNotificationsWhenTheIslandCannotShowThem() {
        var settings = IslandSettings()
        #expect(!settings.enabled, "off on a fresh install")
        #expect(settings.route(.hog, hasPanel: false) == .notification)
        #expect(settings.route(.joined, hasPanel: false) == .nowhere)
        #expect(settings.watches, "the engine watches for the notifications")
        settings.notifications = false
        #expect(!settings.watches, "nothing to watch for")
        settings.notifications = true
        settings.enabled = true
        #expect(settings.route(.hog, hasPanel: true) == .island)
        // On, but no display to show on (the built-in one only, with the lid closed).
        #expect(settings.route(.hog, hasPanel: false) == .notification)
        #expect(settings.route(.joined, hasPanel: false) == .nowhere)
        #expect(!settings.shows(.recap), "the recap is off by default")
    }

    @Test func momentsFromTheCoreAreNamedWithTheRegistry() throws {
        // As `moments::Event::to_json` writes them.
        let json = """
            [{"kind":"hog","app":{"id":"/System/Applications/Music.app","name":"Music"},"bytes":120000000,"minutes":5},
             {"kind":"left","network":2,"since":1793059200,"bytes":35000000,"top":{"id":"/Applications/Safari.app","name":"Safari","bytes":14000000}},
             {"kind":"joined","network":9,"week":1,"today":1,"last_seen":null},
             {"kind":"transfer","app":{"id":"/Applications/Xcode.app","name":"Xcode"},"via":"App Store","bytes":60000000,"rate":2000000,"done":false}]
            """
        let moments = try JSONDecoder().decode([CoreMoment].self, from: Data(json.utf8))
        let home = Network(id: 2, key: "wifi:Home", name: "Home", kind: .wifi)
        let named = { (id: Int64) in id == 2 ? home : nil }
        let contents = moments.map { $0.content(network: named, current: nil) }
        #expect(
            contents[0]
                == .hog(
                    app: MomentApp(id: "/System/Applications/Music.app", name: "Music"), bytes: 120_000_000, minutes: 5,
                    network: nil))
        #expect(
            contents[1]
                == .left(
                    network: home, since: Date(timeIntervalSince1970: 1_793_059_200), bytes: 35_000_000,
                    top: MomentApp(id: "/Applications/Safari.app", name: "Safari", bytes: 14_000_000)))
        #expect(contents[2] == nil, "a network the registry does not know shows nothing")
        #expect(
            contents[3]
                == .transfer(
                    app: MomentApp(id: "/Applications/Xcode.app", name: "Xcode"), via: "App Store", bytes: 60_000_000,
                    rate: 2_000_000, done: false))
    }
}
