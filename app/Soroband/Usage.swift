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
    private(set) var menuBarLayout = MenuBarLayout.default
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

    /// Polls left that reread the registry, after a change that may merge a network into another.
    private var registryRereads = 0

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
        if registryRereads > 0 {
            registryRereads -= 1
            reloadRegistry()
        }
        onChange?()
    }

    /// The engine merges a network after the change that asked for it, so the registry the popover
    /// or Settings read at the change can still list the merged one: read it again on the next
    /// polls.
    func rereadRegistryAfterMerge() {
        registryRereads = 2
    }

    func reloadRegistry() {
        registry = Core.networks()
    }

    /// Rereads the settings the app shows, after `soroband config set` or a change in Settings.
    func reloadSettings() {
        menuBarLayout = MenuBarLayout(
            scope: Core.setting(MenuBarScope.settingKey).flatMap(MenuBarScope.init(rawValue:)) ?? .network,
            readings: Core.setting(MenuBarLayout.readingsKey).flatMap(MenuBarLayout.readings(from:))
                ?? MenuBarLayout.default.readings,
            style: Core.setting(MenuBarLayout.styleKey).flatMap(MenuBarStyle.init(rawValue:))
                ?? MenuBarLayout.default.style)
        resetHour = Core.setting("reset_hour").flatMap(Int.init) ?? 0
        onChange?()
    }

    /// Saves the menu bar layout. Its values come from the core's options, so none is refused.
    func setMenuBarLayout(_ layout: MenuBarLayout) {
        let saved =
            Core.setSetting(MenuBarScope.settingKey, to: layout.scope.rawValue)
            && Core.setSetting(MenuBarLayout.readingsKey, to: layout.readingsValue)
            && Core.setSetting(MenuBarLayout.styleKey, to: layout.style.rawValue)
        if !saved { NSLog("Soroband: the menu bar layout was not saved") }
        reloadSettings()
    }

    func setResetHour(_ hour: Int) {
        if Core.setSetting("reset_hour", to: String(hour)) { reloadSettings() }
    }

    /// Sets network `id` to palette slot `color`, or back to its place's slot with nil.
    func setNetworkColor(id: Int64, color: Int?) {
        if !Core.setNetworkColor(id: id, color: color) {
            NSLog("Soroband: the color of network %lld was not saved", id)
        }
        reloadRegistry()
        onChange?()
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
