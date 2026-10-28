import AppKit
import SwiftUI

extension NetworkKind {
    /// SF Symbol for the kind.
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

/// The symbol for usage booked to no network (id 0).
let unknownNetworkSymbol = "network"

/// Networks take the categorical color slots in the order they were first seen, so a network
/// keeps its color in every view (docs/design.md, Visual language).
enum NetworkColor {
    static let slots: [Color] = [
        Color(light: 0x2A78D6, dark: 0x3987E5),  // blue
        Color(light: 0xEB6834, dark: 0xD95926),  // orange
        Color(light: 0x1BAF7A, dark: 0x199E70),  // aqua
        Color(light: 0xEDA100, dark: 0xC98500),  // yellow
        Color(light: 0xE87BA4, dark: 0xD55181),  // magenta
    ]

    /// The slot of the network at `index` in registry order; past the fifth, colors repeat.
    static func slot(forIndex index: Int) -> Int {
        index % slots.count
    }

    static func color(slot: Int?) -> Color {
        guard let slot else { return .secondary }
        return slots[slot % slots.count]
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(
            nsColor: NSColor(name: nil) { appearance in
                let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
                return NSColor(
                    srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
            })
    }
}
