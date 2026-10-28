import AppKit
import Charts
import SwiftUI

/// The History window's content, laid out as `prototypes/ui-spike` and `docs/mockups/history.png`:
/// networks in the sidebar, ranges in the toolbar, the range's numbers in the detail.
struct HistoryView: View {
    enum SidebarItem: Hashable {
        case all
        case network(Int64)
    }

    @Bindable var model: HistoryModel

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { model.network.map(SidebarItem.network) ?? .all },
                set: { item in
                    switch item {
                    case .network(let id): model.select(network: .some(id))
                    case .all, nil: model.select(network: .some(nil))
                    }
                })
            ) {
                Label(HistoryContent.allNetworksTitle, systemImage: "globe").tag(SidebarItem.all)
                ForEach(NetworkKind.allCases, id: \.self) { kind in
                    let networks = model.registry.enumerated().filter { $0.element.kind == kind }
                    if !networks.isEmpty {
                        Section(kind.label) {
                            ForEach(networks, id: \.element.id) { index, network in
                                Label {
                                    Text(network.name)
                                } icon: {
                                    Image(systemName: kind.symbol)
                                        .foregroundStyle(NetworkColor.color(slot: NetworkColor.slot(forIndex: index)))
                                }
                                .badge(network.id == model.currentNetwork ? Text("Connected").font(.caption2) : nil)
                                .tag(SidebarItem.network(network.id))
                            }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            HistoryDetail(
                content: model.content, expandedApp: $model.expandedApp, hoverDate: $model.hoverDate,
                showsAllApps: $model.showsAllApps)
        }
    }
}

/// The detail column: title, stat tiles, chart, apps, share by network and heatmap.
struct HistoryDetail: View {
    let content: HistoryContent
    @Binding var expandedApp: String?
    @Binding var hoverDate: Date?
    @Binding var showsAllApps: Bool

    private var showsShares: Bool {
        content.legend.count > 1 || content.title == HistoryContent.allNetworksTitle
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(content.title).font(.largeTitle.weight(.semibold))
                    Text(content.subtitle).foregroundStyle(.secondary)
                }
                StatTiles(content: content)
                UsageChart(content: content, hoverDate: $hoverDate)
                HStack(alignment: .top, spacing: 16) {
                    AppsCard(content: content, expandedApp: $expandedApp, showsAll: $showsAllApps)
                    // A single network on a Day has neither card: the apps then take the width.
                    if showsShares || content.heatmap != nil {
                        VStack(spacing: 16) {
                            if showsShares {
                                SharesCard(content: content)
                            }
                            if let heatmap = content.heatmap {
                                HeatmapCard(heatmap: heatmap)
                            }
                        }
                        .frame(width: 340)
                    }
                }
            }
            .padding(20)
        }
    }
}

private struct StatTiles: View {
    let content: HistoryContent

