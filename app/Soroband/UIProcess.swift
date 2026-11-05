import AppKit

/// What the menu bar process asks of the UI process: one JSON line each on the UI process's
/// standard input (`UIHost`).
enum UIRequest: Codable, Equatable {
    /// What the windows show, after each change in the menu bar process.
    case snapshot(UISnapshot)
    /// A click on the menu bar item: opens the popover, or closes it (`PopoverToggle`).
    case toggle(PopoverRequest)
    /// Opens the popover, as `open-popover` and a click while the UI process launched do.
    case showPopover(PopoverRequest)
    case closePopover
    /// The menu bar item moved or changed width; an open popover follows it.
    case anchor(CGRect)
    /// `SettingsView.Tab`'s raw value, or nil for the tab Settings showed last.
    case showSettings(tab: String?, activates: Bool = false)
    case closeSettings
    case showOnboarding(activates: Bool = false)
    /// History on `arguments` (`HistoryOptions.arguments`). A History already open comes forward
    /// as it is, unless `replacing` it.
    case showHistory(arguments: [String], replacing: Bool, activates: Bool = false)
    case closeHistory
    /// The linger ran out: quit, after any History export in flight.
    case quit
    /// Debug builds: answer with `UIEvent.debugState`, or render window `number`.
    case dumpState
    case captureWindow(number: Int)

    /// Whether the request shows a window. Only these start a UI process; the others mean
    /// nothing without one.
    var showsWindow: Bool {
        switch self {
        case .toggle, .showPopover, .showSettings, .showOnboarding, .showHistory: true
        case .snapshot, .closePopover, .anchor, .closeSettings, .closeHistory, .quit, .dumpState,
            .captureWindow:
            false
        }
    }

    /// Whether the window it shows may make Soroband the front app and take the keyboard: only
    /// when the user asked for it (a click on the menu bar item, the Welcome window at the launch
    /// the user started). A Debug URL command never does.
    var activates: Bool {
        switch self {
        case .toggle(let popover), .showPopover(let popover): popover.activates
        case .showSettings(_, let activates), .showOnboarding(let activates), .showHistory(_, _, let activates):
            activates
        case .snapshot, .closePopover, .anchor, .closeSettings, .closeHistory, .quit, .dumpState, .captureWindow:
            false
        }
    }
}

/// Where and how the popover opens.
struct PopoverRequest: Codable, Equatable {
    /// The menu bar item's frame in screen coordinates (points, origin at the bottom left of the
    /// main display, as `NSWindow.frame`).
    var anchor: CGRect
    /// `PopoverView.Tab`'s raw value.
    var tab = "Apps"
    var allNetworks = false
    /// A click on the menu bar item asked for it (`UIRequest.activates`).
    var activates = false
    /// When this process got the click, to time the opening.
    var requested: Date
}

/// What the UI process tells the menu bar process: one JSON line each on its standard output.
enum UIEvent: Codable, Equatable {
    /// It reads its requests from now on.
    case ready
    case popover(shown: Bool)
    /// Whether any of its windows is open, for the linger.
    case windows(open: Bool)
    // Changes the engine's process makes, as `Usage` and `NetworkMonitor` make them there.
    case live(Bool)
    case setMenuBarLayout(MenuBarLayout)
    case setResetHour(Int)
    case setNetworkColor(id: Int64, color: Int?)
    case updateNetwork(id: Int64, name: String, kind: NetworkKind)
    case reloadRegistry
    case refreshNetwork
    case refreshUntilNamed
    /// The popover's Quit button: Soroband quits, and the UI process with it.
    case quit
    /// A `soroband-debug://` URL macOS handed to the UI process instead.
    case url(String)
    /// Debug builds: the UI process's part of `soroband debug state`, as JSON.
    case debugState(String)
}

/// What the popover and Settings show, as the menu bar process's `Usage` and `NetworkMonitor`
/// hold it. It goes over at each change, so a number in the UI process is as fresh as the same
/// poll in the menu bar process.
struct UISnapshot: Codable, Equatable {
    var status: EngineStatus
    /// Today's lists as the core's JSON (`Usage.todayJSON`), read only in the UI process; empty
    /// unless the popover is open (`Usage.isLive`).
    var todayJSON: String
    var registry: [RegisteredNetwork]
    var menuBarLayout: MenuBarLayout
    var resetHour: Int
    var current: Network?
    var connectedSince: Date?

