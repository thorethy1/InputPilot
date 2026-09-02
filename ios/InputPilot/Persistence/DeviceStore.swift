import Foundation
import SwiftData

@Model
final class StoredDevice {
    @Attribute(.unique) var deviceId: String
    var displayName: String
    var mdnsHost: String
    var staIP: String?
    var jiggleEnabled: Bool
    var moveIntervalMs: Int = 30_000
    var clickEnabled: Bool = false
    var clickIntervalMs: Int = 60_000
    var lastSeen: Date?
    var firmwareVersion: String?
    var protocolVersion: Int = 0
    var capabilities: [String] = []
    var otaSchema: Int = 0
    var runningPartition: String?
    var bootPartition: String?
    var usbManufacturerName: String?
    var usbProductName: String?
    var usbVendorID: Int?
    var usbProductID: Int?
    var usbSerialNumber: String?
    var usbIdentityUpdatedAt: Date?
    var cachedWiFiNetworks: [String] = []
    var wifiNetworksUpdatedAt: Date?
    var bluetoothDiscovered: Bool = false
    var lastCapabilitiesUpdate: Date?

    init(
        deviceId: String,
        displayName: String,
        mdnsHost: String,
        staIP: String? = nil,
        jiggleEnabled: Bool = false,
        moveIntervalMs: Int = 30_000,
        clickEnabled: Bool = false,
        clickIntervalMs: Int = 60_000,
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
        self.jiggleEnabled = jiggleEnabled
        self.moveIntervalMs = moveIntervalMs
        self.clickEnabled = clickEnabled
        self.clickIntervalMs = clickIntervalMs
        self.lastSeen = lastSeen
        self.firmwareVersion = firmwareVersion
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.lastCapabilitiesUpdate = lastCapabilitiesUpdate
        self.otaSchema = otaSchema
        self.runningPartition = nil
        self.bootPartition = nil
        self.usbManufacturerName = nil
        self.usbProductName = nil
        self.usbVendorID = nil
        self.usbProductID = nil
        self.usbSerialNumber = nil
        self.usbIdentityUpdatedAt = nil
        self.cachedWiFiNetworks = []
        self.wifiNetworksUpdatedAt = nil
        self.bluetoothDiscovered = bluetoothDiscovered
    }

    convenience init(device: Device) {
        self.init(
            deviceId: device.id,
            displayName: device.displayName,
            mdnsHost: device.mdnsHost,
            staIP: device.staIP,
            jiggleEnabled: device.jiggleEnabled,
            moveIntervalMs: device.moveIntervalMs,
            clickEnabled: device.clickEnabled,
            clickIntervalMs: device.clickIntervalMs,
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
            jiggleEnabled: jiggleEnabled,
            moveIntervalMs: moveIntervalMs,
            clickEnabled: clickEnabled,
            clickIntervalMs: clickIntervalMs,
            lastSeen: lastSeen,
            firmwareVersion: firmwareVersion,
            protocolVersion: protocolVersion,
            capabilities: capabilities,
            otaSchema: otaSchema
        )
    }

    var cachedUSBIdentity: USBIdentity? {
        guard let productName = usbProductName,
              let vid = usbVendorID,
              let pid = usbProductID,
              let serialNumber = usbSerialNumber else { return nil }
        return USBIdentity(
            manufacturerName: usbManufacturerName,
            productName: productName,
            vid: vid,
            pid: pid,
            serialNumber: serialNumber
        )
    }

    func cacheUSBIdentity(_ identity: USBIdentity, at date: Date = Date()) {
        if let manufacturerName = identity.manufacturerName {
            usbManufacturerName = manufacturerName
        }
        usbProductName = identity.productName
        usbVendorID = identity.vid
        usbProductID = identity.pid
        usbSerialNumber = identity.serialNumber
        usbIdentityUpdatedAt = date
    }

    func cacheWiFiNetworks(_ networks: [String], at date: Date = Date()) {
        cachedWiFiNetworks = Array(networks.prefix(5))
        wifiNetworksUpdatedAt = date
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
            existing.jiggleEnabled = device.jiggleEnabled
            existing.moveIntervalMs = device.moveIntervalMs
            existing.clickEnabled = device.clickEnabled
            existing.clickIntervalMs = device.clickIntervalMs
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
    static func wifi(_ status: DeviceStatus, fallbackHost: String, into stored: StoredDevice) {
        if let discoveredId = status.deviceId,
           stored.deviceId.caseInsensitiveCompare(discoveredId) != .orderedSame { return }
        migrateLegacyAutomaticName(status.name, into: stored)
        if let mdns = status.mdns?.trimmingCharacters(in: .whitespacesAndNewlines), !mdns.isEmpty {
            stored.mdnsHost = mdns
        } else if stored.mdnsHost.isEmpty {
            stored.mdnsHost = fallbackHost
        }
        if let address = DeviceEndpointResolver.directAddress(reportedSTAIP: status.staIp, fallbackHost: fallbackHost) {
            stored.staIP = address
        }
        stored.jiggleEnabled = status.jiggle
        stored.moveIntervalMs = status.jiggleIntervalMs
        stored.clickEnabled = status.clickEnabled
        stored.clickIntervalMs = status.clickIntervalMs
        stored.lastSeen = Date()
        stored.firmwareVersion = status.version
        stored.protocolVersion = status.protocolVersion
        stored.otaSchema = status.otaSchema
        stored.capabilities = Array(Set(stored.capabilities).union(status.capabilities)).sorted()
        stored.lastCapabilitiesUpdate = Date()
    }

    static func bluetooth(_ metadata: BLEDeviceMetadata, into stored: StoredDevice) {
        guard stored.deviceId.caseInsensitiveCompare(metadata.deviceId) == .orderedSame else { return }
        migrateLegacyAutomaticName(metadata.deviceName, into: stored)
        stored.lastSeen = Date()
        stored.firmwareVersion = metadata.firmware
        stored.protocolVersion = metadata.protocolVersion
        stored.otaSchema = metadata.otaSchema
        stored.capabilities = Array(Set(stored.capabilities).union(metadata.capabilities)).sorted()
        stored.lastCapabilitiesUpdate = Date()
        stored.bluetoothDiscovered = true
    }

    private static func migrateLegacyAutomaticName(_ discoveredName: String, into stored: StoredDevice) {
        let prefix = "InputPilot-"
        guard stored.displayName.hasPrefix(prefix), !discoveredName.isEmpty else { return }
        let suffix = String(stored.displayName.dropFirst(prefix.count))
        let isLegacyHexName = suffix.count == 4 && suffix.allSatisfy(\.isHexDigit)
        let legacyWords = ["Aero", "Bolt", "Cove", "Dupe", "Echo", "Flux"]
        let isLegacyFriendlyName = legacyWords.contains { word in
            suffix.count == word.count + 1 && suffix.hasPrefix(word) && suffix.last?.isNumber == true
        }
        guard isLegacyHexName || isLegacyFriendlyName else { return }
        stored.displayName = discoveredName
    }
}
