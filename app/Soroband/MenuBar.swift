import AppKit

/// Whose usage today the menu bar item counts: the core's `menu_bar_scope` setting.
enum MenuBarScope: String, CaseIterable, Identifiable {
    case network
    case all

    static let settingKey = "menu_bar_scope"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .network: "This network"
        case .all: "All networks"
        }
    }
}

/// One reading the menu bar item can show: an item of the core's `menu_bar_readings`.
enum MenuBarReading: String, CaseIterable, Identifiable {
    case total
    case download
    case upload
    case speedDown = "speed_down"
    case speedUp = "speed_up"

    var id: String { rawValue }

    /// Today's bytes, as opposed to the live speed.
    static let usage: [MenuBarReading] = [.total, .download, .upload]
    static let speeds: [MenuBarReading] = [.speedDown, .speedUp]

    var label: String {
        switch self {
        case .total: "Today’s total"
        case .download: "Today’s download"
        case .upload: "Today’s upload"
        case .speedDown: "Download speed"
        case .speedUp: "Upload speed"
        }
    }

    /// The reading's name where space is short.
    var shortLabel: String {
        switch self {
        case .total: "Total"
        case .download: "Down"
        case .upload: "Up"
        case .speedDown: "↓ Speed"
        case .speedUp: "↑ Speed"
        }
    }

    /// The caption the labeled style draws over the value.
    var caption: String {
        switch self {
        case .total: "TODAY"
        case .download: "DOWN"
        case .upload: "UP"
        case .speedDown: "↓ LIVE"
        case .speedUp: "↑ LIVE"
        }
    }

    var symbol: String {
        switch self {
        case .total: "chart.bar.fill"
        case .download: "arrow.down"
        case .upload: "arrow.up"
        case .speedDown: "arrow.down.circle"
        case .speedUp: "arrow.up.circle"
        }
    }

    var isSpeed: Bool { Self.speeds.contains(self) }

    /// The value alone: today's bytes as the menu bar rounds them, or the live speed.
    func value(today: ByteCounts, speed: ByteCounts) -> String {
        switch self {
        case .total: Format.menuBarBytes(today.total)
        case .download: Format.menuBarBytes(today.rx)
        case .upload: Format.menuBarBytes(today.tx)
        case .speedDown: Format.menuBarSpeed(speed.rx)
        case .speedUp: Format.menuBarSpeed(speed.tx)
        }
    }

    /// The value with an arrow for its direction, as it reads without a caption.
    func text(today: ByteCounts, speed: ByteCounts) -> String {
        let value = value(today: today, speed: speed)
        return switch self {
        case .total: value
        case .download, .speedDown: "↓ \(value)"
        case .upload, .speedUp: "↑ \(value)"
        }
    }

    /// Today's bytes the reading counts; nil for a speed.
    func counted(_ today: ByteCounts) -> UInt64? {
        switch self {
        case .total: today.total
        case .download: today.rx
        case .upload: today.tx
        case .speedDown, .speedUp: nil
        }
    }
}

/// How the menu bar item draws its readings: the core's `menu_bar_style`.
enum MenuBarStyle: String, CaseIterable, Identifiable {
    /// In pairs, the first on top, in a smaller size; a reading without a partner at full size.
    case stacked
    /// Each value under a small caption.
    case labeled
    /// One line at the menu bar's size.
    case inline

    var id: String { rawValue }

    var label: String {
        switch self {
        case .stacked: "Stacked"
        case .labeled: "Labeled"
        case .inline: "Inline"
        }
    }
}

/// What the menu bar item shows: up to four readings beside the network icon, in order, counting
/// today on the current network or on all of them, drawn in a style.
struct MenuBarLayout: Equatable {
    static let maxReadings = 4

    var scope: MenuBarScope = .network
    /// Empty for the icon alone.
    var readings: [MenuBarReading] = [.total]
    var style: MenuBarStyle = .stacked

    static let `default` = MenuBarLayout()
    static let readingsKey = "menu_bar_readings"
    static let styleKey = "menu_bar_style"

    var showsSpeed: Bool { readings.contains { $0.isSpeed } }

    /// Today's bytes the readings count: on the current network, or on all of them.
    func today(in status: EngineStatus) -> ByteCounts {
        scope == .network ? status.todayNetworkInterfaces : status.todayInterfaces
    }
    var showsUsage: Bool { readings.contains { !$0.isSpeed } }

    /// `readings` as the core stores them: names separated by commas, or `none`.
    var readingsValue: String {
        readings.isEmpty ? "none" : readings.map(\.rawValue).joined(separator: ",")
    }

