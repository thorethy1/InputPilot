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
                case .choosePath:
                    choosePathStep
                case .securePairing:
                    securePairingStep
                case .scanning:
                    scanningStep
                case .bleScanning:
                    bluetoothScanningStep
                case .confirm:
                    confirmStep
                case .confirmBLE:
                    confirmBLEStep
                case .softAPInstructions:
                    softAPInstructionsStep
                case .softAPJoin:
                    softAPJoinStep
                case .softAPHomeWifi:
                    softAPHomeWifiStep
                case .softAPReconnect:
                    softAPReconnectStep
                case .softAPDiscover:
                    softAPDiscoverStep
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { wizardToolbar }
            .alert("Notice", isPresented: errorAlertBinding) {
                Button("OK") { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .interactiveDismissDisabled(viewModel.isProbing || viewModel.isSaving || viewModel.isJoining || viewModel.isProvisioning)
            .onAppear { viewModel.updateKnownDevices(storedDevices) }
            .onChange(of: storedDevices.map(\.deviceId)) { _, _ in
                viewModel.updateKnownDevices(storedDevices)
            }
            .onDisappear { bluetooth.stop() }
        }
    }

    private var navigationTitle: String {
        switch viewModel.step {
        case .choosePath:
            "Add Device"
        case .securePairing:
            "Secure Setup"
        case .scanning:
            "Scan Network"
        case .bleScanning:
            "Scan Bluetooth"
        case .confirm, .confirmBLE:
            "Confirm Device"
        case .softAPInstructions, .softAPJoin, .softAPHomeWifi, .softAPReconnect, .softAPDiscover:
            "Set Up New Device"
        }
    }

    @ToolbarContentBuilder
    private var wizardToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
                viewModel.cancelWizard()
                dismiss()
            }
            .disabled(viewModel.isProbing || viewModel.isSaving || viewModel.isJoining || viewModel.isProvisioning)
        }

        if viewModel.probedDevice != nil || viewModel.bleMetadata != nil {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task { await saveDevice() }
                }
                .disabled(viewModel.isSaving || viewModel.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var choosePathStep: some View {
        List {
            Section("New device") {
                Button { viewModel.chooseSecureSetup() } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Set Up Securely").foregroundStyle(.primary)
                            Text("Pair by USB first, then use encrypted Bluetooth and Wi-Fi.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "lock.shield") }
                }
            }
            Section("Migrate an existing device") {
                Label("Discovery can connect to older firmware without encryption. Update it, then pair by USB.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(AppColors.warning)
            }
            Section("Bluetooth") {
                Button {
                    viewModel.chooseBluetooth(); bluetooth.start()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Scan Nearby").foregroundStyle(.primary)
                            Text("Find nearby InputPilot devices without Wi‑Fi").font(.footnote).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "antenna.radiowaves.left.and.right") }
                }
            }
            Section {
                Button {
                    viewModel.chooseScan()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Scan Local Network")
                                .foregroundStyle(.primary)
                            Text("Find InputPilot in your Network")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "dot.radiowaves.left.and.right")
                    }
                }

                Button {
                    viewModel.chooseSoftAP()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Legacy Wi-Fi Setup")
                                .foregroundStyle(.primary)
                            Text("Join the device setup network and provision Wi‑Fi.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "wifi.router")
                    }
                }
            } header: {
                Text("Wi-Fi")
            } footer: {
                Text("Wi-Fi is optional. Network scanning uses Bonjour.")
            }
        }
    }

    private var scanningStep: some View {
        discoveryList(
            candidates: viewModel.newCandidates,
            emptyTitle: viewModel.hasHiddenKnownCandidates ? "Already Added" : "Scanning…",
            emptyDescription: viewModel.hasHiddenKnownCandidates
                ? "All InputPilot devices found on the network are already in your device list."
                                : "Looking for InputPilot devices on your local network."
        )
    }

    private var bluetoothScanningStep: some View {
        Group {
            let candidates = bluetooth.devices.filter { device in
                if let expected = viewModel.securelyPairedDeviceId,
                   device.deviceId.lowercased() != expected { return false }
                guard let existing = viewModel.knownDevices.match(deviceId: device.deviceId) else { return true }
                return !existing.hasBluetooth
            }
            if candidates.isEmpty {
                ContentUnavailableView("Scanning…", systemImage: "antenna.radiowaves.left.and.right", description: Text("Looking for nearby InputPilot devices."))
            } else {
                List(candidates) { device in
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

    private var softAPInstructionsStep: some View {
        List {
            Section {
                            Label("Power on the InputPilot device.", systemImage: "power")
                Label("Wait for the magenta setup LED.", systemImage: "light.max")
                Label("The device broadcasts a setup Wi‑Fi network named like `InputPilot-XXXX`.", systemImage: "wifi")
            } header: {
                Text("Before You Start")
            }

            Section {
                Button("Continue") {
                    viewModel.continueFromSoftAPInstructions()
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button("Back") {
                    viewModel.backToChoosePath()
                }
            }
        }
    }

    private var softAPJoinStep: some View {
        Form {
            Section {
                TextField("Setup network (SSID)", text: $viewModel.softAPSSID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password (optional for open networks)", text: $viewModel.softAPPassword)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text("Join the device Soft‑AP, then we'll connect to it at 192.168.4.1.")
            }

            Section {
                Button {
                    Task { await viewModel.joinSoftAP() }
                } label: {
                    if viewModel.isJoining {
                        HStack {
                            ProgressView()
                            Text("Joining…")
                        }
                    } else {
                        Text("Join Setup Network")
                    }
                }
                .disabled(viewModel.isJoining || viewModel.isProbing)

                Button("Continue") {
                    Task { await viewModel.continueWithoutJoiningSoftAP() }
                }
                .disabled(viewModel.isJoining || viewModel.isProbing)
            } footer: {
                Text("Or connect in iOS Settings, then Continue.")
            }
        }
        .overlay {
            if viewModel.isProbing {
                ProgressView("Connecting to device…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button("Back") {
                    viewModel.backFromSoftAPJoin()
                }
                .disabled(viewModel.isJoining || viewModel.isProbing)
            }
        }
    }

    private var softAPHomeWifiStep: some View {
        Form {
            if let wifi = viewModel.probedWifiStatus {
                Section("Device") {
                    if let apSSID = wifi.apSsid {
                        LabeledContent("Setup network", value: apSSID)
                    }
                    if let deviceId = wifi.deviceId {
                        LabeledContent("Device ID", value: deviceId)
                    }
                    if let mode = wifi.mode {
                        LabeledContent("Mode", value: mode)
                    }
                }
            }

            Section {
                TextField("Home Wi‑Fi name (SSID)", text: $viewModel.homeWifiSSID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Home Wi‑Fi password", text: $viewModel.homeWifiPassword)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text("Credentials are sent to the device over the setup network only.")
            }

            Section {
                Button {
                    Task { await viewModel.provisionHomeWifi() }
                } label: {
                    if viewModel.isProvisioning {
                        HStack {
                            ProgressView()
                            Text("Provisioning…")
                        }
                    } else {
                        Text("Save & Connect Device")
                    }
                }
                .disabled(viewModel.isProvisioning)
            }
        }
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button("Back") {
                    viewModel.backFromSoftAPHomeWifi()
                }
                .disabled(viewModel.isProvisioning)
            }
        }
    }

    private var softAPReconnectStep: some View {
        List {
            Section {
                Label("Reconnect this iPhone to your home Wi‑Fi.", systemImage: "iphone.gen3")
                Label("The InputPilot device will join the same network.", systemImage: "wifi")
            } header: {
                Text("Almost Done")
            }

            Section {
                Button("Continue") {
                    viewModel.continueAfterHomeWifiReconnect()
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button("Back") {
                    viewModel.backFromSoftAPReconnect()
                }
            }
        }
    }

    private var softAPDiscoverStep: some View {
        VStack(spacing: 0) {
            discoveryList(
                candidates: viewModel.filteredCandidates,
                emptyTitle: "Looking for device…",
                emptyDescription: "Searching your home network for the provisioned InputPilot device."
            )

            Form {
                Section {
                    TextField("Host or IP", text: $viewModel.softAPManualHost, prompt: Text("inputpilot-xxxx.local"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("Probe Address") {
                        Task { await viewModel.probeManualAddress() }
                    }
                    .disabled(viewModel.isProbing || viewModel.softAPManualHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text("Enter Address")
                } footer: {
                    Text("Use this if Bonjour discovery does not list your device yet.")
                }
            }
            .frame(maxHeight: 180)
        }
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button("Back") {
                    viewModel.backFromSoftAPDiscover()
                }
                .disabled(viewModel.isProbing)
            }
        }
    }

    @ViewBuilder
    private func discoveryList(
        candidates: [DiscoveredService],
        emptyTitle: String,
        emptyDescription: String
    ) -> some View {
        Group {
            if candidates.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: "antenna.radiowaves.left.and.right")
                } description: {
                    Text(emptyDescription)
                }
            } else {
                List(candidates) { candidate in
                    Button {
                        Task { await viewModel.selectCandidate(candidate) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(candidate.name)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(DeviceEndpointResolver.sanitizeHost(candidate.host))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if let deviceId = candidate.deviceId {
                                Text(deviceId)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .disabled(viewModel.isProbing)
                }
            }
        }
        .overlay {
            if viewModel.isProbing {
                ProgressView("Probing device…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    @ViewBuilder
    private var confirmStep: some View {
        if let probed = viewModel.probedDevice {
            VStack(spacing: 0) {
                if let message = viewModel.mergeMessage { Label(message, systemImage: "link.badge.plus").padding() }
                ConfirmDeviceForm(probed: probed, displayName: $viewModel.displayName,
                    apiToken: $viewModel.apiToken, showsAuthTokenField: viewModel.showsAuthTokenField)
            }
        }
    }

    @ViewBuilder private var confirmBLEStep: some View {
        if let metadata = viewModel.bleMetadata {
            Form {
                if let message = viewModel.mergeMessage { Section { Label(message, systemImage: "link.badge.plus") } }
                Section("Device") {
                    LabeledContent("Name", value: metadata.deviceName)
                    LabeledContent("Version", value: metadata.firmware)
                    LabeledContent("Device ID", value: metadata.deviceId)
                    LabeledContent("Connection", value: viewModel.mergeMessage == nil ? "Bluetooth" : "Bluetooth + existing connections")
                }
                Section("Friendly name") { TextField("Name", text: $viewModel.displayName) }
                if viewModel.securelyPairedDeviceId != nil && metadata.capabilities.contains("secure_wifi_setup_v1") {
                    Section {
                        TextField("Wi-Fi name (SSID)", text: $viewModel.homeWifiSSID)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Wi-Fi password", text: $viewModel.homeWifiPassword)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } header: {
                        Text("Encrypted Wi-Fi setup")
                    } footer: {
                        Text("Optional. Credentials are encrypted over the paired Bluetooth channel. Leave the SSID empty to use Bluetooth only.")
                    }
                } else if viewModel.securelyPairedDeviceId != nil {
                    Section("Wi-Fi setup") {
                        Label("Update firmware to configure Wi-Fi securely. This device can still be saved and used over encrypted Bluetooth.", systemImage: "info.circle")
                    }
                }
                if viewModel.showsAuthTokenField {
                    Section { TextField("API Token", text: $viewModel.apiToken).textInputAutocapitalization(.never).autocorrectionDisabled() }
                    footer: { Text("This device requires an API token for control.") }
                }
            }
        }
    }

    private var securePairingStep: some View {
        USBPairingInputTestView(
            onPaired: { viewModel.didPairSecurely(deviceId: $0) },
            embedded: true,
            continueAction: {
                viewModel.continueSecureSetup()
                bluetooth.start()
            }
        )
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button("Back") { viewModel.backToChoosePath() }
            }
        }
    }

    private func saveDevice() async {
        do {
            try await viewModel.saveDevice(context: modelContext)
            dismiss()
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }
}

#Preview {
    AddDeviceWizardView()
        .modelContainer(for: StoredDevice.self, inMemory: true)
}