    var body: some View {
        HStack(spacing: 12) {
            Tile(title: "Total") {
                Text(Format.bytes(content.total.total)).font(.system(size: 26, weight: .semibold, design: .rounded))
                if let change = content.change {
                    Label(
                        "\(abs(change).formatted(.percent.precision(.fractionLength(0)))) vs previous \(content.range.label.lowercased())",
                        systemImage: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Tile(title: "Download / upload") {
                Label(Format.bytes(content.total.rx), systemImage: "arrow.down").font(.headline)
                Label(Format.bytes(content.total.tx), systemImage: "arrow.up").font(.subheadline).foregroundStyle(.secondary)
                RatioBar(down: content.total.rx, up: content.total.tx).frame(height: 5)
            }
            Tile(title: "Daily average") {
                Text(Format.bytes(content.dailyAverage)).font(.title3.weight(.semibold))
                Text("over \(content.elapsedDays) day\(content.elapsedDays == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Tile(title: "Busiest day") {
                Text(content.busiestDay.map { Format.bytes($0.bytes) } ?? "–").font(.title3.weight(.semibold))
                Text(content.busiestDay.map { busiestDayLabel($0.start) } ?? " ")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .monospacedDigit()
    }
}

/// "Sunday, 4 Oct", with the year when it is not this year's.
private func busiestDayLabel(_ date: Date) -> String {
    let sameYear = Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
    return date.formatted(sameYear ? .dateTime.weekday(.wide).day().month() : .dateTime.weekday(.wide).day().month().year())
}

private struct RatioBar: View {
    let down: UInt64
    let up: UInt64

    var body: some View {
        GeometryReader { geo in
            let total = max(Double(down + up), 1)
            let width = max(0, geo.size.width - 2)
            HStack(spacing: 2) {
                Capsule().fill(.primary.opacity(0.75)).frame(width: width * Double(down) / total)
                Capsule().fill(.primary.opacity(0.3))
            }
        }
    }
}

private struct UsageChart: View {
    let content: HistoryContent
    @Binding var hoverDate: Date?

    private var unit: Calendar.Component { content.step.component }

    private var hovered: Date? {
        hoverDate.flatMap { Calendar.current.dateInterval(of: unit, for: $0)?.start }
    }

    var body: some View {
        Card(title: content.legend.count > 1 || content.title == HistoryContent.allNetworksTitle ? "Usage by network" : "Usage") {
            if content.bars.isEmpty {
                Text("Nothing was recorded in this range.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                chart
            }
        }
    }

    private var chart: some View {
        // A 2 pt gap between stacked segments, in bytes at a 240 pt chart.
        let gap = content.peakBar / 110
        return Chart {
            ForEach(content.bars) { bar in
                let drawn = bar.drawn(gap: gap)
                BarMark(
                    x: .value("Time", bar.start, unit: unit),
                    yStart: .value("Bytes", drawn.low),
                    yEnd: .value("Bytes", drawn.high),
                    width: .ratio(0.7)
                )
                .foregroundStyle(by: .value("Network", bar.network.name))
                .cornerRadius(2)
                .opacity(hovered == nil || hovered == bar.start ? 1 : 0.45)
            }
            if let average = content.barAverage {
                RuleMark(y: .value("Average", average))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary)
                    .annotation(position: .top, alignment: .leading) {
                        Text("avg \(Format.bytes(average))").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            if let hovered, let tooltip = content.tooltips[hovered] {
                RuleMark(x: .value("Time", hovered, unit: unit))
                    .foregroundStyle(.clear)
                    .annotation(
                        position: .top, spacing: 0,
                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                    ) {
                        TooltipView(tooltip: tooltip, step: content.step)
                    }
            }
        }
        .chartForegroundStyleScale(
            domain: content.legend.map(\.name),
            range: content.legend.map { $0.kind == nil ? Color.gray : NetworkColor.color(slot: $0.slot) })
        .chartLegend(content.legend.count > 1 ? .visible : .hidden)
        .chartLegend(position: .top, alignment: .leading)
        .chartXSelection(value: $hoverDate)
        .chartXScale(domain: content.chartDomain)
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel(format: axisFormat)
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let bytes = value.as(UInt64.self) { Text(bytes == 0 ? "0" : Format.bytes(bytes)) }
                }
            }
        }
        .frame(height: 240)
    }

    private var axisFormat: Date.FormatStyle {
        switch content.step {
        case .hour: .dateTime.hour()
        case .day: .dateTime.day().month(.abbreviated)
        case .month: .dateTime.month(.abbreviated)
        }
    }
}

private struct TooltipView: View {
    let tooltip: HistoryContent.Tooltip
    let step: HistoryStep

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tooltip.start.formatted(title)).font(.caption.weight(.semibold))
            ForEach(tooltip.rows, id: \.network.id) { row in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(color(row.network)).frame(width: 8, height: 8)
                    Text(row.network.name)
                    Spacer(minLength: 12)
                    Text(Format.bytes(row.bytes)).monospacedDigit()
                }
                .font(.caption)
            }
            Divider()
            HStack {
                Text("Total")
                Spacer()
                Text(Format.bytes(tooltip.total)).monospacedDigit()
            }
            .font(.caption.weight(.semibold))
        }
        .padding(8)
        .frame(width: 210)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
    }

    private var title: Date.FormatStyle {
        switch step {
        case .hour: .dateTime.weekday().day().month().hour()
        case .day: .dateTime.weekday().day().month()
        case .month: .dateTime.month(.wide).year()
        }
    }
}

private func color(_ network: HistoryContent.NetworkStyle) -> Color {
    network.kind == nil ? .gray : NetworkColor.color(slot: network.slot)
}

private struct AppsCard: View {
    let content: HistoryContent
    @Binding var expandedApp: String?
    @Binding var showsAll: Bool

