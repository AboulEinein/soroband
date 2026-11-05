import AppKit
import QuartzCore

/// What a moment's buttons do.
enum MomentAction: Equatable {
    /// Quit the app and open it again on the next network that is not a hotspot.
    case pause(MomentApp)
    /// Add the app to `island_ignored_apps`.
    case ignore(MomentApp)
    /// Open History on the app.
    case details(MomentApp)
}

/// The moments' content in AppKit, laid out as the SwiftUI prototype lays them out
/// (`prototypes/ui-spike/Sources/Soroband/IslandView.swift`): a row with a tile, a title and a
/// subtitle, and something on the trailing side; alerts add a row of buttons.
@MainActor
enum MomentViews {
    struct Context {
        /// Whether the data hog offers Pause until off hotspot: the setting is on and the Mac is
        /// on a hotspot.
        var offersPause: Bool
        var color: (Int64) -> NSColor
        var act: (MomentAction) -> Void
    }

    static func view(_ content: MomentContent, context: Context) -> NSView {
        let body: NSView
        switch content {
        case .peek(let network, let today, let down, let up, let speed, let apps):
            let title = "\(network?.name ?? "Unknown network") · today \(Format.bytes(today))"
            let subtitle = "↓ \(Format.bytes(down))  ↑ \(Format.bytes(up))  ·  now ↓ \(Format.speed(speed))"
            let top = row(
                tile: networkTile(network, context: context), title: title, subtitle: subtitle, trailing: nil)
            let appViews = apps.map { app in
                let text = stack(
                    [label(app.name, size: 11), label(Format.bytes(app.bytes ?? 0), size: 11, weight: .semibold)],
                    vertical: true, spacing: 0)
                return stack([appIcon(app, size: 24), text], spacing: 6)
            }
            body = stack([top, packed(appViews, spacing: 16)], vertical: true, spacing: 12)
        case .joined(let network, let week, let today, let lastSeen):
            let when = lastSeen.map { " · last here \(relative($0))" } ?? " · first time here"
            body = row(
                tile: networkTile(network, context: context), title: "Joined \(network.name)",
                subtitle: "\(Format.bytes(week)) in the last 7 days\(when)",
                trailing: stat("Today here", Format.bytes(today)))
        case .left(let network, let since, let bytes, let top):
            let trailing = top.map { app in
                stack([appIcon(app, size: 24), stat("Top: \(app.name)", Format.bytes(app.bytes ?? 0))], spacing: 6)
            }
            body = row(
                tile: networkTile(network, context: context), title: "Left \(network.name)",
                subtitle: "\(Format.bytes(bytes)) over \(duration(since: since))", trailing: trailing)
        case .recap(let bytes, let networks, let top):
            body = row(
                tile: symbolTile("calendar", color: nil),
                title: "Today: \(Format.bytes(bytes)) across \(networks) network\(networks == 1 ? "" : "s")",
                subtitle: "Top app: \(top?.name ?? "–") · counter resets now, history kept", trailing: nil)
        case .hog(let app, let bytes, let minutes, let network):
            let place = network.map { "on \($0.name) (\($0.kind.label))" } ?? "on this network"
            let top = row(
                tile: appIcon(app, size: 34), title: "\(app.name) used \(Format.bytes(bytes)) in \(minutes) min",
                subtitle: place, trailing: symbol("exclamationmark.triangle.fill", color: .systemOrange))
            var buttons: [NSView] = []
            // Only an app bundle can be quit and opened again; a tool or macOS & Services cannot.
            if context.offersPause && app.id.hasSuffix(".app") {
                buttons.append(button("Pause until off hotspot", prominent: true) { context.act(.pause(app)) })
            }
            buttons.append(button("Ignore \(app.name)") { context.act(.ignore(app)) })
            buttons.append(button("Details") { context.act(.details(app)) })
            body = stack([top, packed(buttons)], vertical: true, spacing: 10)
        case .background(let app, let bytes, let uploading):
            let top = row(
                tile: appIcon(app, size: 34), title: "\(app.name) · background \(uploading ? "upload" : "download")",
                subtitle: "\(Format.bytes(bytes)) in the last few minutes, while not in front",
                trailing: symbol("moon.zzz.fill", color: .secondaryLabelColor))
            let buttons = [
                button("Details", prominent: true) { context.act(.details(app)) },
                button("Ignore \(app.name)") { context.act(.ignore(app)) },
            ]
            body = stack([top, packed(buttons)], vertical: true, spacing: 10)
        case .transfer(let app, let via, let bytes, let rate, let done):
            let title = via.map { "\(app.name) via \($0)" } ?? app.name
            let subtitle =
                done ? "Finished · \(Format.bytes(bytes))" : "\(Format.bytes(bytes)) so far · \(Format.speed(rate))"
            let tile = TransferTile(icon: appIcon(app, size: 24), done: done)
            body = row(
                tile: tile, title: title, subtitle: subtitle,
                trailing: done ? symbol("checkmark.circle.fill", color: .systemGreen, size: 20) : nil)
        }
        return padded(body)
    }

