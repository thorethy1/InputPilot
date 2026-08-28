import Foundation
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \StoredDevice.displayName) private var storedDevices: [StoredDevice]
    @StateObject private var viewModel = HomeViewModel()

    @State private var showAddByAddress = false
    @State private var showAddWizard = false

    var body: some View {
        TabView {
          NavigationStack {
            Group {
                if storedDevices.isEmpty {
                    emptyState
                } else {
                    deviceList
                }
            }
            .navigationTitle("InputPilot")
            .toolbar { toolbarContent }
            .refreshable {
                await viewModel.refreshAll(devices: storedDevices, context: modelContext)
            }
            .alert("Error", isPresented: errorAlertBinding) {
                Button("OK") { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .sheet(isPresented: $showAddByAddress) {
                AddByAddressSheet()
            }
            .sheet(isPresented: $showAddWizard) {
                AddDeviceWizardView()
            }
          }
          .tabItem { Label("Devices", systemImage: "computermouse") }
          NavigationStack { ControlRootView(devices: storedDevices) }
            .tabItem { Label("Control", systemImage: "rectangle.and.hand.point.up.left") }
          NavigationStack { FirmwareRootView(devices: storedDevices) }
            .tabItem { Label("Firmware", systemImage: "arrow.triangle.2.circlepath") }
          NavigationStack { ConnectionSettingsView() }
            .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(AppColors.primary)
        .environmentObject(viewModel)
        .task(id: storedDevices.map(\.deviceId)) {
            while !Task.isCancelled {
                await viewModel.refreshQuietly(devices: storedDevices, context: modelContext)
                try? await Task.sleep(nanoseconds: HomeViewModel.presencePollNanoseconds)
            }
        }
    }

    private var deviceList: some View {
        List(storedDevices) { device in
            NavigationLink {
                DeviceDetailView(device: device)
            } label: {
                DeviceRowView(
                    device: device,
                    wifiState: viewModel.wifiState(for: device.deviceId)
                )
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Devices Yet", systemImage: "computermouse")
        } description: {
            Text("InputPilot can connect over Bluetooth or Wi-Fi. Bluetooth works nearby without Wi-Fi or an internet connection.")
        } actions: {
            Button("Add Device") {
                showAddWizard = true
            }
            .buttonStyle(.borderedProminent)

            Button("Add by Address") {
                showAddByAddress = true
            }
            .buttonStyle(.bordered)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    showAddWizard = true
                } label: {
                    Label("Add Device", systemImage: "plus")
                }
                Button {
                    showAddByAddress = true
                } label: {
                    Label("Add by Address", systemImage: "network")
                }
            } label: {
                Image(systemName: "plus")
            }
        }
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }
}

private struct DeviceRowView: View {
    let device: StoredDevice
    let wifiState: WiFiReachabilityState
    @ObservedObject private var bluetooth: BLEHIDControlTransport

    init(device: StoredDevice, wifiState: WiFiReachabilityState) {
        self.device = device
        self.wifiState = wifiState
        _bluetooth = ObservedObject(wrappedValue: InputPilotBluetoothManager.session(deviceId: device.deviceId, token: device.apiToken))
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(presence.color)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(device.displayName)
                    .font(.headline)
                Text(presence.title)
                    .font(.subheadline)
                    .foregroundStyle(presence.color)
                Text(presence.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(device.displayName), \(presence.title), \(presence.detail)")
        }
        .padding(.vertical, 2)
        .task { await bluetooth.connect() }
    }

    private var presence: DevicePresenceStatus {
        DevicePresenceStatus.resolve(
            wifi: wifiState,
            bluetooth: bluetooth.state,
            hasConfiguredWiFi: !DeviceEndpointResolver.endpointURLs(mdnsHost: device.mdnsHost, staIP: device.staIP).isEmpty
        )
    }
}

private struct LiveDeviceStatusView: View {
    let device: StoredDevice
    @EnvironmentObject private var viewModel: HomeViewModel
    @ObservedObject private var bluetooth: BLEHIDControlTransport

    init(device: StoredDevice) {
        self.device = device
        _bluetooth = ObservedObject(wrappedValue: InputPilotBluetoothManager.session(deviceId: device.deviceId, token: device.apiToken))
    }

    private var presence: DevicePresenceStatus {
        DevicePresenceStatus.resolve(
            wifi: viewModel.wifiState(for: device.deviceId),
            bluetooth: bluetooth.state,
            hasConfiguredWiFi: !DeviceEndpointResolver.endpointURLs(mdnsHost: device.mdnsHost, staIP: device.staIP).isEmpty
        )
    }

    var body: some View {
        HStack {
            Label(presence.title, systemImage: presence.isUsable ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(presence.color)
            Spacer()
            Text(presence.detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
        .task { await bluetooth.connect() }
    }
}

private struct ControlRootView: View {
    let devices: [StoredDevice]
    @AppStorage("selectedDeviceId") private var selectedDeviceId = ""
    private var selected: StoredDevice? { devices.first { $0.deviceId == selectedDeviceId } ?? devices.first }
    var body: some View {
        Group {
            if let selected {
                List {
                    Section("Active device") { Picker("Device", selection: $selectedDeviceId) { ForEach(devices) { Text($0.displayName).tag($0.deviceId) } } }
                    Section("Connection") { LiveDeviceStatusView(device: selected) }
                    Section { NavigationLink { HIDControlView(device: selected) } label: { Label("Open Trackpad, Keyboard, Presets & Macros", systemImage: "computermouse") } }
                }
            } else { ContentUnavailableView("Select an InputPilot device", systemImage: "computermouse", description: Text("Add a device in the Devices tab first.")) }
        }.navigationTitle("Control").onAppear { if selectedDeviceId.isEmpty { selectedDeviceId = devices.first?.deviceId ?? "" } }
    }
}

private struct FirmwareRootView: View {
    let devices: [StoredDevice]
    @AppStorage("selectedDeviceId") private var selectedDeviceId = ""
    private var selected: StoredDevice? { devices.first { $0.deviceId == selectedDeviceId } ?? devices.first }
    var body: some View {
        Group {
            if let selected { FirmwareDeviceView(device: selected, devices: devices, selection: $selectedDeviceId).id(selected.deviceId) }
            else { ContentUnavailableView("Select an InputPilot device", systemImage: "arrow.triangle.2.circlepath", description: Text("Select an InputPilot device to view firmware information and updates.")) }
        }.navigationTitle("Firmware").onAppear { if selectedDeviceId.isEmpty { selectedDeviceId = devices.first?.deviceId ?? "" } }
    }
}

private struct FirmwareDeviceView: View {
    @Bindable var device: StoredDevice
    let devices: [StoredDevice]
    @Binding var selection: String
    private let transport: BLEHIDControlTransport
    @StateObject private var updater: FirmwareUpdateManager
    @StateObject private var releaseSource = GitHubFirmwareSource()
    @State private var importing = false
    @State private var selectedData: Data?
    @State private var selectedName = ""
    @State private var targetVersion = ""
    @State private var manualValidationError: String?
    private let appVersion = AppVersionInfo.read().version
    @AppStorage("connectionMode") private var connectionModeRaw = ConnectionMode.automatic.rawValue
    init(device: StoredDevice, devices: [StoredDevice], selection: Binding<String>) {
        self.device = device; self.devices = devices; _selection = selection
        let transport = InputPilotBluetoothManager.session(deviceId: device.deviceId, token: device.apiToken)
        transport.metadataHandler = { [weak device] metadata in
            guard let device, metadata.deviceId.lowercased() == device.deviceId.lowercased() else { return }
            DeviceMerge.bluetooth(metadata, token: nil, into: device)
        }
        self.transport = transport; _updater = StateObject(wrappedValue: transport.firmwareUpdater)
    }
    var body: some View {
        Form {
            Section("Firmware") {
                Picker("Device", selection: $selection) { ForEach(devices) { Text($0.displayName).tag($0.deviceId) } }
                LiveDeviceStatusView(device: device)
                LabeledContent("Installed firmware", value: device.firmwareVersion ?? "Unknown")
                LabeledContent("Latest firmware", value: releaseSource.manifest?.version ?? "Not checked")
                LabeledContent("Update status", value: releaseSource.status.title)
                if let detail = releaseSource.status.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Firmware Update") {
                if device.protocolVersion > FirmwareReleaseEvaluator.supportedProtocol {
                    Label("This device firmware requires a newer version of InputPilot.", systemImage: "app.badge").foregroundStyle(AppColors.warning)
                } else if device.otaSchema < 1 {
                    Label("This device needs a one-time USB migration before firmware updates can be installed.", systemImage: "cable.connector").foregroundStyle(.secondary)
                } else if !device.capabilities.isEmpty && !device.capabilities.contains("ble_ota") && !device.capabilities.contains("wifi_ota") {
                    Label("The installed firmware does not provide a supported update transport.", systemImage: "exclamationmark.triangle").foregroundStyle(AppColors.warning)
                } else {
                    Button("Check for Updates") { Task { await releaseSource.check(installed: device.firmwareVersion, deviceOTASchema: device.otaSchema, appVersion: appVersion) } }
                    if releaseSource.status.canDownload { Button("Download Firmware \(releaseSource.manifest?.version ?? "")") { Task { if let result = await releaseSource.downloadFirmware() { selectedData = result; selectedName = "firmware.bin"; targetVersion = releaseSource.manifest?.version ?? ""; manualValidationError = nil } } }.buttonStyle(.borderedProminent) }
                    if let error = releaseSource.errorMessage { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(AppColors.warning) }
                    if let selectedData { LabeledContent("File", value: selectedName); LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(selectedData.count), countStyle: .file)) }
                    if let manualValidationError { Label(manualValidationError, systemImage: "exclamationmark.triangle").foregroundStyle(AppColors.warning) }
                    Button("Choose Firmware File") { importing = true }
                    if selectedData != nil { TextField("Firmware version", text: $targetVersion).textInputAutocapitalization(.never).autocorrectionDisabled() }
                    if let selectedData { Button("Update Firmware") { updater.configure(device: device, mode: ConnectionMode(rawValue: connectionModeRaw) ?? .automatic); Task { await updater.install(selectedData, version: targetVersion, expectedSHA256: releaseSource.manifest?.version == targetVersion ? releaseSource.manifest?.sha256 : nil) } }.buttonStyle(.borderedProminent).disabled(targetVersion.isEmpty) }
                }
            }
            if updater.state != .idle {
                Section("Update status") {
                    ProgressView(value: updater.progress)
                    Text(statusText).accessibilityLabel("Firmware update status: \(statusText)")
                    if let transport = updater.activeTransport { LabeledContent("Transport", value: transport.rawValue) }
                    if updater.totalBytes > 0 { Text("\(Int(updater.progress * 100))% · \(ByteCountFormatter.string(fromByteCount: Int64(updater.bytesSent), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(updater.totalBytes), countStyle: .file)) · \(ByteCountFormatter.string(fromByteCount: Int64(updater.bytesPerSecond), countStyle: .file))/s").font(.caption).foregroundStyle(.secondary) }
                    if case .transferring = updater.state { Button("Cancel", role: .cancel) { updater.cancel() }.tint(AppColors.primary) }
                }
            }
        }
        .task { updater.configure(device: device, mode: ConnectionMode(rawValue: connectionModeRaw) ?? .automatic); await transport.connect() }
        .onChange(of: updater.state) { _, state in
            guard state == .completed, let installed = updater.installedVersion ?? (targetVersion.isEmpty ? nil : targetVersion) else { return }
            device.firmwareVersion = installed
            releaseSource.reconcile(installed: installed, deviceOTASchema: device.otaSchema, appVersion: appVersion)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "bin") ?? .data]) { result in
            guard case let .success(url) = result, url.pathExtension.lowercased() == "bin", url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let data = try? Data(contentsOf: url) else { return }
            selectedData = data; selectedName = url.lastPathComponent
            do { targetVersion = try FirmwareImageMetadata.parseAndValidate(data).version; manualValidationError = nil }
            catch { targetVersion = ""; manualValidationError = error.localizedDescription }
        }
    }
    private var statusText: String { switch updater.state { case .idle: "Ready"; case .checking: "Checking…"; case .connecting: "Connecting…"; case .authenticating: "Authenticating…"; case .preparing: "Preparing…"; case .transferring: "Updating firmware…"; case .waitingForFinalAck: "Waiting for final acknowledgement…"; case .verifying: "Verifying firmware…"; case .installing: "Installing firmware…"; case .rebooting: "Restarting InputPilot…"; case .reconnecting: "Reconnecting…"; case .verifyingInstalledVersion: "Verifying installed firmware…"; case .completed: "Firmware updated successfully"; case .cancelled: "Update cancelled. Existing firmware remains installed."; case let .failed(message): message } }
}

