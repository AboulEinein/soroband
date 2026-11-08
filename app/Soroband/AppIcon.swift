import AppKit

/// Soroband's icon: the core's `app_icon` setting. Graphite is the bundle's own icon (the asset
/// catalog's `AppIcon`); each other one is an `.icns` from Soroband's icon pack, in the bundle's
/// resources (`AppIcons/`).
enum AppIcon: String, Codable, CaseIterable, Identifiable {
    case graphite, indigo, plum, light
    case hairlineCoral = "hairline-coral"
    case hairlineIndigo = "hairline-indigo"
    case hairlineTeal = "hairline-teal"
    case hairlineEmerald = "hairline-emerald"
    case hairlineAmber = "hairline-amber"
    case hairlineRose = "hairline-rose"
    case hairlineSky = "hairline-sky"
    case hairlineGraphite = "hairline-graphite"
    case hairlinePaper = "hairline-paper"

    static let settingKey = "app_icon"

    /// The icon `value` names; a missing or unknown value (a hand edit, a word from a newer
    /// Soroband) is graphite, the bundle's own.
    init(setting value: String?) {
        self = value.flatMap(AppIcon.init(rawValue:)) ?? .graphite
    }

    var id: String { rawValue }

    /// "Hairline Coral" for `hairline-coral`.
    var label: String {
        rawValue.split(separator: "-").map(\.capitalized).joined(separator: " ")
    }

    /// The `.icns` in the bundle's resources that draws this icon: graphite's is the one the asset
    /// catalog builds.
    var resourceName: String {
        self == .graphite ? "AppIcon" : "AppIcon-\(rawValue)"
    }

    /// The image the app sets in place of the bundle's icon (`NSApp.applicationIconImage`,
    /// Finder's custom icon); nil for graphite, which is the bundle's icon.
    func customImage(in bundle: Bundle = .main) -> NSImage? {
        guard self != .graphite, let icon = image(in: bundle) else { return nil }
        return Self.framed(icon)
    }

    /// `icon` on macOS's icon grid: macOS draws the bundle's own icon at 824 of 1024 pixels with a
    /// shadow under it, but a custom icon as it is, so the pack's full-bleed squares would stand
    /// larger than graphite and every other app. Drawn at each size asked for, from the file's
    /// nearest image.
    static func framed(_ icon: NSImage) -> NSImage {
        NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            let side = rect.width * 824 / 1024
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.shadowBlurRadius = rect.width * 20 / 1024
            shadow.shadowOffset = NSSize(width: 0, height: -rect.width * 8 / 1024)
            shadow.set()
            icon.draw(in: NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side))
            return true
        }
    }

    /// The icon's file as an image, every size in it.
    func image(in bundle: Bundle = .main) -> NSImage? {
        bundle.url(forResource: resourceName, withExtension: "icns").flatMap(NSImage.init(contentsOf:))
    }

    /// In the UI process: the Dock (while a window is open) and Settings › About show this icon.
    @MainActor
    func applyToApp() {
        NSApp.applicationIconImage = customImage()
    }
}

/// What the menu bar process does to the bundle's icon in Finder.
enum FinderIconChange: Equatable {
    /// Writes the icon into the bundle (`NSWorkspace.setIcon`), which adds an `Icon\r` file to it.
    case set(AppIcon)
    /// Takes the custom icon off again, back to the bundle's own.
    case remove
}

/// When the bundle's icon in Finder changes. It is written only when the setting changes, and at a
/// launch only when the bundle lost it (an update replaced the bundle) or holds another one (the
/// setting changed while Soroband was not running), so a launch normally reads two cheap facts
/// and decodes no image.
enum FinderIconPlan {
    /// At launch. `hasCustomIcon` is whether the bundle holds an `Icon\r` file, `written` the icon
    /// this Mac's Soroband last wrote there (nil when none, or after taking it off), `canWrite`
    /// whether this account can change the bundle.
    static func atLaunch(_ icon: AppIcon, hasCustomIcon: Bool, written: AppIcon?, canWrite: Bool) -> FinderIconChange? {
        guard canWrite else { return nil }
        if icon == .graphite {
            // Only an icon Soroband wrote is taken off; one the user pasted in Finder stays.
            return hasCustomIcon && written != nil ? .remove : nil
        }
        return hasCustomIcon && written == icon ? nil : .set(icon)
    }

    /// After the setting changed from `old` to `new` while Soroband runs.
    static func changed(from old: AppIcon, to new: AppIcon, canWrite: Bool) -> FinderIconChange? {
        guard canWrite, old != new else { return nil }
        return new == .graphite ? .remove : .set(new)
    }
}

