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
    @State private var showDeleteConfirmation = false
    @State private var usbProductName = "InputPilot"
    @State private var usbVID = "0xCAFE"
    @State private var usbPID = "0x4001"
    @State private var usbSerialNumber = ""
    @State private var usbBusy = false
    @State private var usbMessage: String?
    @State private var keepAwakeBusy = false
    @State private var keepAwakeMessage: String?
    @State private var managementBusy = false
    @State private var managementMessage: String?

    init(device: StoredDevice) {
        _device = Bindable(wrappedValue: device)
        _bluetooth = ObservedObject(wrappedValue: InputPilotBluetoothManager.session(deviceId: device.deviceId))
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
                let transports = [device.capabilities.contains("wifi_transport") ? "Wi-Fi" : nil, device.capabilities.contains("ble_transport") ? "Bluetooth" : nil].compactMap { $0 }
                LabeledContent("Connection", value: transports.isEmpty ? "Unknown" : transports.joined(separator: " + "))
            }

            Section("Management") {
                Button("Restart InputPilot") { Task { await rebootDevice() } }
                    .disabled(managementBusy || !hasPairingKey)
                if managementBusy { ProgressView() }
                if let managementMessage {
                    Text(managementMessage).font(.caption).foregroundStyle(.secondary)
                }
            }

            if device.capabilities.contains("secure_usb_identity") {
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

            Section("Security") {
                if hasPairingKey {
                    Label("USB-trusted Secure Protocol v2", systemImage: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("USB trust is missing", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppColors.warning)
                    Text("Reflash current firmware if needed, then add the device again through secure USB pairing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Keep Awake") {
                Toggle("Move pointer periodically", isOn: moveEnabledBinding)
                    .disabled(!canConfigureKeepAwake || keepAwakeBusy)
                Picker("Movement interval", selection: moveIntervalBinding) {
                    ForEach(keepAwakeIntervals, id: \.self) { Text(intervalLabel($0)).tag($0) }
                }
                .disabled(!device.jiggleEnabled || !canConfigureKeepAwake || keepAwakeBusy)
                Toggle("Click periodically", isOn: clickEnabledBinding)
                    .disabled(!canConfigureKeepAwake || keepAwakeBusy)
                Picker("Click interval", selection: clickIntervalBinding) {
                    ForEach(keepAwakeIntervals, id: \.self) { Text(intervalLabel($0)).tag($0) }
                }
                .disabled(!device.clickEnabled || !canConfigureKeepAwake || keepAwakeBusy)
                HStack {
                    Button("Test movement") { Task { await testKeepAwake(.mouseMove(8, 0)) } }
                    Spacer()
                    Button("Test click") { Task { await testKeepAwake(.click(.left)) } }
                }
                .disabled(!canConfigureKeepAwake || keepAwakeBusy)
                if keepAwakeBusy { ProgressView() }
                if let keepAwakeMessage {
                    Text(keepAwakeMessage).font(.caption).foregroundStyle(.secondary)
                }
                Text("InputPilot stores both schedules in firmware and continues running them after the phone disconnects.")
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
        }
        .onDisappear {
            saveDisplayName()
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

    private let keepAwakeIntervals = [5_000, 10_000, 30_000, 60_000, 300_000, 900_000, 3_600_000]
    private var canConfigureKeepAwake: Bool {
        bluetooth.state == .ready || viewModel.wifiState(for: device.deviceId) == .reachable
    }

    private var hasPairingKey: Bool { PairingKeyStore.load(deviceId: device.deviceId) != nil }
    private var moveEnabledBinding: Binding<Bool> { Binding(get: { device.jiggleEnabled }, set: { device.jiggleEnabled = $0; saveKeepAwake() }) }
    private var clickEnabledBinding: Binding<Bool> { Binding(get: { device.clickEnabled }, set: { device.clickEnabled = $0; saveKeepAwake() }) }
    private var moveIntervalBinding: Binding<Int> { Binding(get: { device.moveIntervalMs }, set: { device.moveIntervalMs = $0; saveKeepAwake() }) }
    private var clickIntervalBinding: Binding<Int> { Binding(get: { device.clickIntervalMs }, set: { device.clickIntervalMs = $0; saveKeepAwake() }) }

    private func intervalLabel(_ milliseconds: Int) -> String {
        if milliseconds < 60_000 { return "\(milliseconds / 1000) seconds" }
        let minutes = milliseconds / 60_000
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    private func saveKeepAwake() {
        let settings = KeepAwakeSettings(
            moveEnabled: device.jiggleEnabled,
            moveIntervalMs: device.moveIntervalMs,
            clickEnabled: device.clickEnabled,
            clickIntervalMs: device.clickIntervalMs
        )
        Task { await applyKeepAwake(settings) }
    }

    @MainActor
    private func applyKeepAwake(_ settings: KeepAwakeSettings) async {
        guard canConfigureKeepAwake else {
            keepAwakeMessage = "Connect once over Bluetooth or Wi-Fi to send this change."
            return
        }
        keepAwakeBusy = true
        defer { keepAwakeBusy = false }
        do {
            if bluetooth.state == .ready {
                try await bluetooth.setKeepAwake(settings)
                DeviceRepository(context: modelContext).apply(settings, to: device)
                try modelContext.save()
            } else if hasPairingKey, let host = wifiControlHost {
                let tcp = InputPilotWiFiManager.session(host: host, deviceId: device.deviceId)
                try await tcp.setKeepAwake(settings)
                DeviceRepository(context: modelContext).apply(settings, to: device)
                try modelContext.save()
            } else {
                try await DeviceRepository(context: modelContext).setKeepAwake(device, settings: settings)
            }
            keepAwakeMessage = "Saved in InputPilot firmware."
        } catch {
            keepAwakeMessage = error.localizedDescription
        }
    }

    @MainActor
    private func testKeepAwake(_ event: HIDEvent) async {
        keepAwakeBusy = true
        defer { keepAwakeBusy = false }
        do {
            if bluetooth.state == .ready {
                try await bluetooth.send(event)
            } else if hasPairingKey, let host = wifiControlHost {
                let tcp = InputPilotWiFiManager.session(host: host, deviceId: device.deviceId)
                try await tcp.send(event)
            } else { throw TransportError.unavailable }
            keepAwakeMessage = "Test action sent."
        } catch { keepAwakeMessage = error.localizedDescription }
    }

    private func saveDisplayName() {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != device.displayName else { return }
        let repository = DeviceRepository(context: modelContext)
        try? repository.rename(device, name: trimmed)
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

    private var wifiControlHost: String? {
        if let staIP = device.staIP, !DeviceEndpointResolver.sanitizeHost(staIP).isEmpty {
            return DeviceEndpointResolver.sanitizeHost(staIP)
        }
        let host = DeviceEndpointResolver.sanitizeHost(device.mdnsHost)
        return host.isEmpty ? nil : host
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
        if hasPairingKey {
            guard device.capabilities.contains("secure_usb_identity") else {
                usbMessage = "Current secure firmware is required before changing USB identity."
                return
            }
            do {
                if bluetooth.state == .ready {
                    try await bluetooth.setUSBIdentity(productName: product, vid: vid, pid: pid, serialNumber: serial)
                } else if let host = wifiControlHost {
                    let tcp = InputPilotWiFiManager.session(host: host, deviceId: device.deviceId)
                    try await tcp.setUSBIdentity(productName: product, vid: vid, pid: pid, serialNumber: serial)
                } else { throw TransportError.unavailable }
                usbVID = String(format: "0x%04X", vid)
                usbPID = String(format: "0x%04X", pid)
                usbMessage = "Saved securely. InputPilot is restarting with the new USB identity."
                return
            } catch {
                usbMessage = error.localizedDescription
                return
            }
        }
        usbMessage = "Authenticate the device over Bluetooth before changing USB identity."
    }

    @MainActor
    private func resetUSBIdentity() async {
        usbBusy = true
        defer { usbBusy = false }
        if hasPairingKey {
            guard device.capabilities.contains("secure_usb_identity") else {
                usbMessage = "Current secure firmware is required before restoring USB defaults."
                return
            }
            do {
                if bluetooth.state == .ready {
                    try await bluetooth.resetUSBIdentity()
                } else if let host = wifiControlHost {
                    let tcp = InputPilotWiFiManager.session(host: host, deviceId: device.deviceId)
                    try await tcp.resetUSBIdentity()
                } else { throw TransportError.unavailable }
                usbProductName = "InputPilot"
                usbVID = "0xCAFE"
                usbPID = "0x4001"
                usbSerialNumber = device.deviceId
                usbMessage = "Defaults restored securely. InputPilot is restarting."
                return
            } catch {
                usbMessage = error.localizedDescription
                return
            }
        }
        usbMessage = "Authenticate the device over Bluetooth before restoring USB defaults."
    }

    @MainActor
    private func rebootDevice() async {
        managementBusy = true
        defer { managementBusy = false }
        do {
            if bluetooth.state == .ready {
                try await bluetooth.reboot()
            } else if let host = wifiControlHost {
                try await InputPilotWiFiManager.session(host: host, deviceId: device.deviceId).reboot()
            } else { throw TransportError.unavailable }
            managementMessage = "Authenticated restart requested."
        } catch { managementMessage = error.localizedDescription }
    }
}
