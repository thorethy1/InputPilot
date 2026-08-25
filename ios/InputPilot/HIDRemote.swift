import CoreBluetooth
import Foundation
import Network
import SwiftData
import SwiftUI
import UIKit

enum MouseButton: UInt8, Codable, CaseIterable { case left = 0, right = 1, middle = 2 }
enum HIDEvent: Codable, Equatable {
    case mouseMove(Int16, Int16), scroll(Int16), mouseDown(MouseButton), mouseUp(MouseButton)
    case click(MouseButton), typeText(String), key(String), keyCombo(String), releaseAll, ping

    var prefersLowLatency: Bool {
        switch self { case .mouseMove, .scroll, .mouseDown, .mouseUp, .click, .key, .keyCombo, .releaseAll, .ping: true; case .typeText: false }
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
        case .releaseAll: bytes.append(0x20)
        case .ping: bytes.append(0x7f)
        }
        return Data(bytes)
    }
    var line: String {
        func button(_ b: MouseButton) -> String { String(describing: b) }
        switch self {
        case let .mouseMove(x, y): "move \(x) \(y)"
        case let .scroll(v): "move 0 0 \(v)"
        case let .mouseDown(b): "button \(button(b)) down"
        case let .mouseUp(b): "button \(button(b)) up"
        case let .click(b): "click \(button(b))"
        case let .typeText(t): "type \(t)"
        case let .key(k), let .keyCombo(k): "key \(k)"
        case .releaseAll: "release all"
        case .ping: "ping"
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
    var isAvailable = true
    private let baseURL: URL; private let token: String?; private let session: URLSession
    init(baseURL: URL, token: String?, session: URLSession = .shared) { self.baseURL = baseURL; self.token = token; self.session = session }
    func connect() async {}
    func disconnect() async {}
    func send(_ event: HIDEvent) async throws {
        let path: String; let body: [String: Any]
        switch event {
        case let .mouseMove(x, y): path = "api/move"; body = ["dx": x, "dy": y]
        case let .scroll(v): path = "api/move"; body = ["dx": 0, "dy": 0, "wheel": v]
        case let .click(b): path = "api/click"; body = ["button": String(describing: b)]
        case let .mouseDown(b): path = "api/button"; body = ["button": String(describing: b), "state": "down"]
        case let .mouseUp(b): path = "api/button"; body = ["button": String(describing: b), "state": "up"]
        case let .typeText(text): path = "api/type"; body = ["text": text]
        case let .key(key), let .keyCombo(key): path = "api/key"; body = ["key": key]
        case .releaseAll: path = "api/release-all"; body = [:]
        case .ping: path = "api/status"; body = [:]
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(path)); request.httpMethod = event == .ping ? "GET" : "POST"
        if request.httpMethod == "POST" { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token, !token.isEmpty { request.setValue(token, forHTTPHeaderField: "X-API-Token") }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw TransportError.failed("REST request failed") }
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
        conn.stateUpdateHandler = { [weak self] state in self?.isAvailable = { if case .ready = state { true } else { false } }() }
        conn.start(queue: .main)
        if let token, !token.isEmpty { try? await sendLine("auth \(token)") }
    }
    private func sendLine(_ line: String) async throws {
        guard let connection else { throw TransportError.unavailable }
        try await withCheckedThrowingContinuation { continuation in
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
    private let service = CBUUID(string: "7D9F0001-4F4D-4F56-4552-484944000001")
    private let legacyService = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private let legacyRX = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    private let mouse = CBUUID(string: "7D9F0003-4F4D-4F56-4552-484944000001")
    private let keyboard = CBUUID(string: "7D9F0004-4F4D-4F56-4552-484944000001")
    private let control = CBUUID(string: "7D9F0002-4F4D-4F56-4552-484944000001")
    init(token: String?) { self.token = token; super.init(); central = CBCentralManager(delegate: self, queue: .main) }
    func connect() async { if central.state == .poweredOn { central.scanForPeripherals(withServices: [service, legacyService]) } }
    func centralManagerDidUpdateState(_ central: CBCentralManager) { if central.state == .poweredOn { central.scanForPeripherals(withServices: [service, legacyService]) } }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) { self.peripheral = peripheral; central.stopScan(); central.connect(peripheral) }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) { peripheral.delegate = self; peripheral.discoverServices([service, legacyService]) }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) { isAvailable = false; characteristics.removeAll(); central.scanForPeripherals(withServices: [service, legacyService]) }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) { peripheral.services?.forEach { peripheral.discoverCharacteristics(nil, for: $0) } }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        service.characteristics?.forEach { characteristics[$0.uuid] = $0 }
        if let token, !token.isEmpty, let rx = characteristics[legacyRX] { peripheral.writeValue(Data("auth \(token)".utf8), for: rx, type: .withResponse) }
        isAvailable = characteristics[mouse] != nil && characteristics[keyboard] != nil && characteristics[control] != nil
    }
    func send(_ event: HIDEvent) async throws {
        let uuid: CBUUID = { switch event { case .mouseMove, .scroll, .mouseDown, .mouseUp, .click: mouse; case .typeText, .key, .keyCombo: keyboard; default: control } }()
        guard let peripheral, let characteristic = characteristics[uuid] else { throw TransportError.unavailable }
        peripheral.writeValue(event.binary, for: characteristic, type: .withoutResponse)
    }
    func disconnect() async { if let peripheral { central.cancelPeripheralConnection(peripheral) }; isAvailable = false }
}

