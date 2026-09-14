import SwiftData
import SwiftUI
import UIKit

struct AddDeviceWizardView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var storedDevices: [StoredDevice]
    @StateObject private var viewModel: AddDeviceWizardViewModel

    let flow: DeviceSetupFlow
    var onFinished: ((Bool) -> Void)?

    init(flow: DeviceSetupFlow = .addDevice, onFinished: ((Bool) -> Void)? = nil) {
        self.flow = flow
        self.onFinished = onFinished
        _viewModel = StateObject(wrappedValue: AddDeviceWizardViewModel(flow: flow))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.step {
                case .welcome: welcomeStep
                case .hardware: hardwareStep
                case .securePairing: securePairingStep
                case .bleScanning: bluetoothScanningStep
                case .confirmBLE: confirmBLEStep
                case .connectionTest: validationStep(.connection)
                case .mouseTest: validationStep(.mouse)
                case .keyboardTest: validationStep(.keyboard)
                case .complete: completeStep
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
            .onChange(of: storedDevices.map(\.deviceId)) { _, _ in
                viewModel.updateKnownDevices(storedDevices)
            }
        }
    }

    private var navigationTitle: String {
        switch viewModel.step {
        case .welcome: "Welcome"
        case .hardware: "Hardware"
        case .securePairing: "USB Trust"
        case .bleScanning: "Bluetooth"
        case .confirmBLE: "Connection Setup"
        case .connectionTest: "Connection Test"
        case .mouseTest: "Mouse Test"
        case .keyboardTest: "Keyboard Test"
        case .complete: "Setup Complete"
        }
    }

    @ToolbarContentBuilder
    private var wizardToolbar: some ToolbarContent {
        if viewModel.step != .complete {
            ToolbarItem(placement: .cancellationAction) {
                Button(flow == .firstRun ? "Later" : "Cancel") { cancel() }
                    .disabled(viewModel.isSaving)
            }
        }
        if viewModel.bleMetadata != nil {
            ToolbarItem(placement: .confirmationAction) {
                Button(flow == .firstRun ? "Continue" : "Finish") {
                    Task { await saveDevice() }
                }
                .disabled(
                    viewModel.isSaving ||
                    viewModel.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    (viewModel.configureWiFi && viewModel.homeWifiSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                )
            }
        }
    }

    private var welcomeStep: some View {
        SetupIntroductionView(
            icon: "cursorarrow.motionlines",
            title: "Control a computer from your iPhone",
            message: "InputPilot turns an ESP32-S3 into a local, authenticated USB keyboard and mouse. No cloud account or internet connection is required.",
            points: [
                ("lock.shield", "USB establishes trust before Bluetooth or Wi-Fi can control input."),
                ("bluetooth", "Bluetooth-only setup stays fully supported."),
                ("wifi", "Wi-Fi is optional and can be added or changed later.")
            ],
            actionTitle: "Get Started",
            action: viewModel.continueFromWelcome
        )
    }

    private var hardwareStep: some View {
        SetupIntroductionView(
            icon: "memorychip",
            title: "Prepare InputPilot",
            message: "Use an ESP32-S3 Zero with current InputPilot firmware and a USB data cable. Power it on before continuing.",
            points: [
                ("cable.connector", "The cable must support data, not charging only."),
                ("iphone", "First connect InputPilot to this iPhone so it can type its one-time trust code."),
                ("desktopcomputer", "After pairing, connect its USB output to the computer you want to control for the mouse and keyboard tests.")
            ],
            actionTitle: "InputPilot Is Flashed — Continue",
            externalLinkTitle: "InputPilot is not flashed yet?",
            externalLinkMessage: "Open the official Web Flasher in Chrome or Edge on a desktop computer. Connect the ESP32-S3 by USB, install the firmware, then return here.",
            externalLinkURL: InputPilotLinks.webFlasher,
            action: viewModel.continueFromHardware
        )
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button("Back") { viewModel.backToWelcome() }
            }
        }
    }

    private var securePairingStep: some View {
        USBPairingInputTestView(
            onPaired: { viewModel.didPairSecurely(deviceId: $0) },
            embedded: true,
            continueAction: { viewModel.continueSecureSetup() }
        )
        .toolbar {
            if flow == .firstRun {
                ToolbarItem(placement: .bottomBar) {
                    Button("Back") { viewModel.backFromPairing() }
                }
            }
        }
    }

    private var bluetoothScanningStep: some View {
        BluetoothDiscoveryStepView(
            expectedDeviceId: viewModel.securelyPairedDeviceId,
            onMetadata: viewModel.selectBluetooth,
            onError: { viewModel.errorMessage = $0 }
        )
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button("Back") { viewModel.backToPairing() }
            }
        }
    }

    @ViewBuilder private var confirmBLEStep: some View {
        if let metadata = viewModel.bleMetadata {
            Form {
                if let message = viewModel.mergeMessage {
                    Section { Label(message, systemImage: "link.badge.plus") }
                }
                Section("Device") {
                    LabeledContent("Name", value: metadata.deviceName)
                    LabeledContent("Version", value: metadata.firmware)
                    LabeledContent("Security", value: "Authenticated")
                }
                Section("Friendly name") {
                    TextField("Name", text: $viewModel.displayName)
                }
                if viewModel.supportsWiFiSetup {
                    Section {
                        Toggle("Configure Wi-Fi", isOn: $viewModel.configureWiFi)
                    } footer: {
                        Text("Optional. Bluetooth works nearby without a router or internet connection.")
                    }
                } else {
                    Section("Connection") {
                        Label("Bluetooth only", systemImage: "bluetooth")
                        Text("This InputPilot does not offer Wi-Fi setup. Secure Bluetooth is a complete supported connection path.")
                            .foregroundStyle(.secondary)
                    }
                }
                if viewModel.supportsWiFiSetup, viewModel.configureWiFi {
                    Section {
                        TextField("Wi-Fi name (SSID)", text: $viewModel.homeWifiSSID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Wi-Fi password", text: $viewModel.homeWifiPassword)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text("Wi-Fi")
                    } footer: {
                        Text("iOS may now ask for Local Network access so InputPilot can be found after joining Wi-Fi. Credentials are sent through the authenticated Bluetooth session.")
                    }
                }
                if viewModel.isSaving {
                    Section { ProgressView("Verifying the secure connection…") }
                }
            }
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    Button("Back") { viewModel.backFromConfirm() }
                        .disabled(viewModel.isSaving)
                }
            }
        }
    }

    @ViewBuilder
    private func validationStep(_ kind: SetupValidationKind) -> some View {
        if let device = savedDevice {
            SetupValidationView(device: device, kind: kind) {
                switch kind {
                case .connection: viewModel.connectionTestPassed()
                case .mouse: viewModel.mouseTestPassed()
                case .keyboard: viewModel.keyboardTestPassed()
                }
            }
            .toolbar {
                if kind != .connection {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Back") {
                            if kind == .mouse { viewModel.backToConnectionTest() }
                            else { viewModel.backToMouseTest() }
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView {
                ProgressView()
            } description: {
                Text("Loading the saved InputPilot…")
            }
        }
    }

    private var completeStep: some View {
        SetupIntroductionView(
            icon: "checkmark.circle.fill",
            title: "InputPilot is ready",
            message: "The authenticated connection, mouse, and keyboard tests are complete. You can change transport preferences or add Wi-Fi later in Settings.",
            points: [
                ("computermouse", "Use Control for the trackpad and keyboard."),
                ("square.grid.2x2", "Build reusable Presets and Macros for common actions."),
                ("exclamationmark.octagon", "Release All is always available if an input appears stuck.")
            ],
            actionTitle: "Start Using InputPilot"
        ) {
            onFinished?(true)
            dismiss()
        }
    }

    private var savedDevice: StoredDevice? {
        guard let id = viewModel.savedDeviceId else { return nil }
        return storedDevices.first { $0.deviceId.lowercased() == id.lowercased() }
    }

    private func saveDevice() async {
        do {
            try await viewModel.saveDevice(context: modelContext)
            guard viewModel.errorMessage == nil, viewModel.savedDeviceId != nil else { return }
            if flow == .addDevice { dismiss() }
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }

    private func cancel() {
        viewModel.cancelWizard()
        onFinished?(false)
        dismiss()
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }
}

private struct SetupIntroductionView: View {
    let icon: String
    let title: String
    let message: String
    let points: [(String, String)]
    let actionTitle: String
    let externalLinkTitle: String?
    let externalLinkMessage: String?
    let externalLinkURL: URL?
    let action: () -> Void

    init(
        icon: String,
        title: String,
        message: String,
        points: [(String, String)],
        actionTitle: String,
        externalLinkTitle: String? = nil,
        externalLinkMessage: String? = nil,
        externalLinkURL: URL? = nil,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.points = points
        self.actionTitle = actionTitle
        self.externalLinkTitle = externalLinkTitle
        self.externalLinkMessage = externalLinkMessage
        self.externalLinkURL = externalLinkURL
        self.action = action
    }

    var body: some View {
        ScrollView {
            VStack(spacing: AppTheme.Spacing.section) {
                Image(systemName: icon)
                    .font(.system(size: 58, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(spacing: AppTheme.Spacing.standard) {
                    Text(title)
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text(message)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                VStack(alignment: .leading, spacing: AppTheme.Spacing.spacious) {
                    ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                        Label {
                            Text(point.1)
                        } icon: {
                            Image(systemName: point.0)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .frame(maxWidth: 520, alignment: .leading)
                if let externalLinkTitle,
                   let externalLinkMessage,
                   let externalLinkURL {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.standard) {
                        Label(externalLinkTitle, systemImage: "externaldrive.badge.questionmark")
                            .font(.headline)
                        Text(externalLinkMessage)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
                            Link(destination: externalLinkURL) {
                                Label("Open Web Flasher", systemImage: "safari")
                            }
                            .buttonStyle(.bordered)
                            ShareLink(item: externalLinkURL) {
                                Label("Send Link", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(AppTheme.Spacing.spacious)
                    .frame(maxWidth: 520, alignment: .leading)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: AppTheme.Radius.card))
                }
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(minHeight: AppTheme.minimumInteractionSize)
            }
            .padding(AppTheme.Spacing.section)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct BluetoothDiscoveryStepView: View {
    let expectedDeviceId: String?
    let onMetadata: (BLEDeviceMetadata) -> Void
    let onError: (String) -> Void

    @StateObject private var bluetooth = BLEDeviceDiscoveryManager()
    @State private var connectingDeviceId: String?
    @State private var scanAttempt = 0
    @State private var scanTakingLong = false

    var body: some View {
        ContentUnavailableView {
            Label(connectingDeviceId == nil ? "Scanning…" : "Connecting…",
                  systemImage: "antenna.radiowaves.left.and.right")
        } description: {
            Text("Bluetooth access is requested now to find only the InputPilot identified by USB trust. Keep the device nearby and powered on.")
        } actions: {
            if let error = bluetooth.errorMessage {
                Text(error).foregroundStyle(AppColors.error)
                Button("Open InputPilot Settings", action: openAppSettings)
            } else if scanTakingLong {
                Text("InputPilot has not appeared yet. Check power and distance, then scan again.")
                    .foregroundStyle(.secondary)
                Button("Scan Again", action: restartScan)
            } else {
                ProgressView()
            }
        }
        .onAppear {
            restartScan()
            connectToExpectedDevice(in: bluetooth.devices)
        }
        .onChange(of: bluetooth.devices) { _, devices in
            connectToExpectedDevice(in: devices)
        }
        .onDisappear { bluetooth.stop() }
        .task(id: scanAttempt) {
            try? await Task.sleep(for: .seconds(12))
            if !Task.isCancelled, connectingDeviceId == nil, bluetooth.errorMessage == nil {
                scanTakingLong = true
            }
        }
    }

    private func connectToExpectedDevice(in devices: [BLEDiscoveredDevice]) {
        guard connectingDeviceId == nil,
              let expectedDeviceId,
              let device = devices.first(where: {
                  $0.deviceId.lowercased() == expectedDeviceId.lowercased()
              }) else { return }
        connectingDeviceId = device.deviceId
        Task {
            do {
                let metadata = try await bluetooth.metadata(for: device)
                connectingDeviceId = nil
                onMetadata(metadata)
            } catch {
                connectingDeviceId = nil
                onError(error.localizedDescription)
                bluetooth.start()
            }
        }
    }

    private func restartScan() {
        connectingDeviceId = nil
        scanTakingLong = false
        scanAttempt += 1
        bluetooth.start()
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private enum SetupValidationKind: Equatable {
    case connection
    case mouse
    case keyboard
}

private struct SetupValidationView: View {
    private enum State: Equatable {
        case idle
        case running
        case awaitingConfirmation
        case succeeded
        case failed(String)
    }

    let device: StoredDevice
    let kind: SetupValidationKind
    let onSuccess: () -> Void

    @StateObject private var manager: HIDConnectionManager
    @State private var state: State = .idle
    @AppStorage("keyboardLayout") private var layoutName = KeyboardLayout.german.rawValue

    init(device: StoredDevice, kind: SetupValidationKind, onSuccess: @escaping () -> Void) {
        self.device = device
        self.kind = kind
        self.onSuccess = onSuccess
        _manager = StateObject(wrappedValue: HIDConnectionManager(device: device))
    }

    var body: some View {
        Form {
            Section {
                Label(title, systemImage: icon)
                    .font(.title2.bold())
                Text(instructions)
                    .foregroundStyle(.secondary)
            }
            Section {
                switch state {
                case .idle:
                    Button(actionTitle) { Task { await run() } }
                        .buttonStyle(.borderedProminent)
                case .running:
                    ProgressView(progressTitle)
                case .awaitingConfirmation:
                    Label(sentMessage, systemImage: "checkmark.circle")
                        .foregroundStyle(AppColors.success)
                    Button(confirmationTitle) {
                        state = .succeeded
                        onSuccess()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Try Again") { Task { await run() } }
                case .succeeded:
                    Label("Test passed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(AppColors.success)
                case let .failed(message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppColors.error)
                    Button("Try Again") { Task { await run() } }
                }
            } footer: {
                Text("Only authenticated Bluetooth or Wi-Fi transports are eligible. A release-all command is sent after each input test.")
            }
        }
        .task {
            manager.startTransportStatusUpdates()
            if kind == .connection, state == .idle { await run() }
        }
        .onDisappear {
            manager.stopTransportStatusUpdates()
            Task { await manager.releaseAll() }
        }
    }

    private var title: String {
        switch kind {
        case .connection: "Check the secure connection"
        case .mouse: "Check pointer movement"
        case .keyboard: "Check keyboard output"
        }
    }

    private var icon: String {
        switch kind {
        case .connection: "lock.shield"
        case .mouse: "computermouse"
        case .keyboard: "keyboard"
        }
    }

    private var instructions: String {
        switch kind {
        case .connection:
            "Move InputPilot's USB connection to the computer you want to control, keep the board powered on, and leave Bluetooth enabled. Wi-Fi is not required."
        case .mouse:
            "Select Test Pointer. InputPilot will move the pointer in a small square without clicking anything."
        case .keyboard:
            "Focus a safe, empty text field on the controlled computer, then select Type Test Text. InputPilot will type “InputPilot test”."
        }
    }

    private var actionTitle: String {
        switch kind {
        case .connection: "Test Connection"
        case .mouse: "Test Pointer"
        case .keyboard: "Type Test Text"
        }
    }

    private var progressTitle: String {
        switch kind {
        case .connection: "Authenticating…"
        case .mouse: "Sending pointer test…"
        case .keyboard: "Sending keyboard test…"
        }
    }

    private var sentMessage: String {
        switch kind {
        case .connection: "Authenticated connection ready"
        case .mouse: "Pointer test sent"
        case .keyboard: "Keyboard test sent"
        }
    }

    private var confirmationTitle: String {
        switch kind {
        case .connection: "Continue"
        case .mouse: "The Pointer Moved"
        case .keyboard: "The Text Appeared"
        }
    }

    @MainActor
    private func run() async {
        guard state != .running else { return }
        state = .running
        await manager.connect()
        guard await manager.waitUntilReady(timeout: 12) else {
            state = .failed(manager.lastError ?? "No authenticated transport became ready. Check power, Bluetooth, and USB trust, then retry.")
            return
        }

        let succeeded: Bool
        switch kind {
        case .connection:
            succeeded = await manager.send(.ping)
        case .mouse:
            let moves: [HIDEvent] = [
                .mouseMove(36, 0), .mouseMove(0, 36),
                .mouseMove(-36, 0), .mouseMove(0, -36)
            ]
            succeeded = await sendAll(moves)
            await manager.releaseAllPreservingError()
        case .keyboard:
            let layout = KeyboardLayout(rawValue: layoutName) ?? .german
            succeeded = await manager.sendText("InputPilot test", layout: layout, delayMilliseconds: 12)
            await manager.releaseAllPreservingError()
        }

        guard succeeded else {
            state = .failed(manager.lastError ?? "The test command could not be delivered. Reconnect and retry.")
            return
        }
        if kind == .connection {
            state = .succeeded
            onSuccess()
        } else {
            state = .awaitingConfirmation
        }
    }

    @MainActor
    private func sendAll(_ events: [HIDEvent]) async -> Bool {
        for event in events where !Task.isCancelled {
            guard await manager.send(event) else { return false }
            try? await Task.sleep(for: .milliseconds(80))
        }
        return !Task.isCancelled
    }
}

#Preview {
    AddDeviceWizardView(flow: .firstRun)
        .modelContainer(for: StoredDevice.self, inMemory: true)
}
