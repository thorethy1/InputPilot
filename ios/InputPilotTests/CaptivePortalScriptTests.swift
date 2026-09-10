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

    func testBLECommitIsSuccessEvenWhenBestEffortRefreshFails() async throws {
        let script = "INPUTPILOT-CAPTIVE/1\n#\(String(repeating: "x", count: 2_000))\nSUCCESS"
        let bluetooth = BinaryCaptiveRecorder()
        var waitedForBluetooth = false
        var wifiCalls = 0

        let result = try await CaptivePortalSaveCoordinator.save(
            ssid: "Hotel WiFi",
            delayMs: 4_000,
            enabled: true,
            script: script,
            bluetoothIsReady: true,
            waitForBluetooth: { _ in waitedForBluetooth = true },
            bluetoothRequest: { command, timeout in
                try await bluetooth.textReply(to: command, timeout: timeout)
            },
            bluetoothBinaryRequest: { payload, timeout in
                try await bluetooth.binaryReply(to: payload, timeout: timeout)
            },
            wifiRequests: [{ _, _ in
                wifiCalls += 1
                throw TransportError.failed("Wi-Fi must not be used after commit.")
            }]
        )

        let binaryOpcodes = await bluetooth.binaryOpcodes
        let timeouts = await bluetooth.timeouts
        XCTAssertEqual(result.transport, .bluetooth)
        XCTAssertEqual(
            result.metadata,
            CaptivePortalScriptMetadata(
                ssid: "Hotel WiFi", delayMs: 4_000, enabled: true,
                size: script.lengthOfBytes(using: .utf8)
            )
        )
        XCTAssertFalse(waitedForBluetooth)
        XCTAssertEqual(wifiCalls, 0)
        XCTAssertEqual(binaryOpcodes.first, 0x07)
        XCTAssertTrue(binaryOpcodes.dropFirst().allSatisfy { $0 == 0x08 })
        XCTAssertEqual(binaryOpcodes.count - 1, (result.metadata.size + 127) / 128)
        XCTAssertTrue(timeouts.allSatisfy { $0 == CaptivePortalSaveCoordinator.bluetoothOperationTimeout })

        let refreshed = await CaptivePortalDeviceClient.refreshAfterSuccessfulSave(
            preserving: [result.metadata],
            status: nil,
            using: { command, _ in
                throw TransportError.failed("Refresh failed for \(command).")
            }
        )
        XCTAssertEqual(refreshed.scripts, [result.metadata])
        XCTAssertNil(refreshed.status)
    }

    func testBLEFailureBeforeCommitFallsBackToWiFi() async throws {
        let script = "INPUTPILOT-CAPTIVE/1\nSUCCESS"
        let wifi = RequestRecorder()
        var bluetoothBinaryCalls = 0

        let result = try await CaptivePortalSaveCoordinator.save(
            ssid: "Lobby",
            delayMs: 0,
            enabled: true,
            script: script,
            bluetoothIsReady: true,
            waitForBluetooth: { _ in XCTFail("Ready Bluetooth must not wait.") },
            bluetoothRequest: { _, _ in throw TransportError.failed("Unexpected BLE text request.") },
            bluetoothBinaryRequest: { _, _ in
                bluetoothBinaryCalls += 1
                throw TransportError.failed("Secure Bluetooth response timed out.")
            },
            wifiRequests: [{ command, _ in try await wifi.reply(to: command) }]
        )

        let wifiCommands = await wifi.commands
        XCTAssertEqual(bluetoothBinaryCalls, 1)
        XCTAssertEqual(result.transport, .wifi)
        XCTAssertTrue(wifiCommands.last?.hasPrefix("CAPTIVE COMMIT ") == true)
    }

    func testBLEClearsStaleUploadAndRetriesBeginBeforeFallingBack() async throws {
        let script = "INPUTPILOT-CAPTIVE/1\nSUCCESS"
        let bluetooth = BinaryCaptiveRecorder(firstBeginIsBusy: true)
        var wifiCalls = 0

        let result = try await CaptivePortalSaveCoordinator.save(
            ssid: "Lobby",
            delayMs: 0,
            enabled: true,
            script: script,
            bluetoothIsReady: true,
            waitForBluetooth: { _ in XCTFail("Ready Bluetooth must not wait.") },
            bluetoothRequest: { command, timeout in
                try await bluetooth.textReply(to: command, timeout: timeout)
            },
            bluetoothBinaryRequest: { payload, timeout in
                try await bluetooth.binaryReply(to: payload, timeout: timeout)
            },
            wifiRequests: [{ _, _ in
                wifiCalls += 1
                throw TransportError.failed("Wi-Fi must not be used after BLE recovery.")
            }]
        )

        let beginAttempts = await bluetooth.beginAttempts
        let abortCalls = await bluetooth.abortCalls
        XCTAssertEqual(result.transport, .bluetooth)
        XCTAssertEqual(beginAttempts, 2)
        XCTAssertEqual(abortCalls, 1)
        XCTAssertEqual(wifiCalls, 0)
    }

    func testBluetoothReadinessWaitIsBoundedBeforeWiFiFallback() async throws {
        let script = "INPUTPILOT-CAPTIVE/1\nSUCCESS"
        let wifi = RequestRecorder()
        var readinessTimeout: TimeInterval?

        let result = try await CaptivePortalSaveCoordinator.save(
            ssid: "Lobby",
            delayMs: 0,
            enabled: true,
            script: script,
            bluetoothIsReady: false,
            waitForBluetooth: { timeout in
                readinessTimeout = timeout
                throw TransportError.failed("Encrypted Bluetooth connection timed out.")
            },
            bluetoothRequest: { _, _ in throw TransportError.failed("Unexpected BLE request.") },
            bluetoothBinaryRequest: { _, _ in throw TransportError.failed("Unexpected BLE request.") },
            wifiRequests: [{ command, _ in try await wifi.reply(to: command) }]
        )

        XCTAssertEqual(readinessTimeout, 1.5)
        XCTAssertEqual(result.transport, .wifi)
    }

    func testBLEAndWiFiFailuresAreBothReported() async {
        let script = "INPUTPILOT-CAPTIVE/1\nSUCCESS"

        do {
            _ = try await CaptivePortalSaveCoordinator.save(
                ssid: "Lobby",
                delayMs: 0,
                enabled: true,
                script: script,
                bluetoothIsReady: true,
                waitForBluetooth: { _ in XCTFail("Ready Bluetooth must not wait.") },
                bluetoothRequest: { _, _ in throw TransportError.failed("Bluetooth commit failed.") },
                bluetoothBinaryRequest: { _, _ in
                    throw TransportError.failed("Secure Bluetooth response timed out.")
                },
                wifiRequests: [{ _, _ in
                    throw TransportError.failed("Encrypted Wi-Fi connection timed out.")
                }]
            )
            XCTFail("Expected both transports to fail.")
        } catch let error as CaptivePortalSaveError {
            let description = error.localizedDescription
            XCTAssertTrue(description.contains("Bluetooth:"))
            XCTAssertTrue(description.contains("Secure Bluetooth response timed out."))
            XCTAssertTrue(description.contains("Wi-Fi:"))
            XCTAssertTrue(description.contains("Encrypted Wi-Fi connection timed out."))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPollingPausesForBusyOperationsAndPostSaveRefresh() {
        XCTAssertFalse(CaptivePortalPollingPolicy.shouldPoll(isBusy: true, isRefreshingAfterSave: false))
        XCTAssertFalse(CaptivePortalPollingPolicy.shouldPoll(isBusy: false, isRefreshingAfterSave: true))
        XCTAssertTrue(CaptivePortalPollingPolicy.shouldPoll(isBusy: false, isRefreshingAfterSave: false))
    }
}

private actor BinaryCaptiveRecorder {
    private let firstBeginIsBusy: Bool
    private var token: UInt64?
    private var received = 0
    private(set) var binaryOpcodes: [UInt8] = []
    private(set) var timeouts: [TimeInterval] = []
    private(set) var beginAttempts = 0
    private(set) var abortCalls = 0

    init(firstBeginIsBusy: Bool = false) {
        self.firstBeginIsBusy = firstBeginIsBusy
    }

    func binaryReply(to payload: Data, timeout: TimeInterval) throws -> String {
        guard payload.count >= 2, payload[0] == 0xFE else {
            throw TransportError.failed("Invalid binary request.")
        }
        binaryOpcodes.append(payload[1])
        timeouts.append(timeout)
        switch payload[1] {
        case 0x07:
            guard payload.count >= 10 else { throw TransportError.failed("Invalid BEGIN.") }
            beginAttempts += 1
            if firstBeginIsBusy, beginAttempts == 1 { return "error captive_busy" }
            token = payload[2 ..< 10].reduce(UInt64.zero) { ($0 << 8) | UInt64($1) }
            received = 0
            return "captive ready \(tokenText) 0"
        case 0x08:
            guard token != nil, payload.count >= 14 else { throw TransportError.failed("Invalid DATA.") }
            let offset = payload[10 ..< 14].reduce(Int.zero) { ($0 << 8) | Int($1) }
            guard offset == received else { throw TransportError.failed("Wrong DATA offset.") }
            received += payload.count - 14
            return "captive ack \(tokenText) \(received)"
        default:
            throw TransportError.failed("Unexpected binary opcode.")
        }
    }

    func textReply(to command: String, timeout: TimeInterval) throws -> String {
        timeouts.append(timeout)
        if command == "CAPTIVE ABORT" {
            abortCalls += 1
            token = nil
            received = 0
            return "captive aborted"
        }
        guard command == "CAPTIVE COMMIT \(tokenText)" else {
            throw TransportError.failed("Unexpected text request.")
        }
        return "captive committed"
    }

    private var tokenText: String {
        token.map { String(format: "%016llx", $0) } ?? ""
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
