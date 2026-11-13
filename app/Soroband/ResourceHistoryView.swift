import Charts
import SwiftUI

/// History's detail with a resource picked (`docs/mockups/resources.html`, 2A and 3A): the data
/// page's layout for one measure, and on Day the minute chart with the minute's busiest apps.
struct ResourceHistoryDetail: View {
    let content: ResourceHistoryContent
    /// The Day page's minutes; nil on other ranges and on a day the record does not reach.
    let minutes: MinuteContent?
    let minutesKept: Int
    let settings: ResourceSettings
    @Binding var expandedApp: String?
    @Binding var showsAllApps: Bool
    let expandedMeasures: (bytes: ByteCounts?, resources: ResourceSum?)?
    var selectMinute: (Int64?) -> Void = { _ in }
    var moveMinute: (Int) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(content.title).font(.title2.weight(.bold))
                    Text(content.subtitle).foregroundStyle(.secondary)
                    if content.fallback {
                        Label(
                            "Some hours count your processes only",
                            systemImage: "person.crop.circle.badge.exclamationmark"
                        )
                        .font(.caption).foregroundStyle(.yellow)
                        .help(
                            "macOS did not allow Soroband to read every app's resources then, so apps run as root or by other users are left out of those hours."
                        )
                        .padding(.top, 2)
                    }
                }
                TilesCard(content: content)
                if content.range == .day {
                    if let minutes, !minutes.isEmpty {
                        MinuteCard(content: minutes, measure: content.measure, select: selectMinute, move: moveMinute)
                        MinuteLists(content: minutes)
                    } else {
                        Text(
                            "Minute by minute is kept \(minutesKept) day\(minutesKept == 1 ? "" : "s") (Settings › Resources); this day shows its hours."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ResourceChart(content: content)
                HStack(alignment: .top, spacing: 14) {
                    ResourceAppsCard(
                        content: content, settings: settings, expandedApp: $expandedApp, showsAll: $showsAllApps,
                        expandedMeasures: expandedMeasures)
                    if let heatmap = content.heatmap {
                        HeatmapCard(
                            heatmap: heatmap, title: "When the Mac is busy",
                            format: { Format.resource($0, measure: content.measure) }, tint: content.measure.color
                        )
                        .frame(width: 340)
                    }
                }
            }
            .padding(20)
        }
    }
}

/// The range's headline numbers, with the change against the previous period.
private struct TilesCard: View {
    let content: ResourceHistoryContent

    var body: some View {
        Card {
            HStack(spacing: 8) {
                Text("\(content.title) · \(content.subtitle)").font(.caption).foregroundStyle(.secondary)
                if let change = content.change {
                    Label(
                        "\(abs(change).formatted(.percent.precision(.fractionLength(0)))) vs previous \(content.range.label.lowercased())",
                        systemImage: change >= 0 ? "arrow.up.right" : "arrow.down.right"
                    )
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.quaternary.opacity(0.7), in: .capsule)
                }
            }
            HStack(alignment: .top, spacing: 16) {
                ForEach(content.tiles, id: \.title) { tile in
                    Fact(title: tile.title, value: tile.value, detail: tile.detail)
                }
            }
        }
        .monospacedDigit()
    }
}

/// The measure over the range, a bar per hour, day or month; memory with its peak hour as a tick.
private struct ResourceChart: View {
    let content: ResourceHistoryContent

    private var unit: Calendar.Component { content.step.component }

    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text(content.chartTitle).font(.headline)
                Spacer()
                if let average = content.barAverage {
                    Text("– – avg \(Format.resource(average, measure: content.measure))")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if content.bars.isEmpty {
                Text("Nothing was recorded in this range.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                chart
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(content.bars) { bar in
                BarMark(x: .value("Time", bar.start, unit: unit), y: .value("Value", bar.value), width: .ratio(0.7))
                    .foregroundStyle(content.measure.color)
                    .cornerRadius(2)
                if let peak = bar.peak, peak > bar.value {
                    RectangleMark(
                        x: .value("Time", bar.start, unit: unit), y: .value("Peak", peak), width: .ratio(0.7),
                        height: .fixed(2)
                    )
                    .foregroundStyle(content.measure.color.opacity(0.6))
                }
            }
            if let average = content.barAverage {
                RuleMark(y: .value("Average", average))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary)
            }
        }
        .chartXScale(domain: content.chartDomain)
        .chartXAxis {
            AxisMarks { _ in AxisValueLabel(format: axisFormat) }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let number = value.as(UInt64.self) {
                        Text(number == 0 ? "0" : Format.resource(number, measure: content.measure))
                    }
                }
            }
        }
        .frame(height: 200)
    }

    private var axisFormat: Date.FormatStyle {
        switch content.step {
        case .hour: .dateTime.hour()
        case .day: .dateTime.day().month(.abbreviated)
        case .month: .dateTime.month(.abbreviated)
        }
    }
}

/// The apps over the range by the measure, with their share; a click shows an app's five measures.
private struct ResourceAppsCard: View {
    let content: ResourceHistoryContent
    let settings: ResourceSettings
    @Binding var expandedApp: String?
    @Binding var showsAll: Bool
    let expandedMeasures: (bytes: ByteCounts?, resources: ResourceSum?)?

