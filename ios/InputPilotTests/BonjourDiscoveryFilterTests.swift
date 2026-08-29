import XCTest
@testable import InputPilot

final class BonjourDiscoveryFilterTests: XCTestCase {
    func testAcceptsOnlyCurrentIdentityBearingAdvertisements() {
        XCTAssertTrue(BonjourDiscoveryFilter.isCandidate(
            serviceName: "InputPilot-AABB", host: "inputpilot-aabb.local",
            txt: ["id": "aabbccddeeff"]))
        XCTAssertFalse(BonjourDiscoveryFilter.isCandidate(
            serviceName: "InputPilot-AABB", host: "inputpilot-aabb.local", txt: [:]))
        XCTAssertFalse(BonjourDiscoveryFilter.isCandidate(
            serviceName: "hid-helper", host: "hid-helper.local",
            txt: ["id": "aabbccddeeff"]))
        XCTAssertFalse(BonjourDiscoveryFilter.isCandidate(
            serviceName: "InputPilot-AABB", host: "inputpilot-aabb.local",
            txt: ["id": "short"]))
    }

    func testDeduplicatesSameSecureIdentity() {
        let a = DiscoveredService(id: "1", deviceId: "aabbccddeeff", name: "InputPilot-AABB", host: "inputpilot-aabb.local", port: 80)
        let b = DiscoveredService(id: "2", deviceId: "AABBCCDDEEFF", name: "InputPilot-AABB", host: "192.168.2.20", port: 80)
        let result = BonjourDiscoveryFilter.deduplicate([a, b])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].host, "192.168.2.20")
    }
}
