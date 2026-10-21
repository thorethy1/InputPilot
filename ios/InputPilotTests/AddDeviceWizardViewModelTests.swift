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
        XCTAssertEqual(model.step, .permissions)
        model.continueFromPermissions()
        XCTAssertEqual(model.step, .securePairing)
        model.backFromPairing()
        XCTAssertEqual(model.step, .permissions)
        model.backFromPermissions()
        XCTAssertEqual(model.step, .hardware)
        model.backToWelcome()
        XCTAssertEqual(model.step, .welcome)
    }

    func testUnpreparedHardwareRequiresExplicitFirmwareConfirmation() {
        for readiness in [SetupHardwareReadiness.needsFirmware, .needsHardware] {
            let model = AddDeviceWizardViewModel(
                flow: .firstRun, browser: MockBonjourBrowser(), apiClient: MockAPIClient()
            )
            model.continueFromWelcome()
            model.hardwareReadiness = readiness
            model.continueFromHardware()
            XCTAssertEqual(model.step, .firmware)

            model.continueFromFirmware()
            XCTAssertEqual(model.step, .firmware, "Opening the flasher must not imply a flashed board")
            XCTAssertNil(model.securelyPairedDeviceId)

            model.firmwareInstalled = true
            model.continueFromFirmware()
            XCTAssertEqual(model.step, .permissions)
            model.backFromPermissions()
            XCTAssertEqual(model.step, .firmware)
            XCTAssertTrue(model.firmwareInstalled)
            model.backToHardware()
            XCTAssertEqual(model.step, .hardware)
            XCTAssertEqual(model.hardwareReadiness, readiness)
        }
    }

    func testFlashingDoesNotBypassUSBTrust() {
        let model = AddDeviceWizardViewModel(
            flow: .firstRun, browser: MockBonjourBrowser(), apiClient: MockAPIClient()
        )
        model.continueFromWelcome()
        model.hardwareReadiness = .needsFirmware
        model.continueFromHardware()
        model.firmwareInstalled = true
        model.continueFromFirmware()
        model.continueFromPermissions()
        model.continueSecureSetup()

        XCTAssertEqual(model.step, .securePairing)
        XCTAssertNotNil(model.errorMessage)
    }

    func testCancellationClearsPreparationAndCredentialsWithoutCompletingSetup() {
        let model = AddDeviceWizardViewModel(
            flow: .firstRun, browser: MockBonjourBrowser(), apiClient: MockAPIClient()
        )
        model.hardwareReadiness = .needsFirmware
        model.firmwareInstalled = true
        model.homeWifiPassword = "temporary-password"
        model.didPairSecurely(deviceId: "aabbccddeeff")
        model.cancelWizard()

        XCTAssertEqual(model.step, .welcome)
        XCTAssertEqual(model.hardwareReadiness, .ready)
        XCTAssertFalse(model.firmwareInstalled)
        XCTAssertTrue(model.homeWifiPassword.isEmpty)
        XCTAssertNil(model.securelyPairedDeviceId)
        XCTAssertNil(model.savedDeviceId)
    }

    func testConnectionCheckResumesWithSelectedDevice() {
        let model = AddDeviceWizardViewModel(
            flow: .firstRun, preferredDeviceId: "SECOND",
            browser: MockBonjourBrowser(), apiClient: MockAPIClient()
        )
        let first = StoredDevice(deviceId: "first", displayName: "A", mdnsHost: "")
        let second = StoredDevice(deviceId: "second", displayName: "B", mdnsHost: "")
        model.updateKnownDevices([first, second])
        XCTAssertEqual(model.savedDeviceId, "second")
        XCTAssertEqual(model.step, .connectionTest)
    }

    func testSettingsRestartBeginsAtWelcomeWithSavedDevices() {
        let model = AddDeviceWizardViewModel(
            flow: .firstRun, resumeSavedDevice: false,
            browser: MockBonjourBrowser(), apiClient: MockAPIClient()
        )
        let devices = [
            StoredDevice(deviceId: "aabbccddeeff", displayName: "Desk", mdnsHost: ""),
            StoredDevice(deviceId: "112233445566", displayName: "Laptop", mdnsHost: "")
        ]

        model.updateKnownDevices(devices)
        XCTAssertEqual(model.step, .welcome)
        XCTAssertNil(model.savedDeviceId)
        XCTAssertEqual(model.knownDevices.match(deviceId: devices[0].deviceId)?.displayName, "Desk")

        model.continueFromWelcome()
        XCTAssertEqual(model.step, .hardware)
        model.backToWelcome()
        model.updateKnownDevices(devices)
        XCTAssertEqual(model.step, .welcome, "Refreshing saved devices must not skip a manually restarted guide")
        XCTAssertNil(model.savedDeviceId)

        model.continueFromWelcome()
        model.continueFromHardware()
        XCTAssertEqual(model.step, .permissions)
        model.continueFromPermissions()
        XCTAssertEqual(model.step, .securePairing)
        model.continueSecureSetup()
        XCTAssertEqual(model.step, .securePairing, "Restarted setup still requires USB trust")
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
