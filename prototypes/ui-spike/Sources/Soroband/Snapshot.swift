import SwiftUI

/// Spike-only: with SOROBAND_SNAPSHOT=<file> set, opens the popover, history, settings and island moments as plain
/// windows and writes "name windowNumber" lines to <file> so `screencapture -l` can grab each one.
@MainActor
enum Snapshot {
    static func showIfRequested(store: UsageStore, island: IslandModel) {
        guard let file = ProcessInfo.processInfo.environment["SOROBAND_SNAPSHOT"] else { return }
        DispatchQueue.main.async {
            let windows = [
                ("popover", show(PopoverView().environment(store).environment(island), size: nil, at: CGPoint(x: 40, y: 200), titled: false)),
                ("history", show(HistoryView().environment(store), size: CGSize(width: 1100, height: 900), at: CGPoint(x: 440, y: 60), titled: true)),
                ("history-expanded", show(HistoryView(expandedApp: "org.example.huddle", hoverDate: .now.addingTimeInterval(-9 * 86_400)).environment(store), size: CGSize(width: 1100, height: 1000), at: CGPoint(x: 600, y: 0), titled: true)),
                ("settings", show(SettingsView().environment(store).environment(island), size: CGSize(width: 560, height: 380), at: CGPoint(x: 40, y: 900), titled: true)),
                ("settings-island", show(SettingsView(tab: "island").environment(store).environment(island), size: CGSize(width: 560, height: 640), at: CGPoint(x: 80, y: 300), titled: true)),
                ("island-moments", show(momentGallery(), size: CGSize(width: 1000, height: 12 * 170), at: CGPoint(x: 300, y: 0), titled: false)),
            ]
            let lines = windows.map { "\($0.0) \($0.1.windowNumber)" }.joined(separator: "\n")
            try? lines.write(toFile: file, atomically: true, encoding: .utf8)
        }
    }

    /// Every moment pinned over a mock menu bar, so overlap with menu bar items is visible.
    private static func momentGallery() -> some View {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main!
        let geometry = IslandGeometry(screen: screen).hasNotch ? IslandGeometry(screen: screen) : IslandGeometry(notchWidth: 200, menuBarHeight: 37)
        let home = UsageStore()
        let hotspot = UsageStore()
        hotspot.simulateJoin("iphone")

        func scene(_ caption: String, store: UsageStore, moment: Moment?, seamless: Bool = true) -> some View {
            let model = IslandModel()
            model.seamless = seamless
            if let moment { model.pin(moment) }
            return IslandScene(caption: caption, geometry: geometry).environment(model).environment(store)
        }

        let transfer = { (done: Bool) in
            Moment(kind: .bigTransfer, content: .transfer(appID: "com.apple.dt.Xcode", via: "App Store",
                                                          bytes: done ? 3_210_000_000 : 1_240_000_000, rate: 41_000_000, done: done))
        }
        return VStack(spacing: 0) {
            scene("At rest: just the notch", store: home, moment: nil)
            scene("Peek on hover", store: home, moment: MomentSimulator.moment(.notchPeek, store: home))
            scene("Network joined", store: home, moment: MomentSimulator.moment(.networkJoined, store: home))
            scene("Network left (session receipt)", store: home, moment: MomentSimulator.moment(.networkLeft, store: home))
            scene("Hotspot meter (stays while on hotspot)", store: hotspot, moment: nil)
            scene("Data hog alert on hotspot", store: hotspot, moment: MomentSimulator.moment(.dataHog, store: hotspot))
            scene("Background activity", store: home, moment: MomentSimulator.moment(.backgroundActivity, store: home))
            scene("Large transfer, in progress", store: home, moment: transfer(false))
            scene("Large transfer, finished", store: home, moment: transfer(true))
            scene("Daily recap", store: home, moment: MomentSimulator.moment(.dailyRecap, store: home))
            scene("Keep menu bar clear style: data hog", store: hotspot, moment: MomentSimulator.moment(.dataHog, store: hotspot), seamless: false)
            scene("Keep menu bar clear style: hotspot meter", store: hotspot, moment: nil, seamless: false)
        }
    }

    private static func show(_ view: some View, size: CGSize?, at origin: CGPoint, titled: Bool) -> NSWindow {
        let host = NSHostingView(rootView: view)
        let frame = CGRect(origin: origin, size: size ?? host.fittingSize)
        let window = NSWindow(
            contentRect: frame,
            styleMask: titled ? [.titled, .closable, .resizable] : [.borderless],
            backing: .buffered, defer: false)
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }
}

private struct IslandScene: View {
    @Environment(UsageStore.self) private var store
    let caption: String
    let geometry: IslandGeometry

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.16, green: 0.3, blue: 0.24), Color(red: 0.06, green: 0.13, blue: 0.13)],
                           startPoint: .top, endPoint: .bottom)
            menuBar
            IslandView(geometry: geometry)
            Text(caption)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.75))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(12)
        }
        .frame(height: 170)
        .clipped()
        .overlay(alignment: .bottom) { Rectangle().fill(.black.opacity(0.4)).frame(height: 1) }
    }

    private var menuBar: some View {
        HStack(spacing: 18) {
            Image(systemName: "apple.logo")
            Text("Safari").fontWeight(.bold)
            ForEach(["File", "Edit", "View", "History"], id: \.self) { Text($0) }
            Spacer()
            Label(store.menuBarText, systemImage: store.currentNetwork.kind.symbol)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.white.opacity(0.18), in: .rect(cornerRadius: 5))
            Image(systemName: "battery.75percent")
            Image(systemName: "wifi")
            Image(systemName: "switch.2")
            Text("Mon 26 Oct 22:14")
        }
        .font(.system(size: 13))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: geometry.menuBarHeight)
        .background(.black.opacity(0.22))
    }
}
