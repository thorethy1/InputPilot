import SwiftData
import SwiftUI
import UIKit

struct DeviceDetailView: View {
    @Bindable var device: StoredDevice
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var viewModel: HomeViewModel
    @ObservedObject private var bluetooth: BLEHIDControlTransport

    @State private var displayName: String = ""
    @State private var apiToken: String = ""
    @State private var showDeleteConfirmation = false

    init(device: StoredDevice) {
        _device = Bindable(wrappedValue: device)
        _bluetooth = ObservedObject(wrappedValue: InputPilotBluetoothManager.session(deviceId: device.deviceId, token: device.apiToken))
    }

    var body: some View {
        Form {
            Section("Friendly name") {
                TextField("Name", text: $displayName)
                    .onSubmit { saveDisplayName() }
            }

            Section("Status") {
                HStack(spacing: 8) {
                    Circle()
                        .fill(presence.color)
                        .frame(width: 10, height: 10)
                        .accessibilityHidden(true)
                    Text(presence.title)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Status \(presence.title)")
                Text(presence.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Bluetooth", value: bluetooth.radioState.title)
                if bluetooth.radioState == .unauthorized {
                    Button("Open InputPilot Settings") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                } else if bluetooth.radioState == .poweredOff {
                    Text("Turn on Bluetooth in Control Center or Settings, or use Wi-Fi if it is available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Remote Control") {
                NavigationLink {
                    HIDControlView(device: device)
                } label: {
                    Label("Open Trackpad & Keyboard", systemImage: "computermouse")
                }
            }

            Section("Device") {
                LabeledContent("Device ID", value: device.deviceId)
                LabeledContent("Hostname", value: device.mdnsHost)
                if let staIP = device.staIP,
                   DeviceEndpointResolver.sanitizeHost(staIP)
                    != DeviceEndpointResolver.sanitizeHost(device.mdnsHost) {
                    LabeledContent("IP", value: staIP)
                }
            }

            Section("Software") {
                LabeledContent("Firmware", value: device.firmwareVersion ?? "Unknown")
                LabeledContent("Protocol", value: String(device.protocolVersion))
                LabeledContent("OTA Schema", value: String(device.otaSchema))
                LabeledContent("Running Slot", value: device.runningPartition ?? "Unknown")
                let transports = [device.capabilities.contains("wifi_control") ? "Wi-Fi" : nil, (device.capabilities.isEmpty || device.capabilities.contains("ble_control")) ? "Bluetooth" : nil].compactMap { $0 }
                LabeledContent("Connection", value: transports.isEmpty ? "Unknown" : transports.joined(separator: " + "))
            }

            Section("Auth") {
                TextField("API Token (optional)", text: $apiToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { saveApiToken() }
            }

            Section("Keep Awake") {
                Toggle("Move pointer periodically", isOn: jiggleBinding)
                    .disabled(viewModel.wifiState(for: device.deviceId) != .reachable)
                Text("Prevents the attached computer from becoming idle. This setting currently requires a live Wi-Fi connection to the device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Delete Device", role: .destructive) {
                    showDeleteConfirmation = true
                }
            }
        }
        .navigationTitle(displayName.isEmpty ? device.displayName : displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            async let bluetoothConnection: Void = bluetooth.connect()
            await viewModel.refreshDevice(device, context: modelContext)
            _ = await bluetoothConnection
        }
        .onAppear {
            displayName = device.displayName
            apiToken = device.apiToken ?? ""
        }
        .onDisappear {
            saveDisplayName()
            saveApiToken()
        }
        .alert("Delete this device?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                deleteDevice()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes it from your saved list on this iPhone.")
        }
    }

    private var presence: DevicePresenceStatus {
        DevicePresenceStatus.resolve(
            wifi: viewModel.wifiState(for: device.deviceId),
            bluetooth: bluetooth.state,
            hasConfiguredWiFi: !DeviceEndpointResolver.endpointURLs(mdnsHost: device.mdnsHost, staIP: device.staIP).isEmpty
        )
    }

    private var jiggleBinding: Binding<Bool> {
        Binding(
            get: { device.jiggleEnabled },
            set: { newValue in
                Task {
                    await viewModel.setJiggle(device: device, enabled: newValue, context: modelContext)
                }
            }
        )
    }

    private func saveDisplayName() {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != device.displayName else { return }
        let repository = DeviceRepository(context: modelContext)
        try? repository.rename(device, name: trimmed)
    }

    private func saveApiToken() {
        let repository = DeviceRepository(context: modelContext)
        let trimmed = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let newToken = trimmed.isEmpty ? nil : trimmed
        guard newToken != device.apiToken else { return }
        do {
            try repository.updateApiToken(device, token: newToken)
            bluetooth.updateToken(newToken)
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }

    private func deleteDevice() {
        let deviceId = device.deviceId
        let repository = DeviceRepository(context: modelContext)
        try? repository.delete(device)
        Task { await InputPilotBluetoothManager.removeSession(deviceId: deviceId) }
        dismiss()
    }
}