    var body: some View {
        let apps = showsAll ? content.apps : Array(content.apps.prefix(HistoryModel.visibleApps))
        Card(title: "Apps", trailing: content.legend.count > 1 ? "Bars split by network" : nil) {
            VStack(spacing: 12) {
                if content.apps.isEmpty {
                    Text("No app was credited in this range.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(apps) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        AppRowView(row: row, scale: content.appsScale)
                            .contentShape(.rect)
                            .onTapGesture { expandedApp = expandedApp == row.id ? nil : row.id }
                        if expandedApp == row.id { NetworkSplitView(splits: row.networks) }
                    }
                }
                AppRowView(row: content.overhead, scale: content.appsScale)
                    .help("Bytes that crossed the network but no app's connections carry: packet headers, acknowledgements and system traffic.")
                if content.apps.count > HistoryModel.visibleApps {
                    Button(showsAll ? "Show fewer" : "Show all \(content.apps.count) apps") { showsAll.toggle() }
                        .buttonStyle(.link)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct AppRowView: View {
    let row: HistoryContent.AppRow
    let scale: UInt64

    var body: some View {
        HStack(spacing: 10) {
            RowIcon(icon: row.icon).frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.title).lineLimit(1)
                    Spacer()
                    Text(row.share.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption).foregroundStyle(.tertiary)
                    Text(Format.bytes(row.bytes.total)).foregroundStyle(.secondary)
                }
                .monospacedDigit()
                SegmentedBar(segments: row.segments, scale: scale).frame(height: 5)
            }
        }
        .help("↓ \(Format.bytes(row.bytes.rx))   ↑ \(Format.bytes(row.bytes.tx))")
    }
}

/// Where one app's bytes went: download and upload per network.
private struct NetworkSplitView: View {
    let splits: [HistoryContent.NetworkSplit]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            ForEach(splits) { split in
                GridRow {
                    RoundedRectangle(cornerRadius: 2).fill(color(split.network)).frame(width: 8, height: 8)
                    Text(split.network.name).lineLimit(1)
                    Text(split.network.kind?.label ?? "").foregroundStyle(.secondary)
                    Spacer()
                    Text("↓ \(Format.bytes(split.bytes.rx))").gridColumnAlignment(.trailing)
                    Text("↑ \(Format.bytes(split.bytes.tx))").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
        .monospacedDigit()
        .padding(10)
        .padding(.leading, 20)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
    }
}

private struct SharesCard: View {
    let content: HistoryContent

    var body: some View {
        Card(title: "Share by network") {
            SegmentedBar(
                segments: content.shares.map { PopoverContent.Segment(slot: $0.network.slot, bytes: $0.bytes) },
                scale: max(content.total.total, 1)
            )
            .frame(height: 12)
            VStack(spacing: 8) {
                ForEach(content.shares) { row in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(color(row.network)).frame(width: 10, height: 10)
                        Image(systemName: row.network.kind?.symbol ?? unknownNetworkSymbol)
                            .foregroundStyle(.secondary).frame(width: 16)
                        Text(row.network.name).lineLimit(1)
                        Spacer()
                        Text(row.share.formatted(.percent.precision(.fractionLength(0)))).foregroundStyle(.tertiary)
                        Text(Format.bytes(row.bytes)).foregroundStyle(.secondary).frame(width: 76, alignment: .trailing)
                    }
                    .font(.callout)
                    .monospacedDigit()
                }
            }
        }
    }
}

private struct HeatmapCard: View {
    let heatmap: HistoryContent.Heatmap
    @State private var hovered: (row: Int, hour: Int)?

    /// The blue magnitude ramp (docs/design.md, Visual language); the low end recedes into the card.
    static let low = Color(light: 0xCDE2FB, dark: 0x16263A)
    static let high = Color(light: 0x184F95, dark: 0x9EC5F4)
    static let labelWidth: CGFloat = 30
    static let rowHeight: CGFloat = 14
    static let spacing: CGFloat = 2
    static let gridHeight = 7 * rowHeight + 6 * spacing

    var body: some View {
        Card(title: "When you use data", trailing: trailing) {
            HStack(alignment: .top, spacing: Self.spacing) {
                VStack(alignment: .leading, spacing: Self.spacing) {
                    ForEach(heatmap.rows, id: \.weekday) { row in
                        Text(row.weekday).font(.caption2).foregroundStyle(.secondary)
                            .frame(width: Self.labelWidth, height: Self.rowHeight, alignment: .leading)
                    }
                }
                // One canvas for the 168 cells: a view per cell costs a layout and a tooltip each.
                GeometryReader { geo in
                    Canvas { context, size in
                        draw(in: &context, size: size)
                    }
                    .frame(height: Self.gridHeight)
                    .onContinuousHover { phase in
                        hovered = if case .active(let point) = phase { cell(at: point, width: geo.size.width) } else { nil }
                    }
                    ForEach([0, 6, 12, 18], id: \.self) { hour in
                        Text("\(hour)").font(.caption2).foregroundStyle(.secondary).fixedSize()
                            .position(
                                x: CGFloat(hour) * (cellWidth(geo.size.width) + Self.spacing) + cellWidth(geo.size.width) / 2,
                                y: Self.gridHeight + 10)
                    }
                }
                .frame(height: Self.gridHeight + 20)
            }
            HStack(spacing: 6) {
                Text("Less")
                LinearGradient(colors: [Self.low, Self.high], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 80, height: 6).clipShape(.capsule)
                Text("More")
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// The hovered cell's value, else the peak.
    private var trailing: String? {
        if let hovered {
            let row = heatmap.rows[hovered.row]
            return "\(row.weekday) \(hovered.hour):00 · \(Format.bytes(row.hours[hovered.hour]))"
        }
        return heatmap.peak.map { "Peak: \($0.weekday) \($0.hour):00" }
    }

    private func cell(at point: CGPoint, width: CGFloat) -> (row: Int, hour: Int)? {
        let row = Int(point.y / (Self.rowHeight + Self.spacing))
        let hour = Int(point.x / (cellWidth(width) + Self.spacing))
        guard heatmap.rows.indices.contains(row), (0..<24).contains(hour), point.x >= 0, point.y >= 0 else { return nil }
        return (row, hour)
    }

    private func cellWidth(_ width: CGFloat) -> CGFloat {
        max(1, (width - 23 * Self.spacing) / 24)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let peak = Double(max(heatmap.peak?.bytes ?? 1, 1))
        let width = cellWidth(size.width)
        for (r, row) in heatmap.rows.enumerated() {
            for hour in 0..<24 {
                let rect = CGRect(
                    x: CGFloat(hour) * (width + Self.spacing), y: CGFloat(r) * (Self.rowHeight + Self.spacing),
                    width: width, height: Self.rowHeight)
                let path = Path(roundedRect: rect, cornerRadius: 2)
                context.fill(path, with: .color(Self.low))
                context.fill(path, with: .color(Self.high.opacity(Double(row.hours[hour]) / peak)))
            }
        }
    }
}

private struct Tile<Content: View>: View {
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
    var trailing: String?
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
