import CoreBluetooth
import CryptoKit
import Foundation
import Network
import OSLog
import SwiftData
import SwiftUI
import UIKit

enum AppLogCategory: String, CaseIterable, Identifiable { case all = "All", input = "Input", control = "Control", bluetooth = "Bluetooth", tcp = "TCP", diagnostics = "Diagnostics", errors = "Errors"; var id: String { rawValue } }
struct AppLogRecord: Identifiable, Equatable {
    let id = UUID(); let date: Date; let category: AppLogCategory; let message: String
    var line: String { "\(date.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3)))) \(category.rawValue.uppercased()) \(message)" }
    func matches(_ filter: AppLogCategory) -> Bool { filter == .all || filter == category || (filter == .errors && message.localizedCaseInsensitiveContains("error")) }
}
@MainActor final class AppLog: ObservableObject {
    static let shared = AppLog(); static let capacity = 1000
    @Published private(set) var records: [AppLogRecord] = []
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "InputPilot", category: "diagnostics")
    func write(_ category: AppLogCategory, _ message: String) {
        logger.log("[\(category.rawValue, privacy: .public)] \(message, privacy: .public)")
        records.append(AppLogRecord(date: Date(), category: category, message: message))
        if records.count > Self.capacity { records.removeFirst(records.count - Self.capacity) }
    }
    func clear() { records.removeAll(keepingCapacity: true) }
}
enum AppLogContext { @TaskLocal static var eventID: UInt64? }
private func appLog(_ category: AppLogCategory, _ message: String) { Task { @MainActor in AppLog.shared.write(category, message) } }

enum MouseButton: UInt8, Codable, CaseIterable { case left = 0, right = 1, middle = 2 }
enum HIDEvent: Codable, Equatable {
    case mouseMove(Int16, Int16), scroll(Int16), mouseDown(MouseButton), mouseUp(MouseButton)
    case click(MouseButton), typeText(String), key(String), keyCombo(String)
    case keyboardReport(modifiers: UInt8, usage: UInt8)
    case releaseAll, ping

    var prefersLowLatency: Bool {
        switch self { case .mouseMove, .scroll, .mouseDown, .mouseUp, .click, .key, .keyCombo, .keyboardReport, .releaseAll, .ping: true; case .typeText: false }
    }
    var diagnosticName: String {
        switch self { case let .mouseMove(x,y): "mouse_move dx=\(x) dy=\(y)"; case let .scroll(v): "scroll value=\(v)"; case .mouseDown: "mouse_down"; case .mouseUp: "mouse_up"; case .click: "mouse_click"; case let .typeText(text): "keyboard_text length=\(text.count)"; case .key: "keyboard_key"; case .keyCombo: "keyboard_combo"; case .keyboardReport: "keyboard_report"; case .releaseAll: "release_all"; case .ping: "ping" }
    }
    var safeToRetryAfterUncertainDelivery: Bool { switch self { case .mouseMove, .scroll, .ping: true; default: false } }
    var binary: Data {
        var bytes: [UInt8] = [1]
        func append(_ value: Int16) { let raw = UInt16(bitPattern: value); bytes += [UInt8(raw & 255), UInt8(raw >> 8)] }
        switch self {
        case let .mouseMove(x, y): bytes.append(1); append(x); append(y)
        case let .scroll(value): bytes.append(2); append(value)
        case let .mouseDown(button): bytes += [3, button.rawValue]
        case let .mouseUp(button): bytes += [4, button.rawValue]
        case let .click(button): bytes += [5, button.rawValue]
        case let .typeText(text): bytes.append(0x10); bytes += text.utf8
        case let .key(name): bytes.append(0x11); bytes += name.utf8
        case let .keyCombo(combo): bytes.append(0x12); bytes += combo.utf8
        case let .keyboardReport(modifiers, usage): bytes += [0x13, modifiers, usage]
        case .releaseAll: bytes.append(0x20)
        case .ping: bytes.append(0x7f)
        }
        return Data(bytes)
    }
    var line: String {
        func button(_ b: MouseButton) -> String { String(describing: b) }
        switch self {
        case let .mouseMove(x, y): return "move \(x) \(y)"
        case let .scroll(v): return "move 0 0 \(v)"
        case let .mouseDown(b): return "button \(button(b)) down"
        case let .mouseUp(b): return "button \(button(b)) up"
        case let .click(b): return "click \(button(b))"
        case let .typeText(t): return "type \(t)"
        case let .key(k), let .keyCombo(k): return "key \(k)"
        case let .keyboardReport(modifiers, usage): return "report \(modifiers) \(usage)"
        case .releaseAll: return "release all"
        case .ping: return "ping"
        }
    }
}

enum ConnectionMode: String, CaseIterable, Codable, Identifiable {
    case automatic = "Automatic", preferBluetooth = "Prefer Bluetooth", preferWiFi = "Prefer Wi-Fi"
    case bluetoothOnly = "Bluetooth Only", wifiOnly = "Wi-Fi Only"
    var id: String { rawValue }
}
enum TransportKind: String { case bluetooth = "Bluetooth", tcp = "Wi-Fi" }
enum TransportConnectionState: String, Equatable {
    case unavailable, offline, discovering, discovered, connecting, connected, reconnecting, authenticating, ready, authenticationFailed

    var title: String {
        switch self {
        case .unavailable: "Unavailable"
        case .offline: "Offline"
        case .discovering: "Searching"
        case .discovered: "Discovered"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting"
        case .authenticating: "Authenticating"
        case .ready: "Ready"
        case .authenticationFailed: "Authentication failed"
        }
    }
}
enum BluetoothRadioState: String, Equatable {
    case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn
}

protocol HIDControlTransport: AnyObject {
    var kind: TransportKind { get }
    var isAvailable: Bool { get }
    var state: TransportConnectionState { get }
    func connect() async
    func send(_ event: HIDEvent) async throws
    func disconnect() async
}

enum TransportError: LocalizedError { case unavailable, encoding, failed(String)
    var errorDescription: String? { switch self { case .unavailable: "Transport unavailable"; case .encoding: "Could not encode event"; case let .failed(s): s } }
}

struct USBIdentity: Codable, Equatable {
    let manufacturerName: String?
    let productName: String
    let vid: Int
    let pid: Int
    let serialNumber: String

    enum CodingKeys: String, CodingKey {
        case manufacturerName = "manufacturer_name"
        case productName = "product_name"
        case vid, pid
        case serialNumber = "serial_number"
    }

    init(manufacturerName: String? = nil, productName: String, vid: Int, pid: Int, serialNumber: String) {
        self.manufacturerName = manufacturerName
        self.productName = productName
        self.vid = vid
        self.pid = pid
        self.serialNumber = serialNumber
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        manufacturerName = try values.decodeIfPresent(String.self, forKey: .manufacturerName)
        productName = try values.decode(String.self, forKey: .productName)
        vid = try values.decode(Int.self, forKey: .vid)
        pid = try values.decode(Int.self, forKey: .pid)
        serialNumber = try values.decode(String.self, forKey: .serialNumber)
    }
}

