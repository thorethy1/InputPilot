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

    func testValidatorAcceptsNewCommands() throws {
        let script = """
        INPUTPILOT-CAPTIVE/1
        CAPTURE_JSON_FIRST SESSION session || payload.session
        CAPTURE_OBJECT_STRING TOKEN token
        IF_VAR_EQUALS LOGGED_IN true GOTO done
        IF_BODY_EQUALS success GOTO online
        LABEL done
        SUCCESS Registered
        LABEL online
        ALREADY_CONNECTED Online
        """

        XCTAssertNoThrow(try CaptivePortalScriptValidator.validate(script))
    }

    func testValidatorAcceptsCompleteM3ConnectFixture() throws {
        let script = """
        INPUTPILOT-CAPTIVE/1
        HEADER User-Agent: Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148
        GET http://detectportal.firefox.com/success.txt
        IF_BODY_EQUALS success GOTO confirm_online
        GOTO portal
        LABEL confirm_online
        WAIT 2000
        GET http://detectportal.firefox.com/success.txt
        IF_BODY_EQUALS success GOTO online
        LABEL portal
        REQUIRE_HOST_SUFFIX .conn4.com
        SET_ORIGIN BASE
        CAPTURE_OBJECT_STRING TOKEN token
        CAPTURE_OBJECT_STRING SCENE id
        GET ${BASE}/scenes/${SCENE}/
        HEADER X-Requested-With: XMLHttpRequest
        HEADER Origin: ${BASE}
        HEADER Referer: ${BASE}/scenes/${SCENE}/
        HEADER Accept: */*
        POST_FORM ${BASE}/wbs/api/v1/create-session/ session_id=&with-tariffs=1&locale=de_DE&authorization=token%3D${url:TOKEN}
        CAPTURE_JSON_FIRST SESSION session || payload.session
        POST_FORM ${BASE}/wbs/api/v1/register/free/ authorization=session%3D${url:SESSION}&registration_type=terms-only&registration%5Bterms%5D=1
        CAPTURE_JSON REGISTER_OK ok
        IF_VAR_EQUALS REGISTER_OK true GOTO registered
        FAIL REGISTER_FAILED Registration failed
        LABEL registered
        POST_FORM ${BASE}/wbs/api/v1/login/status/ authorization=session%3D${url:SESSION}
        CAPTURE_JSON LOGGED_IN loggedIn
        IF_VAR_EQUALS LOGGED_IN true GOTO success
        WAIT 1000
        POST_FORM ${BASE}/wbs/api/v1/login/status/ authorization=session%3D${url:SESSION}
        CAPTURE_JSON LOGGED_IN loggedIn
        IF_VAR_EQUALS LOGGED_IN true GOTO success
        WAIT 1000
        POST_FORM ${BASE}/wbs/api/v1/login/status/ authorization=session%3D${url:SESSION}
        CAPTURE_JSON LOGGED_IN loggedIn
        IF_VAR_EQUALS LOGGED_IN true GOTO success
        WAIT 1000
        POST_FORM ${BASE}/wbs/api/v1/login/status/ authorization=session%3D${url:SESSION}
        CAPTURE_JSON LOGGED_IN loggedIn
        IF_VAR_EQUALS LOGGED_IN true GOTO success
        WAIT 1000
        POST_FORM ${BASE}/wbs/api/v1/login/status/ authorization=session%3D${url:SESSION}
        CAPTURE_JSON LOGGED_IN loggedIn
        IF_VAR_EQUALS LOGGED_IN true GOTO success
        FAIL LOGIN_NOT_CONFIRMED Login was not confirmed
        LABEL success
        SUCCESS WLAN freigeschaltet
        LABEL online
        ALREADY_CONNECTED Internet already available
        """

        XCTAssertEqual(script.lengthOfBytes(using: .utf8), 2_037)
        XCTAssertNoThrow(try CaptivePortalScriptValidator.validate(script))
    }

    func testValidatorRejectsMalformedNewCommands() {
        let cases: [String] = [
            "IF_BODY_EQUALS success GOTO missing\nSUCCESS",
            "IF_VAR_EQUALS true GOTO done\nLABEL done\nSUCCESS",
            "CAPTURE_JSON_FIRST SESSION\nSUCCESS",
            "IF_VAR_EQUALS LOGGED_IN true\nSUCCESS",
            "CAPTURE_OBJECT_STRING TOKEN invalid.key\nSUCCESS",
        ]
        for script in cases {
            XCTAssertThrowsError(try CaptivePortalScriptValidator.validate(script), script)
        }
    }

    func testValidatorRejectsOversizedScriptAtSharedLimit() {
        let script = String(repeating: "#", count: CaptivePortalScriptValidator.maximumBytes + 1)
        XCTAssertThrowsError(try CaptivePortalScriptValidator.validate(script)) { error in
            XCTAssertEqual(error as? CaptivePortalScriptValidationError,
                           .tooLarge(CaptivePortalScriptValidator.maximumBytes + 1))
        }
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
