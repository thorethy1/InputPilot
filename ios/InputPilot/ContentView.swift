import Foundation
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \StoredDevice.displayName) private var storedDevices: [StoredDevice]
    @StateObject private var viewModel = HomeViewModel()
    @AppStorage("selectedDeviceId") private var selectedDeviceId = ""

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
        .environmentObject(viewModel)
        .task(id: storedDevices.map(\.deviceId)) {
            reconcileActiveDevice()
            viewModel.monitorBonjour(devices: storedDevices, context: modelContext)
            while !Task.isCancelled {
                await viewModel.refreshQuietly(devices: storedDevices, context: modelContext)
                try? await Task.sleep(nanoseconds: HomeViewModel.presencePollNanoseconds)
            }
        }
        .onDisappear { viewModel.stopBonjourMonitoring() }
    }

    private var deviceList: some View {
        List {
            ForEach(storedDevices) { device in
                NavigationLink {
                    DeviceDetailView(device: device)
                } label: {
                    DeviceRowView(
                        device: device,
                        wifiState: viewModel.wifiState(for: device.deviceId),
                        isActive: selectedDeviceId == device.deviceId
                    )
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if selectedDeviceId != device.deviceId {
                        Button {
                            selectedDeviceId = device.deviceId
                        } label: {
                            Label("Make Active", systemImage: "checkmark.circle")
                        }
                        .tint(.accentColor)
                    }
                }
                .contextMenu {
                    Button {
                        selectedDeviceId = device.deviceId
                    } label: {
                        Label(
                            selectedDeviceId == device.deviceId ? "Active Device" : "Make Active",
                            systemImage: selectedDeviceId == device.deviceId
                                ? "checkmark.circle.fill" : "checkmark.circle"
                        )
                    }
                    .disabled(selectedDeviceId == device.deviceId)
                }
            }
        }
    }

    private func reconcileActiveDevice() {
        let resolved = ActiveDeviceSelection.reconciled(
            savedID: selectedDeviceId,
            availableIDs: storedDevices.map(\.deviceId)
        )
        if selectedDeviceId != resolved { selectedDeviceId = resolved }
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
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                showAddWizard = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add Device")
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
    let isActive: Bool
    @ObservedObject private var bluetooth: BLEHIDControlTransport

    init(device: StoredDevice, wifiState: WiFiReachabilityState, isActive: Bool) {
        self.device = device
        self.wifiState = wifiState
        self.isActive = isActive
        _bluetooth = ObservedObject(wrappedValue: InputPilotBluetoothManager.session(deviceId: device.deviceId))
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: presence.systemImage)
                .foregroundStyle(presence.color)
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: AppTheme.Spacing.compact) {
                    Text(device.displayName)
                        .font(.headline)
                    if isActive {
                        Text("Active")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                }
                Text(presence.title)
                    .font(.subheadline)
                    .foregroundStyle(presence.color)
                Text(presence.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(device.displayName), \(isActive ? "active device, " : "")\(presence.title), \(presence.detail)")
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

struct DeviceConnectionBanner: View {
    let device: StoredDevice
    var showsRecoveryActions = true
    @EnvironmentObject private var viewModel: HomeViewModel
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var bluetooth: BLEHIDControlTransport
    @State private var isRetrying = false

    init(device: StoredDevice, showsRecoveryActions: Bool = true) {
        self.device = device
        self.showsRecoveryActions = showsRecoveryActions
        _bluetooth = ObservedObject(wrappedValue: InputPilotBluetoothManager.session(deviceId: device.deviceId))
    }

    private var presence: DevicePresenceStatus {
        DevicePresenceStatus.resolve(
            wifi: viewModel.wifiState(for: device.deviceId),
            bluetooth: bluetooth.state,
            hasConfiguredWiFi: !DeviceEndpointResolver.endpointURLs(mdnsHost: device.mdnsHost, staIP: device.staIP).isEmpty
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.compact) {
                Label(presence.title, systemImage: presence.systemImage)
                    .font(.headline)
                    .foregroundStyle(presence.color)
                Spacer()
                if isRetrying { ProgressView().controlSize(.small) }
            }
            Text(presence.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            if showsRecoveryActions {
                recoveryActions
            }
        }
        .accessibilityElement(children: .contain)
        .task { await bluetooth.connect() }
    }

    @ViewBuilder
    private var recoveryActions: some View {
        if bluetooth.radioState == .unauthorized && !presence.isUsable {
            Label("Bluetooth access is disabled for InputPilot.", systemImage: "bluetooth.slash")
                .font(.caption)
                .foregroundStyle(AppColors.attention)
            Button("Open InputPilot Settings") { openAppSettings() }
        } else if bluetooth.radioState == .poweredOff && !presence.isUsable {
            Label("Bluetooth is off. Turn it on in Control Center or Settings.", systemImage: "bluetooth.slash")
                .font(.caption)
                .foregroundStyle(AppColors.attention)
        } else if presence.needsUSBTrustRecovery {
            NavigationLink("Restore USB Trust") { SecureLifecycleGuideView() }
        } else if presence.canRetry {
            Button("Try Again") { Task { await retry() } }
                .disabled(isRetrying)
        }
    }

    @MainActor
    private func retry() async {
        guard !isRetrying else { return }
        isRetrying = true
        defer { isRetrying = false }
        async let bluetoothRetry: Void = bluetooth.connect()
        await viewModel.refreshDevice(device, context: modelContext)
        await bluetoothRetry
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

struct ActiveDevicePicker: View {
    let devices: [StoredDevice]
    @Binding var selection: String

    var body: some View {
        Picker("Active Device", selection: $selection) {
            ForEach(devices) { device in
                Text(device.displayName).tag(device.deviceId)
            }
        }
        .accessibilityHint("Changes the device used by Control, Firmware, and Settings.")
    }
}

private struct ControlRootView: View {
    let devices: [StoredDevice]
    @AppStorage("selectedDeviceId") private var selectedDeviceId = ""
    private var selected: StoredDevice? {
        guard let selectedID = ActiveDeviceSelection.resolve(
            savedID: selectedDeviceId,
            availableIDs: devices.map(\.deviceId)
        ) else { return nil }
        return devices.first { $0.deviceId == selectedID }
    }
    var body: some View {
        Group {
            if let selected {
                List {
                    Section("Active Device") { ActiveDevicePicker(devices: devices, selection: $selectedDeviceId) }
                    Section("Connection") { DeviceConnectionBanner(device: selected) }
                    Section { NavigationLink { HIDControlView(device: selected) } label: { Label("Open Trackpad, Keyboard, Presets & Macros", systemImage: "computermouse") } }
                }
            } else { ContentUnavailableView("Select an InputPilot device", systemImage: "computermouse", description: Text("Add a device in the Devices tab first.")) }
        }
        .navigationTitle("Control")
        .task(id: devices.map(\.deviceId)) { reconcileSelection() }
    }

    private func reconcileSelection() {
        selectedDeviceId = ActiveDeviceSelection.reconciled(
            savedID: selectedDeviceId,
            availableIDs: devices.map(\.deviceId)
        )
    }
}

private struct FirmwareRootView: View {
    let devices: [StoredDevice]
    @AppStorage("selectedDeviceId") private var selectedDeviceId = ""
    private var selected: StoredDevice? {
        guard let selectedID = ActiveDeviceSelection.resolve(
            savedID: selectedDeviceId,
            availableIDs: devices.map(\.deviceId)
        ) else { return nil }
        return devices.first { $0.deviceId == selectedID }
    }
    var body: some View {
        Group {
            if let selected { FirmwareDeviceView(device: selected, devices: devices, selection: $selectedDeviceId).id(selected.deviceId) }
            else { ContentUnavailableView("Select an InputPilot device", systemImage: "arrow.triangle.2.circlepath", description: Text("Select an InputPilot device to view firmware information and updates.")) }
        }
        .navigationTitle("Firmware")
        .task(id: devices.map(\.deviceId)) { reconcileSelection() }
    }

    private func reconcileSelection() {
        selectedDeviceId = ActiveDeviceSelection.reconciled(
            savedID: selectedDeviceId,
            availableIDs: devices.map(\.deviceId)
        )
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
    @AppStorage("updateChannel") private var updateChannelName = UpdateChannel.buildDefault.rawValue
    init(device: StoredDevice, devices: [StoredDevice], selection: Binding<String>) {
        self.device = device; self.devices = devices; _selection = selection
        let transport = InputPilotBluetoothManager.session(deviceId: device.deviceId)
        transport.metadataHandler = { [weak device] metadata in
            guard let device, metadata.deviceId.lowercased() == device.deviceId.lowercased() else { return }
            DeviceMerge.bluetooth(metadata, into: device)
        }
        self.transport = transport; _updater = StateObject(wrappedValue: transport.firmwareUpdater)
    }
    var body: some View {
        Form {
            Section("Firmware") {
                ActiveDevicePicker(devices: devices, selection: $selection)
                LabeledContent("Update channel", value: updateChannel.rawValue)
                DeviceConnectionBanner(device: device)
                LabeledContent("Installed firmware", value: device.firmwareVersion ?? "Unknown")
                LabeledContent("Latest firmware", value: releaseSource.manifest?.version ?? "Not checked")
                LabeledContent("Update status", value: releaseSource.status.title)
                if let detail = releaseSource.status.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Firmware Update") {
                if device.protocolVersion != FirmwareReleaseEvaluator.supportedProtocol {
                    Label("This device must be reflashed with current Secure Protocol v2 firmware.", systemImage: "externaldrive.badge.exclamationmark").foregroundStyle(AppColors.warning)
                } else if device.otaSchema < 1 {
                    Label("This device must be reflashed over USB before firmware updates can be installed.", systemImage: "cable.connector").foregroundStyle(.secondary)
                } else if !device.capabilities.contains("secure_ota") {
                    Label("The installed firmware does not provide a supported update transport.", systemImage: "exclamationmark.triangle").foregroundStyle(AppColors.warning)
                } else {
                    Button("Check for Updates") { Task { await releaseSource.check(installed: device.firmwareVersion, deviceOTASchema: device.otaSchema, appVersion: appVersion, channel: updateChannel) } }
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
                    if case .transferring = updater.state { Button("Cancel", role: .cancel) { updater.cancel() } }
                }
            }
        }
        .task { updater.configure(device: device, mode: ConnectionMode(rawValue: connectionModeRaw) ?? .automatic); await transport.connect() }
        .onChange(of: updater.state) { _, state in
            guard state == .completed, let installed = updater.installedVersion ?? (targetVersion.isEmpty ? nil : targetVersion) else { return }
            device.firmwareVersion = installed
            releaseSource.reconcile(installed: installed, deviceOTASchema: device.otaSchema, appVersion: appVersion)
        }
        .onChange(of: updateChannelName) { _, _ in releaseSource.reset() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "bin") ?? .data]) { result in
            guard case let .success(url) = result, url.pathExtension.lowercased() == "bin", url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let data = try? Data(contentsOf: url) else { return }
            selectedData = data; selectedName = url.lastPathComponent
            do { targetVersion = try FirmwareImageMetadata.parseAndValidate(data).version; manualValidationError = nil }
            catch { targetVersion = ""; manualValidationError = error.localizedDescription }
        }
    }
    private var updateChannel: UpdateChannel { UpdateChannel(rawValue: updateChannelName) ?? .stable }
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
    func reset() {
        manifest = nil; status = .notChecked; errorMessage = nil; firmwareURL = nil
    }
    func check(installed: String?, deviceOTASchema: Int, appVersion: String, channel: UpdateChannel = .stable) async {
        errorMessage = nil; manifest = nil; firmwareURL = nil; status = .checking
        do {
            var request = URLRequest(url: channel.releaseAPIURL); request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let release = try Self.selectRelease(from: data, channel: channel)
            guard let manifestURL = release.assetURL(named: Self.manifestAssetName),
                  let imageURL = release.assetURL(named: Self.firmwareAssetName) else { throw URLError(.badServerResponse) }
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

struct GitHubReleaseDescriptor: Codable, Equatable, Sendable {
    struct Asset: Codable, Equatable, Sendable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case draft, prerelease, assets
    }

    func assetURL(named name: String) -> URL? {
        assets.first { $0.name == name }?.browserDownloadURL
    }

    var isVersionedBeta: Bool {
        let parts = tagName.components(separatedBy: "-beta.")
        guard parts.count == 2, parts[0].hasPrefix("v"), Int(parts[1]) != nil else { return false }
        return SemanticVersion(String(parts[0].dropFirst())) != nil
    }
}

extension GitHubFirmwareSource {
    static func selectRelease(from data: Data, channel: UpdateChannel) throws -> GitHubReleaseDescriptor {
        let decoder = JSONDecoder()
        switch channel {
        case .stable:
            let release = try decoder.decode(GitHubReleaseDescriptor.self, from: data)
            guard !release.draft, !release.prerelease else { throw URLError(.badServerResponse) }
            return release
        case .beta:
            let releases = try decoder.decode([GitHubReleaseDescriptor].self, from: data)
            guard let release = releases.first(where: {
                !$0.draft && $0.prerelease && $0.isVersionedBeta &&
                $0.assetURL(named: manifestAssetName) != nil &&
                $0.assetURL(named: firmwareAssetName) != nil
            }) else { throw URLError(.resourceUnavailable) }
            return release
        }
    }
}

private struct ConnectionSettingsView: View {
    @Query(sort: \StoredDevice.displayName) private var devices: [StoredDevice]
    @AppStorage("selectedDeviceId") private var selectedDeviceId = ""
    @AppStorage("connectionMode") private var mode = ConnectionMode.automatic.rawValue
    @AppStorage("appAppearance") private var appearanceName = AppAppearance.system.rawValue
    @AppStorage("appAccent") private var accentName = AppAccent.inputPilot.rawValue
    @AppStorage("updateChannel") private var updateChannelName = UpdateChannel.buildDefault.rawValue
    private var selected: StoredDevice? {
        guard let selectedID = ActiveDeviceSelection.resolve(
            savedID: selectedDeviceId,
            availableIDs: devices.map(\.deviceId)
        ) else { return nil }
        return devices.first { $0.deviceId == selectedID }
    }
    private let appVersion = AppVersionInfo.read()
    var body: some View {
        Form {
            if let selected {
                Section("Active Device") {
                    ActiveDevicePicker(devices: devices, selection: $selectedDeviceId)
                    DeviceConnectionBanner(device: selected)
                }
            }
            Section("Connection") {
                Picker("Default transport", selection: $mode) { ForEach(ConnectionMode.allCases) { Text($0.rawValue).tag($0.rawValue) } }
                Text(explanation).font(.caption).foregroundStyle(.secondary)
            }
            Section("Updates") {
                Picker("Channel", selection: $updateChannelName) {
                    ForEach(UpdateChannel.allCases) { channel in
                        Text(channel.rawValue).tag(channel.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text(updateChannel.detail)
                    .font(.caption)
                    .foregroundStyle(updateChannel == .beta ? AppColors.warning : .secondary)
                ShareLink(item: updateChannel.altStoreSourceURL) {
                    Label("Share AltStore \(updateChannel.rawValue) Source", systemImage: "square.and.arrow.up")
                }
                Text("The channel controls firmware OTA checks. Add the matching source in AltStore to receive app updates from the same channel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let selected, PairingKeyStore.load(deviceId: selected.deviceId) == nil {
                Section("Security") {
                    Label("\(selected.displayName) cannot be used until USB trust is restored.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppColors.warning)
                    NavigationLink("Secure lifecycle") { SecureLifecycleGuideView() }
                }
            }
            Section("Support") {
                NavigationLink("Pair InputPilot by USB") { USBPairingInputTestView() }
                NavigationLink("Status LED Matrix") { StatusLEDMatrixView() }
                NavigationLink("Diagnostics & Advanced") {
                    DiagnosticsSettingsView(devices: devices, selection: $selectedDeviceId)
                }
            }
            Section("About") {
                LabeledContent("App Version", value: appVersion.version)
                LabeledContent("Build", value: appVersion.build)
                LabeledContent("App Commit", value: appVersion.commit)
            }
            Section("Appearance") {
                Picker("Interface", selection: $appearanceName) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.rawValue).tag(appearance.rawValue)
                    }
                }
                Picker("Accent color", selection: $accentName) {
                    ForEach(AppAccent.allCases) { accent in
                        Label(accent.rawValue, systemImage: accent == .inputPilot ? "app.fill" : "circle.fill")
                            .foregroundStyle(accent.color)
                            .tag(accent.rawValue)
                    }
                }
                Label("Status and destructive colors keep their meaning when the accent changes.", systemImage: "paintpalette")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .task(id: devices.map(\.deviceId)) {
            selectedDeviceId = ActiveDeviceSelection.reconciled(
                savedID: selectedDeviceId,
                availableIDs: devices.map(\.deviceId)
            )
        }
    }
    private var updateChannel: UpdateChannel { UpdateChannel(rawValue: updateChannelName) ?? .stable }
    private var explanation: String { switch ConnectionMode(rawValue: mode) ?? .automatic { case .automatic: "Uses authenticated Bluetooth for interactive controls and authenticated Wi-Fi for bulk work."; case .preferBluetooth: "Prefers the authenticated Bluetooth session when both transports are ready."; case .preferWiFi: "Prefers the authenticated Wi-Fi session when both transports are ready."; case .bluetoothOnly: "Uses only an authenticated Bluetooth session."; case .wifiOnly: "Uses only an authenticated Secure Protocol session over Wi-Fi." } }
}

private struct StatusLEDMatrixView: View {
    private struct LEDState: Identifiable {
        let id: String
        let color: Color
        let pattern: String
        let meaning: String
    }

    private let states = [
        LEDState(id: "Setup", color: .purple, pattern: "Magenta · blinking", meaning: "Fallback access point is active for setup or recovery."),
        LEDState(id: "Disconnected", color: .red, pattern: "Red · solid", meaning: "Wi-Fi is unavailable, connecting, or the device is running in Bluetooth-only mode."),
        LEDState(id: "Keep Awake", color: .cyan, pattern: "Cyan · breathing", meaning: "Wi-Fi is connected and automatic pointer movement is enabled."),
        LEDState(id: "Ready", color: .green, pattern: "Green · dim solid", meaning: "Wi-Fi is connected and InputPilot is idle.")
    ]

    var body: some View {
        List {
            Section {
                ForEach(states) { state in
                    HStack(alignment: .top, spacing: 12) {
                        Circle()
                            .fill(state.color)
                            .shadow(color: state.color.opacity(0.55), radius: 4)
                            .frame(width: 18, height: 18)
                            .padding(.top, 3)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(state.id).font(.headline)
                            Text(state.pattern).font(.subheadline).foregroundStyle(.secondary)
                            Text(state.meaning).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } footer: {
                Text("Bluetooth advertising recovery is automatic and is recorded in Diagnostics; it does not use a separate LED pattern.")
            }
        }
        .navigationTitle("Status LED Matrix")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DiagnosticsSettingsView: View {
    let devices: [StoredDevice]
    @Binding var selection: String
    @AppStorage("connectionMode") private var connectionMode = ConnectionMode.automatic.rawValue
    private let appVersion = AppVersionInfo.read()

    private var selected: StoredDevice? {
        guard let selectedID = ActiveDeviceSelection.resolve(
            savedID: selection,
            availableIDs: devices.map(\.deviceId)
        ) else { return nil }
        return devices.first { $0.deviceId == selectedID }
    }

    var body: some View {
        Form {
            if let selected {
                Section("Device") {
                    ActiveDevicePicker(devices: devices, selection: $selection)
                    DeviceConnectionBanner(device: selected)
                    LabeledContent("Device ID", value: selected.deviceId)
                    LabeledContent("Firmware", value: selected.firmwareVersion ?? "Unknown")
                    LabeledContent("Secure Protocol", value: "v\(selected.protocolVersion)")
                    LabeledContent("OTA Schema", value: String(selected.otaSchema))
                    LabeledContent("Connection Mode", value: connectionMode)
                    if let lastSeen = selected.lastSeen {
                        LabeledContent(
                            "Last Seen",
                            value: lastSeen.formatted(date: .abbreviated, time: .shortened)
                        )
                    }
                }

                Section("Device Diagnostics") {
                    NavigationLink("Firmware Logs") {
                        FirmwareLogsView(
                            device: selected,
                            devices: devices,
                            selection: $selection
                        )
                        .id(selected.deviceId)
                    }
                    NavigationLink("Export Diagnostics") {
                        DiagnosticsExportView(device: selected)
                    }
                }
            } else {
                Section {
                    ContentUnavailableView(
                        "No Device Selected",
                        systemImage: "wrench.and.screwdriver",
                        description: Text("Add a device to inspect connection and firmware diagnostics.")
                    )
                }
            }

            Section("App Diagnostics") {
                NavigationLink("App Logs") { AppLogsView() }
                NavigationLink("Secure Lifecycle Guide") { SecureLifecycleGuideView() }
            }

            Section("App Build") {
                LabeledContent("Version", value: appVersion.version)
                LabeledContent("Build", value: appVersion.build)
                LabeledContent("Commit", value: appVersion.commit)
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }
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
                    Label("Paired securely with \(pairedDeviceId)", systemImage: "checkmark.shield.fill").foregroundStyle(AppColors.success)
                case .invalid:
                    Label("Input was received, but it was not a valid InputPilot pairing frame", systemImage: "exclamationmark.triangle.fill").foregroundStyle(AppColors.warning)
                case .storageFailed:
                    Label("The credential could not be saved in Keychain", systemImage: "exclamationmark.shield.fill").foregroundStyle(AppColors.error)
                }
                Button("Pair another device") { captured = ""; pairedDeviceId = ""; result = .waiting }
                    .disabled(embedded && result == .valid)
                if result == .valid, continueAction != nil {
                    ProgressView("Connecting over encrypted Bluetooth…")
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
            if let continueAction {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { continueAction() }
            }
        } catch {
            result = .storageFailed
        }
    }
}

struct SecureLifecycleGuideView: View {
    var body: some View {
        List {
            Section("Requirements") {
                Label("Install current Secure Protocol v2 firmware by USB flash.", systemImage: "1.circle")
                Label("Older firmware is intentionally not compatible with this app.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(AppColors.warning)
            }
            Section("Trust") {
                Label("Connect InputPilot directly to the iPhone by USB.", systemImage: "2.circle")
                Label("Focus Secure Pairing, then hold BOOT for two seconds.", systemImage: "3.circle")
                Label("The 128-bit secret is stored in Keychain. A new code invalidates every previous session.", systemImage: "4.circle")
            }
            Section("After pairing") {
                Label("Bluetooth and Wi-Fi carry the same authenticated encrypted protocol.", systemImage: "checkmark.shield.fill")
                    .foregroundStyle(AppColors.success)
                Label("Setup, controls, diagnostics, management, and OTA never use plaintext endpoints.", systemImage: "checkmark.shield.fill")
                    .foregroundStyle(AppColors.success)
                Text("If the key is lost, create a new pairing code over USB. Pair every iPhone again because the old code becomes invalid.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                NavigationLink("Pair InputPilot by USB") { USBPairingInputTestView() }
            }
        }
        .navigationTitle("Secure Lifecycle")
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
        return ["InputPilot diagnostics", "App Version: \(app.version)", "App Build: \(app.build)", "App Commit: \(app.commit)", "Firmware Version: \(device.firmwareVersion ?? "Unknown")", "Firmware Commit: \(metadata?.firmwareCommit ?? "Unknown")", "Device ID: \(device.deviceId)", "Connection Mode: \(UserDefaults.standard.string(forKey: "connectionMode") ?? ConnectionMode.automatic.rawValue)", "Diagnostics Transport: \(diagnostics.status)", "Capabilities: \(device.capabilities.joined(separator: ","))", "Running Partition: \(device.runningPartition ?? "Unknown")", "Reset Reason: \(metadata?.resetReason ?? "Unknown")", "BLE connected/advertising: \(metadata?.ble?.connected ?? false)/\(metadata?.ble?.advertising ?? false)", "BLE advertising recoveries/failures: \(metadata?.ble?.advertisingRecoveries ?? 0)/\(metadata?.ble?.advertisingRecoveryFailures ?? 0)", "HID decoded/queued/executed/failed: \(hid?.decoded ?? 0)/\(hid?.queued ?? 0)/\(hid?.executed ?? 0)/\(hid?.failed ?? 0)", "USB reports attempted/succeeded/failed: \(hid?.usbReportsAttempted ?? 0)/\(hid?.usbReportsSucceeded ?? 0)/\(hid?.usbReportsFailed ?? 0)", "Last HID source/type/sequence/phase: \(hid?.lastSource ?? "Unknown")/\(hid?.lastType ?? "Unknown")/\(hid?.lastSequence ?? 0)/\(hid?.lastPhase ?? "Unknown")", "Previous HID breadcrumb valid/sequence/source/phase: \(hid?.previousBreadcrumbValid ?? false)/\(hid?.previousSequence ?? 0)/\(hid?.previousSource ?? "Unknown")/\(hid?.previousPhase ?? 0)", "", "App Logs:", AppLog.shared.records.map(\.line).joined(separator: "\n"), "", "Firmware Logs:", diagnostics.lines.map(\.raw).joined(separator: "\n")].joined(separator: "\n")
    }
    var body: some View { Form { Section { LabeledContent("Status", value: diagnostics.status); Text("The export excludes pairing secrets, Wi-Fi passwords, and typed text.").foregroundStyle(.secondary); Button("Export inputpilot-diagnostics.txt") { exporting = true } } }.navigationTitle("Export Diagnostics").fileExporter(isPresented: $exporting, document: FirmwareLogDocument(text: text), contentType: .plainText, defaultFilename: "inputpilot-diagnostics.txt") { _ in }.task { diagnostics.start() }.onDisappear { diagnostics.stop() } }
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
                if devices.count > 1 { ActiveDevicePicker(devices: devices, selection: $selection) }
                LabeledContent("Connection", value: manager.status)
                if let metadata = manager.metadata { LabeledContent("Firmware Commit", value: metadata.firmwareCommit ?? "Unknown"); LabeledContent("Reset Reason", value: metadata.resetReason ?? "Unknown") }
                Picker("Filter", selection: $filter) { ForEach(FirmwareLogFilter.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu)
            }.frame(maxHeight: devices.count > 1 ? 170 : 125)
            ScrollViewReader { proxy in
                ScrollView { LazyVStack(alignment: .leading, spacing: 4) { ForEach(visible) { line in Text(line.raw).font(.system(.caption, design: .monospaced)).textSelection(.enabled).foregroundStyle(line.level == "ERROR" ? .red : line.level == "WARN" ? .orange : .primary).frame(maxWidth: .infinity, alignment: .leading).id(line.id) } }.padding() }
                    .background(Color(uiColor: .secondarySystemBackground))
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
