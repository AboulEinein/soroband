import AppKit

/// Whose usage today the menu bar item counts: the core's `menu_bar_scope` setting.
enum MenuBarScope: String, CaseIterable, Identifiable {
    case network
    case all

    static let settingKey = "menu_bar_scope"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .network: "Current network"
        case .all: "All networks"
        }
    }
}

/// What one line of the menu bar item shows: the core's `menu_bar_top` and `menu_bar_bottom`.
enum MenuBarLine: String, CaseIterable, Identifiable {
    case total
    case download
    case upload
    case speed
    case speedDown = "speed_down"
    case speedUp = "speed_up"
    case none

    var id: String { rawValue }

    /// Today's bytes, as opposed to the live speed.
    static let usage: [MenuBarLine] = [.total, .download, .upload]
    static let speeds: [MenuBarLine] = [.speed, .speedDown, .speedUp]

    var label: String {
        switch self {
        case .total: "Total"
        case .download: "Download"
        case .upload: "Upload"
        case .speed: "Speed"
        case .speedDown: "Download speed"
        case .speedUp: "Upload speed"
        case .none: "Nothing"
        }
    }

    var isSpeed: Bool { Self.speeds.contains(self) }

    /// The line's text: today's bytes as the menu bar rounds them, or the live speed.
    func text(today: ByteCounts, speed: ByteCounts) -> String? {
        switch self {
        case .total: Format.menuBarBytes(today.total)
        case .download: "↓ \(Format.menuBarBytes(today.rx))"
        case .upload: "↑ \(Format.menuBarBytes(today.tx))"
        case .speed: "↓ \(Format.speed(speed.rx)) ↑ \(Format.speed(speed.tx))"
        case .speedDown: "↓ \(Format.speed(speed.rx))"
        case .speedUp: "↑ \(Format.speed(speed.tx))"
        case .none: nil
        }
    }

    /// Today's bytes the line counts; nil for a speed or no line.
    func counted(_ today: ByteCounts) -> UInt64? {
        switch self {
        case .total: today.total
        case .download: today.rx
        case .upload: today.tx
        case .speed, .speedDown, .speedUp, .none: nil
        }
    }
}

/// What the menu bar item shows: up to two lines next to the network icon, counting today on
/// the current network or on all of them.
struct MenuBarLayout: Equatable {
    var scope: MenuBarScope = .network
    var top: MenuBarLine = .total
    var bottom: MenuBarLine = .none

    static let `default` = MenuBarLayout()
    static let topKey = "menu_bar_top"
    static let bottomKey = "menu_bar_bottom"

    /// The lines shown, top first; empty for the icon alone.
    var lines: [MenuBarLine] { [top, bottom].filter { $0 != .none } }

    var showsSpeed: Bool { lines.contains { $0.isSpeed } }
    var showsUsage: Bool { lines.contains { !$0.isSpeed } }
}

/// The menu bar item's icon and lines.
struct MenuBarDisplay: Equatable {
    var symbol: String
    /// One line is drawn at the menu bar's size; two are stacked in a smaller size.
    var lines: [String]

    /// The lines as one string, for VoiceOver and `soroband debug state`; nil for the icon alone.
    var text: String? { lines.isEmpty ? nil : lines.joined(separator: " ") }

    /// - Today's totals are what crossed the interfaces, the network's true count.
    /// - The icon is the current network's kind; usage booked to no network shows a plain one.
    /// - An engine that stopped says so instead of showing a count that no longer grows.
    /// - Before the first poll there is no count to show yet.
    static func make(layout: MenuBarLayout, status: EngineStatus, kind: NetworkKind?) -> MenuBarDisplay {
        let symbol = kind?.symbol ?? unknownNetworkSymbol
        if status.state == .failed {
            return MenuBarDisplay(
                symbol: "exclamationmark.triangle", lines: layout.lines.isEmpty ? [] : ["Not counting"])
        }
        if status.state == .starting { return MenuBarDisplay(symbol: symbol, lines: []) }
        let today = layout.scope == .network ? status.todayNetworkInterfaces : status.todayInterfaces
        // Both speeds alone stack, download over upload, rather than one wide line.
        if layout.lines == [.speed] {
            return MenuBarDisplay(
                symbol: symbol,
                lines: [MenuBarLine.speedDown, .speedUp].compactMap { $0.text(today: today, speed: status.speed) })
        }
        return MenuBarDisplay(
            symbol: symbol, lines: layout.lines.compactMap { $0.text(today: today, speed: status.speed) })
    }

