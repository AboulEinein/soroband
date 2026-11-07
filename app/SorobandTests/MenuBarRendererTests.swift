import AppKit
import Testing

@testable import Soroband

/// The menu bar item must look exactly as before `MenuBarRenderer` drew it: the same pixels as
/// `MenuBarDisplay.rasterized(itemImage)`, the image the menu bar item drew before.
@MainActor
struct MenuBarRendererTests {
    /// Every order of up to four readings, and none.
    static let readings: [[MenuBarReading]] = {
        var all: [[MenuBarReading]] = [[]]
        var last: [[MenuBarReading]] = [[]]
        for _ in 1...MenuBarLayout.maxReadings {
            last = last.flatMap { chosen in
                MenuBarReading.allCases.filter { !chosen.contains($0) }.map { chosen + [$0] }
            }
            all += last
        }
        return all
    }()

    /// Small and large values, so narrow and wide texts and every unit are drawn.
    static let statuses = [
        EngineStatus(
            networkID: 1, todayNetworkInterfaces: ByteCounts(rx: 893_600_000, tx: 206_400_000),
            todayInterfaces: ByteCounts(rx: 2_370_000_000, tx: 500_000_000), speed: ByteCounts(rx: 137_000, tx: 42_000)),
        EngineStatus(
            networkID: 2, todayNetworkInterfaces: ByteCounts(rx: 0, tx: 999_000),
            todayInterfaces: ByteCounts(rx: 48_100_000_000, tx: 7_000_000), speed: ByteCounts(rx: 0, tx: 912_400_000)),
    ]

    /// The pixels of `image`'s bitmap.
    func pixels(_ image: NSImage?) throws -> (width: Int, height: Int, bytes: Data) {
        let bitmap = try #require(image?.representations.first as? NSBitmapImageRep)
        let data = try #require(bitmap.bitmapData)
        return (bitmap.pixelsWide, bitmap.pixelsHigh, Data(bytes: data, count: bitmap.bytesPerRow * bitmap.pixelsHigh))
    }

    /// The menu bar's text color in `appearance`, as `MenuBarController` resolves it.
    func textColor(in appearance: NSAppearance) -> NSColor {
        var color = NSColor.labelColor
        appearance.performAsCurrentDrawingAppearance {
            color = NSColor(cgColor: NSColor.labelColor.cgColor) ?? .labelColor
        }
        return color
    }

    /// Compares the renderer's image of `display` with `rasterized(itemImage)`; true when equal.
    func compare(
        _ display: MenuBarDisplay, renderer: MenuBarRenderer, appearance: NSAppearance, debug: Bool, scale: CGFloat
    ) throws -> Bool {
        let color = textColor(in: appearance)
        var expected: NSImage?
        var drawn: NSImage?
        appearance.performAsCurrentDrawingAppearance {
            expected = display.itemImage(debug: debug, textColor: color).map {
                MenuBarDisplay.rasterized($0, scale: scale)
            }
            drawn = renderer.image(display, debug: debug, textColor: color, scale: scale)
        }
        let label =
            "\(appearance.name.rawValue) debug \(debug) @\(scale)x \(display.icon) \(display.style) \(display.text ?? "icon")"
        let want = try pixels(expected)
        let got = try pixels(drawn)
        #expect(got.width == want.width && got.height == want.height, "\(label)")
        #expect(got.bytes == want.bytes, "\(label)")
        #expect(drawn?.size == expected?.size, "\(label)")
        #expect(drawn?.isTemplate == expected?.isTemplate, "\(label)")
        return got.bytes == want.bytes
    }

    static let appearances = [NSAppearance(named: .aqua)!, NSAppearance(named: .darkAqua)!]

    /// Every order of readings in every style and scope, light and dark, installed and Debug
    /// (orange); one renderer throughout, so its kept icons are drawn in each appearance.
    @Test func drawsTheSamePixelsAsTheRasterizedItemImageForEveryLayout() async throws {
        let renderer = MenuBarRenderer()
        var compared = 0
        for appearance in Self.appearances {
            for debug in [false, true] {
                for status in Self.statuses {
                    for style in MenuBarStyle.allCases {
                        for scope in MenuBarScope.allCases {
                            for readings in Self.readings {
                                let display = MenuBarDisplay.make(
                                    layout: MenuBarLayout(scope: scope, readings: readings, style: style),
                                    status: status, kind: .wifi)
                                guard !display.drawsTitle else { continue }
                                compared += 1
                                // Other tests wait on the main actor too.
                                await Task.yield()
                                guard
                                    try compare(
                                        display, renderer: renderer, appearance: appearance, debug: debug, scale: 2)
                                else { return }
                            }
                        }
                    }
                }
            }
        }
        // Of 206 orders of readings, 3 styles and 2 scopes, all but the 19 a title shows (one
        // usage reading stacked, only usage readings inline, or none inline), in 8 combinations.
        #expect(compared == (206 * 3 * 2 - 19 * 2) * 2 * 2 * 2)
    }

    /// Each network's icon and the Soroband glyph, the icon alone (before the first poll too), and
    /// a 1x display; one renderer throughout, so an icon it kept for one must not stand in for
    /// another.
    @Test func drawsTheSamePixelsForEveryIconAndScale() throws {
        let renderer = MenuBarRenderer()
        for appearance in Self.appearances {
            for debug in [false, true] {
                for scale in [CGFloat(1), 2] {
                    for (icon, kind) in [
                        (MenuBarIcon.network, NetworkKind.wifi), (.soroband, .wifi), (.network, .ethernet),
                        (.network, .hotspot), (.soroband, nil), (.network, nil),
                    ] {
                        for style in MenuBarStyle.allCases {
                            for (readings, status) in [
                                ([MenuBarReading.total, .speedDown], Self.statuses[0]), ([], Self.statuses[0]),
                                ([.total], EngineStatus(state: .starting)),
                            ] {
                                let display = MenuBarDisplay.make(
                                    layout: MenuBarLayout(readings: readings, style: style, icon: icon), status: status,
                                    kind: kind)
                                guard !display.drawsTitle else { continue }
                                guard
                                    try compare(
                                        display, renderer: renderer, appearance: appearance, debug: debug, scale: scale)
                                else { return }
                            }
                        }
                    }
                }
            }
        }
    }
}
