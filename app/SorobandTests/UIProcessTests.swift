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

    /// A stand-in that prints `events` once started, then logs what it reads. With `stateAnswer`,
    /// it answers each `dumpState` with it after `answerDelay` seconds. With `firstStopsReading`,
    /// the first one started says it is ready, then closes its standard input and stays alive, as a
    /// UI process that hung or is dying.
    private final class StandIn {
        let script: URL
        let log: URL

        init(
            events: [UIEvent] = [.ready], stateAnswer: String? = nil, answerDelay: Double = 0,
            firstStopsReading: Bool = false
        ) throws {
            let directory = FileManager.default.temporaryDirectory.appending(path: "ui-stand-in-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            script = directory.appending(path: "Soroband")
            log = directory.appending(path: "requests.log")
            let lines = try events.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
            let started = directory.appending(path: "started")
            let stopsReading = """
                if [ ! -e '\(started.path)' ]; then
                  touch '\(started.path)'
                  echo '\(lines[0])'
                  exec 0<&-
                  exec sleep 10
                fi
                """
            try """
            #!/bin/sh
            \(firstStopsReading ? stopsReading : "")
            \(lines.map { "echo '\($0)'" }.joined(separator: "\n"))
            \(reader(stateAnswer: stateAnswer, delay: answerDelay))
            """.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }

        private func reader(stateAnswer: String?, delay: Double) throws -> String {
            guard let stateAnswer else { return "exec cat > '\(log.path)'" }
            let answer = String(decoding: try JSONEncoder().encode(UIEvent.debugState(stateAnswer)), as: UTF8.self)
            return """
                while IFS= read -r line; do
                  printf '%s\\n' "$line" >> '\(log.path)'
                  case "$line" in *dumpState*) (sleep \(delay); echo '\(answer)') & ;; esac
                done
                """
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

    @Test func aDebugStateAnswerReachesTheLatestRequestPastAnEarlierOnesTimeout() async throws {
        // Each answer comes 0.45 s after its request, past the 0.4 s wait; the second request,
        // made 0.2 s after the first, still waits when the first one's wait runs out.
        let standIn = try StandIn(stateAnswer: #"{"pid":1}"#, answerDelay: 0.45)
        let ui = UIProcess(
            executableURL: standIn.script, snapshot: { Self.snapshot }, handle: { _ in },
            debugStateWait: .milliseconds(400))
        defer { ui.stop() }
        ui.send(.showSettings(tab: nil))
        try await until { ui.phase == .ready }

        var first: String?? = .none
        var second: String?? = .none
        ui.debugState { first = .some($0) }
        try await Task.sleep(for: .milliseconds(200))
        ui.debugState { second = .some($0) }
        try await until { second != nil }
        #expect(first == .some(nil), "a newer request takes over from the first")
        #expect(second == .some(#"{"pid":1}"#), "the first request's timeout must not end the second's wait")
    }

    @Test func aWindowAskedOfAUIProcessThatStoppedReadingOpensInANewOne() async throws {
        let standIn = try StandIn(firstStopsReading: true)
        let ui = UIProcess(executableURL: standIn.script, snapshot: { Self.snapshot }, handle: { _ in })
        var exits = 0
        ui.onExit = { exits += 1 }
        defer { ui.stop() }

        ui.send(.showSettings(tab: "general"))
        let stalled = try #require(ui.processIdentifier)
        try await until { standIn.requests.contains(.showSettings(tab: "general")) }

        #expect(
            standIn.requests.contains(.showSettings(tab: "general")),
            "the request reached a UI process that reads, not a pipe nobody reads")
        #expect(ui.processIdentifier != stalled)
        #expect(exits >= 1, "the menu bar process turned the live polls off for the one it dropped")
    }

    @Test func theMenuBarProcessQuitsTheUIProcessWhenTheLingerRunsOut() async throws {
        // The stand-in shows Settings and closes it at once.
        let standIn = try StandIn(events: [.ready, .windows(open: true), .windows(open: false)])
        let ui = UIProcess(
            executableURL: standIn.script, snapshot: { Self.snapshot }, handle: { _ in },
            lingerDelay: .milliseconds(200))
        defer { ui.stop() }
        ui.send(.showSettings(tab: nil))
        let first = try #require(ui.processIdentifier)
        try await until { standIn.requests.contains(.quit) }
        #expect(standIn.requests.last == .quit)
        #expect(ui.phase == .stopped, "gone from the moment it was asked to quit")

        ui.send(.toggle(popover()))
        try await until { ui.phase == .ready }
        #expect(ui.processIdentifier != first, "a click after the linger starts a new UI process")
    }

    @Test func aClickJustBeforeTheLingerRunsOutKeepsTheUIProcess() async throws {
        let standIn = try StandIn(events: [.ready, .windows(open: true), .windows(open: false)])
        let ui = UIProcess(
            executableURL: standIn.script, snapshot: { Self.snapshot }, handle: { _ in },
            lingerDelay: .milliseconds(300))
        defer { ui.stop() }
        ui.send(.showSettings(tab: nil))
        try await until { ui.phase == .ready }
        try await Task.sleep(for: .milliseconds(250))

        ui.send(.toggle(popover()))
        try await Task.sleep(for: .milliseconds(400))
        #expect(!standIn.requests.contains(.quit), "the popover the click asked for counts as open")
        #expect(standIn.requests.last == .toggle(popover()))
        #expect(ui.phase == .ready)
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

        ui.send(.showSettings(tab: nil))
        try await until { handled.count == changes.count }
        #expect(handled == changes)
    }

    @Test func aSnapshotIsSentOnlyWhenItChanged() async throws {
        let standIn = try StandIn()
        var snapshot = Self.snapshot
        let ui = UIProcess(executableURL: standIn.script, snapshot: { snapshot }, handle: { _ in })
        defer { ui.stop() }
        ui.send(.showSettings(tab: nil))
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

    @Test func itQuitsOnlyAfterTheLingerWithNoWindowOpen() async throws {
        var quits = 0
        let linger = Linger(delay: .milliseconds(100)) { quits += 1 }
        linger.windowsOpen = true
        try await Task.sleep(for: .milliseconds(200))
        #expect(quits == 0, "a window is open")

        linger.windowsOpen = false
        #expect(linger.isCounting)
        try await Task.sleep(for: .milliseconds(50))
        linger.windowsOpen = true
        try await Task.sleep(for: .milliseconds(200))
        #expect(quits == 0, "a window opened again before the linger ran out")

        linger.windowsOpen = false
        try await Task.sleep(for: .milliseconds(50))
        #expect(quits == 0, "closing it starts the full linger again")
        try await Task.sleep(for: .milliseconds(200))
        #expect(quits == 1)
    }

    @Test func aUIProcessWhoseFirstWindowNeverOpenedQuitsToo() async throws {
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
