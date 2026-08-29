import XCTest
@testable import InputPilot

final class DeviceAPIClientTests: XCTestCase {
    func testDecodesSecureDiscoveryMetadata() throws {
        let json = Data(#"{"ok":true,"name":"InputPilot-A1B2","version":"0.8.11","device_id":"aabbccddeeff","protocol_version":2,"ota_schema":1,"capabilities":["secure_protocol_v2","ble_transport","wifi_transport","secure_ota"]}"#.utf8)
        let status = try JSONDecoder().decode(DeviceStatus.self, from: json)
        XCTAssertEqual(status.deviceId, "aabbccddeeff")
        XCTAssertEqual(status.protocolVersion, 2)
        XCTAssertTrue(status.capabilities.contains("secure_protocol_v2"))
        XCTAssertTrue(status.capabilities.contains("secure_ota"))
    }

    func testMissingProtocolMetadataIsNotUpgradedImplicitly() throws {
        let status = try JSONDecoder().decode(DeviceStatus.self, from: Data(#"{"name":"InputPilot","version":"0.8.0"}"#.utf8))
        XCTAssertEqual(status.protocolVersion, 0)
        XCTAssertTrue(status.capabilities.isEmpty)
    }
}
