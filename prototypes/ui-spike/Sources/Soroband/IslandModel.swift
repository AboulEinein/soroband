import AppKit
import SwiftUI

enum MomentKind: String, CaseIterable, Identifiable {
    case notchPeek, networkJoined, networkLeft, hotspotMeter, dataHog, backgroundActivity, bigTransfer, dailyRecap
    var id: String { rawValue }

    var title: String {
        switch self {
        case .notchPeek: "Peek on hover"
        case .networkJoined: "Network joined"
        case .networkLeft: "Network left"
        case .hotspotMeter: "Hotspot meter"
        case .dataHog: "Data hog"
        case .backgroundActivity: "Background activity"
        case .bigTransfer: "Large transfer"
        case .dailyRecap: "Daily recap"
        }
    }

    var detail: String {
        switch self {
        case .notchPeek: "Hover the notch to see today's total and top apps."
        case .networkJoined: "This network's recent usage and your last visit."
        case .networkLeft: "A receipt for the session you just ended."
        case .hotspotMeter: "A small live counter under the notch while on a hotspot."
        case .dataHog: "One app uses a lot of data in a short time."
        case .backgroundActivity: "Data moves while no app is in front."
        case .bigTransfer: "Progress of a large download or upload."
        case .dailyRecap: "A one-line summary when the daily counter resets."
        }
    }

    var symbol: String {
        switch self {
        case .notchPeek: "cursorarrow.rays"
        case .networkJoined: "arrow.down.right.circle"
        case .networkLeft: "arrow.up.left.circle"
        case .hotspotMeter: "personalhotspot"
        case .dataHog: "exclamationmark.triangle"
        case .backgroundActivity: "moon.zzz"
        case .bigTransfer: "arrow.down.circle"
        case .dailyRecap: "calendar"
        }
    }

    /// Alerts may still show in full screen and fall back to notifications when the island is off.
    var isAlert: Bool { self == .dataHog || self == .backgroundActivity }
}

enum MomentContent {
    case peek
    case joined(networkID: String)
    case left(networkID: String, since: Date)
    case hotspot
    case hog(appID: String, bytes: Int64, minutes: Int)
    case background(appID: String, bytes: Int64, uploading: Bool)
    case transfer(appID: String, via: String?, bytes: Int64, rate: Double, done: Bool)
    case recap
}

struct Moment: Identifiable {
    let id = UUID()
    let kind: MomentKind
    var content: MomentContent
    var duration: Double = 5
}

@MainActor @Observable
final class IslandModel {
    // Settings
    var enabled = true
    /// Seamless: the island covers the menu bar next to the notch while a moment is open, like other notch apps.
    /// Off: it stays notch-wide inside the menu bar and widens only below it, so no menu bar item is ever covered.
    var seamless = true
    var enabledKinds: Set<MomentKind> = Set(MomentKind.allCases).subtracting([.dailyRecap])
    var hogThresholdMB = 100
    var hogWindowMinutes = 5
    var backgroundThresholdMB = 50
    var transferThresholdMB = 50
    var offerPause = true
    var hideInFullScreen = true
    var alertsInFullScreen = true
    var allDisplays = false
    var notificationsWhenOff = true

    // State
    private(set) var current: Moment?
    var hovering = false {
        didSet { if !hovering && oldValue { scheduleDismiss() } }
    }
    private var queue: [Moment] = []
    private var dismissTask: Task<Void, Never>?

    func isOn(_ kind: MomentKind) -> Bool { enabled && enabledKinds.contains(kind) }

    func binding(for kind: MomentKind) -> Binding<Bool> {
        Binding(
            get: { self.enabledKinds.contains(kind) },
            set: { on in if on { self.enabledKinds.insert(kind) } else { self.enabledKinds.remove(kind) } })
    }

    func post(_ moment: Moment) {
        guard isOn(moment.kind) else { return }
        if current == nil { present(moment) } else { queue.append(moment) }
    }

    /// Spike/snapshot only: show a moment without timers.
    func pin(_ moment: Moment) { current = moment }

    func update(_ id: UUID, _ change: (inout MomentContent) -> Void) {
        guard current?.id == id, var moment = current else { return }
        change(&moment.content)
        current = moment
    }

    private var peekTask: Task<Void, Never>?

    /// Hovering the resting notch opens the peek after a short delay, so passing the cursor by does nothing.
    func hoverChanged(_ inside: Bool) {
        guard inside != hovering else { return }
        hovering = inside
        peekTask?.cancel()
        if inside, current == nil, isOn(.notchPeek) {
            peekTask = Task {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, self.hovering, self.current == nil else { return }
                self.present(Moment(kind: .notchPeek, content: .peek, duration: 0.4))
            }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) { current = nil }
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            self.present(next)
        }
    }

    private func present(_ moment: Moment) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { current = moment }
        scheduleDismiss()
    }

    func scheduleDismiss(after seconds: Double? = nil) {
        dismissTask?.cancel()
        guard let moment = current, !hovering else { return }
        let delay = seconds ?? moment.duration
        dismissTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, self.current?.id == moment.id, !self.hovering else { return }
            self.dismiss()
        }
    }
}

/// A transparent, click-through panel over the notch. The island grows downward from the notch,
/// below the menu bar line, so it never covers menu bar items.
@MainActor
final class IslandPanel {
    static var shared: IslandPanel?
    private let panel: NSPanel

    init(model: IslandModel, store: UsageStore) {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main!
        let geometry = IslandGeometry(screen: screen)
        let size = CGSize(width: 560, height: geometry.menuBarHeight + 200)
        let frame = CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: IslandView(geometry: geometry).environment(model).environment(store))
        panel.orderFrontRegardless()
    }
}

struct IslandGeometry {
    let notchWidth: CGFloat
    let menuBarHeight: CGFloat
    var hasNotch: Bool { notchWidth > 0 }

    init(notchWidth: CGFloat, menuBarHeight: CGFloat) {
        self.notchWidth = notchWidth
        self.menuBarHeight = menuBarHeight
    }

    init(screen: NSScreen) {
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, screen.safeAreaInsets.top > 0 {
            notchWidth = screen.frame.width - left.width - right.width
            menuBarHeight = screen.safeAreaInsets.top
        } else {
            notchWidth = 0
            menuBarHeight = NSStatusBar.system.thickness
        }
    }
}
