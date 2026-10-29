import Foundation
internal import SorobandCore

/// The Rust core, through its C API.
enum Core {
    static var version: String { String(cString: soroband_core_version()) }

    /// Where the app keeps its database and settings. Debug builds use their own directory, so
    /// they never touch the installed app's data, or `SOROBAND_DATA_DIR` when it is set (for a
    /// run on synthetic data). Must match `core/crates/soroband-cli/src/data.rs`.
    static let dataDirectory: URL = {
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["SOROBAND_DATA_DIR"], !dir.isEmpty {
            return URL(filePath: dir, directoryHint: .isDirectory)
        }
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

    /// Opens the usage database for reading only, without the engine, for the History process.
    /// Returns false when it cannot be read.
    @discardableResult
    static func openDatabase() -> Bool {
        dataDirectory.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return soroband_database_open(path)
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
        let formerName = identity.formerKey == nil ? nil : NetworkIdentity.unnamedWiFi
        guard
            soroband_network_changed(
                identity.key, identity.name, identity.kind.rawValue, identity.formerKey, formerName, &out)
        else {
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

    /// The value of setting `key` as `soroband config get` prints it; nil for an unknown key.
    static func setting(_ key: String) -> String? {
        take(soroband_setting_get(key))
    }

    /// Sets `key` as `soroband config set` would and applies it. Returns false when the value does
    /// not fit the setting, saving nothing.
    @discardableResult
    static func setSetting(_ key: String, to value: String) -> Bool {
        soroband_setting_set(key, value)
    }

    /// While on, the engine polls every second and publishes `today()`; for the open popover.
    static func setLive(_ live: Bool) {
        soroband_engine_live(live)
    }

    /// Calls `callback` on the engine's thread after each poll.
    static func onPoll(_ callback: @convention(c) () -> Void) {
        soroband_engine_on_poll(callback)
    }

    /// Today's usage per network and app, as of the last poll; empty unless live.
    static func today() -> Today {
        decode(Today.self, soroband_today_json()) ?? Today(networks: [], apps: [])
    }

    /// Every network in the registry. Reads the database.
    static func networks() -> [RegisteredNetwork] {
        decode([RegisteredNetwork].self, soroband_networks_json()) ?? []
    }

    /// What the History window shows for `query`, aggregated by the core from the database; nil
    /// when the read fails.
    static func history(_ query: HistoryQuery) -> HistoryData? {
        decode(HistoryData.self, soroband_history_json(query.json))
    }

    /// Writes the usage stored over `query`'s span and network to `file` as CSV. Returns the
    /// number of rows written, or nil when the read or write fails.
    static func exportCSV(_ query: HistoryQuery, to file: URL) -> Int? {
        let rows = file.withUnsafeFileSystemRepresentation { path in
            path.map { soroband_export_csv(query.json, $0) } ?? -1
        }
        return rows < 0 ? nil : Int(rows)
    }

    private static func take(_ string: UnsafeMutablePointer<CChar>?) -> String? {
        guard let string else { return nil }
        defer { soroband_string_free(string) }
        return String(cString: string)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ string: UnsafeMutablePointer<CChar>?) -> T? {
        guard let json = take(string) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: Data(json.utf8))
        } catch {
            NSLog("Soroband: cannot read %@ from the core: %@", String(describing: type), String(describing: error))
            return nil
        }
    }
}

/// Received and sent bytes, as the core's JSON writes them.
struct ByteCounts: Codable, Equatable {
    var rx: UInt64
    var tx: UInt64

    var total: UInt64 { rx + tx }

    static let zero = ByteCounts(rx: 0, tx: 0)
}

/// Today's usage as `Core.today()` returns it.
struct Today: Codable, Equatable {
    struct NetworkTotal: Codable, Equatable {
        let network: Int64
        /// Summed over the network's apps.
        let apps: ByteCounts
        /// What crossed the interfaces on that network.
        let interfaces: ByteCounts
    }

    struct AppUsage: Codable, Equatable {
        let network: Int64
        /// The bundle path, the executable path, "macOS & Services", or `process:<name>`.
        let id: String
        let name: String
        let rx: UInt64
        let tx: UInt64

        var bytes: ByteCounts { ByteCounts(rx: rx, tx: tx) }
    }

    let networks: [NetworkTotal]
    let apps: [AppUsage]
}

/// A network in the registry, with the last hour it carried bytes.
struct RegisteredNetwork: Codable, Equatable, Identifiable {
    let id: Int64
    let key: String
    let name: String
    let kind: NetworkKind
    /// Unix time of the start of the last hour it carried bytes; nil when never used.
    let lastUsed: Int64?

    enum CodingKeys: String, CodingKey {
        case id, key, name, kind
        case lastUsed = "last_used"
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
struct EngineStatus: Equatable {
    enum State: String, Encodable {
        case starting, perApp, interfaceOnly, failed
    }

    /// The self-check's verdict on the apps' sum against the interfaces (`core/.../check.rs`).
    enum Check: String, Encodable {
        case ok, degraded, overcount
    }

    typealias Bytes = ByteCounts

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
    /// Bytes per second across the interfaces between the last two polls.
    let speed: Bytes
    let check: Check

    init(
        state: State = .perApp, networkID: Int64 = 0, todayStart: Date = .distantPast, resetHour: Int = 0,
        todayNetworkApps: Bytes = .zero, todayNetworkInterfaces: Bytes = .zero,
        todayApps: Bytes = .zero, todayInterfaces: Bytes = .zero,
        speed: Bytes = .zero, check: Check = .ok
    ) {
        self.state = state
        flows = 0
        apps = 0
        appBytes = .zero
        interfaceBytes = .zero
        self.networkID = networkID
        self.todayStart = todayStart
        self.resetHour = resetHour
        self.todayNetworkApps = todayNetworkApps
        self.todayNetworkInterfaces = todayNetworkInterfaces
        self.todayApps = todayApps
        self.todayInterfaces = todayInterfaces
        self.speed = speed
        self.check = check
    }

    fileprivate init(_ status: SorobandEngineStatus) {
        state =
            switch status.state {
            case UInt32(SOROBAND_ENGINE_PER_APP): .perApp
            case UInt32(SOROBAND_ENGINE_INTERFACE_ONLY): .interfaceOnly
            case UInt32(SOROBAND_ENGINE_FAILED): .failed
            default: .starting
            }
        flows = Int(status.flows)
        apps = Int(status.apps)
        appBytes = Bytes(rx: status.app_rx, tx: status.app_tx)
        interfaceBytes = Bytes(rx: status.interface_rx, tx: status.interface_tx)
        networkID = status.network_id
        todayStart = Date(timeIntervalSince1970: TimeInterval(status.today_start))
        resetHour = Int(status.reset_hour)
        todayNetworkApps = Bytes(rx: status.today_network_app_rx, tx: status.today_network_app_tx)
        todayNetworkInterfaces = Bytes(rx: status.today_network_interface_rx, tx: status.today_network_interface_tx)
        todayApps = Bytes(rx: status.today_app_rx, tx: status.today_app_tx)
        todayInterfaces = Bytes(rx: status.today_interface_rx, tx: status.today_interface_tx)
        speed = Bytes(rx: status.speed_rx, tx: status.speed_tx)
        check =
            switch status.check {
            case UInt32(SOROBAND_CHECK_DEGRADED): .degraded
            case UInt32(SOROBAND_CHECK_OVERCOUNT): .overcount
            default: .ok
            }
    }
}
