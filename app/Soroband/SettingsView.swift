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
                requestLocation: { LocationAccess.shared.request() },
                save: { usage.updateNetwork(id: $0, name: $1, kind: $2) }
            )
            .tabItem { Label("Networks", systemImage: "wifi") }
            .tag(Tab.networks)
        }
        .frame(width: 560, height: 380)
    }
}

struct GeneralSettings: View {
    let usage: Usage
    let launchAtLogin: LaunchAtLogin

    var body: some View {
        Form {
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

    static func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        let date = Calendar.current.date(from: components) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }
}

struct NetworkSettings: View {
    let networks: [RegisteredNetwork]
    let location: CLAuthorizationStatus
    let requestLocation: () -> Void
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
                LocationRow(status: location, request: requestLocation)
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
    let request: () -> Void

    var body: some View {
        LabeledContent {
            switch status {
            case .notDetermined:
                Button("Allow Location Access…", action: request)
            case .authorizedAlways, .authorizedWhenInUse:
                Text("Allowed").foregroundStyle(.secondary)
            default:
                Button("Open Location Settings…") {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!
                    )
                }
            }
        } label: {
            Text("Wi‑Fi names")
            Text("macOS shows Wi‑Fi names only to apps with Location access. Soroband never reads where you are.")
        }
    }
}
