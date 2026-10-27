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

    private static var token: Int32 = 0

    static func start() {
        notify_register_dispatch(notification, &token, .main) { _ in
            Core.reloadSettings()
        }
    }
}
