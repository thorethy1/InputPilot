import SwiftData
import SwiftUI

struct DeviceDetailView: View {
    @Bindable var device: StoredDevice
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var viewModel: HomeViewModel

    @State private var displayName: String = ""
    @State private var apiToken: String = ""
    @State private var showDeleteConfirmation = false

    var body: some View {
        Form {
            Section("Friendly name") {
                TextField("Name", text: $displayName)
                    .onSubmit { saveDisplayName() }
            }

            Section("Status") {
                HStack(spacing: 8) {
                    Circle()
                        .fill(presence.ledColor)
                        .frame(width: 10, height: 10)
                        .accessibilityHidden(true)
                    Text(presence.title)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Status \(presence.title)")
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

            Section("Jiggle") {
                Toggle("Enable jiggle", isOn: jiggleBinding)
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
            await viewModel.refreshDevice(device, context: modelContext)
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
            isReachable: !viewModel.offlineDeviceIds.contains(device.deviceId),
            jiggleEnabled: device.jiggleEnabled,
            staIP: device.staIP
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
        try? repository.updateApiToken(device, token: newToken)
    }

    private func deleteDevice() {
        let repository = DeviceRepository(context: modelContext)
        try? repository.delete(device)
        dismiss()
    }
}
