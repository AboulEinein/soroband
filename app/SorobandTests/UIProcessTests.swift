import Foundation
import Testing

@testable import Soroband

/// The menu bar process's side of the UI process, with a script standing in for Soroband: it says
/// it is ready, then writes every request it reads to a log.
@MainActor
struct UIProcessTests {
    private let anchor = CGRect(x: 1090, y: 1329, width: 87, height: 22)

    private func popover(_ seconds: TimeInterval = 0) -> PopoverRequest {
        PopoverRequest(anchor: anchor, requested: Date(timeIntervalSince1970: 1_793_000_000 + seconds))
    }

    private static let snapshot = UISnapshot(
        status: EngineStatus(networkID: 1), todayJSON: "", registry: [],
        menuBarLayout: .default, resetHour: 0, current: nil, connectedSince: nil)

    /// A stand-in that prints `events` once started, then logs what it reads.
    private final class StandIn {
        let script: URL
        let log: URL
        let argumentsFile: URL

        init(events: [UIEvent] = [.ready]) throws {
            let directory = FileManager.default.temporaryDirectory.appending(path: "ui-stand-in-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            script = directory.appending(path: "Soroband")
            log = directory.appending(path: "requests.log")
            argumentsFile = directory.appending(path: "arguments")
            let lines = try events.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
            try """
            #!/bin/sh
            echo "$*" > '\(argumentsFile.path)'
            \(lines.map { "echo '\($0)'" }.joined(separator: "\n"))
            exec cat > '\(log.path)'
            """.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }

        /// The arguments it was started with.
        var arguments: [String] {
            ((try? String(contentsOf: argumentsFile, encoding: .utf8)) ?? "").split(separator: " ").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        /// The requests read so far.
        var requests: [UIRequest] {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").compactMap {
                try? JSONDecoder().decode(UIRequest.self, from: Data($0.utf8))
            }
        }

        deinit { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func thePointerOnTheItemStartsOneStandbyProcessWithNoWindow() async throws {
        let standIn = try StandIn()
        let ui = UIProcess(executableURL: standIn.script, snapshot: { Self.snapshot }, handle: { _ in })
        defer { ui.stop() }

        ui.pointer(inside: true)
        #expect(ui.phase == .launching, "the hover starts it before any click")
        let pid = try #require(ui.processIdentifier)
        ui.pointer(inside: false)
        ui.pointer(inside: true)
        #expect(ui.processIdentifier == pid, "a second hover does not start a second process")
        try await until { ui.phase == .ready }
        try await until { standIn.requests.contains(.pointer(inside: true)) }

        let requests = standIn.requests
        #expect(requests.first == .pointer(inside: true), "it knows the pointer is over the item, so it stays")
        #expect(requests.contains(.snapshot(Self.snapshot)), "it has the numbers before the first click")
        #expect(!requests.contains { $0.showsWindow }, "standby shows nothing")
        #expect(standIn.arguments == ["--ui", "--standby"], "standby draws the popover once offscreen")
    }

    @Test func clicksWhileItLaunchesOpenThePopoverOnceItIsReady() async throws {
        let standIn = try StandIn()
        let ui = UIProcess(executableURL: standIn.script, snapshot: { Self.snapshot }, handle: { _ in })
        defer { ui.stop() }

        ui.send(.toggle(popover()))
        ui.send(.toggle(popover(0.4)))
        ui.send(.showSettings(tab: "networks"))
        try await until { standIn.requests.contains(.showSettings(tab: "networks")) }

        let shown = standIn.requests.filter { $0.showsWindow }
        #expect(
            shown == [.showPopover(popover()), .showSettings(tab: "networks")],
            "nothing showed before the second click, so it meant open too, not close")
        ui.send(.toggle(popover(5)))
        try await until { standIn.requests.contains(.toggle(popover(5))) }
        #expect(standIn.requests.last == .toggle(popover(5)), "once ready, a click toggles")
        #expect(standIn.arguments == ["--ui"], "a click must not wait for an offscreen popover first")
    }

    @Test func closingWithNoUIProcessStartsNone() {
        let ui = UIProcess(
            executableURL: URL(filePath: "/nonexistent/Soroband"), snapshot: { Self.snapshot }, handle: { _ in })
        for request: UIRequest in [.closePopover, .closeSettings, .closeHistory, .anchor(anchor), .dumpState] {
            ui.send(request)
            #expect(ui.phase == .stopped, "\(request) needs no UI process")
        }
    }

    @Test func aUIProcessThatDiedIsStartedAgainByTheNextClick() async throws {
        let standIn = try StandIn()
        var exits = 0
        let ui = UIProcess(executableURL: standIn.script, snapshot: { Self.snapshot }, handle: { _ in })
        ui.onExit = { exits += 1 }
        defer { ui.stop() }

        ui.send(.toggle(popover()))
        try await until { ui.phase == .ready }
        let first = try #require(ui.processIdentifier)
        kill(first, SIGKILL)
        try await until { ui.phase == .stopped }
        #expect(ui.phase == .stopped)
        #expect(exits == 1, "the menu bar process turns the popover's live polls off")

        ui.send(.toggle(popover(1)))
        try await until { ui.phase == .ready }
        let second = try #require(ui.processIdentifier)
        #expect(second != first)
    }

    @Test func changesMadeInTheUIProcessReachTheMenuBarProcess() async throws {
        let changes: [UIEvent] = [
            .live(true), .setResetHour(4), .updateNetwork(id: 2, name: "Desk", kind: .ethernet),
            .setNetworkColor(id: 2, color: nil),
        ]
        let standIn = try StandIn(events: [.ready] + changes)
        var handled: [UIEvent] = []
        let ui = UIProcess(executableURL: standIn.script, snapshot: { Self.snapshot }, handle: { handled.append($0) })
        defer { ui.stop() }

        ui.pointer(inside: true)
        try await until { handled.count == changes.count }
        #expect(handled == changes)
    }

    @Test func aSnapshotIsSentOnlyWhenItChanged() async throws {
        let standIn = try StandIn()
        var snapshot = Self.snapshot
        let ui = UIProcess(executableURL: standIn.script, snapshot: { snapshot }, handle: { _ in })
        defer { ui.stop() }
        ui.pointer(inside: true)
        try await until { ui.phase == .ready }

        ui.publish()
        ui.publish()
        snapshot.resetHour = 4
        ui.publish()
        try await until { standIn.requests.contains(.snapshot(snapshot)) }
        let snapshots = standIn.requests.filter { if case .snapshot = $0 { true } else { false } }
        #expect(snapshots == [.snapshot(Self.snapshot), .snapshot(snapshot)])
    }
}

/// Decisions of the UI process that need no window.
@MainActor
struct UIHostTests {
    @Test func aClickOnTheItemTogglesThePopover() {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        #expect(PopoverToggle.decide(isShown: true, lastClose: .distantPast, now: now) == .close)
        #expect(PopoverToggle.decide(isShown: false, lastClose: .distantPast, now: now) == .open)
        #expect(
            PopoverToggle.decide(isShown: false, lastClose: now.addingTimeInterval(-0.1), now: now) == .ignore,
            "the popover closed on this click's mouse-down; the click meant close")
        #expect(PopoverToggle.decide(isShown: false, lastClose: now.addingTimeInterval(-1), now: now) == .open)
    }

