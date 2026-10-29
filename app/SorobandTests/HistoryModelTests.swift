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
            range: .all, anchor: .now, network: 2, currentNetwork: nil, registry: [], read: reader.read)
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
            read: Reader().read, readRegistry: { answer.registry })
        model.loadNow()
        #expect(model.registry == [picked])
        answer.registry = []
        model.loadNow()
        #expect(model.registry == [picked], "a failed read keeps the registry")
    }

    /// While History is open, the next period or range it loads brings the registry as it is now.
    @Test func anOpenWindowTakesTheRegistryWithItsNextAnswer() async throws {
        final class Answer: @unchecked Sendable { var registry: [RegisteredNetwork] = [] }
        let home = RegisteredNetwork(id: 1, key: "wifi:Home", name: "Home", kind: .wifi, lastUsed: nil)
        let answer = Answer()
        answer.registry = [home]
        let model = HistoryModel(
            range: .week, anchor: .now, network: nil, currentNetwork: nil, registry: [],
            read: Reader().read, readRegistry: { answer.registry })
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
}
