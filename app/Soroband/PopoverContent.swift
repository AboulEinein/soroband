import Foundation

/// What the popover shows, worked out from the engine's status and today's lists, so the view
/// only lays it out.
struct PopoverContent: Equatable {
    struct Header: Equatable {
        var name: String
        /// The network's kind; nil while usage is booked to no network.
        var kind: NetworkKind?
        var slot: Int?
        var connectedSince: Date?
        /// What crossed the interfaces on this network today.
        var today: ByteCounts
        var speed: ByteCounts
    }

    /// A share of a usage bar in one network's color; `slot` nil is the neutral color.
    struct Segment: Equatable {
        var slot: Int?
        var bytes: UInt64
    }

    enum Icon: Equatable {
        /// An app bundle or an executable, by path.
        case file(String)
        case services
        case tool
        case overhead
        case network(NetworkKind?, slot: Int?)
    }

    enum Subtitle: Equatable {
        case connected
        case lastUsed(Date)
        case neverUsed
    }

    struct Row: Equatable, Identifiable {
        var id: String
        var title: String
        var subtitle: Subtitle?
        var icon: Icon
        var bytes: ByteCounts
        var segments: [Segment]
    }

    enum Notice: Equatable {
        /// The engine runs on interface totals: no app is credited.
        case perAppOff
        /// Two judged windows in a row credited too little to apps.
        case degraded
        /// Apps summed to more than crossed the network.
        case overcount
        case failed
    }

    /// Apps shown before the rest are summed up as "+ N more".
    static let visibleApps = 7

    var header: Header
    var notice: Notice?
    var appsTitle: String
    var apps: [Row]
    var hiddenApps: Int
    /// The raw gap between the interfaces and the apps' sum: headers, acknowledgements and
    /// traffic no flow carried. Always shown, without a verdict.
    var overhead: Row
    /// Bytes that fill a whole bar in the Apps tab: the largest row, overhead included.
    var appsScale: UInt64
    var networks: [Row]
    var networksScale: UInt64
    /// What crossed the interfaces today on every network.
    var allNetworksToday: UInt64

    static let unknownNetworkName = "Unknown network"
    static let overheadTitle = "Other / overhead"

