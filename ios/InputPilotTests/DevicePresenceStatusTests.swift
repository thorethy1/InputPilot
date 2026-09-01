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
        XCTAssertEqual(status.title, "Online")
        XCTAssertEqual(status.detail, "Online via Wi-Fi only")
    }

    func testBluetoothReadyWinsOverWiFiFailure() {
        let status = DevicePresenceStatus.resolve(
            wifi: .offline,
            bluetooth: .ready,
            hasConfiguredWiFi: true
        )
        XCTAssertEqual(status, .readyBluetooth)
        XCTAssertEqual(status.title, "Online")
        XCTAssertEqual(status.detail, "Online via Bluetooth only")
    }

    func testWorkingWiFiWinsOverBluetoothReconnect() {
        let status = DevicePresenceStatus.resolve(
            wifi: .reachable,
            bluetooth: .reconnecting,
            hasConfiguredWiFi: true
        )
        XCTAssertEqual(status, .readyWiFi)
    }

    func testBothWorkingTransportsAreShown() {
        let status = DevicePresenceStatus.resolve(
            wifi: .reachable,
            bluetooth: .ready,
            hasConfiguredWiFi: true
        )
        XCTAssertEqual(status, .readyBoth)
        XCTAssertEqual(status.title, "Online")
        XCTAssertEqual(status.detail, "Online via Wi-Fi and Bluetooth")
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

    func testEveryPresenceStateHasANonColorIndicator() {
        let states: [DevicePresenceStatus] = [
            .checking, .offline, .setup, .bluetoothDiscovered, .connecting,
            .reconnecting, .authenticating, .authenticationFailed, .readyBoth,
            .readyBluetooth, .readyWiFi
        ]

        for state in states {
            XCTAssertFalse(state.systemImage.isEmpty, "Missing symbol for \(state)")
            XCTAssertFalse(state.title.isEmpty, "Missing title for \(state)")
        }
    }
}
