import AppKit
import CoreLocation
import SwiftUI

/// The Settings window, created when it opens and released when it closes.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()

    @Observable
    final class Selection {
        var tab = SettingsView.Tab.general
    }

    private(set) var window: NSWindow?
    private let selection = Selection()

    func show(tab: SettingsView.Tab? = nil) {
        if let tab { selection.tab = tab }
        if window == nil {
            Usage.shared.reloadRegistry()
            LaunchAtLogin.shared.refresh()
            let window = NSWindow(
                contentViewController: NSHostingController(rootView: SettingsView(selection: selection)))
            window.title = "Soroband Settings"
            // The sidebar runs the window's full height, under the traffic lights, as in System
            // Settings.
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            // Otherwise AppKit focuses the first text field, a network's name, as if to rename it.
            window.makeFirstResponder(nil)
            return
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    var tab: SettingsView.Tab { selection.tab }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

struct SettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general
        case menuBar = "menu-bar"
        case networks
        case about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "General"
            case .menuBar: "Menu Bar"
            case .networks: "Networks"
            case .about: "About"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape.fill"
            case .menuBar: "menubar.rectangle"
            case .networks: "wifi"
            case .about: "info"
            }
        }

        /// The sidebar tile's color, as System Settings colors its panes.
        var tint: Color {
            switch self {
            case .general: .gray
            case .menuBar: .blue
            case .networks: .green
            case .about: Color(white: 0.4)
            }
        }
    }

    @Bindable var selection: SettingsWindow.Selection
    var usage = Usage.shared

    var body: some View {
        NavigationSplitView {
            List(
                Tab.allCases,
                selection: Binding(get: { selection.tab }, set: { if let tab = $0 { selection.tab = tab } })
            ) { tab in
                Label {
                    Text(tab.title)
                } icon: {
                    SettingsTile(symbol: tab.symbol, tint: tab.tint)
                }
                .tag(tab)
            }
            .safeAreaInset(edge: .bottom) {
                Label("Nothing leaves this Mac.", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .navigationSplitViewColumnWidth(200)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            switch selection.tab {
            case .general:
                GeneralSettings(usage: usage, launchAtLogin: .shared)
            case .menuBar:
                MenuBarSettings(usage: usage)
            case .networks:
                NetworkSettings(
                    networks: usage.registry, current: NetworkMonitor.shared.current?.id,
                    save: { usage.updateNetwork(id: $0, name: $1, kind: $2) },
                    setColor: { usage.setNetworkColor(id: $0, color: $1) })
            case .about:
                AboutSettings()
            }
        }
        .navigationTitle(selection.tab.title)
        .frame(width: 760, height: 600)
    }
}

/// A white symbol on a small rounded square of color, as System Settings marks its panes.
struct SettingsTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: .rect(cornerRadius: size * 0.26))
    }
}

/// A Settings page: a large title and a line under it, then its sections, scrolling.
struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 22, weight: .bold))
                    Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                content
            }
            .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A titled group of rows on a card, as a grouped form draws it.
struct SettingsSection<Content: View>: View {
    var title: String?
    var trailing: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if title != nil || trailing != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title { Text(title).font(.headline) }
                    Spacer()
                    if let trailing { Text(trailing).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                }
                .padding(.horizontal, 4)
            }
            content
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// The card behind a group of rows.
struct SettingsCard<Content: View>: View {
    var padding: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SettingsColor.card, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
    }
}

/// One row of a card: a label and its explanation on the left, a control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(minHeight: 44)
    }
}

enum SettingsColor {
    /// White cards on the light window; a lifted gray on the dark one.
    static let card = Color(
        nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.055) : NSColor(white: 1, alpha: 1)
        })
}

struct GeneralSettings: View {
    let usage: Usage
    let launchAtLogin: LaunchAtLogin
    var location = LocationAccess.shared
    /// The Location permission shown; the real one when nil.
    var locationStatus: CLAuthorizationStatus?

