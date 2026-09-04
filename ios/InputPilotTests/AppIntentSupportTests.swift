import SwiftData
import XCTest
@testable import InputPilot

private final class IntentMockTransport: HIDControlTransport {
    let kind: TransportKind
    var state: TransportConnectionState
    var isAvailable: Bool { state == .ready }
    var events: [HIDEvent] = []

    init(kind: TransportKind, state: TransportConnectionState) {
        self.kind = kind
        self.state = state
    }

    func connect() async {}
    func send(_ event: HIDEvent) async throws { events.append(event) }
    func disconnect() async { state = .offline }
}

@MainActor private final class IntentActionTransport: HIDActionTransport {
    var beginResult = true
    var failSends = false
    private(set) var sendTextCount = 0

    func send(_ event: HIDEvent) async -> Bool { true }
    func sendText(_ text: String, layout: KeyboardLayout, delayMilliseconds: Int) async -> Bool {
        sendTextCount += 1
        return !failSends
    }
    func beginOrderedSession(lowLatency: Bool) -> Bool { beginResult }
    func endOrderedSession() {}
    func releaseAllPreservingError() async {}
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
            capabilities: ["ble_transport", "wifi_transport", "keyboard_key", "keyboard_type", "keyboard_layout", "release_all"],
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

        let script = HIDPreset(name: "Form", payload: "STRING hi\n[ENTER]", script: true)
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

    func testPresetParseFailureReturnsFailureWithoutSending() async throws {
        let context = try makeContext()
        let manager = makeManager(ready: true)
        let preset = HIDPreset(name: "Broken", payload: "[DELAY", script: true)

        let outcome = await AppIntentSupport.run(preset: preset, manager: manager, context: context)

        XCTAssertFalse(outcome.success)
        XCTAssertTrue(outcome.message.contains("line 1"))
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
        XCTAssertEqual(transport.sendTextCount, 1)
    }

    func testOfflineDeviceProducesHonestFailureText() async throws {
        let context = try makeContext()
        let preset = HIDPreset(name: "Offline", payload: "hello")

        let outcome = await AppIntentSupport.run(preset: preset, manager: makeManager(ready: false), context: context)

        XCTAssertFalse(outcome.success)
        XCTAssertEqual(outcome.message, "The device is not ready to receive input.")
    }

    func testSecretBackedPresetFailsWithMissingSecretWhenKeychainItemAbsent() async throws {
        let context = try makeContext()
        context.insert(StoredSecret(name: "work-password"))
        try? context.save()
        let preset = HIDPreset(name: "Login", payload: "SECRET work-password", script: true)

        let outcome = await AppIntentSupport.run(preset: preset, manager: makeManager(ready: true), context: context)

        XCTAssertFalse(outcome.success)
        XCTAssertEqual(outcome.message, "Secret ‘work-password’ is missing.")
    }

    func testNoOutcomeMessageEverContainsResolvedSecretValue() async throws {
        let context = try makeContext()
        try SecretStore(context: context).save(name: "work-password", value: "s3cret!")
        let preset = HIDPreset(name: "Login", payload: "SECRET work-password", script: true)

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
        XCTAssertEqual(outcome.message, "The device did not accept the action.")
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
