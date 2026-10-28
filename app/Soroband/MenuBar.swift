import AppKit

/// What the menu bar item shows next to the network icon: the core's `menu_bar` setting.
enum MenuBarMode: String, CaseIterable, Identifiable {
    case todayNetwork = "today_network"
    case todayAll = "today_all"
    case speed
    case icon

    static let settingKey = "menu_bar"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .todayNetwork: "Today on current network"
        case .todayAll: "Today on all networks"
        case .speed: "Live speed"
        case .icon: "Icon only"
        }
    }
}

/// The menu bar item's icon and text.
struct MenuBarDisplay: Equatable {
    var symbol: String
    var text: String?

    /// - Today's totals are what crossed the interfaces, the network's true count.
    /// - The icon is the current network's kind; usage booked to no network shows a plain one.
    /// - An engine that stopped says so instead of showing a count that no longer grows.
    /// - Before the first poll there is no count to show yet.
    static func make(mode: MenuBarMode, status: EngineStatus, kind: NetworkKind?) -> MenuBarDisplay {
        let symbol = kind?.symbol ?? unknownNetworkSymbol
        if status.state == .failed {
            return MenuBarDisplay(symbol: "exclamationmark.triangle", text: mode == .icon ? nil : "Not counting")
        }
        if status.state == .starting { return MenuBarDisplay(symbol: symbol, text: nil) }
        return switch mode {
        case .todayNetwork:
            MenuBarDisplay(symbol: symbol, text: Format.menuBarBytes(status.todayNetworkInterfaces.total))
        case .todayAll: MenuBarDisplay(symbol: symbol, text: Format.menuBarBytes(status.todayInterfaces.total))
        case .speed:
            MenuBarDisplay(
                symbol: symbol, text: "↓ \(Format.speed(status.speed.rx)) ↑ \(Format.speed(status.speed.tx))")
        case .icon: MenuBarDisplay(symbol: symbol, text: nil)
        }
    }

    /// Every change redraws the status item on each display (about 18 ms of the main thread with
    /// four), so a total that only grew waits until `totalRedrawInterval` has passed since the last
    /// redraw. Anything else (another network, even of the same kind, the mode, a stopped engine,
    /// the live speed, a total that went down at the reset hour) shows at once.
    static let totalRedrawInterval: TimeInterval = 60

    /// The bytes the text of `mode` counts; nil for the modes that show no total.
    static func total(mode: MenuBarMode, status: EngineStatus) -> UInt64? {
        switch mode {
        case .todayNetwork: status.todayNetworkInterfaces.total
        case .todayAll: status.todayInterfaces.total
        case .speed, .icon: nil
        }
    }

    /// What the item shows, in which mode, for which network (the engine's id), counting how
    /// many bytes.
    struct Drawn: Equatable {
        var display: MenuBarDisplay
        var mode: MenuBarMode
        var network: Int64
        var total: UInt64?
    }

    /// Seconds to wait before showing `new` in place of `old`, drawn at `lastRedraw`.
    static func redrawDelay(from old: Drawn?, to new: Drawn, lastRedraw: Date, now: Date) -> TimeInterval {
        guard let old, old.display != new.display, old.mode == new.mode, old.network == new.network,
            old.display.symbol == new.display.symbol, old.display.text != nil,
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

    /// Read by VoiceOver.
    func accessibilityLabel(debug: Bool = isDebugBuild) -> String {
        [debug ? "Soroband Debug" : "Soroband", text].compactMap { $0 }.joined(separator: ", ")
    }
}
