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
                    return MinuteRecord(
                        firstMinute: 60,
                        minutes: [
                            .init(
                                start: Int64(start.timeIntervalSince1970), cpuBusy: 0.5, memoryUsed: 1, memoryLevel: 50,
                                pressure: 1, volumeFree: nil, volumeSize: nil)
                        ])
                },
                minuteApps: { _ in MinuteApps() })
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
        #expect(model.minutes?.points.count == 1)
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
