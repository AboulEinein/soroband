import AppKit
import SwiftUI

enum NetworkKind: String, CaseIterable, Identifiable {
    case wifi, hotspot, ethernet
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .wifi: "wifi"
        case .hotspot: "personalhotspot"
        case .ethernet: "cable.connector.horizontal"
        }
    }

    var label: String {
        switch self {
        case .wifi: "Wi‑Fi"
        case .hotspot: "Hotspot"
        case .ethernet: "Ethernet"
        }
    }
}

struct Network: Identifiable {
    let id: String
    var name: String
    var kind: NetworkKind
    let tint: Color
}

struct AppInfo: Identifiable {
    let id: String
    let name: String
    let symbol: String
    let tint: Color
    let icon: NSImage?
}

/// One hour of traffic for one app on one network. History is stored at this granularity forever.
struct UsageRecord {
    let hour: Date
    let networkID: String
    let appID: String
    var down: Int64
    var up: Int64
    var total: Int64 { down + up }
}

enum MenuBarMode: String, CaseIterable, Identifiable {
    case todayCurrentNetwork, todayAllNetworks, liveSpeed, iconOnly
    var id: String { rawValue }

    var label: String {
        switch self {
        case .todayCurrentNetwork: "Today on current network"
        case .todayAllNetworks: "Today on all networks"
        case .liveSpeed: "Live speed"
        case .iconOnly: "Icon only"
        }
    }
}

struct Totals {
    var down: Int64 = 0
    var up: Int64 = 0
    var total: Int64 { down + up }
}

extension Sequence where Element == UsageRecord {
    var totals: Totals {
        reduce(into: Totals()) { $0.down += $1.down; $0.up += $1.up }
    }

    func grouped(by key: (UsageRecord) -> String) -> [(id: String, totals: Totals)] {
        var result: [String: Totals] = [:]
        for r in self {
            result[key(r), default: Totals()].down += r.down
            result[key(r), default: Totals()].up += r.up
        }
        return result.map { ($0.key, $0.value) }.sorted { $0.totals.total > $1.totals.total }
    }
}

struct Segment {
    let color: Color
    let bytes: Int64
}

extension Color {
    /// Categorical slots in validated order (see docs/design.md, Visual language). Light and dark steps differ.
    static let series1 = Color(light: 0x2A78D6, dark: 0x3987E5)
    static let series2 = Color(light: 0xEB6834, dark: 0xD95926)
    static let series3 = Color(light: 0x1BAF7A, dark: 0x199E70)
    static let series4 = Color(light: 0xEDA100, dark: 0xC98500)
    static let series5 = Color(light: 0xE87BA4, dark: 0xD55181)

    /// Sequential blue ramp for magnitude; the low end recedes toward the surface in each mode.
    static let heatLow = Color(light: 0xCDE2FB, dark: 0x16263A)
    static let heatHigh = Color(light: 0x184F95, dark: 0x9EC5F4)

    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
}

func formatRate(_ bytesPerSecond: Double) -> String {
    formatBytes(Int64(bytesPerSecond)) + "/s"
}