    @Test func itQuitsOnlyAfterTheLingerWithNoWindowAndThePointerAway() async throws {
        var quits = 0
        let linger = Linger(delay: .milliseconds(100)) { quits += 1 }
        linger.windowsOpen = true
        try await Task.sleep(for: .milliseconds(200))
        #expect(quits == 0, "a window is open")

        linger.windowsOpen = false
        #expect(linger.isCounting)
        try await Task.sleep(for: .milliseconds(50))
        linger.pointerInside = true
        try await Task.sleep(for: .milliseconds(200))
        #expect(quits == 0, "the pointer came back over the item before the linger ran out")

        linger.pointerInside = false
        try await Task.sleep(for: .milliseconds(50))
        #expect(quits == 0, "leaving starts the full linger again")
        try await Task.sleep(for: .milliseconds(200))
        #expect(quits == 1)
    }

    @Test func aStandbyProcessThatNeverOpensAWindowQuitsToo() async throws {
        var quits = 0
        _ = Linger(delay: .milliseconds(50)) { quits += 1 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(quits == 1)
    }

    @Test func theUIProcessShowsWhatTheMenuBarProcessHolds() throws {
        let snapshot = UISnapshot(
            status: EngineStatus(
                networkID: 2, todayStart: Date(timeIntervalSince1970: 1_793_000_000), resetHour: 4,
                todayNetworkInterfaces: ByteCounts(rx: 12, tx: 3), speed: ByteCounts(rx: 1, tx: 2), check: .degraded),
            // As `soroband_today_json` writes it.
            todayJSON: #"""
                {"networks":[{"network":2,"apps":{"rx":10,"tx":2},"interfaces":{"rx":12,"tx":3}}],\#
                "apps":[{"network":2,"id":"/Applications/Safari.app","name":"Safari","rx":10,"tx":2}]}
                """#,
            registry: [
                RegisteredNetwork(id: 2, key: "wifi:Home", name: "Home", kind: .wifi, lastUsed: 1_793_000_000, color: 3)
            ],
            menuBarLayout: MenuBarLayout(scope: .all, readings: [.download, .speedUp], style: .labeled), resetHour: 4,
            current: Network(id: 2, key: "wifi:Home", name: "Home", kind: .wifi),
            connectedSince: Date(timeIntervalSince1970: 1_792_990_000))
        let line = try JSONEncoder().encode(UIRequest.snapshot(snapshot))
        #expect(try JSONDecoder().decode(UIRequest.self, from: line) == .snapshot(snapshot), "every field crosses")

        let usage = Usage()
        usage.mirror(snapshot)
        #expect(usage.status == snapshot.status)
        #expect(
            usage.today
                == Today(
                    networks: [
                        .init(network: 2, apps: ByteCounts(rx: 10, tx: 2), interfaces: ByteCounts(rx: 12, tx: 3))
                    ],
                    apps: [.init(network: 2, id: "/Applications/Safari.app", name: "Safari", rx: 10, tx: 2)]),
            "the UI process reads the lists the menu bar process passed on unread")
        #expect(usage.registry == snapshot.registry)
        #expect(usage.menuBarLayout == snapshot.menuBarLayout)
        #expect(usage.resetHour == 4)
    }
}