    /// The readings in a stored value; nil when it names one the app does not know.
    static func readings(from value: String) -> [MenuBarReading]? {
        if value == "none" { return [] }
        let readings = value.split(separator: ",").map { MenuBarReading(rawValue: String($0)) }
        return readings.contains(nil) ? nil : readings.compactMap { $0 }
    }
}

/// The menu bar item's icon and readings.
struct MenuBarDisplay: Equatable {
    /// One reading as drawn: its caption, its value, and the value with its arrow.
    struct Reading: Equatable {
        var caption = ""
        var value: String
        var text: String
        /// The widest value the reading takes in normal use, whose width it keeps while its own is
        /// narrower: a speed changes at every poll, and an item that changed width would move the
        /// menu bar's other items and lay the menu bar out again.
        var widestValue: String?

        var widestText: String { widestValue.map { text.replacingOccurrences(of: value, with: $0) } ?? text }
    }

    /// The widest speed the menu bar shows below 1 GB/s.
    static let widestSpeed = "999 MB/s"

    var symbol: String
    var style = MenuBarStyle.stacked
    var readings: [Reading]

    /// The readings as one string, for VoiceOver and `soroband debug state`; nil for the icon alone.
    var text: String? { readings.isEmpty ? nil : readings.map(\.text).joined(separator: "  ") }

    /// The groups drawn side by side: pairs when stacked, the first on top; one reading each
    /// otherwise.
    var columns: [[Reading]] {
        guard style == .stacked else { return readings.map { [$0] } }
        return stride(from: 0, to: readings.count, by: 2).map {
            Array(readings[$0..<min($0 + 2, readings.count)])
        }
    }

    /// Whether the item's title can show the readings, on one line at the menu bar's size, so no
    /// image of them is drawn. A speed is drawn, to keep its widest value's width.
    var drawsTitle: Bool {
        readings.allSatisfy { $0.widestValue == nil }
            && (style == .inline || (style == .stacked && readings.count == 1))
    }

    /// - Today's totals are what crossed the interfaces, the network's true count.
    /// - The icon is the current network's kind; usage booked to no network shows a plain one.
    /// - An engine that stopped says so instead of showing a count that no longer grows.
    /// - Before the first poll there is no count to show yet.
    static func make(layout: MenuBarLayout, status: EngineStatus, kind: NetworkKind?) -> MenuBarDisplay {
        let symbol = kind?.symbol ?? unknownNetworkSymbol
        if status.state == .failed {
            return MenuBarDisplay(
                symbol: "exclamationmark.triangle", style: .inline,
                readings: layout.readings.isEmpty ? [] : [Reading(value: "Not counting", text: "Not counting")])
        }
        if status.state == .starting { return MenuBarDisplay(symbol: symbol, style: layout.style, readings: []) }
        let today = layout.today(in: status)
        return MenuBarDisplay(
            symbol: symbol, style: layout.style,
            readings: layout.readings.map {
                Reading(
                    caption: $0.caption, value: $0.value(today: today, speed: status.speed),
                    text: $0.text(today: today, speed: status.speed), widestValue: $0.isSpeed ? widestSpeed : nil)
            })
    }

    /// Every change of the readings redraws the status item on each display (about 18 ms of the
    /// main thread with four), so a total that only grew waits until `totalRedrawInterval` has
    /// passed since the last redraw. Anything else (another network, even of the same kind, the
    /// layout, a stopped engine, the live speed, a total that went down at the reset hour) shows at
    /// once.
    static let totalRedrawInterval: TimeInterval = 60

    /// The bytes the readings count, summed; nil when one shows the live speed or none counts.
    /// Each counted part only grows during a day, so the sum grows whenever any shown part does.
    static func total(layout: MenuBarLayout, status: EngineStatus) -> UInt64? {
        guard !layout.showsSpeed, layout.showsUsage else { return nil }
        let today = layout.today(in: status)
        return layout.readings.compactMap { $0.counted(today) }.reduce(0, +)
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
            old.display.symbol == new.display.symbol, !old.display.readings.isEmpty,
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

    /// The menu bar's own font, digits of one width so a changing count does not shift the bar.
    @MainActor static var fullFont: NSFont {
        .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    }
    /// The font of a stacked pair: two lines fit the menu bar's height.
    @MainActor static var stackedFont: NSFont { .monospacedDigitSystemFont(ofSize: 9.5, weight: .medium) }
    @MainActor static var captionFont: NSFont { .systemFont(ofSize: 6.5, weight: .bold) }
    @MainActor static var labeledFont: NSFont { .monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold) }

    /// The menu bar's height, which the readings are drawn to fit.
    static let height: CGFloat = 22

