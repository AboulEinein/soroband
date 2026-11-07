import AppKit
import QuartzCore

/// The island on one display, drawn with AppKit and Core Animation so the menu bar process stays
/// free of SwiftUI: a `CAShapeLayer` whose outline is rebuilt each frame from springs on its four
/// metrics, as the SwiftUI prototype animates `IslandShape` (`prototypes/ui-spike`), and the
/// moment's content, which fades in once the shape has grown. The display link runs only while a
/// spring moves, so a still island costs no CPU.
@MainActor
final class IslandView: NSView {
    let geometry: IslandGeometry
    /// The pointer entered (true) or left (false) the island's outline.
    var onHover: ((Bool) -> Void)?
    /// A click on the island outside its buttons.
    var onClick: (() -> Void)?

    private let shape = CAShapeLayer()
    private var springs: [Spring]
    private var link: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0
    private var content: NSView?
    private var tracking: NSTrackingArea?
    private var hovering = false
    /// Where the pointer was when the shape last changed: a pointer resting there is not on the
    /// island until it moves, so a moment that opens under it still closes on time.
    private var restingPointer: CGPoint?
    /// While the real pointer is on the island: checks each second that it still is, because a
    /// pointer can leave without the exit event arriving, which would keep a moment open for good.
    private var leaveCheck: Timer?
    /// `hover-island` holds the pointer on the island without moving it, so nothing checks it.
    private var simulated = false
    private(set) var target: IslandMetrics

    init(frame: CGRect, geometry: IslandGeometry) {
        self.geometry = geometry
        target = .rest(geometry)
        springs = [target.width, target.height, target.radius, target.bandWidth].map { Spring(value: $0) }
        super.init(frame: frame)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        shape.fillColor = NSColor.black.cgColor
        shape.frame = bounds
        layer?.addSublayer(shape)
        redraw()
        updateTracking()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The outline as drawn now.
    var metrics: IslandMetrics {
        IslandMetrics(
            width: springs[0].value, height: springs[1].value, radius: springs[2].value, bandWidth: springs[3].value,
            top: target.top)
    }

    var isAnimating: Bool { link != nil }

    /// Grows or shrinks the shape to `metrics`, replacing what it shows with `view` (nil for
    /// nothing). `view` is laid out in the area below the menu bar, or across the whole shape when
    /// `inBand` (the seamless glance, which sits beside the notch).
    func show(_ metrics: IslandMetrics, view: NSView?, inBand: Bool = false) {
        target = metrics
        for (index, value) in [metrics.width, metrics.height, metrics.radius, metrics.bandWidth].enumerated() {
            springs[index].target = value
        }
        if let old = content {
            content = nil
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                old.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated { old.removeFromSuperview() }
            }
        }
        if let view {
            let band = geometry.menuBarHeight
            let top = inBand ? 0 : band
            view.frame = CGRect(
                x: bounds.midX - metrics.width / 2, y: bounds.maxY - metrics.height,
                width: metrics.width, height: metrics.height - top)
            addSubview(view)
            content = view
            fadeIn(view)
        }
        updateTracking()
        // A tracking area replaced under the pointer sends no exit: look where it is now. A
        // pointer on the island stays on it only while it is inside the new outline; one that
        // was not on it counts only once it moves.
        if hovering {
            checkPointer()
        } else {
            restingPointer = NSEvent.mouseLocation
        }
        startLink()
    }

    /// Replaces the content in place, without the shape moving: a transfer's progress, the hotspot
    /// meter's numbers.
    func replace(with view: NSView) {
        guard let old = content else { return }
        view.frame = old.frame
        addSubview(view, positioned: .above, relativeTo: old)
        old.removeFromSuperview()
        content = view
    }

    /// SwiftUI's insertion transition in the prototype: opacity with a 0.96 scale anchored at the
    /// top, ease-out over 0.22 s after 0.14 s.
    private func fadeIn(_ view: NSView) {
        view.alphaValue = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak view] in
            guard let view, view.superview != nil, let layer = view.layer else { return }
            let scale = CABasicAnimation(keyPath: "transform")
            let top = CATransform3DMakeTranslation(0, view.bounds.height * 0.02, 0)
            scale.fromValue = CATransform3DScale(top, 0.96, 0.96, 1)
            scale.toValue = CATransform3DIdentity
            scale.duration = 0.22
            scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(scale, forKey: "in")
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                view.animator().alphaValue = 1
            }
        }
    }

    private func startLink() {
        guard link == nil, springs.contains(where: \.isMoving) else { return }
        lastFrame = CACurrentMediaTime()
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step(_ link: CADisplayLink) {
        let dt = min(link.timestamp - lastFrame, 1.0 / 30)
        lastFrame = link.timestamp
        for index in springs.indices { springs[index].advance(dt) }
        redraw()
        if !springs.contains(where: \.isMoving) {
            link.invalidate()
            self.link = nil
        }
    }

    private func redraw() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.path = islandPath(metrics, band: geometry.menuBarHeight, in: bounds)
        CATransaction.commit()
    }

    /// A view leaving its window (its panel closed) stops its timers.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow == nil else { return }
        link?.invalidate()
        link = nil
        leaveCheck?.invalidate()
        leaveCheck = nil
    }

    // MARK: Pointer

    /// Whether `point`, in this view's coordinates, is on the island's outline as it is going to
    /// be: the frame's transparent parts are not the island.
    func contains(_ point: CGPoint) -> Bool {
        islandPath(target, band: geometry.menuBarHeight, in: bounds).contains(point)
    }

    /// Clicks outside the outline go to whatever is under the panel.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        return contains(convert(point, from: superview)) ? super.hitTest(point) : nil
    }

    /// Tracks the pointer only over the outline's bounds, plus a margin to see it leave, so moving
    /// it anywhere else on screen never wakes this process.
    private func updateTracking() {
        if let tracking { removeTrackingArea(tracking) }
        let rect = islandPath(target, band: geometry.menuBarHeight, in: bounds).boundingBoxOfPath.insetBy(
            dx: -4, dy: -4)
        guard !rect.isNull, rect.width > 0 else {
            tracking = nil
            return
        }
        let area = NSTrackingArea(
            rect: rect, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    /// The panel never becomes key, so the first click is the one that counts.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Clicks reach here from the island's content; its buttons handle their own.
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func mouseEntered(with event: NSEvent) { pointer(at: event) }
    override func mouseMoved(with event: NSEvent) { pointer(at: event) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }

    private func pointer(at event: NSEvent) {
        if let resting = restingPointer {
            guard NSEvent.mouseLocation != resting else { return }
            restingPointer = nil
        }
        setHovering(contains(convert(event.locationInWindow, from: nil)))
    }

    /// For `soroband-debug://hover-island`: the pointer at `point` in this view, or gone.
    func pointer(at point: CGPoint?) {
        simulated = point != nil
        setHovering(point.map(contains) ?? false)
    }

    private func setHovering(_ inside: Bool) {
        guard inside != hovering else { return }
        hovering = inside
        leaveCheck?.invalidate()
        leaveCheck = nil
        if inside && !simulated {
            leaveCheck = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkPointer() }
            }
        }
        onHover?(inside)
    }

    private func checkPointer() {
        guard !simulated, let window, !contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) else {
            return
        }
        setHovering(false)
    }
}
