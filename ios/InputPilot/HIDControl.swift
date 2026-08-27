import CoreBluetooth
import CryptoKit
import Foundation
import Network
import OSLog
import SwiftData
import SwiftUI
import UIKit

enum AppLogCategory: String, CaseIterable, Identifiable { case all = "All", input = "Input", control = "Control", bluetooth = "Bluetooth", tcp = "TCP", rest = "REST", diagnostics = "Diagnostics", errors = "Errors"; var id: String { rawValue } }
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
    var restPath: String {
        switch self {
        case .mouseMove, .scroll: "api/move"
        case .click: "api/click"
        case .mouseDown, .mouseUp: "api/button"
        case .typeText: "api/type"
        case .key, .keyCombo: "api/key"
        case .keyboardReport: "api/report"
        case .releaseAll: "api/release-all"
        case .ping: "api/status"
        }
    }
}

enum ConnectionMode: String, CaseIterable, Codable, Identifiable {
    case automatic = "Automatic", preferBluetooth = "Prefer Bluetooth", preferWiFi = "Prefer Wi-Fi"
    case bluetoothOnly = "Bluetooth Only", wifiOnly = "Wi-Fi Only"
    var id: String { rawValue }
}
enum TransportKind: String { case bluetooth = "Bluetooth", tcp = "Wi-Fi TCP", rest = "REST" }
enum TransportConnectionState: String, Equatable {
    case offline, connecting, reconnecting, authenticating, ready, authenticationFailed
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

final class RESTHIDControlTransport: HIDControlTransport {
    let kind = TransportKind.rest
    private(set) var isAvailable = false
    private(set) var state: TransportConnectionState = .offline
    private let baseURL: URL; private let token: String?; private let session: URLSession
    init(baseURL: URL, token: String?, session: URLSession = .shared) { self.baseURL = baseURL; self.token = token; self.session = session }
    func connect() async { state = .connecting; do { try await send(.ping); isAvailable = true; state = .ready } catch { isAvailable = false; if state != .authenticationFailed { state = .offline } } }
    func disconnect() async { isAvailable = false; state = .offline }
    func send(_ event: HIDEvent) async throws {
        let eid = AppLogContext.eventID.map(String.init) ?? "-"; appLog(.rest, "id=\(eid) request=\(event.restPath) event=\(event.diagnosticName)")
        let body: [String: Any]
        switch event {
        case let .mouseMove(x, y): body = ["dx": x, "dy": y]
        case let .scroll(v): body = ["dx": 0, "dy": 0, "wheel": v]
        case let .click(b): body = ["button": String(describing: b)]
        case let .mouseDown(b): body = ["button": String(describing: b), "state": "down"]
        case let .mouseUp(b): body = ["button": String(describing: b), "state": "up"]
        case let .typeText(text): body = ["text": text]
        case let .key(key), let .keyCombo(key): body = ["key": key]
        case let .keyboardReport(modifiers, usage): body = ["modifiers": modifiers, "usage": usage]
        case .releaseAll, .ping: body = [:]
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(event.restPath)); request.httpMethod = event == .ping ? "GET" : "POST"
        if request.httpMethod == "POST" { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token, !token.isEmpty { request.setValue(token, forHTTPHeaderField: "X-API-Token") }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { isAvailable = false; state = .offline; throw TransportError.failed("Invalid REST response") }
        guard (200...299).contains(http.statusCode) else { appLog(.errors, "REST id=\(eid) HTTP \(http.statusCode)"); isAvailable = false; state = http.statusCode == 401 ? .authenticationFailed : .offline; throw TransportError.failed(http.statusCode == 401 ? "Authentication failed" : "REST request failed (HTTP \(http.statusCode))") }
        appLog(.rest, "id=\(eid) delivered HTTP \(http.statusCode)")
        isAvailable = true; state = .ready
    }
}

final class TCPHIDControlTransport: HIDControlTransport {
    let kind = TransportKind.tcp
    private let host: NWEndpoint.Host; private let token: String?; private var connection: NWConnection?
    private(set) var isAvailable = false
    private(set) var state: TransportConnectionState = .offline
    private var shouldReconnect = false
    private var receiveBuffer = Data()
    private var receiving = false
    private var authTimeoutWork: DispatchWorkItem?
    private let authTimeout: TimeInterval
    init(host: String, token: String?, authTimeout: TimeInterval = 4) { self.host = NWEndpoint.Host(host); self.token = token; self.authTimeout = authTimeout }
    func connect() async {
        shouldReconnect = true
        if connection != nil { return }
        state = state == .offline ? .connecting : .reconnecting
        let conn = NWConnection(host: host, port: 3333, using: .tcp); connection = conn
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn, self.connection === conn else { return }
            switch state {
            case .ready:
                self.startReceiveLoop(on: conn)
                if let token = self.token, !token.isEmpty {
                    self.state = .authenticating
                    guard !token.contains("\n"), !token.contains("\r") else { self.isAvailable = false; self.state = .authenticationFailed; conn.cancel(); return }
                    self.startAuthTimeout(for: conn)
                    conn.send(content: Data("auth \(token)\n".utf8), completion: .contentProcessed { [weak self, weak conn] error in
                        guard let self, let conn, self.connection === conn, let error else { return }
                        self.failConnection(error.localizedDescription, on: conn)
                    })
                } else { self.isAvailable = true; self.state = .ready }
            case .failed, .cancelled:
                self.authTimeoutWork?.cancel(); self.authTimeoutWork = nil; self.receiving = false; self.receiveBuffer.removeAll(); self.isAvailable = false; self.connection = nil
                let authFailed = self.state == .authenticationFailed
                self.state = authFailed ? .authenticationFailed : (self.shouldReconnect ? .reconnecting : .offline)
                if self.shouldReconnect && !authFailed { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in Task { await self?.connect() } } }
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
        switch reply.lowercased() {
        case "auth ok" where state == .authenticating:
            authTimeoutWork?.cancel(); authTimeoutWork = nil; isAvailable = true; state = .ready
        case "auth failed" where state == .authenticating:
            failAuthentication(on: conn)
        case "pong": break
        default:
            if reply.lowercased().hasPrefix("error") { lastProtocolError = reply }
        }
    }
    private var lastProtocolError: String?
    private func startAuthTimeout(for conn: NWConnection) {
        authTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak conn] in guard let self, let conn, self.connection === conn, self.state == .authenticating else { return }; self.failAuthentication(on: conn) }
        authTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + authTimeout, execute: work)
    }
    private func failAuthentication(on conn: NWConnection) { authTimeoutWork?.cancel(); authTimeoutWork = nil; isAvailable = false; state = .authenticationFailed; receiving = false; conn.cancel() }
    private func failConnection(_ message: String, on conn: NWConnection) { lastProtocolError = message; isAvailable = false; receiving = false; conn.cancel() }
    private func sendLine(_ line: String) async throws {
        guard let connection else { throw TransportError.unavailable }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data((line + "\n").utf8), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    func send(_ event: HIDEvent) async throws {
        guard isAvailable else { throw TransportError.unavailable }
        let eid = AppLogContext.eventID.map(String.init) ?? "-"; appLog(.tcp, "id=\(eid) send event=\(event.diagnosticName)")
        do { try await sendLine(event.line); appLog(.tcp, "id=\(eid) delivered") } catch { appLog(.errors, "TCP id=\(eid) error=\(error.localizedDescription)"); isAvailable = false; state = .reconnecting; connection?.cancel(); throw error }
    }
    func disconnect() async { shouldReconnect = false; authTimeoutWork?.cancel(); authTimeoutWork = nil; receiving = false; connection?.cancel(); connection = nil; receiveBuffer.removeAll(); isAvailable = false; state = .offline }
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

    enum CodingKeys: String, CodingKey { case product, version, board, otaSchema, size, sha256; case protocolVersion = "protocol" }
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
            guard protocolVersion == 1 else { throw FirmwareValidationError.unsupportedProtocol }
            guard otaSchema <= 1 else { throw FirmwareValidationError.unsupportedSchema }
            return Self(product: product, board: board, version: version, protocolVersion: protocolVersion, otaSchema: otaSchema)
        }
        throw FirmwareValidationError.missingMetadata
    }
}

