import AppKit

// The UI process shows SwiftUI windows and runs the SwiftUI app (`SorobandApp`). The menu bar
// process runs AppKit alone: the SwiftUI app lifecycle builds a scene graph and a main menu that
// cost it memory all day, and it never shows a window.
if CommandLine.arguments.contains(UIProcess.flag) {
    SorobandApp.main()
} else {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.run()
}
