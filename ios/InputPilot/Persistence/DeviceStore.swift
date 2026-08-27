import Foundation
import SwiftData

@Model
final class StoredDevice {
    @Attribute(.unique) var deviceId: String
    var displayName: String
    var mdnsHost: String
    var staIP: String?
    var apiToken: String?
    var jiggleEnabled: Bool
    var lastSeen: Date?
    var firmwareVersion: String?
    var protocolVersion: Int = 0
    var capabilities: [String] = []
    var otaSchema: Int = 0
    var runningPartition: String?
    var bootPartition: String?
    var bluetoothDiscovered: Bool = false
    var lastCapabilitiesUpdate: Date?

    init(
        deviceId: String,
        displayName: String,
        mdnsHost: String,
        staIP: String? = nil,
        apiToken: String? = nil,
        jiggleEnabled: Bool = false,
        lastSeen: Date? = nil,
        firmwareVersion: String? = nil,
        protocolVersion: Int = 0,
        capabilities: [String] = [],
        lastCapabilitiesUpdate: Date? = nil,
        otaSchema: Int = 0,
        bluetoothDiscovered: Bool = false
    ) {
        self.deviceId = deviceId
        self.displayName = displayName
        self.mdnsHost = mdnsHost
        self.staIP = staIP
        self.apiToken = apiToken
        self.jiggleEnabled = jiggleEnabled
        self.lastSeen = lastSeen
        self.firmwareVersion = firmwareVersion
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.lastCapabilitiesUpdate = lastCapabilitiesUpdate
        self.otaSchema = otaSchema
        self.runningPartition = nil
        self.bootPartition = nil
        self.bluetoothDiscovered = bluetoothDiscovered
    }

    convenience init(device: Device) {
        self.init(
            deviceId: device.id,
            displayName: device.displayName,
            mdnsHost: device.mdnsHost,
            staIP: device.staIP,
            apiToken: device.apiToken,
            jiggleEnabled: device.jiggleEnabled,
            lastSeen: device.lastSeen,
            firmwareVersion: device.firmwareVersion,
            protocolVersion: device.protocolVersion,
            capabilities: device.capabilities,
            lastCapabilitiesUpdate: device.capabilities.isEmpty ? nil : Date(),
            otaSchema: device.otaSchema
        )
    }

    func asDevice() -> Device {
        Device(
            id: deviceId,
            displayName: displayName,
            mdnsHost: mdnsHost,
            staIP: staIP,
            apiToken: apiToken,
            jiggleEnabled: jiggleEnabled,
            lastSeen: lastSeen,
            firmwareVersion: firmwareVersion,
            protocolVersion: protocolVersion,
            capabilities: capabilities,
            otaSchema: otaSchema
        )
    }
}

enum DeviceStore {
    static func upsert(_ device: Device, in context: ModelContext) throws {
        let deviceId = device.id
        var descriptor = FetchDescriptor<StoredDevice>(
            predicate: #Predicate { $0.deviceId == deviceId }
        )
        descriptor.fetchLimit = 1

        if let existing = try context.fetch(descriptor).first {
            if !device.mdnsHost.isEmpty { existing.mdnsHost = device.mdnsHost }
            if let staIP = device.staIP { existing.staIP = staIP }
            if let apiToken = device.apiToken { existing.apiToken = apiToken }
            existing.jiggleEnabled = device.jiggleEnabled
            existing.lastSeen = device.lastSeen
            existing.firmwareVersion = device.firmwareVersion
            existing.protocolVersion = device.protocolVersion
            existing.capabilities = Array(Set(existing.capabilities).union(device.capabilities)).sorted()
            existing.otaSchema = device.otaSchema
            existing.lastCapabilitiesUpdate = device.capabilities.isEmpty ? existing.lastCapabilitiesUpdate : Date()
        } else {
            context.insert(StoredDevice(device: device))
        }
        try context.save()
    }
}

enum DeviceMerge {
    static func wifi(_ status: DeviceStatus, fallbackHost: String, token: String?, into stored: StoredDevice) {
        if let discoveredId = status.deviceId,
           stored.deviceId.caseInsensitiveCompare(discoveredId) != .orderedSame { return }
        if let mdns = status.mdns?.trimmingCharacters(in: .whitespacesAndNewlines), !mdns.isEmpty {
            stored.mdnsHost = mdns
        } else if stored.mdnsHost.isEmpty {
            stored.mdnsHost = fallbackHost
        }
        if let ip = status.staIp?.trimmingCharacters(in: .whitespacesAndNewlines), !ip.isEmpty { stored.staIP = ip }
        if let token, !token.isEmpty { stored.apiToken = token }
        stored.jiggleEnabled = status.jiggle
        stored.lastSeen = Date()
        stored.firmwareVersion = status.version
        stored.protocolVersion = status.protocolVersion
        stored.otaSchema = status.otaSchema
        stored.capabilities = Array(Set(stored.capabilities).union(status.capabilities)).sorted()
        stored.lastCapabilitiesUpdate = Date()
    }

    static func bluetooth(_ metadata: BLEDeviceMetadata, token: String?, into stored: StoredDevice) {
        guard stored.deviceId.caseInsensitiveCompare(metadata.deviceId) == .orderedSame else { return }
        if let token, !token.isEmpty { stored.apiToken = token }
        stored.lastSeen = Date()
        stored.firmwareVersion = metadata.firmware
        stored.protocolVersion = metadata.protocolVersion
        stored.otaSchema = metadata.otaSchema
        stored.capabilities = Array(Set(stored.capabilities).union(metadata.capabilities)).sorted()
        stored.lastCapabilitiesUpdate = Date()
        stored.bluetoothDiscovered = true
    }
}
