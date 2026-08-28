import XCTest
@testable import InputPilot

final class DevicePresenceStatusTests: XCTestCase {
    func testOfflineWhenNeitherTransportIsAvailable() {
        let status = DevicePresenceStatus.resolve(
            wifi: .offline,
            bluetooth: .offline,
            hasConfiguredWiFi: true
        )
        XCTAssertEqual(status, .offline)
        XCTAssertEqual(status.title, "Offline")
    }

    func testWiFiReachabilityMeansOnlineNotBluetoothAvailable() {
        let status = DevicePresenceStatus.resolve(
            wifi: .reachable,
            bluetooth: .offline,
            hasConfiguredWiFi: true
        )
        XCTAssertEqual(status, .readyWiFi)
        XCTAssertEqual(status.title, "Online via Wi-Fi")
    }

    func testBluetoothReadyWinsOverWiFiFailure() {
        let status = DevicePresenceStatus.resolve(
            wifi: .offline,
            bluetooth: .ready,
            hasConfiguredWiFi: true
        )
        XCTAssertEqual(status, .readyBluetooth)
        XCTAssertEqual(status.title, "Ready via Bluetooth")
    }

    func testWorkingWiFiWinsOverBluetoothReconnect() {
        let status = DevicePresenceStatus.resolve(
            wifi: .reachable,
            bluetooth: .reconnecting,
            hasConfiguredWiFi: true
        )
        XCTAssertEqual(status, .readyWiFi)
    }

    func testDiscoveredIsNotReportedAsReady() {
        let status = DevicePresenceStatus.resolve(
            wifi: .offline,
            bluetooth: .discovered,
            hasConfiguredWiFi: false
        )
        XCTAssertEqual(status, .bluetoothDiscovered)
        XCTAssertFalse(status.isUsable)
    }

    func testInitialStateIsCheckingInsteadOfOnline() {
        XCTAssertEqual(
            DevicePresenceStatus.resolve(wifi: .checking, bluetooth: .offline, hasConfiguredWiFi: true),
            .checking
        )
    }

    func testReachableWithoutConfiguredWiFiIsSetup() {
        XCTAssertEqual(
            DevicePresenceStatus.resolve(wifi: .reachable, bluetooth: .offline, hasConfiguredWiFi: false),
            .setup
        )
    }
}
