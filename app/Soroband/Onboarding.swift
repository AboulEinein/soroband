import AppKit
import CoreLocation
import SwiftUI

/// The first-run window that asks for the Location permission, which macOS requires before it
/// reveals Wi‑Fi network names.
enum Onboarding {
    static let shownKey = "onboardingShown"

    /// Shown once, and only while macOS has not asked yet: after a choice in System Settings the
    /// prompt cannot appear again, so the window would have nothing to offer.
    static func shouldShow(status: CLAuthorizationStatus, alreadyShown: Bool) -> Bool {
        !alreadyShown && status == .notDetermined
    }

    @MainActor
    static func showIfNeeded() {
        let defaults = UserDefaults.standard
        guard shouldShow(status: LocationAccess.shared.status, alreadyShown: defaults.bool(forKey: shownKey)) else {
            return
        }
        defaults.set(true, forKey: shownKey)
        OnboardingWindow.shared.show()
    }
}

@MainActor
final class OnboardingWindow: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindow()

    private(set) var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(
                contentViewController: NSHostingController(rootView: OnboardingView { [weak self] in self?.close() }))
            window.title = "Welcome to Soroband"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

struct OnboardingView: View {
    var location = LocationAccess.shared
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "wifi")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(NetworkColor.color(slot: 0).gradient, in: .rect(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Soroband counts your internet per app and per network").font(.headline)
                    Text("It lives in the menu bar. Click its icon for today's usage.")
                        .foregroundStyle(.secondary)
                }
            }
            Text("To tell your Wi‑Fi networks apart by name, macOS needs Location access. Soroband reads only the network's name, never where you are, and nothing leaves your Mac.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Without it, each Wi‑Fi network is still counted on its own, known by its router, and named “Wi‑Fi” until you rename it in Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Not Now", action: done)
                Button("Allow Location Access") {
                    location.request()
                    done()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
