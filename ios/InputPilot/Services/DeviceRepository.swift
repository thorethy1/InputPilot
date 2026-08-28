import Foundation
import SwiftData

enum DeviceRepositoryError: Error, LocalizedError {
    case deviceUnreachable
    case notFound
    case alreadyExists(displayName: String)

    var errorDescription: String? {
        switch self {
        case .deviceUnreachable:
            "Could not reach the device on the local network."
        case .notFound:
            "Device not found."
        case let .alreadyExists(displayName):
            SavedDeviceIndex.alreadyExistsMessage(displayName: displayName)
        }
    }
}

@MainActor
final class DeviceRepository {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func refreshAll(devices: [StoredDevice], api: any DeviceAPIClientProtocol) async -> Set<String> {
        let snapshots = devices.map { device in
            (
                deviceId: device.deviceId,
                mdnsHost: device.mdnsHost,
                staIP: device.staIP,
                token: device.apiToken
            )
        }

        let results = await withTaskGroup(of: (String, DeviceStatus?, String).self) { group in
            for snapshot in snapshots {
                group.addTask {
                    let urls = DeviceEndpointResolver.endpointURLs(
                        mdnsHost: snapshot.mdnsHost,
                        staIP: snapshot.staIP
                    )
                    for url in urls {
                        if let status = try? await api.status(baseURL: url, token: snapshot.token) {
                            return (snapshot.deviceId, status, url.host ?? snapshot.mdnsHost)
                        }
                    }
                    return (snapshot.deviceId, nil, snapshot.mdnsHost)
                }
            }

            var collected: [(String, DeviceStatus?, String)] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        var failed = Set<String>()
        for (deviceId, status, fallbackHost) in results {
            guard let device = devices.first(where: { $0.deviceId == deviceId }) else { continue }
            if let status {
                applyStatus(status, to: device, fallbackHost: fallbackHost)
            } else {
                failed.insert(deviceId)
            }
        }

        try? context.save()
        return failed
    }

    @discardableResult
    func refresh(device: StoredDevice, api: any DeviceAPIClientProtocol) async -> Bool {
        await refreshAll(devices: [device], api: api).isEmpty
    }

    func addFromDiscovery(
        status: DeviceStatus,
        fallbackHost: String,
        displayName: String,
        token: String?,
        api: any DeviceAPIClientProtocol
    ) async throws -> StoredDevice {
        let deviceId = status.deviceId ?? fallbackHost
        if let existing = try fetchStored(deviceId: deviceId) {
            DeviceMerge.wifi(status, fallbackHost: fallbackHost, token: token, into: existing)
            try context.save()
            return existing
        }
        var device = Device(status: status, fallbackHost: fallbackHost)
        device.displayName = displayName
        device.apiToken = token

        try DeviceStore.upsert(device, in: context)
        guard let stored = try fetchStored(deviceId: deviceId) else {
            throw DeviceRepositoryError.notFound
        }
        return stored
    }

    func addOrMergeBluetooth(metadata: BLEDeviceMetadata, displayName: String, token: String?) throws -> StoredDevice {
        if let existing = try fetchStored(deviceId: metadata.deviceId) {
            DeviceMerge.bluetooth(metadata, token: token, into: existing)
            try context.save()
            return existing
        }
        let stored = StoredDevice(deviceId: metadata.deviceId, displayName: displayName, mdnsHost: "", staIP: nil,
            apiToken: token, lastSeen: Date(), firmwareVersion: metadata.firmware,
            protocolVersion: metadata.protocolVersion, capabilities: metadata.capabilities,
            lastCapabilitiesUpdate: Date(), otaSchema: metadata.otaSchema, bluetoothDiscovered: true)
        context.insert(stored)
        try context.save()
        return stored
    }
    /// Probes a host without saving. A matching device ID is returned so the
    /// caller can enrich the existing physical device with this Wi-Fi endpoint.
    func probeByAddress(
        host: String,
        token: String?,
        api: any DeviceAPIClientProtocol
    ) async throws -> ProbedDevice {
        let urls = DeviceEndpointResolver.endpointURLs(mdnsHost: host, staIP: nil)
        guard !urls.isEmpty else { throw DeviceRepositoryError.deviceUnreachable }

        var lastError: Error = DeviceRepositoryError.deviceUnreachable

        for url in urls {
            do {
                let status = try await api.status(baseURL: url, token: token)
                let fallbackHost = url.host ?? host
                let candidate = DiscoveredService(
                    id: "manual-\(fallbackHost)",
                    deviceId: status.deviceId,
                    name: status.name,
                    host: fallbackHost,
                    port: url.port ?? 80
                )
                return ProbedDevice(candidate: candidate, status: status, baseURL: url)
            } catch let error as DeviceRepositoryError {
                throw error
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    func setJiggle(_ device: StoredDevice, enabled: Bool, api: any DeviceAPIClientProtocol) async throws {
        let urls = DeviceEndpointResolver.endpointURLs(mdnsHost: device.mdnsHost, staIP: device.staIP)
        guard !urls.isEmpty else { throw DeviceRepositoryError.deviceUnreachable }

        var lastError: Error = DeviceRepositoryError.deviceUnreachable
        for url in urls {
            do {
                try await api.setJiggle(baseURL: url, enabled: enabled, token: device.apiToken)
                device.jiggleEnabled = enabled
                try context.save()
                return
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    func setKeepAwake(
        _ device: StoredDevice,
        settings: KeepAwakeSettings,
        api: any DeviceAPIClientProtocol
    ) async throws {
        let urls = DeviceEndpointResolver.endpointURLs(mdnsHost: device.mdnsHost, staIP: device.staIP)
        guard !urls.isEmpty else { throw DeviceRepositoryError.deviceUnreachable }
        var lastError: Error = DeviceRepositoryError.deviceUnreachable
        for url in urls {
            do {
                try await api.setKeepAwake(baseURL: url, settings: settings, token: device.apiToken)
                apply(settings, to: device)
                try context.save()
                return
            } catch { lastError = error }
        }
        throw lastError
    }

    func apply(_ settings: KeepAwakeSettings, to device: StoredDevice) {
        device.jiggleEnabled = settings.moveEnabled
        device.moveIntervalMs = settings.moveIntervalMs
        device.clickEnabled = settings.clickEnabled
        device.clickIntervalMs = settings.clickIntervalMs
    }

    func rename(_ device: StoredDevice, name: String) throws {
        device.displayName = name
        try context.save()
    }

    func delete(_ device: StoredDevice) throws {
        PairingKeyStore.remove(deviceId: device.deviceId)
        context.delete(device)
        try context.save()
    }

    func updateApiToken(_ device: StoredDevice, token: String?) throws {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        device.apiToken = trimmed?.isEmpty == true ? nil : trimmed
        try context.save()
    }

    private func applyStatus(_ status: DeviceStatus, to stored: StoredDevice, fallbackHost: String) {
        DeviceMerge.wifi(status, fallbackHost: fallbackHost, token: nil, into: stored)
    }

    private func fetchAll() throws -> [StoredDevice] {
        try context.fetch(FetchDescriptor<StoredDevice>())
    }

    private func fetchStored(deviceId: String) throws -> StoredDevice? {
        var descriptor = FetchDescriptor<StoredDevice>(
            predicate: #Predicate { $0.deviceId == deviceId }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