    /// The hotspot meter's glance: today on the hotspot beside its symbol in the left wing, the
    /// live speed in the right, the notch between them.
    static func glance(today: UInt64, speed: UInt64, color: NSColor, notchWidth: CGFloat, wing: CGFloat) -> NSView {
        let left = stack(
            [
                symbol("personalhotspot", color: color, size: 11.5),
                label(Format.bytes(today), size: 11.5, weight: .semibold),
            ],
            spacing: 5)
        let right = label("↓ \(Format.speed(speed))", size: 11.5, alpha: 0.7)
        let view = FlippedView()
        for (index, part) in [left, right].enumerated() {
            part.translatesAutoresizingMaskIntoConstraints = false
            let box = NSView()
            box.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(part)
            view.addSubview(box)
            NSLayoutConstraint.activate([
                box.widthAnchor.constraint(equalToConstant: wing),
                box.topAnchor.constraint(equalTo: view.topAnchor),
                box.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                index == 0
                    ? box.leadingAnchor.constraint(equalTo: view.leadingAnchor)
                    : box.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                part.centerXAnchor.constraint(equalTo: box.centerXAnchor),
                part.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            ])
        }
        view.wantsLayer = true
        return view
    }

    // MARK: Pieces

    private static func padded(_ body: NSView) -> NSView {
        let view = FlippedView()
        view.wantsLayer = true
        body.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            body.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            body.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
        ])
        return view
    }

    /// Views side by side from the leading edge, each as wide as its content.
    private static func packed(_ views: [NSView], spacing: CGFloat = 8) -> NSView {
        // The spacer takes the width left over, as SwiftUI's `Spacer` does.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = stack(views + [spacer], spacing: spacing)
        row.distribution = .fill
        for view in views { view.setContentHuggingPriority(.required, for: .horizontal) }
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private static func row(tile: NSView, title: String, subtitle: String, trailing: NSView?) -> NSView {
        let text = stack(
            [label(title, size: 13, weight: .semibold), label(subtitle, size: 11, alpha: 0.6)], vertical: true,
            spacing: 2)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let views = [tile, text, spacer] + (trailing.map { [$0] } ?? [])
        let row = stack(views, spacing: 12)
        row.distribution = .fill
        return row
    }

    static func stack(_ views: [NSView], vertical: Bool = false, spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = vertical ? .vertical : .horizontal
        stack.alignment = vertical ? .leading : .centerY
        stack.spacing = spacing
        return stack
    }

    static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, alpha: CGFloat = 1)
        -> NSTextField
    {
        let field = NSTextField(labelWithString: text)
        field.font = .monospacedDigitSystemFont(ofSize: size, weight: weight)
        field.textColor = NSColor.white.withAlphaComponent(alpha)
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        return field
    }

    private static func stat(_ title: String, _ value: String) -> NSView {
        let stack = stack(
            [label(title, size: 10, alpha: 0.55), label(value, size: 13, weight: .semibold)], vertical: true, spacing: 1
        )
        stack.alignment = .trailing
        return stack
    }

    static func symbol(_ name: String, color: NSColor, size: CGFloat = 15) -> NSImageView {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(
            configuration)
        let view = NSImageView(image: image ?? NSImage())
        view.contentTintColor = color
        return view
    }

    private static func networkTile(_ network: Network?, context: Context) -> NSView {
        symbolTile(network?.kind.symbol ?? unknownNetworkSymbol, color: network.map { context.color($0.id) })
    }

    /// A 34 pt rounded tile with a white symbol, on the network's color (a gradient, as SwiftUI's
    /// `Color.gradient` draws it) or a dim gray.
    private static func symbolTile(_ name: String, color: NSColor?) -> NSView {
        let tile = NSView()
        tile.wantsLayer = true
        let gradient = CAGradientLayer()
        let base = color ?? NSColor(white: 0.25, alpha: 1)
        gradient.colors = [base.blended(withFraction: 0.12, of: .white) ?? base, base].map(\.cgColor)
        gradient.cornerRadius = 9
        gradient.frame = CGRect(x: 0, y: 0, width: 34, height: 34)
        tile.layer?.addSublayer(gradient)
        let image = symbol(name, color: .white)
        image.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(image)
        tile.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 34), tile.heightAnchor.constraint(equalToConstant: 34),
            image.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            image.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])
        return tile
    }

    /// The app's icon: its bundle's or tool's from the file system, a terminal for a tool known
    /// only by name, the gear for macOS & Services.
    static func appIcon(_ app: MomentApp, size: CGFloat) -> NSImageView {
        let image: NSImage
        if app.id.hasPrefix("/") {
            image = rasterized(NSWorkspace.shared.icon(forFile: app.id), size: size)
        } else if app.id.hasPrefix("process:") {
            image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) ?? NSImage()
        } else {
            image = NSImage(systemSymbolName: "gearshape.2", accessibilityDescription: nil) ?? NSImage()
        }
        image.size = NSSize(width: size, height: size)
        let view = NSImageView(image: image)
        view.contentTintColor = .white
        view.imageScaling = .scaleProportionallyUpOrDown
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: size), view.heightAnchor.constraint(equalToConstant: size),
        ])
        return view
    }

    /// `icon` drawn once into a bitmap `size` points square at 2x: a file's icon from
    /// `NSWorkspace` can decode its 1024-pixel image when an image view draws it, 4 MB that the
    /// menu bar process would keep after the moment closes.
    private static func rasterized(_ icon: NSImage, size: CGFloat) -> NSImage {
        let pixels = Int(size * 2)
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return icon }
        bitmap.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        return image
    }

    private static func button(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> NSView {
        CapsuleButton(title: title, prominent: prominent, action: action)
    }

    private static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }

    private static func duration(since: Date) -> String {
        Duration.seconds(max(60, Date.now.timeIntervalSince(since)))
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}