@MainActor final class HIDConnectionManager: ObservableObject {
    @Published var mode: ConnectionMode = .automatic
    @Published var activeTransport: TransportKind?
    @Published var lastError: String?
    var onEvent: ((HIDEvent) -> Void)?
    private let ble: HIDControlTransport; private let tcp: HIDControlTransport; private let rest: HIDControlTransport
    init(device: StoredDevice) {
        let host = device.staIP ?? device.mdnsHost
        ble = BLEHIDControlTransport(token: device.apiToken); tcp = TCPHIDControlTransport(host: host, token: device.apiToken)
        rest = RESTHIDControlTransport(baseURL: DeviceEndpointResolver.baseURL(from: host)!, token: device.apiToken)
    }
    func connect() async { await ble.connect(); await tcp.connect(); await rest.connect() }
    func send(_ event: HIDEvent) async {
        onEvent?(event)
        for transport in candidates(for: event) where transport.isAvailable {
            do { try await transport.send(event); activeTransport = transport.kind; lastError = nil; return }
            catch { lastError = error.localizedDescription }
        }
        lastError = "No permitted control transport is available."
    }
    func releaseAll() async { await send(.releaseAll) }
    private func candidates(for event: HIDEvent) -> [HIDControlTransport] {
        switch mode {
        case .bluetoothOnly: return [ble]
        case .wifiOnly: return [event.prefersLowLatency ? tcp : rest, rest, tcp]
        case .preferBluetooth: return [ble, tcp, rest]
        case .preferWiFi: return [tcp, rest, ble]
        case .automatic: return event.prefersLowLatency ? [ble, tcp, rest] : [tcp, rest, ble]
        }
    }
}

@Model final class HIDPreset {
    var name: String; var payload: String; var shortcut: Bool; var favorite: Bool; var order: Int; var enterAfter: Bool; var typingDelayMs: Int
    init(name: String, payload: String, shortcut: Bool = false, favorite: Bool = false, order: Int = 0, enterAfter: Bool = false, typingDelayMs: Int = 0) { self.name = name; self.payload = payload; self.shortcut = shortcut; self.favorite = favorite; self.order = order; self.enterAfter = enterAfter; self.typingDelayMs = typingDelayMs }
}
struct RecordedEvent: Codable { let offset: TimeInterval; let event: HIDEvent }
@Model final class HIDMacro {
    var name: String; var encodedEvents: Data; var createdAt: Date
    init(name: String, events: [RecordedEvent]) { self.name = name; encodedEvents = (try? JSONEncoder().encode(events)) ?? Data(); createdAt = Date() }
    var events: [RecordedEvent] { (try? JSONDecoder().decode([RecordedEvent].self, from: encodedEvents)) ?? [] }
}

