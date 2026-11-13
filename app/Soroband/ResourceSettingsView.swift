import SwiftUI

/// Settings › Resources (`docs/mockups/resources.html`, 5A and 6A): which resources are metered,
/// how long the minute record is kept, how each resource reads, and where the resource read comes
/// from. Every change goes to the core's settings at once (`Usage.setSetting`).
struct ResourceSettingsView: View {
    let settings: ResourceSettings
    let gauges: Gauges
    let set: (String, String) -> Void
    /// The local volumes the disk reading can show, by mount point and name.
    var volumes: [(path: String, name: String)] = ResourceSettingsView.localVolumes()

    var body: some View {
        SettingsPage(
            title: "Resources",
            subtitle: "CPU, memory, disk and energy per app, kept as long as the internet bytes."
        ) {
            SettingsSection {
                SettingsCard {
                    SettingsRow(
                        title: "Meter resources",
                        detail: settings.metered
                            ? "Each app’s resources once a minute, and the Mac’s gauges at every poll."
                            : "Off: nothing is read, and no resource shows in the popover, History or the menu bar."
                    ) {
                        toggle("Meter resources", ResourceSettings.meteredKey, settings.metered) { $0 ? "on" : "off" }
                    }
                    ForEach(ResourceMeasure.allCases) { measure in
                        Divider().padding(.leading, 14)
                        SettingsRow(title: measure.label) {
                            toggle(measure.label, ResourceSettings.measuresKey, settings.measures.contains(measure)) {
                                Self.measures(settings.measures, measure, $0)
                            }
                        }
                        .overlay(alignment: .leading) {
                            Circle().fill(measure.color).frame(width: 7, height: 7).offset(x: 4)
                        }
                        .disabled(!settings.metered)
                    }
                }
            }
            SettingsSection(
                title: "Minute by minute",
                footer: "History’s Day page shows each minute, and the busiest apps in it, for the days kept."
            ) {
                SettingsCard {
                    SettingsRow(
                        title: "Keep minute by minute for",
                        detail: "Hourly resources are kept forever. About 0.6 MB a day."
                    ) {
                        Stepper(
                            "\(settings.minutesDays) day\(settings.minutesDays == 1 ? "" : "s")",
                            value: Binding(
                                get: { settings.minutesDays },
                                set: { set(ResourceSettings.minutesDaysKey, String($0)) }), in: 1...90
                        )
                        .monospacedDigit()
                    }
                }
            }
            .disabled(!settings.metered)
            SettingsSection(
                title: "Show",
                footer: "One setting per resource, for the popover’s gauges, the menu bar and the minute chart."
            ) {
                SettingsCard {
                    SettingsRow(title: "CPU", detail: "Share of all cores, or how many cores’ worth is busy") {
                        picker(
                            "CPU", ResourceSettings.cpuKey, settings.cpu.rawValue,
                            [("percent", "Percent"), ("cores", "Cores")])
                    }
                    Divider().padding(.leading, 14)
                    SettingsRow(title: "Memory", detail: memoryNote) {
                        HStack(spacing: 6) {
                            picker(
                                "Memory", ResourceSettings.memoryKey, settings.memory.rawValue,
                                [("used", "Used"), ("free", "Free"), ("pressure", "Pressure")])
                            picker(
                                "Memory unit", ResourceSettings.memoryUnitKey,
                                settings.memory == .pressure ? "percent" : settings.memoryUnit.rawValue,
                                [("amount", "Amount"), ("percent", "Percent")]
                            )
                            .disabled(settings.memory == .pressure)
                        }
                    }
                    Divider().padding(.leading, 14)
                    SettingsRow(title: "Disk") {
                        HStack(spacing: 6) {
                            picker(
                                "Disk", ResourceSettings.diskKey, settings.disk.rawValue,
                                [("used", "Used"), ("free", "Free")])
                            picker(
                                "Disk unit", ResourceSettings.diskUnitKey, settings.diskUnit.rawValue,
                                [("amount", "Amount"), ("percent", "Percent")])
                        }
                    }
                    Divider().padding(.leading, 14)
                    SettingsRow(title: "Disk volume", detail: volumeNote) {
                        Picker(
                            "Disk volume",
                            selection: Binding(
                                get: { settings.diskVolume }, set: { set(ResourceSettings.diskVolumeKey, $0) })
                        ) {
                            ForEach(volumeChoices, id: \.path) { Text($0.name).tag($0.path) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    Divider().padding(.leading, 14)
                    SettingsRow(title: "Preview", detail: "Popover gauges and the menu bar, as set") {
                        HStack(spacing: 12) {
                            ForEach([ResourceMeasure.cpu, .memory, .disk]) { measure in
                                if let reading = settings.reading(measure, gauges: previewGauges) {
                                    VStack(alignment: .trailing, spacing: 0) {
                                        Text(reading.caption).font(.system(size: 7, weight: .semibold)).opacity(0.75)
                                        Text(reading.value).font(.system(size: 12, weight: .medium)).monospacedDigit()
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .disabled(!settings.metered)
            SettingsSection(title: "Source") {
                SettingsCard {
                    SettingsRow(title: "Read from", detail: sourceNote) {
                        if gauges.fallback {
                            Label("Your processes only", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                        } else if gauges.on {
                            Label("Coalitions", systemImage: "checkmark").foregroundStyle(.secondary)
                        } else {
                            Text("–").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    /// The gauges now, or the mockup's while the meter has not read any.
    private var previewGauges: Gauges { gauges.on ? gauges : MenuBarPreview.sampleGauges }

    private var memoryNote: String? {
        settings.memory == .pressure ? "Pressure is the share of memory macOS does not count as available." : nil
    }

    private var volumeNote: String {
        volumes.contains { $0.path == settings.diskVolume }
            ? "Local volumes Soroband sees"
            : "Not mounted: the start-up disk shows until it is."
    }

    /// The volumes, with the one set kept in the list while it is not mounted.
    private var volumeChoices: [(path: String, name: String)] {
        volumes.contains { $0.path == settings.diskVolume }
            ? volumes : volumes + [(settings.diskVolume, URL(filePath: settings.diskVolume).lastPathComponent)]
    }

    private var sourceNote: String {
        if gauges.fallback {
            return
                "macOS did not allow Soroband to read every app’s resources, so apps run as root or by other users are left out. The hours read this way are marked in History."
        }
        return "Every app’s coalition, root and other users included."
    }

    private func toggle(_ label: String, _ key: String, _ isOn: Bool, value: @escaping (Bool) -> String)
        -> some View
    {
        Toggle(label, isOn: Binding(get: { isOn }, set: { set(key, value($0)) }))
            .toggleStyle(.switch).labelsHidden()
    }

    private func picker(_ label: String, _ key: String, _ value: String, _ options: [(String, String)]) -> some View {
        Picker(label, selection: Binding(get: { value }, set: { set(key, $0) })) {
            ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
    }

    /// `measures` with `measure` turned on or off, as the core stores them.
    static func measures(_ measures: [ResourceMeasure], _ measure: ResourceMeasure, _ on: Bool) -> String {
        var settings = ResourceSettings()
        settings.measures = ResourceMeasure.allCases.filter { $0 == measure ? on : measures.contains($0) }
        return settings.measuresValue
    }

    /// The local volumes a person sees in the Finder, the start-up disk first.
    static func localVolumes() -> [(path: String, name: String)] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsLocalKey]
        let urls =
            FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes])
            ?? []
        let volumes = urls.compactMap { url -> (path: String, name: String)? in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.volumeIsLocal != false else { return nil }
            return (url.path, values?.volumeName ?? url.lastPathComponent)
        }
        return volumes.filter { $0.path == ResourceSettings.startupVolume }
            + volumes.filter { $0.path != ResourceSettings.startupVolume }
    }
}
