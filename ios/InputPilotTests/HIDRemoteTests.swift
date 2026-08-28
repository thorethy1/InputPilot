import XCTest
import CoreBluetooth
@testable import InputPilot

final class HIDRemoteTests: XCTestCase {
    private func firmwareImage(product: String = "InputPilot", board: String = "esp32-s3-zero-4mb", version: String = "0.8.2", protocolVersion: Int = 1) -> Data {
        var data = Data(repeating: 0xff, count: FirmwareImageMetadata.minimumSize)
        data[0] = 0xe9
        data.replaceSubrange(32..<36, with: FirmwareImageMetadata.appDescriptorMagic)
        let metadata = "INPUTPILOT-META:product=\(product);board=\(board);version=\(version);protocol=\(protocolVersion);otaSchema=1;\0"
        data.replaceSubrange(128..<(128 + metadata.utf8.count), with: metadata.utf8)
        return data
    }

    func testSemanticFirmwareVersionsCompareNumerically() {
        XCTAssertLessThan(SemanticVersion("0.8.9")!, SemanticVersion("0.8.10")!)
        XCTAssertEqual(SemanticVersion("1.2")!, SemanticVersion("1.2.0")!)
        XCTAssertNil(SemanticVersion("latest"))
    }

    func testFirmwareManifestDecodingAndIntegrityMetadata() throws {
        let json = #"{"product":"InputPilot","version":"0.8.0","board":"esp32-s3-zero-4mb","protocol":1,"otaSchema":1,"size":1271270,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#
        let manifest = try JSONDecoder().decode(FirmwareManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.protocolVersion, 1)
        XCTAssertEqual(manifest.otaSchema, 1)
        XCTAssertEqual(manifest.size, 1_271_270)
        XCTAssertNil(manifest.minimumAppVersion)
    }

    func testFirmwareReleaseStatesDistinguishUpdateCompatibilityAndAppRequirement() {
        let hash = String(repeating: "a", count: 64)
        let current = FirmwareManifest(product: "InputPilot", version: "0.8.3", board: "esp32-s3-zero-4mb", protocolVersion: 1, otaSchema: 1, size: 1, sha256: hash)
        XCTAssertEqual(FirmwareReleaseEvaluator.evaluate(installed: "0.8.2", manifest: current, deviceOTASchema: 1, appVersion: "0.8.3"), .updateAvailable("0.8.3"))
        XCTAssertEqual(FirmwareReleaseEvaluator.evaluate(installed: "0.8.3", manifest: current, deviceOTASchema: 1, appVersion: "0.8.3"), .upToDate("0.8.3"))
        XCTAssertEqual(FirmwareReleaseEvaluator.evaluate(installed: "0.9.0", manifest: current, deviceOTASchema: 1, appVersion: "0.8.3"), .installedNewer(latest: "0.8.3"))

        let futureProtocol = FirmwareManifest(product: "InputPilot", version: "0.9.0", board: "esp32-s3-zero-4mb", protocolVersion: 2, otaSchema: 1, size: 1, sha256: hash)
        XCTAssertEqual(FirmwareReleaseEvaluator.evaluate(installed: "0.8.3", manifest: futureProtocol, deviceOTASchema: 1, appVersion: "0.8.3").title, "App update required")

        let newerApp = FirmwareManifest(product: "InputPilot", version: "0.8.4", board: "esp32-s3-zero-4mb", protocolVersion: 1, otaSchema: 1, size: 1, sha256: hash, minimumAppVersion: "0.8.4")
        XCTAssertEqual(FirmwareReleaseEvaluator.evaluate(installed: "0.8.3", manifest: newerApp, deviceOTASchema: 1, appVersion: "0.8.3").title, "App update required")

        XCTAssertEqual(FirmwareReleaseEvaluator.evaluate(installed: "0.8.3", manifest: current, deviceOTASchema: 0, appVersion: "0.8.3").title, "Firmware not compatible")
    }