    /// The readings as one image, `height` high, columns 7 pt apart. A template image takes the
    /// menu bar's text color; `color` draws it in a fixed one instead (a Debug build, whose item is
    /// not a template).
    @MainActor func readingsImage(color: NSColor? = nil) -> NSImage {
        let ink = color ?? .black
        let string = { (text: String, font: NSFont, kern: CGFloat) in
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: ink, .kern: kern])
        }
        // The width of `text`, or of `widest` when that is wider.
        let fitted = { (text: String, widest: String, font: NSFont) in
            ceil(max(string(text, font, 0).size().width, string(widest, font, 0).size().width))
        }
        let height = Self.height
        // Each column's width, and how to draw it from a left edge. Text narrower than its column
        // is right-aligned, so digits stay in place as a number shrinks.
        var parts: [(width: CGFloat, draw: (CGFloat) -> Void)] = []
        let full = { (text: String, widest: String) in
            let line = string(text, Self.fullFont, 0)
            let columnWidth = fitted(text, widest, Self.fullFont)
            parts.append(
                (
                    columnWidth,
                    { x in
                        line.draw(
                            at: NSPoint(x: x + columnWidth - line.size().width, y: (height - line.size().height) / 2))
                    }
                ))
        }
        switch style {
        case .inline:
            if let text { full(text, readings.map(\.widestText).joined(separator: "  ")) }
        case .stacked:
            for column in columns {
                guard column.count == 2 else {
                    full(column[0].text, column[0].widestText)
                    continue
                }
                let lines = column.map { string($0.text, Self.stackedFont, 0) }
                let width = column.map { fitted($0.text, $0.widestText, Self.stackedFont) }.max() ?? 0
                let lineHeight: CGFloat = 10.5
                parts.append(
                    (
                        width,
                        { x in
                            let top = (height - lineHeight * 2) / 2
                            for (index, line) in lines.enumerated() {
                                // Each line's box is taller than its digits; draw it up by the difference.
                                let y = top + lineHeight * CGFloat(index) - 1
                                line.draw(at: NSPoint(x: x + width - line.size().width, y: y))
                            }
                        }
                    ))
            }
        case .labeled:
            for reading in readings {
                let caption = string(reading.caption, Self.captionFont, 0.5)
                let value = string(reading.value, Self.labeledFont, 0)
                let width = max(
                    ceil(caption.size().width),
                    fitted(reading.value, reading.widestValue ?? reading.value, Self.labeledFont))
                parts.append(
                    (
                        width,
                        { x in
                            caption.draw(at: NSPoint(x: x + (width - caption.size().width) / 2, y: 1.5))
                            value.draw(at: NSPoint(x: x + (width - value.size().width) / 2, y: 7.5))
                        }
                    ))
            }
        }
        let gap: CGFloat = 7
        let width = parts.map(\.width).reduce(0, +) + gap * CGFloat(max(parts.count - 1, 0))
        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            var x: CGFloat = 0
            for part in parts {
                part.draw(x)
                x += part.width + gap
            }
            return true
        }
        image.isTemplate = color == nil
        return image
    }

    /// The icon and the readings as the one image the status item draws when its title cannot
    /// show them (`drawsTitle`), and Settings' preview always. `textColor` is the menu bar's text
    /// color for a Debug build, whose image is not a template.
    @MainActor func itemImage(debug: Bool = isDebugBuild, textColor: NSColor = .labelColor) -> NSImage? {
        guard let icon = image(debug: debug) else { return nil }
        guard !readings.isEmpty else { return icon }
        let text = readingsImage(color: debug ? textColor : nil)
        let gap: CGFloat = 4
        let size = NSSize(width: icon.size.width + gap + text.size.width, height: text.size.height)
        let composite = NSImage(size: size, flipped: false) { _ in
            icon.draw(
                in: NSRect(
                    x: 0, y: (size.height - icon.size.height) / 2, width: icon.size.width, height: icon.size.height))
            text.draw(in: NSRect(x: icon.size.width + gap, y: 0, width: text.size.width, height: text.size.height))
            return true
        }
        composite.isTemplate = !debug
        return composite
    }

    /// `image` drawn once into a bitmap at `scale`. The menu bar draws its item again for every
    /// display, and an image with a drawing handler lays its text out again each time; a bitmap
    /// is only copied.
    @MainActor static func rasterized(_ image: NSImage, scale: CGFloat) -> NSImage {
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int((image.size.width * scale).rounded(.up)),
                pixelsHigh: Int((image.size.height * scale).rounded(.up)), bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return image }
        bitmap.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        let rasterized = NSImage(size: image.size)
        rasterized.addRepresentation(bitmap)
        rasterized.isTemplate = image.isTemplate
        return rasterized
    }

    /// Read by VoiceOver.
    func accessibilityLabel(debug: Bool = isDebugBuild) -> String {
        [debug ? "Soroband Debug" : "Soroband", text].compactMap { $0 }.joined(separator: ", ")
    }
}
