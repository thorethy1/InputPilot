import SwiftUI

struct CaptivePortalScriptsView: View {
    let device: StoredDevice

    @ObservedObject private var bluetooth: BLEHIDControlTransport
    @State private var scripts: [CaptivePortalScriptMetadata] = []
    @State private var runStatus: CaptivePortalRunStatus?
    @State private var editor: EditorPayload?
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var deleteTarget: CaptivePortalScriptMetadata?

    init(device: StoredDevice) {
        self.device = device
        _bluetooth = ObservedObject(wrappedValue: InputPilotBluetoothManager.session(deviceId: device.deviceId))
    }

    var body: some View {
        List {
            statusSection
            Section {
                if scripts.isEmpty, !isBusy {
                    ContentUnavailableView(
                        "No Portal Scripts",
                        systemImage: "wifi.exclamationmark",
                        description: Text("Add an HTTP workflow and bind it to one of this InputPilot's saved Wi-Fi networks.")
                    )
                } else {
                    ForEach(Array(scripts.enumerated()), id: \.element.id) { entry in
                        let index = entry.offset
                        let script = entry.element
                        Button { Task { await edit(script, index: index) } } label: {
                            scriptRow(script)
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) { deleteTarget = script } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button { Task { await run(script) } } label: { Label("Run Now", systemImage: "play.fill") }
                            Button(role: .destructive) { deleteTarget = script } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Wi-Fi Scripts")
                    Spacer()
                    if isBusy { ProgressView().controlSize(.small) }
                }
            } footer: {
                Text("Scripts are stored on InputPilot and start once per new connection after their delay. They keep working when the iOS app is closed.")
            }

            Section("Runtime") {
                Label("Runs on the InputPilot firmware", systemImage: "memorychip")
                Text("iOS and the ESP32 cannot run arbitrary POSIX shell, curl, or Python. The editor uses InputPilot's bounded HTTP workflow language instead. No portal-specific script is bundled with the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Captive Portal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editor = EditorPayload() } label: { Image(systemName: "plus") }
                    .disabled(isBusy || scripts.count >= 5)
                    .accessibilityLabel("Add captive portal script")
            }
        }
        .task {
            await bluetooth.connect()
            await refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await refreshStatus(quietly: true)
            }
        }
        .refreshable { await refresh() }
        .sheet(item: $editor) { payload in
            CaptivePortalScriptEditor(
                configuredNetworks: device.cachedWiFiNetworks,
                payload: payload,
                onSave: { ssid, delay, enabled, script in
                    try await save(ssid: ssid, delayMs: delay, enabled: enabled, script: script)
                }
            )
        }
        .alert("Captive Portal", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
        .confirmationDialog(
            "Delete script for \(deleteTarget?.ssid ?? "this network")?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let target = deleteTarget else { return }
                deleteTarget = nil
                Task { await remove(target) }
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        }
    }

    @ViewBuilder private var statusSection: some View {
        Section("Last Run") {
            if let runStatus {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: statusSymbol(runStatus.state))
                        .foregroundStyle(statusColor(runStatus.state))
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(runStatus.state.title).font(.headline)
                        if !runStatus.ssid.isEmpty { Text(runStatus.ssid).font(.subheadline) }
                        if !runStatus.message.isEmpty { Text(runStatus.message).font(.caption).foregroundStyle(.secondary) }
                        if !runStatus.error.isEmpty { Text("Code: \(runStatus.error)").font(.caption.monospaced()).foregroundStyle(AppColors.error) }
                    }
                }
                .accessibilityElement(children: .combine)
            } else if isBusy {
                HStack { ProgressView(); Text("Loading status…") }
            } else {
                Text("No status available.").foregroundStyle(.secondary)
            }
        }
    }

    private func scriptRow(_ script: CaptivePortalScriptMetadata) -> some View {
        HStack(spacing: 12) {
            Image(systemName: script.enabled ? "wifi" : "wifi.slash")
                .foregroundStyle(script.enabled ? Color.accentColor : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(script.ssid).font(.headline).foregroundStyle(.primary)
                Text(script.enabled ? "After \(formattedDelay(script.delayMs))" : "Disabled")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func refresh() async {
        isBusy = true
        defer { isBusy = false }
        do {
            scripts = try await CaptivePortalDeviceClient.list(using: request)
            runStatus = try await CaptivePortalDeviceClient.status(using: request)
        } catch { errorMessage = error.localizedDescription }
    }

    private func refreshStatus(quietly: Bool) async {
        do { runStatus = try await CaptivePortalDeviceClient.status(using: request) }
        catch { if !quietly { errorMessage = error.localizedDescription } }
    }

    private func edit(_ metadata: CaptivePortalScriptMetadata, index: Int) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let script = try await CaptivePortalDeviceClient.script(index: index, size: metadata.size, using: request)
            editor = EditorPayload(metadata: metadata, script: script)
        } catch { errorMessage = error.localizedDescription }
    }

    private func save(ssid: String, delayMs: Int, enabled: Bool, script: String) async throws {
        isBusy = true
        defer { isBusy = false }
        var lastError: Error = TransportError.unavailable
        let uploadToken = UInt64.random(in: 1 ... UInt64.max)
        do {
            try await bluetooth.waitUntilReady()
            try await CaptivePortalDeviceClient.save(
                ssid: ssid, delayMs: delayMs, enabled: enabled, script: script,
                token: uploadToken,
                using: { command, timeout in try await bluetooth.request(command, timeout: timeout) },
                binaryRequest: { payload, timeout in
                    try await bluetooth.captiveBinaryRequest(payload, timeout: timeout)
                }
            )
        } catch {
            lastError = error
            var uploaded = false
            for endpoint in DeviceEndpointResolver.endpointURLs(
                mdnsHost: device.mdnsHost, staIP: device.staIP, knownHosts: device.knownWiFiHosts
            ) {
                let wifi = InputPilotWiFiManager.session(
                    host: endpoint.host ?? endpoint.absoluteString, deviceId: device.deviceId
                )
                do {
                    try await CaptivePortalDeviceClient.save(
                        ssid: ssid, delayMs: delayMs, enabled: enabled, script: script,
                        token: uploadToken,
                        using: { command, timeout in try await wifi.request(command, timeout: timeout) }
                    )
                    uploaded = true
                    break
                } catch { lastError = error }
            }
            if !uploaded { throw lastError }
        }
        scripts = try await CaptivePortalDeviceClient.list(using: request)
        runStatus = try? await CaptivePortalDeviceClient.status(using: request)
    }

    private func remove(_ metadata: CaptivePortalScriptMetadata) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await CaptivePortalDeviceClient.remove(ssid: metadata.ssid, using: request)
            scripts = try await CaptivePortalDeviceClient.list(using: request)
        } catch { errorMessage = error.localizedDescription }
    }

    private func run(_ metadata: CaptivePortalScriptMetadata) async {
        do {
            try await CaptivePortalDeviceClient.run(ssid: metadata.ssid, using: request)
            await refreshStatus(quietly: false)
        } catch { errorMessage = error.localizedDescription }
    }

    private func request(_ command: String, _ timeout: TimeInterval) async throws -> String {
        var lastError: Error = TransportError.unavailable
        do { return try await bluetooth.request(command, timeout: timeout) }
        catch { lastError = error }
        let endpoints = DeviceEndpointResolver.endpointURLs(
            mdnsHost: device.mdnsHost, staIP: device.staIP, knownHosts: device.knownWiFiHosts
        )
        for endpoint in endpoints {
            let wifi = InputPilotWiFiManager.session(host: endpoint.host ?? endpoint.absoluteString,
                                                     deviceId: device.deviceId)
            do { return try await wifi.request(command, timeout: timeout) }
            catch { lastError = error }
        }
        throw lastError
    }

    private func formattedDelay(_ milliseconds: Int) -> String {
        milliseconds.isMultiple(of: 1_000) ? "\(milliseconds / 1_000) s" : "\(milliseconds) ms"
    }

    private func statusSymbol(_ state: CaptivePortalRunStatus.State) -> String {
        switch state {
        case .idle: "minus.circle"
        case .waiting: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .success, .alreadyConnected: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    private func statusColor(_ state: CaptivePortalRunStatus.State) -> Color {
        switch state {
        case .success, .alreadyConnected: AppColors.success
        case .failed: AppColors.error
        case .waiting, .running: AppColors.info
        case .idle: AppColors.neutral
        }
    }
}

private struct EditorPayload: Identifiable {
    let id = UUID()
    var ssid = ""
    var delayMs = 4_000
    var enabled = true
    var script = "INPUTPILOT-CAPTIVE/1\n\n# Add HTTP workflow commands here.\n"

    init() {}
    init(metadata: CaptivePortalScriptMetadata, script: String) {
        ssid = metadata.ssid; delayMs = metadata.delayMs
        enabled = metadata.enabled; self.script = script
    }
}

private struct CaptivePortalScriptEditor: View {
    let configuredNetworks: [String]
    let payload: EditorPayload
    let onSave: (String, Int, Bool, String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var ssid: String
    @State private var delayMs: Int
    @State private var enabled: Bool
    @State private var script: String
    @State private var isSaving = false
    @State private var validationMessage: String?

    init(configuredNetworks: [String], payload: EditorPayload,
         onSave: @escaping (String, Int, Bool, String) async throws -> Void) {
        self.configuredNetworks = configuredNetworks
        self.payload = payload
        self.onSave = onSave
        _ssid = State(initialValue: payload.ssid)
        _delayMs = State(initialValue: payload.delayMs)
        _enabled = State(initialValue: payload.enabled)
        _script = State(initialValue: payload.script)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Trigger") {
                    if payload.ssid.isEmpty, !configuredNetworks.isEmpty {
                        Picker("Saved network", selection: $ssid) {
                            Text("Choose…").tag("")
                            ForEach(configuredNetworks, id: \.self) { Text($0).tag($0) }
                        }
                        .livePickerAccent()
                    }
                    TextField("Wi-Fi name (SSID)", text: $ssid)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(!payload.ssid.isEmpty)
                    Toggle("Enabled", isOn: $enabled)
                    Stepper(value: $delayMs, in: 0 ... 60_000, step: 1_000) {
                        LabeledContent("Start delay", value: "\(delayMs / 1_000) s")
                    }
                }
                Section {
                    TextEditor(text: $script)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 280)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Text("\(script.lengthOfBytes(using: .utf8)) / \(CaptivePortalScriptValidator.maximumBytes) bytes")
                        Spacer()
                        Button("Validate") { validate() }
                    }
                    .font(.caption)
                    if let validationMessage {
                        Text(validationMessage).font(.caption)
                            .foregroundStyle(validationMessage == "Script is valid." ? AppColors.success : AppColors.error)
                    }
                } header: { Text("HTTP Workflow") } footer: {
                    Text("Commands: GET, POST_FORM, POST_JSON, HEADER, WAIT, EXPECT_STATUS, EXPECT_BODY, REQUIRE_HOST_SUFFIX, SET_ORIGIN, CAPTURE_JSON, CAPTURE_BETWEEN, LABEL/GOTO, IF_STATUS, IF_BODY_CONTAINS, SUCCESS, ALREADY_CONNECTED, FAIL. Use ${NAME} or ${url:NAME} for captured values. HTTP redirects and cookies are handled automatically.")
                }
                Section("Security") {
                    Label("Only add scripts you trust", systemImage: "exclamationmark.shield")
                    Text("A workflow can send HTTP requests through the connected Wi-Fi. Use REQUIRE_HOST_SUFFIX before submitting tokens or credentials to a portal.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(payload.ssid.isEmpty ? "New Portal Script" : "Edit Portal Script")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isSaving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(isSaving || ssid.isEmpty)
                }
            }
        }
    }

    private func validate() {
        do { try CaptivePortalScriptValidator.validate(script); validationMessage = "Script is valid." }
        catch { validationMessage = error.localizedDescription }
    }

    private func save() async {
        let network = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try CaptivePortalScriptValidator.validate(script)
            guard (1 ... 32).contains(network.lengthOfBytes(using: .utf8)) else {
                throw TransportError.failed("The Wi-Fi name must contain 1 to 32 UTF-8 bytes.")
            }
            isSaving = true
            try await onSave(network, delayMs, enabled, script)
            dismiss()
        } catch {
            isSaving = false
            validationMessage = error.localizedDescription
        }
    }
}
