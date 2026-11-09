import AppKit

/// Where the island sits on one display: the notch's width (0 on a display without one) and the
/// menu bar's height.
struct IslandGeometry: Equatable {
    var notchWidth: CGFloat
    var menuBarHeight: CGFloat
    var hasNotch: Bool { notchWidth > 0 }

    init(notchWidth: CGFloat, menuBarHeight: CGFloat) {
        self.notchWidth = notchWidth
        self.menuBarHeight = menuBarHeight
    }

    @MainActor
    init(screen: NSScreen) {
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
            screen.safeAreaInsets.top > 0
        {
            notchWidth = screen.frame.width - left.width - right.width
            menuBarHeight = screen.safeAreaInsets.top
        } else {
            notchWidth = 0
            menuBarHeight = NSStatusBar.system.thickness
        }
    }
}

/// The island's size: one black shape hanging from the top edge, `width` wide and `height` tall
/// with corners of `radius`. Inside the menu bar it is only `bandWidth` wide, which is narrower
/// than `width` in the keep-menu-bar-clear style. With no notch to hang from in that style, it
/// starts `top` below the screen's edge: under the menu bar.
struct IslandMetrics: Equatable {
    var width: CGFloat
    var height: CGFloat
    var radius: CGFloat
    var bandWidth: CGFloat
    var top: CGFloat = 0

    /// Each side of a glance beside the notch.
    static let wing: CGFloat = 92
    static let panelWidth: CGFloat = 560
    /// How far below the menu bar the island can reach.
    static let panelDepth: CGFloat = 200

    /// At rest: exactly the notch, or nothing on a display without one. Keeping the menu bar
    /// clear without a notch, it rests below the menu bar too, so the shape never crosses it on
    /// the way in or out.
    static func rest(_ geometry: IslandGeometry, style: IslandSettings.Style = .seamless) -> IslandMetrics {
        let notch = geometry.notchWidth
        let top = style == .clear && !geometry.hasNotch ? geometry.menuBarHeight : 0
        return IslandMetrics(
            width: notch, height: geometry.hasNotch ? geometry.menuBarHeight : 0, radius: 9, bandWidth: notch, top: top)
    }

    /// The hotspot meter's glance: widened sideways at notch height (seamless), or a small band
    /// below the notch (keep menu bar clear).
    static func glance(_ geometry: IslandGeometry, style: IslandSettings.Style) -> IslandMetrics {
        let notch = geometry.notchWidth
        let band = geometry.menuBarHeight
        switch style {
        case .seamless:
            let width = notch + 2 * wing
            return IslandMetrics(width: width, height: band, radius: 11, bandWidth: width)
        case .clear:
            let width = max(notch + 60, 200)
            return geometry.hasNotch
                ? IslandMetrics(width: width, height: band + 26, radius: 13, bandWidth: notch)
                : IslandMetrics(width: width, height: band + 26, radius: 13, bandWidth: width, top: band)
        }
    }

    /// A moment of `kind` open.
    static func open(_ kind: MomentKind, _ geometry: IslandGeometry, style: IslandSettings.Style) -> IslandMetrics {
        let band = geometry.menuBarHeight
        let (width, height): (CGFloat, CGFloat) =
            switch kind {
            case .hog, .background: (470, band + 100)
            case .peek: (450, band + 104)
            default: (450, band + 66)
            }
        switch style {
        case .seamless:
            return IslandMetrics(width: width, height: height, radius: 26, bandWidth: width)
        case .clear where !geometry.hasNotch:
            return IslandMetrics(width: width, height: height, radius: 26, bandWidth: width, top: band)
        case .clear:
            return IslandMetrics(width: width, height: height, radius: 26, bandWidth: geometry.notchWidth)
        }
    }
}