/// The bundle's icon in Finder, kept to the `app_icon` setting by the menu bar process. Accepted
/// cost: the `Icon\r` file macOS writes into the bundle's root is content outside the signature's
/// seal, which `codesign --verify --strict` reports.
@MainActor
final class FinderIcon {
    static let shared = FinderIcon(bundle: Bundle.main.bundleURL)

    /// Off in the UI process; `AppDelegate` sets it in the menu bar process before the first read
    /// of the settings (`isEnabled`).
    var isActive = false

    /// The variable that lets a Debug build write Finder's icon.
    nonisolated static let debugEnvironmentKey = "SOROBAND_FINDER_ICON"

    /// Whether the menu bar process keeps Finder's icon. Never in the test host. Debug builds share
    /// one data directory across worktrees, and an `Icon\r` in a build's bundle makes Xcode's next
    /// signing of it fail, so a Debug build writes only with `SOROBAND_FINDER_ICON=1`; its UI
    /// process still shows the picked icon.
    nonisolated static func isEnabled(isDebug: Bool, environment: [String: String]) -> Bool {
        guard environment["XCTestConfigurationFilePath"] == nil else { return false }
        return !isDebug || environment[debugEnvironmentKey] == "1"
    }

    private let bundle: URL
    /// The icon the setting held at the last update; nil before the first, at launch.
    private var current: AppIcon?
    private let queue = DispatchQueue(label: "io.github.abouleinein.soroband.finder-icon", qos: .utility)

    /// The icon this Mac's Soroband last wrote into the bundle, kept in its `UserDefaults`.
    private nonisolated static let writtenKey = "finderIconWritten"

    init(bundle: URL) {
        self.bundle = bundle
    }

    /// Whether this account can change the bundle `url`: a copy another user installed keeps the
    /// bundle's icon in Finder.
    nonisolated static func canWrite(_ url: URL) -> Bool {
        access(url.path, W_OK) == 0
    }

    /// Whether the bundle holds a custom icon, which Finder keeps in its `Icon\r` file.
    nonisolated static func hasCustomIcon(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("Icon\r").path)
    }

    /// Called with the setting at each read of the settings.
    func update(_ icon: AppIcon) {
        guard isActive else { return }
        let change: FinderIconChange?
        if let current {
            change = FinderIconPlan.changed(from: current, to: icon, canWrite: Self.canWrite(bundle))
        } else {
            change = FinderIconPlan.atLaunch(
                icon, hasCustomIcon: Self.hasCustomIcon(bundle),
                written: UserDefaults.standard.string(forKey: Self.writtenKey).map(AppIcon.init(setting:)),
                canWrite: Self.canWrite(bundle))
        }
        current = icon
        guard let change else { return }
        // One write at a time, in order, off the main thread.
        queue.async { [bundle] in Self.write(change, to: bundle) }
    }

    /// The argument that makes the executable write Finder's icon and exit (`main.swift`).
    nonisolated static let writerFlag = "--write-finder-icon"

    /// Writes `change` in a process of its own: `NSWorkspace.setIcon` renders the icon at every
    /// size and loads image frameworks, which kept about 23 MB in the menu bar process after one
    /// write, over its budget, and no API returns.
    private nonisolated static func write(_ change: FinderIconChange, to bundle: URL) {
        let icon: AppIcon
        switch change {
        case .set(let picked): icon = picked
        case .remove: icon = .graphite
        }
        let writer = Process()
        writer.executableURL = Bundle.main.executableURL
        writer.arguments = [writerFlag, icon.rawValue, bundle.path]
        do {
            try writer.run()
            writer.waitUntilExit()
        } catch {
            NSLog("Soroband: the Finder icon writer did not start: %@", error.localizedDescription)
            return
        }
        guard writer.terminationStatus == 0 else {
            NSLog("Soroband: Finder's icon for %@ was not changed", bundle.path)
            return
        }
        switch change {
        case .set(let icon): UserDefaults.standard.set(icon.rawValue, forKey: writtenKey)
        case .remove: UserDefaults.standard.removeObject(forKey: writtenKey)
        }
    }

    /// In the writer process: sets `arguments`' icon on the bundle at its path, or takes the
    /// custom icon off for graphite. Returns the exit status.
    nonisolated static func runWriter(_ arguments: [String]) -> Int32 {
        guard arguments.count == 2, let icon = AppIcon(rawValue: arguments[0]) else { return 2 }
        let image = icon.customImage()
        if icon != .graphite, image == nil {
            NSLog("Soroband: the %@ icon is missing from the app", icon.rawValue)
            return 1
        }
        return NSWorkspace.shared.setIcon(image, forFile: arguments[1], options: []) ? 0 : 1
    }
}
