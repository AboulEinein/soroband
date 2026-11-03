import Foundation
import Testing

@testable import Soroband

@MainActor
struct SettingsListenerTests {
    /// A loop of `soroband config set` posts a notification every few milliseconds; each reread
    /// that wakes the engine costs a poll and a menu bar redraw.
    @Test func aBurstOfRequestsRunsOnceAndALaterOneStillRuns() async throws {
        var runs = 0
        let coalescer = Coalescer(window: .milliseconds(250)) { runs += 1 }
        for _ in 0..<100 { coalescer.request() }
        try await Task.sleep(for: .milliseconds(600))
        #expect(runs == 1)
        coalescer.request()
        try await Task.sleep(for: .milliseconds(600))
        #expect(runs == 2)
    }
}