final class TCPHIDControlTransport: HIDControlTransport {
    let kind = TransportKind.tcp
    private let host: NWEndpoint.Host; private let deviceId: String; private var connection: NWConnection?
    private var secureChannel: SecureChannel?
    private(set) var isAvailable = false
    private(set) var state: TransportConnectionState = .offline
    private var shouldReconnect = false
    private var receiveBuffer = Data()
    private var receiving = false
    private var authTimeoutWork: DispatchWorkItem?
    private var reconnectWork: DispatchWorkItem?
    private let authTimeout: TimeInterval
    private struct PendingReply {
        let id: UUID
        let continuation: CheckedContinuation<String, Error>
        let timeout: DispatchWorkItem
    }
    private var pendingReplies: [PendingReply] = []
    private var otaAcknowledged = 0
    private var otaProtocolError: String?
    private var otaCancelled = false
    private var otaTransferActive = false
    private var otaUsesWindowedFlow = false
    init(host: String, deviceId: String, authTimeout: TimeInterval = 4) { self.host = NWEndpoint.Host(host); self.deviceId = deviceId.lowercased(); self.authTimeout = authTimeout }
    func connect() async {
        shouldReconnect = true
        reconnectWork?.cancel(); reconnectWork = nil
        if connection != nil { return }
        state = state == .offline ? .connecting : .reconnecting
        let conn = NWConnection(host: host, port: 3333, using: .tcp); connection = conn
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn, self.connection === conn else { return }
            switch state {
            case .ready:
                appLog(.tcp, "connected host=\(self.host) deviceId=\(self.deviceId); authenticating")
                self.startReceiveLoop(on: conn)
                if let secret = PairingKeyStore.load(deviceId: self.deviceId),
                   let channel = try? SecureChannel(deviceId: deviceId, secret: secret) {
                    self.secureChannel = channel
                    self.state = .authenticating
                    self.startAuthTimeout(for: conn)
                    conn.send(content: Data("secure begin\n".utf8), completion: .contentProcessed { [weak self, weak conn] error in
                        guard let self, let conn, self.connection === conn, let error else { return }
                        self.failConnection(error.localizedDescription, on: conn)
                    })
                } else { self.failAuthentication(on: conn) }
            case .failed, .cancelled:
                appLog(.tcp, "connection ended host=\(self.host) state=\(String(describing: state)) reconnect=\(self.shouldReconnect)")
                self.authTimeoutWork?.cancel(); self.authTimeoutWork = nil; self.receiving = false; self.receiveBuffer.removeAll(); self.secureChannel = nil; self.isAvailable = false; self.connection = nil; self.failPendingReplies(TransportError.unavailable)
                let authFailed = self.state == .authenticationFailed
                self.state = authFailed ? .authenticationFailed : (self.shouldReconnect ? .reconnecting : .offline)
                if self.shouldReconnect && !authFailed {
                    self.reconnectWork?.cancel()
                    let work = DispatchWorkItem { [weak self] in
                        guard let self, self.shouldReconnect else { return }
                        Task { await self.connect() }
                    }
                    self.reconnectWork = work
                    appLog(.tcp, "reconnect scheduled host=\(self.host) delay=2s")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
                }
            default: self.isAvailable = false
            }
        }
        conn.start(queue: .main)
    }
    private func startReceiveLoop(on conn: NWConnection) {
        guard !receiving, connection === conn else { return }
        receiving = true
        receiveNext(on: conn)
    }
    private func receiveNext(on conn: NWConnection) {
        guard receiving, connection === conn else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak conn] data, _, complete, error in
            guard let self, let conn, self.connection === conn else { return }
            if let data, !data.isEmpty { self.consume(data, on: conn) }
            if let error { self.failConnection(error.localizedDescription, on: conn); return }
            if complete { self.failConnection("Connection closed", on: conn); return }
            self.receiveNext(on: conn)
        }
    }
    private func consume(_ data: Data, on conn: NWConnection) {
        receiveBuffer.append(data)
        while let newline = receiveBuffer.firstIndex(of: 0x0a) {
            let lineData = receiveBuffer[..<newline]
            receiveBuffer.removeSubrange(...newline)
            guard let raw = String(data: lineData, encoding: .utf8) else { continue }
            handleReply(raw.trimmingCharacters(in: .whitespacesAndNewlines), on: conn)
        }
    }
    private func handleReply(_ reply: String, on conn: NWConnection) {
        if state == .authenticating, let secureChannel {
            do {
                if reply.hasPrefix("secure challenge ") {
                    let hello = try secureChannel.hello(for: reply)
                    conn.send(content: Data((hello + "\n").utf8), completion: .contentProcessed { [weak self, weak conn] error in
                        guard let self, let conn, self.connection === conn, let error else { return }
                        self.failConnection(error.localizedDescription, on: conn)
                    })
                    return
                }
                if reply.hasPrefix("secure ready ") {
                    try secureChannel.acceptReady(reply)
                    authTimeoutWork?.cancel(); authTimeoutWork = nil; isAvailable = true; state = .ready
                    return
                }
                if reply == "secure failed" {
                    failAuthentication(on: conn)
                    return
                }
            } catch {
                failAuthentication(on: conn)
                return
            }
        }
        guard state == .ready, let secureChannel,
              let plaintext = try? secureChannel.openText(reply) else { return }
        if otaUsesWindowedFlow, plaintext.hasPrefix("ota ack "),
           let offset = Int(plaintext.dropFirst("ota ack ".count)) {
            otaAcknowledged = max(otaAcknowledged, offset)
            return
        }
        if !pendingReplies.isEmpty {
            let pending = pendingReplies.removeFirst(); pending.timeout.cancel()
            pending.continuation.resume(returning: plaintext); return
        }
        if plaintext.hasPrefix("ota ack "),
           let offset = Int(plaintext.dropFirst("ota ack ".count)) {
            otaAcknowledged = max(otaAcknowledged, offset)
            return
        }
        if plaintext.lowercased().hasPrefix("error") { otaProtocolError = plaintext }
        if plaintext.lowercased().hasPrefix("error") { lastProtocolError = plaintext }
    }
    private var lastProtocolError: String?
    private func startAuthTimeout(for conn: NWConnection) {
        authTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak conn] in guard let self, let conn, self.connection === conn, self.state == .authenticating else { return }; self.retryAfterAuthenticationTimeout(on: conn) }
        authTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + authTimeout, execute: work)
    }
    private func failAuthentication(on conn: NWConnection) { authTimeoutWork?.cancel(); authTimeoutWork = nil; isAvailable = false; state = .authenticationFailed; receiving = false; conn.cancel() }
    private func retryAfterAuthenticationTimeout(on conn: NWConnection) {
        authTimeoutWork?.cancel(); authTimeoutWork = nil
        lastProtocolError = "Secure Wi-Fi handshake timed out; reconnecting."
        isAvailable = false; secureChannel = nil; receiving = false
        state = shouldReconnect ? .reconnecting : .offline
        conn.cancel()
    }
    private func failConnection(_ message: String, on conn: NWConnection) { lastProtocolError = message; isAvailable = false; receiving = false; conn.cancel() }
    private func failPendingReplies(_ error: Error) {
        let pending = pendingReplies; pendingReplies.removeAll()
        pending.forEach { $0.timeout.cancel(); $0.continuation.resume(throwing: error) }
    }
    private func sendData(_ data: Data) async throws {
        guard let connection else { throw TransportError.unavailable }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    private func sendLine(_ line: String) async throws {
        try await sendData(Data((line + "\n").utf8))
    }
    func waitUntilReady(timeout: TimeInterval = 5) async throws {
        if state == .offline || state == .unavailable { await connect() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if state == .ready, isAvailable { return }
            if state == .authenticationFailed {
                throw TransportError.failed("Secure Wi-Fi authentication failed.")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw TransportError.failed("Encrypted Wi-Fi connection timed out.")
    }
    func sendCommands(_ commands: [String]) async throws {
        try await waitUntilReady()
        guard !otaTransferActive else {
            throw TransportError.failed("Secure Wi-Fi controls are unavailable during firmware transfer.")
        }
        guard !commands.contains(where: { $0.contains("\n") || $0.contains("\r") }) else {
            throw TransportError.encoding
        }
        for command in commands {
            guard let secureChannel else { throw TransportError.failed("Secure Wi-Fi session is unavailable.") }
            let line = try secureChannel.sealText(command)
            try await sendLine(line)
        }
    }
    func request(_ command: String, timeout: TimeInterval = 10,
                 allowDuringOTA: Bool = false) async throws -> String {
        try await waitUntilReady()
        guard allowDuringOTA || !otaTransferActive else {
            throw TransportError.failed("Secure Wi-Fi management is busy during firmware transfer.")
        }
        let slotDeadline = Date().addingTimeInterval(timeout)
        while !pendingReplies.isEmpty {
            guard state == .ready, Date() < slotDeadline else {
                throw TransportError.failed("Secure Wi-Fi request queue timed out.")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard !command.contains("\n"), !command.contains("\r"),
              let connection, let secureChannel else { throw TransportError.encoding }
        let sealed = try secureChannel.sealText(command)
        return try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let index = self.pendingReplies.firstIndex(where: { $0.id == id }) else { return }
                let pending = self.pendingReplies.remove(at: index)
                pending.continuation.resume(throwing: TransportError.failed("Secure Wi-Fi response timed out."))
            }
            pendingReplies.append(PendingReply(id: id, continuation: continuation, timeout: work))
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
            connection.send(content: Data((sealed + "\n").utf8), completion: .contentProcessed { [weak self] error in
                guard let error, let self,
                      let index = self.pendingReplies.firstIndex(where: { $0.id == id }) else { return }
                let pending = self.pendingReplies.remove(at: index); pending.timeout.cancel()
                pending.continuation.resume(throwing: error)
            })
        }
    }
    func installFirmware(_ firmware: Data, version: String, sha256: String,
                         progress: @escaping (Int) -> Void) async throws {
        var reply: String
        do {
            reply = try await request("START protocol=2 version=\(version) size=\(firmware.count) sha256=\(sha256) flow=windowed binary=1", allowDuringOTA: true)
        } catch {
            // START delivery is ambiguous when its reply is lost. A best-effort
            // abort releases a receiver that may already own the OTA engine.
            if state == .ready { _ = try? await request("ABORT", allowDuringOTA: true) }
            throw error
        }
        let windowed = Self.windowedParameters(from: reply)
        guard reply == "ota ready 0" || windowed != nil else {
            _ = try? await request("ABORT", allowDuringOTA: true)
            throw TransportError.failed(reply)
        }
        otaAcknowledged = 0
        otaProtocolError = nil
        otaCancelled = false
        otaUsesWindowedFlow = windowed != nil
        otaTransferActive = true
        do {
            if let windowed {
                appLog(.tcp, "OTA flow=\(windowed.binary ? "binary" : "windowed") window=\(windowed.window) chunk=\(windowed.chunk) bytes=\(firmware.count)")
                try await installFirmwareWindowed(
                    firmware, window: windowed.window, chunk: windowed.chunk,
                    binary: windowed.binary,
                    progress: progress
                )
            } else {
                appLog(.tcp, "OTA flow=legacy-stop-and-wait chunk=128 bytes=\(firmware.count)")
                try await installFirmwareLegacy(firmware, progress: progress)
            }
            reply = try await request("FINISH", timeout: 30, allowDuringOTA: true)
            guard reply == "ota success" else { throw TransportError.failed(reply) }
            otaTransferActive = false
            otaUsesWindowedFlow = false
        } catch {
            if !otaCancelled { _ = try? await request("ABORT", allowDuringOTA: true) }
            otaTransferActive = false
            otaUsesWindowedFlow = false
            throw error
        }
    }
    static func windowedParameters(from reply: String) -> (window: Int, chunk: Int, binary: Bool)? {
        var values: [String: Int] = [:]
        for field in reply.split(separator: " ") {
            let parts = field.split(separator: "=", maxSplits: 1)
            if parts.count == 2, let value = Int(parts[1]) {
                values[String(parts[0])] = value
            }
        }
        let binary = values["binary"] == 1
        let maximumChunk = binary ? 2_048 : 128
        guard reply.hasPrefix("ota ready 0 "),
              let window = values["window"], window > 0,
              let chunk = values["chunk"], (1 ... maximumChunk).contains(chunk) else { return nil }
        return (window, chunk, binary)
    }
    private func installFirmwareLegacy(_ firmware: Data,
                                       progress: @escaping (Int) -> Void) async throws {
        var offset = 0
        while offset < firmware.count {
            if otaCancelled { throw CancellationError() }
            try Task.checkCancellation()
            // Secure text records hex-encode ciphertext. Keep the resulting
            // line below the firmware's bounded TCP receive buffer.
            let count = min(128, firmware.count - offset)
            let reply = try await request(
                "DATA \(offset) \(Data(firmware[offset ..< offset + count]).hex)",
                timeout: 15,
                allowDuringOTA: true
            )
            offset += count
            guard reply == "ota ack \(offset)" else { throw TransportError.failed(reply) }
            progress(offset)
        }
    }
    private func installFirmwareWindowed(_ firmware: Data, window: Int, chunk: Int,
                                         binary: Bool,
                                         progress: @escaping (Int) -> Void) async throws {
        var offset = 0
        var lastAcknowledgement = Date()
        var lastAcknowledgedOffset = 0
        while offset < firmware.count {
            if otaCancelled { throw CancellationError() }
            try Task.checkCancellation()
            while offset - otaAcknowledged >= window {
                if let otaProtocolError { throw TransportError.failed(otaProtocolError) }
                if otaAcknowledged > lastAcknowledgedOffset {
                    lastAcknowledgedOffset = otaAcknowledged
                    lastAcknowledgement = Date()
                }
                guard Date().timeIntervalSince(lastAcknowledgement) < 15 else {
                    throw TransportError.failed("Windowed Wi-Fi firmware acknowledgement timed out.")
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            let count = min(chunk, firmware.count - offset)
            guard let secureChannel else { throw TransportError.unavailable }
            if binary {
                var plaintext = Data([0x01])
                var littleEndian = UInt32(offset).littleEndian
                withUnsafeBytes(of: &littleEndian) { plaintext.append(contentsOf: $0) }
                plaintext.append(firmware[offset ..< offset + count])
                let record = try secureChannel.sealBinary(plaintext)
                guard record.count <= Int(UInt16.max) else { throw TransportError.encoding }
                var envelope = Data([0xB2, UInt8((record.count >> 8) & 0xFF), UInt8(record.count & 0xFF)])
                envelope.append(record)
                try await sendData(envelope)
            } else {
                let command = "DATA \(offset) \(Data(firmware[offset ..< offset + count]).hex)"
                try await sendLine(try secureChannel.sealText(command))
            }
            offset += count
            progress(offset)
        }
        let deadline = Date().addingTimeInterval(15)
        while otaAcknowledged < firmware.count {
            if let otaProtocolError { throw TransportError.failed(otaProtocolError) }
            guard Date() < deadline else {
                throw TransportError.failed("Final windowed Wi-Fi firmware acknowledgement timed out.")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func abortFirmwareUpdate() async {
        otaCancelled = true
        _ = try? await request("ABORT", allowDuringOTA: true)
        otaTransferActive = false
        otaUsesWindowedFlow = false
    }
    func diagnosticsInfo() async throws -> Data {
        Data(try await request("DIAGNOSTICS INFO").utf8)
    }
    func nextDiagnostic(after cursor: UInt32) async throws -> FirmwareLogRecord? {
        let data = Data(try await request("DIAGNOSTICS NEXT \(cursor)").utf8)
        if String(data: data, encoding: .utf8) == "{}" { return nil }
        return try JSONDecoder().decode(FirmwareLogRecord.self, from: data)
    }
    func usbIdentity(includeManufacturer: Bool = false) async throws -> USBIdentity {
        let reply = try await request(includeManufacturer ? "USB GET2" : "USB GET")
        return try JSONDecoder().decode(USBIdentity.self, from: Data(reply.utf8))
    }
    func configuredWiFiNetworks() async throws -> [String] {
        struct CountResponse: Decodable { let count: Int }
        struct NetworkResponse: Decodable { let ssid: String }
        let countReply = try await request("WIFI LIST")
        let count = try JSONDecoder().decode(CountResponse.self, from: Data(countReply.utf8)).count
        guard (0 ... 5).contains(count) else {
            throw TransportError.failed("InputPilot returned an invalid Wi-Fi network count.")
        }
        var networks: [String] = []
        for index in 0 ..< count {
            let reply = try await request("WIFI GET \(index)")
            networks.append(try JSONDecoder().decode(NetworkResponse.self, from: Data(reply.utf8)).ssid)
        }
        return networks
    }
    func setWiFi(ssid: String, password: String) async throws {
        let ssidData = Data(ssid.utf8)
        let passwordData = Data(password.utf8)
        guard (1 ... 32).contains(ssidData.count), passwordData.count <= 63 else {
            throw TransportError.failed("Wi-Fi names are limited to 32 bytes and passwords to 63 bytes.")
        }
        let encodedPassword = passwordData.isEmpty ? "-" : passwordData.hex
        try validateWiFiManagementReply(
            try await request("WIFI SETHEX \(ssidData.hex) \(encodedPassword)"),
            operation: "wifi_set"
        )
    }
    func removeWiFi(ssid: String) async throws {
        let ssidData = Data(ssid.utf8)
        guard (1 ... 32).contains(ssidData.count) else {
            throw TransportError.failed("The Wi-Fi network name is invalid.")
        }
        try validateWiFiManagementReply(
            try await request("WIFI REMOVEHEX \(ssidData.hex)"),
            operation: "wifi_remove"
        )
    }
    func clearWiFiNetworks() async throws {
        try validateWiFiManagementReply(try await request("WIFI CLEAR"), operation: "wifi_clear")
    }
    private func validateWiFiManagementReply(_ reply: String, operation: String) throws {
        if reply.hasPrefix("error ") { throw TransportError.failed(reply) }
        struct Reply: Decodable { let operation: String; let status: String }
        guard let decoded = try? JSONDecoder().decode(Reply.self, from: Data(reply.utf8)),
              decoded.operation == operation, decoded.status == "accepted" else {
            throw TransportError.failed("InputPilot returned an invalid Wi-Fi management response.")
        }
    }
    func setUSBIdentity(productName: String, vid: Int, pid: Int, serialNumber: String) async throws {
        let product = Data(productName.utf8).hex
        let serial = Data(serialNumber.utf8).hex
        let reply = try await request("USB SET \(String(vid, radix: 16)) \(String(pid, radix: 16)) \(product) \(serial)")
        guard reply == "management restarting" else { throw TransportError.failed(reply) }
    }
    func setUSBIdentity(manufacturerName: String, productName: String, vid: Int, pid: Int, serialNumber: String) async throws {
        let manufacturer = Data(manufacturerName.utf8).hex
        let product = Data(productName.utf8).hex
        let serial = Data(serialNumber.utf8).hex
        let reply = try await request("USB SET2 \(String(vid, radix: 16)) \(String(pid, radix: 16)) \(manufacturer) \(product) \(serial)")
        guard reply == "management restarting" else { throw TransportError.failed(reply) }
    }
    func resetUSBIdentity() async throws {
        let reply = try await request("USB RESET")
        guard reply == "management restarting" else { throw TransportError.failed(reply) }
    }
    func reboot() async throws {
        let reply = try await request("REBOOT")
        guard reply == "management restarting" else { throw TransportError.failed(reply) }
    }
    func setKeepAwake(_ settings: KeepAwakeSettings) async throws {
        try await sendCommands([
            "jiggle interval \(settings.moveIntervalMs)",
            settings.moveEnabled ? "jiggle on" : "jiggle off",
            "autoclick interval \(settings.clickIntervalMs)",
            settings.clickEnabled ? "autoclick on" : "autoclick off",
        ])
    }
    func send(_ event: HIDEvent) async throws {
        try await waitUntilReady()
        guard !otaTransferActive else {
            throw TransportError.failed("Secure Wi-Fi controls are unavailable during firmware transfer.")
        }
        let eid = AppLogContext.eventID.map(String.init) ?? "-"; appLog(.tcp, "id=\(eid) send event=\(event.diagnosticName)")
        do {
            guard let secureChannel else { throw TransportError.failed("Secure Wi-Fi session is unavailable.") }
            let line = try secureChannel.sealText(event.line)
            try await sendLine(line)
            appLog(.tcp, "id=\(eid) delivered")
        } catch { appLog(.errors, "TCP id=\(eid) error=\(error.localizedDescription)"); isAvailable = false; state = .reconnecting; connection?.cancel(); throw error }
    }
    func disconnect() async { shouldReconnect = false; reconnectWork?.cancel(); reconnectWork = nil; authTimeoutWork?.cancel(); authTimeoutWork = nil; receiving = false; connection?.cancel(); connection = nil; secureChannel = nil; receiveBuffer.removeAll(); failPendingReplies(TransportError.unavailable); isAvailable = false; state = .offline }
}

enum FirmwareUpdateState: Equatable {
    case idle, checking, connecting, authenticating, preparing, transferring, waitingForFinalAck
    case verifying, installing, rebooting, reconnecting, verifyingInstalledVersion, completed, cancelled
    case failed(String)
}

struct FirmwareManifest: Codable, Equatable {
    let product: String
    let version: String
    let board: String
    let protocolVersion: Int
    let otaSchema: Int
    let size: Int
    let sha256: String
    let minimumAppVersion: String?

    enum CodingKeys: String, CodingKey { case product, version, board, otaSchema, size, sha256; case protocolVersion = "protocol"; case minimumAppVersion = "minimum_app_version" }

    init(product: String, version: String, board: String, protocolVersion: Int, otaSchema: Int, size: Int, sha256: String, minimumAppVersion: String? = nil) {
        self.product = product; self.version = version; self.board = board; self.protocolVersion = protocolVersion
        self.otaSchema = otaSchema; self.size = size; self.sha256 = sha256; self.minimumAppVersion = minimumAppVersion
    }
}

enum FirmwareReleaseStatus: Equatable {
    case notChecked
    case checking
    case updateAvailable(String)
    case upToDate(String)
    case installedNewer(latest: String)
    case firmwareIncompatible(String)
    case appUpdateRequired(String)
    case unavailable(String)

    var title: String {
        switch self {
        case .notChecked: "Not checked"
        case .checking: "Checking for updates…"
        case .updateAvailable: "Update available"
        case .upToDate: "Device is up to date"
        case .installedNewer: "Installed firmware is newer"
        case .firmwareIncompatible: "Firmware not compatible"
        case .appUpdateRequired: "App update required"
        case .unavailable: "Update information unavailable"
        }
    }
    var detail: String? {
        switch self {
        case let .updateAvailable(version): "Firmware \(version) can be installed."
        case let .upToDate(version): "Firmware \(version) is installed."
        case let .installedNewer(latest): "The latest published firmware is \(latest). No downgrade is needed."
        case let .firmwareIncompatible(message), let .appUpdateRequired(message), let .unavailable(message): message
        case .notChecked, .checking: nil
        }
    }

    var canDownload: Bool {
        if case .updateAvailable = self { return true }
        return false
    }
}

enum FirmwareReleaseEvaluator {
    static let supportedProtocol = 2
    static let supportedOTASchema = 1

    static func evaluate(installed: String?, manifest: FirmwareManifest, deviceOTASchema: Int, appVersion: String) -> FirmwareReleaseStatus {
        guard manifest.product == "InputPilot", manifest.board == "esp32-s3-zero-4mb" else {
            return .firmwareIncompatible("The published firmware targets different hardware.")
        }
        guard manifest.protocolVersion <= supportedProtocol, manifest.otaSchema <= supportedOTASchema else {
            return .appUpdateRequired("This firmware requires a newer version of InputPilot.")
        }
        guard manifest.protocolVersion == supportedProtocol, manifest.otaSchema == supportedOTASchema else {
            return .firmwareIncompatible("The published firmware uses unsupported update metadata.")
        }
        if let minimum = manifest.minimumAppVersion {
            guard let required = SemanticVersion(minimum) else {
                return .firmwareIncompatible("The published app compatibility metadata is invalid.")
            }
            guard let current = SemanticVersion(appVersion), current >= required else {
                return .appUpdateRequired("InputPilot \(minimum) or newer is required for this firmware.")
            }
        }
        guard deviceOTASchema >= manifest.otaSchema else {
            return .firmwareIncompatible("This device must be reflashed over USB before this firmware can be installed.")
        }
        guard let latest = SemanticVersion(manifest.version) else {
            return .firmwareIncompatible("The published firmware version is invalid.")
        }
        guard let installed, let current = SemanticVersion(installed) else {
            return .updateAvailable(manifest.version)
        }
        if current < latest { return .updateAvailable(manifest.version) }
        if current == latest { return .upToDate(manifest.version) }
        return .installedNewer(latest: manifest.version)
    }
}

enum FirmwareValidationError: LocalizedError, Equatable {
    case notESP32Image, notApplicationImage, tooSmall, tooLarge, missingMetadata, wrongProduct, wrongBoard, unsupportedProtocol, unsupportedSchema
    var errorDescription: String? {
        switch self {
        case .notESP32Image: "The selected file is not an ESP32 application image."
        case .notApplicationImage: "Select firmware.bin only. Full-flash, bootloader, and partition images cannot be installed through OTA."
        case .tooSmall: "The selected firmware file is too small."
        case .tooLarge: "This firmware file is too large for the InputPilot OTA slot."
        case .missingMetadata, .wrongProduct, .wrongBoard: "This firmware is not compatible with InputPilot."
        case .unsupportedProtocol: "This firmware uses an unsupported OTA protocol."
        case .unsupportedSchema: "This firmware requires a newer OTA schema."
        }
    }
}

struct FirmwareImageMetadata: Equatable {
    static let prefix = Data("INPUTPILOT-META:".utf8)
    static let minimumSize = 64 * 1024
    static let otaSlotSize = 0x1e0000
    static let appDescriptorMagic = Data([0x32, 0x54, 0xcd, 0xab])
    let product: String; let board: String; let version: String; let protocolVersion: Int; let otaSchema: Int

    static func parseAndValidate(_ image: Data) throws -> Self {
        guard image.count >= minimumSize else { throw FirmwareValidationError.tooSmall }
        guard image.count <= otaSlotSize else { throw FirmwareValidationError.tooLarge }
        guard image.first == 0xe9 else { throw FirmwareValidationError.notESP32Image }
        guard image.count >= 36, image.subdata(in: 32..<36) == appDescriptorMagic else {
            throw FirmwareValidationError.notApplicationImage
        }
        var searchStart = image.startIndex
        while searchStart < image.endIndex,
              let prefixRange = image.range(of: prefix, in: searchStart..<image.endIndex) {
            searchStart = prefixRange.upperBound
            let tail = image[prefixRange.upperBound...]
            guard let end = tail.firstIndex(of: 0), let text = String(data: tail[..<end], encoding: .utf8) else { continue }
            var fields: [String: String] = [:]
            var valid = true
            for item in text.split(separator: ";") {
                let pair = item.split(separator: "=", maxSplits: 1)
                if pair.count != 2 || fields[String(pair[0])] != nil { valid = false; break }
                fields[String(pair[0])] = String(pair[1])
            }
            guard valid, let product = fields["product"], let board = fields["board"], let version = fields["version"],
                  let protocolVersion = fields["protocol"].flatMap(Int.init), let otaSchema = fields["otaSchema"].flatMap(Int.init),
                  !version.isEmpty else { continue }
            guard product == "InputPilot" else { throw FirmwareValidationError.wrongProduct }
            guard board == "esp32-s3-zero-4mb" else { throw FirmwareValidationError.wrongBoard }
            guard protocolVersion == 2 else { throw FirmwareValidationError.unsupportedProtocol }
            guard otaSchema <= 1 else { throw FirmwareValidationError.unsupportedSchema }
            return Self(product: product, board: board, version: version, protocolVersion: protocolVersion, otaSchema: otaSchema)
        }
        throw FirmwareValidationError.missingMetadata
    }
}

struct BLEDeviceMetadata: Codable, Equatable {
    let product: String; let board: String; let deviceId: String; let deviceName: String
    let firmware: String; let protocolVersion: Int; let otaSchema: Int; let capabilities: [String]; let trustRequired: Bool
    enum CodingKeys: String, CodingKey { case product, board, deviceId, deviceName, firmware, otaSchema, capabilities, trustRequired; case protocolVersion = "protocol" }
}

struct BLEDiscoveredDevice: Identifiable, Equatable {
    let id: UUID; let deviceId: String; let name: String; let rssi: Int
}

enum BLEMetadataRecovery {
    static let invalidHandleMessage = "Bluetooth had cached outdated InputPilot services. Toggle Bluetooth off and on once, then retry setup."

    static func isInvalidHandle(_ error: Error?) -> Bool {
        guard let error = error as NSError? else { return false }
        return (error.domain == CBATTErrorDomain &&
                error.code == CBATTError.Code.invalidHandle.rawValue) ||
            (error.domain == CBErrorDomain &&
             error.code == CBError.Code.invalidHandle.rawValue)
    }

    static func userFacingError(_ error: Error) -> Error {
        isInvalidHandle(error) ? TransportError.failed(invalidHandleMessage) : error
    }
}

final class BLEDeviceDiscoveryManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published private(set) var devices: [BLEDiscoveredDevice] = []
    @Published private(set) var isScanning = false
    @Published private(set) var errorMessage: String?
    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var selected: CBPeripheral?
    private var completion: ((Result<BLEDeviceMetadata, Error>) -> Void)?
    private var resultPendingDisconnect: Result<BLEDeviceMetadata, Error>?
    private var metadataTimeoutWork: DispatchWorkItem?
    private var invalidHandleRetriesRemaining = 0
    private var reconnectingAfterInvalidHandle = false
    private let otaService = CBUUID(string: "7D9F1001-4F4D-4F56-4552-484944000001")
    private let otaStatus = CBUUID(string: "7D9F1004-4F4D-4F56-4552-484944000001")

    override init() { super.init(); central = CBCentralManager(delegate: self, queue: .main) }
    static func deviceId(from manufacturerData: Data) -> String? {
        guard let value = String(data: manufacturerData, encoding: .utf8), value.count == 14,
              value.hasPrefix("IP"), value.dropFirst(2).allSatisfy({ $0.isHexDigit }) else { return nil }
        return String(value.dropFirst(2)).lowercased()
    }
    static func advertisementDeviceId(_ advertisementData: [String: Any]) -> String? {
        guard let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else { return nil }
        return deviceId(from: data)
    }
    static func advertisement(_ advertisementData: [String: Any], matches deviceId: String) -> Bool {
        advertisementDeviceId(advertisementData) == deviceId.lowercased()
    }
    func start() { devices = []; errorMessage = nil; isScanning = true; if central.state == .poweredOn { central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]) } }
    func stop() { central.stopScan(); isScanning = false }
    func metadata(for device: BLEDiscoveredDevice) async throws -> BLEDeviceMetadata {
        guard let peripheral = peripherals[device.id] else { throw TransportError.unavailable }
        stop(); selected = peripheral
        invalidHandleRetriesRemaining = 1
        reconnectingAfterInvalidHandle = false
        resultPendingDisconnect = nil
        return try await withCheckedThrowingContinuation { continuation in
            completion = { continuation.resume(with: $0) }
            central.connect(peripheral)
            startMetadataTimeout()
        }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn, isScanning { central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]) }
        else if central.state != .poweredOn { isScanning = false }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let deviceId = Self.advertisementDeviceId(advertisementData) else { return }
        peripherals[peripheral.identifier] = peripheral
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "InputPilot"
        let found = BLEDiscoveredDevice(id: peripheral.identifier, deviceId: deviceId, name: name, rssi: RSSI.intValue)
        if let index = devices.firstIndex(where: { $0.deviceId == deviceId }) { devices[index] = found }
        else { devices.append(found); devices.sort { $0.rssi > $1.rssi } }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) { peripheral.delegate = self; peripheral.discoverServices([otaService]) }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if let error, recoverInvalidHandle(error, peripheral: peripheral) { return }
        finish(.failure(error.map(BLEMetadataRecovery.userFacingError) ?? TransportError.unavailable))
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if let pending = resultPendingDisconnect {
            resultPendingDisconnect = nil
            complete(pending)
            return
        }
        if reconnectingAfterInvalidHandle, completion != nil {
            reconnectingAfterInvalidHandle = false
            reconnect(peripheral)
            return
        }
        guard completion != nil else { return }
        finish(.failure(error ?? TransportError.failed("Bluetooth disconnected during metadata setup.")))
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            if recoverInvalidHandle(error, peripheral: peripheral) { return }
            finish(.failure(BLEMetadataRecovery.userFacingError(error))); return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == otaService }) else { finish(.failure(TransportError.failed("InputPilot metadata service not found."))); return }
        peripheral.discoverCharacteristics([otaStatus], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            if recoverInvalidHandle(error, peripheral: peripheral) { return }
            finish(.failure(BLEMetadataRecovery.userFacingError(error))); return
        }
        guard let status = service.characteristics?.first(where: { $0.uuid == otaStatus }) else { finish(.failure(TransportError.failed("InputPilot metadata not available."))); return }
        peripheral.readValue(for: status)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == otaStatus else { return }
        if let error {
            if recoverInvalidHandle(error, peripheral: peripheral) { return }
            finish(.failure(BLEMetadataRecovery.userFacingError(error))); return
        }
        guard let value = characteristic.value, let metadata = try? JSONDecoder().decode(BLEDeviceMetadata.self, from: value), metadata.product == "InputPilot", metadata.board == "esp32-s3-zero-4mb" else {
            finish(.failure(TransportError.failed("Invalid InputPilot Bluetooth metadata."))); return
        }
        finish(.success(metadata))
    }
    private func startMetadataTimeout() {
        metadataTimeoutWork?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.completion != nil else { return }
            self.finish(.failure(TransportError.failed("Bluetooth pairing or metadata request timed out.")))
        }
        metadataTimeoutWork = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
    }
    private func recoverInvalidHandle(_ error: Error, peripheral: CBPeripheral) -> Bool {
        guard BLEMetadataRecovery.isInvalidHandle(error),
              invalidHandleRetriesRemaining > 0, completion != nil else { return false }
        invalidHandleRetriesRemaining -= 1
        reconnectingAfterInvalidHandle = true
        appLog(.bluetooth, "stale BLE GATT handle detected during setup; reconnecting and rediscovering services once")
        startMetadataTimeout()
        if peripheral.state == .disconnected {
            reconnectingAfterInvalidHandle = false
            reconnect(peripheral)
        } else {
            central.cancelPeripheralConnection(peripheral)
        }
        return true
    }
    private func reconnect(_ peripheral: CBPeripheral) {
        let retry = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self, let peripheral, self.completion != nil else { return }
            peripheral.delegate = self
            self.central.connect(peripheral)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: retry)
    }
    private func finish(_ result: Result<BLEDeviceMetadata, Error>) {
        metadataTimeoutWork?.cancel(); metadataTimeoutWork = nil
        if let selected, selected.state != .disconnected {
            resultPendingDisconnect = result
            central.cancelPeripheralConnection(selected)
            return
        }
        complete(result)
    }
    private func complete(_ result: Result<BLEDeviceMetadata, Error>) {
        let callback = completion; completion = nil
        reconnectingAfterInvalidHandle = false
        invalidHandleRetriesRemaining = 0
        selected = nil
        callback?(result)
    }
}

