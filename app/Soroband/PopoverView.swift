import AppKit
import SwiftUI

/// The popover under the menu bar item: a hero card tinted with the current network's color,
/// Apps and Networks tabs, and a footer with the History entry (`docs/design.md`, UI).
struct PopoverView: View {
    enum Tab: String, CaseIterable {
        case apps = "Apps"
        case networks = "Networks"
    }

    let content: PopoverContent
    @Binding var tab: Tab
    @Binding var allNetworks: Bool
    var openHistory: () -> Void = {}
    var allowLocation: () -> Void = {}
    var openSettings: () -> Void = {}
    var quit: () -> Void = {}
    /// Bars grow once when the popover opens; nothing animates after that.
    var animatesOpen = true
    @State private var grown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HeroCard(content: content, grown: grown || !animatesOpen)
            if let notice = content.notice {
                NoticeView(notice: notice)
            }
            if content.asksForLocation {
                LocationPrompt(allow: allowLocation)
            }
            TabSwitcher(tab: $tab)

            switch tab {
            case .apps: appsList
            case .networks: networksList
            }

            footer
        }
        .padding(14)
        .frame(width: 360)
        .onAppear {
            guard animatesOpen else { return }
            withAnimation(.spring(duration: 0.5)) { grown = true }
        }
    }

    private var bars: Bool { grown || !animatesOpen }

    private var appsList: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(content.appsTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Toggle("All networks", isOn: $allNetworks)
                    .toggleStyle(.switch).controlSize(.mini).font(.caption)
            }
            if content.apps.isEmpty {
                Text(emptyAppsText)
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(content.apps) { row in
                UsageRow(row: row, scale: content.appsScale, grown: bars)
            }
            UsageRow(row: content.overhead, scale: content.appsScale, grown: bars)
                .help(
                    "Bytes that crossed the network but no app's connections carry: packet headers, acknowledgements and system traffic."
                )
            if content.hiddenApps > 0 {
                Text("+ \(content.hiddenApps) more in History")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Rows shown before the Networks tab scrolls.
    private static let visibleNetworks = 8

    private var emptyAppsText: String {
        if content.notice == .perAppOff { return "No per-app counts on this macOS version." }
        return allNetworks ? "No app has used any network today." : "No app has used this network today."
    }

    private var networksList: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Today by network").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Format.bytes(content.allNetworksToday)) total")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            if content.networks.count > Self.visibleNetworks {
                ScrollView {
                    networkRows.padding(.trailing, 12)
                }
                .frame(height: CGFloat(Self.visibleNetworks) * UsageRow.height)
            } else {
                networkRows
            }
        }
    }

    private var networkRows: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(content.networks) { row in
                UsageRow(row: row, scale: content.networksScale, grown: bars)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: openHistory) {
                HStack(spacing: 10) {
                    WeekSpark(week: content.history?.week ?? [])
                    VStack(alignment: .leading, spacing: 1) {
                        Text("History").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(content.history.map { "\(Format.bytes($0.month)) this month" } ?? "Every day, every app")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            .lineLimit(1).fixedSize()
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 42)
            }
            .buttonStyle(FooterButtonStyle())
            .keyboardShortcut("y")
            .help("Open History (⌘Y)")
            Button(action: openSettings) { Image(systemName: "gearshape").frame(width: 42, height: 42) }
                .buttonStyle(FooterButtonStyle())
                .help("Settings")
            Button(action: quit) { Image(systemName: "power").frame(width: 42, height: 42) }
                .buttonStyle(FooterButtonStyle())
                .help("Quit Soroband")
        }
    }
}

/// Apps and Networks as two halves of one full-width control. The system segmented control keeps
/// its natural width on macOS 27, however wide its frame.
private struct TabSwitcher: View {
    @Binding var tab: PopoverView.Tab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PopoverView.Tab.allCases, id: \.self) { item in
                Button {
                    tab = item
                } label: {
                    Text(item.rawValue)
                        .font(.system(size: 12, weight: tab == item ? .semibold : .regular))
                        .foregroundStyle(tab == item ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .contentShape(.rect)
                        .background {
                            if tab == item {
                                RoundedRectangle(cornerRadius: 7).fill(.quaternary)
                                    .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == item ? .isSelected : [])
            }
        }
        .padding(2)
        .background(.quinary, in: .rect(cornerRadius: 9))
    }
}

/// The current network, today's total on it, and today hour by hour.
private struct HeroCard: View {
    let content: PopoverContent
    let grown: Bool