    /// Every change of the lines redraws the status item on each display (about 18 ms of the main
    /// thread with four), so a total that only grew waits until `totalRedrawInterval` has passed
    /// since the last redraw. Anything else (another network, even of the same kind, the layout, a
    /// stopped engine, the live speed, a total that went down at the reset hour) shows at once.
    static let totalRedrawInterval: TimeInterval = 60

    /// The bytes the lines count, summed; nil when a line shows the live speed or none counts.
    /// Each counted part only grows during a day, so the sum grows whenever any shown part does.
    static func total(layout: MenuBarLayout, status: EngineStatus) -> UInt64? {
        guard !layout.showsSpeed, layout.showsUsage else { return nil }
        let today = layout.scope == .network ? status.todayNetworkInterfaces : status.todayInterfaces
        return layout.lines.compactMap { $0.counted(today) }.reduce(0, +)
    }

    /// What the item shows, with which layout, for which network (the engine's id), counting how
    /// many bytes.
    struct Drawn: Equatable {
        var display: MenuBarDisplay
        var layout: MenuBarLayout
        var network: Int64
        var total: UInt64?
    }

    /// Seconds to wait before showing `new` in place of `old`, drawn at `lastRedraw`.
    static func redrawDelay(from old: Drawn?, to new: Drawn, lastRedraw: Date, now: Date) -> TimeInterval {
        guard let old, old.display != new.display, old.layout == new.layout, old.network == new.network,
            old.display.symbol == new.display.symbol, !old.display.lines.isEmpty,
            let oldTotal = old.total, let newTotal = new.total, newTotal >= oldTotal
        else { return 0 }
        return max(0, totalRedrawInterval - now.timeIntervalSince(lastRedraw))
    }

    /// Whether this is a Debug build, which runs beside the installed app.
    static let isDebugBuild: Bool = {
        #if DEBUG
        true
        #else
        false
        #endif
    }()

    /// The icon as the menu bar draws it. A Debug build's icon is orange, so its item is never
    /// taken for the installed app's.
    func image(debug: Bool = isDebugBuild) -> NSImage? {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        guard debug else {
            image?.isTemplate = true
            return image
        }
        let orange = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemOrange]))
        orange?.isTemplate = false
        return orange
    }

    /// The font of stacked lines: two fit the menu bar's height, digits of one width.
    @MainActor static var stackedFont: NSFont { .monospacedDigitSystemFont(ofSize: 9.5, weight: .medium) }

    /// Two lines stacked and right-aligned, as one image beside the icon. A template image takes
    /// the menu bar's text color; `color` draws it in a fixed one instead (a Debug build, whose
    /// item is not a template).
    @MainActor static func stackedImage(_ lines: [String], color: NSColor? = nil) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: stackedFont, .foregroundColor: color ?? NSColor.black,
        ]
        let strings = lines.map { NSAttributedString(string: $0, attributes: attributes) }
        let width = ceil(strings.map { $0.size().width }.max() ?? 0)
        let lineHeight: CGFloat = 10.5
        let size = NSSize(width: width, height: 22)
        let image = NSImage(size: size, flipped: true) { _ in
            let top = (size.height - lineHeight * CGFloat(strings.count)) / 2
            for (index, string) in strings.enumerated() {
                let x = width - string.size().width
                // Each line's box is taller than its digits; draw it up by the difference.
                string.draw(at: NSPoint(x: x, y: top + lineHeight * CGFloat(index) - 1))
            }
            return true
        }
        image.isTemplate = color == nil
        return image
    }

    /// The icon and two stacked lines as the one image the status item draws: a status item has
    /// one image and one line of title. `textColor` is the menu bar's text color for a Debug build,
    /// whose image is not a template.
    @MainActor func stackedItemImage(debug: Bool = isDebugBuild, textColor: NSColor = .labelColor) -> NSImage? {
        guard let icon = image(debug: debug) else { return nil }
        let text = Self.stackedImage(lines, color: debug ? textColor : nil)
        let gap: CGFloat = 4
        let size = NSSize(width: icon.size.width + gap + text.size.width, height: text.size.height)
        let composite = NSImage(size: size, flipped: false) { _ in
            icon.draw(
                in: NSRect(
                    x: 0, y: (size.height - icon.size.height) / 2, width: icon.size.width,
                    height: icon.size.height))
            text.draw(in: NSRect(x: icon.size.width + gap, y: 0, width: text.size.width, height: text.size.height))
            return true
        }
        composite.isTemplate = !debug
        return composite
    }

    /// Read by VoiceOver.
    func accessibilityLabel(debug: Bool = isDebugBuild) -> String {
        [debug ? "Soroband Debug" : "Soroband", text].compactMap { $0 }.joined(separator: ", ")
    }
}
