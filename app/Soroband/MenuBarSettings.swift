import SwiftUI

/// Settings › Menu Bar: what the menu bar item shows, in which order and style, with a preview of
/// the menu bar pinned above. Every change applies at once; Revert goes back to the layout the
/// page opened with.
struct MenuBarSettings: View {
    let usage: Usage
    /// The preview's clock, and the current network's kind and name.
    var now = Date.now
    var kind: NetworkKind? = NetworkMonitor.shared.current?.kind ?? .wifi
    var networkName: String? = NetworkMonitor.shared.current?.name
    /// The layout when the page opened.
    @State private var opened: MenuBarLayout?

    private var layout: MenuBarLayout { usage.menuBarLayout }

    /// Today's numbers, or sample ones before the engine has counted anything to show.
    private var status: EngineStatus {
        usage.status.state == .starting ? MenuBarPreview.sample : usage.status
    }

    private var today: ByteCounts {
        layout.scope == .network ? status.todayNetworkInterfaces : status.todayInterfaces
    }

    var body: some View {
        VStack(spacing: 0) {
            MenuBarPreview(
                display: MenuBarDisplay.make(layout: layout, status: status, kind: kind), now: now,
                revert: opened.flatMap { opened in opened == layout ? nil : { usage.setMenuBarLayout(opened) } })
            Divider()
            SettingsPage(
                title: "Menu Bar",
                subtitle:
                    "Pick what Soroband shows beside its network icon, put it in order, and choose how it is drawn."
            ) {
                SettingsSection(title: "Readings", trailing: "\(layout.readings.count) of \(MenuBarLayout.maxReadings)")
                {
                    readings
                }
                SettingsSection(title: "Order", trailing: orderNote) {
                    OrderTray(layout: layout, symbol: kind?.symbol ?? unknownNetworkSymbol, apply: apply)
                }
                SettingsSection(title: "Style") {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(MenuBarStyle.allCases) { style in
                            StyleCard(
                                style: style,
                                display: MenuBarDisplay.make(layout: styled(style), status: status, kind: kind),
                                isSelected: layout.style == style
                            ) {
                                apply { $0.style = style }
                            }
                        }
                    }
                }
                SettingsCard {
                    SettingsRow(title: "Count today on", detail: scopeNote) {
                        Picker(
                            "Count today on",
                            selection: Binding(get: { layout.scope }, set: { scope in apply { $0.scope = scope } })
                        ) {
                            ForEach(MenuBarScope.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .disabled(!layout.showsUsage)
                    }
                }
                HStack {
                    Button("Restore Default") { usage.setMenuBarLayout(.default) }
                        .disabled(layout == .default)
                    Spacer()
                    Label("Changes show in the menu bar as you make them", systemImage: "checkmark")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .onAppear { if opened == nil { opened = usage.menuBarLayout } }
    }

    private var readings: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(layout.scope == .all ? "Today on all networks" : "Today on \(networkName ?? "this network")")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4)
                ForEach(MenuBarReading.usage) { tile($0) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Live speed").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4)
                ForEach(MenuBarReading.speeds) { tile($0) }
                EnergyNote(isLive: layout.showsSpeed)
            }
        }
    }

    private func tile(_ reading: MenuBarReading) -> some View {
        let isOn = layout.readings.contains(reading)
        let value = reading.value(today: today, speed: status.speed)
        return ReadingTile(
            reading: reading, value: reading.isSpeed ? "\(value) · every 5 s" : value, isOn: isOn,
            isFull: layout.readings.count >= MenuBarLayout.maxReadings
        ) {
            apply { layout in
                if let index = layout.readings.firstIndex(of: reading) {
                    layout.readings.remove(at: index)
                } else {
                    layout.readings.append(reading)
                }
            }
        }
    }

    private var orderNote: String {
        switch layout.style {
        case .stacked:
            layout.readings.count > 1 ? "Each pair stacks, the first on top" : "One reading draws at full size"
        case .labeled: "Side by side, left to right"
        case .inline: "One line, left to right"
        }
    }

    private var scopeNote: String {
        if !layout.showsUsage { return "Applies to today’s readings. Speed is always this Mac’s." }
        return layout.scope == .network
            ? "Today’s readings count \(networkName ?? "the network you are on"), the network you are on."
            : "Today’s readings add up every network since the day started."
    }

    private func styled(_ style: MenuBarStyle) -> MenuBarLayout {
        var styled = layout
        styled.style = style
        return styled
    }

    private func apply(_ change: (inout MenuBarLayout) -> Void) {
        var next = layout
        change(&next)
        if next != layout { usage.setMenuBarLayout(next) }
    }
}

/// A reading to show or hide: its name, what it reads now, and a checkmark when shown.
private struct ReadingTile: View {
    let reading: MenuBarReading
    let value: String
    let isOn: Bool
    /// Four readings are shown, so another cannot be added.
    let isFull: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: reading.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isOn ? .white : .secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), in: .rect(cornerRadius: 7)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(reading.label).fontWeight(.medium)
                    Text(value).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 4)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            }
            .padding(.leading, 9).padding(.trailing, 12)
            .frame(height: 46)
            .background(
                isOn ? AnyShapeStyle(Color.accentColor.opacity(0.13)) : AnyShapeStyle(SettingsColor.card),
                in: .rect(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isOn ? Color.accentColor.opacity(0.55) : .primary.opacity(0.08), lineWidth: isOn ? 1 : 0.5)
            )
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!isOn && isFull)
        .opacity(!isOn && isFull ? 0.45 : 1)
        .help(!isOn && isFull ? "Four readings fit. Remove one to add this." : "")
        .accessibilityLabel(reading.label)
        .accessibilityValue(value)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// What live speed costs, said more firmly once a speed is shown.
