import CoreBluetooth
import Foundation
import Network
import SwiftData
import SwiftUI
import UIKit

enum MouseButton: UInt8, Codable, CaseIterable { case left = 0, right = 1, middle = 2 }
enum HIDEvent: Codable, Equatable {
    case mouseMove(Int16, Int16), scroll(Int16), mouseDown(MouseButton), mouseUp(MouseButton)
    case click(MouseButton), typeText(String), key(String), keyCombo(String)
    case keyboardReport(modifiers: UInt8, usage: UInt8)
    case releaseAll, ping

    var prefersLowLatency: Bool {
        switch self { case .mouseMove, .scroll, .mouseDown, .mouseUp, .click, .key, .keyCombo, .keyboardReport, .releaseAll, .ping: true; case .typeText: false }
    }
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
        guard (200...299).contains(http.statusCode) else { isAvailable = false; state = http.statusCode == 401 ? .authenticationFailed : .offline; throw TransportError.failed(http.statusCode == 401 ? "Authentication failed" : "REST request failed (HTTP \(http.statusCode))") }
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
        do { try await sendLine(event.line) } catch { isAvailable = false; state = .reconnecting; connection?.cancel(); throw error }
    }
    func disconnect() async { shouldReconnect = false; authTimeoutWork?.cancel(); authTimeoutWork = nil; receiving = false; connection?.cancel(); connection = nil; receiveBuffer.removeAll(); isAvailable = false; state = .offline }
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
    private var reconnectWork: DispatchWorkItem?
    private var scanTimeoutWork: DispatchWorkItem?
    private var shouldReconnect = false
    private var pendingServices = 0
    private var authTimeoutWork: DispatchWorkItem?
    private let authTimeout: TimeInterval
    init(deviceId: String, token: String?, authTimeout: TimeInterval = 4) { self.deviceId = deviceId.lowercased(); self.token = token; self.authTimeout = authTimeout; super.init(); central = CBCentralManager(delegate: self, queue: .main) }
    private func scan() {
        guard shouldReconnect, central.state == .poweredOn, !central.isScanning, peripheral == nil else { return }
        state = state == .offline ? .connecting : .reconnecting
        central.scanForPeripherals(withServices: [service, legacyService])
        scanTimeoutWork?.cancel()
        let timeout = DispatchWorkItem { [weak self] in guard let self else { return }; self.central.stopScan(); let retry = DispatchWorkItem { [weak self] in self?.scan() }; self.reconnectWork = retry; DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: retry) }
        scanTimeoutWork = timeout; DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    }
    func connect() async { shouldReconnect = true; scan() }
    func centralManagerDidUpdateState(_ central: CBCentralManager) { if central.state == .poweredOn { scan() } else { isAvailable = false; state = .offline } }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              let advertised = String(data: data, encoding: .utf8)?.lowercased(),
              advertised.hasSuffix("ip" + deviceId) else { return }
        self.peripheral = peripheral
        scanTimeoutWork?.cancel()
        central.stopScan()
        state = .connecting; central.connect(peripheral)
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) { peripheral.delegate = self; peripheral.discoverServices([service, legacyService]) }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) { authTimeoutWork?.cancel(); authTimeoutWork = nil; isAvailable = false; let authFailed = state == .authenticationFailed; state = authFailed ? .authenticationFailed : (shouldReconnect ? .reconnecting : .offline); characteristics.removeAll(); pendingServices = 0; self.peripheral = nil; reconnectWork?.cancel(); guard shouldReconnect && !authFailed else { return }; let work = DispatchWorkItem { [weak self] in self?.scan() }; reconnectWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work) }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) { guard error == nil, let services = peripheral.services, !services.isEmpty else { central.cancelPeripheralConnection(peripheral); return }; pendingServices = services.count; services.forEach { peripheral.discoverCharacteristics(nil, for: $0) } }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if error == nil { service.characteristics?.forEach { characteristics[$0.uuid] = $0 } }
        pendingServices -= 1
        guard pendingServices == 0 else { return }
        let hasBinary = characteristics[mouse] != nil && characteristics[keyboard] != nil && characteristics[control] != nil
        guard hasBinary else { isAvailable = false; state = .offline; return }
        guard let token, !token.isEmpty else { isAvailable = true; state = .ready; return }
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
        guard characteristic.uuid == legacyTX, error == nil, let data = characteristic.value, let reply = String(data: data, encoding: .utf8) else { return }
        switch reply.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "auth ok" where state == .authenticating: authTimeoutWork?.cancel(); authTimeoutWork = nil; isAvailable = true; state = .ready
        case "auth failed" where state == .authenticating: failAuthentication(peripheral)
        default: break
        }
    }
    private func startAuthTimeout(_ peripheral: CBPeripheral) { authTimeoutWork?.cancel(); let work = DispatchWorkItem { [weak self, weak peripheral] in guard let self, let peripheral, self.state == .authenticating else { return }; self.failAuthentication(peripheral) }; authTimeoutWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + authTimeout, execute: work) }
    private func failAuthentication(_ peripheral: CBPeripheral) { authTimeoutWork?.cancel(); authTimeoutWork = nil; isAvailable = false; state = .authenticationFailed; central.cancelPeripheralConnection(peripheral) }
    func send(_ event: HIDEvent) async throws {
        let uuid: CBUUID = { switch event { case .mouseMove, .scroll, .mouseDown, .mouseUp, .click: mouse; case .typeText, .key, .keyCombo, .keyboardReport: keyboard; default: control } }()
        guard let peripheral, let characteristic = characteristics[uuid] else { throw TransportError.unavailable }
        peripheral.writeValue(event.binary, for: characteristic, type: .withoutResponse)
    }
    func disconnect() async { shouldReconnect = false; reconnectWork?.cancel(); scanTimeoutWork?.cancel(); authTimeoutWork?.cancel(); authTimeoutWork = nil; central.stopScan(); if let peripheral { central.cancelPeripheralConnection(peripheral) }; self.peripheral = nil; characteristics.removeAll(); pendingServices = 0; isAvailable = false; state = .offline }
}

