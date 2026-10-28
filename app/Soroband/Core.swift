internal import SorobandCore

/// The Rust core, through its C API.
enum Core {
    static var version: String { String(cString: soroband_core_version()) }
}