    @MainActor
    static func current() -> UISnapshot {
        let usage = Usage.shared
        return UISnapshot(
            status: usage.status, todayJSON: usage.todayJSON, registry: usage.registry,
            menuBarLayout: usage.menuBarLayout,
            resetHour: usage.resetHour, current: NetworkMonitor.shared.current,
            connectedSince: NetworkMonitor.shared.connectedSince)
    }
}

/// Requests made before the UI process reads them. Every click while it launches meant "open",
/// because nothing showed yet, so they open the popover once, however many there were, under the
/// item where the latest one found it, on the tab the queued request asked for.
struct UIQueue: Equatable {
    private(set) var requests: [UIRequest] = []

    mutating func add(_ request: UIRequest) {
        switch request {
        case .toggle(let click):
            if let opener = requests.firstIndex(where: \.opensPopover), case .showPopover(var queued) = requests[opener]
            {
                // A click brings the item's frame and its time, not a tab: an `open-popover` with
                // a tab keeps it.
                queued.anchor = click.anchor
                queued.requested = click.requested
                queued.activates = queued.activates || click.activates
                requests[opener] = .showPopover(queued)
            } else {
                requests.append(.showPopover(click))
            }
        case .showPopover(var popover):
            if let opener = requests.firstIndex(where: \.opensPopover) {
                // A click queued before it still asked for the keyboard.
                popover.activates = popover.activates || requests[opener].activates
                requests[opener] = .showPopover(popover)
            } else {
                requests.append(request)
            }
        case .snapshot, .anchor:
            // The UI process gets the latest of these when it is ready.
            break
        default:
            requests.append(request)
        }
    }

    mutating func take() -> [UIRequest] {
        defer { requests = [] }
        return requests
    }
}

extension UIRequest {
    fileprivate var opensPopover: Bool {
        switch self {
        case .toggle, .showPopover: true
        default: false
        }
    }
}

/// The UI process, from the menu bar process: a second instance of Soroband.app started with
/// `--ui`, which shows the popover, Settings, History and the Welcome window, so the menu bar
/// process never holds a window and keeps its launch footprint. It starts at the first request for
/// a window. This process quits it 10 minutes after its last window closed (`Linger`), and it quits
/// by itself when this process quits and its standard input closes.
@MainActor
final class UIProcess {
    static let shared = UIProcess()
    nonisolated static let flag = "--ui"

    enum Phase: Equatable {
        case stopped, launching, ready
    }

    private(set) var phase = Phase.stopped
    /// Whether the UI process shows the popover, as it last said.
    private(set) var isPopoverShown = false
    private var process: Process?
    private var input: FileHandle?
    private var queue = UIQueue()
    /// The last snapshot sent; the next is sent only when it differs.
    private var sent: UISnapshot?
    /// Writes in a queue of their own, so a UI process that stops reading never blocks the menu
    /// bar; snapshots are skipped while too many wait, since the next one carries everything.
    private let writer = DispatchQueue(label: "io.github.abouleinein.soroband.ui-process")
    private var waitingWrites = 0
    private var debugStateReply: ((String?) -> Void)?
    /// When a request for a window was last sent again after a failed write (`writeFailed`).
    private var lastReplay: Date?
    /// Ends the wait of the request in `debugStateReply`, and only that one.
    private var debugStateTimeout: Task<Void, Never>?

    /// Counts down to quitting the UI process while none of its windows is open (`Linger`).
    private var linger: Linger?
    private let lingerDelay: Duration
    private let debugStateWait: Duration
    private let executableURL: URL?
    private let snapshot: @MainActor () -> UISnapshot
    private let handle: @MainActor (UIEvent) -> Void
    /// Called when the UI process exits, whatever the cause.
    var onExit: (() -> Void)?

    /// `executableURL` is this app's executable; tests start a stand-in and see its events in
    /// `handle`.
    init(
        executableURL: URL? = Bundle.main.executableURL,
        snapshot: @escaping @MainActor () -> UISnapshot = UISnapshot.current,
        handle: @escaping @MainActor (UIEvent) -> Void = UIProcess.apply,
        lingerDelay: Duration = .seconds(600),
        debugStateWait: Duration = .seconds(1)
    ) {
        self.lingerDelay = lingerDelay
        self.debugStateWait = debugStateWait
        self.executableURL = executableURL
        self.snapshot = snapshot
        self.handle = handle
    }