@MainActor final class HIDConnectionManager: ObservableObject {
    @Published var mode: ConnectionMode = .automatic
    @Published var activeTransport: TransportKind?
    @Published var lastError: String?
    @Published private(set) var isConnecting = false
    let capabilities: Set<String>
    let protocolVersion: Int
    var onEvent: ((HIDEvent) -> Void)?
    private let ble: HIDControlTransport; private let tcp: HIDControlTransport; private let rest: HIDControlTransport
    private var leasedTransport: HIDControlTransport?
    init(device: StoredDevice) {
        let host = device.staIP ?? device.mdnsHost
        ble = BLEHIDControlTransport(deviceId: device.deviceId, token: device.apiToken); tcp = TCPHIDControlTransport(host: host, token: device.apiToken)
        rest = RESTHIDControlTransport(baseURL: DeviceEndpointResolver.baseURL(from: host)!, token: device.apiToken)
        capabilities = Set(device.capabilities)
        protocolVersion = device.protocolVersion
    }
    init(ble: HIDControlTransport, tcp: HIDControlTransport, rest: HIDControlTransport, capabilities: Set<String> = [], protocolVersion: Int = 1) {
        self.ble = ble; self.tcp = tcp; self.rest = rest; self.capabilities = capabilities; self.protocolVersion = protocolVersion
    }
    func connect() async { isConnecting = true; async let b: Void = ble.connect(); async let t: Void = tcp.connect(); async let r: Void = rest.connect(); _ = await (b, t, r); isConnecting = false }
    func disconnect() async { await releaseAll(); await ble.disconnect(); await tcp.disconnect(); await rest.disconnect(); activeTransport = nil }
    @discardableResult func send(_ event: HIDEvent) async -> Bool {
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
            do { try await leasedTransport.send(event); activeTransport = leasedTransport.kind; lastError = nil; onEvent?(event); return true }
            catch { await abortOrderedSession(reason: "Active \(leasedTransport.kind.rawValue) transport failed; sequence stopped."); return false }
        }
        var failure: String?
        for transport in candidates(for: event) where transport.isAvailable && transport.state == .ready {
            do { try await transport.send(event); activeTransport = transport.kind; lastError = nil; onEvent?(event); return true }
            catch { failure = error.localizedDescription }
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
    init(device: StoredDevice) { self.device = device; _manager = StateObject(wrappedValue: HIDConnectionManager(device: device)) }
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) { HStack { Circle().fill(manager.activeTransport == nil ? .orange : .green).frame(width: 9, height: 9); Text(manager.connectionSummary).font(.caption).lineLimit(1); Spacer(); Picker("Connection", selection: $manager.mode) { ForEach(ConnectionMode.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden() }; TimelineView(.periodic(from: .now, by: 1)) { _ in HStack(spacing: 12) { ForEach(manager.transportReadiness, id: \.0) { item in Label(item.0.rawValue, systemImage: item.1 ? "circle.fill" : "circle").foregroundStyle(item.1 ? .green : .secondary) } }.font(.caption2) } }
                .padding(.horizontal)
            TabView { TrackpadView(manager: manager).tabItem { Label("Trackpad", systemImage: "rectangle.and.hand.point.up.left") }; LiveKeyboardView(manager: manager).tabItem { Label("Keyboard", systemImage: "keyboard") }; PresetsView(manager: manager).tabItem { Label("Presets", systemImage: "star") }; MacrosView(manager: manager, controller: macros).tabItem { Label("Macros", systemImage: "record.circle") } }
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
