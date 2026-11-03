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
    /// and redraws once. The test host shares the Debug app's settings file, so the value is
    /// put back.
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
}
