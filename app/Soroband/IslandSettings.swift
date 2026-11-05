import Foundation

/// The island's settings, as the core's schema holds them (`island_*` in `settings.rs`). The
/// menu bar process reads them; the UI process gets them in its snapshot and sends changes back.
struct IslandSettings: Codable, Equatable {
    enum Style: String, Codable, CaseIterable {
        /// Covers the menu bar beside the notch while a moment is open.
        case seamless
        /// Stays notch-wide inside the menu bar and widens only below it.
        case clear
    }

    enum FullScreen: String, Codable, CaseIterable {
        case hide, alerts, all
    }

    enum Displays: String, Codable, CaseIterable {
        case builtin, all
    }

    var enabled = false
    var style = Style.seamless
    var moments: Set<MomentKind> = Set(MomentKind.allCases).subtracting([.recap])
    var hogMB = 100
    var hogMinutes = 5
    var backgroundMB = 50
    var transferMB = 50
    var offersPause = true
    var fullScreen = FullScreen.alerts
    var displays = Displays.builtin
    var notifications = true
    var ignoredApps: [String] = []

    static let enabledKey = "island"
    static let styleKey = "island_style"
    static let momentsKey = "island_moments"
    static let hogMBKey = "island_hog_mb"
    static let hogMinutesKey = "island_hog_minutes"
    static let backgroundMBKey = "island_background_mb"
    static let transferMBKey = "island_transfer_mb"
    static let pauseKey = "island_pause"
    static let fullScreenKey = "island_full_screen"
    static let displaysKey = "island_displays"
    static let notificationsKey = "island_notifications"
    static let ignoredAppsKey = "island_ignored_apps"

    /// Whether `kind` shows on the island: the island is on and the moment is.
    func shows(_ kind: MomentKind) -> Bool { enabled && moments.contains(kind) }

    enum Route: Equatable {
        case island, notification, nowhere
    }

    /// Where a moment of `kind` goes: the island, while it is on and has a display to show on
    /// (`hasPanel`); otherwise a notification for an alert the user has not turned off, while
    /// notifications are on.
    func route(_ kind: MomentKind, hasPanel: Bool) -> Route {
        guard moments.contains(kind) else { return .nowhere }
        if enabled && hasPanel { return .island }
        return notifications && kind.isAlert ? .notification : .nowhere
    }

    /// Whether the engine has to look for moments at all.
    var watches: Bool { enabled || (notifications && moments.contains { $0.isAlert }) }

    /// The settings as `value(key)` gives them (`Core.setting`); a missing or unreadable value
    /// keeps its default.
    init(value: (String) -> String?) {
        func on(_ key: String, _ fallback: Bool) -> Bool { value(key).map { $0 == "on" } ?? fallback }
        func number(_ key: String, _ fallback: Int) -> Int { value(key).flatMap(Int.init) ?? fallback }
        enabled = on(Self.enabledKey, enabled)
        style = value(Self.styleKey).flatMap(Style.init(rawValue:)) ?? style
        if let list = value(Self.momentsKey) {
            moments =
                list == "none" ? [] : Set(list.split(separator: ",").compactMap { MomentKind(rawValue: String($0)) })
        }
        hogMB = number(Self.hogMBKey, hogMB)
        hogMinutes = number(Self.hogMinutesKey, hogMinutes)
        backgroundMB = number(Self.backgroundMBKey, backgroundMB)
        transferMB = number(Self.transferMBKey, transferMB)
        offersPause = on(Self.pauseKey, offersPause)
        fullScreen = value(Self.fullScreenKey).flatMap(FullScreen.init(rawValue:)) ?? fullScreen
        displays = value(Self.displaysKey).flatMap(Displays.init(rawValue:)) ?? displays
        notifications = on(Self.notificationsKey, notifications)
        if let list = value(Self.ignoredAppsKey) {
            ignoredApps = list == "none" ? [] : list.split(separator: ",").map(String.init)
        }
    }

    init() {}

    /// The value of `key` as the core stores it.
    func value(for key: String) -> String? {
        switch key {
        case Self.enabledKey: enabled ? "on" : "off"
        case Self.styleKey: style.rawValue
        case Self.momentsKey: momentsValue
        case Self.hogMBKey: String(hogMB)
        case Self.hogMinutesKey: String(hogMinutes)
        case Self.backgroundMBKey: String(backgroundMB)
        case Self.transferMBKey: String(transferMB)
        case Self.pauseKey: offersPause ? "on" : "off"
        case Self.fullScreenKey: fullScreen.rawValue
        case Self.displaysKey: displays.rawValue
        case Self.notificationsKey: notifications ? "on" : "off"
        case Self.ignoredAppsKey: Self.ignoredValue(ignoredApps)
        default: nil
        }
    }

    /// These settings with `key` set to `value`.
    func setting(_ key: String, to value: String) -> IslandSettings {
        IslandSettings { $0 == key ? value : self.value(for: $0) }
    }

    /// `moments` as the setting's value, in the schema's order.
    var momentsValue: String {
        let list = MomentKind.allCases.filter(moments.contains).map(\.rawValue)
        return list.isEmpty ? "none" : list.joined(separator: ",")
    }

    /// Ignored apps at most, as the core's schema allows (`ISLAND_MAX_IGNORED_APPS`).
    static let maxIgnoredApps = 100

    /// The ignored apps with `app` added; past the limit the oldest makes room, so Ignore always
    /// takes.
    /// Whether `app` can be ignored: the setting separates names with commas, so an app whose id
    /// holds one cannot be stored.
    static func canIgnore(_ app: String) -> Bool { !app.contains(",") }

    func ignoring(_ app: String) -> [String] {
        guard !ignoredApps.contains(app) else { return ignoredApps }
        return Array((ignoredApps + [app]).suffix(Self.maxIgnoredApps))
    }

    /// `apps` as the ignored apps' value.
    static func ignoredValue(_ apps: [String]) -> String {
        apps.isEmpty ? "none" : apps.joined(separator: ",")
    }
}
