import XCTest
@testable import InputPilot

@MainActor
final class AddDeviceWizardViewModelTests: XCTestCase {
    private func metadata(protocolVersion: Int = 2, capabilities: [String] = ["secure_protocol_v2", "ble_transport", "wifi_transport", "secure_wifi_setup"]) -> BLEDeviceMetadata {
        BLEDeviceMetadata(product: "InputPilot", board: "esp32-s3-zero-4mb", deviceId: "aabbccddeeff", deviceName: "Desk", firmware: "0.8.12", protocolVersion: protocolVersion, otaSchema: 1, capabilities: capabilities, trustRequired: true)
    }

    func testWebFlasherUsesOfficialHTTPSPage() {
        XCTAssertEqual(InputPilotLinks.webFlasher.scheme, "https")
        XCTAssertEqual(InputPilotLinks.webFlasher.host, "thorethy1.github.io")
        XCTAssertEqual(InputPilotLinks.webFlasher.absoluteString, "https://thorethy1.github.io/InputPilot/en/")
    }

    func testUSBTrustIsRequiredBeforeBluetoothStep() {
        let model = AddDeviceWizardViewModel(browser: MockBonjourBrowser(), apiClient: MockAPIClient())
        XCTAssertEqual(model.step, .securePairing)
        model.chooseSecureSetup()
        model.continueSecureSetup()
        XCTAssertEqual(model.step, .securePairing)
        XCTAssertNotNil(model.errorMessage)
    }

    func testFirstRunIntroducesHardwareBeforeRequestingUSBTrust() {
        let model = AddDeviceWizardViewModel(
            flow: .firstRun,
            browser: MockBonjourBrowser(),
            apiClient: MockAPIClient()
        )

        XCTAssertEqual(model.step, .welcome)
        model.continueFromWelcome()
        XCTAssertEqual(model.step, .hardware)
        model.continueFromHardware()
        XCTAssertEqual(model.step, .securePairing)
        model.backFromPairing()
        XCTAssertEqual(model.step, .hardware)
        model.backToWelcome()
        XCTAssertEqual(model.step, .welcome)
    }

    func testRegularAddDeviceFlowStillStartsAtUSBTrust() {
        let model = AddDeviceWizardViewModel(
            browser: MockBonjourBrowser(),
            apiClient: MockAPIClient()
        )
        XCTAssertEqual(model.flow, .addDevice)
        XCTAssertEqual(model.step, .securePairing)
    }

    func testInterruptedFirstRunResumesAtConnectionTestForSavedDevice() {
        let model = AddDeviceWizardViewModel(
            flow: .firstRun,
            browser: MockBonjourBrowser(),
            apiClient: MockAPIClient()
        )
        let device = StoredDevice(
            deviceId: "aabbccddeeff",
            displayName: "Desk",
            mdnsHost: "",
            protocolVersion: 2,
            capabilities: ["secure_protocol_v2", "ble_transport"],
            bluetoothDiscovered: true
        )

        model.updateKnownDevices([device])

        XCTAssertEqual(model.savedDeviceId, "aabbccddeeff")
        XCTAssertEqual(model.step, .connectionTest)
        model.connectionTestPassed()
        XCTAssertEqual(model.step, .mouseTest)
        model.mouseTestPassed()
        XCTAssertEqual(model.step, .keyboardTest)
        model.keyboardTestPassed()
        XCTAssertEqual(model.step, .complete)
    }

    func testOnlyPairedIdentityAndProtocolV2AreAccepted() {
        let model = AddDeviceWizardViewModel(browser: MockBonjourBrowser(), apiClient: MockAPIClient())
        model.chooseSecureSetup(); model.didPairSecurely(deviceId: "aabbccddeeff"); model.continueSecureSetup()
        model.selectBluetooth(metadata(protocolVersion: 1))
        XCTAssertEqual(model.step, .bleScanning)
        XCTAssertTrue(model.errorMessage?.contains("Reflash") == true)
        model.errorMessage = nil
        model.selectBluetooth(metadata())
        XCTAssertEqual(model.step, .confirmBLE(metadata()))
    }

    func testMissingSecureWiFiCapabilityUsesCompleteBluetoothOnlyPath() {
        let model = AddDeviceWizardViewModel(browser: MockBonjourBrowser(), apiClient: MockAPIClient())
        model.chooseSecureSetup(); model.didPairSecurely(deviceId: "aabbccddeeff"); model.continueSecureSetup()
        model.selectBluetooth(metadata(capabilities: ["secure_protocol_v2", "ble_transport"]))
        XCTAssertEqual(model.step, .confirmBLE(metadata(capabilities: ["secure_protocol_v2", "ble_transport"])))
        XCTAssertFalse(model.supportsWiFiSetup)
        XCTAssertFalse(model.configureWiFi)
    }

    func testMissingBluetoothTransportIsRejected() {
        let model = AddDeviceWizardViewModel(browser: MockBonjourBrowser(), apiClient: MockAPIClient())
        model.chooseSecureSetup(); model.didPairSecurely(deviceId: "aabbccddeeff"); model.continueSecureSetup()
        model.selectBluetooth(metadata(capabilities: ["secure_protocol_v2", "secure_wifi_setup"]))
        XCTAssertEqual(model.step, .bleScanning)
    }

    func testSecureWiFiHandoffDoesNotCacheTemporarySoftAP() throws {
        let connecting = try JSONDecoder().decode(
            SecureWiFiStatus.self,
            from: Data(#"{"state":"soft_ap","ip":"","device_id":"aabbccddeeff","provisioning":{"state":"connecting","error":""}}"#.utf8)
        )
        let connected = try JSONDecoder().decode(
            SecureWiFiStatus.self,
            from: Data(#"{"state":"connected","ip":"172.20.10.2","device_id":"aabbccddeeff","provisioning":{"state":"connected","error":""}}"#.utf8)
        )
        let failed = try JSONDecoder().decode(
            SecureWiFiStatus.self,
            from: Data(#"{"state":"soft_ap","ip":"","device_id":"aabbccddeeff","provisioning":{"state":"failed","error":"network_unreachable"}}"#.utf8)
        )

        XCTAssertEqual(connecting.handoffState(expectedDeviceId: "aabbccddeeff"), .connecting)
        XCTAssertEqual(
            connected.handoffState(expectedDeviceId: "AABBCCDDEEFF"),
            .station("172.20.10.2")
        )
        XCTAssertEqual(
            failed.handoffState(expectedDeviceId: "aabbccddeeff"),
            .failed("network_unreachable")
        )
        XCTAssertNil(connected.handoffState(expectedDeviceId: "112233445566"))
    }
}