private struct EnergyNote: View {
    let isLive: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "bolt").foregroundStyle(isLive ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
            Text("Speed redraws the menu bar every 5 seconds, so it uses a little more energy than today’s usage.")
                .foregroundStyle(isLive ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .padding(.horizontal, 11).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isLive ? Color.orange.opacity(0.09) : .clear, in: .rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isLive ? Color.orange.opacity(0.35) : .primary.opacity(0.08), lineWidth: 0.5)
        )
        .padding(.top, 2)
    }
}

/// The shown readings in their order, grouped as the style draws them; drag one onto another to
/// move it there.
private struct OrderTray: View {
    let layout: MenuBarLayout
    let symbol: String
    let apply: ((inout MenuBarLayout) -> Void) -> Void

    var body: some View {
        SettingsCard {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(.tertiary)
                if layout.readings.isEmpty {
                    Text("The icon alone. Pick a reading above to show it beside the icon.")
                        .foregroundStyle(.secondary)
                } else if layout.style == .stacked {
                    HStack(spacing: 8) {
                        ForEach(Array(stride(from: 0, to: layout.readings.count, by: 2)), id: \.self) { start in
                            VStack(spacing: 4) {
                                ForEach(start..<min(start + 2, layout.readings.count), id: \.self) { chip($0) }
                            }
                            .padding(4)
                            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 9))
                        }
                    }
                } else {
                    HStack(spacing: 6) {
                        ForEach(layout.readings.indices, id: \.self) { chip($0) }
                    }
                }
                Spacer(minLength: 8)
                if layout.readings.count > 1 {
                    Text("Drag to reorder").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(minHeight: 76)
        }
    }

    private func chip(_ index: Int) -> some View {
        let reading = layout.readings[index]
        return OrderChip(
            reading: reading, position: index + 1, count: layout.readings.count,
            move: { dropped in apply { Self.move(dropped, to: index, in: &$0.readings) } },
            step: { offset in apply { Self.move(reading, to: index + offset, in: &$0.readings) } },
            remove: { apply { $0.readings.removeAll { $0 == reading } } })
    }

    /// Moves `reading` to `index`, the others keeping their order.
    static func move(_ reading: MenuBarReading, to index: Int, in readings: inout [MenuBarReading]) {
        guard let from = readings.firstIndex(of: reading), readings.indices.contains(index), from != index else {
            return
        }
        readings.remove(at: from)
        readings.insert(reading, at: index)
    }
}

private struct OrderChip: View {
    let reading: MenuBarReading
    let position: Int
    let count: Int
    /// Moves the dropped reading to this one's place.
    let move: (MenuBarReading) -> Void
    /// Moves this reading earlier (-1) or later (+1).
    let step: (Int) -> Void
    let remove: () -> Void
    @State private var isTargeted = false

    var body: some View {
        label
            .draggable(reading.rawValue) { label }
            .dropDestination(for: String.self) { items, _ in
                guard let dropped = items.first.flatMap(MenuBarReading.init(rawValue:)) else { return false }
                move(dropped)
                return true
            } isTargeted: {
                isTargeted = $0
            }
            .contextMenu {
                Button("Move Earlier") { step(-1) }.disabled(position == 1)
                Button("Move Later") { step(1) }.disabled(position == count)
                Divider()
                Button("Remove") { remove() }
            }
            .help("Drag onto another reading to move it there, or Control-click to move or remove")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(reading.label), \(position) of \(count)")
            .accessibilityAction(named: "Move earlier") { step(-1) }
            .accessibilityAction(named: "Move later") { step(1) }
            .accessibilityAction(named: "Remove") { remove() }
    }

    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
            Text(reading.shortLabel)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.leading, 7).padding(.trailing, 10)
        .frame(height: 24)
        .background(SettingsColor.card, in: .rect(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isTargeted ? Color.accentColor : .primary.opacity(0.13), lineWidth: isTargeted ? 1.5 : 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
    }
}

