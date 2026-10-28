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
    private var terminateSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !Core.startEngine() {
            NSLog("Soroband: the usage database in %@ cannot be opened; nothing is recorded", Core.dataDirectory.path)
        }
        NetworkMonitor.shared.start()
        SettingsListener.start()
        // `kill` quits like the Quit item, so the last minute of usage is written.
        signal(SIGTERM, SIG_IGN)
        terminateSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminateSignal?.setEventHandler { NSApp.terminate(nil) }
        terminateSignal?.resume()
        #if DEBUG
        DebugCommands.start()
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        Core.stopEngine()
    }

    #if DEBUG
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(DebugCommands.handle)
    }
    #endif
}
