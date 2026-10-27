import Testing
@testable import Soroband

struct NetworkIdentityTests {
    /// The network an observation identifies; fails the test when it waits for the router.
    private func network(_ observation: NetworkObservation) throws -> NetworkIdentity {
        guard case .network(let identity) = NetworkIdentity.identify(observation) else {
            Issue.record("waits for the router: \(observation)")
            throw CancellationError()
        }
        return identity
    }

    private func wifi(ssid: String?, router: String? = "2:0:0:1:2:3", expensive: Bool = false) -> NetworkObservation {
        NetworkObservation(medium: .wifi, interface: "en0", isExpensive: expensive, ssid: ssid, router: router)
    }

    private func wired(router: String?, expensive: Bool = false) -> NetworkObservation {
        NetworkObservation(medium: .wired, interface: "en7", isExpensive: expensive, ssid: nil, router: router)
    }

    @Test func wifiIsKnownByItsName() throws {
        let home = try network(wifi(ssid: "Home"))
        #expect(home == NetworkIdentity(key: "wifi:Home", name: "Home", kind: .wifi))
        // Another access point of the same network, with another router, is the same network.
        #expect(try network(wifi(ssid: "Home", router: "aa:bb:cc:dd:ee:ff")).key == home.key)
    }

    @Test func wifiWithoutItsNameIsKnownByItsRouter() throws {
        // Without the Location permission macOS hides the name; two such networks stay apart.
        let one = try network(wifi(ssid: nil, router: "2:0:0:1:2:3"))
        let other = try network(wifi(ssid: nil, router: "aa:bb:cc:dd:ee:ff"))
        #expect(one.key != other.key)
        #expect(one.name == "Wi-Fi")
    }

    @Test func iPhoneHotspotIsAHotspotOverWifiAndUSB() throws {
        let overWifi = try network(wifi(ssid: "Sam’s iPhone", expensive: true))
        #expect(overWifi == NetworkIdentity(key: "wifi:Sam’s iPhone", name: "Sam’s iPhone", kind: .hotspot))
        let overUSB = try network(wired(router: "f2:5c:1:2:3:4", expensive: true))
        #expect(overUSB.kind == .hotspot)
        #expect(overUSB.name == "Personal Hotspot")
    }

    @Test func wiredNetworksOnOneAdapterAreToldApartByTheirRouter() throws {
        let desk = try network(wired(router: "0:11:22:33:44:55"))
        let office = try network(wired(router: "0:1b:21:aa:bb:cc"))
        #expect(desk.key != office.key)
        #expect(desk.kind == .ethernet)
    }

    @Test func hiddenWifiWithoutARouterYetWaitsInsteadOfSharingAKey() {
        // Two Wi‑Fi networks joined without the Location permission, each before its router is
        // resolved: neither may be booked to an entry the other would also get.
        #expect(NetworkIdentity.identify(wifi(ssid: nil, router: nil)) == .waitForRouter)
        #expect(NetworkIdentity.identify(wifi(ssid: "", router: nil)) == .waitForRouter)
        // A hotspot with its name hidden waits the same way.
        #expect(NetworkIdentity.identify(wifi(ssid: nil, router: nil, expensive: true)) == .waitForRouter)
    }

    @Test func wiredWithoutARouterYetWaitsInsteadOfSharingAKey() {
        // A dock and an office LAN on one adapter would otherwise share the adapter's key.
        #expect(NetworkIdentity.identify(wired(router: nil)) == .waitForRouter)
        #expect(NetworkIdentity.identify(wired(router: nil, expensive: true)) == .waitForRouter)
    }

    @Test func networksThatNeedNoRouterNeverWait() throws {
        #expect(try network(wifi(ssid: "Home", router: nil)).key == "wifi:Home")
        let cellular = NetworkObservation(medium: .cellular, interface: "pdp_ip0", isExpensive: true, ssid: nil, router: nil)
        #expect(try network(cellular).kind == .hotspot)
    }

    @Test func routerIsLookedForEverySecondAtFirstThenEveryHalfMinute() {
        #expect(NetworkIdentity.routerRetryDelay(afterAttempts: 0) == .seconds(1))
        #expect(NetworkIdentity.routerRetryDelay(afterAttempts: 4) == .seconds(1))
        #expect(NetworkIdentity.routerRetryDelay(afterAttempts: 5) == .seconds(30))
    }

    @Test func routerAddressComesFromTheServiceOnTheInterface() {
        let services: [[String: Any]] = [
            ["InterfaceName": "utun9", "Router": "100.64.0.1"],
            ["InterfaceName": "en0", "ARPResolvedHardwareAddress": "0:11:22:33:44:55"],
            ["InterfaceName": "en7"],
        ]
        #expect(routerAddress(on: "en0", in: services) == "0:11:22:33:44:55")
        #expect(routerAddress(on: "en7", in: services) == nil)
        #expect(routerAddress(on: "en1", in: services) == nil)
    }
}
