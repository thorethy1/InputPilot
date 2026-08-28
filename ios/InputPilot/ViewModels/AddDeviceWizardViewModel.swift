import Foundation
import SwiftData

enum AddDeviceWizardStep: Equatable {
    case choosePath
    case scanning
    case bleScanning
    case confirm(ProbedDevice)
    case confirmBLE(BLEDeviceMetadata)
    case softAPInstructions
    case softAPJoin
    case softAPHomeWifi
    case softAPReconnect
    case softAPDiscover
}

struct ProbedDevice: Equatable {
    let candidate: DiscoveredService
    let status: DeviceStatus
    let baseURL: URL
}

@MainActor
final class AddDeviceWizardViewModel: ObservableObject {
    static let softAPBaseURL = URL(string: "http://192.168.4.1/")!
    static let softAPSSIDPrefix = "InputPilot-"

    @Published private(set) var step: AddDeviceWizardStep = .choosePath
    @Published private(set) var candidates: [DiscoveredService] = []
    @Published private(set) var isProbing = false
    @Published private(set) var isSaving = false
    @Published private(set) var isJoining = false
    @Published private(set) var isProvisioning = false
    @Published var errorMessage: String?
    @Published var displayName = ""
    @Published var apiToken = ""

    @Published var softAPSSID = softAPSSIDPrefix
    @Published var softAPPassword = ""
    @Published var homeWifiSSID = ""
    @Published var homeWifiPassword = ""
    @Published var softAPManualHost = ""
    @Published private(set) var expectedDeviceId: String?
    @Published private(set) var probedWifiStatus: WifiStatus?
    @Published private(set) var mergeMessage: String?

    /// Saved devices used to hide duplicates from scan results and reject re-adds.
    @Published private(set) var knownDevices = SavedDeviceIndex.empty

    private let browser: any BonjourBrowserProtocol
    private let apiClient: any DeviceAPIClientProtocol
    private let softAPJoiner: any SoftAPJoinerProtocol

    init(
        browser: any BonjourBrowserProtocol = BonjourBrowser(),
        apiClient: any DeviceAPIClientProtocol = DeviceAPIClient(),
        softAPJoiner: any SoftAPJoinerProtocol = SoftAPJoiner()
    ) {
        self.browser = browser
        self.apiClient = apiClient
        self.softAPJoiner = softAPJoiner
    }

    func updateKnownDevices(_ devices: [StoredDevice]) {
        knownDevices = SavedDeviceIndex(devices: devices)
    }

    var probedDevice: ProbedDevice? {
        if case let .confirm(device) = step {
            return device
        }
        return nil
    }

    var bleMetadata: BLEDeviceMetadata? { if case let .confirmBLE(metadata) = step { metadata } else { nil } }

    var showsAuthTokenField: Bool {
        let id = probedDevice?.status.deviceId ?? bleMetadata?.deviceId
        let paired = id.map { PairingKeyStore.load(deviceId: $0) != nil } ?? false
        return !paired && (probedDevice?.status.authRequired == true || bleMetadata?.authRequired == true)
    }

    /// Candidates for Soft-AP rediscovery (optionally filtered to expected device id).
    var filteredCandidates: [DiscoveredService] {
        let base: [DiscoveredService]
        if let expectedDeviceId {
            let matches = candidates.filter { $0.deviceId == expectedDeviceId }
            base = matches.isEmpty ? candidates : matches
        } else {
            base = candidates
        }
        return base.filter { candidate in
            guard let existing = knownDevices.match(candidate: candidate) else { return true }
            return existing.hosts.isEmpty
        }
    }

    /// Scan-network list excludes devices already saved.
    var newCandidates: [DiscoveredService] {
        candidates.filter { candidate in
            guard let existing = knownDevices.match(candidate: candidate) else { return true }
            return existing.hosts.isEmpty
        }
    }

    var hasHiddenKnownCandidates: Bool {
        !candidates.isEmpty && newCandidates.count < candidates.count
    }

