import ServiceManagement
import Testing

@testable import Soroband

/// The Launch at login toggle against a stand-in for macOS's login items.
@MainActor
struct LaunchAtLoginTests {
    /// What macOS would hold: the status, and whether the next register call is refused.
    final class LoginItems: @unchecked Sendable {
        var status = SMAppService.Status.notRegistered
        var refuse = false
        var calls: [String] = []

        var service: LaunchAtLogin.Service {
            LaunchAtLogin.Service(
                status: { self.status },
                register: {
                    self.calls.append("register")
                    if self.refuse { throw CocoaError(.featureUnsupported) }
                    self.status = .enabled
                },
                unregister: {
                    self.calls.append("unregister")
                    self.status = .notRegistered
                })
        }
    }

    @Test func turningItOnRegistersTheAppAndTheToggleReadsMacOSBack() {
        let items = LoginItems()
        let launch = LaunchAtLogin(service: items.service)
        #expect(launch.state == .init(isOn: false, note: nil))
        launch.set(true)
        #expect(items.calls == ["register"])
        #expect(launch.state == .init(isOn: true, note: nil))
        launch.set(false)
        #expect(items.calls == ["register", "unregister"])
        #expect(launch.state.isOn == false)
    }

    @Test func aRefusedChangeLeavesTheToggleOffAndSaysWhy() {
        let items = LoginItems()
        items.refuse = true
        let launch = LaunchAtLogin(service: items.service)
        launch.set(true)
        #expect(launch.state.isOn == false)
        #expect(launch.state.note?.hasPrefix("macOS refused:") == true)
    }

    @Test func aChangeMadeInSystemSettingsShowsAfterARefresh() {
        let items = LoginItems()
        let launch = LaunchAtLogin(service: items.service)
        items.status = .enabled
        launch.refresh()
        #expect(launch.state.isOn)
    }

    @Test func waitingForApprovalIsOnWithAPointerToLoginItems() {
        let state = LaunchAtLogin.state(for: .requiresApproval, failure: nil)
        #expect(state.isOn)
        #expect(state.note == "Allow Soroband in System Settings › General › Login Items.")
        #expect(LaunchAtLogin.state(for: .notFound, failure: nil).isOn == false)
    }
}
