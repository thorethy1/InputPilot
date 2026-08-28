import SwiftData
import XCTest
@testable import InputPilot

@MainActor
final class DeviceRepositoryTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var mockAPI: MockAPIClient!
    private var repository: DeviceRepository!

    override func setUpWithError() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: StoredDevice.self, configurations: config)
        context = ModelContext(container)
        mockAPI = MockAPIClient()
        repository = DeviceRepository(context: context)
    }

    override func tearDownWithError() throws {
        container = nil
        context = nil
        mockAPI = nil
        repository = nil
    }

    func testSetJiggleUpdatesEnabledFlag() async throws {
        let device = StoredDevice(
            deviceId: "abc123",
            displayName: "Test Device",
            mdnsHost: "hid-helper-abc123.local",
            staIP: "192.168.2.50",
            jiggleEnabled: false
        )
        context.insert(device)
        try context.save()

        let baseURL = URL(string: "http://192.168.2.50/")!
        mockAPI.setJiggleResults[baseURL] = .success(())

        try await repository.setJiggle(device, enabled: true, api: mockAPI)

        XCTAssertTrue(device.jiggleEnabled)
        XCTAssertEqual(mockAPI.setJiggleCalls.count, 1)
        XCTAssertEqual(mockAPI.setJiggleCalls.first?.1, true)
    }

    func testSetJiggleFallsBackToStaIP() async throws {
        let device = StoredDevice(
            deviceId: "abc456",
            displayName: "Fallback Device",
            mdnsHost: "missing.local",
            staIP: "192.168.2.99",
            jiggleEnabled: false
        )
        context.insert(device)
        try context.save()

        let mdnsURL = URL(string: "http://missing.local/")!
        let ipURL = URL(string: "http://192.168.2.99/")!
        mockAPI.setJiggleResults[mdnsURL] = .success(())
        mockAPI.setJiggleResults[ipURL] = .failure(DeviceAPIError.invalidResponse)

        try await repository.setJiggle(device, enabled: true, api: mockAPI)

        XCTAssertTrue(device.jiggleEnabled)
        XCTAssertEqual(mockAPI.setJiggleCalls.count, 2)
        XCTAssertEqual(mockAPI.setJiggleCalls.last?.0, mdnsURL)
    }

    func testRenamePersistsDisplayName() throws {
        let device = StoredDevice(
            deviceId: "rename-me",
            displayName: "Old Name",
            mdnsHost: "hid.local"
        )
        context.insert(device)
        try context.save()

        try repository.rename(device, name: "Desk Mouse")

        XCTAssertEqual(device.displayName, "Desk Mouse")
    }

    func testSetKeepAwakePersistsIndependentSchedules() async throws {
        let device = StoredDevice(deviceId: "keep-awake", displayName: "Desk", mdnsHost: "desk.local")
        context.insert(device)
        try context.save()
        let url = URL(string: "http://desk.local/")!
        mockAPI.setKeepAwakeResults[url] = .success(())
        let settings = KeepAwakeSettings(moveEnabled: true, moveIntervalMs: 30_000,
                                         clickEnabled: true, clickIntervalMs: 60_000)

        try await repository.setKeepAwake(device, settings: settings, api: mockAPI)

        XCTAssertTrue(device.jiggleEnabled)
        XCTAssertEqual(device.moveIntervalMs, 30_000)
        XCTAssertTrue(device.clickEnabled)
        XCTAssertEqual(device.clickIntervalMs, 60_000)
        XCTAssertEqual(mockAPI.setKeepAwakeCalls.first?.1, settings)
    }

    func testAddPersistsProtocolCapabilitiesImmediately() async throws {
        let status = DeviceStatus(
            ok: true,
            name: "InputPilot",
            version: "0.6.0",
            deviceId: "aabbccddeeff",
            jiggle: false,
            jiggleIntervalMs: 10_000,
            mdns: "hid-helper-eeff.local",
            protocolVersion: 1,
            capabilities: ["keyboard_layout", "release_all"]
        )

        let stored = try await repository.addFromDiscovery(
            status: status,
            fallbackHost: "hid-helper-eeff.local",
            displayName: "Office",
            token: nil,
            api: mockAPI
        )

        XCTAssertEqual(stored.protocolVersion, 1)
        XCTAssertEqual(stored.capabilities, ["keyboard_layout", "release_all"])
        XCTAssertNotNil(stored.lastCapabilitiesUpdate)
    }

    func testAddByVPNAddressPersistsReachableAddress() async throws {
        let status = DeviceStatus(
            ok: true,
            name: "InputPilot",
            version: "0.8.4",
            deviceId: "vpn-device",
            jiggle: false,
            jiggleIntervalMs: 10_000,
            staIp: "192.168.2.161",
            mdns: "hid-helper-vpn.local"
        )

        let stored = try await repository.addFromDiscovery(
            status: status,
            fallbackHost: "100.64.0.12",
            displayName: "Remote InputPilot",
            token: nil,
            api: mockAPI
        )

        XCTAssertEqual(stored.staIP, "100.64.0.12")
        XCTAssertEqual(stored.mdnsHost, "hid-helper-vpn.local")
    }

    func testHomePresenceStartsCheckingThenTracksOfflineAndReconnect() async throws {
        let device = StoredDevice(deviceId: "presence", displayName: "Desk", mdnsHost: "desk.local")
        context.insert(device); try context.save()
        let viewModel = HomeViewModel(apiClient: mockAPI)
        XCTAssertEqual(viewModel.wifiState(for: device.deviceId), .checking)

        await viewModel.refreshDevice(device, context: context)
        XCTAssertEqual(viewModel.wifiState(for: device.deviceId), .offline)

        let url = URL(string: "http://desk.local/")!
        mockAPI.statusResults[url] = .success(DeviceStatus(
            ok: true, name: "InputPilot", version: "0.8.3", deviceId: "presence",
            jiggle: false, jiggleIntervalMs: 10_000, mdns: "desk.local",
            protocolVersion: 1, capabilities: ["wifi_control"], otaSchema: 1
        ))
        await viewModel.refreshDevice(device, context: context)
        XCTAssertEqual(viewModel.wifiState(for: device.deviceId), .reachable)
    }
}