    func testBLEDeviceMetadataDecoding() throws {
        let data = Data(#"{"product":"InputPilot","board":"esp32-s3-zero-4mb","deviceId":"aabbccddeeff","deviceName":"Desk","firmware":"0.8.0","protocol":1,"otaSchema":1,"capabilities":["ble_control","ble_ota"],"authRequired":true}"#.utf8)
        let metadata = try JSONDecoder().decode(BLEDeviceMetadata.self, from: data)
        XCTAssertEqual(metadata.deviceId, "aabbccddeeff")
        XCTAssertTrue(metadata.capabilities.contains("ble_ota"))
        XCTAssertTrue(metadata.authRequired)
    }

    func testBLEManufacturerIdentityFiltering() {
        XCTAssertEqual(BLEDeviceDiscoveryManager.deviceId(from: Data("IPaabbccddeeff".utf8)), "aabbccddeeff")
        XCTAssertEqual(BLEDeviceDiscoveryManager.deviceId(from: Data("IPAABBCCDDEEFF".utf8)), "aabbccddeeff")
        XCTAssertNil(BLEDeviceDiscoveryManager.deviceId(from: Data("random".utf8)))
        XCTAssertNil(BLEDeviceDiscoveryManager.deviceId(from: Data("IPaabbccddeefg".utf8)))
        XCTAssertNil(BLEDeviceDiscoveryManager.deviceId(from: Data("xxIPaabbccddeeff".utf8)))
    }

    func testBLEDiscoveryAndReconnectShareExactIdentityMatching() {
        let advertisement: [String: Any] = [CBAdvertisementDataManufacturerDataKey: Data("IPaabbccddeeff".utf8)]
        XCTAssertEqual(BLEDeviceDiscoveryManager.advertisementDeviceId(advertisement), "aabbccddeeff")
        XCTAssertTrue(BLEDeviceDiscoveryManager.advertisement(advertisement, matches: "AABBCCDDEEFF"))
        XCTAssertFalse(BLEDeviceDiscoveryManager.advertisement(advertisement, matches: "00bbccddeeff"))
    }

    func testBundleVersionHelper() {
        let version = AppVersionInfo.read(from: ["CFBundleShortVersionString": "0.8.2", "CFBundleVersion": "123", "InputPilotGitCommit": "abc1234"])
        XCTAssertEqual(version, AppVersionInfo(version: "0.8.2", build: "123", commit: "abc1234"))
        XCTAssertEqual(version.display, "0.8.2 (123)")
        XCTAssertEqual(AppVersionInfo.read(from: [:]).version, "Unknown")
    }

    @MainActor func testAppLogIsBoundedClearableAndDoesNotContainTypedPayloads() {
        let log = AppLog.shared; log.clear()
        for index in 0..<(AppLog.capacity + 10) { log.write(.input, "id=\(index) keyboard_text length=8") }
        XCTAssertEqual(log.records.count, AppLog.capacity)
        XCTAssertFalse(log.records.map(\.line).joined().contains("password"))
        log.clear(); XCTAssertTrue(log.records.isEmpty)
    }

    func testFirmwareLogParsingAndFiltering() {
        let ble = FirmwareLogLine("[1234][INFO][BLE] advertising started")
        let warning = FirmwareLogLine("[4321][WARN][APP] OTA failed")
        let wifi = FirmwareLogLine("[5000][INFO][WIFI] connected")
        XCTAssertEqual(ble.milliseconds, 1234); XCTAssertEqual(ble.level, "INFO"); XCTAssertEqual(ble.tag, "BLE")
        XCTAssertTrue(ble.matches(.ble)); XCTAssertFalse(ble.matches(.ota))
        XCTAssertTrue(warning.matches(.warnings)); XCTAssertTrue(wifi.matches(.wifi))
    }

    func testClientFirmwareLogHistoryIsBoundedAndClearable() {
        var history = FirmwareLogHistory()
        history.append((0..<(FirmwareLogHistory.capacity + 10)).map { "[\($0)][INFO][APP] line-\($0)" })
        XCTAssertEqual(history.lines.count, FirmwareLogHistory.capacity)
        XCTAssertTrue(history.lines.first?.raw.contains("line-10") == true)
        history.clear(); XCTAssertTrue(history.lines.isEmpty)
    }

    func testDiagnosticsSequenceHistoryDeduplicatesHistoryAndLiveFrames() {
        var history = FirmwareLogSequenceHistory()
        let boot = FirmwareLogRecord(sequence: 12, line: "[100][INFO][APP] boot")
        XCTAssertEqual(history.append([boot]), [boot.line])
        XCTAssertTrue(history.append([boot]).isEmpty)
        let live = FirmwareLogRecord(sequence: 13, line: "[200][INFO][BLE] connected")
        XCTAssertEqual(history.append([boot, live]), [live.line])
        XCTAssertEqual(history.records, [boot, live])
    }

    func testDiagnosticsMetadataAndStoredFirmwareFallback() throws {
        let metadata = try JSONDecoder().decode(DiagnosticsMetadata.self, from: Data(#"{"product":"InputPilot","firmware":"0.8.0","board":"esp32-s3-zero-4mb","protocol":1,"otaSchema":1,"deviceId":"aabbccddeeff","runningPartition":"ota_1","bootPartition":"ota_1"}"#.utf8))
        XCTAssertEqual(metadata.firmware, "0.8.0"); XCTAssertEqual(metadata.protocolVersion, 1); XCTAssertEqual(metadata.otaSchema, 1)
        XCTAssertEqual(metadata.runningPartition, "ota_1"); XCTAssertEqual(metadata.bootPartition, "ota_1")
        let stored = StoredDevice(deviceId: "abc", displayName: "Desk", mdnsHost: "", firmwareVersion: "0.7.9", protocolVersion: 1, otaSchema: 1)
        XCTAssertEqual(stored.firmwareVersion ?? "Unknown", "0.7.9")
        stored.firmwareVersion = nil; XCTAssertEqual(stored.firmwareVersion ?? "Unknown", "Unknown")
    }

    func testFirmwareUpdateTransportSelectionRespectsConnectionMode() {
        XCTAssertEqual(FirmwareUpdateManager.transportOrder(mode: .automatic, wifiAvailable: true, bluetoothAvailable: true), [.wifi, .bluetooth])
        XCTAssertEqual(FirmwareUpdateManager.transportOrder(mode: .preferWiFi, wifiAvailable: true, bluetoothAvailable: true), [.wifi, .bluetooth])
        XCTAssertEqual(FirmwareUpdateManager.transportOrder(mode: .preferBluetooth, wifiAvailable: true, bluetoothAvailable: true), [.bluetooth, .wifi])
        XCTAssertEqual(FirmwareUpdateManager.transportOrder(mode: .wifiOnly, wifiAvailable: true, bluetoothAvailable: true), [.wifi])
        XCTAssertEqual(FirmwareUpdateManager.transportOrder(mode: .bluetoothOnly, wifiAvailable: true, bluetoothAvailable: true), [.bluetooth])
        XCTAssertEqual(FirmwareUpdateManager.transportOrder(mode: .automatic, wifiAvailable: false, bluetoothAvailable: true), [.bluetooth])
        XCTAssertEqual(FirmwareUpdateManager.transportOrder(mode: .automatic, wifiAvailable: true, bluetoothAvailable: false), [.wifi])
    }

    func testManualFirmwareVersionComesFromImageMetadata() throws {
        XCTAssertEqual(try FirmwareImageMetadata.parseAndValidate(firmwareImage()).version, "0.8.2")
    }

    func testForeignAndWrongBoardFirmwareAreRejected() {
        XCTAssertThrowsError(try FirmwareImageMetadata.parseAndValidate(firmwareImage(product: "Other")))
        XCTAssertThrowsError(try FirmwareImageMetadata.parseAndValidate(firmwareImage(board: "other-board")))
    }

    func testFullFlashImageIsRejectedStructurally() {
        var image = firmwareImage()
        image.replaceSubrange(32..<36, with: Data([0x50, 0, 0, 0]))
        XCTAssertThrowsError(try FirmwareImageMetadata.parseAndValidate(image)) { error in
            XCTAssertEqual(error as? FirmwareValidationError, .notApplicationImage)
        }
    }

    @MainActor func testGitHubOTAUsesOnlyDedicatedAssets() {
        XCTAssertEqual(GitHubFirmwareSource.manifestAssetName, "firmware-manifest.json")
        XCTAssertEqual(GitHubFirmwareSource.firmwareAssetName, "firmware.bin")
        XCTAssertNotEqual(GitHubFirmwareSource.firmwareAssetName, "initial-flash.bin")
    }

    func testManifestWrongProductAndBoardAreRejected() {
        let hash = String(repeating: "a", count: 64)
        XCTAssertThrowsError(try FirmwareManifestValidator.validate(.init(product: "Other", version: "1.0.0", board: "esp32-s3-zero-4mb", protocolVersion: 1, otaSchema: 1, size: 1, sha256: hash)))
        XCTAssertThrowsError(try FirmwareManifestValidator.validate(.init(product: "InputPilot", version: "1.0.0", board: "other", protocolVersion: 1, otaSchema: 1, size: 1, sha256: hash)))
    }

    func testExpectedAndUnexpectedOTADisconnectStates() {
        XCTAssertTrue(FirmwareUpdateManager.disconnectIsExpected(during: .verifying))
        XCTAssertTrue(FirmwareUpdateManager.disconnectIsExpected(during: .rebooting))
        XCTAssertFalse(FirmwareUpdateManager.disconnectIsExpected(during: .transferring))
    }

    func testActiveOTAStatesBlockConflictingCommands() {
        let updater = FirmwareUpdateManager()
        XCTAssertFalse(updater.blocksControl)
        updater.disconnected(expected: false)
        XCTAssertEqual(updater.state, .idle)
        XCTAssertTrue(FirmwareUpdateManager.disconnectIsExpected(during: .installing))
    }

    func testPostRebootIdentityVersionAndSchemaVerification() {
        let metadata = BLEDeviceMetadata(product: "InputPilot", board: "esp32-s3-zero-4mb", deviceId: "abc", deviceName: "InputPilot", firmware: "0.8.1", protocolVersion: 1, otaSchema: 1, capabilities: ["ble_ota"], authRequired: false)
        XCTAssertTrue(FirmwareUpdateManager.verifies(metadata: metadata, deviceId: "ABC", version: "0.8.1", requiredSchema: 1))
        XCTAssertFalse(FirmwareUpdateManager.verifies(metadata: metadata, deviceId: "abc", version: "0.8.2", requiredSchema: 1))
        XCTAssertFalse(FirmwareUpdateManager.verifies(metadata: metadata, deviceId: "other", version: "0.8.1", requiredSchema: 1))
    }

    func testBLEOnlyStoredDeviceNeedsNoNetworkEndpoint() {
        let stored = StoredDevice(deviceId: "abc", displayName: "BLE", mdnsHost: "", staIP: nil, firmwareVersion: "0.8.0", protocolVersion: 1, capabilities: ["ble_ota"], otaSchema: 1)
        XCTAssertNil(stored.staIP); XCTAssertTrue(stored.mdnsHost.isEmpty); XCTAssertEqual(stored.otaSchema, 1)
    }

    func testOTACapabilityAndMigrationStateDecode() throws {
        let capable = try JSONDecoder().decode(DeviceStatus.self, from: Data(#"{"version":"0.8.0","ota_schema":1,"capabilities":["ble_control","ble_ota"]}"#.utf8))
        XCTAssertEqual(capable.otaSchema, 1)
        XCTAssertTrue(capable.capabilities.contains("ble_ota"))
        let legacy = try JSONDecoder().decode(DeviceStatus.self, from: Data(#"{"version":"0.6.4"}"#.utf8))
        XCTAssertEqual(legacy.otaSchema, 0)
        XCTAssertFalse(legacy.capabilities.contains("ble_ota"))
    }
    func testBinaryAndTCPKeyboardReportEncoding() {
        let event = HIDEvent.keyboardReport(modifiers: 0x40, usage: 0x14)
        XCTAssertEqual(Array(event.binary), [1, 0x13, 0x40, 0x14])
        XCTAssertEqual(event.line, "report 64 20")
    }

    func testMouseBinaryEncoding() {
        XCTAssertEqual(Array(HIDEvent.mouseMove(258, -2).binary), [1, 1, 2, 1, 254, 255])
        XCTAssertEqual(Array(HIDEvent.mouseDown(.right).binary), [1, 3, 1])
        XCTAssertEqual(HIDEvent.releaseAll.line, "release all")
    }

    func testBLEWritePolicyUsesFlowControlledFastPathAndAcknowledgesCriticalState() {
        let both: CBCharacteristicProperties = [.write, .writeWithoutResponse]
        XCTAssertEqual(BLEHIDControlTransport.writeType(for: .mouseMove(1, 2), properties: both), .withoutResponse)
        XCTAssertEqual(BLEHIDControlTransport.writeType(for: .scroll(1), properties: both), .withoutResponse)
        XCTAssertEqual(BLEHIDControlTransport.writeType(for: .mouseDown(.left), properties: both), .withResponse)
        XCTAssertEqual(BLEHIDControlTransport.writeType(for: .keyboardReport(modifiers: 0, usage: 4), properties: both), .withResponse)
        XCTAssertEqual(BLEHIDControlTransport.writeType(for: .releaseAll, properties: both), .withResponse)
    }

    func testTCPAndRESTMappings() {
        XCTAssertEqual(HIDEvent.scroll(-3).line, "move 0 0 -3")
        XCTAssertEqual(HIDEvent.mouseDown(.middle).line, "button middle down")
        XCTAssertEqual(HIDEvent.mouseUp(.left).restPath, "api/button")
        XCTAssertEqual(HIDEvent.typeText("hello").restPath, "api/type")
        XCTAssertEqual(HIDEvent.keyboardReport(modifiers: 2, usage: 4).restPath, "api/report")
        XCTAssertEqual(HIDEvent.releaseAll.restPath, "api/release-all")
    }

    @MainActor func testTransportSelectionOrdersAndConstraints() {
        XCTAssertEqual(HIDConnectionManager.candidateKinds(mode: .automatic, lowLatency: true), [.bluetooth, .tcp, .rest])
        XCTAssertEqual(HIDConnectionManager.candidateKinds(mode: .automatic, lowLatency: false), [.tcp, .rest, .bluetooth])
        XCTAssertEqual(HIDConnectionManager.candidateKinds(mode: .preferBluetooth, lowLatency: false), [.bluetooth, .tcp, .rest])
        XCTAssertEqual(HIDConnectionManager.candidateKinds(mode: .preferWiFi, lowLatency: true), [.tcp, .rest, .bluetooth])
        XCTAssertEqual(HIDConnectionManager.candidateKinds(mode: .bluetoothOnly, lowLatency: true), [.bluetooth])
        XCTAssertEqual(HIDConnectionManager.candidateKinds(mode: .wifiOnly, lowLatency: false), [.rest, .tcp])
    }

    func testCoalescerAggregatesAndFlushes() async {
        let expectation = expectation(description: "flush")
        let values = LockedValues()
        let coalescer = MouseEventCoalescer(interval: .seconds(10)) { x, y in
            values.set(x, y)
            expectation.fulfill()
        }
        await coalescer.add(x: 1, y: 0)
        await coalescer.add(x: 2, y: -1)
        await coalescer.add(x: 1, y: 0)
        await coalescer.flush()
        await fulfillment(of: [expectation], timeout: 1)
        XCTAssertEqual(values.value.0, 4)
        XCTAssertEqual(values.value.1, -1)
    }

    func testCoalescerCancellationDropsPendingMovement() async {
        let values = LockedValues()
        let coalescer = MouseEventCoalescer(interval: .milliseconds(10)) { x, y in values.set(x, y) }
        await coalescer.add(x: 4, y: 7)
        await coalescer.cancel()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(values.value.0, 0)
        XCTAssertEqual(values.value.1, 0)
    }

    func testScrollCoalescerAggregatesAndDropsZero() async {
        let expectation = expectation(description: "scroll flush")
        let values = LockedScrollValues()
        let coalescer = ScrollEventCoalescer(interval: .seconds(10)) { value in
            values.append(value)
            expectation.fulfill()
        }
        await coalescer.add(2)
        await coalescer.add(-1)
        await coalescer.flush()
        await fulfillment(of: [expectation], timeout: 1)
        XCTAssertEqual(values.values, [1])
        await coalescer.add(3)
        await coalescer.add(-3)
        await coalescer.flush()
        XCTAssertEqual(values.values, [1])
    }

    @MainActor func testAutomaticTransportFallsBackToReadyREST() async {
        let ble = MockTransport(kind: .bluetooth, available: false)
        let tcp = MockTransport(kind: .tcp, available: false)
        let rest = MockTransport(kind: .rest, available: true)
        let manager = HIDConnectionManager(ble: ble, tcp: tcp, rest: rest)
        let didSend = await manager.send(.click(.left))
        XCTAssertTrue(didSend)
        XCTAssertEqual(rest.events, [.click(.left)])
        XCTAssertEqual(manager.activeTransport, .rest)
    }

    @MainActor func testBackToBackReleaseAllIsCoalesced() async {
        let transport = MockTransport(kind: .bluetooth, available: true)
        let manager = HIDConnectionManager(ble: transport, tcp: transport, rest: transport)
        await manager.releaseAll()
        await manager.releaseAll()
        XCTAssertEqual(transport.events, [.releaseAll])
    }

    @MainActor func testCapabilitiesRejectUnsupportedEvent() async {
        let transport = MockTransport(kind: .bluetooth, available: true)
        let manager = HIDConnectionManager(ble: transport, tcp: transport, rest: transport, capabilities: ["mouse_move"])
        let didSend = await manager.send(.scroll(1))
        XCTAssertFalse(didSend)
        XCTAssertTrue(transport.events.isEmpty)
    }

    @MainActor func testDragLeaseKeepsEveryEventOnBluetooth() async {
        let ble = MockTransport(kind: .bluetooth, available: true)
        let tcp = MockTransport(kind: .tcp, available: true)
        let rest = MockTransport(kind: .rest, available: true)
        let manager = HIDConnectionManager(ble: ble, tcp: tcp, rest: rest)
        XCTAssertTrue(manager.beginOrderedSession(lowLatency: true))
        let down = await manager.send(.mouseDown(.left))
        let move1 = await manager.send(.mouseMove(2, 1))
        let move2 = await manager.send(.mouseMove(3, -1))
        let up = await manager.send(.mouseUp(.left))
        XCTAssertTrue(down && move1 && move2 && up)
        manager.endOrderedSession()
        XCTAssertEqual(ble.events, [.mouseDown(.left), .mouseMove(2, 1), .mouseMove(3, -1), .mouseUp(.left)])
        XCTAssertTrue(tcp.events.isEmpty)
        XCTAssertTrue(rest.events.isEmpty)
    }

    @MainActor func testSendTextUsesSingleBulkTransport() async {
        let ble = MockTransport(kind: .bluetooth, available: true)
        let tcp = MockTransport(kind: .tcp, available: true)
        let rest = MockTransport(kind: .rest, available: true)
        let manager = HIDConnectionManager(ble: ble, tcp: tcp, rest: rest)
        let sent = await manager.sendText("abc", layout: .us)
        XCTAssertTrue(sent)
        XCTAssertEqual(tcp.events.count, 3)
        XCTAssertTrue(ble.events.isEmpty)
        XCTAssertTrue(rest.events.isEmpty)
    }

    @MainActor func testLeaseFailureAbortsWithoutContinuingOnTCPAndAttemptsReleaseAll() async {
        let ble = MockTransport(kind: .bluetooth, available: true)
        let tcp = MockTransport(kind: .tcp, available: true)
        let rest = MockTransport(kind: .rest, available: false)
        let manager = HIDConnectionManager(ble: ble, tcp: tcp, rest: rest)
        XCTAssertTrue(manager.beginOrderedSession(lowLatency: true))
        let down = await manager.send(.mouseDown(.left))
        XCTAssertTrue(down)
        ble.isAvailable = false
        let moved = await manager.send(.mouseMove(1, 0))
        XCTAssertFalse(moved)
        XCTAssertFalse(tcp.events.contains(.mouseMove(1, 0)))
        XCTAssertTrue(tcp.events.contains(.releaseAll))
        XCTAssertTrue(manager.beginOrderedSession(lowLatency: true))
        let clicked = await manager.send(.click(.left))
        XCTAssertTrue(clicked)
        XCTAssertTrue(tcp.events.contains(.click(.left)))
    }

    @MainActor func testNewerProtocolIsRejectedBeforeTransportSend() async {
        let transport = MockTransport(kind: .bluetooth, available: true)
        let manager = HIDConnectionManager(ble: transport, tcp: transport, rest: transport, protocolVersion: 2)
        let didSend = await manager.send(.click(.left))
        XCTAssertFalse(didSend)
        XCTAssertTrue(transport.events.isEmpty)
        XCTAssertEqual(manager.connectionSummary, "Firmware unsupported")
    }

    @MainActor func testReadyTransportWinsOverAnotherTransportReconnecting() {
        let ble = MockTransport(kind: .bluetooth, available: false, state: .reconnecting)
        let tcp = MockTransport(kind: .tcp, available: true)
        let rest = MockTransport(kind: .rest, available: false)
        let manager = HIDConnectionManager(ble: ble, tcp: tcp, rest: rest)
        XCTAssertEqual(manager.connectionSummary, "Ready Wi-Fi TCP")
    }

    @MainActor func testMacroCompressionPreservesNonMovementEvents() {
        let controller = MacroController()
        controller.startRecording()
        controller.capture(.mouseMove(1, 2))
        controller.capture(.mouseMove(3, -1))
        controller.capture(.click(.left))
        controller.stopRecording()
        XCTAssertEqual(controller.recorded.count, 2)
        XCTAssertEqual(controller.recorded[0].event, .mouseMove(4, 1))
        XCTAssertEqual(controller.recorded[1].event, .click(.left))
    }

    func testPresetFieldsSupportTypingDelayAndEnterAfter() {
        let preset = HIDPreset(name: "Greeting", payload: "Hallo\nWelt", favorite: true, enterAfter: true, typingDelayMs: 25)
        XCTAssertEqual(preset.typingDelayMs, 25)
        XCTAssertTrue(preset.enterAfter)
        let copy = HIDPreset(name: preset.name + " Copy", payload: preset.payload, shortcut: preset.shortcut, favorite: preset.favorite, order: 1, enterAfter: preset.enterAfter, typingDelayMs: preset.typingDelayMs)
        XCTAssertEqual(copy.payload, preset.payload)
        XCTAssertEqual(copy.typingDelayMs, preset.typingDelayMs)
    }
}

private final class MockTransport: HIDControlTransport {
    let kind: TransportKind
    var isAvailable: Bool
    private let explicitState: TransportConnectionState?
    var state: TransportConnectionState { explicitState ?? (isAvailable ? .ready : .offline) }
    var events: [HIDEvent] = []
    init(kind: TransportKind, available: Bool, state: TransportConnectionState? = nil) { self.kind = kind; isAvailable = available; explicitState = state }
    func connect() async {}
    func send(_ event: HIDEvent) async throws { events.append(event) }
    func disconnect() async { isAvailable = false }
}

private final class LockedValues: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: (Int16, Int16) = (0, 0)
    var value: (Int16, Int16) { lock.withLock { storage } }
    func set(_ x: Int16, _ y: Int16) { lock.withLock { storage = (x, y) } }
}

private final class LockedScrollValues: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int16] = []
    var values: [Int16] { lock.withLock { storage } }
    func append(_ value: Int16) { lock.withLock { storage.append(value) } }
}
