import XCTest
@testable import InputPilot

@MainActor final class CaptivePortalScriptTests: XCTestCase {
    func testValidatorAcceptsBoundedWorkflowWithVariablesAndBranches() throws {
        let script = """
        INPUTPILOT-CAPTIVE/1
        GET http://detectportal.firefox.com/success.txt
        IF_BODY_CONTAINS success GOTO online
        REQUIRE_HOST_SUFFIX .example.test
        SET_ORIGIN BASE
        CAPTURE_BETWEEN TOKEN \"token\":\" || \"
        POST_FORM ${BASE}/login token=${url:TOKEN}
        EXPECT_STATUS 200
        CAPTURE_JSON LOGGED_IN loggedIn
        IF_BODY_CONTAINS never GOTO online
        SUCCESS Portal login complete
        LABEL online
        ALREADY_CONNECTED Internet is already available
        """

        XCTAssertNoThrow(try CaptivePortalScriptValidator.validate(script))
    }

    func testValidatorRejectsUnknownJumpTarget() {
        XCTAssertThrowsError(try CaptivePortalScriptValidator.validate("GOTO missing\nSUCCESS")) { error in
            XCTAssertEqual(error as? CaptivePortalScriptValidationError, .unknownLabel(1, "missing"))
        }
    }

    func testValidatorRejectsShellInsteadOfSilentlyAcceptingIt() {
        XCTAssertThrowsError(try CaptivePortalScriptValidator.validate("#!/bin/sh\ncurl http://example.test\nSUCCESS")) { error in
            XCTAssertEqual(error as? CaptivePortalScriptValidationError, .invalidLine(2, "unknown command."))
        }
    }

    func testCompactFirmwareStatusDecodesForTheUI() async throws {
        let status = try await CaptivePortalDeviceClient.status { command, _ in
            XCTAssertEqual(command, "CAPTIVE STATUS")
            return #"{"s":"failed","n":"Hotel","m":"Request failed","e":"NETWORK","t":1234}"#
        }
        XCTAssertEqual(status.state, .failed)
        XCTAssertEqual(status.ssid, "Hotel")
        XCTAssertEqual(status.error, "NETWORK")
        XCTAssertEqual(status.lastRunMs, 1_234)
    }

    func testDeviceClientUploadsChecksummedChunksAndCommits() async throws {
        let script = "INPUTPILOT-CAPTIVE/1\nGET http://example.test\nSUCCESS"
        let recorder = RequestRecorder()

        try await CaptivePortalDeviceClient.save(
            ssid: "Hotel WiFi", delayMs: 4_000, enabled: true, script: script,
            using: { command, _ in try await recorder.reply(to: command) }
        )

        let commands = await recorder.commands
        XCTAssertTrue(commands.first?.hasPrefix("CAPTIVE BEGIN ") == true)
        XCTAssertTrue(commands.contains { $0.hasPrefix("CAPTIVE DATA ") })
        XCTAssertTrue(commands.last?.hasPrefix("CAPTIVE COMMIT ") == true)
    }
}

private actor RequestRecorder {
    private(set) var commands: [String] = []
    private var token = ""
    private var received = 0

    func reply(to command: String) throws -> String {
        commands.append(command)
        let fields = command.split(separator: " ").map(String.init)
        if Array(fields.prefix(2)) == ["CAPTIVE", "BEGIN"] {
            token = fields[2]
            return "captive ready \(token) 0"
        }
        if Array(fields.prefix(2)) == ["CAPTIVE", "DATA"] {
            received += fields[4].count / 2
            return "captive ack \(token) \(received)"
        }
        if Array(fields.prefix(2)) == ["CAPTIVE", "COMMIT"] { return "captive committed" }
        if command == "CAPTIVE ABORT" { return "captive aborted" }
        throw TransportError.failed("Unexpected command")
    }
}
