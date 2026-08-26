import XCTest
@testable import InputPilot

final class HIDRemoteTests: XCTestCase {
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
    var state: TransportConnectionState { isAvailable ? .ready : .offline }
    var events: [HIDEvent] = []
    init(kind: TransportKind, available: Bool) { self.kind = kind; isAvailable = available }
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
