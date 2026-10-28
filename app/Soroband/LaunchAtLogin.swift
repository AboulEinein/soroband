import ServiceManagement

/// Launch at login through `SMAppService.mainApp`, which macOS lists under System Settings ›
/// General › Login Items. macOS owns the state, so it is read back after every change rather
/// than stored by the app.
@MainActor
@Observable
final class LaunchAtLogin {
    static let shared = LaunchAtLogin(service: .mainApp)

    /// What the Settings toggle shows.
    struct State: Equatable {
        var isOn: Bool
        /// Why the toggle may not do what it says, when it may not.
        var note: String?
    }

    /// The parts of `SMAppService` the app uses, so tests can stand in for macOS.
    struct Service: Sendable {
        var status: @Sendable () -> SMAppService.Status
        var register: @Sendable () throws -> Void
        var unregister: @Sendable () throws -> Void

        static let mainApp = Service(
            status: { SMAppService.mainApp.status },
            register: { try SMAppService.mainApp.register() },
            unregister: { try SMAppService.mainApp.unregister() })
    }

    private let service: Service
    private(set) var state: State
    /// The last change macOS refused, shown until the next change.
    private var failure: String?

    init(service: Service) {
        self.service = service
        state = Self.state(for: service.status(), failure: nil)
    }

    static func state(for status: SMAppService.Status, failure: String?) -> State {
        switch status {
        case .enabled:
            State(isOn: true, note: failure)
        case .requiresApproval:
            State(isOn: true, note: failure ?? "Allow Soroband in System Settings › General › Login Items.")
        case .notRegistered:
            State(isOn: false, note: failure)
        case .notFound:
            State(isOn: false, note: failure ?? "macOS cannot find this copy of Soroband. Install it in Applications.")
        @unknown default:
            State(isOn: false, note: failure)
        }
    }

    func set(_ on: Bool) {
        do {
            if on { try service.register() } else { try service.unregister() }
            failure = nil
        } catch {
            failure = "macOS refused: \(error.localizedDescription)"
        }
        refresh()
    }

    /// Reads the state again; the user may have changed it in System Settings.
    func refresh() {
        state = Self.state(for: service.status(), failure: failure)
    }

    var needsApproval: Bool { service.status() == .requiresApproval }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