    private var header: PopoverContent.Header { content.header }
    private var color: Color { header.kind == nil ? .gray : NetworkColor.color(slot: header.slot) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: header.kind?.symbol ?? unknownNetworkSymbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(color.gradient, in: .rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text(header.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text("↓ \(Format.speed(header.speed.rx))")
                    Text("↑ \(Format.speed(header.speed.tx))")
                }
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                let total = Self.split(Format.bytes(header.today.total))
                Text(total.number)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                Text(total.unit)
                    .font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                Spacer()
                Text("today on\nthis network")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
            .monospacedDigit()

            HStack(spacing: 12) {
                Text("↓ **\(Format.bytes(header.today.rx))** download")
                Text("↑ **\(Format.bytes(header.today.tx))** upload")
                Spacer(minLength: 4)
                Text("all **\(Format.bytes(content.allNetworksToday))**")
            }
            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            .lineLimit(1)

            if !content.hours.isEmpty {
                HourBeads(hours: content.hours, color: color, grown: grown)
                HourAxis(start: content.todayStart)
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.26), color.opacity(0.07)], startPoint: .topLeading,
                        endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: 14).strokeBorder(color.opacity(0.35))
        }
    }

    private var subtitle: String {
        guard let kind = header.kind else { return "Waiting to identify the network" }
        guard let since = header.connectedSince else { return kind.label }
        return "\(kind.label) · joined at \(since.formatted(date: .omitted, time: .shortened))"
    }

    /// "1.37 GB" as its number and its unit, drawn in two sizes.
    static func split(_ text: String) -> (number: String, unit: String) {
        guard let space = text.lastIndex(of: " ") else { return (text, "") }
        return (String(text[..<space]), String(text[text.index(after: space)...]))
    }
}

/// Today's 24 hours as bars in the network's color; hours still to come are flat, and the hour
/// in progress is ringed.
private struct HourBeads: View {
    let hours: [UInt64?]
    let color: Color
    let grown: Bool

    static let height: CGFloat = 30

    var body: some View {
        let peak = Double(max(hours.compactMap { $0 }.max() ?? 1, 1))
        let current = hours.lastIndex { $0 != nil }
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(hours.indices, id: \.self) { hour in
                if let bytes = hours[hour] {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.9))
                        .frame(height: max(3, Double(bytes) / peak * Self.height))
                        .scaleEffect(y: grown ? 1 : 0.1, anchor: .bottom)
                        .overlay {
                            if hour == current {
                                RoundedRectangle(cornerRadius: 4).strokeBorder(color.opacity(0.6), lineWidth: 1.5)
                                    .padding(-2.5)
                            }
                        }
                        .help("\(Format.bytes(bytes))")
                } else {
                    RoundedRectangle(cornerRadius: 2).fill(.quaternary).frame(height: 3)
                }
            }
        }
        .frame(height: Self.height, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Today hour by hour")
    }
}

/// Hour labels under the beads: the day's start, every six hours, and its last hour.
private struct HourAxis: View {
    let start: Date?

    var body: some View {
        HStack {
            ForEach([0, 6, 12, 18, 23], id: \.self) { offset in
                Text(label(offset))
                if offset != 23 { Spacer() }
            }
        }
        .font(.system(size: 9.5)).foregroundStyle(.tertiary).monospacedDigit()
    }

    private func label(_ offset: Int) -> String {
        guard let start else { return "" }
        return start.addingTimeInterval(TimeInterval(offset * 3600)).formatted(.dateTime.hour())
    }
}

/// The last 7 days as small bars, today brightest.
private struct WeekSpark: View {
    let week: [UInt64]

    var body: some View {
        let peak = Double(max(week.max() ?? 1, 1))
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<7, id: \.self) { day in
                let bytes = week.indices.contains(day) ? week[day] : 0
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(day == 6 ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary.opacity(0.6)))
                    .frame(width: 4, height: max(3, Double(bytes) / peak * 20))
            }
        }
        .frame(height: 20, alignment: .bottom)
    }
}

/// A rounded tile that lights up under the pointer, for the footer's buttons.
private struct FooterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Hovering { hovered in
            configuration.label
                .contentShape(.rect(cornerRadius: 10))
                .background(
                    .quaternary.opacity(configuration.isPressed ? 1 : hovered ? 0.8 : 0.45), in: .rect(cornerRadius: 10)
                )
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6)))
        }
    }
}

