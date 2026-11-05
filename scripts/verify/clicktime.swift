// Clicks the real pointer at a point and prints the milliseconds until the popover is on screen,
// or "timeout" after 3 s. Needs Accessibility permission for the app running it.
//
// Usage: swiftc -O scripts/verify/clicktime.swift -o /tmp/clicktime
//        /tmp/clicktime <x> <y> <pid>
//   x, y: the menu bar item's centre in global points (`Item-0` in `soroband debug state`)
//   pid:  a window wider than 300 pt owned by this pid counts as the popover. A negative pid -N
//         counts any 386 pt wide window (the popover's) of a process named Soroband other than N,
//         which times a cold open, when the UI process does not exist yet.
import CoreGraphics
import Foundation

let args = CommandLine.arguments
let point = CGPoint(x: Double(args[1])!, y: Double(args[2])!)
let pid = Int(args[3])!

func width(_ window: [String: Any]) -> Double {
    (window[kCGWindowBounds as String] as? [String: Double])?["Width"] ?? 0
}

func popoverIsUp() -> Bool {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
    return windows.contains { window in
        let owner = window[kCGWindowOwnerPID as String] as? Int
        let matches = pid < 0
            ? owner != -pid && window[kCGWindowOwnerName as String] as? String == "Soroband" && width(window) == 386
            : owner == pid
        return matches && width(window) > 300
    }
}

let source = CGEventSource(stateID: .hidSystemState)
func post(_ type: CGEventType) {
    CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!
        .post(tap: .cghidEventTap)
}

post(.mouseMoved)
usleep(50_000)
let start = DispatchTime.now().uptimeNanoseconds
post(.leftMouseDown)
post(.leftMouseUp)
while DispatchTime.now().uptimeNanoseconds - start < 3_000_000_000 {
    if popoverIsUp() {
        print(String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6))
        exit(0)
    }
    usleep(2_000)
}
print("timeout")
