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

/// Networks take the categorical color slots in the order they were first seen unless the user
/// picked one, so a network keeps its color in every view (docs/design.md, Visual language).
enum NetworkColor {
    /// Each slot's light and dark step.
    static let steps: [(light: UInt32, dark: UInt32)] = [
        (0x2A78D6, 0x3987E5),  // blue
        (0xEB6834, 0xD95926),  // orange
        (0x1BAF7A, 0x199E70),  // aqua
        (0xEDA100, 0xC98500),  // yellow
        (0xE87BA4, 0xD55181),  // magenta
    ]

    static let slots: [Color] = steps.map { Color(light: $0.light, dark: $0.dark) }

    /// Slot `slot`'s color in AppKit, for the island, which the menu bar process draws without
    /// SwiftUI.
    static func nsColor(slot: Int) -> NSColor {
        let step = steps[slot % steps.count]
        return NSColor(light: step.light, dark: step.dark)
    }

    static let names = ["Blue", "Orange", "Aqua", "Yellow", "Magenta"]

    /// The slot `network` picked, or that of its `index` in registry order; past the fifth,
    /// colors repeat.
    static func slot(for network: RegisteredNetwork, index: Int) -> Int {
        (network.color ?? index) % slots.count
    }

    static func color(slot: Int?) -> Color {
        guard let slot else { return .secondary }
        return slots[slot % slots.count]
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(light: light, dark: dark))
    }
}

extension NSColor {
    convenience init(light: UInt32, dark: UInt32) {
        self.init(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }
}
