import AppKit
import SwiftUI
import UniformTypeIdentifiers
import os

/// The History window, the only window of the History process (`HistoryOptions`), which quits
/// when it closes.
@MainActor
final class HistoryWindow: NSObject, NSWindowDelegate {
    static let shared = HistoryWindow()
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Soroband", category: "history")

    private(set) var window: NSWindow?
    private(set) var model: HistoryModel?
    private var toolbar: HistoryToolbar?
    /// How long opening took: from the click in the menu bar app (or this process's start, when
    /// opened another way) to a drawn window with its data. Logged as "History opened in N ms"
    /// (`log show --predicate 'subsystem BEGINSWITH "io.github.abouleinein.soroband"'`).
    private(set) var openDuration: TimeInterval?

    func show(_ options: HistoryOptions) {
        guard window == nil else { return }
        NSApp.setActivationPolicy(.accessory)
        let model = HistoryModel(
            range: options.range, anchor: options.date ?? .now, network: options.network,
            currentNetwork: options.current, registry: Core.networks())
        model.expandedApp = options.expandedApp
        model.hoverDate = options.hover
        var window: NSWindow!
        var toolbar: HistoryToolbar!
        // The window and toolbar are built while the database is read.
        model.loadNow {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1000, height: 880),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            toolbar = HistoryToolbar(model: model, export: { [weak self] in self?.exportCSV() })
            window.toolbar = toolbar.toolbar
            window.toolbarStyle = .unified
        }
        let host = NSHostingController(rootView: HistoryView(model: model))
        // The toolbar is AppKit's own (`HistoryToolbar`): bridging SwiftUI toolbar items into
        // the window took about 40% of the time to open it. The window sets the size; asking
        // SwiftUI for the content's fitting size first would lay out the detail once more.
        host.sceneBridgingOptions = []
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(NSSize(width: 1000, height: 880))
        window.contentMinSize = NSSize(width: 860, height: 560)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        model.onChange = { [weak window, weak toolbar, weak model] in
            toolbar?.update()
            window?.title = model?.content.title ?? ""
        }
        model.onChange?()
        self.toolbar = toolbar
        self.window = window
        self.model = model

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        let started = options.requested ?? Self.processStart
        let elapsed = Date.now.timeIntervalSince(started)
        openDuration = elapsed
        Self.log.notice("History opened in \(Int(elapsed * 1000), privacy: .public) ms")
    }

    /// Draws a small History offscreen once, in standby: the first layout of SwiftUI and Charts
    /// in a process cost about 65 ms of the click's wait (measured on Month and Year).
    func warmUp() {
        let now = Date.now
        let query = HistoryQuery.make(
            range: .week, anchor: now, network: nil, firstHour: nil, now: now, calendar: .current)
        let hour = Int64(query.interval.start.timeIntervalSince1970)
        let data = HistoryData(
            firstHour: hour, interfaces: ByteCounts(rx: 2, tx: 1), previous: 1,
            bars: [.init(firstHour: hour, network: 0, rx: 2, tx: 1)],
            networks: [.init(network: 0, interfaces: ByteCounts(rx: 2, tx: 1), apps: ByteCounts(rx: 1, tx: 0))],
            apps: [.init(network: 0, id: "process:warm-up", name: "warm-up", rx: 1, tx: 0)],
            busiestDay: .init(firstHour: hour, bytes: 3), heatmap: [.init(weekday: 0, hour: 0, bytes: 3)])
        let content = HistoryContent.make(
            range: .week, query: query, data: data, registry: [], now: now, calendar: .current)
        let host = NSHostingView(
            rootView: HistoryDetail(
                content: content, expandedApp: .constant(nil), hoverDate: .constant(nil), showsAllApps: .constant(false)
            ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 880), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        window.contentView = nil
    }

    /// When this process started, from the kernel.
    private static var processStart: Date {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return .now }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1e6)
    }

    /// Asks where to save, then writes what the window shows as CSV.
    private func exportCSV() {
        guard let model, let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Soroband \(model.content.title) \(model.content.subtitle).csv"
            .replacingOccurrences(of: "/", with: "-")
        let query = model.query
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let file = panel.url else { return }
            if Core.exportCSV(query, to: file) == nil {
                let alert = NSAlert()
                alert.messageText = "The CSV could not be written."
                alert.informativeText = file.path
                alert.beginSheetModal(for: window)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }
}

/// What the History window shows and the choices that select it.
@MainActor
@Observable
final class HistoryModel {
    private(set) var range: HistoryRange
    private(set) var anchor: Date
    /// One network, or every network when nil.
    private(set) var network: Int64?
    private(set) var registry: [RegisteredNetwork]
    private(set) var query: HistoryQuery
    private(set) var content: HistoryContent
    /// The earliest recorded hour on each network (nil: every network), from earlier answers; All
    /// Time starts there.
    private var firstHours: [Int64?: Date] = [:]
    /// Reads the database: `Core.history`, or a stand-in in tests.
    private let read: @Sendable (HistoryQuery) -> HistoryData?
    /// Reads the registry again at each answer, so names and colors changed in Settings show at the
    /// next refresh: `Core.networks`, or a stand-in in tests. An empty answer (a failed read) keeps
    /// the registry History has.
    private let readRegistry: () -> [RegisteredNetwork]
    /// Drops an answer when a newer query was sent while it was read.
    private var generation = 0

    /// Called after each change of what the window shows.
    var onChange: (() -> Void)?

    var expandedApp: String?
    var hoverDate: Date?
    var showsAllApps = false

    /// Apps listed before "Show all".
    static let visibleApps = 12

