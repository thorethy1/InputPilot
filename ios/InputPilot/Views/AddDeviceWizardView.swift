import SwiftData
import SwiftUI

struct AddDeviceWizardView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var storedDevices: [StoredDevice]
    @StateObject private var viewModel = AddDeviceWizardViewModel()
    @StateObject private var bluetooth = BLEDeviceDiscoveryManager()
    @State private var connectingBluetoothDeviceId: String?

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.step {
                case .securePairing: securePairingStep
                case .bleScanning: bluetoothScanningStep
                case .confirmBLE: confirmBLEStep
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { wizardToolbar }
            .alert("Notice", isPresented: errorAlertBinding) {
                Button("OK") { viewModel.errorMessage = nil }
            } message: { Text(viewModel.errorMessage ?? "") }
            .interactiveDismissDisabled(viewModel.isSaving)
            .onAppear { viewModel.updateKnownDevices(storedDevices) }
            .onChange(of: storedDevices.map(\.deviceId)) { _, _ in viewModel.updateKnownDevices(storedDevices) }
            .onDisappear { bluetooth.stop() }
        }
    }

    private var navigationTitle: String {
        switch viewModel.step {
        case .securePairing: "USB Trust"
        case .bleScanning: "Secure Bluetooth"
        case .confirmBLE: "Connection Setup"
        }
    }

    @ToolbarContentBuilder
    private var wizardToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { viewModel.cancelWizard(); dismiss() }.disabled(viewModel.isSaving)
        }
        if viewModel.bleMetadata != nil {
            ToolbarItem(placement: .confirmationAction) {
                Button("Finish") { Task { await saveDevice() } }
                    .disabled(viewModel.isSaving || viewModel.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (viewModel.configureWiFi && viewModel.homeWifiSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
    }

    private var securePairingStep: some View {
        USBPairingInputTestView(
            onPaired: { viewModel.didPairSecurely(deviceId: $0) },
            embedded: true,
            continueAction: { viewModel.continueSecureSetup(); bluetooth.start() }
        )
    }

    private var bluetoothScanningStep: some View {
        ContentUnavailableView {
            Label(connectingBluetoothDeviceId == nil ? "Scanning…" : "Connecting…",
                  systemImage: "antenna.radiowaves.left.and.right")
        } description: {
            Text("Finding and authenticating the InputPilot identified during USB pairing.")
        } actions: {
            if connectingBluetoothDeviceId != nil { ProgressView() }
        }
        .onAppear { connectToPairedBluetoothDevice(in: bluetooth.devices) }
        .onChange(of: bluetooth.devices) { _, devices in
            connectToPairedBluetoothDevice(in: devices)
        }
        .toolbar { ToolbarItem(placement: .bottomBar) { Button("Back") { bluetooth.stop(); connectingBluetoothDeviceId = nil; viewModel.backToPairing() } } }
    }

    @ViewBuilder private var confirmBLEStep: some View {
        if let metadata = viewModel.bleMetadata {
            Form {
                if let message = viewModel.mergeMessage { Section { Label(message, systemImage: "link.badge.plus") } }
                Section("Device") {
                    LabeledContent("Name", value: metadata.deviceName)
                    LabeledContent("Version", value: metadata.firmware)
                    LabeledContent("Device ID", value: metadata.deviceId)
                    LabeledContent("Security", value: "Secure Protocol v2")
                }
                Section("Friendly name") { TextField("Name", text: $viewModel.displayName) }
                Section {
                    Toggle("Configure Wi-Fi", isOn: $viewModel.configureWiFi)
                } footer: {
                    Text("Wi-Fi is optional. InputPilot can be controlled entirely over secure Bluetooth without a router or internet connection.")
                }
                Section {
                    TextField("Wi-Fi name (SSID)", text: $viewModel.homeWifiSSID)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Wi-Fi password", text: $viewModel.homeWifiPassword)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("Encrypted Wi-Fi setup") } footer: {
                    Text("Credentials travel through the USB-trusted Bluetooth session. Setup completes only after this identity authenticates over the home network.")
                }
                .disabled(!viewModel.configureWiFi)
            }
            .toolbar { ToolbarItem(placement: .bottomBar) { Button("Back") { viewModel.backFromConfirm(); bluetooth.start() } } }
        }
    }

    private func saveDevice() async {
        do {
            try await viewModel.saveDevice(context: modelContext)
            if viewModel.errorMessage == nil { dismiss() }
        } catch { viewModel.errorMessage = error.localizedDescription }
    }

    private func connectToPairedBluetoothDevice(in devices: [BLEDiscoveredDevice]) {
        guard connectingBluetoothDeviceId == nil,
              let pairedId = viewModel.securelyPairedDeviceId,
              let device = devices.first(where: { $0.deviceId.lowercased() == pairedId.lowercased() }) else { return }
        connectingBluetoothDeviceId = device.deviceId
        Task {
            do {
                let metadata = try await bluetooth.metadata(for: device)
                connectingBluetoothDeviceId = nil
                viewModel.selectBluetooth(metadata)
            } catch {
                connectingBluetoothDeviceId = nil
                viewModel.errorMessage = error.localizedDescription
                bluetooth.start()
            }
        }
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } })
    }
}

#Preview { AddDeviceWizardView().modelContainer(for: StoredDevice.self, inMemory: true) }
