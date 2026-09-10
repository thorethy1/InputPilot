import Foundation

struct CaptivePortalScriptMetadata: Codable, Equatable, Identifiable, Sendable {
    var id: String { ssid }
    let ssid: String
    let delayMs: Int
    let enabled: Bool
    let size: Int

    enum CodingKeys: String, CodingKey {
        case ssid, enabled, size
        case delayMs = "delay_ms"
    }
}

struct CaptivePortalRunStatus: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case idle, waiting, running, success, failed
        case alreadyConnected = "already_connected"

        var title: String {
            switch self {
            case .idle: "Not run"
            case .waiting: "Waiting"
            case .running: "Running"
            case .success: "Successful"
            case .alreadyConnected: "Already connected"
            case .failed: "Failed"
            }
        }
    }

    let state: State
    let ssid: String
    let message: String
    let error: String
    let lastRunMs: UInt64

    enum CodingKeys: String, CodingKey {
        case state = "s"
        case ssid = "n"
        case message = "m"
        case error = "e"
        case lastRunMs = "t"
    }
}

struct CaptivePortalRefreshSnapshot: Equatable, Sendable {
    let scripts: [CaptivePortalScriptMetadata]
    let status: CaptivePortalRunStatus?
}

enum CaptivePortalSaveTransport: String, Equatable, Sendable {
    case bluetooth = "BLE"
    case wifi = "Wi-Fi"
}

struct CaptivePortalSaveResult: Equatable, Sendable {
    let metadata: CaptivePortalScriptMetadata
    let transport: CaptivePortalSaveTransport
}

struct CaptivePortalSaveError: LocalizedError {
    let bluetoothError: Error
    let wifiError: Error

    var errorDescription: String? {
        """
        Could not save captive portal script.
        Bluetooth:
        \(bluetoothError.localizedDescription)
        Wi-Fi:
        \(wifiError.localizedDescription)
        """
    }
}

enum CaptivePortalPollingPolicy {
    static func shouldPoll(isBusy: Bool, isRefreshingAfterSave: Bool) -> Bool {
        !isBusy && !isRefreshingAfterSave
    }
}

enum CaptivePortalScriptValidationError: LocalizedError, Equatable {
    case empty
    case tooLarge(Int)
    case invalidLine(Int, String)
    case missingResult
    case duplicateLabel(Int, String)
    case unknownLabel(Int, String)

    var errorDescription: String? {
        switch self {
        case .empty: "The script is empty."
        case let .tooLarge(bytes): "The script is \(bytes) bytes; the device limit is \(CaptivePortalScriptValidator.maximumBytes) bytes."
        case let .invalidLine(line, reason): "Line \(line): \(reason)"
        case .missingResult: "The script needs SUCCESS, ALREADY_CONNECTED, or FAIL."
        case let .duplicateLabel(line, name): "Line \(line): label '\(name)' is duplicated."
        case let .unknownLabel(line, name): "Line \(line): label '\(name)' does not exist."
        }
    }
}

enum CaptivePortalScriptValidator {
    static let maximumBytes = 2_304

