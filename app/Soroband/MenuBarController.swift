import AppKit

/// The menu bar item. Its popover is in the UI process (`UIProcess`), so no window ever lives in
/// this process.
///
/// The item's icon and text change only when the displayed text does.
@MainActor
final class MenuBarController: NSObject {
    static let shared = MenuBarController()

    private var item: NSStatusItem?
    private let renderer = MenuBarRenderer()
    private var drawn: MenuBarDisplay.Drawn?
    var display: MenuBarDisplay? { drawn?.display }
    private var lastRedraw = Date.distantPast
    /// A redraw put off by `MenuBarDisplay.redrawDelay`.
    private var pendingRedraw: Task<Void, Never>?
    /// The item's frame last sent to the UI process.
    private var sentAnchor: CGRect?

    var isPopoverShown: Bool { UIProcess.shared.isPopoverShown }

    func start() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.imagePosition = .imageLeading
        // Digits of one width, so a changing count or speed does not shift the menu bar.
        item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        self.item = item
        Usage.shared.onChange = { [weak self] in
            self?.update()
            UIProcess.shared.publish()
        }
        // The open popover follows the item when it moves, changes width or changes display.
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(itemMoved), name: name, object: item.button?.window)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(itemMoved), name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
        update()
    }

    func update() {
        let usage = Usage.shared
        let display = MenuBarDisplay.make(
            layout: usage.menuBarLayout, status: usage.status, kind: NetworkMonitor.shared.current?.kind,
            gauges: usage.gauges, resources: usage.resources)
        guard display != self.display, let button = item?.button else { return }
        let new = MenuBarDisplay.Drawn(
            display: display, layout: usage.menuBarLayout, network: usage.status.networkID,
            total: MenuBarDisplay.total(layout: usage.menuBarLayout, status: usage.status))
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
        if display.drawsTitle {
            button.image = display.image()
            button.title = display.text.map { " \($0)" } ?? ""
        } else {
            var textColor = NSColor.labelColor
            button.effectiveAppearance.performAsCurrentDrawingAppearance {
                textColor = NSColor(cgColor: NSColor.labelColor.cgColor) ?? .labelColor
            }
            let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
            // If the renderer cannot make its bitmap, the vector image draws instead (both are nil
            // only if the SF Symbol cannot be made).
            button.image =
                renderer.image(display, textColor: textColor, scale: scale)
                ?? display.itemImage(textColor: textColor)
            button.title = ""
        }
        button.setAccessibilityLabel(display.accessibilityLabel())
        // A new width moves the item's frame once the menu bar has laid it out.
        DispatchQueue.main.async { self.itemMoved() }
    }

    @objc func togglePopover() {
        guard let anchor else { return }
        UIProcess.shared.send(.toggle(PopoverRequest(anchor: anchor, activates: true, requested: .now)))
        sentAnchor = anchor
    }

    /// Opens the popover on `tab`, with the Apps tab's toggle set to `allNetworks`.
    func showPopover(tab: String = "Apps", allNetworks: Bool = false) {
        guard let anchor else { return }
        UIProcess.shared.send(
            .showPopover(PopoverRequest(anchor: anchor, tab: tab, allNetworks: allNetworks, requested: .now)))
        sentAnchor = anchor
    }

    func closePopover() {
        UIProcess.shared.send(.closePopover)
    }

    @objc private func itemMoved() {
        guard isPopoverShown, let anchor, anchor != sentAnchor else { return }
        sentAnchor = anchor
        UIProcess.shared.send(.anchor(anchor))
    }

    /// The item's frame on screen, which the popover points at.
    private var anchor: CGRect? {
        guard let button = item?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// The status item's view, for `soroband-debug://capture-status-item`.
    var buttonView: NSView? { item?.button }
}
