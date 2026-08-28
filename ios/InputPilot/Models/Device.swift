import Foundation

struct Device: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var displayName: String
    var mdnsHost: String
    var staIP: String?
    var apiToken: String?
    var jiggleEnabled: Bool
    var lastSeen: Date?
    var firmwareVersion: String?
    var protocolVersion: Int
    var capabilities: [String]
    var otaSchema: Int

    init(
        id: String,
        displayName: String,
        mdnsHost: String,
        staIP: String? = nil,
        apiToken: String? = nil,
        jiggleEnabled: Bool = false,
        lastSeen: Date? = nil,
        firmwareVersion: String? = nil,
        protocolVersion: Int = 0,
        capabilities: [String] = [],
        otaSchema: Int = 0
    ) {
        self.id = id
        self.displayName = displayName
        self.mdnsHost = mdnsHost
        self.staIP = staIP
        self.apiToken = apiToken
        self.jiggleEnabled = jiggleEnabled
        self.lastSeen = lastSeen
        self.firmwareVersion = firmwareVersion
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.otaSchema = otaSchema
    }

    init(status: DeviceStatus, fallbackHost: String) {
        id = status.deviceId ?? fallbackHost
        displayName = status.name
        mdnsHost = status.mdns ?? fallbackHost
        staIP = DeviceEndpointResolver.directAddress(reportedSTAIP: status.staIp, fallbackHost: fallbackHost)
        apiToken = nil
        jiggleEnabled = status.jiggle
        lastSeen = Date()
        firmwareVersion = status.version
        protocolVersion = status.protocolVersion
        capabilities = status.capabilities
        otaSchema = status.otaSchema
    }
}

struct DeviceStatus: Codable, Equatable, Sendable {
    let ok: Bool
    let name: String
    let version: String
    let deviceId: String?
    let jiggle: Bool
    let jiggleIntervalMs: Int
    let staIp: String?
    let mdns: String?
    let authRequired: Bool
    let protocolVersion: Int
    let capabilities: [String]
    let otaSchema: Int

    enum CodingKeys: String, CodingKey {
        case ok
        case name
        case version
        case deviceId = "device_id"
        case jiggle
        case jiggleIntervalMs = "jiggle_interval_ms"
        case staIp = "sta_ip"
        case mdns
        case authRequired = "auth_required"
        case protocolVersion = "protocol_version"
        case capabilities
        case otaSchema = "ota_schema"
    }

    init(
        ok: Bool,
        name: String,
        version: String,
        deviceId: String? = nil,
        jiggle: Bool,
        jiggleIntervalMs: Int,
        staIp: String? = nil,
        mdns: String? = nil,
        authRequired: Bool = false,
        protocolVersion: Int = 0,
        capabilities: [String] = [],
        otaSchema: Int = 0
    ) {
        self.ok = ok
        self.name = name
        self.version = version
        self.deviceId = deviceId
        self.jiggle = jiggle
        self.jiggleIntervalMs = jiggleIntervalMs
        self.staIp = staIp
        self.mdns = mdns
        self.authRequired = authRequired
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.otaSchema = otaSchema
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? true
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "InputPilot-Firmware"
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "unknown"
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId)
        jiggle = try container.decodeIfPresent(Bool.self, forKey: .jiggle) ?? false
        jiggleIntervalMs = try container.decodeIfPresent(Int.self, forKey: .jiggleIntervalMs) ?? 10000
        staIp = try container.decodeIfPresent(String.self, forKey: .staIp)
        mdns = try container.decodeIfPresent(String.self, forKey: .mdns)
        // Older firmware (e.g. 0.3.3) omits auth_required.
        authRequired = try container.decodeIfPresent(Bool.self, forKey: .authRequired) ?? false
        protocolVersion = try container.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? 0
        capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        otaSchema = try container.decodeIfPresent(Int.self, forKey: .otaSchema) ?? 0
    }
}

struct JiggleRequest: Encodable, Sendable {
    let enabled: Bool
}

struct WifiProvisionRequest: Encodable, Sendable {
    let ssid: String
    let password: String

    enum CodingKeys: String, CodingKey {
        case ssid
        case password
    }
}

struct WifiStatus: Codable, Equatable, Sendable {
    let ok: Bool?
    let mode: String?
    let configured: Bool?
    let ssid: String?
    let staIp: String?
    let deviceId: String?
    let apSsid: String?
    let apIp: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case mode
        case configured
        case ssid
        case staIp = "sta_ip"
        case deviceId = "device_id"
        case apSsid = "ap_ssid"
        case apIp = "ap_ip"
    }
}

struct USBIdentity: Codable, Equatable, Sendable {
    let productName: String
    let vid: Int
    let pid: Int
    let vidHex: String?
    let pidHex: String?
    let serialNumber: String
    let requiresRestart: Bool

    enum CodingKeys: String, CodingKey {
        case productName = "product_name"
        case vid
        case pid
        case vidHex = "vid_hex"
        case pidHex = "pid_hex"
        case serialNumber = "serial_number"
        case requiresRestart = "requires_restart"
    }
}

struct USBIdentityUpdate: Encodable, Sendable {
    let productName: String
    let vid: Int
    let pid: Int
    let serialNumber: String

    enum CodingKeys: String, CodingKey {
        case productName = "product_name"
        case vid
        case pid
        case serialNumber = "serial_number"
    }
}

struct USBIdentityReset: Encodable, Sendable {
    let reset = true
}
