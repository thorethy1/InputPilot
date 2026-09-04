import SwiftData
import XCTest
@testable import InputPilot

private final class ScriptedTransport: HIDControlTransport {
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

@MainActor final class PresetsViewModelTests: XCTestCase {
    private func makeManager(ready: Bool) -> HIDConnectionManager {
        let state: TransportConnectionState = ready ? .ready : .offline
        return HIDConnectionManager(
            ble: ScriptedTransport(kind: .bluetooth, state: state),
            tcp: ScriptedTransport(kind: .tcp, state: state),
            capabilities: ["ble_transport", "wifi_transport", "keyboard_key", "keyboard_type", "keyboard_layout", "release_all"],
            protocolVersion: 2
        )
    }

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: StoredDevice.self, HIDPreset.self, HIDMacro.self, StoredSecret.self, configurations: configuration)
        return ModelContext(container)
    }

    @MainActor
    private func waitUntilIdle(_ model: PresetsViewModel) async {
        for _ in 0..<100 {
            if !model.isBusy { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Execution did not finish")
    }

    func testDuplicateGuardIgnoresSecondRunWhileBusy() async throws {
        let model = PresetsViewModel()
        let manager = makeManager(ready: true)
        let context = try makeContext()
        model.bind(manager: manager, context: context)
        let first = HIDPreset(name: "First", payload: "[DELAY 10000]", script: true)
        let second = HIDPreset(name: "Second", payload: "x")

        model.run(first, layoutName: "US QWERTY")
        XCTAssertEqual(model.runningPresetID, first.id)
        XCTAssertTrue(model.isBusy)

        model.run(second, layoutName: "US QWERTY")
        XCTAssertEqual(model.runningPresetID, first.id, "second run must be ignored while busy")

        model.stop()
        await waitUntilIdle(model)
        XCTAssertFalse(model.isBusy)
    }

    func testSuccessfulRunTransitionsRunningToCompleted() async throws {
        let model = PresetsViewModel()
        let manager = makeManager(ready: true)
        let context = try makeContext()
        model.bind(manager: manager, context: context)
        let preset = HIDPreset(name: "Greeting", payload: "hello")

        model.run(preset, layoutName: "US QWERTY")
        XCTAssertEqual(model.state(for: preset.id), .running)
        await waitUntilIdle(model)
        XCTAssertEqual(model.state(for: preset.id), .completed)
        XCTAssertNil(model.lastError)
    }

    func testParseValidationFlagReportsLineAndReason() {
        XCTAssertNil(PresetsViewModel.parseIssue(for: "ok\n[ENTER]"))
        let issue = PresetsViewModel.parseIssue(for: "valid\n[DELAY]")
        XCTAssertEqual(issue?.line, 2)
        XCTAssertNotNil(issue?.reason)
    }

    func testParseFailureMarksPresetFailedWithoutExecution() throws {
        let model = PresetsViewModel()
        let manager = makeManager(ready: true)
        let context = try makeContext()
        model.bind(manager: manager, context: context)
        let preset = HIDPreset(name: "Broken", payload: "[DELAY", script: true)

        model.run(preset, layoutName: "US QWERTY")

        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.state(for: preset.id), .failed(manager.lastError ?? ""))
        XCTAssertNotNil(model.lastError)
    }

    func testTransportFailureMarksTileFailedAndSurfacesBannerError() async throws {
        let model = PresetsViewModel()
        let manager = makeManager(ready: false)
        let context = try makeContext()
        model.bind(manager: manager, context: context)
        let preset = HIDPreset(name: "Offline", payload: "hello")

        model.run(preset, layoutName: "US QWERTY")
        await waitUntilIdle(model)

        guard case .failed = model.state(for: preset.id) else {
            return XCTFail("Expected failed state, got \(model.state(for: preset.id))")
        }
        XCTAssertNotNil(model.lastError)
        XCTAssertFalse(model.isBusy)
    }

    func testDismissErrorClearsBannerAndFailedState() async throws {
        let model = PresetsViewModel()
        let manager = makeManager(ready: false)
        let context = try makeContext()
        model.bind(manager: manager, context: context)
        let preset = HIDPreset(name: "Offline", payload: "hello")

        model.run(preset, layoutName: "US QWERTY")
        await waitUntilIdle(model)
        XCTAssertNotNil(model.lastError)

        model.dismissError()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.state(for: preset.id), .idle)
    }
}