struct AppVersionInfo: Equatable {
    let version: String
    let build: String
    let commit: String
    init(version: String, build: String, commit: String = "Unknown") { self.version = version; self.build = build; self.commit = commit }
    static func read(from info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> Self {
        Self(version: info["CFBundleShortVersionString"] as? String ?? "Unknown",
             build: info["CFBundleVersion"] as? String ?? "Unknown",
             commit: info["InputPilotGitCommit"] as? String ?? "Unknown")
    }
    var display: String { build == "Unknown" ? version : "\(version) (\(build))" }
}

struct DiagnosticsMetadata: Codable, Equatable {
    struct HIDCounters: Codable, Equatable { let rxBle: UInt64?; let rxTcp: UInt64?; let rxSerial: UInt64?; let decoded: UInt64?; let decodeErrors: UInt64?; let queued: UInt64?; let queueRejected: UInt64?; let executed: UInt64?; let failed: UInt64?; let mouseExecuted: UInt64?; let keyboardExecuted: UInt64?; let usbReportsAttempted: UInt64?; let usbReportsSucceeded: UInt64?; let usbReportsFailed: UInt64?; let lastSource: String?; let lastType: String?; let lastSequence: UInt64?; let lastPhase: String?; let previousBreadcrumbValid: Bool?; let previousSequence: UInt64?; let previousSource: String?; let previousEventType: UInt8?; let previousPhase: UInt8?; let previousBleRxType: UInt8?; let previousBleRxLength: UInt64?; let previousQueueDepth: UInt64? }
    struct BLEState: Codable, Equatable { let connected: Bool?; let advertising: Bool?; let advertisingRecoveries: UInt64?; let advertisingRecoveryFailures: UInt64? }
    let product: String
    let firmware: String
    let board: String
    let protocolVersion: Int
    let otaSchema: Int
    let deviceId: String
    let runningPartition: String?
    let bootPartition: String?
    let uptime: UInt64?
    let heap: UInt64?
    let firmwareCommit: String?
    let resetReason: String?
    let ble: BLEState?
    let hid: HIDCounters?
    enum CodingKeys: String, CodingKey {
        case product, firmware, board, protocolVersion = "protocol", otaSchema, deviceId
        case runningPartition, bootPartition, uptime, heap, firmwareCommit, resetReason, ble, hid
    }
}

struct FirmwareLogLine: Identifiable, Equatable {
    let id = UUID()
    let raw: String
    let milliseconds: UInt64?
    let level: String
    let tag: String
    init(_ raw: String) {
        self.raw = raw
        let parts = raw.split(separator: "]", maxSplits: 3, omittingEmptySubsequences: false)
        milliseconds = parts.count >= 3 ? UInt64(parts[0].dropFirst()) : nil
        level = parts.count >= 3 ? String(parts[1].dropFirst()).uppercased() : "UNKNOWN"
        tag = parts.count >= 3 ? String(parts[2].dropFirst()).uppercased() : "UNKNOWN"
    }
    func matches(_ filter: FirmwareLogFilter) -> Bool {
        switch filter {
        case .all: true
        case .warnings: level == "WARN" || level == "ERROR"
        case .wifi: tag == "WIFI"
        default: tag == filter.rawValue.uppercased()
        }
    }
}

enum FirmwareLogFilter: String, CaseIterable, Identifiable {
    case all = "All", ble = "BLE", wifi = "Wi-Fi", ota = "OTA", hid = "HID", usb = "USB", warnings = "Warnings / Errors"
    var id: String { rawValue }
}

struct FirmwareLogHistory {
    static let capacity = 500
    private(set) var lines: [FirmwareLogLine] = []
    mutating func append(_ rawLines: [String]) {
        lines.append(contentsOf: rawLines.filter { !$0.isEmpty }.map(FirmwareLogLine.init))
        if lines.count > Self.capacity { lines.removeFirst(lines.count - Self.capacity) }
    }
    mutating func clear() { lines.removeAll(keepingCapacity: true) }
}

struct FirmwareLogRecord: Codable, Equatable {
    let sequence: UInt32
    let line: String
}

struct FirmwareLogSequenceHistory {
    static let capacity = 500
    private(set) var records: [FirmwareLogRecord] = []
    private var identities = Set<String>()
    mutating func append(_ incoming: [FirmwareLogRecord]) -> [String] {
        var added: [String] = []
        for record in incoming {
            let identity = "\(record.sequence):\(record.line)"
            guard identities.insert(identity).inserted else { continue }
            records.append(record); added.append(record.line)
        }
        if records.count > Self.capacity {
            let removed = records.prefix(records.count - Self.capacity)
            for record in removed { identities.remove("\(record.sequence):\(record.line)") }
            records.removeFirst(records.count - Self.capacity)
        }
        return added
    }
    mutating func clear() { records.removeAll(keepingCapacity: true); identities.removeAll(keepingCapacity: true) }
}

private struct FirmwareLogsResponse: Decodable {
    let entries: [FirmwareLogRecord]
    enum CodingKeys: String, CodingKey { case entries, lines }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let records = try container.decodeIfPresent([FirmwareLogRecord].self, forKey: .entries) { entries = records; return }
        let lines = try container.decodeIfPresent([String].self, forKey: .lines) ?? []
        entries = lines.enumerated().map { FirmwareLogRecord(sequence: UInt32($0.offset + 1), line: $0.element) }
    }
}

@MainActor final class FirmwareDiagnosticsManager: ObservableObject {
    @Published private(set) var lines: [FirmwareLogLine] = []
    @Published private(set) var status = "Connecting…"
    @Published private(set) var metadata: DiagnosticsMetadata?
    @Published var paused = false
    private let mode: ConnectionMode
    private var history = FirmwareLogHistory(); private var sequenceHistory = FirmwareLogSequenceHistory(); private var pending: [FirmwareLogRecord] = []
    private let sharedBLE: BLEHIDControlTransport
    private let wifi: TCPHIDControlTransport?
    private var wifiTask: Task<Void, Never>?
    private var bleTask: Task<Void, Never>?
    init(device: StoredDevice, mode: ConnectionMode = .automatic) {
        self.mode = mode
        sharedBLE = InputPilotBluetoothManager.session(deviceId: device.deviceId)
        let host = device.staIP ?? device.mdnsHost
        wifi = host.isEmpty ? nil : InputPilotWiFiManager.session(host: host, deviceId: device.deviceId)
    }
    func start() {
        if mode == .wifiOnly {
            guard wifi != nil else { status = "No Wi-Fi endpoint is available."; return }
            status = "Authenticating Wi-Fi session…"
            wifiTask = Task { [weak self] in await self?.pollWiFi() }
            return
        }
        status = "Authenticating shared Bluetooth session…"
        bleTask = Task { [weak self] in await self?.pollBluetooth() }
    }
    func stop() {
        bleTask?.cancel(); bleTask = nil
        wifiTask?.cancel(); wifiTask = nil
    }
    func clear() { history.clear(); sequenceHistory.clear(); pending.removeAll(); lines = [] }
    func setPaused(_ value: Bool) { paused = value; if !value, !pending.isEmpty { history.append(sequenceHistory.append(pending)); pending.removeAll(); lines = history.lines } }
    private func receive(_ incoming: [FirmwareLogRecord]) { if paused { pending.append(contentsOf: incoming); if pending.count > FirmwareLogSequenceHistory.capacity { pending.removeFirst(pending.count - FirmwareLogSequenceHistory.capacity) } } else { history.append(sequenceHistory.append(incoming)); lines = history.lines } }
    private func pollBluetooth() async {
        do {
            try await sharedBLE.waitUntilReady()
            metadata = try JSONDecoder().decode(DiagnosticsMetadata.self,
                                                from: try await sharedBLE.diagnosticsInfo())
            status = "Live via secure Bluetooth session"
            var cursor: UInt32 = 0
            while !Task.isCancelled {
                if let record = try await sharedBLE.nextDiagnostic(after: cursor) {
                    cursor = record.sequence
                    receive([record])
                } else { try await Task.sleep(for: .milliseconds(250)) }
            }
        } catch {
            if !Task.isCancelled { status = "Secure Bluetooth diagnostics failed: \(error.localizedDescription)" }
        }
    }
    private func pollWiFi() async {
        guard let wifi else { return }
        do {
            try await wifi.waitUntilReady()
            metadata = try JSONDecoder().decode(DiagnosticsMetadata.self, from: try await wifi.diagnosticsInfo())
            status = "Live via secure Wi-Fi session"
            var cursor: UInt32 = 0
            while !Task.isCancelled {
                if let record = try await wifi.nextDiagnostic(after: cursor) {
                    cursor = record.sequence
                    receive([record])
                } else { try await Task.sleep(for: .milliseconds(250)) }
            }
        } catch {
            if !Task.isCancelled { status = "Secure Wi-Fi diagnostics failed: \(error.localizedDescription)" }
        }
    }
}

enum FirmwareManifestValidator {
    static func validate(_ manifest: FirmwareManifest, firmware: Data? = nil) throws {
        guard manifest.product == "InputPilot" else { throw FirmwareValidationError.wrongProduct }
        guard manifest.board == "esp32-s3-zero-4mb" else { throw FirmwareValidationError.wrongBoard }
        guard manifest.protocolVersion == 2 else { throw FirmwareValidationError.unsupportedProtocol }
        guard manifest.otaSchema == 1 else { throw FirmwareValidationError.unsupportedSchema }
        guard manifest.sha256.count == 64, manifest.sha256.allSatisfy({ $0.isHexDigit }) else { throw FirmwareValidationError.missingMetadata }
        if let firmware {
            guard firmware.count == manifest.size else { throw FirmwareValidationError.tooLarge }
            let digest = SHA256.hash(data: firmware).map { String(format: "%02x", $0) }.joined()
            guard digest == manifest.sha256.lowercased() else { throw FirmwareValidationError.missingMetadata }
            let metadata = try FirmwareImageMetadata.parseAndValidate(firmware)
            guard metadata.version == manifest.version else { throw FirmwareValidationError.missingMetadata }
        }
    }
}

struct SemanticVersion: Comparable, Equatable {
    let components: [Int]
    let prerelease: [String]
    init?(_ value: String) {
        let withoutBuild = value.split(separator: "+", maxSplits: 1)[0]
        let releaseParts = withoutBuild.split(separator: "-", maxSplits: 1)
        let parts = releaseParts[0].split(separator: ".")
        guard !parts.isEmpty, parts.allSatisfy({ Int($0) != nil }) else { return nil }
        components = parts.map { Int($0)! }
        if releaseParts.count == 2 {
            let identifiers = releaseParts[1].split(separator: ".").map(String.init)
            guard !identifiers.isEmpty,
                  identifiers.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }) else { return nil }
            prerelease = identifiers
        } else {
            prerelease = []
        }
    }
    static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let l = index < lhs.components.count ? lhs.components[index] : 0
            let r = index < rhs.components.count ? rhs.components[index] : 0
            if l != r { return l < r }
        }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
        }
        for index in 0..<max(lhs.prerelease.count, rhs.prerelease.count) {
            guard index < lhs.prerelease.count else { return true }
            guard index < rhs.prerelease.count else { return false }
            let left = lhs.prerelease[index], right = rhs.prerelease[index]
            if left == right { continue }
            switch (Int(left), Int(right)) {
            case let (.some(l), .some(r)): return l < r
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return left < right
            }
        }
        return false
    }
    static func == (lhs: Self, rhs: Self) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

