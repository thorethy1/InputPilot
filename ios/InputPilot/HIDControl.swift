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

protocol HIDControlTransport: AnyObject {
    var kind: TransportKind { get }
    var isAvailable: Bool { get }
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
    private let baseURL: URL; private let token: String?; private let session: URLSession
    init(baseURL: URL, token: String?, session: URLSession = .shared) { self.baseURL = baseURL; self.token = token; self.session = session }
    func connect() async { do { try await send(.ping); isAvailable = true } catch { isAvailable = false } }
    func disconnect() async { isAvailable = false }
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
        guard let http = response as? HTTPURLResponse else { isAvailable = false; throw TransportError.failed("Invalid REST response") }
        guard (200...299).contains(http.statusCode) else { isAvailable = false; throw TransportError.failed(http.statusCode == 401 ? "Authentication failed" : "REST request failed (HTTP \(http.statusCode))") }
        isAvailable = true
    }
}

final class TCPHIDControlTransport: HIDControlTransport {
    let kind = TransportKind.tcp
    private let host: NWEndpoint.Host; private let token: String?; private var connection: NWConnection?
    private(set) var isAvailable = false
    init(host: String, token: String?) { self.host = NWEndpoint.Host(host); self.token = token }
    func connect() async {
        if connection != nil { return }
        let conn = NWConnection(host: host, port: 3333, using: .tcp); connection = conn
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn, self.connection === conn else { return }
            switch state {
            case .ready:
                if let token = self.token, !token.isEmpty {
                    guard !token.contains("\n"), !token.contains("\r") else { self.isAvailable = false; conn.cancel(); return }
                    conn.send(content: Data("auth \(token)\n".utf8), completion: .contentProcessed { [weak self] error in self?.isAvailable = error == nil })
                } else { self.isAvailable = true }
            case .failed, .cancelled: self.isAvailable = false; self.connection = nil
            default: self.isAvailable = false
            }
        }
        conn.start(queue: .main)
    }
    private func sendLine(_ line: String) async throws {
        guard let connection else { throw TransportError.unavailable }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data((line + "\n").utf8), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    func send(_ event: HIDEvent) async throws { try await sendLine(event.line) }
    func disconnect() async { connection?.cancel(); connection = nil; isAvailable = false }
}

final class BLEHIDControlTransport: NSObject, HIDControlTransport, CBCentralManagerDelegate, CBPeripheralDelegate {
    let kind = TransportKind.bluetooth
    private(set) var isAvailable = false
    private var central: CBCentralManager!; private var peripheral: CBPeripheral?; private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private let token: String?
    private let deviceId: String
    private let service = CBUUID(string: "7D9F0001-4F4D-4F56-4552-484944000001")
    private let legacyService = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private let legacyRX = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    private let mouse = CBUUID(string: "7D9F0003-4F4D-4F56-4552-484944000001")
    private let keyboard = CBUUID(string: "7D9F0004-4F4D-4F56-4552-484944000001")
    private let control = CBUUID(string: "7D9F0002-4F4D-4F56-4552-484944000001")
    private var reconnectWork: DispatchWorkItem?
    init(deviceId: String, token: String?) { self.deviceId = deviceId.lowercased(); self.token = token; super.init(); central = CBCentralManager(delegate: self, queue: .main) }
    private func scan() { guard central.state == .poweredOn, !central.isScanning, peripheral == nil else { return }; central.scanForPeripherals(withServices: [service, legacyService]) }
    func connect() async { scan() }
    func centralManagerDidUpdateState(_ central: CBCentralManager) { if central.state == .poweredOn { scan() } else { isAvailable = false } }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              let advertised = String(data: data, encoding: .utf8)?.lowercased(),
              advertised.hasSuffix("ip" + deviceId) else { return }
        self.peripheral = peripheral
        central.stopScan()
        central.connect(peripheral)
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) { peripheral.delegate = self; peripheral.discoverServices([service, legacyService]) }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) { isAvailable = false; characteristics.removeAll(); self.peripheral = nil; reconnectWork?.cancel(); let work = DispatchWorkItem { [weak self] in self?.scan() }; reconnectWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work) }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) { peripheral.services?.forEach { peripheral.discoverCharacteristics(nil, for: $0) } }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        service.characteristics?.forEach { characteristics[$0.uuid] = $0 }
        if let token, !token.isEmpty, let rx = characteristics[legacyRX] { peripheral.writeValue(Data("auth \(token)".utf8), for: rx, type: .withResponse) }
        let hasBinary = characteristics[mouse] != nil && characteristics[keyboard] != nil && characteristics[control] != nil
        isAvailable = hasBinary && (token?.isEmpty != false || characteristics[legacyRX] != nil)
    }
    func send(_ event: HIDEvent) async throws {
        let uuid: CBUUID = { switch event { case .mouseMove, .scroll, .mouseDown, .mouseUp, .click: mouse; case .typeText, .key, .keyCombo, .keyboardReport: keyboard; default: control } }()
        guard let peripheral, let characteristic = characteristics[uuid] else { throw TransportError.unavailable }
        peripheral.writeValue(event.binary, for: characteristic, type: .withoutResponse)
    }
    func disconnect() async { reconnectWork?.cancel(); central.stopScan(); if let peripheral { central.cancelPeripheralConnection(peripheral) }; self.peripheral = nil; isAvailable = false }
}

