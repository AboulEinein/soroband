import AppKit

/// What both renderers draw: the ui-spike's island (`prototypes/ui-spike/Sources/Soroband/IslandView.swift`),
/// its shape, sizes and springs, on fixed content.

struct IslandGeometry {
    let notchWidth: CGFloat
    let menuBarHeight: CGFloat
    var hasNotch: Bool { notchWidth > 0 }

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

enum Content: CaseIterable {
    case joined, left, peek, hog, background, transfer
}

struct Metrics: Equatable {
    var width: CGFloat
    var height: CGFloat
    var radius: CGFloat
    var bandWidth: CGFloat
}

func metrics(for content: Content?, geometry: IslandGeometry, seamless: Bool = true) -> Metrics {
    let band = geometry.menuBarHeight
    let notch = geometry.hasNotch ? geometry.notchWidth : 0
    guard let content else {
        return Metrics(width: notch, height: geometry.hasNotch ? band : 0, radius: 9, bandWidth: notch)
    }
    let (w, h): (CGFloat, CGFloat) =
        switch content {
        case .hog, .background: (470, band + 100)
        case .peek: (450, band + 104)
        default: (450, band + 66)
        }
    return Metrics(width: w, height: h, radius: 26, bandWidth: seamless ? w : notch)
}

/// `IslandShape.path(in:)` from the ui-spike, as a `CGPath` with the top edge at `rect.maxY` (flipped
/// for AppKit and Core Animation, whose y grows upward) or at `rect.minY`.
func islandPath(_ m: Metrics, band: CGFloat, in rect: CGRect, flipped: Bool) -> CGPath {
    let p = CGMutablePath()
    guard m.width > 1, m.height > 1 else { return p }
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: flipped ? rect.maxY - y : rect.minY + y) }
    let cx = rect.midX
    let left = cx - m.width / 2, right = cx + m.width / 2
    let r = min(m.radius, m.height / 2, m.width / 2)
    let ear = min(6, m.height / 3)
    let necked = m.bandWidth < m.width - 12 && m.height > band + 12 && m.bandWidth > 0
    let nl = cx - m.bandWidth / 2, nr = cx + m.bandWidth / 2
    let topLeft = necked ? nl : left, topRight = necked ? nr : right
    let f: CGFloat = 8
    p.move(to: pt(topLeft - ear, 0))
    p.addQuadCurve(to: pt(topLeft, ear), control: pt(topLeft, 0))
    if necked {
        p.addLine(to: pt(nl, band - f))
        p.addQuadCurve(to: pt(nl - f, band), control: pt(nl, band))
        p.addLine(to: pt(left + f, band))
        p.addQuadCurve(to: pt(left, band + f), control: pt(left, band))
    }
    p.addLine(to: pt(left, m.height - r))
    p.addQuadCurve(to: pt(left + r, m.height), control: pt(left, m.height))
    p.addLine(to: pt(right - r, m.height))
    p.addQuadCurve(to: pt(right, m.height - r), control: pt(right, m.height))
    if necked {
        p.addLine(to: pt(right, band + f))
        p.addQuadCurve(to: pt(right - f, band), control: pt(right, band))
        p.addLine(to: pt(nr + f, band))
        p.addQuadCurve(to: pt(nr, band - f), control: pt(nr, band))
    }
    p.addLine(to: pt(topRight, ear))
    p.addQuadCurve(to: pt(topRight + ear, 0), control: pt(topRight, 0))
    p.closeSubpath()
    return p
}

/// Fixed text and icons per moment, as the ui-spike shows them.
struct Lines {
    let title: String
    let subtitle: String
    let icon: NSImage
    let trailing: String?
    let buttons: [String]

    static func of(_ content: Content) -> Lines {
        let safari = NSWorkspace.shared.icon(forFile: "/Applications/Safari.app")
        let music = NSWorkspace.shared.icon(forFile: "/System/Applications/Music.app")
        let mail = NSWorkspace.shared.icon(forFile: "/System/Applications/Mail.app")
        let wifi = NSImage(systemSymbolName: "wifi", accessibilityDescription: nil)!
        return switch content {
        case .joined: Lines(title: "Joined Office", subtitle: "1.2 GB this week · last here yesterday", icon: wifi, trailing: "412 MB", buttons: [])
        case .left: Lines(title: "Left iPhone", subtitle: "318 MB over 1 hr 12 min", icon: wifi, trailing: "Top: Safari 120 MB", buttons: [])
        case .peek: Lines(title: "Office · today 1.4 GB", subtitle: "↓ 1.2 GB  ↑ 210 MB  ·  now ↓ 1.2 MB/s", icon: music, trailing: nil, buttons: [])
        case .hog: Lines(title: "Music used 214 MB in 5 min", subtitle: "on iPhone (Hotspot)", icon: music, trailing: "⚠︎", buttons: ["Pause until off hotspot", "Ignore Music", "Details"])
        case .background: Lines(title: "Mail · background download", subtitle: "86 MB in the last few minutes, no app in front", icon: mail, trailing: nil, buttons: ["Details", "Ignore Mail"])
        case .transfer: Lines(title: "Safari via App Store", subtitle: "640 MB so far · 12.4 MB/s", icon: safari, trailing: nil, buttons: [])
        }
    }
}
