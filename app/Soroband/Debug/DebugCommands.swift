#if DEBUG
import AppKit
import notify

/// Lets an agent drive and observe a Debug build without a mouse.
///
/// - `open -g -a <this build's Soroband.app> "soroband-debug://<command>"` runs a command (see
///   `handle`); without `-g` macOS brings the app to the front, taking the user's keyboard.
/// - `soroband debug state --json` posts `dumpStateNotification`; the app answers by writing its
///   state to `stateFile`. `soroband debug history --json` does the same with the History
///   process (`dumpHistoryNotification`, `historyFile`). The names must match
///   `core/crates/soroband-cli/src/debug.rs`.
@MainActor
enum DebugCommands {
    static let dumpStateNotification = "io.github.abouleinein.soroband.debug.dump-state"
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Caches/io.github.abouleinein.soroband.debug")
    static let stateFile = directory.appending(path: "state.json")
    static let statusItemFile = directory.appending(path: "status-item.png")
    static let windowFile = directory.appending(path: "window.png")
    static let historyCSVFile = directory.appending(path: "history.csv")
    static let dumpHistoryNotification = "io.github.abouleinein.soroband.debug.dump-history"
    static let historyFile = directory.appending(path: "history.json")
    /// The menu bar app tells the History process to export what it shows.
    static let exportHistoryNotification = "io.github.abouleinein.soroband.debug.export-history"

    private static var token: Int32 = 0
    private static var exportToken: Int32 = 0

    static func start() {
        notify_register_dispatch(dumpStateNotification, &token, .main) { _ in
            MainActor.assumeIsolated { writeState() }
        }
    }

    /// The History process answers `soroband debug history --json` and `export-history`.
    static func startHistory() {
        notify_register_dispatch(dumpHistoryNotification, &token, .main) { _ in
            MainActor.assumeIsolated { write(HistoryState.current(), to: historyFile) }
        }
        notify_register_dispatch(exportHistoryNotification, &exportToken, .main) { _ in
            MainActor.assumeIsolated { exportHistory() }
        }
    }

    static func handle(_ url: URL) {
        guard url.scheme == "soroband-debug" else { return }
        switch url.host() {
        case "quit": NSApp.terminate(nil)
        case "open-popover": openPopover(url)
        case "close-popover": MenuBarController.shared.closePopover()
        case "open-settings": openSettings(url)
        case "close-settings": SettingsWindow.shared.window?.close()
        case "open-history": openHistory(url)
        case "close-history": HistoryProcess.close()
        case "export-history": notify_post(exportHistoryNotification)
        case "open-onboarding": OnboardingWindow.shared.show()
        case "capture-status-item": captureStatusItem()
        case "capture-window": captureWindow(url)
        case "simulate-network": simulateNetwork(url)
        case "update-network": updateNetwork(url)
        default: NSLog("soroband-debug: unknown command %@", url.absoluteString)
        }
    }

    /// `simulate-network?id=office&kind=hotspot` books usage to a made-up network named `id`
    /// (kind `wifi` unless given); `simulate-network` alone goes back to the real network.
    private static func simulateNetwork(_ url: URL) {
        let query = queryItems(url)
        guard let id = query["id"], !id.isEmpty else {
            NetworkMonitor.shared.simulated = nil
            return
        }
        guard let kind = NetworkKind(rawValue: query["kind"] ?? "wifi") else {
            NSLog("soroband-debug: unknown network kind in %@", url.absoluteString)
            return
        }
        NetworkMonitor.shared.simulated = NetworkIdentity(key: "simulated:\(id)", name: id, kind: kind)
    }

    /// `update-network?name=Desk&kind=ethernet` renames the current network and sets its kind, as
    /// the Networks settings will.
    private static func updateNetwork(_ url: URL) {
        let query = queryItems(url)
        guard let current = NetworkMonitor.shared.current else { return }
        guard let kind = NetworkKind(rawValue: query["kind"] ?? current.kind.rawValue) else {
            NSLog("soroband-debug: unknown network kind in %@", url.absoluteString)
            return
        }
        NetworkMonitor.shared.updateCurrent(name: query["name"] ?? current.name, kind: kind)
    }

    /// `open-popover?tab=networks&all=1` opens the popover on a tab (`apps` unless given), with
    /// the Apps tab showing all networks when `all` is 1.
    private static func openPopover(_ url: URL) {
        let query = queryItems(url)
        guard let tab = PopoverView.Tab(rawValue: (query["tab"] ?? "apps").capitalized) else {
            NSLog("soroband-debug: unknown popover tab in %@", url.absoluteString)
            return
        }
        MenuBarController.shared.showPopover(tab: tab, allNetworks: query["all"] == "1")
    }

