#if DEBUG
import AppKit
import notify

/// Lets an agent drive and observe a Debug build without a mouse.
///
/// - `open -g -a <this build's Soroband.app> "soroband-debug://<command>"` runs a command (see
///   `handle`); without `-g` macOS brings the app to the front, taking the user's keyboard.
/// - `soroband debug state --json` posts `dumpStateNotification`; the menu bar process answers by
///   writing its state and the UI process's to `stateFile`. `soroband debug history --json` asks
///   the UI process for History (`dumpHistoryNotification`, `historyFile`). The names must match
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
    /// The menu bar process tells the UI process to export what History shows.
    static let exportHistoryNotification = "io.github.abouleinein.soroband.debug.export-history"

    private static var token: Int32 = 0
    private static var exportToken: Int32 = 0

    static func start() {
        notify_register_dispatch(dumpStateNotification, &token, .main) { _ in
            MainActor.assumeIsolated { writeState() }
        }
    }

    /// The UI process answers `soroband debug history --json` and `export-history`.
    static func startUI() {
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
        case "close-settings": UIProcess.shared.send(.closeSettings)
        case "open-history": openHistory(url)
        case "close-history": UIProcess.shared.send(.closeHistory)
        case "export-history": requestHistoryExport()
        case "open-onboarding": UIProcess.shared.send(.showOnboarding)
        case "quit-ui": UIProcess.shared.stop()
        case "capture-status-item": captureStatusItem()
        case "capture-window": captureWindow(url)
        case "simulate-network": simulateNetwork(url)
        case "update-network": updateNetwork(url)
        case "fire-moment": fireMoment(url)
        case "hover-island": hoverIsland(url)
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

    /// `fire-moment?kind=hog` shows a moment with sample numbers, as if the engine had found it
    /// (`peek`, `joined`, `left`, `hog`, `background`, `transfer`, `recap`); `done=1` ends a
    /// transfer. Real traffic fires them through the engine; this is for captures.
    private static func fireMoment(_ url: URL) {
        let query = queryItems(url)
        let network = NetworkMonitor.shared.current ?? Network(id: 0, key: "", name: "Office", kind: .wifi)
        let app = MomentApp(id: "/System/Applications/Music.app", name: "Music")
        let mb: UInt64 = 1_000_000
        let content: MomentContent
        switch MomentKind(rawValue: query["kind"] ?? "") {
        case .peek:
            content = .peek(
                network: network, today: 1_400 * mb, down: 1_190 * mb, up: 210 * mb, speed: 1_200_000,
                apps: [
                    MomentApp(id: "/Applications/Safari.app", name: "Safari", bytes: 620 * mb),
                    MomentApp(id: app.id, name: app.name, bytes: 410 * mb),
                    MomentApp(id: "/System/Applications/Mail.app", name: "Mail", bytes: 96 * mb),
                ])
        case .joined: content = .joined(network: network, week: 1_200 * mb, today: 412 * mb, lastSeen: .now - 86_400)
        case .left:
            content = .left(
                network: network, since: .now - 4_320, bytes: 318 * mb,
                top: MomentApp(id: "/Applications/Safari.app", name: "Safari", bytes: 120 * mb))
        case .hog: content = .hog(app: app, bytes: 214 * mb, minutes: 5, network: network)
        case .background:
            content = .background(
                app: MomentApp(id: "/System/Applications/Mail.app", name: "Mail"), bytes: 86 * mb, uploading: false)
        case .transfer:
            content = .transfer(
                app: MomentApp(id: "/Applications/Safari.app", name: "Safari"), via: "App Store", bytes: 640 * mb,
                rate: 12_400_000, done: query["done"] == "1")
        case .recap: content = .recap(bytes: 2_100 * mb, networks: 2, top: app)
        case .hotspot, nil:
            NSLog("soroband-debug: fire-moment needs a kind in %@", url.absoluteString)
            return
        }
        IslandController.shared.post(content, source: "debug")
    }

    /// `hover-island?at=notch` puts the pointer, for the island, on the middle of the notch;
    /// `hover-island?x=280&y=10` at a point in the island's view (origin at its bottom left);
    /// `hover-island` alone takes it away. The real pointer does not move.
    private static func hoverIsland(_ url: URL) {
        let query = queryItems(url)
        guard let island = IslandController.shared.debugIsland else { return }
        if query["at"] == "notch" {
            let bounds = island.bounds
            IslandController.shared.debugHover(
                at: CGPoint(x: bounds.midX, y: bounds.maxY - island.geometry.menuBarHeight / 2))
        } else if let x = query["x"].flatMap(Double.init), let y = query["y"].flatMap(Double.init) {
            IslandController.shared.debugHover(at: CGPoint(x: x, y: y))
        } else {
            IslandController.shared.debugHover(at: nil)
        }
    }

    /// `update-network?name=Desk&kind=ethernet` renames the current network and sets its kind, as
    /// the Networks settings do; `color=3` picks its palette slot, `color=auto` clears the pick.
    private static func updateNetwork(_ url: URL) {
        let query = queryItems(url)
        guard let current = NetworkMonitor.shared.current else { return }
        if let color = query["color"] {
            guard color == "auto" || Int(color).map(NetworkColor.slots.indices.contains) == true else {
                NSLog("soroband-debug: unknown color in %@", url.absoluteString)
                return
            }
            Usage.shared.setNetworkColor(id: current.id, color: Int(color))
            if query["name"] == nil, query["kind"] == nil { return }
        }
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
        MenuBarController.shared.showPopover(tab: tab.rawValue, allNetworks: query["all"] == "1")
    }

    /// `open-history?range=year&network=2&date=2026-10-15&app=<app id>&hover=2026-10-18T09:00`
    /// opens History in the UI process (Month, every network, today unless given) and, for
    /// captures, expands an app and holds the chart's hover on a time. A History already open is
    /// replaced.
    private static func openHistory(_ url: URL) {
        let query = queryItems(url)
        guard let range = HistoryRange(rawValue: query["range"] ?? "month") else {
            NSLog("soroband-debug: unknown history range in %@", url.absoluteString)
            return
        }
        let options = HistoryOptions(
            range: range, date: query["date"].flatMap(localDate), network: query["network"].flatMap(Int64.init),
            current: NetworkMonitor.shared.current?.id, requested: .now, expandedApp: query["app"],
            hover: query["hover"].flatMap(localDate))
        UIProcess.shared.send(.showHistory(arguments: options.arguments, replacing: true))
    }

    /// `2026-10-15` or `2026-10-15T09:00`, in the local time zone.
    private static func localDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = text.contains("T") ? "yyyy-MM-dd'T'HH:mm" : "yyyy-MM-dd"
        return formatter.date(from: text)
    }

    /// Asks the UI process to export what History shows to `file` (`historyCSVFile`), deleting the
    /// last export first, so an export that writes nothing (no History open, no UI process) leaves
    /// no file to be read as this one. `post` is the notification, or a stand-in in tests.
    static func requestHistoryExport(
        to file: URL = historyCSVFile, post: () -> Void = { notify_post(exportHistoryNotification) }
    ) {
        try? FileManager.default.removeItem(at: file)
        post()
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
        HistoryWindow.shared.export(
            query, to: historyCSVFile,
            done: { rows in
                NSLog("soroband-debug: exported %d rows to %@", rows ?? -1, historyCSVFile.path)
            })
    }

    /// `open-settings?tab=networks` opens Settings on a tab (`general` unless given).
    private static func openSettings(_ url: URL) {
        let name = queryItems(url)["tab"] ?? SettingsView.Tab.general.rawValue
        guard let tab = SettingsView.Tab(rawValue: name) else {
            NSLog("soroband-debug: unknown settings tab in %@", url.absoluteString)
            return
        }
        UIProcess.shared.send(.showSettings(tab: tab.rawValue))
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
    /// popover). A window of the UI process is rendered there. The output path is fixed for the
    /// same reason as `statusItemFile`'s. The last capture is deleted first, so a capture that
    /// finds no window leaves no file to be read as this one.
    private static func captureWindow(_ url: URL) {
        try? FileManager.default.removeItem(at: windowFile)
        guard let number = queryItems(url)["number"].flatMap(Int.init) else {
            NSLog("soroband-debug: capture-window needs a window number in %@", url.absoluteString)
            return
        }
        switch captureTarget(
            number: number, here: NSApp.windows.map(\.windowNumber), uiProcessRuns: UIProcess.shared.phase != .stopped)
        {
        case .here: captureWindow(number: number)
        case .uiProcess: UIProcess.shared.send(.captureWindow(number: number))
        case .none: NSLog("soroband-debug: capture-window found no window %d", number)
        }
    }

    enum CaptureTarget: Equatable {
        case here, uiProcess, none
    }

    /// Which process renders window `number`: this one if it has it, else the UI process while one
    /// runs, else none.
    nonisolated static func captureTarget(number: Int, here: [Int], uiProcessRuns: Bool) -> CaptureTarget {
        if here.contains(number) { return .here }
        return uiProcessRuns ? .uiProcess : .none
    }

    static func captureWindow(number: Int) {
        guard let view = NSApp.windows.first(where: { $0.windowNumber == number })?.contentView?.superview,
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else {
            NSLog("soroband-debug: capture-window found no window %d", number)
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

    /// Writes the menu bar process's state with the UI process's, once it has answered.
    static func writeState() {
        UIProcess.shared.debugState { json in
            var ui = json.flatMap { try? JSONDecoder().decode(UIState.self, from: Data($0.utf8)) }
            ui?.lingering = UIProcess.shared.isLingering
            write(DebugState.current(ui: ui), to: stateFile)
        }
    }

    /// The UI process's part of `soroband debug state`, as JSON.
    static func uiState() -> String {
        let data = (try? JSONEncoder().encode(UIState.current())) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
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
    struct Window: Codable {
        let number: Int
        let kind: String
        let title: String
        let visible: Bool
        /// Frame in `screencapture -R` coordinates: points, origin at the top left of the main display.
        let rect: Rect
    }

    struct Rect: Codable {
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
        let scope: String
        /// As `menu_bar_readings` stores them.
        let readings: String
        let style: String
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
        /// Bytes per second across the interfaces, less the local-network bytes, between the last two polls.
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
    /// The UI process, while it runs; it holds the popover, Settings, History and Welcome windows.
    let uiProcess: UIState?
    let launchAtLogin: LaunchAtLoginState
    let location: String
    let engine: Engine
    let network: Network?
    let today: Today
    let island: IslandController.DebugState
    let dataDirectory: String
    let windows: [Window]

    @MainActor
    static func current(ui: UIState?) -> DebugState {
        let engine = Core.engine
        return DebugState(
            pid: ProcessInfo.processInfo.processIdentifier,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
            coreVersion: Core.version,
            menuBarText: MenuBarController.shared.display?.text ?? "",
            menuBar: MenuBar(
                scope: Usage.shared.menuBarLayout.scope.rawValue,
                readings: Usage.shared.menuBarLayout.readingsValue,
                style: Usage.shared.menuBarLayout.style.rawValue,
                symbol: MenuBarController.shared.display?.symbol,
                text: MenuBarController.shared.display?.text),
            popoverShown: ui?.popoverShown ?? false,
            settingsTab: ui?.settingsTab,
            uiProcess: ui,
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
            island: IslandController.shared.debugState,
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

/// What the UI process shows, in `soroband debug state --json`'s `uiProcess`.
struct UIState: Codable {
    let pid: Int32
    let popoverShown: Bool
    /// From the click in the menu bar process to the popover drawn, at its last opening.
    let popoverOpenMilliseconds: Double?
    /// The open Settings tab; nil while Settings is closed.
    let settingsTab: String?
    let historyShown: Bool
    let welcomeShown: Bool
    /// Whether it waits to quit, with no window open; the menu bar process, which runs the linger,
    /// fills it in.
    var lingering: Bool
    let windows: [DebugState.Window]

    @MainActor
    static func current() -> UIState {
        UIState(
            pid: ProcessInfo.processInfo.processIdentifier,
            popoverShown: PopoverController.shared.isShown,
            popoverOpenMilliseconds: PopoverController.shared.openDuration.map { $0 * 1000 },
            settingsTab: SettingsWindow.shared.window == nil ? nil : SettingsWindow.shared.tab.rawValue,
            historyShown: HistoryWindow.shared.window != nil,
            welcomeShown: OnboardingWindow.shared.window != nil,
            lingering: false,
            windows: DebugState.windows())
    }
}

/// What the History window shows, as printed by `soroband debug history --json`.
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
