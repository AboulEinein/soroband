#if DEBUG
import AppKit
import notify

/// Lets an agent drive and observe a Debug build without a mouse.
///
/// - `open "soroband-debug://<command>"` runs a command (see `handle`).
/// - `soroband debug state --json` posts `dumpStateNotification`; the app answers by writing its
///   state to `stateFile`. Both names must match `core/crates/soroband-cli/src/debug.rs`.
@MainActor
enum DebugCommands {
    static let dumpStateNotification = "io.github.abouleinein.soroband.debug.dump-state"
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Caches/io.github.abouleinein.soroband.debug")
    static let stateFile = directory.appending(path: "state.json")
    static let statusItemFile = directory.appending(path: "status-item.png")

    private static var token: Int32 = 0

    static func start() {
        notify_register_dispatch(dumpStateNotification, &token, .main) { _ in
            MainActor.assumeIsolated { writeState() }
        }
    }

    static func handle(_ url: URL) {
        guard url.scheme == "soroband-debug" else { return }
        switch url.host() {
        case "quit": NSApp.terminate(nil)
        case "capture-status-item": captureStatusItem()
        default: NSLog("soroband-debug: unknown command %@", url.absoluteString)
        }
    }

    /// Renders the menu bar item to `statusItemFile`. The item may sit behind the notch on a
    /// crowded menu bar, where `screencapture` cannot see it. The output path is fixed because any
    /// app or web page can open a `soroband-debug://` URL.
    private static func captureStatusItem() {
        guard let view = NSApp.windows.first(where: { $0.title.hasPrefix("Item-") })?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else {
            NSLog("soroband-debug: capture-status-item found no status item")
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        // The item draws on a transparent window; put it on a dark menu bar so the text shows.
        let pixels = NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        let image = NSImage(size: pixels, flipped: false) { rect in
            NSColor(white: 0.15, alpha: 1).setFill()
            rect.fill()
            bitmap.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            return true
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let png = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?
                .representation(using: .png, properties: [:])
            try png?.write(to: statusItemFile, options: .atomic)
        } catch {
            NSLog("soroband-debug: cannot write %@: %@", statusItemFile.path, String(describing: error))
        }
    }

    static func writeState() {
        let state = DebugState.current()
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(state).write(to: stateFile, options: .atomic)
        } catch {
            NSLog("soroband-debug: cannot write state: %@", String(describing: error))
        }
    }
}

/// What the running app shows, as printed by `soroband debug state --json`.
struct DebugState: Encodable {
    struct Window: Encodable {
        let number: Int
        let kind: String
        let title: String
        let visible: Bool
        /// Frame in `screencapture -R` coordinates: points, origin at the top left of the main display.
        let rect: Rect
    }

    struct Rect: Encodable {
        let x, y, width, height: Double
    }

    let pid: Int32
    let bundleIdentifier: String
    let coreVersion: String
    let menuBarText: String
    let location: String
    let windows: [Window]

    @MainActor
    static func current() -> DebugState {
        let mainDisplayHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return DebugState(
            pid: ProcessInfo.processInfo.processIdentifier,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
            coreVersion: Core.version,
            menuBarText: MenuBar.text,
            location: LocationAccess.shared.statusName,
            windows: NSApp.windows.map { window in
                let frame = window.frame
                return Window(
                    number: window.windowNumber,
                    kind: String(describing: type(of: window)),
                    title: window.title,
                    visible: window.isVisible,
                    rect: Rect(
                        x: frame.minX, y: mainDisplayHeight - frame.maxY,
                        width: frame.width, height: frame.height))
            })
    }
}
#endif