    /// `open-history?range=year&network=2&date=2026-10-15&app=<app id>&hover=2026-10-18T09:00`
    /// opens History in a new History process (Month, every network, today unless given) and, for
    /// captures, expands an app and holds the chart's hover on a time. A History already open is
    /// replaced.
    private static func openHistory(_ url: URL) {
        let query = queryItems(url)
        guard let range = HistoryRange(rawValue: query["range"] ?? "month") else {
            NSLog("soroband-debug: unknown history range in %@", url.absoluteString)
            return
        }
        HistoryProcess.open(
            HistoryOptions(
                range: range, date: query["date"].flatMap(localDate), network: query["network"].flatMap(Int64.init),
                current: NetworkMonitor.shared.current?.id, expandedApp: query["app"],
                hover: query["hover"].flatMap(localDate)),
            replacing: true)
    }

    /// `2026-10-15` or `2026-10-15T09:00`, in the local time zone.
    private static func localDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = text.contains("T") ? "yyyy-MM-dd'T'HH:mm" : "yyyy-MM-dd"
        return formatter.date(from: text)
    }

    /// Exports what History shows to `historyCSVFile`, as its Export button does to the file the
    /// user picks. The output path is fixed for the same reason as `statusItemFile`'s.
    private static func exportHistory() {
        guard let query = HistoryWindow.shared.model?.query else {
            NSLog("soroband-debug: export-history needs the History window open")
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: historyCSVFile)
        let rows = Core.exportCSV(query, to: historyCSVFile)
        NSLog("soroband-debug: exported %d rows to %@", rows ?? -1, historyCSVFile.path)
    }

    /// `open-settings?tab=networks` opens Settings on a tab (`general` unless given).
    private static func openSettings(_ url: URL) {
        let name = queryItems(url)["tab"] ?? SettingsView.Tab.general.rawValue
        guard let tab = SettingsView.Tab(rawValue: name) else {
            NSLog("soroband-debug: unknown settings tab in %@", url.absoluteString)
            return
        }
        SettingsWindow.shared.show(tab: tab)
    }

    private static func queryItems(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
    }

    /// Renders the menu bar item to `statusItemFile`. The item may sit behind the notch on a
    /// crowded menu bar, where `screencapture` cannot see it. The output path is fixed because any
    /// app or web page can open a `soroband-debug://` URL.
    private static func captureStatusItem() {
        guard let view = MenuBarController.shared.buttonView,
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else {
            NSLog("soroband-debug: capture-status-item found no status item")
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        write(bitmap, background: NSColor(white: 0.15, alpha: 1), to: statusItemFile)
    }

    /// `capture-window?number=<window number>` renders that window's content, as the app draws
    /// it, to `windowFile`: for windows `screencapture` cannot see (behind the notch, or a
    /// popover). The output path is fixed for the same reason as `statusItemFile`'s.
    private static func captureWindow(_ url: URL) {
        guard let number = queryItems(url)["number"].flatMap(Int.init),
            let view = NSApp.windows.first(where: { $0.windowNumber == number })?.contentView?.superview,
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else {
            NSLog("soroband-debug: capture-window found no window for %@", url.absoluteString)
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        write(bitmap, background: NSColor(white: 0.12, alpha: 1), to: windowFile)
    }

    /// Writes `bitmap` over `background` as PNG: the status item and popovers draw on
    /// transparent windows.
    private static func write(_ bitmap: NSBitmapImageRep, background: NSColor, to file: URL) {
        let pixels = NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        let image = NSImage(size: pixels, flipped: false) { rect in
            background.setFill()
            rect.fill()
            bitmap.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            return true
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let png = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?
                .representation(using: .png, properties: [:])
            try png?.write(to: file, options: .atomic)
        } catch {
            NSLog("soroband-debug: cannot write %@: %@", file.path, String(describing: error))
        }
    }

    static func writeState() {
        write(DebugState.current(), to: stateFile)
    }

    private static func write(_ state: some Encodable, to file: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(state).write(to: file, options: .atomic)
        } catch {
            NSLog("soroband-debug: cannot write state: %@", String(describing: error))
        }
    }
}

/// What the running app shows, as printed by `soroband debug state --json`.
struct DebugState: Encodable {
    struct Window: Encodable {
        let number: Int
        let kind: String
        let title: String
        let visible: Bool
        /// Frame in `screencapture -R` coordinates: points, origin at the top left of the main display.
        let rect: Rect
    }

    struct Rect: Encodable {
        let x, y, width, height: Double
    }

    struct Engine: Encodable {
        let state: EngineStatus.State
        let flows: Int
        let apps: Int
        let appBytes: Bytes
        let interfaceBytes: Bytes
        let check: EngineStatus.Check
    }

    struct Bytes: Encodable {
        let received, sent: UInt64

        init(_ bytes: EngineStatus.Bytes) {
            received = bytes.rx
            sent = bytes.tx
        }
    }

    struct Network: Encodable {
        let id: Int64
        let key: String
        let name: String
        let kind: NetworkKind
        let simulated: Bool
    }

    struct MenuBar: Encodable {
        let mode: String
        let count: String
        let symbol: String?
        let text: String?
    }

