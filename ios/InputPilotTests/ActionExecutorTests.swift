import XCTest
@testable import InputPilot

@MainActor private final class MockActionTransport: HIDActionTransport {
    enum RecordedCall: Equatable {
        case beginOrderedSession(lowLatency: Bool)
        case endOrderedSession
        case keyCombo(String)
        case sendText(String, delayMilliseconds: Int)
        case releaseAllPreservingError
    }

    var beginResult = true
    var sendResults: [Bool] = []
    private(set) var calls: [RecordedCall] = []
    private var sendIndex = 0

    private func nextResult() -> Bool {
        defer { sendIndex += 1 }
        return sendIndex < sendResults.count ? sendResults[sendIndex] : true
    }

    func send(_ event: HIDEvent) async -> Bool {
        if case let .keyCombo(key) = event { calls.append(.keyCombo(key)) }
        return nextResult()
    }

    func sendText(_ text: String, layout: KeyboardLayout, delayMilliseconds: Int) async -> Bool {
        calls.append(.sendText(text, delayMilliseconds: delayMilliseconds))
        return nextResult()
    }

    func beginOrderedSession(lowLatency: Bool) -> Bool {
        calls.append(.beginOrderedSession(lowLatency: lowLatency))
        return beginResult
    }

    func endOrderedSession() {
        calls.append(.endOrderedSession)
    }

    func releaseAllPreservingError() async {
        calls.append(.releaseAllPreservingError)
    }
}

final class ActionExecutorTests: XCTestCase {
    @MainActor func testHappyPathSendsTextKeyAndDelayInOrder() async {
        let transport = MockActionTransport()
        let result = await ActionExecutor().run(
            steps: [.text("hello"), .delay(1), .key("enter")],
            layout: .us,
            typingDelayMs: 0,
            transport: transport,
            secretResolver: { _ in "" }
        )
        guard case .success = result else { return XCTFail("Expected success, got \(result)") }
        XCTAssertEqual(transport.calls, [
            .beginOrderedSession(lowLatency: false),
            .sendText("hello", delayMilliseconds: 0),
            .keyCombo("enter"),
            .releaseAllPreservingError,
            .endOrderedSession
        ])
    }

    @MainActor func testTypingDelayIsForwardedToSendText() async {
        let transport = MockActionTransport()
        _ = await ActionExecutor().run(
            steps: [.text("hi")],
            layout: .us,
            typingDelayMs: 25,
            transport: transport,
            secretResolver: { _ in "" }
        )
        let sendCalls = transport.calls.filter { if case .sendText = $0 { return true } else { return false } }
        XCTAssertEqual(sendCalls, [.sendText("hi", delayMilliseconds: 25)])
    }

    @MainActor func testLayoutValidationFailureSendsNothing() async {
        let transport = MockActionTransport()
        let result = await ActionExecutor().run(
            steps: [.text("ok"), .text("ä")],
            layout: .us,
            typingDelayMs: 0,
            transport: transport,
            secretResolver: { _ in "" }
        )
        guard case .failure(.unsupportedCharacter(let character)) = result else {
            return XCTFail("Expected unsupportedCharacter, got \(result)")
        }
        XCTAssertEqual(character, "ä")
        XCTAssertTrue(transport.calls.isEmpty)
    }

    @MainActor func testTransportFailureMidRunReleasesKeysAndFails() async {
        let transport = MockActionTransport()
        transport.sendResults = [true, false]
        let result = await ActionExecutor().run(
            steps: [.text("ok"), .key("enter")],
            layout: .us,
            typingDelayMs: 0,
            transport: transport,
            secretResolver: { _ in "" }
        )
        guard case .failure(.transportFailure) = result else {
            return XCTFail("Expected transportFailure, got \(result)")
        }
        XCTAssertEqual(transport.calls, [
            .beginOrderedSession(lowLatency: false),
            .sendText("ok", delayMilliseconds: 0),
            .keyCombo("enter"),
            .releaseAllPreservingError,
            .endOrderedSession
        ])
    }

    @MainActor func testCancellationReleasesKeys() async {
        let transport = MockActionTransport()
        let executor = ActionExecutor()
        let task = Task {
            await executor.run(
                steps: [.key("enter"), .delay(5000)],
                layout: .us,
                typingDelayMs: 0,
                transport: transport,
                secretResolver: { _ in "" }
            )
        }
        task.cancel()
        let result = await task.value
        guard case .failure(.cancelled) = result else {
            return XCTFail("Expected cancellation, got \(result)")
        }
        XCTAssertEqual(transport.calls, [
            .beginOrderedSession(lowLatency: false),
            .releaseAllPreservingError,
            .endOrderedSession
        ])
    }

    @MainActor func testFailedSessionStartSendsNothing() async {
        let transport = MockActionTransport()
        transport.beginResult = false
        let result = await ActionExecutor().run(
            steps: [.text("ok")],
            layout: .us,
            typingDelayMs: 0,
            transport: transport,
            secretResolver: { _ in "" }
        )
        guard case .failure(.transportFailure) = result else {
            return XCTFail("Expected transportFailure, got \(result)")
        }
        XCTAssertEqual(transport.calls, [.beginOrderedSession(lowLatency: false)])
    }

    @MainActor func testSecretStepResolvesThroughResolverAndSendsViaSendText() async {
        let transport = MockActionTransport()
        let result = await ActionExecutor().run(
            steps: [.secret("work-password")],
            layout: .us,
            typingDelayMs: 10,
            transport: transport,
            secretResolver: { $0 == "work-password" ? "hunter2" : "" }
        )
        guard case .success = result else {
            return XCTFail("Expected success, got \(result)")
        }
        XCTAssertEqual(transport.calls, [
            .beginOrderedSession(lowLatency: false),
            .sendText("hunter2", delayMilliseconds: 10),
            .releaseAllPreservingError,
            .endOrderedSession
        ])
    }

    @MainActor func testMissingSecretFailsReleasesKeysAndNeverLeaksResolverError() async {
        let transport = MockActionTransport()
        struct LeakyError: LocalizedError {
            var errorDescription: String? { "hunter2 leaked" }
        }
        let result = await ActionExecutor().run(
            steps: [.secret("work-password")],
            layout: .us,
            typingDelayMs: 0,
            transport: transport,
            secretResolver: { _ in throw LeakyError() }
        )
        guard case .failure(let error) = result else {
            return XCTFail("Expected failure, got \(result)")
        }
        XCTAssertEqual(error.localizedDescription, "Secret ‘work-password’ is missing.")
        XCTAssertFalse(error.localizedDescription.contains("hunter2"))
        XCTAssertEqual(transport.calls, [
            .beginOrderedSession(lowLatency: false),
            .releaseAllPreservingError,
            .endOrderedSession
        ])
    }

    @MainActor func testUnsupportedSecretCharacterFailsWithoutLeakingValue() async {
        let transport = MockActionTransport()
        let result = await ActionExecutor().run(
            steps: [.secret("work-password")],
            layout: .us,
            typingDelayMs: 0,
            transport: transport,
            secretResolver: { _ in "pässwort" }
        )
        guard case .failure(.transportFailure(let reason)) = result else {
            return XCTFail("Expected transportFailure, got \(result)")
        }
        XCTAssertTrue(reason.contains("work-password"))
        XCTAssertFalse(reason.contains("ä"))
        XCTAssertEqual(transport.calls, [
            .beginOrderedSession(lowLatency: false),
            .releaseAllPreservingError,
            .endOrderedSession
        ])
    }
}
