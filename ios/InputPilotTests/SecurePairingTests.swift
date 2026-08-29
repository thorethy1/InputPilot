import CryptoKit
import XCTest
@testable import InputPilot

final class SecurePairingTests: XCTestCase {
    private let deviceId = "aabbccddeeff"
    private let secret = Data((0 ..< 16).map(UInt8.init))

    func testPairingFrameParsesAndRejectsCorruption() {
        let encoded = "IPPAIR1aabbccddeeff000102030405060708090A0B0C0D0E0FC8FFF215"
        XCTAssertEqual(PairingInputFrame(encoded: encoded), PairingInputFrame(deviceId: deviceId, secret: secret))
        XCTAssertNil(PairingInputFrame(encoded: String(encoded.dropLast()) + "0"))
    }

    func testDirectionalV2KeysInteroperateAndRejectReplay() throws {
        let serverNonce = Data(repeating: 0xA5, count: 16)
        let channel = try SecureChannel(deviceId: deviceId, secret: secret)
        let hello = try channel.hello(for: "secure challenge 1 \(deviceId) \(hex(serverNonce))")
        let fields = hello.split(separator: " ")
        let clientNonce = try XCTUnwrap(data(hex: String(fields[2])))
        var serverTranscript = Data("IPSEC1-S\(deviceId)".utf8)
        serverTranscript.append(serverNonce); serverTranscript.append(clientNonce)
        let serverProof = Data(HMAC<SHA256>.authenticationCode(for: serverTranscript, using: SymmetricKey(data: secret)))
        try channel.acceptReady("secure ready \(hex(serverProof))")

        var salt = serverNonce; salt.append(clientNonce)
        let serverKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: salt, info: Data("InputPilot secure protocol v2 server".utf8), outputByteCount: 32)
        let counter = UInt64(1).bigEndianData
        var nonce = Data([0x49, 0x50, 0x53, 0x02]); nonce.append(counter)
        let box = try AES.GCM.seal(Data("ota ready 0".utf8), using: serverKey, nonce: AES.GCM.Nonce(data: nonce), authenticating: Data(deviceId.utf8))
        var record = Data([SecureChannel.binaryVersion]); record.append(counter); record.append(box.ciphertext); record.append(box.tag)
        XCTAssertEqual(try channel.openBinary(record), Data("ota ready 0".utf8))
        XCTAssertThrowsError(try channel.openBinary(record))
    }

    private func hex(_ value: Data) -> String { value.map { String(format: "%02X", $0) }.joined() }
    private func data(hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var result = Data(); var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            result.append(byte); index = next
        }
        return result
    }
}

private extension UInt64 {
    var bigEndianData: Data { var value = bigEndian; return withUnsafeBytes(of: &value) { Data($0) } }
}
