import Foundation
import SwiftData
import SwiftUI
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
            .task(id: storedDevices.map(\.deviceId)) {
                while !Task.isCancelled {
                    await viewModel.refreshQuietly(devices: storedDevices, context: modelContext)
                    try? await Task.sleep(nanoseconds: HomeViewModel.presencePollNanoseconds)
                }
            }
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
    }

    private var deviceList: some View {
        List(storedDevices) { device in
            NavigationLink {
                DeviceDetailView(device: device)
            } label: {
                DeviceRowView(
                    device: device,
                    presence: DevicePresenceStatus.resolve(
                        isReachable: !viewModel.offlineDeviceIds.contains(device.deviceId),
                        jiggleEnabled: device.jiggleEnabled,
                        staIP: device.staIP
                    ),
                    jiggleBinding: jiggleBinding(for: device)
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

    private func jiggleBinding(for device: StoredDevice) -> Binding<Bool> {
        Binding(
            get: { device.jiggleEnabled },
            set: { newValue in
                Task {
                    await viewModel.setJiggle(device: device, enabled: newValue, context: modelContext)
                }
            }
        )
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
    let presence: DevicePresenceStatus
    @Binding var jiggleBinding: Bool

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(device.displayName)
                    .font(.headline)
                Text(statusTitle)
                    .font(.subheadline)
                    .foregroundStyle(statusColor)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(device.displayName), \(statusTitle)")

            Spacer()

            Toggle("Jiggle", isOn: $jiggleBinding)
                .labelsHidden()
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        let bluetooth = device.capabilities.isEmpty || device.capabilities.contains("ble_control") ? "Bluetooth available" : nil
        let wifi = device.staIP.map { "Wi-Fi \($0)" }
        return [bluetooth, wifi].compactMap { $0 }.joined(separator: " · ")
    }
    private var hasBluetooth: Bool { device.capabilities.isEmpty || device.capabilities.contains("ble_control") }
    private var statusTitle: String { presence == .offline && hasBluetooth ? "Bluetooth available" : presence.title }
    private var statusColor: Color { presence == .offline && hasBluetooth ? AppColors.info : presence.ledColor }
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
    init(device: StoredDevice, devices: [StoredDevice], selection: Binding<String>) {
        self.device = device; self.devices = devices; _selection = selection
        let transport = InputPilotBluetoothManager.session(deviceId: device.deviceId, token: device.apiToken)
        transport.metadataHandler = { [weak device] metadata in
            guard let device, metadata.deviceId.lowercased() == device.deviceId.lowercased() else { return }
            device.firmwareVersion = metadata.firmware; device.protocolVersion = metadata.protocolVersion
            device.capabilities = metadata.capabilities; device.otaSchema = metadata.otaSchema
            device.lastCapabilitiesUpdate = Date(); device.lastSeen = Date()
        }
        self.transport = transport; _updater = StateObject(wrappedValue: transport.firmwareUpdater)
    }
    var body: some View {
        Form {
            Section("Device") { Picker("Active device", selection: $selection) { ForEach(devices) { Text($0.displayName).tag($0.deviceId) } }; LabeledContent("Installed", value: device.firmwareVersion ?? "Unknown"); if let manifest = releaseSource.manifest { LabeledContent("Available", value: manifest.version) } }
            Section("Bluetooth OTA") {
                if !device.capabilities.contains("ble_ota") || device.otaSchema < 1 {
                    Label("This device needs a one-time USB migration before Bluetooth updates are available.", systemImage: "cable.connector").foregroundStyle(.secondary)
                } else {
                    Label("Available", systemImage: "checkmark.circle").foregroundStyle(AppColors.success)
                    Button("Check GitHub Releases") { Task { await releaseSource.check(installed: device.firmwareVersion) } }
                    if releaseSource.updateAvailable { Button("Download Latest Firmware") { Task { if let result = await releaseSource.downloadFirmware() { selectedData = result; selectedName = "firmware.bin"; targetVersion = releaseSource.manifest?.version ?? ""; manualValidationError = nil } } }.buttonStyle(.borderedProminent) }
                    if let error = releaseSource.errorMessage { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(AppColors.warning) }
                    if let selectedData { LabeledContent("File", value: selectedName); LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(selectedData.count), countStyle: .file)) }
                    if let manualValidationError { Label(manualValidationError, systemImage: "exclamationmark.triangle").foregroundStyle(AppColors.warning) }
                    Button("Choose Firmware File") { importing = true }
                    if selectedData != nil { TextField("Firmware version", text: $targetVersion).textInputAutocapitalization(.never).autocorrectionDisabled() }
                    if let selectedData { Button("Update Firmware") { Task { await updater.install(selectedData, version: targetVersion, expectedSHA256: releaseSource.manifest?.version == targetVersion ? releaseSource.manifest?.sha256 : nil) } }.buttonStyle(.borderedProminent).disabled(targetVersion.isEmpty) }
                }
            }
            if updater.state != .idle {
                Section("Update status") {
                    ProgressView(value: updater.progress)
                    Text(statusText).accessibilityLabel("Firmware update status: \(statusText)")
                    if updater.totalBytes > 0 { Text("\(Int(updater.progress * 100))% · \(ByteCountFormatter.string(fromByteCount: Int64(updater.bytesSent), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(updater.totalBytes), countStyle: .file)) · \(ByteCountFormatter.string(fromByteCount: Int64(updater.bytesPerSecond), countStyle: .file))/s").font(.caption).foregroundStyle(.secondary) }
                    if case .transferring = updater.state { Button("Cancel", role: .cancel) { updater.cancel() }.tint(AppColors.primary) }
                }
            }
        }
        .task { await transport.connect() }
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

@MainActor private final class GitHubFirmwareSource: ObservableObject {
    @Published var manifest: FirmwareManifest?
    @Published var updateAvailable = false
    @Published var errorMessage: String?
    private var firmwareURL: URL?
    func check(installed: String?) async {
        errorMessage = nil
        do {
            let url = URL(string: "https://api.github.com/repos/thorethy1/InputPilot/releases/latest")!
            var request = URLRequest(url: url); request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let assets = json["assets"] as? [[String: Any]],
                  let manifestString = assets.first(where: { $0["name"] as? String == "firmware-manifest.json" })?["browser_download_url"] as? String,
                  let firmwareString = assets.first(where: { $0["name"] as? String == "firmware.bin" })?["browser_download_url"] as? String,
                  let manifestURL = URL(string: manifestString), let imageURL = URL(string: firmwareString) else { throw URLError(.badServerResponse) }
            let (manifestData, _) = try await URLSession.shared.data(from: manifestURL)
            let decoded = try JSONDecoder().decode(FirmwareManifest.self, from: manifestData)
            try FirmwareManifestValidator.validate(decoded)
            manifest = decoded; firmwareURL = imageURL
            updateAvailable = installed.flatMap(SemanticVersion.init).map { current in SemanticVersion(decoded.version).map { current < $0 } ?? false } ?? true
        } catch { errorMessage = "Could not check GitHub Releases." }
    }
    func downloadFirmware() async -> Data? {
        guard let firmwareURL, let manifest else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: firmwareURL)
            try FirmwareManifestValidator.validate(manifest, firmware: data)
            return data
        } catch { errorMessage = "Could not download the firmware image."; return nil }
    }
}

private struct ConnectionSettingsView: View {
    @AppStorage("connectionMode") private var mode = ConnectionMode.automatic.rawValue
    var body: some View { Form { Section("Connection") { Picker("Default transport", selection: $mode) { ForEach(ConnectionMode.allCases) { Text($0.rawValue).tag($0.rawValue) } }; Text(explanation).font(.caption).foregroundStyle(.secondary) }; Section("Appearance") { Label("InputPilot uses the native iOS interface with a red brand accent. Status colors remain semantic.", systemImage: "paintpalette") } }.navigationTitle("Settings") }
    private var explanation: String { switch ConnectionMode(rawValue: mode) ?? .automatic { case .automatic: "InputPilot automatically chooses the best available connection for each operation."; case .preferBluetooth: "Uses nearby Bluetooth first, then Wi-Fi when needed."; case .preferWiFi: "Uses Wi-Fi first, with Bluetooth as fallback."; case .bluetoothOnly: "Controls InputPilot nearby without Wi-Fi or internet."; case .wifiOnly: "Uses TCP or REST over your local Wi-Fi network." } }
}

#Preview {
    ContentView()
        .modelContainer(for: StoredDevice.self, inMemory: true)
}
