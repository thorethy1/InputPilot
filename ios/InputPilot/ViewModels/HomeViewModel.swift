import Foundation
import SwiftData

@MainActor
final class HomeViewModel: ObservableObject {
    static let presencePollNanoseconds: UInt64 = 15_000_000_000

    @Published private(set) var isRefreshing = false
    @Published private(set) var wifiStates: [String: WiFiReachabilityState] = [:]
    @Published var errorMessage: String?

    private let apiClient: any DeviceAPIClientProtocol
    private let bonjourBrowser: any BonjourBrowserProtocol
    private var refreshInFlight = false
    private var isBonjourMonitoring = false
    private var bonjourDevices: [String: StoredDevice] = [:]
    private var bonjourContext: ModelContext?
    private var bonjourValidationInFlight = Set<String>()

    init(
        apiClient: any DeviceAPIClientProtocol = DeviceAPIClient(),
        bonjourBrowser: any BonjourBrowserProtocol = BonjourBrowser()
    ) {
        self.apiClient = apiClient
        self.bonjourBrowser = bonjourBrowser
    }

    func wifiState(for deviceId: String) -> WiFiReachabilityState {
        wifiStates[deviceId] ?? .checking
    }

    /// Keeps Bonjour as an optional update source. Connections continue to use
    /// the last confirmed IP first, including when mDNS is unavailable over a
    /// VPN. A newly resolved address is cached only after the public status
    /// endpoint confirms the expected secure device identity.
    func monitorBonjour(devices: [StoredDevice], context: ModelContext) {
        bonjourDevices = Dictionary(uniqueKeysWithValues: devices.map { ($0.deviceId.lowercased(), $0) })
        bonjourContext = context
        guard !isBonjourMonitoring else { return }
        isBonjourMonitoring = true
        bonjourBrowser.onUpdate = { [weak self] services in
            Task { @MainActor in
                await self?.applyBonjourUpdates(services)
            }
        }
        bonjourBrowser.startBrowsing()
    }

    func stopBonjourMonitoring() {
        guard isBonjourMonitoring else { return }
        isBonjourMonitoring = false
        bonjourBrowser.stopBrowsing()
        bonjourBrowser.onUpdate = nil
        bonjourDevices = [:]
        bonjourContext = nil
    }

    private func applyBonjourUpdates(_ services: [DiscoveredService]) async {
        guard isBonjourMonitoring, let context = bonjourContext else { return }
        for service in BonjourDiscoveryFilter.deduplicate(services) {
            guard let rawDeviceId = service.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawDeviceId.isEmpty else { continue }
            let deviceId = rawDeviceId.lowercased()
            guard let device = bonjourDevices[deviceId],
                  let address = DeviceEndpointResolver.directIPv4Address(from: service.host),
                  DeviceEndpointResolver.sanitizeHost(device.staIP ?? "") != address,
                  let baseURL = DeviceEndpointResolver.baseURL(host: address, port: service.port),
                  bonjourValidationInFlight.insert(deviceId).inserted else { continue }

            defer { bonjourValidationInFlight.remove(deviceId) }
            guard let status = try? await apiClient.status(baseURL: baseURL),
                  isBonjourMonitoring,
                  status.deviceId?.caseInsensitiveCompare(deviceId) == .orderedSame,
                  status.protocolVersion == 2,
                  status.capabilities.contains("secure_protocol_v2"),
                  let currentDevice = bonjourDevices[deviceId] else { continue }

            DeviceMerge.wifi(status, fallbackHost: address, into: currentDevice)
            wifiStates[deviceId] = .reachable
            try? context.save()
        }
    }

    /// Pull-to-refresh: may drive `isRefreshing` for UI that observes it.
    func refreshAll(devices: [StoredDevice], context: ModelContext) async {
        await refreshAll(devices: devices, context: context, showIndicator: true)
    }

    /// Auto/resume poll: updates presence without toggling the refresh indicator.
    func refreshQuietly(devices: [StoredDevice], context: ModelContext) async {
        await refreshAll(devices: devices, context: context, showIndicator: false)
    }

    /// Probe a single device without disturbing the state of other saved devices.
    func refreshDevice(_ device: StoredDevice, context: ModelContext) async {
        wifiStates[device.deviceId] = .checking
        let repository = DeviceRepository(context: context)
        var failed = await repository.refreshAll(devices: [device], api: apiClient)
        if failed.contains(device.deviceId),
           await recoverEndpointFromReadyBluetooth(device, context: context),
           await repository.refresh(device: device, api: apiClient) {
            failed.remove(device.deviceId)
        }
        wifiStates[device.deviceId] = failed.contains(device.deviceId) ? .offline : .reachable
    }

    private func refreshAll(
        devices: [StoredDevice],
        context: ModelContext,
        showIndicator: Bool
    ) async {
        guard !devices.isEmpty else {
            wifiStates = [:]
            return
        }
        guard !refreshInFlight else { return }
        refreshInFlight = true
        if showIndicator { isRefreshing = true }
        errorMessage = nil
        defer {
            refreshInFlight = false
            if showIndicator { isRefreshing = false }
        }

        let repository = DeviceRepository(context: context)
        let deviceIds = Set(devices.map(\.deviceId))
        wifiStates = wifiStates.filter { deviceIds.contains($0.key) }
        for deviceId in deviceIds where wifiStates[deviceId] == nil {
            wifiStates[deviceId] = .checking
        }
        var failed = await repository.refreshAll(devices: devices, api: apiClient)
        for device in devices where failed.contains(device.deviceId) {
            if await recoverEndpointFromReadyBluetooth(device, context: context),
               await repository.refresh(device: device, api: apiClient) {
                failed.remove(device.deviceId)
            }
        }
        for deviceId in deviceIds {
            wifiStates[deviceId] = failed.contains(deviceId) ? .offline : .reachable
        }
    }

    /// BLE is an opportunistic discovery source, never a prerequisite: only an
    /// already-authenticated session is queried after all saved IP/mDNS probes
    /// failed.
    private func recoverEndpointFromReadyBluetooth(
        _ device: StoredDevice,
        context: ModelContext
    ) async -> Bool {
        let bluetooth = InputPilotBluetoothManager.session(deviceId: device.deviceId)
        guard bluetooth.state == .ready,
              let reply = try? await bluetooth.request("WIFI STATUS", timeout: 2),
              let status = try? JSONDecoder().decode(SecureWiFiStatus.self, from: Data(reply.utf8)),
              let handoff = status.handoffState(expectedDeviceId: device.deviceId)
        else { return false }
        guard case let .station(host) = handoff else { return false }
        device.promoteWiFiHost(host)
        try? context.save()
        await InputPilotWiFiManager.removeSessions(deviceId: device.deviceId)
        return true
    }

    func setJiggle(device: StoredDevice, enabled: Bool, context: ModelContext) async {
        let previous = device.jiggleEnabled
        device.jiggleEnabled = enabled

        let repository = DeviceRepository(context: context)
        do {
            try await repository.setJiggle(device, enabled: enabled)
            wifiStates[device.deviceId] = .reachable
        } catch {
            device.jiggleEnabled = previous
            wifiStates[device.deviceId] = .offline
            errorMessage = error.localizedDescription
        }
    }
}
