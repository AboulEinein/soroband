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
        // The run waits out the window, so it reads the settings the burst's last post left.
        #expect(runs == 0)
        try await waitUntil { runs == 1 }
        // Long enough for a second run of the burst to show.
        try await Task.sleep(for: .milliseconds(500))
        #expect(runs == 1)
        coalescer.request()
        #expect(runs == 1)
        try await waitUntil { runs == 2 }
    }

    /// Waits for `done`, up to 10 s: the main actor the run needs is shared with other tests.
    private func waitUntil(_ done: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !done(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(done())
    }
}