    var processIdentifier: pid_t? {
        process?.isRunning == true ? process?.processIdentifier : nil
    }

    /// Sends `request`, starting the UI process when it needs one. Until the UI process is ready,
    /// requests wait in `UIQueue`.
    func send(_ request: UIRequest) {
        // Counted as open from now, before the UI process says so, so the linger cannot run out
        // while the request is on its way.
        if request.showsWindow { linger?.windowsOpen = true }
        switch phase {
        case .ready:
            write(request)
        case .launching:
            queue.add(request)
        case .stopped:
            guard request.showsWindow else { return }
            queue.add(request)
            launch()
        }
    }

    /// Sends what the windows show, if it changed since the last snapshot.
    func publish() {
        guard phase == .ready else { return }
        let snapshot = snapshot()
        guard snapshot != sent, waitingWrites < 4 else { return }
        sent = snapshot
        write(.snapshot(snapshot))
    }

    /// Quits the UI process.
    func stop() {
        process?.terminate()
    }

    /// Whether the UI process waits to quit, for `soroband debug state`.
    var isLingering: Bool { linger?.isCounting ?? false }

    /// Asks the UI process for its part of `soroband debug state`; nil when none runs, it does not
    /// answer within `debugStateWait` (a second), or a newer request takes over.
    func debugState(_ reply: @escaping (String?) -> Void) {
        guard phase == .ready else { return reply(nil) }
        answerDebugState(nil)
        debugStateReply = reply
        write(.dumpState)
        debugStateTimeout = Task { [weak self, debugStateWait] in
            try? await Task.sleep(for: debugStateWait)
            guard !Task.isCancelled else { return }
            self?.answerDebugState(nil)
        }
    }

    private func answerDebugState(_ json: String?) {
        debugStateTimeout?.cancel()
        debugStateTimeout = nil
        let reply = debugStateReply
        debugStateReply = nil
        reply?(json)
    }

