import Foundation
import Testing

/// Files in the repository, located from this source file so tests do not depend on the build directory.
enum RepositoryFiles {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // SorobandTests
        .deletingLastPathComponent()  // app
        .deletingLastPathComponent()

    /// The `version` in `[workspace.package]` of `core/Cargo.toml`.
    static func coreWorkspaceVersion() throws -> String {
        let manifest = try String(contentsOf: root.appending(path: "core/Cargo.toml"), encoding: .utf8)
        let package = try #require(manifest.components(separatedBy: "[workspace.package]").dropFirst().first)
        let line = try #require(
            package.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("version = ") })
        return line.split(separator: "\"")[1].description
    }
}
