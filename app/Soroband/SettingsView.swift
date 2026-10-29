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
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
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
    enum Tab: String, CaseIterable {
        case general, networks
    }

    @Bindable var selection: SettingsWindow.Selection
    var usage = Usage.shared

    var body: some View {
        TabView(selection: $selection.tab) {
            GeneralSettings(usage: usage, launchAtLogin: .shared)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            NetworkSettings(
                networks: usage.registry, location: LocationAccess.shared.status,
                allowLocation: { LocationAccess.shared.allow() },
                save: { usage.updateNetwork(id: $0, name: $1, kind: $2) }
            )
            .tabItem { Label("Networks", systemImage: "wifi") }
            .tag(Tab.networks)
        }
        .frame(width: 560, height: 440)
    }
}

struct GeneralSettings: View {
    let usage: Usage
    let launchAtLogin: LaunchAtLogin
    /// The preview's clock.
    var now = Date.now

    var body: some View {
        Form {
            Section {
                MenuBarPreview(
                    display: MenuBarDisplay.make(
                        mode: usage.menuBarMode, count: usage.menuBarCount, status: previewStatus,
                        kind: NetworkMonitor.shared.current?.kind ?? .wifi), now: now)
            } header: {
                Text("Preview")
            }
            Picker("Menu bar shows", selection: Binding(get: { usage.menuBarMode }, set: { usage.setMenuBarMode($0) }))
            {
                ForEach(MenuBarMode.allCases) { Text($0.label).tag($0) }
            }
            if usage.menuBarMode == .todayNetwork || usage.menuBarMode == .todayAll {
                Picker(
                    "Count", selection: Binding(get: { usage.menuBarCount }, set: { usage.setMenuBarCount($0) })
                ) {
                    ForEach(MenuBarCount.allCases) { Text($0.label).tag($0) }
                }
            }
            if usage.menuBarMode == .speed {
                Text(
                    "Live speed changes the menu bar at every count, every 5 seconds, which uses more energy than a daily total."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Picker(
                "Daily counter resets at", selection: Binding(get: { usage.resetHour }, set: { usage.setResetHour($0) })
            ) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(Self.hourLabel(hour)).tag(hour)
                }
            }
            Text("Resetting only clears today's counter. Every day stays in History.")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                // Closures, not method references: Swift 6.3 (Xcode 26) crashes compiling a main-actor
                // method passed where a plain function is expected.
                Toggle(
                    "Launch at login", isOn: Binding(get: { launchAtLogin.state.isOn }, set: { launchAtLogin.set($0) }))
                if let note = launchAtLogin.state.note {
                    HStack {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                        if launchAtLogin.needsApproval {
                            Button("Open Login Items…") { launchAtLogin.openLoginItems() }
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Today's numbers, or sample ones before the engine has counted anything to show.
    private var previewStatus: EngineStatus {
        usage.status.state == .starting ? MenuBarPreview.sample : usage.status
    }

    static func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        let date = Calendar.current.date(from: components) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }
}

/// The menu bar item as the chosen settings draw it, on a strip like the menu bar, beside a
/// clock for scale.
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
                if let text = display.text { Text(text) }
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
        .frame(height: 26)
        .background(.bar, in: .rect(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        .help("How the menu bar item looks with these settings")
    }
}

struct NetworkSettings: View {
    let networks: [RegisteredNetwork]
    let location: CLAuthorizationStatus
    let allowLocation: () -> Void
    let save: (_ id: Int64, _ name: String, _ kind: NetworkKind) -> Void

    var body: some View {
        Form {
            Section {
                if networks.isEmpty {
                    Text("No network seen yet.").foregroundStyle(.secondary)
                }
                ForEach(Array(networks.enumerated()), id: \.element.id) { index, network in
                    NetworkEditor(network: network, slot: NetworkColor.slot(forIndex: index)) { name, kind in
                        save(network.id, name, kind)
                    }
                }
            } footer: {
                Text("Rename a network or fix a misdetected type. Press Return to save a name.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LocationRow(status: location, allow: allowLocation)
            }
        }
        .formStyle(.grouped)
    }
}

private struct NetworkEditor: View {
    let network: RegisteredNetwork
    let slot: Int
    let save: (String, NetworkKind) -> Void
    @State private var name = ""

    var body: some View {
        HStack {
            Image(systemName: network.kind.symbol).foregroundStyle(NetworkColor.color(slot: slot)).frame(width: 18)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .onSubmit {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty { name = network.name } else { save(trimmed, network.kind) }
                }
            Picker("Type", selection: Binding(get: { network.kind }, set: { save(network.name, $0) })) {
                ForEach(NetworkKind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(width: 110)
        }
        .onAppear { name = network.name }
        .onChange(of: network.name) { name = network.name }
    }
}

/// The Location permission, which names Wi‑Fi networks.
struct LocationRow: View {
    let status: CLAuthorizationStatus
    /// `LocationAccess.allow`: asks macOS, or opens System Settings once the user has answered.
    let allow: () -> Void

    var body: some View {
        LabeledContent {
            switch status {
            case .notDetermined:
                Button("Allow Location Access…", action: allow)
            case .authorizedAlways, .authorizedWhenInUse:
                Text("Allowed").foregroundStyle(.secondary)
            default:
                Button("Open Location Settings…", action: allow)
            }
        } label: {
            Text("Wi‑Fi names")
            Text("macOS shows Wi‑Fi names only to apps with Location access. Soroband never reads where you are.")
        }
    }
}
