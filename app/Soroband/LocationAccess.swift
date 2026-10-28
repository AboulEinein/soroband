import CoreLocation
import SwiftUI

/// The Location permission, which macOS requires before it reveals the Wi‑Fi network name.
@MainActor
@Observable
final class LocationAccess: NSObject, CLLocationManagerDelegate {
    static let shared = LocationAccess()

    private let manager = CLLocationManager()
    private(set) var status: CLAuthorizationStatus

    override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    func request() {
        manager.requestWhenInUseAuthorization()
    }

    var isAllowed: Bool { statusName == "authorized" }

    /// Asks macOS, or opens Location Services in System Settings once the user has answered,
    /// because macOS asks only once.
    func allow() {
        if status == .notDetermined {
            request()
        } else if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")
        {
            NSWorkspace.shared.open(url)
        }
    }

    /// The status as a stable name for `soroband debug state`.
    var statusName: String {
        switch status {
        case .notDetermined: "notDetermined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorizedAlways, .authorizedWhenInUse: "authorized"
        @unknown default: "unknown"
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            self.status = status
            // With the permission the Wi‑Fi name becomes readable.
            NetworkMonitor.shared.refreshUntilNamed()
        }
    }
}
