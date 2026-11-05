// Clicks the real pointer at a point and prints the milliseconds until the popover is on screen,
// or "timeout" after 3 s. Needs Accessibility permission for the app running it.
//
// Usage: swiftc -O scripts/verify/clicktime.swift -o /tmp/clicktime
//        /tmp/clicktime <x> <y> <menu bar pid>
//   x, y: the menu bar item's centre in global points (`Item-0` in `soroband debug state`)
//   menu bar pid: this build's menu bar process. The popover is a 386 pt wide window owned by
//         its child, the UI process, whether that already runs (warm) or the click starts it (cold).
// Exits 1 on timeout, and 2 without clicking when the popover is already open.
import CoreGraphics
import Darwin
import Foundation

let args = CommandLine.arguments
let point = CGPoint(x: Double(args[1])!, y: Double(args[2])!)
let menuBarPID = Int32(args[3])!
let popoverWidth = 386.0

func parent(of pid: Int32) -> Int32? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return Int32(info.pbi_ppid)
}

func popoverIsUp() -> Bool {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
    return windows.contains { window in
        let width = (window[kCGWindowBounds as String] as? [String: Double])?["Width"] ?? 0
        guard width == popoverWidth, let owner = window[kCGWindowOwnerPID as String] as? Int32 else { return false }
        return parent(of: owner) == menuBarPID
    }
}

let source = CGEventSource(stateID: .hidSystemState)
func post(_ type: CGEventType) {
    CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!
        .post(tap: .cghidEventTap)
}

if popoverIsUp() {
    print("popover already open")
    exit(2)
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
exit(1)
