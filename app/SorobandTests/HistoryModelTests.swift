import Foundation
import Testing

@testable import Soroband

/// What History asks the database for as the choices change, with a stand-in for the core.
@MainActor
struct HistoryModelTests {
    /// Records each query and answers with the first hour of the network asked about.
    final class Reader: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [HistoryQuery] = []
        /// 1 March 2026 on the hotspot (2); 1 January 2025 on every network.
        let firstHours: [Int64?: Int64] = [2: 1_772_323_200, nil: 1_735_689_600]

        var queries: [HistoryQuery] { lock.withLock { asked } }

        func read(_ query: HistoryQuery) -> HistoryData? {
            lock.withLock { asked.append(query) }
            return HistoryData(
                firstHour: firstHours[query.network] ?? nil, interfaces: .zero, previous: nil, bars: [],
                networks: [], apps: [], busiestDay: nil, heatmap: [])
        }
    }

    @Test func allTimeOnAnotherNetworkStartsWhereThatNetworkStarts() async throws {
        let reader = Reader()
        let model = HistoryModel(
            range: .all, anchor: .now, network: 2, currentNetwork: nil, registry: [],
            reads: HistoryReads(history: reader.read))
        model.loadNow()
        #expect(
            model.content.interval.start
                == Calendar.current.startOfDay(
                    for: Date(timeIntervalSince1970: 1_772_323_200)))

        model.select(network: .some(nil))
        for _ in 0..<200 where model.query.network != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        // Every network has nothing known yet, so it is read from the start, not from the
        // hotspot's March.
        let everyNetwork = try #require(reader.queries.last { $0.network == nil })
        #expect(everyNetwork.interval.start == Date(timeIntervalSince1970: 0))
        #expect(
            model.content.interval.start
                == Calendar.current.startOfDay(
                    for: Date(timeIntervalSince1970: 1_735_689_600)))
    }

    /// History runs in its own process: a color or name changed in Settings reaches it at its
    /// next refresh, and a failed registry read keeps what it had.
    @Test func eachRefreshRereadsTheRegistry() {
        let home = RegisteredNetwork(id: 1, key: "wifi:Home", name: "Home", kind: .wifi, lastUsed: nil)
        var picked = home
        picked.color = 3
        final class Answer: @unchecked Sendable { var registry: [RegisteredNetwork] = [] }
        let answer = Answer()
        answer.registry = [picked]
        let model = HistoryModel(
            range: .week, anchor: .now, network: nil, currentNetwork: nil, registry: [home],
            reads: HistoryReads(history: Reader().read, registry: { answer.registry }))
        model.loadNow()
        #expect(model.registry == [picked])
        var repicked = picked
        repicked.color = 5
        answer.registry = [repicked]
        model.loadNow()
        #expect(model.registry == [repicked], "every refresh reads the registry, not only the first")
        answer.registry = []
        model.loadNow()
        #expect(model.registry == [repicked], "a failed read keeps the registry")
    }

    /// An All Time export can take a while; it is written off the main thread, so the window keeps
    /// drawing, and a failed write is reported.
    @Test func csvIsWrittenOffTheMainThread() async throws {
        let query = HistoryQuery.make(
            range: .all, anchor: .now, network: nil, firstHour: nil, now: .now, calendar: .current)
        let file = try Self.exportDirectory().appending(path: "usage.csv")
        final class Seen: @unchecked Sendable { var onMain: Bool? }
        let seen = Seen()
        let written = await HistoryWindow.writeCSV(query, to: file) { _, temporary in
            seen.onMain = Thread.isMainThread
            return (try? "rows".write(to: temporary, atomically: false, encoding: .utf8)) != nil ? 10 : nil
        }
        #expect(written == 10)
        #expect(seen.onMain == false)
        #expect(await HistoryWindow.writeCSV(query, to: file) { _, _ in nil } == nil)
    }

    /// A write that fails, or a process that dies, partway through an export leaves the file the
    /// user picked as it was: an earlier export they chose to overwrite is not truncated.
    @Test func anUnfinishedExportLeavesTheFileWhole() async throws {
        let query = HistoryQuery.make(
            range: .all, anchor: .now, network: nil, firstHour: nil, now: .now, calendar: .current)
        let file = try Self.exportDirectory().appending(path: "usage.csv")
        try "earlier export".write(to: file, atomically: true, encoding: .utf8)
        let written = await HistoryWindow.writeCSV(query, to: file) { _, target in
            try? "half a".write(to: target, atomically: false, encoding: .utf8)
            return nil
        }
        #expect(written == nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == "earlier export")
        _ = await HistoryWindow.writeCSV(query, to: file) { _, target in
            (try? "new export".write(to: target, atomically: false, encoding: .utf8)).map { 1 }
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "new export")
    }

    /// Closing the History window quits its process; an export still being written finishes
    /// first, instead of the process exiting mid-write.
    @Test func quittingWaitsForAnExportInFlight() async throws {
        let query = HistoryQuery.make(
            range: .all, anchor: .now, network: nil, firstHour: nil, now: .now, calendar: .current)
        let file = try Self.exportDirectory().appending(path: "usage.csv")
        let history = HistoryWindow()
        let writing = DispatchSemaphore(value: 0)
        let (written, finished) = AsyncStream.makeStream(of: Int?.self)
        history.export(
            query, to: file,
            write: { _, target in
                writing.wait()
                return (try? "rows".write(to: target, atomically: false, encoding: .utf8)).map { 3 }
            }, done: { finished.yield($0) })
        let (replied, reply) = AsyncStream.makeStream(of: Void.self)
        let answer = history.shouldTerminate { reply.yield() }
        #expect(answer == .terminateLater, "quitting now would end the write partway")
        writing.signal()
        var rows: Int?? = nil
        for await value in written {
            rows = value
            break
        }
        if answer == .terminateLater { for await _ in replied { break } }
        #expect(rows == 3)
        #expect(try String(contentsOf: file, encoding: .utf8) == "rows")
        #expect(history.shouldTerminate {} == .terminateNow, "nothing left to wait for")
    }

    private static func exportDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "soroband-export-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// While History is open, the next period or range it loads brings the registry as it is now.
    @Test func anOpenWindowTakesTheRegistryWithItsNextAnswer() async throws {
        final class Answer: @unchecked Sendable { var registry: [RegisteredNetwork] = [] }
        let home = RegisteredNetwork(id: 1, key: "wifi:Home", name: "Home", kind: .wifi, lastUsed: nil)
        let answer = Answer()
        answer.registry = [home]
        let model = HistoryModel(
            range: .week, anchor: .now, network: nil, currentNetwork: nil, registry: [],
            reads: HistoryReads(history: Reader().read, registry: { answer.registry }))
        model.loadNow()
        var picked = home
        picked.color = 2
        answer.registry = [picked]
        model.select(range: .month)
        for _ in 0..<200 where model.registry != [picked] {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.registry == [picked])
    }

    /// Records what a resource page asks the core.
    final class ResourceReader: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [ResourceQuery] = []
        private var minuteSpans: [DateInterval] = []
        private var minutesAsked: [Int64] = []
        var minuteApps: [Int64] { lock.withLock { minutesAsked } }
        var queries: [ResourceQuery] { lock.withLock { asked } }
        var minutes: [DateInterval] { lock.withLock { minuteSpans } }

        var reads: HistoryReads {
            HistoryReads(
                history: { _ in .empty }, registry: { [] },
                resources: { query in
                    self.lock.withLock { self.asked.append(query) }
                    return .empty
                },
                minutes: { start, end, _ in
                    self.lock.withLock { self.minuteSpans.append(DateInterval(start: start, end: end)) }
                    // The day's first two minutes.
                    return MinuteRecord(
                        firstMinute: 60,
                        minutes: [0, 60].map {
                            .init(
                                start: Int64(start.timeIntervalSince1970) + $0, cpuBusy: 0.5, memoryUsed: 1,
                                memoryLevel: 50, pressure: 1, volumeFree: nil, volumeSize: nil)
                        })
                },
                minuteApps: { minute in
                    self.lock.withLock { self.minutesAsked.append(minute) }
                    return MinuteApps()
                })
        }
    }

    /// A resource page reads the same span as the data page, on every network, by its measure; a
    /// Day page also reads that day's minutes.
    @Test func aResourcePageReadsItsMeasureOnEveryNetworkAndADayItsMinutes() async throws {
        let reader = ResourceReader()
        let model = HistoryModel(
            range: .month, anchor: .now, network: 2, currentNetwork: nil, registry: [], measure: .disk,
            reads: reader.reads)
        model.loadNow()
        let month = Calendar.current.dateInterval(of: .month, for: .now)!
        #expect(reader.queries.last?.measure == .disk)
        #expect(reader.queries.last?.interval == month)
        #expect(reader.queries.last?.step == .day)
        #expect(reader.minutes.isEmpty, "only a Day page reads minutes")
        #expect(model.resourceContent?.title == "Disk")
        #expect(model.minutes == nil)

        model.select(range: .day)
        for _ in 0..<200 where model.minutes == nil { try await Task.sleep(for: .milliseconds(10)) }
        let day = Calendar.current.dateInterval(of: .day, for: .now)!
        #expect(reader.minutes.last == day)
        #expect(model.minutes?.points.count == 2)
        #expect(reader.minuteApps.last == Int64(day.start.timeIntervalSince1970) + 60, "the latest minute's apps")

        // A minute picked keeps its apps across a reload of the page.
        let first = Int64(day.start.timeIntervalSince1970)
        model.selectMinute(first)
        var settings = ResourceSettings()
        settings.cpu = .cores
        model.settings = settings
        for _ in 0..<200 where reader.minutes.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(reader.minuteApps.last == first)
        #expect(model.minutes?.selected == day.start)
    }

    /// Holds a read until the test lets it go.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var closed = false
        private let opened = DispatchSemaphore(value: 0)
        func close() { lock.withLock { closed = true } }
        func open() { opened.signal() }
        func pass() { if lock.withLock({ closed }) { opened.wait() } }
    }

    /// A minute picked while a reload is read keeps its own apps: the reload, read for the minute
    /// picked before, reads the new one's again rather than showing the old one's.
    @Test func aMinutePickedDuringAReloadKeepsItsOwnApps() async throws {
        let reader = ResourceReader()
        let gate = Gate()
        var reads = reader.reads
        let minutes = reads.minutes
        reads.minutes = { start, end, volume in
            gate.pass()
            return minutes(start, end, volume)
        }
        let model = HistoryModel(
            range: .day, anchor: .now, network: nil, currentNetwork: nil, registry: [], measure: .cpu, reads: reads)
        model.loadNow()
        let first = Int64(Calendar.current.startOfDay(for: .now).timeIntervalSince1970)
        model.selectMinute(first)
        for _ in 0..<200 where reader.minuteApps.last != first { try await Task.sleep(for: .milliseconds(10)) }

        gate.close()
        var settings = ResourceSettings()
        settings.cpu = .cores
        model.settings = settings  // the reload reads for the first minute, held at the gate
        model.selectMinute(first + 60)
        for _ in 0..<200 where reader.minuteApps.last != first + 60 { try await Task.sleep(for: .milliseconds(10)) }
        let asked = reader.minuteApps.count
        gate.open()
        for _ in 0..<200 where reader.minuteApps.count < asked + 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(reader.minuteApps.suffix(2) == [first, first + 60], "the reload's read, then the picked minute's")
        #expect(model.minutes?.selected == Date(timeIntervalSince1970: TimeInterval(first + 60)))
    }

    /// A minute picked on a Day page while the day before loads is not the new day's: the new
    /// page shows its latest minute and that minute's apps.
    @Test func aMinutePickedOnTheDayBeingReplacedIsDropped() async throws {
        let reader = ResourceReader()
        let gate = Gate()
        var reads = reader.reads
        let minutes = reads.minutes
        reads.minutes = { start, end, volume in
            gate.pass()
            return minutes(start, end, volume)
        }
        let model = HistoryModel(
            range: .day, anchor: .now, network: nil, currentNetwork: nil, registry: [], measure: .cpu, reads: reads)
        model.loadNow()
        let today = Int64(Calendar.current.startOfDay(for: .now).timeIntervalSince1970)
        gate.close()
        model.step(-1)  // yesterday, held at the gate
        model.selectMinute(today)  // on today's page, still shown
        for _ in 0..<200 where reader.minuteApps.last != today { try await Task.sleep(for: .milliseconds(10)) }
        gate.open()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: .now))!
        let latest = Int64(yesterday.timeIntervalSince1970) + 60
        for _ in 0..<200 where model.minutes?.selected != Date(timeIntervalSince1970: TimeInterval(latest)) {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.minutes?.selected == Date(timeIntervalSince1970: TimeInterval(latest)))
        #expect(reader.minuteApps.last == latest, "yesterday's latest minute's apps, not today's")
    }

    /// The apps of the replaced day's latest minute, picked while the next day loads and read
    /// after it arrives, are dropped: that day's latest minute is not the new day's.
    @Test func aReplacedDaysMinuteReadLandingLateIsDropped() async throws {
        let reader = ResourceReader()
        let page = Gate()
        let apps = Gate()
        let today = Int64(Calendar.current.startOfDay(for: .now).timeIntervalSince1970)
        var reads = reader.reads
        let minutes = reads.minutes
        let minuteApps = reads.minuteApps
        reads.minutes = { start, end, volume in
            page.pass()
            return minutes(start, end, volume)
        }
        reads.minuteApps = { minute in
            if minute == today + 60 { apps.pass() }
            guard minute == today + 60 else { return minuteApps(minute) }
            return MinuteApps(cpu: [.init(id: "old", name: "Old", value: 1)])
        }
        let model = HistoryModel(
            range: .day, anchor: .now, network: nil, currentNetwork: nil, registry: [], measure: .cpu, reads: reads)
        model.loadNow()
        page.close()
        apps.close()
        model.step(-1)  // yesterday, held at the gate
        model.selectMinute(today + 60)  // today's latest, on today's page: its apps held too
        page.open()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: .now))!
        let latest = Date(timeIntervalSince1970: yesterday.timeIntervalSince1970 + 60)
        for _ in 0..<200 where model.minutes?.selected != latest { try await Task.sleep(for: .milliseconds(10)) }
        apps.open()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.minutes?.selected == latest)
        let names = model.minutes?.lists.flatMap { $0.rows.map(\.name) } ?? []
        #expect(!names.contains("Old"), "today's minute's apps are not shown on yesterday's")
    }

    /// An app expanded on a page a newer one is replacing reads that page's span; its answer,
    /// landing after the new page's, is dropped.
    @Test func anExpandedReadForThePageReplacedIsDropped() async throws {
        let calendar = Calendar.current
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: .now)!
        let lastWeek = calendar.dateInterval(of: .weekOfYear, for: thisWeek.start.addingTimeInterval(-1))!
        let page = Gate()
        let oldExpansion = Gate()
        let app = "/Applications/Xcode.app"
        let reads = HistoryReads(
            history: { _ in .empty }, registry: { [] },
            resources: { query in
                let expansion = query.previous == nil
                if !expansion, query.interval == lastWeek { page.pass() }
                if expansion, query.interval == thisWeek { oldExpansion.pass() }
                // The app's CPU tells the spans apart: 1 this week, 2 last week.
                let cpu: UInt64 = query.interval == thisWeek ? 1 : 2
                return ResourceHistoryData(
                    firstHour: nil, total: .zero, previous: nil, bars: [],
                    apps: [.init(id: app, name: "Xcode", sum: ResourceSum(cpu: cpu))], busiestDay: nil, days: 0,
                    heatmap: [])
            })
        let model = HistoryModel(
            range: .week, anchor: .now, network: nil, currentNetwork: nil, registry: [], measure: .cpu, reads: reads)
        model.loadNow()
        page.close()
        oldExpansion.close()
        model.step(-1)  // last week's page, held at the gate
        model.expandedApp = app  // on this week's page, still shown: its read is held too
        page.open()
        for _ in 0..<200 where model.expandedMeasures?.resources?.cpu != 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.expandedMeasures?.resources?.cpu == 2, "last week's")
        oldExpansion.open()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.expandedMeasures?.resources?.cpu == 2, "this week's answer, landing last, is dropped")
    }

    /// An app kept expanded while the settings change reads its measures again, rather than
    /// waiting on a read the new answer dropped.
    @Test func anExpandedAppReadsItsMeasuresAgainAfterASettingsChange() async throws {
        let reader = ResourceReader()
        let model = HistoryModel(
            range: .week, anchor: .now, network: nil, currentNetwork: nil, registry: [], measure: .cpu,
            reads: reader.reads)
        model.loadNow()
        model.expandedApp = "/Applications/Xcode.app"
        var settings = ResourceSettings()
        settings.cpu = .cores
        model.settings = settings
        for _ in 0..<200 where model.expandedMeasures == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.expandedMeasures != nil)
        #expect(model.expandedApp == "/Applications/Xcode.app")
    }

    /// Turning the page's resource off in Settings goes back to the data page.
    @Test func aResourceTurnedOffLeavesItsPage() {
        let reader = ResourceReader()
        let model = HistoryModel(
            range: .week, anchor: .now, network: nil, currentNetwork: nil, registry: [], measure: .energy,
            reads: reader.reads)
        model.loadNow()
        #expect(model.measure == .energy)
        var settings = ResourceSettings()
        settings.measures = [.cpu]
        model.settings = settings
        #expect(model.measure == nil)
        // A measure not shown is not taken.
        model.select(measure: .some(.memory))
        #expect(model.measure == nil)
        let off = HistoryModel(
            range: .week, anchor: .now, network: nil, currentNetwork: nil, registry: [], measure: .cpu,
            settings: ResourceSettings { $0 == "resources" ? "off" : nil }, reads: reader.reads)
        #expect(off.measure == nil, "the meter is off")
    }
}
