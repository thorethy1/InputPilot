import SwiftData
import XCTest
@testable import InputPilot

private final class IntentMockTransport: HIDControlTransport {
    let kind: TransportKind
    var state: TransportConnectionState
    var isAvailable: Bool { state == .ready }
    var events: [HIDEvent] = []
    private var presetToken: UInt64 = 0
    private var presetSize = 0

    init(kind: TransportKind, state: TransportConnectionState) {
        self.kind = kind
        self.state = state
    }

    func connect() async {}
    func send(_ event: HIDEvent) async throws { events.append(event) }
    func managementRequest(_ command: String, timeout: TimeInterval) async throws -> String {
        let fields = command.split(separator: " ")
        if command.hasPrefix("PRESET BEGIN "), fields.count == 5 {
            presetToken = UInt64(fields[2], radix: 16) ?? 0
            presetSize = Int(fields[3]) ?? 0
            return "preset ready \(String(format: "%016llx", presetToken)) 0"
        }
        if command.hasPrefix("PRESET RUN ") {
            return "preset running \(String(format: "%016llx", presetToken)) 0 \(presetSize)"
        }
        if command == "PRESET STATUS" {
            return "preset completed \(String(format: "%016llx", presetToken)) \(presetSize) \(presetSize)"
        }
        if command.hasPrefix("PRESET ABORT") {
            return "preset cancelled \(String(format: "%016llx", presetToken)) 0 \(presetSize)"
        }
        throw TransportError.failed("unexpected command")
    }
    func uploadPresetChunk(token: UInt64, offset: UInt32, data: Data) async throws -> String {
        "preset ack \(String(format: "%016llx", token)) \(Int(offset) + data.count)"
    }
    func disconnect() async { state = .offline }
}

@MainActor private final class IntentActionTransport: HIDActionTransport {
    var beginResult = true
    var failSends = false
    private(set) var sendTextCount = 0
    private(set) var startPresetCount = 0

    func send(_ event: HIDEvent) async -> Bool { true }
    func sendText(_ text: String, layout: KeyboardLayout, delayMilliseconds: Int) async -> Bool {
        sendTextCount += 1
        return !failSends
    }
    func beginOrderedSession(lowLatency: Bool) -> Bool { beginResult }
    func endOrderedSession() {}
    func releaseAllPreservingError() async {}
    func startPreset(program: Data, token: UInt64) async -> Bool {
        startPresetCount += 1
        return !failSends
    }
    func abortPreset(token: UInt64) async -> Bool { true }
}