struct BLEDeviceMetadata: Codable, Equatable {
    let product: String; let board: String; let deviceId: String; let deviceName: String
    let firmware: String; let protocolVersion: Int; let otaSchema: Int; let capabilities: [String]; let authRequired: Bool
    enum CodingKeys: String, CodingKey { case product, board, deviceId, deviceName, firmware, otaSchema, capabilities, authRequired; case protocolVersion = "protocol" }
}

struct BLEDiscoveredDevice: Identifiable, Equatable {
    let id: UUID; let deviceId: String; let name: String; let rssi: Int
}

final class BLEDeviceDiscoveryManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published private(set) var devices: [BLEDiscoveredDevice] = []
    @Published private(set) var isScanning = false
    @Published private(set) var errorMessage: String?
    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var selected: CBPeripheral?
    private var completion: ((Result<BLEDeviceMetadata, Error>) -> Void)?
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
        return try await withCheckedThrowingContinuation { continuation in
            completion = { continuation.resume(with: $0) }
            central.connect(peripheral)
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak peripheral] in
                guard let self, self.completion != nil else { return }
                self.finish(.failure(TransportError.failed("Bluetooth metadata request timed out.")))
                if let peripheral { self.central.cancelPeripheralConnection(peripheral) }
            }
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
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) { finish(.failure(error ?? TransportError.unavailable)) }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == otaService }) else { finish(.failure(error ?? TransportError.failed("InputPilot metadata service not found."))); return }
        peripheral.discoverCharacteristics([otaStatus], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let status = service.characteristics?.first(where: { $0.uuid == otaStatus }) else { finish(.failure(error ?? TransportError.failed("InputPilot metadata not available."))); return }
        peripheral.readValue(for: status)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == otaStatus else { return }
        if let error { finish(.failure(error)); return }
        guard let value = characteristic.value, let metadata = try? JSONDecoder().decode(BLEDeviceMetadata.self, from: value), metadata.product == "InputPilot", metadata.board == "esp32-s3-zero-4mb" else {
            finish(.failure(TransportError.failed("Invalid InputPilot Bluetooth metadata."))); return
        }
        finish(.success(metadata))
    }
    private func finish(_ result: Result<BLEDeviceMetadata, Error>) {
        let callback = completion; completion = nil; callback?(result)
        if let selected { central.cancelPeripheralConnection(selected) }; selected = nil
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
    struct HIDCounters: Codable, Equatable { let rxBle: UInt64?; let rxTcp: UInt64?; let rxRest: UInt64?; let rxSerial: UInt64?; let decoded: UInt64?; let decodeErrors: UInt64?; let queued: UInt64?; let queueRejected: UInt64?; let executed: UInt64?; let failed: UInt64?; let mouseExecuted: UInt64?; let keyboardExecuted: UInt64?; let lastSource: String?; let lastType: String?; let lastSequence: UInt64? }
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
    let hid: HIDCounters?
    enum CodingKeys: String, CodingKey {
        case product, firmware, board, protocolVersion = "protocol", otaSchema, deviceId
        case runningPartition, bootPartition, uptime, heap, firmwareCommit, resetReason, hid
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

@MainActor final class FirmwareDiagnosticsManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published private(set) var lines: [FirmwareLogLine] = []
    @Published private(set) var status = "Connecting…"
    @Published private(set) var metadata: DiagnosticsMetadata?
    @Published var paused = false
    private let deviceId: String; private let mdnsHost: String; private let staIP: String?; private let token: String?
    private let mode: ConnectionMode; private let deviceCapabilities: Set<String>
    private var history = FirmwareLogHistory(); private var sequenceHistory = FirmwareLogSequenceHistory(); private var pending: [FirmwareLogRecord] = []
    private var central: CBCentralManager!; private var peripheral: CBPeripheral?; private var logCharacteristic: CBCharacteristic?
    private var fallbackTask: Task<Void, Never>?; private var pollTask: Task<Void, Never>?
    private var bluetoothScanEnabled = false
    private let service = CBUUID(string: "7D9F2001-4F4D-4F56-4552-484944000001")
    private let info = CBUUID(string: "7D9F2002-4F4D-4F56-4552-484944000001")
    private let log = CBUUID(string: "7D9F2003-4F4D-4F56-4552-484944000001")
    private var allowsBluetooth: Bool { mode != .wifiOnly && (deviceCapabilities.isEmpty || deviceCapabilities.contains("ble_diagnostics")) }
    init(device: StoredDevice, mode: ConnectionMode = .automatic) { deviceId = device.deviceId.lowercased(); mdnsHost = device.mdnsHost; staIP = device.staIP; token = device.apiToken; self.mode = mode; deviceCapabilities = Set(device.capabilities); super.init(); central = CBCentralManager(delegate: self, queue: .main) }
    func start() {
        let wifi = !DeviceEndpointResolver.endpointURLs(mdnsHost: mdnsHost, staIP: staIP).isEmpty && deviceCapabilities.contains("wifi_diagnostics")
        let ble = deviceCapabilities.isEmpty || deviceCapabilities.contains("ble_diagnostics")
        let order = FirmwareUpdateManager.transportOrder(mode: mode, wifiAvailable: wifi, bluetoothAvailable: ble)
        bluetoothScanEnabled = order.first == .bluetooth
        if order.first == .wifi { Task { await startRESTFallback() } }
        else if bluetoothScanEnabled, central.state == .poweredOn { scan() }
        if order.dropFirst().contains(.wifi) { fallbackTask = Task { [weak self] in try? await Task.sleep(for: .seconds(6)); guard !Task.isCancelled else { return }; await self?.startRESTFallback() } }
    }
    func stop() {
        fallbackTask?.cancel(); pollTask?.cancel(); central.stopScan()
        if let peripheral, let logCharacteristic, logCharacteristic.isNotifying { peripheral.setNotifyValue(false, for: logCharacteristic) }
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        self.peripheral = nil; logCharacteristic = nil
    }
    func clear() { history.clear(); sequenceHistory.clear(); pending.removeAll(); lines = [] }
    func setPaused(_ value: Bool) { paused = value; if !value, !pending.isEmpty { history.append(sequenceHistory.append(pending)); pending.removeAll(); lines = history.lines } }
    func centralManagerDidUpdateState(_ central: CBCentralManager) { if central.state == .poweredOn, allowsBluetooth, bluetoothScanEnabled { scan() } else if central.state != .poweredOn && mode == .bluetoothOnly { status = "Bluetooth unavailable" } }
    private func scan() {
        guard !central.isScanning, peripheral == nil else { return }
        status = "Searching via Bluetooth…"
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        appLog(.bluetooth, "scan started deviceId=\(deviceId)")
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        guard BLEDeviceDiscoveryManager.advertisement(advertisementData, matches: deviceId) else { return }
        self.peripheral = peripheral; central.stopScan(); central.connect(peripheral)
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) { status = "Live via Bluetooth"; fallbackTask?.cancel(); pollTask?.cancel(); peripheral.delegate = self; peripheral.discoverServices([service]) }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) { self.peripheral = nil; scheduleReconnectAndFallback() }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) { status = "Bluetooth disconnected"; self.peripheral = nil; logCharacteristic = nil; scheduleReconnectAndFallback() }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == service }) else { Task { await startRESTFallback() }; return }
        peripheral.discoverCharacteristics([info, log], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { return }
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == info { peripheral.readValue(for: characteristic) }
            if characteristic.uuid == log { logCharacteristic = characteristic; peripheral.setNotifyValue(true, for: characteristic) }
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { appLog(.errors, "BLE diagnostics read error=\(error?.localizedDescription ?? "empty value")"); return }
        if characteristic.uuid == info {
            metadata = try? JSONDecoder().decode(DiagnosticsMetadata.self, from: data)
            if metadata == nil { appLog(.errors, "BLE diagnostics JSON decode failed") }
        } else if characteristic.uuid == log {
            if let record = try? JSONDecoder().decode(FirmwareLogRecord.self, from: data) { receive([record]) }
            else if let line = String(data: data, encoding: .utf8), !line.isEmpty {
                let sequence = (sequenceHistory.records.last?.sequence ?? 0) &+ 1; receive([FirmwareLogRecord(sequence: sequence, line: line)])
                appLog(.diagnostics, "BLE plain log fallback used sequence=\(sequence)")
            } else { appLog(.errors, "BLE diagnostics log decode failed") }
        }
    }
    private func receive(_ incoming: [FirmwareLogRecord]) { if paused { pending.append(contentsOf: incoming); if pending.count > FirmwareLogSequenceHistory.capacity { pending.removeFirst(pending.count - FirmwareLogSequenceHistory.capacity) } } else { history.append(sequenceHistory.append(incoming)); lines = history.lines } }
    private func scheduleReconnectAndFallback() {
        if central.state == .poweredOn, allowsBluetooth { scan() }
        fallbackTask?.cancel(); fallbackTask = Task { [weak self] in try? await Task.sleep(for: .seconds(6)); guard !Task.isCancelled else { return }; await self?.startRESTFallback() }
    }
    private func startRESTFallback() async {
        guard peripheral == nil, pollTask == nil else { return }
        let endpoints = DeviceEndpointResolver.endpointURLs(mdnsHost: mdnsHost, staIP: staIP)
        guard !endpoints.isEmpty else { status = "No diagnostics transport available"; return }
        status = "Connecting via Wi-Fi…"
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                var loaded = false
                for base in endpoints where !loaded {
                    do { var request = URLRequest(url: base.appendingPathComponent("api/logs")); if let token, !token.isEmpty { request.setValue(token, forHTTPHeaderField: "X-API-Token") }; let (data, response) = try await URLSession.shared.data(for: request); let code = (response as? HTTPURLResponse)?.statusCode ?? 0; guard code == 200 else { appLog(.errors, "REST logs HTTP \(code)"); continue }; let decoded = try JSONDecoder().decode(FirmwareLogsResponse.self, from: data); self.receive(decoded.entries); var infoRequest = URLRequest(url: base.appendingPathComponent("api/diagnostics")); if let token, !token.isEmpty { infoRequest.setValue(token, forHTTPHeaderField: "X-API-Token") }; if let (infoData, _) = try? await URLSession.shared.data(for: infoRequest) { self.metadata = try? JSONDecoder().decode(DiagnosticsMetadata.self, from: infoData); if self.metadata == nil { appLog(.errors, "REST diagnostics JSON decode failed") } }; loaded = true; self.status = "Live via Wi-Fi" } catch { appLog(.errors, "REST diagnostics connection/decode failed error=\(error.localizedDescription)"); continue }
                }
                if !loaded {
                    self.status = "Diagnostics unavailable"
                    if self.allowsBluetooth, self.central.state == .poweredOn, self.peripheral == nil {
                        self.bluetoothScanEnabled = true
                        self.scan()
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

enum FirmwareManifestValidator {
    static func validate(_ manifest: FirmwareManifest, firmware: Data? = nil) throws {
        guard manifest.product == "InputPilot" else { throw FirmwareValidationError.wrongProduct }
        guard manifest.board == "esp32-s3-zero-4mb" else { throw FirmwareValidationError.wrongBoard }
        guard manifest.protocolVersion == 1 else { throw FirmwareValidationError.unsupportedProtocol }
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
    init?(_ value: String) {
        let core = value.split(separator: "+", maxSplits: 1)[0].split(separator: "-", maxSplits: 1)[0]
        let parts = core.split(separator: ".")
        guard !parts.isEmpty, parts.allSatisfy({ Int($0) != nil }) else { return nil }
        components = parts.map { Int($0)! }
    }
    static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let l = index < lhs.components.count ? lhs.components[index] : 0
            let r = index < rhs.components.count ? rhs.components[index] : 0
            if l != r { return l < r }
        }
        return false
    }
    static func == (lhs: Self, rhs: Self) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

enum FirmwareUpdateTransportKind: String, Equatable { case wifi = "Wi-Fi", bluetooth = "Bluetooth" }

final class FirmwareUpdateManager: NSObject, ObservableObject, URLSessionTaskDelegate {
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
    private var hidControl: CBCharacteristic?
    private var acknowledged = 0
    private var windowSize = 32 * 1024
    private var statusEvent = ""
    private var targetVersion: String?
    private var cancelled = false
    private var lastProgress = Date()
    private var preUpdateDeviceId: String?
    private var requiredSchema = 1
    private var rebootTimeoutWork: DispatchWorkItem?
    private var wifiEndpoints: [URL] = []
    private var wifiToken: String?
    private var connectionMode: ConnectionMode = .automatic
    private var capabilities: Set<String> = []
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

    func configure(device: StoredDevice, mode: ConnectionMode) {
        wifiEndpoints = DeviceEndpointResolver.endpointURLs(mdnsHost: device.mdnsHost, staIP: device.staIP)
        wifiToken = device.apiToken; connectionMode = mode; capabilities = Set(device.capabilities)
        preUpdateDeviceId = device.deviceId
    }

    func attach(peripheral: CBPeripheral, control: CBCharacteristic, data: CBCharacteristic, status: CBCharacteristic, hidControl: CBCharacteristic? = nil) {
        self.peripheral = peripheral; self.control = control; self.data = data; self.status = status; self.hidControl = hidControl
        peripheral.readValue(for: status)
    }

    func receive(_ value: Data?, error: Error?) {
        guard error == nil, let value,
              let object = try? JSONSerialization.jsonObject(with: value) as? [String: Any] else { return }
        statusEvent = object["event"] as? String ?? ""
        acknowledged = object["offset"] as? Int ?? acknowledged
        windowSize = object["windowSize"] as? Int ?? windowSize
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
        let wifiCapable = capabilities.contains("wifi_ota") && !wifiEndpoints.isEmpty
        let bleCapable = (capabilities.isEmpty || capabilities.contains("ble_ota")) &&
                         peripheral != nil && control != nil && data != nil
        let order = Self.transportOrder(mode: connectionMode, wifiAvailable: wifiCapable, bluetoothAvailable: bleCapable)
        guard let selected = order.first else { state = .failed("No permitted firmware update transport is available."); return }
        if selected == .wifi {
            do { try await installWiFi(firmware, version: version, expectedSHA256: expectedSHA256); return }
            catch where order.contains(.bluetooth) && state == .preparing { await installBLE(firmware, version: version, expectedSHA256: expectedSHA256); return }
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
        if let hidControl { peripheral.writeValue(HIDEvent.releaseAll.binary, for: hidControl, type: .withResponse) }
        let command = "START protocol=1 version=\(version) size=\(firmware.count) sha256=\(digest)"
        peripheral.writeValue(Data(command.utf8), for: control, type: .withResponse)
        guard await wait(for: "READY", timeout: 10) else { if case .failed = state { return }; state = .failed("InputPilot did not become ready for the update."); return }
        let started = Date()
        let maximum = max(5, peripheral.maximumWriteValueLength(for: .withoutResponse) - 4)
        var offset = 0
        while offset < firmware.count && !cancelled {
            while (!peripheral.canSendWriteWithoutResponse || offset - acknowledged >= windowSize) && !cancelled {
                if Date().timeIntervalSince(lastProgress) > 15 { state = .failed("Firmware transfer timed out."); return }
                try? await Task.sleep(for: .milliseconds(10))
            }
            let count = min(maximum, firmware.count - offset)
            var frame = Data()
            var littleEndian = UInt32(offset).littleEndian
            withUnsafeBytes(of: &littleEndian) { frame.append(contentsOf: $0) }
            frame.append(firmware[offset..<(offset + count)])
            peripheral.writeValue(frame, for: data, type: .withoutResponse)
            offset += count; bytesSent = offset; if peripheral.canSendWriteWithoutResponse { lastProgress = Date() }
            bytesPerSecond = Double(offset) / max(0.1, Date().timeIntervalSince(started))
        }
        guard !cancelled else { return }
        state = .waitingForFinalAck
        let ackDeadline = Date().addingTimeInterval(15)
        while acknowledged < firmware.count { if case .failed = state { return }; if Date() >= ackDeadline { state = .failed("Final firmware acknowledgement timed out."); return }; try? await Task.sleep(for: .milliseconds(20)) }
        peripheral.writeValue(Data("FINISH".utf8), for: control, type: .withResponse)
        state = .verifying
        guard await waitForFinalization(timeout: 30) else { if case .failed = state { return }; state = .failed("Firmware verification timed out."); return }
    }

    func cancel() {
        cancelled = true
        if activeTransport == .wifi { Task { [wifiEndpoints, wifiToken] in for base in wifiEndpoints { var request = URLRequest(url: base.appendingPathComponent("api/ota/abort")); request.httpMethod = "POST"; if let wifiToken, !wifiToken.isEmpty { request.setValue(wifiToken, forHTTPHeaderField: "X-API-Token") }; if (try? await URLSession.shared.data(for: request)) != nil { break } } } }
        else if let peripheral, let control { peripheral.writeValue(Data("ABORT".utf8), for: control, type: .withResponse) }
        state = .cancelled
    }

    private func installWiFi(_ firmware: Data, version: String, expectedSHA256: String?) async throws {
        let metadata = try FirmwareImageMetadata.parseAndValidate(firmware)
        guard metadata.version == version else { throw TransportError.failed("The target version does not match the firmware image metadata.") }
        let digest = SHA256.hash(data: firmware).map { String(format: "%02x", $0) }.joined()
        if let expectedSHA256, expectedSHA256.lowercased() != digest { throw TransportError.failed("Firmware verification failed before transfer.") }
        guard let base = wifiEndpoints.first else { throw TransportError.unavailable }
        activeTransport = .wifi; cancelled = false; targetVersion = version; requiredSchema = metadata.otaSchema
        totalBytes = firmware.count; bytesSent = 0; state = .preparing
        var start = authorized(URLRequest(url: base.appendingPathComponent("api/ota/start")))
        start.httpMethod = "POST"; start.timeoutInterval = 5; start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        start.httpBody = try JSONSerialization.data(withJSONObject: ["protocol": 1, "version": version, "size": firmware.count, "sha256": digest])
        let (_, startResponse) = try await URLSession.shared.data(for: start)
        guard (startResponse as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) == true else { throw TransportError.failed("Wi-Fi OTA start was rejected.") }
        state = .transferring; let boundary = "InputPilot-\(UUID().uuidString)"
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"firmware\"; filename=\"firmware.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
        body.append(firmware); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var upload = authorized(URLRequest(url: base.appendingPathComponent("api/ota/firmware")))
        upload.httpMethod = "POST"; upload.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let started = Date()
        let (responseData, response) = try await URLSession.shared.upload(for: upload, from: body, delegate: self)
        guard (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) == true else {
            let message = (try? JSONSerialization.jsonObject(with: responseData) as? [String: Any])?["error"] as? String
            throw TransportError.failed(message ?? "Wi-Fi firmware upload failed.")
        }
        bytesSent = firmware.count; bytesPerSecond = Double(firmware.count) / max(0.1, Date().timeIntervalSince(started)); state = .rebooting
        try await verifyWiFiReboot(base: base, version: version)
    }

    private func authorized(_ request: URLRequest) -> URLRequest { var request = request; if let wifiToken, !wifiToken.isEmpty { request.setValue(wifiToken, forHTTPHeaderField: "X-API-Token") }; return request }
    private func verifyWiFiReboot(base: URL, version: String) async throws {
        state = .reconnecting; try? await Task.sleep(for: .seconds(2)); let deadline = Date().addingTimeInterval(60)
        while Date() < deadline && !cancelled {
            do { let status = try await DeviceAPIClient().status(baseURL: base, token: wifiToken); if status.deviceId?.lowercased() == preUpdateDeviceId?.lowercased(), status.version == version, status.otaSchema >= requiredSchema { installedVersion = status.version; if let id = status.deviceId { metadataHandler?(BLEDeviceMetadata(product: "InputPilot", board: "esp32-s3-zero-4mb", deviceId: id, deviceName: status.name, firmware: status.version, protocolVersion: status.protocolVersion, otaSchema: status.otaSchema, capabilities: status.capabilities, authRequired: status.authRequired)) }; state = .completed; return } } catch {}
            try? await Task.sleep(for: .seconds(1))
        }
        throw TransportError.failed("Update could not be verified after Wi-Fi restart.")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSentNow: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard activeTransport == .wifi, totalBytesExpectedToSend > 0 else { return }
        DispatchQueue.main.async { self.bytesSent = min(self.totalBytes, Int(Double(totalBytesSent) / Double(totalBytesExpectedToSend) * Double(self.totalBytes))) }
    }
    func disconnected(expected: Bool) {
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
        case "migration_required": "This device needs a one-time USB migration before Bluetooth updates are available."
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

final class BLEHIDControlTransport: NSObject, HIDControlTransport, CBCentralManagerDelegate, CBPeripheralDelegate {
    let kind = TransportKind.bluetooth
    private(set) var isAvailable = false
    private(set) var state: TransportConnectionState = .offline
    private var central: CBCentralManager!; private var peripheral: CBPeripheral?; private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private let token: String?
    private let deviceId: String
    private let service = CBUUID(string: "7D9F0001-4F4D-4F56-4552-484944000001")
    private let legacyService = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private let legacyRX = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    private let legacyTX = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    private let mouse = CBUUID(string: "7D9F0003-4F4D-4F56-4552-484944000001")
    private let keyboard = CBUUID(string: "7D9F0004-4F4D-4F56-4552-484944000001")
    private let control = CBUUID(string: "7D9F0002-4F4D-4F56-4552-484944000001")
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
    private var shouldReconnect = false
    private var pendingServices = 0
    private var authTimeoutWork: DispatchWorkItem?
    private let authTimeout: TimeInterval
    init(deviceId: String, token: String?, authTimeout: TimeInterval = 10) { self.deviceId = deviceId.lowercased(); self.token = token; self.authTimeout = authTimeout; super.init(); central = CBCentralManager(delegate: self, queue: .main) }
    private func scan() {
        guard shouldReconnect, central.state == .poweredOn, !central.isScanning, peripheral == nil else { return }
        state = state == .offline ? .connecting : .reconnecting
        // InputPilot identity lives in manufacturer data. Service-filtered scans
        // miss valid legacy advertisements when 128-bit UUIDs do not fit.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        appLog(.bluetooth, "control scan started deviceId=\(deviceId)")
        scanTimeoutWork?.cancel()
        let timeout = DispatchWorkItem { [weak self] in guard let self else { return }; self.central.stopScan(); let retry = DispatchWorkItem { [weak self] in self?.scan() }; self.reconnectWork = retry; DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: retry) }
        scanTimeoutWork = timeout; DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    }
    func connect() async { shouldReconnect = true; scan() }
    func centralManagerDidUpdateState(_ central: CBCentralManager) { if central.state == .poweredOn { scan() } else { isAvailable = false; state = .offline } }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard BLEDeviceDiscoveryManager.advertisement(advertisementData, matches: deviceId) else { return }
        appLog(.bluetooth, "discovered deviceId=\(deviceId) rssi=\(RSSI) connect requested")
        self.peripheral = peripheral
        scanTimeoutWork?.cancel()
        central.stopScan()
        state = .connecting; central.connect(peripheral)
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) { appLog(.bluetooth, "didConnect deviceId=\(deviceId)"); peripheral.delegate = self; peripheral.discoverServices([service, legacyService, otaService]) }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) { appLog(error == nil ? .bluetooth : .errors, "BLE disconnected error=\(error?.localizedDescription ?? "none") reconnect=\(shouldReconnect)"); authTimeoutWork?.cancel(); authTimeoutWork = nil; isAvailable = false; if firmwareUpdater.activeTransport != .wifi { firmwareUpdater.disconnected(expected: firmwareUpdater.expectsReboot) }; let authFailed = state == .authenticationFailed; state = authFailed ? .authenticationFailed : (shouldReconnect ? .reconnecting : .offline); characteristics.removeAll(); pendingServices = 0; self.peripheral = nil; reconnectWork?.cancel(); guard shouldReconnect && !authFailed else { return }; let work = DispatchWorkItem { [weak self] in appLog(.bluetooth, "reconnect scheduled"); self?.scan() }; reconnectWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work) }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) { guard error == nil, let services = peripheral.services, !services.isEmpty else { appLog(.errors, "BLE service discovery error=\(error?.localizedDescription ?? "empty")"); central.cancelPeripheralConnection(peripheral); return }; appLog(.bluetooth, "services discovered count=\(services.count)"); pendingServices = services.count; services.forEach { peripheral.discoverCharacteristics(nil, for: $0) } }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if error == nil { service.characteristics?.forEach { characteristic in characteristics[characteristic.uuid] = characteristic; appLog(.bluetooth, "characteristic uuid=\(characteristic.uuid.uuidString) properties=\(characteristic.properties.rawValue)") } }
        pendingServices -= 1
        guard pendingServices == 0 else { return }
        let hasBinary = characteristics[mouse] != nil && characteristics[keyboard] != nil && characteristics[control] != nil
        guard hasBinary else { appLog(.errors, "BLE control characteristics missing"); isAvailable = false; state = .offline; return }
        guard let token, !token.isEmpty else { isAvailable = true; state = .ready; prepareFirmwareUpdater(peripheral); return }
        guard !token.contains("\n"), !token.contains("\r"), let tx = characteristics[legacyTX], characteristics[legacyRX] != nil else { failAuthentication(peripheral); return }
        state = .authenticating
        peripheral.setNotifyValue(true, for: tx)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == legacyTX, state == .authenticating else { return }
        guard error == nil, characteristic.isNotifying, let token, let rx = characteristics[legacyRX] else { failAuthentication(peripheral); return }
        startAuthTimeout(peripheral)
        peripheral.writeValue(Data("auth \(token)".utf8), for: rx, type: .withResponse)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == otaStatus { firmwareUpdater.receive(characteristic.value, error: error); return }
        guard characteristic.uuid == legacyTX, error == nil, let data = characteristic.value, let reply = String(data: data, encoding: .utf8) else { return }
        switch reply.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "auth ok" where state == .authenticating: authTimeoutWork?.cancel(); authTimeoutWork = nil; isAvailable = true; state = .ready; prepareFirmwareUpdater(peripheral)
        case "auth failed" where state == .authenticating: failAuthentication(peripheral)
        default: break
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let id = AppLogContext.eventID.map(String.init) ?? "-"
        appLog(error == nil ? .bluetooth : .errors, "BLE didWrite id=\(id) uuid=\(characteristic.uuid.uuidString) result=\(error?.localizedDescription ?? "success")")
    }
    private func prepareFirmwareUpdater(_ peripheral: CBPeripheral) {
        guard let control = characteristics[otaControl], let data = characteristics[otaData], let status = characteristics[otaStatus] else { return }
        firmwareUpdater.attach(peripheral: peripheral, control: control, data: data, status: status, hidControl: characteristics[self.control])
        peripheral.setNotifyValue(true, for: status)
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) { firmwareUpdater.writerReady() }
    private func startAuthTimeout(_ peripheral: CBPeripheral) { authTimeoutWork?.cancel(); let work = DispatchWorkItem { [weak self, weak peripheral] in guard let self, let peripheral, self.state == .authenticating else { return }; self.failAuthentication(peripheral) }; authTimeoutWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + authTimeout, execute: work) }
    private func failAuthentication(_ peripheral: CBPeripheral) { authTimeoutWork?.cancel(); authTimeoutWork = nil; isAvailable = false; state = .authenticationFailed; central.cancelPeripheralConnection(peripheral) }
    func send(_ event: HIDEvent) async throws {
        if firmwareUpdater.blocksControl, event != .releaseAll { throw TransportError.failed("Controls are unavailable during a firmware update.") }
        let uuid: CBUUID = { switch event { case .mouseMove, .scroll, .mouseDown, .mouseUp, .click: mouse; case .typeText, .key, .keyCombo, .keyboardReport: keyboard; default: control } }()
        guard let peripheral, let characteristic = characteristics[uuid] else { throw TransportError.unavailable }
        let id = AppLogContext.eventID.map(String.init) ?? "-"; let payload = event.binary
        let properties = characteristic.properties
        let writeType: CBCharacteristicWriteType
        if properties.contains(.write) { writeType = .withResponse }
        else if properties.contains(.writeWithoutResponse) { writeType = .withoutResponse }
        else { appLog(.errors, "BLE id=\(id) characteristic not writable properties=\(properties.rawValue)"); throw TransportError.failed("Bluetooth HID characteristic is not writable.") }
        if writeType == .withoutResponse && !peripheral.canSendWriteWithoutResponse { appLog(.errors, "BLE id=\(id) cannot send without response"); throw TransportError.failed("Bluetooth write queue is full.") }
        appLog(.bluetooth, "HID write requested id=\(id) uuid=\(uuid.uuidString) bytes=\(payload.count) writeType=\(writeType == .withResponse ? "withResponse" : "withoutResponse") canSendWithoutResponse=\(peripheral.canSendWriteWithoutResponse) maximum=\(peripheral.maximumWriteValueLength(for: writeType))")
        peripheral.writeValue(payload, for: characteristic, type: writeType)
    }
    func disconnect() async { shouldReconnect = false; reconnectWork?.cancel(); scanTimeoutWork?.cancel(); authTimeoutWork?.cancel(); authTimeoutWork = nil; central.stopScan(); if let peripheral { central.cancelPeripheralConnection(peripheral) }; self.peripheral = nil; characteristics.removeAll(); pendingServices = 0; isAvailable = false; state = .offline }
}

