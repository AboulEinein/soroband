import AppKit
import SwiftUI

/// The popover, in the UI process, under the menu bar item the menu bar process draws.
///
/// An `NSPopover` points at a view; the item lives in another process, so the popover points at a
/// transparent panel laid over the item, which lets every click through. The popover's view is
/// created when it opens and released when it closes, so nothing of it redraws while it is closed.
@MainActor
final class PopoverController: NSObject, NSPopoverDelegate {
    static let shared = PopoverController()

    private let popover = NSPopover()
    private var anchor: NSPanel?
    private var lastClose = Date.distantPast
    /// History draws once offscreen after the first popover, so History… opens without the first
    /// layout of SwiftUI and Charts in this process.
    private var warmedHistory = false
    /// From the click in the menu bar process to the popover's window on screen, as WindowServer
    /// reports it (its occlusion state turning visible), for `soroband debug state`.
    private(set) var openDuration: TimeInterval?
    private var occlusion: NSObjectProtocol?
    /// The app that had the keyboard before a click brought the popover forward; it gets it back
    /// when the popover closes.
    private var previousApp: NSRunningApplication?
    /// Whether the popover was the key window as its close began, and whether a mouse-down in
    /// another of this app's windows began it (`KeyboardReturn`).
    private var wasKeyAtClose = false
    private var clickInOtherWindowAtClose = false
    /// Closes the popover on a click in another app or on the menu bar, which a transient popover
    /// misses; installed only while it is shown.
    private var outsideClicks: Any?

    var isShown: Bool { popover.isShown }

    /// The theme's light or dark (`Theme.apply`), or nil for macOS's. Set on the popover itself,
    /// which does not take the app's appearance: its frame would stay macOS's around content in
    /// the theme's.
    var appearance: NSAppearance? {
        get { popover.appearance }
        set { popover.appearance = newValue }
    }

    override init() {
        super.init()
        popover.behavior = .transient
        popover.delegate = self
    }

    func toggle(_ request: PopoverRequest) {
        switch PopoverToggle.decide(isShown: popover.isShown, lastClose: lastClose, now: .now) {
        case .close: popover.performClose(nil)
        case .open: show(request)
        case .ignore: break
        }
    }

    /// Opens the popover on the request's tab, with the Apps tab's toggle set as it asks.
    func show(_ request: PopoverRequest) {
        guard !popover.isShown else { return }
        Usage.shared.isLive = true
        popover.contentViewController = makeContent(
            tab: PopoverView.Tab(rawValue: request.tab) ?? .apps, allNetworks: request.allNetworks)
        presentBuilt(request)
    }

    private func makeContent(tab: PopoverView.Tab, allNetworks: Bool) -> NSViewController {
        NSHostingController(
            rootView: LivePopover(
                tab: tab, allNetworks: allNetworks,
                openHistory: { [weak self] network in
                    HistoryWindow.shared.show(
                        HistoryOptions(
                            range: .month, network: network, current: NetworkMonitor.shared.current?.id,
                            requested: .now), activates: true)
                    self?.popover.performClose(nil)
                },
                openResource: { [weak self] measure in
                    HistoryWindow.shared.show(
                        HistoryOptions(
                            range: .day, measure: measure, current: NetworkMonitor.shared.current?.id,
                            requested: .now), activates: true)
                    self?.popover.performClose(nil)
                },
                openSettings: { [weak self] in
                    // Settings first, so it is key as the popover's close begins and keeps the keyboard.
                    SettingsWindow.shared.show(activates: true)
                    self?.popover.performClose(nil)
                },
                quit: { UIHost.send(.quit) }
            ).themed())
    }