final class DeviceEndpointResolverTests: XCTestCase {
    func testEndpointURLsPrefersDirectAddressThenMdns() {
        let urls = DeviceEndpointResolver.endpointURLs(
            mdnsHost: "hid-helper-a1b2.local",
            staIP: "192.168.2.161"
        )

        XCTAssertEqual(urls.count, 2)
        XCTAssertEqual(urls[0].absoluteString, "http://192.168.2.161/")
        XCTAssertEqual(urls[1].absoluteString, "http://hid-helper-a1b2.local/")
    }

    func testBaseURLAddsSchemeAndTrailingSlash() {
        XCTAssertEqual(
            DeviceEndpointResolver.baseURL(from: "hid-helper.local")?.absoluteString,
            "http://hid-helper.local/"
        )
    }

    func testBaseURLPreservesExistingScheme() {
        XCTAssertEqual(
            DeviceEndpointResolver.baseURL(from: "http://192.168.2.161")?.absoluteString,
            "http://192.168.2.161/"
        )
    }

    func testEndpointURLsDeduplicatesSameHost() {
        let urls = DeviceEndpointResolver.endpointURLs(
            mdnsHost: "192.168.2.161",
            staIP: "192.168.2.161"
        )
        XCTAssertEqual(urls.count, 1)
    }

    func testSanitizeHostStripsInterfaceZone() {
        XCTAssertEqual(
            DeviceEndpointResolver.sanitizeHost("192.168.2.161%en0"),
            "192.168.2.161"
        )
    }

    func testBaseURLFromScopedIPv4() {
        XCTAssertEqual(
            DeviceEndpointResolver.baseURL(from: "192.168.2.161%en0")?.absoluteString,
            "http://192.168.2.161/"
        )
    }

    func testBaseURLWithPortFromScopedHost() {
        XCTAssertEqual(
            DeviceEndpointResolver.baseURL(host: "192.168.2.161%en0", port: 80)?.absoluteString,
            "http://192.168.2.161/"
        )
    }

    func testDirectProbeAddressWinsOverReportedLANAddress() {
        XCTAssertEqual(
            DeviceEndpointResolver.directAddress(
                reportedSTAIP: "192.168.2.161",
                fallbackHost: "100.64.0.12"
            ),
            "100.64.0.12"
        )
    }

    func testBonjourProbeUsesReportedDirectAddress() {
        XCTAssertEqual(
            DeviceEndpointResolver.directAddress(
                reportedSTAIP: "192.168.2.161",
                fallbackHost: "hid-helper-a1b2.local"
            ),
            "192.168.2.161"
        )
    }
}
