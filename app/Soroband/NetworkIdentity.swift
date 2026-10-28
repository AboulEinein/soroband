import Foundation

/// What kind of network it is. Must match the core's `NetworkKind`.
enum NetworkKind: String, Codable, CaseIterable {
    case wifi, ethernet, hotspot
}

/// What the app can see of the network the Mac is on.
struct NetworkObservation: Equatable {
    enum Medium: Equatable {
        case wifi, wired, cellular
    }

    var medium: Medium
    /// BSD name of the interface carrying the traffic (`en0`).
    var interface: String
    /// Set by macOS for an iPhone's Personal Hotspot, over Wi‑Fi or USB.
    var isExpensive: Bool
    /// The Wi‑Fi network name; macOS reveals it only with the Location permission.
    var ssid: String?
    /// The router's hardware address (`2:0:0:1:2:3`).
    var router: String?
}

/// How the registry knows a network again: a key that stays the same each time the Mac joins it,
/// and the name and kind it starts with.
struct NetworkIdentity: Equatable {
    var key: String
    var name: String
    var kind: NetworkKind
    /// The key the registry may know this network by from before its name was readable: a Wi‑Fi
    /// network known by its router. The registry gives that network this key, and its history.
    var formerKey: String?

    /// The name a Wi‑Fi network known by its router starts with.
    static let unnamedWiFi = "Wi-Fi"

    /// What an observation identifies.
    enum Result: Equatable {
        case network(NetworkIdentity)
        /// The only stable key is the router's address, which is not resolved yet. Until it is,
        /// usage is booked to no network rather than to a key two networks would share.
        case waitForRouter
    }

    /// - Wi‑Fi is known by its name, or by its router when the name is hidden (no Location
    ///   permission). Once the name shows, the network known by its router becomes the named one.
    /// - Wired networks are known by their router, so a desk dock and the office LAN on the same
    ///   adapter stay apart.
    /// - A path macOS marks expensive is a hotspot.
    static func identify(_ observation: NetworkObservation) -> Result {
        let kind: NetworkKind =
            if observation.isExpensive || observation.medium == .cellular {
                .hotspot
            } else if observation.medium == .wifi {
                .wifi
            } else {
                .ethernet
            }
        switch observation.medium {
        case .wifi:
            if let ssid = observation.ssid, !ssid.isEmpty {
                return .network(
                    NetworkIdentity(
                        key: "wifi:\(ssid)", name: ssid, kind: kind,
                        formerKey: observation.router.map { "wifi-router:\($0)" }))
            }
            guard let router = observation.router else { return .waitForRouter }
            return .network(NetworkIdentity(key: "wifi-router:\(router)", name: unnamedWiFi, kind: kind))
        case .wired:
            guard let router = observation.router else { return .waitForRouter }
            let name = observation.isExpensive ? "Personal Hotspot" : "Ethernet"
            return .network(NetworkIdentity(key: "ethernet:\(router)", name: name, kind: kind))
        case .cellular:
            return .network(NetworkIdentity(key: "cellular:\(observation.interface)", name: "Cellular", kind: kind))
        }
    }

    /// How long to wait before looking for the router again, after `attempts` looks: it is
    /// usually resolved within seconds of the path appearing, and may never be on a network
    /// without IPv4.
    static func routerRetryDelay(afterAttempts attempts: Int) -> Duration {
        attempts < 5 ? .seconds(1) : .seconds(30)
    }
}

/// The router's hardware address on `interface`, from the IPv4 state macOS publishes per network
/// service (`State:/Network/Service/<id>/IPv4` in the System Configuration dynamic store).
///
/// The kernel's ARP table would give the same address, but macOS hides it from apps that are not
/// part of the system.
func routerAddress(on interface: String, in services: [[String: Any]]) -> String? {
    services.first { $0["InterfaceName"] as? String == interface }?["ARPResolvedHardwareAddress"] as? String
}
