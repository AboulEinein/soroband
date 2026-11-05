import AppKit
import UserNotifications

/// The island, in the menu bar process: a transparent panel over the notch of each display it
/// shows on, the moment queue, and the moments' sources: the engine's (`Core.moments()`, after
/// each poll), the pointer on the notch (peek), and the current network (the hotspot meter).
///
/// With the island off nothing is drawn and no panel exists; the engine still watches for alerts
/// when they go out as notifications instead.
@MainActor
final class IslandController {
    static let shared = IslandController()

    private(set) var settings = IslandSettings()
    private var queue = MomentQueue()
    private var panels: [IslandPanel] = []
    private var timer: Task<Void, Never>?
    private var peekWait: Task<Void, Never>?
    private var started = false
    /// What the panels show, so a poll redraws only what changed.
    private var shown: Shown = .rest
    /// An app in front is full screen on the island's display.
    private(set) var fullScreen = false
    /// The latest moments and where each came from, for `soroband debug state`.
    private(set) var recent: [(kind: MomentKind, source: String, at: Date)] = []

    private enum Shown: Equatable {
        case rest
        case glance(today: UInt64, speed: UInt64)
        case moment(Moment)
    }

    /// Apps quit by Pause until off hotspot, reopened on the next network that is not one.
    private static let pausedKey = "pausedApps"

