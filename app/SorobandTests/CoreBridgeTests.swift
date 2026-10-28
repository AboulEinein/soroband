import Foundation
import Testing

@testable import Soroband

struct CoreBridgeTests {
    @Test func bridgeReturnsTheCoreVersionFromCargoToml() throws {
        #expect(Core.version == (try RepositoryFiles.coreWorkspaceVersion()))
    }

    /// The engine reaches the kernel and finishes its first poll. On a macOS version whose
    /// descriptor layouts are not recorded yet it runs on interface totals, which still counts.
    @Test func engineConnectsToTheKernelAndPolls() async throws {
        Core.startEngine(interval: 1)
        let deadline = Date.now.addingTimeInterval(15)
        while Core.engine.state == .starting, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect([.perApp, .interfaceOnly].contains(Core.engine.state))
    }
}
