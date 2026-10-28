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
            NetworkMonitor.shared.refresh()
        }
    }
}
