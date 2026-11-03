import AppKit

/// The UI process's side of `UIProcess`: reads the menu bar process's requests on standard input,
/// shows the windows, and sends the changes the user makes to the menu bar process, which runs
/// the engine. It quits when its standard input closes (the menu bar process is gone) or 60 s
/// after its last window closed (`Linger`).
@MainActor
enum UIHost {
    /// Whether this process is the UI process.
    private(set) static var isUIProcess = false
    private static let linger = Linger(delay: .seconds(60)) { NSApp.terminate(nil) }
    /// A standby process draws the popover once offscreen, with the first snapshot's numbers.
    private static var prerenders = CommandLine.arguments.contains(UIProcess.standbyFlag)

    static func start() {
        isUIProcess = true
        // A menu bar process gone before this one reads its standard input closing must not kill
        // it with SIGPIPE.
        _ = fcntl(FileHandle.standardOutput.fileDescriptor, F_SETNOSIGPIPE, 1)
        LineReader.listen(.standardInput) { line in
            guard let request = try? JSONDecoder().decode(UIRequest.self, from: Data(line.utf8)) else {
                NSLog("Soroband: unreadable request from the menu bar: %@", line)
                return
            }
            handle(request)
        } ended: {
            NSApp.terminate(nil)
        }
        windowsChanged()
        send(.ready)
    }

    /// In the UI process, sends `event` to the menu bar process and returns true; in the menu bar
    /// process returns false, and the caller makes the change itself.
    @discardableResult
    static func forward(_ event: UIEvent) -> Bool {
        guard isUIProcess else { return false }
        send(event)
        return true
    }

    static func send(_ event: UIEvent) {
        guard var line = try? JSONEncoder().encode(event) else { return }
        line.append(UInt8(ascii: "\n"))
        try? FileHandle.standardOutput.write(contentsOf: line)
    }

    /// Called whenever a window opens or closes: the process lingers once none is open.
    static func windowsChanged() {
        linger.windowsOpen =
            PopoverController.shared.isShown || SettingsWindow.shared.window != nil
            || HistoryWindow.shared.window != nil || OnboardingWindow.shared.window != nil
    }

    private static func handle(_ request: UIRequest) {
        if request.showsWindow {
            // Started with activation prohibited, so a standby process never takes the keyboard.
            NSApp.setActivationPolicy(.accessory)
        }
        switch request {
        case .snapshot(let snapshot):
            Usage.shared.mirror(snapshot)
            NetworkMonitor.shared.mirror(current: snapshot.current, connectedSince: snapshot.connectedSince)
            if prerenders {
                prerenders = false
                PopoverController.shared.prerender()
            }
        case .toggle(let popover): PopoverController.shared.toggle(popover)
        case .showPopover(let popover): PopoverController.shared.show(popover)
        case .closePopover: PopoverController.shared.close()
        case .anchor(let anchor): PopoverController.shared.move(to: anchor)
        case .showSettings(let tab): SettingsWindow.shared.show(tab: tab.flatMap(SettingsView.Tab.init(rawValue:)))
        case .closeSettings: SettingsWindow.shared.window?.close()
        case .showOnboarding: OnboardingWindow.shared.show(aboveOtherApps: true)
        case .showHistory(let arguments, let replacing):
            if let options = HistoryOptions(arguments: arguments) {
                HistoryWindow.shared.show(options, replacing: replacing)
            }
        case .closeHistory: HistoryWindow.shared.close()
        case .pointer(let inside): linger.pointerInside = inside
        case .dumpState:
            #if DEBUG
            send(.debugState(DebugCommands.uiState()))
            #else
            break
            #endif
        case .captureWindow(let number):
            #if DEBUG
            DebugCommands.captureWindow(number: number)
            #else
            _ = number
            #endif
        }
        // Each window reports itself too; this keeps the linger right for any path that opens one.
        if request.showsWindow { windowsChanged() }
    }

    /// Whether the process is waiting to quit, for `soroband debug state`.
    static var isLingering: Bool { linger.isCounting }
}

/// When the UI process quits: `delay` after the last of its windows closed, unless the pointer
/// is over the menu bar item then, which may be about to open one again.
@MainActor
final class Linger {
    var windowsOpen = false {
        didSet { if windowsOpen != oldValue { update() } }
    }
    var pointerInside = false {
        didSet { if pointerInside != oldValue { update() } }
    }
    private let delay: Duration
    private let quit: () -> Void
    private var countdown: Task<Void, Never>?

    /// Counts from the start: a standby process that never opens a window quits too.
    init(delay: Duration, quit: @escaping () -> Void) {
        self.delay = delay
        self.quit = quit
        update()
    }

    var isCounting: Bool { countdown != nil }

    private func update() {
        countdown?.cancel()
        countdown = nil
        guard !windowsOpen, !pointerInside else { return }
        countdown = Task { [delay, quit] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            quit()
        }
    }
}

/// What a click on the menu bar item does to the popover.
enum PopoverToggle: Equatable {
    case open, close, ignore

    /// Closes an open popover and opens a closed one, unless it closed under 0.3 s ago: a
    /// transient popover can close on the mouse-down of the click on the item, before the click
    /// reaches the UI process, and that click meant "close".
    static func decide(isShown: Bool, lastClose: Date, now: Date) -> PopoverToggle {
        if isShown { return .close }
        return now.timeIntervalSince(lastClose) > 0.3 ? .open : .ignore
    }
}