    init(
        range: HistoryRange, anchor: Date, network: Int64?, currentNetwork: Int64?, registry: [RegisteredNetwork],
        read: @escaping @Sendable (HistoryQuery) -> HistoryData? = Core.history,
        readRegistry: @escaping () -> [RegisteredNetwork] = Core.networks
    ) {
        self.read = read
        self.readRegistry = readRegistry
        self.currentNetwork = currentNetwork
        self.range = range
        self.anchor = anchor
        self.network = network
        self.registry = registry
        let query = HistoryQuery.make(
            range: range, anchor: anchor, network: network, firstHour: nil, now: .now, calendar: .current)
        self.query = query
        content = HistoryContent.make(
            range: range, query: query, data: .empty, registry: registry, now: .now, calendar: .current)
    }

    var calendar: Calendar { .current }

    /// The network the Mac was on when History opened, for the sidebar's badge.
    let currentNetwork: Int64?

    /// Whether `next` would show a period that has not started yet.
    var isAtPresent: Bool { query.interval.end > .now }

    func select(range: HistoryRange? = nil, anchor: Date? = nil, network: Int64?? = nil) {
        if let range { self.range = range }
        if let anchor { self.anchor = anchor }
        if let network { self.network = network }
        expandedApp = nil
        hoverDate = nil
        showsAllApps = false
        load()
    }

    /// Moves one period back (-1) or forward (1).
    func step(_ direction: Int) {
        guard let period = range.period, let moved = calendar.date(byAdding: period, value: direction, to: anchor)
        else { return }
        select(anchor: moved)
    }

    /// Reads the current choice on another thread while `work` runs on this one, and shows it
    /// before returning, so the first answer is drawn with the window. Reading elsewhere also keeps
    /// the read's short-lived allocations from interleaving with the window's, which left several
    /// megabytes of the heap fragmented.
    func loadNow(while work: () -> Void = {}) {
        final class Answer: @unchecked Sendable {
            var data: HistoryData?
        }
        let query = makeQuery()
        let answer = Answer()
        let reading = DispatchGroup()
        reading.enter()
        let read = read
        DispatchQueue.global(qos: .userInitiated).async {
            answer.data = read(query)
            reading.leave()
        }
        work()
        reading.wait()
        apply(answer.data, for: query)
        // All Time chooses days or months by how far back history goes, known only now.
        if range == .all, makeQuery().step != query.step { loadNow() }
    }

    /// Reads the current choice off the main thread and shows it when it arrives.
    func load() {
        generation += 1
        let generation = generation
        let query = makeQuery()
        let read = read
        Task.detached(priority: .userInitiated) {
            let data = read(query)
            await MainActor.run {
                guard generation == self.generation else { return }
                self.apply(data, for: query)
                if self.range == .all, self.makeQuery().step != query.step { self.load() }
            }
        }
    }

    private func makeQuery() -> HistoryQuery {
        HistoryQuery.make(
            range: range, anchor: anchor, network: network, firstHour: firstHours[network], now: .now,
            calendar: calendar)
    }

    private func apply(_ data: HistoryData?, for query: HistoryQuery) {
        if let first = data?.firstHour {
            firstHours[query.network] = Date(timeIntervalSince1970: TimeInterval(first))
        }
        self.query = query
        let fresh = readRegistry()
        if !fresh.isEmpty, fresh != registry { registry = fresh }
        content = HistoryContent.make(
            range: range, query: query, data: data ?? .empty, registry: registry, now: .now, calendar: calendar)
        onChange?()
    }
}

/// The History window's toolbar: previous, Today and next, the range, and Export.
@MainActor
final class HistoryToolbar: NSObject, NSToolbarDelegate {
    let toolbar = NSToolbar(identifier: "history")
    private let model: HistoryModel
    private let export: () -> Void
    private let previous = NSButton()
    private let today = NSButton()
    private let next = NSButton()
    private let ranges = NSSegmentedControl(
        labels: HistoryRange.allCases.map(\.label), trackingMode: .selectOne, target: nil, action: nil)

    private static let navigation = NSToolbarItem.Identifier("navigation")
    private static let range = NSToolbarItem.Identifier("range")
    private static let export = NSToolbarItem.Identifier("export")

    init(model: HistoryModel, export: @escaping () -> Void) {
        self.model = model
        self.export = export
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        for (button, symbol, label) in [(previous, "chevron.left", "Previous"), (next, "chevron.right", "Next")] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.toolTip = label
        }
        today.title = "Today"
        for button in [previous, today, next] {
            button.bezelStyle = .toolbar
            button.target = self
        }
        previous.action = #selector(goBack)
        today.action = #selector(goToToday)
        next.action = #selector(goForward)
        ranges.target = self
        ranges.action = #selector(pickRange)
    }

    /// Shows the model's range and which moves are possible.
    func update() {
        ranges.selectedSegment = HistoryRange.allCases.firstIndex(of: model.range) ?? 0
        let moves = model.range != .all
        previous.isEnabled = moves
        today.isEnabled = moves
        next.isEnabled = moves && !model.isAtPresent
    }

    @objc private func goBack() { model.step(-1) }
    @objc private func goToToday() { model.select(anchor: .now) }
    @objc private func goForward() { model.step(1) }
    @objc private func runExport() { export() }

    @objc private func pickRange() {
        model.select(range: HistoryRange.allCases[ranges.selectedSegment])
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.navigation, Self.range, .flexibleSpace, Self.export]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier {
        case Self.navigation:
            let stack = NSStackView(views: [previous, today, next])
            stack.spacing = 4
            item.view = stack
            item.label = "Navigate"
        case Self.range:
            item.view = ranges
            item.label = "Range"
        case Self.export:
            item.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Export CSV")
            item.label = "Export CSV"
            item.toolTip = "Export CSV…"
            item.isBordered = true
            item.target = self
            item.action = #selector(runExport)
        default:
            return nil
        }
        return item
    }
}