enum FirmwareUpdateTransportKind: String, Equatable { case wifi = "Wi-Fi", bluetooth = "Bluetooth" }

final class FirmwareUpdateManager: NSObject, ObservableObject {
    @Published private(set) var state: FirmwareUpdateState = .idle
    @Published private(set) var bytesSent = 0
    @Published private(set) var totalBytes = 0
    @Published private(set) var bytesPerSecond = 0.0
    @Published private(set) var installedVersion: String?
    @Published private(set) var activeTransport: FirmwareUpdateTransportKind?
    var progress: Double { totalBytes == 0 ? 0 : Double(bytesSent) / Double(totalBytes) }
    var expectsReboot: Bool { Self.disconnectIsExpected(during: state) }
    static func disconnectIsExpected(during state: FirmwareUpdateState) -> Bool {
        switch state { case .verifying, .installing, .rebooting, .reconnecting, .verifyingInstalledVersion: true; default: false }
    }
    static func verifies(metadata: BLEDeviceMetadata, deviceId: String, version: String, requiredSchema: Int) -> Bool {
        metadata.deviceId.lowercased() == deviceId.lowercased() && metadata.firmware == version && metadata.otaSchema >= requiredSchema
    }
    var blocksControl: Bool {
        switch state { case .preparing, .transferring, .waitingForFinalAck, .verifying, .installing, .rebooting, .reconnecting, .verifyingInstalledVersion: true; default: false }
    }

    private weak var peripheral: CBPeripheral?
    private var control: CBCharacteristic?
    private var data: CBCharacteristic?
    private var status: CBCharacteristic?
    private var seal: ((Data) throws -> Data)?
    private var acknowledged = 0
    private var windowSize = 32 * 1024
    private var maximumChunkSize = 500
    private var statusEvent = ""
    private var targetVersion: String?
    private var cancelled = false
    private var lastProgress = Date()
    private var preUpdateDeviceId: String?
    private var requiredSchema = 1
    private var rebootTimeoutWork: DispatchWorkItem?
    private var wifiEndpoints: [URL] = []
    private var activeWiFiEndpoint: URL?
    private var wifiTransport: TCPHIDControlTransport?
    private var connectionMode: ConnectionMode = .automatic
    private var capabilities: Set<String> = []
    private var hasSecurePairing = false
    var metadataHandler: ((BLEDeviceMetadata) -> Void)?

    static func transportOrder(mode: ConnectionMode, wifiAvailable: Bool, bluetoothAvailable: Bool) -> [FirmwareUpdateTransportKind] {
        let wifi = wifiAvailable ? [FirmwareUpdateTransportKind.wifi] : []
        let ble = bluetoothAvailable ? [FirmwareUpdateTransportKind.bluetooth] : []
        switch mode {
        case .automatic, .preferWiFi: return wifi + ble
        case .preferBluetooth: return ble + wifi
        case .bluetoothOnly: return ble
        case .wifiOnly: return wifi
        }
    }

    static func wifiOTAAvailable(hasSecurePairing: Bool, capabilities: Set<String>, hasEndpoints: Bool) -> Bool {
        hasSecurePairing && capabilities.contains("secure_ota") &&
            capabilities.contains("wifi_transport") && hasEndpoints
    }

    static func bleFirmwarePayloadSize(advertised: Int, maximumWriteLength: Int) -> Int? {
        // Secure binary record: version (1), counter (8), GCM tag (16), plus
        // the four-byte OTA offset that precedes each firmware payload.
        let available = maximumWriteLength - 29
        guard advertised > 0, available >= 128 else { return nil }
        return min(advertised, available)
    }

    func configure(device: StoredDevice, mode: ConnectionMode) {
        wifiEndpoints = DeviceEndpointResolver.endpointURLs(mdnsHost: device.mdnsHost, staIP: device.staIP)
        activeWiFiEndpoint = nil
        connectionMode = mode; capabilities = Set(device.capabilities)
        hasSecurePairing = PairingKeyStore.load(deviceId: device.deviceId) != nil
        preUpdateDeviceId = device.deviceId
        let host = device.staIP ?? device.mdnsHost
        wifiTransport = host.isEmpty ? nil : InputPilotWiFiManager.session(host: host, deviceId: device.deviceId)
    }

    func attach(peripheral: CBPeripheral, control: CBCharacteristic, data: CBCharacteristic,
                status: CBCharacteristic, seal: @escaping (Data) throws -> Data) {
        self.peripheral = peripheral; self.control = control; self.data = data
        self.status = status; self.seal = seal
        peripheral.readValue(for: status)
    }

    func receive(_ value: Data?, error: Error?) {
        guard error == nil, let value,
              let object = try? JSONSerialization.jsonObject(with: value) as? [String: Any] else { return }
        statusEvent = object["event"] as? String ?? ""
        acknowledged = object["offset"] as? Int ?? acknowledged
        windowSize = object["windowSize"] as? Int ?? windowSize
        maximumChunkSize = object["maxChunk"] as? Int ?? maximumChunkSize
        installedVersion = object["firmware"] as? String ?? installedVersion
        if let metadata = try? JSONDecoder().decode(BLEDeviceMetadata.self, from: value) {
            metadataHandler?(metadata)
            if preUpdateDeviceId == nil { preUpdateDeviceId = metadata.deviceId }
            if case .verifyingInstalledVersion = state {
                guard let preUpdateDeviceId, let targetVersion, Self.verifies(metadata: metadata, deviceId: preUpdateDeviceId, version: targetVersion, requiredSchema: requiredSchema) else {
                    state = .failed("Update could not be verified after restart."); return
                }
                state = .completed
            }
        }
        lastProgress = Date()
        if let code = object["error"] as? String { state = .failed(Self.message(for: code)); return }
        switch statusEvent {
        case "READY": state = .transferring
        case "VERIFYING": state = .verifying
        case "INSTALLING": state = .installing
        case "SUCCESS", "REBOOTING": state = .rebooting
        case "CANCELLED": state = .cancelled
        case "IDLE" where expectsReboot:
            state = .verifyingInstalledVersion
            if let metadata = try? JSONDecoder().decode(BLEDeviceMetadata.self, from: value),
               let preUpdateDeviceId, let targetVersion {
                state = Self.verifies(metadata: metadata, deviceId: preUpdateDeviceId, version: targetVersion, requiredSchema: requiredSchema)
                    ? .completed : .failed("Update could not be verified after restart.")
            }
        default: break
        }
        if case .completed = state { rebootTimeoutWork?.cancel(); rebootTimeoutWork = nil }
    }

    func install(_ firmware: Data, version: String, expectedSHA256: String? = nil) async {
        let wifiCapable = Self.wifiOTAAvailable(
            hasSecurePairing: hasSecurePairing,
            capabilities: capabilities,
            hasEndpoints: !wifiEndpoints.isEmpty
        )
        let bleCapable = capabilities.contains("secure_ota") &&
                         peripheral != nil && control != nil && data != nil
        let order = Self.transportOrder(mode: connectionMode, wifiAvailable: wifiCapable, bluetoothAvailable: bleCapable)
        guard let selected = order.first else { state = .failed("No permitted firmware update transport is available."); return }
        if selected == .wifi {
            do { try await installWiFi(firmware, version: version, expectedSHA256: expectedSHA256); return }
            catch where order.contains(.bluetooth) && state == .preparing && !cancelled { await installBLE(firmware, version: version, expectedSHA256: expectedSHA256); return }
            catch is CancellationError { if cancelled { state = .cancelled }; return }
            catch { state = .failed(error.localizedDescription); return }
        }
        await installBLE(firmware, version: version, expectedSHA256: expectedSHA256)
    }

    private func installBLE(_ firmware: Data, version: String, expectedSHA256: String? = nil) async {
        activeTransport = .bluetooth
        guard let peripheral, let control, let data else { state = .failed("Connect to this InputPilot over Bluetooth first."); return }
        let metadata: FirmwareImageMetadata
        do { metadata = try FirmwareImageMetadata.parseAndValidate(firmware) }
        catch { state = .failed(error.localizedDescription); return }
        guard version == metadata.version else { state = .failed("The target version does not match the firmware image metadata."); return }
        let digest = SHA256.hash(data: firmware).map { String(format: "%02x", $0) }.joined()
        if let expectedSHA256, expectedSHA256.lowercased() != digest { state = .failed("Firmware verification failed. The selected file was not transferred."); return }
        cancelled = false; targetVersion = version; requiredSchema = metadata.otaSchema; totalBytes = firmware.count; bytesSent = 0; acknowledged = 0; state = .preparing; lastProgress = Date()
        statusEvent = ""
        if let status, !status.isNotifying {
            peripheral.setNotifyValue(true, for: status)
            let notificationDeadline = Date().addingTimeInterval(5)
            while !status.isNotifying && Date() < notificationDeadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard status.isNotifying else { state = .failed("InputPilot firmware update status is not ready."); return }
        }
        let command = "START protocol=2 version=\(version) size=\(firmware.count) sha256=\(digest)"
        guard let seal else { state = .failed("The authenticated session was lost."); return }
        do { peripheral.writeValue(try seal(Data(command.utf8)), for: control, type: .withResponse) }
        catch { state = .failed("Could not encrypt the firmware update command."); return }
        guard await wait(for: "READY", timeout: 10) else {
            if case .failed = state { return }
            abortBLETransfer("InputPilot did not become ready for the update.")
            return
        }
        let started = Date()
        guard let maximum = Self.bleFirmwarePayloadSize(
            advertised: maximumChunkSize,
            maximumWriteLength: peripheral.maximumWriteValueLength(for: .withoutResponse)
        ) else { abortBLETransfer("The negotiated Bluetooth packet size is too small for firmware updates."); return }
        appLog(.bluetooth, "OTA flow=windowed window=\(windowSize) chunk=\(maximum) bytes=\(firmware.count)")
        var offset = 0
        while offset < firmware.count && !cancelled {
            while (!peripheral.canSendWriteWithoutResponse || offset - acknowledged >= windowSize) && !cancelled {
                if Date().timeIntervalSince(lastProgress) > 15 { abortBLETransfer("Firmware transfer timed out."); return }
                try? await Task.sleep(for: .milliseconds(10))
            }
            let count = min(maximum, firmware.count - offset)
            var frame = Data()
            var littleEndian = UInt32(offset).littleEndian
            withUnsafeBytes(of: &littleEndian) { frame.append(contentsOf: $0) }
            frame.append(firmware[offset..<(offset + count)])
            do { peripheral.writeValue(try seal(frame), for: data, type: .withoutResponse) }
            catch { abortBLETransfer("Could not encrypt the firmware update data."); return }
            offset += count; bytesSent = offset; if peripheral.canSendWriteWithoutResponse { lastProgress = Date() }
            bytesPerSecond = Double(offset) / max(0.1, Date().timeIntervalSince(started))
        }
        guard !cancelled else { return }
        state = .waitingForFinalAck
        let ackDeadline = Date().addingTimeInterval(15)
        while acknowledged < firmware.count { if case .failed = state { return }; if Date() >= ackDeadline { abortBLETransfer("Final firmware acknowledgement timed out."); return }; try? await Task.sleep(for: .milliseconds(20)) }
        do { peripheral.writeValue(try seal(Data("FINISH".utf8)), for: control, type: .withResponse) }
        catch { abortBLETransfer("Could not encrypt the firmware finalization command."); return }
        state = .verifying
        guard await waitForFinalization(timeout: 30) else { if case .failed = state { return }; state = .failed("Firmware verification timed out."); return }
    }

    private func abortBLETransfer(_ message: String) {
        if let peripheral, let control, let seal,
           let payload = try? seal(Data("ABORT".utf8)) {
            peripheral.writeValue(payload, for: control, type: .withResponse)
        }
        state = .failed(message)
    }

    func cancel() {
        cancelled = true
        if activeTransport == .wifi {
            Task { [weak self] in await self?.wifiTransport?.abortFirmwareUpdate() }
        } else if let peripheral, let control, let seal,
                  let payload = try? seal(Data("ABORT".utf8)) {
            peripheral.writeValue(payload, for: control, type: .withResponse)
        }
        state = .cancelled
    }

    private func installWiFi(_ firmware: Data, version: String, expectedSHA256: String?) async throws {
        let metadata = try FirmwareImageMetadata.parseAndValidate(firmware)
        guard metadata.version == version else { throw TransportError.failed("The target version does not match the firmware image metadata.") }
        let digest = SHA256.hash(data: firmware).map { String(format: "%02x", $0) }.joined()
        if let expectedSHA256, expectedSHA256.lowercased() != digest { throw TransportError.failed("Firmware verification failed before transfer.") }
        activeTransport = .wifi; cancelled = false; targetVersion = version; requiredSchema = metadata.otaSchema
        totalBytes = firmware.count; bytesSent = 0; state = .preparing
        let base = try await reachableWiFiEndpoint(); activeWiFiEndpoint = base
        guard let wifiTransport else { throw TransportError.unavailable }
        state = .authenticating
        try await wifiTransport.waitUntilReady()
        state = .transferring
        let started = Date()
        try await wifiTransport.installFirmware(firmware, version: version, sha256: digest) { [weak self] sent in
            DispatchQueue.main.async {
                self?.bytesSent = sent
                self?.bytesPerSecond = Double(sent) / max(0.1, Date().timeIntervalSince(started))
            }
        }
        bytesSent = firmware.count; bytesPerSecond = Double(firmware.count) / max(0.1, Date().timeIntervalSince(started)); state = .rebooting
        try await verifyWiFiReboot(preferredBase: base, version: version)
    }
    private func reachableWiFiEndpoint() async throws -> URL {
        for base in wifiEndpoints {
            guard let status = try? await DeviceAPIClient().status(baseURL: base) else { continue }
            if let expected = preUpdateDeviceId {
                guard let actual = status.deviceId,
                      expected.caseInsensitiveCompare(actual) == .orderedSame else { continue }
            }
            return base
        }
        throw TransportError.failed("InputPilot is not reachable over Wi-Fi.")
    }
    private func verifyWiFiReboot(preferredBase: URL, version: String) async throws {
        state = .reconnecting; try? await Task.sleep(for: .seconds(2)); let deadline = Date().addingTimeInterval(60)
        let endpoints = [preferredBase] + wifiEndpoints.filter { $0 != preferredBase }
        while Date() < deadline && !cancelled {
            for base in endpoints {
                do { let status = try await DeviceAPIClient().status(baseURL: base); if status.deviceId?.lowercased() == preUpdateDeviceId?.lowercased(), status.version == version, status.otaSchema >= requiredSchema { installedVersion = status.version; if let id = status.deviceId { metadataHandler?(BLEDeviceMetadata(product: "InputPilot", board: "esp32-s3-zero-4mb", deviceId: id, deviceName: status.name, firmware: status.version, protocolVersion: status.protocolVersion, otaSchema: status.otaSchema, capabilities: status.capabilities, trustRequired: true)) }; state = .completed; return } } catch {}
            }
            try? await Task.sleep(for: .seconds(1))
        }
        throw TransportError.failed("Update could not be verified after Wi-Fi restart.")
    }

