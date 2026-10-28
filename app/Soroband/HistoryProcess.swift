import AppKit

/// What a History process opens on, passed as its launch arguments.
///
/// History runs in a process of its own, a second instance of Soroband.app started with
/// `--history`: AppKit, SwiftUI and Charts keep tens of megabytes after a window closes, and the
/// menu bar app runs all day. The History process reads the database, never starts the engine,
/// and quits when its window closes.
struct HistoryOptions: Equatable {
    var range: HistoryRange = .month
    /// A day in the period to show; today when nil.
    var date: Date?
    /// One network, or every network when nil.
    var network: Int64?
    /// The network the Mac is on, for the sidebar's badge.
    var current: Int64?
    /// When the menu bar app asked for History, to time the opening from the click.
    var requested: Date?
    /// For captures: an app shown expanded, and a time the chart shows as hovered.
    var expandedApp: String?
    var hover: Date?

    static let flag = "--history"
    /// Started ahead of a click, waiting for options on standard input (`HistoryStandby`).
    static let standbyFlag = "--standby"
    /// Between the arguments of one line on standard input.
    static let separator = "\u{1F}"

    var arguments: [String] {
        var arguments = [Self.flag, "--range", range.rawValue]
        if let date { arguments += ["--date", Self.format(date)] }
        if let network { arguments += ["--network", String(network)] }
        if let current { arguments += ["--current", String(current)] }
        if let requested { arguments += ["--requested", String(requested.timeIntervalSince1970)] }
        if let expandedApp { arguments += ["--app", expandedApp] }
        if let hover { arguments += ["--hover", Self.format(hover)] }
        return arguments
    }

    /// The options in `arguments`, or nil when they do not start History.
    init?(arguments: [String]) {
        guard arguments.contains(Self.flag) else { return nil }
        var values: [String: String] = [:]
        for (index, argument) in arguments.enumerated() where argument.hasPrefix("--") && index + 1 < arguments.count {
            values[argument] = arguments[index + 1]
        }
        range = values["--range"].flatMap(HistoryRange.init(rawValue:)) ?? .month
        date = values["--date"].flatMap(Self.parse)
        network = values["--network"].flatMap(Int64.init)
        current = values["--current"].flatMap(Int64.init)
        requested = values["--requested"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        expandedApp = values["--app"]
        hover = values["--hover"].flatMap(Self.parse)
    }

    init(
        range: HistoryRange = .month, date: Date? = nil, network: Int64? = nil, current: Int64? = nil,
        requested: Date? = nil, expandedApp: String? = nil, hover: Date? = nil
    ) {
        self.range = range
        self.date = date
        self.network = network
        self.current = current
        self.requested = requested
        self.expandedApp = expandedApp
        self.hover = hover
    }

    /// Unix seconds, so a date crosses the process boundary whatever the time zone.
    private static func format(_ date: Date) -> String { String(date.timeIntervalSince1970) }
    private static func parse(_ text: String) -> Date? { Double(text).map(Date.init(timeIntervalSince1970:)) }
}

/// Starts and stops the History process from the menu bar app.
///
/// Starting a process takes about 150 ms of the 300 ms History may take to open, so the popover
/// starts one in standby when it opens (`prepare`): it loads its frameworks and the network list,
/// then waits for options on its standard input. A click hands them over, and the window shows
/// with no launch to wait for. A standby process the popover did not use quits when it closes
/// (`dismissStandby`), and every History process quits when its standard input closes, so none
/// outlives the menu bar app.
@MainActor
enum HistoryProcess {
    private static var running: Process?
    private static var input: Pipe?
    /// Whether the running process waits in standby, with no window yet.
    private static var standing = false

    /// The History process, while it runs.
    static var processIdentifier: pid_t? {
        running?.isRunning == true ? running?.processIdentifier : nil
    }

    /// Starts a History process in standby, unless one runs.
    static func prepare() {
        guard running?.isRunning != true else { return }
        standing = launch([HistoryOptions.flag, HistoryOptions.standbyFlag])
    }

    /// Quits the standby process, if it was not used.
    static func dismissStandby() {
        guard standing else { return }
        close()
    }

    /// Opens History on `options`: in the standby process when there is one, else in a new
    /// process. A History already open is brought forward as it is, unless `replacing` it, which
    /// quits it and opens a new one.
    static func open(_ options: HistoryOptions, replacing: Bool = false) {
        var options = options
        options.requested = .now
        if let running, running.isRunning {
            // macOS lets an app come forward only when the active app yields to it.
            if let app = NSRunningApplication(processIdentifier: running.processIdentifier) {
                NSApp.yieldActivation(to: app)
            }
            if standing, let input {
                standing = false
                let line = options.arguments.joined(separator: HistoryOptions.separator) + "\n"
                input.fileHandleForWriting.write(Data(line.utf8))
                return
            }
            guard replacing else {
                NSRunningApplication(processIdentifier: running.processIdentifier)?.activate()
                return
            }
            close()
        }
        _ = launch(options.arguments)
    }

    static func close() {
        running?.terminate()
        running = nil
        input = nil
        standing = false
    }

    /// Starts the process directly rather than through Launch Services, which dropped the
    /// arguments of a second instance of the same app. It inherits the environment, so a Debug
    /// build run on another data directory opens History on the same one.
    private static func launch(_ arguments: [String]) -> Bool {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = Bundle.main.executableURL
        process.arguments = arguments
        process.standardInput = pipe
        do {
            try process.run()
            running = process
            input = pipe
            return true
        } catch {
            NSLog("Soroband: cannot open History: %@", String(describing: error))
            return false
        }
    }
}

/// The History process's side of standby: waits for options on standard input.
enum HistoryStandby {
    /// Calls `show` on the main thread with the first options read, and `ended` when standard
    /// input closes: the menu bar app quit, or dropped the process.
    static func listen(show: @escaping @MainActor (HistoryOptions) -> Void, ended: @escaping @MainActor () -> Void) {
        Thread.detachNewThread {
            var buffer = Data()
            while true {
                let chunk = FileHandle.standardInput.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(decoding: buffer[..<newline], as: UTF8.self)
                    buffer.removeSubrange(...newline)
                    let arguments = line.components(separatedBy: HistoryOptions.separator)
                    if let options = HistoryOptions(arguments: arguments) {
                        DispatchQueue.main.async { MainActor.assumeIsolated { show(options) } }
                    }
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { ended() } }
        }
    }
}
