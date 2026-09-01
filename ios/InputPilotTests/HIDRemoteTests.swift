import CoreBluetooth
import XCTest
@testable import InputPilot

final class HIDRemoteTests: XCTestCase {
    func testReconnectGateRequiresAdvertisementAfterConnectionFailure() {
        var gate = BLEReconnectGate()
        XCTAssertTrue(gate.permitsCachedPeripheral)

        gate.connectionAttemptFailed()
        XCTAssertFalse(gate.permitsCachedPeripheral)

        gate.advertisementObserved()
        XCTAssertTrue(gate.permitsCachedPeripheral)
    }

    func testDiagnosticsDecodeActualBLEAdvertisingState() throws {
        let data = Data(#"{"product":"InputPilot","firmware":"0.9.0-beta.2","board":"esp32-s3-zero-4mb","protocol":2,"otaSchema":1,"deviceId":"aabbccddeeff","ble":{"connected":false,"advertising":true,"advertisingRecoveries":2,"advertisingRecoveryFailures":1}}"#.utf8)
        let metadata = try JSONDecoder().decode(DiagnosticsMetadata.self, from: data)
        XCTAssertEqual(metadata.ble?.connected, false)
        XCTAssertEqual(metadata.ble?.advertising, true)
        XCTAssertEqual(metadata.ble?.advertisingRecoveries, 2)
        XCTAssertEqual(metadata.ble?.advertisingRecoveryFailures, 1)
    }

    func testUSBIdentityDecodesSecureProtocolResponse() throws {
        let data = Data(#"{"manufacturer_name":"thorethy","product_name":"InputPilot","vid":51966,"pid":16385,"serial_number":"Desk-01"}"#.utf8)
        let identity = try JSONDecoder().decode(USBIdentity.self, from: data)
        XCTAssertEqual(identity, USBIdentity(manufacturerName: "thorethy", productName: "InputPilot", vid: 0xCAFE, pid: 0x4001, serialNumber: "Desk-01"))
    }

    func testUSBIdentityDecodesLegacyResponseWithoutManufacturer() throws {
        let data = Data(#"{"product_name":"InputPilot","vid":51966,"pid":16385,"serial_number":"Desk-01"}"#.utf8)
        let identity = try JSONDecoder().decode(USBIdentity.self, from: data)
        XCTAssertNil(identity.manufacturerName)
    }
    private func firmwareImage(protocolVersion: Int = 2) -> Data {
        var data = Data(repeating: 0xff, count: FirmwareImageMetadata.minimumSize)
        data[0] = 0xe9
        data.replaceSubrange(32..<36, with: FirmwareImageMetadata.appDescriptorMagic)
        let metadata = "INPUTPILOT-META:product=InputPilot;board=esp32-s3-zero-4mb;version=0.8.11;protocol=\(protocolVersion);otaSchema=1;\0"
        data.replaceSubrange(128..<(128 + metadata.utf8.count), with: metadata.utf8)
        return data
    }

    func testFirmwareMetadataRequiresProtocolV2() throws {
        XCTAssertEqual(try FirmwareImageMetadata.parseAndValidate(firmwareImage()).protocolVersion, 2)
        XCTAssertThrowsError(try FirmwareImageMetadata.parseAndValidate(firmwareImage(protocolVersion: 1)))
    }

    func testSecureOTATransportEligibility() {
        let caps: Set<String> = ["secure_ota", "wifi_transport"]
        XCTAssertTrue(FirmwareUpdateManager.wifiOTAAvailable(hasSecurePairing: true, capabilities: caps, hasEndpoints: true))
        XCTAssertFalse(FirmwareUpdateManager.wifiOTAAvailable(hasSecurePairing: false, capabilities: caps, hasEndpoints: true))
        XCTAssertFalse(FirmwareUpdateManager.wifiOTAAvailable(hasSecurePairing: true, capabilities: ["wifi_transport"], hasEndpoints: true))
    }

    func testWindowedWiFiOTAReadyNegotiation() {
        let parameters = TCPHIDControlTransport.windowedParameters(
            from: "ota ready 0 window=4096 chunk=128"
        )
        XCTAssertEqual(parameters?.window, 4096)
        XCTAssertEqual(parameters?.chunk, 128)
        XCTAssertEqual(parameters?.binary, false)
        let binary = TCPHIDControlTransport.windowedParameters(
            from: "ota ready 0 window=32768 chunk=2048 binary=1"
        )
        XCTAssertEqual(binary?.window, 32768)
        XCTAssertEqual(binary?.chunk, 2048)
        XCTAssertEqual(binary?.binary, true)
        XCTAssertNil(TCPHIDControlTransport.windowedParameters(from: "ota ready 0"))
        XCTAssertNil(TCPHIDControlTransport.windowedParameters(from: "ota ready 0 window=4096 chunk=512"))
    }

    func testBLEOTAPayloadFitsEncryptedATTWrite() {
        XCTAssertEqual(FirmwareUpdateManager.bleFirmwarePayloadSize(advertised: 500, maximumWriteLength: 512), 483)
        XCTAssertEqual(FirmwareUpdateManager.bleFirmwarePayloadSize(advertised: 500, maximumWriteLength: 182), 153)
        XCTAssertNil(FirmwareUpdateManager.bleFirmwarePayloadSize(advertised: 500, maximumWriteLength: 156))
        XCTAssertNil(FirmwareUpdateManager.bleFirmwarePayloadSize(advertised: 500, maximumWriteLength: 29))
    }

    @MainActor func testTransportSelectionContainsNoFallbackTransport() {
        XCTAssertEqual(HIDConnectionManager.candidateKinds(mode: .automatic, lowLatency: true), [.bluetooth, .tcp])
        XCTAssertEqual(HIDConnectionManager.candidateKinds(mode: .automatic, lowLatency: false), [.tcp, .bluetooth])
        XCTAssertEqual(HIDConnectionManager.candidateKinds(mode: .wifiOnly, lowLatency: false), [.tcp])
    }

    func testWiFiSessionOwnershipIsSharedPerIdentityAndEndpoint() async {
        let first = InputPilotWiFiManager.session(host: "inputpilot-eeff.local", deviceId: "aabbccddeeff")
        let second = InputPilotWiFiManager.session(host: "INPUTPILOT-EEFF.LOCAL", deviceId: "AABBCCDDEEFF")
        XCTAssertTrue(first === second)
        await InputPilotWiFiManager.removeSessions(deviceId: "aabbccddeeff")
    }

    func testBinaryAndTCPEventEncoding() {
        XCTAssertEqual(Array(HIDEvent.keyboardReport(modifiers: 0x40, usage: 0x14).binary), [1, 0x13, 0x40, 0x14])
        XCTAssertEqual(HIDEvent.keyboardReport(modifiers: 0x40, usage: 0x14).line, "report 64 20")
        XCTAssertEqual(Array(HIDEvent.mouseMove(258, -2).binary), [1, 1, 2, 1, 254, 255])
    }

    func testBLEWritePolicyAcknowledgesStateChanges() {
        let properties: CBCharacteristicProperties = [.write, .writeWithoutResponse]
        XCTAssertEqual(BLEHIDControlTransport.writeType(for: .mouseMove(1, 2), properties: properties), .withoutResponse)
        XCTAssertEqual(BLEHIDControlTransport.writeType(for: .releaseAll, properties: properties), .withResponse)
    }

    @MainActor func testProtocolV1IsRejectedBeforeSending() async {
        let transport = MockTransport(kind: .bluetooth, available: true)
        let manager = HIDConnectionManager(ble: transport, tcp: transport, protocolVersion: 1)
        let sent = await manager.send(.click(.left))
        XCTAssertFalse(sent)
        XCTAssertTrue(transport.events.isEmpty)
        XCTAssertEqual(manager.connectionSummary, "Firmware must be reflashed")
    }

    @MainActor func testSecureTransportsCanFailOver() async {
        let ble = MockTransport(kind: .bluetooth, available: false)
        let tcp = MockTransport(kind: .tcp, available: true)
        let manager = HIDConnectionManager(ble: ble, tcp: tcp,
            capabilities: ["ble_transport", "wifi_transport", "mouse_click"])
        let sent = await manager.send(.click(.left))
        XCTAssertTrue(sent)
        XCTAssertEqual(tcp.events, [.click(.left)])
        XCTAssertEqual(manager.activeTransport, .tcp)
    }

    @MainActor func testUnavailableWiFiAuthenticationDoesNotMaskReadyBluetooth() {
        let ble = MockTransport(kind: .bluetooth, state: .ready)
        let tcp = MockTransport(kind: .tcp, state: .authenticationFailed)
        let manager = HIDConnectionManager(
            ble: ble, tcp: tcp,
            capabilities: ["ble_transport", "wifi_transport", "mouse_click"]
        )
        XCTAssertEqual(manager.connectionSummary, "Ready Bluetooth")
    }

    func testSemanticVersionsCompareNumerically() {
        XCTAssertLessThan(SemanticVersion("0.8.9")!, SemanticVersion("0.8.11")!)
        XCTAssertLessThan(SemanticVersion("0.9.0-beta.1")!, SemanticVersion("0.9.0-beta.2")!)
        XCTAssertLessThan(SemanticVersion("0.9.0-beta.9")!, SemanticVersion("0.9.0")!)
    }

    func testLaterBetaFirmwareIsAnUpdateAndStableSupersedesBeta() {
        func manifest(_ version: String) -> FirmwareManifest {
            FirmwareManifest(
                product: "InputPilot", version: version, board: "esp32-s3-zero-4mb",
                protocolVersion: 2, otaSchema: 1, size: 100, sha256: String(repeating: "a", count: 64)
            )
        }
        XCTAssertEqual(
            FirmwareReleaseEvaluator.evaluate(
                installed: "0.9.0-beta.1", manifest: manifest("0.9.0-beta.2"),
                deviceOTASchema: 1, appVersion: "0.9.0"
            ),
            .updateAvailable("0.9.0-beta.2")
        )
        XCTAssertEqual(
            FirmwareReleaseEvaluator.evaluate(
                installed: "0.9.0-beta.2", manifest: manifest("0.9.0"),
                deviceOTASchema: 1, appVersion: "0.9.0"
            ),
            .updateAvailable("0.9.0")
        )
    }

    @MainActor func testBetaReleaseSelectionSkipsRollingFeedAndStableReleases() throws {
        let data = Data(#"""
        [
          {"tag_name":"beta","draft":false,"prerelease":true,"assets":[{"name":"altstore-source.json","browser_download_url":"https://example.com/feed"}]},
          {"tag_name":"v0.8.19","draft":false,"prerelease":false,"assets":[]},
          {"tag_name":"v0.9.0-beta.2","draft":false,"prerelease":true,"assets":[
            {"name":"firmware-manifest.json","browser_download_url":"https://example.com/manifest"},
            {"name":"firmware.bin","browser_download_url":"https://example.com/firmware"}
          ]}
        ]
        """#.utf8)
        let release = try GitHubFirmwareSource.selectRelease(from: data, channel: .beta)
        XCTAssertEqual(release.tagName, "v0.9.0-beta.2")
    }

    @MainActor func testStableReleaseSelectionRejectsPrerelease() {
        let data = Data(#"{"tag_name":"v0.9.0-beta.1","draft":false,"prerelease":true,"assets":[]}"#.utf8)
        XCTAssertThrowsError(try GitHubFirmwareSource.selectRelease(from: data, channel: .stable))
    }
}

private final class MockTransport: HIDControlTransport {
    let kind: TransportKind
    var state: TransportConnectionState
    var isAvailable: Bool { state == .ready }
    var events: [HIDEvent] = []
    init(kind: TransportKind, available: Bool) {
        self.kind = kind; state = available ? .ready : .offline
    }
    init(kind: TransportKind, state: TransportConnectionState) {
        self.kind = kind; self.state = state
    }
    func connect() async {}
    func send(_ event: HIDEvent) async throws { events.append(event) }
    func disconnect() async { state = .offline }
}
