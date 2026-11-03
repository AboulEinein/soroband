import Foundation
import notify

/// Applies `soroband config set` to the running app: the command posts a Darwin notification named
/// after the bundle identifier, and the core rereads the settings file.
/// Must match `core/crates/soroband-cli/src/data.rs`.
@MainActor
enum SettingsListener {
    static var notification: String {
        "\(Bundle.main.bundleIdentifier ?? "io.github.abouleinein.soroband").settings-changed"
    }

    /// A script setting several values, or a loop of `soroband config set`, posts a burst of
    /// notifications: they cost one reread per 250 ms, and a single change applies within 250 ms.
    static let reread = Coalescer(window: .milliseconds(250)) {
        Core.reloadSettings()
        Usage.shared.reloadSettings()
    }

    private static var token: Int32 = 0

    static func start() {
        notify_register_dispatch(notification, &token, .main) { _ in
            MainActor.assumeIsolated { reread.request() }
        }
    }
}

/// Runs `action` once, `window` after the first request; requests made while it waits join that
/// run, so a burst of requests runs `action` at most once per window.
@MainActor
final class Coalescer {
    private let window: Duration
    private let action: @MainActor () -> Void
    private var pending: Task<Void, Never>?

    init(window: Duration, action: @escaping @MainActor () -> Void) {
        self.window = window
        self.action = action
    }

    func request() {
        guard pending == nil else { return }
        pending = Task { [window] in
            try? await Task.sleep(for: window)
            self.pending = nil
            self.action()
        }
    }
}
