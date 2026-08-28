import CryptoKit
import XCTest
@testable import InputPilot

final class SecurePairingTests: XCTestCase {
    private let deviceId = "aabbccddeeff"
    private let secret = Data((0 ..< 16).map(UInt8.init))

    func testPairingFrameParsesAndRejectsCorruption() {
        let encoded = "IPPAIR1aabbccddeeff000102030405060708090A0B0C0D0E0FC8FFF215"
        XCTAssertEqual(PairingInputFrame(encoded: encoded),
                       PairingInputFrame(deviceId: deviceId, secret: secret))
        XCTAssertNil(PairingInputFrame(encoded: String(encoded.dropLast()) + "0"))
    }

    func testHandshakeProofAndEncryptedRecordAreInteroperable() throws {
        let serverNonce = Data(repeating: 0xA5, count: 16)
        let channel = try SecureChannel(deviceId: deviceId, secret: secret)
        let hello = try channel.hello(for: "secure challenge 1 \(deviceId) \(hex(serverNonce))")
        let fields = hello.split(separator: " ")
        XCTAssertEqual(fields.count, 4)
        let clientNonce = try XCTUnwrap(data(hex: String(fields[2])))

        var clientTranscript = Data("IPSEC1-C\(deviceId)".utf8)
        clientTranscript.append(serverNonce)
        clientTranscript.append(clientNonce)
        let expectedClientProof = Data(HMAC<SHA256>.authenticationCode(
            for: clientTranscript, using: SymmetricKey(data: secret)))
        XCTAssertEqual(String(fields[3]), hex(expectedClientProof))

        var serverTranscript = Data("IPSEC1-S\(deviceId)".utf8)
        serverTranscript.append(serverNonce)
        serverTranscript.append(clientNonce)
        let serverProof = Data(HMAC<SHA256>.authenticationCode(
            for: serverTranscript, using: SymmetricKey(data: secret)))
        try channel.acceptReady("secure ready \(hex(serverProof))")

        let plaintext = Data([1, 5, 0])
        let record = try channel.sealBinary(plaintext)
        XCTAssertEqual(record.first, SecureChannel.binaryVersion)
        let counter = record[1 ..< 9]
        var nonce = Data([0x49, 0x50, 0x43, 0x01])
        nonce.append(counter)
        var salt = serverNonce
        salt.append(clientNonce)
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret), salt: salt,
            info: Data("InputPilot secure channel v1".utf8), outputByteCount: 32)
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonce),
            ciphertext: record[9 ..< record.count - 16],
            tag: record.suffix(16))
        XCTAssertEqual(try AES.GCM.open(box, using: key,
                                       authenticating: Data(deviceId.utf8)), plaintext)
    }

    private func hex(_ value: Data) -> String {
        value.map { String(format: "%02X", $0) }.joined()
    }

    private func data(hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var result = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
            result.append(byte); index = next
        }
        return result
    }
}
