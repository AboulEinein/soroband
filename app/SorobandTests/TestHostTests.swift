import AppKit
import Testing

struct TestHostTests {
    @MainActor
    @Test func testHostCannotTakeFocus() {
        // Agents run these tests while the user types in another app; an activated host takes
        // the keyboard.
        #expect(NSApp.activationPolicy() == .prohibited)
    }
}