    func disconnected(expected: Bool) {
        switch state {
        case .idle, .checking, .completed, .cancelled, .failed: return
        default: break
        }
        guard expected else { state = .failed("Bluetooth connection lost. The existing firmware is still installed."); return }
        state = .reconnecting
        rebootTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            switch self.state {
            case .reconnecting, .verifyingInstalledVersion: self.state = .failed("Update could not be verified after restart.")
            default: break
            }
        }
        rebootTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }
    func writerReady() {}
    private func wait(for event: String, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if statusEvent == event { return true }; if case .failed = state { return false }; try? await Task.sleep(for: .milliseconds(20)) }
        return false
    }
    private func waitForFinalization(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch state { case .installing, .rebooting, .reconnecting, .verifyingInstalledVersion, .completed: return true; default: break }
            if case .failed = state { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
    private static func message(for code: String) -> String {
        switch code {
        case "checksum_mismatch", "image_invalid": "Firmware verification failed. The update was not installed."
        case "invalid_metadata", "incompatible_product", "incompatible_board": "This firmware is not compatible with InputPilot."
        case "version_mismatch": "The firmware version does not match the selected target version."
        case "firmware_too_large": "This firmware file is too large for this InputPilot device."
        case "reflash_required": "This device must be reflashed over USB before Bluetooth updates are available."
        case "unauthorized": "Authentication is required before updating firmware."
        case "connection_lost": "Bluetooth connection lost. The existing firmware is still installed."
        default: "The firmware update failed (\(code.replacingOccurrences(of: "_", with: " ")))."
        }
    }
}

final class UnavailableHIDControlTransport: HIDControlTransport {
    let kind: TransportKind
    let isAvailable = false
    let state = TransportConnectionState.offline
    init(kind: TransportKind) { self.kind = kind }
    func connect() async {}
    func send(_ event: HIDEvent) async throws { throw TransportError.unavailable }
    func disconnect() async {}
}

struct BLEReconnectGate: Equatable {
    private(set) var requiresAdvertisement = false
    var permitsCachedPeripheral: Bool { !requiresAdvertisement }
    mutating func connectionAttemptFailed() { requiresAdvertisement = true }
    mutating func advertisementObserved() { requiresAdvertisement = false }
}

final class BLEHIDControlTransport: NSObject, ObservableObject, HIDControlTransport, CBCentralManagerDelegate, CBPeripheralDelegate {
    let kind = TransportKind.bluetooth
    @Published private(set) var isAvailable = false
    @Published private(set) var state: TransportConnectionState = .offline
    @Published private(set) var radioState: BluetoothRadioState = .unknown
    private var central: CBCentralManager!; private var peripheral: CBPeripheral?; private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var secureChannel: SecureChannel?
    private let deviceId: String
    private let service = CBUUID(string: "7D9F0001-4F4D-4F56-4552-484944000001")
    private let control = CBUUID(string: "7D9F0002-4F4D-4F56-4552-484944000001")
    private let secureStatus = CBUUID(string: "7D9F0005-4F4D-4F56-4552-484944000001")
    private let otaService = CBUUID(string: "7D9F1001-4F4D-4F56-4552-484944000001")
    private let otaControl = CBUUID(string: "7D9F1002-4F4D-4F56-4552-484944000001")
    private let otaData = CBUUID(string: "7D9F1003-4F4D-4F56-4552-484944000001")
    private let otaStatus = CBUUID(string: "7D9F1004-4F4D-4F56-4552-484944000001")
    let firmwareUpdater = FirmwareUpdateManager()
    var metadataHandler: ((BLEDeviceMetadata) -> Void)? {
        didSet { firmwareUpdater.metadataHandler = metadataHandler }
    }
    private var reconnectWork: DispatchWorkItem?
    private var scanTimeoutWork: DispatchWorkItem?
    private var connectionTimeoutWork: DispatchWorkItem?
    private var peripheralIdentifier: UUID?
    private var reconnectGate = BLEReconnectGate()
    private var shouldReconnect = false
    private var pendingServices = 0
    private var authTimeoutWork: DispatchWorkItem?
    private let authTimeout: TimeInterval
    private let connectionTimeout: TimeInterval
    private struct PendingWrite {
        let id: String
        let characteristic: CBCharacteristic
        let payload: Data
        let type: CBCharacteristicWriteType
        let continuation: CheckedContinuation<Void, Error>
    }
    private var writeQueue: [PendingWrite] = []
    private var responseWrite: PendingWrite?
    private var responseTimeoutWork: DispatchWorkItem?
    private struct PendingSecureReply {
        let id: UUID
        let continuation: CheckedContinuation<String, Error>
        let timeout: DispatchWorkItem
    }
    private var pendingSecureReplies: [PendingSecureReply] = []
    private var secureRequestInFlight = false
    static func writeType(for event: HIDEvent, properties: CBCharacteristicProperties) -> CBCharacteristicWriteType? {
        let highFrequency: Bool = {
            if case .mouseMove = event { return true }
            if case .scroll = event { return true }
            return false
        }()
        if highFrequency && properties.contains(.writeWithoutResponse) { return .withoutResponse }
        if properties.contains(.write) { return .withResponse }
        if properties.contains(.writeWithoutResponse) { return .withoutResponse }
        return nil
    }
    init(deviceId: String, authTimeout: TimeInterval = 10, connectionTimeout: TimeInterval = 8) { self.deviceId = deviceId.lowercased(); self.authTimeout = authTimeout; self.connectionTimeout = connectionTimeout; super.init(); central = CBCentralManager(delegate: self, queue: .main) }
    private func scan() {
        guard shouldReconnect, central.state == .poweredOn, !central.isScanning, peripheral == nil else { return }
        if reconnectGate.permitsCachedPeripheral, let peripheralIdentifier,
           let known = central.retrievePeripherals(withIdentifiers: [peripheralIdentifier]).first {
            peripheral = known
            state = .connecting
            appLog(.bluetooth, "reconnecting known peripheral deviceId=\(deviceId)")
            central.connect(known)
            startConnectionTimeout(for: known, source: "cached")
            return
        }
        state = state == .reconnecting ? .reconnecting : .discovering
        // Identity is advertised in manufacturer data because the compact BLE
        // advertisement cannot also carry the 128-bit service UUID.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        appLog(.bluetooth, "control scan started deviceId=\(deviceId)")
        scanTimeoutWork?.cancel()
        let timeout = DispatchWorkItem { [weak self] in guard let self, self.central.isScanning else { return }; self.central.stopScan(); self.state = .offline; appLog(.bluetooth, "control scan timed out deviceId=\(self.deviceId)"); let retry = DispatchWorkItem { [weak self] in self?.scan() }; self.reconnectWork = retry; DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: retry) }
        scanTimeoutWork = timeout; DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    }
    private func startConnectionTimeout(for candidate: CBPeripheral, source: String) {
        connectionTimeoutWork?.cancel()
        let timeout = DispatchWorkItem { [weak self, weak candidate] in
            guard let self, let candidate, self.peripheral === candidate,
                  self.state == .connecting else { return }
            appLog(.errors, "BLE \(source) connection timed out deviceId=\(self.deviceId); cancelling and forcing advertisement scan")
            self.reconnectGate.connectionAttemptFailed()
            self.connectionTimeoutWork = nil
            self.central.cancelPeripheralConnection(candidate)
            self.peripheral = nil
            self.isAvailable = false
            self.state = self.shouldReconnect ? .reconnecting : .offline
            if self.shouldReconnect {
                // Let CoreBluetooth deliver the cancellation callback before a
                // scan can rediscover the same CBPeripheral object.
                let recovery = DispatchWorkItem { [weak self] in self?.scan() }
                self.reconnectWork = recovery
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: recovery)
            }
        }
        connectionTimeoutWork = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + connectionTimeout, execute: timeout)
    }
    func connect() async { shouldReconnect = true; scan() }
    func waitUntilReady(timeout: TimeInterval = 10) async throws {
        await connect()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if state == .ready, isAvailable { return }
            if state == .authenticationFailed {
                throw TransportError.failed("Secure Bluetooth authentication failed.")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw TransportError.failed("Encrypted Bluetooth connection timed out.")
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: radioState = .poweredOn; if state == .unavailable { state = .offline }; scan()
        case .poweredOff: radioState = .poweredOff; resetForUnavailableRadio(); state = .unavailable
        case .unsupported: radioState = .unsupported; resetForUnavailableRadio(); state = .unavailable
        case .unauthorized: radioState = .unauthorized; resetForUnavailableRadio(); state = .unavailable
        case .resetting: radioState = .resetting; resetForUnavailableRadio(); state = .unavailable
        case .unknown: radioState = .unknown; resetForUnavailableRadio(); state = .unavailable
        @unknown default: radioState = .unknown; resetForUnavailableRadio(); state = .unavailable
        }
    }
    private func resetForUnavailableRadio() {
        reconnectWork?.cancel(); scanTimeoutWork?.cancel(); connectionTimeoutWork?.cancel()
        central.stopScan()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil; isAvailable = false; secureChannel = nil
        characteristics.removeAll(); pendingServices = 0
        failPendingWrites(TransportError.unavailable)
        failPendingSecureReplies(TransportError.unavailable)
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard BLEDeviceDiscoveryManager.advertisement(advertisementData, matches: deviceId) else { return }
        appLog(.bluetooth, "discovered deviceId=\(deviceId) rssi=\(RSSI) connect requested")
        reconnectGate.advertisementObserved()
        self.peripheral = peripheral
        peripheralIdentifier = peripheral.identifier
        scanTimeoutWork?.cancel()
        central.stopScan()
        state = .discovered
        central.connect(peripheral)
        state = .connecting
        startConnectionTimeout(for: peripheral, source: "scan")
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) { guard self.peripheral === peripheral else { central.cancelPeripheralConnection(peripheral); return }; connectionTimeoutWork?.cancel(); connectionTimeoutWork = nil; reconnectGate.advertisementObserved(); appLog(.bluetooth, "didConnect deviceId=\(deviceId)"); state = .connected; peripheral.delegate = self; peripheral.discoverServices([service, otaService]) }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral else { appLog(.bluetooth, "ignored stale BLE connect failure deviceId=\(deviceId)"); return }
        connectionTimeoutWork?.cancel(); connectionTimeoutWork = nil
        reconnectGate.connectionAttemptFailed()
        appLog(.errors, "BLE connection failed error=\(error?.localizedDescription ?? "unknown")")
        self.peripheral = nil; isAvailable = false; state = shouldReconnect ? .reconnecting : .offline
        guard shouldReconnect else { return }
        reconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        reconnectWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral else { appLog(.bluetooth, "ignored stale BLE disconnect deviceId=\(deviceId)"); return }
        connectionTimeoutWork?.cancel(); connectionTimeoutWork = nil
        appLog(error == nil ? .bluetooth : .errors, "BLE disconnected error=\(error?.localizedDescription ?? "none") reconnect=\(shouldReconnect)")
        let authFailed = state == .authenticationFailed
        isAvailable = false
        state = authFailed ? .authenticationFailed : (shouldReconnect ? .reconnecting : .offline)
        self.peripheral = nil
        secureChannel = nil
        failPendingWrites(TransportError.failed("Bluetooth disconnected before HID delivery was confirmed."))
        failPendingSecureReplies(TransportError.failed("Bluetooth disconnected before the secure response arrived."))
        authTimeoutWork?.cancel(); authTimeoutWork = nil
        if firmwareUpdater.activeTransport != .wifi { firmwareUpdater.disconnected(expected: firmwareUpdater.expectsReboot) }
        characteristics.removeAll(); pendingServices = 0; reconnectWork?.cancel()
        guard shouldReconnect && !authFailed else { return }
        let work = DispatchWorkItem { [weak self] in appLog(.bluetooth, "reconnect scheduled"); self?.scan() }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) { guard error == nil, let services = peripheral.services, !services.isEmpty else { appLog(.errors, "BLE service discovery error=\(error?.localizedDescription ?? "empty")"); central.cancelPeripheralConnection(peripheral); return }; appLog(.bluetooth, "services discovered count=\(services.count)"); pendingServices = services.count; services.forEach { peripheral.discoverCharacteristics(nil, for: $0) } }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if error == nil { service.characteristics?.forEach { characteristic in characteristics[characteristic.uuid] = characteristic; appLog(.bluetooth, "characteristic uuid=\(characteristic.uuid.uuidString) properties=\(characteristic.properties.rawValue)") } }
        pendingServices -= 1
        guard pendingServices == 0 else { return }
        guard characteristics[control] != nil, let tx = characteristics[secureStatus],
              let secret = PairingKeyStore.load(deviceId: deviceId),
              let channel = try? SecureChannel(deviceId: deviceId, secret: secret) else {
            appLog(.errors, "Secure Protocol v2 or USB trust is missing")
            failAuthentication(peripheral); return
        }
        secureChannel = channel
        state = .authenticating
        peripheral.setNotifyValue(true, for: tx)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == secureStatus, state == .authenticating else { return }
        guard error == nil, characteristic.isNotifying, let rx = characteristics[control] else { failAuthentication(peripheral); return }
        startAuthTimeout(peripheral)
        peripheral.writeValue(Data("secure begin".utf8), for: rx, type: .withResponse)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == otaStatus { firmwareUpdater.receive(characteristic.value, error: error); return }
        guard characteristic.uuid == secureStatus, error == nil,
              let data = characteristic.value else { return }
        if state == .authenticating, let secureChannel {
            guard let reply = String(data: data, encoding: .utf8) else { return }
            do {
                if reply.hasPrefix("secure challenge "), let rx = characteristics[control] {
                    peripheral.writeValue(Data(try secureChannel.hello(for: reply).utf8), for: rx, type: .withResponse)
                    return
                }
                if reply.hasPrefix("secure ready ") {
                    try secureChannel.acceptReady(reply)
                    authTimeoutWork?.cancel(); authTimeoutWork = nil
                    isAvailable = true; state = .ready; prepareFirmwareUpdater(peripheral)
                    return
                }
                if reply == "secure failed" {
                    appLog(.errors, "BLE secure proof was rejected")
                    failAuthentication(peripheral)
                    return
                }
            } catch {
                appLog(.errors, "BLE secure handshake failed")
                failAuthentication(peripheral)
                return
            }
        }
        guard state == .ready, let secureChannel, !pendingSecureReplies.isEmpty else { return }
        let plaintext: String?
        if data.first == SecureChannel.binaryVersion,
           let opened = try? secureChannel.openBinary(data) {
            plaintext = String(data: opened, encoding: .utf8)
        } else if let reply = String(data: data, encoding: .utf8) {
            plaintext = try? secureChannel.openText(reply)
        } else {
            plaintext = nil
        }
        if let plaintext {
            let pending = pendingSecureReplies.removeFirst()
            pending.timeout.cancel()
            pending.continuation.resume(returning: plaintext)
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let pending = responseWrite,
              pending.characteristic.uuid == characteristic.uuid else { return }
        responseTimeoutWork?.cancel(); responseTimeoutWork = nil; responseWrite = nil
        appLog(error == nil ? .bluetooth : .errors, "BLE didWrite id=\(pending.id) uuid=\(characteristic.uuid.uuidString) result=\(error?.localizedDescription ?? "success")")
        if let error { pending.continuation.resume(throwing: error) }
        else { pending.continuation.resume(); appLog(.bluetooth, "HID delivered id=\(pending.id) confirmation=ATT") }
        drainWrites(peripheral)
    }
    private func prepareFirmwareUpdater(_ peripheral: CBPeripheral) {
        guard let control = characteristics[otaControl], let data = characteristics[otaData], let status = characteristics[otaStatus] else { return }
        guard let secureChannel else { return }
        firmwareUpdater.attach(peripheral: peripheral, control: control, data: data,
                               status: status, seal: { try secureChannel.sealBinary($0) })
        peripheral.setNotifyValue(true, for: status)
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) { firmwareUpdater.writerReady(); drainWrites(peripheral) }
    private func startAuthTimeout(_ peripheral: CBPeripheral) { authTimeoutWork?.cancel(); let work = DispatchWorkItem { [weak self, weak peripheral] in guard let self, let peripheral, self.state == .authenticating else { return }; self.retryAfterAuthenticationTimeout(peripheral) }; authTimeoutWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + authTimeout, execute: work) }
    private func failAuthentication(_ peripheral: CBPeripheral) { authTimeoutWork?.cancel(); authTimeoutWork = nil; isAvailable = false; state = .authenticationFailed; central.cancelPeripheralConnection(peripheral) }
    private func retryAfterAuthenticationTimeout(_ peripheral: CBPeripheral) {
        authTimeoutWork?.cancel(); authTimeoutWork = nil
        appLog(.bluetooth, "Secure handshake timed out; reconnecting without invalidating USB trust")
        isAvailable = false; secureChannel = nil
        state = shouldReconnect ? .reconnecting : .offline
        central.cancelPeripheralConnection(peripheral)
    }
    private func writeConfirmed(_ payload: Data, id: String) async throws {
        guard let peripheral, let characteristic = characteristics[control],
              characteristic.properties.contains(.write) else { throw TransportError.unavailable }
        try await withCheckedThrowingContinuation { continuation in
            writeQueue.append(PendingWrite(id: id, characteristic: characteristic,
                                           payload: payload, type: .withResponse,
                                           continuation: continuation))
            drainWrites(peripheral)
        }
    }
    func request(_ command: String, timeout: TimeInterval = 10) async throws -> String {
        try await waitUntilReady()
        guard !firmwareUpdater.blocksControl else {
            throw TransportError.failed("Secure Bluetooth management is busy during firmware transfer.")
        }
        guard !command.contains("\n"), !command.contains("\r"),
              let secureChannel else { throw TransportError.encoding }
        return try await requestPayload(timeout: timeout) {
            Data(try secureChannel.sealText(command).utf8)
        }
    }
    private func requestPayload(
        timeout: TimeInterval = 10,
        makePayload: () throws -> Data
    ) async throws -> String {
        let slotDeadline = Date().addingTimeInterval(timeout)
        while secureRequestInFlight {
            guard state == .ready, Date() < slotDeadline else {
                throw TransportError.failed("Secure Bluetooth request queue timed out.")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        secureRequestInFlight = true
        defer { secureRequestInFlight = false }
        let payload = try makePayload()
        return try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            let timeoutWork = DispatchWorkItem { [weak self] in
                guard let self,
                      let index = self.pendingSecureReplies.firstIndex(where: { $0.id == id }) else { return }
                let pending = self.pendingSecureReplies.remove(at: index)
                pending.continuation.resume(throwing: TransportError.failed("Secure Bluetooth response timed out."))
            }
            pendingSecureReplies.append(PendingSecureReply(id: id, continuation: continuation,
                                                            timeout: timeoutWork))
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
            Task {
                do { try await self.writeConfirmed(payload, id: "request-\(id.uuidString)") }
                catch { self.failPendingSecureReply(id: id, error: error) }
            }
        }
    }
    func diagnosticsInfo() async throws -> Data {
        Data(try await request("DIAGNOSTICS INFO").utf8)
    }
    func nextDiagnostic(after cursor: UInt32) async throws -> FirmwareLogRecord? {
        let data = Data(try await request("DIAGNOSTICS NEXT \(cursor)").utf8)
        if String(data: data, encoding: .utf8) == "{}" { return nil }
        return try JSONDecoder().decode(FirmwareLogRecord.self, from: data)
    }
    func usbIdentity(includeManufacturer: Bool = false) async throws -> USBIdentity {
        let basicReply = try await request("USB GET")
        let basic = try JSONDecoder().decode(USBIdentity.self, from: Data(basicReply.utf8))
        guard includeManufacturer else { return basic }
        // USB GET2 can exceed the text-notification size on smaller negotiated
        // ATT MTUs. Keep the serial/VID/PID result even when the optional,
        // manufacturer-inclusive response cannot be delivered by an older peer.
        guard let extendedReply = try? await request("USB GET2", timeout: 3),
              let extended = try? JSONDecoder().decode(
                USBIdentity.self, from: Data(extendedReply.utf8)
              ) else { return basic }
        return extended
    }
    func send(_ event: HIDEvent) async throws {
        if firmwareUpdater.blocksControl { throw TransportError.failed("Controls are unavailable during a firmware update.") }
        let uuid = control
        guard state == .ready, let secureChannel, let peripheral,
              let characteristic = characteristics[control] else { throw TransportError.unavailable }
        let id = AppLogContext.eventID.map(String.init) ?? "-"
        let payload: Data
        do { payload = try secureChannel.sealBinary(event.binary) }
        catch { throw TransportError.failed("Could not encrypt Bluetooth control event.") }
        let properties = characteristic.properties
        guard let writeType = Self.writeType(for: event, properties: properties) else { appLog(.errors, "BLE id=\(id) characteristic not writable properties=\(properties.rawValue)"); throw TransportError.failed("Bluetooth HID characteristic is not writable.") }
        guard payload.count <= peripheral.maximumWriteValueLength(for: writeType) else { throw TransportError.failed("Bluetooth HID frame exceeds the negotiated ATT write size.") }
        if writeType == .withoutResponse, writeQueue.count >= 32 {
            throw TransportError.failed("Bluetooth control is busy; high-frequency input was throttled.")
        }
        appLog(.bluetooth, "HID write requested id=\(id) uuid=\(uuid.uuidString) bytes=\(payload.count) writeType=\(writeType == .withResponse ? "withResponse" : "withoutResponse") canSendWithoutResponse=\(peripheral.canSendWriteWithoutResponse) maximum=\(peripheral.maximumWriteValueLength(for: writeType))")
        try await withCheckedThrowingContinuation { continuation in
            writeQueue.append(PendingWrite(id: id, characteristic: characteristic, payload: payload, type: writeType, continuation: continuation))
            drainWrites(peripheral)
        }
    }
    func setKeepAwake(_ settings: KeepAwakeSettings) async throws {
        guard !firmwareUpdater.blocksControl else {
            throw TransportError.failed("Bluetooth management is unavailable during a firmware update.")
        }
        guard state == .ready, let peripheral, let rx = characteristics[control],
              rx.properties.contains(.write) else { throw TransportError.unavailable }
        let commands = [
            "jiggle interval \(settings.moveIntervalMs)",
            settings.moveEnabled ? "jiggle on" : "jiggle off",
            "autoclick interval \(settings.clickIntervalMs)",
            settings.clickEnabled ? "autoclick on" : "autoclick off",
        ]
        for command in commands {
            guard let secureChannel else { throw TransportError.failed("The authenticated Bluetooth session was lost.") }
            let payload: Data
            do { payload = Data(try secureChannel.sealText(command).utf8) }
            catch { throw TransportError.failed("Could not encrypt keep-awake settings.") }
            try await withCheckedThrowingContinuation { continuation in
                writeQueue.append(PendingWrite(
                    id: "keep-awake-\(UUID().uuidString)",
                    characteristic: rx,
                    payload: payload,
                    type: .withResponse,
                    continuation: continuation
                ))
                drainWrites(peripheral)
            }
        }
    }
    func setWiFi(ssid: String, password: String) async throws {
        try await waitUntilReady()
        let ssidData = Data(ssid.utf8)
        let passwordData = Data(password.utf8)
        guard (1 ... 32).contains(ssidData.count), passwordData.count <= 63 else {
            throw TransportError.failed("Wi-Fi names are limited to 32 bytes and passwords to 63 bytes.")
        }
        var plaintext = Data([0xFE, 0x01, UInt8(ssidData.count), UInt8(passwordData.count)])
        plaintext.append(ssidData)
        plaintext.append(passwordData)
        try await sendManagementFrame(plaintext, id: "wifi-setup")
    }
    func configuredWiFiNetworks() async throws -> [String] {
        struct CountResponse: Decodable { let count: Int }
        struct NetworkResponse: Decodable { let ssid: String }
        let countReply = try await request("WIFI LIST")
        let count = try JSONDecoder().decode(CountResponse.self, from: Data(countReply.utf8)).count
        guard (0 ... 5).contains(count) else {
            throw TransportError.failed("InputPilot returned an invalid Wi-Fi network count.")
        }
        var networks: [String] = []
        for index in 0 ..< count {
            let reply = try await request("WIFI GET \(index)")
            networks.append(try JSONDecoder().decode(NetworkResponse.self, from: Data(reply.utf8)).ssid)
        }
        return networks
    }
    func removeWiFi(ssid: String) async throws {
        try await waitUntilReady()
        let ssidData = Data(ssid.utf8)
        guard (1 ... 32).contains(ssidData.count) else {
            throw TransportError.failed("The Wi-Fi network name is invalid.")
        }
        var plaintext = Data([0xFE, 0x04, UInt8(ssidData.count)])
        plaintext.append(ssidData)
        try await sendManagementFrame(plaintext, id: "wifi-remove")
    }
    func clearWiFiNetworks() async throws {
        try await waitUntilReady()
        try await sendManagementFrame(Data([0xFE, 0x05]), id: "wifi-clear")
    }
    private func sendManagementFrame(_ plaintext: Data, id: String) async throws {
        guard !firmwareUpdater.blocksControl else {
            throw TransportError.failed("Bluetooth management is unavailable during a firmware update.")
        }
        guard let peripheral, let commandCharacteristic = characteristics[control],
              commandCharacteristic.properties.contains(.write) else {
            throw TransportError.unavailable
        }
        guard let secureChannel else {
            throw TransportError.failed("Device management requires secure USB pairing.")
        }
        let reply: String
        do {
            reply = try await requestPayload(timeout: 2) {
                let payload = try secureChannel.sealBinary(plaintext)
                guard payload.count <= peripheral.maximumWriteValueLength(for: .withResponse) else {
                    throw TransportError.failed("The encrypted management command is too large.")
                }
                return payload
            }
        } catch where error.localizedDescription == "Secure Bluetooth response timed out." {
            // Firmware through 0.8.17 acknowledged only the ATT write. Preserve
            // that wire compatibility; 0.8.18+ returns the structured protocol
            // acknowledgement above without entering this fallback.
            appLog(.control, "BLE management used legacy ATT-only acknowledgement id=\(id)")
            return
        }
        if reply.hasPrefix("error ") {
            let code = String(reply.dropFirst("error ".count))
            switch code {
            case "invalid_wifi_credentials":
                throw TransportError.failed("The Wi-Fi network name or password is invalid.")
            case "wifi_network_not_found":
                throw TransportError.failed("That Wi-Fi network is no longer configured.")
            case "wifi_storage_failed":
                throw TransportError.failed("InputPilot could not store the Wi-Fi configuration.")
            default:
                throw TransportError.failed("InputPilot rejected the Wi-Fi operation (\(code)).")
            }
        }
        struct ManagementReply: Decodable { let operation: String; let status: String }
        guard let result = try? JSONDecoder().decode(ManagementReply.self, from: Data(reply.utf8)),
              result.status == "accepted" else {
            throw TransportError.failed("InputPilot returned an invalid Wi-Fi management response.")
        }
        appLog(.control, "BLE management acknowledged id=\(id) operation=\(result.operation)")
    }
    func reboot() async throws {
        guard !firmwareUpdater.blocksControl else {
            throw TransportError.failed("Bluetooth management is unavailable during a firmware update.")
        }
        try await waitUntilReady()
        guard let secureChannel, let peripheral,
              let characteristic = characteristics[control] else { throw TransportError.unavailable }
        let payload = Data(try secureChannel.sealText("REBOOT").utf8)
        try await withCheckedThrowingContinuation { continuation in
            writeQueue.append(PendingWrite(
                id: "reboot-\(UUID().uuidString)", characteristic: characteristic,
                payload: payload, type: .withResponse, continuation: continuation
            ))
            drainWrites(peripheral)
        }
    }
    func resetUSBIdentity() async throws {
        guard !firmwareUpdater.blocksControl else {
            throw TransportError.failed("Bluetooth management is unavailable during a firmware update.")
        }
        try await waitUntilReady()
        guard let peripheral, let commandCharacteristic = characteristics[control],
              commandCharacteristic.properties.contains(.write), let secureChannel else {
            throw TransportError.failed("Restoring USB defaults requires secure Bluetooth pairing.")
        }
        let payload = try secureChannel.sealBinary(Data([0xFE, 0x02]))
        try await withCheckedThrowingContinuation { continuation in
            writeQueue.append(PendingWrite(
                id: "usb-reset-\(UUID().uuidString)", characteristic: commandCharacteristic,
                payload: payload, type: .withResponse, continuation: continuation
            ))
            drainWrites(peripheral)
        }
    }
    func setUSBIdentity(productName: String, vid: Int, pid: Int, serialNumber: String) async throws {
        guard !firmwareUpdater.blocksControl else {
            throw TransportError.failed("Bluetooth management is unavailable during a firmware update.")
        }
        try await waitUntilReady()
        let product = Data(productName.utf8)
        let serial = Data(serialNumber.utf8)
        guard (1 ... 31).contains(product.count), (1 ... 31).contains(serial.count),
              (1 ... 0xFFFF).contains(vid), (1 ... 0xFFFF).contains(pid) else {
            throw TransportError.failed("Invalid USB identity values.")
        }
        guard let peripheral, let commandCharacteristic = characteristics[control],
              commandCharacteristic.properties.contains(.write), let secureChannel else {
            throw TransportError.failed("Changing USB identity requires secure Bluetooth pairing.")
        }
        var plaintext = Data([0xFE, 0x03, UInt8(vid & 0xFF), UInt8((vid >> 8) & 0xFF),
                              UInt8(pid & 0xFF), UInt8((pid >> 8) & 0xFF),
                              UInt8(product.count), UInt8(serial.count)])
        plaintext.append(product)
        plaintext.append(serial)
        let payload = try secureChannel.sealBinary(plaintext)
        guard payload.count <= peripheral.maximumWriteValueLength(for: .withResponse) else {
            throw TransportError.failed("USB identity exceeds the encrypted Bluetooth frame size.")
        }
        try await withCheckedThrowingContinuation { continuation in
            writeQueue.append(PendingWrite(
                id: "usb-update-\(UUID().uuidString)", characteristic: commandCharacteristic,
                payload: payload, type: .withResponse, continuation: continuation
            ))
            drainWrites(peripheral)
        }
    }
    func setUSBIdentity(manufacturerName: String, productName: String, vid: Int, pid: Int, serialNumber: String) async throws {
        guard !firmwareUpdater.blocksControl else {
            throw TransportError.failed("Bluetooth management is unavailable during a firmware update.")
        }
        try await waitUntilReady()
        let manufacturer = Data(manufacturerName.utf8)
        let product = Data(productName.utf8)
        let serial = Data(serialNumber.utf8)
        guard (1 ... 31).contains(manufacturer.count), (1 ... 31).contains(product.count),
              (1 ... 31).contains(serial.count), (1 ... 0xFFFF).contains(vid),
              (1 ... 0xFFFF).contains(pid) else {
            throw TransportError.failed("Invalid USB identity values.")
        }
        guard let peripheral, let commandCharacteristic = characteristics[control],
              commandCharacteristic.properties.contains(.write), let secureChannel else {
            throw TransportError.failed("Changing USB identity requires secure Bluetooth pairing.")
        }
        var plaintext = Data([0xFE, 0x05, UInt8(vid & 0xFF), UInt8((vid >> 8) & 0xFF),
                              UInt8(pid & 0xFF), UInt8((pid >> 8) & 0xFF),
                              UInt8(manufacturer.count), UInt8(product.count), UInt8(serial.count)])
        plaintext.append(manufacturer)
        plaintext.append(product)
        plaintext.append(serial)
        let payload = try secureChannel.sealBinary(plaintext)
        guard payload.count <= peripheral.maximumWriteValueLength(for: .withResponse) else {
            throw TransportError.failed("USB identity exceeds the encrypted Bluetooth frame size.")
        }
        try await withCheckedThrowingContinuation { continuation in
            writeQueue.append(PendingWrite(
                id: "usb-update-\(UUID().uuidString)", characteristic: commandCharacteristic,
                payload: payload, type: .withResponse, continuation: continuation
            ))
            drainWrites(peripheral)
        }
    }
    private func drainWrites(_ peripheral: CBPeripheral) {
        guard responseWrite == nil else { return }
        while !writeQueue.isEmpty {
            let pending = writeQueue[0]
            if pending.type == .withoutResponse {
                guard peripheral.canSendWriteWithoutResponse else { return }
                writeQueue.removeFirst()
                peripheral.writeValue(pending.payload, for: pending.characteristic, type: .withoutResponse)
                appLog(.bluetooth, "HID delivered id=\(pending.id) confirmation=CoreBluetooth-flow-controlled")
                pending.continuation.resume()
                continue
            }
            writeQueue.removeFirst(); responseWrite = pending
            peripheral.writeValue(pending.payload, for: pending.characteristic, type: .withResponse)
            let timeout = DispatchWorkItem { [weak self, weak peripheral] in
                guard let self, let current = self.responseWrite, current.id == pending.id else { return }
                self.isAvailable = false
                self.state = self.shouldReconnect ? .reconnecting : .offline
                self.responseWrite = nil
                current.continuation.resume(throwing: TransportError.failed("Bluetooth ATT write acknowledgement timed out."))
                appLog(.errors, "BLE HID write timeout id=\(current.id)")
                if let peripheral { self.central.cancelPeripheralConnection(peripheral) }
            }
            responseTimeoutWork = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
            return
        }
    }
    private func failPendingWrites(_ error: Error) {
        responseTimeoutWork?.cancel(); responseTimeoutWork = nil
        if let pending = responseWrite { pending.continuation.resume(throwing: error) }
        responseWrite = nil
        let queued = writeQueue; writeQueue.removeAll(keepingCapacity: true)
        queued.forEach { $0.continuation.resume(throwing: error) }
    }
    private func failPendingSecureReply(id: UUID, error: Error) {
        guard let index = pendingSecureReplies.firstIndex(where: { $0.id == id }) else { return }
        let pending = pendingSecureReplies.remove(at: index)
        pending.timeout.cancel()
        pending.continuation.resume(throwing: error)
    }
    private func failPendingSecureReplies(_ error: Error) {
        let pending = pendingSecureReplies
        pendingSecureReplies.removeAll()
        pending.forEach { $0.timeout.cancel(); $0.continuation.resume(throwing: error) }
    }
    func disconnect() async { shouldReconnect = false; reconnectWork?.cancel(); scanTimeoutWork?.cancel(); connectionTimeoutWork?.cancel(); connectionTimeoutWork = nil; authTimeoutWork?.cancel(); authTimeoutWork = nil; failPendingWrites(TransportError.unavailable); failPendingSecureReplies(TransportError.unavailable); central.stopScan(); if let peripheral { central.cancelPeripheralConnection(peripheral) }; self.peripheral = nil; secureChannel = nil; characteristics.removeAll(); pendingServices = 0; isAvailable = false; state = .offline }
}

