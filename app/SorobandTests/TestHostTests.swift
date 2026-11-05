import Foundation
import Testing

@testable import Soroband

/// `xcodebuild test` runs the tests in the Debug app as their test host, whose engine books
/// traffic and whose tests write settings: none of it may reach the running Debug app's data.
struct TestHostTests {
    @Test func theTestHostKeepsItsDataOutOfTheDebugAppsDirectory() {
        let debugApp = URL.applicationSupportDirectory.appending(path: "Soroband Debug", directoryHint: .isDirectory)
        #expect(Core.dataDirectory.standardizedFileURL.path != debugApp.standardizedFileURL.path)
    }

    /// A UI process the test host starts inherits its environment, and `SettingsListener` names
    /// its notification after `SOROBAND_DATA_DIR`, so both must find the directory there.
    @Test func theTestHostsDataDirectoryIsInItsEnvironment() throws {
        let dir = try #require(ProcessInfo.processInfo.environment["SOROBAND_DATA_DIR"])
        #expect(
            URL(filePath: dir, directoryHint: .isDirectory).standardizedFileURL
                == Core.dataDirectory.standardizedFileURL)
    }
}