/// A style to choose, with the item drawn in it.
private struct StyleCard: View {
    let style: MenuBarStyle
    let display: MenuBarDisplay
    let isSelected: Bool
    let select: () -> Void

    private var detail: String {
        switch style {
        case .stacked: "Pairs stacked in small type. The narrowest."
        case .labeled: "A tiny caption names each value."
        case .inline: "One line at full size. Best for one or two."
        }
    }

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 0) {
                MenuBarItemImage(display: display)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(MenuBarPreview.strip, in: .rect(cornerRadius: 7))
                    .environment(\.colorScheme, .dark)
                HStack(spacing: 6) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    Text(style.label).fontWeight(.semibold)
                }
                .padding(.top, 8).padding(.horizontal, 4)
                Text(detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 24).padding(.trailing, 4).padding(.top, 2)
            }
            .padding(7).padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SettingsColor.card, in: .rect(cornerRadius: 11))
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(
                        isSelected ? Color.accentColor : .primary.opacity(0.08), lineWidth: isSelected ? 2 : 0.5)
            )
            .contentShape(.rect(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(style.label) style")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The item exactly as the menu bar draws it: the same image, in the menu bar's text color,
/// scaled down only when it would not fit.
struct MenuBarItemImage: View {
    let display: MenuBarDisplay

    var body: some View {
        if let image = display.itemImage(debug: false) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                .foregroundStyle(.primary)
        }
    }
}

/// The menu bar as it would look with the item, between other items and the clock, with how
/// wide the item is and, after a change, a way back.
struct MenuBarPreview: View {
    let display: MenuBarDisplay
    var now = Date.now
    /// Puts back the layout Settings opened with; nil while it is unchanged.
    var revert: (() -> Void)?

    /// 1.09 GB today on this network (893.6 MB down, 203.8 MB up), 2.87 GB on all networks; the menu
    /// bar rounds them down to 1.0 GB and 2.8 GB.
    static let sample = EngineStatus(
        todayNetworkInterfaces: ByteCounts(rx: 893_600_000, tx: 203_800_000),
        todayInterfaces: ByteCounts(rx: 2_370_000_000, tx: 500_000_000),
        speed: ByteCounts(rx: 137_000, tx: 42_000))

    /// The menu bar's color over a wallpaper, in each appearance.
    static let strip = Color(light: 0xE9E7EE, dark: 0x0B0B0E)

    /// Wider than this, the item may be hidden beside the notch of a MacBook's display.
    static let notchWidth: CGFloat = 160

    @MainActor private var width: CGFloat { (display.itemImage(debug: false)?.size.width ?? 0).rounded() }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Menu bar preview")
                Spacer()
                Group {
                    if width > Self.notchWidth {
                        Text("\(Int(width)) pt wide · may crowd the notch")
                            .foregroundStyle(.orange)
                            .help(
                                "On a MacBook with a notch, menu bar items that do not fit beside it are hidden. A narrower style keeps more of them in sight."
                            )
                    } else {
                        Text("\(Int(width)) pt wide")
                    }
                }
                .monospacedDigit()
                if let revert {
                    Button("Revert Changes", action: revert)
                        .buttonStyle(.link)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                HStack(spacing: 16) {
                    Image(systemName: "apple.logo")
                    Text("Soroband").fontWeight(.bold)
                    Text("Edit")
                    Text("Window")
                }
                .fixedSize()
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .clipped()
                .opacity(0.5)
                .mask(
                    LinearGradient(
                        stops: [.init(color: .black, location: 0.7), .init(color: .clear, location: 1)],
                        startPoint: .leading, endPoint: .trailing)
                )
                .accessibilityHidden(true)
                // The other menus give way first; an item wider than the strip is scaled down
                // rather than cut.
                .layoutPriority(-1)
                Image(systemName: "icloud").accessibilityHidden(true)
                MenuBarItemImage(display: display)
                    .layoutPriority(1)
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .background(.primary.opacity(0.14), in: .rect(cornerRadius: 5))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(display.accessibilityLabel(debug: false))
                Image(systemName: "battery.75percent").accessibilityHidden(true)
                Image(systemName: "switch.2").accessibilityHidden(true)
                Text(now.formatted(.dateTime.weekday().hour().minute()))
                    .fixedSize()
                    .accessibilityHidden(true)
            }
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
            .frame(height: 30)
            .clipped()
            .background(Self.strip, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.07), lineWidth: 0.5))
            .help("How the menu bar item looks with these settings")
        }
        .padding(.horizontal, 24).padding(.top, 6).padding(.bottom, 12)
        .background(.bar)
    }
}
