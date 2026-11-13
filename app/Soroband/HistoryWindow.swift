import AppKit
import SwiftUI
import UniformTypeIdentifiers
import os

/// The History window, in the UI process (`UIHost`).
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

    /// Opens History on `options`. A History already open comes forward as it is, unless
    /// `replacing` it, which closes it and opens a new one.
    /// `activates` is true for the user's own action; a Debug URL command passes false, and History
    /// comes forward without taking the keyboard.
    func show(_ options: HistoryOptions, replacing: Bool = false, activates: Bool) {
        if let window {
            guard replacing else {
                bringForward(window, activates: activates)
                return
            }
            window.close()
        }
        let model = HistoryModel(
            range: options.range, anchor: options.date ?? .now, network: options.network,
            // The registry comes with the first answer, read off the main thread.
            currentNetwork: options.current, registry: [], measure: options.measure,
            settings: Usage.shared.resources)
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
            // The page carries its title; the toolbar's room goes to the measure and the range.
            window.titleVisibility = .hidden
        }
        let host = NSHostingController(rootView: HistoryView(model: model).themed())
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
            window?.title = model?.title ?? ""
        }
        model.onChange?()
        self.toolbar = toolbar
        self.window = window
        self.model = model

        bringForward(window, activates: activates)
        window.displayIfNeeded()
        UIHost.windowsChanged()
        let started = options.requested ?? Self.processStart
        let elapsed = Date.now.timeIntervalSince(started)
        openDuration = elapsed
        Self.log.notice("History opened in \(Int(elapsed * 1000), privacy: .public) ms")
    }

    /// Draws a small History offscreen once: the first layout of SwiftUI and Charts in a process
    /// cost about 65 ms of the click's wait (measured on Month and Year).
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
            self.export(
                query, to: file,
                done: { rows in
                    guard rows == nil else { return }
                    guard window.isVisible else {
                        Self.log.error("The CSV could not be written to \(file.path, privacy: .public)")
                        return
                    }
                    let alert = NSAlert()
                    alert.messageText = "The CSV could not be written."
                    alert.informativeText = file.path
                    alert.beginSheetModal(for: window, completionHandler: nil)
                })
        }
    }

    /// Exports in flight, which quitting waits for (`shouldTerminate`).
    private var exports: [Int: Task<Void, Never>] = [:]
    private var nextExport = 0

    /// Writes `query`'s usage to `file` (`writeCSV`), then calls `done` with the rows written, nil
    /// when it could not be written.
    func export(
        _ query: HistoryQuery, to file: URL,
        write: @escaping @Sendable (HistoryQuery, URL) -> Int? = Core.exportCSV,
        done: @escaping (Int?) -> Void = { _ in }
    ) {
        let id = nextExport
        nextExport += 1
        exports[id] = Task {
            done(await Self.writeCSV(query, to: file, write: write))
            exports[id] = nil
        }
    }

    /// The UI process quits once an export in flight has finished, and `reply` is called then.
    func shouldTerminate(reply: @escaping () -> Void) -> NSApplication.TerminateReply {
        guard !exports.isEmpty else { return .terminateNow }
        let pending = Array(exports.values)
        Task {
            for export in pending { await export.value }
            reply()
        }
        return .terminateLater
    }

    /// Writes `query`'s usage to `file` off the main thread, so a long range does not stall the
    /// window, and returns the rows written; nil when it could not be written. The CSV is written
    /// beside `file` and moved over it once complete, so `file` is never left half-written. `write`
    /// is `Core.exportCSV`, or a stand-in in tests.
    nonisolated static func writeCSV(
        _ query: HistoryQuery, to file: URL,
        write: @escaping @Sendable (HistoryQuery, URL) -> Int? = Core.exportCSV
    ) async -> Int? {
        await Task.detached(priority: .userInitiated) {
            let files = FileManager.default
            guard
                let directory = try? files.url(
                    for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: file, create: true)
            else { return nil }
            defer { try? files.removeItem(at: directory) }
            let temporary = directory.appending(path: file.lastPathComponent)
            guard let rows = write(query, temporary), (try? files.replaceItemAt(file, withItemAt: temporary)) != nil
            else { return nil }
            return rows
        }.value
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        model = nil
        toolbar = nil
        UIHost.windowsChanged()
    }
}