@MainActor final class GitHubFirmwareSource: ObservableObject {
    static let manifestAssetName = "firmware-manifest.json"
    static let firmwareAssetName = "firmware.bin"
    @Published var manifest: FirmwareManifest?
    @Published var status = FirmwareReleaseStatus.notChecked
    @Published var errorMessage: String?
    private var firmwareURL: URL?
    func reconcile(installed: String?, deviceOTASchema: Int, appVersion: String) {
        guard let manifest else { return }
        status = FirmwareReleaseEvaluator.evaluate(installed: installed, manifest: manifest, deviceOTASchema: deviceOTASchema, appVersion: appVersion)
    }
    func check(installed: String?, deviceOTASchema: Int, appVersion: String) async {
        errorMessage = nil; manifest = nil; firmwareURL = nil; status = .checking
        do {
            let url = URL(string: "https://api.github.com/repos/thorethy1/InputPilot/releases/latest")!
            var request = URLRequest(url: url); request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let assets = json["assets"] as? [[String: Any]],
                  let manifestString = assets.first(where: { $0["name"] as? String == Self.manifestAssetName })?["browser_download_url"] as? String,
                  let firmwareString = assets.first(where: { $0["name"] as? String == Self.firmwareAssetName })?["browser_download_url"] as? String,
                  let manifestURL = URL(string: manifestString), let imageURL = URL(string: firmwareString) else { throw URLError(.badServerResponse) }
            let (manifestData, manifestResponse) = try await URLSession.shared.data(from: manifestURL)
            guard (manifestResponse as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) == true else { throw URLError(.badServerResponse) }
            let decoded = try JSONDecoder().decode(FirmwareManifest.self, from: manifestData)
            let evaluated = FirmwareReleaseEvaluator.evaluate(installed: installed, manifest: decoded, deviceOTASchema: deviceOTASchema, appVersion: appVersion)
            manifest = decoded; status = evaluated
            if evaluated.canDownload {
                try FirmwareManifestValidator.validate(decoded)
                firmwareURL = imageURL
            }
        } catch {
            let message = "Could not check the latest firmware release."
            errorMessage = message; status = .unavailable(message)
        }
    }
    func downloadFirmware() async -> Data? {
        guard status.canDownload, let firmwareURL, let manifest else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: firmwareURL)
            guard (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) == true else { throw URLError(.badServerResponse) }
            try FirmwareManifestValidator.validate(manifest, firmware: data)
            return data
        } catch { errorMessage = "Could not download the firmware image."; return nil }
    }
}