    /// Starts the process directly rather than through Launch Services, which drops the arguments
    /// of a second instance of the same app. It inherits the environment, so a Debug build run on
    /// another data directory shows the same data.
    private func launch() {
        guard let executableURL else { return }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = [Self.flag]
        process.standardInput = input
        process.standardOutput = output
        // A UI process gone before this process knows it must not kill it with SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.exited(ended) } }
        }
        LineReader.listen(output.fileHandleForReading) { [weak self, process] line in
            guard let event = try? JSONDecoder().decode(UIEvent.self, from: Data(line.utf8)) else { return }
            self?.received(event, from: process)
        } ended: {
        }
        do {
            try process.run()
            self.process = process
            self.input = input.fileHandleForWriting
            phase = .launching
            let linger = Linger(delay: lingerDelay) { [weak self] in self?.lingerRanOut() }
            linger.windowsOpen = !queue.requests.isEmpty
            self.linger = linger
        } catch {
            NSLog("Soroband: cannot start the UI process: %@", String(describing: error))
            queue = UIQueue()
        }
    }

    /// Events count only from the UI process this process still knows: one it forgot (it exited,
    /// the linger ended it, or a write to it failed) can still send a line it had written, and its
    /// `ready` would mark a process ready that has no input.
    private func received(_ event: UIEvent, from sender: Process) {
        guard sender === process else { return }
        switch event {
        case .ready:
            phase = .ready
            sent = nil
            publish()
            queue.take().forEach(write)
        case .popover(let shown):
            isPopoverShown = shown
        case .windows(let open):
            linger?.windowsOpen = open
        case .debugState(let json):
            answerDebugState(json)
        default:
            handle(event)
            // Sent even when nothing changed here: the UI process already shows a reset hour or
            // layout it asked for, and a save that failed must take it back.
            sent = nil
            publish()
        }
    }

    private func exited(_ ended: Process) {
        guard ended === process else { return }
        // A UI process that died before it was ready read none of its requests: they wait for the
        // next launch, which the next request starts, so a click made then still opens the popover.
        let unread = phase == .launching ? queue : UIQueue()
        forget()
        queue = unread
        onExit?()
    }

    /// Asks the UI process to quit, and from now on counts it as gone: a click a moment later
    /// starts another one rather than reaching one that is quitting.
    private func lingerRanOut() {
        guard phase != .stopped else { return }
        write(.quit)
        forget()
    }

    /// A write that failed found the UI process no longer reading, though it has not been seen to
    /// exit yet: it is stopped and forgotten, and a request for a window goes to a new one, once in
    /// 5 s at most, so a UI process that never reads cannot start a launch loop.
    private func writeFailed(_ request: UIRequest, to failed: FileHandle) {
        if failed === input {
            process?.terminate()
            forget()
            onExit?()
        }
        guard request.showsWindow, lastReplay.map({ Date.now.timeIntervalSince($0) > 5 }) ?? true else { return }
        lastReplay = .now
        send(request)
    }

    private func forget() {
        process = nil
        input = nil
        phase = .stopped
        isPopoverShown = false
        queue = UIQueue()
        sent = nil
        linger = nil
        answerDebugState(nil)
    }

    private func write(_ request: UIRequest) {
        guard let input, let json = try? JSONEncoder().encode(request) else { return }
        let line = json + [UInt8(ascii: "\n")]
        // macOS lets an app come forward only when the active app yields to it.
        if request.activates, let pid = processIdentifier, let app = NSRunningApplication(processIdentifier: pid) {
            NSApp.yieldActivation(to: app)
        }
        waitingWrites += 1
        writer.async { [weak self] in
            let failed = (try? input.write(contentsOf: line)) == nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.waitingWrites -= 1
                    if failed { self?.writeFailed(request, to: input) }
                }
            }
        }
    }

    /// Applies a change the UI process asked for, as the change made in this process would.
    static func apply(_ event: UIEvent) {
        let usage = Usage.shared
        switch event {
        case .live(let live): usage.isLive = live
        case .setMenuBarLayout(let layout): usage.setMenuBarLayout(layout)
        case .setResetHour(let hour): usage.setResetHour(hour)
        case .setNetworkColor(let id, let color): usage.setNetworkColor(id: id, color: color)
        case .updateNetwork(let id, let name, let kind): usage.updateNetwork(id: id, name: name, kind: kind)
        case .reloadRegistry: usage.reloadRegistry()
        case .refreshNetwork: NetworkMonitor.shared.refresh()
        case .refreshUntilNamed: NetworkMonitor.shared.refreshUntilNamed()
        case .quit: NSApp.terminate(nil)
        case .url(let text):
            #if DEBUG
            if let url = URL(string: text) { DebugCommands.handle(url) }
            #else
            NSLog("Soroband: ignoring %@", text)
            #endif
        case .ready, .popover, .windows, .debugState: break
        }
    }
}

/// When the UI process quits: `delay` after the last of its windows closed. The menu bar process
/// runs it, so a request it sends can never meet a UI process that already decided to quit.
@MainActor
final class Linger {
    var windowsOpen = false {
        didSet { if windowsOpen != oldValue { update() } }
    }
    private let delay: Duration
    private let quit: () -> Void
    private var countdown: Task<Void, Never>?

    /// Counts from the start: a UI process whose first window never opened quits too.
    init(delay: Duration, quit: @escaping () -> Void) {
        self.delay = delay
        self.quit = quit
        update()
    }

    var isCounting: Bool { countdown != nil }

    private func update() {
        countdown?.cancel()
        countdown = nil
        guard !windowsOpen else { return }
        countdown = Task { [delay, quit] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            quit()
        }
    }
}

/// Reads newline-separated lines from a pipe on a thread of its own.
enum LineReader {
    /// Calls `line` on the main thread with each line read, and `ended` once the pipe closes.
    static func listen(
        _ handle: FileHandle, line: @escaping @MainActor (String) -> Void, ended: @escaping @MainActor () -> Void
    ) {
        Thread.detachNewThread {
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let text = String(decoding: buffer[..<newline], as: UTF8.self)
                    buffer.removeSubrange(...newline)
                    DispatchQueue.main.async { MainActor.assumeIsolated { line(text) } }
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { ended() } }
        }
    }
}