@MainActor final class AppIntentSupportTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: StoredDevice.self, HIDPreset.self, HIDMacro.self, StoredSecret.self, configurations: configuration)
        return ModelContext(container)
    }

    private func makeManager(ready: Bool) -> HIDConnectionManager {
        let state: TransportConnectionState = ready ? .ready : .offline
        return HIDConnectionManager(
            ble: IntentMockTransport(kind: .bluetooth, state: state),
            tcp: IntentMockTransport(kind: .tcp, state: state),
            capabilities: ["ble_transport", "wifi_transport", "keyboard_key", "keyboard_type", "keyboard_layout", "release_all", "device_presets", "preset_abort"],
            protocolVersion: 2
        )
    }

    override func setUp() {
        super.setUp()
        InMemoryKeychain.reset()
    }

    func testStepsBuildShortcutScriptTextAndEnterAfter() throws {
        let shortcut = HIDPreset(name: "Combo", payload: "ctrl+alt+t", shortcut: true)
        XCTAssertEqual(try AppIntentSupport.steps(for: shortcut), [.key("ctrl+alt+t")])

        let script = HIDPreset(name: "Form", payload: "hi\n[ENTER]", script: true)
        XCTAssertEqual(try AppIntentSupport.steps(for: script), [.text("hi"), .key("enter")])

        let text = HIDPreset(name: "Text", payload: "hello", enterAfter: true)
        XCTAssertEqual(try AppIntentSupport.steps(for: text), [.text("hello"), .key("enter")])
    }

    func testKeyComboStepsAcceptKeysAndRejectText() {
        XCTAssertEqual(AppIntentSupport.keyComboSteps("ENTER"), [.key("enter")])
        XCTAssertEqual(AppIntentSupport.keyComboSteps("CTRL ALT DELETE"), [.key("ctrl+alt+delete")])
        XCTAssertNil(AppIntentSupport.keyComboSteps("hello"))
        XCTAssertNil(AppIntentSupport.keyComboSteps("CTRL BOGUS"))
        XCTAssertNil(AppIntentSupport.keyComboSteps(""))
    }

    func testSwitchDevicePersistsTheSelectedIdentity() throws {
        let previous = UserDefaults.standard.string(forKey: "selectedDeviceId")
        defer { UserDefaults.standard.set(previous, forKey: "selectedDeviceId") }
        let context = try makeContext()
        let first = StoredDevice(deviceId: "001122334455", displayName: "Desk", mdnsHost: "")
        let second = StoredDevice(deviceId: "aabbccddeeff", displayName: "Travel", mdnsHost: "")
        context.insert(first)
        context.insert(second)

        let outcome = AppIntentSupport.select(second)

        XCTAssertTrue(outcome.success)
        XCTAssertEqual(AppIntentSupport.activeDevice(context: context)?.deviceId, second.deviceId)
        XCTAssertEqual(
            AppIntentSupport.device(
                matching: InputPilotDeviceEntity(id: first.deviceId, name: first.displayName),
                context: context
            )?.deviceId,
            first.deviceId
        )
    }

    func testPresetParseFailureReturnsFailureWithoutSending() async throws {
        let context = try makeContext()
        let manager = makeManager(ready: true)
        let preset = HIDPreset(name: "Broken", payload: "[DELAY", script: true)

        let outcome = await AppIntentSupport.run(preset: preset, manager: manager, context: context)

        XCTAssertFalse(outcome.success)
        XCTAssertTrue(outcome.message.contains("line 1"))
    }

    func testMacroIntentExecutionUsesSharedManagerAndCompletes() async throws {
        let context = try makeContext()
        let manager = makeManager(ready: true)
        let macro = HIDMacro(
            name: "Return",
            events: [RecordedEvent(offset: 0, event: .key("enter"))]
        )

        let outcome = await AppIntentSupport.run(
            macro: macro,
            speed: 1,
            repeats: 1,
            delay: 0,
            manager: manager,
            context: context
        )

        XCTAssertTrue(outcome.success, outcome.message)
        XCTAssertEqual(outcome.message, "Return completed.")
    }

    func testExecutionAgainstMockActionTransportSucceeds() async throws {
        let context = try makeContext()
        let transport = IntentActionTransport()
        let preset = HIDPreset(name: "Text", payload: "hello world")

        let outcome = await AppIntentSupport.execute(
            steps: try AppIntentSupport.steps(for: preset),
            typingDelayMs: 0,
            transport: transport,
            context: context
        )
        XCTAssertTrue(outcome.success, outcome.message)
        XCTAssertEqual(transport.startPresetCount, 1)
        XCTAssertEqual(transport.sendTextCount, 0)
    }

    func testOfflineDeviceProducesHonestFailureText() async throws {
        let context = try makeContext()
        let preset = HIDPreset(name: "Offline", payload: "hello")

        let outcome = await AppIntentSupport.run(preset: preset, manager: makeManager(ready: false), context: context, readinessTimeout: 0.3)

        XCTAssertFalse(outcome.success)
        XCTAssertEqual(outcome.message, "The device did not finish connecting in time (Offline).")
    }

    func testWaitUntilReadyKeepsWaitingWhileTransportsStartOffline() async throws {
        // Cold start: the BLE radio is still powering up and the Wi-Fi
        // transport has not started its handshake yet. Both report offline
        // initially, which must not fail the wait before they had a chance.
        let ble = IntentMockTransport(kind: .bluetooth, state: .offline)
        let tcp = IntentMockTransport(kind: .tcp, state: .offline)
        let manager = HIDConnectionManager(ble: ble, tcp: tcp, capabilities: ["ble_transport", "wifi_transport"], protocolVersion: 2)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            ble.state = .ready
        }

        let ready = await manager.waitUntilReady(timeout: 2)

        XCTAssertTrue(ready)
    }

    func testWaitUntilReadyFailsFastWhenOnlyUnavailableTransportsRemain() async throws {
        let ble = IntentMockTransport(kind: .bluetooth, state: .unavailable)
        let tcp = UnavailableHIDControlTransport(kind: .tcp)
        let manager = HIDConnectionManager(ble: ble, tcp: tcp, capabilities: ["ble_transport", "wifi_transport"], protocolVersion: 2)

        let start = Date()
        let ready = await manager.waitUntilReady(timeout: 5)

        XCTAssertFalse(ready)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testReadinessIgnoresReadyTransportExcludedByMode() async {
        let previous = UserDefaults.standard.string(forKey: "connectionMode")
        defer { UserDefaults.standard.set(previous, forKey: "connectionMode") }
        for mode in [ConnectionMode.wifiOnly, .bluetoothOnly] {
            let ble = IntentMockTransport(kind: .bluetooth, state: mode == .wifiOnly ? .ready : .connecting)
            let tcp = IntentMockTransport(kind: .tcp, state: mode == .bluetoothOnly ? .ready : .connecting)
            let manager = HIDConnectionManager(ble: ble, tcp: tcp, capabilities: ["ble_transport", "wifi_transport"])
            manager.mode = mode
            let ready = await manager.waitUntilReady(timeout: 0.2)
            XCTAssertFalse(ready)
        }
    }

    func testReadinessRejectsReadyTransportsWithoutFirmwareCapabilities() async {
        let ble = IntentMockTransport(kind: .bluetooth, state: .ready)
        let tcp = IntentMockTransport(kind: .tcp, state: .ready)
        let manager = HIDConnectionManager(ble: ble, tcp: tcp, capabilities: [])

        let ready = await manager.waitUntilReady(timeout: 1)

        XCTAssertFalse(ready)
        XCTAssertFalse(manager.beginOrderedSession(lowLatency: false))
    }

    func testWiFiColdStartSucceedsWhenBluetoothUnavailable() async throws {
        let ble = UnavailableHIDControlTransport(kind: .bluetooth)
        let tcp = IntentMockTransport(kind: .tcp, state: .offline)
        let manager = HIDConnectionManager(
            ble: ble,
            tcp: tcp,
            capabilities: ["wifi_transport", "keyboard_layout", "release_all", "device_presets", "preset_abort"]
        )
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            tcp.state = .ready
        }
        let outcome = await AppIntentSupport.run(preset: HIDPreset(name: "Wi-Fi", payload: "hi"),
                                                 manager: manager, context: try makeContext(), readinessTimeout: 2)
        XCTAssertTrue(outcome.success, outcome.message)
        XCTAssertFalse(tcp.events.isEmpty)
        XCTAssertEqual(manager.activeTransport, .tcp)
    }

    func testConnectOutcomeReportsFailureWhenDeviceNeverConnects() async {
        let outcome = await AppIntentSupport.connectOutcome(manager: makeManager(ready: false), timeout: 0.1)
        XCTAssertFalse(outcome.success)
        XCTAssertTrue(outcome.message.contains("did not finish connecting"))
    }

    func testCancelledReadinessWaitStopsPromptly() async {
        let manager = makeManager(ready: false)
        let task = Task { @MainActor in await manager.waitUntilReady(timeout: 25) }
        task.cancel()
        let start = Date()
        let ready = await task.value
        XCTAssertFalse(ready)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    func testCancelledQueuedIntentDoesNotExecuteItsWork() async {
        var didExecute = false
        let task = Task { @MainActor in
            await AppIntentSupport.serialized {
                didExecute = true
                return PresetRunOutcome(success: true, message: "Unexpected")
            }
        }
        task.cancel()
        let outcome = await task.value
        XCTAssertFalse(outcome.success)
        XCTAssertFalse(didExecute)
    }

    func testAddingWiFiFallbackPreservesTheSharedSession() async {
        let deviceId = "intent-wifi-session"
        let original = InputPilotWiFiManager.session(host: "192.0.2.10", deviceId: deviceId)
        let withFallback = InputPilotWiFiManager.session(host: "192.0.2.10", deviceId: deviceId,
                                                       fallbackHosts: ["inputpilot-test.local"])
        XCTAssertTrue(original === withFallback)
        await InputPilotWiFiManager.removeSessions(deviceId: deviceId)
    }

    func testChangingFallbackHostnameInvalidatesIntentManagerCache() {
        let device = StoredDevice(deviceId: "cache-fallback", displayName: "Test", mdnsHost: "old.local")
        device.staIP = "192.0.2.1"
        let first = AppIntentSupport.manager(for: device)
        device.mdnsHost = "new.local"
        XCTAssertFalse(first === AppIntentSupport.manager(for: device))
    }

    func testCompactAndLegacyBluetoothIdentitiesMatchTheSameDevice() {
        let compact = Data([0x49, 0x50, 0x00, 0x11, 0x22, 0xab, 0xcd, 0xff])
        XCTAssertEqual(BLEDeviceDiscoveryManager.deviceId(from: compact), "001122abcdff")
        XCTAssertEqual(BLEDeviceDiscoveryManager.deviceId(from: Data("IP001122ABCDFF".utf8)), "001122abcdff")
        XCTAssertNil(BLEDeviceDiscoveryManager.deviceId(from: Data(compact.dropLast())))
        XCTAssertNil(BLEDeviceDiscoveryManager.deviceId(from: Data([0, 0]) + compact.dropFirst(2)))
    }

    func testSerializedRunsExecuteOneAfterAnother() async {
        @MainActor final class RunLog {
            var entries: [String] = []
        }
        let log = RunLog()

        async let first: PresetRunOutcome = AppIntentSupport.serialized {
            log.entries.append("start-1")
            try? await Task.sleep(for: .milliseconds(50))
            log.entries.append("end-1")
            return PresetRunOutcome(success: true, message: "1")
        }
        async let second: PresetRunOutcome = AppIntentSupport.serialized {
            log.entries.append("start-2")
            log.entries.append("end-2")
            return PresetRunOutcome(success: true, message: "2")
        }
        let outcomes = await [first, second]

        XCTAssertTrue(outcomes.allSatisfy(\.success))
        // Whichever run acquired the queue first, the two sequences must never
        // interleave: quick successive intents run strictly one after another.
        let order = log.entries.map { $0.hasSuffix("-1") ? 0 : 1 }
        XCTAssertTrue(order == [0, 0, 1, 1] || order == [1, 1, 0, 0], "runs interleaved: \(log.entries)")
    }

    func testManagerCacheReusesOneConnectionManagerPerDevice() throws {
        let context = try makeContext()
        let device = StoredDevice(deviceId: "cache-manager-1", displayName: "Cache Device", mdnsHost: "inputpilot-9.local")
        context.insert(device)

        let first = AppIntentSupport.manager(for: device)
        let second = AppIntentSupport.manager(for: device)

        XCTAssertTrue(first === second)
    }

    func testWaitUntilReadyReturnsOnceTransportBecomesReady() async throws {
        let ble = IntentMockTransport(kind: .bluetooth, state: .connecting)
        let tcp = IntentMockTransport(kind: .tcp, state: .connecting)
        let manager = HIDConnectionManager(ble: ble, tcp: tcp, capabilities: ["ble_transport", "wifi_transport"], protocolVersion: 2)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            ble.state = .ready
        }
        let ready = await manager.waitUntilReady()
        XCTAssertTrue(ready)
    }

    func testWaitUntilReadyTimesOutWhenNeverReady() async throws {
        let ble = IntentMockTransport(kind: .bluetooth, state: .connecting)
        let tcp = IntentMockTransport(kind: .tcp, state: .connecting)
        let manager = HIDConnectionManager(ble: ble, tcp: tcp, capabilities: ["ble_transport", "wifi_transport"], protocolVersion: 2)

        let ready = await manager.waitUntilReady(timeout: 0.4)

        XCTAssertFalse(ready)
    }

    func testWaitUntilReadyFailsImmediatelyOnAuthenticationFailure() async throws {
        let ble = IntentMockTransport(kind: .bluetooth, state: .authenticationFailed)
        let tcp = IntentMockTransport(kind: .tcp, state: .authenticationFailed)
        let manager = HIDConnectionManager(ble: ble, tcp: tcp, capabilities: ["ble_transport", "wifi_transport"], protocolVersion: 2)

        let start = Date()
        let ready = await manager.waitUntilReady()
        XCTAssertFalse(ready)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testColdStartPresetRunWaitsForDelayedReadyTransportAndSucceeds() async throws {
        let context = try makeContext()
        let ble = IntentMockTransport(kind: .bluetooth, state: .connecting)
        let tcp = IntentMockTransport(kind: .tcp, state: .unavailable)
        let manager = HIDConnectionManager(ble: ble, tcp: tcp, capabilities: ["ble_transport", "wifi_transport", "keyboard_key", "keyboard_type", "keyboard_layout", "release_all", "device_presets", "preset_abort"], protocolVersion: 2)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            ble.state = .ready
        }
        let preset = HIDPreset(name: "Cold", payload: "hello")

        let outcome = await AppIntentSupport.run(preset: preset, manager: manager, context: context)

        XCTAssertTrue(outcome.success, outcome.message)
    }

    func testSecretBackedPresetFailsWithMissingSecretWhenKeychainItemAbsent() async throws {
        let context = try makeContext()
        context.insert(StoredSecret(name: "work-password"))
        try? context.save()
        let preset = HIDPreset(name: "Login", payload: "[SECRET work-password]", script: true)

        let outcome = await AppIntentSupport.run(preset: preset, manager: makeManager(ready: true), context: context)

        XCTAssertFalse(outcome.success)
        XCTAssertEqual(outcome.message, "Secret ‘work-password’ is missing.")
    }

    func testNoOutcomeMessageEverContainsResolvedSecretValue() async throws {
        let context = try makeContext()
        try SecretStore(context: context).save(name: "work-password", value: "s3cret!")
        let preset = HIDPreset(name: "Login", payload: "[SECRET work-password]", script: true)

        let failing = IntentActionTransport()
        failing.failSends = true
        let outcome = await AppIntentSupport.execute(
            steps: try AppIntentSupport.steps(for: preset),
            typingDelayMs: 0,
            transport: failing,
            context: context
        )
        XCTAssertFalse(outcome.success)
        XCTAssertFalse(outcome.message.contains("s3cret!"))
        XCTAssertEqual(outcome.message, "The device did not accept the preset.")
    }

    func testActiveDeviceResolvesSavedSelectionAndFallsBackToFirst() throws {
        let context = try makeContext()
        let first = StoredDevice(deviceId: "device-1", displayName: "Beta Device", mdnsHost: "inputpilot-1.local")
        let second = StoredDevice(deviceId: "device-2", displayName: "Alpha Device", mdnsHost: "inputpilot-2.local")
        context.insert(first)
        context.insert(second)

        let previous = UserDefaults.standard.string(forKey: "selectedDeviceId")
        defer { UserDefaults.standard.set(previous, forKey: "selectedDeviceId") }

        UserDefaults.standard.set("device-2", forKey: "selectedDeviceId")
        XCTAssertEqual(AppIntentSupport.activeDevice(context: context)?.deviceId, "device-2")

        UserDefaults.standard.set("missing-device", forKey: "selectedDeviceId")
        XCTAssertEqual(AppIntentSupport.activeDevice(context: context)?.deviceId, "device-2")
    }
}
