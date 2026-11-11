import Foundation
import Testing

@testable import Soroband

@MainActor
struct UsageTests {
    /// An engine that stops before its first poll, such as one whose database cannot be opened,
    /// never calls back; the menu bar must still learn its state when the app starts.
    @Test func startReadsTheEnginesStatusWithoutWaitingForAPoll() async throws {
        // The test host's engine has polled by now, so its status is no longer the empty one.
        Core.startEngine(interval: 1)
        let deadline = Date.now.addingTimeInterval(15)
        while Core.engine.state == .starting, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        let usage = Usage()
        #expect(usage.status.state == .starting)
        usage.start()
        #expect(usage.status.state == Core.engine.state)
        #expect(usage.status.state != .starting)
    }

    /// A reread that finds the same settings, as most of a burst of notifications does, leaves
    /// the menu bar alone.
    @Test func rereadingUnchangedSettingsDoesNotRedrawTheMenuBar() {
        let usage = Usage()
        usage.reloadSettings()
        var changes = 0
        usage.onChange = { changes += 1 }
        usage.reloadSettings()
        #expect(changes == 0)
    }

    /// `soroband config set menu_bar_readings` must reach the menu bar: a changed layout is kept
    /// and redraws once. Other tests share the test host's settings file, so the value is put
    /// back.
    @Test func rereadingAChangedLayoutRedrawsTheMenuBarOnce() throws {
        let original = try #require(Core.setting(MenuBarLayout.readingsKey))
        defer { Core.setSetting(MenuBarLayout.readingsKey, to: original) }
        let usage = Usage()
        usage.reloadSettings()
        var changes = 0
        usage.onChange = { changes += 1 }
        let changed = original == "download" ? "upload" : "download"
        #expect(Core.setSetting(MenuBarLayout.readingsKey, to: changed))
        usage.reloadSettings()
        #expect(usage.menuBarLayout.readingsValue == changed)
        #expect(changes == 1)
    }

    /// The icon reaches the menu bar from `soroband config set menu_bar_icon`, and Settings' Icon
    /// picker saves it where the command reads it. The value is put back, as above.
    @Test func theIconSettingReachesTheLayoutAndIsSavedFromIt() throws {
        let original = try #require(Core.setting(MenuBarIcon.settingKey))
        defer { Core.setSetting(MenuBarIcon.settingKey, to: original) }
        let usage = Usage()
        var changes = 0
        usage.onChange = { changes += 1 }
        #expect(Core.setSetting(MenuBarIcon.settingKey, to: "soroband"))
        usage.reloadSettings()
        #expect(usage.menuBarLayout.icon == .soroband)
        var layout = usage.menuBarLayout
        layout.icon = .network
        usage.setMenuBarLayout(layout)
        #expect(Core.setting(MenuBarIcon.settingKey) == "network")
        #expect(usage.menuBarLayout.icon == .network)
        #expect(changes == 2)
    }

    /// `soroband config set accent` reaches the UI process: the menu bar process's `Usage` keeps
    /// the new theme and announces it once (its `onChange` publishes the snapshot), and Settings'
    /// pick is saved where the command reads it. The values are put back, as above.
    @Test func theThemeSettingsReachTheSnapshotAndAreSavedFromSettings() throws {
        let original = (
            try #require(Core.setting(Appearance.settingKey)), try #require(Core.setting(Accent.settingKey))
        )
        defer {
            Core.setSetting(Appearance.settingKey, to: original.0)
            Core.setSetting(Accent.settingKey, to: original.1)
        }
        let usage = Usage()
        usage.reloadSettings()
        var changes = 0
        usage.onChange = { changes += 1 }
        #expect(Core.setSetting(Accent.settingKey, to: original.1 == "coral" ? "amber" : "coral"))
        usage.reloadSettings()
        #expect(usage.theme.accent == (original.1 == "coral" ? .amber : .coral))
        #expect(changes == 1)
        let appearance: Appearance = original.0 == "dark" ? .light : .dark
        usage.setSetting(Appearance.settingKey, to: appearance.rawValue)
        #expect(Core.setting(Appearance.settingKey) == appearance.rawValue)
        #expect(usage.theme.appearance == appearance)
        #expect(changes == 2)
        // A value the core refuses is not kept.
        usage.setSetting(Accent.settingKey, to: "rainbow")
        #expect(usage.theme.accent == (original.1 == "coral" ? .amber : .coral))
        #expect(changes == 2)
    }
}
