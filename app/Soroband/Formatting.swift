import Foundation

/// How byte counts read everywhere in the app: decimal units, as Finder shows file sizes
/// ("420.3 MB", "137 KB/s").
enum Format {
    static func bytes(_ bytes: UInt64) -> String {
        formatter.string(fromByteCount: Int64(clamping: bytes))
    }

    static func speed(_ bytesPerSecond: UInt64) -> String {
        "\(bytes(bytesPerSecond))/s"
    }

    /// A day's total for the menu bar: whole megabytes below 1 GB, tenths of a gigabyte above,
    /// rounded down so it never runs ahead of the popover. Every change of the text redraws the
    /// status item on each display, so it changes about once a megabyte rather than every 100 KB.
    static func menuBarBytes(_ bytes: UInt64) -> String {
        if bytes < 1_000_000 { return "< 1 MB" }
        if bytes < 1_000_000_000 { return "\(bytes / 1_000_000) MB" }
        let tenths = Double(bytes / 100_000_000) / 10
        return "\(tenths.formatted(.number.precision(.fractionLength(1)))) GB"
    }

    /// Formatters are safe to share across threads once configured, and this one is never changed.
    nonisolated(unsafe) private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        // "0 bytes", not "Zero KB".
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()
}