private struct ConnectionSettingsView: View {
    @Query(sort: \StoredDevice.displayName) private var devices: [StoredDevice]
    @AppStorage("selectedDeviceId") private var selectedDeviceId = ""
    @AppStorage("connectionMode") private var mode = ConnectionMode.automatic.rawValue
    private var selected: StoredDevice? { devices.first { $0.deviceId == selectedDeviceId } ?? devices.first }
    private let appVersion = AppVersionInfo.read()
    var body: some View {
        Form {
            Section("Connection") {
                if let selected { LiveDeviceStatusView(device: selected) }
                Picker("Default transport", selection: $mode) { ForEach(ConnectionMode.allCases) { Text($0.rawValue).tag($0.rawValue) } }
                Text(explanation).font(.caption).foregroundStyle(.secondary)
            }
            if let selected, PairingKeyStore.load(deviceId: selected.deviceId) == nil {
                Section("Security") {
                    Label("Communication with \(selected.displayName) may be unencrypted.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppColors.warning)
                    NavigationLink("Migrate to encrypted connections") { SecurityMigrationGuideView() }
                }
            }
            Section("Diagnostics") {
                NavigationLink("Pair InputPilot by USB") { USBPairingInputTestView() }
                NavigationLink("Security Migration Guide") { SecurityMigrationGuideView() }
                if let selected { NavigationLink("Firmware Logs") { FirmwareLogsView(device: selected, devices: devices, selection: $selectedDeviceId).id(selected.deviceId) } }
                else { LabeledContent("Firmware Logs", value: "Add a device first") }
                NavigationLink("App Logs") { AppLogsView() }
                if let selected { NavigationLink("Export Diagnostics") { DiagnosticsExportView(device: selected) } }
            }
            Section("About") {
                LabeledContent("App Version", value: appVersion.version)
                LabeledContent("Build", value: appVersion.build)
                LabeledContent("App Commit", value: appVersion.commit)
                if let selected {
                    if devices.count > 1 { Picker("Device", selection: $selectedDeviceId) { ForEach(devices) { Text($0.displayName).tag($0.deviceId) } } }
                    LabeledContent("Firmware", value: selected.firmwareVersion ?? "Unknown")
                    LabeledContent("Protocol", value: String(selected.protocolVersion))
                    LabeledContent("OTA Schema", value: String(selected.otaSchema))
                    if let lastSeen = selected.lastSeen { LabeledContent("Last seen", value: lastSeen.formatted(date: .abbreviated, time: .shortened)) }
                }
            }
            Section("Appearance") { Label("InputPilot uses the native iOS interface with a red brand accent. Status colors remain semantic.", systemImage: "paintpalette") }
        }.navigationTitle("Settings").onAppear { if selectedDeviceId.isEmpty { selectedDeviceId = devices.first?.deviceId ?? "" } }
    }
    private var explanation: String { switch ConnectionMode(rawValue: mode) ?? .automatic { case .automatic: "Uses Bluetooth first for interactive controls and Wi-Fi first for bulk work, then falls back to another ready transport."; case .preferBluetooth: "Uses ready Bluetooth first, then falls back to Wi-Fi."; case .preferWiFi: "Uses ready Wi-Fi first, then falls back to Bluetooth."; case .bluetoothOnly: "Uses only an authenticated, ready Bluetooth connection."; case .wifiOnly: "Uses encrypted TCP for paired devices. REST is retained only for unpaired legacy devices." } }
}

struct USBPairingInputTestView: View {
    var onPaired: ((String) -> Void)? = nil
    var embedded = false
    var continueAction: (() -> Void)? = nil
    @State private var captured = ""
    @State private var result: ResultState = .waiting
    @State private var pairedDeviceId = ""
    private enum ResultState: Equatable { case waiting, valid, invalid, storageFailed }

