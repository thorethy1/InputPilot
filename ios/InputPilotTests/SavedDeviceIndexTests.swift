import SwiftData
import XCTest
@testable import InputPilot

final class SavedDeviceIndexTests: XCTestCase {
    func testMatchesOnlyStableIdentityOrKnownAddress() {
        let device = StoredDevice(deviceId: "aabbccddeeff", displayName: "Desk", mdnsHost: "inputpilot-eeff.local", staIP: "192.168.2.20")
        let index = SavedDeviceIndex(devices: [device])
        XCTAssertEqual(index.match(candidate: DiscoveredService(id: "1", deviceId: "AABBCCDDEEFF", name: "InputPilot", host: "other.local", port: 80))?.deviceId, device.deviceId)
        XCTAssertEqual(index.match(candidate: DiscoveredService(id: "2", deviceId: nil, name: "InputPilot", host: "192.168.2.20", port: 80))?.deviceId, device.deviceId)
    }
}

@MainActor
final class DeviceRepositoryMergeTests: XCTestCase {
    func testBLEAndWiFiMergeIntoOneIdentity() async throws {
        let container = try ModelContainer(for: StoredDevice.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let repository = DeviceRepository(context: context)
        let metadata = BLEDeviceMetadata(product: "InputPilot", board: "esp32-s3-zero-4mb", deviceId: "aabbccddeeff", deviceName: "Desk", firmware: "0.8.11", protocolVersion: 2, otaSchema: 1, capabilities: ["secure_protocol_v2", "ble_transport"], trustRequired: true)
        _ = try repository.addOrMergeBluetooth(metadata: metadata, displayName: "Desk")
        let status = DeviceStatus(ok: true, name: "InputPilot", version: "0.8.11", deviceId: metadata.deviceId, jiggle: false, jiggleIntervalMs: 30_000, staIp: "192.168.2.20", mdns: "inputpilot-eeff.local", protocolVersion: 2, capabilities: ["secure_protocol_v2", "wifi_transport"], otaSchema: 1)
        let merged = try await repository.addFromDiscovery(status: status, fallbackHost: "inputpilot-eeff.local", displayName: "Replacement")
        XCTAssertEqual(merged.displayName, "Desk")
        XCTAssertEqual(Set(merged.capabilities), Set(["secure_protocol_v2", "ble_transport", "wifi_transport"]))
        XCTAssertEqual(try context.fetch(FetchDescriptor<StoredDevice>()).count, 1)
    }
}