    var body: some View {
        SettingsPage(title: "General", subtitle: "When a day starts, how Soroband starts, and what macOS lets it see.")
        {
            SettingsSection(
                title: "Day",
                footer:
                    "Night owl? Start the day at 4 AM so a late night counts toward the day it began. History keeps every hour, so this changes only what “today” means."
            ) {
                SettingsCard {
                    SettingsRow(title: "A new day starts at", detail: Self.resetNote(usage.resetHour)) {
                        Picker(
                            "A new day starts at",
                            selection: Binding(get: { usage.resetHour }, set: { usage.setResetHour($0) })
                        ) {
                            ForEach(0..<24, id: \.self) { Text(Self.hourLabel($0)).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    DayRuler(resetHour: usage.resetHour)
                        .padding(.horizontal, 14).padding(.bottom, 12)
                }
            }
            SettingsSection(title: "Startup") {
                SettingsCard {
                    SettingsRow(
                        title: "Open at login",
                        detail: launchAtLogin.state.note ?? "Soroband counts only while it is running."
                    ) {
                        HStack {
                            if launchAtLogin.needsApproval {
                                // Closures, not method references: Swift 6.3 (Xcode 26) crashes compiling
                                // a main-actor method passed where a plain function is expected.
                                Button("Open Login Items…") { launchAtLogin.openLoginItems() }
                            }
                            Toggle(
                                "Open at login",
                                isOn: Binding(get: { launchAtLogin.state.isOn }, set: { launchAtLogin.set($0) })
                            )
                            .toggleStyle(.switch).labelsHidden()
                        }
                    }
                }
            }
            SettingsSection(title: "Wi‑Fi names") {
                SettingsCard {
                    LocationRow(status: locationStatus ?? location.status, allow: { location.allow() })
                }
            }
            SettingsSection(title: "Your data") {
                SettingsCard {
                    HStack(spacing: 12) {
                        Image(systemName: "cylinder.split.1x2")
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .background(.quaternary, in: .rect(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Bytes per app, per network, per hour")
                            Text("Stored on this Mac. No packet contents, no addresses, nothing sent anywhere.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([Core.dataDirectory])
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                }
            }
        }
    }

    static func resetNote(_ hour: Int) -> String {
        hour == 0
            ? "Today’s counts go back to zero at midnight."
            : "Until \(hourLabel(hour)), usage counts toward the day before."
    }

    static func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        let date = Calendar.current.date(from: components) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }
}

/// A clock day from midnight to midnight, its hours before the reset hour marked as the day
/// before's.
struct DayRuler: View {
    let resetHour: Int

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 3) {
                ForEach(0..<24, id: \.self) { hour in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(hour < resetHour ? Color.orange.opacity(0.75) : Color.accentColor.opacity(0.8))
                        .frame(height: hour == resetHour ? 22 : 12)
                }
            }
            .frame(height: 22, alignment: .bottom)
            HStack {
                ForEach([0, 6, 12, 18], id: \.self) { hour in
                    Text(GeneralSettings.hourLabel(hour)).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            if resetHour > 0 {
                HStack(spacing: 12) {
                    Label("The day before", systemImage: "circle.fill").foregroundStyle(.orange)
                    Label("Today", systemImage: "circle.fill").foregroundStyle(Color.accentColor)
                    Spacer()
                }
                .font(.caption2).labelStyle(DotLabelStyle())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(GeneralSettings.resetNote(resetHour))
    }
}

/// A small colored dot before a secondary label.
private struct DotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 6))
            configuration.title.foregroundStyle(.secondary)
        }
    }
}

/// The Location permission, which names Wi‑Fi networks.
struct LocationRow: View {
    let status: CLAuthorizationStatus
    /// `LocationAccess.allow`: asks macOS, or opens System Settings once the user has answered.
    let allow: () -> Void

    private var isAllowed: Bool {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: true
        default: false
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SettingsTile(symbol: "location.fill", tint: .blue, size: 30)
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Location access")
                    Text(
                        "macOS shows Wi‑Fi names only to apps it trusts with Location. Soroband asks for it to tell your networks apart by name and never reads where you are."
                    )
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 5) {
                    Circle().fill(isAllowed ? Color.green : Color.secondary).frame(width: 7, height: 7)
                    Text(
                        isAllowed
                            ? "Allowed: Wi‑Fi networks show their names" : "Not allowed: Wi‑Fi networks show as “Wi‑Fi”"
                    )
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            switch status {
            case .notDetermined: Button("Allow…", action: allow)
            case .authorizedAlways, .authorizedWhenInUse: EmptyView()
            default: Button("Open Location Settings…", action: allow)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }
}

struct NetworkSettings: View {
    let networks: [RegisteredNetwork]
    /// The network the Mac is on.
    let current: Int64?
    let save: (_ id: Int64, _ name: String, _ kind: NetworkKind) -> Void
    /// Sets a network's palette slot, or nil for its place's.
    let setColor: (_ id: Int64, _ color: Int?) -> Void
    var now = Date.now

    var body: some View {
        SettingsPage(
            title: "Networks",
            subtitle:
                "Every network your Mac has used the internet on. A network keeps its name and color everywhere in Soroband."
        ) {
            SettingsSection(
                title: "Known networks",
                footer:
                    "Click a name to rename it, then press Return. Click the icon to change its color. Change the kind if macOS guessed wrong: a hotspot is a network you may pay for by the byte."
            ) {
                SettingsCard {
                    if networks.isEmpty {
                        Text("No network seen yet.").foregroundStyle(.secondary).padding(14)
                    }
                    ForEach(Array(networks.enumerated()), id: \.element.id) { index, network in
                        if index > 0 { Divider().padding(.leading, 55) }
                        NetworkEditor(
                            network: network, slot: NetworkColor.slot(for: network, index: index),
                            automaticSlot: NetworkColor.slot(for: RegisteredNetwork.unpicked(network), index: index),
                            isCurrent: network.id == current, now: now,
                            save: { save(network.id, $0, $1) }, setColor: { setColor(network.id, $0) })
                    }
                }
            }
        }
    }
}

private struct NetworkEditor: View {
    let network: RegisteredNetwork
    let slot: Int
    /// The slot it takes without a pick.
    let automaticSlot: Int
    let isCurrent: Bool
    let now: Date
    let save: (String, NetworkKind) -> Void
    let setColor: (Int?) -> Void
    @State private var name = ""
    @State private var picksColor = false

    private var subtitle: String {
        guard let lastUsed = network.lastUsed else { return "Never used" }
        let date = Date(timeIntervalSince1970: TimeInterval(lastUsed))
        return "Last used \(date.formatted(.relative(presentation: .named, unitsStyle: .wide)))"
    }

    var body: some View {
        HStack(spacing: 11) {
            Button {
                picksColor = true
            } label: {
                SettingsTile(symbol: network.kind.symbol, tint: NetworkColor.color(slot: slot), size: 30)
            }
            .buttonStyle(.plain)
            .help("Change the color of \(network.name)")
            .accessibilityLabel("Color of \(network.name): \(NetworkColor.names[slot])")
            .popover(isPresented: $picksColor, arrowEdge: .bottom) {
                NetworkColorPicker(slot: slot, automaticSlot: automaticSlot, isPicked: network.color != nil) { color in
                    setColor(color)
                    picksColor = false
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                    .onSubmit {
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        if trimmed.isEmpty { name = network.name } else { save(trimmed, network.kind) }
                    }
                if isCurrent {
                    Text("Connected")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.green)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.green.opacity(0.14), in: .capsule)
                } else {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Picker("Kind", selection: Binding(get: { network.kind }, set: { save(network.name, $0) })) {
                ForEach(NetworkKind.allCases, id: \.self) { Label($0.label, systemImage: $0.symbol).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .onAppear { name = network.name }
        .onChange(of: network.name) { name = network.name }
    }
}

/// The palette's swatches, and Automatic for the color of the network's place in the list.
struct NetworkColorPicker: View {
    let slot: Int
    let automaticSlot: Int
    let isPicked: Bool
    let pick: (Int?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The color by name: some slots are low-contrast in light mode, so no swatch stands
            // without a label.
            Text("Color: \(NetworkColor.names[slot])")
                .font(.caption.weight(.semibold))
            HStack(spacing: 8) {
                ForEach(NetworkColor.slots.indices, id: \.self) { index in
                    Button {
                        pick(index)
                    } label: {
                        Circle()
                            .fill(NetworkColor.slots[index])
                            .frame(width: 20, height: 20)
                            .padding(3)
                            .overlay(Circle().strokeBorder(.secondary, lineWidth: isPicked && index == slot ? 2 : 0))
                    }
                    .buttonStyle(.plain)
                    .help(NetworkColor.names[index])
                    .accessibilityLabel(NetworkColor.names[index])
                    .accessibilityAddTraits(isPicked && index == slot ? .isSelected : [])
                }
            }
            Button {
                pick(nil)
            } label: {
                Label(
                    "Automatic (\(NetworkColor.names[automaticSlot]))",
                    systemImage: isPicked ? "circle" : "checkmark.circle.fill")
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
    }
}

struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Soroband").font(.system(size: 22, weight: .bold)).padding(.top, 8)
            Text("Version \(Self.version) · core \(Core.version)")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            Text(
                "Counts the internet your Mac uses, per app and per network. Counters and metadata only; nothing leaves this Mac."
            )
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 340)
            .padding(.vertical, 14)
            Link("Soroband on GitHub", destination: URL(string: "https://github.com/AboulEinein/soroband")!)
            Text("The name: soroban, the Japanese abacus, plus bandwidth.")
                .font(.caption).foregroundStyle(.tertiary).padding(.top, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
}
