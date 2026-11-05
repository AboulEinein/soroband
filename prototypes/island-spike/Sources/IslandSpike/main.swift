import AppKit
import Darwin
import SwiftUI

/// Measures what the island costs the process that shows it. An AppKit agent with a status item, as
/// the menu bar process is, shows every moment `cycles` times on the built-in display's notch, then
/// rests, and prints one JSON line: the footprint at launch, at the peak, after the moments, after the
/// rest, and the CPU time of the moments and of the rest.
///
/// Usage: IslandSpike <none|appkit|swiftui> [cycles] [rest seconds] [--capture <dir>] [--record <mov>]
/// `none` makes the status item and no island. The panel ignores the pointer, so the user's clicks
/// pass through it.

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

func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
    return s(usage.ru_utime) + s(usage.ru_stime)
}

let arguments = CommandLine.arguments
let mode = arguments.count > 1 ? arguments[1] : "none"
let cycles = arguments.count > 2 ? Int(arguments[2]) ?? 5 : 5
let rest = arguments.count > 3 ? Double(arguments[3]) ?? 60 : 60
let captureDir = arguments.firstIndex(of: "--capture").map { arguments[$0 + 1] }
let recordPath = arguments.firstIndex(of: "--record").map { arguments[$0 + 1] }

@MainActor
final class Driver: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var panel: NSPanel?
    private var show: ((Content?) -> Void)?
    private var result: [String: Double] = [:]
    private var screen: NSScreen!

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button!.title = "IS"
        screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main!
        if mode != "none" { makePanel() }
        Task { await run() }
    }

    private func makePanel() {
        let geometry = IslandGeometry(screen: screen)
        let size = CGSize(width: 560, height: geometry.menuBarHeight + 200)
        let frame = CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        switch mode {
        case "swiftui":
            let model = SwiftUIIslandModel()
            panel.contentView = NSHostingView(rootView: SwiftUIIsland(model: model, geometry: geometry))
            show = { content in
                model.current = content
                model.id += 1
            }
        case "appkit":
            let view = AppKitIslandView(frame: CGRect(origin: .zero, size: size), geometry: geometry)
            panel.contentView = view
            show = { view.show($0) }
        default: fatalError("unknown mode \(mode)")
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    private func run() async {
        await pause(3)
        result["launch"] = footprintMB()
        let cpuStart = cpuSeconds()
        var peak = 0.0
        let recording = recordPath.flatMap { screencapture(["-v", "-V", "\(cycles * 16 + 3)", $0]) }
        if recording != nil { await pause(1.5) }
        if let show {
            for cycle in 0..<cycles {
                for content in Content.allCases {
                    show(content)
                    await pause(1.2)
                    peak = max(peak, footprintMB())
                    if cycle == 0, let captureDir { capture("\(captureDir)/\(mode)-\(content).png") }
                    await pause(0.6)
                    show(nil)
                    await pause(0.7)
                }
            }
        }
        recording?.waitUntilExit()
        result["peak"] = peak
        result["momentsCPU"] = cpuSeconds() - cpuStart
        await pause(5)
        result["after"] = footprintMB()
        let restStart = cpuSeconds()
        await pause(rest)
        result["restCPUPercent"] = (cpuSeconds() - restStart) / rest * 100
        result["rest"] = footprintMB()
        let fields = result.keys.sorted().map { "\"\($0)\":\((result[$0]! * 1000).rounded() / 1000)" }
        print("{\"mode\":\"\(mode)\",\"cycles\":\(cycles),\(fields.joined(separator: ","))}")
        exit(0)
    }

    private func capture(_ path: String) {
        screencapture([path])?.waitUntilExit()
    }

    /// `screencapture` of the panel's rect, started.
    private func screencapture(_ arguments: [String]) -> Process? {
        guard let panel else { return nil }
        let main = NSScreen.screens[0].frame
        let f = panel.frame
        let rect = "\(Int(f.minX)),\(Int(main.maxY - f.maxY)),\(Int(f.width)),\(Int(f.height))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-R", rect] + arguments
        try? process.run()
        return process
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let driver = MainActor.assumeIsolated { Driver() }
app.delegate = driver
app.run()