@MainActor final class HIDConnectionManager: ObservableObject {
    @Published var mode: ConnectionMode = .automatic
    @Published var activeTransport: TransportKind?
    @Published var lastError: String?
    @Published private(set) var isConnecting = false
    let capabilities: Set<String>
    var onEvent: ((HIDEvent) -> Void)?
    private let ble: HIDControlTransport; private let tcp: HIDControlTransport; private let rest: HIDControlTransport
    init(device: StoredDevice) {
        let host = device.staIP ?? device.mdnsHost
        ble = BLEHIDControlTransport(deviceId: device.deviceId, token: device.apiToken); tcp = TCPHIDControlTransport(host: host, token: device.apiToken)
        rest = RESTHIDControlTransport(baseURL: DeviceEndpointResolver.baseURL(from: host)!, token: device.apiToken)
        capabilities = Set(device.capabilities)
    }
    init(ble: HIDControlTransport, tcp: HIDControlTransport, rest: HIDControlTransport, capabilities: Set<String> = []) {
        self.ble = ble; self.tcp = tcp; self.rest = rest; self.capabilities = capabilities
    }
    func connect() async { isConnecting = true; async let b: Void = ble.connect(); async let t: Void = tcp.connect(); async let r: Void = rest.connect(); _ = await (b, t, r); isConnecting = false }
    func disconnect() async { await releaseAll(); await ble.disconnect(); await tcp.disconnect(); await rest.disconnect(); activeTransport = nil }
    @discardableResult func send(_ event: HIDEvent) async -> Bool {
        if let capability = requiredCapability(for: event), !supports(capability) {
            lastError = "This firmware does not support \(capability.replacingOccurrences(of: "_", with: " "))."
            return false
        }
        for transport in candidates(for: event) where transport.isAvailable {
            do { try await transport.send(event); activeTransport = transport.kind; lastError = nil; onEvent?(event); return true }
            catch { lastError = error.localizedDescription }
        }
        lastError = "No permitted control transport is available."
        return false
    }
    func releaseAll() async { await send(.releaseAll) }
    @discardableResult func sendText(_ text: String, layout: KeyboardLayout, delayMilliseconds: Int = 0) async -> Bool {
        do {
            for stroke in try layout.strokes(for: text) {
                if Task.isCancelled { return false }
                guard await send(.keyboardReport(modifiers: stroke.modifiers, usage: stroke.usage)) else { return false }
                if delayMilliseconds > 0 { try? await Task.sleep(for: .milliseconds(delayMilliseconds)) }
            }
            return true
        } catch { lastError = error.localizedDescription; return false }
    }
    func supports(_ capability: String) -> Bool { capabilities.isEmpty || capabilities.contains(capability) }
    var transportReadiness: [(TransportKind, Bool)] { [(.bluetooth, ble.isAvailable), (.tcp, tcp.isAvailable), (.rest, rest.isAvailable)] }
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
        let transports: [TransportKind: HIDControlTransport] = [.bluetooth: ble, .tcp: tcp, .rest: rest]
        return Self.candidateKinds(mode: mode, lowLatency: event.prefersLowLatency).compactMap { transports[$0] }
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
            while !Task.isCancelled && (repeats == nil || iteration < repeats!) {
                var previous = 0.0
                for item in macro.events { if Task.isCancelled { break }; do { try await Task.sleep(for: .seconds(max(0, item.offset - previous) / speed)) } catch { break }; guard !Task.isCancelled else { break }; previous = item.offset; if !(await manager.send(item.event)) { self?.isPlaying = false; await manager.releaseAll(); return } }
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
            VStack(spacing: 4) { HStack { Circle().fill(manager.activeTransport == nil ? .orange : .green).frame(width: 9, height: 9); Text(manager.lastError ?? manager.activeTransport.map { "Connected · \($0.rawValue)" } ?? (manager.isConnecting ? "Connecting…" : "Offline")).font(.caption).lineLimit(1); Spacer(); Picker("Connection", selection: $manager.mode) { ForEach(ConnectionMode.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden() }; TimelineView(.periodic(from: .now, by: 1)) { _ in HStack(spacing: 12) { ForEach(manager.transportReadiness, id: \.0) { item in Label(item.0.rawValue, systemImage: item.1 ? "circle.fill" : "circle").foregroundStyle(item.1 ? .green : .secondary) } }.font(.caption2) } }
                .padding(.horizontal)
            TabView { TrackpadView(manager: manager).tabItem { Label("Trackpad", systemImage: "rectangle.and.hand.point.up.left") }; LiveKeyboardView(manager: manager).tabItem { Label("Keyboard", systemImage: "keyboard") }; PresetsView(manager: manager).tabItem { Label("Presets", systemImage: "star") }; MacrosView(manager: manager, controller: macros).tabItem { Label("Macros", systemImage: "record.circle") } }
        }
        .navigationTitle(device.displayName).navigationBarTitleDisplayMode(.inline)
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
        VStack { TrackpadInputBridge(move: { x, y in Task { await coalescer.add(x: Int(x * sensitivity), y: Int(y * sensitivity)) } }, scroll: { value in guard manager.supports("mouse_scroll") else { return }; Task { await manager.send(.scroll(Int16(clamping: Int(-value / 5)))) } }, click: { count in UIImpactFeedbackGenerator(style: .light).impactOccurred(); Task { for _ in 0..<count { await manager.send(.click(.left)) } } }, drag: { active in guard manager.supports("mouse_button_state") else { return }; dragging = active; Task { await manager.send(active ? .mouseDown(.left) : .mouseUp(.left)) } }, cancel: { dragging = false; Task { await coalescer.cancel(); await manager.releaseAll() } }).overlay { Text(dragging ? "Dragging" : "Trackpad").foregroundStyle(.secondary).allowsHitTesting(false) }.padding()
            HStack { Button("Left") { Task { await manager.send(.click(.left)) } }; Button("Middle") { Task { await manager.send(.click(.middle)) } }; Button("Right") { Task { await manager.send(.click(.right)) } } }.buttonStyle(.borderedProminent)
            HStack { Text("Sensitivity"); Slider(value: $sensitivity, in: 0.4...2.5) }.padding()
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
                case .deleteBackward: await manager.send(.key("backspace")) } } }.frame(minHeight: 90).padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 12));
            HStack { modifierButton("Ctrl", 0x01); modifierButton("Shift", 0x02); modifierButton("Alt", 0x04); modifierButton("Win/Cmd", 0x08) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 82))]) { ForEach(keys, id: \.self) { key in Button(key.capitalized) { UIImpactFeedbackGenerator(style: .light).impactOccurred(); let prefix = modifierNames; modifiers = 0; Task { await manager.send(prefix.isEmpty ? .key(key) : .keyCombo((prefix + [key]).joined(separator: "+"))) } }.buttonStyle(.bordered) } }; Text("Shortcuts").font(.headline); HStack { ForEach(["ctrl+c", "ctrl+v", "ctrl+x", "ctrl+z", "ctrl+shift+z", "ctrl+a", "ctrl+f", "alt+tab", "ctrl+shift+t", "cmd+space"], id: \.self) { combo in Button(combo) { Task { await manager.send(.keyCombo(combo)) } } }.buttonStyle(.borderedProminent) }.padding() } }
    private var modifierNames: [String] { let values: [(UInt8, String)] = [(0x01, "ctrl"), (0x02, "shift"), (0x04, "alt"), (0x08, "cmd")]; return values.compactMap { modifiers & $0.0 == 0 ? nil : $0.1 } }
    private func modifierButton(_ title: String, _ bit: UInt8) -> some View { Button(title) { modifiers ^= bit }.buttonStyle(.borderedProminent).tint(modifiers & bit == 0 ? .gray : .accentColor).accessibilityValue(modifiers & bit == 0 ? "Off" : "One shot") }
}

