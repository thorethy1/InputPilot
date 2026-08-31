import XCTest
@testable import InputPilot

@MainActor
final class AddDeviceWizardViewModelTests: XCTestCase {
    private func metadata(protocolVersion: Int = 2, capabilities: [String] = ["secure_protocol_v2", "secure_wifi_setup"]) -> BLEDeviceMetadata {
        BLEDeviceMetadata(product: "InputPilot", board: "esp32-s3-zero-4mb", deviceId: "aabbccddeeff", deviceName: "Desk", firmware: "0.8.12", protocolVersion: protocolVersion, otaSchema: 1, capabilities: capabilities, trustRequired: true)
    }

    func testUSBTrustIsRequiredBeforeBluetoothStep() {
        let model = AddDeviceWizardViewModel(browser: MockBonjourBrowser(), apiClient: MockAPIClient())
        XCTAssertEqual(model.step, .securePairing)
        model.chooseSecureSetup()
        model.continueSecureSetup()
        XCTAssertEqual(model.step, .securePairing)
        XCTAssertNotNil(model.errorMessage)
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

    func testMissingSecureWifiCapabilityIsRejected() {
        let model = AddDeviceWizardViewModel(browser: MockBonjourBrowser(), apiClient: MockAPIClient())
        model.chooseSecureSetup(); model.didPairSecurely(deviceId: "aabbccddeeff"); model.continueSecureSetup()
        model.selectBluetooth(metadata(capabilities: ["secure_protocol_v2"]))
        XCTAssertEqual(model.step, .bleScanning)
    }
}