@MainActor enum InputPilotBluetoothManager {
    private static var sessions: [String: BLEHIDControlTransport] = [:]
    static func session(deviceId: String) -> BLEHIDControlTransport {
        let key = deviceId.lowercased()
        if let existing = sessions[key] { return existing }
        let session = BLEHIDControlTransport(deviceId: deviceId)
        sessions[key] = session
        return session
    }
    static func removeSession(deviceId: String) async {
        guard let session = sessions.removeValue(forKey: deviceId.lowercased()) else { return }
        await session.disconnect()
    }
}

enum InputPilotWiFiManager {
    private static var sessions: [String: TCPHIDControlTransport] = [:]
    static func session(host: String, deviceId: String) -> TCPHIDControlTransport {
        let normalizedHost = DeviceEndpointResolver.sanitizeHost(host).lowercased()
        let key = "\(deviceId.lowercased())|\(normalizedHost)"
        if let existing = sessions[key] { return existing }
        let session = TCPHIDControlTransport(host: normalizedHost, deviceId: deviceId)
        sessions[key] = session
        return session
    }
    static func removeSessions(deviceId: String) async {
        let prefix = deviceId.lowercased() + "|"
        let keys = sessions.keys.filter { $0.hasPrefix(prefix) }
        let removed = keys.compactMap { sessions.removeValue(forKey: $0) }
        for session in removed { await session.disconnect() }
    }
}