    struct Today: Encodable {
        /// ISO 8601, local time zone.
        let start: String
        let resetHour: Int
        /// The network the core books to; matches `network.id` once the switch is done.
        let networkID: Int64
        let networkApps: Bytes
        let networkInterfaces: Bytes
        let allApps: Bytes
        let allInterfaces: Bytes
        /// Bytes per second across the interfaces between the last two polls.
        let speed: Bytes
    }

    struct LaunchAtLoginState: Encodable {
        let isOn: Bool
        let note: String?
    }

    let pid: Int32
    let bundleIdentifier: String
    let coreVersion: String
    let menuBarText: String
    let menuBar: MenuBar
    let popoverShown: Bool
    /// The open Settings tab; nil while Settings is closed.
    let settingsTab: String?
    /// The History process, while it runs (`soroband debug history --json` asks it).
    let historyProcess: Int32?
    let launchAtLogin: LaunchAtLoginState
    let location: String
    let engine: Engine
    let network: Network?
    let today: Today
    let dataDirectory: String
    let windows: [Window]

    @MainActor
    static func current() -> DebugState {
        let mainDisplayHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let engine = Core.engine
        return DebugState(
            pid: ProcessInfo.processInfo.processIdentifier,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
            coreVersion: Core.version,
            menuBarText: MenuBarController.shared.display?.text ?? "",
            menuBar: MenuBar(
                mode: Usage.shared.menuBarMode.rawValue,
                count: Usage.shared.menuBarCount.rawValue,
                symbol: MenuBarController.shared.display?.symbol,
                text: MenuBarController.shared.display?.text),
            popoverShown: MenuBarController.shared.isPopoverShown,
            settingsTab: SettingsWindow.shared.window == nil ? nil : SettingsWindow.shared.tab.rawValue,
            historyProcess: HistoryProcess.processIdentifier,
            launchAtLogin: LaunchAtLoginState(
                isOn: LaunchAtLogin.shared.state.isOn, note: LaunchAtLogin.shared.state.note),
            location: LocationAccess.shared.statusName,
            engine: Engine(
                state: engine.state, flows: engine.flows, apps: engine.apps,
                appBytes: Bytes(engine.appBytes), interfaceBytes: Bytes(engine.interfaceBytes),
                check: engine.check),
            network: NetworkMonitor.shared.current.map { network in
                Network(
                    id: network.id, key: network.key, name: network.name, kind: network.kind,
                    simulated: NetworkMonitor.shared.simulated != nil)
            },
            today: Today(
                start: Date.ISO8601FormatStyle(timeZone: .current).format(engine.todayStart),
                resetHour: engine.resetHour,
                networkID: engine.networkID,
                networkApps: Bytes(engine.todayNetworkApps),
                networkInterfaces: Bytes(engine.todayNetworkInterfaces),
                allApps: Bytes(engine.todayApps),
                allInterfaces: Bytes(engine.todayInterfaces),
                speed: Bytes(engine.speed)),
            dataDirectory: Core.dataDirectory.path,
            windows: windows())
    }

    /// Every window of this process, in `screencapture -R` coordinates.
    @MainActor
    static func windows() -> [Window] {
        let mainDisplayHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return NSApp.windows.map { window in
            let frame = window.frame
            return Window(
                number: window.windowNumber,
                kind: String(describing: type(of: window)),
                title: window.title,
                visible: window.isVisible,
                rect: Rect(
                    x: frame.minX, y: mainDisplayHeight - frame.maxY,
                    width: frame.width, height: frame.height))
        }
    }
}

/// What the History process shows, as printed by `soroband debug history --json`.
struct HistoryState: Encodable {
    let pid: Int32
    let range: String
    /// nil for every network.
    let network: Int64?
    /// ISO 8601, local time zone.
    let start: String
    let end: String
    let step: String
    let total: DebugState.Bytes
    /// Bars with bytes, and apps listed.
    let bars: Int
    let apps: Int
    let expandedApp: String?
    /// From the click in the menu bar app to a drawn window with its data.
    let openMilliseconds: Double?
    let windows: [DebugState.Window]

    @MainActor
    static func current() -> HistoryState {
        let model = HistoryWindow.shared.model
        let iso = Date.ISO8601FormatStyle(timeZone: .current)
        return HistoryState(
            pid: ProcessInfo.processInfo.processIdentifier,
            range: model?.range.rawValue ?? "",
            network: model?.network,
            start: model.map { iso.format($0.content.interval.start) } ?? "",
            end: model.map { iso.format($0.content.interval.end) } ?? "",
            step: model?.query.step.rawValue ?? "",
            total: DebugState.Bytes(model?.content.total ?? .zero),
            bars: Set(model?.content.bars.map(\.start) ?? []).count,
            apps: model?.content.apps.count ?? 0,
            expandedApp: model?.expandedApp,
            openMilliseconds: HistoryWindow.shared.openDuration.map { $0 * 1000 },
            windows: DebugState.windows())
    }
}
#endif
