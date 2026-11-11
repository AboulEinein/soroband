import AppKit

// The menu bar process starts the executable for a moment to write Finder's icon (`FinderIcon`):
// no app, no window, nothing kept.
if let flag = CommandLine.arguments.firstIndex(of: FinderIcon.writerFlag) {
    exit(FinderIcon.runWriter(Array(CommandLine.arguments[(flag + 1)...])))
}

#if DEBUG
Core.isolateTestHost()
#endif

// The UI process shows SwiftUI windows and runs the SwiftUI app (`SorobandApp`). The menu bar
// process runs AppKit alone: the SwiftUI app lifecycle builds a scene graph and a main menu that
// cost it memory all day, and it never shows a window.
if CommandLine.arguments.contains(UIProcess.flag) {
    SorobandApp.main()
} else {
    // `NSApplication.delegate` is weak: keep the delegate alive for as long as the app runs.
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    withExtendedLifetime(delegate) {
        NSApplication.shared.run()
    }
}