struct PresetsView: View {
    @ObservedObject var manager: HIDConnectionManager; @Environment(\.modelContext) private var context; @Query(sort: \HIDPreset.order) private var presets: [HIDPreset]; @State private var name = ""; @State private var payload = ""; @AppStorage("keyboardLayout") private var layoutName = KeyboardLayout.german.rawValue
    var body: some View { NavigationStack { List { Section("New preset") { TextField("Name", text: $name); TextField("Text or shortcut", text: $payload, axis: .vertical); Button("Add Text Preset") { context.insert(HIDPreset(name: name.isEmpty ? "Preset" : name, payload: payload, order: presets.count)); name = ""; payload = "" } }; Section("Presets") { ForEach(presets) { preset in HStack { Button { preset.favorite.toggle() } label: { Image(systemName: preset.favorite ? "star.fill" : "star") }; VStack(alignment: .leading) { TextField("Name", text: Binding(get: { preset.name }, set: { preset.name = $0 })); TextField("Content", text: Binding(get: { preset.payload }, set: { preset.payload = $0 }), axis: .vertical).font(.caption); Toggle("Shortcut", isOn: Binding(get: { preset.shortcut }, set: { preset.shortcut = $0 })); Toggle("Enter after", isOn: Binding(get: { preset.enterAfter }, set: { preset.enterAfter = $0 })); Picker("Typing speed", selection: Binding(get: { preset.typingDelayMs }, set: { preset.typingDelayMs = $0 })) { ForEach([0,10,25,50,100], id: \.self) { Text($0 == 0 ? "Fast" : "\($0) ms").tag($0) } } }; Spacer(); Button("Run") { UIImpactFeedbackGenerator(style: .medium).impactOccurred(); Task { let sent: Bool; if preset.shortcut { sent = await manager.send(.keyCombo(preset.payload)) } else { sent = await manager.sendText(preset.payload, layout: KeyboardLayout(rawValue: layoutName) ?? .german, delayMilliseconds: preset.typingDelayMs) }; if sent && preset.enterAfter { await manager.send(.key("enter")) } } } }.swipeActions { Button(role: .destructive) { context.delete(preset) } label: { Label("Delete", systemImage: "trash") }; Button { context.insert(HIDPreset(name: preset.name + " Copy", payload: preset.payload, shortcut: preset.shortcut, favorite: preset.favorite, order: presets.count, enterAfter: preset.enterAfter, typingDelayMs: preset.typingDelayMs)) } label: { Label("Duplicate", systemImage: "plus.square.on.square") } } }.onMove { source, destination in var ordered = presets; ordered.move(fromOffsets: source, toOffset: destination); for (index, item) in ordered.enumerated() { item.order = index } } } }.toolbar { EditButton() } } }
}

