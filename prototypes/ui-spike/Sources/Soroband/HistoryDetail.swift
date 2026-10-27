import Charts
import SwiftUI

struct HistoryDetail: View {
    @Environment(UsageStore.self) private var store
    let networkID: String?
    let range: HistoryRange
    let anchor: Date
    @State var expandedApp: String?
    @State var hoverDate: Date?

    private let calendar = Calendar.current

    private var interval: DateInterval {
        guard let period = range.period else {
            return DateInterval(start: calendar.startOfDay(for: store.firstRecordDate), end: .now)
        }
        return calendar.dateInterval(of: period, for: anchor)!
    }

    /// The same elapsed span one period earlier, so a month in progress compares fairly.
    private var previousInterval: DateInterval? {
        guard let period = range.period else { return nil }
        let start = calendar.date(byAdding: period, value: -1, to: interval.start)!
        return DateInterval(start: start, duration: min(interval.end, .now).timeIntervalSince(interval.start))
    }

    var body: some View {
        let records = store.records(in: interval, network: networkID)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                title
                statTiles(records)
                chartCard(records)
                HStack(alignment: .top, spacing: 16) {
                    appsCard(records)
                    VStack(spacing: 16) {
                        if networkID == nil { networksCard(records) }
                        if range != .day { heatmapCard(records) }
                    }
                    .frame(width: 340)
                }
            }
            .padding(20)
        }
        .navigationTitle(networkID.map { store.network($0).name } ?? "All Networks")
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(networkID.map { store.network($0).name } ?? "All Networks")
                .font(.largeTitle.weight(.semibold))
            Text(intervalLabel).foregroundStyle(.secondary)
        }
    }

    private var intervalLabel: String {
        switch range {
        case .day: anchor.formatted(date: .complete, time: .omitted)
        case .year: anchor.formatted(.dateTime.year())
        case .month: anchor.formatted(.dateTime.month(.wide).year())
        case .week, .all: "\(interval.start.formatted(date: .abbreviated, time: .omitted)) – \(interval.end.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted))"
        }
    }

    // MARK: Stat tiles

    private func statTiles(_ records: [UsageRecord]) -> some View {
        let totals = records.totals
        let days = Dictionary(grouping: records) { calendar.startOfDay(for: $0.hour) }.mapValues { $0.totals.total }
        let busiest = days.max { $0.value < $1.value }
        let elapsedDays = max(1, (min(interval.end, .now).timeIntervalSince(interval.start) / 86_400).rounded(.up))
        let previous = previousInterval.map { store.records(in: $0, network: networkID).totals.total } ?? 0

        return HStack(spacing: 12) {
            StatTile(title: "Total") {
                Text(formatBytes(totals.total)).font(.system(size: 26, weight: .semibold, design: .rounded))
                if previous > 0 {
                    let change = Double(totals.total - previous) / Double(previous)
                    Label("\(abs(change).formatted(.percent.precision(.fractionLength(0)))) vs previous \(range.rawValue.lowercased())",
                          systemImage: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            StatTile(title: "Download / upload") {
                Label(formatBytes(totals.down), systemImage: "arrow.down").font(.headline)
                Label(formatBytes(totals.up), systemImage: "arrow.up").font(.subheadline).foregroundStyle(.secondary)
                SegmentedBar(segments: [Segment(color: .primary.opacity(0.75), bytes: totals.down),
                                        Segment(color: .primary.opacity(0.3), bytes: totals.up)],
                             scale: max(totals.total, 1))
                    .frame(height: 5)
            }
            StatTile(title: "Daily average") {
                Text(formatBytes(totals.total / Int64(elapsedDays))).font(.title3.weight(.semibold))
                Text("over \(Int(elapsedDays)) day\(elapsedDays == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            }
            StatTile(title: "Busiest day") {
                Text(busiest.map { formatBytes($0.value) } ?? "–").font(.title3.weight(.semibold))
                Text(busiest.map { $0.key.formatted(.dateTime.weekday(.wide).day().month()) } ?? " ")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .monospacedDigit()
    }

    // MARK: Usage over time

    private struct Bar: Identifiable {
        let id: String
        let start: Date
        let networkID: String
        let yStart: Int64
        let yEnd: Int64
    }

    private func bucketTotals(_ records: [UsageRecord]) -> [Date: [String: Int64]] {
        var sums: [Date: [String: Int64]] = [:]
        for r in records {
            let start = calendar.dateInterval(of: range.bucket, for: r.hour)!.start
            sums[start, default: [:]][r.networkID, default: 0] += r.total
        }
        return sums
    }

    /// Stacks in fixed network order, leaving a ~2pt surface gap between segments.
    private func bars(_ sums: [Date: [String: Int64]], gap: Int64) -> [Bar] {
        sums.flatMap { start, byNetwork in
            var y: Int64 = 0
            return store.networks.compactMap { net -> Bar? in
                guard let bytes = byNetwork[net.id], bytes > 0 else { return nil }
                defer { y += bytes }
                let bar = Bar(id: "\(start.timeIntervalSince1970)\(net.id)", start: start, networkID: net.id,
                              yStart: y == 0 ? 0 : y + gap / 2, yEnd: y + bytes - gap / 2)
                return bar.yEnd > bar.yStart ? bar : nil
            }
        }
    }

    private func chartCard(_ records: [UsageRecord]) -> some View {
        let sums = bucketTotals(records)
        let peak = sums.values.map { $0.values.reduce(0, +) }.max() ?? 0
        let average = sums.isEmpty ? 0 : sums.values.map { $0.values.reduce(0, +) }.reduce(0, +) / Int64(sums.count)
        let hovered = hoverDate.flatMap { calendar.dateInterval(of: range.bucket, for: $0)?.start }
        let single = networkID.map(store.network)

        return Card(title: single == nil ? "Usage by network" : "Usage") {
            Chart {
                ForEach(bars(sums, gap: peak / 110)) { bar in
                    BarMark(
                        x: .value("Time", bar.start, unit: range.bucket),
                        yStart: .value("Bytes", bar.yStart),
                        yEnd: .value("Bytes", bar.yEnd),
                        width: .ratio(0.7)
                    )
                    .foregroundStyle(by: .value("Network", store.network(bar.networkID).name))
                    .cornerRadius(2)
                    .opacity(hovered == nil || hovered == bar.start ? 1 : 0.45)
                }
                if average > 0 {
                    RuleMark(y: .value("Average", average))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.secondary)
                        .annotation(position: .top, alignment: .leading) {
                            Text("avg \(formatBytes(average))").font(.caption2).foregroundStyle(.secondary)
                        }
                }
                if let hovered, let byNetwork = sums[hovered] {
                    RuleMark(x: .value("Time", hovered, unit: range.bucket))
                        .foregroundStyle(.clear)
                        .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            tooltip(start: hovered, byNetwork: byNetwork)
                        }
                }
            }
            .chartForegroundStyleScale(domain: store.networks.map(\.name), range: store.networks.map(\.tint))
            .chartLegend(single == nil ? .visible : .hidden)
            .chartLegend(position: .top, alignment: .leading)
            .chartXSelection(value: $hoverDate)
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel(format: axisFormat)
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel {
                        if let bytes = value.as(Int64.self) { Text(bytes == 0 ? "0" : formatBytes(bytes)) }
                    }
                }
            }
            .frame(height: 240)
        }
    }

    private func tooltip(start: Date, byNetwork: [String: Int64]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(start.formatted(range.bucket == .hour ? .dateTime.weekday().hour() : .dateTime.weekday().day().month()))
                .font(.caption.weight(.semibold))
            ForEach(store.networks.filter { byNetwork[$0.id] != nil }) { net in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(net.tint).frame(width: 8, height: 8)
                    Text(net.name)
                    Spacer(minLength: 12)
                    Text(formatBytes(byNetwork[net.id]!)).monospacedDigit()
                }
                .font(.caption)
            }
            Divider()
            HStack {
                Text("Total")
                Spacer()
                Text(formatBytes(byNetwork.values.reduce(0, +))).monospacedDigit()
            }
            .font(.caption.weight(.semibold))
        }
        .padding(8)
        .frame(width: 200)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
    }

    private var axisFormat: Date.FormatStyle {
        switch range.bucket {
        case .hour: .dateTime.hour()
        case .month: .dateTime.month(.abbreviated)
        default: .dateTime.day().month(.abbreviated)
        }
    }

    // MARK: Apps

    private func appsCard(_ records: [UsageRecord]) -> some View {
        let rows = records.grouped(by: \.appID)
        let total = max(records.totals.total, 1)
        let maxTotal = rows.first?.totals.total ?? 1
        return Card(title: "Apps", trailing: networkID == nil ? "Bars split by network" : nil) {
            VStack(spacing: 12) {
                ForEach(rows, id: \.id) { row in
                    let app = store.app(row.id)
                    let appRecords = records.filter { $0.appID == row.id }
                    VStack(alignment: .leading, spacing: 6) {
                        UsageRow(title: app.name, totals: row.totals, scale: maxTotal,
                                 segments: store.networkSegments(appRecords),
                                 share: Double(row.totals.total) / Double(total)) {
                            AppIconView(app: app)
                        }
                        .contentShape(.rect)
                        .onTapGesture { expandedApp = expandedApp == row.id ? nil : row.id }
                        if expandedApp == row.id { appNetworkSplit(appRecords) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Clicking an app shows where its traffic went: per network, with download and upload.
    private func appNetworkSplit(_ records: [UsageRecord]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            ForEach(records.grouped(by: \.networkID), id: \.id) { row in
                let net = store.network(row.id)
                GridRow {
                    RoundedRectangle(cornerRadius: 2).fill(net.tint).frame(width: 8, height: 8)
                    Text(net.name)
                    Text(net.kind.label).foregroundStyle(.secondary)
                    Spacer()
                    Text("↓ \(formatBytes(row.totals.down))").gridColumnAlignment(.trailing)
                    Text("↑ \(formatBytes(row.totals.up))").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
        .monospacedDigit()
        .padding(10)
        .padding(.leading, 20)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
    }

    // MARK: Networks

    private func networksCard(_ records: [UsageRecord]) -> some View {
        let total = max(records.totals.total, 1)
        let byNetwork = Dictionary(uniqueKeysWithValues: records.grouped(by: \.networkID).map { ($0.id, $0.totals) })
        let used = store.networks.filter { byNetwork[$0.id] != nil }
        return Card(title: "Share by network") {
            SegmentedBar(segments: store.networkSegments(records), scale: total).frame(height: 12)
            VStack(spacing: 8) {
                ForEach(used.sorted { byNetwork[$0.id]!.total > byNetwork[$1.id]!.total }) { net in
                    let totals = byNetwork[net.id]!
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(net.tint).frame(width: 10, height: 10)
                        Image(systemName: net.kind.symbol).foregroundStyle(.secondary).frame(width: 16)
                        Text(net.name).lineLimit(1)
                        Spacer()
                        Text((Double(totals.total) / Double(total)).formatted(.percent.precision(.fractionLength(0))))
                            .foregroundStyle(.tertiary)
                        Text(formatBytes(totals.total)).foregroundStyle(.secondary).frame(width: 72, alignment: .trailing)
                    }
                    .font(.callout)
                    .monospacedDigit()
                }
            }
        }
    }

    // MARK: Heatmap

    private struct Cell: Identifiable {
        var id: String { "\(weekday)-\(hour)" }
        let weekday: String
        let hour: Int
        let bytes: Int64
    }

    private func heatmapCard(_ records: [UsageRecord]) -> some View {
        let symbols = calendar.shortWeekdaySymbols
        let order = (0..<7).map { symbols[($0 + calendar.firstWeekday - 1) % 7] }
        var sums: [String: Int64] = [:]
        for r in records {
            let c = calendar.dateComponents([.weekday, .hour], from: r.hour)
            sums["\(symbols[c.weekday! - 1])-\(c.hour!)", default: 0] += r.total
        }
        let cells = order.flatMap { day in (0..<24).map { Cell(weekday: day, hour: $0, bytes: sums["\(day)-\($0)"] ?? 0) } }
        let peak = cells.max { $0.bytes < $1.bytes }

        return Card(title: "When you use data", trailing: peak.map { "Peak: \($0.weekday) \($0.hour):00" }) {
            let maxBytes = max(peak?.bytes ?? 1, 1)
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                ForEach(order, id: \.self) { day in
                    GridRow {
                        Text(day).font(.caption2).foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
                        ForEach(cells.filter { $0.weekday == day }) { cell in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.heatLow)
                                .overlay(RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.heatHigh.opacity(Double(cell.bytes) / Double(maxBytes))))
                                .frame(height: 14)
                                .help("\(day) \(cell.hour):00 · \(formatBytes(cell.bytes))")
                        }
                    }
                }
                GridRow {
                    Color.clear.frame(width: 28, height: 1)
                    ForEach(0..<24, id: \.self) { hour in
                        Text(hour % 6 == 0 ? "\(hour)" : "").font(.caption2).foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
            }
            HStack(spacing: 6) {
                Text("Less")
                LinearGradient(colors: [.heatLow, .heatHigh], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 80, height: 6).clipShape(.capsule)
                Text("More")
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct StatTile<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
    }
}

private struct Card<Content: View>: View {
    let title: String
    var trailing: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                if let trailing { Text(trailing).font(.caption).foregroundStyle(.secondary) }
            }
            content()
        }
        .padding(14)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
    }
}
