import Foundation

/// The island's moments, by the names the core's `island_moments` setting uses.
enum MomentKind: String, Codable, CaseIterable, Identifiable {
    case peek, joined, left, hotspot, hog, background, transfer, recap

    var id: String { rawValue }

    var title: String {
        switch self {
        case .peek: "Peek on hover"
        case .joined: "Network joined"
        case .left: "Network left"
        case .hotspot: "Hotspot meter"
        case .hog: "Data hog"
        case .background: "Background activity"
        case .transfer: "Large transfer"
        case .recap: "Daily recap"
        }
    }

    var detail: String {
        switch self {
        case .peek: "Hover the notch to see today's total and top apps."
        case .joined: "This network's recent usage and when you were last on it."
        case .left: "A receipt for the session you just ended."
        case .hotspot: "A small live counter at the notch while on a hotspot."
        case .hog: "One app uses a lot of data in a short time."
        case .background: "An app not in front moves a lot of data."
        case .transfer: "Progress of a large download or upload."
        case .recap: "A one-line summary when the daily counter resets."
        }
    }

    /// Alerts still show while an app is full screen (unless hidden), and become notifications
    /// while the island is off.
    var isAlert: Bool { self == .hog || self == .background }

    /// Which moment the queue shows first: alerts, then transfers, then the rest.
    var priority: Int {
        switch self {
        case .hog, .background: 3
        case .transfer: 2
        case .joined, .left: 1
        case .peek, .hotspot, .recap: 0
        }
    }

    /// Seconds a moment stays open when the pointer is not on it.
    var duration: Double {
        switch self {
        case .hog, .background: 8
        case .transfer: 6
        case .peek: 0.4
        default: 5
        }
    }
}

/// An app as a moment names it: its id is the path of its bundle or executable, as the core
/// names apps.
struct MomentApp: Codable, Equatable {
    var id: String
    var name: String
    var bytes: UInt64?
}

/// What a moment says.
enum MomentContent: Equatable {
    /// Today on the network, the live speed and today's top apps there.
    case peek(network: Network?, today: UInt64, down: UInt64, up: UInt64, speed: UInt64, apps: [MomentApp])
    case joined(network: Network, week: UInt64, today: UInt64, lastSeen: Date?)
    case left(network: Network, since: Date, bytes: UInt64, top: MomentApp?)
    case hog(app: MomentApp, bytes: UInt64, minutes: Int, network: Network?)
    case background(app: MomentApp, bytes: UInt64, uploading: Bool)
    case transfer(app: MomentApp, via: String?, bytes: UInt64, rate: UInt64, done: Bool)
    case recap(bytes: UInt64, networks: Int, top: MomentApp?)

    var kind: MomentKind {
        switch self {
        case .peek: .peek
        case .joined: .joined
        case .left: .left
        case .hog: .hog
        case .background: .background
        case .transfer: .transfer
        case .recap: .recap
        }
    }
}

/// A moment as the core reports it (`Core.moments()`), before the app names its network.
struct CoreMoment: Decodable, Equatable {
    var kind: MomentKind
    var app: MomentApp?
    var top: MomentApp?
    var via: String?
    var bytes: UInt64?
    var rate: UInt64?
    var done: Bool?
    var minutes: Int?
    var uploading: Bool?
    var network: Int64?
    var week: UInt64?
    var today: UInt64?
    var lastSeen: Int64?
    var since: Int64?
    var networks: Int?

    enum CodingKeys: String, CodingKey {
        case kind, app, top, via, bytes, rate, done, minutes, uploading, network, week, today, since, networks
        case lastSeen = "last_seen"
    }

    /// What the moment says, naming networks with `network(id)`; nil when its network is not
    /// known or a field it needs is missing.
    func content(network named: (Int64) -> Network?, current: Network?) -> MomentContent? {
        switch kind {
        case .hog:
            guard let app, let bytes else { return nil }
            return .hog(app: app, bytes: bytes, minutes: minutes ?? 0, network: current)
        case .background:
            guard let app, let bytes else { return nil }
            return .background(app: app, bytes: bytes, uploading: uploading ?? false)
        case .transfer:
            guard let app, let bytes else { return nil }
            return .transfer(app: app, via: via, bytes: bytes, rate: rate ?? 0, done: done ?? false)
        case .joined:
            guard let id = network, let network = named(id) else { return nil }
            return .joined(
                network: network, week: week ?? 0, today: today ?? 0,
                lastSeen: lastSeen.map { Date(timeIntervalSince1970: TimeInterval($0)) })
        case .left:
            guard let id = network, let network = named(id), let since else { return nil }
            return .left(
                network: network, since: Date(timeIntervalSince1970: TimeInterval(since)), bytes: bytes ?? 0,
                top: top)
        case .recap:
            return .recap(bytes: bytes ?? 0, networks: networks ?? 0, top: top)
        case .peek, .hotspot:
            return nil
        }
    }
}

/// One moment on the island.
struct Moment: Equatable, Identifiable {
    let id: Int
    var content: MomentContent
    var kind: MomentKind { content.kind }
}