@MainActor final class MacroController: ObservableObject {
    @Published var isRecording = false; @Published var isPlaying = false; @Published var recorded: [RecordedEvent] = []
    private var started = Date(); private var playback: Task<Void, Never>?
    func startRecording() { recorded = []; started = Date(); isRecording = true }
    func capture(_ event: HIDEvent) { if isRecording { recorded.append(RecordedEvent(offset: Date().timeIntervalSince(started), event: event)) } }
    func stopRecording() { isRecording = false }
    func play(_ macro: HIDMacro, speed: Double, repeats: Int?, delay: Double, manager: HIDConnectionManager) {
        stop(manager: manager); isPlaying = true
        playback = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay)); var iteration = 0
            while !Task.isCancelled && (repeats == nil || iteration < repeats!) {
                var previous = 0.0
                for item in macro.events { if Task.isCancelled { break }; try? await Task.sleep(for: .seconds(max(0, item.offset - previous) / speed)); previous = item.offset; await manager.send(item.event) }
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
            HStack { Circle().fill(manager.activeTransport == nil ? .orange : .green).frame(width: 9, height: 9); Text(manager.activeTransport.map { "Connected · \($0.rawValue)" } ?? "Connecting…").font(.caption); Spacer(); Picker("Connection", selection: $manager.mode) { ForEach(ConnectionMode.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden() }
                .padding(.horizontal)
            TabView { TrackpadView(manager: manager).tabItem { Label("Trackpad", systemImage: "rectangle.and.hand.point.up.left") }; LiveKeyboardView(manager: manager).tabItem { Label("Keyboard", systemImage: "keyboard") }; PresetsView(manager: manager).tabItem { Label("Presets", systemImage: "star") }; MacrosView(manager: manager, controller: macros).tabItem { Label("Macros", systemImage: "record.circle") } }
        }
        .navigationTitle(device.displayName).navigationBarTitleDisplayMode(.inline)
        .task { manager.onEvent = { macros.capture($0) }; await manager.connect() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in macros.stop(manager: manager) }
    }
}

struct TrackpadView: View {
    @ObservedObject var manager: HIDConnectionManager; @State private var previous = CGSize.zero; @State private var dragging = false; @AppStorage("trackpadSensitivity") private var sensitivity = 1.0
    var body: some View {
        VStack { GeometryReader { _ in RoundedRectangle(cornerRadius: 18).fill(.quaternary).overlay(Text(dragging ? "Dragging" : "Trackpad").foregroundStyle(.secondary))
                .contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 1).onChanged { value in let dx = (value.translation.width - previous.width) * sensitivity; let dy = (value.translation.height - previous.height) * sensitivity; previous = value.translation; Task { await manager.send(.mouseMove(Int16(clamping: Int(dx)), Int16(clamping: Int(dy)))) } }.onEnded { _ in previous = .zero; if dragging { dragging = false; Task { await manager.send(.mouseUp(.left)) } } }).onTapGesture(count: 2) { Task { await manager.send(.click(.left)); await manager.send(.click(.left)) } }.onTapGesture { UIImpactFeedbackGenerator(style: .light).impactOccurred(); Task { await manager.send(.click(.left)) } }.onLongPressGesture { dragging = true; Task { await manager.send(.mouseDown(.left)) } }
        }.padding()
            HStack { Button("Left") { Task { await manager.send(.click(.left)) } }; Button("Middle") { Task { await manager.send(.click(.middle)) } }; Button("Right") { Task { await manager.send(.click(.right)) } } }.buttonStyle(.borderedProminent)
            HStack { Text("Sensitivity"); Slider(value: $sensitivity, in: 0.4...2.5) }.padding()
        }
    }
}

