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

    /// "1.37 GB" as its number and its unit, for drawing them in two sizes.
    static func numberAndUnit(_ bytes: UInt64) -> (number: String, unit: String) {
        let text = self.bytes(bytes)
        guard let space = text.lastIndex(of: " ") else { return (text, "") }
        return (String(text[..<space]), String(text[text.index(after: space)...]))
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

    /// A live speed for the menu bar: whole KB/s below 1 MB/s, tenths of a MB/s below 10 MB/s,
    /// whole MB/s above, rounded down. Idle traffic of a few hundred bytes a second reads "0 KB/s"
    /// and leaves the text, and so the status item, unchanged.
    static func menuBarSpeed(_ bytesPerSecond: UInt64) -> String {
        if bytesPerSecond < 1_000_000 { return "\(bytesPerSecond / 1000) KB/s" }
        if bytesPerSecond < 10_000_000 {
            let tenths = Double(bytesPerSecond / 100_000) / 10
            return "\(tenths.formatted(.number.precision(.fractionLength(1)))) MB/s"
        }
        return "\(bytesPerSecond / 1_000_000) MB/s"
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
