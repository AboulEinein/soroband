import AppKit

/// What the History window opens on, as arguments: the menu bar process sends them to the UI
/// process in `UIRequest.showHistory`.
struct HistoryOptions: Equatable {
    var range: HistoryRange = .month
    /// The resource History shows; the data page when nil.
    var measure: ResourceMeasure?
    /// A day in the period to show; today when nil.
    var date: Date?
    /// One network, or every network when nil.
    var network: Int64?
    /// The network the Mac is on, for the sidebar's badge.
    var current: Int64?
    /// When History was asked for, to time the opening from the click.
    var requested: Date?
    /// For captures: an app shown expanded, and a time the chart shows as hovered.
    var expandedApp: String?
    var hover: Date?

    static let flag = "--history"

    var arguments: [String] {
        var arguments = [Self.flag, "--range", range.rawValue]
        if let measure { arguments += ["--measure", measure.rawValue] }
        if let date { arguments += ["--date", Self.format(date)] }
        if let network { arguments += ["--network", String(network)] }
        if let current { arguments += ["--current", String(current)] }
        if let requested { arguments += ["--requested", String(requested.timeIntervalSince1970)] }
        if let expandedApp { arguments += ["--app", expandedApp] }
        if let hover { arguments += ["--hover", Self.format(hover)] }
        return arguments
    }

    /// The options in `arguments`, or nil when they do not ask for History.
    init?(arguments: [String]) {
        guard arguments.contains(Self.flag) else { return nil }
        var values: [String: String] = [:]
        for (index, argument) in arguments.enumerated() where argument.hasPrefix("--") && index + 1 < arguments.count {
            values[argument] = arguments[index + 1]
        }
        range = values["--range"].flatMap(HistoryRange.init(rawValue:)) ?? .month
        measure = values["--measure"].flatMap(ResourceMeasure.init(rawValue:))
        date = values["--date"].flatMap(Self.parse)
        network = values["--network"].flatMap(Int64.init)
        current = values["--current"].flatMap(Int64.init)
        requested = values["--requested"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        expandedApp = values["--app"]
        hover = values["--hover"].flatMap(Self.parse)
    }

    init(
        range: HistoryRange = .month, measure: ResourceMeasure? = nil, date: Date? = nil, network: Int64? = nil,
        current: Int64? = nil, requested: Date? = nil, expandedApp: String? = nil, hover: Date? = nil
    ) {
        self.range = range
        self.measure = measure
        self.date = date
        self.network = network
        self.current = current
        self.requested = requested
        self.expandedApp = expandedApp
        self.hover = hover
    }

    /// Unix seconds, so a date crosses the process boundary whatever the time zone.
    private static func format(_ date: Date) -> String { String(date.timeIntervalSince1970) }
    private static func parse(_ text: String) -> Date? { Double(text).map(Date.init(timeIntervalSince1970:)) }
}
