import SwiftUI

/// Spike-only: fires moments with fake data so each one can be judged on screen.
@MainActor
enum MomentSimulator {
    static func join(_ networkID: String, store: UsageStore, island: IslandModel) {
        let previous = store.currentNetworkID
        let since = store.connectedSince
        guard previous != networkID else { return }
        store.simulateJoin(networkID)
        island.post(Moment(kind: .networkLeft, content: .left(networkID: previous, since: since), duration: 4))
        island.post(Moment(kind: .networkJoined, content: .joined(networkID: networkID)))
    }

    static func moment(_ kind: MomentKind, store: UsageStore) -> Moment? {
        switch kind {
        case .notchPeek: Moment(kind: kind, content: .peek)
        case .networkJoined: Moment(kind: kind, content: .joined(networkID: store.currentNetworkID))
        case .networkLeft: Moment(kind: kind, content: .left(networkID: store.currentNetworkID, since: store.connectedSince))
        case .hotspotMeter: nil
        case .dataHog: Moment(kind: kind, content: .hog(appID: "com.apple.bird", bytes: 240_000_000, minutes: 4), duration: 9)
        case .backgroundActivity: Moment(kind: kind, content: .background(appID: "system", bytes: 180_000_000, uploading: false), duration: 8)
        case .bigTransfer: Moment(kind: kind, content: .transfer(appID: "com.apple.dt.Xcode", via: "App Store", bytes: 1_240_000_000, rate: 41_000_000, done: false))
        case .dailyRecap: Moment(kind: kind, content: .recap)
        }
    }

    static func trigger(_ kind: MomentKind, store: UsageStore, island: IslandModel) {
        switch kind {
        case .hotspotMeter: join("iphone", store: store, island: island)
        case .bigTransfer: runTransfer(island: island)
        default: moment(kind, store: store).map(island.post)
        }
    }

    private static func runTransfer(island: IslandModel) {
        let moment = Moment(kind: .bigTransfer, content: .transfer(appID: "com.apple.dt.Xcode", via: "App Store", bytes: 0, rate: 0, done: false), duration: 60)
        island.post(moment)
        Task {
            for step in 1...30 {
                try? await Task.sleep(for: .milliseconds(160))
                island.update(moment.id) { content in
                    guard case .transfer(let app, let via, let bytes, _, _) = content else { return }
                    content = .transfer(appID: app, via: via, bytes: bytes + 107_000_000,
                                        rate: Double.random(in: 38_000_000...46_000_000), done: step == 30)
                }
            }
            island.scheduleDismiss(after: 2.5)
        }
    }
}
