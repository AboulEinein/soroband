import AppKit

/// Draws the menu bar item's image when its title cannot show the readings (`drawsTitle`): the
/// pixels of `MenuBarDisplay.rasterized(itemImage)`, the image the menu bar item drew before, at
/// less cost for a live speed redrawn at every poll. The icon is made once per symbol or glyph, and the
/// icon and the readings are drawn once, straight into the bitmap, instead of through two images
/// with drawing handlers drawn again into it.
@MainActor
final class MenuBarRenderer {
    private struct IconKey: Hashable {
        var icon: MenuBarDisplay.Icon
        var debug: Bool
    }
    private var icons: [IconKey: NSImage] = [:]

    /// The item's image for `display` at `scale`, a template unless `debug`. `textColor` is the
    /// menu bar's text color for a Debug build, whose image is not a template.
    func image(
        _ display: MenuBarDisplay, debug: Bool = MenuBarDisplay.isDebugBuild, textColor: NSColor, scale: CGFloat
    ) -> NSImage? {
        guard let icon = icon(display, debug: debug) else { return nil }
        let columns = display.readingColumns(ink: debug ? textColor : .black)
        let readingsWidth = MenuBarDisplay.width(of: columns)
        let size =
            display.readings.isEmpty
            ? icon.size
            : NSSize(width: icon.size.width + MenuBarDisplay.iconGap + readingsWidth, height: MenuBarDisplay.height)
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded(.up)),
                pixelsHigh: Int((size.height * scale).rounded(.up)), bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return nil }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        icon.draw(
            in: NSRect(x: 0, y: (size.height - icon.size.height) / 2, width: icon.size.width, height: icon.size.height))
        if !columns.isEmpty {
            // The readings are laid out top down, as `readingsImage` draws them.
            let cg = context.cgContext
            cg.saveGState()
            cg.translateBy(x: icon.size.width + MenuBarDisplay.iconGap, y: size.height)
            cg.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
            MenuBarDisplay.draw(columns)
            cg.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        image.isTemplate = !debug
        return image
    }

    /// A Debug build's orange is resolved in the appearance each drawing is made in, so one icon
    /// serves light and dark.
    private func icon(_ display: MenuBarDisplay, debug: Bool) -> NSImage? {
        let key = IconKey(icon: display.icon, debug: debug)
        if let icon = icons[key] { return icon }
        let icon = display.image(debug: debug)
        icons[key] = icon
        return icon
    }
}
