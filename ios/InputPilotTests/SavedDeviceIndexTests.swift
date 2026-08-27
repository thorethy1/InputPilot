import SwiftData
import XCTest
@testable import InputPilot

final class SavedDeviceIndexTests: XCTestCase {
    func testMatchesByDeviceId() {
        let device = StoredDevice(
            deviceId: "1cdbd4862378",
            displayName: "Desk",
            mdnsHost: "hid-helper-2378.local",
            staIP: "192.168.2.161"
        )
        let index = SavedDeviceIndex(devices: [device])
        let candidate = DiscoveredService(
            id: "1",
            deviceId: "1cdbd4862378",
            name: "hid-helper-2378",
            host: "192.168.2.200",
            port: 80
        )
        XCTAssertEqual(index.match(candidate: candidate)?.displayName, "Desk")
    }

    func testMatchesByIP() {
        let device = StoredDevice(
            deviceId: "abc",
            displayName: "Lab",
            mdnsHost: "hid-helper-abcd.local",
            staIP: "192.168.2.161"
        )
        let index = SavedDeviceIndex(devices: [device])
        let candidate = DiscoveredService(
            id: "1",
            deviceId: nil,
            name: "hid-helper",
            host: "192.168.2.161%en0",
            port: 80
        )
        XCTAssertEqual(index.match(candidate: candidate)?.displayName, "Lab")
    }

    func testMatchesStatusByHost() {
        let device = StoredDevice(
            deviceId: "xyz",
            displayName: "Office",
            mdnsHost: "hid-helper-xyz.local",
            staIP: "10.0.0.5"
        )
        let index = SavedDeviceIndex(devices: [device])
        let status = DeviceStatus(
            ok: true,
            name: "usb-hid-s3",
            version: "0.4.0",
            deviceId: "other-id",
            jiggle: false,
            jiggleIntervalMs: 10000,
            staIp: "10.0.0.5",
            mdns: "hid-helper-other.local"
        )
        XCTAssertEqual(index.match(status: status, host: "ignored")?.displayName, "Office")
    }

    func testNoMatchForUnknownDevice() {
        let index = SavedDeviceIndex.empty
        let candidate = DiscoveredService(
            id: "1",
            deviceId: "new",
            name: "hid-helper-new",
            host: "192.168.1.1",
            port: 80
        )
        XCTAssertNil(index.match(candidate: candidate))
    }
}

@MainActor
final class DeviceRepositoryMergeTests: XCTestCase {
    func testProbeByAddressReturnsKnownDeviceForConnectionUpdate() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: StoredDevice.self, configurations: config)
        let context = ModelContext(container)
        context.insert(
            StoredDevice(
                deviceId: "dup-id",
                displayName: "Already Here",
                mdnsHost: "hid-helper-dup.local",
                staIP: "192.168.2.50"
            )
        )
        try context.save()

        let mockAPI = MockAPIClient()
        let baseURL = URL(string: "http://192.168.2.50/")!
        mockAPI.statusResults[baseURL] = .success(
            DeviceStatus(
                ok: true,
                name: "usb-hid-s3",
                version: "0.4.0",
                deviceId: "dup-id",
                jiggle: false,
                jiggleIntervalMs: 10000,
                staIp: "192.168.2.50",
                mdns: "hid-helper-dup.local"
            )
        )

        let repository = DeviceRepository(context: context)
        let probed = try await repository.probeByAddress(host: "192.168.2.50", token: nil, api: mockAPI)
        XCTAssertEqual(probed.status.deviceId, "dup-id")
    }

    func testBLEFirstThenWiFiDiscoveryMergesWithoutDuplicate() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: StoredDevice.self, configurations: config)
        let context = ModelContext(container)
        context.insert(
            StoredDevice(
                deviceId: "save-dup",
                displayName: "Saved",
                mdnsHost: "",
                apiToken: "keep-token",
                capabilities: ["ble_control"],
                bluetoothDiscovered: true
            )
        )
        try context.save()

        let status = DeviceStatus(
            ok: true,
            name: "usb-hid-s3",
            version: "0.4.0",
            deviceId: "save-dup",
            jiggle: false,
            jiggleIntervalMs: 10000,
            staIp: "192.168.2.88",
            mdns: "hid-helper-save.local",
            protocolVersion: 1,
            capabilities: ["wifi_control", "wifi_diagnostics"],
            otaSchema: 1
        )
        let repository = DeviceRepository(context: context)
        let merged = try await repository.addFromDiscovery(status: status,
            fallbackHost: "hid-helper-save.local", displayName: "New Name", token: nil, api: MockAPIClient())
        XCTAssertEqual(merged.displayName, "Saved")
        XCTAssertEqual(merged.mdnsHost, "hid-helper-save.local")
        XCTAssertEqual(merged.staIP, "192.168.2.88")
        XCTAssertEqual(merged.apiToken, "keep-token")
        XCTAssertTrue(merged.capabilities.contains("ble_control"))
        XCTAssertTrue(merged.capabilities.contains("wifi_control"))
        XCTAssertEqual(try context.fetch(FetchDescriptor<StoredDevice>()).count, 1)
    }

    func testWiFiFirstThenBLEMergePreservesExistingFields() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: StoredDevice.self, configurations: config)
        let context = ModelContext(container)
        let existing = StoredDevice(deviceId: "same-id", displayName: "Friendly", mdnsHost: "hid-helper.local",
            staIP: "10.0.0.8", apiToken: "secret", capabilities: ["wifi_control"])
        context.insert(existing); try context.save()
        let metadata = BLEDeviceMetadata(product: "InputPilot", board: "esp32-s3-zero-4mb", deviceId: "same-id",
            deviceName: "usb-hid-s3", firmware: "0.8.0", protocolVersion: 1, otaSchema: 1,
            capabilities: ["ble_control"], authRequired: false)
        let merged = try DeviceRepository(context: context).addOrMergeBluetooth(metadata: metadata,
            displayName: "Replacement", token: nil)
        XCTAssertEqual(merged.displayName, "Friendly")
        XCTAssertEqual(merged.mdnsHost, "hid-helper.local")
        XCTAssertEqual(merged.staIP, "10.0.0.8")
        XCTAssertEqual(merged.apiToken, "secret")
        XCTAssertTrue(merged.bluetoothDiscovered)
        XCTAssertEqual(Set(merged.capabilities), Set(["wifi_control", "ble_control"]))
        XCTAssertEqual(try context.fetch(FetchDescriptor<StoredDevice>()).count, 1)
    }
}