/// The island's outline in a view `rect` whose top edge is the screen's: a rounded rectangle
/// flush with the top, with small outward fillets where it meets the edge, like the hardware
/// notch. Where `bandWidth` is narrower than `width`, the part inside the menu bar (`band` tall)
/// stays that narrow and the shape widens only below it.
///
/// `flipped`: y grows downward in `rect` (false for AppKit and Core Animation, whose y grows up).
func islandPath(_ m: IslandMetrics, band: CGFloat, in rect: CGRect, flipped: Bool = false) -> CGPath {
    let p = CGMutablePath()
    guard m.width > 1, m.height > 1 else { return p }
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: flipped ? rect.minY + y : rect.maxY - y) }
    if m.top > 0 {
        // Below the menu bar, rounded at all four corners; nothing while not taller than it.
        guard m.height > m.top else { return p }
        let corner = min(m.radius, (m.height - m.top) / 2)
        let topLeft = pt(rect.midX - m.width / 2, m.top)
        let bottomRight = pt(rect.midX + m.width / 2, m.height)
        let box = CGRect(
            x: topLeft.x, y: min(topLeft.y, bottomRight.y), width: m.width, height: abs(topLeft.y - bottomRight.y))
        p.addRoundedRect(in: box, cornerWidth: corner, cornerHeight: corner)
        return p
    }
    let cx = rect.midX
    // Wider than the band: only the part below the menu bar may be wider. While the shape is
    // still no deeper than the menu bar, it is only as wide as the band.
    let neckable = m.bandWidth > 0 && m.bandWidth < m.width
    let below = m.height - band
    let width = neckable && below <= 0 ? m.bandWidth : m.width
    let left = cx - width / 2
    let right = cx + width / 2
    let necked = neckable && below > 0
    // The fillets where the neck meets the wider part start at the menu bar's lower edge, and
    // shrink with the room they have, so the outline changes smoothly from frame to frame.
    let f = necked ? min(8, (m.width - m.bandWidth) / 2, below / 3) : 0
    let r = necked ? min(m.radius, width / 2, below - 2 * f) : min(m.radius, m.height / 2, width / 2)
    let shoulder = band + f
    let ear = min(6, m.height / 3)
    let nl = cx - m.bandWidth / 2
    let nr = cx + m.bandWidth / 2
    let topLeft = necked ? nl : left
    let topRight = necked ? nr : right
    p.move(to: pt(topLeft - ear, 0))
    p.addQuadCurve(to: pt(topLeft, ear), control: pt(topLeft, 0))
    if necked {
        p.addLine(to: pt(nl, band))
        p.addQuadCurve(to: pt(nl - f, shoulder), control: pt(nl, shoulder))
        p.addLine(to: pt(left + f, shoulder))
        p.addQuadCurve(to: pt(left, shoulder + f), control: pt(left, shoulder))
    }
    p.addLine(to: pt(left, m.height - r))
    p.addQuadCurve(to: pt(left + r, m.height), control: pt(left, m.height))
    p.addLine(to: pt(right - r, m.height))
    p.addQuadCurve(to: pt(right, m.height - r), control: pt(right, m.height))
    if necked {
        p.addLine(to: pt(right, shoulder + f))
        p.addQuadCurve(to: pt(right - f, shoulder), control: pt(right, shoulder))
        p.addLine(to: pt(nr + f, shoulder))
        p.addQuadCurve(to: pt(nr, band), control: pt(nr, shoulder))
    }
    p.addLine(to: pt(topRight, ear))
    p.addQuadCurve(to: pt(topRight + ear, 0), control: pt(topRight, 0))
    p.closeSubpath()
    return p
}

/// SwiftUI's `.spring(response:dampingFraction:)`, which the island's prototype animates with:
/// mass 1, stiffness (2π / response)², damping 4π ζ / response. Stepped by the display link.
struct Spring: Equatable {
    var value: CGFloat
    var target: CGFloat
    var velocity: CGFloat = 0
    let stiffness: CGFloat
    let damping: CGFloat

    init(value: CGFloat, response: CGFloat = 0.45, dampingFraction: CGFloat = 0.8) {
        self.value = value
        target = value
        stiffness = (2 * .pi / response) * (2 * .pi / response)
        damping = 4 * .pi * dampingFraction / response
    }

    var isMoving: Bool { value != target || velocity != 0 }

    /// Moves `dt` seconds on. Settles exactly on the target once within a twentieth of a point.
    mutating func advance(_ dt: CGFloat) {
        let steps = 4
        let h = dt / CGFloat(steps)
        for _ in 0..<steps {
            let force = -stiffness * (value - target) - damping * velocity
            velocity += force * h
            value += velocity * h
        }
        if abs(value - target) < 0.05 && abs(velocity) < 0.5 {
            value = target
            velocity = 0
        }
    }
}
