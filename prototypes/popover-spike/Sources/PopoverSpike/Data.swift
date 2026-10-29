import AppKit

/// Option C's popover on fake data: Keyez!_5G, today 1.37 GB, 24 hourly beads, seven apps.
enum Fake {
    static let network = "Keyez!_5G"
    static let subtitle = "Wi‑Fi · joined at 7:58 AM"
    static let total = "1.37"
    static let unit = "GB"
    static let down = "1.12 GB"
    static let up = "248 MB"
    static let allNetworks = "1.61 GB"
    static let speed = ("2.4 MB/s", "186 KB/s")
    static let nowHour = 21
    /// Megabytes per hour, midnight to 11 PM; hours after `nowHour` have not happened.
    static let hours: [Double] = [
        4, 2, 1, 1, 0, 1, 3, 12, 48, 96, 120, 88, 64, 72, 110, 140, 96, 80, 60, 74, 102, 118, 0, 0,
    ]
    static let apps: [(name: String, path: String, value: String, share: Double)] = [
        ("Safari", "/Applications/Safari.app", "438.0 MB", 1.0),
        ("Zoom", "/System/Applications/FaceTime.app", "291.0 MB", 0.66),
        ("Slack", "/System/Applications/Messages.app", "176.0 MB", 0.40),
        ("Music", "/System/Applications/Music.app", "152.0 MB", 0.35),
        ("macOS & Services", "/System/Library/CoreServices/Finder.app", "96.0 MB", 0.22),
        ("curl", "/System/Applications/Utilities/Terminal.app", "41.0 MB", 0.09),
        ("Other / overhead", "", "118.0 MB", 0.27),
    ]
    /// `SPIKE_NO_ICONS=1` leaves app icons out, to see what they cost.
    static let icons = ProcessInfo.processInfo.environment["SPIKE_NO_ICONS"] == nil
    static let week: [Double] = [6.1, 8.4, 7.2, 9.8, 8.8, 10.4, 11.5]
    static let blue = NSColor(srgbRed: 0x39 / 255, green: 0x87 / 255, blue: 0xE5 / 255, alpha: 1)
}