    /// - `current`: the network bytes are booked to, nil while none is identified.
    /// - `allNetworks`: the Apps tab's toggle; bars are then split by network.
    static func make(
        status: EngineStatus, today: Today, registry: [RegisteredNetwork], current: Network?,
        connectedSince: Date?, allNetworks: Bool
    ) -> PopoverContent {
        let slots = Dictionary(
            uniqueKeysWithValues: registry.enumerated().map { ($1.id, NetworkColor.slot(forIndex: $0)) })
        let networkID = current?.id ?? 0

        let header = Header(
            name: current?.name ?? unknownNetworkName,
            kind: current?.kind,
            slot: current.flatMap { slots[$0.id] },
            connectedSince: current == nil ? nil : connectedSince,
            today: status.todayNetworkInterfaces,
            speed: status.speed)

        // Apps, one row each, with a segment per network it used.
        var byApp: [String: (name: String, bytes: ByteCounts, perNetwork: [Int64: UInt64])] = [:]
        for usage in today.apps where allNetworks || usage.network == networkID {
            var entry = byApp[usage.id] ?? (usage.name, .zero, [:])
            entry.bytes.rx += usage.rx
            entry.bytes.tx += usage.tx
            entry.perNetwork[usage.network, default: 0] += usage.bytes.total
            byApp[usage.id] = entry
        }
        let order = registry.map(\.id)
        let sorted = byApp.sorted { a, b in
            a.value.bytes.total != b.value.bytes.total
                ? a.value.bytes.total > b.value.bytes.total
                : a.value.name.localizedStandardCompare(b.value.name) == .orderedAscending
        }
        let apps = sorted.prefix(visibleApps).map { id, entry in
            let segments = entry.perNetwork
                .sorted { (order.firstIndex(of: $0.key) ?? .max) < (order.firstIndex(of: $1.key) ?? .max) }
                .map { Segment(slot: slots[$0.key], bytes: $0.value) }
            return Row(
                id: id, title: entry.name, icon: icon(forApp: id), bytes: entry.bytes,
                segments: allNetworks ? segments : [Segment(slot: slots[networkID], bytes: entry.bytes.total)])
        }

        let interfaces = allNetworks ? status.todayInterfaces : status.todayNetworkInterfaces
        let credited = allNetworks ? status.todayApps : status.todayNetworkApps
        let gap = interfaces.gap(minus: credited)
        let overhead = Row(
            id: "overhead", title: overheadTitle, icon: .overhead, bytes: gap,
            segments: [Segment(slot: nil, bytes: gap.total)])

        // Networks: every network in the registry, plus no network when it carried bytes today.
        let totals = Dictionary(uniqueKeysWithValues: today.networks.map { ($0.network, $0.interfaces) })
        var networks = registry.map { network in
            let bytes = totals[network.id] ?? .zero
            let subtitle: Subtitle? =
                if network.id == networkID {
                    .connected
                } else if bytes.total > 0 {
                    nil
                } else if let lastUsed = network.lastUsed {
                    .lastUsed(Date(timeIntervalSince1970: TimeInterval(lastUsed)))
                } else {
                    .neverUsed
                }
            return Row(
                id: "network-\(network.id)", title: network.name, subtitle: subtitle,
                icon: .network(network.kind, slot: slots[network.id]), bytes: bytes,
                segments: [Segment(slot: slots[network.id], bytes: bytes.total)])
        }
        if let unknown = totals[0], unknown.total > 0 {
            networks.append(
                Row(
                    id: "network-0", title: unknownNetworkName, subtitle: networkID == 0 ? .connected : nil,
                    icon: .network(nil, slot: nil), bytes: unknown, segments: [Segment(slot: nil, bytes: unknown.total)]
                ))
        }
        // Stable for equal totals: registry order.
        networks = networks.enumerated()
            .sorted {
                $0.element.bytes.total != $1.element.bytes.total
                    ? $0.element.bytes.total > $1.element.bytes.total : $0.offset < $1.offset
            }
            .map(\.element)

        return PopoverContent(
            header: header,
            notice: notice(for: status),
            appsTitle: allNetworks ? "Today, all networks" : "Today on \(header.name)",
            apps: apps,
            hiddenApps: max(0, sorted.count - visibleApps),
            overhead: overhead,
            appsScale: max(apps.first?.bytes.total ?? 0, gap.total, 1),
            networks: networks,
            networksScale: max(networks.first?.bytes.total ?? 0, 1),
            allNetworksToday: status.todayInterfaces.total)
    }

    static func notice(for status: EngineStatus) -> Notice? {
        switch status.state {
        case .failed: return .failed
        case .interfaceOnly: return .perAppOff
        case .starting, .perApp: break
        }
        return switch status.check {
        case .ok: nil
        case .degraded: .degraded
        case .overcount: .overcount
        }
    }

    /// The core names apps by bundle path, executable path, "macOS & Services", or
    /// `process:<name>` when the path is unknown.
    static func icon(forApp id: String) -> Icon {
        if id.hasPrefix("/") { return .file(id) }
        if id.hasPrefix("process:") { return .tool }
        return .services
    }
}

extension ByteCounts {
    /// What `self` holds beyond `other`, never below zero. When one direction of `other` is the
    /// larger, its excess comes off the other direction, so the total is the difference of the
    /// totals.
    func gap(minus other: ByteCounts) -> ByteCounts {
        let rx = Int64(clamping: self.rx) - Int64(clamping: other.rx)
        let tx = Int64(clamping: self.tx) - Int64(clamping: other.tx)
        if rx < 0 { return ByteCounts(rx: 0, tx: UInt64(max(0, tx + rx))) }
        if tx < 0 { return ByteCounts(rx: UInt64(max(0, rx + tx)), tx: 0) }
        return ByteCounts(rx: UInt64(rx), tx: UInt64(tx))
    }
}
