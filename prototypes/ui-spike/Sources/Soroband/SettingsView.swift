import SwiftUI

struct SettingsView: View {
    @State var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            IslandSettings().tabItem { Label("Island", systemImage: "capsule.tophalf.filled") }.tag("island")
            NetworkSettings().tabItem { Label("Networks", systemImage: "wifi") }.tag("networks")
            DataSettings().tabItem { Label("Data", systemImage: "externaldrive") }.tag("data")
        }
        .frame(width: 560, height: tab == "island" ? 640 : 380)
    }
}

private struct IslandSettings: View {
    @Environment(IslandModel.self) private var island

    var body: some View {
        @Bindable var island = island
        Form {
            Section {
                Toggle(isOn: $island.enabled) {
                    Text("Show moments in the Dynamic Island")
                    Text("Short updates that grow from the notch, below the menu bar. The menu bar item always stays.")
                }
                if island.enabled {
                    Picker("Style", selection: $island.seamless) {
                        Text("Seamless: covers the menu bar next to the notch while open").tag(true)
                        Text("Keep menu bar clear: widens only below the menu bar").tag(false)
                    }
                    .pickerStyle(.radioGroup)
                } else {
                    Toggle("Send alerts as notifications instead", isOn: $island.notificationsWhenOff)
                }
            }
            Section("Moments") {
                ForEach(MomentKind.allCases) { kind in
                    Toggle(isOn: island.binding(for: kind)) {
                        Label {
                            Text(kind.title)
                            Text(kind.detail)
                        } icon: {
                            Image(systemName: kind.symbol)
                        }
                    }
                    if island.enabledKinds.contains(kind) { thresholds(for: kind, island: $island) }
                }
            }
            .disabled(!island.enabled)
            Section("Behavior") {
                Toggle("Hide during full-screen apps", isOn: $island.hideInFullScreen)
                Toggle("Still show alerts in full screen", isOn: $island.alertsInFullScreen)
                    .disabled(!island.hideInFullScreen)
                Toggle("Offer “Pause until off hotspot” (quits the app, reopens it later)", isOn: $island.offerPause)
                Picker("Show on", selection: $island.allDisplays) {
                    Text("Built-in display").tag(false)
                    Text("All displays").tag(true)
                }
            }
            .disabled(!island.enabled)
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func thresholds(for kind: MomentKind, island: Bindable<IslandModel>) -> some View {
        switch kind {
        case .dataHog:
            HStack {
                Text("When one app uses more than").foregroundStyle(.secondary)
                Stepper("\(island.wrappedValue.hogThresholdMB) MB", value: island.hogThresholdMB, in: 10...2000, step: 10).fixedSize()
                Text("in").foregroundStyle(.secondary)
                Stepper("\(island.wrappedValue.hogWindowMinutes) min", value: island.hogWindowMinutes, in: 1...60).fixedSize()
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 28)
        case .backgroundActivity:
            HStack {
                Text("When more than").foregroundStyle(.secondary)
                Stepper("\(island.wrappedValue.backgroundThresholdMB) MB", value: island.backgroundThresholdMB, in: 5...1000, step: 5).fixedSize()
                Text("moves with no app in front").foregroundStyle(.secondary)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 28)
        case .bigTransfer:
            HStack {
                Text("Transfers larger than").foregroundStyle(.secondary)
                Stepper("\(island.wrappedValue.transferThresholdMB) MB", value: island.transferThresholdMB, in: 10...5000, step: 10).fixedSize()
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 28)
        default:
            EmptyView()
        }
    }
}

private struct GeneralSettings: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Picker("Menu bar shows", selection: $store.menuBarMode) {
                ForEach(MenuBarMode.allCases) { Text($0.label).tag($0) }
            }
            Picker("Daily counter resets at", selection: $store.resetHour) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now)!
                        .formatted(date: .omitted, time: .shortened)).tag(hour)
                }
            }
            Text("Resetting only clears today's counter. Every day stays in History.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Launch at login", isOn: $store.launchAtLogin)
        }
        .formStyle(.grouped)
    }
}

private struct NetworkSettings: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                ForEach($store.networks) { $net in
                    HStack {
                        Image(systemName: net.kind.symbol).foregroundStyle(net.tint).frame(width: 18)
                        TextField("Name", text: $net.name).labelsHidden()
                        Picker("Type", selection: $net.kind) {
                            ForEach(NetworkKind.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 100)
                    }
                }
            } footer: {
                Text("Rename a network or fix a misdetected type.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DataSettings: View {
    var body: some View {
        Form {
            LabeledContent("History", value: "Kept forever, hourly per app per network")
            LabeledContent("Database size", value: "3.2 MB")
            HStack {
                Button("Export CSV…") {}
                Button("Show Database in Finder") {}
            }
        }
        .formStyle(.grouped)
    }
}
