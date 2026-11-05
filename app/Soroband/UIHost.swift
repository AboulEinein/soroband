import AppKit

/// The UI process's side of `UIProcess`: reads the menu bar process's requests on standard input,
/// shows the windows, and sends the changes the user makes to the menu bar process, which runs
/// the engine. It quits when the menu bar process asks (`UIRequest.quit`, at the end of the
/// linger) or when its standard input closes (the menu bar process is gone).
@MainActor
enum UIHost {
    /// Whether this process is the UI process.
    private(set) static var isUIProcess = false
    /// Whether a window was open at the last report to the menu bar process, which runs the linger.
    private static var reportedWindowsOpen: Bool?

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

    /// Called whenever a window opens or closes, and after each request for one: the menu bar
    /// process starts the linger once none is open.
    static func windowsChanged(after request: UIRequest? = nil) {
        let open =
            PopoverController.shared.isShown || SettingsWindow.shared.window != nil
            || HistoryWindow.shared.window != nil || OnboardingWindow.shared.window != nil
        guard let report = windowsReport(open: open, reported: reportedWindowsOpen, after: request) else { return }
        reportedWindowsOpen = open
        send(report)
    }

    /// What to tell the menu bar process about the windows: a change, and the state after every
    /// request for a window even when nothing changed. The menu bar process counts a window as
    /// open from the moment it asks for one, so a request that opens nothing (a click within
    /// 0.3 s of a close, History options it cannot read) must still be answered, or the linger
    /// never runs.
    nonisolated static func windowsReport(open: Bool, reported: Bool?, after request: UIRequest?) -> UIEvent? {
        guard open != reported || request?.showsWindow == true else { return nil }
        return .windows(open: open)
    }

    private static func handle(_ request: UIRequest) {
        if request.showsWindow {
            // Started with activation prohibited, so a launch never takes the keyboard by itself.
            NSApp.setActivationPolicy(.accessory)
        }
        switch request {
        case .snapshot(let snapshot):
            Usage.shared.mirror(snapshot)
            NetworkMonitor.shared.mirror(current: snapshot.current, connectedSince: snapshot.connectedSince)
        case .toggle(let popover): PopoverController.shared.toggle(popover)
        case .showPopover(let popover): PopoverController.shared.show(popover)
        case .closePopover: PopoverController.shared.close()
        case .anchor(let anchor): PopoverController.shared.move(to: anchor)
        case .showSettings(let tab, _):
            SettingsWindow.shared.show(
                tab: tab.flatMap(SettingsView.Tab.init(rawValue:)), activates: request.activates)
        case .closeSettings: SettingsWindow.shared.window?.close()
        case .showOnboarding: OnboardingWindow.shared.show(aboveOtherApps: true, activates: request.activates)
        case .showHistory(let arguments, let replacing, _):
            if let options = HistoryOptions(arguments: arguments) {
                HistoryWindow.shared.show(options, replacing: replacing, activates: request.activates)
            }
        case .closeHistory: HistoryWindow.shared.close()
        case .quit: NSApp.terminate(nil)
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
        if request.showsWindow { windowsChanged(after: request) }
    }
}

/// Brings `window` forward. When it `activates`, Soroband becomes the front app (if macOS lets it)
/// and the window takes the keyboard; otherwise it only comes forward, and the keyboard stays
/// where it was.
@MainActor
func bringForward(_ window: NSWindow, activates: Bool) {
    if activates {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    } else {
        window.orderFront(nil)
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

/// Whether the popover's close gives the keyboard back to the app that had it before the click.
enum KeyboardReturn {
    /// Only when a click took it from an app (`hasPreviousApp`), Soroband still has it (the user
    /// did not click into another app meanwhile), and the popover still had it as its close began
    /// (`popoverWasKey`): Settings or History reached from the popover (its buttons, ⌘, or a click
    /// into one) is key by then and keeps it. A window merely open in the background does not.
    static func givesBack(hasPreviousApp: Bool, sorobandIsFront: Bool, popoverWasKey: Bool) -> Bool {
        hasPreviousApp && sorobandIsFront && popoverWasKey
    }
}
