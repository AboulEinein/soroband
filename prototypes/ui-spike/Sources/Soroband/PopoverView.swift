import SwiftUI

struct PopoverView: View {
    @Environment(UsageStore.self) private var store
    @Environment(IslandModel.self) private var island
    @Environment(\.openWindow) private var openWindow
    @State private var tab: Tab = .apps
    @State private var allNetworks = false

    enum Tab: String, CaseIterable { case apps = "Apps", networks = "Networks" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

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

    // MARK: Header

    private var header: some View {
        let net = store.currentNetwork
        let today = store.records(in: store.todayInterval, network: net.id).totals
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: net.kind.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(net.tint.gradient, in: .rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text(net.name).font(.headline)
                    Text("\(net.kind.label) · connected since \(store.connectedSince.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                simulateMenu
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("TODAY ON THIS NETWORK")
                    .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                Text(formatBytes(today.total))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                HStack(spacing: 12) {
                    Label(formatBytes(today.down), systemImage: "arrow.down")
                    Label(formatBytes(today.up), systemImage: "arrow.up")
                    Spacer()
                    Text("↓ \(formatRate(store.liveDown))  ↑ \(formatRate(store.liveUp))")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .monospacedDigit()
            }
        }
    }

    /// Spike-only: lets you "walk into the office" to see per-network counting.
    private var simulateMenu: some View {
        Menu {
            Section("Spike: simulate joining") {
                ForEach(store.networks) { net in
                    Button {
                        MomentSimulator.join(net.id, store: store, island: island)
                    } label: {
                        Label(net.name, systemImage: net.kind.symbol)
                    }
                }
            }
            Section("Spike: fire a moment") {
                ForEach(MomentKind.allCases) { kind in
                    Button {
                        MomentSimulator.trigger(kind, store: store, island: island)
                    } label: {
                        Label(kind.title, systemImage: kind.symbol)
                    }
                    .disabled(!island.isOn(kind))
                }
            }
        } label: {
            Image(systemName: "arrow.triangle.swap")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Spike: simulate switching networks")
    }

    // MARK: Apps

    private var appsList: some View {
        let today = store.records(in: store.todayInterval, network: allNetworks ? nil : store.currentNetworkID)
        let rows = today.grouped(by: \.appID)
        let maxTotal = rows.first?.totals.total ?? 1
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(allNetworks ? "Today, all networks" : "Today on \(store.currentNetwork.name)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("All networks", isOn: $allNetworks)
                    .toggleStyle(.switch).controlSize(.mini).font(.caption)
            }
            ForEach(rows.prefix(7), id: \.id) { row in
                let app = store.app(row.id)
                UsageRow(title: app.name, totals: row.totals, scale: maxTotal,
                         segments: store.networkSegments(today.filter { $0.appID == row.id })) {
                    AppIconView(app: app)
                }
            }
            if rows.count > 7 {
                Text("+ \(rows.count - 7) more in History")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Networks

    private var networksList: some View {
        let today = store.records(in: store.todayInterval)
        let byNetwork = Dictionary(uniqueKeysWithValues: today.grouped(by: \.networkID).map { ($0.id, $0.totals) })
        let maxTotal = byNetwork.values.map(\.total).max() ?? 1
        let ordered = store.networks.sorted { (byNetwork[$0.id]?.total ?? 0) > (byNetwork[$1.id]?.total ?? 0) }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Today by network").font(.caption).foregroundStyle(.secondary)
            ForEach(ordered) { net in
                let totals = byNetwork[net.id] ?? Totals()
                UsageRow(
                    title: net.name,
                    subtitle: subtitle(for: net, used: totals.total > 0),
                    totals: totals,
                    scale: maxTotal,
                    segments: [Segment(color: net.tint, bytes: totals.total)]
                ) {
                    Image(systemName: net.kind.symbol).foregroundStyle(net.tint)
                }
            }
        }
    }

    private func subtitle(for net: Network, used: Bool) -> String? {
        if net.id == store.currentNetworkID { return "Connected" }
        if used { return nil }
        guard let seen = store.lastSeen(net.id) else { return "Never used" }
        return "Last used \(seen.formatted(.relative(presentation: .named)))"
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("All networks today").font(.caption2).foregroundStyle(.secondary)
                Text(formatBytes(store.records(in: store.todayInterval).totals.total))
                    .font(.caption.weight(.semibold)).monospacedDigit()
            }
            Spacer()
            Button("History…") {
                openWindow(id: "history")
                NSApp.activate()
            }
            SettingsLink { Image(systemName: "gearshape") }
                .simultaneousGesture(TapGesture().onEnded { NSApp.activate() })
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .help("Quit Soroband")
        }
        .buttonStyle(.borderless)
    }
}

struct UsageRow<Icon: View>: View {
    let title: String
    var subtitle: String? = nil
    let totals: Totals
    /// Bytes that fill the full bar width (usually the largest row).
    let scale: Int64
    let segments: [Segment]
    var share: Double? = nil
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        HStack(spacing: 10) {
            icon().frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).lineLimit(1)
                    if let subtitle {
                        Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let share {
                        Text(share.formatted(.percent.precision(.fractionLength(0))))
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    Text(formatBytes(totals.total)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
                SegmentedBar(segments: segments, scale: scale).frame(height: 5)
            }
        }
        .help("↓ \(formatBytes(totals.down))   ↑ \(formatBytes(totals.up))")
    }
}

/// Horizontal bar split into colored segments with a 2pt surface gap between them.
struct SegmentedBar: View {
    let segments: [Segment]
    let scale: Int64

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
                            .fill(visible[i].color)
                            .frame(width: max(2, width * CGFloat(visible[i].bytes) / CGFloat(max(scale, 1))))
                    }
                }
            }
        }
    }
}

struct AppIconView: View {
    let app: AppInfo

    var body: some View {
        if let icon = app.icon {
            Image(nsImage: icon).resizable().frame(width: 20, height: 20)
        } else {
            Image(systemName: app.symbol).foregroundStyle(app.tint)
        }
    }
}