private struct Hovering<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content
    @State private var hovered = false

    var body: some View {
        content(hovered).onHover { hovered = $0 }
    }
}

/// Offered while the current Wi‑Fi is known by its router.
private struct LocationPrompt: View {
    let allow: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "location.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Show Wi‑Fi names").font(.caption.weight(.semibold))
                Text("macOS shares the network's name only with Location access. Nothing leaves your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Allow…", action: allow).buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(10)
        .background(.yellow.opacity(0.1), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.yellow.opacity(0.3)))
    }
}

private struct NoticeView: View {
    let notice: PopoverContent.Notice

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.orange.opacity(0.1), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.orange.opacity(0.3)))
    }

    private var title: String {
        switch notice {
        case .perAppOff: "Counting totals only"
        case .degraded: "Per-app counts look low"
        case .overcount: "Per-app counts exceed the network"
        case .failed: "Not counting"
        }
    }

    private var detail: String {
        switch notice {
        case .perAppOff:
            "This macOS version reports connections in a layout Soroband does not know yet, so only the network's totals are counted."
        case .degraded:
            "For 20 minutes, apps were credited with less than 85% of what crossed the network."
        case .overcount:
            "Apps were credited with more than crossed the network. The per-app numbers may be wrong."
        case .failed:
            "The meter stopped, or the usage database could not be opened. Quit and reopen Soroband."
        }
    }
}

struct UsageRow: View {
    /// A row's height with the 9 pt between rows, for sizing a list that scrolls.
    static let height: CGFloat = 40

    let row: PopoverContent.Row
    /// Bytes that fill the full bar width.
    let scale: UInt64
    var grown = true

    var body: some View {
        HStack(spacing: 10) {
            RowIcon(icon: row.icon, tiled: true).frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.title).lineLimit(1)
                    if let subtitle {
                        Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(Format.bytes(row.bytes.total)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
                SegmentedBar(segments: row.segments, scale: scale)
                    .frame(height: 4)
                    .scaleEffect(x: grown ? 1 : 0, anchor: .leading)
            }
        }
        .help("↓ \(Format.bytes(row.bytes.rx))   ↑ \(Format.bytes(row.bytes.tx))")
    }

    private var subtitle: String? {
        switch row.subtitle {
        case nil: nil
        case .connected: "Connected"
        case .neverUsed: "Never used"
        case .lastUsed(let date): "Last used \(date.formatted(.relative(presentation: .named)))"
        }
    }
}

/// A horizontal bar split into colored segments with a 2 pt gap between them.
struct SegmentedBar: View {
    let segments: [PopoverContent.Segment]
    let scale: UInt64

    var body: some View {
        GeometryReader { geo in
            let visible = segments.filter { $0.bytes > 0 }
            let gaps = CGFloat(max(0, visible.count - 1)) * 2
            let width = max(0, geo.size.width - gaps)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary.opacity(0.6))
                HStack(spacing: 2) {
                    ForEach(visible.indices, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(NetworkColor.color(slot: visible[i].slot))
                            .frame(width: max(2, width * CGFloat(visible[i].bytes) / CGFloat(max(scale, 1))))
                    }
                }
            }
        }
    }
}

/// An app's icon, or a symbol for what has none. `tiled` sets symbols on a rounded tile the size
/// of an app icon, tinted with the network's color for a network.
struct RowIcon: View {
    let icon: PopoverContent.Icon
    var tiled = false

    var body: some View {
        switch icon {
        case .file(let path):
            Image(nsImage: AppIcons.icon(forPath: path)).resizable()
        case .services:
            symbol("gearshape.2", tint: .secondary)
        case .tool:
            symbol("terminal", tint: .secondary)
        case .overhead:
            symbol("ellipsis", tint: .secondary)
        case .network(let kind, let slot):
            symbol(
                kind?.symbol ?? unknownNetworkSymbol, tint: kind == nil ? .secondary : NetworkColor.color(slot: slot))
        }
    }

    @ViewBuilder
    private func symbol(_ name: String, tint: Color) -> some View {
        if tiled {
            Image(systemName: name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(tint.opacity(0.16), in: .rect(cornerRadius: 6))
        } else {
            Image(systemName: name).foregroundStyle(tint)
        }
    }
}

/// App icons, loaded when first shown, at 24 pt, and kept by path while the popover is open.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func clear() {
        cache.removeAll()
    }

    static func icon(forPath path: String) -> NSImage {
        if let icon = cache[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 24, height: 24)
        cache[path] = icon
        return icon
    }
}
