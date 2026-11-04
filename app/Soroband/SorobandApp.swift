import SwiftUI

/// The UI process's app (`main.swift`).
struct SorobandApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    // The menu bar item, its popover and the windows are AppKit objects, so the app can open them
    // itself (and Debug builds on an agent's command). SwiftUI needs a scene.
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

    private var isUIProcess: Bool { CommandLine.arguments.contains(UIProcess.flag) }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // A second instance takes activation at launch, which would take the keyboard from the
        // app the user is in, before it shows anything. It may once it shows a window
        // (`UIHost`).
        if isUIProcess {
            NSApp.setActivationPolicy(.prohibited)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isUIProcess {
            startUI()
            return
        }
        if !Core.startEngine() {
            NSLog("Soroband: the usage database in %@ cannot be opened; nothing is recorded", Core.dataDirectory.path)
        }
        Usage.shared.start()
        MenuBarController.shared.start()
        // A UI process gone with the popover open leaves nobody to turn the live polls off.
        UIProcess.shared.onExit = { Usage.shared.isLive = false }
        NetworkMonitor.shared.start()
        SettingsListener.start()
        // `kill` quits like the Quit button, so the last minute of usage is written.
        signal(SIGTERM, SIG_IGN)
        terminateSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminateSignal?.setEventHandler { NSApp.terminate(nil) }
        terminateSignal?.resume()
        // `xcodebuild test` launches the app as its test host; the first run is the user's.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            Onboarding.showIfNeeded()
        }
        #if DEBUG
        DebugCommands.start()
        #endif
    }

    /// The UI process: the popover, Settings, History and the Welcome window (`UIHost`). It reads
    /// the database, and the engine's numbers come from the menu bar process.
    @MainActor
    private func startUI() {
        if !Core.openDatabase() {
            NSLog("Soroband: the usage database in %@ cannot be read", Core.dataDirectory.path)
        }
        #if DEBUG
        DebugCommands.startUI()
        #endif
        UIHost.start()
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard isUIProcess else { return .terminateNow }
        return HistoryWindow.shared.shouldTerminate { sender.reply(toApplicationShouldTerminate: true) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Core.stopEngine()
    }

    #if DEBUG
    /// macOS may hand a URL to either instance; the menu bar process runs every command.
    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        if isUIProcess {
            for url in urls { UIHost.send(.url(url.absoluteString)) }
        } else {
            urls.forEach(DebugCommands.handle)
        }
    }
    #endif
}
