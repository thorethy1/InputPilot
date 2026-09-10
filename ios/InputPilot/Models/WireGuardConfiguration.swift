import Foundation

struct WireGuardConfiguration: Equatable, Sendable {
    static let maximumBytes = 2_048
    let text: String
    let address: String
    let endpoint: String
    let allowedIPs: String

    static func parse(_ text: String) throws -> Self {
        let size = text.lengthOfBytes(using: .utf8)
        guard size > 0 else { throw WireGuardConfigurationError.empty }
        guard size <= maximumBytes else { throw WireGuardConfigurationError.tooLarge(size) }

        enum Section { case none, interface, peer }
        var section = Section.none
        var interfaceCount = 0
        var peerCount = 0
        var interface: [String: String] = [:]
        var peer: [String: String] = [:]
        let interfaceKeys: Set<String> = ["privatekey", "address", "listenport", "dns", "mtu"]
        let peerKeys: Set<String> = ["publickey", "presharedkey", "endpoint", "allowedips", "persistentkeepalive"]

        for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = String(rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            switch line.lowercased() {
            case "[interface]":
                interfaceCount += 1
                guard interfaceCount == 1 else { throw WireGuardConfigurationError.multipleInterfaces }
                section = .interface
                continue
            case "[peer]":
                peerCount += 1
                guard peerCount == 1 else { throw WireGuardConfigurationError.multiplePeers }
                section = .peer
                continue
            default:
                break
            }
            guard !line.hasPrefix("["), let equals = line.firstIndex(of: "=") else {
                throw WireGuardConfigurationError.invalidLine(offset + 1)
            }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { throw WireGuardConfigurationError.invalidLine(offset + 1) }
            switch section {
            case .interface:
                guard interfaceKeys.contains(key) else { throw WireGuardConfigurationError.unsupportedKey(offset + 1, key) }
                guard interface.updateValue(value, forKey: key) == nil else { throw WireGuardConfigurationError.duplicateKey(offset + 1, key) }
            case .peer:
                guard peerKeys.contains(key) else { throw WireGuardConfigurationError.unsupportedKey(offset + 1, key) }
                guard peer.updateValue(value, forKey: key) == nil else { throw WireGuardConfigurationError.duplicateKey(offset + 1, key) }
            case .none:
                throw WireGuardConfigurationError.invalidLine(offset + 1)
            }
        }

        guard interfaceCount == 1 else { throw WireGuardConfigurationError.missingInterface }
        guard peerCount == 1 else { throw WireGuardConfigurationError.missingPeer }
        guard let privateKey = interface["privatekey"], validKey(privateKey) else {
            throw WireGuardConfigurationError.invalidPrivateKey
        }
        guard let addressValue = interface["address"] else { throw WireGuardConfigurationError.missingAddress }
        guard !addressValue.contains(",") else { throw WireGuardConfigurationError.multipleAddresses }
        let address = try parseIPv4Range(addressValue)
        guard let publicKey = peer["publickey"], validKey(publicKey) else {
            throw WireGuardConfigurationError.invalidPublicKey
        }
        if let presharedKey = peer["presharedkey"], !validKey(presharedKey) {
            throw WireGuardConfigurationError.invalidPresharedKey
        }
        guard let endpoint = peer["endpoint"], validEndpoint(endpoint) else {
            throw WireGuardConfigurationError.invalidEndpoint
        }
        guard let allowed = peer["allowedips"] else { throw WireGuardConfigurationError.missingAllowedIPs }
        guard !allowed.contains(",") else { throw WireGuardConfigurationError.multipleAllowedIPs }
        _ = try parseIPv4Range(allowed)
        guard range(allowed, contains: address) else {
            throw WireGuardConfigurationError.allowedIPsRouteMismatch
        }
        if let port = interface["listenport"], !(UInt16(port).map { $0 > 0 } ?? false) {
            throw WireGuardConfigurationError.invalidListenPort
        }
        if let keepalive = peer["persistentkeepalive"], UInt16(keepalive) == nil {
            throw WireGuardConfigurationError.invalidKeepalive
        }
        if let mtu = interface["mtu"], !(Int(mtu).map { (576 ... 1_420).contains($0) } ?? false) {
            throw WireGuardConfigurationError.unsupportedMTU
        }
        return Self(text: text, address: address, endpoint: endpoint, allowedIPs: allowed)
    }