    func start() {
        guard !started else { return }
        started = true
        reloadSettings()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let path = app?.bundleURL?.path
            MainActor.assumeIsolated {
                Core.setFrontmost(path)
                IslandController.shared.checkFullScreen()
            }
        }
        center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { IslandController.shared.checkFullScreen() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { IslandController.shared.makePanels() }
        }
        Core.setFrontmost(NSWorkspace.shared.frontmostApplication?.bundleURL?.path)
    }

    /// Rereads the island's settings, after `soroband config set` or a change in Settings.
    func reloadSettings() {
        guard started else { return }
        let old = settings
        settings = IslandSettings(value: Core.setting)
        if settings != old { UIProcess.shared.publish() }
        Core.watchMoments(settings.watches)
        for kind in MomentKind.allCases where !settings.shows(kind) {
            queue.remove(kind, now: now)
        }
        if settings.enabled != old.enabled || settings.displays != old.displays || (settings.enabled && panels.isEmpty)
        {
            makePanels()
        } else {
            render(force: settings.style != old.style)
        }
    }

    /// After each poll: takes the engine's moments and refreshes the numbers on the island.
    func polled() {
        guard started else { return }
        let moments = settings.watches ? Core.moments() : []
        if !moments.isEmpty {
            registry = nil
            let current = NetworkMonitor.shared.current
            let named = { (id: Int64) -> Network? in
                if let current, current.id == id { return current }
                if self.registry == nil { self.registry = Core.networks() }
                return self.registry?.first { $0.id == id }.map {
                    Network(id: $0.id, key: $0.key, name: $0.name, kind: $0.kind)
                }
            }
            for moment in moments {
                guard let content = moment.content(network: named, current: current) else { continue }
                post(content, source: "engine")
            }
        }
        refreshNumbers()
    }

    /// Shows `content` on the island, or as a notification while the island is off.
    func post(_ content: MomentContent, source: String) {
        let kind = content.kind
        if settings.notifies(kind) {
            notify(content)
            record(kind, source: source)
            return
        }
        guard settings.shows(kind) else { return }
        if queue.post(content, now: now) { record(kind, source: source) }
        render()
    }

    /// The network changed: reopens paused apps once off a hotspot, and shows or hides the
    /// hotspot meter.
    func networkChanged() {
        guard started else { return }
        registry = nil
        if NetworkMonitor.shared.current?.kind != .hotspot { resumePaused() }
        render()
    }

    // MARK: Panels

    private func makePanels() {
        for panel in panels { panel.close() }
        panels = []
        guard settings.enabled else {
            shown = .rest
            return
        }
        let screens = NSScreen.screens.filter { settings.displays == .all || Self.isBuiltIn($0) }
        panels = screens.map { screen in
            let panel = IslandPanel(screen: screen)
            panel.island.onHover = { inside in IslandController.shared.hover(inside) }
            return panel
        }
        shown = .rest
        checkFullScreen()
        render(force: true)
    }

    private static func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else {
            return false
        }
        return CGDisplayIsBuiltin(number) != 0
    }

    /// Draws the queue's moment, the hotspot meter, or the island at rest, on every panel.
    private func render(force: Bool = false) {
        queue.advance(now: now)
        schedule()
        let next: Shown
        if let moment = queue.current {
            next = .moment(moment)
        } else if showsGlance {
            let status = Usage.shared.status
            next = .glance(today: status.todayNetworkInterfaces.total, speed: status.speed.rx)
        } else {
            next = .rest
        }
        let visible = isVisible(next)
        for panel in panels { panel.setVisible(visible) }
        guard force || next != shown else { return }
        let previous = shown
        shown = next
        for panel in panels {
            draw(next, previous: previous, on: panel.island)
        }
    }

    private func draw(_ next: Shown, previous: Shown, on island: IslandView) {
        let geometry = island.geometry
        switch next {
        case .rest:
            island.show(.rest(geometry), view: nil)
        case .glance(let today, let speed):
            let style = settings.style
            let metrics = IslandMetrics.glance(geometry, style: style)
            let color = NetworkMonitor.shared.current.map { networkColor($0.id) } ?? .white
            let view =
                style == .seamless
                ? MomentViews.glance(
                    today: today, speed: speed, color: color, notchWidth: geometry.notchWidth, wing: IslandMetrics.wing)
                : MomentViews.glance(
                    today: today, speed: speed, color: color, notchWidth: 18, wing: (metrics.width - 18) / 2)
            if case .glance = previous {
                island.replace(with: view)
            } else {
                island.show(metrics, view: view, inBand: style == .seamless)
            }
        case .moment(let moment):
            let view = MomentViews.view(moment.content, context: context)
            if case .moment(let old) = previous, old.id == moment.id {
                island.replace(with: view)
            } else {
                island.show(.open(moment.kind, geometry, style: settings.style), view: view)
            }
        }
    }

    private var showsGlance: Bool {
        settings.shows(.hotspot) && NetworkMonitor.shared.current?.kind == .hotspot
    }

    /// Full screen hides the island, or all of it but alerts, as `island_full_screen` says.
    private func isVisible(_ shown: Shown) -> Bool {
        guard fullScreen else { return true }
        switch settings.fullScreen {
        case .all: return true
        case .hide: return false
        case .alerts:
            if case .moment(let moment) = shown { return moment.kind.isAlert }
            return false
        }
    }

    private var context: MomentViews.Context {
        MomentViews.Context(
            offersPause: settings.offersPause && NetworkMonitor.shared.current?.kind == .hotspot,
            color: { [weak self] id in self?.networkColor(id) ?? .systemBlue },
            act: { action in IslandController.shared.perform(action) })
    }

    /// The registry the island's colors come from, read when first needed after a network change.
    private var registry: [RegisteredNetwork]?

    private func networkColor(_ id: Int64) -> NSColor {
        if registry == nil { registry = Core.networks() }
        let registry = self.registry ?? []
        guard let index = registry.firstIndex(where: { $0.id == id }) else { return NetworkColor.nsColor(slot: 0) }
        return NetworkColor.nsColor(slot: NetworkColor.slot(for: registry[index], index: index))
    }

    /// The open peek and the hotspot meter follow each poll's numbers; nothing else changes.
    private func refreshNumbers() {
        switch shown {
        case .glance:
            render()
        case .moment(let moment) where moment.kind == .peek:
            if let content = peekContent(), content != moment.content {
                queue.update(content)
                render()
            }
        default:
            break
        }
    }

    // MARK: Timing

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// One timer, to the queue's next change.
    private func schedule() {
        timer?.cancel()
        guard let at = queue.nextChange else { return }
        let delay = max(0, at - now)
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.render()
        }
    }

    // MARK: Pointer

    private func hover(_ inside: Bool) {
        queue.hover(inside, now: now)
        peekWait?.cancel()
        if inside, queue.current == nil, settings.shows(.peek) {
            // Passing the pointer by does nothing: the peek opens after it rests 0.4 s.
            peekWait = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, !Task.isCancelled, self.queue.hovering, self.queue.current == nil,
                    let content = self.peekContent()
                else { return }
                self.post(content, source: "hover")
            }
        }
        render()
    }

    private func peekContent() -> MomentContent? {
        let status = Usage.shared.status
        return .peek(
            network: NetworkMonitor.shared.current, today: status.todayNetworkInterfaces.total,
            down: status.todayNetworkInterfaces.rx, up: status.todayNetworkInterfaces.tx, speed: status.speed.rx,
            apps: Core.topApps())
    }

    // MARK: Full screen

    /// Whether the app in front has a window covering the whole of a display the island is on,
    /// as a full-screen app's does (the menu bar is hidden over it).
    func checkFullScreen() {
        guard !panels.isEmpty, let front = NSWorkspace.shared.frontmostApplication else {
            setFullScreen(false)
            return
        }
        let windows =
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let screens = panels.compactMap(\.screen).map(\.frame)
        let main = NSScreen.screens.first?.frame ?? .zero
        let covers = windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == front.processIdentifier,
                (window[kCGWindowLayer as String] as? Int) == 0,
                let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                let rect = CGRect(dictionaryRepresentation: bounds)
            else { return false }
            // Window bounds have their origin at the top left of the main display.
            let frame = CGRect(x: rect.minX, y: main.maxY - rect.maxY, width: rect.width, height: rect.height)
            return screens.contains { $0 == frame }
        }
        setFullScreen(covers)
    }

    private func setFullScreen(_ value: Bool) {
        guard value != fullScreen else { return }
        fullScreen = value
        render()
    }

    // MARK: Actions

    private func perform(_ action: MomentAction) {
        queue.dismiss(now: now)
        render()
        switch action {
        case .pause(let app):
            pause(app)
        case .ignore(let app):
            var ignored = settings.ignoredApps
            if !ignored.contains(app.id) { ignored.append(app.id) }
            if Core.setSetting(IslandSettings.ignoredAppsKey, to: IslandSettings.ignoredValue(ignored)) {
                Core.reloadSettings()
                reloadSettings()
            }
        case .details(let app):
            let options = HistoryOptions(
                range: .day, current: NetworkMonitor.shared.current?.id, requested: .now, expandedApp: app.id)
            UIProcess.shared.send(.showHistory(arguments: options.arguments, replacing: true))
        }
    }

    /// Quits the app, to open it again on the next network that is not a hotspot.
    private func pause(_ app: MomentApp) {
        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == app.id }
        guard !running.isEmpty else { return }
        for instance in running { instance.terminate() }
        var paused = UserDefaults.standard.stringArray(forKey: Self.pausedKey) ?? []
        if !paused.contains(app.id) { paused.append(app.id) }
        UserDefaults.standard.set(paused, forKey: Self.pausedKey)
    }

    private func resumePaused() {
        guard let paused = UserDefaults.standard.stringArray(forKey: Self.pausedKey), !paused.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: Self.pausedKey)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        for path in paused {
            NSWorkspace.shared.openApplication(at: URL(filePath: path), configuration: configuration)
        }
    }

    // MARK: Notifications

    private func notify(_ content: MomentContent) {
        let center = UNUserNotificationCenter.current()
        let body: (title: String, text: String)
        switch content {
        case .hog(let app, let bytes, let minutes, let network):
            body = ("\(app.name) used \(Format.bytes(bytes)) in \(minutes) min", network.map { "On \($0.name)" } ?? "")
        case .background(let app, let bytes, let uploading):
            body = (
                "\(app.name) · background \(uploading ? "upload" : "download")",
                "\(Format.bytes(bytes)) while not in front"
            )
        default:
            return
        }
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let note = UNMutableNotificationContent()
            note.title = body.title
            note.body = body.text
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: note, trigger: nil))
        }
    }

    private func record(_ kind: MomentKind, source: String) {
        recent.append((kind, source, .now))
        if recent.count > 20 { recent.removeFirst() }
    }

    // MARK: Debug

    #if DEBUG
    struct DebugState: Encodable {
        struct Fired: Encodable {
            let kind: String
            /// `engine` (real traffic or a network change), `hover`, or `debug` (`fire-moment`).
            let source: String
            let at: Double
        }

        let enabled: Bool
        let style: String
        /// `rest`, `glance` (the hotspot meter) or the open moment's kind.
        let showing: String
        let waiting: [String]
        let fullScreen: Bool
        /// The island's panels' window numbers; their frames are in `windows`.
        let panels: [Int]
        let recent: [Fired]
    }

    /// What the island shows, for `soroband debug state`.
    var debugState: DebugState {
        let showing: String =
            switch shown {
            case .rest: "rest"
            case .glance: "glance"
            case .moment(let moment): moment.kind.rawValue
            }
        return DebugState(
            enabled: settings.enabled, style: settings.style.rawValue, showing: showing,
            waiting: queue.waiting.map(\.kind.rawValue), fullScreen: fullScreen,
            panels: panels.map(\.windowNumber),
            recent: recent.map { .init(kind: $0.kind.rawValue, source: $0.source, at: $0.at.timeIntervalSince1970) })
    }

    /// `soroband-debug://hover-island`: the pointer at `point` on the first panel (in the
    /// island view's coordinates), or off it with nil.
    func debugHover(at point: CGPoint?) {
        panels.first?.island.pointer(at: point)
    }

    /// The first panel's island view, for captures and the hover command's coordinates.
    var debugIsland: IslandView? { panels.first?.island }
    #endif
}

/// A transparent, borderless, non-activating panel over the top of a display, holding the island.
/// Its transparent pixels pass clicks through, so it can lie over the menu bar; it never takes
/// the keyboard.
@MainActor
final class IslandPanel: NSPanel {
    let island: IslandView

    init(screen: NSScreen) {
        let geometry = IslandGeometry(screen: screen)
        let size = CGSize(width: IslandMetrics.panelWidth, height: geometry.menuBarHeight + IslandMetrics.panelDepth)
        let frame = CGRect(
            x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width,
            height: size.height)
        island = IslandView(frame: CGRect(origin: .zero, size: size), geometry: geometry)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        contentView = island
        orderFrontRegardless()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        if visible { orderFrontRegardless() } else { orderOut(nil) }
    }
}
