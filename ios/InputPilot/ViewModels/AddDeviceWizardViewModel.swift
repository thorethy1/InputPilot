import Foundation
import SwiftData

enum AddDeviceWizardStep: Equatable {
    case choosePath
    case securePairing
    case bleScanning
    case confirmBLE(BLEDeviceMetadata)
}

@MainActor
final class AddDeviceWizardViewModel: ObservableObject {
    @Published private(set) var step: AddDeviceWizardStep = .choosePath
    @Published private(set) var candidates: [DiscoveredService] = []
    @Published private(set) var isSaving = false
    @Published var errorMessage: String?
    @Published var displayName = ""
    @Published var homeWifiSSID = ""
    @Published var homeWifiPassword = ""
    @Published private(set) var mergeMessage: String?
    @Published private(set) var securelyPairedDeviceId: String?
    @Published private(set) var knownDevices = SavedDeviceIndex.empty

    private let browser: any BonjourBrowserProtocol
    private let apiClient: any DeviceAPIClientProtocol

    init(browser: any BonjourBrowserProtocol = BonjourBrowser(), apiClient: any DeviceAPIClientProtocol = DeviceAPIClient()) {
        self.browser = browser
        self.apiClient = apiClient
    }

    var bleMetadata: BLEDeviceMetadata? {
        if case let .confirmBLE(metadata) = step { metadata } else { nil }
    }

    func updateKnownDevices(_ devices: [StoredDevice]) { knownDevices = SavedDeviceIndex(devices: devices) }

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
              metadata.capabilities.contains("secure_wifi_setup") else {
            errorMessage = "This firmware is incompatible. Reflash current InputPilot firmware over USB."
            return
        }
        if let existing = knownDevices.match(deviceId: metadata.deviceId) {
            displayName = existing.displayName
            mergeMessage = "The secure transports will be merged with this InputPilot."
        } else {
            displayName = metadata.deviceName.isEmpty ? "InputPilot" : metadata.deviceName
            mergeMessage = nil
        }
        step = .confirmBLE(metadata)
    }

    func backToChoosePath() {
        browser.stopBrowsing()
        candidates = []
        errorMessage = nil
        mergeMessage = nil
        securelyPairedDeviceId = nil
        step = .choosePath
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
        mergeMessage = nil
        securelyPairedDeviceId = nil
        step = .choosePath
    }

    func saveDevice(context: ModelContext) async throws {
        guard case let .confirmBLE(metadata) = step else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let ssid = homeWifiSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { errorMessage = "Display name is required."; return }
        guard !ssid.isEmpty else { errorMessage = "Home Wi-Fi network name is required."; return }
        guard PairingKeyStore.load(deviceId: metadata.deviceId) != nil else {
            errorMessage = "Secure setup requires a valid USB pairing code."
            return
        }

        let bluetooth = InputPilotBluetoothManager.session(deviceId: metadata.deviceId)
        try await bluetooth.setWiFi(ssid: ssid, password: homeWifiPassword)
        startBrowsing()

        let deadline = Date().addingTimeInterval(45)
        var verified: (DeviceStatus, DiscoveredService)?
        while Date() < deadline, verified == nil {
            for candidate in candidates where candidate.deviceId?.lowercased() == metadata.deviceId.lowercased() {
                guard let baseURL = DeviceEndpointResolver.baseURL(host: candidate.host, port: candidate.port),
                      let status = try? await apiClient.status(baseURL: baseURL),
                      status.deviceId?.lowercased() == metadata.deviceId.lowercased(),
                      status.protocolVersion == 2,
                      status.capabilities.contains("secure_protocol_v2") else { continue }
                let tcp = InputPilotWiFiManager.session(host: candidate.host, deviceId: metadata.deviceId)
                do {
                    try await tcp.waitUntilReady(timeout: 5)
                    verified = (status, candidate)
                } catch {}
            }
            if verified == nil { try? await Task.sleep(for: .milliseconds(500)) }
        }

        guard let (status, candidate) = verified else {
            errorMessage = "Wi-Fi was saved, but the same device could not be authenticated on the home network. Check the credentials and retry."
            return
        }
        let repository = DeviceRepository(context: context)
        _ = try repository.addOrMergeBluetooth(metadata: metadata, displayName: trimmedName)
        _ = try await repository.addFromDiscovery(status: status, fallbackHost: candidate.host, displayName: trimmedName)
        browser.stopBrowsing()
    }

    private func startBrowsing() {
        browser.onUpdate = { [weak self] services in Task { @MainActor in self?.candidates = services } }
        browser.startBrowsing()
    }
}
