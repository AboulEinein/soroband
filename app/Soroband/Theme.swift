import AppKit
import SwiftUI

/// How Soroband's windows look: the core's `appearance` setting.
enum Appearance: String, Codable, CaseIterable, Identifiable {
    /// Light or dark, as macOS is.
    case system
    case light
    case dark

    static let settingKey = "appearance"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The appearance the UI process's windows take (`NSApp.appearance`); nil follows macOS.
    var name: NSAppearance.Name? {
        switch self {
        case .system: nil
        case .light: .aqua
        case .dark: .darkAqua
        }
    }
}

/// The color of selections and highlights in Soroband's windows: the core's `accent` setting.
/// Each color but `system` comes from Soroband's icon pack, a light step for light windows and a
/// dark step for dark ones.
enum Accent: String, Codable, CaseIterable, Identifiable {
    /// macOS's accent color.
    case system
    case coral, amber, emerald, teal, sky, indigo, plum, rose

    static let settingKey = "accent"

    var id: String { rawValue }

    var label: String { self == .system ? "System" : rawValue.capitalized }

    /// The light and dark step, as sRGB hex. Each is a point on its icon's background gradient
    /// (plum: between the plum icon's purple and its lilac; indigo's dark step: between its
    /// gradient's top and the mark's white), picked so the color stands out at 3:1 or more
    /// (WCAG's contrast for controls) against the light window (#ECECEC) and the dark one
    /// (#1E1E1E, and #323232).
    var steps: (light: UInt32, dark: UInt32)? {
        switch self {
        case .system: nil
        case .coral: (0xD94E4B, 0xEC6C53)
        case .amber: (0xE5521F, 0xF58C31)
        case .emerald: (0x19945D, 0x24B36C)
        case .teal: (0x109396, 0x13B8A8)
        case .sky: (0x327CE6, 0x4099F3)
        case .indigo: (0x6C5CFF, 0x8C80FF)
        case .plum: (0x7944A3, 0xA67EC6)
        case .rose: (0xDD4B92, 0xFF5FA2)
        }
    }

    /// The tint the windows take; nil keeps macOS's accent color.
    var color: Color? {
        steps.map { Color(light: $0.light, dark: $0.dark) }
    }
}

/// The theme of Soroband's windows: their appearance and accent color. The menu bar process
/// reads it from the core and sends it to the UI process in its snapshot, where it applies to the
/// popover, Settings, History and the Welcome window; the island keeps its own dark look.
struct Theme: Codable, Equatable {
    var appearance = Appearance.system
    var accent = Accent.system

    /// The theme as `value(key)` gives it (`Core.setting`); a missing or unknown value is the
    /// system's.
    init(value: (String) -> String?) {
        appearance = value(Appearance.settingKey).flatMap(Appearance.init(rawValue:)) ?? .system
        accent = value(Accent.settingKey).flatMap(Accent.init(rawValue:)) ?? .system
    }

    init(appearance: Appearance = .system, accent: Accent = .system) {
        self.appearance = appearance
        self.accent = accent
    }

    /// This theme with `key` set to `value`; a key that is not the theme's changes nothing.
    func setting(_ key: String, to value: String) -> Theme {
        Theme {
            if $0 == key { return value }
            return $0 == Appearance.settingKey ? appearance.rawValue : accent.rawValue
        }
    }

    /// Makes the UI process's windows take `appearance`. Never called in the menu bar process,
    /// whose island draws itself dark.
    @MainActor
    func apply() {
        let appearance = self.appearance.name.flatMap(NSAppearance.init(named:))
        guard NSApp.appearance?.name != appearance?.name else { return }
        NSApp.appearance = appearance
        PopoverController.shared.appearance = appearance
    }
}

extension View {
    /// Tints the view with the theme's accent color, following each change.
    func themed(_ usage: Usage = .shared) -> some View {
        modifier(ThemedTint(usage: usage))
    }
}

private struct ThemedTint: ViewModifier {
    let usage: Usage

    func body(content: Content) -> some View {
        content.tint(usage.theme.accent.color)
    }
}
