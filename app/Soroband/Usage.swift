import Foundation

/// What the app shows, refreshed after each poll of the engine. One instance, shared by the menu
/// bar item, the popover and the settings.
///
/// While the popover is closed only the status is read (a struct copy); the lists the popover
/// needs are published by the core and read only while it is open.
@MainActor
@Observable
final class Usage {
    static let shared = Usage()

    private(set) var status = EngineStatus(state: .starting)
    private(set) var today = Today(networks: [], apps: [])
    /// The network registry, read when the popover or the Networks settings open.
    private(set) var registry: [RegisteredNetwork] = []
    private(set) var menuBarMode = MenuBarMode.todayNetwork
    private(set) var menuBarCount = MenuBarCount.total
    private(set) var resetHour = 0

    /// Set by the popover: polls every second and publishes today's lists while true.
    var isLive = false {
        didSet {
            guard isLive != oldValue else { return }
            Core.setLive(isLive)
            if isLive {
                reloadRegistry()
            } else {
                today = Today(networks: [], apps: [])
            }
        }
    }

    /// Called by `MenuBarController` after each refresh.
    var onChange: (() -> Void)?

    func start() {
        reloadSettings()
        Core.onPoll {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Usage.shared.polled() }
            }
        }
        // An engine that could not start (no database) never polls; show that at once.
        polled()
    }

    func polled() {
        let status = Core.engine
        if status != self.status { self.status = status }
        if isLive {
            let today = Core.today()
            if today != self.today { self.today = today }
        }
        onChange?()
    }

    func reloadRegistry() {
        registry = Core.networks()
    }

    /// Rereads the settings the app shows, after `soroband config set` or a change in Settings.
    func reloadSettings() {
        menuBarMode = Core.setting(MenuBarMode.settingKey).flatMap(MenuBarMode.init(rawValue:)) ?? .todayNetwork
        menuBarCount = Core.setting(MenuBarCount.settingKey).flatMap(MenuBarCount.init(rawValue:)) ?? .total
        resetHour = Core.setting("reset_hour").flatMap(Int.init) ?? 0
        onChange?()
    }

    func setMenuBarMode(_ mode: MenuBarMode) {
        if Core.setSetting(MenuBarMode.settingKey, to: mode.rawValue) { reloadSettings() }
    }

    func setMenuBarCount(_ count: MenuBarCount) {
        if Core.setSetting(MenuBarCount.settingKey, to: count.rawValue) { reloadSettings() }
    }

    func setResetHour(_ hour: Int) {
        if Core.setSetting("reset_hour", to: String(hour)) { reloadSettings() }
    }

    /// Renames network `id` and sets its kind, as the user chose in Settings.
    func updateNetwork(id: Int64, name: String, kind: NetworkKind) {
        if NetworkMonitor.shared.current?.id == id {
            NetworkMonitor.shared.updateCurrent(name: name, kind: kind)
        } else {
            Core.updateNetwork(id: id, name: name, kind: kind)
        }
        reloadRegistry()
        onChange?()
    }
}
