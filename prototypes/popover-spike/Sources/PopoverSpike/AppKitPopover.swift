import AppKit
import QuartzCore

/// Option C's popover in AppKit: stack views, labels and Core Animation layers.
final class AppKitPopover: NSViewController {
    private let blue = Fake.blue
    private var growing: [CALayer] = []

    override func loadView() {
        let stack = NSStackView(views: [hero(), segmented(), listHeader(), list(), footer()])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: 360).isActive = true
        view = stack
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Beads and bars grow once on open, as the SwiftUI spring does.
        for layer in growing {
            let grow = CASpringAnimation(keyPath: "transform.scale")
            grow.fromValue = 0
            grow.toValue = 1
            grow.duration = 0.5
            layer.add(grow, forKey: "grow")
        }
    }

    // MARK: Pieces

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, secondary: Bool = false,
                       rounded: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        var font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        if rounded, let descriptor = font.fontDescriptor.withDesign(.rounded) {
            font = NSFont(descriptor: descriptor, size: size) ?? font
        }
        field.font = font
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        return field
    }

    private func row(_ views: [NSView], spacing: CGFloat = 8, alignment: NSLayoutConstraint.Attribute = .centerY)
        -> NSStackView
    {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = spacing
        stack.alignment = alignment
        return stack
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        return view
    }

    private func layerView(height: CGFloat, width: CGFloat? = nil, _ configure: (CALayer) -> Void) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        configure(view.layer!)
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        if let width { view.widthAnchor.constraint(equalToConstant: width).isActive = true }
        return view
    }

    private func hero() -> NSView {
        let badge = NSImageView(image: NSImage(systemSymbolName: "wifi", accessibilityDescription: nil)!)
        badge.contentTintColor = .white
        badge.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        badge.wantsLayer = true
        badge.layer?.backgroundColor = blue.cgColor
        badge.layer?.cornerRadius = 8
        badge.widthAnchor.constraint(equalToConstant: 28).isActive = true
        badge.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let titles = NSStackView(views: [
            label(Fake.network, size: 13, weight: .semibold), label(Fake.subtitle, size: 11, secondary: true),
        ])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 1
        let speeds = NSStackView(views: [
            label("↓ \(Fake.speed.0)", size: 10.5, secondary: true), label("↑ \(Fake.speed.1)", size: 10.5, secondary: true),
        ])
        speeds.orientation = .vertical
        speeds.alignment = .trailing
        speeds.spacing = 1

        let caption = label("today on\nthis network", size: 11, secondary: true)
        caption.alignment = .right
        let number = row([
            label(Fake.total, size: 44, weight: .bold, rounded: true),
            label(Fake.unit, size: 20, weight: .semibold, secondary: true, rounded: true), spacer(), caption,
        ], spacing: 6, alignment: .lastBaseline)

        let split = row([
            label("↓ \(Fake.down) download", size: 11, secondary: true),
            label("↑ \(Fake.up) upload", size: 11, secondary: true), spacer(),
            label("all \(Fake.allNetworks)", size: 11, secondary: true),
        ])

        let axisLabels = ["12 AM", "6", "12 PM", "6", "11 PM"].map { label($0, size: 9.5, secondary: true) }
        axisLabels.forEach { $0.textColor = .tertiaryLabelColor }
        let axis = row(axisLabels, spacing: 0)
        axis.distribution = .equalSpacing

        let card = NSStackView(views: [
            row([badge, titles, spacer(), speeds], spacing: 9), number, split, beads(), axis,
        ])
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 10
        card.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        for view in card.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -28).isActive = true
        }
        card.wantsLayer = true
        let tint = CAGradientLayer()
        tint.colors = [blue.withAlphaComponent(0.30).cgColor, blue.withAlphaComponent(0.12).cgColor]
        tint.startPoint = CGPoint(x: 0, y: 1)
        tint.endPoint = CGPoint(x: 1, y: 0)
        tint.cornerRadius = 14
        tint.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        card.layer?.addSublayer(tint)
        card.layer?.cornerRadius = 14
        card.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: card, queue: .main) {
            [weak card] _ in tint.frame = card?.bounds ?? .zero
        }
        return card
    }

    private func beads() -> NSView {
        let peak = Fake.hours.max() ?? 1
        let view = BeadsView(hours: Fake.hours, peak: peak, now: Fake.nowHour, color: blue)
        view.heightAnchor.constraint(equalToConstant: 30).isActive = true
        growing.append(contentsOf: view.bars)
        return view
    }

    private func segmented() -> NSView {
        let control = NSSegmentedControl(labels: ["Apps", "Networks"], trackingMode: .selectOne, target: nil, action: nil)
        control.selectedSegment = 0
        control.segmentDistribution = .fillEqually
        return control
    }

    private func listHeader() -> NSView {
        let toggle = NSSwitch()
        toggle.controlSize = .mini
        return row([label("Today on \(Fake.network)", size: 11, secondary: true), spacer(),
                    label("All networks", size: 11), toggle])
    }

    private func list() -> NSView {
        let rows: [NSView] = Fake.apps.map { app in
            let icon: NSImageView
            if app.path.isEmpty || !Fake.icons {
                icon = NSImageView(image: NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)!)
                icon.symbolConfiguration = .init(pointSize: 18, weight: .regular)
                icon.contentTintColor = .secondaryLabelColor
            } else {
                icon = NSImageView(image: NSWorkspace.shared.icon(forFile: app.path))
                icon.imageScaling = .scaleProportionallyUpOrDown
            }
            icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 22).isActive = true
            let bar = BarView(share: app.share, color: app.path.isEmpty ? .secondaryLabelColor : blue)
            growing.append(bar.fill)
            let text = NSStackView(views: [
                row([label(app.name, size: 13), spacer(), label(app.value, size: 12, secondary: true)]), bar,
            ])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 4
            for view in text.arrangedSubviews {
                view.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
            }
            return row([icon, text], spacing: 10)
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.spacing = 9
        for view in rows { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }

    private func footer() -> NSView {
        let spark = layerView(height: 20, width: 7 * 4 + 6 * 2) { layer in
            for (day, value) in Fake.week.enumerated() {
                let bar = CALayer()
                let height = value / 11.5 * 20
                bar.frame = CGRect(x: CGFloat(day) * 6, y: 0, width: 4, height: height)
                bar.cornerRadius = 1.5
                bar.backgroundColor = (day == Fake.week.count - 1
                    ? NSColor.labelColor : NSColor.secondaryLabelColor.withAlphaComponent(0.5)).cgColor
                layer.addSublayer(bar)
            }
        }
        let titles = NSStackView(views: [
            label("History", size: 12, weight: .semibold), label("62.3 GB this month", size: 10.5, secondary: true),
        ])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 1
        let shortcut = label("⌘Y", size: 10, secondary: true)
        shortcut.textColor = .tertiaryLabelColor
        let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)!)
        chevron.contentTintColor = .tertiaryLabelColor
        let card = row([spark, titles, spacer(), shortcut, chevron], spacing: 10)
        card.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.6).cgColor
        card.layer?.cornerRadius = 10
        let buttons: [NSView] = ["gearshape", "power"].map { symbol in
            let button = NSButton(
                image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!, target: nil, action: nil)
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.6).cgColor
            button.layer?.cornerRadius = 10
            button.widthAnchor.constraint(equalToConstant: 36).isActive = true
            button.heightAnchor.constraint(equalToConstant: 36).isActive = true
            return button
        }
        return row([card] + buttons, spacing: 8)
    }
}

