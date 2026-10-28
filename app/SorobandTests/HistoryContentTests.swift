import Foundation
import Testing
@testable import Soroband

/// The History window's ranges and numbers, from a month worked out by hand in Berlin, whose
/// clocks went back an hour on 25 October 2026. Unix times were computed with Python's `zoneinfo`.
struct HistoryContentTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.locale = Locale(identifier: "en_US")
        calendar.firstWeekday = 2  // Monday
        return calendar
    }()

    static func date(_ unix: TimeInterval) -> Date { Date(timeIntervalSince1970: unix) }

    // Local midnights and hours in Berlin.
    static let october1 = date(1_790_805_600)
    static let november1 = date(1_793_487_600)
    static let september1 = date(1_788_213_600)
    static let october15Noon = date(1_792_058_400)
    static let october26 = date(1_792_969_200)
    static let october27At9 = date(1_793_088_000)
    static let october28 = date(1_793_142_000)

    let registry = [
        RegisteredNetwork(id: 1, key: "wifi:Home", name: "Home", kind: .wifi, lastUsed: nil),
        RegisteredNetwork(id: 2, key: "wifi:Phone", name: "Phone", kind: .hotspot, lastUsed: nil),
    ]

    // MARK: Queries

    @Test func monthCoversTheCalendarMonthAndComparesTheSameElapsedTime() {
        let query = HistoryQuery.make(
            range: .month, anchor: Self.october15Noon, network: 2, firstHour: nil, now: Self.october15Noon,
            calendar: Self.calendar)
        #expect(query.interval == DateInterval(start: Self.october1, end: Self.november1))
        // 14.5 days into October; the same 14.5 days of September.
        #expect(query.previous == DateInterval(start: Self.september1, duration: 14.5 * 86_400))
        #expect(query.step == .day)
        #expect(query.network == 2)
        #expect(query.json == """
            {"start": 1790805600, "end": 1793487600, "step": "day", "previous_start": 1788213600, \
            "previous_end": 1789466400, "network": 2}
            """)
    }

    @Test func aFinishedMonthComparesWithNoneOfItsOwnDays() {
        // October has 31 days, September 30: 31 days from 1 September would reach 1 October.
        let november2 = Self.calendar.date(byAdding: .day, value: 1, to: Self.november1)!
        let query = HistoryQuery.make(
            range: .month, anchor: Self.october15Noon, network: nil, firstHour: nil, now: november2,
            calendar: Self.calendar)
        #expect(query.previous == DateInterval(start: Self.september1, end: Self.october1))
    }

    @Test func aWeekStartsOnTheCalendarsFirstWeekday() {
        let query = HistoryQuery.make(
            range: .week, anchor: Self.october27At9, network: nil, firstHour: nil, now: Self.october28,
            calendar: Self.calendar)
        // Monday 26 October to Monday 2 November; 26 October is a 24-hour day after the change.
        #expect(query.interval.start == Self.october26)
        #expect(query.interval.duration == 7 * 86_400)
        #expect(query.json.contains("\"network\"") == false, "every network")
    }

    @Test func eachRangeHasItsBars() {
        func step(_ range: HistoryRange) -> HistoryStep {
            HistoryQuery.make(
                range: range, anchor: Self.october27At9, network: nil, firstHour: nil, now: Self.october28,
                calendar: Self.calendar
            ).step
        }
        #expect(step(.day) == .hour)
        #expect(step(.week) == .day)
        #expect(step(.month) == .day)
        #expect(step(.year) == .month)
    }

    @Test func allTimeBeforeTheFirstHourIsKnownReadsEverythingByMonth() {
        let query = HistoryQuery.make(
            range: .all, anchor: Self.october28, network: nil, firstHour: nil, now: Self.october28,
            calendar: Self.calendar)
        #expect(query.interval.start == Date(timeIntervalSince1970: 0))
        #expect(query.step == .month)
    }

    @Test func allTimeStartsAtTheFirstHourAndShowsMonthsPastThreeMonths() {
        let recent = HistoryQuery.make(
            range: .all, anchor: Self.october28, network: nil, firstHour: Self.october1, now: Self.october28,
            calendar: Self.calendar)
        #expect(recent.interval.start == Self.october1)
        #expect(recent.interval.end == Self.calendar.date(byAdding: .day, value: 1, to: Self.october28))
        #expect(recent.previous == nil)
        #expect(recent.step == .day)
        let longAgo = Self.calendar.date(byAdding: .day, value: -(HistoryQuery.allTimeDays + 1), to: Self.october28)!
        let long = HistoryQuery.make(
            range: .all, anchor: Self.october28, network: nil, firstHour: longAgo, now: Self.october28,
            calendar: Self.calendar)
        #expect(long.step == .month)
    }

    // MARK: Content

    /// October 2026 up to the 28th, all networks. Interfaces: Home 700 + 100 (300 on the 26th,
    /// 500 on the 27th), Phone 100 (26th), no network 100 (27th): 1,000. Apps: Safari 440 on Home
    /// and 80 on Phone, Mail 160 on Home; the other 320 is overhead. September's same span: 800.
    let october = HistoryData(
        firstHour: 1_788_000_000,
        interfaces: ByteCounts(rx: 900, tx: 100),
        previous: 800,
        bars: [
            .init(firstHour: 1_792_969_200, network: 1, rx: 300, tx: 0),
            .init(firstHour: 1_792_969_200, network: 2, rx: 100, tx: 0),
            .init(firstHour: 1_793_088_000, network: 0, rx: 100, tx: 0),
            .init(firstHour: 1_793_088_000, network: 1, rx: 400, tx: 100),
        ],
        networks: [
            .init(network: 1, interfaces: ByteCounts(rx: 700, tx: 100), apps: ByteCounts(rx: 550, tx: 50)),
            .init(network: 2, interfaces: ByteCounts(rx: 100, tx: 0), apps: ByteCounts(rx: 80, tx: 0)),
            .init(network: 0, interfaces: ByteCounts(rx: 100, tx: 0), apps: .zero),
        ],
        apps: [
            .init(network: 2, id: "/Applications/Safari.app", name: "Safari", rx: 80, tx: 0),
            .init(network: 1, id: "/Applications/Safari.app", name: "Safari", rx: 400, tx: 40),
            .init(network: 1, id: "/Applications/Mail.app", name: "Mail", rx: 150, tx: 10),
        ],
        busiestDay: .init(firstHour: 1_793_088_000, bytes: 600),
        heatmap: [
            .init(weekday: 1, hour: 0, bytes: 400),
            .init(weekday: 2, hour: 9, bytes: 600),
        ])

    func content(_ data: HistoryData) -> HistoryContent {
        let query = HistoryQuery.make(
            range: .month, anchor: Self.october27At9, network: nil, firstHour: nil, now: Self.october28,
            calendar: Self.calendar)
        return HistoryContent.make(
            range: .month, query: query, data: data, registry: registry, now: Self.october28, calendar: Self.calendar)
    }

    @Test func tilesCountTheElapsedDaysOnTheCalendar() {
        let c = content(october)
        #expect(c.title == "All Networks")
        #expect(c.subtitle == "October 2026")
        #expect(c.total == ByteCounts(rx: 900, tx: 100))
        #expect(c.change == 0.25)
        // 27 days and the hour 25 October gave back: still 27 days, not 28.
        #expect(c.elapsedDays == 27)
        #expect(c.dailyAverage == 1_000 / 27)
        #expect(c.busiestDay?.start == Self.calendar.startOfDay(for: Self.october27At9))
        #expect(c.busiestDay?.bytes == 600)
    }

    @Test func barsStackInRegistryOrderWithNoNetworkOnTop() {
        let c = content(october)
        let oct27 = Self.calendar.startOfDay(for: Self.october27At9)
        #expect(c.bars.map(\.start) == [Self.october26, Self.october26, oct27, oct27])
        #expect(c.bars.map(\.network.id) == [1, 2, 1, 0])
        #expect(c.bars.map(\.low) == [0, 300, 0, 500])
        #expect(c.bars.map(\.high) == [300, 400, 500, 600])
        #expect(c.tooltips[oct27]?.total == 600)
        #expect(c.tooltips[oct27]?.rows.map(\.network.name) == ["Home", PopoverContent.unknownNetworkName])
        #expect(c.peakBar == 600)
        // Over the 27 days elapsed, not only the 2 with bytes.
        #expect(c.barAverage == 1_000 / 27)
        #expect(c.legend.map(\.id) == [1, 2, 0])
        #expect(c.legend.map(\.slot) == [0, 1, nil])
        // The axis starts and ends on whole days.
        #expect(c.chartDomain == Self.october1...Self.november1)
    }

    @Test func appsAreSplitByNetworkAndTheRestIsOverhead() {
        let c = content(october)
        #expect(c.apps.map(\.title) == ["Safari", "Mail"])
        #expect(c.apps[0].bytes == ByteCounts(rx: 480, tx: 40))
        #expect(c.apps[0].share == 0.52)
        // Home before Phone, as in the registry, whatever order the rows came in.
        #expect(c.apps[0].segments == [.init(slot: 0, bytes: 440), .init(slot: 1, bytes: 80)])
        #expect(c.apps[0].networks.map(\.network.name) == ["Home", "Phone"])
        #expect(c.apps[1].share == 0.16)
        #expect(c.overhead.bytes == ByteCounts(rx: 270, tx: 50))
        #expect(c.overhead.share == 0.32)
        #expect(c.appsScale == 520)
    }

    @Test func sharesFollowTheInterfaces() {
        let c = content(october)
        #expect(c.shares.map(\.network.name) == ["Home", "Phone", PopoverContent.unknownNetworkName])
        #expect(c.shares.map(\.bytes) == [800, 100, 100])
        #expect(c.shares.map(\.share) == [0.8, 0.1, 0.1])
    }

    @Test func heatmapRowsFollowTheCalendarsWeek() throws {
        let heatmap = try #require(content(october).heatmap)
        #expect(heatmap.rows.map(\.weekday) == ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"])
        #expect(heatmap.rows[0].hours[0] == 400)
        #expect(heatmap.rows[1].hours[9] == 600)
        #expect(heatmap.peak?.weekday == "Tue")
        #expect(heatmap.peak?.hour == 9)
    }

    @Test func aRangeWithNothingRecordedShowsZeros() {
        let c = content(.empty)
        #expect(c.total == .zero)
        #expect(c.change == nil)
        #expect(c.bars.isEmpty)
        #expect(c.barAverage == nil)
        #expect(c.busiestDay == nil)
        #expect(c.apps.isEmpty)
        #expect(c.overhead.bytes == .zero)
        #expect(c.heatmap?.peak == nil)
    }

    @Test func aPreviousPeriodWithNothingGivesNoChange() {
        let data = HistoryData(
            firstHour: nil, interfaces: ByteCounts(rx: 10, tx: 0), previous: 0, bars: [], networks: [], apps: [],
            busiestDay: nil, heatmap: [])
        #expect(content(data).change == nil)
    }

    @Test func aDayHasNoHeatmap() {
        let query = HistoryQuery.make(
            range: .day, anchor: Self.october27At9, network: 1, firstHour: nil, now: Self.october28,
            calendar: Self.calendar)
        let c = HistoryContent.make(
            range: .day, query: query, data: october, registry: registry, now: Self.october28, calendar: Self.calendar)
        #expect(c.heatmap == nil)
        #expect(c.title == "Home")
        #expect(c.subtitle == "Tuesday, October 27, 2026")
    }

    @Test func networksWithTheSameNameStaySeparateInTheChart() {
        let registry = [
            RegisteredNetwork(id: 1, key: "wifi:a", name: "Home", kind: .wifi, lastUsed: nil),
            RegisteredNetwork(id: 2, key: "wifi:b", name: "Home", kind: .wifi, lastUsed: nil),
            RegisteredNetwork(id: 3, key: "wifi:c", name: PopoverContent.unknownNetworkName, kind: .wifi, lastUsed: nil),
        ]
        let styles = HistoryContent.networkStyles(registry: registry)
        #expect(styles[1]?.label == "Home")
        #expect(styles[2]?.label == "Home (2)")
        #expect(styles[2]?.name == "Home", "the sidebar and lists keep the name")
        // No network keeps its plain name in the chart.
        #expect(styles[3]?.label == "\(PopoverContent.unknownNetworkName) (2)")
        #expect(Set(styles.values.map(\.slot)).count == 3)
        // A suffix never lands on a name another network already has.
        let clash = HistoryContent.networkStyles(registry: [
            RegisteredNetwork(id: 1, key: "wifi:a", name: "Home", kind: .wifi, lastUsed: nil),
            RegisteredNetwork(id: 2, key: "wifi:b", name: "Home (2)", kind: .wifi, lastUsed: nil),
            RegisteredNetwork(id: 3, key: "wifi:c", name: "Home", kind: .wifi, lastUsed: nil),
        ])
        #expect(clash[3]?.label == "Home (3)")
        #expect(Set(clash.values.map(\.label)).count == 3)
    }

    // MARK: Pieces

    @Test func aTinySegmentIsDrawnWithNoHeightInsteadOfBelowZero() {
        let segment = HistoryContent.BarSegment(
            start: Self.october26,
            network: .init(id: 1, name: "Home", kind: .wifi, slot: 0), bytes: 3, low: 0, high: 3)
        #expect(segment.drawn(gap: 10) == (low: 0, high: 0))
        let upper = HistoryContent.BarSegment(
            start: Self.october26,
            network: .init(id: 1, name: "Home", kind: .wifi, slot: 0), bytes: 100, low: 100, high: 200)
        // 5 bytes off each side of the 10-byte gap.
        #expect(upper.drawn(gap: 10) == (low: 105, high: 195))
        let sliver = HistoryContent.BarSegment(
            start: Self.october26,
            network: .init(id: 1, name: "Home", kind: .wifi, slot: 0), bytes: 4, low: 100, high: 104)
        #expect(sliver.drawn(gap: 10) == (low: 105, high: 105))
    }

    @Test func stepsCountOnlyThoseThatHaveBegun() {
        let c = Self.calendar
        #expect(HistoryContent.countSteps(.day, from: Self.october1, to: Self.october28, calendar: c) == 27)
        #expect(HistoryContent.countSteps(.day, from: Self.october1, to: Self.october27At9, calendar: c) == 27)
        #expect(HistoryContent.countSteps(.month, from: Self.september1, to: Self.october15Noon, calendar: c) == 2)
        #expect(HistoryContent.countSteps(.hour, from: Self.october28, to: Self.october28, calendar: c) == 0)
    }

    @Test func aHalfHourZonePlacesAnHourByItsMiddle() {
        var india = Calendar(identifier: .gregorian)
        india.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        // 18:00 UTC on 26 October is 23:30 in India; most of that hour is the 27th.
        let hour: Int64 = 1_793_037_600
        let start = HistoryContent.barStart(firstHour: hour, step: .day, calendar: india)
        #expect(india.component(.day, from: start) == 27)
        #expect(india.component(.hour, from: start) == 0)
    }
}