    private static func validKey(_ value: String) -> Bool {
        Data(base64Encoded: value)?.count == 32 && value.utf8.count == 44
    }

    private static func parseIPv4Range(_ value: String) throws -> String {
        let fields = value.split(separator: "/", omittingEmptySubsequences: false)
        guard fields.count == 2, validIPv4(String(fields[0])),
              let prefix = Int(fields[1]), (0 ... 32).contains(prefix) else {
            if value.contains(":") { throw WireGuardConfigurationError.ipv6Unsupported }
            throw WireGuardConfigurationError.invalidAddress
        }
        return String(fields[0])
    }

    private static func validIPv4(_ value: String) -> Bool {
        let octets = value.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy {
            !$0.isEmpty && ($0.count == 1 || $0.first != "0") && Int($0).map { (0 ... 255).contains($0) } == true
        }
    }

    private static func validEndpoint(_ value: String) -> Bool {
        guard !value.hasPrefix("["), value.filter({ $0 == ":" }).count == 1,
              let colon = value.lastIndex(of: ":"), colon != value.startIndex else { return false }
        let host = value[..<colon]
        let permitted = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        guard !host.isEmpty, host.utf8.count <= 96,
              host.unicodeScalars.allSatisfy({ permitted.contains($0) }) else { return false }
        return UInt16(value[value.index(after: colon)...]).map { $0 > 0 } ?? false
    }

    private static func range(_ range: String, contains address: String) -> Bool {
        let fields = range.split(separator: "/")
        guard fields.count == 2, let prefix = Int(fields[1]),
              let network = ipv4Number(String(fields[0])), let candidate = ipv4Number(address) else { return false }
        let mask: UInt32 = prefix == 0 ? 0 : UInt32.max << UInt32(32 - prefix)
        return network & mask == candidate & mask
    }

    private static func ipv4Number(_ value: String) -> UInt32? {
        let octets = value.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        return octets.reduce(UInt32(0)) { partial, octet in
            (partial << 8) | UInt32(Int(octet) ?? 0)
        }
    }
}

enum WireGuardConfigurationError: LocalizedError, Equatable {
    case empty, tooLarge(Int), invalidEncoding, invalidLine(Int), unsupportedKey(Int, String), duplicateKey(Int, String)
    case multipleInterfaces, multiplePeers, missingInterface, missingPeer
    case invalidPrivateKey, missingAddress, multipleAddresses, invalidPublicKey, invalidPresharedKey
    case invalidEndpoint, missingAllowedIPs, multipleAllowedIPs, invalidAddress, ipv6Unsupported
    case invalidListenPort, invalidKeepalive, unsupportedMTU, allowedIPsRouteMismatch

    var errorDescription: String? {
        switch self {
        case .empty: "The WireGuard configuration is empty."
        case let .tooLarge(size): "The configuration is \(size) bytes; the InputPilot limit is 2048 bytes."
        case .invalidEncoding: "The WireGuard configuration must be UTF-8 text."
        case let .invalidLine(line): "Line \(line) is not a valid wg-quick setting."
        case let .unsupportedKey(line, key): "Line \(line) uses unsupported setting ‘\(key)’."
        case let .duplicateKey(line, key): "Line \(line) repeats ‘\(key)’."
        case .multipleInterfaces: "InputPilot supports one WireGuard interface per device."
        case .multiplePeers: "InputPilot supports one WireGuard peer per device."
        case .missingInterface: "The configuration needs an [Interface] section."
        case .missingPeer: "The configuration needs one [Peer] section."
        case .invalidPrivateKey: "[Interface] needs a valid 32-byte PrivateKey."
        case .missingAddress: "[Interface] needs one IPv4 Address with a prefix."
        case .multipleAddresses: "InputPilot supports one WireGuard interface address."
        case .invalidPublicKey: "[Peer] needs a valid 32-byte PublicKey."
        case .invalidPresharedKey: "PresharedKey is not a valid 32-byte key."
        case .invalidEndpoint: "[Peer] needs an IPv4 or hostname Endpoint with a port."
        case .missingAllowedIPs: "[Peer] needs one IPv4 AllowedIPs range."
        case .multipleAllowedIPs: "InputPilot currently supports one AllowedIPs range."
        case .invalidAddress: "A WireGuard IPv4 address or prefix is invalid."
        case .ipv6Unsupported: "This ESP32 WireGuard implementation does not support IPv6."
        case .invalidListenPort: "ListenPort must be between 1 and 65535."
        case .invalidKeepalive: "PersistentKeepalive must be between 0 and 65535 seconds."
        case .unsupportedMTU: "MTU must be between 576 and 1420 bytes."
        case .allowedIPsRouteMismatch: "AllowedIPs must include the WireGuard interface address on InputPilot."
        }
    }
}

