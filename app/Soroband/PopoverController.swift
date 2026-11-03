import AppKit
import SwiftUI

/// The popover, in the UI process, under the menu bar item the menu bar process draws.
///
/// An `NSPopover` points at a view; the item lives in another process, so the popover points at a
/// transparent window laid over the item, which lets every click through. The popover's view is
/// created when it opens and released when it closes, so nothing of it redraws while it is closed.
@MainActor
final class PopoverController: NSObject, NSPopoverDelegate {
    static let shared = PopoverController()

    private let popover = NSPopover()
    private var anchor: NSWindow?
    private var lastClose = Date.distantPast
    /// History draws once offscreen after the first popover, so History… opens without the first
    /// layout of SwiftUI and Charts in this process.
    private var warmedHistory = false
    /// From the click in the menu bar process to the popover drawn, for `soroband debug state`.
    private(set) var openDuration: TimeInterval?

    var isShown: Bool { popover.isShown }

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
        popover.contentViewController = NSHostingController(
            rootView: LivePopover(
                tab: PopoverView.Tab(rawValue: request.tab) ?? .apps, allNetworks: request.allNetworks,
                openHistory: { [weak self] network in
                    HistoryWindow.shared.show(
                        HistoryOptions(
                            range: .month, network: network, current: NetworkMonitor.shared.current?.id,
                            requested: .now))
                    self?.popover.performClose(nil)
                },
                openSettings: { [weak self] in
                    self?.popover.performClose(nil)
                    SettingsWindow.shared.show()
                },
                quit: { UIHost.send(.quit) }))
        let view = anchorView(at: request.anchor)
        // The popover takes keys and clicks only once the app is active.
        NSApp.activate()
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        let window = popover.contentViewController?.view.window
        window?.makeKey()
        window?.displayIfNeeded()
        openDuration = Date.now.timeIntervalSince(request.requested)
        UIHost.send(.popover(shown: true))
        UIHost.windowsChanged()
    }

    func close() {
        popover.performClose(nil)
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
                let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
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

    /// Set as the close starts, not after its animation, which can end after the click's toggle.
    func popoverWillClose(_ notification: Notification) {
        lastClose = .now
    }

    func popoverDidShow(_ notification: Notification) {
        guard !warmedHistory else { return }
        warmedHistory = true
        HistoryWindow.shared.warmUp()
    }

    func popoverDidClose(_ notification: Notification) {
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
    /// Opens History on this month, on `network` or on every network when nil.
    let openHistory: (_ network: Int64?) -> Void
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
        .onAppear {
            // macOS may reveal the Wi‑Fi name later than `refreshUntilNamed` looked for it.
            if location.isAllowed, monitor.current?.key.hasPrefix("wifi-router:") == true { monitor.refresh() }
        }
    }
}

/// What the popover's summary depends on.
private struct SummaryKey: Equatable {
    var network: Int64
    var historyNetwork: Int64?
    var todayStart: Date
    /// A new hour stores the last one, which the summary then reads.
    var hour: Int
}
