import SwiftUI
import Testing
@testable import Soroband

/// Views rendered with fixed data. Each baseline in `tests/snapshots/` was checked by eye.
@MainActor
@Suite(.serialized)
struct SnapshotTests {
    @Test func menuBarLabel() throws {
        // A fixed string, so the baseline does not change with the core's version.
        let label = MenuBarLabel(text: "Soroband 9.9.9")
            .font(.system(size: 13))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Color(white: 0.15))
            .environment(\.colorScheme, .dark)
        try Snapshot.verify(label, named: "menu-bar-label")
    }

    @Test func comparisonFindsAChangedPixel() throws {
        // Guards the comparison itself: without it, every snapshot test would pass.
        let one = try #require(ImageRenderer(content: Color.black.frame(width: 4, height: 4)).cgImage)
        let other = try #require(
            ImageRenderer(content: ZStack(alignment: .topLeading) {
                Color.black
                Color.white.frame(width: 1, height: 1)
            }.frame(width: 4, height: 4)).cgImage)
        #expect(Snapshot.changedPixels(one, one) == 0)
        #expect(Snapshot.changedPixels(one, other) == 1)
    }
}
