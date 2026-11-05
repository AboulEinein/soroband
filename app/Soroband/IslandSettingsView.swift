import SwiftUI

/// Settings › Island, in the UI process: the master switch, the style, each moment with its
/// threshold, and how the island behaves. Every change goes to the core's settings at once
/// (`Usage.setSetting`), as `soroband config set` would.
struct IslandSettingsView: View {
    let settings: IslandSettings
    let set: (String, String) -> Void

    var body: some View {
        SettingsPage(
            title: "Island",
            subtitle: "Short moments that grow from the notch. The menu bar item always stays."
        ) {
            SettingsSection {
                SettingsCard {
                    SettingsRow(
                        title: "Show moments at the notch",
                        detail: settings.enabled ? nil : "Off, Soroband is a plain menu bar app."
                    ) {
                        toggle(IslandSettings.enabledKey, settings.enabled)
                    }
                    Divider().padding(.leading, 14)
                    if settings.enabled {
                        SettingsRow(title: "Style", detail: styleNote) {
                            Picker("Style", selection: binding(IslandSettings.styleKey, settings.style.rawValue)) {
                                Text("Seamless").tag(IslandSettings.Style.seamless.rawValue)
                                Text("Keep menu bar clear").tag(IslandSettings.Style.clear.rawValue)
                            }
                            .labelsHidden().pickerStyle(.segmented).fixedSize()
                        }
                    } else {
                        SettingsRow(
                            title: "Send alerts as notifications",
                            detail: "A data hog or background activity still tells you, as a notification."
                        ) {
                            toggle(IslandSettings.notificationsKey, settings.notifications)
                        }
                    }
                }
            }
            SettingsSection(title: "Moments") {
                SettingsCard {
                    ForEach(Array(MomentKind.allCases.enumerated()), id: \.element) { index, kind in
                        if index > 0 { Divider().padding(.leading, 14) }
                        SettingsRow(title: kind.title, detail: kind.detail) {
                            toggle(
                                IslandSettings.momentsKey, settings.moments.contains(kind),
                                value: { on in Self.moments(settings.moments, kind, on) })
                        }
                        .disabled(!settings.enabled && !(kind.isAlert && settings.notifications))
                        if settings.moments.contains(kind) { threshold(kind) }
                    }
                }
            }
            SettingsSection(title: "Behavior") {
                SettingsCard {
                    SettingsRow(title: "While an app is full screen") {
                        Picker(
                            "While an app is full screen",
                            selection: binding(IslandSettings.fullScreenKey, settings.fullScreen.rawValue)
                        ) {
                            Text("Hide the island").tag(IslandSettings.FullScreen.hide.rawValue)
                            Text("Show alerts only").tag(IslandSettings.FullScreen.alerts.rawValue)
                            Text("Show every moment").tag(IslandSettings.FullScreen.all.rawValue)
                        }
                        .labelsHidden().fixedSize()
                    }
                    Divider().padding(.leading, 14)
                    SettingsRow(
                        title: "Offer “Pause until off hotspot”",
                        detail: "A data hog on a hotspot can quit the app; it opens again on the next network."
                    ) {
                        toggle(IslandSettings.pauseKey, settings.offersPause)
                    }
                    Divider().padding(.leading, 14)
                    SettingsRow(title: "Show on") {
                        Picker("Show on", selection: binding(IslandSettings.displaysKey, settings.displays.rawValue)) {
                            Text("Built-in display").tag(IslandSettings.Displays.builtin.rawValue)
                            Text("All displays").tag(IslandSettings.Displays.all.rawValue)
                        }
                        .labelsHidden().fixedSize()
                    }
                }
                .disabled(!settings.enabled)
            }
            if !settings.ignoredApps.isEmpty {
                SettingsSection(title: "Ignored apps", footer: "These apps raise no moment.") {
                    SettingsCard {
                        ForEach(Array(settings.ignoredApps.enumerated()), id: \.element) { index, app in
                            if index > 0 { Divider().padding(.leading, 14) }
                            SettingsRow(title: Self.name(of: app), detail: app) {
                                Button("Remove") {
                                    set(
                                        IslandSettings.ignoredAppsKey,
                                        IslandSettings.ignoredValue(settings.ignoredApps.filter { $0 != app }))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var styleNote: String {
        settings.style == .seamless
            ? "Covers the menu bar beside the notch while a moment is open."
            : "Stays notch-wide in the menu bar and widens only below it."
    }

    @ViewBuilder
    private func threshold(_ kind: MomentKind) -> some View {
        switch kind {
        case .hog:
            thresholdRow {
                Text("When one app uses more than")
                stepper(IslandSettings.hogMBKey, settings.hogMB, unit: "MB", range: 10...10_000, step: 10)
                Text("in")
                stepper(IslandSettings.hogMinutesKey, settings.hogMinutes, unit: "min", range: 1...60, step: 1)
            }
        case .background:
            thresholdRow {
                Text("When an app not in front uses more than")
                stepper(IslandSettings.backgroundMBKey, settings.backgroundMB, unit: "MB", range: 10...10_000, step: 10)
                Text("in \(settings.hogMinutes) min")
            }
        case .transfer:
            thresholdRow {
                Text("Transfers larger than")
                stepper(IslandSettings.transferMBKey, settings.transferMB, unit: "MB", range: 10...100_000, step: 10)
            }
        default:
            EmptyView()
        }
    }

    private func thresholdRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) { content() }
            .font(.callout).foregroundStyle(.secondary)
            .padding(.leading, 28).padding(.trailing, 14).padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stepper(_ key: String, _ value: Int, unit: String, range: ClosedRange<Int>, step: Int) -> some View {
        Stepper(
            "\(value) \(unit)",
            value: Binding(get: { value }, set: { set(key, String($0)) }), in: range, step: step
        )
        .foregroundStyle(.primary).monospacedDigit().fixedSize()
    }

    private func toggle(_ key: String, _ isOn: Bool, value: ((Bool) -> String)? = nil) -> some View {
        Toggle(key, isOn: Binding(get: { isOn }, set: { set(key, value?($0) ?? ($0 ? "on" : "off")) }))
            .toggleStyle(.switch).labelsHidden()
    }

    private func binding(_ key: String, _ value: String) -> Binding<String> {
        Binding(get: { value }, set: { set(key, $0) })
    }

    /// The moments' value with `kind` turned on or off.
    static func moments(_ moments: Set<MomentKind>, _ kind: MomentKind, _ on: Bool) -> String {
        var settings = IslandSettings()
        settings.moments = on ? moments.union([kind]) : moments.subtracting([kind])
        return settings.momentsValue
    }

    /// An app's name from its id: the bundle's or tool's file name.
    static func name(of id: String) -> String {
        guard id.hasPrefix("/") else { return id.replacingOccurrences(of: "process:", with: "") }
        return URL(filePath: id).deletingPathExtension().lastPathComponent
    }
}
