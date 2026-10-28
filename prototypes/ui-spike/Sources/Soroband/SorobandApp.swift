import SwiftUI

@main
struct SorobandApp: App {
    // One instance each for the whole app: the menu bar, popover, settings and the island panel must share them.
    private static let store = UsageStore()
    private static let island = IslandModel()
    private var store: UsageStore { Self.store }
    private var island: IslandModel { Self.island }

    init() {
        if ProcessInfo.processInfo.environment["SOROBAND_SNAPSHOT"] != nil {
            Snapshot.showIfRequested(store: store, island: island)
        } else {
            let (store, island) = (store, island)
            DispatchQueue.main.async {
                IslandPanel.shared = IslandPanel(model: island, store: store)
                // Spike: SOROBAND_DEMO=<moment kind> fires that moment once at launch.
                if let demo = ProcessInfo.processInfo.environment["SOROBAND_DEMO"].flatMap(MomentKind.init(rawValue:)) {
                    MomentSimulator.trigger(demo, store: store, island: island)
                }
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environment(store).environment(island)
        } label: {
            Label(store.menuBarText, systemImage: store.currentNetwork.kind.symbol)
                .labelStyle(.titleAndIcon)
        }
        .menuBarExtraStyle(.window)

        Window("Soroband History", id: "history") {
            HistoryView().environment(store)
        }
        .defaultSize(width: 1000, height: 720)

        Settings {
            SettingsView().environment(store).environment(island)
        }
    }
}
