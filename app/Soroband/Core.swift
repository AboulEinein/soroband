import Foundation
internal import SorobandCore

/// The Rust core, through its C API.
enum Core {
    static var version: String { String(cString: soroband_core_version()) }

    /// Where the app keeps its database and settings. Debug builds use their own directory, so
    /// they never touch the installed app's data. Must match `core/crates/soroband-cli/src/data.rs`.
    static let dataDirectory: URL = {
        #if DEBUG
        let name = "Soroband Debug"
        #else
        let name = "Soroband"
        #endif
        return URL.applicationSupportDirectory.appending(path: name, directoryHint: .isDirectory)
    }()

    /// Starts the meter engine on its own thread. Later calls do nothing. Returns false when the
    /// usage database cannot be opened.
    @discardableResult
    static func startEngine(interval: UInt32 = 5) -> Bool {
        dataDirectory.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return soroband_engine_start(interval, path)
        }
    }

    /// Polls once more, writes everything to the database and stops the engine.
    static func stopEngine() {
        soroband_engine_stop(3_000)
    }

    static var engine: EngineStatus { EngineStatus(soroband_engine_status()) }

    /// Tells the engine the Mac moved to `identity`'s network. Returns the network as stored: a
    /// network seen before keeps the name and kind the user gave it.
    static func networkChanged(to identity: NetworkIdentity) -> Network? {
        var out = SorobandNetwork()
        guard soroband_network_changed(identity.key, identity.name, identity.kind.rawValue, &out) else {
            return nil
        }
        return Network(out, key: identity.key)
    }

    /// Tells the engine the Mac is on a network it cannot identify yet: usage is booked to no
    /// network (id 0, "Unknown network") until the next `networkChanged`.
    static func networkUnidentified() {
        soroband_network_unidentified()
    }

    /// Renames network `id` and sets its kind.
    @discardableResult
    static func updateNetwork(id: Int64, name: String, kind: NetworkKind) -> Bool {
        soroband_network_update(id, name, kind.rawValue)
    }

    /// Rereads the settings file.
    static func reloadSettings() {
        soroband_settings_reload()
    }
}

/// A network as the registry stores it.
struct Network: Equatable {
    let id: Int64
    let key: String
    let name: String
    let kind: NetworkKind
}

extension Network {
    fileprivate init?(_ network: SorobandNetwork, key: String) {
        let name = withUnsafeBytes(of: network.name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let kind = withUnsafeBytes(of: network.kind) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        guard let kind = NetworkKind(rawValue: kind) else { return nil }
        self.init(id: network.id, key: key, name: name, kind: kind)
    }
}

/// The meter engine's health, totals since it started, and today's usage.
struct EngineStatus {
    enum State: String, Encodable {
        case starting, perApp, interfaceOnly, failed
    }

    typealias Bytes = (received: UInt64, sent: UInt64)

    let state: State
    let flows: Int
    let apps: Int
    let appBytes: Bytes
    let interfaceBytes: Bytes
    /// The network bytes are booked to; 0 when none is identified (before the app named one, or
    /// while it waits for a network's router).
    let networkID: Int64
    let todayStart: Date
    let resetHour: Int
    /// Today on the current network, summed over its apps and as crossed its interfaces.
    let todayNetworkApps: Bytes
    let todayNetworkInterfaces: Bytes
    /// Today on every network.
    let todayApps: Bytes
    let todayInterfaces: Bytes

    fileprivate init(_ status: SorobandEngineStatus) {
        state = switch status.state {
        case UInt32(SOROBAND_ENGINE_PER_APP): .perApp
        case UInt32(SOROBAND_ENGINE_INTERFACE_ONLY): .interfaceOnly
        case UInt32(SOROBAND_ENGINE_FAILED): .failed
        default: .starting
        }
        flows = Int(status.flows)
        apps = Int(status.apps)
        appBytes = (status.app_rx, status.app_tx)
        interfaceBytes = (status.interface_rx, status.interface_tx)
        networkID = status.network_id
        todayStart = Date(timeIntervalSince1970: TimeInterval(status.today_start))
        resetHour = Int(status.reset_hour)
        todayNetworkApps = (status.today_network_app_rx, status.today_network_app_tx)
        todayNetworkInterfaces = (status.today_network_interface_rx, status.today_network_interface_tx)
        todayApps = (status.today_app_rx, status.today_app_tx)
        todayInterfaces = (status.today_interface_rx, status.today_interface_tx)
    }
}