    func chooseScan() {
        resetSoftAPState()
        mergeMessage = nil
        errorMessage = nil
        step = .scanning
        startBrowsing()
    }

    func chooseBluetooth() { browser.stopBrowsing(); resetSoftAPState(); mergeMessage = nil; errorMessage = nil; step = .bleScanning }

    func selectBluetooth(_ metadata: BLEDeviceMetadata) {
        if let existing = knownDevices.match(deviceId: metadata.deviceId) {
            if existing.hasBluetooth {
                errorMessage = "This device is already configured for Bluetooth."; return
            }
            displayName = existing.displayName
            mergeMessage = "Bluetooth will be added to this existing InputPilot."
        } else {
            displayName = metadata.deviceName.isEmpty ? "InputPilot" : metadata.deviceName
            mergeMessage = nil
        }
        apiToken = ""; step = .confirmBLE(metadata)
    }

    func chooseSoftAP() {
        browser.stopBrowsing()
        resetSoftAPState()
        errorMessage = nil
        step = .softAPInstructions
    }

    func continueFromSoftAPInstructions() {
        errorMessage = nil
        step = .softAPJoin
    }

    func joinSoftAP() async {
        isJoining = true
        errorMessage = nil
        defer { isJoining = false }

        let trimmedSSID = softAPSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSSID.isEmpty else {
            errorMessage = SoftAPJoinError.invalidSSID.localizedDescription
            return
        }

        let password = softAPPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await softAPJoiner.join(
                ssid: trimmedSSID,
                password: password.isEmpty ? nil : password
            )
            await probeDeviceOnSoftAP()
        } catch let error as SoftAPJoinError where error == .notSupported {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func continueWithoutJoiningSoftAP() async {
        await probeDeviceOnSoftAP()
    }

    func probeDeviceOnSoftAP() async {
        isProbing = true
        errorMessage = nil
        defer { isProbing = false }

        do {
            let wifi = try await apiClient.getWifi(baseURL: Self.softAPBaseURL, token: nil)
            probedWifiStatus = wifi
            expectedDeviceId = wifi.deviceId
            if let apSSID = wifi.apSsid, !apSSID.isEmpty, softAPSSID == Self.softAPSSIDPrefix {
                softAPSSID = apSSID
            }
            step = .softAPHomeWifi
        } catch {
            errorMessage = "Could not reach the device at 192.168.4.1. Join the setup Wi‑Fi network and try again."
        }
    }

    func provisionHomeWifi() async {
        let trimmedSSID = homeWifiSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSSID.isEmpty else {
            errorMessage = "Home Wi‑Fi network name is required."
            return
        }

        isProvisioning = true
        errorMessage = nil
        defer { isProvisioning = false }

        do {
            try await apiClient.provisionWifi(
                baseURL: Self.softAPBaseURL,
                ssid: trimmedSSID,
                password: homeWifiPassword,
                token: nil
            )
            step = .softAPReconnect
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func continueAfterHomeWifiReconnect() {
        errorMessage = nil
        step = .softAPDiscover
        startBrowsing()
    }

    func probeManualAddress() async {
        let trimmedHost = softAPManualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            errorMessage = "Enter a host or IP address."
            return
        }

        let candidate = DiscoveredService(
            id: "manual-\(trimmedHost)",
            deviceId: expectedDeviceId,
            name: trimmedHost,
            host: trimmedHost,
            port: 80
        )
        await selectCandidate(candidate)
    }

    func backToChoosePath() {
        browser.stopBrowsing()
        step = .choosePath
        candidates = []
        errorMessage = nil
        resetSoftAPState()
    }

    func backFromConfirm() {
        errorMessage = nil
        mergeMessage = nil
        if case .confirmBLE = step { step = .bleScanning; return }
        if expectedDeviceId != nil {
            step = .softAPDiscover
            startBrowsing()
        } else {
            step = .scanning
            startBrowsing()
        }
    }

    func backFromSoftAPJoin() {
        errorMessage = nil
        step = .softAPInstructions
    }

    func backFromSoftAPHomeWifi() {
        errorMessage = nil
        step = .softAPJoin
    }

    func backFromSoftAPReconnect() {
        errorMessage = nil
        step = .softAPHomeWifi
    }

    func backFromSoftAPDiscover() {
        browser.stopBrowsing()
        errorMessage = nil
        step = .softAPReconnect
        candidates = []
    }

    func cancelWizard() {
        browser.stopBrowsing()
        step = .choosePath
        candidates = []
        errorMessage = nil
        displayName = ""
        apiToken = ""
        mergeMessage = nil
        resetSoftAPState()
    }

    func selectCandidate(_ candidate: DiscoveredService) async {
        isProbing = true
        errorMessage = nil
        defer { isProbing = false }

        if let existing = knownDevices.match(candidate: candidate), !existing.hosts.isEmpty {
            errorMessage = SavedDeviceIndex.alreadyExistsMessage(displayName: existing.displayName)
            return
        }

        guard let baseURL = Self.baseURL(for: candidate) else {
            errorMessage = "Could not build a URL for this device."
            return
        }

        do {
            let status = try await apiClient.status(baseURL: baseURL, token: nil)
            if let expectedDeviceId, let deviceId = status.deviceId, deviceId != expectedDeviceId {
                errorMessage = "This device does not match the one you provisioned."
                return
            }
            if let existing = knownDevices.match(status: status, host: candidate.host) {
                displayName = existing.displayName
                mergeMessage = "Wi-Fi will be added to this existing InputPilot."
            } else {
                displayName = Self.defaultDisplayName(for: status)
                mergeMessage = nil
            }
            apiToken = ""
            step = .confirm(ProbedDevice(candidate: candidate, status: status, baseURL: baseURL))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveDevice(context: ModelContext) async throws {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Display name is required."
            return
        }

        let trimmedToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = trimmedToken.isEmpty ? nil : trimmedToken

        let requiresAuth = probedDevice?.status.authRequired == true || bleMetadata?.authRequired == true
        let deviceId = probedDevice?.status.deviceId ?? bleMetadata?.deviceId
        let hasPairingKey = deviceId.map { PairingKeyStore.load(deviceId: $0) != nil } ?? false
        if requiresAuth && token == nil && !hasPairingKey {
            errorMessage = "This device requires an API token."
            return
        }

        if case let .confirm(probed) = step {
            let repository = DeviceRepository(context: context)
            _ = try await repository.addFromDiscovery(status: probed.status, fallbackHost: probed.candidate.host, displayName: trimmedName, token: token, api: apiClient)
        } else if case let .confirmBLE(metadata) = step {
            let repository = DeviceRepository(context: context)
            _ = try repository.addOrMergeBluetooth(metadata: metadata, displayName: trimmedName, token: token)
        } else { return }

        browser.stopBrowsing()
    }

    static func baseURL(for candidate: DiscoveredService) -> URL? {
        DeviceEndpointResolver.baseURL(host: candidate.host, port: candidate.port)
    }

    static func defaultDisplayName(for status: DeviceStatus) -> String {
        if let deviceId = status.deviceId, deviceId.count >= 4 {
            return String(deviceId.suffix(4))
        }
        if !status.name.isEmpty {
            return status.name
        }
        return "InputPilot"
    }

    private func startBrowsing() {
        browser.onUpdate = { [weak self] services in
            Task { @MainActor in
                self?.candidates = services
            }
        }
        browser.startBrowsing()
    }

    private func resetSoftAPState() {
        softAPSSID = Self.softAPSSIDPrefix
        softAPPassword = ""
        homeWifiSSID = ""
        homeWifiPassword = ""
        softAPManualHost = ""
        expectedDeviceId = nil
        probedWifiStatus = nil
    }
}
