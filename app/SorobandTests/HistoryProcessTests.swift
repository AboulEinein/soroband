import Foundation
import Testing

@testable import Soroband

/// The menu bar app's side of the History process, with a script standing in for Soroband: in
/// standby it exits at once, as a standby process that died; with a window it runs until its
/// standard input closes.
@MainActor
struct HistoryProcessTests {
    @Test func aWindowOpenedAfterTheStandbyDiedOutlivesThePopoverClosing() async throws {
        let script = FileManager.default.temporaryDirectory.appending(path: "history-stand-in-\(UUID()).sh")
        try """
        #!/bin/sh
        case "$*" in *--standby*) exit 0 ;; esac
        exec cat >/dev/null
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let executable = HistoryProcess.executableURL
        HistoryProcess.executableURL = script
        defer {
            HistoryProcess.close()
            HistoryProcess.executableURL = executable
            try? FileManager.default.removeItem(at: script)
        }

        HistoryProcess.prepare()
        for _ in 0..<200 where HistoryProcess.processIdentifier != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(HistoryProcess.processIdentifier == nil, "the standby process exited")

        HistoryProcess.open(HistoryOptions())
        let window = try #require(HistoryProcess.processIdentifier)
        HistoryProcess.dismissStandby()
        #expect(HistoryProcess.processIdentifier == window, "closing the popover keeps the History just opened")
    }
}