@MainActor enum InputPilotBluetoothManager {
    private static var sessions: [String: BLEHIDControlTransport] = [:]
    static func session(deviceId: String, token: String?) -> BLEHIDControlTransport {
        let key = deviceId.lowercased() + "|" + (token ?? "")
        if let existing = sessions[key] { return existing }
        let session = BLEHIDControlTransport(deviceId: deviceId, token: token)
        sessions[key] = session
        return session
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
    private let ble: HIDControlTransport; private let tcp: HIDControlTransport; private let rest: HIDControlTransport
    private var leasedTransport: HIDControlTransport?
    private var nextEventID: UInt64 = 0
    init(device: StoredDevice) {
        mode = ConnectionMode(rawValue: UserDefaults.standard.string(forKey: "connectionMode") ?? "") ?? .automatic
        let host = device.staIP ?? device.mdnsHost
        let bluetooth = InputPilotBluetoothManager.session(deviceId: device.deviceId, token: device.apiToken)
        bluetooth.metadataHandler = { [weak device] metadata in
            guard let device, metadata.deviceId.lowercased() == device.deviceId.lowercased() else { return }
            DeviceMerge.bluetooth(metadata, token: nil, into: device)
        }
        ble = bluetooth
        if host.isEmpty { tcp = UnavailableHIDControlTransport(kind: .tcp); rest = UnavailableHIDControlTransport(kind: .rest) }
        else {
            tcp = TCPHIDControlTransport(host: host, token: device.apiToken)
            if let url = DeviceEndpointResolver.baseURL(from: host) { rest = RESTHIDControlTransport(baseURL: url, token: device.apiToken) }
            else { rest = UnavailableHIDControlTransport(kind: .rest) }
        }
        capabilities = Set(device.capabilities)
        protocolVersion = device.protocolVersion
    }
    init(ble: HIDControlTransport, tcp: HIDControlTransport, rest: HIDControlTransport, capabilities: Set<String> = [], protocolVersion: Int = 1) {
        mode = .automatic
        self.ble = ble; self.tcp = tcp; self.rest = rest; self.capabilities = capabilities; self.protocolVersion = protocolVersion
    }
    func connect() async { isConnecting = true; async let b: Void = ble.connect(); async let t: Void = tcp.connect(); async let r: Void = rest.connect(); _ = await (b, t, r); isConnecting = false }
    func disconnect() async { await releaseAll(); await tcp.disconnect(); await rest.disconnect(); activeTransport = nil }
    @discardableResult func send(_ event: HIDEvent) async -> Bool {
        nextEventID &+= 1; let eventID = nextEventID
        appLog(.input, "id=\(eventID) \(event.diagnosticName)")
        guard protocolVersion <= 1 else { lastError = "Firmware protocol v\(protocolVersion) is unsupported."; activeTransport = nil; return false }
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
    func releaseAll() async { await send(.releaseAll) }
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
    func supports(_ capability: String) -> Bool { capabilities.isEmpty || capabilities.contains(capability) }
    func supports(_ event: HIDEvent) -> Bool { requiredCapability(for: event).map { supports($0) } ?? true }
    var unsupportedControlMessages: [String] {
        var messages: [String] = []
        if !supports("mouse_scroll") { messages.append("Scrolling requires firmware 0.6+.") }
        if !supports("mouse_button_state") { messages.append("Drag is not supported by this firmware.") }
        if !supports("keyboard_layout") { messages.append("Keyboard layout mapping is unavailable.") }
        return messages
    }
    var transportReadiness: [(TransportKind, Bool)] { [(.bluetooth, ble.isAvailable), (.tcp, tcp.isAvailable), (.rest, rest.isAvailable)] }
    var connectionSummary: String {
        if protocolVersion > 1 { return "Firmware unsupported" }
        if let lastError { return lastError }
        if let activeTransport { return "Connected · \(activeTransport.rawValue)" }
        if allTransports.contains(where: { $0.state == .authenticationFailed }) { return "Authentication failed" }
        if allTransports.contains(where: { $0.state == .reconnecting }) { return "Reconnecting…" }
        if isConnecting || allTransports.contains(where: { [.connecting, .authenticating].contains($0.state) }) { return "Connecting…" }
        return "Offline"
    }
    private var allTransports: [HIDControlTransport] { [ble, tcp, rest] }
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
        case .wifiOnly: lowLatency ? [.tcp, .rest] : [.rest, .tcp]
        case .preferBluetooth: [.bluetooth, .tcp, .rest]
        case .preferWiFi: [.tcp, .rest, .bluetooth]
        case .automatic: lowLatency ? [.bluetooth, .tcp, .rest] : [.tcp, .rest, .bluetooth]
        }
    }
    private func candidates(for event: HIDEvent) -> [HIDControlTransport] {
        candidateTransports(lowLatency: event.prefersLowLatency)
    }
    private func candidateTransports(lowLatency: Bool) -> [HIDControlTransport] {
        let transports: [TransportKind: HIDControlTransport] = [.bluetooth: ble, .tcp: tcp, .rest: rest]
        return Self.candidateKinds(mode: mode, lowLatency: lowLatency).compactMap { kind in
            guard supports(kind == .bluetooth ? "ble_control" : kind == .tcp ? "tcp_control" : "rest_control") else { return nil }
            return transports[kind]
        }
    }
}

