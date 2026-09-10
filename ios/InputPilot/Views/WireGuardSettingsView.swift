import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct WireGuardSettingsView: View {
    @Bindable var device: StoredDevice
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var bluetooth: BLEHIDControlTransport

    @State private var status: WireGuardDeviceStatus?
    @State private var imported: WireGuardConfiguration?
    @State private var importedName = ""
    @State private var enabledAfterInstall = true
    @State private var restrictToSSIDs = false
    @State private var allowedSSIDs: [String] = []
    @State private var customSSID = ""
    @State private var isBusy = false
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var showDeleteConfirmation = false

    init(device: StoredDevice) {
        _device = Bindable(wrappedValue: device)
        _bluetooth = ObservedObject(wrappedValue: InputPilotBluetoothManager.session(deviceId: device.deviceId))
    }

    var body: some View {
        Form {
            statusSection
            configurationSection
            policySection
            securitySection
        }
        .navigationTitle("WireGuard")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isBusy { ToolbarItem(placement: .primaryAction) { ProgressView() } }
        }
        .task {
            await bluetooth.connect()
            await refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await refresh(quietly: true)
            }
        }
        .refreshable { await refresh() }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [UTType(filenameExtension: "conf") ?? .plainText, .plainText],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                importConfiguration(from: url)
            case let .failure(error):
                errorMessage = error.localizedDescription
            }
        }
        .alert("WireGuard", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
        .confirmationDialog(
            "Remove the WireGuard configuration from InputPilot?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Configuration", role: .destructive) { Task { await removeConfiguration() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The private key and all SSID restrictions will be erased from the ESP32.")
        }
    }

    @ViewBuilder private var statusSection: some View {
        Section("Tunnel Status") {
            if let status {
                Label(stateTitle(status.state), systemImage: stateSymbol(status.state))
                    .foregroundStyle(stateColor(status.state))
                if status.configured {
                    LabeledContent("WireGuard IP", value: status.ip)
                    LabeledContent("Peer", value: status.endpoint)
                    Toggle("Enabled", isOn: Binding(
                        get: { status.enabled },
                        set: { value in Task { await setEnabled(value) } }
                    ))
                    .disabled(isBusy)
                }
                if !status.error.isEmpty {
                    Text("Error: \(status.error)")
                        .font(.caption.monospaced())
                        .foregroundStyle(AppColors.error)
                }
            } else if isBusy {
                HStack { ProgressView(); Text("Loading tunnel status…") }
            } else {
                Text("Status unavailable").foregroundStyle(.secondary)
            }
        }
    }

    private var configurationSection: some View {
        Section {
            Button { isImporting = true } label: {
                Label(status?.configured == true ? "Replace .conf File" : "Import .conf File",
                      systemImage: "doc.badge.plus")
            }
            .disabled(isBusy)

            if let imported {
                LabeledContent("File", value: importedName)
                LabeledContent("Interface address", value: imported.address)
                LabeledContent("Peer", value: imported.endpoint)
                LabeledContent("Allowed IPs", value: imported.allowedIPs)
                Toggle("Enable after upload", isOn: $enabledAfterInstall)
                Button("Install on InputPilot") { Task { await install(imported) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy || (restrictToSSIDs && allowedSSIDs.isEmpty))
            }

            if status?.configured == true {
                Button("Remove Configuration", role: .destructive) { showDeleteConfirmation = true }
                    .disabled(isBusy)
            }
        } header: {
            Text("Configuration")
        } footer: {
            Text("Supported: one IPv4 interface, one peer and one AllowedIPs range. IPv6, multiple peers and PostUp/PostDown commands are rejected on the device.")
        }
    }

    private var policySection: some View {
        Section {
            Toggle("Restrict to selected Wi-Fi networks", isOn: $restrictToSSIDs)
                .disabled(isBusy)
            if restrictToSSIDs {
                ForEach(candidateSSIDs, id: \.self) { ssid in
                    Toggle(ssid, isOn: Binding(
                        get: { allowedSSIDs.contains(ssid) },
                        set: { selected in
                            if selected { if !allowedSSIDs.contains(ssid) { allowedSSIDs.append(ssid) } }
                            else { allowedSSIDs.removeAll { $0 == ssid } }
                        }
                    ))
                    .disabled(isBusy)
                }
                HStack {
                    TextField("Wi-Fi name (SSID)", text: $customSSID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Add") { addCustomSSID() }
                        .disabled(isBusy || customSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if status?.configured == true {
                Button("Apply Wi-Fi Restriction") { Task { await savePolicy() } }
                    .disabled(isBusy || (restrictToSSIDs && allowedSSIDs.isEmpty))
            }
        } header: {
            Text("Wi-Fi Restriction")
        } footer: {
            Text(restrictToSSIDs
                 ? "The ESP32 starts WireGuard only while connected to one of the selected SSIDs."
                 : "The ESP32 starts WireGuard on every configured Wi-Fi network.")
        }
    }

    private var securitySection: some View {
        Section("Security") {
            Label("Encrypted transfer", systemImage: "lock.shield")
            Text("The .conf file is sent only through InputPilot Secure Protocol v2. Its private and preshared keys are stored on the ESP32 and are never returned by status or diagnostics. The app discards the imported file from memory after a successful upload.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var candidateSSIDs: [String] {
        Array(Set(device.cachedWiFiNetworks + allowedSSIDs)).sorted()
    }

    private func importConfiguration(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= WireGuardConfiguration.maximumBytes else {
                throw WireGuardConfigurationError.tooLarge(data.count)
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw WireGuardConfigurationError.invalidEncoding
            }
            imported = try WireGuardConfiguration.parse(text)
            importedName = url.lastPathComponent
        } catch {
            imported = nil
            errorMessage = error.localizedDescription
        }
    }

    @MainActor private func refresh(quietly: Bool = false) async {
        if !quietly { isBusy = true }
        defer { if !quietly { isBusy = false } }
        do {
            let hadStatus = status != nil
            var latest = try await WireGuardDeviceClient.status(
                includeDetails: !quietly || !hadStatus, using: request
            )
            if quietly, let previous = status {
                latest.endpoint = previous.endpoint
                latest.ssids = previous.ssids
            }
            status = latest
            // Background polling updates live state without undoing policy
            // edits that have not been applied yet.
            if !quietly || !hadStatus {
                restrictToSSIDs = latest.restricted
                allowedSSIDs = latest.ssids
            }
            if !latest.ip.isEmpty {
                device.rememberWiFiHost(latest.ip)
                try? modelContext.save()
            }
        } catch {
            if !quietly { errorMessage = error.localizedDescription }
        }
    }

    @MainActor private func install(_ configuration: WireGuardConfiguration) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let token = UInt64.random(in: 1 ... UInt64.max)
            let ssids = restrictToSSIDs ? allowedSSIDs : []
            var lastError: Error = TransportError.unavailable
            var installed = false
            do {
                try await bluetooth.waitUntilReady()
                try await WireGuardDeviceClient.install(
                    configuration, enabled: enabledAfterInstall, restrictedTo: ssids,
                    token: token,
                    using: { command, timeout in try await bluetooth.request(command, timeout: timeout) },
                    binaryRequest: { payload, timeout in
                        try await bluetooth.wireGuardBinaryRequest(payload, timeout: timeout)
                    }
                )
                installed = true
            } catch { lastError = error }
            if !installed {
                for wifi in wifiSessions() {
                    do {
                        try await WireGuardDeviceClient.install(
                            configuration, enabled: enabledAfterInstall, restrictedTo: ssids,
                            token: token,
                            using: { command, timeout in try await wifi.request(command, timeout: timeout) }
                        )
                        installed = true
                        break
                    } catch { lastError = error }
                }
            }
            if !installed { throw lastError }
            device.rememberWiFiHost(configuration.address)
            try modelContext.save()
            imported = nil
            importedName = ""
            status = nil
            await refresh(quietly: true)
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor private func savePolicy() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let ssids = restrictToSSIDs ? allowedSSIDs : []
            var lastError: Error = TransportError.unavailable
            var saved = false
            do {
                try await bluetooth.waitUntilReady()
                try await WireGuardDeviceClient.setPolicy(
                    ssids: ssids,
                    using: { command, timeout in try await bluetooth.request(command, timeout: timeout) },
                    binaryRequest: { payload, timeout in
                        try await bluetooth.wireGuardBinaryRequest(payload, timeout: timeout)
                    }
                )
                saved = true
            } catch { lastError = error }
            if !saved {
                for wifi in wifiSessions() {
                    do {
                        try await WireGuardDeviceClient.setPolicy(
                            ssids: ssids,
                            using: { command, timeout in try await wifi.request(command, timeout: timeout) }
                        )
                        saved = true
                        break
                    } catch { lastError = error }
                }
            }
            if !saved { throw lastError }
            await refresh(quietly: true)
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor private func setEnabled(_ enabled: Bool) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await WireGuardDeviceClient.setEnabled(enabled, using: request)
            await refresh(quietly: true)
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor private func removeConfiguration() async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await WireGuardDeviceClient.remove(using: request)
            allowedSSIDs = []
            restrictToSSIDs = false
            status = nil
            await refresh(quietly: true)
        } catch { errorMessage = error.localizedDescription }
    }

    private func addCustomSSID() {
        let ssid = customSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1 ... 32).contains(ssid.lengthOfBytes(using: .utf8)) else {
            errorMessage = "A Wi-Fi name must contain 1 to 32 UTF-8 bytes."
            return
        }
        if !allowedSSIDs.contains(ssid) { allowedSSIDs.append(ssid) }
        customSSID = ""
    }

    private func request(_ command: String, _ timeout: TimeInterval) async throws -> String {
        var lastError: Error = TransportError.unavailable
        do { return try await bluetooth.request(command, timeout: timeout) }
        catch { lastError = error }
        for endpoint in DeviceEndpointResolver.endpointURLs(
            mdnsHost: device.mdnsHost, staIP: device.staIP, knownHosts: device.knownWiFiHosts
        ) {
            let wifi = InputPilotWiFiManager.session(
                host: endpoint.host ?? endpoint.absoluteString, deviceId: device.deviceId
            )
            do { return try await wifi.request(command, timeout: timeout) }
            catch { lastError = error }
        }
        throw lastError
    }

    private func wifiSessions() -> [TCPHIDControlTransport] {
        DeviceEndpointResolver.endpointURLs(
            mdnsHost: device.mdnsHost, staIP: device.staIP, knownHosts: device.knownWiFiHosts
        ).map { endpoint in
            InputPilotWiFiManager.session(
                host: endpoint.host ?? endpoint.absoluteString, deviceId: device.deviceId
            )
        }
    }

    private func stateTitle(_ state: WireGuardDeviceStatus.State) -> String {
        switch state {
        case .disabled: "Disabled"
        case .notConfigured: "Not configured"
        case .waitingWiFi: "Waiting for Wi-Fi"
        case .ssidBlocked: "Disabled on this Wi-Fi"
        case .captiveBlocked: "Waiting for captive portal"
        case .waitingTime: "Synchronizing clock"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .error: "Connection failed"
        }
    }

    private func stateSymbol(_ state: WireGuardDeviceStatus.State) -> String {
        switch state {
        case .connected: "checkmark.shield.fill"
        case .connecting, .waitingTime: "arrow.triangle.2.circlepath"
        case .error: "exclamationmark.shield.fill"
        case .ssidBlocked, .captiveBlocked, .disabled: "shield.slash"
        case .waitingWiFi: "wifi.slash"
        case .notConfigured: "shield"
        }
    }

    private func stateColor(_ state: WireGuardDeviceStatus.State) -> Color {
        switch state {
        case .connected: AppColors.success
        case .connecting, .waitingTime: AppColors.info
        case .error: AppColors.error
        default: AppColors.neutral
        }
    }
}
