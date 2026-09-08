import XCTest
@testable import InputPilot

@MainActor private final class MockActionTransport: HIDActionTransport {
    var acceptsPreset = true
    private(set) var programs: [Data] = []
    private(set) var abortedTokens: [UInt64] = []

    func send(_ event: HIDEvent) async -> Bool { true }
    func sendText(_ text: String, layout: KeyboardLayout, delayMilliseconds: Int) async -> Bool { true }
    func beginOrderedSession(lowLatency: Bool) -> Bool { true }
    func endOrderedSession() {}
    func releaseAllPreservingError() async {}
    func startPreset(program: Data, token: UInt64) async -> Bool { programs.append(program); return acceptsPreset }
    func abortPreset(token: UInt64) async -> Bool { abortedTokens.append(token); return true }
}

final class ActionExecutorTests: XCTestCase {
    @MainActor func testHappyPathUploadsOneCompleteProgram() async {
        let transport = MockActionTransport()
        let result = await ActionExecutor().run(
            steps: [.text("hello"), .delay(1), .key("enter")], layout: .us,
            typingDelayMs: 0, token: 7, transport: transport, secretResolver: { _ in "" }
        )
        guard case .success = result else { return XCTFail("Expected success, got \(result)") }
        XCTAssertEqual(transport.programs.count, 1)
        let bytes = Array(try! XCTUnwrap(transport.programs.first))
        XCTAssertEqual(Array(bytes.prefix(3)), [0x01, 0, 0x0b])
        XCTAssertTrue(bytes.contains(0x28))
        XCTAssertEqual(transport.abortedTokens, [])
    }

    @MainActor func testTypingAndLongDelaysAreCompiledIntoDeviceProgram() async {
        let transport = MockActionTransport()
        _ = await ActionExecutor().run(
            steps: [.text("hi"), .delay(60_000), .delay(60_000)], layout: .us,
            typingDelayMs: 25, token: 8, transport: transport, secretResolver: { _ in "" }
        )
        let bytes = Array(try! XCTUnwrap(transport.programs.first))
        XCTAssertGreaterThanOrEqual(bytes.filter { $0 == 0x02 }.count, 5)
    }

    @MainActor func testMouseClicksAreCompiledIntoDeviceProgram() async {
        let transport = MockActionTransport()
        let result = await ActionExecutor().run(
            steps: [.click(.right)], layout: .us, typingDelayMs: 0,
            token: 9, transport: transport, secretResolver: { _ in "" }
        )
        guard case .success = result else { return XCTFail("Expected success, got \(result)") }
        XCTAssertEqual(Array(try! XCTUnwrap(transport.programs.first).prefix(2)), [0x03, 0x01])
    }

    @MainActor func testLayoutValidationFailureUploadsNothing() async {
        let transport = MockActionTransport()
        let result = await ActionExecutor().run(
            steps: [.text("ok"), .text("ä")], layout: .us, typingDelayMs: 0,
            transport: transport, secretResolver: { _ in "" }
        )
        guard case .failure(.unsupportedCharacter(let character)) = result else {
            return XCTFail("Expected unsupportedCharacter, got \(result)")
        }
        XCTAssertEqual(character, "ä")
        XCTAssertTrue(transport.programs.isEmpty)
    }

    @MainActor func testRejectedUploadFails() async {
        let transport = MockActionTransport(); transport.acceptsPreset = false
        let result = await ActionExecutor().run(
            steps: [.text("ok")], layout: .us, typingDelayMs: 0,
            transport: transport, secretResolver: { _ in "" }
        )
        guard case .failure(.transportFailure) = result else { return XCTFail("Expected transportFailure, got \(result)") }
        XCTAssertEqual(transport.programs.count, 1)
    }

    @MainActor func testCancellationAbortsDeviceToken() async {
        let transport = MockActionTransport(); let token: UInt64 = 99
        let task = Task {
            await ActionExecutor().run(
                steps: [.key("enter"), .delay(5000)], layout: .us,
                typingDelayMs: 0, token: token, transport: transport, secretResolver: { _ in "" }
            )
        }
        task.cancel()
        let result = await task.value
        guard case .failure(.cancelled) = result else { return XCTFail("Expected cancellation, got \(result)") }
        XCTAssertEqual(transport.abortedTokens, [token])
    }

    @MainActor func testSecretIsResolvedToHIDReportsAndNeverStoredAsPlaintext() async {
        let transport = MockActionTransport()
        let result = await ActionExecutor().run(
            steps: [.secret("work-password")], layout: .us, typingDelayMs: 10,
            transport: transport, secretResolver: { _ in "hunter2" }
        )
        guard case .success = result else { return XCTFail("Expected success, got \(result)") }
        let program = try! XCTUnwrap(transport.programs.first)
        XCTAssertNil(String(data: program, encoding: .utf8)?.range(of: "hunter2"))
    }

    @MainActor func testMissingSecretFailsWithoutLeakingResolverError() async {
        let transport = MockActionTransport()
        struct LeakyError: LocalizedError { var errorDescription: String? { "hunter2 leaked" } }
        let result = await ActionExecutor().run(
            steps: [.secret("work-password")], layout: .us, typingDelayMs: 0,
            transport: transport, secretResolver: { _ in throw LeakyError() }
        )
        guard case .failure(let error) = result else { return XCTFail("Expected failure, got \(result)") }
        XCTAssertEqual(error.localizedDescription, "Secret ‘work-password’ is missing.")
        XCTAssertFalse(error.localizedDescription.contains("hunter2"))
        XCTAssertTrue(transport.programs.isEmpty)
    }

    @MainActor func testUnsupportedSecretCharacterFailsWithoutLeakingValue() async {
        let transport = MockActionTransport()
        let result = await ActionExecutor().run(
            steps: [.secret("work-password")], layout: .us, typingDelayMs: 0,
            transport: transport, secretResolver: { _ in "pässwort" }
        )
        guard case .failure(.transportFailure(let reason)) = result else { return XCTFail("Expected failure, got \(result)") }
        XCTAssertTrue(reason.contains("work-password")); XCTAssertFalse(reason.contains("ä"))
        XCTAssertTrue(transport.programs.isEmpty)
    }
}