    static func validate(_ script: String) throws {
        let byteCount = script.lengthOfBytes(using: .utf8)
        guard byteCount > 0 else { throw CaptivePortalScriptValidationError.empty }
        guard byteCount <= maximumBytes else { throw CaptivePortalScriptValidationError.tooLarge(byteCount) }

        var labels = Set<String>()
        var jumps: [(line: Int, label: String)] = []
        var hasResult = false
        let lines = script.components(separatedBy: .newlines)
        for (offset, raw) in lines.enumerated() {
            let number = offset + 1
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line == "INPUTPILOT-CAPTIVE/1" { continue }
            if line.hasPrefix("LABEL ") {
                let name = argument(line, after: "LABEL ")
                guard validName(name) else { throw CaptivePortalScriptValidationError.invalidLine(number, "LABEL needs a simple name.") }
                guard labels.insert(name).inserted else { throw CaptivePortalScriptValidationError.duplicateLabel(number, name) }
                continue
            }
            if line.hasPrefix("GOTO ") {
                let name = argument(line, after: "GOTO ")
                guard validName(name) else { throw CaptivePortalScriptValidationError.invalidLine(number, "GOTO needs a label.") }
                jumps.append((number, name)); continue
            }
            if line.hasPrefix("IF_STATUS ") || line.hasPrefix("IF_BODY_CONTAINS ") ||
                line.hasPrefix("IF_BODY_EQUALS ") {
                guard let range = line.range(of: " GOTO ", options: .backwards) else {
                    throw CaptivePortalScriptValidationError.invalidLine(number, "the condition needs GOTO and a label.")
                }
                if line.hasPrefix("IF_STATUS ") {
                    let start = line.index(line.startIndex, offsetBy: "IF_STATUS ".count)
                    guard Int(line[start ..< range.lowerBound]) != nil else {
                        throw CaptivePortalScriptValidationError.invalidLine(number, "IF_STATUS needs an HTTP status code.")
                    }
                }
                if line.hasPrefix("IF_BODY_EQUALS ") {
                    let start = line.index(line.startIndex, offsetBy: "IF_BODY_EQUALS ".count)
                    guard !String(line[start ..< range.lowerBound]).trimmingCharacters(in: .whitespaces).isEmpty else {
                        throw CaptivePortalScriptValidationError.invalidLine(number, "IF_BODY_EQUALS needs comparison text.")
                    }
                }
                let name = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                guard validName(name) else { throw CaptivePortalScriptValidationError.invalidLine(number, "GOTO needs a valid label.") }
                jumps.append((number, name)); continue
            }
            if line.hasPrefix("IF_VAR_EQUALS ") {
                guard let range = line.range(of: " GOTO ", options: .backwards) else {
                    throw CaptivePortalScriptValidationError.invalidLine(number, "IF_VAR_EQUALS needs GOTO and a label.")
                }
                let start = line.index(line.startIndex, offsetBy: "IF_VAR_EQUALS ".count)
                let operands = String(line[start ..< range.lowerBound])
                guard let separator = operands.firstIndex(of: " ") else {
                    throw CaptivePortalScriptValidationError.invalidLine(number, "IF_VAR_EQUALS needs a variable name and value.")
                }
                let variable = String(operands[..<separator])
                let value = String(operands[operands.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
                guard validPortableName(variable), !value.isEmpty else {
                    throw CaptivePortalScriptValidationError.invalidLine(number, "IF_VAR_EQUALS needs a valid variable name and value.")
                }
                let name = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                guard validName(name) else { throw CaptivePortalScriptValidationError.invalidLine(number, "GOTO needs a valid label.") }
                jumps.append((number, name)); continue
            }
            if line.hasPrefix("WAIT ") {
                guard let milliseconds = Int(argument(line, after: "WAIT ")), (0 ... 60_000).contains(milliseconds) else {
                    throw CaptivePortalScriptValidationError.invalidLine(number, "WAIT must be between 0 and 60000 ms.")
                }
                continue
            }
            if line.hasPrefix("GET ") {
                guard !argument(line, after: "GET ").isEmpty else { throw CaptivePortalScriptValidationError.invalidLine(number, "GET needs a URL.") }
                continue
            }
            if line.hasPrefix("POST_FORM ") || line.hasPrefix("POST_JSON ") {
                let prefix = line.hasPrefix("POST_FORM ") ? "POST_FORM " : "POST_JSON "
                let value = argument(line, after: prefix)
                guard value.firstIndex(of: " ") != nil else {
                    throw CaptivePortalScriptValidationError.invalidLine(number, "\(prefix.trimmingCharacters(in: .whitespaces)) needs a URL and body.")
                }
                continue
            }
            if line.hasPrefix("HEADER ") {
                let header = argument(line, after: "HEADER ")
                guard let separator = header.firstIndex(of: ":") else {
                    throw CaptivePortalScriptValidationError.invalidLine(number, "HEADER needs 'Name: value'.")
                }
                let name = String(header[..<separator])
                let tokenPunctuation = "!#$%&'*+-.^_`|~"
                guard !name.isEmpty, name.utf8.count <= 64,
                      name.allSatisfy({ $0.isLetter || $0.isNumber || tokenPunctuation.contains($0) }) else {
                    throw CaptivePortalScriptValidationError.invalidLine(number, "HEADER has an invalid name.")
                }
                continue
            }
            if line.hasPrefix("EXPECT_STATUS ") {
                guard Int(argument(line, after: "EXPECT_STATUS ")) != nil else { throw CaptivePortalScriptValidationError.invalidLine(number, "EXPECT_STATUS needs an HTTP status code.") }
                continue
            }
            if line.hasPrefix("CAPTURE_JSON ") {
                guard argument(line, after: "CAPTURE_JSON ").split(separator: " ", maxSplits: 1).count == 2 else {
                    throw CaptivePortalScriptValidationError.invalidLine(number, "CAPTURE_JSON needs a variable name and JSON path.")
                }
                continue
            }
            if line.hasPrefix("CAPTURE_JSON_FIRST ") {
                let arguments = argument(line, after: "CAPTURE_JSON_FIRST ")
                guard let separator = arguments.firstIndex(of: " ") else {
                    throw CaptivePortalScriptValidationError.invalidLine(number, "CAPTURE_JSON_FIRST needs a variable name and path.")
                }
                let variable = String(arguments[..<separator])
                let pathList = String(arguments[arguments.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
                let paths = pathList.components(separatedBy: " || ")
                guard validPortableName(variable), !paths.isEmpty,
                      paths.allSatisfy({ validDotPath($0.trimmingCharacters(in: .whitespaces)) }) else {
                    throw CaptivePortalScriptValidationError.invalidLine(number, "CAPTURE_JSON_FIRST needs a valid variable and one or more dot-paths separated by ' || '.")
                }
                continue
            }
            if line.hasPrefix("CAPTURE_OBJECT_STRING ") {
                let fields = argument(line, after: "CAPTURE_OBJECT_STRING ").split(separator: " ", omittingEmptySubsequences: true)
                guard fields.count == 2, validPortableName(String(fields[0])),
                      validPortableName(String(fields[1])) else {
                    throw CaptivePortalScriptValidationError.invalidLine(number, "CAPTURE_OBJECT_STRING needs a valid variable name and key.")
                }
                continue
            }
            if line.hasPrefix("REQUIRE_HOST_SUFFIX ") {
                let suffix = argument(line, after: "REQUIRE_HOST_SUFFIX ")
                guard suffix.hasPrefix("."), suffix.count > 1, !suffix.contains("/") else {
                    throw CaptivePortalScriptValidationError.invalidLine(number, "REQUIRE_HOST_SUFFIX needs a leading-dot domain suffix.")
                }
                continue
            }
            if line.hasPrefix("SET_ORIGIN ") {
                guard validName(argument(line, after: "SET_ORIGIN ")) else {
                    throw CaptivePortalScriptValidationError.invalidLine(number, "SET_ORIGIN needs a valid variable name.")
                }
                continue
            }
            if line.hasPrefix("EXPECT_BODY ") {
                guard line.contains(" "), !line.split(separator: " ", maxSplits: 1).last!.isEmpty else {
                    throw CaptivePortalScriptValidationError.invalidLine(number, "the command needs an argument.")
                }
                continue
            }
            if line.hasPrefix("CAPTURE_BETWEEN ") {
                guard line.contains(" || ") else { throw CaptivePortalScriptValidationError.invalidLine(number, "CAPTURE_BETWEEN needs 'name prefix || suffix'.") }
                continue
            }
            if line == "SUCCESS" || line.hasPrefix("SUCCESS ") ||
                line == "ALREADY_CONNECTED" || line.hasPrefix("ALREADY_CONNECTED ") ||
                line.hasPrefix("FAIL ") {
                hasResult = true; continue
            }
            throw CaptivePortalScriptValidationError.invalidLine(number, "unknown command.")
        }
        for jump in jumps where !labels.contains(jump.label) {
            throw CaptivePortalScriptValidationError.unknownLabel(jump.line, jump.label)
        }
        guard hasResult else { throw CaptivePortalScriptValidationError.missingResult }
    }

    private static func argument(_ line: String, after prefix: String) -> String {
        String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    private static func validName(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    private static func validDotPath(_ value: String) -> Bool {
        !value.isEmpty && value.split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy { validPortableName(String($0)) }
    }

    private static func validPortableName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            ($0 >= 97 && $0 <= 122) || ($0 >= 65 && $0 <= 90) ||
                ($0 >= 48 && $0 <= 57) || $0 == 95 || $0 == 45
        }
    }
}

@MainActor enum CaptivePortalDeviceClient {
    typealias Request = (_ command: String, _ timeout: TimeInterval) async throws -> String
    typealias BinaryRequest = (_ payload: Data, _ timeout: TimeInterval) async throws -> String

    static func list(using request: Request) async throws -> [CaptivePortalScriptMetadata] {
        struct Count: Decodable { let count: Int }
        let summary = try decode(Count.self, from: try await request("CAPTIVE LIST", 5))
        guard (0 ... 5).contains(summary.count) else { throw TransportError.failed("InputPilot returned an invalid captive script count.") }
        var result: [CaptivePortalScriptMetadata] = []
        for index in 0 ..< summary.count {
            result.append(try decode(CaptivePortalScriptMetadata.self, from: try await request("CAPTIVE GET \(index)", 5)))
        }
        return result
    }

    static func status(using request: Request) async throws -> CaptivePortalRunStatus {
        try decode(CaptivePortalRunStatus.self, from: try await request("CAPTIVE STATUS", 5))
    }

    static func refreshAfterSuccessfulSave(
        preserving scripts: [CaptivePortalScriptMetadata],
        status: CaptivePortalRunStatus?,
        using request: Request
    ) async -> CaptivePortalRefreshSnapshot {
        var refreshedScripts = scripts
        var refreshedStatus = status
        do {
            refreshedScripts = try await list(using: request)
        } catch {
            appLog(.errors, "CAPTIVE refresh failed after successful save phase=list error=\(error.localizedDescription)")
        }
        do {
            refreshedStatus = try await self.status(using: request)
        } catch {
            appLog(.errors, "CAPTIVE refresh failed after successful save phase=status error=\(error.localizedDescription)")
        }
        return CaptivePortalRefreshSnapshot(scripts: refreshedScripts, status: refreshedStatus)
    }

    static func script(index: Int, size: Int, using request: Request) async throws -> String {
        guard (0 ... maximumScriptSize).contains(size) else { throw TransportError.failed("InputPilot returned an invalid captive script size.") }
        var data = Data()
        while data.count < size {
            let length = min(60, size - data.count)
            let reply = try await request("CAPTIVE READ \(index) \(data.count) \(length)", 5)
            let fields = reply.split(separator: " ", maxSplits: 3).map(String.init)
            guard fields.count == 4, fields[0] == "captive", fields[1] == "data",
                  Int(fields[2]) == data.count, let chunk = Data(captiveHex: fields[3]), !chunk.isEmpty else {
                throw TransportError.failed("InputPilot returned an invalid captive script chunk.")
            }
            data.append(chunk)
        }
        guard data.count == size, let value = String(data: data, encoding: .utf8) else {
            throw TransportError.failed("The captive script is not valid UTF-8.")
        }
        return value
    }

    static func save(ssid: String, delayMs: Int, enabled: Bool, script: String,
                     token suppliedToken: UInt64? = nil, using request: Request,
                     binaryRequest: BinaryRequest? = nil,
                     transportLabel suppliedTransportLabel: String? = nil,
                     operationTimeout: TimeInterval = 8,
                     abortOnFailure: Bool = true,
                     abortTimeout: TimeInterval = 3) async throws {
        try CaptivePortalScriptValidator.validate(script)
        let ssidData = Data(ssid.utf8)
        let scriptData = Data(script.utf8)
        guard (1 ... 32).contains(ssidData.count), (0 ... 60_000).contains(delayMs) else {
            throw TransportError.failed("Wi-Fi names are limited to 32 bytes and the delay to 60 seconds.")
        }
        let token = suppliedToken ?? UInt64.random(in: 1 ... UInt64.max)
        let tokenText = String(format: "%016llx", token)
        let checksum = fnv1a(scriptData)
        let transportLabel = suppliedTransportLabel ?? (binaryRequest == nil ? "Wi-Fi" : "BLE")
        var phase = "begin"
        do {
            appLog(.control, "CAPTIVE \(transportLabel) begin")
            let beginReply: String
            if let binaryRequest {
                var payload = Data([0xFE, 0x07])
                payload.appendBigEndian(token)
                payload.appendBigEndian(UInt32(delayMs))
                payload.appendBigEndian(UInt16(scriptData.count))
                payload.appendBigEndian(checksum)
                payload.append(enabled ? 1 : 0)
                payload.append(UInt8(ssidData.count))
                payload.append(ssidData)
                beginReply = try await binaryRequest(payload, operationTimeout)
            } else {
                let begin = "CAPTIVE BEGIN \(tokenText) \(ssidData.hex) \(delayMs) \(scriptData.count) \(String(format: "%08x", checksum)) \(enabled ? 1 : 0)"
                beginReply = try await request(begin, operationTimeout)
            }
            let beginFields = beginReply.split(separator: " ").map(String.init)
            guard beginFields.count == 4, beginFields[0] == "captive", beginFields[1] == "ready",
                  beginFields[2] == tokenText, let receivedOffset = Int(beginFields[3]),
                  (0 ... scriptData.count).contains(receivedOffset) else {
                throw protocolError(beginReply)
            }
            appLog(.control, "CAPTIVE \(transportLabel) ready offset=\(receivedOffset)")
            // BEGIN is idempotent for the same token and metadata, allowing a
            // partially transferred BLE upload to resume over secure Wi-Fi.
            var offset = receivedOffset
            while offset < scriptData.count {
                // 128 raw bytes plus the binary envelope fits an ATT MTU of
                // 185; larger negotiated MTUs are not required for this path.
                let count = min(binaryRequest == nil ? 60 : 128, scriptData.count - offset)
                let chunk = Data(scriptData[offset ..< offset + count])
                phase = "data offset=\(offset)"
                appLog(.control, "CAPTIVE \(transportLabel) chunk offset=\(offset) size=\(count)")
                let chunkReply: String
                if let binaryRequest {
                    var payload = Data([0xFE, 0x08])
                    payload.appendBigEndian(token)
                    payload.appendBigEndian(UInt32(offset))
                    payload.append(chunk)
                    chunkReply = try await binaryRequest(payload, operationTimeout)
                } else {
                    chunkReply = try await request("CAPTIVE DATA \(tokenText) \(offset) \(chunk.hex)", operationTimeout)
                }
                offset += count
                guard chunkReply == "captive ack \(tokenText) \(offset)" else { throw protocolError(chunkReply) }
            }
            phase = "commit"
            appLog(.control, "CAPTIVE \(transportLabel) commit")
            let commitReply = try await request("CAPTIVE COMMIT \(tokenText)", operationTimeout)
            guard commitReply == "captive committed" else { throw protocolError(commitReply) }
            appLog(.control, "CAPTIVE \(transportLabel) committed")
        } catch {
            appLog(.errors, "CAPTIVE \(transportLabel) failed phase=\(phase) error=\(error.localizedDescription)")
            if abortOnFailure {
                _ = try? await request("CAPTIVE ABORT \(tokenText)", abortTimeout)
            }
            throw error
        }
    }

    static func remove(ssid: String, using request: Request) async throws {
        let reply = try await request("CAPTIVE REMOVE \(Data(ssid.utf8).hex)", 5)
        guard reply == "captive removed" else { throw protocolError(reply) }
    }

    static func run(ssid: String, using request: Request) async throws {
        let reply = try await request("CAPTIVE RUN \(Data(ssid.utf8).hex)", 5)
        guard reply == "captive started" else { throw protocolError(reply) }
    }

    private static let maximumScriptSize = CaptivePortalScriptValidator.maximumBytes

    private static func decode<T: Decodable>(_ type: T.Type, from reply: String) throws -> T {
        if reply.hasPrefix("error ") { throw protocolError(reply) }
        do { return try JSONDecoder().decode(type, from: Data(reply.utf8)) }
        catch { throw TransportError.failed("InputPilot returned invalid captive portal data.") }
    }

    private static func protocolError(_ reply: String) -> Error {
        let code = reply.hasPrefix("error ") ? String(reply.dropFirst(6)) : reply
        return switch code {
        case "captive_not_found": TransportError.failed("The captive portal script no longer exists.")
        case "captive_busy": TransportError.failed("Another captive portal operation is already active.")
        case "captive_wrong_network": TransportError.failed("InputPilot is not connected to that Wi-Fi network.")
        case "captive_storage": TransportError.failed("InputPilot could not persist the captive portal script.")
        case "captive_checksum": TransportError.failed("The captive portal script failed checksum validation.")
        default: TransportError.failed("InputPilot rejected the captive portal operation (\(code)).")
        }
    }

    private static func fnv1a(_ data: Data) -> UInt32 {
        data.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
    }
}

@MainActor enum CaptivePortalSaveCoordinator {
    static let bluetoothReadinessTimeout: TimeInterval = 1.5
    static let bluetoothOperationTimeout: TimeInterval = 3
    static let wifiOperationTimeout: TimeInterval = 8
    static let abortTimeout: TimeInterval = 1

    static func save(
        ssid: String,
        delayMs: Int,
        enabled: Bool,
        script: String,
        bluetoothIsReady: Bool,
        waitForBluetooth: (_ timeout: TimeInterval) async throws -> Void,
        bluetoothRequest: @escaping CaptivePortalDeviceClient.Request,
        bluetoothBinaryRequest: @escaping CaptivePortalDeviceClient.BinaryRequest,
        wifiRequests: [CaptivePortalDeviceClient.Request]
    ) async throws -> CaptivePortalSaveResult {
        try CaptivePortalScriptValidator.validate(script)
        let ssidByteCount = ssid.lengthOfBytes(using: .utf8)
        guard (1 ... 32).contains(ssidByteCount), (0 ... 60_000).contains(delayMs) else {
            throw TransportError.failed("Wi-Fi names are limited to 32 bytes and the delay to 60 seconds.")
        }
        let startedAt = Date()
        let byteCount = script.lengthOfBytes(using: .utf8)
        let metadata = CaptivePortalScriptMetadata(
            ssid: ssid, delayMs: delayMs, enabled: enabled, size: byteCount
        )
        let uploadToken = UInt64.random(in: 1 ... UInt64.max)
        appLog(.control, "CAPTIVE save start ssid=\(ssid) bytes=\(byteCount)")

        var bluetoothError: Error
        var bluetoothReadinessCompleted = bluetoothIsReady
        do {
            if !bluetoothIsReady {
                try await waitForBluetooth(bluetoothReadinessTimeout)
                bluetoothReadinessCompleted = true
            }
            appLog(.control, "CAPTIVE transport=BLE ready")
            try await CaptivePortalDeviceClient.save(
                ssid: ssid, delayMs: delayMs, enabled: enabled, script: script,
                token: uploadToken,
                using: bluetoothRequest,
                binaryRequest: bluetoothBinaryRequest,
                transportLabel: CaptivePortalSaveTransport.bluetooth.rawValue,
                operationTimeout: bluetoothOperationTimeout,
                abortOnFailure: wifiRequests.isEmpty,
                abortTimeout: abortTimeout
            )
            logSuccess(transport: .bluetooth, startedAt: startedAt)
            return CaptivePortalSaveResult(metadata: metadata, transport: .bluetooth)
        } catch {
            bluetoothError = error
            if !bluetoothReadinessCompleted {
                appLog(.errors, "CAPTIVE BLE failed phase=readiness error=\(error.localizedDescription)")
            }
        }

        appLog(.control, "CAPTIVE fallback transport=Wi-Fi")
        var wifiError: Error = TransportError.unavailable
        for (index, wifiRequest) in wifiRequests.enumerated() {
            do {
                try await CaptivePortalDeviceClient.save(
                    ssid: ssid, delayMs: delayMs, enabled: enabled, script: script,
                    token: uploadToken,
                    using: wifiRequest,
                    transportLabel: CaptivePortalSaveTransport.wifi.rawValue,
                    operationTimeout: wifiOperationTimeout,
                    abortOnFailure: index == wifiRequests.index(before: wifiRequests.endIndex),
                    abortTimeout: abortTimeout
                )
                logSuccess(transport: .wifi, startedAt: startedAt)
                return CaptivePortalSaveResult(metadata: metadata, transport: .wifi)
            } catch {
                wifiError = error
            }
        }
        throw CaptivePortalSaveError(bluetoothError: bluetoothError, wifiError: wifiError)
    }

    private static func logSuccess(transport: CaptivePortalSaveTransport, startedAt: Date) {
        let milliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
        appLog(.control, "CAPTIVE save success transport=\(transport.rawValue) duration=\(milliseconds)ms")
    }
}

private extension Data {
    init?(captiveHex hex: String) {
        guard !hex.isEmpty, hex.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8](); bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
            bytes.append(byte); index = next
        }
        self.init(bytes)
    }

    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var encoded = value.bigEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }
}