    private func presentBuilt(_ request: PopoverRequest) {
        let view = anchorView(at: request.anchor)
        // The popover takes keys and clicks only once the app is active.
        if request.activates {
            let front = NSWorkspace.shared.frontmostApplication
            previousApp = front == .current ? nil : front
            // A click on the item in the menu bar's overflow reaches the menu bar process while it
            // is not active, so its yield gives nothing and `NSApp.activate()` is refused; this
            // call, deprecated but still honored, brings Soroband forward from the overflow too.
            NSApp.activate(ignoringOtherApps: true)
        }
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        let window = popover.contentViewController?.view.window
        if request.activates { window?.makeKey() }
        if let window { timeUntilOnScreen(window, from: request.requested) }
        // Clicks in this process's windows never reach a global monitor.
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            // An event for another app's window has no window here, so its location is on screen,
            // as the item's frame is; `NSEvent.mouseLocation` would be wherever the pointer is now.
            let location = event.locationInWindow
            MainActor.assumeIsolated {
                guard let self, Self.closesOnMouseDown(at: location, item: self.anchor?.frame) else {
                    return
                }
                self.popover.performClose(nil)
            }
        }
        UIHost.send(.popover(shown: true))
        UIHost.windowsChanged()
    }

    func close() {
        popover.performClose(nil)
    }

    private func timeUntilOnScreen(_ window: NSWindow, from requested: Date) {
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        occlusion = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, window.occlusionState.contains(.visible) else { return }
                self.openDuration = Date.now.timeIntervalSince(requested)
                if let occlusion = self.occlusion { NotificationCenter.default.removeObserver(occlusion) }
                self.occlusion = nil
            }
        }
    }

    /// Follows the menu bar item when it moves or changes width.
    func move(to rect: CGRect) {
        guard popover.isShown, let anchor, anchor.frame != rect, let view = anchor.contentView else { return }
        anchor.setFrame(rect, display: false)
        popover.positioningRect = view.bounds
    }

    private func anchorView(at rect: CGRect) -> NSView {
        let window =
            anchor
            ?? {
                // A non-activating panel, as a status item's window is: AppKit then lets the popover
                // become key and draw as active without this app in front, as a status item's
                // popover does. A plain window leaves it drawn inactive (its default button gray).
                let window = NSPanel(
                    contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                window.isOpaque = false
                window.backgroundColor = .clear
                window.hasShadow = false
                window.ignoresMouseEvents = true
                window.isReleasedWhenClosed = false
                window.level = .statusBar
                window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
                return window
            }()
        anchor = window
        window.setFrame(rect, display: false)
        window.orderFrontRegardless()
        return window.contentView!
    }

    /// Whether a mouse-down outside this process closes the popover: anywhere but on the menu bar
    /// item, whose own toggle closes it on the mouse-up. Closing on the item's mouse-down would let
    /// a press held past `PopoverToggle`'s 0.3 s reopen it on release.
    nonisolated static func closesOnMouseDown(at point: CGPoint, item: CGRect?) -> Bool {
        !(item?.contains(point) ?? false)
    }

    /// Set as the close starts, not after its animation, which can end after the click's toggle.
    func popoverWillClose(_ notification: Notification) {
        lastClose = .now
        let window = popover.contentViewController?.view.window
        wasKeyAtClose = window?.isKeyWindow == true
        let event = NSApp.currentEvent
        clickInOtherWindowAtClose = KeyboardReturn.isClickInOtherWindow(
            type: event?.type, inOtherWindow: event?.window != nil && event?.window !== window,
            age: ProcessInfo.processInfo.systemUptime - (event?.timestamp ?? 0))
    }

    func popoverDidShow(_ notification: Notification) {
        guard !warmedHistory else { return }
        warmedHistory = true
        HistoryWindow.shared.warmUp()
    }

    /// Gives the keyboard back to the app that had it when the popover opened, when
    /// `KeyboardReturn` says so.
    private func returnKeyboard() {
        defer { previousApp = nil }
        guard
            KeyboardReturn.givesBack(
                hasPreviousApp: previousApp != nil,
                sorobandIsFront: NSWorkspace.shared.frontmostApplication == .current, popoverWasKey: wasKeyAtClose,
                clickInOtherWindow: clickInOtherWindowAtClose)
        else { return }
        previousApp?.activate()
    }

    func popoverDidClose(_ notification: Notification) {
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
        returnKeyboard()
        popover.contentViewController = nil
        anchor?.orderOut(nil)
        AppIcons.clear()
        Usage.shared.isLive = false
        UIHost.send(.popover(shown: false))
        UIHost.windowsChanged()
    }
}

