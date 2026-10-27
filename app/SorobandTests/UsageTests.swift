import Foundation
import Testing
@testable import Soroband

@MainActor
struct UsageTests {
    /// An engine that stops before its first poll, such as one whose database cannot be opened,
    /// never calls back; the menu bar must still learn its state when the app starts.
    @Test func startReadsTheEnginesStatusWithoutWaitingForAPoll() async throws {
        // The test host's engine has polled by now, so its status is no longer the empty one.
        Core.startEngine(interval: 1)
        let deadline = Date.now.addingTimeInterval(15)
        while Core.engine.state == .starting, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        let usage = Usage()
        #expect(usage.status.state == .starting)
        usage.start()
        #expect(usage.status.state == Core.engine.state)
        #expect(usage.status.state != .starting)
    }
}
