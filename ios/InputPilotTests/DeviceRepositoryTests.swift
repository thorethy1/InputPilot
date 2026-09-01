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
        let refreshed = await DeviceRepository(context: context).refresh(device: device, api: api)
        XCTAssertTrue(refreshed)
        XCTAssertEqual(api.statusCalls, [url])
    }

    func testRefreshPrefersLastKnownIPWithoutBonjour() async throws {
        let container = try ModelContainer(
            for: StoredDevice.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let device = StoredDevice(
            deviceId: "aabbccddeeff",
            displayName: "Desk",
            mdnsHost: "inputpilot-eeff.local",
            staIP: "10.8.0.42"
        )
        context.insert(device)
        let api = MockAPIClient()
        let cachedIPURL = URL(string: "http://10.8.0.42/")!
        api.statusResults[cachedIPURL] = .success(DeviceStatus(
            ok: true, name: "InputPilot", version: "0.8.19", deviceId: device.deviceId,
            jiggle: false, jiggleIntervalMs: 30_000, staIp: "192.168.2.20",
            mdns: "inputpilot-eeff.local", protocolVersion: 2,
            capabilities: ["secure_protocol_v2", "wifi_transport"], otaSchema: 1
        ))

        let refreshed = await DeviceRepository(context: context).refresh(device: device, api: api)
        XCTAssertTrue(refreshed)
        XCTAssertEqual(api.statusCalls, [cachedIPURL])
        XCTAssertEqual(device.staIP, "10.8.0.42")
    }

    func testRefreshFallsBackToBonjourAndReplacesAStaleIP() async throws {
        let container = try ModelContainer(
            for: StoredDevice.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let device = StoredDevice(
            deviceId: "aabbccddeeff", displayName: "Desk",
            mdnsHost: "inputpilot-eeff.local", staIP: "192.168.2.20"
        )
        context.insert(device)
        let api = MockAPIClient()
        let staleURL = URL(string: "http://192.168.2.20/")!
        let bonjourURL = URL(string: "http://inputpilot-eeff.local/")!
        api.statusResults[bonjourURL] = .success(DeviceStatus(
            ok: true, name: "InputPilot", version: "0.8.19", deviceId: device.deviceId,
            jiggle: false, jiggleIntervalMs: 30_000, staIp: "192.168.2.44",
            mdns: "inputpilot-eeff.local", protocolVersion: 2,
            capabilities: ["secure_protocol_v2", "wifi_transport"], otaSchema: 1
        ))

        let refreshed = await DeviceRepository(context: context).refresh(device: device, api: api)

        XCTAssertTrue(refreshed)
        XCTAssertEqual(api.statusCalls, [staleURL, bonjourURL])
        XCTAssertEqual(device.staIP, "192.168.2.44")
    }

    func testRefreshAcceptsIdentityVerifiedSoftAPFallback() async throws {
        let container = try ModelContainer(
            for: StoredDevice.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let device = StoredDevice(
            deviceId: "aabbccddeeff", displayName: "Desk",
            mdnsHost: "inputpilot-eeff.local", staIP: "192.168.2.20"
        )
        context.insert(device)
        let api = MockAPIClient()
        let fallbackURL = URL(string: "http://192.168.4.1/")!
        api.statusResults[fallbackURL] = .success(DeviceStatus(
            ok: true, name: "InputPilot-Dupe9", version: "0.9.0-beta.2",
            deviceId: device.deviceId, jiggle: false, jiggleIntervalMs: 30_000,
            protocolVersion: 2, capabilities: ["secure_protocol_v2", "wifi_transport"],
            radioMode: "wifi+ble", otaSchema: 1
        ))

        let refreshed = await DeviceRepository(context: context).refresh(device: device, api: api)
        XCTAssertTrue(refreshed)
        XCTAssertEqual(api.statusCalls.last, fallbackURL)
        XCTAssertEqual(device.staIP, DeviceEndpointResolver.softAPHost)
    }

    func testBonjourValidatesAndCachesChangedIP() async throws {
        let container = try ModelContainer(
            for: StoredDevice.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let device = StoredDevice(
            deviceId: "aabbccddeeff",
            displayName: "Desk",
            mdnsHost: "inputpilot-eeff.local",
            staIP: "192.168.2.20"
        )
        context.insert(device)
        let browser = MockBonjourBrowser()
        let api = MockAPIClient()
        let updatedURL = URL(string: "http://192.168.2.44/")!
        api.statusResults[updatedURL] = .success(DeviceStatus(
            ok: true, name: "InputPilot", version: "0.8.19", deviceId: device.deviceId,
            jiggle: false, jiggleIntervalMs: 30_000, staIp: "192.168.2.44",
            mdns: "inputpilot-eeff.local", protocolVersion: 2,
            capabilities: ["secure_protocol_v2", "wifi_transport"], otaSchema: 1
        ))
        let viewModel = HomeViewModel(apiClient: api, bonjourBrowser: browser)
        viewModel.monitorBonjour(devices: [device], context: context)
        viewModel.monitorBonjour(devices: [device], context: context)

        browser.emit([DiscoveredService(
            id: "service", deviceId: device.deviceId, name: "InputPilot-EEFF",
            host: "192.168.2.44", port: 80, txt: ["id": device.deviceId]
        )])
        for _ in 0 ..< 20 where device.staIP != "192.168.2.44" {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(api.statusCalls, [updatedURL])
        XCTAssertEqual(device.staIP, "192.168.2.44")
        XCTAssertEqual(viewModel.wifiState(for: device.deviceId), .reachable)
        viewModel.stopBonjourMonitoring()
        XCTAssertEqual(browser.startCount, 1)
        XCTAssertEqual(browser.stopCount, 1)
    }

    func testBonjourDoesNotCacheAnUnverifiedIdentity() async throws {
        let container = try ModelContainer(
            for: StoredDevice.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let device = StoredDevice(
            deviceId: "aabbccddeeff", displayName: "Desk",
            mdnsHost: "inputpilot-eeff.local", staIP: "192.168.2.20"
        )
        context.insert(device)
        let browser = MockBonjourBrowser()
        let api = MockAPIClient()
        let candidateURL = URL(string: "http://192.168.2.99/")!
        api.statusResults[candidateURL] = .success(DeviceStatus(
            ok: true, name: "Other", version: "0.8.19", deviceId: "112233445566",
            jiggle: false, jiggleIntervalMs: 30_000, staIp: "192.168.2.99",
            mdns: "other.local", protocolVersion: 2,
            capabilities: ["secure_protocol_v2"], otaSchema: 1
        ))
        let viewModel = HomeViewModel(apiClient: api, bonjourBrowser: browser)
        viewModel.monitorBonjour(devices: [device], context: context)

        browser.emit([DiscoveredService(
            id: "service", deviceId: device.deviceId, name: "InputPilot-EEFF",
            host: "192.168.2.99", port: 80, txt: ["id": device.deviceId]
        )])
        for _ in 0 ..< 20 where api.statusCalls.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(api.statusCalls, [candidateURL])
        XCTAssertEqual(device.staIP, "192.168.2.20")
        viewModel.stopBonjourMonitoring()
    }

    func testCachesLastKnownUSBIdentityAndWiFiNames() throws {
        let container = try ModelContainer(
            for: StoredDevice.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let device = StoredDevice(
            deviceId: "aabbccddeeff",
            displayName: "Desk",
            mdnsHost: "inputpilot-eeff.local"
        )
        context.insert(device)
        let cachedAt = Date(timeIntervalSince1970: 123)
        device.cacheUSBIdentity(
            USBIdentity(
                manufacturerName: "thorethy",
                productName: "InputPilot Custom",
                vid: 0xCAFE,
                pid: 0x4001,
                serialNumber: "DESK-01"
            ),
            at: cachedAt
        )
        device.cacheWiFiNetworks(["Office", "Guest"], at: cachedAt)
        try context.save()

        let stored = try XCTUnwrap(context.fetch(FetchDescriptor<StoredDevice>()).first)
        XCTAssertEqual(stored.cachedUSBIdentity?.manufacturerName, "thorethy")
        XCTAssertEqual(stored.cachedUSBIdentity?.productName, "InputPilot Custom")
        XCTAssertEqual(stored.cachedUSBIdentity?.serialNumber, "DESK-01")
        XCTAssertEqual(stored.cachedWiFiNetworks, ["Office", "Guest"])
        XCTAssertEqual(stored.usbIdentityUpdatedAt, cachedAt)
        XCTAssertEqual(stored.wifiNetworksUpdatedAt, cachedAt)
    }

    func testFriendlyDiscoveryNameMigratesOnlyLegacyAutomaticName() {
        let metadata = BLEDeviceMetadata(
            product: "InputPilot", board: "esp32-s3-zero-4mb",
            deviceId: "aabbccddeeff", deviceName: "InputPilot-Dupe9",
            firmware: "0.9.0-beta.2", protocolVersion: 2, otaSchema: 1,
            capabilities: ["secure_protocol_v2"], trustRequired: true
        )
        let legacy = StoredDevice(
            deviceId: metadata.deviceId, displayName: "InputPilot-DE94", mdnsHost: ""
        )
        let custom = StoredDevice(
            deviceId: metadata.deviceId, displayName: "Standing Desk", mdnsHost: ""
        )

        DeviceMerge.bluetooth(metadata, into: legacy)
        DeviceMerge.bluetooth(metadata, into: custom)

        XCTAssertEqual(legacy.displayName, "InputPilot-Dupe9")
        XCTAssertEqual(custom.displayName, "Standing Desk")
    }

    func testBasicUSBRefreshPreservesCachedManufacturer() {
        let device = StoredDevice(
            deviceId: "aabbccddeeff",
            displayName: "Desk",
            mdnsHost: ""
        )
        device.cacheUSBIdentity(USBIdentity(
            manufacturerName: "thorethy",
            productName: "InputPilot",
            vid: 0xCAFE,
            pid: 0x4001,
            serialNumber: "DESK-01"
        ))

        device.cacheUSBIdentity(USBIdentity(
            manufacturerName: nil,
            productName: "InputPilot Updated",
            vid: 0xCAFE,
            pid: 0x4002,
            serialNumber: "DESK-02"
        ))

        XCTAssertEqual(device.cachedUSBIdentity?.manufacturerName, "thorethy")
        XCTAssertEqual(device.cachedUSBIdentity?.productName, "InputPilot Updated")
        XCTAssertEqual(device.cachedUSBIdentity?.pid, 0x4002)
    }
}

final class DeviceEndpointResolverTests: XCTestCase {
    func testEndpointsPreferDirectAddressAndDeduplicate() {
        XCTAssertEqual(DeviceEndpointResolver.endpointURLs(mdnsHost: "inputpilot-eeff.local", staIP: "192.168.2.20").map(\.absoluteString), ["http://192.168.2.20/", "http://inputpilot-eeff.local/"])
        XCTAssertEqual(DeviceEndpointResolver.endpointURLs(mdnsHost: "192.168.2.20", staIP: "192.168.2.20").count, 1)
    }

    func testProbeEndpointsUseSoftAPAsLastFallback() {
        XCTAssertEqual(
            DeviceEndpointResolver.probeURLs(mdnsHost: "inputpilot-eeff.local", staIP: "192.168.2.20").map(\.absoluteString),
            ["http://192.168.2.20/", "http://inputpilot-eeff.local/", "http://192.168.4.1/"]
        )
        XCTAssertEqual(
            DeviceEndpointResolver.probeURLs(mdnsHost: "192.168.4.1", staIP: "192.168.4.1").map(\.absoluteString),
            ["http://192.168.4.1/"]
        )
    }

    func testDirectIPv4AddressRejectsBonjourHostnames() {
        XCTAssertEqual(DeviceEndpointResolver.directIPv4Address(from: "192.168.2.44%en0"), "192.168.2.44")
        XCTAssertNil(DeviceEndpointResolver.directIPv4Address(from: "inputpilot-eeff.local"))
        XCTAssertNil(DeviceEndpointResolver.directIPv4Address(from: "192.168.2.999"))
    }
}