@MainActor final class HIDConnectionManager: ObservableObject {
    @Published var mode: ConnectionMode { didSet { UserDefaults.standard.set(mode.rawValue, forKey: "connectionMode") } }
    @Published var activeTransport: TransportKind?
    @Published var lastError: String?
    @Published private(set) var isConnecting = false
    let capabilities: Set<String>
    let protocolVersion: Int
    var onEvent: ((HIDEvent) -> Void)?
    private let ble: HIDControlTransport; private let tcp: HIDControlTransport
    private var leasedTransport: HIDControlTransport?
    private var nextEventID: UInt64 = 0
    private var lastReleaseAllAt = Date.distantPast
    init(device: StoredDevice) {
        mode = ConnectionMode(rawValue: UserDefaults.standard.string(forKey: "connectionMode") ?? "") ?? .automatic
        let host = device.staIP ?? device.mdnsHost
        let bluetooth = InputPilotBluetoothManager.session(deviceId: device.deviceId)
        bluetooth.metadataHandler = { [weak device] metadata in
            guard let device, metadata.deviceId.lowercased() == device.deviceId.lowercased() else { return }
            DeviceMerge.bluetooth(metadata, into: device)
        }
        ble = bluetooth
        tcp = host.isEmpty ? UnavailableHIDControlTransport(kind: .tcp) :
            InputPilotWiFiManager.session(host: host, deviceId: device.deviceId)
        capabilities = Set(device.capabilities)
        protocolVersion = device.protocolVersion
    }
    init(ble: HIDControlTransport, tcp: HIDControlTransport, capabilities: Set<String> = [], protocolVersion: Int = 2) {
        mode = .automatic
        self.ble = ble; self.tcp = tcp; self.capabilities = capabilities; self.protocolVersion = protocolVersion
    }
    func connect() async { isConnecting = true; async let b: Void = ble.connect(); async let t: Void = tcp.connect(); _ = await (b, t); isConnecting = false }
    func disconnect() async { await releaseAll(); activeTransport = nil }
    @discardableResult func send(_ event: HIDEvent) async -> Bool {
        nextEventID &+= 1; let eventID = nextEventID
        appLog(.input, "id=\(eventID) \(event.diagnosticName)")
        guard protocolVersion == 2 else { lastError = "Firmware protocol v\(protocolVersion) is unsupported. Reflash the device with current firmware."; activeTransport = nil; return false }
        if let capability = requiredCapability(for: event), !supports(capability) {
            lastError = "This firmware does not support \(capability.replacingOccurrences(of: "_", with: " "))."
            return false
        }
        if let leasedTransport {
            guard leasedTransport.isAvailable, leasedTransport.state == .ready else {
                await abortOrderedSession(reason: "Active \(leasedTransport.kind.rawValue) transport was lost; sequence stopped.")
                return false
            }
            do { try await AppLogContext.$eventID.withValue(eventID) { try await leasedTransport.send(event) }; activeTransport = leasedTransport.kind; lastError = nil; onEvent?(event); return true }
            catch { await abortOrderedSession(reason: "Active \(leasedTransport.kind.rawValue) transport failed; sequence stopped."); return false }
        }
        var failure: String?; let available = candidates(for: event).filter { $0.isAvailable && $0.state == .ready }
        appLog(.control, "id=\(eventID) candidates=\(available.map(\.kind.rawValue).joined(separator: ","))")
        for (index, transport) in available.enumerated() {
            appLog(.control, "id=\(eventID) selected=\(transport.kind.rawValue)")
            do { try await AppLogContext.$eventID.withValue(eventID) { try await transport.send(event) }; activeTransport = transport.kind; lastError = nil; onEvent?(event); return true }
            catch {
                failure = error.localizedDescription; appLog(.errors, "CONTROL id=\(eventID) transport=\(transport.kind.rawValue) error=\(error.localizedDescription)")
                if !event.safeToRetryAfterUncertainDelivery {
                    appLog(.control, "id=\(eventID) original event retried=no; stateful recovery=releaseAll")
                    if let recovery = available.dropFirst(index + 1).first { try? await AppLogContext.$eventID.withValue(eventID) { try await recovery.send(.releaseAll) } }
                    break
                }
                if index + 1 < available.count { appLog(.control, "id=\(eventID) fallback=\(available[index + 1].kind.rawValue) original event retried=yes") }
            }
        }
        lastError = failure ?? (allTransports.contains { $0.state == .authenticationFailed } ? "Authentication failed" : "No permitted control transport is ready.")
        activeTransport = nil
        return false
    }
    func releaseAll() async {
        let now = Date()
        guard now.timeIntervalSince(lastReleaseAllAt) >= 0.5 else {
            appLog(.control, "release_all coalesced duplicate=yes")
            return
        }
        lastReleaseAllAt = now
        await send(.releaseAll)
    }
    func releaseAllPreservingError() async {
        let error = lastError
        await releaseAll()
        if let error { lastError = error }
    }
    @discardableResult func sendText(_ text: String, layout: KeyboardLayout, delayMilliseconds: Int = 0) async -> Bool {
        let ownsSession = leasedTransport == nil
        if ownsSession && !beginOrderedSession(lowLatency: false) { return false }
        defer { if ownsSession { endOrderedSession() } }
        do {
            for stroke in try layout.strokes(for: text) {
                if Task.isCancelled { return false }
                guard await send(.keyboardReport(modifiers: stroke.modifiers, usage: stroke.usage)) else { return false }
                if delayMilliseconds > 0 { try? await Task.sleep(for: .milliseconds(delayMilliseconds)) }
            }
            return true
        } catch { lastError = error.localizedDescription; return false }
    }
    @discardableResult func beginOrderedSession(lowLatency: Bool) -> Bool {
        if leasedTransport != nil { return true }
        guard let selected = candidateTransports(lowLatency: lowLatency).first(where: { $0.isAvailable && $0.state == .ready }) else {
            lastError = allTransports.contains { $0.state == .authenticationFailed } ? "Authentication failed" : "No permitted control transport is ready."
            return false
        }
        leasedTransport = selected
        activeTransport = selected.kind
        return true
    }
    func endOrderedSession() { leasedTransport = nil }
    private func abortOrderedSession(reason: String) async {
        leasedTransport = nil
        activeTransport = nil
        for transport in allTransports where transport.isAvailable && transport.state == .ready {
            try? await transport.send(.releaseAll)
        }
        lastError = reason + " Release-all was attempted."
    }
    func supports(_ capability: String) -> Bool { capabilities.contains(capability) }
    func supports(_ event: HIDEvent) -> Bool { requiredCapability(for: event).map { supports($0) } ?? true }
    var unsupportedControlMessages: [String] {
        var messages: [String] = []
        if !supports("mouse_scroll") { messages.append("Scrolling requires firmware 0.6+.") }
        if !supports("mouse_button_state") { messages.append("Drag is not supported by this firmware.") }
        if !supports("keyboard_layout") { messages.append("Keyboard layout mapping is unavailable.") }
        return messages
    }
    var transportReadiness: [(TransportKind, Bool)] { [(.bluetooth, ble.isAvailable), (.tcp, tcp.isAvailable)] }
    var connectionSummary: String {
        if protocolVersion != 2 { return "Firmware must be reflashed" }
        if let activeTransport, transport(for: activeTransport).state == .ready { return "Active \(activeTransport.rawValue)" }
        if let ready = candidateTransports(lowLatency: false).first(where: { $0.state == .ready }) { return "Ready \(ready.kind.rawValue)" }
        if let lastError { return lastError }
        if allTransports.contains(where: { $0.state == .authenticationFailed }) { return "Authentication failed" }
        if allTransports.contains(where: { $0.state == .reconnecting }) { return "Reconnecting…" }
        if allTransports.contains(where: { $0.state == .authenticating }) { return "Authenticating…" }
        if isConnecting || allTransports.contains(where: { [.discovering, .discovered, .connecting, .connected].contains($0.state) }) { return "Connecting…" }
        return "Offline"
    }
    private var allTransports: [HIDControlTransport] { [ble, tcp] }
    private func transport(for kind: TransportKind) -> HIDControlTransport {
        switch kind { case .bluetooth: ble; case .tcp: tcp }
    }
    private func requiredCapability(for event: HIDEvent) -> String? {
        switch event {
        case .mouseMove: "mouse_move"
        case .scroll: "mouse_scroll"
        case .mouseDown, .mouseUp: "mouse_button_state"
        case .click: "mouse_click"
        case .typeText: "keyboard_type"
        case .key, .keyCombo: "keyboard_key"
        case .keyboardReport: "keyboard_layout"
        case .releaseAll: "release_all"
        case .ping: nil
        }
    }
    static func candidateKinds(mode: ConnectionMode, lowLatency: Bool) -> [TransportKind] {
        switch mode {
        case .bluetoothOnly: [.bluetooth]
        case .wifiOnly: [.tcp]
        case .preferBluetooth: [.bluetooth, .tcp]
        case .preferWiFi: [.tcp, .bluetooth]
        case .automatic: lowLatency ? [.bluetooth, .tcp] : [.tcp, .bluetooth]
        }
    }
    private func candidates(for event: HIDEvent) -> [HIDControlTransport] {
        candidateTransports(lowLatency: event.prefersLowLatency)
    }
    private func candidateTransports(lowLatency: Bool) -> [HIDControlTransport] {
        let transports: [TransportKind: HIDControlTransport] = [.bluetooth: ble, .tcp: tcp]
        return Self.candidateKinds(mode: mode, lowLatency: lowLatency).compactMap { kind in
            guard supports(kind == .bluetooth ? "ble_transport" : "wifi_transport") else { return nil }
            return transports[kind]
        }
    }
}

/// Deliberately small, line-oriented DuckyScript subset. Parse before sending any keys.
enum PresetScript {
    enum Step: Equatable { case text(String), key(String), delay(Int) }
    struct ParseError: LocalizedError {
        let line: Int
        let reason: String
        var errorDescription: String? { "Script line \(line): \(reason)" }
    }
    static let modifiers: Set<String> = ["CTRL", "CONTROL", "SHIFT", "ALT", "OPTION", "OPT", "GUI", "WIN", "CMD", "COMMAND", "SUPER", "META"]
    static let keys: Set<String> = Set("ENTER RETURN TAB ESC ESCAPE BACKSPACE BKSP SPACE SPACEBAR DELETE DEL INSERT INS HOME END PAGEUP PGUP PAGEDOWN PGDN RIGHT RIGHTARROW LEFT LEFTARROW DOWN DOWNARROW UP UPARROW CAPSLOCK CAPS PRINTSCREEN PRTSC".split(separator: " ").map(String.init)).union((1...12).map { "F\($0)" })

    static func parse(_ source: String) throws -> [Step] {
        var steps: [Step] = []
        for (index, raw) in source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let bracketed = line.hasPrefix("[")
            if bracketed && !line.hasSuffix("]") { throw ParseError(line: index + 1, reason: "Missing closing bracket.") }
            let command = bracketed ? String(line.dropFirst().dropLast()) : line
            let parts = command.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            let name = parts.first.map(String.init)?.uppercased() ?? ""
            let argument = parts.count > 1 ? String(parts[1]) : ""
            if name == "REM" && !bracketed { continue }
            if name == "STRING" && !bracketed {
                // Preserve spaces after the first command separator, including trailing spaces.
                let content = raw.drop(while: { $0.isWhitespace }).dropFirst(6)
                steps.append(.text(content.isEmpty ? "" : String(content.dropFirst())))
                continue
            }
            if name == "DELAY" {
                let value = argument.trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }), let ms = Int(value), (0...60000).contains(ms) else {
                    throw ParseError(line: index + 1, reason: "DELAY needs 0–60000 milliseconds, e.g. [DELAY 500].")
                }
                steps.append(.delay(ms)); continue
            }
            let tokens = command.uppercased().split(whereSeparator: { $0 == "+" || $0.isWhitespace }).map(String.init)
            if let first = tokens.first, bracketed || keys.contains(first) || modifiers.contains(first) {
                guard let last = tokens.last,
                      tokens.dropLast().allSatisfy({ modifiers.contains($0) }),
                      keys.contains(last) || (tokens.count > 1 && last.count == 1 && last.unicodeScalars.allSatisfy({ (65...90).contains(Int($0.value)) || (48...57).contains(Int($0.value)) })) else {
                    throw ParseError(line: index + 1, reason: "Unknown key or unsupported command. Use STRING for literal text.")
                }
                steps.append(.key(tokens.joined(separator: "+").lowercased()))
            } else {
                steps.append(.text(raw))
            }
        }
        return steps
    }
}

@Model final class HIDPreset {
    var script: Bool = false
    var name: String; var payload: String; var shortcut: Bool; var favorite: Bool; var order: Int; var enterAfter: Bool; var typingDelayMs: Int
    init(name: String, payload: String, shortcut: Bool = false, favorite: Bool = false, order: Int = 0, enterAfter: Bool = false, typingDelayMs: Int = 0, script: Bool = false) { self.script = script; self.name = name; self.payload = payload; self.shortcut = shortcut; self.favorite = favorite; self.order = order; self.enterAfter = enterAfter; self.typingDelayMs = typingDelayMs }
}
struct RecordedEvent: Codable { let offset: TimeInterval; let event: HIDEvent }
@Model final class HIDMacro {
    var name: String; var macroDescription: String = ""; var encodedEvents: Data; var createdAt: Date
    init(name: String, description: String = "", events: [RecordedEvent]) { self.name = name; macroDescription = description; encodedEvents = (try? JSONEncoder().encode(events)) ?? Data(); createdAt = Date() }
    var events: [RecordedEvent] { (try? JSONDecoder().decode([RecordedEvent].self, from: encodedEvents)) ?? [] }
}

@MainActor final class MacroController: ObservableObject {
    @Published var isRecording = false; @Published var isPlaying = false; @Published var recorded: [RecordedEvent] = []
    private var started = Date(); private var playback: Task<Void, Never>?
    var recordingDuration: TimeInterval { isRecording ? Date().timeIntervalSince(started) : 0 }
    func startRecording() { recorded = []; started = Date(); isRecording = true }
    func capture(_ event: HIDEvent) {
        guard isRecording else { return }
        let now = Date().timeIntervalSince(started)
        if case let .mouseMove(x, y) = event, let last = recorded.last,
           now - last.offset <= 0.02, case let .mouseMove(lastX, lastY) = last.event {
            recorded[recorded.count - 1] = RecordedEvent(offset: now, event: .mouseMove(Int16(clamping: Int(lastX) + Int(x)), Int16(clamping: Int(lastY) + Int(y))))
        } else { recorded.append(RecordedEvent(offset: now, event: event)) }
    }
    func stopRecording() { isRecording = false }
    func play(_ macro: HIDMacro, speed: Double, repeats: Int?, delay: Double, manager: HIDConnectionManager) {
        stop(manager: manager); isPlaying = true
        playback = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { self?.isPlaying = false; return }; var iteration = 0
            guard manager.beginOrderedSession(lowLatency: macro.events.first?.event.prefersLowLatency ?? true) else { self?.isPlaying = false; return }
            defer { manager.endOrderedSession() }
            while !Task.isCancelled && (repeats == nil || iteration < repeats!) {
                var previous = 0.0
                for item in macro.events { if Task.isCancelled { break }; do { try await Task.sleep(for: .seconds(max(0, item.offset - previous) / speed)) } catch { break }; guard !Task.isCancelled else { break }; previous = item.offset; if !(await manager.send(item.event)) { self?.isPlaying = false; await manager.releaseAllPreservingError(); return } }
                iteration += 1
            }
            await manager.releaseAll(); self?.isPlaying = false
        }
    }
    func stop(manager: HIDConnectionManager) { playback?.cancel(); playback = nil; isPlaying = false; Task { await manager.releaseAll() } }
}

