#if DEBUG
import Testing

@testable import Soroband

/// The values Debug URL commands take from an agent.
struct DebugCommandsTests {
    @Test func hoverTakesOnlyOneOrZero() {
        #expect(DebugCommands.pointerInside("1") == true)
        #expect(DebugCommands.pointerInside("0") == false)
        for refused: String? in [nil, "", "2", "-1", "01", "true", "yes", " 1"] {
            #expect(DebugCommands.pointerInside(refused) == nil, "\(String(describing: refused)) is refused")
        }
    }
}
#endif
