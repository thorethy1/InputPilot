import SwiftData
import XCTest
@testable import InputPilot

@MainActor
final class DeviceRepositoryTests: XCTestCase {
    func testDiscoveryPersistsSecureProtocolIdentity() async throws {
        let container = try ModelContainer(for: StoredDevice.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let status = DeviceStatus(ok: true, name: "InputPilot", version: "0.8.11", deviceId: "aabbccddeeff", jiggle: false, jiggleIntervalMs: 30_000, staIp: "192.168.2.20", mdns: "inputpilot-eeff.local", protocolVersion: 2, capabilities: ["secure_protocol_v2", "wifi_transport"], otaSchema: 1)
        let stored = try await DeviceRepository(context: context).addFromDiscovery(status: status, fallbackHost: "inputpilot-eeff.local", displayName: "Desk")
        XCTAssertEqual(stored.deviceId, "aabbccddeeff")
        XCTAssertEqual(stored.protocolVersion, 2)
        XCTAssertEqual(Set(stored.capabilities), Set(["secure_protocol_v2", "wifi_transport"]))
    }

    func testRefreshUsesPublicStatusOnly() async throws {
        let container = try ModelContainer(for: StoredDevice.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let device = StoredDevice(deviceId: "aabbccddeeff", displayName: "Desk", mdnsHost: "inputpilot-eeff.local")
        context.insert(device); try context.save()
        let api = MockAPIClient()
        let url = URL(string: "http://inputpilot-eeff.local/")!
        api.statusResults[url] = .success(DeviceStatus(ok: true, name: "InputPilot", version: "0.8.11", deviceId: device.deviceId, jiggle: false, jiggleIntervalMs: 30_000, mdns: "inputpilot-eeff.local", protocolVersion: 2, capabilities: ["secure_protocol_v2"], otaSchema: 1))
        XCTAssertTrue(await DeviceRepository(context: context).refresh(device: device, api: api))
        XCTAssertEqual(api.statusCalls, [url])
    }
}

final class DeviceEndpointResolverTests: XCTestCase {
    func testEndpointsPreferDirectAddressAndDeduplicate() {
        XCTAssertEqual(DeviceEndpointResolver.endpointURLs(mdnsHost: "inputpilot-eeff.local", staIP: "192.168.2.20").map(\.absoluteString), ["http://192.168.2.20/", "http://inputpilot-eeff.local/"])
        XCTAssertEqual(DeviceEndpointResolver.endpointURLs(mdnsHost: "192.168.2.20", staIP: "192.168.2.20").count, 1)
    }
}
