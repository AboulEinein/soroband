import AppKit
import SwiftUI
import Testing

@testable import Soroband

@MainActor
struct ThemeTests {
    /// System must leave the windows to macOS (nil), not pin them to the light or dark it finds
    /// at launch, so a later switch in System Settings still reaches them.
    @Test func eachAppearanceGivesTheWindowsItsAppearance() {
        #expect(Appearance.system.name == nil)
        #expect(Appearance.light.name == .aqua)
        #expect(Appearance.dark.name == .darkAqua)
    }

    @Test func theThemeIsReadFromTheCoresWords() {
        let values = ["appearance": "dark", "accent": "teal"]
        let theme = Theme { values[$0] }
        #expect(theme == Theme(appearance: .dark, accent: .teal))
        #expect(Appearance.allCases.map(\.rawValue) == ["system", "light", "dark"])
        #expect(
            Accent.allCases.map(\.rawValue)
                == ["system", "coral", "amber", "emerald", "teal", "sky", "indigo", "plum", "rose"])
    }

    /// A value the app does not know (a hand edit, or a word from a newer Soroband) and a missing
    /// one both follow macOS, as a fresh install does.
    @Test(arguments: [["appearance": "sepia", "accent": "graphite"], ["appearance": "Dark", "accent": ""], [:]])
    func unknownOrMissingValuesFollowTheSystem(values: [String: String]) {
        #expect(Theme { values[$0] } == Theme(appearance: .system, accent: .system))
    }

    /// Settings shows a pick before the menu bar process confirms it, so a key that is not the
    /// theme's (the island's, from the same path) must leave the theme alone.
    @Test func settingAKeyChangesOnlyThatPartOfTheTheme() {
        let theme = Theme(appearance: .light, accent: .rose)
        #expect(theme.setting("accent", to: "sky") == Theme(appearance: .light, accent: .sky))
        #expect(theme.setting("appearance", to: "dark") == Theme(appearance: .dark, accent: .rose))
        #expect(theme.setting(IslandSettings.styleKey, to: "clear") == theme)
        #expect(theme.setting("accent", to: "rainbow") == Theme(appearance: .light, accent: .system))
    }

    @Test func systemKeepsMacOSsAccentColor() {
        #expect(Accent.system.color == nil)
        #expect(Accent.system.steps == nil)
    }

    /// Every accent tints controls on both windows, so each step stands out from its window by
    /// at least 3:1 (WCAG's contrast for controls): the light step on the light window (#ECECEC),
    /// the dark step on the dark one (#1E1E1E).
    @Test(arguments: Accent.allCases.filter { $0 != .system })
    func eachAccentStandsOutOnLightAndDarkWindows(accent: Accent) throws {
        let steps = try #require(accent.steps)
        #expect(Self.contrast(steps.light, 0xECECEC) >= 3, "\(accent) light")
        #expect(Self.contrast(steps.dark, 0x1E1E1E) >= 3, "\(accent) dark")
    }

    /// The color the windows take is the light step in a light window and the dark step in a
    /// dark one.
    @Test func anAccentResolvesToItsStepForEachAppearance() throws {
        let color = try #require(Accent.sky.color)
        let ns = NSColor(color)
        #expect(Self.hex(ns, in: .aqua) == 0x327CE6)
        #expect(Self.hex(ns, in: .darkAqua) == 0x4099F3)
    }

    /// No two accents share a step, so each swatch is a choice of its own.
    @Test func accentsAreDistinct() {
        let steps = Accent.allCases.compactMap(\.steps)
        #expect(Set(steps.map(\.light)).count == steps.count)
        #expect(Set(steps.map(\.dark)).count == steps.count)
    }

    /// WCAG 2's contrast ratio of two sRGB colors.
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func luminance(_ hex: UInt32) -> Double {
            func channel(_ value: UInt32) -> Double {
                let c = Double(value & 0xFF) / 255
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(hex >> 16) + 0.7152 * channel(hex >> 8) + 0.0722 * channel(hex)
        }
        let (high, low) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (high + 0.05) / (low + 0.05)
    }

    static func hex(_ color: NSColor, in name: NSAppearance.Name) -> UInt32? {
        var resolved: NSColor?
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)
        }
        guard let resolved else { return nil }
        let channel = { (value: CGFloat) in UInt32((value * 255).rounded()) }
        return channel(resolved.redComponent) << 16 | channel(resolved.greenComponent) << 8
            | channel(resolved.blueComponent)
    }
}