@Model final class HIDPreset {
    var name: String; var payload: String; var shortcut: Bool; var favorite: Bool; var order: Int; var enterAfter: Bool; var typingDelayMs: Int
    init(name: String, payload: String, shortcut: Bool = false, favorite: Bool = false, order: Int = 0, enterAfter: Bool = false, typingDelayMs: Int = 0) { self.name = name; self.payload = payload; self.shortcut = shortcut; self.favorite = favorite; self.order = order; self.enterAfter = enterAfter; self.typingDelayMs = typingDelayMs }
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
            VStack(spacing: 4) { HStack { Circle().fill(manager.activeTransport == nil ? .orange : .green).frame(width: 9, height: 9); Text(manager.connectionSummary).font(.caption).lineLimit(1); Spacer(); Picker("Connection", selection: $manager.mode) { ForEach(ConnectionMode.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden() }; TimelineView(.periodic(from: .now, by: 1)) { _ in HStack(spacing: 12) { ForEach(manager.transportReadiness, id: \.0) { item in Label(item.0.rawValue, systemImage: item.1 ? "circle.fill" : "circle").foregroundStyle(item.1 ? .green : .secondary) } }.font(.caption2) } }
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
    @ObservedObject var manager: HIDConnectionManager; @State private var dragging = false; @AppStorage("trackpadSensitivity") private var sensitivity = 1.0
    private let coalescer: MouseEventCoalescer
    init(manager: HIDConnectionManager) {
        self.manager = manager
        coalescer = MouseEventCoalescer { [weak manager] x, y in await manager?.send(.mouseMove(x, y)) }
    }
    var body: some View {
        VStack { TrackpadInputBridge(move: { x, y in guard manager.supports("mouse_move") else { return }; Task { await coalescer.add(x: Int(x * sensitivity), y: Int(y * sensitivity)) } }, scroll: { value in guard manager.supports("mouse_scroll") else { return }; Task { await manager.send(.scroll(Int16(clamping: Int(-value / 5)))) } }, click: { count in guard manager.supports("mouse_click") else { return }; UIImpactFeedbackGenerator(style: .light).impactOccurred(); Task { for _ in 0..<count { await manager.send(.click(.left)) } } }, drag: { active in guard manager.supports("mouse_button_state") else { return }; dragging = active; Task { if active { guard manager.beginOrderedSession(lowLatency: true) else { dragging = false; return } }; let sent = await manager.send(active ? .mouseDown(.left) : .mouseUp(.left)); if !active || !sent { manager.endOrderedSession() }; if !sent { dragging = false; await manager.releaseAllPreservingError() } } }, cancel: { dragging = false; Task { await coalescer.cancel(); manager.endOrderedSession(); await manager.releaseAll() } }).overlay { Text(dragging ? "Dragging" : "Trackpad").foregroundStyle(.secondary).allowsHitTesting(false) }.padding()
            HStack { Button("Left") { Task { await manager.send(.click(.left)) } }; Button("Middle") { Task { await manager.send(.click(.middle)) } }; Button("Right") { Task { await manager.send(.click(.right)) } } }.buttonStyle(.borderedProminent).disabled(!manager.supports("mouse_click"))
            HStack { Text("Sensitivity"); Slider(value: $sensitivity, in: 0.4...2.5) }.padding()
        }.onChange(of: manager.lastError) { _, error in if error != nil && dragging { dragging = false; Task { await coalescer.cancel(); await manager.releaseAll() } } }
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
    @ObservedObject var manager: HIDConnectionManager; @Environment(\.modelContext) private var context; @Query(sort: \HIDPreset.order) private var presets: [HIDPreset]; @State private var name = ""; @State private var payload = ""; @State private var shortcut = false; @State private var favorite = false; @State private var enterAfter = false; @State private var typingDelayMs = 0; @AppStorage("keyboardLayout") private var layoutName = KeyboardLayout.german.rawValue
    var body: some View { NavigationStack { List { Section("New preset") { TextField("Name", text: $name); TextField("Text or shortcut", text: $payload, axis: .vertical); Picker("Type", selection: $shortcut) { Text("Text").tag(false); Text("Keyboard Shortcut").tag(true) }; Toggle("Favorite", isOn: $favorite); Toggle("Enter after", isOn: $enterAfter).disabled(shortcut); Picker("Typing speed", selection: $typingDelayMs) { ForEach([0,10,25,50,100], id: \.self) { Text($0 == 0 ? "Fast" : "\($0) ms").tag($0) } }.disabled(shortcut); Button("Add Preset") { context.insert(HIDPreset(name: name.isEmpty ? "Preset" : name, payload: payload, shortcut: shortcut, favorite: favorite, order: presets.count, enterAfter: enterAfter, typingDelayMs: typingDelayMs)); name = ""; payload = ""; shortcut = false; favorite = false; enterAfter = false; typingDelayMs = 0 } }; Section("Presets") { ForEach(presets) { preset in HStack { Button { preset.favorite.toggle() } label: { Image(systemName: preset.favorite ? "star.fill" : "star") }; VStack(alignment: .leading) { TextField("Name", text: Binding(get: { preset.name }, set: { preset.name = $0 })); TextField("Content", text: Binding(get: { preset.payload }, set: { preset.payload = $0 }), axis: .vertical).font(.caption); Toggle("Shortcut", isOn: Binding(get: { preset.shortcut }, set: { preset.shortcut = $0 })); Toggle("Enter after", isOn: Binding(get: { preset.enterAfter }, set: { preset.enterAfter = $0 })); Picker("Typing speed", selection: Binding(get: { preset.typingDelayMs }, set: { preset.typingDelayMs = $0 })) { ForEach([0,10,25,50,100], id: \.self) { Text($0 == 0 ? "Fast" : "\($0) ms").tag($0) } } }; Spacer(); Button("Run") { UIImpactFeedbackGenerator(style: .medium).impactOccurred(); Task { let sent: Bool; if preset.shortcut { sent = await manager.send(.keyCombo(preset.payload)) } else { sent = await manager.sendText(preset.payload, layout: KeyboardLayout(rawValue: layoutName) ?? .german, delayMilliseconds: preset.typingDelayMs) }; if sent && preset.enterAfter { await manager.send(.key("enter")) } } } }.swipeActions { Button(role: .destructive) { context.delete(preset) } label: { Label("Delete", systemImage: "trash") }; Button { context.insert(HIDPreset(name: preset.name + " Copy", payload: preset.payload, shortcut: preset.shortcut, favorite: preset.favorite, order: presets.count, enterAfter: preset.enterAfter, typingDelayMs: preset.typingDelayMs)) } label: { Label("Duplicate", systemImage: "plus.square.on.square") } } }.onMove { source, destination in var ordered = presets; ordered.move(fromOffsets: source, toOffset: destination); for (index, item) in ordered.enumerated() { item.order = index } } } }.toolbar { EditButton() } } }
}

struct MacrosView: View {
    @ObservedObject var manager: HIDConnectionManager; @ObservedObject var controller: MacroController; @Environment(\.modelContext) private var context; @Query(sort: \HIDMacro.createdAt, order: .reverse) private var saved: [HIDMacro]; @State private var speed = 1.0; @State private var repeatCount = 1; @State private var delay = 0; @State private var showSave = false; @State private var macroName = ""; @State private var macroDescription = ""
    var body: some View { VStack { if controller.isPlaying { Button("STOP", role: .destructive) { UINotificationFeedbackGenerator().notificationOccurred(.warning); controller.stop(manager: manager) }.buttonStyle(.borderedProminent).tint(.red).controlSize(.large) }; HStack { Button(controller.isRecording ? "Stop & Save" : "Record") { if controller.isRecording { controller.stopRecording(); macroName = "Macro \(saved.count + 1)"; showSave = true; UIImpactFeedbackGenerator(style: .medium).impactOccurred() } else { controller.startRecording(); UIImpactFeedbackGenerator(style: .medium).impactOccurred() } }.buttonStyle(.borderedProminent); if controller.isRecording { Button("Cancel", role: .cancel) { controller.stopRecording(); controller.recorded = [] } }; TimelineView(.periodic(from: .now, by: 1)) { _ in Text(recordingStatus) } }; Form { Picker("Speed", selection: $speed) { ForEach([0.5, 1, 1.5, 2], id: \.self) { Text("\($0, specifier: "%g")×").tag($0) } }; Picker("Repeat", selection: $repeatCount) { ForEach([1, 2, 5, 10, 0], id: \.self) { Text($0 == 0 ? "Infinite" : "\($0)×").tag($0) } }; Picker("Start delay", selection: $delay) { ForEach([0, 3, 5, 10], id: \.self) { Text("\($0) s").tag($0) } }; Section("Saved") { ForEach(saved) { macro in HStack { VStack(alignment: .leading) { TextField("Name", text: Binding(get: { macro.name }, set: { macro.name = $0 })); Text("\(macro.events.count) events").font(.caption) }; Spacer(); Button("Play") { UIImpactFeedbackGenerator(style: .medium).impactOccurred(); controller.play(macro, speed: speed, repeats: repeatCount == 0 ? nil : repeatCount, delay: Double(delay), manager: manager) } }.swipeActions { Button(role: .destructive) { context.delete(macro) } label: { Label("Delete", systemImage: "trash") }; Button { context.insert(HIDMacro(name: macro.name + " Copy", description: macro.macroDescription, events: macro.events)) } label: { Label("Duplicate", systemImage: "plus.square.on.square") } } } } } } .alert("Save Macro", isPresented: $showSave) { TextField("Name", text: $macroName); TextField("Description (optional)", text: $macroDescription); Button("Save") { context.insert(HIDMacro(name: macroName.isEmpty ? "Macro" : macroName, description: macroDescription, events: controller.recorded)); controller.recorded = [] }; Button("Cancel", role: .cancel) { controller.recorded = [] } } }
    private var recordingStatus: String { guard controller.isRecording else { return "\(controller.recorded.count) events" }; let seconds = Int(controller.recordingDuration); return String(format: "🔴 Recording · %02d:%02d · %d events", seconds / 60, seconds % 60, controller.recorded.count) }
}