/// A view laid out from its top.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The prototype's island button: medium 11 pt text on a white capsule at 12% (24% when
/// prominent), brighter while pressed.
@MainActor
private final class CapsuleButton: NSView {
    private let action: () -> Void
    private let base: CGFloat

    init(title: String, prominent: Bool, action: @escaping () -> Void) {
        self.action = action
        base = prominent ? 0.24 : 0.12
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.backgroundColor = NSColor.white.withAlphaComponent(base).cgColor
        let label = MomentViews.label(title, size: 11, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(base + 0.12).cgColor
    }

    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(base).cgColor
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
}

/// A transfer's app icon in a ring: a spinning arc while it runs, a green circle once done.
@MainActor
private final class TransferTile: NSView {
    init(icon: NSView, done: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 34), heightAnchor.constraint(equalToConstant: 34),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        let ring = CAShapeLayer()
        ring.frame = CGRect(x: 0, y: 0, width: 34, height: 34)
        ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 1.25, dy: 1.25), transform: nil)
        ring.fillColor = nil
        ring.lineWidth = 2.5
        ring.lineCap = .round
        if done {
            ring.strokeColor = NSColor.systemGreen.cgColor
        } else {
            ring.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
            ring.strokeEnd = 0.3
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 1
            spin.repeatCount = .infinity
            ring.add(spin, forKey: "spin")
        }
        layer?.addSublayer(ring)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
