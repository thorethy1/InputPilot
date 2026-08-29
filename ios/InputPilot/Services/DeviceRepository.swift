import Foundation
import SwiftData

enum DeviceRepositoryError: Error, LocalizedError {
    case deviceUnreachable
    case notFound
    case alreadyExists(displayName: String)
    case secureProtocolRequired

    var errorDescription: String? {
        switch self {
        case .deviceUnreachable:
            "Could not reach the device on the local network."
        case .notFound:
            "Device not found."
        case let .alreadyExists(displayName):
            SavedDeviceIndex.alreadyExistsMessage(displayName: displayName)
        case .secureProtocolRequired:
            "This device must be reflashed with Secure Protocol v2 firmware."
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
                staIP: device.staIP
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
                        if let status = try? await api.status(baseURL: url) {
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
            if let status,
               status.deviceId?.caseInsensitiveCompare(deviceId) == .orderedSame,
               status.protocolVersion == 2,
               status.capabilities.contains("secure_protocol_v2") {
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
        displayName: String
    ) async throws -> StoredDevice {
        guard let deviceId = status.deviceId?.lowercased(),
              deviceId.count == 12, deviceId.allSatisfy(\.isHexDigit),
              status.protocolVersion == 2,
              status.capabilities.contains("secure_protocol_v2") else {
            throw DeviceRepositoryError.secureProtocolRequired
        }
        if let existing = try fetchStored(deviceId: deviceId) {
            DeviceMerge.wifi(status, fallbackHost: fallbackHost, into: existing)
            try context.save()
            return existing
        }
        var device = Device(status: status, deviceId: deviceId, endpointHost: fallbackHost)
        device.displayName = displayName
        try DeviceStore.upsert(device, in: context)
        guard let stored = try fetchStored(deviceId: deviceId) else {
            throw DeviceRepositoryError.notFound
        }
        return stored
    }

    func addOrMergeBluetooth(metadata: BLEDeviceMetadata, displayName: String) throws -> StoredDevice {
        guard metadata.deviceId.count == 12,
              metadata.deviceId.allSatisfy(\.isHexDigit),
              metadata.protocolVersion == 2,
              metadata.capabilities.contains("secure_protocol_v2") else {
            throw DeviceRepositoryError.secureProtocolRequired
        }
        if let existing = try fetchStored(deviceId: metadata.deviceId) {
            DeviceMerge.bluetooth(metadata, into: existing)
            try context.save()
            return existing
        }
        let stored = StoredDevice(deviceId: metadata.deviceId, displayName: displayName, mdnsHost: "", staIP: nil,
            lastSeen: Date(), firmwareVersion: metadata.firmware,
            protocolVersion: metadata.protocolVersion, capabilities: metadata.capabilities,
            lastCapabilitiesUpdate: Date(), otaSchema: metadata.otaSchema, bluetoothDiscovered: true)
        context.insert(stored)
        try context.save()
        return stored
    }
    func setJiggle(_ device: StoredDevice, enabled: Bool) async throws {
        let settings = KeepAwakeSettings(moveEnabled: enabled, moveIntervalMs: device.moveIntervalMs,
            clickEnabled: device.clickEnabled, clickIntervalMs: device.clickIntervalMs)
        try await setKeepAwake(device, settings: settings)
    }

    func setKeepAwake(
        _ device: StoredDevice,
        settings: KeepAwakeSettings
    ) async throws {
        let bluetooth = InputPilotBluetoothManager.session(deviceId: device.deviceId)
        do { try await bluetooth.setKeepAwake(settings) }
        catch {
            let host = device.staIP ?? device.mdnsHost
            guard !host.isEmpty else { throw error }
            let wifi = InputPilotWiFiManager.session(host: host, deviceId: device.deviceId)
            try await wifi.setKeepAwake(settings)
        }
        apply(settings, to: device); try context.save()
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
        Task { await InputPilotWiFiManager.removeSessions(deviceId: device.deviceId) }
        context.delete(device)
        try context.save()
    }

    private func applyStatus(_ status: DeviceStatus, to stored: StoredDevice, fallbackHost: String) {
        DeviceMerge.wifi(status, fallbackHost: fallbackHost, into: stored)
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