/// How History reads the database: the core, or stand-ins in tests.
struct HistoryReads: Sendable {
    var history: @Sendable (HistoryQuery) -> HistoryData? = Core.history
    /// Reads the registry again with each answer, on the same thread, so names and colors changed
    /// in Settings show at the next refresh. An empty answer (a failed read) keeps the registry.
    var registry: @Sendable () -> [RegisteredNetwork] = Core.networks
    var resources: @Sendable (ResourceQuery) -> ResourceHistoryData? = Core.resourceHistory
    var minutes: @Sendable (Date, Date, String) -> MinuteRecord? = {
        Core.resourceMinutes(from: $0, to: $1, volume: $2)
    }
    var minuteApps: @Sendable (Int64) -> MinuteApps? = Core.minuteApps
}

/// What the History window shows and the choices that select it.
@MainActor
@Observable
final class HistoryModel {
    private(set) var range: HistoryRange
    private(set) var anchor: Date
    /// One network, or every network when nil.
    private(set) var network: Int64?
    /// The resource the page shows; the data page when nil.
    private(set) var measure: ResourceMeasure?
    private(set) var registry: [RegisteredNetwork]
    private(set) var query: HistoryQuery
    private(set) var content: HistoryContent
    /// The resource page, while a resource is picked.
    private(set) var resourceContent: ResourceHistoryContent?
    /// The Day page of a resource, minute by minute; nil on other pages, and on a day the minute
    /// record does not reach (`minutesKept` then says how long it keeps them).
    private(set) var minutes: MinuteContent?
    /// The expanded app's five measures over the range: its bytes on every network and its
    /// resources, read when an app is expanded.
    private(set) var expandedMeasures: (bytes: ByteCounts?, resources: ResourceSum?)?
    /// How each resource reads, from Settings › Resources.
    var settings: ResourceSettings {
        didSet {
            guard settings != oldValue else { return }
            if let measure, !settings.shows(measure) { self.measure = nil }
            load()
        }
    }
    /// The earliest recorded hour on each network (nil: every network), and of the resources, from
    /// earlier answers; All Time starts there.
    private var firstHours: [Int64?: Date] = [:]
    private var firstResourceHour: Date?
    private var minuteRecord: MinuteRecord?
    private var minuteApps: MinuteApps?
    private let reads: HistoryReads
    /// Drops an answer when a newer query was sent while it was read.
    private var generation = 0

    /// Called after each change of what the window shows.
    var onChange: (() -> Void)?

    var expandedApp: String? {
        didSet {
            guard expandedApp != oldValue else { return }
            expandedMeasures = nil
            if expandedApp != nil, !settings.shown.isEmpty { loadExpandedMeasures() }
        }
    }
    var hoverDate: Date?
    var showsAllApps = false
    /// The minute the Day page's lists show; the latest when nil.
    private(set) var selectedMinute: Int64?

    /// Apps listed before "Show all".
    static let visibleApps = 12

