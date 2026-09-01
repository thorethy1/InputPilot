import Foundation

struct Device: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var displayName: String
    var mdnsHost: String
    var staIP: String?
    var jiggleEnabled: Bool
    var moveIntervalMs: Int
    var clickEnabled: Bool
    var clickIntervalMs: Int
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
        jiggleEnabled: Bool = false,
        moveIntervalMs: Int = 30_000,
        clickEnabled: Bool = false,
        clickIntervalMs: Int = 60_000,
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
        self.jiggleEnabled = jiggleEnabled
        self.moveIntervalMs = moveIntervalMs
        self.clickEnabled = clickEnabled
        self.clickIntervalMs = clickIntervalMs
        self.lastSeen = lastSeen
        self.firmwareVersion = firmwareVersion
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.otaSchema = otaSchema
    }

    init(status: DeviceStatus, deviceId: String, endpointHost: String) {
        id = deviceId
        displayName = status.name
        mdnsHost = status.mdns ?? endpointHost
        staIP = DeviceEndpointResolver.directAddress(reportedSTAIP: status.staIp, fallbackHost: endpointHost)
        jiggleEnabled = status.jiggle
        moveIntervalMs = status.jiggleIntervalMs
        clickEnabled = status.clickEnabled
        clickIntervalMs = status.clickIntervalMs
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
    let clickEnabled: Bool
    let clickIntervalMs: Int
    let staIp: String?
    let mdns: String?
    let protocolVersion: Int
    let capabilities: [String]
    let radioMode: String?
    let otaSchema: Int

    enum CodingKeys: String, CodingKey {
        case ok
        case name
        case version
        case deviceId = "device_id"
        case jiggle
        case jiggleIntervalMs = "jiggle_interval_ms"
        case clickEnabled = "click_enabled"
        case clickIntervalMs = "click_interval_ms"
        case staIp = "sta_ip"
        case mdns
        case protocolVersion = "protocol_version"
        case capabilities
        case radioMode = "radio_mode"
        case otaSchema = "ota_schema"
    }

    init(
        ok: Bool,
        name: String,
        version: String,
        deviceId: String? = nil,
        jiggle: Bool,
        jiggleIntervalMs: Int,
        clickEnabled: Bool = false,
        clickIntervalMs: Int = 60_000,
        staIp: String? = nil,
        mdns: String? = nil,
        protocolVersion: Int = 0,
        capabilities: [String] = [],
        radioMode: String? = nil,
        otaSchema: Int = 0
    ) {
        self.ok = ok
        self.name = name
        self.version = version
        self.deviceId = deviceId
        self.jiggle = jiggle
        self.jiggleIntervalMs = jiggleIntervalMs
        self.clickEnabled = clickEnabled
        self.clickIntervalMs = clickIntervalMs
        self.staIp = staIp
        self.mdns = mdns
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.radioMode = radioMode
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
        clickEnabled = try container.decodeIfPresent(Bool.self, forKey: .clickEnabled) ?? false
        clickIntervalMs = try container.decodeIfPresent(Int.self, forKey: .clickIntervalMs) ?? 60_000
        staIp = try container.decodeIfPresent(String.self, forKey: .staIp)
        mdns = try container.decodeIfPresent(String.self, forKey: .mdns)
        protocolVersion = try container.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? 0
        capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        radioMode = try container.decodeIfPresent(String.self, forKey: .radioMode)
        otaSchema = try container.decodeIfPresent(Int.self, forKey: .otaSchema) ?? 0
    }
}

struct KeepAwakeSettings: Codable, Equatable, Sendable {
    let moveEnabled: Bool
    let moveIntervalMs: Int
    let clickEnabled: Bool
    let clickIntervalMs: Int

    enum CodingKeys: String, CodingKey {
        case moveEnabled = "move_enabled"
        case moveIntervalMs = "move_interval_ms"
        case clickEnabled = "click_enabled"
        case clickIntervalMs = "click_interval_ms"
    }
}