    var body: some View {
        Form {
            Section("Secure USB pairing") {
                Text("Connect InputPilot to this iPhone, wait for it to power on, then hold BOOT for two seconds. InputPilot types a one-time, 128-bit pairing credential into the focused field below.")
                KeyboardInputBridge(autoFocus: true) { event in
                    switch event {
                    case let .insert(text): receive(text)
                    case .deleteBackward: if !captured.isEmpty { captured.removeLast() }
                    }
                }
                .frame(height: 44)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary))
                LabeledContent("Received", value: "\(captured.count) characters")
                switch result {
                case .waiting:
                    Text("Waiting for InputPilot…").foregroundStyle(.secondary)
                case .valid:
                    Label("Paired securely with \(pairedDeviceId)", systemImage: "checkmark.shield.fill").foregroundStyle(.green)
                case .invalid:
                    Label("Input was received, but it was not a valid InputPilot pairing frame", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .storageFailed:
                    Label("The credential could not be saved in Keychain", systemImage: "exclamationmark.shield.fill").foregroundStyle(.red)
                }
                Button("Pair another device") { captured = ""; pairedDeviceId = ""; result = .waiting }
                if result == .valid, let continueAction {
                    Button("Continue with Encrypted Bluetooth") { continueAction() }
                        .buttonStyle(.borderedProminent)
                }
            }
            Section("Safety") {
                Text("The credential is saved only in this iPhone’s Keychain. It is cleared from the input field immediately and is never written to app logs. Generating a new code on InputPilot invalidates its previous pairing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(embedded ? "Secure Setup" : "Secure Pairing")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func receive(_ text: String) {
        guard result == .waiting else { return }
        for character in text.uppercased() {
            if character == "\n" || character == "\r" {
                validateAndClear()
            } else if "0123456789ABCDEFIPR".contains(character) {
                if captured.count < 80 { captured.append(character) }
            }
        }
    }

    private func validateAndClear() {
        let value = captured
        captured = ""
        guard let frame = PairingInputFrame(encoded: value) else {
            result = .invalid
            return
        }
        do {
            try PairingKeyStore.save(frame.secret, deviceId: frame.deviceId)
            pairedDeviceId = frame.deviceId
            result = .valid
            onPaired?(frame.deviceId)
            Task { await InputPilotBluetoothManager.removeSession(deviceId: frame.deviceId) }
        } catch {
            result = .storageFailed
        }
    }
}

struct SecurityMigrationGuideView: View {
    var body: some View {
        List {
            Section("Before pairing") {
                Label("Install firmware with secure_channel_v1 before creating the pairing code.", systemImage: "1.circle")
                Label("Legacy BLE, Wi-Fi TCP, REST, and API-token connections may transmit control data without encryption.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppColors.warning)
            }
            Section("Migrate") {
                Label("Update InputPilot to the current firmware.", systemImage: "2.circle")
                Label("Connect it directly to this iPhone or to a computer by USB.", systemImage: "3.circle")
                Label("Open Secure Pairing, focus the input field, then hold BOOT for two seconds. The complete frame can also be typed manually.", systemImage: "4.circle")
                Label("The 128-bit secret is stored only in this iPhone's Keychain. Creating another code invalidates the previous one.", systemImage: "5.circle")
            }
            Section("After pairing") {
                Label("Bluetooth uses BLE link encryption and the authenticated InputPilot secure channel.", systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                Label("Wi-Fi control uses the authenticated encrypted channel. Paired firmware rejects plaintext REST control.", systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                Text("If the key is lost, create a new pairing code over USB. Pair every iPhone again because the old code becomes invalid.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                NavigationLink("Pair InputPilot by USB") { USBPairingInputTestView() }
            }
        }
        .navigationTitle("Security Migration")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AppLogsView: View {
    @ObservedObject private var log = AppLog.shared
    @State private var filter = AppLogCategory.all
    @State private var paused = false
    @State private var frozen: [AppLogRecord] = []
    private var source: [AppLogRecord] { paused ? frozen : log.records }
    private var visible: [AppLogRecord] { source.filter { $0.matches(filter) } }
    private var text: String { source.map(\.line).joined(separator: "\n") }
    var body: some View {
        VStack(spacing: 0) {
            Picker("Filter", selection: $filter) { ForEach(AppLogCategory.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu).padding()
            ScrollViewReader { proxy in ScrollView { LazyVStack(alignment: .leading, spacing: 4) { ForEach(visible) { entry in Text(entry.line).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).id(entry.id) } }.padding() }.onChange(of: visible.count) { _, _ in if !paused, let last = visible.last { proxy.scrollTo(last.id, anchor: .bottom) } } }
        }
        .navigationTitle("App Logs").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItemGroup(placement: .topBarTrailing) { Button(paused ? "Resume" : "Pause") { if !paused { frozen = log.records }; paused.toggle() }; Button { log.clear(); frozen = [] } label: { Image(systemName: "trash") }; Button { UIPasteboard.general.string = text } label: { Image(systemName: "doc.on.doc") }; ShareLink(item: text) { Image(systemName: "square.and.arrow.up") } } }
    }
}

private struct DiagnosticsExportView: View {
    let device: StoredDevice
    private let app = AppVersionInfo.read()
    @StateObject private var diagnostics: FirmwareDiagnosticsManager
    @State private var exporting = false
    init(device: StoredDevice) { self.device = device; _diagnostics = StateObject(wrappedValue: FirmwareDiagnosticsManager(device: device, mode: ConnectionMode(rawValue: UserDefaults.standard.string(forKey: "connectionMode") ?? "") ?? .automatic)) }
    private var text: String {
        let metadata = diagnostics.metadata
        let hid = metadata?.hid
        return ["InputPilot diagnostics", "App Version: \(app.version)", "App Build: \(app.build)", "App Commit: \(app.commit)", "Firmware Version: \(device.firmwareVersion ?? "Unknown")", "Firmware Commit: \(metadata?.firmwareCommit ?? "Unknown")", "Device ID: \(device.deviceId)", "Connection Mode: \(UserDefaults.standard.string(forKey: "connectionMode") ?? ConnectionMode.automatic.rawValue)", "Diagnostics Transport: \(diagnostics.status)", "Capabilities: \(device.capabilities.joined(separator: ","))", "Running Partition: \(device.runningPartition ?? "Unknown")", "Reset Reason: \(metadata?.resetReason ?? "Unknown")", "HID decoded/queued/executed/failed: \(hid?.decoded ?? 0)/\(hid?.queued ?? 0)/\(hid?.executed ?? 0)/\(hid?.failed ?? 0)", "USB reports attempted/succeeded/failed: \(hid?.usbReportsAttempted ?? 0)/\(hid?.usbReportsSucceeded ?? 0)/\(hid?.usbReportsFailed ?? 0)", "Last HID source/type/sequence/phase: \(hid?.lastSource ?? "Unknown")/\(hid?.lastType ?? "Unknown")/\(hid?.lastSequence ?? 0)/\(hid?.lastPhase ?? "Unknown")", "Previous HID breadcrumb valid/sequence/source/phase: \(hid?.previousBreadcrumbValid ?? false)/\(hid?.previousSequence ?? 0)/\(hid?.previousSource ?? "Unknown")/\(hid?.previousPhase ?? 0)", "", "App Logs:", AppLog.shared.records.map(\.line).joined(separator: "\n"), "", "Firmware Logs:", diagnostics.lines.map(\.raw).joined(separator: "\n")].joined(separator: "\n")
    }
    var body: some View { Form { Section { LabeledContent("Status", value: diagnostics.status); Text("The export excludes API tokens, Wi-Fi passwords, and typed text.").foregroundStyle(.secondary); Button("Export inputpilot-diagnostics.txt") { exporting = true } } }.navigationTitle("Export Diagnostics").fileExporter(isPresented: $exporting, document: FirmwareLogDocument(text: text), contentType: .plainText, defaultFilename: "inputpilot-diagnostics.txt") { _ in }.task { diagnostics.start() }.onDisappear { diagnostics.stop() } }
}

private struct FirmwareLogDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = configuration.file.regularFileContents.flatMap { String(data: $0, encoding: .utf8) } ?? "" }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}

private struct FirmwareLogsView: View {
    let device: StoredDevice; let devices: [StoredDevice]; @Binding var selection: String
    @StateObject private var manager: FirmwareDiagnosticsManager
    @State private var filter = FirmwareLogFilter.all
    @State private var exporting = false
    init(device: StoredDevice, devices: [StoredDevice], selection: Binding<String>) { self.device = device; self.devices = devices; _selection = selection; _manager = StateObject(wrappedValue: FirmwareDiagnosticsManager(device: device, mode: ConnectionMode(rawValue: UserDefaults.standard.string(forKey: "connectionMode") ?? "") ?? .automatic)) }
    private var visible: [FirmwareLogLine] { manager.lines.filter { $0.matches(filter) } }
    private var allText: String { manager.lines.map(\.raw).joined(separator: "\n") }
    var body: some View {
        VStack(spacing: 0) {
            Form {
                if devices.count > 1 { Picker("Device", selection: $selection) { ForEach(devices) { Text($0.displayName).tag($0.deviceId) } } }
                LabeledContent("Connection", value: manager.status)
                if let metadata = manager.metadata { LabeledContent("Firmware Commit", value: metadata.firmwareCommit ?? "Unknown"); LabeledContent("Reset Reason", value: metadata.resetReason ?? "Unknown") }
                Picker("Filter", selection: $filter) { ForEach(FirmwareLogFilter.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu)
            }.frame(maxHeight: devices.count > 1 ? 170 : 125)
            ScrollViewReader { proxy in
                ScrollView { LazyVStack(alignment: .leading, spacing: 4) { ForEach(visible) { line in Text(line.raw).font(.system(.caption, design: .monospaced)).textSelection(.enabled).foregroundStyle(line.level == "ERROR" ? .red : line.level == "WARN" ? .orange : .primary).frame(maxWidth: .infinity, alignment: .leading).id(line.id) } }.padding() }
                    .background(.black.opacity(0.04))
                    .onChange(of: visible.count) { _, _ in if !manager.paused, let last = visible.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
            }
        }
        .navigationTitle("Firmware Logs").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItemGroup(placement: .topBarTrailing) { Button(manager.paused ? "Resume" : "Pause") { manager.setPaused(!manager.paused) }; Button { manager.clear() } label: { Image(systemName: "trash") }; Button { UIPasteboard.general.string = allText } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel("Copy All"); ShareLink(item: allText) { Image(systemName: "square.and.arrow.up") }; Button { exporting = true } label: { Image(systemName: "arrow.down.doc") }.accessibilityLabel("Export text file") } }
        .fileExporter(isPresented: $exporting, document: FirmwareLogDocument(text: allText), contentType: .plainText, defaultFilename: "InputPilot-\(device.deviceId)-logs.txt") { _ in }
        .task { manager.start() }
        .onChange(of: manager.metadata) { _, metadata in guard let metadata else { return }; device.firmwareVersion = metadata.firmware; device.protocolVersion = metadata.protocolVersion; device.otaSchema = metadata.otaSchema; device.runningPartition = metadata.runningPartition; device.bootPartition = metadata.bootPartition; device.lastSeen = Date() }
        .onDisappear { manager.stop() }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: StoredDevice.self, inMemory: true)
}
