import SwiftUI

/// Settings › Menu Bar: the menu bar item designed by dragging what it shows into its two lines,
/// with a live preview. Nothing changes in the menu bar until Save.
struct MenuBarSettings: View {
    let usage: Usage
    /// The preview's clock and network kind.
    var now = Date.now
    var kind: NetworkKind = NetworkMonitor.shared.current?.kind ?? .wifi
    /// The layout being designed; nil while it is the saved one.
    @State private var draft: MenuBarLayout?

    private var layout: MenuBarLayout { draft ?? usage.menuBarLayout }
    private var isEdited: Bool { draft != nil && draft != usage.menuBarLayout }

    /// Today's numbers, or sample ones before the engine has counted anything to show.
    private var previewStatus: EngineStatus {
        usage.status.state == .starting ? MenuBarPreview.sample : usage.status
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Preview").font(.headline)
                MenuBarPreview(
                    display: MenuBarDisplay.make(
                        layout: layout, status: previewStatus, kind: kind),
                    now: now)
            }

            HStack(alignment: .center, spacing: 10) {
                LineSlot(title: "Top line", line: binding(\.top))
                Button {
                    edit { swap(&$0.top, &$0.bottom) }
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .buttonStyle(.borderless)
                .help("Swap the lines")
                LineSlot(title: "Bottom line", line: binding(\.bottom))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Drag into a line, or click to add").font(.caption).foregroundStyle(.secondary)
                Palette(title: "Today", lines: MenuBarLine.usage, status: previewStatus, scope: layout.scope, add: add)
                Palette(
                    title: "Live speed", lines: MenuBarLine.speeds, status: previewStatus, scope: layout.scope, add: add
                )
            }

            Picker("Count today on", selection: binding(\.scope)) {
                ForEach(MenuBarScope.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(!layout.showsUsage)

            if layout.showsSpeed {
                Text("Live speed redraws the menu bar every 5 seconds, which uses more energy than today's usage.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
            HStack {
                Button("Default") { draft = .default }
                    .disabled(layout == .default)
                Spacer()
                Button("Revert") { draft = nil }
                    .disabled(!isEdited)
                Button("Save") {
                    if let draft { usage.setMenuBarLayout(draft) }
                    draft = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isEdited)
            }
        }
        .padding(20)
    }

    private func edit(_ change: (inout MenuBarLayout) -> Void) {
        var next = layout
        change(&next)
        draft = next
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<MenuBarLayout, Value>) -> Binding<Value> {
        Binding(get: { layout[keyPath: keyPath] }, set: { value in edit { $0[keyPath: keyPath] = value } })
    }

    /// A click on a palette item fills the first empty line, or replaces the bottom one.
    private func add(_ line: MenuBarLine) {
        edit {
            if $0.top == .none {
                $0.top = line
            } else if $0.top != line {
                $0.bottom = line
            }
        }
    }
}

/// One line of the item: what it shows, or a place to drop something.
private struct LineSlot: View {
    let title: String
    @Binding var line: MenuBarLine
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack {
                if line == .none {
                    Text("Drop here").foregroundStyle(.tertiary)
                } else {
                    Text(line.label)
                    Spacer()
                    Button {
                        line = .none
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Clear this line")
                    .accessibilityLabel("Clear \(title.lowercased())")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(targeted ? Color.accentColor.opacity(0.15) : .clear, in: .rect(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        targeted ? Color.accentColor : Color.secondary.opacity(0.5),
                        style: StrokeStyle(lineWidth: 1, dash: line == .none ? [4, 3] : []))
            )
            .dropDestination(for: String.self) { items, _ in
                guard let dropped = items.first.flatMap(MenuBarLine.init(rawValue:)) else { return false }
                line = dropped
                return true
            } isTargeted: {
                targeted = $0
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(line == .none ? "nothing" : line.label)")
    }
}

/// A row of items to drag into a line, each with what it would show now.
private struct Palette: View {
    let title: String
    let lines: [MenuBarLine]
    let status: EngineStatus
    let scope: MenuBarScope
    let add: (MenuBarLine) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            ForEach(lines) { line in
                let today = scope == .network ? status.todayNetworkInterfaces : status.todayInterfaces
                Button {
                    add(line)
                } label: {
                    VStack(spacing: 1) {
                        Text(line.label).font(.caption.weight(.medium))
                        Text(line.text(today: today, speed: status.speed) ?? "")
                            .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.quaternary.opacity(0.6), in: .capsule)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .draggable(line.rawValue)
                .help("Drag into a line, or click to add")
            }
        }
    }
}

/// The menu bar item as a layout draws it, on a strip like the menu bar, beside a clock for scale.
/// Two lines stack in the smaller size the menu bar uses for them.
struct MenuBarPreview: View {
    let display: MenuBarDisplay
    var now = Date.now

    /// 1.1 GB today on this network (893.6 MB down, 203.8 MB up), 2.9 GB on all networks.
    static let sample = EngineStatus(
        todayNetworkInterfaces: ByteCounts(rx: 893_600_000, tx: 203_800_000),
        todayInterfaces: ByteCounts(rx: 2_370_000_000, tx: 500_000_000),
        speed: ByteCounts(rx: 137_000, tx: 42_000))

    var body: some View {
        HStack(spacing: 14) {
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: display.symbol)
                if display.lines.count > 1 {
                    VStack(alignment: .trailing, spacing: -1) {
                        ForEach(display.lines.indices, id: \.self) { Text(display.lines[$0]) }
                    }
                    .font(Font(MenuBarDisplay.stackedFont))
                } else if let text = display.text {
                    Text(text)
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(.primary.opacity(0.12), in: .rect(cornerRadius: 5))
            .fixedSize()
            .accessibilityElement(children: .combine)
            .accessibilityLabel(display.accessibilityLabel(debug: false))
            Image(systemName: "battery.75percent").foregroundStyle(.secondary)
            Text(now.formatted(.dateTime.weekday().hour().minute()))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .font(.system(size: 13)).monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(.bar, in: .rect(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        .help("How the menu bar item looks with this design")
    }
}
