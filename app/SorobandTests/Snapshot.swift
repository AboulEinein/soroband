import AppKit
import SwiftUI
import Testing

/// Renders a view to PNG and compares it with its baseline in `tests/snapshots/`.
///
/// Run `scripts/verify/snapshots.sh --record` to write new baselines, then look at each one
/// before committing it.
@MainActor
enum Snapshot {
    static let baselines = RepositoryFiles.root.appending(path: "tests/snapshots")
    static let failures = FileManager.default.temporaryDirectory.appending(path: "soroband-snapshots")
    /// Channel values may differ by this much before a pixel counts as changed.
    static let channelTolerance = 2

    /// Renders `view` in dark mode at its fitting size, or at `size`, hosted in a window as the
    /// app shows it: `ImageRenderer` leaves out AppKit-backed controls such as switches and
    /// segmented pickers.
    static func verify(
        _ view: some View, named name: String, size: CGSize? = nil, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let image = try #require(render(view, size: size), "could not render \(name)", sourceLocation: sourceLocation)
        let baseline = baselines.appending(path: "\(name).png")

        if ProcessInfo.processInfo.environment["SOROBAND_RECORD_SNAPSHOTS"] == "1" {
            try FileManager.default.createDirectory(at: baselines, withIntermediateDirectories: true)
            try png(image).write(to: baseline)
            return
        }

        let expected = try #require(
            NSImage(contentsOf: baseline)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
            "no baseline at \(baseline.path); run scripts/verify/snapshots.sh --record",
            sourceLocation: sourceLocation)
        let changed = changedPixels(image, expected)
        if changed != 0 {
            try FileManager.default.createDirectory(at: failures, withIntermediateDirectories: true)
            let actual = failures.appending(path: "\(name).png")
            try png(image).write(to: actual)
            Issue.record("\(name): \(changed) pixels differ from the baseline; actual image at \(actual.path)", sourceLocation: sourceLocation)
        }
    }

    static func render(_ view: some View, size: CGSize?) -> CGImage? {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size ?? host.fittingSize),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // The first layout can change the fitting height (text that wraps), so fit once more.
        if size == nil {
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
        }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap.cgImage
    }

    /// Number of pixels that differ by more than `channelTolerance`, or every pixel when the sizes differ.
    static func changedPixels(_ a: CGImage, _ b: CGImage) -> Int {
        guard a.width == b.width, a.height == b.height else { return max(a.width * a.height, b.width * b.height) }
        let (pa, pb) = (rgba(a), rgba(b))
        var changed = 0
        for pixel in stride(from: 0, to: pa.count, by: 4) {
            if (0..<4).contains(where: { abs(Int(pa[pixel + $0]) - Int(pb[pixel + $0])) > channelTolerance }) {
                changed += 1
            }
        }
        return changed
    }

    private static func rgba(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(
            data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }

    private static func png(_ image: CGImage) throws -> Data {
        try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }
}
