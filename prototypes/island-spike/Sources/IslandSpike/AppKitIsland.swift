import AppKit
import QuartzCore

/// The same island in AppKit and Core Animation: a `CAShapeLayer` whose path is rebuilt each frame
/// from springs on the four metrics (as SwiftUI animates `IslandShape.animatableData`), driven by the
/// view's display link only while a spring moves; the content is AppKit views faded and scaled in
/// with Core Animation.
final class AppKitIslandView: NSView {
    private let geometry: IslandGeometry
    private let shape = CAShapeLayer()
    private var springs: [Spring]
    private var link: CADisplayLink?
    private var lastTime: CFTimeInterval = 0
    private var content: NSView?

    init(frame: CGRect, geometry: IslandGeometry) {
        self.geometry = geometry
        let rest = metrics(for: nil, geometry: geometry)
        springs = [rest.width, rest.height, rest.radius, rest.bandWidth].map { Spring(value: $0) }
        super.init(frame: frame)
        wantsLayer = true
        shape.fillColor = .black
        layer!.addSublayer(shape)
        shape.frame = bounds
        redraw()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ moment: Content?) {
        let m = metrics(for: moment, geometry: geometry)
        for (i, target) in [m.width, m.height, m.radius, m.bandWidth].enumerated() { springs[i].target = target }
        if let old = content {
            content = nil
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                old.animator().alphaValue = 0
            } completionHandler: { old.removeFromSuperview() }
        }
        if let moment {
            let view = MomentView(lines: .of(moment))
            let band = geometry.menuBarHeight
            view.frame = CGRect(x: bounds.midX - m.width / 2, y: bounds.maxY - m.height, width: m.width, height: m.height - band)
            addSubview(view)
            content = view
            let layer = view.layer!
            layer.anchorPoint = CGPoint(x: 0.5, y: 1)
            layer.position = CGPoint(x: view.frame.midX, y: view.frame.maxY)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.96
            scale.toValue = 1
            let group = CAAnimationGroup()
            group.animations = [fade, scale]
            group.duration = 0.22
            group.beginTime = CACurrentMediaTime() + 0.14
            group.fillMode = .backwards
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(group, forKey: "in")
        }
        startLink()
    }

    private func startLink() {
        guard link == nil else { return }
        lastTime = CACurrentMediaTime()
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = min(now - lastTime, 1.0 / 30)
        lastTime = now
        var moving = false
        for i in springs.indices { moving = springs[i].advance(dt) || moving }
        redraw()
        if !moving {
            link.invalidate()
            self.link = nil
        }
    }

    private func redraw() {
        let m = Metrics(width: springs[0].value, height: springs[1].value, radius: springs[2].value, bandWidth: springs[3].value)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.path = islandPath(m, band: geometry.menuBarHeight, in: bounds, flipped: true)
        CATransaction.commit()
    }
}

/// SwiftUI's `.spring(response:dampingFraction:)`: mass 1, stiffness (2π / response)², damping 4π ζ / response.
struct Spring {
    var value: CGFloat
    var target: CGFloat
    var velocity: CGFloat = 0
    private let stiffness: CGFloat = (2 * .pi / 0.45) * (2 * .pi / 0.45)
    private let damping: CGFloat = 4 * .pi * 0.8 / 0.45

    init(value: CGFloat) {
        self.value = value
        target = value
    }

    /// Returns whether it still moves.
    mutating func advance(_ dt: CGFloat) -> Bool {
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
            return false
        }
        return true
    }
}

private final class MomentView: NSView {
    init(lines: Lines) {
        super.init(frame: .zero)
        wantsLayer = true
        let icon = NSImageView(image: lines.icon)
        icon.imageScaling = .scaleProportionallyUpOrDown
        let title = label(lines.title, size: 13, weight: .semibold, alpha: 1)
        let subtitle = label(lines.subtitle, size: 11, weight: .regular, alpha: 0.6)
        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        var row: [NSView] = [icon, text, NSView()]
        if let trailing = lines.trailing { row.append(label(trailing, size: 13, weight: .semibold, alpha: 1)) }
        let top = NSStackView(views: row)
        top.spacing = 12
        icon.widthAnchor.constraint(equalToConstant: 34).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 34).isActive = true
        var rows: [NSView] = [top]
        if !lines.buttons.isEmpty {
            let buttons = NSStackView(views: lines.buttons.map(capsule))
            buttons.spacing = 8
            rows.append(buttons)
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), top.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func label(_ string: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat) -> NSTextField {
        let field = NSTextField(labelWithString: string)
        field.font = .monospacedDigitSystemFont(ofSize: size, weight: weight)
        field.textColor = .white.withAlphaComponent(alpha)
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private func capsule(_ title: String) -> NSView {
        let field = label(title, size: 11, weight: .medium, alpha: 1)
        let box = NSView()
        box.wantsLayer = true
        box.layer!.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        box.layer!.cornerRadius = 11
        field.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10), field.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            field.topAnchor.constraint(equalTo: box.topAnchor, constant: 5), field.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -5),
        ])
        return box
    }
}
