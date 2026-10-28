import CoreWLAN
import Network
import SystemConfiguration

/// Follows the network the Mac is on and tells the core when it changes.
///
/// Event-driven: `NWPathMonitor` reports each path change; nothing polls while an identified
/// network is stable. A network still waiting for its router is looked at again every 30 s.
@MainActor
@Observable
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    /// The network bytes are booked to, as the registry stores it; nil while usage is booked to no
    /// network (id 0): before the first network is identified, while waiting for a router, or
    /// after the registry failed to record a network.
    private(set) var current: Network? {
        didSet {
            if current?.id != oldValue?.id { connectedSince = current == nil ? nil : .now }
            Usage.shared.onChange?()
        }
    }
    /// When the Mac joined `current`, as seen by this run of the app.
    private(set) var connectedSince: Date?
    /// Debug builds can pretend to be on another network (`soroband-debug://simulate-network`).
    var simulated: NetworkIdentity? {
        didSet { identify() }
    }

    private let monitor = NWPathMonitor()
    private var observation: NetworkObservation?
    /// Looks for the router again until it is resolved or the path changes.
    private var routerWait: Task<Void, Never>?
    private var routerAttempts = 0
    /// Looks for the Wi‑Fi name again after Location access was granted.
    private var nameWait: Task<Void, Never>?

    func start() {
        monitor.pathUpdateHandler = { path in
            MainActor.assumeIsolated { NetworkMonitor.shared.update(path) }
        }
        monitor.start(queue: .main)
    }

    /// Looks again at the current path, for when the Wi‑Fi name became readable.
    func refresh() {
        update(monitor.currentPath)
    }

    /// Looks again at the current path each second for a few seconds until the Wi‑Fi name shows:
    /// after Location access is granted, macOS can take seconds to reveal it, and no path change
    /// follows when it does.
    func refreshUntilNamed() {
        nameWait?.cancel()
        nameWait = Task { @MainActor in
            for _ in 0..<10 {
                self.refresh()
                guard let observation = self.observation, observation.medium == .wifi, observation.ssid == nil else {
                    return
                }
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
            }
        }
    }

    private func update(_ path: NWPath) {
        observation = Self.observe(path)
        routerWait?.cancel()
        routerWait = nil
        routerAttempts = 0
        identify()
    }

    private func identify() {
        let identity: NetworkIdentity
        if let simulated {
            identity = simulated
        } else if let observation {
            switch NetworkIdentity.identify(observation) {
            case .network(let found):
                identity = found
            case .waitForRouter:
                if current != nil {
                    Core.networkUnidentified()
                    current = nil
                }
                let delay = NetworkIdentity.routerRetryDelay(afterAttempts: routerAttempts)
                routerAttempts += 1
                routerWait = Task { @MainActor in
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else { return }
                    self.retryRouter()
                }
                return
            }
        } else {
            // Offline: keep booking to the last network; almost nothing moves until the next one.
            return
        }
        guard identity.key != current?.key else { return }
        if let network = Core.networkChanged(to: identity) {
            current = network
        } else if current != nil {
            // The registry could not record it: book to no network rather than the last one.
            Core.networkUnidentified()
            current = nil
        }
    }

    private func retryRouter() {
        guard var observation, simulated == nil else { return }
        observation.router = Self.router(on: observation.interface)
        self.observation = observation
        identify()
    }

    /// Applies a rename or kind change to the current network.
    func updateCurrent(name: String, kind: NetworkKind) {
        guard let current, Core.updateNetwork(id: current.id, name: name, kind: kind) else { return }
        self.current = Network(id: current.id, key: current.key, name: name, kind: kind)
    }

    private static func observe(_ path: NWPath) -> NetworkObservation? {
        guard path.status == .satisfied else { return nil }
        // The first physical interface carries the traffic; a VPN's tunnel comes before it.
        for interface in path.availableInterfaces {
            let medium: NetworkObservation.Medium
            switch interface.type {
            case .wifi: medium = .wifi
            case .wiredEthernet: medium = .wired
            case .cellular: medium = .cellular
            default: continue
            }
            return NetworkObservation(
                medium: medium,
                interface: interface.name,
                isExpensive: path.isExpensive,
                ssid: medium == .wifi ? CWWiFiClient.shared().interface(withName: interface.name)?.ssid() : nil,
                router: router(on: interface.name))
        }
        return nil
    }

    private static func router(on interface: String) -> String? {
        guard let store = SCDynamicStoreCreate(nil, "Soroband" as CFString, nil, nil),
            let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/[^/]+/IPv4" as CFString) as? [String]
        else { return nil }
        let services = keys.compactMap { SCDynamicStoreCopyValue(store, $0 as CFString) as? [String: Any] }
        return routerAddress(on: interface, in: services)
    }
}
