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
    @State private var usbProductName = "InputPilot"
    @State private var usbVID = "0xCAFE"
    @State private var usbPID = "0x4001"
    @State private var usbSerialNumber = ""
    @State private var usbBusy = false
    @State private var usbMessage: String?

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

            if device.capabilities.contains("usb_identity") && !endpointURLs.isEmpty {
                Section("USB Identity") {
                    TextField("Product name", text: $usbProductName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                    TextField("Vendor ID", text: $usbVID)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("Product ID", text: $usbPID)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("Serial number", text: $usbSerialNumber)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("VID and PID must be hexadecimal values from 0x0001 through 0xFFFF. The serial number accepts letters, numbers, period, dash, and underscore.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Apply and Restart InputPilot") {
                        Task { await saveUSBIdentity() }
                    }
                    .disabled(usbBusy)
                    Button("Restore USB Defaults", role: .destructive) {
                        Task { await resetUSBIdentity() }
                    }
                    .disabled(usbBusy)
                    if usbBusy { ProgressView() }
                    if let usbMessage {
                        Text(usbMessage)
                            .font(.caption)
                            .foregroundStyle(usbMessage.hasPrefix("Could not") || usbMessage.hasPrefix("Invalid") ? AppColors.warning : Color.secondary)
                    }
                }
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
            if device.capabilities.contains("usb_identity") { await loadUSBIdentity() }
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

    private var endpointURLs: [URL] {
        DeviceEndpointResolver.endpointURLs(mdnsHost: device.mdnsHost, staIP: device.staIP)
    }

    private func parseUSBHex(_ value: String) -> Int? {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("0x") { trimmed.removeFirst(2) }
        guard let number = Int(trimmed, radix: 16), (1 ... 0xFFFF).contains(number) else { return nil }
        return number
    }

    private func isPrintableASCII(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (0x20 ... 0x7E).contains($0) }
    }

    private func isValidUSBSerial(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            (0x30 ... 0x39).contains($0) || (0x41 ... 0x5A).contains($0) ||
            (0x61 ... 0x7A).contains($0) || [0x2D, 0x2E, 0x5F].contains($0)
        }
    }

    @MainActor
    private func loadUSBIdentity() async {
        usbBusy = true
        defer { usbBusy = false }
        let api = DeviceAPIClient()
        for baseURL in endpointURLs {
            guard let identity = try? await api.usbIdentity(baseURL: baseURL, token: device.apiToken) else { continue }
            usbProductName = identity.productName
            usbVID = identity.vidHex ?? String(format: "0x%04X", identity.vid)
            usbPID = identity.pidHex ?? String(format: "0x%04X", identity.pid)
            usbSerialNumber = identity.serialNumber
            usbMessage = nil
            return
        }
        usbMessage = "Could not load the USB identity over Wi-Fi."
    }

    @MainActor
    private func saveUSBIdentity() async {
        let product = usbProductName.trimmingCharacters(in: .whitespacesAndNewlines)
        let serial = usbSerialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPrintableASCII(product), product.utf8.count <= 31,
              isValidUSBSerial(serial), serial.utf8.count <= 31,
              let vid = parseUSBHex(usbVID), let pid = parseUSBHex(usbPID) else {
            usbMessage = "Invalid USB identity values."
            return
        }
        usbBusy = true
        defer { usbBusy = false }
        let update = USBIdentityUpdate(productName: product, vid: vid, pid: pid, serialNumber: serial)
        let api = DeviceAPIClient()
        for baseURL in endpointURLs {
            do {
                try await api.setUSBIdentity(baseURL: baseURL, identity: update, token: device.apiToken)
                usbVID = String(format: "0x%04X", vid)
                usbPID = String(format: "0x%04X", pid)
                usbMessage = "Saved. InputPilot is restarting; USB reconnects with the new identity."
                return
            } catch {}
        }
        usbMessage = "Could not save the USB identity over Wi-Fi."
    }

    @MainActor
    private func resetUSBIdentity() async {
        usbBusy = true
        defer { usbBusy = false }
        let api = DeviceAPIClient()
        for baseURL in endpointURLs {
            do {
                try await api.resetUSBIdentity(baseURL: baseURL, token: device.apiToken)
                usbProductName = "InputPilot"
                usbVID = "0xCAFE"
                usbPID = "0x4001"
                usbSerialNumber = device.deviceId
                usbMessage = "Defaults restored. InputPilot is restarting."
                return
            } catch {}
        }
        usbMessage = "Could not restore the USB defaults over Wi-Fi."
    }
}