    var body: some View {
        let apps = showsAll ? content.apps : Array(content.apps.prefix(HistoryModel.visibleApps))
        Card(title: "Apps", trailing: "Click a row for its every measure") {
            VStack(spacing: 12) {
                if content.apps.isEmpty {
                    Text("No app was read in this range.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(apps) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        ResourceAppRow(row: row, measure: content.measure, scale: content.appsScale)
                            .contentShape(.rect)
                            .onTapGesture { expandedApp = expandedApp == row.id ? nil : row.id }
                        if expandedApp == row.id {
                            AppMeasuresView(
                                bytes: expandedMeasures?.bytes, resources: row.sum, settings: settings,
                                loading: expandedMeasures == nil)
                        }
                    }
                }
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

private struct ResourceAppRow: View {
    let row: ResourceHistoryContent.AppRow
    let measure: ResourceMeasure
    let scale: UInt64

    var body: some View {
        HStack(spacing: 10) {
            RowIcon(icon: row.icon, tiled: true).frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.title).lineLimit(1)
                    Spacer()
                    Text(row.share.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption).foregroundStyle(.tertiary)
                    Text(Format.resource(row.value, measure: measure)).foregroundStyle(.secondary)
                }
                .monospacedDigit()
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary.opacity(0.6))
                        RoundedRectangle(cornerRadius: 2).fill(measure.color)
                            .frame(width: max(2, geo.size.width * CGFloat(row.value) / CGFloat(max(scale, 1))))
                    }
                }
                .frame(height: 5)
            }
        }
    }
}

/// One app's five measures over the range: its data on every network (left out on the data page,
/// whose row shows it) and its resources.
struct AppMeasuresView: View {
    let bytes: ByteCounts?
    let resources: ResourceSum?
    let settings: ResourceSettings
    var loading = false

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            if let bytes {
                row("Data", color: .secondary, "↓ \(Format.bytes(bytes.rx))   ↑ \(Format.bytes(bytes.tx))")
            }
            if settings.shows(.cpu) {
                row(
                    "CPU", color: ResourceMeasure.cpu.color,
                    resources.map {
                        "\(Format.cpuTime(nanoseconds: $0.cpu)) · \(Format.cpuTime(nanoseconds: $0.billed)) billed by daemons"
                    })
            }
            if settings.shows(.memory) {
                row(
                    "Memory", color: ResourceMeasure.memory.color,
                    resources.map { "\(Format.bytes($0.footprint)) on average · \(Format.bytes($0.peak)) at most" })
            }
            if settings.shows(.disk) {
                row(
                    "Disk", color: ResourceMeasure.disk.color,
                    resources.map { "\(Format.bytes($0.read)) read · \(Format.bytes($0.written)) written" })
            }
            if settings.shows(.energy) {
                row(
                    "Energy", color: ResourceMeasure.energy.color,
                    resources.map { Format.energy(nanojoules: $0.energy) })
            }
        }
        .font(.caption)
        .monospacedDigit()
        .padding(10)
        .padding(.leading, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
    }

    private func row(_ title: String, color: some ShapeStyle, _ value: String?) -> some View {
        GridRow {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(title).foregroundStyle(.secondary)
            Text(value ?? (loading ? "…" : "–"))
        }
    }
}

/// The day minute by minute: the CPU and memory lines, the minute picked, and its numbers.
private struct MinuteCard: View {
    let content: MinuteContent
    let measure: ResourceMeasure
    let select: (Int64?) -> Void
    let move: (Int) -> Void
    @State private var hovered: Date?

    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Minute by minute").font(.headline)
                legend(content.cpuLabel, color: ResourceMeasure.cpu.color)
                legend(content.memoryLabel, color: ResourceMeasure.memory.color)
                Spacer()
                Text("← → move a minute").font(.caption).foregroundStyle(.tertiary)
            }
            Chart {
                ForEach(content.points) { point in
                    if let cpu = point.cpu {
                        LineMark(
                            x: .value("Minute", point.start), y: .value("Share", cpu), series: .value("Line", "CPU")
                        )
                        .foregroundStyle(ResourceMeasure.cpu.color)
                        .lineStyle(StrokeStyle(lineWidth: 1.2))
                    }
                    if let memory = point.memory {
                        LineMark(
                            x: .value("Minute", point.start), y: .value("Share", memory),
                            series: .value("Line", "Memory")
                        )
                        .foregroundStyle(ResourceMeasure.memory.color)
                        .lineStyle(StrokeStyle(lineWidth: 1.2))
                    }
                }
                if let selected = content.selected {
                    RuleMark(x: .value("Minute", selected)).foregroundStyle(.primary.opacity(0.5))
                }
            }
            .chartYScale(domain: 0...1)
            .chartYAxis {
                AxisMarks(values: [0, 0.5, 1]) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { if let share = value.as(Double.self) { Text(Format.percent(share)) } }
                }
            }
            .chartXAxis { AxisMarks { _ in AxisValueLabel(format: .dateTime.hour()) } }
            .chartXSelection(value: $hovered)
            .frame(height: 140)
            .onChange(of: hovered) {
                guard let hovered else { return }
                select(Int64(hovered.timeIntervalSince1970) / 60 * 60)
            }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) {
                move(-1)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                move(1)
                return .handled
            }
            if let selected = content.selected {
                HStack(alignment: .firstTextBaseline) {
                    Text(selected.formatted(.dateTime.hour().minute())).font(.headline).monospacedDigit()
                    Spacer()
                    Text(content.summary ?? "").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }

    private func legend(_ label: String, color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 10, height: 3)
            Text(label)
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

/// The minute picked: its five busiest apps by CPU, memory and disk written.
private struct MinuteLists: View {
    let content: MinuteContent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(content.lists) { list in
                Card {
                    Text(list.title.uppercased())
                        .font(.caption.weight(.semibold)).foregroundStyle(list.measure.color)
                    if list.rows.isEmpty {
                        Text("None").font(.callout).foregroundStyle(.tertiary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(list.rows.enumerated()), id: \.offset) { index, row in
                            HStack {
                                Text("\(index + 1). \(row.name)").lineLimit(1)
                                Spacer()
                                Text(row.value).foregroundStyle(.secondary)
                            }
                            .font(.callout).monospacedDigit()
                        }
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
