import AppKit
import SwiftUI

/// The popover under the menu bar item, laid out as `prototypes/ui-spike` and
/// `docs/mockups/popover.png`.
struct PopoverView: View {
    enum Tab: String, CaseIterable {
        case apps = "Apps", networks = "Networks"
    }

    let content: PopoverContent
    @Binding var tab: Tab
    @Binding var allNetworks: Bool
    var openHistory: () -> Void = {}
    var openSettings: () -> Void = {}
    var quit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let notice = content.notice {
                NoticeView(notice: notice)
            }
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)

            switch tab {
            case .apps: appsList
            case .networks: networksList
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
    }

    private var header: some View {
        let header = content.header
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: header.kind?.symbol ?? unknownNetworkSymbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(
                        (header.kind == nil ? Color.gray : NetworkColor.color(slot: header.slot)).gradient,
                        in: .rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text(header.name).font(.headline).lineLimit(1)
                    Text(subtitle(header)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("TODAY ON THIS NETWORK")
                    .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                Text(Format.bytes(header.today.total))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                HStack(spacing: 12) {
                    Label(Format.bytes(header.today.rx), systemImage: "arrow.down")
                    Label(Format.bytes(header.today.tx), systemImage: "arrow.up")
                    Spacer()
                    Text("↓ \(Format.speed(header.speed.rx))  ↑ \(Format.speed(header.speed.tx))")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .monospacedDigit()
            }
        }
    }

    private func subtitle(_ header: PopoverContent.Header) -> String {
        guard let kind = header.kind else { return "Waiting to identify the network" }
        guard let since = header.connectedSince else { return kind.label }
        return "\(kind.label) · connected since \(since.formatted(date: .omitted, time: .shortened))"
    }

    private var appsList: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                UsageRow(row: row, scale: content.appsScale)
            }
            UsageRow(row: content.overhead, scale: content.appsScale)
                .help("Bytes that crossed the network but no app's connections carry: packet headers, acknowledgements and system traffic.")
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Today by network").font(.caption).foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 8) {
            ForEach(content.networks) { row in
                UsageRow(row: row, scale: content.networksScale)
            }
        }
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("All networks today").font(.caption2).foregroundStyle(.secondary)
                Text(Format.bytes(content.allNetworksToday))
                    .font(.caption.weight(.semibold)).monospacedDigit()
            }
            Spacer()
            Button("History…", action: openHistory)
            Button(action: openSettings) { Image(systemName: "gearshape") }
                .help("Settings")
            Button(action: quit) { Image(systemName: "power") }
                .help("Quit Soroband")
        }
        .buttonStyle(.borderless)
    }
}

private struct NoticeView: View {
    let notice: PopoverContent.Notice

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
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
    /// A row's height with the 8 pt between rows, for sizing a list that scrolls.
    static let height: CGFloat = 34

    let row: PopoverContent.Row
    /// Bytes that fill the full bar width.
    let scale: UInt64

    var body: some View {
        HStack(spacing: 10) {
            RowIcon(icon: row.icon).frame(width: 20, height: 20)
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
                SegmentedBar(segments: row.segments, scale: scale).frame(height: 5)
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

struct RowIcon: View {
    let icon: PopoverContent.Icon

    var body: some View {
        switch icon {
        case .file(let path):
            Image(nsImage: AppIcons.icon(forPath: path)).resizable()
        case .services:
            Image(systemName: "gearshape.2").foregroundStyle(.secondary)
        case .tool:
            Image(systemName: "terminal").foregroundStyle(.secondary)
        case .overhead:
            Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
        case .network(let kind, let slot):
            Image(systemName: kind?.symbol ?? unknownNetworkSymbol)
                .foregroundStyle(kind == nil ? Color.secondary : NetworkColor.color(slot: slot))
        }
    }
}

/// App icons, loaded when first shown, at 20 pt, and kept by path while the popover is open.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func clear() {
        cache.removeAll()
    }

    static func icon(forPath path: String) -> NSImage {
        if let icon = cache[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 20, height: 20)
        cache[path] = icon
        return icon
    }
}