/// The popover's content, following `Usage` while it is open.
private struct LivePopover: View {
    var usage = Usage.shared
    var monitor = NetworkMonitor.shared
    var location = LocationAccess.shared
    /// Read from the database once the popover has drawn, and again on another network or hour.
    @State private var summary: PopoverSummary?
    @State var tab: PopoverView.Tab
    @State var allNetworks: Bool
    /// The measure the Resources tab lists today's apps by.
    @State private var measure = ResourceMeasure.cpu
    /// Today's resources per app, read when the Resources tab shows and again each minute, as
    /// the engine writes them.
    @State private var resourcesToday: ResourceHistoryData?
    /// Opens History on this month, on `network` or on every network when nil.
    let openHistory: (_ network: Int64?) -> Void
    /// Opens History on today's page of a resource.
    let openResource: (ResourceMeasure) -> Void
    let openSettings: () -> Void
    let quit: () -> Void

    /// The network History opens on, which the History card's numbers follow: the current one
    /// while the Apps tab shows only it, every network otherwise.
    private var historyNetwork: Int64? {
        allNetworks || tab == .networks ? nil : monitor.current?.id
    }

    var body: some View {
        PopoverView(
            content: PopoverContent.make(
                status: usage.status, today: usage.today, registry: usage.registry,
                current: monitor.current, connectedSince: monitor.connectedSince, allNetworks: allNetworks,
                locationAllowed: location.isAllowed, summary: summary),
            tab: $tab, allNetworks: $allNetworks,
            resources: resources, measure: $measure, openResource: openResource,
            openHistory: { openHistory(historyNetwork) },
            allowLocation: { location.allow() },
            openSettings: openSettings, quit: quit
        )
        .onChange(of: monitor.current) { usage.reloadRegistry() }
        .task(
            id: SummaryKey(
                network: usage.status.networkID, historyNetwork: historyNetwork, todayStart: usage.status.todayStart,
                hour: Int(Date.now.timeIntervalSince1970 / 3600))
        ) {
            guard usage.status.state != .starting else { return }
            let (network, history, todayStart) = (usage.status.networkID, historyNetwork, usage.status.todayStart)
            summary = await Task.detached(priority: .userInitiated) {
                PopoverSummary.load(network: network, historyNetwork: history, todayStart: todayStart)
            }.value
        }
        .task(id: resourcesKey) {
            guard let key = resourcesKey else { return }
            // Spans are whole hours: the day from today's start takes in the hour under way.
            let query = ResourceQuery(
                interval: DateInterval(
                    start: key.todayStart,
                    // A local day: 23 or 25 hours when the clocks change.
                    end: Calendar.current.date(byAdding: .day, value: 1, to: key.todayStart)
                        ?? key.todayStart.addingTimeInterval(86_400)),
                previous: nil, step: .hour,
                measure: key.measure)
            let answer = await Task.detached(priority: .userInitiated) { Core.resourceHistory(query) }.value
            // A newer read took this one's place while it ran: its answer is stale.
            guard !Task.isCancelled else { return }
            resourcesToday = answer
        }
        .onAppear {
            // macOS may reveal the Wi‑Fi name later than `refreshUntilNamed` looked for it.
            if location.isAllowed, monitor.current?.key.hasPrefix("wifi-router:") == true { monitor.refresh() }
        }
    }
}

extension LivePopover {
    /// The Resources tab, while a resource is shown.
    fileprivate var resources: PopoverResources? {
        guard !usage.resources.shown.isEmpty else { return nil }
        return PopoverResources.make(
            settings: usage.resources, gauges: usage.gauges, measure: measure, today: resourcesToday)
    }

    /// What today's resources depend on; nil while the tab is not shown.
    fileprivate var resourcesKey: ResourcesKey? {
        guard tab == .resources, let shown = resources?.measure, usage.status.state != .starting else { return nil }
        return ResourcesKey(
            measure: shown, todayStart: usage.status.todayStart, minute: Int(Date.now.timeIntervalSince1970 / 60))
    }
}

/// What today's resources in the popover depend on.
private struct ResourcesKey: Equatable {
    var measure: ResourceMeasure
    var todayStart: Date
    /// The engine writes its resources once a minute.
    var minute: Int
}

/// What the popover's summary depends on.
private struct SummaryKey: Equatable {
    var network: Int64
    var historyNetwork: Int64?
    var todayStart: Date
    /// A new hour stores the last one, which the summary then reads.
    var hour: Int
}
