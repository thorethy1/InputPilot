import SwiftData
import SwiftUI

struct AddDeviceWizardView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var storedDevices: [StoredDevice]
    @StateObject private var viewModel = AddDeviceWizardViewModel()
    @StateObject private var bluetooth = BLEDeviceDiscoveryManager()

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.step {
                case .choosePath: choosePathStep
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
        case .choosePath: "Add Device"
        case .securePairing: "USB Trust"
        case .bleScanning: "Secure Bluetooth"
        case .confirmBLE: "Wi-Fi Setup"
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
                    .disabled(viewModel.isSaving || viewModel.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.homeWifiSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var choosePathStep: some View {
        List {
            Section("Secure device setup") {
                Button { viewModel.chooseSecureSetup() } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Set Up Securely").foregroundStyle(.primary)
                            Text("USB trust, encrypted Bluetooth provisioning, then authenticated Wi-Fi verification.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "lock.shield") }
                }
            }
            Section {
                Label("Older firmware is intentionally unsupported and must be reflashed over USB.", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var securePairingStep: some View {
        USBPairingInputTestView(
            onPaired: { viewModel.didPairSecurely(deviceId: $0) },
            embedded: true,
            continueAction: { viewModel.continueSecureSetup(); bluetooth.start() }
        )
        .toolbar { ToolbarItem(placement: .bottomBar) { Button("Back") { viewModel.backToChoosePath() } } }
    }

    private var bluetoothScanningStep: some View {
        Group {
            let devices = bluetooth.devices.filter {
                $0.deviceId.lowercased() == viewModel.securelyPairedDeviceId?.lowercased()
            }
            if devices.isEmpty {
                ContentUnavailableView("Scanning…", systemImage: "antenna.radiowaves.left.and.right", description: Text("Looking for the InputPilot trusted over USB."))
            } else {
                List(devices) { device in
                    Button {
                        Task {
                            do { viewModel.selectBluetooth(try await bluetooth.metadata(for: device)) }
                            catch { viewModel.errorMessage = error.localizedDescription; bluetooth.start() }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(device.name).font(.headline).foregroundStyle(.primary)
                            Text(device.deviceId).font(.caption).foregroundStyle(.secondary)
                            Text("RSSI \(device.rssi) dBm").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .toolbar { ToolbarItem(placement: .bottomBar) { Button("Back") { bluetooth.stop(); viewModel.backToChoosePath() } } }
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
                    TextField("Wi-Fi name (SSID)", text: $viewModel.homeWifiSSID)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Wi-Fi password", text: $viewModel.homeWifiPassword)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("Encrypted Wi-Fi setup") } footer: {
                    Text("Credentials travel through the USB-trusted Bluetooth session. Setup completes only after this identity authenticates over the home network.")
                }
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

    private var errorAlertBinding: Binding<Bool> {
        Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } })
    }
}

#Preview { AddDeviceWizardView().modelContainer(for: StoredDevice.self, inMemory: true) }