struct HIDControlView: View {
    @Bindable var device: StoredDevice
    @StateObject private var manager: HIDConnectionManager
    @StateObject private var macros = MacroController()
    @State private var section: ControlSection = .trackpad
    enum ControlSection: String, CaseIterable, Identifiable { case trackpad = "Trackpad", keyboard = "Keyboard", presets = "Presets", macros = "Macros"; var id: Self { self } }
    init(device: StoredDevice) { self.device = device; _manager = StateObject(wrappedValue: HIDConnectionManager(device: device)) }
    var body: some View {
        VStack(spacing: 0) {
            DeviceConnectionBanner(device: device, showsRecoveryActions: false)
                .padding(.horizontal)
                .padding(.bottom, AppTheme.Spacing.compact)
            HStack {
                Label(manager.connectionSummary, systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Picker("Connection", selection: $manager.mode) {
                    ForEach(ConnectionMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
            }
            .padding(.horizontal)
            Picker("Control", selection: $section) { ForEach(ControlSection.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).padding(.horizontal)
            Group { switch section { case .trackpad: TrackpadView(manager: manager); case .keyboard: LiveKeyboardView(manager: manager); case .presets: PresetsView(manager: manager); case .macros: MacrosView(manager: manager, controller: macros) } }
        }
        .navigationTitle(device.displayName).navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { if !manager.unsupportedControlMessages.isEmpty { Text(manager.unsupportedControlMessages.joined(separator: " ")).font(.caption).foregroundStyle(.secondary).padding(.horizontal).accessibilityIdentifier("capability-limitations") } }
        .task { manager.onEvent = { macros.capture($0) }; await manager.connect() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in macros.stop(manager: manager) }
        .onDisappear { Task { macros.stop(manager: manager); await manager.disconnect() } }
    }
}

struct TrackpadView: View {
    @ObservedObject var manager: HIDConnectionManager
    @AppStorage("trackpadSensitivity") private var sensitivity = 1.0
    @AppStorage("trackpadNaturalScrolling") private var naturalScrolling = true
    @AppStorage("trackpadMomentum") private var momentumEnabled = true
    @AppStorage("trackpadHintsSeen") private var hintsSeen = false
    @State private var gestureState: TrackpadGestureState = .idle
    @State private var pointerAccumulator = PointerAccumulator()
    @State private var scrollAccumulator = FractionalAccumulator()
    @State private var zoomAccumulator = FractionalAccumulator()
    @State private var zoomActive = false
    @State private var momentumTask: Task<Void, Never>?
    @State private var showGestureHints = false
    private let coalescer: MouseEventCoalescer
    private let scrollCoalescer: ScrollEventCoalescer
    private var canZoom: Bool { manager.supports("mouse_scroll") && manager.supports("keyboard_layout") }

    init(manager: HIDConnectionManager) {
        self.manager = manager
        coalescer = MouseEventCoalescer { [weak manager] x, y in await manager?.send(.mouseMove(x, y)) }
        scrollCoalescer = ScrollEventCoalescer { [weak manager] value in await manager?.send(.scroll(value)) }
    }

    var body: some View {
        VStack {
            trackpad
            HStack { Button("Left") { Task { await manager.send(.click(.left)) } }; Button("Middle") { Task { await manager.send(.click(.middle)) } }; Button("Right") { Task { await manager.send(.click(.right)) } } }
                .buttonStyle(.borderedProminent)
                .disabled(!manager.supports("mouse_click"))
            VStack(spacing: AppTheme.Spacing.compact) {
                HStack { Text("Sensitivity"); Slider(value: $sensitivity, in: 0.4...2.5) }
                Toggle("Natural Scrolling", isOn: $naturalScrolling)
                Toggle("Momentum Scrolling", isOn: $momentumEnabled)
            }
            .padding(.horizontal)
            .padding(.bottom)
            if !hintsSeen {
                Label("Tap the ? on the trackpad for gesture help.", systemImage: "hand.tap")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear { stopMomentum() }
        .onChange(of: manager.lastError) { _, error in if error != nil { recoverFromError() } }
    }

    private var trackpad: some View {
        TrackpadInputBridge(
            move: { x, y in
                guard manager.supports("mouse_move") else { return }
                stopMomentum()
                if gestureState != .moving && gestureState != .dragging { gestureState = .moving }
                let scaled = pointerAccumulator.add(dx: Double(x) * sensitivity, dy: Double(y) * sensitivity)
                guard scaled.x != 0 || scaled.y != 0 else { return }
                Task { await coalescer.add(x: scaled.x, y: scaled.y) }
            },
            moveEnded: { if gestureState == .moving { gestureState = .idle } },
            scroll: { value in
                guard manager.supports("mouse_scroll") else { return }
                stopMomentum()
                if gestureState != .dragging { gestureState = .scrolling }
                let lines = scrollAccumulator.add(TrackpadGestures.scrollContribution(panDeltaY: value, natural: naturalScrolling))
                guard lines != 0 else { return }
                Task { await scrollCoalescer.add(lines) }
            },
            scrollEnded: { velocity in
                let residue = scrollAccumulator.flush()
                if residue != 0 { Task { await scrollCoalescer.add(residue) } }
                if gestureState == .scrolling { gestureState = .idle }
                startMomentum(velocityY: velocity)
            },
            click: { count in
                guard manager.supports("mouse_click") else { return }
                stopMomentum()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                Task { for _ in 0..<count { await manager.send(.click(.left)) } }
            },
            drag: { active in
                guard manager.supports("mouse_button_state") else { return }
                stopMomentum()
                if active {
                    guard manager.beginOrderedSession(lowLatency: true) else { return }
                    gestureState = .dragging
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    Task {
                        guard await manager.send(.mouseDown(.left)) else {
                            gestureState = .idle
                            manager.endOrderedSession()
                            await manager.releaseAllPreservingError()
                            return
                        }
                    }
                } else {
                    if gestureState == .dragging { gestureState = .idle }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    Task {
                        // Deliver queued pointer movement before the button
                        // lifts so the drop lands where the finger stopped.
                        await coalescer.flush()
                        let sent = await manager.send(.mouseUp(.left))
                        manager.endOrderedSession()
                        if !sent { await manager.releaseAllPreservingError() }
                    }
                }
            },
            rightClick: {
                guard manager.supports("mouse_click") else { return }
                stopMomentum()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                Task { await manager.send(.click(.right)) }
            },
            middleClick: {
                guard manager.supports("mouse_click") else { return }
                stopMomentum()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                Task { await manager.send(.click(.middle)) }
            },
            zoom: { change in
                guard canZoom else { return }
                stopMomentum()
                hintsSeen = true
                if !zoomActive {
                    guard manager.beginOrderedSession(lowLatency: true) else { return }
                    zoomActive = true
                    zoomAccumulator.reset()
                    gestureState = .zooming
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    Task { await manager.send(.keyboardReport(modifiers: HIDModifiers.ctrl, usage: 0)) }
                }
                let lines = zoomAccumulator.add(TrackpadGestures.zoomContribution(scaleChange: change))
                guard lines != 0 else { return }
                Task { await scrollCoalescer.add(lines) }
            },
            zoomEnded: { cancelled in
                guard zoomActive else { return }
                zoomActive = false
                let residue = zoomAccumulator.flush()
                if gestureState == .zooming { gestureState = .idle }
                Task {
                    // Flush every remaining zoom line first so the Ctrl key
                    // can never be released while wheel lines are in flight.
                    if residue != 0 { await scrollCoalescer.add(residue) }
                    await scrollCoalescer.flush()
                    await manager.send(.keyboardReport(modifiers: HIDModifiers.none, usage: 0))
                    manager.endOrderedSession()
                    if cancelled { await manager.releaseAll() }
                }
            },
            cancel: {
                stopMomentum()
                let wasZooming = zoomActive
                zoomActive = false
                gestureState = .idle
                pointerAccumulator.reset()
                scrollAccumulator.reset()
                zoomAccumulator.reset()
                Task {
                    if wasZooming { await manager.send(.keyboardReport(modifiers: HIDModifiers.none, usage: 0)) }
                    await coalescer.cancel()
                    await scrollCoalescer.cancel()
                    manager.endOrderedSession()
                    await manager.releaseAll()
                }
            }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Remote trackpad")
        .accessibilityValue(gestureState.overlayTitle)
        .overlay {
            Text(gestureState.overlayTitle)
                .foregroundStyle(.secondary)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .topTrailing) { hintsButton }
        .popover(isPresented: $showGestureHints) { gestureHints }
        .padding()
    }

    private var hintsButton: some View {
        Button {
            showGestureHints = true
            hintsSeen = true
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(8)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .padding(6)
        .accessibilityLabel("Trackpad gesture help")
    }

    private var gestureHints: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
            Text("Trackpad Gestures").font(.headline)
            Label("One finger moves the pointer.", systemImage: "hand.point.up.left")
            Label("Tap or double-tap to click.", systemImage: "hand.tap")
            Label("Two fingers scroll.", systemImage: "arrow.up.arrow.down")
            Label("Pinch with two fingers to zoom.", systemImage: "arrow.up.left.and.arrow.down.right")
            Label("Hold, then move to drag.", systemImage: "hand.press")
            Label("Hold and release without moving to right-click.", systemImage: "cursorarrow.rays")
            Label("Tap with two fingers to right-click, with three for a middle click.", systemImage: "hand.tap.fill")
            if !canZoom {
                Label("Zoom needs mouse_scroll and keyboard_layout firmware support.", systemImage: "info.circle")
            }
        }
        .font(.subheadline)
        .padding()
        .frame(maxWidth: 320, alignment: .leading)
        .presentationCompactAdaptation(.popover)
    }

    private func startMomentum(velocityY: CGFloat) {
        guard momentumEnabled else { return }
        var generator = MomentumGenerator(velocity: velocityY, natural: naturalScrolling)
        guard !generator.isFinished else { return }
        let coalescer = scrollCoalescer
        momentumTask?.cancel()
        momentumTask = Task {
            while !Task.isCancelled, !generator.isFinished {
                let lines = generator.nextLine()
                if lines != 0 { await coalescer.add(lines) }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func stopMomentum() {
        momentumTask?.cancel()
        momentumTask = nil
    }

    private func recoverFromError() {
        stopMomentum()
        let wasZooming = zoomActive
        zoomActive = false
        gestureState = .idle
        pointerAccumulator.reset()
        scrollAccumulator.reset()
        zoomAccumulator.reset()
        Task {
            if wasZooming { await manager.send(.keyboardReport(modifiers: HIDModifiers.none, usage: 0)) }
            await coalescer.cancel()
            await scrollCoalescer.cancel()
            manager.endOrderedSession()
            await manager.releaseAll()
        }
    }
}

struct LiveKeyboardView: View {
    @ObservedObject var manager: HIDConnectionManager; @AppStorage("keyboardLayout") private var layoutName = KeyboardLayout.german.rawValue
    @State private var modifiers: UInt8 = 0
    let keys = ["esc", "tab", "enter", "backspace", "delete", "home", "end", "pageup", "pagedown", "left", "up", "down", "right"]
    private var layout: KeyboardLayout { KeyboardLayout(rawValue: layoutName) ?? .german }
    var body: some View { ScrollView { VStack(spacing: 12) { Picker("Layout", selection: $layoutName) { ForEach(KeyboardLayout.allCases) { Text($0.rawValue).tag($0.rawValue) } }.pickerStyle(.segmented).disabled(!manager.supports("keyboard_layout")); KeyboardInputBridge { event in Task { switch event { case let .insert(text):
                    if modifiers == 0 { await manager.sendText(text, layout: layout) }
                    else if let strokes = try? layout.strokes(for: text), let first = strokes.first { let oneShot = modifiers; modifiers = 0; guard await manager.send(.keyboardReport(modifiers: first.modifiers | oneShot, usage: first.usage)) else { return }; for stroke in strokes.dropFirst() { guard await manager.send(.keyboardReport(modifiers: stroke.modifiers, usage: stroke.usage)) else { return } } }
                case .deleteBackward: await manager.send(.key("backspace")) } } }.disabled(!manager.supports("keyboard_layout")).frame(minHeight: 90).padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 12));
            HStack { modifierButton("Ctrl", 0x01); modifierButton("Shift", 0x02); modifierButton("Alt", 0x04); modifierButton("Win/Cmd", 0x08) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 82))]) { ForEach(keys, id: \.self) { key in Button(key.capitalized) { UIImpactFeedbackGenerator(style: .light).impactOccurred(); let prefix = modifierNames; modifiers = 0; Task { await manager.send(prefix.isEmpty ? .key(key) : .keyCombo((prefix + [key]).joined(separator: "+"))) } }.buttonStyle(.bordered) } }; Text("Shortcuts").font(.headline); HStack { ForEach(["ctrl+c", "ctrl+v", "ctrl+x", "ctrl+z", "ctrl+shift+z", "ctrl+a", "ctrl+f", "alt+tab", "ctrl+shift+t", "cmd+space"], id: \.self) { combo in Button(combo) { Task { await manager.send(.keyCombo(combo)) } } }.buttonStyle(.borderedProminent) }.padding() } }
    }
    private var modifierNames: [String] { let values: [(UInt8, String)] = [(0x01, "ctrl"), (0x02, "shift"), (0x04, "alt"), (0x08, "cmd")]; return values.compactMap { modifiers & $0.0 == 0 ? nil : $0.1 } }
    private func modifierButton(_ title: String, _ bit: UInt8) -> some View { Button(title) { modifiers ^= bit }.buttonStyle(.borderedProminent).tint(modifiers & bit == 0 ? .gray : .accentColor).accessibilityValue(modifiers & bit == 0 ? "Off" : "One shot") }
}

struct PresetsView: View {
    @ObservedObject var manager: HIDConnectionManager; @Environment(\.modelContext) private var context; @Query(sort: \HIDPreset.order) private var presets: [HIDPreset]; @State private var name = ""; @State private var payload = ""; @State private var shortcut = false; @State private var script = false; @State private var execution: Task<Void, Never>?; @State private var favorite = false; @State private var enterAfter = false; @State private var typingDelayMs = 0; @AppStorage("keyboardLayout") private var layoutName = KeyboardLayout.german.rawValue
    var body: some View { NavigationStack { List { if let error = manager.lastError { Section("Execution error") { Text(error).foregroundStyle(.red) } }; Section("New preset") { TextField("Name", text: $name); TextField("Text or shortcut", text: $payload, axis: .vertical); Picker("Type", selection: $shortcut) { Text("Text").tag(false); Text("Keyboard Shortcut").tag(true) }; Toggle("Script (keys, text & delays)", isOn: $script).disabled(shortcut); Text("Script: [TAB], [ENTER], [CTRL+A], [DELAY 500] or DuckyScript TAB, STRING text, DELAY 500. One action per line.").font(.caption).foregroundStyle(.secondary); Toggle("Favorite", isOn: $favorite); Toggle("Enter after", isOn: $enterAfter).disabled(shortcut); Picker("Typing speed", selection: $typingDelayMs) { ForEach([0,10,25,50,100], id: \.self) { Text($0 == 0 ? "Fast" : "\($0) ms").tag($0) } }.disabled(shortcut); Button("Add Preset") { context.insert(HIDPreset(name: name.isEmpty ? "Preset" : name, payload: payload, shortcut: shortcut, favorite: favorite, order: presets.count, enterAfter: enterAfter, typingDelayMs: typingDelayMs, script: script)); name = ""; payload = ""; shortcut = false; script = false; favorite = false; enterAfter = false; typingDelayMs = 0 } }; Section("Presets") { ForEach(presets) { preset in VStack(alignment: .leading, spacing: 8) { HStack { Button { preset.favorite.toggle() } label: { Image(systemName: preset.favorite ? "star.fill" : "star") }.buttonStyle(.borderless); TextField("Name", text: Binding(get: { preset.name }, set: { preset.name = $0 })); Spacer(); Button("Run") { run(preset) }.buttonStyle(.borderedProminent).disabled(execution != nil) }; TextField("Content", text: Binding(get: { preset.payload }, set: { preset.payload = $0 }), axis: .vertical).font(.caption); Toggle("Shortcut", isOn: Binding(get: { preset.shortcut }, set: { preset.shortcut = $0 })); Toggle("Script", isOn: Binding(get: { preset.script }, set: { preset.script = $0 })).disabled(preset.shortcut); Toggle("Enter after", isOn: Binding(get: { preset.enterAfter }, set: { preset.enterAfter = $0 })); Picker("Typing speed", selection: Binding(get: { preset.typingDelayMs }, set: { preset.typingDelayMs = $0 })) { ForEach([0,10,25,50,100], id: \.self) { Text($0 == 0 ? "Fast" : "\($0) ms").tag($0) } }.disabled(preset.shortcut) }.buttonStyle(.borderless).swipeActions { Button(role: .destructive) { context.delete(preset) } label: { Label("Delete", systemImage: "trash") }; Button { context.insert(HIDPreset(name: preset.name + " Copy", payload: preset.payload, shortcut: preset.shortcut, favorite: preset.favorite, order: presets.count, enterAfter: preset.enterAfter, typingDelayMs: preset.typingDelayMs, script: preset.script)) } label: { Label("Duplicate", systemImage: "plus.square.on.square") } } }.onMove { source, destination in var ordered = presets; ordered.move(fromOffsets: source, toOffset: destination); for (index, item) in ordered.enumerated() { item.order = index } } } }.toolbar { EditButton(); if execution != nil { Button("Stop") { execution?.cancel() } } }.onDisappear { execution?.cancel() } } }
    private func run(_ preset: HIDPreset) {
        guard execution == nil else { return }
        let layout = KeyboardLayout(rawValue: layoutName) ?? .german
        let delay = max(0, preset.typingDelayMs)
        let steps: [PresetScript.Step]
        do {
            if preset.shortcut { steps = [.key(preset.payload)] }
            else if preset.script { steps = try PresetScript.parse(preset.payload) }
            else { steps = [.text(preset.payload)] }
            // Reject unsupported characters before partially filling a form.
            for step in steps { if case let .text(text) = step { _ = try layout.strokes(for: text) } }
        } catch { manager.lastError = error.localizedDescription; return }
        let enterAfter = preset.enterAfter
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        execution = Task { @MainActor in
            defer { execution = nil }
            guard manager.beginOrderedSession(lowLatency: false) else { return }
            defer { manager.endOrderedSession() }
            do {
                for step in steps {
                    try Task.checkCancellation()
                    let sent: Bool
                    switch step {
                    case let .text(text): sent = await manager.sendText(text, layout: layout, delayMilliseconds: delay)
                    case let .key(key): sent = await manager.send(.keyCombo(key))
                    case let .delay(ms): try await Task.sleep(for: .milliseconds(ms)); continue
                    }
                    guard sent else { await manager.releaseAllPreservingError(); return }
                    try await Task.sleep(for: .milliseconds(50))
                }
                try Task.checkCancellation()
                if enterAfter { _ = await manager.send(.key("enter")) }
            } catch is CancellationError {
                await manager.releaseAllPreservingError()
            } catch {
                manager.lastError = error.localizedDescription
                await manager.releaseAllPreservingError()
            }
        }
    }
}

struct MacrosView: View {
    @ObservedObject var manager: HIDConnectionManager; @ObservedObject var controller: MacroController; @Environment(\.modelContext) private var context; @Query(sort: \HIDMacro.createdAt, order: .reverse) private var saved: [HIDMacro]; @State private var speed = 1.0; @State private var repeatCount = 1; @State private var delay = 0; @State private var showSave = false; @State private var macroName = ""; @State private var macroDescription = ""
    var body: some View { VStack { if controller.isPlaying { Button("STOP", role: .destructive) { UINotificationFeedbackGenerator().notificationOccurred(.warning); controller.stop(manager: manager) }.buttonStyle(.borderedProminent).tint(AppColors.destructive).controlSize(.large) }; HStack { Button(controller.isRecording ? "Stop & Save" : "Record") { if controller.isRecording { controller.stopRecording(); macroName = "Macro \(saved.count + 1)"; showSave = true; UIImpactFeedbackGenerator(style: .medium).impactOccurred() } else { controller.startRecording(); UIImpactFeedbackGenerator(style: .medium).impactOccurred() } }.buttonStyle(.borderedProminent); if controller.isRecording { Button("Cancel", role: .cancel) { controller.stopRecording(); controller.recorded = [] } }; TimelineView(.periodic(from: .now, by: 1)) { _ in Text(recordingStatus) } }; Form { Picker("Speed", selection: $speed) { ForEach([0.5, 1, 1.5, 2], id: \.self) { Text("\($0, specifier: "%g")×").tag($0) } }; Picker("Repeat", selection: $repeatCount) { ForEach([1, 2, 5, 10, 0], id: \.self) { Text($0 == 0 ? "Infinite" : "\($0)×").tag($0) } }; Picker("Start delay", selection: $delay) { ForEach([0, 3, 5, 10], id: \.self) { Text("\($0) s").tag($0) } }; Section("Saved") { ForEach(saved) { macro in HStack { VStack(alignment: .leading) { TextField("Name", text: Binding(get: { macro.name }, set: { macro.name = $0 })); Text("\(macro.events.count) events").font(.caption) }; Spacer(); Button("Play") { UIImpactFeedbackGenerator(style: .medium).impactOccurred(); controller.play(macro, speed: speed, repeats: repeatCount == 0 ? nil : repeatCount, delay: Double(delay), manager: manager) } }.swipeActions { Button(role: .destructive) { context.delete(macro) } label: { Label("Delete", systemImage: "trash") }; Button { context.insert(HIDMacro(name: macro.name + " Copy", description: macro.macroDescription, events: macro.events)) } label: { Label("Duplicate", systemImage: "plus.square.on.square") } } } } } } .alert("Save Macro", isPresented: $showSave) { TextField("Name", text: $macroName); TextField("Description (optional)", text: $macroDescription); Button("Save") { context.insert(HIDMacro(name: macroName.isEmpty ? "Macro" : macroName, description: macroDescription, events: controller.recorded)); controller.recorded = [] }; Button("Cancel", role: .cancel) { controller.recorded = [] } } }
    private var recordingStatus: String { guard controller.isRecording else { return "\(controller.recorded.count) events" }; let seconds = Int(controller.recordingDuration); return String(format: "🔴 Recording · %02d:%02d · %d events", seconds / 60, seconds % 60, controller.recorded.count) }
}
