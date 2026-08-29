import CryptoKit
import Foundation
import Security

struct PairingInputFrame: Equatable {
    static let marker = "IPPAIR1"
    let deviceId: String
    let secret: Data

    init(deviceId: String, secret: Data) {
        self.deviceId = deviceId.lowercased()
        self.secret = secret
    }

    init?(encoded: String) {
        let value = encoded.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard value.hasPrefix(Self.marker) else { return nil }
        let tail = value.dropFirst(Self.marker.count)
        guard tail.count == 52, tail.allSatisfy(\.isHexDigit) else { return nil }
        let id = String(tail.prefix(12))
        let secretHex = String(tail.dropFirst(12).prefix(32))
        let checksumHex = String(tail.suffix(8))
        guard let bytes = Data(hex: secretHex), bytes.count == 16 else { return nil }
        var checksum: UInt32 = 2_166_136_261
        for byte in bytes { checksum = (checksum ^ UInt32(byte)) &* 16_777_619 }
        guard String(format: "%08X", checksum) == checksumHex else { return nil }
        deviceId = id.lowercased()
        secret = bytes
    }
}

enum PairingKeyStore {
    private static let service = "com.thorethy.inputpilot.pairing"

    static func save(_ secret: Data, deviceId: String) throws {
        guard secret.count == 16 else { throw SecureChannelError.invalidSecret }
        let account = deviceId.lowercased()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = secret
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecureChannelError.keychain(status) }
    }

    static func load(deviceId: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceId.lowercased(),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func remove(deviceId: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceId.lowercased(),
        ] as CFDictionary)
    }
}

enum SecureChannelError: Error, Equatable {
    case invalidSecret
    case invalidChallenge
    case wrongDevice
    case invalidServerProof
    case notReady
    case keychain(OSStatus)
}

final class SecureChannel {
    static let binaryVersion: UInt8 = 0xA1
    private let deviceId: String
    private let secret: SymmetricKey
    private var sendKey: SymmetricKey?
    private var receiveKey: SymmetricKey?
    private var transcript: Data?
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0

    init(deviceId: String, secret: Data) throws {
        guard secret.count == 16 else { throw SecureChannelError.invalidSecret }
        self.deviceId = deviceId.lowercased()
        self.secret = SymmetricKey(data: secret)
    }

    func hello(for challenge: String) throws -> String {
        let fields = challenge.split(separator: " ")
        guard fields.count == 5, fields[0] == "secure", fields[1] == "challenge",
              fields[2] == "1", let serverNonce = Data(hex: String(fields[4])),
              serverNonce.count == 16 else { throw SecureChannelError.invalidChallenge }
        guard fields[3].lowercased() == deviceId else { throw SecureChannelError.wrongDevice }
        var clientNonce = Data(count: 16)
        let status = clientNonce.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw SecureChannelError.keychain(status) }
        var clientTranscript = Data("IPSEC1-C\(deviceId)".utf8)
        clientTranscript.append(serverNonce)
        clientTranscript.append(clientNonce)
        let proof = Data(HMAC<SHA256>.authenticationCode(for: clientTranscript, using: secret))
        var serverTranscript = Data("IPSEC1-S\(deviceId)".utf8)
        serverTranscript.append(serverNonce)
        serverTranscript.append(clientNonce)
        transcript = serverTranscript
        var salt = serverNonce
        salt.append(clientNonce)
        sendKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: secret,
            salt: salt,
            info: Data("InputPilot secure protocol v2 client".utf8),
            outputByteCount: 32
        )
        receiveKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: secret,
            salt: salt,
            info: Data("InputPilot secure protocol v2 server".utf8),
            outputByteCount: 32
        )
        sendCounter = 0
        receiveCounter = 0
        return "secure hello \(clientNonce.hex) \(proof.hex)"
    }

    func acceptReady(_ reply: String) throws {
        let fields = reply.split(separator: " ")
        guard fields.count == 3, fields[0] == "secure", fields[1] == "ready",
              let supplied = Data(hex: String(fields[2])), supplied.count == 32,
              let transcript else { throw SecureChannelError.invalidServerProof }
        let expected = Data(HMAC<SHA256>.authenticationCode(for: transcript, using: secret))
        guard supplied == expected else { throw SecureChannelError.invalidServerProof }
        self.transcript = nil
    }

    func sealBinary(_ plaintext: Data) throws -> Data {
        guard let sendKey else { throw SecureChannelError.notReady }
        sendCounter &+= 1
        let counter = sendCounter.bigEndianData
        var nonceData = Data([0x49, 0x50, 0x43, 0x02])
        nonceData.append(counter)
        let box = try AES.GCM.seal(
            plaintext,
            using: sendKey,
            nonce: AES.GCM.Nonce(data: nonceData),
            authenticating: Data(deviceId.utf8)
        )
        var record = Data([Self.binaryVersion])
        record.append(counter)
        record.append(box.ciphertext)
        record.append(box.tag)
        return record
    }

    func sealText(_ plaintext: String) throws -> String {
        let record = try sealBinary(Data(plaintext.utf8))
        let counter = record[1 ..< 9]
        let cipher = record[9 ..< record.count - 16]
        let tag = record.suffix(16)
        return "secure data \(Data(counter).hex) \(Data(cipher).hex) \(Data(tag).hex)"
    }

    func openBinary(_ record: Data) throws -> Data {
        guard let receiveKey, record.count >= 25, record.first == Self.binaryVersion else {
            throw SecureChannelError.notReady
        }
        let counterData = Data(record[1 ..< 9])
        let counter = counterData.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard counter > receiveCounter else { throw SecureChannelError.invalidServerProof }
        var nonceData = Data([0x49, 0x50, 0x53, 0x02])
        nonceData.append(counterData)
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonceData),
            ciphertext: Data(record[9 ..< record.count - 16]),
            tag: Data(record.suffix(16))
        )
        let plaintext = try AES.GCM.open(box, using: receiveKey,
                                        authenticating: Data(deviceId.utf8))
        receiveCounter = counter
        return plaintext
    }

    func openText(_ line: String) throws -> String {
        let fields = line.split(separator: " ")
        guard fields.count == 5, fields[0] == "secure", fields[1] == "data",
              let counter = Data(hex: String(fields[2])), counter.count == 8,
              let cipher = Data(hex: String(fields[3])),
              let tag = Data(hex: String(fields[4])), tag.count == 16 else {
            throw SecureChannelError.invalidServerProof
        }
        var record = Data([Self.binaryVersion]); record.append(counter)
        record.append(cipher); record.append(tag)
        guard let plaintext = String(data: try openBinary(record), encoding: .utf8) else {
            throw SecureChannelError.invalidServerProof
        }
        return plaintext
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var output = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
            output.append(byte)
            index = next
        }
        self = output
    }
}

extension Data {
    var hex: String { map { String(format: "%02X", $0) }.joined() }
}

private extension UInt64 {
    var bigEndianData: Data {
        var value = bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}
