internal import SorobandCore

/// The Rust core, through its C API.
enum Core {
    static var version: String { String(cString: soroband_core_version()) }

    /// Starts the meter engine on its own thread. Later calls do nothing.
    static func startEngine(interval: UInt32 = 5) {
        soroband_engine_start(interval)
    }

    static var engine: EngineStatus { EngineStatus(soroband_engine_status()) }
}

/// The meter engine's health and totals since it started.
struct EngineStatus {
    enum State: String, Encodable {
        case starting, perApp, interfaceOnly, failed
    }

    let state: State
    let flows: Int
    let apps: Int
    let appBytes: (received: UInt64, sent: UInt64)
    let interfaceBytes: (received: UInt64, sent: UInt64)

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
    }
}