struct LiveKeyboardView: View {
    @ObservedObject var manager: HIDConnectionManager; @State private var text = ""; @AppStorage("keyboardLayout") private var layout = "German QWERTZ"
    let keys = ["esc", "tab", "enter", "backspace", "delete", "home", "end", "pageup", "pagedown", "left", "up", "down", "right"]
    var body: some View { ScrollView { VStack { Picker("Layout", selection: $layout) { Text("German QWERTZ").tag("German QWERTZ"); Text("US QWERTY").tag("US QWERTY") }.pickerStyle(.segmented); TextField("Type on the connected computer", text: $text).textFieldStyle(.roundedBorder).onChange(of: text) { old, new in guard new.count > old.count else { return }; let typed = String(new.dropFirst(old.count)); Task { await manager.send(.typeText(typed)) } }; LazyVGrid(columns: [GridItem(.adaptive(minimum: 82))]) { ForEach(keys, id: \.self) { key in Button(key.capitalized) { Task { await manager.send(.key(key)) } }.buttonStyle(.bordered) } }; Text("Shortcuts").font(.headline); HStack { ForEach(["ctrl+c", "ctrl+v", "ctrl+x", "cmd+space"], id: \.self) { combo in Button(combo) { Task { await manager.send(.keyCombo(combo)) } } } }.buttonStyle(.borderedProminent) }.padding() } }
}

struct PresetsView: View {
    @ObservedObject var manager: HIDConnectionManager; @Environment(\.modelContext) private var context; @Query(sort: \HIDPreset.order) private var presets: [HIDPreset]; @State private var name = ""; @State private var payload = ""
    var body: some View { NavigationStack { List { Section("New preset") { TextField("Name", text: $name); TextField("Text or shortcut", text: $payload); Button("Add Text Preset") { context.insert(HIDPreset(name: name.isEmpty ? "Preset" : name, payload: payload, order: presets.count)); name = ""; payload = "" } }; Section("Presets") { ForEach(presets) { preset in HStack { Button { preset.favorite.toggle() } label: { Image(systemName: preset.favorite ? "star.fill" : "star") }; VStack(alignment: .leading) { Text(preset.name); Text(preset.payload).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Run") { Task { await manager.send(preset.shortcut ? .keyCombo(preset.payload) : .typeText(preset.payload)); if preset.enterAfter { await manager.send(.key("enter")) } } } }.swipeActions { Button(role: .destructive) { context.delete(preset) } label: { Label("Delete", systemImage: "trash") }; Button { context.insert(HIDPreset(name: preset.name + " Copy", payload: preset.payload, shortcut: preset.shortcut, order: presets.count)) } label: { Label("Duplicate", systemImage: "plus.square.on.square") } } }.onMove { source, destination in var ordered = presets; ordered.move(fromOffsets: source, toOffset: destination); for (index, item) in ordered.enumerated() { item.order = index } } } }.toolbar { EditButton() } } }
}

struct MacrosView: View {
    @ObservedObject var manager: HIDConnectionManager; @ObservedObject var controller: MacroController; @Environment(\.modelContext) private var context; @Query(sort: \HIDMacro.createdAt, order: .reverse) private var saved: [HIDMacro]; @State private var speed = 1.0; @State private var repeatCount = 1; @State private var delay = 0
    var body: some View { VStack { if controller.isPlaying { Button("STOP", role: .destructive) { controller.stop(manager: manager) }.buttonStyle(.borderedProminent).tint(.red).controlSize(.large) }; HStack { Button(controller.isRecording ? "Stop Recording" : "Record") { if controller.isRecording { controller.stopRecording(); context.insert(HIDMacro(name: "Macro \(saved.count + 1)", events: controller.recorded)) } else { controller.startRecording() } }.buttonStyle(.borderedProminent); Text("\(controller.recorded.count) events") }; Form { Picker("Speed", selection: $speed) { ForEach([0.5, 1, 1.5, 2], id: \.self) { Text("\($0, specifier: "%g")×").tag($0) } }; Picker("Repeat", selection: $repeatCount) { ForEach([1, 2, 5, 10, 0], id: \.self) { Text($0 == 0 ? "Infinite" : "\($0)×").tag($0) } }; Picker("Start delay", selection: $delay) { ForEach([0, 3, 5, 10], id: \.self) { Text("\($0) s").tag($0) } }; Section("Saved") { ForEach(saved) { macro in HStack { VStack(alignment: .leading) { Text(macro.name); Text("\(macro.events.count) events").font(.caption) }; Spacer(); Button("Play") { controller.play(macro, speed: speed, repeats: repeatCount == 0 ? nil : repeatCount, delay: Double(delay), manager: manager) } }.swipeActions { Button(role: .destructive) { context.delete(macro) } label: { Label("Delete", systemImage: "trash") } } } } } } }
}
