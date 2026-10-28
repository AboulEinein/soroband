import SwiftUI

@main
struct SorobandApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    // The menu bar item, its popover and the windows are AppKit objects owned by the delegate, so
    // the app can open them itself (and Debug builds on an agent's command). SwiftUI needs a scene.
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                // ⌘, opens the app's own Settings window, not this empty scene.
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { SettingsWindow.shared.show() }
                        .keyboardShortcut(",")
                }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminateSignal: DispatchSourceSignal?
    // `xcodebuild test` launches the app as its test host.
    private let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The test runner launches the host as the active app, which takes keyboard focus from
        // whatever the user is typing in while an agent runs the tests.
        if isTestHost { NSApp.setActivationPolicy(.prohibited) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !Core.startEngine() {
            NSLog("Soroband: the usage database in %@ cannot be opened; nothing is recorded", Core.dataDirectory.path)
        }
        Usage.shared.start()
        MenuBarController.shared.start()
        NetworkMonitor.shared.start()
        SettingsListener.start()
        // `kill` quits like the Quit button, so the last minute of usage is written.
        signal(SIGTERM, SIG_IGN)
        terminateSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminateSignal?.setEventHandler { NSApp.terminate(nil) }
        terminateSignal?.resume()
        // The first run is the user's, not the test host's.
        if !isTestHost {
            Onboarding.showIfNeeded()
        }
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
