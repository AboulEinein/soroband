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
    case showSettings(tab: String?)
    case closeSettings
    case showOnboarding
    /// History on `arguments` (`HistoryOptions.arguments`). A History already open comes forward
    /// as it is, unless `replacing` it.
    case showHistory(arguments: [String], replacing: Bool)
    case closeHistory
    /// Whether the pointer is over the menu bar item, which keeps the UI process from quitting.
    case pointer(inside: Bool)
    /// Debug builds: answer with `UIEvent.debugState`, or render window `number`.
    case dumpState
    case captureWindow(number: Int)

    /// Whether the request shows a window. Only these start a UI process; the others mean
    /// nothing without one.
    var showsWindow: Bool {
        switch self {
        case .toggle, .showPopover, .showSettings, .showOnboarding, .showHistory: true
        case .snapshot, .closePopover, .anchor, .closeSettings, .closeHistory, .pointer, .dumpState, .captureWindow:
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
    /// When this process got the click, to time the opening.
    var requested: Date
}

/// What the UI process tells the menu bar process: one JSON line each on its standard output.
enum UIEvent: Codable, Equatable {
    /// It reads its requests from now on.
    case ready
    case popover(shown: Bool)
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
/// because nothing showed yet, so they open the popover once, however many there were.
struct UIQueue: Equatable {
    private(set) var requests: [UIRequest] = []

    mutating func add(_ request: UIRequest) {
        switch request {
        case .toggle(let popover):
            guard !requests.contains(where: \.opensPopover) else { return }
            requests.append(.showPopover(popover))
        case .showPopover:
            guard !requests.contains(where: \.opensPopover) else { return }
            requests.append(request)
        case .snapshot, .anchor, .pointer:
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
/// process never holds a window and keeps its launch footprint. It starts when the pointer enters
/// the menu bar item (in standby, with no window) or at the first request, and quits by itself
/// 60 s after its last window closes (`Linger`), or when this process quits and its standard
/// input closes.
@MainActor
final class UIProcess {
    static let shared = UIProcess()
    nonisolated static let flag = "--ui"
    /// Started by the pointer on the item, ahead of any window: it draws the popover once offscreen
    /// (`PopoverController.prerender`).
    nonisolated static let standbyFlag = "--standby"

    enum Phase: Equatable {
        case stopped, launching, ready
    }

    private(set) var phase = Phase.stopped
    /// Whether the UI process shows the popover, as it last said.
    private(set) var isPopoverShown = false
    private var process: Process?
    private var input: FileHandle?
    private var queue = UIQueue()
    private var pointerInside = false
    /// The last snapshot sent; the next is sent only when it differs.
    private var sent: UISnapshot?
    /// Writes in a queue of their own, so a UI process that stops reading never blocks the menu
    /// bar; snapshots are skipped while too many wait, since the next one carries everything.
    private let writer = DispatchQueue(label: "io.github.abouleinein.soroband.ui-process")
    private var waitingWrites = 0
    private var debugStateReply: ((String?) -> Void)?

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
        handle: @escaping @MainActor (UIEvent) -> Void = UIProcess.apply
    ) {
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
        switch phase {
        case .ready:
            write(request)
        case .launching:
            queue.add(request)
        case .stopped:
            guard request.showsWindow else { return }
            queue.add(request)
            launch(standby: false)
        }
    }

    /// The pointer entered or left the menu bar item: entering starts the UI process in standby,
    /// so a click does not wait for a launch.
    func pointer(inside: Bool) {
        pointerInside = inside
        switch phase {
        case .ready: write(.pointer(inside: inside))
        case .launching: break
        case .stopped: if inside { launch(standby: true) }
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

    /// Asks the UI process for its part of `soroband debug state`; nil when none runs or it does
    /// not answer within a second.
    func debugState(_ reply: @escaping (String?) -> Void) {
        guard phase == .ready else { return reply(nil) }
        debugStateReply?(nil)
        debugStateReply = reply
        write(.dumpState)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.debugStateReply?(nil)
            self?.debugStateReply = nil
        }
    }

    /// Starts the process directly rather than through Launch Services, which drops the arguments
    /// of a second instance of the same app. It inherits the environment, so a Debug build run on
    /// another data directory shows the same data.
    private func launch(standby: Bool) {
        guard let executableURL else { return }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = standby ? [Self.flag, Self.standbyFlag] : [Self.flag]
        process.standardInput = input
        process.standardOutput = output
        // A UI process gone before this process knows it must not kill it with SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.exited(ended) } }
        }
        LineReader.listen(output.fileHandleForReading) { [weak self] line in
            guard let event = try? JSONDecoder().decode(UIEvent.self, from: Data(line.utf8)) else { return }
            self?.received(event)
        } ended: {
        }
        do {
            try process.run()
            self.process = process
            self.input = input.fileHandleForWriting
            phase = .launching
        } catch {
            NSLog("Soroband: cannot start the UI process: %@", String(describing: error))
            queue = UIQueue()
        }
    }

    private func received(_ event: UIEvent) {
        switch event {
        case .ready:
            phase = .ready
            sent = nil
            write(.pointer(inside: pointerInside))
            publish()
            queue.take().forEach(write)
        case .popover(let shown):
            isPopoverShown = shown
        case .debugState(let json):
            debugStateReply?(json)
            debugStateReply = nil
        default:
            handle(event)
            publish()
        }
    }

    private func exited(_ ended: Process) {
        guard ended === process else { return }
        process = nil
        input = nil
        phase = .stopped
        isPopoverShown = false
        queue = UIQueue()
        sent = nil
        debugStateReply?(nil)
        debugStateReply = nil
        onExit?()
    }

    private func write(_ request: UIRequest) {
        guard let input, let json = try? JSONEncoder().encode(request) else { return }
        let line = json + [UInt8(ascii: "\n")]
        // macOS lets an app come forward only when the active app yields to it.
        if request.showsWindow, let pid = processIdentifier, let app = NSRunningApplication(processIdentifier: pid) {
            NSApp.yieldActivation(to: app)
        }
        waitingWrites += 1
        writer.async { [weak self] in
            // An error means the UI process is gone; its termination handler resets the state.
            try? input.write(contentsOf: line)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.waitingWrites -= 1 } }
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
        case .ready, .popover, .debugState: break
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
