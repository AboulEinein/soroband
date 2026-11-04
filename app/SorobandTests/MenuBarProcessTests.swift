import AppKit
import Testing

@testable import Soroband

/// The menu bar process runs all day without a window, so it runs AppKit alone (`main.swift`):
/// the SwiftUI app lifecycle holds about 4 MB in it from launch. The test host is a menu bar
/// process.
@MainActor
struct MenuBarProcessTests {
    @Test func theMenuBarProcessRunsNoSwiftUIApp() {
        #expect(NSApp.delegate is AppDelegate)
        // The SwiftUI app lifecycle builds a main menu, with an icon for most of its items.
        #expect(NSApp.mainMenu == nil)
    }
}
