import Foundation

/// What the app shows, refreshed after each poll of the engine. One instance, shared by the menu
/// bar item, the popover and the settings.
///
/// While the popover is closed only the status is read (a struct copy); the lists the popover
/// needs are published by the core and read only while it is open. In the UI process it mirrors
/// the menu bar process's (`mirror`), and its changes go to the menu bar process, which runs the
/// engine (`UIHost.forward`).
@MainActor
@Observable
final class Usage {
    static let shared = Usage()

    private(set) var status = EngineStatus(state: .starting)
    /// Read in the UI process, from `todayJSON`.
    private(set) var today = Today(networks: [], apps: [])
    /// Today's lists as the core writes them (`Core.todayJSON`). The menu bar process hands them on
    /// without reading them: decoding and encoding them each second there left about 1.4 MB of
    /// fragmented heap after the popover closed.
    private(set) var todayJSON = ""
    /// The network registry, read when the popover or the Networks settings open.
    private(set) var registry: [RegisteredNetwork] = []
    private(set) var menuBarLayout = MenuBarLayout.default
    private(set) var resetHour = 0
    /// The island's settings, read in the UI process for Settings; the menu bar process's
    /// `IslandController` holds its own.
    private(set) var island = IslandSettings()
    /// The windows' theme. The menu bar process only reads it and hands it on; the UI process
    /// applies it (`Theme.apply`, `themed`).
    private(set) var theme = Theme()

    /// Set by the popover: polls every second and publishes today's lists while true.
    var isLive = false {
        didSet {
            guard isLive != oldValue else { return }
            if !isLive {
                today = Today(networks: [], apps: [])
                todayJSON = ""
            }
            if UIHost.forward(.live(isLive)) { return }
            Core.setLive(isLive)
            if isLive { reloadRegistry() }
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
            let json = Core.todayJSON()
            if json != todayJSON { todayJSON = json }
        }
        if registryRereads > 0 {
            registryRereads -= 1
            reloadRegistry()
        }
        onChange?()
        IslandController.shared.polled()
    }

    /// The engine merges a network after the change that asked for it, so the registry the popover
    /// or Settings read at the change can still list the merged one: read it again on the next
    /// polls.
    func rereadRegistryAfterMerge() {
        registryRereads = 2
    }

    func reloadRegistry() {
        if UIHost.forward(.reloadRegistry) { return }
        registry = Core.networks()
    }

    /// In the UI process: takes what the menu bar process's `Usage` holds.
    func mirror(_ snapshot: UISnapshot) {
        if snapshot.status != status { status = snapshot.status }
        if snapshot.todayJSON != todayJSON {
            todayJSON = snapshot.todayJSON
            today = todayJSON.isEmpty ? Today(networks: [], apps: []) : Core.today(json: todayJSON)
        }
        if snapshot.registry != registry { registry = snapshot.registry }
        if snapshot.menuBarLayout != menuBarLayout { menuBarLayout = snapshot.menuBarLayout }
        if snapshot.resetHour != resetHour { resetHour = snapshot.resetHour }
        if snapshot.island != island { island = snapshot.island }
        if snapshot.theme != theme { theme = snapshot.theme }
        theme.apply()
    }

    /// Rereads the settings the app shows, after `soroband config set` or a change in Settings.
    /// Only a changed layout or theme reaches the UI process at once, and only a changed layout
    /// redraws the menu bar; a changed reset hour reaches both with the poll the engine makes for
    /// it.
    func reloadSettings() {
        let theme = Theme(value: Core.setting)
        let layout = MenuBarLayout(
            scope: Core.setting(MenuBarScope.settingKey).flatMap(MenuBarScope.init(rawValue:)) ?? .network,
            readings: Core.setting(MenuBarLayout.readingsKey).flatMap(MenuBarLayout.readings(from:))
                ?? MenuBarLayout.default.readings,
            style: Core.setting(MenuBarLayout.styleKey).flatMap(MenuBarStyle.init(rawValue:))
                ?? MenuBarLayout.default.style,
            icon: Core.setting(MenuBarIcon.settingKey).flatMap(MenuBarIcon.init(rawValue:))
                ?? MenuBarLayout.default.icon)
        let resetHour = Core.setting("reset_hour").flatMap(Int.init) ?? 0
        if resetHour != self.resetHour { self.resetHour = resetHour }
        guard layout != menuBarLayout || theme != self.theme else { return }
        if layout != menuBarLayout { menuBarLayout = layout }
        if theme != self.theme { self.theme = theme }
        onChange?()
    }

    /// Saves the menu bar layout. Its values come from the core's options, so none is refused.
    func setMenuBarLayout(_ layout: MenuBarLayout) {
        if UIHost.forward(.setMenuBarLayout(layout)) {
            // Shown at once; the menu bar process's snapshot confirms it.
            menuBarLayout = layout
            return
        }
        let saved =
            Core.setSetting(MenuBarScope.settingKey, to: layout.scope.rawValue)
            && Core.setSetting(MenuBarLayout.readingsKey, to: layout.readingsValue)
            && Core.setSetting(MenuBarLayout.styleKey, to: layout.style.rawValue)
            && Core.setSetting(MenuBarIcon.settingKey, to: layout.icon.rawValue)
        if !saved { NSLog("Soroband: the menu bar layout was not saved") }
        reloadSettings()
    }

    /// Sets `key` as `soroband config set` would, for the island's and the theme's settings. A
    /// value that does not fit the setting is not saved.
    func setSetting(_ key: String, to value: String) {
        if UIHost.forward(.setSetting(key: key, value: value)) {
            // Shown at once; the menu bar process's snapshot confirms it.
            island = island.setting(key, to: value)
            theme = theme.setting(key, to: value)
            theme.apply()
            return
        }
        guard Core.setSetting(key, to: value) else {
            NSLog("Soroband: %@ = %@ was not saved", key, value)
            return
        }
        Core.reloadSettings()
        reloadSettings()
        IslandController.shared.reloadSettings()
    }

    func setResetHour(_ hour: Int) {
        if UIHost.forward(.setResetHour(hour)) {
            resetHour = hour
            return
        }
        if Core.setSetting("reset_hour", to: String(hour)) { reloadSettings() }
    }

    /// Sets network `id` to palette slot `color`, or back to its place's slot with nil.
    func setNetworkColor(id: Int64, color: Int?) {
        if UIHost.forward(.setNetworkColor(id: id, color: color)) { return }
        if !Core.setNetworkColor(id: id, color: color) {
            NSLog("Soroband: the color of network %lld was not saved", id)
        }
        reloadRegistry()
        onChange?()
    }

    /// Renames network `id` and sets its kind, as the user chose in Settings.
    func updateNetwork(id: Int64, name: String, kind: NetworkKind) {
        if UIHost.forward(.updateNetwork(id: id, name: name, kind: kind)) { return }
        if NetworkMonitor.shared.current?.id == id {
            NetworkMonitor.shared.updateCurrent(name: name, kind: kind)
        } else {
            Core.updateNetwork(id: id, name: name, kind: kind)
        }
        reloadRegistry()
        onChange?()
    }
}
