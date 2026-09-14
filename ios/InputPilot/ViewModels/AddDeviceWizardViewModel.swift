import Foundation
import SwiftData

enum InputPilotLinks {
    static let webFlasher = URL(string: "https://thorethy1.github.io/InputPilot/en/")!
}

enum AddDeviceWizardStep: Equatable {
    case welcome
    case hardware
    case securePairing
    case bleScanning
    case confirmBLE(BLEDeviceMetadata)
    case connectionTest
    case mouseTest
    case keyboardTest
    case complete
}

enum DeviceSetupFlow: Equatable {
    case addDevice
    case firstRun
}

@MainActor
final class AddDeviceWizardViewModel: ObservableObject {
    private enum WiFiHandoff {
        case connected(String)
        case failed(String)
        case unavailable
    }

    let flow: DeviceSetupFlow
    @Published private(set) var step: AddDeviceWizardStep
    @Published private(set) var candidates: [DiscoveredService] = []
    @Published private(set) var isSaving = false
    @Published var errorMessage: String?
    @Published var displayName = ""
    @Published var homeWifiSSID = ""
    @Published var homeWifiPassword = ""
    @Published var configureWiFi = true
    @Published private(set) var mergeMessage: String?
    @Published private(set) var securelyPairedDeviceId: String?
    @Published private(set) var savedDeviceId: String?
    @Published private(set) var knownDevices = SavedDeviceIndex.empty

    private let browser: any BonjourBrowserProtocol
    private let apiClient: any DeviceAPIClientProtocol

    init(
        flow: DeviceSetupFlow = .addDevice,
        browser: any BonjourBrowserProtocol = BonjourBrowser(),
        apiClient: any DeviceAPIClientProtocol = DeviceAPIClient()
    ) {
        self.flow = flow
        step = flow == .firstRun ? .welcome : .securePairing
        self.browser = browser
        self.apiClient = apiClient
    }

    var bleMetadata: BLEDeviceMetadata? {
        if case let .confirmBLE(metadata) = step { metadata } else { nil }
    }

    var supportsWiFiSetup: Bool {
        guard let metadata = bleMetadata else { return false }
        return metadata.capabilities.contains("wifi_transport") &&
            metadata.capabilities.contains("secure_wifi_setup")
    }

    func updateKnownDevices(_ devices: [StoredDevice]) {
        knownDevices = SavedDeviceIndex(devices: devices)
        // A first-run device is persisted before the physical HID tests. If the
        // app is terminated there, resume at the non-destructive connection
        // check instead of asking for USB trust and credentials again.
        if flow == .firstRun, step == .welcome, let device = devices.first {
            savedDeviceId = device.deviceId
            step = .connectionTest
        }
    }

    func continueFromWelcome() {
        guard flow == .firstRun else { return }
        errorMessage = nil
        step = .hardware
    }

    func continueFromHardware() {
        guard flow == .firstRun else { return }
        errorMessage = nil
        step = .securePairing
    }

    func backToWelcome() {
        guard flow == .firstRun else { return }
        errorMessage = nil
        step = .welcome
    }

    func chooseSecureSetup() {
        browser.stopBrowsing()
        errorMessage = nil
        mergeMessage = nil
        securelyPairedDeviceId = nil
        step = .securePairing
    }

    func didPairSecurely(deviceId: String) { securelyPairedDeviceId = deviceId.lowercased() }

    func continueSecureSetup() {
        guard securelyPairedDeviceId != nil else {
            errorMessage = "Connect InputPilot by USB and capture its pairing code first."
            return
        }
        step = .bleScanning
    }

    func selectBluetooth(_ metadata: BLEDeviceMetadata) {
        guard let expected = securelyPairedDeviceId, metadata.deviceId.lowercased() == expected else {
            errorMessage = "This is not the InputPilot that was paired by USB."
            return
        }
        guard metadata.protocolVersion == 2,
              metadata.capabilities.contains("secure_protocol_v2"),
              metadata.capabilities.contains("ble_transport") else {
            errorMessage = "This firmware is incompatible. Reflash current InputPilot firmware over USB."
            return
        }
        configureWiFi = metadata.capabilities.contains("wifi_transport") &&
            metadata.capabilities.contains("secure_wifi_setup")
        if let existing = knownDevices.match(deviceId: metadata.deviceId) {
            displayName = existing.displayName
            mergeMessage = "The secure transports will be merged with this InputPilot."
        } else {
            displayName = metadata.deviceName.isEmpty ? "InputPilot" : metadata.deviceName
            mergeMessage = nil
        }
        step = .confirmBLE(metadata)
    }

