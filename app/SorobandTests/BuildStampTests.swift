import Foundation
import Testing

@testable import Soroband

/// The user tells which build runs by comparing Settings › About with `git rev-parse --short origin/main`,
/// so the app must carry the commit it was built from.
struct BuildStampTests {
    @Test func theAppIsStampedWithTheCommitItWasBuiltFrom() throws {
        let info = try #require(Bundle.main.infoDictionary)
        // The checkout can turn dirty between the build and the test, so the suffix is left out
        // here; soroband-cli's tests check it on fixtures of the same script.
        let commit = (info["SorobandCommit"] as? String)?.replacingOccurrences(of: "-dirty", with: "")
        #expect(commit == (try git("rev-parse", "--short", "HEAD")))
        #expect(info["SorobandBranch"] as? String == (try git("branch", "--show-current")))
        // The build number is the commit count, or 0 in a shallow clone, which cannot count them.
        let shallow = try git("rev-parse", "--is-shallow-repository") == "true"
        let count = shallow ? "0" : try git("rev-list", "--count", "HEAD")
        #expect(info["CFBundleVersion"] as? String == count)
    }

    @Test func aboutShowsTheVersionBuildAndStamp() {
        let info: [String: Any] = [
            "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "412",
            "SorobandCommit": "16e85ce-dirty", "SorobandBranch": "main",
        ]
        #expect(AboutSettings.versionLine(info) == "Version 0.1.0 (412) · 16e85ce-dirty main")
        var detached = info
        detached["SorobandBranch"] = ""
        #expect(AboutSettings.versionLine(detached) == "Version 0.1.0 (412) · 16e85ce-dirty")
        #expect(
            AboutSettings.versionLine(["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"])
                == "Version 0.1.0 (1) · unknown")
    }

    private func git(_ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", RepositoryFiles.root.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "git \(arguments) exited \(process.terminationStatus)")
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
