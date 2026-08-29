import Foundation
import SwiftData

@MainActor
final class HomeViewModel: ObservableObject {
    static let presencePollNanoseconds: UInt64 = 15_000_000_000

    @Published private(set) var isRefreshing = false
    @Published private(set) var wifiStates: [String: WiFiReachabilityState] = [:]
    @Published var errorMessage: String?

    private let apiClient: any DeviceAPIClientProtocol
    private var refreshInFlight = false

    init(apiClient: any DeviceAPIClientProtocol = DeviceAPIClient()) {
        self.apiClient = apiClient
    }

    func wifiState(for deviceId: String) -> WiFiReachabilityState {
        wifiStates[deviceId] ?? .checking
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
        let failed = await repository.refreshAll(devices: [device], api: apiClient)
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
        let failed = await repository.refreshAll(devices: devices, api: apiClient)
        for deviceId in deviceIds {
            wifiStates[deviceId] = failed.contains(deviceId) ? .offline : .reachable
        }
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