    func backToPairing() {
        browser.stopBrowsing()
        candidates = []
        errorMessage = nil
        mergeMessage = nil
        securelyPairedDeviceId = nil
        step = .securePairing
    }

    func backFromPairing() {
        if flow == .firstRun {
            errorMessage = nil
            step = .hardware
        }
    }

    func backFromConfirm() {
        browser.stopBrowsing()
        candidates = []
        errorMessage = nil
        mergeMessage = nil
        step = .bleScanning
    }

    func cancelWizard() {
        browser.stopBrowsing()
        candidates = []
        errorMessage = nil
        displayName = ""
        homeWifiSSID = ""
        homeWifiPassword = ""
        configureWiFi = true
        mergeMessage = nil
        securelyPairedDeviceId = nil
        savedDeviceId = nil
        step = flow == .firstRun ? .welcome : .securePairing
    }
    func connectionTestPassed() {
        guard flow == .firstRun, savedDeviceId != nil else { return }
        errorMessage = nil
        step = .mouseTest
    }

    func mouseTestPassed() {
        guard flow == .firstRun, savedDeviceId != nil else { return }
        errorMessage = nil
        step = .keyboardTest
    }

    func keyboardTestPassed() {
        guard flow == .firstRun, savedDeviceId != nil else { return }
        errorMessage = nil
        step = .complete
    }

    func backToConnectionTest() {
        guard flow == .firstRun, savedDeviceId != nil else { return }
        errorMessage = nil
        step = .connectionTest
    }

    func backToMouseTest() {
        guard flow == .firstRun, savedDeviceId != nil else { return }
        errorMessage = nil
        step = .mouseTest
    }

    func saveDevice(context: ModelContext) async throws {
        guard case let .confirmBLE(metadata) = step else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let ssid = homeWifiSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { errorMessage = "Display name is required."; return }
        guard !configureWiFi || !ssid.isEmpty else { errorMessage = "Home Wi-Fi network name is required."; return }
        guard PairingKeyStore.load(deviceId: metadata.deviceId) != nil else {
            errorMessage = "Secure setup requires a valid USB pairing code."
            return
        }

        let repository = DeviceRepository(context: context)
        if !configureWiFi {
            _ = try repository.addOrMergeBluetooth(metadata: metadata, displayName: trimmedName)
            browser.stopBrowsing()
            didSaveDevice(metadata.deviceId)
            return
        }

        let bluetooth = InputPilotBluetoothManager.session(deviceId: metadata.deviceId)
        try await bluetooth.setWiFi(ssid: ssid, password: homeWifiPassword)
        startBrowsing()

        // The authenticated BLE session provides a direct, identity-bound
        // handoff to the station IP. Bonjour remains active as a fallback, but
        // setup no longer depends on the router forwarding multicast DNS.
        let handoff = await waitForSecureWiFiAddress(
            bluetooth: bluetooth,
            expectedDeviceId: metadata.deviceId,
            timeout: 20
        )
        let directHost: String?
        switch handoff {
        case let .connected(host): directHost = host
        case let .failed(message):
            errorMessage = message
            return
        case .unavailable: directHost = nil
        }
        // The firmware intentionally owns one secure TCP session. Remove stale
        // managers from an earlier setup/control attempt before verification.
        await InputPilotWiFiManager.removeSessions(deviceId: metadata.deviceId)

        let deadline = Date().addingTimeInterval(45)
        var verified: (DeviceStatus, DiscoveredService)?
        var sawMatchingDiscovery = false
        var sawValidDiscoveryMetadata = false
        var lastVerificationFailure: String?
        var loggedFailures = Set<String>()
        while Date() < deadline, verified == nil {
            var verificationCandidates: [DiscoveredService] = []
            if let directHost {
                verificationCandidates.append(DiscoveredService(
                    id: "secure-ble-handoff-\(metadata.deviceId)",
                    deviceId: metadata.deviceId,
                    name: metadata.deviceName,
                    host: directHost,
                    port: 80
                ))
            }
            verificationCandidates.append(contentsOf: candidates)
            verificationCandidates.append(DiscoveredService(
                id: "soft-ap-fallback-\(metadata.deviceId)",
                deviceId: metadata.deviceId,
                name: metadata.deviceName,
                host: DeviceEndpointResolver.softAPHost,
                port: 80
            ))
            var attemptedEndpoints = Set<String>()
            for candidate in verificationCandidates where
                candidate.deviceId?.lowercased() == metadata.deviceId.lowercased() {
                let endpointKey = "\(DeviceEndpointResolver.sanitizeHost(candidate.host).lowercased()):\(candidate.port)"
                guard attemptedEndpoints.insert(endpointKey).inserted else { continue }
                sawMatchingDiscovery = true
                guard let baseURL = DeviceEndpointResolver.baseURL(host: candidate.host, port: candidate.port) else {
                    lastVerificationFailure = "The discovered network address was invalid."
                    continue
                }
                let status: DeviceStatus
                do {
                    status = try await apiClient.status(baseURL: baseURL)
                } catch {
                    lastVerificationFailure = "Discovery metadata could not be read: \(error.localizedDescription)"
                    if loggedFailures.insert(lastVerificationFailure!).inserted {
                        AppLog.shared.write(.errors, "Setup Wi-Fi verification: \(lastVerificationFailure!) host=\(candidate.host)")
                    }
                    continue
                }
                guard status.deviceId?.lowercased() == metadata.deviceId.lowercased(),
                      status.protocolVersion == 2,
                      status.capabilities.contains("secure_protocol_v2") else {
                    lastVerificationFailure = "The rediscovered endpoint did not present the paired secure identity."
                    continue
                }
                sawValidDiscoveryMetadata = true
                let tcp = InputPilotWiFiManager.session(host: candidate.host, deviceId: metadata.deviceId)
                do {
                    try await tcp.waitUntilReady(timeout: 5)
                    verified = (status, candidate)
                } catch {
                    lastVerificationFailure = "Secure Wi-Fi authentication failed: \(error.localizedDescription)"
                    if loggedFailures.insert(lastVerificationFailure!).inserted {
                        AppLog.shared.write(.errors, "Setup Wi-Fi verification: \(lastVerificationFailure!) host=\(candidate.host)")
                    }
                }
            }
            if verified == nil { try? await Task.sleep(for: .milliseconds(500)) }
        }

        guard let (status, candidate) = verified else {
            if !sawMatchingDiscovery {
                errorMessage = "Wi-Fi was saved, but this InputPilot did not reappear on the home network. Check the network credentials and mDNS/local-network access, then retry."
            } else if !sawValidDiscoveryMetadata {
                errorMessage = "InputPilot reappeared on Wi-Fi, but its secure identity metadata could not be verified. Open Diagnostics for the recorded cause."
            } else {
                errorMessage = "InputPilot reappeared on Wi-Fi, but Secure Protocol authentication failed. Reconnect USB trust and retry. Details were saved in Diagnostics."
            }
            if let lastVerificationFailure {
                AppLog.shared.write(.errors, "Setup Wi-Fi verification exhausted: \(lastVerificationFailure)")
            }
            return
        }
        _ = try repository.addOrMergeBluetooth(metadata: metadata, displayName: trimmedName)
        _ = try await repository.addFromDiscovery(status: status, fallbackHost: candidate.host, displayName: trimmedName)
        browser.stopBrowsing()
        didSaveDevice(metadata.deviceId)
    }