    init(
        range: HistoryRange, anchor: Date, network: Int64?, currentNetwork: Int64?, registry: [RegisteredNetwork],
        measure: ResourceMeasure? = nil, settings: ResourceSettings = .default, reads: HistoryReads = HistoryReads()
    ) {
        self.reads = reads
        self.currentNetwork = currentNetwork
        self.range = range
        self.anchor = anchor
        self.network = network
        self.settings = settings
        self.measure = measure.flatMap { settings.shows($0) ? $0 : nil }
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

    /// The page's title, for the window.
    var title: String { resourceContent?.title ?? content.title }

    func select(
        range: HistoryRange? = nil, anchor: Date? = nil, network: Int64?? = nil, measure: ResourceMeasure?? = nil
    ) {
        if let range { self.range = range }
        if let anchor { self.anchor = anchor }
        if let network { self.network = network }
        if let measure { self.measure = measure.flatMap { settings.shows($0) ? $0 : nil } }
        expandedApp = nil
        hoverDate = nil
        showsAllApps = false
        selectedMinute = nil
        load()
    }

    /// Moves one period back (-1) or forward (1).
    func step(_ direction: Int) {
        guard let period = range.period, let moved = calendar.date(byAdding: period, value: direction, to: anchor)
        else { return }
        select(anchor: moved)
    }

    /// Picks the minute starting at `minute` on the Day page, and reads its busiest apps.
    func selectMinute(_ minute: Int64?) {
        guard minute != selectedMinute || minuteApps == nil, let record = minuteRecord else { return }
        selectedMinute = minute
        guard let shown = minute ?? record.minutes.last?.start else { return }
        let read = reads.minuteApps
        let generation = generation
        Task.detached(priority: .userInitiated) {
            let apps = read(shown)
            await MainActor.run {
                guard generation == self.generation, (self.selectedMinute ?? record.minutes.last?.start) == shown
                else { return }
                self.minuteApps = apps
                self.updateMinutes()
            }
        }
    }

    /// Moves the picked minute by `offset` minutes.
    func moveMinute(_ offset: Int) {
        guard let record = minuteRecord else { return }
        selectMinute(MinuteContent.moved(record, from: selectedMinute, by: offset))
    }

    /// What one read brings back.
    private struct Answer: @unchecked Sendable {
        var data: HistoryData?
        var registry: [RegisteredNetwork] = []
        var resources: ResourceHistoryData?
        var minutes: MinuteRecord?
        var minuteApps: MinuteApps?
    }

    private enum Request: Sendable {
        case data(HistoryQuery)
        case resource(ResourceQuery, day: DateInterval?, volume: String)

        var step: HistoryStep {
            switch self {
            case .data(let query): query.step
            case .resource(let query, _, _): query.step
            }
        }
    }

    private nonisolated static func read(_ request: Request, with reads: HistoryReads) -> Answer {
        var answer = Answer()
        switch request {
        case .data(let query):
            answer.data = reads.history(query)
            answer.registry = reads.registry()
        case .resource(let query, let day, let volume):
            answer.resources = reads.resources(query)
            if let day, let record = reads.minutes(day.start, day.end, volume) {
                answer.minutes = record
                if let last = record.minutes.last?.start { answer.minuteApps = reads.minuteApps(last) }
            }
        }
        return answer
    }

    /// Reads the current choice on another thread while `work` runs on this one, and shows it
    /// before returning, so the first answer is drawn with the window. Reading elsewhere also keeps
    /// the read's short-lived allocations from interleaving with the window's, which left several
    /// megabytes of the heap fragmented.
    func loadNow(while work: () -> Void = {}) {
        final class Box: @unchecked Sendable { var answer = Answer() }
        let request = makeRequest()
        let box = Box()
        let reading = DispatchGroup()
        reading.enter()
        let reads = reads
        DispatchQueue.global(qos: .userInitiated).async {
            box.answer = Self.read(request, with: reads)
            reading.leave()
        }
        work()
        reading.wait()
        apply(box.answer, for: request)
        // All Time chooses days or months by how far back history goes, known only now.
        if range == .all, makeRequest().step != request.step { loadNow() }
    }

    /// Reads the current choice off the main thread and shows it when it arrives.
    func load() {
        generation += 1
        let generation = generation
        let request = makeRequest()
        let reads = reads
        Task.detached(priority: .userInitiated) {
            let answer = Self.read(request, with: reads)
            await MainActor.run {
                guard generation == self.generation else { return }
                self.apply(answer, for: request)
                if self.range == .all, self.makeRequest().step != request.step { self.load() }
            }
        }
    }

    private func makeRequest() -> Request {
        guard let measure else {
            return .data(
                HistoryQuery.make(
                    range: range, anchor: anchor, network: network, firstHour: firstHours[network], now: .now,
                    calendar: calendar))
        }
        let query = ResourceQuery.make(
            range: range, anchor: anchor, measure: measure, firstHour: firstResourceHour, now: .now,
            calendar: calendar)
        return .resource(query, day: range == .day ? query.interval : nil, volume: settings.diskVolume)
    }

    private func apply(_ answer: Answer, for request: Request) {
        switch request {
        case .data(let query):
            if let first = answer.data?.firstHour {
                firstHours[query.network] = Date(timeIntervalSince1970: TimeInterval(first))
            }
            self.query = query
            if !answer.registry.isEmpty, answer.registry != registry { registry = answer.registry }
            content = HistoryContent.make(
                range: range, query: query, data: answer.data ?? .empty, registry: registry, now: .now,
                calendar: calendar)
            resourceContent = nil
            minuteRecord = nil
            minutes = nil
        case .resource(let query, let day, _):
            if let first = answer.resources?.firstHour {
                firstResourceHour = Date(timeIntervalSince1970: TimeInterval(first))
            }
            self.query = HistoryQuery(
                interval: query.interval, previous: query.previous, network: nil, step: query.step)
            resourceContent = ResourceHistoryContent.make(
                range: range, query: query, data: answer.resources ?? .empty, now: .now, calendar: calendar)
            minuteRecord = day == nil ? nil : answer.minutes
            minuteApps = answer.minuteApps
            updateMinutes()
        }
        onChange?()
    }

    private func updateMinutes() {
        guard let record = minuteRecord else {
            minutes = nil
            return
        }
        minutes = MinuteContent.make(
            record: record, selected: selectedMinute, apps: minuteApps, settings: settings,
            keptDays: minutesKept)
    }

    /// Days the minute record keeps, from the settings.
    var minutesKept: Int { settings.minutesDays }

    private func loadExpandedMeasures() {
        guard let app = expandedApp else { return }
        let interval = query.interval
        let step = query.step
        let reads = reads
        let generation = generation
        Task.detached(priority: .userInitiated) {
            let bytes = reads.history(HistoryQuery(interval: interval, previous: nil, network: nil, step: step))
            let resources = reads.resources(
                ResourceQuery(interval: interval, previous: nil, step: step, measure: .cpu))
            await MainActor.run {
                guard generation == self.generation, self.expandedApp == app else { return }
                let shares = bytes?.apps.filter { $0.id == app }
                let total = shares.map {
                    $0.reduce(ByteCounts.zero) { ByteCounts(rx: $0.rx + $1.rx, tx: $0.tx + $1.tx) }
                }
                self.expandedMeasures = (total, resources?.apps.first { $0.id == app }?.sum ?? .zero)
            }
        }
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
    /// Data, then each resource shown: the page's measure.
    private let measures = NSSegmentedControl(labels: ["Data"], trackingMode: .selectOne, target: nil, action: nil)
    private var shownMeasures: [ResourceMeasure] = []

    private static let navigation = NSToolbarItem.Identifier("navigation")
    private static let range = NSToolbarItem.Identifier("range")
    private static let measure = NSToolbarItem.Identifier("measure")
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
        measures.target = self
        measures.action = #selector(pickMeasure)
    }

    /// Shows the model's range and which moves are possible.
    func update() {
        let shown = model.settings.shown
        if shown != shownMeasures {
            shownMeasures = shown
            measures.segmentCount = shown.count + 1
            for (index, label) in (["Data"] + shown.map(\.label)).enumerated() {
                measures.setLabel(label, forSegment: index)
                measures.setWidth(0, forSegment: index)
            }
            measures.isHidden = shown.isEmpty
            measures.sizeToFit()
        }
        measures.selectedSegment = model.measure.flatMap { shown.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
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

    @objc private func pickMeasure() {
        let index = measures.selectedSegment
        model.select(measure: .some(shownMeasures.indices.contains(index - 1) ? shownMeasures[index - 1] : nil))
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.measure, .flexibleSpace, Self.navigation, Self.range, Self.export]
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
        case Self.measure:
            item.view = measures
            item.label = "Measure"
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
