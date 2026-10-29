import AppKit
import Darwin
import SwiftUI

/// Opens and closes option C's popover `cycles` times in one framework and prints the process's
/// memory footprint (what `footprint` and Activity Monitor report) at each stage, as JSON.
///
/// Usage: PopoverSpike <swiftui|swiftui-charts|appkit|empty> [cycles] [--snapshot <png>]
/// The popover hangs off a window far off screen, so nothing shows over the user's work.

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

let arguments = CommandLine.arguments
let mode = arguments.count > 1 ? arguments[1] : "swiftui"
let cycles = arguments.count > 2 ? Int(arguments[2]) ?? 20 : 20
let snapshotPath = arguments.firstIndex(of: "--snapshot").map { arguments[$0 + 1] }

@MainActor
func makeContent() -> NSViewController {
    switch mode {
    case "swiftui":
        NSHostingController(rootView: SwiftUIPopover(charts: false).environment(\.colorScheme, .dark))
    case "swiftui-charts":
        NSHostingController(rootView: SwiftUIPopover(charts: true).environment(\.colorScheme, .dark))
    case "appkit": AppKitPopover()
    case "empty":
        {
            let controller = NSViewController()
            controller.view = NSView(frame: CGRect(x: 0, y: 0, width: 360, height: 600))
            return controller
        }()
    default: fatalError("unknown mode \(mode)")
    }
}

@MainActor
final class Driver: NSObject, NSApplicationDelegate {
    private var anchor: NSWindow!
    private var popover: NSPopover?
    private var stages: [String: Double] = [:]
    private var peakOpen = 0.0
    private var openShown = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The popover is drawn dark, as on the user's Mac; layer colors resolve at creation.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        anchor = NSWindow(
            contentRect: CGRect(x: -6000, y: -6000, width: 20, height: 20), styleMask: .borderless, backing: .buffered,
            defer: false)
        anchor.orderFrontRegardless()
        if let snapshotPath {
            snapshot(to: snapshotPath)
            return
        }
        after(1.0) {
            self.stages["launch"] = footprintMB()
            self.cycle(1) {
                self.after(1.0) {
                    self.stages["after_1"] = footprintMB()
                    self.cycle(cycles - 1) {
                        self.after(3.0) {
                            self.stages["after_\(cycles)"] = footprintMB()
                            malloc_zone_pressure_relief(nil, 0)
                            self.after(1.0) {
                                self.stages["after_\(cycles)_relief"] = footprintMB()
                                self.stages["peak_open"] = self.peakOpen
                                self.report()
                            }
                        }
                    }
                }
            }
        }
    }

    private func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { work() } }
    }

    /// Opens a new popover with fresh content, as the app does, lets it draw, then closes and drops it.
    private func cycle(_ remaining: Int, then done: @escaping @MainActor () -> Void) {
        guard remaining > 0 else { return done() }
        autoreleasepool {
            let popover = NSPopover()
            popover.behavior = .applicationDefined
            popover.animates = false
            popover.contentViewController = makeContent()
            popover.show(relativeTo: anchor.contentView!.bounds, of: anchor.contentView!, preferredEdge: .minY)
            if popover.isShown { openShown += 1 }
            self.popover = popover
        }
        after(0.6) {
            self.peakOpen = max(self.peakOpen, footprintMB())
            autoreleasepool {
                self.popover?.close()
                self.popover?.contentViewController = nil
                self.popover = nil
            }
            self.after(0.3) { self.cycle(remaining - 1, then: done) }
        }
    }

    private func report() {
        let result: [String: Any] = [
            "mode": mode, "cycles": cycles, "shown": openShown,
            "mb": stages.mapValues { ($0 * 10).rounded() / 10 },
        ]
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(data: data, encoding: .utf8)!)
        exit(0)
    }

    /// Renders the content in a plain window and writes it as a PNG, to compare the two looks.
    private func snapshot(to path: String) {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 360, height: 600), styleMask: .borderless, backing: .buffered,
            defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.16, alpha: 1)
        var controller: NSViewController!
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { controller = makeContent() }
        window.contentViewController = controller
        window.setContentSize(controller.view.fittingSize)
        window.setFrameOrigin(CGPoint(x: -6000, y: -6000))
        window.orderFrontRegardless()
        after(1.0) {
            let view = window.contentView!
            view.layoutSubtreeIfNeeded()
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: rep)
            try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
            exit(0)
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let driver = Driver()
    app.delegate = driver
    app.run()
}
