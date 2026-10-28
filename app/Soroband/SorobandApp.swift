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

    func applicationWillFinishLaunching(_ notification: Notification) {
        // A standby History process must not take activation from the menu bar app, which would
        // close the popover that started it. It may once it shows its window.
        if CommandLine.arguments.contains(HistoryOptions.standbyFlag) {
            NSApp.setActivationPolicy(.prohibited)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let options = HistoryOptions(arguments: CommandLine.arguments) {
            startHistory(options)
            return
        }
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
        // `xcodebuild test` launches the app as its test host; the first run is the user's.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            Onboarding.showIfNeeded()
        }
        #if DEBUG
        DebugCommands.start()
        #endif
    }

    /// The History process: the History window and nothing else (`HistoryOptions`).
    @MainActor
    private func startHistory(_ options: HistoryOptions) {
        if !Core.openDatabase() {
            NSLog("Soroband: the usage database in %@ cannot be read", Core.dataDirectory.path)
        }
        #if DEBUG
        DebugCommands.startHistory()
        #endif
        // Standard input closing means the menu bar app is gone or dropped this process.
        HistoryStandby.listen(
            show: { HistoryWindow.shared.show($0) },
            ended: { NSApp.terminate(nil) })
        if CommandLine.arguments.contains(HistoryOptions.standbyFlag) {
            HistoryWindow.shared.warmUp()
        } else {
            HistoryWindow.shared.show(options)
        }
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
