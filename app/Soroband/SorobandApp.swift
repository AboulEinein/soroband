import SwiftUI

@main
struct SorobandApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    // Owned outside SwiftUI state so every scene and the debug commands share one instance.
    private var location: LocationAccess { .shared }

    var body: some Scene {
        MenuBarExtra {
            LocationMenuItem(location: location)
            Divider()
            Button("Quit Soroband") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            MenuBarLabel(text: MenuBar.text)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        DebugCommands.start()
        #endif
    }

    #if DEBUG
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(DebugCommands.handle)
    }
    #endif
}