struct MacrosView: View {
    @ObservedObject var manager: HIDConnectionManager; @ObservedObject var controller: MacroController; @Environment(\.modelContext) private var context; @Query(sort: \HIDMacro.createdAt, order: .reverse) private var saved: [HIDMacro]; @State private var speed = 1.0; @State private var repeatCount = 1; @State private var delay = 0; @State private var showSave = false; @State private var macroName = ""; @State private var macroDescription = ""
    var body: some View { VStack { if controller.isPlaying { Button("STOP", role: .destructive) { UINotificationFeedbackGenerator().notificationOccurred(.warning); controller.stop(manager: manager) }.buttonStyle(.borderedProminent).tint(.red).controlSize(.large) }; HStack { Button(controller.isRecording ? "Stop & Save" : "Record") { if controller.isRecording { controller.stopRecording(); macroName = "Macro \(saved.count + 1)"; showSave = true; UIImpactFeedbackGenerator(style: .medium).impactOccurred() } else { controller.startRecording(); UIImpactFeedbackGenerator(style: .medium).impactOccurred() } }.buttonStyle(.borderedProminent); if controller.isRecording { Button("Cancel", role: .cancel) { controller.stopRecording(); controller.recorded = [] } }; TimelineView(.periodic(from: .now, by: 1)) { _ in Text(recordingStatus) } }; Form { Picker("Speed", selection: $speed) { ForEach([0.5, 1, 1.5, 2], id: \.self) { Text("\($0, specifier: "%g")×").tag($0) } }; Picker("Repeat", selection: $repeatCount) { ForEach([1, 2, 5, 10, 0], id: \.self) { Text($0 == 0 ? "Infinite" : "\($0)×").tag($0) } }; Picker("Start delay", selection: $delay) { ForEach([0, 3, 5, 10], id: \.self) { Text("\($0) s").tag($0) } }; Section("Saved") { ForEach(saved) { macro in HStack { VStack(alignment: .leading) { TextField("Name", text: Binding(get: { macro.name }, set: { macro.name = $0 })); Text("\(macro.events.count) events").font(.caption) }; Spacer(); Button("Play") { UIImpactFeedbackGenerator(style: .medium).impactOccurred(); controller.play(macro, speed: speed, repeats: repeatCount == 0 ? nil : repeatCount, delay: Double(delay), manager: manager) } }.swipeActions { Button(role: .destructive) { context.delete(macro) } label: { Label("Delete", systemImage: "trash") }; Button { context.insert(HIDMacro(name: macro.name + " Copy", description: macro.macroDescription, events: macro.events)) } label: { Label("Duplicate", systemImage: "plus.square.on.square") } } } } } } .alert("Save Macro", isPresented: $showSave) { TextField("Name", text: $macroName); TextField("Description (optional)", text: $macroDescription); Button("Save") { context.insert(HIDMacro(name: macroName.isEmpty ? "Macro" : macroName, description: macroDescription, events: controller.recorded)); controller.recorded = [] }; Button("Cancel", role: .cancel) { controller.recorded = [] } } }
    private var recordingStatus: String { guard controller.isRecording else { return "\(controller.recorded.count) events" }; let seconds = Int(controller.recordingDuration); return String(format: "🔴 Recording · %02d:%02d · %d events", seconds / 60, seconds % 60, controller.recorded.count) }
}