    private func didSaveDevice(_ deviceId: String) {
        homeWifiPassword = ""
        savedDeviceId = deviceId.lowercased()
        if flow == .firstRun { step = .connectionTest }
    }

    private func waitForSecureWiFiAddress(
        bluetooth: BLEHIDControlTransport,
        expectedDeviceId: String,
        timeout: TimeInterval
    ) async -> WiFiHandoff {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            do {
                let reply = try await bluetooth.request("WIFI STATUS", timeout: 2)
                let status = try JSONDecoder().decode(SecureWiFiStatus.self, from: Data(reply.utf8))
                guard let handoffState = status.handoffState(expectedDeviceId: expectedDeviceId) else {
                    AppLog.shared.write(.errors, "BLE Wi-Fi handoff returned a different device identity")
                    return .failed("InputPilot returned a different secure device identity.")
                }
                switch handoffState {
                case let .station(host):
                    AppLog.shared.write(.control, "BLE Wi-Fi handoff connected host=\(host)")
                    return .connected(host)
                case let .failed(error):
                    AppLog.shared.write(.errors, "BLE Wi-Fi provisioning failed code=\(error)")
                    return .failed("InputPilot saved the network, but could not connect to it. Check the Wi-Fi name, password, and signal, then retry.")
                case .softAP:
                    AppLog.shared.write(.control, "BLE Wi-Fi handoff is using authenticated Soft-AP fallback host=\(DeviceEndpointResolver.softAPHost)")
                    return .connected(DeviceEndpointResolver.softAPHost)
                case .connecting:
                    break
                }
            } catch {
                AppLog.shared.write(.errors, "BLE Wi-Fi handoff status failed: \(error.localizedDescription)")
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return .unavailable
    }

    private func startBrowsing() {
        browser.onUpdate = { [weak self] services in Task { @MainActor in self?.candidates = services } }
        browser.startBrowsing()
    }
}