struct WireGuardDeviceStatus: Decodable, Equatable, Sendable {
    enum State: String, Decodable, Sendable {
        case disabled, notConfigured = "not_configured", waitingWiFi = "waiting_wifi"
        case ssidBlocked = "ssid_blocked", waitingTime = "waiting_time"
        case connecting, connected, error
    }
    let configured: Bool
    let enabled: Bool
    let state: State
    let ip: String
    let restricted: Bool
    let ssidCount: Int
    var endpoint: String
    let error: String
    var ssids: [String] = []

    enum CodingKeys: String, CodingKey {
        case configured = "c", enabled = "e", state = "s", ip, restricted = "r"
        case ssidCount = "n", error = "x"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        configured = try values.decode(Bool.self, forKey: .configured)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        state = try values.decode(State.self, forKey: .state)
        ip = try values.decode(String.self, forKey: .ip)
        restricted = try values.decode(Bool.self, forKey: .restricted)
        ssidCount = try values.decode(Int.self, forKey: .ssidCount)
        endpoint = ""
        error = try values.decode(String.self, forKey: .error)
        ssids = []
    }
}

@MainActor enum WireGuardDeviceClient {
    typealias Request = (_ command: String, _ timeout: TimeInterval) async throws -> String
    typealias BinaryRequest = (_ plaintext: Data, _ timeout: TimeInterval) async throws -> String

    static func status(includeDetails: Bool = true,
                       using request: Request) async throws -> WireGuardDeviceStatus {
        var status = try decode(WireGuardDeviceStatus.self, from: try await request("WIREGUARD STATUS", 5))
        guard (0 ... 5).contains(status.ssidCount) else {
            throw TransportError.failed("InputPilot returned an invalid WireGuard SSID count.")
        }
        if includeDetails {
            for index in 0 ..< status.ssidCount {
                struct Entry: Decodable { let ssid: String }
                status.ssids.append(try decode(Entry.self, from: try await request("WIREGUARD SSID \(index)", 5)).ssid)
            }
            if status.configured {
                struct Peer: Decodable { let p: String }
                status.endpoint = try decode(Peer.self, from: try await request("WIREGUARD PEER", 5)).p
            }
        }
        return status
    }

    static func install(_ configuration: WireGuardConfiguration, enabled: Bool,
                        restrictedTo ssids: [String], token suppliedToken: UInt64? = nil,
                        using request: Request, binaryRequest: BinaryRequest? = nil) async throws {
        let data = Data(configuration.text.utf8)
        let token = suppliedToken ?? UInt64.random(in: 1 ... UInt64.max)
        let tokenText = String(format: "%016llx", token)
        let checksum = data.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
        do {
            // Install disabled first, so an SSID-restricted profile can never
            // start in the interval before its policy has been committed.
            let begin = "WIREGUARD BEGIN \(tokenText) \(data.count) \(String(format: "%08x", checksum)) 0"
            let beginReply = try await request(begin, 8)
            let fields = beginReply.split(separator: " ").map(String.init)
            guard fields.count == 4, fields[0] == "wireguard", fields[1] == "ready",
                  fields[2] == tokenText, let received = Int(fields[3]), (0 ... data.count).contains(received) else {
                throw protocolError(beginReply)
            }
            var offset = received
            while offset < data.count {
                let count = min(binaryRequest == nil ? 60 : 128, data.count - offset)
                let chunk = Data(data[offset ..< offset + count])
                let reply: String
                if let binaryRequest {
                    var payload = Data([0xFE, 0x09])
                    payload.appendBigEndian(token)
                    payload.appendBigEndian(UInt32(offset))
                    payload.append(chunk)
                    reply = try await binaryRequest(payload, 8)
                } else {
                    reply = try await request("WIREGUARD DATA \(tokenText) \(offset) \(chunk.wireGuardHex)", 8)
                }
                offset += count
                guard reply == "wireguard ack \(tokenText) \(offset)" else { throw protocolError(reply) }
            }
            guard try await request("WIREGUARD COMMIT \(tokenText)", 8) == "wireguard committed" else {
                throw TransportError.failed("InputPilot could not commit the WireGuard profile.")
            }
            try await setPolicy(ssids: ssids, using: request, binaryRequest: binaryRequest)
            if enabled { try await setEnabled(true, using: request) }
        } catch {
            _ = try? await request("WIREGUARD ABORT \(tokenText)", 3)
            throw error
        }
    }