/// Today's 24 hourly beads, laid out on resize.
final class BeadsView: NSView {
    let bars: [CALayer]
    private let ring = CALayer()
    private let hours: [Double]
    private let peak: Double
    private let now: Int

    init(hours: [Double], peak: Double, now: Int, color: NSColor) {
        self.hours = hours
        self.peak = peak
        self.now = now
        bars = hours.indices.map { hour in
            let bar = CALayer()
            bar.cornerRadius = 3
            bar.anchorPoint = CGPoint(x: 0.5, y: 0)
            bar.backgroundColor = hour > now
                ? NSColor.secondaryLabelColor.withAlphaComponent(0.2).cgColor : color.withAlphaComponent(0.9).cgColor
            return bar
        }
        super.init(frame: .zero)
        wantsLayer = true
        ring.borderColor = color.withAlphaComponent(0.6).cgColor
        ring.borderWidth = 1.5
        ring.cornerRadius = 4
        bars.forEach { layer?.addSublayer($0) }
        layer?.addSublayer(ring)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let gap: CGFloat = 3
        let width = (bounds.width - gap * CGFloat(hours.count - 1)) / CGFloat(hours.count)
        for (hour, bar) in bars.enumerated() {
            let height = hour > now ? 3 : max(3, hours[hour] / peak * bounds.height)
            bar.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            bar.position = CGPoint(x: CGFloat(hour) * (width + gap) + width / 2, y: 0)
        }
        let current = bars[now].frame
        ring.frame = current.insetBy(dx: -2.5, dy: -2.5)
    }
}

/// An app's usage bar: a track and its fill.
final class BarView: NSView {
    let fill = CALayer()
    private let share: Double

    init(share: Double, color: NSColor) {
        self.share = share
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        layer?.cornerRadius = 2
        fill.backgroundColor = color.cgColor
        fill.cornerRadius = 2
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        layer?.addSublayer(fill)
        heightAnchor.constraint(equalToConstant: 4).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        fill.bounds = CGRect(x: 0, y: 0, width: bounds.width * share, height: bounds.height)
        fill.position = CGPoint(x: 0, y: bounds.midY)
    }
}
