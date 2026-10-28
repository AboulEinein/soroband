import AppKit
import SwiftUI

/// The menu bar item and its popover.
///
/// The item's icon and text change only when the displayed text does. The popover's view is
/// created when it opens and released when it closes, so nothing of it stays in memory or redraws
/// while it is closed.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    static let shared = MenuBarController()

    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var drawn: MenuBarDisplay.Drawn?
    var display: MenuBarDisplay? { drawn?.display }
    private var lastRedraw = Date.distantPast
    private var lastClose = Date.distantPast
    /// A redraw put off by `MenuBarDisplay.redrawDelay`.
    private var pendingRedraw: Task<Void, Never>?

    var isPopoverShown: Bool { popover.isShown }

    func start() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.imagePosition = .imageLeading
        // Digits of one width, so a changing count or speed does not shift the menu bar.
        item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        self.item = item
        popover.behavior = .transient
        popover.delegate = self
        Usage.shared.onChange = { [weak self] in self?.update() }
        update()
    }

    func update() {
        let usage = Usage.shared
        let display = MenuBarDisplay.make(
            mode: usage.menuBarMode, status: usage.status, kind: NetworkMonitor.shared.current?.kind)
        guard display != self.display, let button = item?.button else { return }
        let new = MenuBarDisplay.Drawn(
            display: display, mode: usage.menuBarMode, network: usage.status.networkID,
            total: MenuBarDisplay.total(mode: usage.menuBarMode, status: usage.status))
        let delay = MenuBarDisplay.redrawDelay(from: drawn, to: new, lastRedraw: lastRedraw, now: .now)
        if delay > 0 {
            // The latest numbers are read again when it fires.
            if pendingRedraw == nil {
                pendingRedraw = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    self?.pendingRedraw = nil
                    self?.update()
                }
            }
            return
        }
        pendingRedraw?.cancel()
        pendingRedraw = nil
        lastRedraw = .now
        drawn = new
        button.image = display.image()
        button.title = display.text.map { " \($0)" } ?? ""
        button.setAccessibilityLabel(display.accessibilityLabel())
    }

    @objc func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if Date.now.timeIntervalSince(lastClose) > 0.3 {
            // A transient popover closes on the mouse-down of a click on the item, before the
            // item's action runs; that click meant "close", not "open again".
            showPopover()
        }
    }

    /// Opens the popover on `tab`, with the Apps tab's toggle set to `allNetworks`.
    func showPopover(tab: PopoverView.Tab = .apps, allNetworks: Bool = false) {
        guard !popover.isShown, let button = item?.button else { return }
        Usage.shared.isLive = true
        HistoryProcess.prepare()
        popover.contentViewController = NSHostingController(
            rootView: LivePopover(
                tab: tab, allNetworks: allNetworks,
                openHistory: { [weak self] network in
                    // Before the close, which dismisses an unused standby process.
                    HistoryProcess.open(
                        HistoryOptions(
                            range: .month, network: network, current: NetworkMonitor.shared.current?.id))
                    self?.popover.performClose(nil)
                },
                openSettings: { [weak self] in
                    self?.popover.performClose(nil)
                    SettingsWindow.shared.show()
                },
                quit: { NSApp.terminate(nil) }))
        // A menu bar app is never frontmost by itself; the popover takes keys and clicks only once
        // the app is active.
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func closePopover() {
        popover.performClose(nil)
    }

    /// Set as the close starts, not after its animation, which can end after the click's action.
    func popoverWillClose(_ notification: Notification) {
        lastClose = .now
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
        AppIcons.clear()
        Usage.shared.isLive = false
        HistoryProcess.dismissStandby()
    }

    /// The status item's view, for `soroband-debug://capture-status-item`.
    var buttonView: NSView? { item?.button }
}

/// The popover's content, following `Usage` while it is open.
private struct LivePopover: View {
    var usage = Usage.shared
    var monitor = NetworkMonitor.shared
    @State var tab: PopoverView.Tab
    @State var allNetworks: Bool
    /// Opens History on this month, on `network` or on every network when nil.
    let openHistory: (_ network: Int64?) -> Void
    let openSettings: () -> Void
    let quit: () -> Void

    var body: some View {
        PopoverView(
            content: PopoverContent.make(
                status: usage.status, today: usage.today, registry: usage.registry,
                current: monitor.current, connectedSince: monitor.connectedSince, allNetworks: allNetworks),
            tab: $tab, allNetworks: $allNetworks,
            openHistory: { openHistory(allNetworks || tab == .networks ? nil : monitor.current?.id) },
            openSettings: openSettings, quit: quit
        )
        .onChange(of: monitor.current) { usage.reloadRegistry() }
    }
}