    static func setPolicy(ssids: [String], using request: Request,
                          binaryRequest: BinaryRequest? = nil) async throws {
        let normalized = Array(Set(ssids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })).sorted()
        guard normalized.count <= 5, normalized.allSatisfy({ (1 ... 32).contains($0.lengthOfBytes(using: .utf8)) }) else {
            throw TransportError.failed("Choose up to five Wi-Fi names of 1 to 32 UTF-8 bytes.")
        }
        let begin = normalized.isEmpty ? "WIREGUARD POLICY ANY" : "WIREGUARD POLICY BEGIN"
        guard try await request(begin, 5) == "wireguard policy ready" else {
            throw TransportError.failed("InputPilot rejected the WireGuard Wi-Fi policy.")
        }
        for ssid in normalized {
            let reply: String
            if let binaryRequest {
                let ssidData = Data(ssid.utf8)
                var payload = Data([0xFE, 0x0A, UInt8(ssidData.count)])
                payload.append(ssidData)
                reply = try await binaryRequest(payload, 5)
            } else {
                reply = try await request("WIREGUARD POLICY ADD \(Data(ssid.utf8).wireGuardHex)", 5)
            }
            guard reply == "wireguard policy ack" else {
                throw TransportError.failed("InputPilot rejected Wi-Fi network ‘\(ssid)’.")
            }
        }
        guard try await request("WIREGUARD POLICY COMMIT", 5) == "wireguard policy committed" else {
            throw TransportError.failed("InputPilot could not save the WireGuard Wi-Fi policy.")
        }
    }

    static func setEnabled(_ enabled: Bool, using request: Request) async throws {
        let reply = try await request("WIREGUARD ENABLE \(enabled ? 1 : 0)", 5)
        guard reply == "wireguard enabled" else { throw protocolError(reply) }
    }

    static func remove(using request: Request) async throws {
        let reply = try await request("WIREGUARD REMOVE", 5)
        guard reply == "wireguard removed" else { throw protocolError(reply) }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from reply: String) throws -> T {
        if reply.hasPrefix("error ") { throw protocolError(reply) }
        do { return try JSONDecoder().decode(type, from: Data(reply.utf8)) }
        catch { throw TransportError.failed("InputPilot returned invalid WireGuard status data.") }
    }

    private static func protocolError(_ reply: String) -> Error {
        let code = reply.hasPrefix("error ") ? String(reply.dropFirst(6)) : reply
        if code.hasPrefix("wireguard_config_") {
            return TransportError.failed("The ESP32 rejected this WireGuard configuration (\(code.dropFirst(17))).")
        }
        return switch code {
        case "wireguard_busy": TransportError.failed("Another WireGuard upload is active.")
        case "wireguard_checksum": TransportError.failed("The WireGuard configuration failed transfer validation.")
        case "wireguard_storage": TransportError.failed("InputPilot could not persist the WireGuard settings.")
        case "wireguard_not_found": TransportError.failed("No WireGuard configuration is stored on InputPilot.")
        case "ota_busy": TransportError.failed("Wait for the firmware update to finish.")
        default: TransportError.failed("InputPilot rejected the WireGuard operation (\(code)).")
        }
    }
}

private extension Data {
    var wireGuardHex: String { map { String(format: "%02x", $0) }.joined() }

    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var encoded = value.bigEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }
}
